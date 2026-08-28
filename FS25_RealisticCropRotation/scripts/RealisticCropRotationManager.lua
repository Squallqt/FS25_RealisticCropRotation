-- Copyright © 2026 Squallqt. All rights reserved.
-- Facade over Repository + Service for the GUI/HUD reads.
RealisticCropRotationManager = {}
local RealisticCropRotationManager_mt = Class(RealisticCropRotationManager)

-- Grid resolution for locating representative points inside a read region.
local REGION_SCAN_STEPS = 16

-- Field share that must reach a level for that level to be reported.
local VANILLA_LEVEL_COVERAGE = 0.90

-- Field-ground share a soil/ground state must cover to become the field's status.
local FIELD_STATE_COVERAGE = 0.50

-- Field share a crop must cover to count as standing.
local MIN_CROP_COVERAGE = 0.05

-- Minimum field area considered relevant for crop rotation.
local MIN_ROTATION_AREA_HA = 0.01

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
    return g_farmlandManager:getFarmlandById(farmlandId)
end

---Returns the owning farm id for a farmland.
-- @param integer farmlandId
-- @return integer farmId or nil
local function getOwnerFarmIdForFarmland(farmlandId)
    if g_farmlandManager == nil then return nil end
    return g_farmlandManager:getFarmlandOwner(tonumber(farmlandId) or farmlandId)
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
local function fieldPolygonBounds(field)
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

-- READ REGIONS

---World-space bounding box of a farmland parcel.
-- @param table farmland
-- @return number minX, minZ, maxX, maxZ, or nil when the parcel has no bounding box
local function getFarmlandBounds(farmland)
    local box = type(farmland) == "table" and farmland.boundingBox or nil
    if type(box) ~= "table" then return nil end
    local minX, minZ = tonumber(box.minX), tonumber(box.minZ)
    local maxX, maxZ = tonumber(box.maxX), tonumber(box.maxZ)
    if minX == nil or minZ == nil or maxX == nil or maxZ == nil then return nil end
    if maxX <= minX or maxZ <= minZ then return nil end
    return minX, minZ, maxX, maxZ
end

---Density filter selecting one parcel's pixels on the farmland id map, or every pixel outside it.
-- @param integer farmlandId
-- @param boolean outside True to select every pixel outside the parcel
-- @return table filter, or nil
function RealisticCropRotationManager.makeFarmlandFilter(farmlandId, outside)
    if g_farmlandManager == nil then return nil end
    local localMap = g_farmlandManager:getLocalMap()
    if localMap == nil then return nil end
    return makeDensityFilter(localMap, 0, g_farmlandManager.numberOfBits,
        outside and DensityValueCompareType.NOTEQUAL or DensityValueCompareType.EQUAL, farmlandId)
end

local makeFarmlandFilter = RealisticCropRotationManager.makeFarmlandFilter

---Density filter selecting everything outside a parcel region; nil for a mapped field.
-- @param table region
-- @return table filter, or nil
function RealisticCropRotationManager.makeOutsideRegionFilter(region)
    if region == nil or region.farmlandId == nil then return nil end
    return makeFarmlandFilter(region.farmlandId, true)
end

---Representative world point on a parcel's field ground, the scanned point closest to its bounding-box centre.
-- @param table region Parcel region
-- @return number x, number z, or nil when no scanned point falls on the parcel's field ground
local function locateParcelSamplePoint(region)
    local terrainDetailId = g_currentMission ~= nil and g_currentMission.terrainDetailId or nil
    if terrainDetailId == nil or getDensityAtWorldPos == nil or g_farmlandManager == nil then
        return nil
    end

    local centerX, centerZ = (region.minX + region.maxX) * 0.5, (region.minZ + region.maxZ) * 0.5
    local stepX = (region.maxX - region.minX) / (REGION_SCAN_STEPS - 1)
    local stepZ = (region.maxZ - region.minZ) / (REGION_SCAN_STEPS - 1)

    local bestX, bestZ, bestDistance = nil, nil, nil
    for i = 0, REGION_SCAN_STEPS - 1 do
        for j = 0, REGION_SCAN_STEPS - 1 do
            local x, z = region.minX + i * stepX, region.minZ + j * stepZ
            local distance = (x - centerX) ^ 2 + (z - centerZ) ^ 2
            if (bestDistance == nil or distance < bestDistance)
                and tonumber(g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)) == region.farmlandId
                and getDensityAtWorldPos(terrainDetailId, x, 0, z) ~= 0 then
                bestX, bestZ, bestDistance = x, z, distance
            end
        end
    end
    return bestX, bestZ
end

---Builds a parcel bounding-box region narrowed by its farmland mask.
-- @param integer farmlandId
-- @return table region, or nil when the parcel mask is unavailable
local function buildFarmlandRegion(farmlandId)
    local minX, minZ, maxX, maxZ = getFarmlandBounds(getFarmlandById(farmlandId))
    if minX == nil then return nil end

    local filter = makeFarmlandFilter(farmlandId)
    if filter == nil then return nil end

    return {
        farmlandId = farmlandId,
        minX = minX, minZ = minZ, maxX = maxX, maxZ = maxZ,
        filter = filter,
    }
end

---Builds the ground area a farmland's native reads run over: the mapped field's polygon, or the parcel's bounding box narrowed by the farmland mask.
-- @param integer farmlandId
-- @param table field Mapped Field object, or nil
-- @return table region, or nil when neither a field polygon nor a parcel mask is available
local function buildFieldRegion(farmlandId, field)
    if field ~= nil then
        return {
            field = field,
            vertices = getFieldPolygonVertices(field),
            sampleX = tonumber(field.posX),
            sampleZ = tonumber(field.posZ),
        }
    end

    local region = buildFarmlandRegion(farmlandId)
    if region ~= nil then
        region.sampleX, region.sampleZ = locateParcelSamplePoint(region)
    end
    return region
end

---World-space bounds of a read region.
-- @param table region
-- @return number minX, maxX, minZ, maxZ, or nil when the region has no usable geometry
local function regionBounds(region)
    if region.field ~= nil then return fieldPolygonBounds(region.field) end
    return region.minX, region.maxX, region.minZ, region.maxZ
end

---World-space bounds of a read region, in the minX, minZ, maxX, maxZ order the painting code takes.
-- @param table region
-- @return number minX, minZ, maxX, maxZ, or nil when the region has no usable geometry
function RealisticCropRotationManager.regionWorldBounds(region)
    if region == nil then return nil end
    local minX, maxX, minZ, maxZ = regionBounds(region)
    if minX == nil then return nil end
    return minX, minZ, maxX, maxZ
end

---True when a world point lies inside a read region.
-- @param table region
-- @param number x
-- @param number z
-- @return boolean inside
local function isPointInRegion(region, x, z)
    if region.farmlandId ~= nil then
        return tonumber(g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)) == region.farmlandId
    end
    return region.vertices == nil or isPointInPolygon(x, z, region.vertices)
end

---Binds a modifier to a read region's ground area.
-- @param table region
-- @param table modifier
-- @return boolean applied
function RealisticCropRotationManager.applyRegionToModifier(region, modifier)
    if region == nil or modifier == nil then return false end
    if region.field ~= nil then
        local polygon = region.field:getDensityMapPolygon()
        if polygon == nil then return false end
        polygon:applyToModifier(modifier)
        return true
    end

    if DensityCoordType == nil then return false end
    modifier:setParallelogramWorldCoords(
        region.minX, region.minZ, region.maxX, region.minZ, region.minX, region.maxZ,
        DensityCoordType.POINT_POINT_POINT)
    return true
end

local applyRegionToModifier = RealisticCropRotationManager.applyRegionToModifier

---Sums a density layer over a read region.
-- @param table region
-- @param integer mapId
-- @param integer firstChannel
-- @param integer numChannels
-- @param table filterA Optional density filter
-- @param table filterB Optional second density filter
-- @return number sum, number pixels, number totalPixels, or nil when the region cannot be bound
local function aggregateRegionLayer(region, mapId, firstChannel, numChannels, filterA, filterB)
    if region == nil or mapId == nil or firstChannel == nil or numChannels == nil then return nil end
    if DensityMapModifier == nil or g_terrainNode == nil then return nil end

    local modifier = DensityMapModifier.new(mapId, firstChannel, numChannels, g_terrainNode)
    if modifier == nil then return nil end
    if not applyRegionToModifier(region, modifier) then return nil end

    local f1, f2, f3 = filterA, filterB, region.filter
    if f1 == nil then f1, f2, f3 = f2, f3, nil end
    if f2 == nil then f2, f3 = f3, nil end

    local ok, sum, pixels, totalPixels = pcall(modifier.executeGet, modifier, f1, f2, f3)
    if not ok then return nil end
    return tonumber(sum) or 0, tonumber(pixels) or 0, tonumber(totalPixels) or 0
end

---Resolves a vanilla field density layer's map handle.
-- @param integer layer FieldDensityMap entry
-- @return integer mapId, integer firstChannel, integer numChannels, or nil
local function getFieldGroundLayer(layer)
    local system = g_currentMission ~= nil and g_currentMission.fieldGroundSystem or nil
    if system == nil or layer == nil then return nil end
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

---Sums a vanilla field layer over a read region, narrowed by an optional value filter and mask.
-- @param table region
-- @param integer layer FieldDensityMap entry
-- @param integer compareType DensityValueCompareType, or nil to take the whole region
-- @param number value
-- @param number maxValue Upper bound for BETWEEN, or nil
-- @param table maskFilter Optional second filter
-- @return number sum, number pixels, or nil when the layer or region is unavailable
local function aggregateRegionGroundLayer(region, layer, compareType, value, maxValue, maskFilter)
    local mapId, firstChannel, numChannels = getFieldGroundLayer(layer)
    if mapId == nil then return nil end

    local filter = nil
    if compareType ~= nil then
        filter = makeDensityFilter(mapId, firstChannel, numChannels, compareType, value, maxValue)
        if filter == nil then return nil end
    end

    return aggregateRegionLayer(region, mapId, firstChannel, numChannels, filter, maskFilter)
end

---Deepest vanilla layer level covering VANILLA_LEVEL_COVERAGE of the region, plus the region-average ratio.
-- @param table region
-- @param integer layer FieldDensityMap entry
-- @param integer maxLevel
-- @return integer level Deepest sufficiently covered level, 0 when none, or nil when the region has no worked ground
-- @return number ratio Region average over maxLevel, for the bar fill
local function getRegionLayerCoverageLevel(region, layer, maxLevel)
    local groundFilter = RealisticCropRotationManager.makeFieldGroundFilter()
    local sum, pixels = aggregateRegionGroundLayer(region, layer, nil, nil, nil, groundFilter)
    if sum == nil or pixels == nil or pixels <= 0 then return nil end

    local level = 0
    for candidate = maxLevel, 1, -1 do
        local _, covered = aggregateRegionGroundLayer(region, layer,
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

---Dominant map-visible fruit type in a read region, counted natively over its whole ground area.
-- @param table region
-- @param integer hintFruitTypeIndex Previously detected fruit type, or nil
-- @param number capacity Region pixel capacity, or nil
-- @param integer hintGrowthState Previously detected growth state, or nil
-- @return integer fruitTypeIndex, or nil
-- @return integer growthState, or nil
-- @return integer pixels Cells the winning crop covers
local function getRegionFruitTypeIndex(region, hintFruitTypeIndex, capacity, hintGrowthState)
    if region == nil or g_fruitTypeManager == nil
        or DensityMapFilter == nil or DensityValueCompareType == nil then
        return nil
    end
    local fruitTypes = g_fruitTypeManager:getFruitTypes()

    local function countPixels(desc)
        local filter = DensityMapFilter.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels)
        filter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
        local _, pixels = aggregateRegionLayer(region, desc.terrainDataPlaneId,
            desc.startStateChannel, desc.numStateChannels, filter)
        return pixels or 0
    end

    local function isReadable(desc)
        return desc ~= nil and desc.shownOnMap == true and desc.terrainDataPlaneId ~= nil
            and desc.startStateChannel ~= nil and desc.numStateChannels ~= nil
    end

    local bestDesc, bestPixels = nil, 0
    -- The crop last seen here is tried first.
    local hint = normalizeFruitTypeIndex(hintFruitTypeIndex)
    if hint ~= nil then
        local desc = g_fruitTypeManager:getFruitTypeByIndex(hint)
        if isReadable(desc) then bestDesc, bestPixels = desc, countPixels(desc) end
    end

    -- The sweep stops once a crop passes half the region.
    local majority = (tonumber(capacity) or 0) > 0 and capacity / 2 or nil
    if majority == nil or bestPixels <= majority then
        for _, desc in pairs(fruitTypes) do
            if isReadable(desc) and desc ~= bestDesc then
                local pixels = countPixels(desc)
                if pixels > bestPixels then bestDesc, bestPixels = desc, pixels end
                if majority ~= nil and bestPixels > majority then break end
            end
        end
    end
    if bestDesc == nil or bestPixels <= 0 then return nil end

    local maxState = 0
    for state in pairs(bestDesc.growthStateToName or {}) do
        state = tonumber(state)
        if state ~= nil and state > maxState then maxState = state end
    end
    for _, key in ipairs({ "numGrowthStates", "maxHarvestingGrowthState", "maxPreparingGrowthState",
        "cutState", "witheredState", "mulchedState", "rolledCutState" }) do
        local value = tonumber(bestDesc[key])
        if value ~= nil and value > maxState then maxState = value end
    end

    local bestState, bestStatePixels = nil, 0
    local stateMajority = bestPixels / 2

    local function countState(state)
        local filter = DensityMapFilter.new(bestDesc.terrainDataPlaneId, bestDesc.startStateChannel, bestDesc.numStateChannels)
        filter:setValueCompareParams(DensityValueCompareType.EQUAL, state)
        local _, pixels = aggregateRegionLayer(region, bestDesc.terrainDataPlaneId,
            bestDesc.startStateChannel, bestDesc.numStateChannels, filter)
        return pixels or 0
    end

    -- The stage last seen here is tried first.
    local stateHint = tonumber(hintGrowthState)
    if stateHint ~= nil and stateHint >= 1 and stateHint <= maxState then
        bestState, bestStatePixels = stateHint, countState(stateHint)
    end
    if bestStatePixels <= stateMajority then
        for state = 1, maxState do
            if state ~= stateHint then
                local pixels = countState(state)
                if pixels > bestStatePixels then bestState, bestStatePixels = state, pixels end
                if bestStatePixels > stateMajority then break end
            end
        end
    end

    return normalizeFruitTypeIndex(bestDesc.index), bestState, bestPixels
end

---Resolves the active crop name (+ index, growth) from a read region.
-- @param table region
-- @param integer hintFruitTypeIndex Previously detected fruit type, or nil
-- @param number capacity Region pixel capacity, or nil
-- @param integer hintGrowthState Previously detected growth state, or nil
-- @return string cropName, or nil
-- @return integer fruitTypeIndex, or nil
-- @return integer growthState, or nil
local function getActiveCropNameFromRegion(region, hintFruitTypeIndex, capacity, hintGrowthState)
    local fruitTypeIndex, growthState, pixels = getRegionFruitTypeIndex(region, hintFruitTypeIndex, capacity, hintGrowthState)
    if fruitTypeIndex == nil or g_fruitTypeManager == nil then return nil end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil or fruitType.name == nil or fruitType.name == "" then return nil end
    return tostring(fruitType.name), fruitTypeIndex, growthState, pixels
end

---Builds a fresh, validated FieldState at a region's sample point.
-- @param table region
-- @return table fieldState, or nil
local function sampleFieldStateInRegion(region)
    if region == nil or FieldState == nil then return nil end
    if type(region.sampleX) ~= "number" or type(region.sampleZ) ~= "number" then return nil end

    local fieldState = FieldState.new()
    fieldState:update(region.sampleX, region.sampleZ)
    if not fieldState.isValid then return nil end
    return fieldState
end

---Field-ground mask (GROUND_TYPE above NONE) and the pixels it selects inside a read region.
-- @param table region
-- @return table filter, number pixels, or nil when the region has no worked ground
local function getRegionGroundCoverage(region)
    local filter = RealisticCropRotationManager.makeFieldGroundFilter()
    if filter == nil then return nil end

    local mapId, firstChannel, numChannels = getFieldGroundLayer(FieldDensityMap.GROUND_TYPE)
    local _, pixels = aggregateRegionLayer(region, mapId, firstChannel, numChannels, filter)
    if pixels == nil or pixels <= 0 then return nil end
    return filter, pixels
end

---Worked field ground inside a region, in hectares.
-- @param table region
-- @return number areaHa
local function measureRegionFieldAreaHa(region)
    local _, pixels = getRegionGroundCoverage(region)
    if pixels == nil or pixels <= 0 then return 0 end

    local terrainSize = g_currentMission ~= nil and tonumber(g_currentMission.terrainSize) or nil
    local mapId = FieldDensityMap ~= nil and getFieldGroundLayer(FieldDensityMap.GROUND_TYPE) or nil
    local mapSize = mapId ~= nil and getDensityMapSize(mapId) or nil
    if terrainSize == nil or mapSize == nil or mapSize <= 0 then return 0 end

    local pixelSize = terrainSize / mapSize
    return MathUtil.areaToHa(pixels, pixelSize * pixelSize)
end

---Counts the field-ground pixels holding one exact value on a vanilla layer.
-- @param table region
-- @param integer layer FieldDensityMap entry
-- @param integer value
-- @param table groundFilter Field-ground mask, or nil when the value implies it
-- @return number pixels
local function countRegionLayerValue(region, layer, value, groundFilter)
    if value == nil then return 0 end
    local _, pixels = aggregateRegionGroundLayer(region, layer,
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

---Ground state covering most of a region's worked ground.
-- @param table region
-- @param number groundPixels Field-ground pixel count from getRegionGroundCoverage
-- @return integer index GROWTH_STATE_INDEX, or nil when no state covers the region
local function getNativeGroundStateIndex(region, groundPixels)
    local groups = getGroundStateGroups()
    if region == nil or groups == nil or groundPixels == nil then return nil end

    local layer = FieldDensityMap.GROUND_TYPE
    local threshold = groundPixels * FIELD_STATE_COVERAGE
    for _, group in ipairs(groups) do
        if group.index ~= nil then
            local pixels = 0
            for _, groundType in ipairs(group.types) do
                if groundType ~= nil then
                    local ok, value = pcall(FieldGroundType.getValueByType, groundType)
                    if ok then pixels = pixels + countRegionLayerValue(region, layer, tonumber(value), nil) end
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

---Soil state covering most of a region's worked ground.
-- @param table region
-- @param table groundFilter Field-ground mask from getRegionGroundCoverage
-- @param number groundPixels Field-ground pixel count from getRegionGroundCoverage
-- @return integer index SOIL_STATE_INDEX, or nil when no state covers the region
local function getNativeSoilStateIndex(region, groundFilter, groundPixels)
    local states = getSoilStateDefinitions()
    if region == nil or states == nil or #states == 0 or groundPixels == nil then return nil end

    local threshold = groundPixels * FIELD_STATE_COVERAGE
    for _, state in ipairs(states) do
        if state.layer ~= nil then
            local pixels = countRegionLayerValue(region, state.layer, state.value, groundFilter)
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
    self.rotationAreaHaCache = {}
    self.fieldRegions = {}
    self.isInitialized = false
    return self
end

function RealisticCropRotationManager:initialize()
    if self.isInitialized then return end
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.fieldStateMemo = nil
    self.rotationAreaHaCache = {}
    self.fieldRegions = {}
    self.isInitialized = true
end

function RealisticCropRotationManager:cleanup()
    self.repository:clear()
    self.service:reset()
    self.activeCropNameCache = {}
    self.fieldStateMemo = nil
    self.soilScanMemo = nil
    self.rotationAreaHaCache = nil
    self.fieldRegions = {}
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

---Crop standing on the field and not yet in history.
-- @param integer farmlandId
-- @return string cropName, or nil for none or a cover crop
function RealisticCropRotationManager:getPendingHistoryCrop(farmlandId)
    local cropName = self.repository:getLastKnownActiveCrop(farmlandId)
    if cropName == nil or cropName == "" then
        -- Field not reconciled yet: read the crop straight off the ground.
        cropName = self:getActiveCropName(farmlandId)
    end
    if cropName == nil or cropName == "" then return nil end
    cropName = string.upper(tostring(cropName))
    if self.service:isCoverCropForRotationHistory(nil, cropName) then return nil end
    return cropName
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

---Normalizes and validates a main-plan or cover-plan crop name against the loaded crop configuration.
-- @param string cropName
-- @param boolean isCover
-- @return string normalizedName, or nil
-- @return boolean valid
local function normalizePlanCropName(cropName, isCover)
    local value = string.upper(tostring(cropName or ""))
    if value == "" then return value, true end
    if RealisticCropRotation.isFallowCrop(value) then
        if isCover then return nil, false end
        return value, true
    end
    if g_fruitTypeManager == nil or type(g_fruitTypeManager.getFruitTypeByName) ~= "function"
        or g_fruitTypeManager:getFruitTypeByName(value) == nil then
        return nil, false
    end

    local config = RealisticCropRotation.cropConfig
    local family = config ~= nil and config.families ~= nil and config.families[value] or nil
    local configuredCover = config ~= nil and config.coverCrops ~= nil and config.coverCrops[value] == true
    if isCover then
        if family ~= "COVER" or not configuredCover then return nil, false end
    elseif family == nil or family == "COVER" or configuredCover then
        return nil, false
    end

    return value, true
end

---Validates and sets one year slot of a farmland's main-crop rotation plan.
-- @param integer farmlandId
-- @param integer yearIdx Slot 1-4
-- @param string cropName Crop name, or "" to clear
-- @return boolean changed
-- @return boolean valid
function RealisticCropRotationManager:setRotationPlanYear(farmlandId, yearIdx, cropName)
    local n = tonumber(farmlandId)
    local y = tonumber(yearIdx)
    if n == nil or n <= 0 or y == nil or y < 1 or y > 4 then return false, false end
    local value, valid = normalizePlanCropName(cropName, false)
    if not valid then return false, false end
    return self.repository:setPlanYear(n, y, value)
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

---Validates and sets one year slot of a farmland's cover-crop plan.
-- @param integer farmlandId
-- @param integer yearIdx Slot 1-4
-- @param string cropName Cover crop name, or "" to clear
-- @return boolean changed
-- @return boolean valid
function RealisticCropRotationManager:setRotationCoverPlanYear(farmlandId, yearIdx, cropName)
    local n = tonumber(farmlandId)
    local y = tonumber(yearIdx)
    if n == nil or n <= 0 or y == nil or y < 1 or y > 4 then return false, false end
    local value, valid = normalizePlanCropName(cropName, true)
    if not valid then return false, false end
    return self.repository:setCoverPlanYear(n, y, value)
end

---Clears a farmland's main and cover plans.
-- @param integer farmlandId
-- @return boolean changed
function RealisticCropRotationManager:clearRotationPlan(farmlandId)
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
    if g_fieldManager == nil then return nil end
    return g_fieldManager.farmlandIdFieldMapping[n]
end

---Ground area a farmland's native reads run over, cached after successful resolution.
-- @param integer farmlandId
-- @return table region, or nil when the farmland has neither a field polygon nor a parcel mask
function RealisticCropRotationManager:getFieldRegion(farmlandId)
    local n = tonumber(farmlandId)
    if n == nil or n <= 0 then return nil end

    local cached = self.fieldRegions[n]
    if cached ~= nil then return cached end

    local region = buildFieldRegion(n, self:getFieldByFarmlandId(n))
    if region ~= nil then self.fieldRegions[n] = region end
    return region
end

---Current field-ground area of a farmland in hectares.
-- @param integer farmlandId
-- @return number areaHa
function RealisticCropRotationManager:getRotationAreaHa(farmlandId)
    local n = tonumber(farmlandId)
    if n == nil or n <= 0 then return 0 end

    self.rotationAreaHaCache = self.rotationAreaHaCache or {}
    local cached = self.rotationAreaHaCache[n]
    if cached ~= nil then return cached end

    local areaHa = measureRegionFieldAreaHa(buildFarmlandRegion(n))
    if areaHa > MIN_ROTATION_AREA_HA then
        self.rotationAreaHaCache[n] = areaHa
        return areaHa
    end
    return 0
end

---Cells a region holds on the fruit map, measured once per farmland.
-- @param integer farmlandId
-- @param table region
-- @param integer fruitTypeIndex
-- @return integer capacity, or nil
function RealisticCropRotationManager:getFieldPixelCapacity(farmlandId, region, fruitTypeIndex)
    self.fieldPixelCapacity = self.fieldPixelCapacity or {}
    local cached = self.fieldPixelCapacity[farmlandId]
    if cached ~= nil then return cached > 0 and cached or nil end

    local desc = (fruitTypeIndex ~= nil and g_fruitTypeManager ~= nil)
        and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex) or nil
    if desc == nil or desc.terrainDataPlaneId == nil then return nil end

    local _, pixels, totalPixels = aggregateRegionLayer(region, desc.terrainDataPlaneId,
        desc.startStateChannel, desc.numStateChannels)

    local capacity = totalPixels
    if region ~= nil and region.filter ~= nil then
        capacity = pixels
    end
    if capacity == nil or capacity <= 0 then
        capacity = pixels
    end

    self.fieldPixelCapacity[farmlandId] = tonumber(capacity) or 0
    return (tonumber(capacity) or 0) > 0 and tonumber(capacity) or nil
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
    local entry = cache[numericFarmlandId]
    if entry ~= nil and entry.tMs == nowMs then
        return entry.name, entry.fruitTypeIndex, entry.growthState, entry.belowFloor == true
    end

    local region = self:getFieldRegion(numericFarmlandId)
    local hint = entry ~= nil and entry.fruitTypeIndex or nil
    if hint == nil and g_fruitTypeManager ~= nil
        and type(g_fruitTypeManager.getFruitTypeByName) == "function" then
        local lastCrop = self.repository:getLastKnownActiveCrop(numericFarmlandId)
        local fruitType = lastCrop ~= nil and lastCrop ~= ""
            and g_fruitTypeManager:getFruitTypeByName(lastCrop) or nil
        hint = fruitType ~= nil and fruitType.index or nil
    end
    local capacity = self:getFieldPixelCapacity(numericFarmlandId, region, hint)
    local resolved, fruitTypeIndex, growthState, cropPixels =
        getActiveCropNameFromRegion(region, hint, capacity,
            entry ~= nil and entry.growthState or self.repository:getLastKnownGrowthState(numericFarmlandId))

    local belowFloor = false
    if resolved ~= nil and cropPixels ~= nil then
        capacity = capacity or self:getFieldPixelCapacity(numericFarmlandId, region, fruitTypeIndex)
        belowFloor = capacity ~= nil and cropPixels < capacity * MIN_CROP_COVERAGE
    end

    cache[numericFarmlandId] = {
        name = resolved,
        fruitTypeIndex = fruitTypeIndex,
        growthState = growthState,
        belowFloor = belowFloor,
        tMs = nowMs,
    }
    return resolved, fruitTypeIndex, growthState, belowFloor
end

---Returns the live crop only when it reaches the display coverage floor.
-- Raw crop detection remains available through getActiveCropInfo for gameplay logic.
-- @param integer farmlandId
-- @return string cropName, or nil
-- @return integer fruitTypeIndex, or nil
-- @return integer growthState, or nil
function RealisticCropRotationManager:getDisplayCropInfo(farmlandId)
    local cropName, fruitTypeIndex, growthState, belowFloor = self:getActiveCropInfo(farmlandId)
    if cropName == nil or cropName == "" or belowFloor then
        return nil, nil, nil
    end

    return cropName, fruitTypeIndex, growthState
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
    local n = tonumber(farmlandId)
    if n == nil then return end
    self.activeCropNameCache[n] = nil
end

---Reconciles stored history with the live active crop (server only).
-- @param integer farmlandId
-- @return boolean changed
-- @return table completedCrops Exact entries accepted into history
function RealisticCropRotationManager:reconcileActiveCropForFarmland(farmlandId)
    if isPureClient() then return false, {} end
    if self:getFieldRegion(farmlandId) == nil then return false, {} end

    local currentCropName, currentFruitTypeIndex, currentGrowthState, belowFloor =
        self:getActiveCropInfo(farmlandId)

    local groundWorked = (currentCropName == nil or belowFloor) and self:isFieldGroundWorked(farmlandId)

    -- A remnant on worked ground ends the cycle.
    if currentCropName ~= nil and belowFloor and groundWorked then
        currentCropName, currentFruitTypeIndex, currentGrowthState = nil, nil, nil
    end

    -- Keep the same-frame memo aligned with the effective crop so the UI can reuse this scan immediately.
    local numericFarmlandId = tonumber(farmlandId)
    local cacheEntry = numericFarmlandId ~= nil
        and self.activeCropNameCache[numericFarmlandId] or nil
    if cacheEntry ~= nil and cacheEntry.tMs == (tonumber(g_time) or 0) then
        cacheEntry.name = currentCropName
        cacheEntry.fruitTypeIndex = currentFruitTypeIndex
        cacheEntry.growthState = currentGrowthState
        cacheEntry.belowFloor = false
    end

    return self.service:reconcileActiveCrop(
        farmlandId,
        currentCropName,
        currentFruitTypeIndex,
        currentGrowthState,
        groundWorked)
end

---Ground + soil state of a field, both resolved from a single field-ground read.
-- @param integer farmlandId
-- @return table states { groundIndex, soilIndex }, or nil
function RealisticCropRotationManager:getFieldStateIndices(farmlandId)
    local n = tonumber(farmlandId)
    if n == nil then return nil end

    local nowMs = tonumber(g_time) or 0
    if self.fieldStateMemo == nil or self.fieldStateMemo.tMs ~= nowMs then
        self.fieldStateMemo = { tMs = nowMs }
    end
    local memo = self.fieldStateMemo
    if memo[n] ~= nil then return memo[n] end

    local region = self:getFieldRegion(n)
    if region == nil then return nil end

    local groundFilter, groundPixels = getRegionGroundCoverage(region)
    local entry = {
        groundIndex = getNativeGroundStateIndex(region, groundPixels),
        soilIndex = getNativeSoilStateIndex(region, groundFilter, groundPixels),
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
    if g_farmlandManager == nil then return result end

    for farmlandId in pairs(g_farmlandManager:getFarmlands() or {}) do
        if isRealFarmOwner(getOwnerFarmIdForFarmland(farmlandId))
            and self:getRotationAreaHa(farmlandId) > 0 then
            table.insert(result, tonumber(farmlandId) or farmlandId)
        end
    end

    table.sort(result, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na ~= nil and nb ~= nil then return na < nb end
        return tostring(a) < tostring(b)
    end)

    return result
end

---Unprefixed field label: the farmland or field name, or the raw id.
-- @param integer farmlandId
-- @return string label
function RealisticCropRotationManager:getFarmlandLabel(farmlandId)
    local farmland = getFarmlandById(farmlandId)
    local field = self:getFieldByFarmlandId(farmlandId)
    local rawName = farmland ~= nil and farmland.name or nil
    if (rawName == nil or rawName == "") and field ~= nil then rawName = field.name end
    if rawName == nil or rawName == "" then return tostring(farmlandId) end
    return tostring(rawName)
end

---Field name with the localized prefix, unless the farmland carries a real name.
-- @param integer farmlandId
-- @return string displayName
function RealisticCropRotationManager:getFarmlandDisplayName(farmlandId)
    local label = self:getFarmlandLabel(farmlandId)
    if tonumber(label) == nil then return label end

    local prefix = "Field"
    if g_i18n ~= nil and type(g_i18n.getText) == "function" then
        prefix = g_i18n:getText("rcr_field_prefix") or prefix
    end
    return prefix .. " " .. label
end

---Returns owned farmlands as display rows for the menu, sorted by field number.
-- @return table rows { farmlandId, name, areaHa }
function RealisticCropRotationManager:getOwnedFarmlands()
    local result = {}
    local farmId = self:getCurrentFarmId()
    if farmId == nil or g_farmlandManager == nil then return result end

    local farmlandIds = g_farmlandManager:getOwnedFarmlandIdsByFarmId(farmId)

    for _, farmlandId in ipairs(farmlandIds) do
        local areaHa = self:getRotationAreaHa(farmlandId)
        if areaHa > 0 then
            table.insert(result, {
                farmlandId = farmlandId,
                name = self:getFarmlandDisplayName(farmlandId),
                areaHa = areaHa,
            })
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

---Fresh client-safe FieldState sampled at the region's representative point.
-- @param integer farmlandId
-- @return table fieldState, or nil
function RealisticCropRotationManager:sampleFieldState(farmlandId)
    return sampleFieldStateInRegion(self:getFieldRegion(farmlandId))
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

    local level, ratio = getRegionLayerCoverageLevel(self:getFieldRegion(farmlandId), layer, maxLevel)
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

    local level, ratio = getRegionLayerCoverageLevel(self:getFieldRegion(farmlandId), layer, maxLevel)
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

---True when a region is not yet soil-analysed (pH reads back the floor value, which a real pH never does).
-- @param table pf precisionFarming
-- @param table region
-- @return boolean locked
function RealisticCropRotationManager:isPFSoilLocked(pf, region)
    if type(region.sampleX) ~= "number" or type(region.sampleZ) ~= "number" then return false end
    if pf.pHMap == nil then return false end
    return pf.pHMap:getLevelAtWorldPos(region.sampleX, region.sampleZ) <= 1
end

---Soil-type pixel counts over a region, keyed by PF's 1-based soil type index.
-- @param table region
-- @param table soilMap PF soil map
-- @param table restrictFilter Optional filter narrowing the counted area
-- @return table weights soilTypeIndex -> pixel count
local function getRegionSoilTypeWeights(region, soilMap, restrictFilter)
    local weights = {}
    if region == nil or soilMap == nil then return weights end

    local mapId = tonumber(soilMap.bitVectorMap)
    local firstChannel = tonumber(soilMap.typeFirstChannel)
    local numChannels = math.floor(tonumber(soilMap.typeNumChannels) or 0)
    if mapId == nil or firstChannel == nil or numChannels <= 0 then return weights end

    for value = 0, (2 ^ numChannels) - 1 do
        local filter = makeDensityFilter(mapId, firstChannel, numChannels, DensityValueCompareType.EQUAL, value)
        local _, pixels = aggregateRegionLayer(region, mapId, firstChannel, numChannels, filter, restrictFilter)
        if pixels ~= nil and pixels > 0 then
            weights[value + 1] = pixels
        end
    end
    return weights
end

---Finds one representative world position per soil type present in a region.
-- @param table region
-- @param table soilMap PF soil map
-- @param integer expectedCount Soil type count to locate before stopping
-- @return table positions soilTypeIndex -> { x, z }
local function locateSoilTypePositions(region, soilMap, expectedCount)
    local positions = {}
    if region == nil or soilMap == nil then return positions end

    local minX, maxX, minZ, maxZ = regionBounds(region)
    if minX == nil then return positions end

    local steps = REGION_SCAN_STEPS
    local stepX = (maxX - minX) / (steps - 1)
    local stepZ = (maxZ - minZ) / (steps - 1)
    local found = 0

    for i = 0, steps - 1 do
        for j = 0, steps - 1 do
            local x, z = minX + i * stepX, minZ + j * stepZ
            if isPointInRegion(region, x, z) then
                local index = soilMap:getTypeIndexAtWorldPos(x, z)
                if type(index) == "number" and positions[index] == nil then
                    positions[index] = { x = x, z = z }
                    found = found + 1
                    if expectedCount ~= nil and found >= expectedCount then return positions end
                end
            end
        end
    end
    return positions
end

---Reads nitrogen and soil weights on PF's tramline-map resolution, excluding every non-zero tramline state.
-- @param table region
-- @param table nMap
-- @param table soilMap
-- @param table tramlineMap PF tramline map
-- @return number internalMean, table soilWeights, or nil when the native maps cannot be aligned
local function getTramlineAlignedNitrogen(region, nMap, soilMap, tramlineMap)
    if region == nil or region.field == nil or region.filter ~= nil
        or nMap == nil or soilMap == nil or tramlineMap == nil
        or DensityMapModifier == nil or g_terrainNode == nil then return nil end

    local nMapId, nFirstChannel, nNumChannels = getValueMapLayer(nMap)
    local soilMapId = tonumber(soilMap.bitVectorMap)
    local soilFirstChannel = tonumber(soilMap.typeFirstChannel)
    local soilNumChannels = math.floor(tonumber(soilMap.typeNumChannels) or 0)
    local tramlineMapId = tramlineMap ~= nil and tonumber(tramlineMap.bitVectorMap) or nil
    local tramlineChannels = tramlineMap ~= nil
        and math.floor(tonumber(tramlineMap.numChannels) or 0) or 0
    if nMapId == nil or nFirstChannel == nil or nNumChannels <= 0
        or soilMapId == nil or soilFirstChannel == nil or soilNumChannels <= 0
        or tramlineMapId == nil or tramlineChannels <= 0 then return nil end

    local modifier = DensityMapModifier.new(
        tramlineMapId, 0, tramlineChannels, g_terrainNode)
    if modifier == nil or not applyRegionToModifier(region, modifier) then return nil end

    local clearFilter = makeDensityFilter(
        tramlineMapId, 0, tramlineChannels,
        DensityValueCompareType.EQUAL, 0)
    if clearFilter == nil then return nil end

    local okTotal, _, clearPixels = pcall(
        modifier.executeGet, modifier, clearFilter)
    if not okTotal or type(clearPixels) ~= "number" or clearPixels <= 0 then return nil end

    local reconstructedSum = 0
    for bitIndex = 0, nNumChannels - 1 do
        local bitFilter = makeDensityFilter(
            nMapId, nFirstChannel + bitIndex, 1,
            DensityValueCompareType.EQUAL, 1)
        if bitFilter == nil then return nil end

        local okBit, _, bitPixels = pcall(
            modifier.executeGet, modifier, clearFilter, bitFilter)
        if not okBit or type(bitPixels) ~= "number" then return nil end
        reconstructedSum = reconstructedSum + bitPixels * (2 ^ bitIndex)
    end

    local soilWeights = {}
    for soilValue = 0, (2 ^ soilNumChannels) - 1 do
        local soilFilter = makeDensityFilter(
            soilMapId, soilFirstChannel, soilNumChannels,
            DensityValueCompareType.EQUAL, soilValue)
        if soilFilter == nil then return nil end

        local okSoil, _, soilPixels = pcall(
            modifier.executeGet, modifier, clearFilter, soilFilter)
        if not okSoil or type(soilPixels) ~= "number" then return nil end
        if soilPixels > 0 then soilWeights[soilValue + 1] = soilPixels end
    end

    return reconstructedSum / clearPixels, soilWeights
end

---Live PF soil read: field-average N and pH, with targets weighted by the field's soil-type mix.
-- @param integer farmlandId
-- @param integer activeFruitTypeIndex Known active fruit type, or nil
-- @param boolean useProvidedFruitType True to avoid resolving the active crop again
-- @return table record, false when not analysed, or nil when PF is absent
function RealisticCropRotationManager:scanFieldSoil(farmlandId, activeFruitTypeIndex, useProvidedFruitType)
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

    local region = self:getFieldRegion(n)
    if region == nil then return nil end
    if self:isPFSoilLocked(pf, region) then
        memo[n] = { value = false }
        return false
    end

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
    if not useProvidedFruitType then
        activeFruitTypeIndex = select(2, self:getActiveCropInfo(n))
    end
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
    local groundFilter = getRegionGroundCoverage(region)

    -- A parcel with no mapped field is bounded by its worked ground.
    local parcelGroundMask = region.field == nil and groundFilter or nil
    local nitrogenMask = cropFilter or parcelGroundMask

    -- PF stores tramlines at a higher resolution than nitrogen. Reconstructing
    -- nitrogen on that native grid avoids mixed low-resolution edge cells.
    local alignedNitrogenMean, alignedSoilWeights = nil, nil
    local tramlineMap = pf.tramlineMap
    local tramlineState = tramlineMap ~= nil
        and type(tramlineMap.farmlandTramlineStates) == "table"
        and tramlineMap.farmlandTramlineStates[n] or nil
    if activeFruitTypeIndex ~= nil and nCanLevel and tramlineState ~= nil then
        alignedNitrogenMean, alignedSoilWeights =
            getTramlineAlignedNitrogen(region, nMap, soilMap, tramlineMap)
    end

    if phCanLevel then
        local mapId, firstChannel, numChannels = getValueMapLayer(phMap)
        if mapId ~= nil then
            local sum, pixels = aggregateRegionLayer(region, mapId, firstChannel, numChannels, groundFilter)
            if sum ~= nil and pixels > 0 then
                rec.phActual = snapToDisplayStep(phConv(sum / pixels), PF_PH_DISPLAY_STEP)
                rec.phMin, rec.phMax = phConv(0) or 0, phConv(phMaxInternal) or 0
            end
        end
    end

    if nCanLevel then
        if alignedNitrogenMean ~= nil then
            rec.nActual = snapToDisplayStep(
                nConv(alignedNitrogenMean), PF_N_DISPLAY_STEP)
        else
            local mapId, firstChannel, numChannels = getValueMapLayer(nMap)
            if mapId ~= nil then
                local sum, pixels = aggregateRegionLayer(
                    region, mapId, firstChannel, numChannels, nitrogenMask)
                -- Crop mask matching nothing: falls back to the read region.
                if (sum == nil or pixels == 0) and nitrogenMask ~= parcelGroundMask then
                    sum, pixels = aggregateRegionLayer(
                        region, mapId, firstChannel, numChannels, parcelGroundMask)
                end

                if sum ~= nil and pixels > 0 then
                    rec.nActual = snapToDisplayStep(nConv(sum / pixels), PF_N_DISPLAY_STEP)
                end
            end
        end
    end

    -- Targets weighted by soil-type pixel counts over worked ground.
    local soilWeights = getRegionSoilTypeWeights(region, soilMap, groundFilter)
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

        if activeFruitTypeIndex ~= nil and nCanLevel and nCanTargetAtPos and rec.nActual ~= nil then
            -- Nitrogen target weighted over the same area the average was read on.
            local cropWeights = alignedSoilWeights
            if cropWeights == nil or next(cropWeights) == nil then
                cropWeights = getRegionSoilTypeWeights(region, soilMap, nitrogenMask)
            end
            if next(cropWeights) == nil then cropWeights = soilWeights end

            local expectedCount = 0
            for _ in pairs(cropWeights) do expectedCount = expectedCount + 1 end

            local positions = locateSoilTypePositions(region, soilMap, expectedCount)
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
-- @param integer activeFruitTypeIndex Known active fruit type, or nil
-- @param boolean useProvidedFruitType True to avoid resolving the active crop again
-- @return number actual, false when not analysed, or nil when no PF (vanilla fallback)
-- @return number target Crop requirement, or nil when no crop
function RealisticCropRotationManager:getNitrogenLevel(farmlandId, activeFruitTypeIndex, useProvidedFruitType)
    local rec = self:scanFieldSoil(farmlandId, activeFruitTypeIndex, useProvidedFruitType)
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
-- @return table info { growthStageText, growthIsAction, weedHeader, weedActionText }, or nil
function RealisticCropRotationManager:getFieldCropInfo(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return nil end

    -- Weeds are read on bare ground too, no crop required.
    local weedHeader, weedValue
    local state = sampleFieldStateInRegion(self:getFieldRegion(numericFarmlandId))
    if state ~= nil then
        state.farmlandId = numericFarmlandId
        if RealisticCropRotationHud ~= nil and RealisticCropRotationHud.getWeedLineFromGame ~= nil then
            weedHeader, weedValue = RealisticCropRotationHud.getWeedLineFromGame(state)
        end
    end

    -- Reads the cached native crop.
    local growthStageText, growthIsAction
    if g_fruitTypeManager ~= nil then
        local _, fruitTypeIndex, growthState = self:getDisplayCropInfo(numericFarmlandId)
        fruitTypeIndex = normalizeFruitTypeIndex(fruitTypeIndex)
        local fruitType = fruitTypeIndex ~= nil and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex) or nil
        if fruitType ~= nil then
            growthStageText, growthIsAction = RealisticCropRotationManager.classifyGrowthStage(
                fruitType, tonumber(growthState) or 0)
        end
    end

    return {
        growthStageText = growthStageText,
        growthIsAction  = growthIsAction,
        weedHeader      = weedHeader,
        weedActionText  = weedValue,
    }
end
