-- Copyright © 2026 Squallqt. All rights reserved.
-- Business logic: legume detection, history recording, pending-bonus computation,
-- nitrogen restitution at crop termination.
--
-- Nitrogen application strategy
-- -----------------------------
-- Precision Farming does not expose a public API to inject nitrogen at an
-- arbitrary world area from a third-party mod (its NitrogenMap.addNitrogenLevelAtArea
-- and friends require an internal pre/post pipeline state that is not reachable
-- from the outside — proven by runtime probing). The only viable path is to
-- write the nitrogen value directly through DensityMapModifier on PF's
-- nitrogenMap.bitVectorMap, gated by:
--   1. PF's getIsLockedAtWorldPos() to honour any external lock state, and
--   2. a dedicated 1-bit application mask persisted alongside the savegame
--      (realisticCropRotation_nitrogenAppliedMask.grle) that prevents re-applying the
--      bonus on the same pixels within the same in-game period.
-- The mask is created eagerly at mission load (like every other game density
-- map), saved unconditionally on save (like PF's own maps), and reset on
-- period change.
--
-- Cover crops natively handled by PF (isCatchCrop=true at runtime, e.g.
-- OILSEEDRADISH) are deliberately skipped here — see
-- getCoverCropTerminationStateChange — so the mod never duplicates PF's own
-- catchCrops increase.
RealisticCropRotationService = {}
local RealisticCropRotationService_mt = Class(RealisticCropRotationService)

-- Crop data (families, nitrogen, cover flags) is driven by cropConfig.xml.
-- RealisticCropRotation.cropConfig is loaded once at mod init by main.lua.
-- 1 PF state = 5 kg N/ha (source: PrecisionFarming.xml amountPerState=5).
RealisticCropRotationService.PF_STATE_PER_UNIT = 5
RealisticCropRotationService.CROP_CHANGE_AREA_THRESHOLD = 0.90

RealisticCropRotationService.NITROGEN_DIAGNOSTICS_ENABLED = false

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

local function getNitrogenApplicationMaskFilename(savegamePath)
    if savegamePath == nil or savegamePath == "" then return nil end
    local lastChar = savegamePath:sub(-1)
    if lastChar ~= "/" and lastChar ~= "\\" then
        savegamePath = savegamePath .. "/"
    end
    return savegamePath .. "realisticCropRotation_nitrogenAppliedMask.grle"
end

function RealisticCropRotationService.new(repository)
    local self = setmetatable({}, RealisticCropRotationService_mt)
    self.repository = repository
    self.pendingBonus = {}            -- farmlandId -> { n1StateChange, n2StateChange }
    self.cropChangeAreaAccumulator = {}
    self.cropNameByFruitTypeIndex = {}
    self.warnedNitrogenBackend = {}
    self.nitrogenApplicationMaskMap = nil
    self.nitrogenApplicationMaskWidth = nil
    self.nitrogenApplicationMaskHeight = nil
    self.nitrogenApplicationMaskPeriod = 0
    self.nitrogenApplicationMaskFilename = nil
    self.nitrogenApplicationMaskDirty = false
    return self
end

function RealisticCropRotationService:reset()
    self:releaseNitrogenApplicationMask()
    self.pendingBonus = {}
    self.cropChangeAreaAccumulator = {}
    self.cropNameByFruitTypeIndex = {}
    self.warnedNitrogenBackend = {}
    self.nitrogenApplicationMaskPeriod = 0
    self.nitrogenApplicationMaskFilename = nil
    self.nitrogenApplicationMaskDirty = false
end

function RealisticCropRotationService:getNitrogenKgPerHaFromStateChange(stateChange)
    return (stateChange or 0) * RealisticCropRotationService.PF_STATE_PER_UNIT
end

function RealisticCropRotationService:getCurrentPeriod()
    if g_currentMission == nil or g_currentMission.environment == nil then return 0 end
    return g_currentMission.environment.currentPeriod or 0
end

function RealisticCropRotationService:getCurrentYear()
    if g_currentMission == nil or g_currentMission.environment == nil then return 0 end
    local environment = g_currentMission.environment

    local currentYear = tonumber(environment.currentYear)
    if currentYear ~= nil and currentYear > 0 then
        return math.floor(currentYear)
    end

    local currentMonotonicDay = tonumber(environment.currentMonotonicDay)
    local daysPerPeriod = tonumber(environment.daysPerPeriod)
    local periodsInYear = Environment ~= nil and tonumber(Environment.PERIODS_IN_YEAR) or nil
    if currentMonotonicDay ~= nil and currentMonotonicDay > 0
        and daysPerPeriod ~= nil and daysPerPeriod > 0
        and periodsInYear ~= nil and periodsInYear > 0 then
        return math.floor((currentMonotonicDay - 1) / (daysPerPeriod * periodsInYear)) + 1
    end

    return 0
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

function RealisticCropRotationService:getCoverCropTerminationStateChange(fruitTypeIndex)
    local cropName = self:getCropNameByFruitTypeIndex(fruitTypeIndex)
    if cropName == nil then return 0 end
    if not self:isCoverCropForRotationHistory(fruitTypeIndex, cropName) then return 0 end
    -- PF natively applies +25 kg N/ha on isCatchCrop=true crops. Do NOT duplicate.
    if self:isFruitTypeCatchCrop(fruitTypeIndex, cropName) then return 0 end
    local entry = self:getResidueEntry(cropName)
    if entry == nil then return 0 end
    return entry.n1 or 0
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

function RealisticCropRotationService:pushHistoryCrop(farmlandId, cropName, sourceName)
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
        if RealisticCropRotationService.NITROGEN_DIAGNOSTICS_ENABLED then
            Logging.info("[RealisticCropRotation][N-DIAG] history pushed farmland=%s crop=%s source=%s",
                tostring(numericFarmlandId), tostring(normalizedCropName), tostring(sourceName))
        end
    end
    return changed
end

function RealisticCropRotationService:setLastKnownActiveCrop(farmlandId, cropName)
    local normalizedCropName = self:normalizeCropName(cropName)
    return self.repository:setLastKnownActiveCrop(farmlandId, normalizedCropName)
end

function RealisticCropRotationService:reconcileActiveCrop(farmlandId, currentCropName, sourceName)
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

    local pushed = self:pushHistoryCrop(numericFarmlandId, lastKnownCrop, sourceName or "UI_RECONCILE")
    local activeChanged = self.repository:setLastKnownActiveCrop(numericFarmlandId, normalizedCurrentCrop)
    return pushed or activeChanged
end

function RealisticCropRotationService:onCropChangeArea(farmlandId, fruitTypeIndex, sourceName, activeCropNameBeforeTermination, changedArea, requiredArea, nextActiveCropName)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local numericChangedArea = tonumber(changedArea) or 0
    local numericRequiredArea = tonumber(requiredArea) or 0
    if numericChangedArea <= 0 or numericRequiredArea <= 0 then return false end

    local cropName = self:getCropNameByFruitTypeIndex(fruitTypeIndex)
    local normalizedCropName = self:normalizeCropName(cropName)
    if normalizedCropName == nil then return false end

    if activeCropNameBeforeTermination ~= nil and activeCropNameBeforeTermination ~= ""
        and self:isCoverCropForRotationHistory(nil, activeCropNameBeforeTermination) then
        return false
    end

    if self:isCoverCropForRotationHistory(fruitTypeIndex, normalizedCropName) then
        return false
    end

    local key = tostring(numericFarmlandId) .. ":" .. normalizedCropName
    local accumulatedArea = (self.cropChangeAreaAccumulator[key] or 0) + numericChangedArea
    if accumulatedArea < numericRequiredArea then
        self.cropChangeAreaAccumulator[key] = accumulatedArea
        return false
    end

    self.cropChangeAreaAccumulator[key] = nil
    local pushed = self:pushHistoryCrop(numericFarmlandId, normalizedCropName, sourceName)
    local activeChanged = self:setLastKnownActiveCrop(numericFarmlandId, nextActiveCropName)
    return pushed or activeChanged
end

function RealisticCropRotationService:getActiveBonusStateChange(farmlandId)
    local bonus = self.pendingBonus[farmlandId]
    if bonus == nil then return 0 end
    return (bonus.n1StateChange or 0) + (bonus.n2StateChange or 0)
end

function RealisticCropRotationService:getTerminationBonusStateChange(farmlandId)
    if farmlandId == nil or farmlandId == 0 then return 0 end
    local entries = self.repository:getHistoryNoAlloc(farmlandId)
    local total = 0
    if entries ~= nil and entries[1] ~= nil then
        local entry = self:getResidueEntry(entries[1].crop)
        if entry ~= nil then total = total + (entry.n1 or 0) end
    end
    if entries ~= nil and entries[2] ~= nil then
        local entry = self:getResidueEntry(entries[2].crop)
        if entry ~= nil then total = total + (entry.n2 or 0) end
    end
    return total
end

function RealisticCropRotationService:getTerminationBonusStateChangeForCandidate(farmlandId, fruitTypeIndex, activeCropNameBeforeTermination)
    if farmlandId == nil or farmlandId == 0 then return 0 end

    local cropName = self:getCropNameByFruitTypeIndex(fruitTypeIndex)
    if cropName == nil then return self:getTerminationBonusStateChange(farmlandId) end

    if activeCropNameBeforeTermination ~= nil and activeCropNameBeforeTermination ~= ""
        and self:isCoverCropForRotationHistory(nil, activeCropNameBeforeTermination) then
        return self:getTerminationBonusStateChange(farmlandId)
    end

    if self:isCoverCropForRotationHistory(fruitTypeIndex, cropName) then
        return self:getTerminationBonusStateChange(farmlandId)
    end

    -- Nitrogen still applies on every changed area, but history is now written
    -- only after a significant area threshold. Compute the same N-1/N-2 state
    -- that an immediate history push used to expose, without mutating history.
    local total = 0
    local candidateEntry = self:getResidueEntry(cropName)
    if candidateEntry ~= nil then total = total + (candidateEntry.n1 or 0) end

    local entries = self.repository:getHistoryNoAlloc(farmlandId)
    if entries ~= nil and entries[1] ~= nil then
        local previousEntry = self:getResidueEntry(entries[1].crop)
        if previousEntry ~= nil then total = total + (previousEntry.n2 or 0) end
    end

    return total
end

-- =========================================================================
-- Nitrogen application mask
-- =========================================================================

function RealisticCropRotationService:releaseNitrogenApplicationMask()
    if self.nitrogenApplicationMaskMap ~= nil then
        pcall(delete, self.nitrogenApplicationMaskMap)
    end
    self.nitrogenApplicationMaskMap = nil
    self.nitrogenApplicationMaskWidth = nil
    self.nitrogenApplicationMaskHeight = nil
    self.nitrogenApplicationMaskPeriod = 0
    self.nitrogenApplicationMaskFilename = nil
    self.nitrogenApplicationMaskDirty = false
end

-- Eager initialization called from manager:loadFromXML on the server.
-- Creates the mask once. A saved mask is loaded only when realisticCropRotation.xml
-- proves it belongs to the current in-game period.
function RealisticCropRotationService:initializeNitrogenApplicationMask(savegamePath)
    self:releaseNitrogenApplicationMask()

    local currentPeriod = self:getCurrentPeriod()
    if currentPeriod == 0 then
        Logging.warning("[RealisticCropRotation] Nitrogen application mask init skipped: current period unavailable")
        return false
    end

    local precisionFarming = getPrecisionFarmingInstance()
    local nitrogenMap = precisionFarming ~= nil and precisionFarming.nitrogenMap or nil
    if nitrogenMap == nil or nitrogenMap.bitVectorMap == nil then
        Logging.info("[RealisticCropRotation] Nitrogen application mask not initialized: PF nitrogenMap unavailable")
        return false
    end

    if createBitVectorMap == nil or loadBitVectorMapNew == nil or getBitVectorMapSize == nil then
        Logging.warning("[RealisticCropRotation] Nitrogen application mask init skipped: bit-vector map API unavailable")
        return false
    end

    local sizeOk, mapWidth, mapHeight = pcall(getBitVectorMapSize, nitrogenMap.bitVectorMap)
    if not sizeOk or mapWidth == nil or mapHeight == nil then
        Logging.warning("[RealisticCropRotation] Nitrogen application mask init skipped: getBitVectorMapSize failed")
        return false
    end

    local createOk, createdMap = pcall(createBitVectorMap, "RealisticCropRotationNitrogenApplicationMask")
    if not createOk or createdMap == nil then
        Logging.warning("[RealisticCropRotation] Nitrogen application mask init failed: createBitVectorMap failed")
        return false
    end

    local maskFilename = getNitrogenApplicationMaskFilename(savegamePath)
    local loaded = false
    local loadReason = "new"
    local savedMaskPeriod = 0
    if self.repository ~= nil and type(self.repository.getNitrogenMaskPeriod) == "function" then
        savedMaskPeriod = self.repository:getNitrogenMaskPeriod()
    end
    if maskFilename ~= nil and loadBitVectorMapFromFile ~= nil and fileExists ~= nil
        and savedMaskPeriod == currentPeriod then
        local existsOk, exists = pcall(fileExists, maskFilename)
        if existsOk and exists == true then
            local loadOk, loadResult = pcall(loadBitVectorMapFromFile, createdMap, maskFilename, 1)
            if loadOk and loadResult == true then
                local sizeCheckOk, loadedW, loadedH = pcall(getBitVectorMapSize, createdMap)
                if sizeCheckOk and loadedW == mapWidth and loadedH == mapHeight then
                    loaded = true
                    loadReason = "saved"
                else
                    loadReason = "sizeMismatch"
                end
            else
                loadReason = "loadFailed"
            end
        else
            loadReason = "noSavedMask"
        end
    elseif savedMaskPeriod ~= currentPeriod then
        loadReason = "periodChanged"
    elseif maskFilename == nil then
        loadReason = "noSavegamePath"
    end

    if not loaded then
        local newOk, newErr = pcall(loadBitVectorMapNew, createdMap, mapWidth, mapHeight, 1, false)
        if not newOk then
            pcall(delete, createdMap)
            Logging.warning("[RealisticCropRotation] Nitrogen application mask init failed: loadBitVectorMapNew error=%s",
                tostring(newErr))
            return false
        end
        self.nitrogenApplicationMaskDirty = true
    end

    self.nitrogenApplicationMaskMap = createdMap
    self.nitrogenApplicationMaskWidth = mapWidth
    self.nitrogenApplicationMaskHeight = mapHeight
    self.nitrogenApplicationMaskPeriod = currentPeriod
    self.nitrogenApplicationMaskFilename = maskFilename
    if self.repository ~= nil and type(self.repository.setNitrogenMaskPeriod) == "function" then
        self.repository:setNitrogenMaskPeriod(currentPeriod)
    end
    Logging.info("[RealisticCropRotation] Nitrogen application mask ready: size=%dx%d period=%d loadedFromFile=%s reason=%s savedPeriod=%d",
        mapWidth, mapHeight, currentPeriod, tostring(loaded), tostring(loadReason), savedMaskPeriod)
    return true
end

-- Unconditional save aligned with PF's own save pattern (called from
-- FSBaseMission.saveSavegame via manager:saveToXML).
function RealisticCropRotationService:saveNitrogenApplicationMask(savegamePath)
    if self.nitrogenApplicationMaskMap == nil then return false end
    if saveBitVectorMapToFile == nil then return false end

    local maskFilename = getNitrogenApplicationMaskFilename(savegamePath) or self.nitrogenApplicationMaskFilename
    if maskFilename == nil then return false end

    local saveOk, saveResult = pcall(saveBitVectorMapToFile, self.nitrogenApplicationMaskMap, maskFilename)
    if not saveOk or saveResult == false then
        Logging.warning("[RealisticCropRotation] Nitrogen application mask save failed: filename=%s result=%s",
            tostring(maskFilename), tostring(saveResult))
        return false
    end
    self.nitrogenApplicationMaskFilename = maskFilename
    self.nitrogenApplicationMaskDirty = false
    if self.repository ~= nil and type(self.repository.setNitrogenMaskPeriod) == "function" then
        self.repository:setNitrogenMaskPeriod(self.nitrogenApplicationMaskPeriod or 0)
    end
    return true
end

-- Reset all bits to 0 when a new in-game period starts so the mask covers the
-- current period only. Called from main.lua on currentPeriodChanged.
function RealisticCropRotationService:resetNitrogenApplicationMaskForNewPeriod()
    if self.nitrogenApplicationMaskMap == nil then return end
    if self.nitrogenApplicationMaskWidth == nil or self.nitrogenApplicationMaskHeight == nil then return end
    if loadBitVectorMapNew == nil then return end

    local currentPeriod = self:getCurrentPeriod()
    if currentPeriod == self.nitrogenApplicationMaskPeriod then return end

    local ok, err = pcall(loadBitVectorMapNew, self.nitrogenApplicationMaskMap,
        self.nitrogenApplicationMaskWidth, self.nitrogenApplicationMaskHeight, 1, false)
    if not ok then
        Logging.warning("[RealisticCropRotation] Nitrogen application mask reset failed: %s", tostring(err))
        return
    end
    self.nitrogenApplicationMaskPeriod = currentPeriod
    self.nitrogenApplicationMaskDirty = true
    if self.repository ~= nil and type(self.repository.setNitrogenMaskPeriod) == "function" then
        self.repository:setNitrogenMaskPeriod(currentPeriod)
    end
    Logging.info("[RealisticCropRotation] Nitrogen application mask reset for period=%d", currentPeriod)
end

-- =========================================================================
-- Nitrogen restitution write
-- =========================================================================
-- Precision Farming does not expose a verified high-level restitution API in
-- the local source set. This density-map writer is the single accepted backend
-- exception and must stay server-side, mask-gated, period-gated, and logged.

function RealisticCropRotationService:applyNitrogenStateChangeAtArea(totalStateChange, xs, zs, xw, zw, xh, zh, sourceName)
    if totalStateChange == nil or totalStateChange <= 0 then return false end
    if xs == nil or zs == nil or xw == nil or zw == nil or xh == nil or zh == nil then return false end

    local precisionFarming = getPrecisionFarmingInstance()
    local nitrogenMap = precisionFarming ~= nil and precisionFarming.nitrogenMap or nil
    if nitrogenMap == nil then
        if not self.warnedNitrogenBackend.pf then
            self.warnedNitrogenBackend.pf = true
            Logging.warning("[RealisticCropRotation] Nitrogen restitution skipped: PF nitrogenMap unavailable")
        end
        return false
    end

    if self.nitrogenApplicationMaskMap == nil then
        if not self.warnedNitrogenBackend.mask then
            self.warnedNitrogenBackend.mask = true
            Logging.warning("[RealisticCropRotation] Nitrogen restitution skipped: application mask not initialized")
        end
        return false
    end

    -- Honour PF lock state at the work-area center before any write.
    if type(nitrogenMap.getIsLockedAtWorldPos) == "function" then
        local centerX = (xw + xh) * 0.5
        local centerZ = (zw + zh) * 0.5
        local lockOk, isLocked = pcall(nitrogenMap.getIsLockedAtWorldPos, nitrogenMap, centerX, centerZ)
        if lockOk and isLocked == true then return false end
    end

    return self:writeNitrogenDensityMapStateChange(nitrogenMap, totalStateChange, xs, zs, xw, zw, xh, zh, sourceName)
end

function RealisticCropRotationService:writeNitrogenDensityMapStateChange(nitrogenMap, totalStateChange, xs, zs, xw, zw, xh, zh, sourceName)
    if DensityMapModifier == nil or DensityMapFilter == nil
        or DensityCoordType == nil or DensityValueCompareType == nil
        or g_terrainNode == nil then
        Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: density map API unavailable source=%s", tostring(sourceName))
        return false
    end

    local bitVectorMap = nitrogenMap.bitVectorMap
    local firstChannel = nitrogenMap.firstChannel or 0
    local numChannels = nitrogenMap.numChannels or nitrogenMap.NUM_BITS
    local maxValue = nitrogenMap.maxValue
    if bitVectorMap == nil or numChannels == nil or maxValue == nil then
        Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: invalid PF nitrogen map source=%s", tostring(sourceName))
        return false
    end

    local pointPointPoint = DensityCoordType.POINT_POINT_POINT
    local equalCompare = DensityValueCompareType.EQUAL
    local betweenCompare = DensityValueCompareType.BETWEEN

    -- Main modifier targets the N density-map.
    local modOk, modifier = pcall(DensityMapModifier.new, bitVectorMap, firstChannel, numChannels, g_terrainNode)
    if not modOk or modifier == nil then
        Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: DensityMapModifier.new error=%s source=%s",
            tostring(modifier), tostring(sourceName))
        return false
    end

    local valueFilterOk, valueFilter = pcall(DensityMapFilter.new, modifier)
    if not valueFilterOk or valueFilter == nil then
        Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: DensityMapFilter.new error=%s source=%s",
            tostring(valueFilter), tostring(sourceName))
        return false
    end

    local areaOk, areaErr = pcall(function()
        modifier:setParallelogramWorldCoords(xs, zs, xw, zw, xh, zh, pointPointPoint)
    end)
    if not areaOk then
        Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: N area setup error=%s source=%s",
            tostring(areaErr), tostring(sourceName))
        return false
    end

    -- Mask modifier excludes pixels already updated this period.
    local maskMap = self.nitrogenApplicationMaskMap
    local maskModOk, maskModifier = pcall(DensityMapModifier.new, maskMap, 0, 1, g_terrainNode)
    if not maskModOk or maskModifier == nil then
        Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: mask DensityMapModifier.new error=%s source=%s",
            tostring(maskModifier), tostring(sourceName))
        return false
    end
    local maskFilterOk, maskFilter = pcall(DensityMapFilter.new, maskMap, 0, 1)
    if not maskFilterOk or maskFilter == nil then
        Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: mask DensityMapFilter.new error=%s source=%s",
            tostring(maskFilter), tostring(sourceName))
        return false
    end

    local maskAreaOk, maskAreaErr = pcall(function()
        maskModifier:setParallelogramWorldCoords(xs, zs, xw, zw, xh, zh, pointPointPoint)
        maskFilter:setValueCompareParams(equalCompare, 0)
    end)
    if not maskAreaOk then
        Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: mask area setup error=%s source=%s",
            tostring(maskAreaErr), tostring(sourceName))
        return false
    end

    local changedPixels = 0

    -- Saturate the high end first (between maxValue-stateChange+1 and maxValue all clamp to maxValue).
    if betweenCompare ~= nil then
        local capMin = math.max(math.floor(maxValue - totalStateChange) + 1, 0)
        if capMin <= maxValue then
            local capOk, capResult1, capResult2 = pcall(function()
                valueFilter:setValueCompareParams(betweenCompare, capMin, maxValue)
                return modifier:executeSet(maxValue, valueFilter, maskFilter)
            end)
            if not capOk then
                Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: executeSet cap error=%s source=%s",
                    tostring(capResult1), tostring(sourceName))
                return false
            end
            changedPixels = changedPixels + (tonumber(capResult2) or 0)
        end
    end

    -- Add stateChange to each lower bucket.
    local loopStart = math.min(math.floor(maxValue - totalStateChange), maxValue)
    for sourceValue = loopStart, 0, -1 do
        local targetValue = math.min(sourceValue + totalStateChange, maxValue)
        if targetValue ~= sourceValue then
            local setOk, setResult1, setResult2 = pcall(function()
                valueFilter:setValueCompareParams(equalCompare, sourceValue)
                return modifier:executeSet(targetValue, valueFilter, maskFilter)
            end)
            if not setOk then
                Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: executeSet sourceValue=%s targetValue=%s error=%s source=%s",
                    tostring(sourceValue), tostring(targetValue), tostring(setResult1), tostring(sourceName))
                return false
            end
            changedPixels = changedPixels + (tonumber(setResult2) or 0)
        end
    end

    -- Mark the application mask for the area we just wrote on.
    local maskOk, maskResult1, maskResult2 = pcall(function()
        maskFilter:setValueCompareParams(equalCompare, 0)
        return maskModifier:executeSet(1, maskFilter)
    end)
    if not maskOk then
        Logging.warning("[RealisticCropRotation] Nitrogen restitution failed: mask executeSet error=%s source=%s",
            tostring(maskResult1), tostring(sourceName))
        return false
    end

    local maskPixels = tonumber(maskResult2) or 0
    if maskPixels > 0 then
        self.nitrogenApplicationMaskDirty = true
    end

    if type(nitrogenMap.setMinimapRequiresUpdate) == "function" then
        pcall(nitrogenMap.setMinimapRequiresUpdate, nitrogenMap, true)
    end

    if RealisticCropRotationService.NITROGEN_DIAGNOSTICS_ENABLED then
        Logging.info("[RealisticCropRotation][N-DIAG] applied state=%d kgHa=%d source=%s changedPixels=%d maskPixels=%d",
            totalStateChange, self:getNitrogenKgPerHaFromStateChange(totalStateChange), tostring(sourceName),
            changedPixels, maskPixels)
    end
    return true
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
