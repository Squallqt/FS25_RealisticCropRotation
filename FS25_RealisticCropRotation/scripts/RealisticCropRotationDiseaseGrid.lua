-- Copyright © 2026 Squallqt. All rights reserved.
RealisticCropRotationDiseaseGrid = {}
local RealisticCropRotationDiseaseGrid_mt = Class(RealisticCropRotationDiseaseGrid)

RealisticCropRotationDiseaseGrid.GRID_SIZE = 2048
RealisticCropRotationDiseaseGrid.NUM_CHANNELS = 2
RealisticCropRotationDiseaseGrid.FILENAME = "realisticCropRotationDiseaseGrid.grle"

function RealisticCropRotationDiseaseGrid.new()
    local self = setmetatable({}, RealisticCropRotationDiseaseGrid_mt)
    self.mapId = nil
    self.size = RealisticCropRotationDiseaseGrid.GRID_SIZE
    self.numChannels = RealisticCropRotationDiseaseGrid.NUM_CHANNELS
    self.changeRevision = 0
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
