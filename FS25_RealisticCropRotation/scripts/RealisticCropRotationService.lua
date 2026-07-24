-- Copyright © 2026 Squallqt. All rights reserved.
-- Business logic: legume detection, history recording, and rotation residue estimates.
RealisticCropRotationService = {}
local RealisticCropRotationService_mt = Class(RealisticCropRotationService)

-- Conversion: 1 state = 5 kg N/ha (source: PrecisionFarming.xml amountPerState=5).
RealisticCropRotationService.PF_STATE_PER_UNIT = 5

-- PF applies +25 kg N/ha when a catch-crop cover is destroyed; the planner reflects it as an estimate, the mod never deposits it.
RealisticCropRotationService.COVER_CROP_RESIDUE_KG_HA = 25

---Creates the service over a repository.
-- @param RealisticCropRotationRepository repository
-- @return RealisticCropRotationService instance
function RealisticCropRotationService.new(repository)
    local self = setmetatable({}, RealisticCropRotationService_mt)
    self.repository = repository
    self.cropNameByFruitTypeIndex = {}
    return self
end

---Resets caches.
function RealisticCropRotationService:reset()
    self.cropNameByFruitTypeIndex = {}
end

---Converts a legacy state change into kg N/ha.
-- @param number stateChange Number of legacy states
-- @return number kgPerHa
function RealisticCropRotationService:getNitrogenKgPerHaFromStateChange(stateChange)
    return (stateChange or 0) * RealisticCropRotationService.PF_STATE_PER_UNIT
end

---Returns the upper-case crop name for a fruit type index (cached).
-- @param integer fruitTypeIndex
-- @return string cropName or nil
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

---Upper-cases a crop name, or nil when empty.
-- @param string cropName
-- @return string normalizedCropName or nil
function RealisticCropRotationService:normalizeCropName(cropName)
    if cropName == nil or cropName == "" then return nil end
    local normalizedCropName = string.upper(tostring(cropName))
    if normalizedCropName == "" then return nil end
    return normalizedCropName
end

---Returns the cropConfig nitrogen residue entry for a crop, or nil when none.
-- @param string cropName Upper-case crop name
-- @return table entry { n1, n2 } or nil
function RealisticCropRotationService:getResidueEntry(cropName)
    if cropName == nil then return nil end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.nitrogen == nil then return nil end
    local entry = config.nitrogen[cropName]
    if entry ~= nil and ((entry.n1 or 0) > 0 or (entry.n2 or 0) > 0) then return entry end
    return nil
end

---Nitrogen residue to deposit on termination, in PF states: the crop's own n1 plus the last real crop's carried-over n2.
-- @param integer farmlandId
-- @param string terminatedCropName Crop being destroyed by the tool
-- @return integer states
function RealisticCropRotationService:getResidueStatesForTermination(farmlandId, terminatedCropName)
    local states = 0
    local terminated = self:getResidueEntry(self:normalizeCropName(terminatedCropName))
    if terminated ~= nil then states = states + (tonumber(terminated.n1) or 0) end

    -- Reach past fallow entries to the last real crop's carried-over n2.
    local history = self.repository:getHistory(farmlandId)
    local previousCrop = nil
    for i = 1, #history do
        local crop = history[i] ~= nil and history[i].crop or nil
        if crop ~= nil and not RealisticCropRotation.isFallowCrop(crop) then
            previousCrop = crop
            break
        end
    end
    local previous = previousCrop ~= nil and self:getResidueEntry(self:normalizeCropName(previousCrop)) or nil
    if previous ~= nil then states = states + (tonumber(previous.n2) or 0) end

    if states < 0 then states = 0 end
    return math.floor(states)
end

---Sums the cover-crop nitrogen residue (kg/ha) over a 4-slot cover plan.
-- @param table coverPlan 4-slot cover plan
-- @return number totalKgHa
function RealisticCropRotationService:getCoverResidueKgHa(coverPlan)
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.coverCrops == nil or coverPlan == nil then return 0 end

    local total = 0
    for i = 1, 4 do
        local cropName = self:normalizeCropName(coverPlan[i])
        if cropName ~= nil and config.coverCrops[cropName] then
            total = total + RealisticCropRotationService.COVER_CROP_RESIDUE_KG_HA
        end
    end
    return total
end

---Returns the fruit type for a crop name.
-- @param string cropName
-- @return table fruitType or nil
function RealisticCropRotationService:getFruitTypeByCropName(cropName)
    if cropName == nil or g_fruitTypeManager == nil or g_fruitTypeManager.getFruitTypeByName == nil then
        return nil
    end
    return g_fruitTypeManager:getFruitTypeByName(cropName)
end

---True when the fruit type is a catch crop (by index or name).
-- @param integer fruitTypeIndex
-- @param string cropName
-- @return boolean isCatchCrop
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

---True when a crop is a cover crop excluded from rotation history (cropConfig or catch-crop flag).
-- @param integer fruitTypeIndex
-- @param string cropName
-- @return boolean isCover
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

---Pushes a non-cover crop onto a farmland's rotation history.
-- @param integer farmlandId
-- @param string cropName
-- @param boolean allowDuplicate Allow repeating the most recent crop
-- @return boolean changed
function RealisticCropRotationService:pushHistoryCrop(farmlandId, cropName, allowDuplicate)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local normalizedCropName = self:normalizeCropName(cropName)
    if normalizedCropName == nil then return false end
    if self:isCoverCropForRotationHistory(nil, normalizedCropName) then
        return false
    end

    return self.repository:pushEntry(numericFarmlandId, normalizedCropName, allowDuplicate == true)
end

---Rounds a growth state to a non-negative integer, or nil when invalid.
-- @param number growthState
-- @return integer growthState or nil
function RealisticCropRotationService:normalizeGrowthState(growthState)
    local numericGrowthState = tonumber(growthState)
    if numericGrowthState == nil or numericGrowthState < 0 then return nil end
    return math.floor(numericGrowthState + 0.5)
end

---Resolves the fruit type from a fruit type index, falling back to the crop name.
-- @param string cropName
-- @param integer fruitTypeIndex
-- @return table fruitType or nil
function RealisticCropRotationService:getFruitTypeForCrop(cropName, fruitTypeIndex)
    if g_fruitTypeManager == nil then return nil end
    local numericFruitTypeIndex = tonumber(fruitTypeIndex)
    local unknownFruitTypeIndex = (FruitType ~= nil and FruitType.UNKNOWN) or 0
    if numericFruitTypeIndex ~= nil and numericFruitTypeIndex ~= unknownFruitTypeIndex
        and type(g_fruitTypeManager.getFruitTypeByIndex) == "function" then
        local fruitType = g_fruitTypeManager:getFruitTypeByIndex(numericFruitTypeIndex)
        if fruitType ~= nil then return fruitType end
    end
    local normalizedCropName = self:normalizeCropName(cropName)
    if normalizedCropName ~= nil and type(g_fruitTypeManager.getFruitTypeByName) == "function" then
        return g_fruitTypeManager:getFruitTypeByName(normalizedCropName)
    end
    return nil
end

---True when a growth state is terminal (cut or withered) for the fruit type.
-- @param table fruitType
-- @param number growthState
-- @return boolean isTerminal
function RealisticCropRotationService:isTerminalGrowthState(fruitType, growthState)
    local numericGrowthState = self:normalizeGrowthState(growthState)
    if fruitType == nil or numericGrowthState == nil then return false end

    if type(fruitType.getIsCut) == "function" then
        local ok, isCut = pcall(fruitType.getIsCut, fruitType, numericGrowthState)
        if ok and isCut then return true end
    elseif type(fruitType.cutStates) == "table" and fruitType.cutStates[numericGrowthState] then
        return true
    elseif fruitType.cutState ~= nil and numericGrowthState == tonumber(fruitType.cutState) then
        return true
    end

    if type(fruitType.getIsWithered) == "function" then
        local ok, isWithered = pcall(fruitType.getIsWithered, fruitType, numericGrowthState)
        if ok and isWithered then return true end
    elseif fruitType.witheredState ~= nil and numericGrowthState == tonumber(fruitType.witheredState) then
        return true
    end

    return false
end

---True when a growth state is in the crop's early (pre-harvest) phase.
-- @param table fruitType
-- @param number growthState
-- @return boolean isEarly
function RealisticCropRotationService:isEarlyGrowthState(fruitType, growthState)
    local numericGrowthState = self:normalizeGrowthState(growthState)
    if fruitType == nil or numericGrowthState == nil or numericGrowthState <= 0 then return false end
    if self:isTerminalGrowthState(fruitType, numericGrowthState) then return false end

    local minHarvestingGrowthState = tonumber(fruitType.minHarvestingGrowthState) or 0
    if minHarvestingGrowthState > 1 then
        return numericGrowthState < minHarvestingGrowthState
    end

    local numGrowthStates = tonumber(fruitType.numGrowthStates) or 0
    if numGrowthStates > 1 then
        return numericGrowthState <= math.max(1, math.floor(numGrowthStates / 2))
    end

    return numericGrowthState == 1
end

---True when a growth-state drop means a fresh replant (mature -> early), i.e. a new cycle.
-- @param table fruitType
-- @param number lastGrowthState
-- @param number currentGrowthState
-- @return boolean isReplant
function RealisticCropRotationService:isFreshReplantingGrowthDrop(fruitType, lastGrowthState, currentGrowthState)
    local last = self:normalizeGrowthState(lastGrowthState)
    local current = self:normalizeGrowthState(currentGrowthState)
    if fruitType == nil or last == nil or current == nil then return false end
    if current >= last then return false end
    if self:isEarlyGrowthState(fruitType, last) then return false end
    return self:isEarlyGrowthState(fruitType, current)
end

---Reconciles the field's current crop with stored state, pushing history on a real rotation change.
-- @param integer farmlandId
-- @param string currentCropName Crop currently on the field
-- @param integer currentFruitTypeIndex Current fruit type index
-- @param number currentGrowthState Current growth state
-- @param boolean groundWorked True when the bare field has been tilled since harvest (ignored while a crop is present)
-- @return boolean changed
function RealisticCropRotationService:reconcileActiveCrop(farmlandId, currentCropName, currentFruitTypeIndex, currentGrowthState, groundWorked)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local normalizedCurrentCrop = self:normalizeCropName(currentCropName)
    local normalizedCurrentGrowthState = self:normalizeGrowthState(currentGrowthState)
    local lastKnownCrop = self.repository:getLastKnownActiveCrop(numericFarmlandId)
    local lastKnownGrowthState = self.repository:getLastKnownGrowthState(numericFarmlandId)

    if lastKnownCrop == normalizedCurrentCrop then
        if normalizedCurrentCrop == nil then
            -- Fallow gap closes only once the ground is worked, not merely because it's bare.
            if groundWorked then
                return self:pushFallowIfPlanned(numericFarmlandId)
            end
            return false
        end
        if normalizedCurrentGrowthState == nil then
            return false
        end

        local fruitType = self:getFruitTypeForCrop(normalizedCurrentCrop, currentFruitTypeIndex)
        local pushed = false
        if fruitType ~= nil and fruitType.regrows ~= true
            and self:isFreshReplantingGrowthDrop(fruitType, lastKnownGrowthState, normalizedCurrentGrowthState) then
            pushed = self:pushHistoryCrop(numericFarmlandId, normalizedCurrentCrop, true)
        end

        self.repository:setLastKnownGrowthState(numericFarmlandId, normalizedCurrentGrowthState)
        return pushed
    end

    -- Old crop ended (or this is the first-ever read, when lastKnownCrop is nil and this no-ops).
    local pushed = self:pushHistoryCrop(numericFarmlandId, lastKnownCrop, true)
    local fallowPushed = false
    if normalizedCurrentCrop ~= nil then
        fallowPushed = self:pushFallowIfPlanned(numericFarmlandId)
    end
    local activeChanged = self.repository:setLastKnownActiveCrop(numericFarmlandId, normalizedCurrentCrop)
    if normalizedCurrentCrop ~= nil then
        self.repository:setLastKnownGrowthState(numericFarmlandId, normalizedCurrentGrowthState)
    end
    return pushed or fallowPushed or activeChanged
end

---True when the plan slot right after the most recently harvested crop is set to fallow.
-- @param integer farmlandId
-- @return boolean isFallow
function RealisticCropRotationService:isCurrentGapFallow(farmlandId)
    local lastEntry = self.repository:getHistory(farmlandId)[1]
    local lastCrop = lastEntry ~= nil and lastEntry.crop or nil
    if lastCrop == nil or RealisticCropRotation.isFallowCrop(lastCrop) then return false end

    local plan = self.repository:getPlan(farmlandId)
    for i = 1, 4 do
        if plan[i] == lastCrop then
            return RealisticCropRotation.isFallowCrop(plan[(i % 4) + 1])
        end
    end
    return false
end

---Pushes a fallow entry when isCurrentGapFallow says so (pushHistoryCrop dedupes).
-- @param integer farmlandId
-- @return boolean changed
function RealisticCropRotationService:pushFallowIfPlanned(farmlandId)
    if not self:isCurrentGapFallow(farmlandId) then return false end
    return self:pushHistoryCrop(farmlandId, RealisticCropRotation.SPECIAL_CROP_FALLOW, false)
end

-- MP sync helpers (server-authoritative).

---Applies a received server snapshot to the repository (client).
-- @param table receivedHistory
-- @param table receivedPlans
-- @param table receivedCoverPlans
-- @param table receivedLastKnownActiveCrop
-- @param table receivedLastKnownGrowthState
function RealisticCropRotationService:applySyncData(receivedHistory, receivedPlans, receivedCoverPlans, receivedLastKnownActiveCrop, receivedLastKnownGrowthState)
    self.repository:replaceAll(receivedHistory, receivedPlans, receivedCoverPlans, receivedLastKnownActiveCrop, receivedLastKnownGrowthState)
end

---Returns the snapshot to broadcast (server).
-- @return table history
-- @return table lastKnownActiveCrop
-- @return table lastKnownGrowthState
function RealisticCropRotationService:getSyncData()
    return self.repository:getAllHistory(),
        self.repository:getAllLastKnownActiveCrops(),
        self.repository:getAllLastKnownGrowthStates()
end
