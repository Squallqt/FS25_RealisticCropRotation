-- Copyright © 2026 Squallqt. All rights reserved.
-- Facade exposed on g_currentMission.fieldRotationManager.
-- Owns Repository + Service and forwards GUI-side reads.
RealisticCropRotationManager = {}
local RealisticCropRotationManager_mt = Class(RealisticCropRotationManager)

-- Active-crop cache TTL on the server.
-- UI/HUD reads can call getActiveCropName repeatedly. A TTL-based cache keeps
-- those reads cheap while the field's growth state changes far slower than this.
local ACTIVE_CROP_CACHE_TTL_MS = 10000

-- PF soil read cache TTL. PF nitrogen/pH only change when the player works the
-- field; a short TTL keeps the menu-open reads cheap without going stale.
local SOIL_PF_CACHE_TTL_MS = 10000

-- Full-field soil scan resolution (menu only). The field bounding box is sampled
-- on a FIELD_SCAN_STEPS x FIELD_SCAN_STEPS grid, off-field points dropped by the
-- terrain mask, so nitrogen/pH are averaged over the WHOLE field -- never a
-- centre cluster. Perf is irrelevant here (read on menu open, behind a TTL cache).
local FIELD_SCAN_STEPS = 50

local function isPureClient()
    return g_currentMission ~= nil
        and g_currentMission.getIsServer ~= nil
        and not g_currentMission:getIsServer()
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

local function getOwnerFarmIdForFarmland(farmlandId, farmland)
    if g_farmlandManager ~= nil and type(g_farmlandManager.getFarmlandOwner) == "function" then
        return g_farmlandManager:getFarmlandOwner(tonumber(farmlandId) or farmlandId)
    end
    return farmland ~= nil and farmland.farmId or nil
end

local function isRealFarmOwner(farmId)
    local numericFarmId = tonumber(farmId)
    if numericFarmId == nil or numericFarmId <= 0 then return false end
    if FarmlandManager ~= nil and FarmlandManager.NOT_BUYABLE_FARM_ID ~= nil
        and numericFarmId == FarmlandManager.NOT_BUYABLE_FARM_ID then
        return false
    end
    return true
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

    local ok, fruitTypeIndex, growthState = pcall(FSDensityMapUtil.getFruitTypeIndexAtWorldPos, x, z)
    if not ok then return nil, true end
    return normalizeFruitTypeIndex(fruitTypeIndex), true, tonumber(growthState)
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

local function getFieldFruitTypeIndex(field)
    local fruitTypeIndex, sampledDensityMap, growthState = getFieldFruitTypeIndexFromDensityMap(field)
    if sampledDensityMap then return fruitTypeIndex, growthState end
    if isPureClient() then return nil end
    return getFieldFruitTypeIndexFromFieldState(field)
end

local function getActiveCropNameFromField(field)
    local fruitTypeIndex, growthState = getFieldFruitTypeIndex(field)
    if fruitTypeIndex == nil or g_fruitTypeManager == nil then return nil end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil or fruitType.name == nil or fruitType.name == "" then return nil end
    return tostring(fruitType.name), fruitTypeIndex, growthState
end

local function sampleFieldStateAtField(field)
    if field == nil or FieldState == nil then return nil end
    if type(field.posX) ~= "number" or type(field.posZ) ~= "number" then return nil end

    local fieldState = FieldState.new()
    if type(fieldState.update) ~= "function" then return nil end
    fieldState:update(field.posX, field.posZ)
    if not fieldState.isValid then return nil end
    return fieldState
end

-- Live ground type at the field, read straight from the GROUND_TYPE density map at the same
-- sample points the crop detection uses (getFieldFruitTypeIndexFromDensityMap). This keeps the
-- "worked" status (cultivated/plowed/...) as fresh as the crop status, instead of lagging behind the
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

local function getRoundedFieldStateLevel(fieldState, name)
    return math.floor((tonumber(fieldState ~= nil and fieldState[name]) or 0) + 0.5)
end

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

local function getNativeSoilStateIndex(field)
    if field == nil then return nil end

    local samples = {}
    if type(field.posX) == "number" and type(field.posZ) == "number" then
        table.insert(samples, { x = field.posX, z = field.posZ })
    end
    collectFieldDimensionSamples(field, samples)

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

-- Resolves the current ground state of a field to a native GIANTS l10n key.
-- Mapping is between FieldGroundType.<NAME> and
-- MapOverlayGenerator.L10N_SYMBOL.GROWTH_MAP_<NAME>, both globally exposed at
-- runtime. The same descriptions are what the in-game map overlay shows
-- (MapOverlayGenerator.lua:628-678 in gameSource).
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

-- Importance ranking shared by the no-crop field status (getCurrentFieldStatus):
-- one line must carry the most useful state, so actionable advisories (needs
-- plowing/rolling) outrank the tillage state (plowed/stubble/cultivated/seedbed),
-- which outranks passive conditions (mulched/watered) -- the latter used to mask
-- the tillage state once mulching was added. Lower = higher priority; math.huge
-- for anything outside the ranking.
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

-- Field-prep operations still required at a sampled point, mirroring the base-game
-- soil overlay conditions (MapOverlayGenerator.buildSoilStateMapOverlay):
--   plow -> PLOW_LEVEL 0   (usePlowCounter + plowingRequiredEnabled)
--   roll -> ROLLER_LEVEL 1 (useRolling)
-- Returns plowNeeded, rollNeeded (booleans).
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

-- =========================================================================
-- Construction / lifecycle.
-- =========================================================================

function RealisticCropRotationManager.new()
    local self = setmetatable({}, RealisticCropRotationManager_mt)
    self.repository = RealisticCropRotationRepository.new()
    self.service = RealisticCropRotationService.new(self.repository)
    self.activeCropNameCache = {}
    self.soilPFCache = {}
    self.isInitialized = false
    return self
end

function RealisticCropRotationManager:initialize()
    if self.isInitialized then return end
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.soilPFCache = {}
    self.isInitialized = true
end

function RealisticCropRotationManager:cleanup()
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.soilPFCache = {}
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

function RealisticCropRotationManager:getRotationCoverPlan(farmlandId)
    return self.repository:getCoverPlan(farmlandId)
end

function RealisticCropRotationManager:getAllRotationCoverPlans()
    return self.repository:getAllCoverPlans()
end

function RealisticCropRotationManager:setRotationCoverPlanYear(farmlandId, yearIdx, cropName)
    local n = tonumber(farmlandId)
    local y = tonumber(yearIdx)
    if n == nil or n <= 0 or y == nil or y < 1 or y > 4 then return false end
    self.repository:setCoverPlanYear(n, y, cropName)
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

-- Returns the currently active crop details on a farmland.
-- Pure clients use density-map sampling only; fieldState fallback is server-only.
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
            -- Player-converted permanent grassland: no Field object/fieldState
            -- but still valid rotation land. Show FIELDGRASS as the natural
            -- meadow crop, not Fallow.
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

-- Returns the currently active crop name on a farmland.
function RealisticCropRotationManager:getActiveCropName(farmlandId)
    local cropName = self:getActiveCropInfo(farmlandId)
    return cropName
end

function RealisticCropRotationManager:getActiveCropFruitTypeIndex(farmlandId)
    local _, fruitTypeIndex = self:getActiveCropInfo(farmlandId)
    return fruitTypeIndex
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

    local currentCropName, currentFruitTypeIndex, currentGrowthState = self:getActiveCropInfo(farmlandId)
    local changed = self.service:reconcileActiveCrop(farmlandId, currentCropName, currentFruitTypeIndex, currentGrowthState)
    if changed then
        self:invalidateActiveCropCache(farmlandId)
    end
    return changed
end

-- Single most-important current field status for a NO-CROP field: combines the
-- tillage/ground state (cultivated/plowed/stubble/seedbed) and the soil condition
-- (needs plowing/rolling, mulched, watered) into one line by importance
-- (fieldStatusRank). Works on MP clients -- the ground state is read live from the
-- GROUND_TYPE density map (WheelPhysics pattern), so no isPureClient guard.
-- Returns label(string), kind("ground"|"soil"), index -- or nil when nothing
-- applies (caller then shows "no crop").
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

-- Top field-prep action the player still has to do on the parcel, as the native
-- localised label ("Needs plowing" / "Needs rolling"), or nil when none. Plow
-- outranks roll. Detection samples the live field state across the field (action
-- shown when the majority of samples need it), client-safe. Lime is intentionally
-- not here -- it lives on the dedicated pH/lime gauge.
function RealisticCropRotationManager:getRequiredFieldActionLabel(farmlandId)
    if MapOverlayGenerator == nil or MapOverlayGenerator.SOIL_STATE_INDEX == nil then return nil end
    local field = self:getFieldByFarmlandId(farmlandId)
    if field == nil or FieldState == nil then return nil end

    local samples = {}
    if type(field.posX) == "number" and type(field.posZ) == "number" then
        samples[#samples + 1] = { x = field.posX, z = field.posZ }
    end
    collectFieldDimensionSamples(field, samples)
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

-- Samples a fresh FieldState from the density maps at the field centre. The
-- engine forces field.fieldState to a placeholder on MP clients (FieldManager),
-- so the soil gauges read this client-safe sample instead -- the same pattern
-- getFieldCropInfo already uses. One density sample, on menu open only. Returns
-- a populated FieldState or nil.
function RealisticCropRotationManager:sampleFieldState(farmlandId)
    local field = self:getFieldByFarmlandId(farmlandId)
    return sampleFieldStateAtField(field)
end

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

-- Current base-game fertilisation level (SPRAY_LEVEL density map), mirroring
-- getCurrentLimeLevel. Reads the client-safe sampled FieldState so the gauge
-- works in MP too. Returns level, maxLevel.
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

-- =========================================================================
-- Precision Farming soil reads (nitrogen + pH). Active only when PF is
-- installed; otherwise the gauges use the vanilla getCurrent*Level above.
-- Bounded sampling + TTL cache, read on menu open only: no hooks, no per-frame.
-- =========================================================================

-- Builds the on-field sample grid shared by the nitrogen and pH scans. A bounded
-- FIELD_SCAN_STEPS x FIELD_SCAN_STEPS grid over the field bounding box, with
-- off-field points dropped via the terrain field mask, so the soil averages
-- cover the WHOLE field, never a centre cluster. Returns an array of { x, z }
-- world positions, or nil when the field has no usable position / no on-field
-- point.
function RealisticCropRotationManager:buildFieldSampleGrid(field)
    if field == nil then return nil end
    if type(field.posX) ~= "number" or type(field.posZ) ~= "number" then return nil end

    local areaHa = getFieldAreaHa(field)
    if areaHa <= 0 then areaHa = 1 end
    local side = math.sqrt(areaHa * 10000)
    local steps = FIELD_SCAN_STEPS
    local step = (steps > 1) and (side / (steps - 1)) or 0
    local startX, startZ = field.posX - side * 0.5, field.posZ - side * 0.5

    local terrainDetailId = g_currentMission ~= nil and g_currentMission.terrainDetailId or nil
    local canMask = terrainDetailId ~= nil and getDensityAtWorldPos ~= nil

    local points = {}
    for i = 0, steps - 1 do
        for j = 0, steps - 1 do
            local x, z = startX + i * step, startZ + j * step
            if not canMask or getDensityAtWorldPos(terrainDetailId, x, 0, z) ~= 0 then
                points[#points + 1] = { x = x, z = z }
            end
        end
    end

    if #points == 0 then return nil end
    return points
end

function RealisticCropRotationManager:getCachedPFSoil(farmlandId, kind)
    local cache = self.soilPFCache
    if cache == nil then return nil end
    local entry = cache[farmlandId]
    if entry == nil or entry[kind] == nil then return nil end
    local nowMs = tonumber(g_time) or 0
    if (nowMs - (entry[kind .. "Ms"] or 0)) >= SOIL_PF_CACHE_TTL_MS then return nil end
    return entry[kind]
end

function RealisticCropRotationManager:setCachedPFSoil(farmlandId, kind, values)
    if self.soilPFCache == nil then self.soilPFCache = {} end
    local entry = self.soilPFCache[farmlandId]
    if entry == nil then entry = {}; self.soilPFCache[farmlandId] = entry end
    entry[kind] = values
    entry[kind .. "Ms"] = tonumber(g_time) or 0
end

-- Precision Farming runs sandboxed in its own mod environment, so its
-- g_precisionFarming is not on the shared global table for other mods. Reach it
-- through the env table the engine exposes under the mod name. Returns the PF
-- module instance or nil when PF is absent.
function RealisticCropRotationManager:getPrecisionFarming()
    if g_precisionFarming ~= nil then return g_precisionFarming end
    local env = FS25_precisionFarming
    if type(env) == "table" then
        if type(env.g_precisionFarming) == "table" then return env.g_precisionFarming end
        if env.nitrogenMap ~= nil or env.pHMap ~= nil then return env end
    end
    return nil
end

-- True when the field's PF soil is NOT analysed (so the gauges show "not
-- sampled" instead of a misleading 0 / pH 4.5). PF exposes no reliable
-- per-farmland "analysed" getter (getIsLockedAtWorldPos returns false even when
-- unanalysed). The reliable, verified signal: until the soil is analysed PF
-- returns the absolute floor from the read methods (pH internal state 0 = 4.5,
-- confirmed in-game), and a real analysed pH is never at the floor (PF generates
-- pH per soil type, optimum 6-7 + small noise -- PrecisionFarming.xml). So a pH
-- reading at/below state 1 means not analysed. One analysis unlocks N + pH +
-- soil type, so this single pH check covers both gauges. Fail-open: any read
-- error -> false (treat as analysed/available).
function RealisticCropRotationManager:isPFSoilLocked(pf, field)
    if pf == nil or field == nil then return false end
    local phMap = pf.pHMap
    if phMap == nil or type(phMap.getLevelAtWorldPos) ~= "function" then return false end
    if type(field.posX) ~= "number" or type(field.posZ) ~= "number" then return false end
    local ok, phInternal = pcall(phMap.getLevelAtWorldPos, phMap, field.posX, field.posZ)
    if not ok or type(phInternal) ~= "number" then return false end
    return phInternal <= 1
end

-- PF nitrogen for a farmland. Full-field scan:
--   * actual  = average available soil nitrogen over the whole field (kg/ha).
--   * target  = average crop requirement (kg/ha), averaged ONLY over the points
--               where a crop is actually growing -- so the "besoin" reflects the
--               planted crop. nil when no crop is planted (the caller then shows
--               an empty gauge with the soil's real average nitrogen).
-- Returns actual, target, min, max (kg/ha); false when the soil is not analysed
-- ("not sampled"); or nil when PF is absent -> falls back to the vanilla read.
function RealisticCropRotationManager:getNitrogenLevel(farmlandId)
    local pf = self:getPrecisionFarming()
    if pf == nil then return nil end
    local nMap = pf.nitrogenMap
    if nMap == nil or type(nMap.getNitrogenValueFromInternalValue) ~= "function" then return nil end
    if type(nMap.getLevelAtWorldPos) ~= "function" then return nil end

    local n = tonumber(farmlandId)
    if n == nil then return nil end

    local field = self:getFieldByFarmlandId(n)
    if self:isPFSoilLocked(pf, field) then return false end

    local cached = self:getCachedPFSoil(n, "nitrogen")
    if cached ~= nil then return cached[1], cached[2], cached[3], cached[4] end

    local points = self:buildFieldSampleGrid(field)
    if points == nil then return nil end

    local hasTargetApi = type(nMap.getTargetLevelAtWorldPos) == "function"
    local hasCropApi = getFruitTypeIndexAtWorldPos ~= nil

    local actualSum, actualCount = 0, 0
    local targetSum, targetCount = 0, 0
    local ok = pcall(function()
        for _, p in ipairs(points) do
            local actual = nMap:getLevelAtWorldPos(p.x, p.z)
            if type(actual) == "number" then
                actualSum = actualSum + actual
                actualCount = actualCount + 1
                if hasTargetApi and hasCropApi then
                    local fruitTypeIndex, didSample = getFruitTypeIndexAtWorldPos(p.x, p.z)
                    if didSample and fruitTypeIndex ~= nil then
                        local target = nMap:getTargetLevelAtWorldPos(p.x, p.z)
                        if type(target) == "number" then
                            targetSum = targetSum + target
                            targetCount = targetCount + 1
                        end
                    end
                end
            end
        end
    end)
    if not ok or actualCount == 0 then return nil end

    -- Clamp internal levels to [0, maxValue] before conversion, mirroring the PF
    -- sprayer HUD (math.clamp(value, 0, nitrogenMap.maxValue)).
    local maxInternal = tonumber(nMap.maxValue) or 45
    local function conv(level)
        return tonumber(nMap:getNitrogenValueFromInternalValue(math.max(0, math.min(level, maxInternal))))
    end

    local actual = conv(actualSum / actualCount)
    if actual == nil then return nil end
    local target = targetCount > 0 and conv(targetSum / targetCount) or nil
    local minVal = conv(0) or 0
    local maxVal = conv(maxInternal) or 0

    self:setCachedPFSoil(n, "nitrogen", { actual, target, minVal, maxVal })
    return actual, target, minVal, maxVal
end

-- PF soil pH for a farmland. Full-field scan:
--   * actual = average real pH over the whole field.
--   * target = average OPTIMAL pH, computed per point from that point's soil type
--              (lime depends on soil, not crop), so a field spanning several soil
--              types gets the true field-average objective -- never the centre's.
-- Returns actual, target, min, max (pH); false when the soil is not analysed
-- ("not sampled"); or nil when PF is absent -> falls back to the vanilla read.
function RealisticCropRotationManager:getPHLevel(farmlandId)
    local pf = self:getPrecisionFarming()
    if pf == nil then return nil end
    local phMap = pf.pHMap
    if phMap == nil or type(phMap.getPhValueFromInternalValue) ~= "function" then return nil end
    if type(phMap.getLevelAtWorldPos) ~= "function" then return nil end

    local n = tonumber(farmlandId)
    if n == nil then return nil end

    local field = self:getFieldByFarmlandId(n)
    if self:isPFSoilLocked(pf, field) then return false end

    local cached = self:getCachedPFSoil(n, "ph")
    if cached ~= nil then return cached[1], cached[2], cached[3], cached[4] end

    local points = self:buildFieldSampleGrid(field)
    if points == nil then return nil end

    -- Clamp internal level to [0, maxValue] before conversion (same guard as PF).
    local maxInternal = tonumber(phMap.maxValue) or 31
    local function conv(level)
        return tonumber(phMap:getPhValueFromInternalValue(math.max(0, math.min(level, maxInternal))))
    end

    -- Per-point optimal pH: read the soil type, ask PF for its optimal.
    -- getOptimalPHValueForSoilTypeIndex returns a real pH (6-7) or an internal
    -- state (>9, then converted). PrecisionFarming.xml optimal: type 1=6.0,
    -- 2=6.5, 3=6.75, 4=7.0.
    local soilMap = pf.soilMap
    local hasOptimalApi = soilMap ~= nil
        and type(soilMap.getTypeIndexAtWorldPos) == "function"
        and type(phMap.getOptimalPHValueForSoilTypeIndex) == "function"

    local actualSum, actualCount = 0, 0
    local optimalSum, optimalCount = 0, 0
    local ok = pcall(function()
        for _, p in ipairs(points) do
            local actual = phMap:getLevelAtWorldPos(p.x, p.z)
            if type(actual) == "number" then
                actualSum = actualSum + actual
                actualCount = actualCount + 1
            end
            if hasOptimalApi then
                local typeIndex = soilMap:getTypeIndexAtWorldPos(p.x, p.z)
                if typeIndex ~= nil then
                    local optimal = phMap:getOptimalPHValueForSoilTypeIndex(typeIndex)
                    if type(optimal) == "number" and optimal > 0 then
                        if optimal > 9 then optimal = conv(optimal) end
                        if type(optimal) == "number" then
                            optimalSum = optimalSum + optimal
                            optimalCount = optimalCount + 1
                        end
                    end
                end
            end
        end
    end)
    if not ok or actualCount == 0 then return nil end

    local actual = conv(actualSum / actualCount)
    if actual == nil then return nil end
    local target = optimalCount > 0 and (optimalSum / optimalCount) or nil
    local minPH = conv(0) or 0
    local maxPH = conv(maxInternal) or 0

    self:setCachedPFSoil(n, "ph", { actual, target, minPH, maxPH })
    return actual, target, minPH, maxPH
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

-- Weed display is mirrored directly from the base-game pedestrian HUD via
-- RealisticCropRotationHud.getWeedLineFromGame (it calls the real
-- PlayerHUDUpdater:fieldAddWeed with a capture box). No hardcoded
-- weedState->stage/tool mapping lives here anymore: the game composes both the
-- stage label and the tool recommendation, and Precision Farming feeds the
-- weedState, so the card never drifts from what the player sees on foot.

-- Per-field crop info for the detail card: growth stage + the mirrored base-game
-- weed line. No yield estimate (that feature was removed). Returns nil when no
-- crop is growing.
function RealisticCropRotationManager:getFieldCropInfo(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return nil end

    local field = self:getFieldByFarmlandId(farmlandId)
    if field == nil or g_fruitTypeManager == nil or FieldState == nil then return nil end
    if type(field.posX) ~= "number" or type(field.posZ) ~= "number" then return nil end

    -- field.fieldState is forced to groundType=CULTIVATED/fruitTypeIndex=UNKNOWN
    -- on MP clients by the engine (FieldManager.lua:292-302). Build a fresh
    -- FieldState and sample density maps at the field center -- the engine pattern
    -- from FieldManager.lua:327-343 (debug overlay path, proven client-safe). The
    -- same shape of FieldState is what PlayerHUDUpdater.fieldAddFarmland receives
    -- as 'data'. One sample feeds both the growth stage and the weed line.
    local fieldState = FieldState.new()
    if type(fieldState.update) ~= "function" then return nil end
    fieldState:update(field.posX, field.posZ)
    if not fieldState.isValid then return nil end

    local fruitTypeIndex = normalizeFruitTypeIndex(fieldState.fruitTypeIndex)
    if fruitTypeIndex == nil then return nil end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then return nil end

    local growthState = tonumber(fieldState.growthState or fieldState.lastGrowthState) or 0

    -- Mirror the base-game pedestrian HUD weed line: feed our sampled field
    -- state (weedState already set by the engine / PF override) to the real
    -- PlayerHUDUpdater:fieldAddWeed and read back the exact stage label + tool
    -- value it would display. farmlandId is set because the HUD's own data
    -- carries it; fieldAddWeed reads weedState/fruitTypeIndex/growthState here.
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
