-- Copyright © 2026 Squallqt. All rights reserved.
-- Sprayer wiring for the RCR consumable products (RCR_FUNGICIDE / RCR_NEMATICIDE): registers their sprayType, ground paint, and disease-protection/AI data.
RealisticCropRotationSprayerProducts = {}

RealisticCropRotationSprayerProducts.PRODUCT_NAMES = { "RCR_FUNGICIDE", "RCR_NEMATICIDE" }

-- Treatment family per product; selects which per-cell protection map a sprayed strip marks.
RealisticCropRotationSprayerProducts.PRODUCT_TREATMENTS = {
    RCR_FUNGICIDE = "FUNGICIDE",
    RCR_NEMATICIDE = "NEMATICIDE",
}

-- fillTypeIndex -> true; refreshed each mission load since fillType indices may shift between savegames.
local productFillTypeSet = {}
-- fillTypeIndex -> "FUNGICIDE" | "NEMATICIDE"; same lifecycle as productFillTypeSet.
local productTreatmentByFillType = {}
local hookInstalled = false

-- Ground-paint value only (SPRAY_TYPE channel); the engine clears it on the crop's next growth-state transition.
local treatmentSprayType = nil

---Queues the client-side sprayer materials before the engine loads mod material holders.
function RealisticCropRotationSprayerProducts.registerMaterialHolder(modDirectory)
    if g_dedicatedServerInfo == nil and g_materialManager ~= nil then
        g_materialManager:addModMaterialHolder(
            modDirectory .. "effects/rcrSprayer_materialHolder.i3d")
    end
end

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

    -- Reuses FERTILIZER's ground value for the paint channel (SPRAY_TYPE only, never SPRAY_LEVEL, so no fertilisation/nitrogen/yield).
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
                -- HERBICIDE is the only engine sprayType accepting a custom fillType; its ground effect is neutralized below.
                g_sprayTypeManager:addSprayType(name, litersPerSecond, "HERBICIDE", sprayGroundType, false)
            end
        end
    end

end

---Server: paints curative/preventive disease protection under the sprayed strip and clears matching overlay marks.
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
-- @param table self Sprayer vehicle
-- @param function superFunc Original function
-- @param integer fillType
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

---Paints the sprayed strip's ground look (SPRAY_TYPE only, no fertilisation/nitrogen/yield effect).
-- @param table self Sprayer vehicle
-- @param table workArea Work area giving the sprayed strip corners
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
end

---Overwrites Sprayer.processSprayerArea once per game session; non-RCR fillTypes fall through unchanged.
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

        -- Replicates the original activation guards but skips FSDensityMapUtil.updateSprayArea (no herbicide ground effect here).
        if params.sprayFillLevel <= 0 then
            return 0, 0
        end

        if not self.isServer and self.currentUpdateDistance > Sprayer.CLIENT_DM_UPDATE_RADIUS then
            return 0, 0
        end

        params.isActive = true
        params.lastSprayTime = g_time

        -- Treated-ground visual only (no agronomy effect); cleared by the engine on the next growth-state bump.
        paintTreatmentGround(self, workArea)

        if self:getLastSpeed() > 1 then
            spec.isWorking = true
        end

        -- Curative + preventive disease protection: server-only, since it gates the server-authoritative daily destroy pass.
        if self.isServer then
            paintDiseaseProtection(workArea, sprayFillType)
        end

        return 0, 0
    end)

    -- AI job completion: without this, the HERBICIDE sprayType has no weed-replacement data for a custom fillType, so the AI never sees the field as done.
    if Sprayer.setSprayerAITerrainDetailProhibitedRange ~= nil then
        Sprayer.setSprayerAITerrainDetailProhibitedRange = Utils.overwrittenFunction(
            Sprayer.setSprayerAITerrainDetailProhibitedRange, setSprayerAITerrainDetailProhibitedRange)
    end

    hookInstalled = true
end

---Mission-load entry point; called from main.lua after the GUI assets load.
function RealisticCropRotationSprayerProducts.onMissionLoaded()
    productFillTypeSet = {}
    productTreatmentByFillType = {}
    ensureSprayTypes()
    -- Safety net only: the hook is normally installed at source time, before TypeManager:finalizeTypes snapshots it.
    installSprayerHook()
end

---Mission teardown: forget the mission-scoped fillType indices.
function RealisticCropRotationSprayerProducts.onMissionDeleted()
    productFillTypeSet = {}
    productTreatmentByFillType = {}
end

-- Source-time installation is the only moment the overwritten processSprayerArea reaches every sprayer vehicleType.
installSprayerHook()
