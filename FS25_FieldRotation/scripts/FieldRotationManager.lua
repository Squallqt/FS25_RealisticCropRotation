-- Copyright © 2026 Squallqt. All rights reserved.
-- Facade exposed on g_currentMission.fieldRotationManager.
-- Owns Repository + Service and forwards GUI-side reads.
FieldRotationManager = {}
local FieldRotationManager_mt = Class(FieldRotationManager)

-- Active-crop cache TTL on the server.
-- captureFieldRotationTerminationCrop calls getActiveCropName from every
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

-- Precision Farming soil yield potential factor for a farmland.
-- PF multiplies the base crop yield by this factor, which reflects soil quality
-- (AdditionalFieldBuyInfo.lua:414-421: weighted soilMap:getYieldPotentialBy
-- SoilTypeIndex over the farmland soil distribution, clamped to [0, 1.25]).
-- Returns 1.0 when PF is inactive — vanilla yield, no soil bonus.
local function getSoilYieldPotential(farmland)
    if type(farmland) ~= "table" then return 1.0 end

    -- PF caches the computed factor on the farmland (= the "~120%" PF shows).
    local cached = tonumber(farmland.yieldPotential)
    if cached ~= nil and cached > 0 then return math.min(cached, 1.25) end

    -- Fallback: recompute from the soil map with PF's own formula.
    local precisionFarming = getPrecisionFarmingInstance()
    local soilMap = precisionFarming ~= nil and precisionFarming.soilMap or nil
    if soilMap == nil or type(soilMap.getYieldPotentialBySoilTypeIndex) ~= "function"
        or type(farmland.soilDistribution) ~= "table" then
        return 1.0
    end

    local weightSum = 0
    for _, weight in pairs(farmland.soilDistribution) do
        weightSum = weightSum + (tonumber(weight) or 0)
    end
    if weightSum <= 0 then return 1.0 end

    local potential = 0
    for soilTypeIndex, weight in pairs(farmland.soilDistribution) do
        local ok, value = pcall(soilMap.getYieldPotentialBySoilTypeIndex, soilMap, soilTypeIndex)
        if ok and type(value) == "number" then
            potential = potential + value * (tonumber(weight) or 0) / weightSum
        end
    end
    if potential <= 0 then return 1.0 end
    return math.min(potential, 1.25)
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

local function hasUsableFieldRotationArea(farmland, field)
    return getRotationAreaHa(farmland, field) > 0
end

-- =========================================================================
-- Yield debug helpers (assolementYieldDebug console command). Read-only.
-- =========================================================================

local function formatDebugValue(value, decimals)
    value = tonumber(value)
    if value == nil then return "nil" end
    return string.format("%." .. tostring(decimals or 3) .. "f", value)
end

local function getFillTypeByIndex(fillTypeIndex)
    fillTypeIndex = tonumber(fillTypeIndex)
    if fillTypeIndex == nil or g_fillTypeManager == nil
        or type(g_fillTypeManager.getFillTypeByIndex) ~= "function" then
        return nil
    end
    return g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
end

local function getFillTypeName(fillType)
    if type(fillType) ~= "table" then return "nil" end
    if fillType.name ~= nil and fillType.name ~= "" then return tostring(fillType.name) end
    if fillType.title ~= nil and fillType.title ~= "" then return tostring(fillType.title) end
    if fillType.index ~= nil then return "#" .. tostring(fillType.index) end
    return "unknown"
end

local function getFruitConverterName(converterIndex)
    if g_fruitTypeManager ~= nil and type(g_fruitTypeManager.converterNameToIndex) == "table" then
        for name, index in pairs(g_fruitTypeManager.converterNameToIndex) do
            if index == converterIndex then return tostring(name) end
        end
    end
    return "#" .. tostring(converterIndex)
end

local function logYieldDebug(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    if not ok then text = tostring(fmt) end
    local message = "[FieldRotation][YieldDebug] " .. text
    if Logging ~= nil and type(Logging.info) == "function" then
        Logging.info(message)
    end
    print(message)
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

local function getNativeGroundStateIndex(field)
    if field == nil or field.fieldState == nil then return nil end
    if FieldGroundType == nil or MapOverlayGenerator == nil
        or MapOverlayGenerator.GROWTH_STATE_INDEX == nil then
        return nil
    end

    local groundType = field.fieldState.groundType
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

function FieldRotationManager.new()
    local self = setmetatable({}, FieldRotationManager_mt)
    self.repository = FieldRotationRepository.new()
    self.service = FieldRotationService.new(self.repository)
    self.activeCropNameCache = {}
    self.isInitialized = false
    return self
end

function FieldRotationManager:initialize()
    if self.isInitialized then return end
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.isInitialized = true
end

function FieldRotationManager:cleanup()
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.isInitialized = false
end

function FieldRotationManager:saveToXML(savegamePath)
    if self.service ~= nil and type(self.service.saveNitrogenApplicationMask) == "function" then
        self.service:saveNitrogenApplicationMask(savegamePath)
    end
    return self.repository:saveToXML(savegamePath)
end

function FieldRotationManager:loadFromXML(savegamePath)
    self.repository:loadFromXML(savegamePath)
    self.service:recomputeAllPendingBonuses()
    self.service:initializeNitrogenApplicationMask(savegamePath)
end

-- =========================================================================
-- GUI / runtime queries.
-- =========================================================================

function FieldRotationManager:getHistory(farmlandId)
    return self.repository:getHistory(farmlandId)
end

function FieldRotationManager:getAllHistory()
    return self.repository:getAllHistory()
end

function FieldRotationManager:getPendingBonus(farmlandId)
    if farmlandId == nil or self.service == nil then return nil end
    return self.service.pendingBonus[farmlandId]
end

function FieldRotationManager:getRotationPlan(farmlandId)
    return self.repository:getPlan(farmlandId)
end

function FieldRotationManager:getAllRotationPlans()
    return self.repository:getAllPlans()
end

function FieldRotationManager:setRotationPlanYear(farmlandId, yearIdx, family)
    local n = tonumber(farmlandId)
    local y = tonumber(yearIdx)
    if n == nil or n <= 0 or y == nil or y < 1 or y > 4 then return false end
    self.repository:setPlanYear(n, y, family)
    return true
end

function FieldRotationManager:getCurrentFarmId()
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then return g_localPlayer.farmId end
    if g_currentMission ~= nil and type(g_currentMission.getFarmId) == "function" then
        return g_currentMission:getFarmId()
    end
    return nil
end

function FieldRotationManager:getFieldByFarmlandId(farmlandId)
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
function FieldRotationManager:getActiveCropName(farmlandId)
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

function FieldRotationManager:getActiveCropFruitTypeIndex(farmlandId)
    return getFieldFruitTypeIndex(self:getFieldByFarmlandId(farmlandId))
end

function FieldRotationManager:invalidateActiveCropCache(farmlandId)
    if self.activeCropNameCache == nil then return end
    local n = tonumber(farmlandId)
    if n == nil then return end
    self.activeCropNameCache[n] = nil
end

-- Returns the native ground state label (Cultivé/Labouré/Lit de semences/...)
-- when no active crop is growing on the farmland. nil when there IS a crop
-- (caller should display the crop) or when the ground is in NONE state.
function FieldRotationManager:getCurrentGroundStateLabel(farmlandId)
    if isPureClient() then return nil end
    local field = self:getFieldByFarmlandId(farmlandId)
    return getNativeGroundStateLabel(field)
end

function FieldRotationManager:getOwnedFarmlands()
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
        prefix = g_i18n:getText("fr_field_prefix") or prefix
    end

    for _, farmlandId in ipairs(farmlandIds) do
        local farmland = getFarmlandById(farmlandId)
        local field = self:getFieldByFarmlandId(farmlandId)
        if hasUsableFieldRotationArea(farmland, field) then
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

function FieldRotationManager:getCurrentSprayLevel(farmlandId)
    local field = self:getFieldByFarmlandId(farmlandId)
    local sprayLevel = field ~= nil and field.fieldState ~= nil and field.fieldState.sprayLevel or 0
    sprayLevel = tonumber(sprayLevel) or 0
    return math.max(0, math.min(2, math.floor(sprayLevel + 0.5)))
end

function FieldRotationManager:getCurrentLimeLevel(farmlandId)
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

-- Returns crop info for a farmland in a single density-map sample:
--   { growthState, maxStage }                      -- crop present, not harvestable
--   { growthState, maxStage, totalLiters,          -- crop present and harvestable
--     yieldPerArea, areaUnit }
--   nil                                            -- no crop / not resolvable
-- growthState/maxStage are nil when the engine reports no usable stage.
function FieldRotationManager:getFieldCropInfo(farmlandId)
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
    local maxStage = tonumber(fruitType.numGrowthStates) or 0
    -- States above numGrowthStates are terminal/track states (e.g. tireTracks),
    -- not growth stages: don't surface values like 10/8.
    local hasDisplayGrowthStage = growthState > 0 and maxStage > 0 and growthState <= maxStage

    local info = {
        growthState = hasDisplayGrowthStage and growthState or nil,
        maxStage = hasDisplayGrowthStage and maxStage or nil,
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

    local fillType = g_fruitTypeManager:getFillTypeByFruitTypeIndex(fruitType.index)
    local literPerSqm = tonumber(fruitType.literPerSqm) or 0
    if isForageReady and fruitType.windrowFillType ~= nil then
        fillType = fruitType.windrowFillType
        literPerSqm = tonumber(fruitType.windrowLiterPerSqm) or literPerSqm
    end

    local massPerLiter = fillType ~= nil and tonumber(fillType.massPerLiter) or nil
    if literPerSqm <= 0 or massPerLiter == nil or massPerLiter <= 0 then return info end

    -- Apply the Precision Farming soil yield potential so the result matches PF's
    -- expected yield: mod 8.85 T/ha * soil 1.2075 = PF 10.7 T/ha. 1.0 without PF.
    local soilYieldFactor = getSoilYieldPotential(getFarmlandById(numericFarmlandId))

    local totalLiters = literPerSqm * areaHa * harvestMultiplier * 10000 * soilYieldFactor
    if totalLiters <= 0 then return info end

    local displayArea = areaHa
    local areaUnit = "ha"
    if g_i18n ~= nil then
        if type(g_i18n.getArea) == "function" then
            local areaOk, convertedArea = pcall(g_i18n.getArea, g_i18n, areaHa)
            if areaOk and type(convertedArea) == "number" and convertedArea > 0 then
                displayArea = convertedArea
            end
        end
        if type(g_i18n.getAreaUnit) == "function" then
            local unitOk, convertedUnit = pcall(g_i18n.getAreaUnit, g_i18n)
            if unitOk and convertedUnit ~= nil and convertedUnit ~= "" then
                areaUnit = tostring(convertedUnit)
            end
        end
    end

    info.totalLiters = totalLiters
    info.yieldPerArea = (totalLiters * massPerLiter) / displayArea
    info.areaUnit = areaUnit
    return info
end

-- Console debug: logs every yield source for a farmland so the in-game numbers
-- can be cross-checked against Precision Farming. Read-only, no gameplay effect.
function FieldRotationManager:debugYieldSource(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then
        logYieldDebug("Usage: assolementYieldDebug <farmlandId>")
        return
    end

    local farmland = getFarmlandById(numericFarmlandId)
    local field = self:getFieldByFarmlandId(numericFarmlandId)
    logYieldDebug("farmland=%s field=%s fieldId=%s fieldAreaHa=%s farmlandTotalFieldArea=%s farmlandAreaInHa=%s pfYieldPotential=%s",
        tostring(numericFarmlandId),
        tostring(field ~= nil),
        tostring(field ~= nil and field.fieldId or nil),
        formatDebugValue(getFieldAreaHa(field), 4),
        formatDebugValue(getFarmlandFieldAreaHa(farmland), 4),
        formatDebugValue(farmland ~= nil and farmland.areaInHa or nil, 4),
        formatDebugValue(farmland ~= nil and farmland.yieldPotential or nil, 4))

    local precisionFarming = getPrecisionFarmingInstance()
    logYieldDebug("PF instances: g_precisionFarming=%s resolved=%s fieldInfoDisplayExtension=%s additionalFieldBuyInfo=%s harvestExtension=%s yieldMap=%s",
        tostring(g_precisionFarming ~= nil),
        tostring(precisionFarming ~= nil),
        tostring(precisionFarming ~= nil and precisionFarming.fieldInfoDisplayExtension ~= nil),
        tostring(precisionFarming ~= nil and precisionFarming.additionalFieldBuyInfo ~= nil),
        tostring(precisionFarming ~= nil and precisionFarming.harvestExtension ~= nil),
        tostring(precisionFarming ~= nil and precisionFarming.yieldMap ~= nil))

    if field == nil or FieldState == nil or g_fruitTypeManager == nil then
        logYieldDebug("STOP: missing field=%s FieldState=%s g_fruitTypeManager=%s",
            tostring(field ~= nil), tostring(FieldState ~= nil), tostring(g_fruitTypeManager ~= nil))
        return
    end
    if type(field.posX) ~= "number" or type(field.posZ) ~= "number" then
        logYieldDebug("STOP: field has no numeric center position posX=%s posZ=%s",
            tostring(field.posX), tostring(field.posZ))
        return
    end

    local fieldState = FieldState.new()
    if type(fieldState.update) ~= "function" then
        logYieldDebug("STOP: FieldState.update missing")
        return
    end
    fieldState:update(field.posX, field.posZ)
    logYieldDebug("FieldState: valid=%s fruitTypeIndex=%s growthState=%s lastGrowthState=%s spray=%s plow=%s lime=%s weed=%s stubble=%s roller=%s",
        tostring(fieldState.isValid),
        tostring(fieldState.fruitTypeIndex),
        tostring(fieldState.growthState),
        tostring(fieldState.lastGrowthState),
        tostring(fieldState.sprayLevel),
        tostring(fieldState.plowLevel),
        tostring(fieldState.limeLevel),
        tostring(fieldState.weedFactor),
        tostring(fieldState.stubbleShredLevel),
        tostring(fieldState.rollerLevel))
    if not fieldState.isValid then return end

    local fruitTypeIndex = normalizeFruitTypeIndex(fieldState.fruitTypeIndex)
    if fruitTypeIndex == nil then
        logYieldDebug("STOP: no fruit type at field sample")
        return
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then
        logYieldDebug("STOP: fruitType not found for index=%s", tostring(fruitTypeIndex))
        return
    end

    local growthState = tonumber(fieldState.growthState or fieldState.lastGrowthState) or 0
    local growthStateName = type(fruitType.growthStateToName) == "table"
        and fruitType.growthStateToName[growthState] or nil
    logYieldDebug("Fruit: index=%s name=%s growth=%s stateName=%s numGrowthStates=%s harvest=%s-%s forage=%s-%s literPerSqm=%s windrowLiterPerSqm=%s",
        tostring(fruitType.index),
        tostring(fruitType.name),
        tostring(growthState),
        tostring(growthStateName),
        tostring(fruitType.numGrowthStates),
        tostring(fruitType.minHarvestingGrowthState),
        tostring(fruitType.maxHarvestingGrowthState),
        tostring(fruitType.minForageGrowthState),
        tostring(fruitType.maxForageGrowthState),
        formatDebugValue(fruitType.literPerSqm, 6),
        formatDebugValue(fruitType.windrowLiterPerSqm, 6))

    local directFillType = g_fruitTypeManager:getFillTypeByFruitTypeIndex(fruitType.index)
    local windrowFillType = fruitType.windrowFillType
    logYieldDebug("Fill direct: name=%s index=%s massPerLiter=%s",
        getFillTypeName(directFillType),
        tostring(directFillType ~= nil and directFillType.index or nil),
        formatDebugValue(directFillType ~= nil and directFillType.massPerLiter or nil, 6))
    logYieldDebug("Fill windrow: name=%s index=%s massPerLiter=%s",
        getFillTypeName(windrowFillType),
        tostring(windrowFillType ~= nil and windrowFillType.index or nil),
        formatDebugValue(windrowFillType ~= nil and windrowFillType.massPerLiter or nil, 6))

    local harvestMultiplier = nil
    if type(fieldState.getHarvestScaleMultiplier) == "function" then
        local ok, value = pcall(fieldState.getHarvestScaleMultiplier, fieldState)
        harvestMultiplier = ok and tonumber(value) or nil
        logYieldDebug("FieldState.getHarvestScaleMultiplier=%s ok=%s",
            formatDebugValue(harvestMultiplier, 6), tostring(ok))
    else
        logYieldDebug("FieldState.getHarvestScaleMultiplier=missing")
    end

    local baseLiterPerSqm = tonumber(fruitType.literPerSqm) or 0
    local harvestLitersHa = baseLiterPerSqm * 10000
    local forageLitersHa = (tonumber(fruitType.windrowLiterPerSqm) or baseLiterPerSqm) * 10000
    if type(g_fruitTypeManager.getFruitTypeAreaLiters) == "function" then
        local harvestOk, value = pcall(g_fruitTypeManager.getFruitTypeAreaLiters,
            g_fruitTypeManager, fruitType.index, 10000, false)
        if harvestOk and tonumber(value) ~= nil then harvestLitersHa = tonumber(value) end
        local forageOk, forageValue = pcall(g_fruitTypeManager.getFruitTypeAreaLiters,
            g_fruitTypeManager, fruitType.index, 10000, true)
        if forageOk and tonumber(forageValue) ~= nil then forageLitersHa = tonumber(forageValue) end
    end
    logYieldDebug("Engine area liters per ha: harvest(false)=%s forage(true)=%s",
        formatDebugValue(harvestLitersHa, 1),
        formatDebugValue(forageLitersHa, 1))

    local areaHa = getRotationAreaHa(farmland, field)
    if harvestMultiplier ~= nil and harvestMultiplier >= 0 and harvestLitersHa > 0 and areaHa > 0 then
        local directMass = directFillType ~= nil and tonumber(directFillType.massPerLiter) or nil
        local directLiters = harvestLitersHa * areaHa * harvestMultiplier
        logYieldDebug("Estimate direct: litersTotal=%s litersHa=%s tonsHa=%s",
            formatDebugValue(directLiters, 1),
            formatDebugValue(directLiters / areaHa, 1),
            formatDebugValue(directMass ~= nil and (directLiters / areaHa * directMass) or nil, 3))
    else
        logYieldDebug("Estimate direct: skipped multiplier=%s harvestLitersHa=%s areaHa=%s",
            formatDebugValue(harvestMultiplier, 6),
            formatDebugValue(harvestLitersHa, 1),
            formatDebugValue(areaHa, 4))
    end

    if type(g_fruitTypeManager.fruitTypeConverters) == "table" then
        local converterCount = 0
        for converterIndex, converter in pairs(g_fruitTypeManager.fruitTypeConverters) do
            local converterData = type(converter) == "table" and converter[fruitType.index] or nil
            if type(converterData) == "table" then
                converterCount = converterCount + 1
                local outputFillType = getFillTypeByIndex(converterData.fillTypeIndex)
                local conversionFactor = tonumber(converterData.conversionFactor) or 1
                local outputMass = outputFillType ~= nil and tonumber(outputFillType.massPerLiter) or nil
                local converterName = getFruitConverterName(converterIndex)
                local sourceLitersHa = converterName == "MOWER" and forageLitersHa or harvestLitersHa
                local litersHa, tonsHa = nil, nil
                if harvestMultiplier ~= nil and sourceLitersHa > 0 then
                    litersHa = sourceLitersHa * harvestMultiplier * conversionFactor
                    if outputMass ~= nil then tonsHa = litersHa * outputMass end
                end
                logYieldDebug("Converter[%s]: sourceLitersHa=%s to=%s fillTypeIndex=%s factor=%s litersHa=%s tonsHa=%s massPerLiter=%s",
                    converterName,
                    formatDebugValue(sourceLitersHa, 1),
                    getFillTypeName(outputFillType),
                    tostring(converterData.fillTypeIndex),
                    formatDebugValue(conversionFactor, 6),
                    formatDebugValue(litersHa, 1),
                    formatDebugValue(tonsHa, 3),
                    formatDebugValue(outputMass, 6))
            end
        end
        if converterCount == 0 then
            logYieldDebug("Converters: none for fruit=%s", tostring(fruitType.name))
        end
    end

    -- PF harvest yield-factor decomposition. Populated during harvest, so to see
    -- real values: harvest a few metres of the field, then run this command.
    local harvestExtension = precisionFarming ~= nil and precisionFarming.harvestExtension or nil
    if harvestExtension ~= nil and type(harvestExtension.debugValues) == "table" then
        local d = harvestExtension.debugValues
        logYieldDebug("PF debugValues: yieldFactor=%s yieldFactorRegular=%s yieldPotential=%s nFactor=%s regularNFactor=%s pHFactor=%s regularPHFactor=%s weedFactor=%s stubbleFactor=%s rollerFactor=%s plowFactor=%s seedRate=%s nActual=%s nTarget=%s pHActual=%s pHTarget=%s",
            formatDebugValue(d.yieldFactor, 4), formatDebugValue(d.yieldFactorRegular, 4),
            formatDebugValue(d.yieldPotential, 4), formatDebugValue(d.nFactor, 4),
            formatDebugValue(d.regularNFactor, 4), formatDebugValue(d.pHFactor, 4),
            formatDebugValue(d.regularPHFactor, 4), formatDebugValue(d.weedFactor, 4),
            formatDebugValue(d.stubbleFactor, 4), formatDebugValue(d.rollerFactor, 4),
            formatDebugValue(d.plowFactor, 4), formatDebugValue(d.seedRateYieldFactor, 4),
            formatDebugValue(d.nActualValue, 2), formatDebugValue(d.nTargetValue, 2),
            formatDebugValue(d.pHActualValue, 3), formatDebugValue(d.pHTargetValue, 3))
    else
        logYieldDebug("PF debugValues: unavailable (harvestExtension=%s)",
            tostring(harvestExtension ~= nil))
    end

    local info = self:getFieldCropInfo(numericFarmlandId)
    logYieldDebug("Current UI info: growth=%s/%s totalLiters=%s yieldPerArea=%s areaUnit=%s",
        tostring(info ~= nil and info.growthState or nil),
        tostring(info ~= nil and info.maxStage or nil),
        formatDebugValue(info ~= nil and info.totalLiters or nil, 1),
        formatDebugValue(info ~= nil and info.yieldPerArea or nil, 3),
        tostring(info ~= nil and info.areaUnit or nil))
end

-- Returns:
--   actualKgHa : average N in kg/ha over the field polygon (nil if not resolvable)
--   targetKgHa : nitrogen target for the active crop on this soil (nil if no active crop)
--   mapMaxKgHa : map's global max value in kg/ha, used by UI when no crop target exists.
function FieldRotationManager:getNitrogenLevel(farmlandId)
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

function FieldRotationManager:getPHLevel(farmlandId)
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
