-- Copyright © 2026 Squallqt. All rights reserved.
-- Business logic: legume detection, history recording, and legacy rotation residue metadata.
RealisticCropRotationService = {}
local RealisticCropRotationService_mt = Class(RealisticCropRotationService)

-- Crop data (families, legacy nitrogen metadata, cover flags) is driven by cropConfig.xml.
-- RealisticCropRotation.cropConfig is loaded once at mod init by main.lua.
-- Historical conversion: 1 legacy state = 5 kg N/ha. No nitrogen/PF write path is active on dev.
RealisticCropRotationService.PF_STATE_PER_UNIT = 5
RealisticCropRotationService.NITROGEN_DEPOSIT_LOCK_CHANNELS = 8
RealisticCropRotationService.NITROGEN_DEPOSIT_LOCK_MAX_VALUE = (2 ^ RealisticCropRotationService.NITROGEN_DEPOSIT_LOCK_CHANNELS) - 1

function RealisticCropRotationService.new(repository)
    local self = setmetatable({}, RealisticCropRotationService_mt)
    self.repository = repository
    self.cropNameByFruitTypeIndex = {}
    self.residueCycleByFarmland = {}  -- farmlandId -> current residue lock generation
    self.nitrogenDepositLock = nil    -- legacy inactive deposit lock; no current runtime path creates it
    return self
end

function RealisticCropRotationService:reset()
    self.cropNameByFruitTypeIndex = {}
    self.residueCycleByFarmland = {}
    if self.nitrogenDepositLock ~= nil and delete ~= nil then
        pcall(delete, self.nitrogenDepositLock)
    end
    self.nitrogenDepositLock = nil
end

function RealisticCropRotationService:getNitrogenKgPerHaFromStateChange(stateChange)
    return (stateChange or 0) * RealisticCropRotationService.PF_STATE_PER_UNIT
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

-- Legacy residue-release metadata for a crop:
--   "harvest"      : deposited at harvest (cutFruitArea) -- grain crops.
--   "destroy"      : deposited at mechanical destruction -- perennial/multi-cut forage, roots, veg.
--   "destroyGreen" : deposited at destruction only while still green -- green-manure dual-use crops.
-- The value is resolved at config load (family default + per-crop override) and stored in
-- RealisticCropRotation.cropConfig.residueEvent. Current dev does not deposit nitrogen.
function RealisticCropRotationService:getResidueEvent(cropName)
    local normalizedCropName = self:normalizeCropName(cropName)
    if normalizedCropName == nil then return "harvest" end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config ~= nil and config.residueEvent ~= nil then
        local event = config.residueEvent[normalizedCropName]
        if event ~= nil then return event end
    end
    return "harvest"
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

function RealisticCropRotationService:pushHistoryCrop(farmlandId, cropName)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local normalizedCropName = self:normalizeCropName(cropName)
    if normalizedCropName == nil then return false end
    if self:isCoverCropForRotationHistory(nil, normalizedCropName) then
        return false
    end

    return self.repository:pushEntry(numericFarmlandId, normalizedCropName)
end

function RealisticCropRotationService:getResidueCycle(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return 1 end

    local cycle = tonumber(self.residueCycleByFarmland[numericFarmlandId]
        or self.residueCycleByFarmland[tostring(numericFarmlandId)]) or 1
    if cycle < 1 then cycle = 1 end
    return math.floor(cycle)
end

function RealisticCropRotationService:advanceResidueCycle(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return 1 end

    local nextCycle = self:getResidueCycle(numericFarmlandId) + 1
    if nextCycle > RealisticCropRotationService.NITROGEN_DEPOSIT_LOCK_MAX_VALUE then
        if self.nitrogenDepositLock ~= nil and delete ~= nil then
            pcall(delete, self.nitrogenDepositLock)
        end
        self.nitrogenDepositLock = nil
        self.residueCycleByFarmland = {}
        nextCycle = 1
    end

    self.residueCycleByFarmland[numericFarmlandId] = nextCycle
    self.residueCycleByFarmland[tostring(numericFarmlandId)] = nil
    return nextCycle
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
    if pushed or activeChanged then
        self:advanceResidueCycle(numericFarmlandId)
    end
    return pushed or activeChanged
end

function RealisticCropRotationService:onCropChangeArea(farmlandId, fruitTypeIndex, activeCropNameBeforeTermination, changedArea, nextActiveCropName)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local numericChangedArea = tonumber(changedArea) or 0
    if numericChangedArea <= 0 then return false end

    local normalizedHistoryCrop = self:normalizeCropName(activeCropNameBeforeTermination)

    local historyCropIsCover = false
    if normalizedHistoryCrop ~= nil then
        historyCropIsCover = self:isCoverCropForRotationHistory(nil, normalizedHistoryCrop)
    end

    local pushed = false
    if normalizedHistoryCrop ~= nil and not historyCropIsCover then
        pushed = self:pushHistoryCrop(numericFarmlandId, normalizedHistoryCrop)
    end
    local activeChanged = self:setLastKnownActiveCrop(numericFarmlandId, nextActiveCropName)
    if pushed or activeChanged then
        self:advanceResidueCycle(numericFarmlandId)
    end
    return pushed or activeChanged
end

-- =========================================================================
-- MP sync helpers (server-authoritative).
-- =========================================================================

function RealisticCropRotationService:applySyncData(receivedHistory, receivedPlans, receivedLastKnownActiveCrop, receivedAppliedResidue)
    self.repository:replaceAll(receivedHistory or {}, receivedPlans or {}, receivedLastKnownActiveCrop or {}, receivedAppliedResidue or {})
end

function RealisticCropRotationService:getSyncData()
    return self.repository:getAllHistory(), self.repository:getAllLastKnownActiveCrops(), self.repository:getAllAppliedResidues()
end
