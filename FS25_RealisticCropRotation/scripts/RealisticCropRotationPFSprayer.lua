-- Copyright © 2026 Squallqt. All rights reserved.
-- Precision Farming nozzle integration for the RCR fungicide and nematicide products.
RealisticCropRotationPFSprayer = {}

local MIN_WORK_SPEED = 0.5
local SPRAYER_MATERIAL_TYPE = "sprayer"
local SPRAYER_MATERIAL_INDEX = 1
local SPRAYER_SHADER_PARAMETERS = {
    "fadeProgress",
    "offsetUV",
    "isPulsating",
    "blinkMulti",
}

---Requires the native Sprayer and Precision Farming nozzle-effect specializations.
-- @param table specializations Vehicle-type specializations
-- @return boolean hasPrerequisites True when both required specializations are present
function RealisticCropRotationPFSprayer.prerequisitesPresent(specializations)
    local pfEffectsSpecialization = RealisticCropRotationPFSprayer.PF_EFFECTS_SPECIALIZATION
    return pfEffectsSpecialization ~= nil
        and SpecializationUtil.hasSpecialization(Sprayer, specializations)
        and SpecializationUtil.hasSpecialization(pfEffectsSpecialization, specializations)
end

---Registers the nozzle-state extension after the native Precision Farming chain.
-- @param table vehicleType Vehicle type receiving the specialization
function RealisticCropRotationPFSprayer.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(
        vehicleType,
        "updateExtendedSprayerNozzleEffectState",
        RealisticCropRotationPFSprayer.updateExtendedSprayerNozzleEffectState)
end

---Registers specialization lifecycle listeners.
-- @param table vehicleType Vehicle type receiving the specialization
function RealisticCropRotationPFSprayer.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", RealisticCropRotationPFSprayer)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", RealisticCropRotationPFSprayer)
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", RealisticCropRotationPFSprayer)
end

---Initializes the PF nozzle-material state and caches the native field-ground density-map channels.
-- @param table _ Savegame data, unused
function RealisticCropRotationPFSprayer:onLoad(_)
    local spec = self[RealisticCropRotationPFSprayer.SPEC_TABLE_NAME]
    spec.lastMaterialFillType = nil
    spec.lastEffectCount = nil
    spec.missingMaterialFillType = nil
    spec.isRcrMaterialActive = false
    spec.nativeMaterialHolders = {}

    local mission = g_currentMission
    if mission ~= nil and mission.fieldGroundSystem ~= nil
        and FieldDensityMap ~= nil and FieldDensityMap.GROUND_TYPE ~= nil then
        spec.groundTypeMapId, spec.groundTypeFirstChannel, spec.groundTypeNumChannels =
            mission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    end
end

---Deletes the unlinked nodes that keep native PF nozzle materials alive.
function RealisticCropRotationPFSprayer:onDelete()
    local spec = self[RealisticCropRotationPFSprayer.SPEC_TABLE_NAME]
    for _, holderNode in pairs(spec.nativeMaterialHolders or {}) do
        if entityExists(holderNode) then
            delete(holderNode)
        end
    end
    spec.nativeMaterialHolders = {}
end

local function setEffectMaterial(effectNode, materialId)
    local shaderParameters = {}
    for _, parameterName in ipairs(SPRAYER_SHADER_PARAMETERS) do
        if getHasShaderParameter(effectNode, parameterName) then
            shaderParameters[parameterName] = { getShaderParameter(effectNode, parameterName) }
        end
    end

    setMaterial(effectNode, materialId, 0)

    for parameterName, values in pairs(shaderParameters) do
        if getHasShaderParameter(effectNode, parameterName) then
            setShaderParameter(
                effectNode, parameterName,
                values[1], values[2], values[3], values[4], false)
        end
    end
end

---Keeps each native PF nozzle material referenced by an unlinked node while RCR is active.
-- @param table spec RCR PF specialization state
-- @param table sprayerEffects Native PF nozzle-effect entries
-- @return boolean success True when every nozzle material is retained
local function cacheNativeSprayerMaterials(spec, sprayerEffects)
    for _, effectData in ipairs(sprayerEffects) do
        local effectNode = effectData.effectNode
        if effectNode ~= nil and spec.nativeMaterialHolders[effectData] == nil then
            local holderNode = clone(effectNode, false, false, false)
            if holderNode == nil or holderNode == 0 then
                return false
            end

            setVisibility(holderNode, false)
            spec.nativeMaterialHolders[effectData] = holderNode
        end
    end

    return true
end

---Restores the retained native PF nozzle materials and deletes their holder nodes.
-- @param table spec RCR PF specialization state
-- @param table sprayerEffects Native PF nozzle-effect entries
local function restoreNativeSprayerMaterials(spec, sprayerEffects)
    for _, effectData in ipairs(sprayerEffects) do
        local effectNode = effectData.effectNode
        local holderNode = spec.nativeMaterialHolders[effectData]
        if holderNode ~= nil then
            if effectNode ~= nil and entityExists(holderNode) then
                setEffectMaterial(effectNode, getMaterial(holderNode, 0))
            end
            if entityExists(holderNode) then
                delete(holderNode)
            end
            spec.nativeMaterialHolders[effectData] = nil
        end
    end
end

local function updateSprayerMaterial(vehicle)
    if g_dedicatedServerInfo ~= nil or g_materialManager == nil then return end

    local pfEffectsSpecialization = RealisticCropRotationPFSprayer.PF_EFFECTS_SPECIALIZATION
    local effectsSpec = pfEffectsSpecialization ~= nil
        and vehicle[pfEffectsSpecialization.SPEC_TABLE_NAME] or nil
    if effectsSpec == nil or effectsSpec.hasCustomEffects ~= true then return end

    local sprayerEffects = effectsSpec.sprayerEffects
    local effectCount = sprayerEffects ~= nil and #sprayerEffects or 0
    if effectCount == 0 then return end

    local fillType = RealisticCropRotationSprayerProducts.getVehicleSprayFillType(vehicle, true)
    local spec = vehicle[RealisticCropRotationPFSprayer.SPEC_TABLE_NAME]

    if not RealisticCropRotationSprayerProducts.isProductFillType(fillType) then
        if spec.isRcrMaterialActive or next(spec.nativeMaterialHolders) ~= nil then
            restoreNativeSprayerMaterials(spec, sprayerEffects)
        end

        spec.lastMaterialFillType = nil
        spec.lastEffectCount = effectCount
        spec.missingMaterialFillType = nil
        spec.isRcrMaterialActive = false
        return
    end

    if spec.lastMaterialFillType == fillType
        and spec.lastEffectCount == effectCount then return end

    local materialId = g_materialManager:getMaterial(
        fillType, SPRAYER_MATERIAL_TYPE, SPRAYER_MATERIAL_INDEX)
    if materialId == nil then
        if spec.missingMaterialFillType ~= fillType then
            Logging.warning(
                "[RealisticCropRotation] Missing sprayer material for fillType %s",
                tostring(fillType))
            spec.missingMaterialFillType = fillType
        end
        return
    end

    if not cacheNativeSprayerMaterials(spec, sprayerEffects) then
        return
    end

    for _, effectData in ipairs(sprayerEffects) do
        local effectNode = effectData.effectNode
        if effectNode ~= nil then
            setEffectMaterial(effectNode, materialId)
        end
    end

    spec.lastMaterialFillType = fillType
    spec.lastEffectCount = effectCount
    spec.missingMaterialFillType = nil
    spec.isRcrMaterialActive = true
end

---Keeps the Precision Farming nozzle material aligned with the current sprayer product.
-- @param float _dt Time since the last update in milliseconds, unused
-- @param boolean _isActiveForInput Input-active state, unused
-- @param boolean _isActiveForInputIgnoreSelection Input-active state ignoring selection, unused
-- @param boolean _isSelected Selection state, unused
function RealisticCropRotationPFSprayer:onUpdate(_dt, _isActiveForInput, _isActiveForInputIgnoreSelection, _isSelected)
    updateSprayerMaterial(self)
end

local function getProtectionMap(treatment)
    local grid = RealisticCropRotation ~= nil and RealisticCropRotation.grid or nil
    if grid == nil then return nil, nil end

    if treatment == "FUNGICIDE" then
        return grid.fungicideProtectionMapId, grid.fungicideProtectionMapSize
    elseif treatment == "NEMATICIDE" then
        return grid.nematicideProtectionMapId, grid.nematicideProtectionMapSize
    end

    return nil, nil
end

local function getProtectionMapPoint(mapId, mapSize, worldX, worldZ)
    local mission = g_currentMission
    if mapId == nil or mapSize == nil or mission == nil
        or mission.terrainSize == nil then return nil end

    local terrainSize = mission.terrainSize
    local localX = math.floor(mapSize * (worldX + terrainSize * 0.5) / terrainSize)
    local localZ = math.floor(mapSize * (worldZ + terrainSize * 0.5) / terrainSize)
    return getBitVectorMapPoint(mapId, localX, localZ, 0, 1)
end

---Applies the RCR field-ground and already-treated checks after the native PF nozzle state.
-- @param function superFunc Native PF nozzle-state chain
-- @param table effectData PF nozzle effect data
-- @param float dt Time since the last update in milliseconds
-- @param boolean isTurnedOn Native turned-on state
-- @param float lastSpeed Vehicle speed in km/h
-- @return boolean isActive Nozzle state
-- @return number amountScale Native PF amount scale
function RealisticCropRotationPFSprayer:updateExtendedSprayerNozzleEffectState(
    superFunc, effectData, dt, isTurnedOn, lastSpeed)
    local isActive, amountScale = superFunc(self, effectData, dt, isTurnedOn, lastSpeed)
    -- Dedicated servers keep the native PF state; RCR nozzle filtering is visual and client-side.
    if not self.isClient then return isActive, amountScale end
    if not isActive then return false, amountScale end

    local fillType = RealisticCropRotationSprayerProducts.getVehicleSprayFillType(self, true)
    local treatment = RealisticCropRotationSprayerProducts.getProductTreatment(fillType)
    if treatment == nil then return isActive, amountScale end

    if (lastSpeed or 0) <= MIN_WORK_SPEED then return false, amountScale end

    local spec = self[RealisticCropRotationPFSprayer.SPEC_TABLE_NAME]
    if spec.groundTypeMapId == nil or effectData.effectNode == nil then
        return false, amountScale
    end

    local worldX, worldY, worldZ = localToWorld(effectData.effectNode, 0, 0, 1)
    local densityBitsGround = getDensityAtWorldPos(spec.groundTypeMapId, worldX, worldY, worldZ)
    local groundTypeValue = bit32.band(
        bit32.rshift(densityBitsGround, spec.groundTypeFirstChannel),
        2 ^ spec.groundTypeNumChannels - 1)
    if FieldGroundType.getTypeByValue(groundTypeValue) == FieldGroundType.NONE then
        return false, amountScale
    end

    local protectionMapId, protectionMapSize = getProtectionMap(treatment)
    local protectionValue = getProtectionMapPoint(
        protectionMapId, protectionMapSize, worldX, worldZ)
    if protectionValue == nil or protectionValue > 0 then
        return false, amountScale
    end

    return isActive, amountScale
end
