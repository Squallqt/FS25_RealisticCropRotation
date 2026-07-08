-- Copyright © 2026 Squallqt. All rights reserved.
-- Sprayer wiring for the RCR consumable products (RCR_FUNGICIDE / RCR_NEMATICIDE): registers their
-- sprayType, short-circuits the native ground treatment, paints our own disease protection/AI data,
-- and keeps the jet as the native white mist (a per-fillType recolour was not visible in-game).
-- processSprayerArea is overwritten at file-source time, not mission load: TypeManager:finalizeTypes()
-- copies it by value into every vehicleType before any load-time hook would run.
RealisticCropRotationSprayerProducts = {}

RealisticCropRotationSprayerProducts.PRODUCT_NAMES = { "RCR_FUNGICIDE", "RCR_NEMATICIDE" }

-- Treatment family per product, used to pick which per-cell protection map the sprayed strip marks.
RealisticCropRotationSprayerProducts.PRODUCT_TREATMENTS = {
    RCR_FUNGICIDE = "FUNGICIDE",
    RCR_NEMATICIDE = "NEMATICIDE",
}

-- fillTypeIndex -> true; refreshed each mission load since fillType indices may shift between savegames.
local productFillTypeSet = {}
-- fillTypeIndex -> "FUNGICIDE" | "NEMATICIDE"; same lifecycle as productFillTypeSet.
local productTreatmentByFillType = {}
local hookInstalled = false

-- Treated-ground visual only (SPRAY_TYPE channel): adds no fertilisation, nitrogen or yield. Nothing
-- else clears it, so a daily sweep fades each painted farmland about a month after its last treatment.
-- Resolved at mission load from the FERTILISER spray type's ground value (nil disables the paint).
local treatmentSprayType = nil
-- farmlandId -> painted bounds + last-painted day (server-only); drives the fade sweep, reset at mission load/teardown.
local treatedGround = {}

---Returns true when the given fillType index is one of the RCR sprayer products.
-- @param integer fillTypeIndex fillType index (may be nil)
-- @return boolean isProduct true for RCR_FUNGICIDE / RCR_NEMATICIDE
function RealisticCropRotationSprayerProducts.isProductFillType(fillTypeIndex)
    return fillTypeIndex ~= nil and productFillTypeSet[fillTypeIndex] == true
end

---Curative treatment family of an RCR product fillType, or nil for a non-RCR fillType.
-- @param integer fillTypeIndex fillType index (may be nil)
-- @return string|nil treatment "FUNGICIDE" | "NEMATICIDE" | nil
function RealisticCropRotationSprayerProducts.getProductTreatment(fillTypeIndex)
    return fillTypeIndex ~= nil and productTreatmentByFillType[fillTypeIndex] or nil
end

---Registers the RCR sprayTypes at the HERBICIDE flow rate, until per-product dosing is decided.
local function ensureSprayTypes()
    if g_fillTypeManager == nil or g_sprayTypeManager == nil then
        Logging.warning("[RealisticCropRotation] fillType/sprayType managers unavailable; RCR sprayer products were not wired")
        return
    end

    local herbicideSprayType = g_sprayTypeManager:getSprayTypeByName("HERBICIDE")
    local litersPerSecond = herbicideSprayType ~= nil and herbicideSprayType.litersPerSecond or 0.0081
    local sprayGroundType = herbicideSprayType ~= nil and herbicideSprayType.sprayGroundType or nil

    -- Ground-visual value: reuse the base FERTILISER spray type's ground value so the treated strip
    -- shows the game's fertiliser ground rendering. Only this visual channel (SPRAY_TYPE) is ever
    -- written, never SPRAY_LEVEL, so it carries no fertilisation / nitrogen / yield.
    local fertiliserSprayType = g_sprayTypeManager:getSprayTypeByName("FERTILIZER")
    treatmentSprayType = fertiliserSprayType ~= nil and fertiliserSprayType.sprayGroundType or nil
    if treatmentSprayType == nil then
        Logging.warning("[RealisticCropRotation] FERTILIZER sprayGroundType unavailable; the treated-ground visual is disabled")
    end

    for _, name in ipairs(RealisticCropRotationSprayerProducts.PRODUCT_NAMES) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(name)
        if fillTypeIndex == nil then
            Logging.warning("[RealisticCropRotation] Missing fillType '%s'; its sprayType was not registered", name)
        else
            productFillTypeSet[fillTypeIndex] = true
            productTreatmentByFillType[fillTypeIndex] = RealisticCropRotationSprayerProducts.PRODUCT_TREATMENTS[name]

            if g_sprayTypeManager:getSprayTypeByFillTypeIndex(fillTypeIndex) == nil then
                -- HERBICIDE is the only engine spray type matching a crop-protection
                -- liquid (SprayTypeManager only accepts FERTILIZER/HERBICIDE/LIME).
                -- Its ground-side behavior is neutralized by the hook below.
                g_sprayTypeManager:addSprayType(name, litersPerSecond, "HERBICIDE", sprayGroundType, false)
            end
        end
    end

end

---Adds the farmland under (x, z) to `out` once (dedup via `seen`); ignores invalid/unowned ids.
-- @param number x, z world position; @param table seen dedup set; @param table out farmland id list
local function collectFarmland(x, z, seen, out)
    if type(x) ~= "number" or type(z) ~= "number" then return end
    if g_farmlandManager == nil or type(g_farmlandManager.getFarmlandIdAtWorldPosition) ~= "function" then return end
    local fid = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    if fid ~= nil and fid > 0 and not seen[fid] then
        seen[fid] = true
        out[#out + 1] = fid
    end
end

---Server: paints curative+preventive protection under the sprayed strip. A protected cell is excluded
---from all future disease destruction there, curing and shielding it with the same per-cell write; the
---disease-overlay marks for that area are cleared immediately so the overlay recedes strip by strip.
-- @param table workArea work area whose start/width/height nodes give the sprayed strip
-- @param integer fillType RCR product fillType
local function paintDiseaseProtection(workArea, fillType)
    if workArea == nil or workArea.start == nil or workArea.width == nil or workArea.height == nil then
        return
    end
    if getWorldTranslation == nil then return end

    local treatmentType = RealisticCropRotationSprayerProducts.getProductTreatment(fillType)
    if treatmentType == nil then return end

    local grid = RealisticCropRotation ~= nil and RealisticCropRotation.grid or nil
    if grid == nil or type(grid.paintProtection) ~= "function" then return end

    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    if sx == nil or wx == nil or hx == nil then return end

    grid:paintProtection(treatmentType, sx, sz, wx, wz, hx, hz)
end

---AI job-completion rule: prohibits re-working an already-protected cell.
-- @param table self sprayer vehicle; @param function superFunc native implementation; @param integer fillType
local function setSprayerAITerrainDetailProhibitedRange(self, superFunc, fillType)
    if not RealisticCropRotationSprayerProducts.isProductFillType(fillType) then
        return superFunc(self, fillType)
    end

    if not self:getUseSprayerAIRequirements() then return end
    if self.addAITerrainDetailProhibitedRange == nil then return end

    self:clearAITerrainDetailRequiredRange()
    self:clearAITerrainDetailProhibitedRange()
    self:clearAIFruitRequirements()
    self:clearAIFruitProhibitions()

    local treatmentType = RealisticCropRotationSprayerProducts.getProductTreatment(fillType)
    local grid = RealisticCropRotation ~= nil and RealisticCropRotation.grid or nil
    if treatmentType == nil or grid == nil then return end

    local protectionMapId = treatmentType == "FUNGICIDE" and grid.fungicideProtectionMapId
        or treatmentType == "NEMATICIDE" and grid.nematicideProtectionMapId or nil
    if protectionMapId == nil or RealisticCropRotationDiseaseGrid == nil then return end

    self:addAIGroundTypeRequirements(Sprayer.AI_REQUIRED_GROUND_TYPES)

    -- Already-protected (value 1) cells are excluded from future AI passes over this fillType.
    self:addAIFruitProhibitions(0, 1, 1, protectionMapId, 0, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS)

    -- Don't work a field whose crop is already past its harvest-ready growth state.
    if g_fruitTypeManager ~= nil then
        for _, fruitType in pairs(g_fruitTypeManager:getFruitTypes()) do
            if fruitType.terrainDataPlaneId ~= nil and string.lower(fruitType.name) ~= "grass" then
                if fruitType.minHarvestingGrowthState ~= nil and fruitType.maxHarvestingGrowthState ~= nil then
                    self:addAIFruitProhibitions(fruitType.index, fruitType.minHarvestingGrowthState, fruitType.maxHarvestingGrowthState)
                end
            end
        end
    end
end

---Server: merges the just-painted strip into the per-farmland treated-ground record (accumulated
---bounds + current day) so the daily fade sweep knows what to erase and when.
local function recordTreatedGround(sx, sz, wx, wz, hx, hz)
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local day = env ~= nil and (env.currentMonotonicDay or env.currentDay) or nil
    if day == nil then return end

    local fourthX, fourthZ = wx + hx - sx, wz + hz - sz
    local centerX, centerZ = (wx + hx) * 0.5, (wz + hz) * 0.5
    local minX = math.min(sx, wx, hx, fourthX)
    local maxX = math.max(sx, wx, hx, fourthX)
    local minZ = math.min(sz, wz, hz, fourthZ)
    local maxZ = math.max(sz, wz, hz, fourthZ)

    local seen, farmlands = {}, {}
    collectFarmland(sx, sz, seen, farmlands)
    collectFarmland(wx, wz, seen, farmlands)
    collectFarmland(hx, hz, seen, farmlands)
    collectFarmland(fourthX, fourthZ, seen, farmlands)
    collectFarmland(centerX, centerZ, seen, farmlands)

    for _, fid in ipairs(farmlands) do
        local rec = treatedGround[fid]
        if rec == nil then
            treatedGround[fid] = { day = day, minX = minX, minZ = minZ, maxX = maxX, maxZ = maxZ }
        else
            rec.day = day
            if minX < rec.minX then rec.minX = minX end
            if minZ < rec.minZ then rec.minZ = minZ end
            if maxX > rec.maxX then rec.maxX = maxX end
            if maxZ > rec.maxZ then rec.maxZ = maxZ end
        end
    end
end

---Paints the ephemeral "treated" ground look over the sprayed strip (SPRAY_TYPE only, never SPRAY_LEVEL,
---so no fertilisation/nitrogen/yield), off roads/yards/water. Server-only write; the engine replicates
---the density change to clients, so the fade sweep can never diverge between machines.
-- @param table self sprayer vehicle; @param table workArea work area giving the sprayed strip corners
local function paintTreatmentGround(self, workArea)
    if self == nil or not self.isServer then return end
    if treatmentSprayType == nil then return end
    if DensityMapModifier == nil or DensityMapFilter == nil or g_terrainNode == nil then return end
    if getWorldTranslation == nil or DensityCoordType == nil or DensityValueCompareType == nil then return end
    if workArea == nil or workArea.start == nil or workArea.width == nil or workArea.height == nil then return end

    local mission = g_currentMission
    if mission == nil or mission.fieldGroundSystem == nil or FieldDensityMap == nil then return end

    local sprayTypeMapId, sprayFirstChannel, sprayNumChannels =
        mission.fieldGroundSystem:getDensityMapData(FieldDensityMap.SPRAY_TYPE)
    if sprayTypeMapId == nil then return end
    local groundTypeMapId, groundFirstChannel, groundNumChannels =
        mission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if groundTypeMapId == nil then return end

    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    if sx == nil or wx == nil or hx == nil then return end

    local modifier = DensityMapModifier.new(sprayTypeMapId, sprayFirstChannel, sprayNumChannels, g_terrainNode)
    modifier:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)

    -- Only paint where there is field ground (groundType > 0): never roads, yards or standing water.
    local fieldFilter = DensityMapFilter.new(groundTypeMapId, groundFirstChannel, groundNumChannels)
    fieldFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)

    -- SPRAY_TYPE only (the fertiliser ground look); SPRAY_LEVEL is never touched, so no fertilisation.
    modifier:executeSet(treatmentSprayType, fieldFilter)

    -- Track the painted area (server) so the daily sweep can fade it ~a month later.
    recordTreatedGround(sx, sz, wx, wz, hx, hz)
end

---Overwrites Sprayer.processSprayerArea once per game session.
-- Non-RCR fillTypes go through the untouched native path.
local function installSprayerHook()
    if hookInstalled then
        return
    end

    if Sprayer == nil or Sprayer.processSprayerArea == nil then
        Logging.warning("[RealisticCropRotation] Sprayer specialization unavailable; RCR sprayer hook was not installed")
        return
    end

    Sprayer.processSprayerArea = Utils.overwrittenFunction(Sprayer.processSprayerArea, function(self, superFunc, workArea, dt)
        local spec = self.spec_sprayer
        local params = spec ~= nil and spec.workAreaParameters or nil
        local sprayFillType = params ~= nil and params.sprayFillType or FillType.UNKNOWN

        if not RealisticCropRotationSprayerProducts.isProductFillType(sprayFillType) then
            return superFunc(self, workArea, dt)
        end

        -- RCR product: replicate the native activation guards, but never call
        -- FSDensityMapUtil.updateSprayArea (no native herbicide ground treatment).
        if params.sprayFillLevel <= 0 then
            return 0, 0
        end

        if not self.isServer and self.currentUpdateDistance > Sprayer.CLIENT_DM_UPDATE_RADIUS then
            return 0, 0
        end

        params.isActive = true
        params.lastSprayTime = g_time

        -- Treated-ground visual only (no agronomy effect); faded out ~a month later by the server sweep.
        paintTreatmentGround(self, workArea)

        if self:getLastSpeed() > 1 then
            spec.isWorking = true
        end

        -- Curative + preventive disease protection: server-only, since it gates the server-authoritative
        -- daily destroy pass. Runs every qualifying tick over just the sprayed strip; never touches the real crop.
        if self.isServer then
            paintDiseaseProtection(workArea, sprayFillType)
        end

        return 0, 0
    end)

    -- AI job completion: without this, the HERBICIDE-family sprayType has no weed-replacement data for
    -- a custom fillType, so no prohibitions are ever set and the AI never knows the field is done.
    if Sprayer.setSprayerAITerrainDetailProhibitedRange ~= nil then
        Sprayer.setSprayerAITerrainDetailProhibitedRange = Utils.overwrittenFunction(
            Sprayer.setSprayerAITerrainDetailProhibitedRange, setSprayerAITerrainDetailProhibitedRange)
    end

    hookInstalled = true
end

---Server daily sweep: erases the treated-ground visual on farmlands whose last treatment aged past the
---fade window (~one season period), clearing SPRAY_TYPE only over that farmland's own bounds.
function RealisticCropRotationSprayerProducts.fadeTreatedGround()
    if next(treatedGround) == nil then return end
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    if DensityMapModifier == nil or DensityMapFilter == nil or g_terrainNode == nil
        or DensityCoordType == nil or DensityValueCompareType == nil then return end

    local mission = g_currentMission
    if mission.fieldGroundSystem == nil or FieldDensityMap == nil then return end
    if g_farmlandManager == nil or type(g_farmlandManager.getLocalMap) ~= "function"
        or getBitVectorMapNumChannels == nil then return end

    local env = mission.environment
    local day = env ~= nil and (env.currentMonotonicDay or env.currentDay) or nil
    if day == nil then return end
    -- One season period (plannedDaysPerPeriod), falling back to 3 days when unavailable.
    local daysPerPeriod = env ~= nil and tonumber(env.plannedDaysPerPeriod) or nil
    local fadeDays = (daysPerPeriod ~= nil and daysPerPeriod > 0) and daysPerPeriod or 3

    local sprayTypeMapId, sprayFirstChannel, sprayNumChannels =
        mission.fieldGroundSystem:getDensityMapData(FieldDensityMap.SPRAY_TYPE)
    if sprayTypeMapId == nil then return end
    local farmlandLocalMap = g_farmlandManager:getLocalMap()
    if farmlandLocalMap == nil then return end
    local farmlandChannels = getBitVectorMapNumChannels(farmlandLocalMap)

    for fid, rec in pairs(treatedGround) do
        if day - (rec.day or day) >= fadeDays then
            local modifier = DensityMapModifier.new(sprayTypeMapId, sprayFirstChannel, sprayNumChannels, g_terrainNode)
            modifier:setParallelogramWorldCoords(rec.minX, rec.minZ, rec.maxX, rec.minZ, rec.minX, rec.maxZ, DensityCoordType.POINT_POINT_POINT)
            local farmlandFilter = DensityMapFilter.new(farmlandLocalMap, 0, farmlandChannels)
            farmlandFilter:setValueCompareParams(DensityValueCompareType.EQUAL, fid)
            modifier:executeSet(0, farmlandFilter)
            treatedGround[fid] = nil
        end
    end
end

---Persists the treated-ground fade tracker so it keeps working across save/load. The SPRAY_TYPE map
---itself is saved by the engine; this only saves the per-farmland age/bounds the sweep needs.
-- @param string savegamePath savegame folder path (trailing slash)
function RealisticCropRotationSprayerProducts.saveTreatedGround(savegamePath)
    if savegamePath == nil or savegamePath == "" or createXMLFile == nil then return end
    local xmlFile = createXMLFile("rcrTreatedGround",
        savegamePath .. "realisticCropRotationTreatedGround.xml", "realisticCropRotationTreatedGround")
    if xmlFile == nil or xmlFile == 0 then return end

    local i = 0
    for fid, rec in pairs(treatedGround) do
        local key = string.format("realisticCropRotationTreatedGround.farmland(%d)", i)
        setXMLInt(xmlFile, key .. "#id", fid)
        setXMLInt(xmlFile, key .. "#day", math.floor(tonumber(rec.day) or 0))
        setXMLFloat(xmlFile, key .. "#minX", rec.minX)
        setXMLFloat(xmlFile, key .. "#minZ", rec.minZ)
        setXMLFloat(xmlFile, key .. "#maxX", rec.maxX)
        setXMLFloat(xmlFile, key .. "#maxZ", rec.maxZ)
        i = i + 1
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

---Restores the treated-ground fade tracker from the savegame folder (server). Called after
---onMissionLoaded() has reset it, so a missing file simply leaves it empty.
-- @param string savegamePath savegame folder path (trailing slash)
function RealisticCropRotationSprayerProducts.loadTreatedGround(savegamePath)
    treatedGround = {}
    if savegamePath == nil or savegamePath == "" then return end
    local filePath = savegamePath .. "realisticCropRotationTreatedGround.xml"
    if fileExists == nil or not fileExists(filePath) then return end
    local xmlFile = loadXMLFile("rcrTreatedGround", filePath)
    if xmlFile == nil or xmlFile == 0 then return end

    local i = 0
    while true do
        local key = string.format("realisticCropRotationTreatedGround.farmland(%d)", i)
        if not hasXMLProperty(xmlFile, key) then break end
        local id = getXMLInt(xmlFile, key .. "#id")
        local minX = getXMLFloat(xmlFile, key .. "#minX")
        local minZ = getXMLFloat(xmlFile, key .. "#minZ")
        local maxX = getXMLFloat(xmlFile, key .. "#maxX")
        local maxZ = getXMLFloat(xmlFile, key .. "#maxZ")
        if id ~= nil and minX ~= nil and minZ ~= nil and maxX ~= nil and maxZ ~= nil then
            treatedGround[id] = {
                day = getXMLInt(xmlFile, key .. "#day") or 0,
                minX = minX, minZ = minZ, maxX = maxX, maxZ = maxZ,
            }
        end
        i = i + 1
    end

    delete(xmlFile)
end

---Mission-load entry point; called from main.lua after the GUI assets load.
function RealisticCropRotationSprayerProducts.onMissionLoaded()
    productFillTypeSet = {}
    productTreatmentByFillType = {}
    treatedGround = {}
    ensureSprayTypes()
    -- Safety net only: the hook is normally installed at source time below
    -- (before TypeManager:finalizeTypes snapshots Sprayer.processSprayerArea).
    installSprayerHook()
end

---Mission teardown: forget the mission-scoped fillType indices and treated-ground marks.
function RealisticCropRotationSprayerProducts.onMissionDeleted()
    productFillTypeSet = {}
    productTreatmentByFillType = {}
    treatedGround = {}
end

-- Source-time installation: mod scripts are sourced before TypeManager:finalizeTypes() runs, the
-- only moment the overwritten processSprayerArea is guaranteed to reach every sprayer vehicleType.
-- Until onMissionLoaded() populates productFillTypeSet, the wrapper is a pure passthrough.
installSprayerHook()
