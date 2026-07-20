-- Copyright © 2026 Squallqt. All rights reserved.
-- Facade over Repository + Service for the GUI/HUD reads.
RealisticCropRotationManager = {}
local RealisticCropRotationManager_mt = Class(RealisticCropRotationManager)

-- Active-crop cache TTL: UI/HUD reads are frequent, growth changes slowly.
local ACTIVE_CROP_CACHE_TTL_MS = 10000

-- Grid resolution for locating one representative point per soil type.
local SOIL_TYPE_LOCATOR_STEPS = 16

-- Field share that must reach a level for that level to be reported.
local VANILLA_LEVEL_COVERAGE = 0.90

-- Field-ground share a soil/ground state must cover to become the field's status.
local FIELD_STATE_COVERAGE = 0.50

-- PF field-info only displays legend values (PrecisionFarming.xml showOnHud): nitrogen per 20 kg/ha, pH per 0.25.
local PF_N_DISPLAY_STEP = 20
local PF_PH_DISPLAY_STEP = 0.25


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

---World-space polygon vertices for a field, resolved from its scene-graph corner nodes.
-- @param table field
-- @return table vertices Array of {x=, z=} world points, or nil when geometry is unavailable
local function getFieldPolygonVertices(field)
    if field == nil or getWorldTranslation == nil then return nil end
    local points = field.polygonPoints
    if type(points) ~= "table" or #points == 0 then return nil end

    local vertices = {}
    for _, node in ipairs(points) do
        if node ~= nil then
            local ok, x, _, z = pcall(getWorldTranslation, node)
            if ok and type(x) == "number" and type(z) == "number" then
                table.insert(vertices, { x = x, z = z })
            end
        end
    end
    if #vertices == 0 then return nil end
    return vertices
end

---World-space axis-aligned bounding box of a field's polygon corner nodes (Field has no `fieldDimensions`).
-- @param table field
-- @return number minX, maxX, minZ, maxZ, or nil when geometry is unavailable
function RealisticCropRotationManager.fieldPolygonBounds(field)
    local vertices = getFieldPolygonVertices(field)
    if vertices == nil then return nil end

    local minX, maxX, minZ, maxZ
    for _, v in ipairs(vertices) do
        if minX == nil or v.x < minX then minX = v.x end
        if maxX == nil or v.x > maxX then maxX = v.x end
        if minZ == nil or v.z < minZ then minZ = v.z end
        if maxZ == nil or v.z > maxZ then maxZ = v.z end
    end
    return minX, maxX, minZ, maxZ
end

-- File-local alias for the functions below.
local fieldPolygonBounds = RealisticCropRotationManager.fieldPolygonBounds

---True when a 2D point lies inside a polygon (ray-casting / even-odd rule).
-- @param number x
-- @param number z
-- @param table vertices Array of {x=, z=}
-- @return boolean inside
local function isPointInPolygon(x, z, vertices)
    if vertices == nil or #vertices < 3 then return false end
    local inside = false
    local j = #vertices
    for i = 1, #vertices do
        local vi, vj = vertices[i], vertices[j]
        if (vi.z > z) ~= (vj.z > z) then
            local edgeX = vi.x + (vj.x - vi.x) * (z - vi.z) / (vj.z - vi.z)
            if x < edgeX then inside = not inside end
        end
        j = i
    end
    return inside
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
    -- Cultivable agricultural area, different from areaInHa which is the full buyable parcel (may include yards/buildable land).
    local totalFieldArea = tonumber(farmland.totalFieldArea) or 0
    if totalFieldArea > 0 then return totalFieldArea end
    local fieldAreaHa = tonumber(farmland.fieldAreaHa) or 0
    if fieldAreaHa > 0 then return fieldAreaHa end
    return 0
end

---Best rotation area in hectares: measured worked ground first, field polygon fallback.
-- @param table farmland
-- @param table field
-- @return number areaHa
local function getRotationAreaHa(farmland, field)
    -- Measured worked area first, map polygon as fallback.
    local measuredArea = getFarmlandFieldAreaHa(farmland)
    if measuredArea > 0 then return measuredArea end
    return getFieldAreaHa(field)
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

-- NATIVE FIELD AGGREGATES

---Builds a density filter on a layer.
-- @param integer mapId
-- @param integer firstChannel
-- @param integer numChannels
-- @param integer compareType DensityValueCompareType
-- @param number value
-- @param number maxValue Upper bound for BETWEEN, or nil
-- @return table filter, or nil
local function makeDensityFilter(mapId, firstChannel, numChannels, compareType, value, maxValue)
    if DensityMapFilter == nil or DensityValueCompareType == nil then return nil end
    if mapId == nil or firstChannel == nil or numChannels == nil or compareType == nil then return nil end
    local filter = DensityMapFilter.new(mapId, firstChannel, numChannels)
    if filter == nil then return nil end
    filter:setValueCompareParams(compareType, value, maxValue)
    return filter
end

---Sums a density layer over a field's polygon.
-- @param table field
-- @param integer mapId
-- @param integer firstChannel
-- @param integer numChannels
-- @param table filterA Optional density filter
-- @param table filterB Optional second density filter
-- @return number sum, number pixels, or nil when the field has no usable polygon
local function aggregateFieldLayer(field, mapId, firstChannel, numChannels, filterA, filterB)
    if field == nil or mapId == nil or firstChannel == nil or numChannels == nil then return nil end
    if DensityMapModifier == nil or g_terrainNode == nil then return nil end
    if type(field.getDensityMapPolygon) ~= "function" then return nil end

    local polygon = field:getDensityMapPolygon()
    if polygon == nil then return nil end

    local modifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    if modifier == nil then return nil end
    polygon:applyToModifier(modifier)

    local ok, sum, pixels = pcall(modifier.executeGet, modifier, filterA, filterB)
    if not ok then return nil end
    return tonumber(sum) or 0, tonumber(pixels) or 0
end

---Resolves a vanilla field density layer's map handle.
-- @param integer layer FieldDensityMap entry
-- @return integer mapId, integer firstChannel, integer numChannels, or nil
local function getFieldGroundLayer(layer)
    local system = g_currentMission ~= nil and g_currentMission.fieldGroundSystem or nil
    if system == nil or layer == nil or type(system.getDensityMapData) ~= "function" then return nil end
    local mapId, firstChannel, numChannels = system:getDensityMapData(layer)
    if mapId == nil or firstChannel == nil or numChannels == nil then return nil end
    return mapId, firstChannel, numChannels
end

---Filter selecting worked field ground (GROUND_TYPE above NONE).
-- @return table filter, or nil
function RealisticCropRotationManager.makeFieldGroundFilter()
    local layer = FieldDensityMap ~= nil and FieldDensityMap.GROUND_TYPE or nil
    local mapId, firstChannel, numChannels = getFieldGroundLayer(layer)
    if mapId == nil then return nil end
    return makeDensityFilter(mapId, firstChannel, numChannels, DensityValueCompareType.GREATER, 0)
end

---Sums a vanilla field layer over a field, narrowed by an optional value filter and mask.
-- @param table field
-- @param integer layer FieldDensityMap entry
-- @param integer compareType DensityValueCompareType, or nil to take the whole polygon
-- @param number value
-- @param number maxValue Upper bound for BETWEEN, or nil
-- @param table maskFilter Optional second filter
-- @return number sum, number pixels, or nil when the layer or polygon is unavailable
local function aggregateFieldGroundLayer(field, layer, compareType, value, maxValue, maskFilter)
    local mapId, firstChannel, numChannels = getFieldGroundLayer(layer)
    if mapId == nil then return nil end

    local filter = nil
    if compareType ~= nil then
        filter = makeDensityFilter(mapId, firstChannel, numChannels, compareType, value, maxValue)
        if filter == nil then return nil end
    end

    return aggregateFieldLayer(field, mapId, firstChannel, numChannels, filter, maskFilter)
end

---Deepest vanilla layer level covering VANILLA_LEVEL_COVERAGE of the field, plus the field-average ratio.
-- @param table field
-- @param integer layer FieldDensityMap entry
-- @param integer maxLevel
-- @return integer level Deepest sufficiently covered level, 0 when none, or nil when the field has no polygon
-- @return number ratio Field average over maxLevel, for the bar fill
local function getFieldLayerCoverageLevel(field, layer, maxLevel)
    local groundFilter = RealisticCropRotationManager.makeFieldGroundFilter()
    local sum, pixels = aggregateFieldGroundLayer(field, layer, nil, nil, nil, groundFilter)
    if sum == nil or pixels == nil or pixels <= 0 then return nil end

    local level = 0
    for candidate = maxLevel, 1, -1 do
        local _, covered = aggregateFieldGroundLayer(field, layer,
            DensityValueCompareType.BETWEEN, candidate, maxLevel, groundFilter)
        if covered ~= nil and (covered / pixels) >= VANILLA_LEVEL_COVERAGE then
            level = candidate
            break
        end
    end

    return level, (sum / pixels) / maxLevel
end

---Snaps a real-unit value onto PF's storage steps, measured from state 1 to the map maximum.
-- @param number value Real-unit value
-- @param function conv Internal-to-real converter
-- @param number step
-- @return number snapped
local function snapToDisplayStep(value, step)
    if value == nil or step == nil or step <= 0 then return value end
    return math.floor(value / step + 0.5) * step
end

---Resolves a Precision Farming ValueMap's density handle.
-- @param table valueMap
-- @param integer defaultNumChannels Channel count for a map declaring none, or nil
-- @return integer mapId, integer firstChannel, integer numChannels, or nil
local function getValueMapLayer(valueMap, defaultNumChannels)
    if valueMap == nil then return nil end
    local mapId = tonumber(valueMap.bitVectorMap)
    if mapId == nil then return nil end
    local firstChannel = math.floor(tonumber(valueMap.firstChannel) or 0)
    local numChannels = math.floor(tonumber(valueMap.numChannels) or defaultNumChannels or 0)
    if numChannels <= 0 then return nil end
    return mapId, firstChannel, numChannels
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

---Appends interior sample points kept only when truly inside the field's polygon, not just its bounding box.
-- @param table field
-- @param table samples Accumulator of { x, z } points
local function collectFieldInteriorSamples(field, samples)
    local vertices = getFieldPolygonVertices(field)
    local minX, maxX, minZ, maxZ = fieldPolygonBounds(field)
    if vertices == nil or minX == nil then return end

    -- Spread from near-edge to near-edge, not just the central band, so a localized destruction patch can't outvote crop near the borders.
    local offsets = {
        {0.15, 0.15}, {0.50, 0.15}, {0.85, 0.15},
        {0.15, 0.50}, {0.50, 0.50}, {0.85, 0.50},
        {0.15, 0.85}, {0.50, 0.85}, {0.85, 0.85},
    }

    for _, offset in ipairs(offsets) do
        local x = minX + (maxX - minX) * offset[1]
        local z = minZ + (maxZ - minZ) * offset[2]
        if isPointInPolygon(x, z, vertices) then
            table.insert(samples, { x = x, z = z })
        end
    end
end

---True when a fruit type is a cover crop (cropConfig cover="true" or the native isCatchCrop flag).
-- @param table fruitType
-- @return boolean isCover
local function isFruitTypeCoverCrop(fruitType)
    if fruitType == nil then return false end
    if fruitType.isCatchCrop == true then return true end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.coverCrops == nil or fruitType.name == nil then return false end
    return config.coverCrops[string.upper(tostring(fruitType.name))] == true
end

---True when a fruit type's growth state is cut/withered (harvested residue, not a live crop); cover crops are exempt.
-- @param table fruitType
-- @param number growthState
-- @return boolean isDone
local function isFruitTypeCutOrWithered(fruitType, growthState)
    if fruitType == nil or growthState == nil then return false end
    if isFruitTypeCoverCrop(fruitType) then return false end

    if type(fruitType.getIsCut) == "function" then
        local ok, isCut = pcall(fruitType.getIsCut, fruitType, growthState)
        if ok and isCut then return true end
    elseif fruitType.cutState ~= nil and growthState == tonumber(fruitType.cutState) then
        return true
    end

    if type(fruitType.getIsWithered) == "function" then
        local ok, isWithered = pcall(fruitType.getIsWithered, fruitType, growthState)
        if ok and isWithered then return true end
    elseif fruitType.witheredState ~= nil and growthState == tonumber(fruitType.witheredState) then
        return true
    end

    return false
end

---Majority fruit type over field samples from the density map.
-- @param table field
-- @return integer fruitTypeIndex, or nil
-- @return boolean sampled True when the density map could be read
-- @return integer growthState Representative growth state, or nil
-- Point sampled: off-field points return no fruit type and drop out of the vote.
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
            local fruitType = fruitTypeIndex ~= nil and g_fruitTypeManager ~= nil
                and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex) or nil
            if fruitTypeIndex ~= nil and not isFruitTypeCutOrWithered(fruitType, tonumber(growthState)) then
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
    if bestFruitTypeIndex == nil then return nil, true end

    local representativeGrowthState = nil
    local representativeGrowthCount = 0
    local states = growthStateCounts[bestFruitTypeIndex]
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

    if isFruitTypeCutOrWithered(fruitType, growthState) then return nil end

    return fruitTypeIndex, growthState
end

---Active fruit type: density map first, fieldState fallback (server only) when the density map couldn't be read at all.
-- @param table field
-- @return integer fruitTypeIndex, or nil
-- @return integer growthState, or nil
local function getFieldFruitTypeIndex(field)
    local fruitTypeIndex, sampledDensityMap, growthState = getFieldFruitTypeIndexFromDensityMap(field)
    if sampledDensityMap then return fruitTypeIndex, growthState end
    if isPureClient() then return nil end
    return getFieldFruitTypeIndexFromFieldState(field)
end

---True when a fruit type still has any live (non-destroyed) area in the field polygon.
-- @param table field
-- @param integer fruitTypeIndex
-- @return boolean hasLiveArea
local function fieldHasLiveFruitArea(field, fruitTypeIndex)
    if field == nil or fruitTypeIndex == nil or g_fruitTypeManager == nil
        or DensityMapModifier == nil or DensityMapFilter == nil or DensityValueCompareType == nil
        or g_terrainNode == nil or type(field.getDensityMapPolygon) ~= "function" then
        return false
    end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if desc == nil or desc.terrainDataPlaneId == nil then return false end
    local polygon = field:getDensityMapPolygon()
    if polygon == nil then return false end

    local modifier = DensityMapModifier.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels, g_terrainNode)
    polygon:applyToModifier(modifier)
    local filter = DensityMapFilter.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels)
    filter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
    local _, hits = modifier:executeGet(filter)
    return (tonumber(hits) or 0) > 0
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

---Field-ground mask (GROUND_TYPE above NONE) and the pixels it selects inside a field's polygon.
-- @param table field
-- @return table filter, number pixels, or nil when the field has no worked ground
local function getFieldGroundCoverage(field)
    local filter = RealisticCropRotationManager.makeFieldGroundFilter()
    if filter == nil then return nil end

    local mapId, firstChannel, numChannels = getFieldGroundLayer(FieldDensityMap.GROUND_TYPE)
    local _, pixels = aggregateFieldLayer(field, mapId, firstChannel, numChannels, filter)
    if pixels == nil or pixels <= 0 then return nil end
    return filter, pixels
end

---Counts the field-ground pixels holding one exact value on a vanilla layer.
-- @param table field
-- @param integer layer FieldDensityMap entry
-- @param integer value
-- @param table groundFilter Field-ground mask, or nil when the value implies it
-- @return number pixels
local function countFieldLayerValue(field, layer, value, groundFilter)
    if value == nil then return 0 end
    local _, pixels = aggregateFieldGroundLayer(field, layer,
        DensityValueCompareType.EQUAL, value, nil, groundFilter)
    return pixels or 0
end

---Ground types grouped by the GROWTH_STATE_INDEX the field card reports them as.
-- @return table groups { index, types }, or nil
local function getGroundStateGroups()
    if FieldGroundType == nil or type(FieldGroundType.getValueByType) ~= "function" then return nil end
    if MapOverlayGenerator == nil or MapOverlayGenerator.GROWTH_STATE_INDEX == nil then return nil end

    local indices = MapOverlayGenerator.GROWTH_STATE_INDEX
    return {
        { index = indices.PLOWED,          types = { FieldGroundType.PLOWED } },
        { index = indices.STUBBLE_TILLAGE, types = { FieldGroundType.STUBBLE_TILLAGE } },
        { index = indices.CULTIVATED,      types = { FieldGroundType.CULTIVATED } },
        { index = indices.SEEDBED,         types = { FieldGroundType.SEEDBED, FieldGroundType.ROLLED_SEEDBED } },
    }
end

---Ground state covering most of a field's worked ground.
-- @param table field
-- @param number groundPixels Field-ground pixel count from getFieldGroundCoverage
-- @return integer index GROWTH_STATE_INDEX, or nil when no state covers the field
local function getNativeGroundStateIndex(field, groundPixels)
    local groups = getGroundStateGroups()
    if field == nil or groups == nil or groundPixels == nil then return nil end

    local layer = FieldDensityMap.GROUND_TYPE
    local threshold = groundPixels * FIELD_STATE_COVERAGE
    for _, group in ipairs(groups) do
        if group.index ~= nil then
            -- First group above the threshold wins.
            local pixels = 0
            for _, groundType in ipairs(group.types) do
                if groundType ~= nil then
                    local ok, value = pcall(FieldGroundType.getValueByType, groundType)
                    if ok then pixels = pixels + countFieldLayerValue(field, layer, tonumber(value), nil) end
                end
            end
            if pixels > threshold then return group.index end
        end
    end

    return nil
end

---Soil states the field card reports, each with the layer value the soil overlay paints.
-- @return table states { index, layer, value } in classification order, or nil
local function getSoilStateDefinitions()
    if MapOverlayGenerator == nil or MapOverlayGenerator.SOIL_STATE_INDEX == nil then return nil end
    if FieldDensityMap == nil then return nil end

    local indices = MapOverlayGenerator.SOIL_STATE_INDEX
    local gameplay = Platform ~= nil and Platform.gameplay or nil
    local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local states = {}

    if indices.WATERED ~= nil then
        table.insert(states, { index = indices.WATERED, layer = FieldDensityMap.WATER_LEVEL, value = 1 })
    end
    if indices.MULCHED ~= nil and gameplay ~= nil and gameplay.useStubbleShred == true then
        table.insert(states, { index = indices.MULCHED, layer = FieldDensityMap.STUBBLE_SHRED_LEVEL, value = 1 })
    end
    if indices.NEEDS_ROLLING ~= nil and gameplay ~= nil and gameplay.useRolling == true then
        table.insert(states, { index = indices.NEEDS_ROLLING, layer = FieldDensityMap.ROLLER_LEVEL, value = 1 })
    end
    if indices.NEEDS_PLOWING ~= nil and gameplay ~= nil and gameplay.usePlowCounter == true
        and missionInfo ~= nil and missionInfo.plowingRequiredEnabled == true then
        table.insert(states, { index = indices.NEEDS_PLOWING, layer = FieldDensityMap.PLOW_LEVEL, value = 0 })
    end

    return states
end

---Soil state covering most of a field's worked ground.
-- @param table field
-- @param table groundFilter Field-ground mask from getFieldGroundCoverage
-- @param number groundPixels Field-ground pixel count from getFieldGroundCoverage
-- @return integer index SOIL_STATE_INDEX, or nil when no state covers the field
local function getNativeSoilStateIndex(field, groundFilter, groundPixels)
    local states = getSoilStateDefinitions()
    if field == nil or states == nil or #states == 0 or groundPixels == nil then return nil end

    local threshold = groundPixels * FIELD_STATE_COVERAGE
    for _, state in ipairs(states) do
        if state.layer ~= nil then
            local pixels = countFieldLayerValue(field, state.layer, state.value, groundFilter)
            if pixels > threshold then return state.index end
        end
    end

    return nil
end

---Ground state -> native l10n label (GROWTH_MAP_* via MapOverlayGenerator.L10N_SYMBOL).
-- @param integer index GROWTH_STATE_INDEX
-- @return string label, or nil
local function getNativeGroundStateLabel(index)
    if MapOverlayGenerator == nil or MapOverlayGenerator.L10N_SYMBOL == nil
        or g_i18n == nil or type(g_i18n.getText) ~= "function" then
        return nil
    end
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

---Soil state -> native l10n label (SOIL_MAP_* via MapOverlayGenerator.L10N_SYMBOL).
-- @param integer index SOIL_STATE_INDEX
-- @return string label, or nil
local function getNativeSoilStateLabel(index)
    if MapOverlayGenerator == nil or MapOverlayGenerator.L10N_SYMBOL == nil
        or MapOverlayGenerator.SOIL_STATE_INDEX == nil
        or g_i18n == nil or type(g_i18n.getText) ~= "function" then
        return nil
    end
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

-- Construction / lifecycle.

---Creates the manager (repository + service, caches).
-- @return RealisticCropRotationManager instance
function RealisticCropRotationManager.new()
    local self = setmetatable({}, RealisticCropRotationManager_mt)
    self.repository = RealisticCropRotationRepository.new()
    self.service = RealisticCropRotationService.new(self.repository)
    self.activeCropNameCache = {}
    self.isInitialized = false
    return self
end

---Initializes the manager once (clears state).
function RealisticCropRotationManager:initialize()
    if self.isInitialized then return end
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.fieldStateMemo = nil
    self.isInitialized = true
end

---Clears all state and marks the manager uninitialized.
function RealisticCropRotationManager:cleanup()
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.fieldStateMemo = nil
    self.soilScanMemo = nil
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

---Returns the currently active crop on a farmland (cached), cross-checked against the last confirmed crop.
-- @param integer farmlandId
-- @return string cropName, or nil
-- @return integer fruitTypeIndex, or nil
-- @return integer growthState, or nil
function RealisticCropRotationManager:getActiveCropInfo(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil then return nil end

    local cache = self.activeCropNameCache
    local nowMs = tonumber(g_time) or 0
    local entry = cache ~= nil and cache[numericFarmlandId] or nil
    if entry ~= nil and (nowMs - (entry.tMs or 0)) < ACTIVE_CROP_CACHE_TTL_MS then
        return entry.name, entry.fruitTypeIndex, entry.growthState
    end

    local field = self:getFieldByFarmlandId(numericFarmlandId)
    local resolved, fruitTypeIndex, growthState = getActiveCropNameFromField(field)

    if resolved == nil and entry ~= nil and entry.fruitTypeIndex ~= nil
        and fieldHasLiveFruitArea(field, entry.fruitTypeIndex) then
        -- Falls back to the last confirmed crop.
        resolved, fruitTypeIndex, growthState = entry.name, entry.fruitTypeIndex, entry.growthState
    end

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
    -- Only worth sampling ground state while the field is bare: irrelevant once a crop is growing.
    local groundWorked = currentCropName == nil and self:isFieldGroundWorked(farmlandId)
    local changed = self.service:reconcileActiveCrop(farmlandId, currentCropName, currentFruitTypeIndex, currentGrowthState, groundWorked)
    if changed then
        self:invalidateActiveCropCache(farmlandId)
    end
    return changed
end

---Ground + soil state of a field, both resolved from a single field-ground read.
-- @param integer farmlandId
-- @return table states { groundIndex, soilIndex }, or nil
function RealisticCropRotationManager:getFieldStateIndices(farmlandId)
    local n = tonumber(farmlandId)
    if n == nil then return nil end

    -- Same-frame memo.
    local nowMs = tonumber(g_time) or 0
    if self.fieldStateMemo == nil or self.fieldStateMemo.tMs ~= nowMs then
        self.fieldStateMemo = { tMs = nowMs }
    end
    local memo = self.fieldStateMemo
    if memo[n] ~= nil then return memo[n] end

    local field = self:getFieldByFarmlandId(n)
    if field == nil then return nil end

    local groundFilter, groundPixels = getFieldGroundCoverage(field)
    local entry = {
        groundIndex = getNativeGroundStateIndex(field, groundPixels),
        soilIndex = getNativeSoilStateIndex(field, groundFilter, groundPixels),
    }
    memo[n] = entry
    return entry
end

---True when the field's native ground state shows real tillage work, not just post-harvest stubble.
-- @param integer farmlandId
-- @return boolean isWorked
function RealisticCropRotationManager:isFieldGroundWorked(farmlandId)
    if MapOverlayGenerator == nil or MapOverlayGenerator.GROWTH_STATE_INDEX == nil then return false end

    local states = self:getFieldStateIndices(farmlandId)
    local groundIndex = states ~= nil and states.groundIndex or nil
    if groundIndex == nil then return false end
    return groundIndex ~= MapOverlayGenerator.GROWTH_STATE_INDEX.STUBBLE_TILLAGE
end

---True when this farmland's plan calls the current gap a fallow year.
-- @param integer farmlandId
-- @return boolean isFallow
function RealisticCropRotationManager:isCurrentGapFallow(farmlandId)
    if self.service == nil or type(self.service.isCurrentGapFallow) ~= "function" then return false end
    return self.service:isCurrentGapFallow(farmlandId)
end

---Most important no-crop field status (tillage + soil merged via fieldStatusRank).
-- @param integer farmlandId
-- @return string label, or nil
-- @return string kind "ground" or "soil"
-- @return integer index Native state index
function RealisticCropRotationManager:getCurrentFieldStatus(farmlandId)
    local states = self:getFieldStateIndices(farmlandId)
    if states == nil then return nil end
    local soilIndex, groundIndex = states.soilIndex, states.groundIndex

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
        label = getNativeSoilStateLabel(chosenIndex)
    else
        label = getNativeGroundStateLabel(chosenIndex)
    end
    if label == nil or label == "" then return nil end
    return label, chosenKind, chosenIndex
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

---Max level of a vanilla field density layer, from the field manager or the ground system.
-- @param string managerField FieldManager attribute holding the max, or nil
-- @param integer layer FieldDensityMap entry
-- @return integer maxLevel At least 1
local function getFieldLayerMaxLevel(managerField, layer)
    local maxLevel = nil
    if g_fieldManager ~= nil and managerField ~= nil then
        maxLevel = tonumber(g_fieldManager[managerField])
    end
    if maxLevel == nil and g_currentMission ~= nil and g_currentMission.fieldGroundSystem ~= nil
        and layer ~= nil and type(g_currentMission.fieldGroundSystem.getMaxValue) == "function" then
        local ok, value = pcall(g_currentMission.fieldGroundSystem.getMaxValue,
            g_currentMission.fieldGroundSystem, layer)
        if ok then maxLevel = tonumber(value) end
    end
    return math.max(1, math.floor((tonumber(maxLevel) or 1) + 0.5))
end

---Vanilla lime level (LIME_LEVEL): deepest level covering most of the field.
-- @param integer farmlandId
-- @return integer level
-- @return integer maxLevel
-- @return number ratio Bar fill, 0..1
function RealisticCropRotationManager:getCurrentLimeLevel(farmlandId)
    local layer = FieldDensityMap ~= nil and FieldDensityMap.LIME_LEVEL or nil
    local maxLevel = getFieldLayerMaxLevel("limeLevelMaxValue", layer)

    local level, ratio = getFieldLayerCoverageLevel(self:getFieldByFarmlandId(farmlandId), layer, maxLevel)
    if level == nil then
        local fieldState = self:sampleFieldState(farmlandId)
        level = math.max(0, math.floor((tonumber(fieldState ~= nil and fieldState.limeLevel or 0) or 0) + 0.5))
        ratio = level / maxLevel
    end

    return math.min(level, maxLevel), maxLevel, math.max(0, math.min(1, ratio or 0))
end

---Vanilla fertilisation level (SPRAY_LEVEL): deepest level covering most of the field.
-- @param integer farmlandId
-- @return integer level
-- @return integer maxLevel
-- @return number ratio Bar fill, 0..1
function RealisticCropRotationManager:getCurrentNitrogenLevel(farmlandId)
    local layer = FieldDensityMap ~= nil and FieldDensityMap.SPRAY_LEVEL or nil
    local maxLevel = getFieldLayerMaxLevel("sprayLevelMaxValue", layer)

    local level, ratio = getFieldLayerCoverageLevel(self:getFieldByFarmlandId(farmlandId), layer, maxLevel)
    if level == nil then
        local fieldState = self:sampleFieldState(farmlandId)
        level = math.max(0, math.floor((tonumber(fieldState ~= nil and fieldState.sprayLevel or 0) or 0) + 0.5))
        ratio = level / maxLevel
    end

    return math.min(level, maxLevel), maxLevel, math.max(0, math.min(1, ratio or 0))
end

-- Precision Farming soil reads (nitrogen + pH); vanilla fallback otherwise.

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

---Soil-type pixel counts over a field, keyed by PF's 1-based soil type index.
-- @param table field
-- @param table soilMap PF soil map
-- @param table restrictFilter Optional filter narrowing the counted area
-- @return table weights soilTypeIndex -> pixel count
local function getFieldSoilTypeWeights(field, soilMap, restrictFilter)
    local weights = {}
    if field == nil or soilMap == nil then return weights end

    local mapId = tonumber(soilMap.bitVectorMap)
    local firstChannel = tonumber(soilMap.typeFirstChannel)
    local numChannels = math.floor(tonumber(soilMap.typeNumChannels) or 0)
    if mapId == nil or firstChannel == nil or numChannels <= 0 then return weights end

    for value = 0, (2 ^ numChannels) - 1 do
        local filter = makeDensityFilter(mapId, firstChannel, numChannels, DensityValueCompareType.EQUAL, value)
        local _, pixels = aggregateFieldLayer(field, mapId, firstChannel, numChannels, filter, restrictFilter)
        if pixels ~= nil and pixels > 0 then
            weights[value + 1] = pixels
        end
    end
    return weights
end

---Finds one representative world position per soil type present in a field.
-- @param table field
-- @param table soilMap PF soil map
-- @param integer expectedCount Soil type count to locate before stopping
-- @return table positions soilTypeIndex -> { x, z }
local function locateSoilTypePositions(field, soilMap, expectedCount)
    local positions = {}
    if field == nil or soilMap == nil or type(soilMap.getTypeIndexAtWorldPos) ~= "function" then return positions end

    local minX, maxX, minZ, maxZ = fieldPolygonBounds(field)
    if minX == nil then return positions end

    local vertices = getFieldPolygonVertices(field)
    local steps = SOIL_TYPE_LOCATOR_STEPS
    local stepX = (maxX - minX) / (steps - 1)
    local stepZ = (maxZ - minZ) / (steps - 1)
    local found = 0

    for i = 0, steps - 1 do
        for j = 0, steps - 1 do
            local x, z = minX + i * stepX, minZ + j * stepZ
            if vertices == nil or isPointInPolygon(x, z, vertices) then
                local ok, index = pcall(soilMap.getTypeIndexAtWorldPos, soilMap, x, z)
                if ok and type(index) == "number" and positions[index] == nil then
                    positions[index] = { x = x, z = z }
                    found = found + 1
                    if expectedCount ~= nil and found >= expectedCount then return positions end
                end
            end
        end
    end
    return positions
end

---Live PF soil read: field-average N and pH, with targets weighted by the field's soil-type mix.
-- @param integer farmlandId
-- @return table record, false when not analysed, or nil when PF is absent
function RealisticCropRotationManager:scanFieldSoil(farmlandId)
    local pf = self:getPrecisionFarming()
    if pf == nil then return nil end
    local nMap, phMap, soilMap = pf.nitrogenMap, pf.pHMap, pf.soilMap
    if nMap == nil and phMap == nil then return nil end

    local n = tonumber(farmlandId)
    if n == nil then return nil end

    -- Same-frame memo: one panel refresh reads nitrogen and pH four times.
    local nowMs = tonumber(g_time) or 0
    if self.soilScanMemo == nil or self.soilScanMemo.tMs ~= nowMs then
        self.soilScanMemo = { tMs = nowMs }
    end
    local memo = self.soilScanMemo
    local memoed = memo[n]
    if memoed ~= nil then return memoed.value end

    local field = self:getFieldByFarmlandId(n)
    if field == nil then return nil end
    if self:isPFSoilLocked(pf, field) then
        memo[n] = { value = false }
        return false
    end

    -- Capabilities, resolved once.
    local nCanLevel  = nMap ~= nil and type(nMap.getNitrogenValueFromInternalValue) == "function"
    local phCanLevel = phMap ~= nil and type(phMap.getPhValueFromInternalValue) == "function"
    local phCanOptimal = phMap ~= nil and type(phMap.getOptimalPHValueForSoilTypeIndex) == "function"
    local nCanTargetAtPos = nMap ~= nil and type(nMap.getTargetLevelAtWorldPos) == "function"

    local nMaxInternal = (nMap ~= nil and tonumber(nMap.maxValue)) or 45
    local function nConv(level)
        return tonumber(nMap:getNitrogenValueFromInternalValue(math.max(0, math.min(level, nMaxInternal))))
    end
    local phMaxInternal = (phMap ~= nil and tonumber(phMap.maxValue)) or 31
    local function phConv(level)
        return tonumber(phMap:getPhValueFromInternalValue(math.max(0, math.min(level, phMaxInternal))))
    end

    local rec = {}

    -- Crop mask, shared by the nitrogen average and its target weighting.
    local cropFilter = nil
    local _, activeFruitTypeIndex = self:getActiveCropInfo(n)
    if activeFruitTypeIndex ~= nil and g_fruitTypeManager ~= nil
        and type(g_fruitTypeManager.getFruitTypeByIndex) == "function" then
        local desc = g_fruitTypeManager:getFruitTypeByIndex(activeFruitTypeIndex)
        local descChannels = desc ~= nil and math.floor(tonumber(desc.numStateChannels) or 0) or 0
        if desc ~= nil and desc.terrainDataPlaneId ~= nil and descChannels > 0 then
            cropFilter = makeDensityFilter(desc.terrainDataPlaneId, desc.startStateChannel, descChannels,
                DensityValueCompareType.BETWEEN, 1, (2 ^ descChannels) - 1)
        end
    end

    -- Field-ground mask, shared by the pH average and its target weighting.
    local groundFilter = getFieldGroundCoverage(field)

    if phCanLevel then
        local mapId, firstChannel, numChannels = getValueMapLayer(phMap)
        if mapId ~= nil then
            local sum, pixels = aggregateFieldLayer(field, mapId, firstChannel, numChannels, groundFilter)
            if sum ~= nil and pixels > 0 then
                rec.phActual = snapToDisplayStep(phConv(sum / pixels), PF_PH_DISPLAY_STEP)
                rec.phMin, rec.phMax = phConv(0) or 0, phConv(phMaxInternal) or 0
            end
        end
    end

    if nCanLevel then
        local mapId, firstChannel, numChannels = getValueMapLayer(nMap)
        if mapId ~= nil then
            -- Tramline pixels dropped via PF's tramline map.
            local tramlineFilter = nil
            local tMapId, tFirstChannel, tNumChannels = getValueMapLayer(pf.tramlineMap, 1)
            if tMapId ~= nil then
                tramlineFilter = makeDensityFilter(tMapId, tFirstChannel, tNumChannels,
                    DensityValueCompareType.EQUAL, 0)
            end

            local sum, pixels = aggregateFieldLayer(field, mapId, firstChannel, numChannels, cropFilter, tramlineFilter)
            -- Field entirely under tramlines: falls back to the whole cropped area.
            if sum == nil or pixels == 0 then
                sum, pixels = aggregateFieldLayer(field, mapId, firstChannel, numChannels, cropFilter)
            end

            if sum ~= nil and pixels > 0 then
                rec.nActual = snapToDisplayStep(nConv(sum / pixels), PF_N_DISPLAY_STEP)
            end
        end
    end

    -- Targets weighted by soil-type pixel counts over worked ground.
    local soilWeights = getFieldSoilTypeWeights(field, soilMap, groundFilter)
    if next(soilWeights) ~= nil then
        if phCanLevel and phCanOptimal then
            local sum, total = 0, 0
            for index, pixels in pairs(soilWeights) do
                local ok, optimal = pcall(phMap.getOptimalPHValueForSoilTypeIndex, phMap, index)
                if ok and type(optimal) == "number" and optimal > 0 then
                    if optimal > 9 then optimal = phConv(optimal) end
                    if type(optimal) == "number" then
                        sum, total = sum + optimal * pixels, total + pixels
                    end
                end
            end
            if total > 0 then
                rec.phTarget = snapToDisplayStep(sum / total, PF_PH_DISPLAY_STEP)
            end
        end

        if nCanLevel and nCanTargetAtPos and rec.nActual ~= nil then
            -- Nitrogen target weighted over the cropped area only.
            local cropWeights = getFieldSoilTypeWeights(field, soilMap, cropFilter)
            if next(cropWeights) == nil then cropWeights = soilWeights end

            local expectedCount = 0
            for _ in pairs(cropWeights) do expectedCount = expectedCount + 1 end

            local positions = locateSoilTypePositions(field, soilMap, expectedCount)
            local sum, total = 0, 0
            for index, pixels in pairs(cropWeights) do
                local position = positions[index]
                if position ~= nil then
                    local ok, target = pcall(nMap.getTargetLevelAtWorldPos, nMap, position.x, position.z)
                    if ok and type(target) == "number" then
                        sum, total = sum + target * pixels, total + pixels
                    end
                end
            end
            if total > 0 then
                rec.nTarget = snapToDisplayStep(nConv(sum / total), PF_N_DISPLAY_STEP)
            end
        end
    end

    memo[n] = { value = rec }
    return rec
end

---PF nitrogen (kg/ha): field-average available N + crop requirement.
-- @param integer farmlandId
-- @return number actual, false when not analysed, or nil when no PF (vanilla fallback)
-- @return number target Crop requirement, or nil when no crop
function RealisticCropRotationManager:getNitrogenLevel(farmlandId)
    local rec = self:scanFieldSoil(farmlandId)
    if rec == nil or rec == false then return rec end
    if rec.nActual == nil then return nil end
    return rec.nActual, rec.nTarget
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


---Localised growth-tier label (growing / ready to prepare / ready to harvest / cut / withered).
-- @param table fruitType
-- @param integer growthState
-- @return string label, or nil
-- @return boolean isActionable True when the player has something to do now (prepare/harvest)
function RealisticCropRotationManager.getGrowthTierText(fruitType, growthState)
    if fruitType == nil then return nil end
    growthState = tonumber(growthState) or 0
    if growthState <= 0 then return nil end
    if g_i18n == nil or g_i18n.getText == nil then return nil end

    if fruitType.witheredState ~= nil and growthState == tonumber(fruitType.witheredState) then
        return g_i18n:getText("ui_growthMapWithered"), false
    end
    if type(fruitType.cutStates) == "table" and fruitType.cutStates[growthState] then
        return g_i18n:getText("ui_growthMapCut"), false
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
            return g_i18n:getText("ui_growthMapGrowing"), false
        end
    end

    if minPrep >= 0 and growthState >= minPrep and growthState <= maxPrep then
        return g_i18n:getText("ui_growthMapReadyToPrepareForHarvest"), true
    end
    if minHarvest > 0 and growthState >= minHarvest and growthState <= maxHarvest then
        return g_i18n:getText("ui_growthMapReadyToHarvest"), true
    end

    return nil, false
end

---"(X/Y) · <tier>" for active tiers, tier alone for terminal ones.
-- @param table fruitType
-- @param integer growthState
-- @return string text, or nil
-- @return boolean isActionable True when the player has something to do now (prepare/harvest)
function RealisticCropRotationManager.classifyGrowthStage(fruitType, growthState)
    local tierText, isActionable = RealisticCropRotationManager.getGrowthTierText(fruitType, growthState)
    if tierText == nil then return nil end
    local numbers = RealisticCropRotationManager.getGrowthStageNumbers(fruitType, growthState)
    if numbers == nil then return tierText, isActionable end
    return string.format("(%s) · %s", numbers, tierText), isActionable
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

    -- Denominator = maturity: first preparing state, else last harvest-ready state.
    local maturity = tonumber(fruitType.maxHarvestingGrowthState) or 0
    if maturity <= 0 then return nil end
    if minPreparing >= 1 and minPreparing < maturity then
        maturity = minPreparing
    end

    return string.format("%d/%d", math.min(growthState, maturity), maturity)
end

---Per-field card info: growth stage + the on-foot weed line.
-- @param integer farmlandId
-- @return table info { growthStageText, growthIsAction, weedHeader, weedActionText }, or nil when no crop
function RealisticCropRotationManager:getFieldCropInfo(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return nil end
    if g_fruitTypeManager == nil then return nil end

    -- Reads the cached majority-vote crop.
    local _, fruitTypeIndex, growthState = self:getActiveCropInfo(numericFarmlandId)
    fruitTypeIndex = normalizeFruitTypeIndex(fruitTypeIndex)
    if fruitTypeIndex == nil then return nil end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then return nil end
    growthState = tonumber(growthState) or 0

    -- Reads the weed line from a live FieldState (mirrors PlayerHUDUpdater:fieldAddWeed).
    local weedHeader, weedValue
    local field = self:getFieldByFarmlandId(farmlandId)
    if field ~= nil and FieldState ~= nil
        and type(field.posX) == "number" and type(field.posZ) == "number" then
        local fieldState = FieldState.new()
        if type(fieldState.update) == "function" then
            fieldState:update(field.posX, field.posZ)
            if fieldState.isValid then
                fieldState.farmlandId = numericFarmlandId
                if RealisticCropRotationHud ~= nil and RealisticCropRotationHud.getWeedLineFromGame ~= nil then
                    weedHeader, weedValue = RealisticCropRotationHud.getWeedLineFromGame(fieldState)
                end
            end
        end
    end

    local growthStageText, growthIsAction = RealisticCropRotationManager.classifyGrowthStage(fruitType, growthState)

    return {
        growthStageText = growthStageText,
        growthIsAction  = growthIsAction,
        weedHeader      = weedHeader,
        weedActionText  = weedValue,
    }
end

