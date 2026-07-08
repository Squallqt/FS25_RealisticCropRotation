-- Copyright © 2026 Squallqt. All rights reserved.
RealisticCropRotationDiseaseGrid = {}
local RealisticCropRotationDiseaseGrid_mt = Class(RealisticCropRotationDiseaseGrid)

-- 4 channels hold a per-disease state 0..15 (0 = clean), enough for the 9 pathogens (states 1..9)
-- so each disease is painted with its OWN colour on the parcel.
RealisticCropRotationDiseaseGrid.NUM_CHANNELS = 4
RealisticCropRotationDiseaseGrid.FILENAME = "realisticCropRotationDiseaseGrid.grle"

-- Per-cell curative/preventive protection, one bitvector per treatment family (0/1, 1 channel each,
-- same resolution as the main grid so cell-for-cell it lines up 1:1). A cell painted protected is
-- excluded from ALL future destruction under it (see RealisticCropRotationDisease's destroy filter) --
-- this covers BOTH curing an existing infection under the sprayed strip AND shielding it from a future
-- one, with the SAME mechanism. Persisted like the main grid.
RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS = 1
RealisticCropRotationDiseaseGrid.FUNGICIDE_PROTECTION_FILENAME = "realisticCropRotationFungicideProtection.grle"
RealisticCropRotationDiseaseGrid.NEMATICIDE_PROTECTION_FILENAME = "realisticCropRotationNematicideProtection.grle"

-- Risk map: runtime-only display map (never saved), painted off the UI path, rendered with no
-- mask and no map building at render time.
RealisticCropRotationDiseaseGrid.RISK_NUM_CHANNELS = 2

-- Scratch mask (never saved): recomputed by every destroy call to hold "eligible for transition-band
-- speckle" cells, then immediately consumed -- see RealisticCropRotationDisease's band speckle pass.
RealisticCropRotationDiseaseGrid.SPECKLE_NUM_CHANNELS = 1

function RealisticCropRotationDiseaseGrid.new()
    local self = setmetatable({}, RealisticCropRotationDiseaseGrid_mt)
    self.mapId = nil
    self.size = nil
    self.numChannels = RealisticCropRotationDiseaseGrid.NUM_CHANNELS
    self.changeRevision = 0
    self.fungicideProtectionMapId = nil
    self.nematicideProtectionMapId = nil
    self.protectionMapSize = nil
    self.protectionRevision = 0
    self.riskMapId = nil
    self.riskMapSize = nil
    self.riskNumChannels = RealisticCropRotationDiseaseGrid.RISK_NUM_CHANNELS
    self.riskRevision = 0
    self.speckleMapId = nil
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
    -- Single real dynamic source for every custom map's size: the native ground-detail resolution.
    local resolvedSize = tonumber(g_currentMission.terrainDetailMapSize)
    self.size = resolvedSize
    self.riskMapSize = resolvedSize

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

    self.protectionMapSize = resolvedSize

    self.fungicideProtectionMapId = createBitVectorMap("rcrFungicideProtection")
    local loadedFungProt = false
    if savegamePath ~= nil and savegamePath ~= "" then
        local fp = savegamePath .. RealisticCropRotationDiseaseGrid.FUNGICIDE_PROTECTION_FILENAME
        if fileExists ~= nil and fileExists(fp) then
            loadedFungProt = loadBitVectorMapFromFile(self.fungicideProtectionMapId, fp, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS)
        end
    end
    if not loadedFungProt then
        loadBitVectorMapNew(self.fungicideProtectionMapId, self.protectionMapSize, self.protectionMapSize, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS, false)
    end

    self.nematicideProtectionMapId = createBitVectorMap("rcrNematicideProtection")
    local loadedNemaProt = false
    if savegamePath ~= nil and savegamePath ~= "" then
        local np = savegamePath .. RealisticCropRotationDiseaseGrid.NEMATICIDE_PROTECTION_FILENAME
        if fileExists ~= nil and fileExists(np) then
            loadedNemaProt = loadBitVectorMapFromFile(self.nematicideProtectionMapId, np, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS)
        end
    end
    if not loadedNemaProt then
        loadBitVectorMapNew(self.nematicideProtectionMapId, self.protectionMapSize, self.protectionMapSize, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS, false)
    end

    -- Runtime-only risk display map (never saved: risk is derived from the synced history).
    self.riskMapId = createBitVectorMap("rcrRiskMap")
    loadBitVectorMapNew(self.riskMapId, self.riskMapSize, self.riskMapSize, self.riskNumChannels, false)

    -- Runtime-only scratch mask (never saved: recomputed by every destroy call).
    self.speckleMapId = createBitVectorMap("rcrSpeckleMask")
    loadBitVectorMapNew(self.speckleMapId, self.protectionMapSize, self.protectionMapSize, RealisticCropRotationDiseaseGrid.SPECKLE_NUM_CHANNELS, false)
end

function RealisticCropRotationDiseaseGrid:saveMap(savegamePath)
    if self.mapId == nil or savegamePath == nil or savegamePath == "" then return end
    saveBitVectorMapToFile(self.mapId, savegamePath .. RealisticCropRotationDiseaseGrid.FILENAME)
    if self.fungicideProtectionMapId ~= nil then
        saveBitVectorMapToFile(self.fungicideProtectionMapId, savegamePath .. RealisticCropRotationDiseaseGrid.FUNGICIDE_PROTECTION_FILENAME)
    end
    if self.nematicideProtectionMapId ~= nil then
        saveBitVectorMapToFile(self.nematicideProtectionMapId, savegamePath .. RealisticCropRotationDiseaseGrid.NEMATICIDE_PROTECTION_FILENAME)
    end
end

function RealisticCropRotationDiseaseGrid:deleteMap()
    if self.mapId ~= nil then
        delete(self.mapId)
        self.mapId = nil
    end
    if self.fungicideProtectionMapId ~= nil then
        delete(self.fungicideProtectionMapId)
        self.fungicideProtectionMapId = nil
    end
    if self.nematicideProtectionMapId ~= nil then
        delete(self.nematicideProtectionMapId)
        self.nematicideProtectionMapId = nil
    end
    if self.riskMapId ~= nil then
        delete(self.riskMapId)
        self.riskMapId = nil
    end
    if self.speckleMapId ~= nil then
        delete(self.speckleMapId)
        self.speckleMapId = nil
    end
end

---Wipes the risk display map (before a full repaint, e.g. on ownership changes).
function RealisticCropRotationDiseaseGrid:clearRiskMap()
    if self.riskMapId == nil then return end
    setBitVectorMapParallelogram(self.riskMapId, 0, 0, self.riskMapSize, 0, 0, self.riskMapSize, 0, self.riskNumChannels, 0)
    self.riskRevision = (self.riskRevision or 0) + 1
end

---Paints one field's risk band into the risk display map, on worked-soil cells only. band 0 erases.
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
    local farmlandFilter = nil
    if farmlandId ~= nil and fm ~= nil and type(fm.getLocalMap) == "function"
        and DensityMapFilter ~= nil and getBitVectorMapNumChannels ~= nil then
        local localMap = fm:getLocalMap()
        if localMap ~= nil then
            farmlandFilter = DensityMapFilter.new(localMap, 0, getBitVectorMapNumChannels(localMap))
            farmlandFilter:setValueCompareParams(DensityValueCompareType.EQUAL, farmlandId)
        end
    end

    if farmlandFilter ~= nil then
        modifier:executeSet(0, farmlandFilter)
    else
        modifier:executeSet(0)
    end
    self.changeRevision = (self.changeRevision or 0) + 1

    -- Protection is crop-cycle scoped: it ends when the crop changes, same as the disease marks above.
    for _, protectionMapId in ipairs({ self.fungicideProtectionMapId, self.nematicideProtectionMapId }) do
        if protectionMapId ~= nil then
            local protModifier = DensityMapModifier.new(protectionMapId, 0, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS, g_terrainNode)
            protModifier:setParallelogramWorldCoords(minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)
            if farmlandFilter ~= nil then
                protModifier:executeSet(0, farmlandFilter)
            else
                protModifier:executeSet(0)
            end
        end
    end
end

function RealisticCropRotationDiseaseGrid:clearAll()
    if self.mapId == nil then return end
    setBitVectorMapParallelogram(self.mapId, 0, 0, self.size, 0, 0, self.size, 0, self.numChannels, 0)
    self.changeRevision = (self.changeRevision or 0) + 1
end

---Marks the sprayed strip protected for the given family and clears its disease marks immediately.
---The daily destruction pass excludes protected cells, so the SAME write both cures and prevents.
-- @param string family "FUNGICIDE" | "NEMATICIDE"
-- @param number sx, sz, wx, wz, hx, hz world-space parallelogram corners of the sprayed strip
function RealisticCropRotationDiseaseGrid:paintProtection(family, sx, sz, wx, wz, hx, hz)
    local protectionMapId = family == "FUNGICIDE" and self.fungicideProtectionMapId
        or family == "NEMATICIDE" and self.nematicideProtectionMapId or nil
    if protectionMapId == nil or self.mapId == nil or g_terrainNode == nil
        or DensityMapModifier == nil or DensityMapFilter == nil
        or DensityCoordType == nil or DensityValueCompareType == nil
        or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil
        or FieldDensityMap == nil then
        return
    end

    local groundTypeMapId, groundFirstChannel, groundNumChannels =
        g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if groundTypeMapId == nil then return end

    local groundFilter = DensityMapFilter.new(groundTypeMapId, groundFirstChannel, groundNumChannels)
    groundFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)

    local protModifier = DensityMapModifier.new(protectionMapId, 0, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS, g_terrainNode)
    protModifier:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
    -- Same changed-count gating as the grid write below: only bump protectionRevision (drives the
    -- treatment-coverage map view) when a cell was ACTUALLY newly marked, not on every spray tick.
    local _, protChanged = protModifier:executeSetWithStats(1, groundFilter)
    if (protChanged or 0) > 0 then
        self.protectionRevision = (self.protectionRevision or 0) + 1
    end

    local gridModifier = DensityMapModifier.new(self.mapId, 0, self.numChannels, g_terrainNode)
    gridModifier:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
    -- Only bump changeRevision on a real change, or every spray tick forces an overlay rebuild (flicker).
    local _, changed = gridModifier:executeSetWithStats(0, groundFilter)
    if (changed or 0) > 0 then
        self.changeRevision = (self.changeRevision or 0) + 1
    end
end
