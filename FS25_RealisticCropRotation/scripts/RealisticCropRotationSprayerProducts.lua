-- Copyright © 2026 Squallqt. All rights reserved.
-- Sprayer wiring for the RCR consumable products (RCR_FUNGICIDE / RCR_NEMATICIDE).
--
-- JET COLOUR: abandoned. The jet is left as the native white water mist. A per-fillType
-- "sprayer" material holder was tried and did not recolour the jet in-game (the effect does
-- not visibly adopt the swapped material for this shader), so it was removed. The mod's
-- treatment feedback lives on the ground/map layer instead, not the nozzle.
--
-- Two responsibilities here:
--
--   1. Register an engine sprayType for each product. Without one,
--      Sprayer:onStartWorkAreaProcessing() stores sprayType = nil and
--      Sprayer:processSprayerArea() feeds that nil into the engine call
--      FSDensityMapUtil.updateSprayArea(); the work-area processing then never
--      reaches params.lastSprayTime, so Sprayer:getAreEffectsVisible() stays
--      false and updateSprayerEffects() never starts the spray effect at all.
--      Registering the sprayType also gives the product a correct consumption
--      rate instead of the 1 L/s fallback.
--
--   2. Short-circuit Sprayer.processSprayerArea for the RCR products so the
--      HERBICIDE-typed sprayType never reaches the native ground treatment
--      (no weed replacement, no native spray overlay), while still setting
--      params.isActive / params.lastSprayTime so consumption and the spray
--      effect run like a native product. The curative disease treatment is
--      applied inside this same hook (server-only, see applyTreatment).
--
--      TIMING (GIANTS truth, dataS/scripts): the overwrite MUST be installed
--      when this file is sourced, NOT at mission load. TypeManager:finalizeTypes()
--      copies Sprayer.processSprayerArea by value into every vehicleType's
--      functions table during mission loading (SpecializationUtil.registerFunction,
--      SpecializationUtil.lua line 93), and each work area then captures
--      workArea.processingFunction = self[functionName] when the vehicle loads
--      (WorkArea.lua line 404). An overwrite performed at
--      Mission00.loadMission00Finished is therefore seen by nobody.
RealisticCropRotationSprayerProducts = {}

RealisticCropRotationSprayerProducts.PRODUCT_NAMES = { "RCR_FUNGICIDE", "RCR_NEMATICIDE" }

-- Curative treatment family applied by each product on the disease state
-- (RealisticCropRotationDisease:treatField reads config.diseaseTreatments[group]).
RealisticCropRotationSprayerProducts.PRODUCT_TREATMENTS = {
    RCR_FUNGICIDE = "FUNGICIDE",
    RCR_NEMATICIDE = "NEMATICIDE",
}

-- Cooldown window (ms of g_time) per (vehicle, farmland, product): the curative treatment is applied
-- at most once per window, NOT every work-area tick. Kept short so a slow pass still re-treats.
RealisticCropRotationSprayerProducts.TREATMENT_COOLDOWN_MS = 3000

-- Corner-sampling interval (ms) per work area: farmland resolution for the treatment runs at most
-- 4x/s per section instead of every tick. At working speed this is well under one metre of travel,
-- far finer than any farmland, and an order of magnitude inside TREATMENT_COOLDOWN_MS.
RealisticCropRotationSprayerProducts.TREATMENT_SAMPLE_INTERVAL_MS = 250

-- fillTypeIndex -> true; refreshed at every mission load because fillType
-- indices may shift between savegames with different mod sets.
local productFillTypeSet = {}
-- fillTypeIndex -> "FUNGICIDE" | "NEMATICIDE"; same lifecycle as productFillTypeSet.
local productTreatmentByFillType = {}
local hookInstalled = false

-- Treated-ground visual: written into the field WATER_LEVEL detail channel (a damp look). It is NOT a
-- product texture and deposits nothing agronomic -- no fertiliser, no lime, no weed kill; nothing in
-- the game reads or consumes it. Because nothing consumes it, it never clears on its own, so we make
-- it EPHEMERAL ourselves: each painted farmland is tracked (server) and a daily sweep erases it about
-- a month (one season period) after the last treatment.
local WATER_VISUAL_VALUE = 1
-- farmlandId -> { day = <monotonic day last painted>, minX, minZ, maxX, maxZ = accumulated painted
-- world bounds }. Server-only; drives the fade sweep. Reset at mission load/teardown.
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

---Registers the RCR sprayTypes, copying the native HERBICIDE flow profile.
-- litersPerSecond 0.0081 is the native HERBICIDE rate (maps_sprayTypes.xml);
-- it is kept identical for both products until per-product dosing is decided
-- (SPRAYER_PRODUCT_RUNTIME_DEBT.md, "Stratégie RCR recommandée", point 3).
local function ensureSprayTypes()
    if g_fillTypeManager == nil or g_sprayTypeManager == nil then
        Logging.warning("[RealisticCropRotation] fillType/sprayType managers unavailable; RCR sprayer products were not wired")
        return
    end

    local herbicideSprayType = g_sprayTypeManager:getSprayTypeByName("HERBICIDE")
    local litersPerSecond = herbicideSprayType ~= nil and herbicideSprayType.litersPerSecond or 0.0081
    local sprayGroundType = herbicideSprayType ~= nil and herbicideSprayType.sprayGroundType or nil

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
                Logging.info("[RealisticCropRotation] Registered sprayType %s (litersPerSecond=%.4f)", name, litersPerSecond)
            end
        end
    end

end

---Adds the farmland under (x, z) to `out` once (dedup via `seen`). A farmland id <= 0 (no valid
---parcel, unowned/not-buyable sentinels) is ignored; treatField re-checks the state anyway.
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

---Server-only curative treatment for an RCR product spray tick. Samples a FIXED, small set of points
---of the work area (the 3 corner nodes, the 4th corner and the centre -- O(1), never a dense scan),
---resolves each to a farmland, dedups them, and applies the product's treatment once per farmland per
---cooldown window. The cooldown table lives on the sprayer spec (per-vehicle, GC'd with the vehicle;
---stale keys are pruned opportunistically), so nothing global grows. Returns whether any group was cured.
-- @param table self sprayer vehicle; @param table spec self.spec_sprayer; @param integer fillType RCR product
-- @param table workArea work area whose start/width/height nodes give the sprayed strip
-- @return boolean treatedAny true when at least one infection group was cured (caller broadcasts)
local function applyTreatment(self, spec, fillType, workArea)
    if workArea == nil or workArea.start == nil or workArea.width == nil or workArea.height == nil then
        return false
    end
    if getWorldTranslation == nil then return false end

    -- Per-work-area sampling gate: corner reads + farmland resolution run at most once per
    -- TREATMENT_SAMPLE_INTERVAL_MS per section, not every tick. Stored on the work area itself
    -- (per vehicle+section, GC'd with the vehicle), so wide multi-section sprayers stay covered.
    local now = g_time
    local nextSampleMs = workArea.rcrNextTreatmentSampleMs
    if nextSampleMs ~= nil and now < nextSampleMs then return false end
    workArea.rcrNextTreatmentSampleMs = now + RealisticCropRotationSprayerProducts.TREATMENT_SAMPLE_INTERVAL_MS

    local treatmentType = RealisticCropRotationSprayerProducts.getProductTreatment(fillType)
    if treatmentType == nil then return false end

    local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
    if disease == nil or type(disease.treatField) ~= "function" then return false end

    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    if sx == nil or wx == nil or hx == nil then return false end

    -- Parallelogram corners: start, width, height, the opposite corner (width+height-start), and centre.
    local fourthX, fourthZ = wx + hx - sx, wz + hz - sz
    local centerX, centerZ = (wx + hx) * 0.5, (wz + hz) * 0.5

    local seen, farmlands = {}, {}
    collectFarmland(sx, sz, seen, farmlands)
    collectFarmland(wx, wz, seen, farmlands)
    collectFarmland(hx, hz, seen, farmlands)
    collectFarmland(fourthX, fourthZ, seen, farmlands)
    collectFarmland(centerX, centerZ, seen, farmlands)
    if #farmlands == 0 then return false end

    local window = RealisticCropRotationSprayerProducts.TREATMENT_COOLDOWN_MS
    local cooldown = spec.rcrTreatmentCooldown
    if cooldown == nil then
        cooldown = {}
        spec.rcrTreatmentCooldown = cooldown
    end

    -- Opportunistic prune so a long-lived vehicle crossing many parcels keeps this table bounded.
    if now - (spec.rcrTreatmentCooldownPruned or 0) > window * 20 then
        spec.rcrTreatmentCooldownPruned = now
        for key, last in pairs(cooldown) do
            if now - last > window * 20 then cooldown[key] = nil end
        end
    end

    local treatedAny = false
    for _, farmlandId in ipairs(farmlands) do
        -- One key per (farmland, product); the spec table already scopes it to this vehicle.
        local key = fillType * 100003 + farmlandId
        local last = cooldown[key]
        if last == nil or now - last >= window then
            cooldown[key] = now -- gate future ticks even when this field carries no matching infection
            if disease:treatField(farmlandId, treatmentType) > 0 then
                treatedAny = true
            end
        end
    end

    return treatedAny
end

---Server: merges the just-painted strip into the per-farmland treated-ground record (accumulated
---bounds + the current day), so the daily fade sweep knows what to erase and when. Uses the strip's
---corner and centre points to find the farmland(s), like the curative sampling.
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

---Paints the ephemeral "treated" ground look over the sprayed strip: writes value 1 into the field
---WATER_LEVEL detail channel (a damp texture). This is NOT a product texture and deposits nothing
---agronomic -- no fertiliser, no lime, no weed kill; nothing reads it. A field-ground filter
---(groundType > 0) keeps the paint off roads, yards and standing water.
---SERVER-AUTHORITATIVE: the write happens on the server only and the engine synchronises the field
---density map to clients, exactly like the disease crop-destruction pass -- no client-side prediction,
---so the fade sweep can never diverge between machines. The painted area is recorded per farmland so
---the daily sweep can fade it later.
-- @param table self sprayer vehicle; @param table workArea work area giving the sprayed strip corners
local function paintTreatmentGround(self, workArea)
    if self == nil or not self.isServer then return end
    if DensityMapModifier == nil or DensityMapFilter == nil or g_terrainNode == nil then return end
    if getWorldTranslation == nil or DensityCoordType == nil or DensityValueCompareType == nil then return end
    if workArea == nil or workArea.start == nil or workArea.width == nil or workArea.height == nil then return end

    local mission = g_currentMission
    if mission == nil or mission.fieldGroundSystem == nil or FieldDensityMap == nil then return end

    local waterMapId, waterFirstChannel, waterNumChannels =
        mission.fieldGroundSystem:getDensityMapData(FieldDensityMap.WATER_LEVEL)
    if waterMapId == nil then return end
    local groundTypeMapId, groundFirstChannel, groundNumChannels =
        mission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if groundTypeMapId == nil then return end

    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    if sx == nil or wx == nil or hx == nil then return end

    local modifier = DensityMapModifier.new(waterMapId, waterFirstChannel, waterNumChannels, g_terrainNode)
    modifier:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)

    -- Only paint where there is field ground (groundType > 0): never roads, yards or standing water.
    local fieldFilter = DensityMapFilter.new(groundTypeMapId, groundFirstChannel, groundNumChannels)
    fieldFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)

    modifier:executeSet(WATER_VISUAL_VALUE, fieldFilter)

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

        -- Treated-ground visual: paint the WATER_LEVEL detail (a damp look, visual only, no agronomy)
        -- over the sprayed strip so the field visibly shows where the product was applied. Ephemeral --
        -- faded out ~a month later by the server sweep (fadeTreatedGround / onDayChanged).
        paintTreatmentGround(self, workArea)

        if self:getLastSpeed() > 1 then
            spec.isWorking = true
        end

        -- Curative disease treatment: SERVER ONLY (disease state is server-authoritative; clients get
        -- it through the existing rotation broadcast). Runs off the same tick that drives consumption
        -- and effects, but is gated by the per-(vehicle, farmland, product) cooldown inside applyTreatment
        -- and never scans the field densely (fixed sample points -> farmland -> treatField).
        if self.isServer and applyTreatment(self, spec, sprayFillType, workArea) then
            if RealisticCropRotation ~= nil and type(RealisticCropRotation.requestBroadcast) == "function" then
                RealisticCropRotation.requestBroadcast() -- coalesced/debounced; syncs the cured state
            end
        end

        return 0, 0
    end)

    hookInstalled = true
end

---Server daily sweep (called from onDayChanged): erases the water visual on farmlands whose last
---treatment has aged past the fade window (~one season period == about a month). Clears WATER_LEVEL
---back to 0 over each expired farmland's accumulated bounds, filtered to that farmland so only OUR
---marks go (never a neighbouring parcel or a rice paddy), then forgets it. One native pass per expired
---farmland, at most once per in-game day.
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
    -- One in-game month == one season period. plannedDaysPerPeriod is the configured days-per-period
    -- (same field the GUI reads); fall back to 3 (the base-game default) when it is unavailable.
    local daysPerPeriod = env ~= nil and tonumber(env.plannedDaysPerPeriod) or nil
    local fadeDays = (daysPerPeriod ~= nil and daysPerPeriod > 0) and daysPerPeriod or 3

    local waterMapId, waterFirstChannel, waterNumChannels =
        mission.fieldGroundSystem:getDensityMapData(FieldDensityMap.WATER_LEVEL)
    if waterMapId == nil then return end
    local farmlandLocalMap = g_farmlandManager:getLocalMap()
    if farmlandLocalMap == nil then return end
    local farmlandChannels = getBitVectorMapNumChannels(farmlandLocalMap)

    for fid, rec in pairs(treatedGround) do
        if day - (rec.day or day) >= fadeDays then
            local modifier = DensityMapModifier.new(waterMapId, waterFirstChannel, waterNumChannels, g_terrainNode)
            modifier:setParallelogramWorldCoords(rec.minX, rec.minZ, rec.maxX, rec.minZ, rec.minX, rec.maxZ, DensityCoordType.POINT_POINT_POINT)
            local farmlandFilter = DensityMapFilter.new(farmlandLocalMap, 0, farmlandChannels)
            farmlandFilter:setValueCompareParams(DensityValueCompareType.EQUAL, fid)
            modifier:executeSet(0, farmlandFilter)
            treatedGround[fid] = nil
        end
    end
end

---Persists the treated-ground fade tracker (server) so the ephemeral water visual keeps fading across
---save/load instead of leaking marks that never clear. The WATER_LEVEL density map itself is saved by
---the engine; this only saves the per-farmland age/bounds the sweep needs. Mirrors the disease save.
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

-- Source-time installation (see TIMING note in the header): mod scripts are
-- sourced before the mission's TypeManager:finalizeTypes() run, so this is the
-- only moment the overwritten Sprayer.processSprayerArea is guaranteed to be
-- copied into every sprayer vehicleType and captured by its work areas.
-- Until onMissionLoaded() fills productFillTypeSet the wrapper is a pure
-- passthrough, so native fillTypes are never affected.
installSprayerHook()
