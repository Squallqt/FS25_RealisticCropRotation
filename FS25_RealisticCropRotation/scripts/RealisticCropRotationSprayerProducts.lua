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

-- Below this ground speed (km/h) the tool counts as stopped: no consumption, jet fades.
local MIN_WORK_SPEED = 0.5

local PF_MOD_NAME = "FS25_precisionFarming"
local PF_PATCH_REFRESH_INTERVAL = 1000
local pfExtendedSprayer = nil
local pfExtendedSprayerEffects = nil
local pfPatchedFunctionSet = {}
local pfPatchRecords = {}
local pfPatchTimer = 0
local pfUpdateRegistered = false

-- Ground-paint value only (SPRAY_TYPE channel); the engine clears it on the crop's next growth-state transition.
local treatmentSprayType = nil

---Returns the loaded Precision Farming script environment, if available.
local function getPrecisionFarmingEnvironment()
    local globalEnvironment = _G
    local globalMetaTable = getmetatable(_G)
    if globalMetaTable ~= nil and type(globalMetaTable.__index) == "table" then
        globalEnvironment = globalMetaTable.__index
    end

    if g_thGlobalEnv ~= nil then
        local environment = g_thGlobalEnv[PF_MOD_NAME]
        if environment ~= nil then
            return environment._G or environment
        end
    end

    if globalEnvironment ~= nil then
        local environment = globalEnvironment[PF_MOD_NAME]
        if environment ~= nil then
            return environment._G or environment
        end
    end

    if g_modManager ~= nil then
        local modData = g_modManager.getModByName ~= nil and g_modManager:getModByName(PF_MOD_NAME) or nil
        if modData == nil and g_modManager.nameToMod ~= nil then
            modData = g_modManager.nameToMod[PF_MOD_NAME]
                or g_modManager.nameToMod[string.upper(PF_MOD_NAME)]
                or g_modManager.nameToMod[string.lower(PF_MOD_NAME)]
        end
        if modData ~= nil then
            return modData.environment or modData._G
        end
    end

    return nil
end

---Returns true when the active PF sprayer source contains an RCR product.
local function isPrecisionFarmingRcrProductActive(vehicle)
    if vehicle == nil or pfExtendedSprayer == nil or pfExtendedSprayer.getFillTypeSourceVehicle == nil then
        return false
    end

    local sourceVehicle, fillUnitIndex = pfExtendedSprayer.getFillTypeSourceVehicle(vehicle)
    if sourceVehicle == nil or fillUnitIndex == nil then
        return false
    end

    local fillType = sourceVehicle:getFillUnitFillType(fillUnitIndex)
    if fillType == FillType.UNKNOWN then
        fillType = sourceVehicle:getFillUnitLastValidFillType(fillUnitIndex)
    end

    return RealisticCropRotationSprayerProducts.isProductFillType(fillType)
end

---Runs PF's base-effect state update while exposing the vanilla effects for RCR products.
local function runPrecisionFarmingVanillaEffectState(originalFunction, vehicle, force, ...)
    local isRcrProduct = isPrecisionFarmingRcrProductActive(vehicle)
    local effectsSpec = pfExtendedSprayerEffects ~= nil
        and vehicle[pfExtendedSprayerEffects.SPEC_TABLE_NAME] or nil

    if effectsSpec ~= nil then
        effectsSpec.rcrUseVanillaSprayerEffects = isRcrProduct
    end

    if not isRcrProduct or effectsSpec == nil or effectsSpec.hasCustomEffects ~= true then
        return originalFunction(vehicle, force, ...)
    end

    effectsSpec.hasCustomEffects = false
    originalFunction(vehicle, force, ...)
    effectsSpec.hasCustomEffects = true
end

local function createPatchedUpdateSprayerEffectState(originalFunction)
    return function(vehicle, force, ...)
        return runPrecisionFarmingVanillaEffectState(originalFunction, vehicle, force, ...)
    end
end

local function useVanillaSprayerEffects(vehicle)
    local effectsSpec = pfExtendedSprayerEffects ~= nil
        and vehicle[pfExtendedSprayerEffects.SPEC_TABLE_NAME] or nil
    return effectsSpec ~= nil and effectsSpec.rcrUseVanillaSprayerEffects == true
end

local function createPatchedNozzleEffectState(originalFunction)
    return function(vehicle, superFunc, effectData, dt, isTurnedOn, lastSpeed, ...)
        if useVanillaSprayerEffects(vehicle) then
            return false, 1
        end
        return originalFunction(vehicle, superFunc, effectData, dt, isTurnedOn, lastSpeed, ...)
    end
end

local function createPatchedCopiedNozzleEffectState(originalFunction)
    return function(vehicle, effectData, dt, isTurnedOn, lastSpeed, ...)
        if useVanillaSprayerEffects(vehicle) then
            return false, 1
        end
        return originalFunction(vehicle, effectData, dt, isTurnedOn, lastSpeed, ...)
    end
end

---Patches one PF function holder without stacking an RCR wrapper on an existing RCR wrapper.
local function patchPrecisionFarmingTarget(functionName, target, createPatchedFunction)
    if target == nil or target[functionName] == nil then
        return
    end

    local originalFunction = target[functionName]
    if pfPatchedFunctionSet[originalFunction] == true then
        return
    end

    local patchedFunction = createPatchedFunction(originalFunction)
    local functionRecords = pfPatchRecords[functionName]
    if functionRecords == nil then
        functionRecords = {}
        pfPatchRecords[functionName] = functionRecords
    end

    functionRecords[target] = { original = originalFunction, patched = patchedFunction }
    pfPatchedFunctionSet[patchedFunction] = true
    target[functionName] = patchedFunction
end

---Patches PF's class plus the copies already stored on vehicle types and loaded vehicles.
local function patchPrecisionFarmingFunctionCopies(functionName, classFactory, copyFactory)
    patchPrecisionFarmingTarget(functionName, pfExtendedSprayer, classFactory)

    if g_vehicleTypeManager ~= nil and g_vehicleTypeManager.types ~= nil then
        for _, vehicleType in pairs(g_vehicleTypeManager.types) do
            if vehicleType.functions ~= nil
                and vehicleType.specializations ~= nil
                and SpecializationUtil ~= nil
                and SpecializationUtil.hasSpecialization(pfExtendedSprayer, vehicleType.specializations) then
                patchPrecisionFarmingTarget(functionName, vehicleType.functions, copyFactory or classFactory)
            end
        end
    end

    local vehicles = g_currentMission ~= nil and g_currentMission.vehicleSystem ~= nil
        and g_currentMission.vehicleSystem.vehicles or nil
    if vehicles ~= nil then
        for _, vehicle in pairs(vehicles) do
            if vehicle.specializations ~= nil
                and SpecializationUtil ~= nil
                and SpecializationUtil.hasSpecialization(pfExtendedSprayer, vehicle.specializations) then
                patchPrecisionFarmingTarget(functionName, vehicle, copyFactory or classFactory)
            end
        end
    end
end

---Installs or repairs the two PF visual hooks required to retain vanilla RCR spray effects.
local function patchPrecisionFarmingEffects()
    if pfExtendedSprayer == nil or pfExtendedSprayerEffects == nil then
        return
    end

    patchPrecisionFarmingTarget(
        "updateSprayerEffectState", pfExtendedSprayer, createPatchedUpdateSprayerEffectState)
    patchPrecisionFarmingFunctionCopies(
        "updateExtendedSprayerNozzleEffectState",
        createPatchedNozzleEffectState,
        createPatchedCopiedNozzleEffectState)
end

---Restores every PF function only when the currently installed function is still RCR's wrapper.
local function restorePrecisionFarmingEffects()
    for functionName, functionRecords in pairs(pfPatchRecords) do
        for target, record in pairs(functionRecords) do
            if target[functionName] == record.patched then
                target[functionName] = record.original
            end
        end
    end

    pfExtendedSprayer = nil
    pfExtendedSprayerEffects = nil
    pfPatchedFunctionSet = {}
    pfPatchRecords = {}
    pfPatchTimer = 0
end

---Client update: repairs PF function copies created after mission load.
function RealisticCropRotationSprayerProducts:update(dt)
    pfPatchTimer = pfPatchTimer + dt
    if pfPatchTimer >= PF_PATCH_REFRESH_INTERVAL then
        pfPatchTimer = pfPatchTimer - PF_PATCH_REFRESH_INTERVAL
        patchPrecisionFarmingEffects()
    end
end

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

        -- Guards mirror the vanilla activation path; RCR skips FSDensityMapUtil.updateSprayArea (no herbicide ground effect, no SPRAY_LEVEL).
        if params.sprayFillLevel <= 0 then
            return 0, 0
        end

        if not self.isServer and self.currentUpdateDistance > Sprayer.CLIENT_DM_UPDATE_RADIUS then
            return 0, 0
        end

        -- Stationary means no work. RCR has no changedArea to fall to zero, so speed is its work signal: leaving
        -- isActive/lastSprayTime unset makes onEndWorkAreaProcessing skip consumption and lets the jet fade out.
        if self:getLastSpeed() <= MIN_WORK_SPEED then
            return 0, 0
        end

        -- isActive drives the vanilla per-tick consumption in onEndWorkAreaProcessing; lastSprayTime drives the jet effect.
        params.isActive = true
        params.lastSprayTime = g_time
        spec.isWorking = true

        -- Treated-ground look plus curative/preventive protection; server only (protection gates the daily destroy pass).
        if self.isServer then
            paintTreatmentGround(self, workArea)
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

    local pfEnvironment = getPrecisionFarmingEnvironment()
    pfExtendedSprayer = pfEnvironment ~= nil and pfEnvironment.ExtendedSprayer or nil
    pfExtendedSprayerEffects = pfEnvironment ~= nil and pfEnvironment.ExtendedSprayerEffects or nil
    if g_currentMission ~= nil and g_currentMission:getIsClient()
        and pfExtendedSprayer ~= nil and pfExtendedSprayerEffects ~= nil then
        patchPrecisionFarmingEffects()
        g_currentMission:addUpdateable(RealisticCropRotationSprayerProducts)
        pfUpdateRegistered = true
    end
end

---Mission teardown: forget the mission-scoped fillType indices.
function RealisticCropRotationSprayerProducts.onMissionDeleted()
    if pfUpdateRegistered and g_currentMission ~= nil then
        g_currentMission:removeUpdateable(RealisticCropRotationSprayerProducts)
    end
    pfUpdateRegistered = false
    restorePrecisionFarmingEffects()
    productFillTypeSet = {}
    productTreatmentByFillType = {}
end

-- Source-time installation is the only moment the overwritten processSprayerArea reaches every sprayer vehicleType.
installSprayerHook()
