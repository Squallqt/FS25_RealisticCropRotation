-- Copyright © 2026 Squallqt. All rights reserved.
-- Facade exposed on g_currentMission.fieldRotationManager.
-- Owns Repository + Service and forwards GUI-side reads.
RealisticCropRotationManager = {}
local RealisticCropRotationManager_mt = Class(RealisticCropRotationManager)

-- Active-crop cache TTL on the server.
-- captureCropCandidate calls getActiveCropName from every
-- density-map hook tick. A TTL-based cache (no event invalidation) is the
-- correct shape: the field's growth state does not move on the second/sub-
-- second scale, so a stale read up to TTL is harmless.
local ACTIVE_CROP_CACHE_TTL_MS = 10000

local function isPureClient()
    return g_currentMission ~= nil
        and g_currentMission.getIsServer ~= nil
        and not g_currentMission:getIsServer()
end

local function getPrecisionFarmingInstance()
    if g_precisionFarming ~= nil then return g_precisionFarming end
    if FS25_precisionFarming ~= nil and FS25_precisionFarming.g_precisionFarming ~= nil then
        return FS25_precisionFarming.g_precisionFarming
    end
    if g_currentMission ~= nil and g_currentMission.g_precisionFarming ~= nil then
        return g_currentMission.g_precisionFarming
    end
    return nil
end

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

local function getFieldAreaHa(field)
    if type(field) ~= "table" then return 0 end
    local areaHa = tonumber(field.areaHa) or 0
    if areaHa > 0 then return areaHa end
    local fieldAreaHa = tonumber(field.fieldAreaHa) or 0
    if fieldAreaHa > 0 then return fieldAreaHa end
    return 0
end

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

local function getRotationAreaHa(farmland, field)
    local fieldArea = getFieldAreaHa(field)
    if fieldArea > 0 then return fieldArea end
    return getFarmlandFieldAreaHa(farmland)
end

local function hasUsableRealisticCropRotationArea(farmland, field)
    return getRotationAreaHa(farmland, field) > 0
end

local function getPermanentGrasslandFallbackCropName()
    if g_fruitTypeManager == nil or g_fruitTypeManager.getFruitTypeByName == nil then return nil end
    local fieldGrass = g_fruitTypeManager:getFruitTypeByName("FIELDGRASS")
    if fieldGrass ~= nil and fieldGrass.name ~= nil and fieldGrass.name ~= "" then
        return tostring(fieldGrass.name)
    end
    return nil
end

local function normalizeFruitTypeIndex(fruitTypeIndex)
    local n = tonumber(fruitTypeIndex)
    local unknown = (FruitType ~= nil and FruitType.UNKNOWN) or 0
    if n == nil or n == unknown then return nil end
    return n
end

local function getFruitTypeIndexAtWorldPos(x, z)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then
        return nil, false
    end
    if type(x) ~= "number" or type(z) ~= "number" then
        return nil, false
    end

    local ok, fruitTypeIndex = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
    if not ok then return nil, true end
    return normalizeFruitTypeIndex(fruitTypeIndex), true
end

local function collectFieldDimensionSamples(field, samples)
    if field == nil or getWorldTranslation == nil then return end

    local dimensions = field.fieldDimensions or field.dimensions
    if type(dimensions) ~= "table" then return end

    local offsets = {
        {0.50, 0.50},
        {0.25, 0.25},
        {0.75, 0.25},
        {0.25, 0.75},
        {0.75, 0.75},
    }

    for _, dimension in pairs(dimensions) do
        local startNode = dimension ~= nil and (dimension.start or dimension.startNode) or nil
        local widthNode = dimension ~= nil and (dimension.width or dimension.widthNode) or nil
        local heightNode = dimension ~= nil and (dimension.height or dimension.heightNode) or nil

        if startNode ~= nil and widthNode ~= nil and heightNode ~= nil then
            local okStart, sx, _, sz = pcall(getWorldTranslation, startNode)
            local okWidth, wx, _, wz = pcall(getWorldTranslation, widthNode)
            local okHeight, hx, _, hz = pcall(getWorldTranslation, heightNode)
            if okStart and okWidth and okHeight
                and type(sx) == "number" and type(sz) == "number"
                and type(wx) == "number" and type(wz) == "number"
                and type(hx) == "number" and type(hz) == "number" then
                for _, offset in ipairs(offsets) do
                    local u, v = offset[1], offset[2]
                    table.insert(samples, {
                        x = sx + (wx - sx) * u + (hx - sx) * v,
                        z = sz + (wz - sz) * u + (hz - sz) * v,
                    })
                end
            end
        end
    end
end

local function getFieldFruitTypeIndexFromDensityMap(field)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then
        return nil, false
    end

    local samples = {}
    if field ~= nil and type(field.posX) == "number" and type(field.posZ) == "number" then
        table.insert(samples, { x = field.posX, z = field.posZ })
    end
    collectFieldDimensionSamples(field, samples)

    local sampled = false
    local counts = {}
    for _, sample in ipairs(samples) do
        local fruitTypeIndex, didSample = getFruitTypeIndexAtWorldPos(sample.x, sample.z)
        if didSample then
            sampled = true
            if fruitTypeIndex ~= nil then
                counts[fruitTypeIndex] = (counts[fruitTypeIndex] or 0) + 1
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

    return bestFruitTypeIndex, true
end

local function getFieldFruitTypeIndexFromFieldState(field)
    local fieldState = field ~= nil and field.fieldState or nil
    if fieldState == nil then return nil end

    local fruitTypeIndex = normalizeFruitTypeIndex(fieldState.fruitTypeIndex)
    if fruitTypeIndex == nil then return nil end

    local fruitType = nil
    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByIndex ~= nil then
        fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    end

    if fruitType ~= nil then
        local growthState = tonumber(fieldState.growthState or fieldState.lastGrowthState)
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

    return fruitTypeIndex
end

local function getFieldFruitTypeIndex(field)
    local fruitTypeIndex, sampledDensityMap = getFieldFruitTypeIndexFromDensityMap(field)
    if sampledDensityMap then return fruitTypeIndex end
    if isPureClient() then return nil end
    return getFieldFruitTypeIndexFromFieldState(field)
end

local function getActiveCropNameFromField(field)
    local fruitTypeIndex = getFieldFruitTypeIndex(field)
    if fruitTypeIndex == nil or g_fruitTypeManager == nil then return nil end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil or fruitType.name == nil or fruitType.name == "" then return nil end
    return tostring(fruitType.name)
end

-- Live ground type at the field, read straight from the GROUND_TYPE density map at the same
-- sample points the crop detection uses (getFieldFruitTypeIndexFromDensityMap). This keeps the
-- "worked" status (Cultivé/Labouré/...) as fresh as the crop status, instead of lagging behind the
-- engine's periodic field.fieldState snapshot -- the reason the status did not always appear right
-- after working a field. Mirrors the engine's own per-position read
-- (WheelPhysics: getDensityAtWorldPos + FieldGroundType.getTypeByValue).
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
    collectFieldDimensionSamples(field, samples)
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

-- Resolves the current ground state of a field to a native GIANTS l10n key.
-- Mapping is between FieldGroundType.<NAME> and
-- MapOverlayGenerator.L10N_SYMBOL.GROWTH_MAP_<NAME>, both globally exposed at
-- runtime. The same descriptions are what the in-game map overlay shows
-- (MapOverlayGenerator.lua:628-678 in gameSource).
local function getNativeGroundStateLabel(field)
    if MapOverlayGenerator == nil or MapOverlayGenerator.L10N_SYMBOL == nil
        or g_i18n == nil or type(g_i18n.getText) ~= "function" then
        return nil
    end

    local index = getNativeGroundStateIndex(field)
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

-- =========================================================================
-- Density-map polygon helpers (read-only).
-- =========================================================================

local function getMapMaxInternalValue(map)
    local maxValue = tonumber(map ~= nil and map.maxValue or nil) or 0
    return math.max(0, math.floor(maxValue + 0.5))
end

local function getFieldDensityMapAverage(field, map, converterName)
    if field == nil or map == nil or map.bitVectorMap == nil or map.numChannels == nil then
        return nil, nil, nil
    end
    if DensityMapModifier == nil or DensityMapFilter == nil or DensityValueCompareType == nil then
        return nil, nil, nil
    end

    local polygon = field.densityMapPolygon
    if type(field.getDensityMapPolygon) == "function" then
        local ok, result = pcall(field.getDensityMapPolygon, field)
        if ok and result ~= nil then polygon = result end
    end
    if polygon == nil or polygon.applyToModifier == nil then return nil, nil, nil end

    local modOk, modifier = pcall(DensityMapModifier.new,
        map.bitVectorMap, tonumber(map.firstChannel) or 0, map.numChannels, g_terrainNode)
    if not modOk or modifier == nil then return nil, nil, nil end

    local applyOk = pcall(function() polygon:applyToModifier(modifier) end)
    if not applyOk then return nil, nil, nil end

    local filterOk, filter = pcall(DensityMapFilter.new, modifier)
    if not filterOk or filter == nil then return nil, nil, nil end

    local maxState = getMapMaxInternalValue(map)
    local valueFunc = converterName ~= nil and map[converterName] or nil
    local weightedValue = 0
    local areaTotal = 0

    for state = 0, maxState do
        filter:setValueCompareParams(DensityValueCompareType.EQUAL, state)
        local ok, _, area = pcall(modifier.executeGet, modifier, filter)
        if ok and type(area) == "number" and area > 0 then
            local value = state
            if valueFunc ~= nil then
                local valueOk, converted = pcall(valueFunc, map, state)
                if valueOk and type(converted) == "number" then value = converted end
            end
            weightedValue = weightedValue + value * area
            areaTotal = areaTotal + area
        end
    end

    if areaTotal <= 0 then return nil end
    return weightedValue / areaTotal
end

local function getMapMaxKgHa(nitrogenMap)
    if nitrogenMap == nil or type(nitrogenMap.getNitrogenValueFromInternalValue) ~= "function" then
        return nil
    end
    local maxState = getMapMaxInternalValue(nitrogenMap)
    if maxState <= 0 then return nil end
    local ok, converted = pcall(nitrogenMap.getNitrogenValueFromInternalValue, nitrogenMap, maxState)
    if not ok or type(converted) ~= "number" or converted <= 0 then return nil end
    return converted
end

local function getNitrogenRequirementForFruit(nitrogenMap, fruitTypeIndex)
    if nitrogenMap == nil or fruitTypeIndex == nil then return nil end
    local byIndex = nitrogenMap.fruitTypeIndexToFruitRequirement
    if type(byIndex) == "table" and type(byIndex[fruitTypeIndex]) == "table" then
        return byIndex[fruitTypeIndex]
    end
    local requirements = nitrogenMap.fruitRequirements
    if type(requirements) == "table" then
        for _, req in ipairs(requirements) do
            if type(req) == "table" and tonumber(req.fruitTypeIndex) == fruitTypeIndex then
                return req
            end
        end
    end
    return nil
end

local function getNitrogenTargetKgHa(nitrogenMap, farmland, fruitTypeIndex)
    local requirement = getNitrogenRequirementForFruit(nitrogenMap, fruitTypeIndex)
    if requirement == nil then return nil end
    if type(nitrogenMap.getNitrogenValueFromInternalValue) ~= "function" then return nil end

    local function convert(internalValue)
        local n = tonumber(internalValue)
        if n == nil or n <= 0 then return nil end
        local ok, real = pcall(nitrogenMap.getNitrogenValueFromInternalValue, nitrogenMap, n)
        if ok and type(real) == "number" and real > 0 then return real end
        return nil
    end

    local bySoilType = requirement.bySoilType
    if type(farmland) == "table" and type(farmland.soilDistribution) == "table" and type(bySoilType) == "table" then
        local weightedTarget = 0
        local weightTotal = 0
        for soilTypeIndex, weight in pairs(farmland.soilDistribution) do
            local numericSoilTypeIndex = tonumber(soilTypeIndex)
            local numericWeight = tonumber(weight)
            if numericSoilTypeIndex ~= nil and numericWeight ~= nil and numericWeight > 0 then
                local soilSettings = bySoilType[numericSoilTypeIndex]
                if soilSettings == nil then
                    for _, entry in pairs(bySoilType) do
                        if type(entry) == "table" and tonumber(entry.soilTypeIndex) == numericSoilTypeIndex then
                            soilSettings = entry
                            break
                        end
                    end
                end
                if type(soilSettings) == "table" then
                    local target = convert(soilSettings.targetLevel)
                    if target ~= nil then
                        weightedTarget = weightedTarget + target * numericWeight
                        weightTotal = weightTotal + numericWeight
                    end
                end
            end
        end
        if weightTotal > 0 then return weightedTarget / weightTotal end
    end

    return convert(requirement.targetLevel)
end

-- =========================================================================
-- Construction / lifecycle.
-- =========================================================================

function RealisticCropRotationManager.new()
    local self = setmetatable({}, RealisticCropRotationManager_mt)
    self.repository = RealisticCropRotationRepository.new()
    self.service = RealisticCropRotationService.new(self.repository)
    self.activeCropNameCache = {}
    self.isInitialized = false
    return self
end

function RealisticCropRotationManager:initialize()
    if self.isInitialized then return end
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.isInitialized = true
end

function RealisticCropRotationManager:cleanup()
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.isInitialized = false
end

function RealisticCropRotationManager:saveToXML(savegamePath)
    return self.repository:saveToXML(savegamePath)
end

function RealisticCropRotationManager:loadFromXML(savegamePath)
    self.repository:loadFromXML(savegamePath)
end

-- =========================================================================
-- GUI / runtime queries.
-- =========================================================================

function RealisticCropRotationManager:getHistory(farmlandId)
    return self.repository:getHistory(farmlandId)
end

function RealisticCropRotationManager:getAllHistory()
    return self.repository:getAllHistory()
end

function RealisticCropRotationManager:getAppliedResidue(farmlandId)
    if farmlandId == nil or self.repository == nil or type(self.repository.getAppliedResidue) ~= "function" then
        return nil
    end

    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return nil end

    local entry = self.repository:getAppliedResidue(numericFarmlandId)
    if entry == nil or entry.crop == nil or entry.crop == "" then return nil end

    return {
        crop = entry.crop,
        stateChange = tonumber(entry.stateChange) or 0,
        sprayLevel = tonumber(entry.sprayLevel) or 0,
        unit = tostring(entry.unit or "STATE"),
    }
end

function RealisticCropRotationManager:getRotationPlan(farmlandId)
    return self.repository:getPlan(farmlandId)
end

function RealisticCropRotationManager:getAllRotationPlans()
    return self.repository:getAllPlans()
end

function RealisticCropRotationManager:setRotationPlanYear(farmlandId, yearIdx, family)
    local n = tonumber(farmlandId)
    local y = tonumber(yearIdx)
    if n == nil or n <= 0 or y == nil or y < 1 or y > 4 then return false end
    self.repository:setPlanYear(n, y, family)
    return true
end

function RealisticCropRotationManager:clearRotationPlan(farmlandId)
    if self.repository == nil or type(self.repository.clearPlan) ~= "function" then return false end
    return self.repository:clearPlan(farmlandId)
end

function RealisticCropRotationManager:getCurrentFarmId()
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then return g_localPlayer.farmId end
    if g_currentMission ~= nil and type(g_currentMission.getFarmId) == "function" then
        return g_currentMission:getFarmId()
    end
    return nil
end

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

-- Returns the currently active crop name on a farmland.
-- Pure clients use density-map sampling only; fieldState fallback is server-only.
function RealisticCropRotationManager:getActiveCropName(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil then return nil end

    local cache = self.activeCropNameCache
    local nowMs = tonumber(g_time) or 0
    if cache ~= nil then
        local entry = cache[numericFarmlandId]
        if entry ~= nil and (nowMs - (entry.tMs or 0)) < ACTIVE_CROP_CACHE_TTL_MS then
            return entry.name
        end
    end

    local field = self:getFieldByFarmlandId(numericFarmlandId)
    local resolved = getActiveCropNameFromField(field)
    if resolved == nil then
        local farmland = getFarmlandById(numericFarmlandId)
        if field == nil and getFarmlandFieldAreaHa(farmland) > 0 then
            -- Player-converted permanent grassland: no Field object/fieldState
            -- but still valid rotation land. Show FIELDGRASS as the natural
            -- meadow crop, not Fallow.
            resolved = getPermanentGrasslandFallbackCropName()
        end
    end

    if cache ~= nil then
        cache[numericFarmlandId] = { name = resolved, tMs = nowMs }
    end
    return resolved
end

function RealisticCropRotationManager:getActiveCropFruitTypeIndex(farmlandId)
    return getFieldFruitTypeIndex(self:getFieldByFarmlandId(farmlandId))
end

function RealisticCropRotationManager:invalidateActiveCropCache(farmlandId)
    if self.activeCropNameCache == nil then return end
    local n = tonumber(farmlandId)
    if n == nil then return end
    self.activeCropNameCache[n] = nil
end

function RealisticCropRotationManager:recordCropChangeFromHook(changedArea, cropCandidate, nextActiveCropName)
    if self.service == nil or cropCandidate == nil then return false end

    local farmlandId = tonumber(cropCandidate.farmlandId)
    if farmlandId == nil or farmlandId <= 0 then return false end

    local changed = self.service:onCropChangeArea(
        farmlandId,
        cropCandidate.fruitTypeIndex,
        cropCandidate.activeCropName,
        changedArea,
        nextActiveCropName)
    if changed then
        self:invalidateActiveCropCache(farmlandId)
    end
    return changed
end

function RealisticCropRotationManager:reconcileActiveCropForFarmland(farmlandId)
    if self.service == nil then return false end
    if isPureClient() then return false end

    local currentCropName = self:getActiveCropName(farmlandId)
    local changed = self.service:reconcileActiveCrop(farmlandId, currentCropName)
    if changed then
        self:invalidateActiveCropCache(farmlandId)
    end
    return changed
end

-- Returns the native ground state label (Cultivé/Labouré/Lit de semences/...)
-- when no active crop is growing on the farmland. nil when there IS a crop
-- (caller should display the crop) or when the ground is in NONE state.
function RealisticCropRotationManager:getCurrentGroundStateLabel(farmlandId)
    if isPureClient() then return nil end
    local field = self:getFieldByFarmlandId(farmlandId)
    return getNativeGroundStateLabel(field)
end

function RealisticCropRotationManager:getOwnedFarmlands()
    local result = {}
    local farmId = self:getCurrentFarmId()
    if farmId == nil or g_farmlandManager == nil then return result end

    local farmlandIds = {}
    if type(g_farmlandManager.getOwnedFarmlandIdsByFarmId) == "function" then
        farmlandIds = g_farmlandManager:getOwnedFarmlandIdsByFarmId(farmId) or {}
    elseif type(g_farmlandManager.getFarmlands) == "function" then
        for farmlandId, farmland in pairs(g_farmlandManager:getFarmlands() or {}) do
            local owner = nil
            if type(g_farmlandManager.getFarmlandOwner) == "function" then
                owner = g_farmlandManager:getFarmlandOwner(farmlandId)
            elseif farmland ~= nil then
                owner = farmland.farmId
            end
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

function RealisticCropRotationManager:getCurrentSprayLevel(farmlandId)
    local field = self:getFieldByFarmlandId(farmlandId)
    local sprayLevel = field ~= nil and field.fieldState ~= nil and field.fieldState.sprayLevel or 0
    sprayLevel = tonumber(sprayLevel) or 0
    return math.max(0, math.min(2, math.floor(sprayLevel + 0.5)))
end

function RealisticCropRotationManager:getCurrentLimeLevel(farmlandId)
    local field = self:getFieldByFarmlandId(farmlandId)
    local limeLevel = field ~= nil and field.fieldState ~= nil and field.fieldState.limeLevel or 0

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

-- Returns the localised growth-tier label string for the current foliage
-- state, matching what the base game prints on the minimap growth overlay
-- legend (MapOverlayGenerator.buildGrowthStateMapOverlay). Used both for the
-- card and to detect the base-game pedestrian HUD's "Croissance:" line so
-- we can inject the numeric progress into it instead of adding a duplicate.
-- Returns nil when no displayable tier applies (no fruit / no i18n).
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

    -- Match MapOverlayGenerator.buildGrowthStateMapOverlay: forage-ready
    -- states are still rendered as growing unless they are also harvest-ready.
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

-- Composes the card-side growth display string for the current state:
--   - active tiers get "(X/Y) · <tier>" with X/Y from getGrowthStageNumbers
--   - terminal tiers (Withered / Cut) get the tier label alone, since the
--     numeric progress is meaningless once the crop cycle is over
--   - nil when no displayable tier applies
function RealisticCropRotationManager.classifyGrowthStage(fruitType, growthState)
    local tierText = RealisticCropRotationManager.getGrowthTierText(fruitType, growthState)
    if tierText == nil then return nil end
    local numbers = RealisticCropRotationManager.getGrowthStageNumbers(fruitType, growthState)
    if numbers == nil then return tierText end
    return string.format("(%s) · %s", numbers, tierText)
end

-- Returns just the "X/Y" numeric progress for the current growth state, or
-- nil when the state is terminal (withered / cut) or numbers are not
-- meaningful. Used by the pedestrian HUD which already gets the tier label
-- from the base game field-info line ("Croissance: <tier>"), so the mod only
-- needs to surface the numeric progress to avoid duplicating wording.
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

    -- numFoliageStates includes terminal foliage variants (cut/withered/tracks).
    -- The visible crop cycle ends at the engine's max harvest-ready state.
    local total = tonumber(fruitType.maxHarvestingGrowthState) or 0
    if total <= 0 then
        total = tonumber(fruitType.numGrowthStates) or 0
    end
    if total <= 0 or growthState > total then return nil end

    return string.format("%d/%d", growthState, total)
end

-- Per-weedState lookup tables for the runtime mapping observed in the base
-- game pedestrian field-info HUD (weedState 0..9). These describe weed only;
-- the crop's foliage state then constrains which mechanical tool is actually
-- usable (see classifyWeedAction).
RealisticCropRotationManager.WEED_STAGE_KEY = {
    [1] = "rcr_weed_stage_sprout",
    [2] = "rcr_weed_stage_sprout",
    [3] = "rcr_weed_stage_small",
    [4] = "rcr_weed_stage_medium",
    [5] = "rcr_weed_stage_large",
    [6] = "rcr_weed_stage_partial",
}

RealisticCropRotationManager.WEED_IDEAL_TOOL = {
    [1] = "weeder", [2] = "weeder", [3] = "weeder",
    [4] = "hoe",
    [5] = "herbicide",
    [6] = "hoe",
}

-- Compose the weed action label by combining the engine weedState with the
-- crop's mechanical-removal windows. The output mirrors the format the base
-- game uses on the pedestrian field-info HUD ("(<stage>) · <tool>").
--
-- Step 1 — weedState → ideal tool (from runtime observation, light→heavy):
--   0       → nothing to do
--   1..3    → Weeder      (sprout / sprout / small)
--   4       → Hoe         (medium)
--   5       → Herbicide   (large — past any mechanical pass)
--   6       → Hoe         (partial / wounded remnant after treatment)
--   7..9    → nothing to do (withered weed)
--
-- Step 2 — crop constraint: the ideal mechanical tool is only usable when the
-- crop's current foliage state declares the matching flag (allowsWeeding /
-- allowsHoeing in the fruit XML, condensed by FruitTypeDesc into
-- minWeederState/maxWeederState and minWeederHoeState/maxWeederHoeState).
-- When the crop has grown past the relevant window, the recommendation
-- escalates to herbicide. This applies to any crop the player hovers over.
--
-- Returns the final composed display string, or nil when there is nothing to
-- show (no weed / withered weed / no fruit / no i18n).
function RealisticCropRotationManager.classifyWeedAction(fruitType, growthState, weedState)
    weedState = tonumber(weedState) or 0
    if weedState <= 0 or weedState >= 7 then return nil end
    if fruitType == nil then return nil end
    growthState = tonumber(growthState) or 0
    if growthState <= 0 then return nil end
    if g_i18n == nil or g_i18n.getText == nil then return nil end

    local stageKey  = RealisticCropRotationManager.WEED_STAGE_KEY[weedState]
    local idealTool = RealisticCropRotationManager.WEED_IDEAL_TOOL[weedState]
    if stageKey == nil or idealTool == nil then return nil end

    -- For weeder-ideal states, try weeder first, then hoe as fallback before
    -- escalating to herbicide. This covers crops where the weeder window is
    -- narrower than the hoe window (e.g. onion state 4 is outside weeder but
    -- still inside hoe window — base game confirms "Houe" for that case).
    local minWeed = tonumber(fruitType.minWeederState) or 0
    local maxWeed = tonumber(fruitType.maxWeederState) or 0
    local minHoe  = tonumber(fruitType.minWeederHoeState) or 0
    local maxHoe  = tonumber(fruitType.maxWeederHoeState) or 0

    local toolKey
    if idealTool == "weeder" then
        if minWeed > 0 and growthState >= minWeed and growthState <= maxWeed then
            toolKey = "rcr_weed_tool_weeder"
        elseif minHoe > 0 and growthState >= minHoe and growthState <= maxHoe then
            toolKey = "rcr_weed_tool_hoe"
        else
            toolKey = "rcr_weed_tool_herbicide"
        end
    elseif idealTool == "hoe" then
        if minHoe > 0 and growthState >= minHoe and growthState <= maxHoe then
            toolKey = "rcr_weed_tool_hoe"
        else
            toolKey = "rcr_weed_tool_herbicide"
        end
    else
        toolKey = "rcr_weed_tool_herbicide"
    end

    return string.format("(%s) · %s",
        g_i18n:getText(stageKey), g_i18n:getText(toolKey))
end

-- Cache populated by the pedestrian HUD hook (fieldAddFarmland wrapper) when
-- the player walks near a field. The base game runs fieldAddWeed internally
-- with its own per-crop tool logic; we intercept the addLine call to capture
-- exactly what it computed. Card prefers this over classifyWeedAction.
RealisticCropRotationManager.weedCache = {}

function RealisticCropRotationManager.setWeedFromHUD(farmlandId, stage, tool)
    RealisticCropRotationManager.weedCache[tonumber(farmlandId)] = { stage = stage, tool = tool }
end

-- Returns crop info for a farmland in a single density-map sample:
--   { growthStageText, weedActionText }              -- crop present, not harvestable
--   { growthStageText, weedActionText, totalLiters } -- crop present and harvestable
--   nil                                              -- no crop / not resolvable
-- growthStageText is the composed display string for the growth tier (with
-- optional "(X/Y) ·" prefix for active tiers); weedActionText is the composed
-- weed action label "(<stage>) · <tool>". Either may be nil when nothing
-- displayable applies for that field.
function RealisticCropRotationManager:getFieldCropInfo(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return nil end

    local field = self:getFieldByFarmlandId(farmlandId)
    if field == nil or g_fruitTypeManager == nil or FieldState == nil then return nil end
    if type(field.posX) ~= "number" or type(field.posZ) ~= "number" then return nil end

    -- field.fieldState is forced to groundType=CULTIVATED/fruitTypeIndex=UNKNOWN
    -- on MP clients by the engine (FieldManager.lua:292-302). Build a fresh
    -- FieldState and sample density maps at the field center — this is the
    -- engine pattern used in FieldManager.lua:327-343 (debug overlay path,
    -- proven client-safe). The same shape of FieldState is what
    -- PlayerHUDUpdater.fieldAddFarmland receives as 'data'. One sample feeds
    -- both the growth stage and the yield estimate.
    local fieldState = FieldState.new()
    if type(fieldState.update) ~= "function" then return nil end
    fieldState:update(field.posX, field.posZ)
    if not fieldState.isValid then return nil end

    local fruitTypeIndex = normalizeFruitTypeIndex(fieldState.fruitTypeIndex)
    if fruitTypeIndex == nil then return nil end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then return nil end

    local growthState = tonumber(fieldState.growthState or fieldState.lastGrowthState) or 0
    local weedState = tonumber(fieldState.weedState) or 0

    local cachedWeed = RealisticCropRotationManager.weedCache[numericFarmlandId]
    local weedText
    if cachedWeed ~= nil then
        weedText = string.format("(%s) · %s", cachedWeed.stage, cachedWeed.tool)
    else
        weedText = RealisticCropRotationManager.classifyWeedAction(fruitType, growthState, weedState)
    end

    local info = {
        growthStageText = RealisticCropRotationManager.classifyGrowthStage(fruitType, growthState),
        weedActionText  = weedText,
    }

    local minHarvest = tonumber(fruitType.minHarvestingGrowthState) or 0
    local maxHarvest = tonumber(fruitType.maxHarvestingGrowthState) or 0
    local minForage = tonumber(fruitType.minForageGrowthState) or 0
    local maxForage = tonumber(fruitType.maxForageGrowthState) or 0

    local isHarvestReady = minHarvest > 0 and growthState >= minHarvest and growthState <= maxHarvest
    local isForageReady = minForage > 0 and growthState >= minForage and growthState <= maxForage
    if not isHarvestReady and not isForageReady then return info end

    if type(fieldState.getHarvestScaleMultiplier) ~= "function" then return info end
    local ok, harvestMultiplier = pcall(fieldState.getHarvestScaleMultiplier, fieldState)
    harvestMultiplier = ok and tonumber(harvestMultiplier) or nil
    if harvestMultiplier == nil or harvestMultiplier < 0 then return info end

    local areaHa = tonumber(field.areaHa) or 0
    if areaHa <= 0 then return info end

    -- Base density: windrow litres when foraging only (silage/mowing), grain
    -- litres otherwise. literPerSqm is the engine's per-sqm yield for the crop.
    local useForage = isForageReady and not isHarvestReady and fruitType.windrowFillType ~= nil
    local literPerSqm = tonumber(fruitType.literPerSqm) or 0
    if useForage then
        literPerSqm = tonumber(fruitType.windrowLiterPerSqm) or literPerSqm
    end
    if literPerSqm <= 0 then return info end

    -- Per-growth-state yield scale (FruitTypeDesc.lua:296, XML #yieldScale).
    -- This is why the same crop yields different litres at green-plant vs full
    -- maturity. Defaults to 1 when the state defines no scale.
    local yieldScale = 1
    if type(fruitType.yieldScales) == "table"
        and type(fruitType.yieldScales[growthState]) == "number" then
        yieldScale = fruitType.yieldScales[growthState]
    end

    local totalLiters = literPerSqm * areaHa * 10000 * harvestMultiplier * yieldScale
    if totalLiters <= 0 then return info end

    info.totalLiters = totalLiters
    return info
end

-- Returns:
--   actualKgHa : average N in kg/ha over the field polygon (nil if not resolvable)
--   targetKgHa : nitrogen target for the active crop on this soil (nil if no active crop)
--   mapMaxKgHa : map's global max value in kg/ha, used by UI when no crop target exists.
function RealisticCropRotationManager:getNitrogenLevel(farmlandId)
    local precisionFarming = getPrecisionFarmingInstance()
    local nitrogenMap = precisionFarming ~= nil and precisionFarming.nitrogenMap or nil
    if nitrogenMap == nil then return nil end

    local field = self:getFieldByFarmlandId(farmlandId)
    local farmland = getFarmlandById(farmlandId)
    local activeFruitIndex = self:getActiveCropFruitTypeIndex(farmlandId)

    local mapMaxKgHa = getMapMaxKgHa(nitrogenMap)
    local targetKgHa = activeFruitIndex ~= nil
        and getNitrogenTargetKgHa(nitrogenMap, farmland, activeFruitIndex)
        or nil

    local actualKgHa = getFieldDensityMapAverage(field, nitrogenMap, "getNitrogenValueFromInternalValue")
    if actualKgHa == nil and field ~= nil and field.posX ~= nil and field.posZ ~= nil
        and type(nitrogenMap.getLevelAtWorldPos) == "function" then
        local levelOk, level = pcall(nitrogenMap.getLevelAtWorldPos, nitrogenMap, field.posX, field.posZ)
        if levelOk and level ~= nil and type(nitrogenMap.getNitrogenValueFromInternalValue) == "function" then
            local convertOk, value = pcall(nitrogenMap.getNitrogenValueFromInternalValue, nitrogenMap, level)
            if convertOk and type(value) == "number" then actualKgHa = value end
        end
    end

    return actualKgHa, targetKgHa, mapMaxKgHa
end

function RealisticCropRotationManager:getPHLevel(farmlandId)
    local precisionFarming = getPrecisionFarmingInstance()
    local pHMap = precisionFarming ~= nil and precisionFarming.pHMap or nil
    if pHMap == nil or type(pHMap.getPhValueFromInternalValue) ~= "function" then return nil end

    local field = self:getFieldByFarmlandId(farmlandId)

    local minPH = nil
    local maxPH = nil
    local minOk, convertedMin = pcall(pHMap.getPhValueFromInternalValue, pHMap, 0)
    if minOk and type(convertedMin) == "number" then minPH = convertedMin end
    local maxOk, convertedMax = pcall(pHMap.getPhValueFromInternalValue,
        pHMap, getMapMaxInternalValue(pHMap))
    if maxOk and type(convertedMax) == "number" then maxPH = convertedMax end

    local actualPH = getFieldDensityMapAverage(field, pHMap, "getPhValueFromInternalValue")
    if actualPH == nil and field ~= nil and field.posX ~= nil and field.posZ ~= nil
        and type(pHMap.getLevelAtWorldPos) == "function" then
        local ok, level = pcall(pHMap.getLevelAtWorldPos, pHMap, field.posX, field.posZ)
        if ok then
            local valueOk, value = pcall(pHMap.getPhValueFromInternalValue, pHMap, level)
            if valueOk and type(value) == "number" then actualPH = value end
        end
    end

    local targetPH = nil
    if type(pHMap.getOptimalPHValueForSoilTypeIndex) == "function" and g_farmlandManager ~= nil then
        local farmland = getFarmlandById(farmlandId)
        if farmland ~= nil and type(farmland.soilDistribution) == "table" then
            local weightedTarget = 0
            local weightTotal = 0
            for soilTypeIndex, weight in pairs(farmland.soilDistribution) do
                if type(soilTypeIndex) == "number" and type(weight) == "number" and weight > 0 then
                    local ok, optimal = pcall(pHMap.getOptimalPHValueForSoilTypeIndex, pHMap, soilTypeIndex)
                    if ok and type(optimal) == "number" then
                        local target = optimal
                        local convOk, conv = pcall(pHMap.getPhValueFromInternalValue, pHMap, optimal)
                        if convOk and type(conv) == "number" then target = conv end
                        weightedTarget = weightedTarget + target * weight
                        weightTotal = weightTotal + weight
                    end
                end
            end
            if weightTotal > 0 then targetPH = weightedTarget / weightTotal end
        end
    end

    return actualPH, targetPH, minPH, maxPH
end
