-- Copyright © 2026 Squallqt. All rights reserved.
-- BitVectorMap storage for the disease system: runtime disease/risk grids, persistent protection maps and a destruction mask.
RealisticCropRotationDiseaseGrid = {}
local RealisticCropRotationDiseaseGrid_mt = Class(RealisticCropRotationDiseaseGrid)

-- 4 channels hold a per-disease state 0..15 (0 = clean), enough for the 9 pathogens, each painted its own colour.
RealisticCropRotationDiseaseGrid.NUM_CHANNELS = 4

-- Per-cell protection, one bitvector per treatment family: a protected cell is excluded from all future destruction, so the same write cures and prevents.
RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS = 1
RealisticCropRotationDiseaseGrid.FUNGICIDE_PROTECTION_FILENAME = "realisticCropRotationFungicideProtection.grle"
RealisticCropRotationDiseaseGrid.NEMATICIDE_PROTECTION_FILENAME = "realisticCropRotationNematicideProtection.grle"

-- Risk map: runtime-only display map (never saved), painted off the UI path.
RealisticCropRotationDiseaseGrid.RISK_NUM_CHANNELS = 2

-- Scratch mask (never saved): recomputed for each core or transition-band destruction pass.
RealisticCropRotationDiseaseGrid.DESTRUCTION_MASK_NUM_CHANNELS = 1

function RealisticCropRotationDiseaseGrid.new()
    local self = setmetatable({}, RealisticCropRotationDiseaseGrid_mt)
    self.mapId = nil
    self.size = nil
    self.numChannels = RealisticCropRotationDiseaseGrid.NUM_CHANNELS
    self.changeRevision = 0
    self.fungicideProtectionMapId = nil
    self.nematicideProtectionMapId = nil
    self.fungicideProtectionMapSize = nil
    self.nematicideProtectionMapSize = nil
    self.protectionRevision = 0
    self.riskMapId = nil
    self.riskMapSize = nil
    self.riskNumChannels = RealisticCropRotationDiseaseGrid.RISK_NUM_CHANNELS
    self.riskRevision = 0
    self.destructionMaskMapId = nil
    return self
end

local regionWorldBounds = RealisticCropRotationManager.regionWorldBounds
local applyRegionToModifier = RealisticCropRotationManager.applyRegionToModifier

---Creates or loads one persistent treatment-protection map and records its actual size.
-- @param table owner Disease-grid instance
-- @param string savegamePath
-- @param string mapIdField Instance field receiving the map ID
-- @param string mapSizeField Instance field receiving the map size
-- @param string mapName Internal BitVectorMap name
-- @param string filename Savegame filename
-- @param integer resolvedSize Default map size
local function loadProtectionMap(owner, savegamePath, mapIdField, mapSizeField, mapName, filename, resolvedSize)
    owner[mapIdField] = createBitVectorMap(mapName)
    owner[mapSizeField] = resolvedSize
    local loaded = false
    if savegamePath ~= nil and savegamePath ~= "" then
        local filePath = savegamePath .. filename
        if fileExists ~= nil and fileExists(filePath) then
            loaded = loadBitVectorMapFromFile(
                owner[mapIdField], filePath, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS)
        end
    end
    if not loaded then
        loadBitVectorMapNew(
            owner[mapIdField], owner[mapSizeField], owner[mapSizeField],
            RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS, false)
    end
    local actualSize = getBitVectorMapSize(owner[mapIdField])
    owner[mapSizeField] = tonumber(actualSize) or owner[mapSizeField]
end

function RealisticCropRotationDiseaseGrid:loadMap(savegamePath, densityMapSyncer)
    -- Maps default to the native ground-detail resolution.
    local resolvedSize = tonumber(g_currentMission.terrainDetailMapSize)
    self.size = resolvedSize
    self.riskMapSize = resolvedSize

    self.mapId = createBitVectorMap("rcrDiseaseGrid")
    loadBitVectorMapNew(self.mapId, self.size, self.size, self.numChannels, false)

    local w = getBitVectorMapSize(self.mapId)
    self.size = tonumber(w) or self.size

    loadProtectionMap(
        self, savegamePath, "fungicideProtectionMapId", "fungicideProtectionMapSize",
        "rcrFungicideProtection", RealisticCropRotationDiseaseGrid.FUNGICIDE_PROTECTION_FILENAME, resolvedSize)
    loadProtectionMap(
        self, savegamePath, "nematicideProtectionMapId", "nematicideProtectionMapSize",
        "rcrNematicideProtection", RealisticCropRotationDiseaseGrid.NEMATICIDE_PROTECTION_FILENAME, resolvedSize)

    if densityMapSyncer ~= nil and type(densityMapSyncer.addDensityMap) == "function" then
        densityMapSyncer:addDensityMap(self.fungicideProtectionMapId)
        densityMapSyncer:addDensityMap(self.nematicideProtectionMapId)
    else
        Logging.warning("[RealisticCropRotation] Density-map synchronizer unavailable; treatment coverage cannot synchronize")
    end

    -- Runtime-only risk display map (never saved: risk is derived from the synced history).
    self.riskMapId = createBitVectorMap("rcrRiskMap")
    loadBitVectorMapNew(self.riskMapId, self.riskMapSize, self.riskMapSize, self.riskNumChannels, false)

    -- Runtime-only scratch mask (never saved: recomputed by every destruction pass).
    local destructionMaskSize = tonumber(g_currentMission.fruitMapSize) or resolvedSize
    self.destructionMaskMapId = createBitVectorMap("rcrDestructionMask")
    loadBitVectorMapNew(self.destructionMaskMapId, destructionMaskSize, destructionMaskSize,
        RealisticCropRotationDiseaseGrid.DESTRUCTION_MASK_NUM_CHANNELS, false)
end

function RealisticCropRotationDiseaseGrid:saveMap(savegamePath)
    if savegamePath == nil or savegamePath == "" then return end
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
    if self.destructionMaskMapId ~= nil then
        delete(self.destructionMaskMapId)
        self.destructionMaskMapId = nil
    end
end

function RealisticCropRotationDiseaseGrid:clearRiskMap()
    if self.riskMapId == nil then return end
    setBitVectorMapParallelogram(self.riskMapId, 0, 0, self.riskMapSize, 0, 0, self.riskMapSize, 0, self.riskNumChannels, 0)
    self.riskRevision = (self.riskRevision or 0) + 1
end

---Paints one parcel's risk band into the risk display map, on worked-soil cells only. band 0 erases.
-- @param table region Read region (for the world bbox)
-- @param integer farmlandId
-- @param integer band risk band 0..3
function RealisticCropRotationDiseaseGrid:paintFarmlandRisk(region, farmlandId, band)
    if self.riskMapId == nil or region == nil or g_terrainNode == nil
        or DensityMapModifier == nil or DensityMapFilter == nil
        or DensityValueCompareType == nil or DensityCoordType == nil
        or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil
        or FieldDensityMap == nil or FieldDensityMap.GROUND_TYPE == nil then
        return false
    end

    local groundTypeMapId, groundFirstChannel, groundNumChannels =
        g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if groundTypeMapId == nil then return false end

    local minX, minZ, maxX, maxZ = regionWorldBounds(region)
    local farmlandFilter = region.filter
        or RealisticCropRotationManager.makeFarmlandFilter(farmlandId)
    if minX == nil or farmlandFilter == nil then return false end

    local modifier = DensityMapModifier.new(self.riskMapId, 0, self.riskNumChannels, g_terrainNode)
    modifier:setParallelogramWorldCoords(minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)

    local groundFilter = DensityMapFilter.new(groundTypeMapId, groundFirstChannel, groundNumChannels)
    groundFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)

    modifier:executeSet(band, farmlandFilter, groundFilter)
    self.riskRevision = (self.riskRevision or 0) + 1
    return true
end

---Builds a region bounding box and exact farmland mask, failing closed when either cannot be resolved.
-- @param table region
-- @param integer farmlandId
-- @return number minX, minZ, maxX, maxZ Region bbox, or nil if unbounded
-- @return table farmlandFilter Farmland mask, or nil
local function regionClearParams(region, farmlandId)
    local minX, minZ, maxX, maxZ = regionWorldBounds(region)
    if minX == nil then return nil end

    local farmlandFilter = region.filter
        or RealisticCropRotationManager.makeFarmlandFilter(farmlandId)
    if farmlandFilter == nil then return nil end
    return minX, minZ, maxX, maxZ, farmlandFilter
end

---Clears only disease marks inside a parcel's farmland mask and returns the reusable clear parameters.
-- @param table region
-- @param integer farmlandId
-- @return boolean cleared
-- @return number minX
-- @return number minZ
-- @return number maxX
-- @return number maxZ
-- @return table farmlandFilter
function RealisticCropRotationDiseaseGrid:clearFieldDisease(region, farmlandId)
    if self.mapId == nil or region == nil or g_terrainNode == nil
        or DensityMapModifier == nil or DensityCoordType == nil then return end

    local minX, minZ, maxX, maxZ, farmlandFilter = regionClearParams(region, farmlandId)
    if minX == nil then return end

    local modifier = DensityMapModifier.new(self.mapId, 0, self.numChannels, g_terrainNode)
    -- Axis-aligned bbox as a parallelogram: start, +X edge, +Z edge (absolute world points).
    modifier:setParallelogramWorldCoords(minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)
    modifier:executeSet(0, farmlandFilter)
    self.changeRevision = (self.changeRevision or 0) + 1
    return true, minX, minZ, maxX, maxZ, farmlandFilter
end

---Clears a parcel's disease marks and crop-scoped fungicide protection while preserving timed nematicide protection.
-- @param table region
-- @param integer farmlandId
function RealisticCropRotationDiseaseGrid:clearField(region, farmlandId)
    local cleared, minX, minZ, maxX, maxZ, farmlandFilter = self:clearFieldDisease(region, farmlandId)
    if not cleared then return end
    -- Foliar protection ends with the harvested crop; soil nematicide follows its own timed lifecycle.
    self:clearFieldProtectionFamily(region, farmlandId, "FUNGICIDE", minX, minZ, maxX, maxZ, farmlandFilter)
end

---Wipes one treatment family from this parcel, leaving disease marks untouched.
-- @param table region
-- @param integer farmlandId
-- @param string family "FUNGICIDE" | "NEMATICIDE"
-- @param number minX Optional region bbox, reused from clearField
-- @param number minZ Optional region bbox, reused from clearField
-- @param number maxX Optional region bbox, reused from clearField
-- @param number maxZ Optional region bbox, reused from clearField
-- @param table farmlandFilter Optional farmland mask, reused from clearField
function RealisticCropRotationDiseaseGrid:clearFieldProtectionFamily(region, farmlandId, family, minX, minZ, maxX, maxZ, farmlandFilter)
    if g_terrainNode == nil or DensityMapModifier == nil or DensityCoordType == nil then return end
    if minX == nil or farmlandFilter == nil then
        minX, minZ, maxX, maxZ, farmlandFilter = regionClearParams(region, farmlandId)
        if minX == nil or farmlandFilter == nil then return end
    end

    local protectionMapId = family == "FUNGICIDE" and self.fungicideProtectionMapId
        or family == "NEMATICIDE" and self.nematicideProtectionMapId or nil
    if protectionMapId == nil then return end

    local protModifier = DensityMapModifier.new(protectionMapId, 0, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS, g_terrainNode)
    protModifier:setParallelogramWorldCoords(minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)
    local _, changed = protModifier:executeSetWithStats(0, farmlandFilter)
    if (changed or 0) > 0 then
        self.protectionRevision = (self.protectionRevision or 0) + 1
    end
end

function RealisticCropRotationDiseaseGrid:clearAll()
    if self.mapId == nil then return end
    setBitVectorMapParallelogram(self.mapId, 0, 0, self.size, 0, 0, self.size, 0, self.numChannels, 0)
    self.changeRevision = (self.changeRevision or 0) + 1
end

---Marks a sprayed strip for one treatment family and returns native changed/total pixel counts.
-- @param string family "FUNGICIDE" | "NEMATICIDE"
-- @param integer farmlandId Sole farmland allowed to receive the treatment
-- @param number sx World-space parallelogram start X
-- @param number sz World-space parallelogram start Z
-- @param number wx World-space parallelogram width X
-- @param number wz World-space parallelogram width Z
-- @param number hx World-space parallelogram height X
-- @param number hz World-space parallelogram height Z
-- @return number changedPixels
-- @return number totalPixels
function RealisticCropRotationDiseaseGrid:paintProtection(family, farmlandId, sx, sz, wx, wz, hx, hz)
    local protectionMapId = family == "FUNGICIDE" and self.fungicideProtectionMapId
        or family == "NEMATICIDE" and self.nematicideProtectionMapId or nil
    farmlandId = tonumber(farmlandId)
    if protectionMapId == nil or g_terrainNode == nil
        or DensityMapModifier == nil or DensityMapMultiModifier == nil or DensityMapFilter == nil
        or DensityCoordType == nil or DensityValueCompareType == nil
        or farmlandId == nil or farmlandId <= 0
        or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil
        or FieldDensityMap == nil then
        return 0, 0
    end

    local groundTypeMapId, groundFirstChannel, groundNumChannels =
        g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if groundTypeMapId == nil or groundFirstChannel == nil or groundNumChannels == nil then
        return 0, 0
    end

    local groundFilter = DensityMapFilter.new(groundTypeMapId, groundFirstChannel, groundNumChannels)
    groundFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
    local farmlandFilter = RealisticCropRotationManager.makeFarmlandFilter(farmlandId)
    if farmlandFilter == nil then return 0, 0 end

    local protModifier = DensityMapModifier.new(protectionMapId, 0, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS, g_terrainNode)
    local label = "rcrProtection"
    local multiModifier = DensityMapMultiModifier.new()
    multiModifier:addExecuteSetWithStats(label, 1, protModifier, farmlandFilter, groundFilter)
    multiModifier:updateParallelogramWorldCoords(
        sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
    multiModifier:resetStats()
    local numChangedPixels = {}
    local totalNumPixels = {}
    multiModifier:execute(nil, numChangedPixels, totalNumPixels)
    local protChanged = numChangedPixels[label] or 0
    local protTotal = totalNumPixels[label] or 0
    if (protChanged or 0) > 0 then
        self.protectionRevision = (self.protectionRevision or 0) + 1
    end
    if family == "NEMATICIDE" then
        RealisticCropRotationTreatmentLifecycle.onNematicideApplied(farmlandId)
    end
    -- Disease marks are left untouched.
    return protChanged, protTotal
end

---Clears one treatment family from a world-space work-area parallelogram.
-- @param string family "FUNGICIDE" | "NEMATICIDE"
-- @param number sx World-space parallelogram start X
-- @param number sz World-space parallelogram start Z
-- @param number wx World-space parallelogram width X
-- @param number wz World-space parallelogram width Z
-- @param number hx World-space parallelogram height X
-- @param number hz World-space parallelogram height Z
-- @return boolean changed True when protected cells were cleared
function RealisticCropRotationDiseaseGrid:clearProtectionArea(family, sx, sz, wx, wz, hx, hz)
    local protectionMapId = family == "FUNGICIDE" and self.fungicideProtectionMapId
        or family == "NEMATICIDE" and self.nematicideProtectionMapId or nil
    if protectionMapId == nil or g_terrainNode == nil or DensityMapModifier == nil then
        return false
    end

    local modifier = DensityMapModifier.new(
        protectionMapId, 0, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS, g_terrainNode)
    modifier:setParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
    local _, changed = modifier:executeSetWithStats(0)
    if (changed or 0) <= 0 then return false end

    self.protectionRevision = (self.protectionRevision or 0) + 1
    return true
end

---Native aggregate (executeGet): fraction of a parcel's worked ground marked protected for a treatment family.
-- @param table region
-- @param string family "FUNGICIDE" | "NEMATICIDE"
-- @return number coverage fraction [0,1]
function RealisticCropRotationDiseaseGrid:getProtectionCoverage(region, family)
    local protectionMapId = family == "FUNGICIDE" and self.fungicideProtectionMapId
        or family == "NEMATICIDE" and self.nematicideProtectionMapId or nil
    if region == nil or protectionMapId == nil or DensityMapModifier == nil or DensityMapFilter == nil
        or g_terrainNode == nil or DensityValueCompareType == nil then
        return 0
    end

    local modifier = DensityMapModifier.new(protectionMapId, 0, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS, g_terrainNode)
    if not applyRegionToModifier(region, modifier) then return 0 end

    local filter = DensityMapFilter.new(protectionMapId, 0, RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS)
    filter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)

    -- Worked-ground pixels counted in their own pass.
    local groundFilter = RealisticCropRotationManager.makeFieldGroundFilter()
    if groundFilter == nil then return 0 end
    local _, protectedPixels = modifier:executeGet(filter, groundFilter, region.filter)
    local _, groundPixels = modifier:executeGet(groundFilter, region.filter)
    if groundPixels == nil or groundPixels <= 0 then return 0 end
    return (protectedPixels or 0) / groundPixels
end
