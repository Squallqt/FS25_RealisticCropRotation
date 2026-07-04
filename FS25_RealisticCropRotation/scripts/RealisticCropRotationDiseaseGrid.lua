-- Copyright © 2026 Squallqt. All rights reserved.
RealisticCropRotationDiseaseGrid = {}
local RealisticCropRotationDiseaseGrid_mt = Class(RealisticCropRotationDiseaseGrid)

RealisticCropRotationDiseaseGrid.GRID_SIZE = 2048
-- 4 channels hold a per-disease state 0..15 (0 = clean), enough for the 9 pathogens (states 1..9)
-- so each disease is painted with its OWN colour on the parcel. The filename carries a version
-- suffix: the channel count changed from the old 2-state (fungal/soil) format, so an old .grle is
-- NOT read back (it would be misinterpreted); the infection overlay simply repaints from live state.
RealisticCropRotationDiseaseGrid.NUM_CHANNELS = 4
RealisticCropRotationDiseaseGrid.FILENAME = "realisticCropRotationDiseaseGrid_v2.grle"

-- Risk map: a runtime-only display map (never saved) holding the per-field risk band 0..3 on
-- worked-soil cells. Painted natively off the UI path (load / period tick / ownership / MP sync)
-- and rendered directly by the map overlay, BMP-style: no mask and no map building at render time.
RealisticCropRotationDiseaseGrid.RISK_MAP_SIZE = 1024
RealisticCropRotationDiseaseGrid.RISK_NUM_CHANNELS = 2

-- Infection map: a second runtime-only display map (never saved), the exact twin of the risk map but
-- for the "active foci" view. It holds each infected field's DOMINANT disease state 1..9 on its
-- worked-soil cells, painted FULL (farmland EQUAL id + groundType GREATER 0) -- so the foci view gets
-- the same crisp field border as the pressure view instead of the sparse Perlin scatter of grid.mapId.
-- 4 channels (0..15) are needed because disease states run 1..9 (the risk map's 2 channels only hold
-- bands 1..3). Repainted from the synced infection state on every machine, so it is deterministic.
RealisticCropRotationDiseaseGrid.INFECTION_MAP_SIZE = 1024
RealisticCropRotationDiseaseGrid.INFECTION_NUM_CHANNELS = 4

function RealisticCropRotationDiseaseGrid.new()
    local self = setmetatable({}, RealisticCropRotationDiseaseGrid_mt)
    self.mapId = nil
    self.size = RealisticCropRotationDiseaseGrid.GRID_SIZE
    self.numChannels = RealisticCropRotationDiseaseGrid.NUM_CHANNELS
    self.changeRevision = 0
    self.riskMapId = nil
    self.riskMapSize = RealisticCropRotationDiseaseGrid.RISK_MAP_SIZE
    self.riskNumChannels = RealisticCropRotationDiseaseGrid.RISK_NUM_CHANNELS
    self.riskRevision = 0
    self.infectionMapId = nil
    self.infectionMapSize = RealisticCropRotationDiseaseGrid.INFECTION_MAP_SIZE
    self.infectionNumChannels = RealisticCropRotationDiseaseGrid.INFECTION_NUM_CHANNELS
    self.infectionRevision = 0
    return self
end

---World-space axis-aligned bounding box of a field, from its polygon corner nodes.
---FS25 Field objects carry `polygonPoints` (a list of transform nodes), not the
---`fieldDimensions`/`start-width-height` triplets the old code assumed.
-- @return number minX, minZ, maxX, maxZ, or nil when geometry is unavailable
local function fieldWorldBounds(field)
    if field == nil or getWorldTranslation == nil then return nil end
    local points = field.polygonPoints
    if type(points) ~= "table" or #points == 0 then return nil end

    local minX, maxX, minZ, maxZ
    for _, node in ipairs(points) do
        if node ~= nil then
            local x, _, z = getWorldTranslation(node)
            if type(x) == "number" and type(z) == "number" then
                if minX == nil or x < minX then minX = x end
                if maxX == nil or x > maxX then maxX = x end
                if minZ == nil or z < minZ then minZ = z end
                if maxZ == nil or z > maxZ then maxZ = z end
            end
        end
    end

    if minX == nil then return nil end
    return minX, minZ, maxX, maxZ
end

function RealisticCropRotationDiseaseGrid:loadMap(savegamePath)
    self.mapId = createBitVectorMap("rcrDiseaseGrid")
    local loaded = false

    if savegamePath ~= nil and savegamePath ~= "" then
        local filePath = savegamePath .. RealisticCropRotationDiseaseGrid.FILENAME
        if fileExists ~= nil and fileExists(filePath) then
            loaded = loadBitVectorMapFromFile(self.mapId, filePath, self.numChannels)
        end
    end

    if not loaded then
        loadBitVectorMapNew(self.mapId, self.size, self.size, self.numChannels, false)
    end

    local w = getBitVectorMapSize(self.mapId)
    self.size = tonumber(w) or self.size

    -- Runtime-only risk display map (never saved: risk is derived from the synced history).
    self.riskMapId = createBitVectorMap("rcrRiskMap")
    loadBitVectorMapNew(self.riskMapId, self.riskMapSize, self.riskMapSize, self.riskNumChannels, false)

    -- Runtime-only infection display map (never saved: repainted from the synced infection state).
    self.infectionMapId = createBitVectorMap("rcrInfectionMap")
    loadBitVectorMapNew(self.infectionMapId, self.infectionMapSize, self.infectionMapSize, self.infectionNumChannels, false)
end

function RealisticCropRotationDiseaseGrid:saveMap(savegamePath)
    if self.mapId == nil or savegamePath == nil or savegamePath == "" then return end
    saveBitVectorMapToFile(self.mapId, savegamePath .. RealisticCropRotationDiseaseGrid.FILENAME)
end

function RealisticCropRotationDiseaseGrid:deleteMap()
    if self.mapId ~= nil then
        delete(self.mapId)
        self.mapId = nil
    end
    if self.riskMapId ~= nil then
        delete(self.riskMapId)
        self.riskMapId = nil
    end
    if self.infectionMapId ~= nil then
        delete(self.infectionMapId)
        self.infectionMapId = nil
    end
end

---Wipes the risk display map (before a full repaint, e.g. on ownership changes).
function RealisticCropRotationDiseaseGrid:clearRiskMap()
    if self.riskMapId == nil then return end
    setBitVectorMapParallelogram(self.riskMapId, 0, 0, self.riskMapSize, 0, 0, self.riskMapSize, 0, self.riskNumChannels, 0)
    self.riskRevision = (self.riskRevision or 0) + 1
end

---Paints one field's risk band into the risk display map, on its worked-soil cells only
---(farmland map EQUAL farmlandId + groundType GREATER 0): the shape is the real cultivable
---field, like BMP's overlay base, not the cadastral parcel. Same native modifier+filters
---mechanism as clearField / the destruction pass. band 0 erases the field's cells.
-- @param table field game Field object (for the world bbox)
-- @param integer farmlandId
-- @param integer band risk band 0..3
function RealisticCropRotationDiseaseGrid:paintFarmlandRisk(field, farmlandId, band)
    if self.riskMapId == nil or field == nil or g_terrainNode == nil
        or DensityMapModifier == nil or DensityMapFilter == nil
        or DensityValueCompareType == nil or DensityCoordType == nil
        or g_farmlandManager == nil or type(g_farmlandManager.getLocalMap) ~= "function"
        or getBitVectorMapNumChannels == nil
        or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil
        or type(g_currentMission.fieldGroundSystem.getDensityMapData) ~= "function"
        or FieldDensityMap == nil or FieldDensityMap.GROUND_TYPE == nil then
        return false
    end

    local farmlandLocalMap = g_farmlandManager:getLocalMap()
    local groundTypeMapId, groundFirstChannel, groundNumChannels =
        g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if farmlandLocalMap == nil or groundTypeMapId == nil then return false end

    local minX, minZ, maxX, maxZ = fieldWorldBounds(field)
    if minX == nil then return false end

    local modifier = DensityMapModifier.new(self.riskMapId, 0, self.riskNumChannels, g_terrainNode)
    modifier:setParallelogramWorldCoords(minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)

    local farmlandFilter = DensityMapFilter.new(farmlandLocalMap, 0, getBitVectorMapNumChannels(farmlandLocalMap))
    farmlandFilter:setValueCompareParams(DensityValueCompareType.EQUAL, farmlandId)

    local groundFilter = DensityMapFilter.new(groundTypeMapId, groundFirstChannel, groundNumChannels)
    groundFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)

    modifier:executeSet(band, farmlandFilter, groundFilter)
    self.riskRevision = (self.riskRevision or 0) + 1
    return true
end

---Wipes the infection display map (before a full repaint, e.g. on ownership changes). Twin of
---clearRiskMap, on the 4-channel infection map.
function RealisticCropRotationDiseaseGrid:clearInfectionMap()
    if self.infectionMapId == nil then return end
    setBitVectorMapParallelogram(self.infectionMapId, 0, 0, self.infectionMapSize, 0, 0, self.infectionMapSize, 0, self.infectionNumChannels, 0)
    self.infectionRevision = (self.infectionRevision or 0) + 1
end

---Paints one field's DOMINANT disease state into the infection display map, FULL on its worked-soil
---cells only (farmland map EQUAL farmlandId + groundType GREATER 0): the exact twin of paintFarmlandRisk,
---so the "active foci" view gets the same crisp field border as the pressure view -- only the written
---value differs (a disease state 1..9 instead of a risk band 1..3). state 0 erases the field's cells.
-- @param table field game Field object (for the world bbox)
-- @param integer farmlandId
-- @param integer state disease overlay state 0..15 (0 = no active infection)
function RealisticCropRotationDiseaseGrid:paintFarmlandInfection(field, farmlandId, state)
    if self.infectionMapId == nil or field == nil or g_terrainNode == nil
        or DensityMapModifier == nil or DensityMapFilter == nil
        or DensityValueCompareType == nil or DensityCoordType == nil
        or g_farmlandManager == nil or type(g_farmlandManager.getLocalMap) ~= "function"
        or getBitVectorMapNumChannels == nil
        or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil
        or type(g_currentMission.fieldGroundSystem.getDensityMapData) ~= "function"
        or FieldDensityMap == nil or FieldDensityMap.GROUND_TYPE == nil then
        return false
    end

    local farmlandLocalMap = g_farmlandManager:getLocalMap()
    local groundTypeMapId, groundFirstChannel, groundNumChannels =
        g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if farmlandLocalMap == nil or groundTypeMapId == nil then return false end

    local minX, minZ, maxX, maxZ = fieldWorldBounds(field)
    if minX == nil then return false end

    local modifier = DensityMapModifier.new(self.infectionMapId, 0, self.infectionNumChannels, g_terrainNode)
    modifier:setParallelogramWorldCoords(minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)

    local farmlandFilter = DensityMapFilter.new(farmlandLocalMap, 0, getBitVectorMapNumChannels(farmlandLocalMap))
    farmlandFilter:setValueCompareParams(DensityValueCompareType.EQUAL, farmlandId)

    local groundFilter = DensityMapFilter.new(groundTypeMapId, groundFirstChannel, groundNumChannels)
    groundFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)

    modifier:executeSet(state, farmlandFilter, groundFilter)
    self.infectionRevision = (self.infectionRevision or 0) + 1
    return true
end

---Wipes this field's disease marks from the grid (called on crop change / clear).
function RealisticCropRotationDiseaseGrid:clearField(field)
    if self.mapId == nil or field == nil or g_terrainNode == nil or DensityMapModifier == nil then return end

    local minX, minZ, maxX, maxZ = fieldWorldBounds(field)
    if minX == nil then return end

    local modifier = DensityMapModifier.new(self.mapId, 0, self.numChannels, g_terrainNode)
    -- Axis-aligned bbox as a parallelogram: start, +X edge, +Z edge (absolute world points).
    modifier:setParallelogramWorldCoords(minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)

    -- Restrict the wipe to THIS farmland's cells, using the farmland map as a mask, so a
    -- neighbouring field whose bbox overlaps keeps its own marks (native cross-map filter).
    local farmlandId = field.farmland ~= nil and tonumber(field.farmland.id) or nil
    local fm = g_farmlandManager
    if farmlandId ~= nil and fm ~= nil and type(fm.getLocalMap) == "function"
        and DensityMapFilter ~= nil and getBitVectorMapNumChannels ~= nil then
        local localMap = fm:getLocalMap()
        if localMap ~= nil then
            local filter = DensityMapFilter.new(localMap, 0, getBitVectorMapNumChannels(localMap))
            filter:setValueCompareParams(DensityValueCompareType.EQUAL, farmlandId)
            modifier:executeSet(0, filter)
            self.changeRevision = (self.changeRevision or 0) + 1
            return
        end
    end

    modifier:executeSet(0)
    self.changeRevision = (self.changeRevision or 0) + 1
end

function RealisticCropRotationDiseaseGrid:clearAll()
    if self.mapId == nil then return end
    setBitVectorMapParallelogram(self.mapId, 0, 0, self.size, 0, 0, self.size, 0, self.numChannels, 0)
    self.changeRevision = (self.changeRevision or 0) + 1
end
