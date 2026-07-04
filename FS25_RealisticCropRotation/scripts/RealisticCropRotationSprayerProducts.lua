-- Copyright © 2026 Squallqt. All rights reserved.
-- Sprayer wiring for the RCR consumable products (RCR_FUNGICIDE / RCR_NEMATICIDE).
--
-- Two responsibilities, both required for the colored spray jet to appear:
--
--   1. Register an engine sprayType for each product. Without one,
--      Sprayer:onStartWorkAreaProcessing() stores sprayType = nil and
--      Sprayer:processSprayerArea() feeds that nil into the engine call
--      FSDensityMapUtil.updateSprayArea(); the work-area processing then never
--      reaches params.lastSprayTime, so Sprayer:getAreEffectsVisible() stays
--      false and updateSprayerEffects() never starts the jet effects at all.
--      The jet color itself comes from the per-fillType materials registered by
--      effects/sprayer/rcrSprayerMeshes_materialHolder.i3d (modDesc
--      <materialHolders> + the loadSprayerMaterialHolder() fallback in main.lua).
--
--   2. Short-circuit Sprayer.processSprayerArea for the RCR products so the
--      HERBICIDE-typed sprayType never reaches the native ground treatment
--      (no weed replacement, no native spray overlay), while still setting
--      params.isActive / params.lastSprayTime so consumption and jet effects
--      run exactly like a native product (plan: SPRAYER_PRODUCT_RUNTIME_DEBT.md).
--      Only visuals and consumption are handled here; the disease-treatment
--      application is a separate feature and can be added inside this same
--      hook later.
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

---Mission-load entry point; called from main.lua next to loadSprayerMaterialHolder().
function RealisticCropRotationSprayerProducts.onMissionLoaded()
    productFillTypeSet = {}
    productTreatmentByFillType = {}
    ensureSprayTypes()
    -- Safety net only: the hook is normally installed at source time below
    -- (before TypeManager:finalizeTypes snapshots Sprayer.processSprayerArea).
    installSprayerHook()
end

---Mission teardown: forget the mission-scoped fillType indices.
function RealisticCropRotationSprayerProducts.onMissionDeleted()
    productFillTypeSet = {}
    productTreatmentByFillType = {}
end

-- Source-time installation (see TIMING note in the header): mod scripts are
-- sourced before the mission's TypeManager:finalizeTypes() run, so this is the
-- only moment the overwritten Sprayer.processSprayerArea is guaranteed to be
-- copied into every sprayer vehicleType and captured by its work areas.
-- Until onMissionLoaded() fills productFillTypeSet the wrapper is a pure
-- passthrough, so native fillTypes are never affected.
installSprayerHook()
