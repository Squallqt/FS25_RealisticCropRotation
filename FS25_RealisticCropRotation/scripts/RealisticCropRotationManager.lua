-- Copyright © 2026 Squallqt. All rights reserved.
-- Facade over Repository + Service for the GUI/HUD reads.
RealisticCropRotationManager = {}
local RealisticCropRotationManager_mt = Class(RealisticCropRotationManager)

-- Active-crop cache TTL: UI/HUD reads are frequent, growth changes slowly.
local ACTIVE_CROP_CACHE_TTL_MS = 10000

-- PF soil read cache TTL. PF nitrogen/pH only change when the player works the
-- field; a short TTL keeps the menu-open reads cheap without going stale.
local SOIL_PF_CACHE_TTL_MS = 10000

-- Soil scan grid resolution (menu only): FIELD_SCAN_STEPS^2 points over the field.
local FIELD_SCAN_STEPS = 50


---True on a multiplayer client (not the server/host).
-- @return boolean isPureClient
local function isPureClient()
    return g_currentMission ~= nil
        and g_currentMission.getIsServer ~= nil
        and not g_currentMission:getIsServer()
end

---Returns the farmland object for an id.
-- @param integer farmlandId
-- @return table farmland or nil
local function getFarmlandById(farmlandId)
    if farmlandId == nil or g_farmlandManager == nil then return nil end
    if g_farmlandManager.getFarmlandById ~= nil then
        return g_farmlandManager:getFarmlandById(farmlandId)
    end
    if g_farmlandManager.farmlands ~= nil then
        return g_farmlandManager.farmlands[farmlandId]
    end
    return nil
end

---Returns the owning farm id for a farmland.
-- @param integer farmlandId
-- @param table farmland
-- @return integer farmId or nil
local function getOwnerFarmIdForFarmland(farmlandId, farmland)
    if g_farmlandManager ~= nil and type(g_farmlandManager.getFarmlandOwner) == "function" then
        return g_farmlandManager:getFarmlandOwner(tonumber(farmlandId) or farmlandId)
    end
    return farmland ~= nil and farmland.farmId or nil
end

---True when farmId is a real buyable-farm owner (not the not-buyable id).
-- @param integer farmId
-- @return boolean
local function isRealFarmOwner(farmId)
    local numericFarmId = tonumber(farmId)
    if numericFarmId == nil or numericFarmId <= 0 then return false end
    if FarmlandManager ~= nil and FarmlandManager.NOT_BUYABLE_FARM_ID ~= nil
        and numericFarmId == FarmlandManager.NOT_BUYABLE_FARM_ID then
        return false
    end
    return true
end

---World-space axis-aligned bounding box of a field's polygon corner nodes (Field has no `fieldDimensions`).
-- @param table field
-- @return number minX, maxX, minZ, maxZ, or nil when geometry is unavailable
local function fieldPolygonBounds(field)
    if field == nil or getWorldTranslation == nil then return nil end
    local points = field.polygonPoints
    if type(points) ~= "table" or #points == 0 then return nil end

    local minX, maxX, minZ, maxZ
    for _, node in ipairs(points) do
        if node ~= nil then
            local ok, x, _, z = pcall(getWorldTranslation, node)
            if ok and type(x) == "number" and type(z) == "number" then
                if minX == nil or x < minX then minX = x end
                if maxX == nil or x > maxX then maxX = x end
                if minZ == nil or z < minZ then minZ = z end
                if maxZ == nil or z > maxZ then maxZ = z end
            end
        end
    end

    if minX == nil then return nil end
    return minX, maxX, minZ, maxZ
end

---Returns the first usable Field object attached to a farmland.
-- @param table farmland
-- @return table field or nil
local function getUsableFieldFromFarmland(farmland)
    if type(farmland) ~= "table" then return nil end
    if type(farmland.field) == "table" then return farmland.field end
    if type(farmland.fields) == "table" then
        for _, candidate in pairs(farmland.fields) do
            if type(candidate) == "table" then return candidate end
        end
    end
    return nil
end

---Returns the cultivable area of a field in hectares (0 when unknown).
-- @param table field
-- @return number areaHa
local function getFieldAreaHa(field)
    if type(field) ~= "table" then return 0 end
    local areaHa = tonumber(field.areaHa) or 0
    if areaHa > 0 then return areaHa end
    local fieldAreaHa = tonumber(field.fieldAreaHa) or 0
    if fieldAreaHa > 0 then return fieldAreaHa end
    return 0
end

---Returns the cultivable agricultural area of a farmland in hectares (0 when unknown).
-- @param table farmland
-- @return number areaHa
local function getFarmlandFieldAreaHa(farmland)
    if type(farmland) ~= "table" then return 0 end
    -- Cultivable agricultural area on the farmland — different from areaInHa
    -- which is the full buyable parcel and may include yards/buildable land.
    local totalFieldArea = tonumber(farmland.totalFieldArea) or 0
    if totalFieldArea > 0 then return totalFieldArea end
    local fieldAreaHa = tonumber(farmland.fieldAreaHa) or 0
    if fieldAreaHa > 0 then return fieldAreaHa end
    return 0
end

---Best rotation area in hectares: field area first, farmland field area fallback.
-- @param table farmland
-- @param table field
-- @return number areaHa
local function getRotationAreaHa(farmland, field)
    local fieldArea = getFieldAreaHa(field)
    if fieldArea > 0 then return fieldArea end
    return getFarmlandFieldAreaHa(farmland)
end

---True when a farmland/field pair has a non-zero rotation area.
-- @param table farmland
-- @param table field
-- @return boolean
local function hasUsableRealisticCropRotationArea(farmland, field)
    return getRotationAreaHa(farmland, field) > 0
end

---Fallback crop name (FIELDGRASS) for player-converted grassland with no Field object.
-- @return string cropName, or nil
local function getPermanentGrasslandFallbackCropName()
    if g_fruitTypeManager == nil or g_fruitTypeManager.getFruitTypeByName == nil then return nil end
    local fieldGrass = g_fruitTypeManager:getFruitTypeByName("FIELDGRASS")
    if fieldGrass ~= nil and fieldGrass.name ~= nil and fieldGrass.name ~= "" then
        return tostring(fieldGrass.name)
    end
    return nil
end

---Normalizes a fruit-type index, mapping UNKNOWN/invalid to nil.
-- @param integer fruitTypeIndex
-- @return integer index, or nil
local function normalizeFruitTypeIndex(fruitTypeIndex)
    local n = tonumber(fruitTypeIndex)
    local unknown = (FruitType ~= nil and FruitType.UNKNOWN) or 0
    if n == nil or n == unknown then return nil end
    return n
end

---Samples the fruit type + growth state at a world position.
-- @param number x
-- @param number z
-- @return integer fruitTypeIndex, or nil
-- @return boolean sampled True when the density map could be read
-- @return integer growthState, or nil
local function getFruitTypeIndexAtWorldPos(x, z)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then
        return nil, false
    end
    if type(x) ~= "number" or type(z) ~= "number" then
        return nil, false
    end

    local ok, fruitTypeIndex, growthState = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
    if not ok then return nil, true end
    return normalizeFruitTypeIndex(fruitTypeIndex), true, tonumber(growthState)
end

---Appends interior sample points across the field, masked to worked ground so off-field corners of an angled field don't skew the majority-crop vote.
-- @param table field
-- @param table samples Accumulator of { x, z } points
local function collectFieldInteriorSamples(field, samples)
    local minX, maxX, minZ, maxZ = fieldPolygonBounds(field)
    if minX == nil then return end

    local terrainDetailId = g_currentMission ~= nil and g_currentMission.terrainDetailId or nil
    local canMask = terrainDetailId ~= nil and getDensityAtWorldPos ~= nil

    local offsets = {
        {0.50, 0.50},
        {0.25, 0.25},
        {0.75, 0.25},
        {0.25, 0.75},
        {0.75, 0.75},
    }

    for _, offset in ipairs(offsets) do
        local x = minX + (maxX - minX) * offset[1]
        local z = minZ + (maxZ - minZ) * offset[2]
        if not canMask or getDensityAtWorldPos(terrainDetailId, x, 0, z) ~= 0 then
            table.insert(samples, { x = x, z = z })
        end
    end
end

---Majority fruit type over field samples from the density map.
-- @param table field
-- @return integer fruitTypeIndex, or nil
-- @return boolean sampled True when the density map could be read
-- @return integer growthState Representative growth state, or nil
local function getFieldFruitTypeIndexFromDensityMap(field)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then
        return nil, false
    end

    local samples = {}
    if field ~= nil and type(field.posX) == "number" and type(field.posZ) == "number" then
        table.insert(samples, { x = field.posX, z = field.posZ })
    end
    collectFieldInteriorSamples(field, samples)

    local sampled = false
    local counts = {}
    local growthStateCounts = {}
    for _, sample in ipairs(samples) do
        local fruitTypeIndex, didSample, growthState = getFruitTypeIndexAtWorldPos(sample.x, sample.z)
        if didSample then
            sampled = true
            if fruitTypeIndex ~= nil then
                counts[fruitTypeIndex] = (counts[fruitTypeIndex] or 0) + 1
                growthState = tonumber(growthState)
                if growthState ~= nil then
                    growthState = math.floor(growthState + 0.5)
                    growthStateCounts[fruitTypeIndex] = growthStateCounts[fruitTypeIndex] or {}
                    growthStateCounts[fruitTypeIndex][growthState] = (growthStateCounts[fruitTypeIndex][growthState] or 0) + 1
                end
            end
        end
    end

    if not sampled then return nil, false end

    local bestFruitTypeIndex = nil
    local bestCount = 0
    for fruitTypeIndex, count in pairs(counts) do
        if count > bestCount then
            bestFruitTypeIndex = fruitTypeIndex
            bestCount = count
        end
    end

    local representativeGrowthState = nil
    local representativeGrowthCount = 0
    local states = bestFruitTypeIndex ~= nil and growthStateCounts[bestFruitTypeIndex] or nil
    for growthState, count in pairs(states or {}) do
        if count > representativeGrowthCount
            or (count == representativeGrowthCount
                and (representativeGrowthState == nil or growthState < representativeGrowthState)) then
            representativeGrowthState = growthState
            representativeGrowthCount = count
        end
    end

    return bestFruitTypeIndex, true, representativeGrowthState
end

---Fruit type from the engine's fieldState snapshot (server only); skips cut/withered.
-- @param table field
-- @return integer fruitTypeIndex, or nil
-- @return integer growthState, or nil
local function getFieldFruitTypeIndexFromFieldState(field)
    local fieldState = field ~= nil and field.fieldState or nil
    if fieldState == nil then return nil end

    local fruitTypeIndex = normalizeFruitTypeIndex(fieldState.fruitTypeIndex)
    if fruitTypeIndex == nil then return nil end
    local growthState = tonumber(fieldState.growthState or fieldState.lastGrowthState)

    local fruitType = nil
    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByIndex ~= nil then
        fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    end

    if fruitType ~= nil then
        if growthState ~= nil then
            if type(fruitType.getIsCut) == "function" then
                local ok, isCut = pcall(fruitType.getIsCut, fruitType, growthState)
                if ok and isCut then return nil end
            elseif fruitType.cutState ~= nil and growthState == tonumber(fruitType.cutState) then
                return nil
            end

            if type(fruitType.getIsWithered) == "function" then
                local ok, isWithered = pcall(fruitType.getIsWithered, fruitType, growthState)
                if ok and isWithered then return nil end
            elseif fruitType.witheredState ~= nil and growthState == tonumber(fruitType.witheredState) then
                return nil
            end
        end
    end

    return fruitTypeIndex, growthState
end

---Active fruit type: density map first, fieldState fallback (server only).
-- @param table field
-- @return integer fruitTypeIndex, or nil
-- @return integer growthState, or nil
local function getFieldFruitTypeIndex(field)
    local fruitTypeIndex, sampledDensityMap, growthState = getFieldFruitTypeIndexFromDensityMap(field)
    if sampledDensityMap then return fruitTypeIndex, growthState end
    if isPureClient() then return nil end
    return getFieldFruitTypeIndexFromFieldState(field)
end

---Resolves the active crop name (+ index, growth) from a field.
-- @param table field
-- @return string cropName, or nil
-- @return integer fruitTypeIndex, or nil
-- @return integer growthState, or nil
local function getActiveCropNameFromField(field)
    local fruitTypeIndex, growthState = getFieldFruitTypeIndex(field)
    if fruitTypeIndex == nil or g_fruitTypeManager == nil then return nil end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil or fruitType.name == nil or fruitType.name == "" then return nil end
    return tostring(fruitType.name), fruitTypeIndex, growthState
end

---Builds a fresh, validated FieldState at the field centre.
-- @param table field
-- @return table fieldState, or nil
local function sampleFieldStateAtField(field)
    if field == nil or FieldState == nil then return nil end
    if type(field.posX) ~= "number" or type(field.posZ) ~= "number" then return nil end

    local fieldState = FieldState.new()
    if type(fieldState.update) ~= "function" then return nil end
    fieldState:update(field.posX, field.posZ)
    if not fieldState.isValid then return nil end
    return fieldState
end

---Live majority ground type from the GROUND_TYPE density map (WheelPhysics read pattern).
-- @param table field
-- @return table groundType FieldGroundType entry, or nil
local function getFieldGroundTypeFromDensityMap(field)
    if g_currentMission == nil or g_currentMission.fieldGroundSystem == nil then return nil end
    if getDensityAtWorldPos == nil or getTerrainHeightAtWorldPos == nil or g_terrainNode == nil then return nil end
    if FieldGroundType == nil or type(FieldGroundType.getTypeByValue) ~= "function" then return nil end
    if FieldDensityMap == nil or FieldDensityMap.GROUND_TYPE == nil then return nil end

    local mapId, firstChannel, numChannels =
        g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if mapId == nil or firstChannel == nil or numChannels == nil then return nil end

    local samples = {}
    if field ~= nil and type(field.posX) == "number" and type(field.posZ) == "number" then
        table.insert(samples, { x = field.posX, z = field.posZ })
    end
    collectFieldInteriorSamples(field, samples)
    if #samples == 0 then return nil end

    local mask = 2 ^ numChannels - 1
    local counts = {}
    for _, sample in ipairs(samples) do
        local wy = getTerrainHeightAtWorldPos(g_terrainNode, sample.x, 0, sample.z)
        local bits = getDensityAtWorldPos(mapId, sample.x, wy, sample.z)
        local value = bit32.band(bit32.rshift(bits, firstChannel), mask)
        local groundType = FieldGroundType.getTypeByValue(value)
        if groundType ~= nil then
            counts[groundType] = (counts[groundType] or 0) + 1
        end
    end

    local best, bestCount = nil, 0
    for groundType, count in pairs(counts) do
        if count > bestCount then best, bestCount = groundType, count end
    end
    return best
end

---Maps the live ground type to a GROWTH_STATE_INDEX (cultivated/plowed/stubble/seedbed).
-- @param table field
-- @return integer index, or nil
local function getNativeGroundStateIndex(field)
    if FieldGroundType == nil or MapOverlayGenerator == nil
        or MapOverlayGenerator.GROWTH_STATE_INDEX == nil then
        return nil
    end

    -- Live read first (fresh, consistent with the crop detection); fall back to the engine's
    -- periodic fieldState snapshot only when the live read is unavailable.
    local groundType = getFieldGroundTypeFromDensityMap(field)
    if groundType == nil and field ~= nil and field.fieldState ~= nil then
        groundType = field.fieldState.groundType
    end
    if groundType == nil then return nil end

    local indices = MapOverlayGenerator.GROWTH_STATE_INDEX

    if groundType == FieldGroundType.CULTIVATED then
        return indices.CULTIVATED
    elseif groundType == FieldGroundType.PLOWED then
        return indices.PLOWED
    elseif groundType == FieldGroundType.STUBBLE_TILLAGE then
        return indices.STUBBLE_TILLAGE
    elseif groundType == FieldGroundType.SEEDBED
        or groundType == FieldGroundType.ROLLED_SEEDBED then
        return indices.SEEDBED
    end

    return nil
end

---Reads a fieldState level field, rounded to the nearest integer.
-- @param table fieldState
-- @param string name Level field name
-- @return integer level
local function getRoundedFieldStateLevel(fieldState, name)
    return math.floor((tonumber(fieldState ~= nil and fieldState[name]) or 0) + 0.5)
end

---Soil state at a point (watered/mulched/needs-rolling/needs-plowing) per gameplay flags.
-- @param table fieldState
-- @return integer index SOIL_STATE_INDEX, or nil
local function getNativeSoilStateIndexFromFieldState(fieldState)
    if fieldState == nil or MapOverlayGenerator == nil
        or MapOverlayGenerator.SOIL_STATE_INDEX == nil then
        return nil
    end

    local indices = MapOverlayGenerator.SOIL_STATE_INDEX
    local gameplay = Platform ~= nil and Platform.gameplay or nil
    local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil

    if indices.WATERED ~= nil and getRoundedFieldStateLevel(fieldState, "waterLevel") == 1 then
        return indices.WATERED
    end
    if gameplay ~= nil and gameplay.useStubbleShred == true and indices.MULCHED ~= nil
        and getRoundedFieldStateLevel(fieldState, "stubbleShredLevel") == 1 then
        return indices.MULCHED
    end
    if gameplay ~= nil and gameplay.useRolling == true and indices.NEEDS_ROLLING ~= nil
        and getRoundedFieldStateLevel(fieldState, "rollerLevel") == 1 then
        return indices.NEEDS_ROLLING
    end
    if gameplay ~= nil and gameplay.usePlowCounter == true
        and missionInfo ~= nil and missionInfo.plowingRequiredEnabled == true
        and indices.NEEDS_PLOWING ~= nil
        and getRoundedFieldStateLevel(fieldState, "plowLevel") == 0 then
        return indices.NEEDS_PLOWING
    end

    return nil
end

---Ordered SOIL_STATE_INDEX list used to break ties when picking a majority soil state.
-- @return table indices
local function getNativeSoilStatePriority()
    if MapOverlayGenerator == nil or MapOverlayGenerator.SOIL_STATE_INDEX == nil then return {} end
    local indices = MapOverlayGenerator.SOIL_STATE_INDEX
    local result = {}
    if indices.WATERED ~= nil then table.insert(result, indices.WATERED) end
    if indices.MULCHED ~= nil then table.insert(result, indices.MULCHED) end
    if indices.NEEDS_ROLLING ~= nil then table.insert(result, indices.NEEDS_ROLLING) end
    if indices.NEEDS_PLOWING ~= nil then table.insert(result, indices.NEEDS_PLOWING) end
    return result
end

---Majority soil state over field samples, with a centre-point fallback.
-- @param table field
-- @return integer index SOIL_STATE_INDEX, or nil
local function getNativeSoilStateIndex(field)
    if field == nil then return nil end

    local samples = {}
    if type(field.posX) == "number" and type(field.posZ) == "number" then
        table.insert(samples, { x = field.posX, z = field.posZ })
    end
    collectFieldInteriorSamples(field, samples)

    local counts = {}
    if #samples > 0 and FieldState ~= nil then
        for _, sample in ipairs(samples) do
            local fieldState = FieldState.new()
            if type(fieldState.update) == "function" then
                fieldState:update(sample.x, sample.z)
                if fieldState.isValid then
                    local index = getNativeSoilStateIndexFromFieldState(fieldState)
                    if index ~= nil then
                        counts[index] = (counts[index] or 0) + 1
                    end
                end
            end
        end
    end

    local best, bestCount = nil, 0
    for _, index in ipairs(getNativeSoilStatePriority()) do
        local count = counts[index] or 0
        if count > bestCount then
            best = index
            bestCount = count
        end
    end
    if best ~= nil then return best end

    local fieldState = sampleFieldStateAtField(field)
        or (field ~= nil and field.fieldState or nil)
    return getNativeSoilStateIndexFromFieldState(fieldState)
end

---Ground state -> native GIANTS l10n label (GROWTH_MAP_* via MapOverlayGenerator.L10N_SYMBOL).
-- @param table field
-- @param integer groundStateIndex Resolved when nil
-- @return string label, or nil
local function getNativeGroundStateLabel(field, groundStateIndex)
    if MapOverlayGenerator == nil or MapOverlayGenerator.L10N_SYMBOL == nil
        or g_i18n == nil or type(g_i18n.getText) ~= "function" then
        return nil
    end

    local index = groundStateIndex or getNativeGroundStateIndex(field)
    if index == nil then return nil end

    local symbols = MapOverlayGenerator.L10N_SYMBOL
    local indices = MapOverlayGenerator.GROWTH_STATE_INDEX
    local key = nil

    if index == indices.CULTIVATED then
        key = symbols.GROWTH_MAP_CULTIVATED
    elseif index == indices.PLOWED then
        key = symbols.GROWTH_MAP_PLOWED
    elseif index == indices.STUBBLE_TILLAGE then
        key = symbols.GROWTH_MAP_STUBBLE_TILLAGE
    elseif index == indices.SEEDBED then
        key = symbols.GROWTH_MAP_SEEDBED
    end

    if key == nil then return nil end
    local label = g_i18n:getText(key)
    if label == nil or label == "" or label == key then return nil end
    return label
end

---Soil state -> native GIANTS l10n label (SOIL_MAP_* via MapOverlayGenerator.L10N_SYMBOL).
-- @param table field
-- @param integer soilStateIndex Resolved when nil
-- @return string label, or nil
local function getNativeSoilStateLabel(field, soilStateIndex)
    if MapOverlayGenerator == nil or MapOverlayGenerator.L10N_SYMBOL == nil
        or MapOverlayGenerator.SOIL_STATE_INDEX == nil
        or g_i18n == nil or type(g_i18n.getText) ~= "function" then
        return nil
    end

    local index = soilStateIndex or getNativeSoilStateIndex(field)
    if index == nil then return nil end

    local symbols = MapOverlayGenerator.L10N_SYMBOL
    local indices = MapOverlayGenerator.SOIL_STATE_INDEX
    local key = nil

    if index == indices.NEEDS_PLOWING then
        key = symbols.SOIL_MAP_NEED_PLOWING
    elseif index == indices.NEEDS_ROLLING then
        key = symbols.SOIL_MAP_NEED_ROLLING
    elseif index == indices.MULCHED then
        key = symbols.SOIL_MAP_MULCHED
    elseif index == indices.WATERED then
        key = symbols.SOIL_MAP_WATERED
    end

    if key == nil then return nil end
    local label = g_i18n:getText(key)
    if label == nil or label == "" or label == key then return nil end
    return label
end

---No-crop status priority (lower = higher): needed actions > tillage > passive conditions.
-- @param string kind "soil" or "ground"
-- @param integer index State index for that kind
-- @return integer rank Lower wins; math.huge when unranked
local function fieldStatusRank(kind, index)
    if MapOverlayGenerator == nil then return math.huge end
    local G = MapOverlayGenerator.GROWTH_STATE_INDEX
    local S = MapOverlayGenerator.SOIL_STATE_INDEX
    if kind == "soil" and S ~= nil then
        if index == S.NEEDS_PLOWING then return 1 end
        if index == S.NEEDS_ROLLING then return 2 end
        if index == S.MULCHED       then return 7 end
        if index == S.WATERED       then return 8 end
    elseif kind == "ground" and G ~= nil then
        if index == G.PLOWED          then return 3 end
        if index == G.STUBBLE_TILLAGE then return 4 end
        if index == G.CULTIVATED      then return 5 end
        if index == G.SEEDBED         then return 6 end
    end
    return math.huge
end

---Field-prep needed at a point (PLOW_LEVEL 0 / ROLLER_LEVEL 1), per buildSoilStateMapOverlay.
-- @param table fieldState
-- @return boolean plowNeeded
-- @return boolean rollNeeded
local function detectTillageActionsFromFieldState(fieldState)
    local gameplay = Platform ~= nil and Platform.gameplay or nil
    local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil

    local plowNeeded = gameplay ~= nil and gameplay.usePlowCounter == true
        and missionInfo ~= nil and missionInfo.plowingRequiredEnabled == true
        and getRoundedFieldStateLevel(fieldState, "plowLevel") == 0

    local rollNeeded = gameplay ~= nil and gameplay.useRolling == true
        and getRoundedFieldStateLevel(fieldState, "rollerLevel") == 1

    return plowNeeded == true, rollNeeded == true
end

-- Construction / lifecycle.

---Creates the manager (repository + service, caches).
-- @return RealisticCropRotationManager instance
function RealisticCropRotationManager.new()
    local self = setmetatable({}, RealisticCropRotationManager_mt)
    self.repository = RealisticCropRotationRepository.new()
    self.service = RealisticCropRotationService.new(self.repository)
    self.activeCropNameCache = {}
    self.soilPFCache = {}
    self.isInitialized = false
    return self
end

---Initializes the manager once (clears state).
function RealisticCropRotationManager:initialize()
    if self.isInitialized then return end
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.soilPFCache = {}
    self.isInitialized = true
end

---Clears all state and marks the manager uninitialized.
function RealisticCropRotationManager:cleanup()
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.soilPFCache = {}
    self.isInitialized = false
end

---Persists the rotation state to the savegame.
-- @param string savegamePath Savegame folder path
function RealisticCropRotationManager:saveToXML(savegamePath)
    return self.repository:saveToXML(savegamePath)
end

---Loads the rotation state from the savegame.
-- @param string savegamePath Savegame folder path
function RealisticCropRotationManager:loadFromXML(savegamePath)
    self.repository:loadFromXML(savegamePath)
end

-- GUI / runtime queries.

---Returns the crop history for a farmland.
-- @param integer farmlandId
-- @return table entries
function RealisticCropRotationManager:getHistory(farmlandId)
    return self.repository:getHistory(farmlandId)
end

---Returns the full history map.
-- @return table history
function RealisticCropRotationManager:getAllHistory()
    return self.repository:getAllHistory()
end

---Returns the 4-slot rotation plan for a farmland.
-- @param integer farmlandId
-- @return table plan
function RealisticCropRotationManager:getRotationPlan(farmlandId)
    return self.repository:getPlan(farmlandId)
end

---Returns the full rotation-plan map.
-- @return table plans
function RealisticCropRotationManager:getAllRotationPlans()
    return self.repository:getAllPlans()
end

---Sets one year slot of a farmland's rotation plan.
-- @param integer farmlandId
-- @param integer yearIdx Slot 1-4
-- @param string family Crop family, or "" to clear
-- @return boolean changed
function RealisticCropRotationManager:setRotationPlanYear(farmlandId, yearIdx, family)
    local n = tonumber(farmlandId)
    local y = tonumber(yearIdx)
    if n == nil or n <= 0 or y == nil or y < 1 or y > 4 then return false end
    self.repository:setPlanYear(n, y, family)
    return true
end

---Returns the 4-slot cover-crop plan for a farmland.
-- @param integer farmlandId
-- @return table coverPlan
function RealisticCropRotationManager:getRotationCoverPlan(farmlandId)
    return self.repository:getCoverPlan(farmlandId)
end

---Returns the full cover-plan map.
-- @return table coverPlans
function RealisticCropRotationManager:getAllRotationCoverPlans()
    return self.repository:getAllCoverPlans()
end

---Sets one year slot of a farmland's cover-crop plan.
-- @param integer farmlandId
-- @param integer yearIdx Slot 1-4
-- @param string cropName Cover crop name, or "" to clear
-- @return boolean changed
function RealisticCropRotationManager:setRotationCoverPlanYear(farmlandId, yearIdx, cropName)
    local n = tonumber(farmlandId)
    local y = tonumber(yearIdx)
    if n == nil or n <= 0 or y == nil or y < 1 or y > 4 then return false end
    self.repository:setCoverPlanYear(n, y, cropName)
    return true
end

---Clears a farmland's main and cover plans.
-- @param integer farmlandId
-- @return boolean changed
function RealisticCropRotationManager:clearRotationPlan(farmlandId)
    if self.repository == nil or type(self.repository.clearPlan) ~= "function" then return false end
    return self.repository:clearPlan(farmlandId)
end

---Returns the local player's farm id.
-- @return integer farmId, or nil
function RealisticCropRotationManager:getCurrentFarmId()
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then return g_localPlayer.farmId end
    if g_currentMission ~= nil and type(g_currentMission.getFarmId) == "function" then
        return g_currentMission:getFarmId()
    end
    return nil
end

---Resolves the Field object owning a farmland.
-- @param integer farmlandId
-- @return table field, or nil
function RealisticCropRotationManager:getFieldByFarmlandId(farmlandId)
    local n = tonumber(farmlandId)
    if n == nil or n <= 0 then return nil end

    if g_fieldManager ~= nil then
        if g_fieldManager.farmlandIdFieldMapping ~= nil then
            local field = g_fieldManager.farmlandIdFieldMapping[n]
                or g_fieldManager.farmlandIdFieldMapping[tostring(n)]
            if field ~= nil then return field end
        end

        local fields = nil
        if type(g_fieldManager.getFields) == "function" then
            fields = g_fieldManager:getFields()
        else
            fields = g_fieldManager.fields
        end
        if fields ~= nil then
            for _, field in pairs(fields) do
                if field ~= nil and field.farmland ~= nil and tonumber(field.farmland.id) == n then
                    return field
                end
            end
        end
    end

    return getUsableFieldFromFarmland(getFarmlandById(n))
end

---Returns the currently active crop on a farmland (cached).
-- Pure clients use density-map sampling only; fieldState fallback is server-only.
-- @param integer farmlandId
-- @return string cropName, or nil
-- @return integer fruitTypeIndex, or nil
-- @return integer growthState, or nil
function RealisticCropRotationManager:getActiveCropInfo(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil then return nil end

    local cache = self.activeCropNameCache
    local nowMs = tonumber(g_time) or 0
    if cache ~= nil then
        local entry = cache[numericFarmlandId]
        if entry ~= nil and (nowMs - (entry.tMs or 0)) < ACTIVE_CROP_CACHE_TTL_MS then
            return entry.name, entry.fruitTypeIndex, entry.growthState
        end
    end

    local field = self:getFieldByFarmlandId(numericFarmlandId)
    local resolved, fruitTypeIndex, growthState = getActiveCropNameFromField(field)
    if resolved == nil then
        local farmland = getFarmlandById(numericFarmlandId)
        if field == nil and getFarmlandFieldAreaHa(farmland) > 0 then
            -- Player-converted grassland (no Field object): show FIELDGRASS, not Fallow.
            resolved = getPermanentGrasslandFallbackCropName()
            if resolved ~= nil and g_fruitTypeManager ~= nil
                and type(g_fruitTypeManager.getFruitTypeByName) == "function" then
                local fruitType = g_fruitTypeManager:getFruitTypeByName(resolved)
                fruitTypeIndex = fruitType ~= nil and fruitType.index or nil
            end
        end
    end

    if cache ~= nil then
        cache[numericFarmlandId] = {
            name = resolved,
            fruitTypeIndex = fruitTypeIndex,
            growthState = growthState,
            tMs = nowMs,
        }
    end
    return resolved, fruitTypeIndex, growthState
end

---Returns just the active crop name on a farmland.
-- @param integer farmlandId
-- @return string cropName, or nil
function RealisticCropRotationManager:getActiveCropName(farmlandId)
    local cropName = self:getActiveCropInfo(farmlandId)
    return cropName
end

---Drops the cached active-crop entry for a farmland.
-- @param integer farmlandId
function RealisticCropRotationManager:invalidateActiveCropCache(farmlandId)
    if self.activeCropNameCache == nil then return end
    local n = tonumber(farmlandId)
    if n == nil then return end
    self.activeCropNameCache[n] = nil
end

---Reconciles stored history with the live active crop (server only).
-- @param integer farmlandId
-- @return boolean changed
function RealisticCropRotationManager:reconcileActiveCropForFarmland(farmlandId)
    if self.service == nil then return false end
    if isPureClient() then return false end

    local currentCropName, currentFruitTypeIndex, currentGrowthState = self:getActiveCropInfo(farmlandId)
    local changed = self.service:reconcileActiveCrop(farmlandId, currentCropName, currentFruitTypeIndex, currentGrowthState)
    if changed then
        self:invalidateActiveCropCache(farmlandId)
    end
    return changed
end

---Most important no-crop field status (tillage + soil merged via fieldStatusRank).
-- @param integer farmlandId
-- @return string label, or nil
-- @return string kind "ground" or "soil"
-- @return integer index Native state index
function RealisticCropRotationManager:getCurrentFieldStatus(farmlandId)
    local field = self:getFieldByFarmlandId(farmlandId)
    if field == nil then return nil end

    local soilIndex = getNativeSoilStateIndex(field)
    local groundIndex = getNativeGroundStateIndex(field)

    local chosenKind, chosenIndex, bestRank = nil, nil, math.huge
    if soilIndex ~= nil then
        local r = fieldStatusRank("soil", soilIndex)
        if r < bestRank then bestRank, chosenKind, chosenIndex = r, "soil", soilIndex end
    end
    if groundIndex ~= nil then
        local r = fieldStatusRank("ground", groundIndex)
        if r < bestRank then bestRank, chosenKind, chosenIndex = r, "ground", groundIndex end
    end
    if chosenKind == nil then return nil end

    local label
    if chosenKind == "soil" then
        label = getNativeSoilStateLabel(nil, chosenIndex)
    else
        label = getNativeGroundStateLabel(field, chosenIndex)
    end
    if label == nil or label == "" then return nil end
    return label, chosenKind, chosenIndex
end

---Top field-prep action label over field samples (plow > roll).
-- @param integer farmlandId
-- @return string label Native action label, or nil when none
function RealisticCropRotationManager:getRequiredFieldActionLabel(farmlandId)
    if MapOverlayGenerator == nil or MapOverlayGenerator.SOIL_STATE_INDEX == nil then return nil end
    local field = self:getFieldByFarmlandId(farmlandId)
    if field == nil or FieldState == nil then return nil end

    local samples = {}
    if type(field.posX) == "number" and type(field.posZ) == "number" then
        samples[#samples + 1] = { x = field.posX, z = field.posZ }
    end
    collectFieldInteriorSamples(field, samples)
    if #samples == 0 then return nil end

    local total, plowCount, rollCount = 0, 0, 0
    for _, s in ipairs(samples) do
        local fieldState = FieldState.new()
        if type(fieldState.update) == "function" then
            fieldState:update(s.x, s.z)
            if fieldState.isValid then
                total = total + 1
                local plowNeeded, rollNeeded = detectTillageActionsFromFieldState(fieldState)
                if plowNeeded then plowCount = plowCount + 1 end
                if rollNeeded then rollCount = rollCount + 1 end
            end
        end
    end
    if total == 0 then return nil end

    local indices = MapOverlayGenerator.SOIL_STATE_INDEX
    if plowCount * 2 >= total then
        return getNativeSoilStateLabel(nil, indices.NEEDS_PLOWING)
    end
    if rollCount * 2 >= total then
        return getNativeSoilStateLabel(nil, indices.NEEDS_ROLLING)
    end
    return nil
end

---Returns the player-owned farmland ids that carry a usable rotation area, sorted.
-- @return table farmlandIds
function RealisticCropRotationManager:getOwnedRotationFarmlandIds()
    local result = {}
    if g_farmlandManager == nil or type(g_farmlandManager.getFarmlands) ~= "function" then return result end

    for farmlandId, farmland in pairs(g_farmlandManager:getFarmlands() or {}) do
        if isRealFarmOwner(getOwnerFarmIdForFarmland(farmlandId, farmland)) then
            local field = self:getFieldByFarmlandId(farmlandId)
            if hasUsableRealisticCropRotationArea(farmland, field) then
                table.insert(result, tonumber(farmlandId) or farmlandId)
            end
        end
    end

    table.sort(result, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na ~= nil and nb ~= nil then return na < nb end
        return tostring(a) < tostring(b)
    end)

    return result
end

---Returns owned farmlands as display rows for the menu, sorted by field number.
-- @return table rows { farmlandId, name, areaHa }
function RealisticCropRotationManager:getOwnedFarmlands()
    local result = {}
    local farmId = self:getCurrentFarmId()
    if farmId == nil or g_farmlandManager == nil then return result end

    local farmlandIds = {}
    if type(g_farmlandManager.getOwnedFarmlandIdsByFarmId) == "function" then
        farmlandIds = g_farmlandManager:getOwnedFarmlandIdsByFarmId(farmId) or {}
    elseif type(g_farmlandManager.getFarmlands) == "function" then
        for farmlandId, farmland in pairs(g_farmlandManager:getFarmlands() or {}) do
            local owner = getOwnerFarmIdForFarmland(farmlandId, farmland)
            if owner == farmId then table.insert(farmlandIds, farmlandId) end
        end
    end

    local prefix = "Field"
    if g_i18n ~= nil and type(g_i18n.getText) == "function" then
        prefix = g_i18n:getText("rcr_field_prefix") or prefix
    end

    for _, farmlandId in ipairs(farmlandIds) do
        local farmland = getFarmlandById(farmlandId)
        local field = self:getFieldByFarmlandId(farmlandId)
        if hasUsableRealisticCropRotationArea(farmland, field) then
            local rawName = farmland ~= nil and farmland.name or nil
            if (rawName == nil or rawName == "") and field ~= nil then rawName = field.name end
            local displayName
            if rawName == nil or rawName == "" or tonumber(rawName) ~= nil then
                local label = rawName ~= nil and rawName ~= "" and rawName or tostring(farmlandId)
                displayName = prefix .. " " .. label
            else
                displayName = rawName
            end
            local areaHa = getRotationAreaHa(farmland, field)
            table.insert(result, { farmlandId = farmlandId, name = displayName, areaHa = areaHa })
        end
    end

    table.sort(result, function(a, b)
        local na = tonumber(tostring(a.name):match("%d+$"))
        local nb = tonumber(tostring(b.name):match("%d+$"))
        if na ~= nil and nb ~= nil then return na < nb end
        return tostring(a.name) < tostring(b.name)
    end)

    return result
end

---Fresh client-safe FieldState sampled at the field centre.
-- @param integer farmlandId
-- @return table fieldState, or nil
function RealisticCropRotationManager:sampleFieldState(farmlandId)
    local field = self:getFieldByFarmlandId(farmlandId)
    return sampleFieldStateAtField(field)
end

---Vanilla lime level (LIME_LEVEL) for the no-PF fallback.
-- @param integer farmlandId
-- @return integer level
-- @return integer maxLevel
function RealisticCropRotationManager:getCurrentLimeLevel(farmlandId)
    local fieldState = self:sampleFieldState(farmlandId)
    local limeLevel = fieldState ~= nil and fieldState.limeLevel or 0

    local maxLevel = nil
    if g_fieldManager ~= nil then
        maxLevel = tonumber(g_fieldManager.limeLevelMaxValue)
    end
    if maxLevel == nil and g_currentMission ~= nil and g_currentMission.fieldGroundSystem ~= nil
        and FieldDensityMap ~= nil and FieldDensityMap.LIME_LEVEL ~= nil
        and type(g_currentMission.fieldGroundSystem.getMaxValue) == "function" then
        local ok, value = pcall(g_currentMission.fieldGroundSystem.getMaxValue,
            g_currentMission.fieldGroundSystem, FieldDensityMap.LIME_LEVEL)
        if ok then maxLevel = tonumber(value) end
    end

    limeLevel = math.max(0, math.floor((tonumber(limeLevel) or 0) + 0.5))
    maxLevel = math.max(1, math.floor((tonumber(maxLevel) or 1) + 0.5))
    return math.min(limeLevel, maxLevel), maxLevel
end

---Vanilla fertilisation level (SPRAY_LEVEL) for the no-PF fallback.
-- @param integer farmlandId
-- @return integer level
-- @return integer maxLevel
function RealisticCropRotationManager:getCurrentNitrogenLevel(farmlandId)
    local fieldState = self:sampleFieldState(farmlandId)
    local sprayLevel = fieldState ~= nil and fieldState.sprayLevel or 0

    local maxLevel = nil
    if g_fieldManager ~= nil then
        maxLevel = tonumber(g_fieldManager.sprayLevelMaxValue)
    end
    if maxLevel == nil and g_currentMission ~= nil and g_currentMission.fieldGroundSystem ~= nil
        and FieldDensityMap ~= nil and FieldDensityMap.SPRAY_LEVEL ~= nil
        and type(g_currentMission.fieldGroundSystem.getMaxValue) == "function" then
        local ok, value = pcall(g_currentMission.fieldGroundSystem.getMaxValue,
            g_currentMission.fieldGroundSystem, FieldDensityMap.SPRAY_LEVEL)
        if ok then maxLevel = tonumber(value) end
    end

    sprayLevel = math.max(0, math.floor((tonumber(sprayLevel) or 0) + 0.5))
    maxLevel = math.max(1, math.floor((tonumber(maxLevel) or 1) + 0.5))
    return math.min(sprayLevel, maxLevel), maxLevel
end

-- Precision Farming soil reads (nitrogen + pH); vanilla fallback otherwise.

---Builds an { x, z } sample grid over the field bbox, masked to this farmland's ground so neighbours never leak in.
-- @param table field
-- @param integer farmlandId
-- @return table points, or nil when no point is on the farmland
function RealisticCropRotationManager:buildFieldSampleGrid(field, farmlandId, customSteps)
    if field == nil then return nil end
    if type(field.posX) ~= "number" or type(field.posZ) ~= "number" then return nil end

    -- Real field bounding box (covers non-square fields); equal-area square is a fallback.
    local minX, maxX, minZ, maxZ = fieldPolygonBounds(field)
    if minX == nil then
        local areaHa = getFieldAreaHa(field)
        if areaHa <= 0 then areaHa = 1 end
        local half = math.sqrt(areaHa * 10000) * 0.5
        minX, maxX = field.posX - half, field.posX + half
        minZ, maxZ = field.posZ - half, field.posZ + half
    end

    local steps = math.max(2, math.floor(tonumber(customSteps) or FIELD_SCAN_STEPS))
    local stepX = (steps > 1) and ((maxX - minX) / (steps - 1)) or 0
    local stepZ = (steps > 1) and ((maxZ - minZ) / (steps - 1)) or 0

    local terrainDetailId = g_currentMission ~= nil and g_currentMission.terrainDetailId or nil
    local canMask = terrainDetailId ~= nil and getDensityAtWorldPos ~= nil
    local fm = g_farmlandManager
    local canFarmland = farmlandId ~= nil and fm ~= nil
        and type(fm.getFarmlandIdAtWorldPosition) == "function"

    local points = {}
    for i = 0, steps - 1 do
        for j = 0, steps - 1 do
            local x, z = minX + i * stepX, minZ + j * stepZ
            local onField = not canMask or getDensityAtWorldPos(terrainDetailId, x, 0, z) ~= 0
            if onField and canFarmland then
                onField = fm:getFarmlandIdAtWorldPosition(x, z) == farmlandId
            end
            if onField then
                points[#points + 1] = { x = x, z = z }
            end
        end
    end

    if #points == 0 then return nil end
    return points
end

---Returns a cached PF soil record while still within its TTL.
-- @param integer farmlandId
-- @param string kind Cache slot key
-- @return table values, or nil when missing/expired
function RealisticCropRotationManager:getCachedPFSoil(farmlandId, kind)
    local cache = self.soilPFCache
    if cache == nil then return nil end
    local entry = cache[farmlandId]
    if entry == nil or entry[kind] == nil then return nil end
    local nowMs = tonumber(g_time) or 0
    if (nowMs - (entry[kind .. "Ms"] or 0)) >= SOIL_PF_CACHE_TTL_MS then return nil end
    return entry[kind]
end

---Stores a PF soil record under a cache slot, stamping the time.
-- @param integer farmlandId
-- @param string kind Cache slot key
-- @param table values
function RealisticCropRotationManager:setCachedPFSoil(farmlandId, kind, values)
    if self.soilPFCache == nil then self.soilPFCache = {} end
    local entry = self.soilPFCache[farmlandId]
    if entry == nil then entry = {}; self.soilPFCache[farmlandId] = entry end
    entry[kind] = values
    entry[kind .. "Ms"] = tonumber(g_time) or 0
end

---Resolves PF's g_precisionFarming (sandboxed) via the FS25_precisionFarming env table.
-- @return table precisionFarming, or nil when PF is absent
function RealisticCropRotationManager:getPrecisionFarming()
    if g_precisionFarming ~= nil then return g_precisionFarming end
    local env = FS25_precisionFarming
    if type(env) == "table" then
        if type(env.g_precisionFarming) == "table" then return env.g_precisionFarming end
        if env.nitrogenMap ~= nil or env.pHMap ~= nil then return env end
    end
    return nil
end

---True when a field is not yet soil-analysed (pH reads back the floor value, which a real pH never does). Fail-open.
-- @param table pf precisionFarming
-- @param table field
-- @return boolean locked
function RealisticCropRotationManager:isPFSoilLocked(pf, field)
    if pf == nil or field == nil then return false end
    local phMap = pf.pHMap
    if phMap == nil or type(phMap.getLevelAtWorldPos) ~= "function" then return false end
    if type(field.posX) ~= "number" or type(field.posZ) ~= "number" then return false end
    local ok, phInternal = pcall(phMap.getLevelAtWorldPos, phMap, field.posX, field.posZ)
    if not ok or type(phInternal) ~= "number" then return false end
    return phInternal <= 1
end

---Loads PF crop nitrogen requirements (kg/ha by soil type) from PrecisionFarming.xml at runtime, cached.
-- @return table targets cropName(upper) -> { [soilTypeIndex]=kgPerHa }
function RealisticCropRotationManager:getPFNitrogenTargets()
    if self.pfNitrogenTargets ~= nil then return self.pfNitrogenTargets end
    self.pfNitrogenTargets = {}
    if g_modManager == nil or type(g_modManager.getModByName) ~= "function" then return self.pfNitrogenTargets end
    if loadXMLFile == nil or hasXMLProperty == nil then return self.pfNitrogenTargets end

    local mod = g_modManager:getModByName("FS25_precisionFarming")
    local dir = mod ~= nil and (mod.modDir or mod.modDirectory) or nil
    if dir == nil or dir == "" then return self.pfNitrogenTargets end

    local xmlFile = loadXMLFile("rcrPFRequirements", dir .. "PrecisionFarming.xml")
    if xmlFile == nil or xmlFile == 0 then return self.pfNitrogenTargets end

    local i = 0
    while true do
        local fruitKey = string.format("precisionFarming.nitrogenMap.fruitRequirements.fruitRequirement(%d)", i)
        if not hasXMLProperty(xmlFile, fruitKey) then break end
        local name = getXMLString(xmlFile, fruitKey .. "#fruitTypeName")
        if name ~= nil and name ~= "" then
            local bySoil = {}
            local j = 0
            while true do
                local soilKey = string.format("%s.soil(%d)", fruitKey, j)
                if not hasXMLProperty(xmlFile, soilKey) then break end
                local soilIndex = getXMLInt(xmlFile, soilKey .. "#soilTypeIndex")
                local target = getXMLInt(xmlFile, soilKey .. "#targetLevel")
                if soilIndex ~= nil and target ~= nil then bySoil[soilIndex] = target end
                j = j + 1
            end
            self.pfNitrogenTargets[string.upper(name)] = bySoil
        end
        i = i + 1
    end

    delete(xmlFile)
    return self.pfNitrogenTargets
end

---Single cached PF soil scan: targets come from PF's native per-field soil distribution; actual N (tramlines excluded) and pH are sampled live.
-- @param integer farmlandId
-- @return table record, false when not analysed, or nil when PF is absent
function RealisticCropRotationManager:scanFieldSoil(farmlandId)
    local pf = self:getPrecisionFarming()
    if pf == nil then return nil end
    local nMap, phMap = pf.nitrogenMap, pf.pHMap
    if nMap == nil and phMap == nil then return nil end

    local n = tonumber(farmlandId)
    if n == nil then return nil end

    local cached = self:getCachedPFSoil(n, "soil")
    if cached ~= nil then return cached end

    local field = self:getFieldByFarmlandId(n)
    if self:isPFSoilLocked(pf, field) then return false end

    local points = self:buildFieldSampleGrid(field, n)
    if points == nil then return nil end

    -- Capabilities, resolved once.
    local nCanLevel  = nMap ~= nil and type(nMap.getLevelAtWorldPos) == "function"
        and type(nMap.getNitrogenValueFromInternalValue) == "function"
    local phCanLevel = phMap ~= nil and type(phMap.getLevelAtWorldPos) == "function"
        and type(phMap.getPhValueFromInternalValue) == "function"
    local phCanOptimal = phMap ~= nil and type(phMap.getOptimalPHValueForSoilTypeIndex) == "function"

    local phMaxInternal = (phMap ~= nil and tonumber(phMap.maxValue)) or 31
    local function phConv(level)
        return tonumber(phMap:getPhValueFromInternalValue(math.max(0, math.min(level, phMaxInternal))))
    end

    -- Targets are soil-type properties: weight them by PF's native per-field soil distribution
    -- (fraction of each soil type over the cultivable surface) instead of sampling a grid.
    local farmland = getFarmlandById(n)
    local soilDist = farmland ~= nil and farmland.soilDistribution or nil

    -- Besoin azote: crop's per-soil requirement (PF fruitRequirements), distribution-weighted.
    local cropName, activeFruitTypeIndex = self:getActiveCropInfo(n)
    local nTarget = nil
    if soilDist ~= nil and cropName ~= nil then
        local nReq = self:getPFNitrogenTargets()[string.upper(tostring(cropName))]
        if nReq ~= nil then
            local sum, w = 0, 0
            for i = 1, #soilDist do
                local frac = soilDist[i]
                if frac ~= nil and frac > 0 and nReq[i] ~= nil then
                    sum = sum + frac * nReq[i]; w = w + frac
                end
            end
            if w > 0 then nTarget = math.floor(sum / w + 0.5) end
        end
    end

    -- pH optimal: each soil type's optimal pH, distribution-weighted (independent of the crop).
    local phTarget = nil
    if soilDist ~= nil and phCanOptimal then
        local sum, w = 0, 0
        for i = 1, #soilDist do
            local frac = soilDist[i]
            if frac ~= nil and frac > 0 then
                local opt = phMap:getOptimalPHValueForSoilTypeIndex(i)
                if type(opt) == "number" and opt > 0 then
                    if opt > 9 then opt = phConv(opt) end
                    if type(opt) == "number" then sum = sum + frac * opt; w = w + frac end
                end
            end
        end
        if w > 0 then phTarget = sum / w end
    end

    -- Actual state is dynamic -> sample it. Current pH is a soil property (read over all ground).
    -- Available N belongs to the crop: keep only pixels deep in the crop -- a crop pixel bordering a
    -- tramline reads low (coarse N map smears the unfertilised track in), so exclude it.
    local TRAMLINE_MARGIN = 2.5
    local nActSum, nActCnt, nCropSum, nCropCnt, phActSum, phActCnt = 0, 0, 0, 0, 0, 0
    local ok = pcall(function()
        for _, p in ipairs(points) do
            if phCanLevel then
                local level = phMap:getLevelAtWorldPos(p.x, p.z)
                if type(level) == "number" then phActSum = phActSum + level; phActCnt = phActCnt + 1 end
            end
            if nCanLevel and (activeFruitTypeIndex == nil
                or getFruitTypeIndexAtWorldPos(p.x, p.z) == activeFruitTypeIndex) then
                local level = nMap:getLevelAtWorldPos(p.x, p.z)
                if type(level) == "number" then
                    nCropSum = nCropSum + level; nCropCnt = nCropCnt + 1
                    local m = TRAMLINE_MARGIN
                    if activeFruitTypeIndex == nil
                        or (getFruitTypeIndexAtWorldPos(p.x + m, p.z) ~= nil
                            and getFruitTypeIndexAtWorldPos(p.x - m, p.z) ~= nil
                            and getFruitTypeIndexAtWorldPos(p.x, p.z + m) ~= nil
                            and getFruitTypeIndexAtWorldPos(p.x, p.z - m) ~= nil) then
                        nActSum = nActSum + level; nActCnt = nActCnt + 1
                    end
                end
            end
        end
    end)
    if not ok then return nil end
    -- No deep-crop pixels (tiny or fully-tramlined field): fall back to the whole cropped area.
    if nActCnt == 0 then nActSum, nActCnt = nCropSum, nCropCnt end

    -- Precise averages (no PF-legend snap) so the gauge fills exactly to the requirement.
    local rec = {}
    if nCanLevel and nActCnt > 0 then
        local nMaxInternal = tonumber(nMap.maxValue) or 45
        local function nConv(level)
            return tonumber(nMap:getNitrogenValueFromInternalValue(math.max(0, math.min(level, nMaxInternal))))
        end
        rec.nActual = nConv(nActSum / nActCnt)
        rec.nTarget = nTarget
        rec.nMin, rec.nMax = nConv(0) or 0, nConv(nMaxInternal) or 0
    end
    if phCanLevel and phActCnt > 0 then
        rec.phActual = phConv(phActSum / phActCnt)
        rec.phTarget = phTarget
        rec.phMin, rec.phMax = phConv(0) or 0, phConv(phMaxInternal) or 0
    end

    self:setCachedPFSoil(n, "soil", rec)
    return rec
end

---PF nitrogen (kg/ha): field-average available N + crop requirement.
-- @param integer farmlandId
-- @return number actual, false when not analysed, or nil when no PF (vanilla fallback)
-- @return number target Crop requirement, or nil when no crop
-- @return number min
-- @return number max
function RealisticCropRotationManager:getNitrogenLevel(farmlandId)
    local rec = self:scanFieldSoil(farmlandId)
    if rec == nil or rec == false then return rec end
    if rec.nActual == nil then return nil end
    return rec.nActual, rec.nTarget, rec.nMin, rec.nMax
end

---PF soil pH: field-average real pH + soil-type optimal.
-- @param integer farmlandId
-- @return number actual, false when not analysed, or nil when no PF (vanilla fallback)
-- @return number target Optimal pH
-- @return number min
-- @return number max
function RealisticCropRotationManager:getPHLevel(farmlandId)
    local rec = self:scanFieldSoil(farmlandId)
    if rec == nil or rec == false then return rec end
    if rec.phActual == nil then return nil end
    return rec.phActual, rec.phTarget, rec.phMin, rec.phMax
end

---Localised growth-tier label, matching MapOverlayGenerator.buildGrowthStateMapOverlay.
-- @param table fruitType
-- @param integer growthState
-- @return string label, or nil
function RealisticCropRotationManager.getGrowthTierText(fruitType, growthState)
    if fruitType == nil then return nil end
    growthState = tonumber(growthState) or 0
    if growthState <= 0 then return nil end
    if g_i18n == nil or g_i18n.getText == nil then return nil end

    if fruitType.witheredState ~= nil and growthState == tonumber(fruitType.witheredState) then
        return g_i18n:getText("ui_growthMapWithered")
    end
    if type(fruitType.cutStates) == "table" and fruitType.cutStates[growthState] then
        return g_i18n:getText("ui_growthMapCut")
    end

    local minHarvest = tonumber(fruitType.minHarvestingGrowthState) or 0
    local maxHarvest = tonumber(fruitType.maxHarvestingGrowthState) or 0
    local minPrep    = tonumber(fruitType.minPreparingGrowthState) or -1
    local maxPrep    = tonumber(fruitType.maxPreparingGrowthState) or -1

    -- Forage-ready states still render as growing unless also harvest-ready.
    if minHarvest > 0 then
        local maxGrowingState = minHarvest - 1
        if minPrep >= 0 then
            maxGrowingState = math.min(maxGrowingState, minPrep - 1)
        end
        if growthState >= 1 and growthState <= maxGrowingState then
            return g_i18n:getText("ui_growthMapGrowing")
        end
    end

    if minPrep >= 0 and growthState >= minPrep and growthState <= maxPrep then
        return g_i18n:getText("ui_growthMapReadyToPrepareForHarvest")
    end
    if minHarvest > 0 and growthState >= minHarvest and growthState <= maxHarvest then
        return g_i18n:getText("ui_growthMapReadyToHarvest")
    end

    return nil
end

---"(X/Y) · <tier>" for active tiers, tier alone for terminal ones.
-- @param table fruitType
-- @param integer growthState
-- @return string text, or nil
function RealisticCropRotationManager.classifyGrowthStage(fruitType, growthState)
    local tierText = RealisticCropRotationManager.getGrowthTierText(fruitType, growthState)
    if tierText == nil then return nil end
    local numbers = RealisticCropRotationManager.getGrowthStageNumbers(fruitType, growthState)
    if numbers == nil then return tierText end
    return string.format("(%s) · %s", numbers, tierText)
end

---"X/Y" native growth-state progress (nil for terminal states). Used by menu card + HUD.
-- @param table fruitType
-- @param integer growthState
-- @return string numbers, or nil
function RealisticCropRotationManager.getGrowthStageNumbers(fruitType, growthState)
    if fruitType == nil then return nil end
    growthState = tonumber(growthState) or 0
    if growthState <= 0 then return nil end

    if fruitType.witheredState ~= nil and growthState == tonumber(fruitType.witheredState) then
        return nil
    end
    if type(fruitType.cutStates) == "table" and fruitType.cutStates[growthState] then
        return nil
    end

    if type(fruitType.growthStateToName) == "table" and fruitType.growthStateToName[growthState] == nil then
        return nil
    end

    local minPreparing = tonumber(fruitType.minPreparingGrowthState) or -1
    local maxPreparing = tonumber(fruitType.maxPreparingGrowthState) or -1
    if minPreparing >= 1 and growthState >= minPreparing and growthState <= maxPreparing then
        return string.format("%d/%d", minPreparing, minPreparing)
    end

    local maxStage = tonumber(fruitType.numGrowthStates) or 0
    local maxHarvest = tonumber(fruitType.maxHarvestingGrowthState) or 0
    if maxHarvest > maxStage then
        maxStage = maxHarvest
    end

    if maxStage <= 0 or growthState > maxStage then
        return nil
    end

    return string.format("%d/%d", growthState, maxStage)
end

---Per-field card info: growth stage + the mirrored base-game weed line.
-- @param integer farmlandId
-- @return table info { growthStageText, weedHeader, weedActionText }, or nil when no crop
function RealisticCropRotationManager:getFieldCropInfo(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return nil end

    local field = self:getFieldByFarmlandId(farmlandId)
    if field == nil or g_fruitTypeManager == nil or FieldState == nil then return nil end
    if type(field.posX) ~= "number" or type(field.posZ) ~= "number" then return nil end

    -- field.fieldState is clobbered on MP clients; sample a fresh one at the field centre.
    local fieldState = FieldState.new()
    if type(fieldState.update) ~= "function" then return nil end
    fieldState:update(field.posX, field.posZ)
    if not fieldState.isValid then return nil end

    local fruitTypeIndex = normalizeFruitTypeIndex(fieldState.fruitTypeIndex)
    if fruitTypeIndex == nil then return nil end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then return nil end

    local growthState = tonumber(fieldState.growthState or fieldState.lastGrowthState) or 0

    -- Mirror the base-game weed line via the real PlayerHUDUpdater:fieldAddWeed.
    fieldState.farmlandId = numericFarmlandId
    local weedHeader, weedValue
    if RealisticCropRotationHud ~= nil and RealisticCropRotationHud.getWeedLineFromGame ~= nil then
        weedHeader, weedValue = RealisticCropRotationHud.getWeedLineFromGame(fieldState)
    end

    return {
        growthStageText = RealisticCropRotationManager.classifyGrowthStage(fruitType, growthState),
        weedHeader      = weedHeader,
        weedActionText  = weedValue,
    }
end
