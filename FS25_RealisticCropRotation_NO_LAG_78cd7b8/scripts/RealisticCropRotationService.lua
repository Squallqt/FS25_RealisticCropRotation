-- Copyright © 2026 Squallqt. All rights reserved.
-- Business logic: legume detection, history recording, pending-bonus computation,
-- nitrogen restitution at crop termination.
--
-- Nitrogen application strategy
-- -----------------------------
-- The residue is restituted the way the base game already does it for cover crops: by
-- adding fertilizer over the worked area through the native FSDensityMapUtil.updateSprayArea
-- (SprayType.FERTILIZER), exactly like a fertilizing cultivator. The base game owns the
-- nitrogen-restitution function; Precision Farming, when present, only reads that and shows
-- it in kg N/ha. The mod therefore writes no PF map and applies no hack. See
-- applyNitrogenResidueAtArea.
--
-- Cover crops (isCatchCrop=true at runtime, e.g. OILSEEDRADISH) restitute nothing here --
-- getResidueStateChangeForTermination returns 0 for them -- because the base game already
-- gives them their residue on incorporation.
RealisticCropRotationService = {}
local RealisticCropRotationService_mt = Class(RealisticCropRotationService)

-- Crop data (families, nitrogen, cover flags) is driven by cropConfig.xml.
-- RealisticCropRotation.cropConfig is loaded once at mod init by main.lua.
-- 1 PF state = 5 kg N/ha (source: PrecisionFarming.xml amountPerState=5).
RealisticCropRotationService.PF_STATE_PER_UNIT = 5

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

function RealisticCropRotationService.new(repository)
    local self = setmetatable({}, RealisticCropRotationService_mt)
    self.repository = repository
    self.pendingBonus = {}            -- farmlandId -> { n1StateChange, n2StateChange }
    self.cropNameByFruitTypeIndex = {}
    self.nitrogenDepositLock = nil    -- transient idempotency lock (created on first deposit)
    return self
end

function RealisticCropRotationService:reset()
    self.pendingBonus = {}
    self.cropNameByFruitTypeIndex = {}
    if self.nitrogenDepositLock ~= nil and delete ~= nil then
        pcall(delete, self.nitrogenDepositLock)
    end
    self.nitrogenDepositLock = nil
end

function RealisticCropRotationService:getNitrogenKgPerHaFromStateChange(stateChange)
    return (stateChange or 0) * RealisticCropRotationService.PF_STATE_PER_UNIT
end

-- Convert a PF state delta to kg N/ha. Prefers PF's live getNitrogenFromChangedStates
-- so the kg-per-state factor is never hardcoded; falls back to the documented
-- amountPerState constant when PF is unavailable (e.g. vanilla).
function RealisticCropRotationService:getNitrogenKgFromStates(stateChange)
    local states = stateChange or 0
    if states <= 0 then return 0 end
    local pf = getPrecisionFarmingInstance()
    local nitrogenMap = pf ~= nil and pf.nitrogenMap or nil
    if nitrogenMap ~= nil and type(nitrogenMap.getNitrogenFromChangedStates) == "function" then
        local ok, kg = pcall(nitrogenMap.getNitrogenFromChangedStates, nitrogenMap, states)
        if ok and type(kg) == "number" then return kg end
    end
    return self:getNitrogenKgPerHaFromStateChange(states)
end

function RealisticCropRotationService:getCurrentPeriod()
    if g_currentMission == nil or g_currentMission.environment == nil then return 0 end
    return g_currentMission.environment.currentPeriod or 0
end

function RealisticCropRotationService:getCropNameByFruitTypeIndex(fruitTypeIndex)
    if g_fruitTypeManager == nil or fruitTypeIndex == nil then return nil end
    local cached = self.cropNameByFruitTypeIndex[fruitTypeIndex]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil or fruitType.name == nil then
        self.cropNameByFruitTypeIndex[fruitTypeIndex] = false
        return nil
    end
    local cropName = string.upper(fruitType.name)
    self.cropNameByFruitTypeIndex[fruitTypeIndex] = cropName
    return cropName
end

function RealisticCropRotationService:normalizeCropName(cropName)
    if cropName == nil or cropName == "" then return nil end
    local normalizedCropName = string.upper(tostring(cropName))
    if normalizedCropName == "" then return nil end
    return normalizedCropName
end

function RealisticCropRotationService:getResidueEntry(cropName)
    if cropName == nil then return nil end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.nitrogen == nil then return nil end
    local entry = config.nitrogen[cropName]
    if entry ~= nil and ((entry.n1 or 0) > 0 or (entry.n2 or 0) > 0) then return entry end
    return nil
end

function RealisticCropRotationService:getFruitTypeByCropName(cropName)
    if cropName == nil or g_fruitTypeManager == nil or g_fruitTypeManager.getFruitTypeByName == nil then
        return nil
    end
    return g_fruitTypeManager:getFruitTypeByName(cropName)
end

function RealisticCropRotationService:isFruitTypeCatchCrop(fruitTypeIndex, cropName)
    local fruitType = nil
    if fruitTypeIndex ~= nil and fruitTypeIndex ~= FruitType.UNKNOWN
        and g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByIndex ~= nil then
        fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    end
    if fruitType == nil and cropName ~= nil then
        fruitType = self:getFruitTypeByCropName(cropName)
    end
    if fruitType == nil then return false end
    return fruitType.isCatchCrop == true
end

function RealisticCropRotationService:isCoverCropForRotationHistory(fruitTypeIndex, cropName)
    local normalizedName = cropName
    if normalizedName == nil and fruitTypeIndex ~= nil then
        normalizedName = self:getCropNameByFruitTypeIndex(fruitTypeIndex)
    end
    if normalizedName ~= nil then
        normalizedName = string.upper(tostring(normalizedName))
    end
    -- XML config: cover="true" crops are excluded from rotation history
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config ~= nil and config.coverCrops ~= nil
        and normalizedName ~= nil and config.coverCrops[normalizedName] then
        return true
    end
    -- Runtime fallback: isCatchCrop=true crops are always cover crops
    if self:isFruitTypeCatchCrop(fruitTypeIndex, normalizedName) then
        return true
    end
    return false
end

-- Cover crop residue deposited by Precision Farming on incorporation. The amount comes from
-- PF's catchCropsStateChange (states). Returns 0 without PF. Display-only: PF does the deposit.
function RealisticCropRotationService:getCoverResidueStateChange()
    local pf = getPrecisionFarmingInstance()
    local nitrogenMap = pf ~= nil and pf.nitrogenMap or nil
    if nitrogenMap == nil then return 0 end
    return tonumber(nitrogenMap.catchCropsStateChange) or 0
end

function RealisticCropRotationService:getLastCover(farmlandId)
    if self.repository == nil then return nil end
    return self.repository:getLastCover(farmlandId)
end

function RealisticCropRotationService:recomputePendingBonus(farmlandId)
    local entries = self.repository:getHistory(farmlandId)
    local n1Change = 0
    local n2Change = 0

    if entries[1] ~= nil then
        local entry = self:getResidueEntry(entries[1].crop)
        if entry ~= nil then n1Change = entry.n1 or 0 end
    end
    if entries[2] ~= nil then
        local entry = self:getResidueEntry(entries[2].crop)
        if entry ~= nil then n2Change = entry.n2 or 0 end
    end

    if n1Change > 0 or n2Change > 0 then
        self.pendingBonus[farmlandId] = { n1StateChange = n1Change, n2StateChange = n2Change }
    else
        self.pendingBonus[farmlandId] = nil
    end
end

function RealisticCropRotationService:recomputeAllPendingBonuses()
    self.pendingBonus = {}
    for farmlandId in pairs(self.repository:getAllHistory()) do
        self:recomputePendingBonus(farmlandId)
    end
end

function RealisticCropRotationService:pushHistoryCrop(farmlandId, cropName)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local normalizedCropName = self:normalizeCropName(cropName)
    if normalizedCropName == nil then return false end
    if self:isCoverCropForRotationHistory(nil, normalizedCropName) then
        return false
    end

    local changed = self.repository:pushEntry(numericFarmlandId, normalizedCropName)
    if changed then
        self:recomputePendingBonus(numericFarmlandId)
        -- A new main crop entered history: the previous cover residue is now consumed.
        self.repository:clearLastCover(numericFarmlandId)
    end
    return changed
end

function RealisticCropRotationService:setLastKnownActiveCrop(farmlandId, cropName)
    local normalizedCropName = self:normalizeCropName(cropName)
    return self.repository:setLastKnownActiveCrop(farmlandId, normalizedCropName)
end

function RealisticCropRotationService:reconcileActiveCrop(farmlandId, currentCropName)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local normalizedCurrentCrop = self:normalizeCropName(currentCropName)
    local lastKnownCrop = self.repository:getLastKnownActiveCrop(numericFarmlandId)

    if lastKnownCrop == nil or lastKnownCrop == "" then
        return self.repository:setLastKnownActiveCrop(numericFarmlandId, normalizedCurrentCrop)
    end

    if lastKnownCrop == normalizedCurrentCrop then
        return false
    end

    local pushed = self:pushHistoryCrop(numericFarmlandId, lastKnownCrop)
    local activeChanged = self.repository:setLastKnownActiveCrop(numericFarmlandId, normalizedCurrentCrop)
    return pushed or activeChanged
end

function RealisticCropRotationService:onCropChangeArea(farmlandId, fruitTypeIndex, activeCropNameBeforeTermination, changedArea, nextActiveCropName)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local numericChangedArea = tonumber(changedArea) or 0
    if numericChangedArea <= 0 then return false end

    local cropName = self:getCropNameByFruitTypeIndex(fruitTypeIndex)
    local normalizedCropName = self:normalizeCropName(cropName)
    if normalizedCropName == nil then return false end

    if activeCropNameBeforeTermination ~= nil and activeCropNameBeforeTermination ~= ""
        and self:isCoverCropForRotationHistory(nil, activeCropNameBeforeTermination) then
        return false
    end

    if self:isCoverCropForRotationHistory(fruitTypeIndex, normalizedCropName) then
        -- Cover crop incorporated: excluded from rotation history, but recorded so the HUD can
        -- show its residue on the following crop. Cleared when the next main crop enters history.
        self.repository:setLastCover(numericFarmlandId, normalizedCropName)
        return false
    end

    local pushed = self:pushHistoryCrop(numericFarmlandId, normalizedCropName)
    local activeChanged = self:setLastKnownActiveCrop(numericFarmlandId, nextActiveCropName)
    return pushed or activeChanged
end

-- =========================================================================
-- Nitrogen residue deposit (native vanilla fertilizer)
-- =========================================================================
-- Fertilizer amount restituted when a crop is terminated on a farmland: the terminated
-- crop's own first-year residue (n1) plus the second-year residue (n2) of the crop that is
-- now N-2 in the rotation history. Cover crops (isCatchCrop) restitute nothing here -- the
-- base game already gives them their residue on incorporation.
function RealisticCropRotationService:getResidueStateChangeForTermination(farmlandId, fruitTypeIndex)
    if farmlandId == nil or farmlandId == 0 then return 0 end
    local cropName = self:getCropNameByFruitTypeIndex(fruitTypeIndex)
    if cropName == nil then return 0 end
    if self:isCoverCropForRotationHistory(fruitTypeIndex, cropName) then return 0 end

    local total = 0
    local candidateEntry = self:getResidueEntry(cropName)
    if candidateEntry ~= nil then total = total + (candidateEntry.n1 or 0) end

    -- Second-year residue of the PREVIOUS crop, only when it is a different crop. The same crop
    -- twice in a row must not stack its own n1 + n2 (e.g. soybean after soybean stays its 80 kg,
    -- not 95). A different predecessor still leaves its n2 (e.g. pea after soybean = pea.n1 + soybean.n2).
    local entries = self.repository:getHistoryNoAlloc(farmlandId)
    if entries ~= nil and entries[1] ~= nil and entries[1].crop ~= cropName then
        local previousEntry = self:getResidueEntry(entries[1].crop)
        if previousEntry ~= nil then total = total + (previousEntry.n2 or 0) end
    end
    return total
end

-- Server-side. Restitutes the crop residue the same way FS25_MulchingFertilizes does for a
-- mulcher, with the same two paths: with Precision Farming it writes PF's own nitrogen map;
-- without it, it adds vanilla fertilizer (SPRAY_LEVEL). Runs AFTER superFunc so the engine's
-- tillage pass cannot overwrite it. The work-area parallelogram keeps it behind the tool.
function RealisticCropRotationService:applyNitrogenResidueAtArea(cropCandidate, xs, zs, xw, zw, xh, zh)
    if cropCandidate == nil or cropCandidate.fruitTypeIndex == nil then return end

    local residue = self:getResidueStateChangeForTermination(cropCandidate.farmlandId, cropCandidate.fruitTypeIndex)
    if residue <= 0 then return end

    if g_modIsLoaded ~= nil and g_modIsLoaded["FS25_precisionFarming"] then
        self:addNitrogenToPrecisionFarming(residue, xs, zs, xw, zw, xh, zh)
    else
        self:addFertilizerToSprayLevel(residue, xs, zs, xw, zw, xh, zh)
    end
end

-- Transient, in-memory idempotency lock (NOT the old persisted .grle): a 1-bit map the size of
-- the nitrogen map that marks pixels already given a residue. It is never saved, never tied to a
-- period; it is reset per worked area when a new crop is sown. Created lazily on first deposit.
function RealisticCropRotationService:getNitrogenDepositLock(nitrogenMap)
    if self.nitrogenDepositLock ~= nil then return self.nitrogenDepositLock end
    if createBitVectorMap == nil or loadBitVectorMapNew == nil or getBitVectorMapSize == nil then return nil end
    local sizeOk, w, h = pcall(getBitVectorMapSize, nitrogenMap.bitVectorMap)
    if not sizeOk or w == nil or h == nil then return nil end
    local createOk, lock = pcall(createBitVectorMap, "RealisticCropRotationNitrogenDepositLock")
    if not createOk or lock == nil then return nil end
    local newOk = pcall(loadBitVectorMapNew, lock, w, h, 1, false)
    if not newOk then pcall(delete, lock); return nil end
    self.nitrogenDepositLock = lock
    return lock
end

-- Precision Farming present: write the residue onto nitrogenMap.bitVectorMap. That map is
-- standalone (not terrain-attached), so world coords are converted to its pixel space and
-- setParallelogramDensityMapCoords is used, like FS25_MulchingFertilizes' destroy path. The
-- transient lock makes it idempotent: each pixel only receives the residue once per crop.
function RealisticCropRotationService:addNitrogenToPrecisionFarming(residue, xs, zs, xw, zw, xh, zh)
    local pf = getPrecisionFarmingInstance()
    local nitrogenMap = pf ~= nil and pf.nitrogenMap or nil
    if nitrogenMap == nil then return end

    local maxValue = nitrogenMap.maxValue
    local size = nitrogenMap.sizeX
    local terrainSize = g_currentMission.terrainSize
    local function toPixel(c) return size * (c + terrainSize * 0.5) / terrainSize end
    local lxs, lzs, lxw, lzw, lxh, lzh = toPixel(xs), toPixel(zs), toPixel(xw), toPixel(zw), toPixel(xh), toPixel(zh)

    local modifier = DensityMapModifier.new(nitrogenMap.bitVectorMap, nitrogenMap.firstChannel, nitrogenMap.numChannels, g_terrainNode)
    modifier:setPolygonRoundingMode(DensityRoundingMode.INCLUSIVE)
    modifier:setParallelogramDensityMapCoords(lxs, lzs, lxw, lzw, lxh, lzh, DensityCoordType.POINT_POINT_POINT)

    local nFilter = DensityMapFilter.new(modifier)

    -- Idempotency: only deposit where the lock is still 0, so overlapping tool slices don't stack.
    local lock = self:getNitrogenDepositLock(nitrogenMap)
    local lockFilter = nil
    if lock ~= nil then
        lockFilter = DensityMapFilter.new(lock, 0, 1)
        lockFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 0)
    end

    -- Saturate the band that would overflow maxValue, then add the residue to the rest.
    nFilter:setValueCompareParams(DensityValueCompareType.BETWEEN, maxValue - residue + 1, maxValue)
    if lockFilter ~= nil then modifier:executeSet(maxValue, lockFilter, nFilter) else modifier:executeSet(maxValue, nFilter) end
    nFilter:setValueCompareParams(DensityValueCompareType.BETWEEN, 0, maxValue - residue)
    if lockFilter ~= nil then modifier:executeAdd(residue, lockFilter, nFilter) else modifier:executeAdd(residue, nFilter) end

    -- Mark the whole worked area as done for this crop so a later overlapping slice skips it.
    if lock ~= nil then
        local lockModifier = DensityMapModifier.new(lock, 0, 1, g_terrainNode)
        lockModifier:setPolygonRoundingMode(DensityRoundingMode.INCLUSIVE)
        lockModifier:setParallelogramDensityMapCoords(lxs, lzs, lxw, lzw, lxh, lzh, DensityCoordType.POINT_POINT_POINT)
        lockModifier:executeSet(1)
    end

    nitrogenMap:setMinimapRequiresUpdate(true)
end

-- Clear the idempotency lock over a worked area, so the next crop grown there can be fertilized
-- again. Called from the sowing hooks (a new crop starts its own residue cycle).
function RealisticCropRotationService:resetNitrogenDepositLockAtArea(xs, zs, xw, zw, xh, zh)
    local lock = self.nitrogenDepositLock
    if lock == nil then return end
    local pf = getPrecisionFarmingInstance()
    local nitrogenMap = pf ~= nil and pf.nitrogenMap or nil
    if nitrogenMap == nil then return end

    local size = nitrogenMap.sizeX
    local terrainSize = g_currentMission.terrainSize
    local function toPixel(c) return size * (c + terrainSize * 0.5) / terrainSize end

    local lockModifier = DensityMapModifier.new(lock, 0, 1, g_terrainNode)
    lockModifier:setPolygonRoundingMode(DensityRoundingMode.INCLUSIVE)
    lockModifier:setParallelogramDensityMapCoords(toPixel(xs), toPixel(zs), toPixel(xw), toPixel(zw), toPixel(xh), toPixel(zh), DensityCoordType.POINT_POINT_POINT)
    lockModifier:executeSet(0)
end

-- No Precision Farming: add vanilla fertilizer onto the SPRAY_LEVEL map over the worked field
-- area. That map is terrain-attached, so world coords are used directly
-- (setParallelogramWorldCoords), like FS25_MulchingFertilizes' vanilla path. Capped at the
-- spray-level max and limited to actual field ground.
function RealisticCropRotationService:addFertilizerToSprayLevel(residue, xs, zs, xw, zw, xh, zh)
    local fieldGroundSystem = g_currentMission ~= nil and g_currentMission.fieldGroundSystem or nil
    if fieldGroundSystem == nil then return end

    local sprayLevelMapId, firstChannel, numChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.SPRAY_LEVEL)
    local maxValue = fieldGroundSystem:getMaxValue(FieldDensityMap.SPRAY_LEVEL)
    local groundTypeMapId, gtFirstChannel, gtNumChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)

    local modifier = DensityMapModifier.new(sprayLevelMapId, firstChannel, numChannels, g_currentMission.terrainRootNode)
    modifier:setParallelogramWorldCoords(xs, zs, xw, zw, xh, zh, DensityCoordType.POINT_POINT_POINT)

    local levelFilter = DensityMapFilter.new(sprayLevelMapId, firstChannel, numChannels)
    levelFilter:setValueCompareParams(DensityValueCompareType.BETWEEN, 0, maxValue - 1)

    local fieldFilter = DensityMapFilter.new(groundTypeMapId, gtFirstChannel, gtNumChannels)
    fieldFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)

    modifier:executeAdd(math.min(residue, maxValue), levelFilter, fieldFilter)
end

-- =========================================================================
-- MP sync helpers (server-authoritative).
-- =========================================================================

function RealisticCropRotationService:applySyncData(receivedHistory, receivedPlans, receivedLastKnownActiveCrop)
    self.repository:replaceAll(receivedHistory or {}, receivedPlans or {}, receivedLastKnownActiveCrop or {})
    self:recomputeAllPendingBonuses()
end

function RealisticCropRotationService:getSyncData()
    return self.repository:getAllHistory(), self.repository:getAllLastKnownActiveCrops()
end
