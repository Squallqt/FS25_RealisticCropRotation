-- Copyright © 2026 Squallqt. All rights reserved.
-- CRUD + XML persistence: per-farmland crop history, active crop, rotation plans.
RealisticCropRotationRepository = {}
local RealisticCropRotationRepository_mt = Class(RealisticCropRotationRepository)

RealisticCropRotationRepository.SAVE_VERSION = 1
RealisticCropRotationRepository.MAX_HISTORY = 4

---True when the 4-slot plan has at least one non-empty entry.
-- @param table plan 4-slot plan array
-- @return boolean hasData
local function hasPlanData(plan)
    if plan ~= nil then
        for i = 1, 4 do
            if plan[i] ~= nil and plan[i] ~= "" then
                return true
            end
        end
    end
    return false
end

---Resets every repository data table.
-- @param table repository
local function resetStorage(repository)
    repository.history = {}
    repository.plans = {}
    repository.coverPlans = {}
    repository.lastKnownActiveCrop = {}
    repository.lastKnownGrowthState = {}
end

---Collects sorted positive numeric farmland IDs across all repository tables.
-- @param table repository
-- @return table farmlandIds
local function collectFarmlandIds(repository)
    local allIds = {}
    local seen = {}
    local stores = {
        repository.history,
        repository.plans,
        repository.coverPlans,
        repository.lastKnownActiveCrop,
        repository.lastKnownGrowthState,
    }
    for _, store in ipairs(stores) do
        for farmlandId in pairs(store) do
            local numericId = tonumber(farmlandId)
            if numericId ~= nil and numericId > 0 and not seen[numericId] then
                seen[numericId] = true
                allIds[#allIds + 1] = numericId
            end
        end
    end
    table.sort(allIds)
    return allIds
end

---Writes one four-slot plan node.
-- @param integer xmlFile
-- @param string farmlandKey
-- @param string nodeName
-- @param table plan
local function writePlan(xmlFile, farmlandKey, nodeName, plan)
    local planKey = string.format("%s.%s(0)", farmlandKey, nodeName)
    for planIndex = 1, 4 do
        if plan[planIndex] ~= nil and plan[planIndex] ~= "" then
            setXMLString(xmlFile, planKey .. "#year" .. planIndex, plan[planIndex])
        end
    end
end

---Reads one four-slot plan node.
-- @param integer xmlFile
-- @param string farmlandKey
-- @param string nodeName
-- @return table plan, or nil when empty or absent
local function readPlan(xmlFile, farmlandKey, nodeName)
    local planKey = string.format("%s.%s(0)", farmlandKey, nodeName)
    if not hasXMLProperty(xmlFile, planKey) then return nil end

    local plan = {"", "", "", ""}
    local hasData = false
    for planIndex = 1, 4 do
        local value = getXMLString(xmlFile, planKey .. "#year" .. planIndex)
        if value ~= nil and value ~= "" then
            plan[planIndex] = value
            hasData = true
        end
    end
    return hasData and plan or nil
end

---Creates an empty repository.
-- @return RealisticCropRotationRepository instance
function RealisticCropRotationRepository.new()
    local self = setmetatable({}, RealisticCropRotationRepository_mt)
    resetStorage(self)
    return self
end

---Clears all stored history, plans and last-known state.
function RealisticCropRotationRepository:clear()
    resetStorage(self)
end

---Returns the history entries for a farmland (empty table when none).
-- @param integer farmlandId
-- @return table entries History entries, newest first
function RealisticCropRotationRepository:getHistory(farmlandId)
    local entries = self.history[farmlandId]
    if entries == nil then return {} end
    return entries
end

---Returns the full history map (farmlandId -> entries).
-- @return table history
function RealisticCropRotationRepository:getAllHistory()
    return self.history
end

---Pushes a crop onto the farmland history (deduped unless allowDuplicate), capped at MAX_HISTORY.
-- @param integer farmlandId
-- @param string cropName
-- @param boolean allowDuplicate Allow repeating the most recent crop
-- @return boolean changed
function RealisticCropRotationRepository:pushEntry(farmlandId, cropName, allowDuplicate)
    local entries = self.history[farmlandId]
    if entries == nil then
        entries = {}
        self.history[farmlandId] = entries
    end

    -- One entry per actual rotation change: ignore a crop that is already the most recent, so history doesn't grow on repeat passes.
    if not allowDuplicate and entries[1] ~= nil and entries[1].crop == cropName then
        return false
    end

    table.insert(entries, 1, { crop = cropName })
    while #entries > RealisticCropRotationRepository.MAX_HISTORY do
        table.remove(entries, #entries)
    end
    return true
end

---Returns the 4-slot rotation plan for a farmland.
-- @param integer farmlandId
-- @return table plan 4-slot plan array
function RealisticCropRotationRepository:getPlan(farmlandId)
    return self.plans[farmlandId] or {"","","",""}
end

---Returns the full plan map (farmlandId -> plan).
-- @return table plans
function RealisticCropRotationRepository:getAllPlans()
    return self.plans
end

---Sets one year slot of a farmland's rotation plan.
-- @param integer farmlandId
-- @param integer yearIdx Slot 1-4
-- @param string family Crop family, or "" to clear
function RealisticCropRotationRepository:setPlanYear(farmlandId, yearIdx, family)
    yearIdx = tonumber(yearIdx) or 0
    if yearIdx < 1 or yearIdx > 4 then return end
    if self.plans[farmlandId] == nil then
        self.plans[farmlandId] = {"","","",""}
    end
    self.plans[farmlandId][yearIdx] = tostring(family or "")
end

---Returns the 4-slot cover-crop plan for a farmland.
-- @param integer farmlandId
-- @return table coverPlan 4-slot cover plan array
function RealisticCropRotationRepository:getCoverPlan(farmlandId)
    return self.coverPlans[farmlandId] or self.coverPlans[tostring(farmlandId)] or {"","","",""}
end

---Returns the full cover-plan map (farmlandId -> cover plan).
-- @return table coverPlans
function RealisticCropRotationRepository:getAllCoverPlans()
    return self.coverPlans
end

---Sets one year slot of a farmland's cover-crop plan.
-- @param integer farmlandId
-- @param integer yearIdx Slot 1-4
-- @param string cropName Cover crop name, or "" to clear
function RealisticCropRotationRepository:setCoverPlanYear(farmlandId, yearIdx, cropName)
    yearIdx = tonumber(yearIdx) or 0
    if yearIdx < 1 or yearIdx > 4 then return end
    if self.coverPlans[farmlandId] == nil then
        self.coverPlans[farmlandId] = {"","","",""}
    end
    self.coverPlans[farmlandId][yearIdx] = tostring(cropName or "")
end

---Removes a farmland's main and cover plans.
-- @param integer farmlandId
-- @return boolean changed
function RealisticCropRotationRepository:clearPlan(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local stringFarmlandId = tostring(numericFarmlandId)
    local changed = self.plans[numericFarmlandId] ~= nil or self.plans[stringFarmlandId] ~= nil
        or self.coverPlans[numericFarmlandId] ~= nil or self.coverPlans[stringFarmlandId] ~= nil
    self.plans[numericFarmlandId] = nil
    self.plans[stringFarmlandId] = nil
    self.coverPlans[numericFarmlandId] = nil
    self.coverPlans[stringFarmlandId] = nil
    return changed
end

---Returns the last-known active crop name for a farmland.
-- @param integer farmlandId
-- @return string cropName or nil
function RealisticCropRotationRepository:getLastKnownActiveCrop(farmlandId)
    return self.lastKnownActiveCrop[farmlandId] or self.lastKnownActiveCrop[tostring(farmlandId)]
end

---Returns the full last-known active crop map.
-- @return table lastKnownActiveCrop
function RealisticCropRotationRepository:getAllLastKnownActiveCrops()
    return self.lastKnownActiveCrop
end

---Returns the last-known growth state for a farmland.
-- @param integer farmlandId
-- @return integer growthState or nil
function RealisticCropRotationRepository:getLastKnownGrowthState(farmlandId)
    return tonumber(self.lastKnownGrowthState[farmlandId] or self.lastKnownGrowthState[tostring(farmlandId)])
end

---Returns the full last-known growth-state map.
-- @return table lastKnownGrowthState
function RealisticCropRotationRepository:getAllLastKnownGrowthStates()
    return self.lastKnownGrowthState
end

---Sets the last-known active crop (clears growth state on change; clears both when cropName empty).
-- @param integer farmlandId
-- @param string cropName Crop name, or "" to clear
-- @return boolean changed
function RealisticCropRotationRepository:setLastKnownActiveCrop(farmlandId, cropName)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    if cropName == nil or cropName == "" then
        local stringFarmlandId = tostring(numericFarmlandId)
        local changed = self.lastKnownActiveCrop[numericFarmlandId] ~= nil
            or self.lastKnownActiveCrop[stringFarmlandId] ~= nil
            or self.lastKnownGrowthState[numericFarmlandId] ~= nil
            or self.lastKnownGrowthState[stringFarmlandId] ~= nil
        self.lastKnownActiveCrop[numericFarmlandId] = nil
        self.lastKnownActiveCrop[stringFarmlandId] = nil
        self.lastKnownGrowthState[numericFarmlandId] = nil
        self.lastKnownGrowthState[stringFarmlandId] = nil
        return changed
    end

    local normalizedCropName = string.upper(tostring(cropName))
    local changed = self.lastKnownActiveCrop[numericFarmlandId] ~= normalizedCropName
    self.lastKnownActiveCrop[numericFarmlandId] = normalizedCropName
    self.lastKnownActiveCrop[tostring(numericFarmlandId)] = nil
    if changed then
        self.lastKnownGrowthState[numericFarmlandId] = nil
        self.lastKnownGrowthState[tostring(numericFarmlandId)] = nil
    end
    return changed
end

---Sets the last-known growth state (clears it when growthState is nil/negative).
-- @param integer farmlandId
-- @param integer growthState
-- @return boolean changed
function RealisticCropRotationRepository:setLastKnownGrowthState(farmlandId, growthState)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local stringFarmlandId = tostring(numericFarmlandId)
    local numericGrowthState = tonumber(growthState)
    if numericGrowthState == nil or numericGrowthState < 0 then
        local changed = self.lastKnownGrowthState[numericFarmlandId] ~= nil
            or self.lastKnownGrowthState[stringFarmlandId] ~= nil
        self.lastKnownGrowthState[numericFarmlandId] = nil
        self.lastKnownGrowthState[stringFarmlandId] = nil
        return changed
    end

    numericGrowthState = math.floor(numericGrowthState + 0.5)
    local changed = tonumber(self.lastKnownGrowthState[numericFarmlandId]) ~= numericGrowthState
    self.lastKnownGrowthState[numericFarmlandId] = numericGrowthState
    self.lastKnownGrowthState[stringFarmlandId] = nil
    return changed
end

---Replaces all stored data (used by the client sync).
-- @param table newHistory
-- @param table newPlans
-- @param table newCoverPlans
-- @param table newLastKnownActiveCrop
-- @param table newLastKnownGrowthState
function RealisticCropRotationRepository:replaceAll(newHistory, newPlans, newCoverPlans, newLastKnownActiveCrop, newLastKnownGrowthState)
    self.history    = newHistory or {}
    self.plans      = newPlans or {}
    self.coverPlans = newCoverPlans or {}
    self.lastKnownActiveCrop = newLastKnownActiveCrop or {}
    self.lastKnownGrowthState = newLastKnownGrowthState or {}
end

---Writes the rotation state to realisticCropRotation.xml in the savegame folder.
-- @param string savegamePath Savegame folder path (trailing slash)
function RealisticCropRotationRepository:saveToXML(savegamePath)
    if savegamePath == nil or savegamePath == "" then
        Logging.warning("[RealisticCropRotation] Save skipped: savegame path unavailable")
        return
    end

    local filePath = savegamePath .. "realisticCropRotation.xml"
    local xmlFile = createXMLFile("realisticCropRotation", filePath, "realisticCropRotation")
    if xmlFile == nil or xmlFile == 0 then
        Logging.error("[RealisticCropRotation] Failed to create save file: %s", filePath)
        return
    end

    setXMLInt(xmlFile, "realisticCropRotation#version", RealisticCropRotationRepository.SAVE_VERSION)

    local allIds = collectFarmlandIds(self)

    local farmlandIndex = 0
    for _, numericFarmlandId in ipairs(allIds) do
        local entries = self.history[numericFarmlandId]
        local hasHistory = entries ~= nil and #entries > 0
        local plan = self.plans[numericFarmlandId]
        local hasPlan = hasPlanData(plan)
        local coverPlan = self.coverPlans[numericFarmlandId]
        local hasCoverPlan = hasPlanData(coverPlan)
        local activeCrop = self.lastKnownActiveCrop[numericFarmlandId]
            or self.lastKnownActiveCrop[tostring(numericFarmlandId)]
        local hasActiveCrop = activeCrop ~= nil and activeCrop ~= ""
        local activeGrowthState = tonumber(self.lastKnownGrowthState[numericFarmlandId]
            or self.lastKnownGrowthState[tostring(numericFarmlandId)])
        local hasActiveGrowthState = activeGrowthState ~= nil and activeGrowthState >= 0

        if hasHistory or hasPlan or hasCoverPlan or hasActiveCrop or hasActiveGrowthState then
            local farmlandKey = string.format("realisticCropRotation.farmland(%d)", farmlandIndex)
            setXMLInt(xmlFile, farmlandKey .. "#id", numericFarmlandId)
            if hasActiveCrop then
                setXMLString(xmlFile, farmlandKey .. "#lastKnownActiveCrop", tostring(activeCrop))
            end
            if hasActiveGrowthState then
                setXMLInt(xmlFile, farmlandKey .. "#lastKnownGrowthState", math.floor(activeGrowthState + 0.5))
            end

            if hasHistory then
                for i, entry in ipairs(entries) do
                    if i > RealisticCropRotationRepository.MAX_HISTORY then break end
                    local entryKey = string.format("%s.entry(%d)", farmlandKey, i - 1)
                    setXMLString(xmlFile, entryKey .. "#crop", tostring(entry.crop or ""))
                end
            end

            if hasPlan then
                writePlan(xmlFile, farmlandKey, "plan", plan)
            end

            if hasCoverPlan then
                writePlan(xmlFile, farmlandKey, "coverPlan", coverPlan)
            end

            farmlandIndex = farmlandIndex + 1
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

---Loads the rotation state from realisticCropRotation.xml in the savegame folder.
-- @param string savegamePath Savegame folder path (trailing slash)
function RealisticCropRotationRepository:loadFromXML(savegamePath)
    if savegamePath == nil or savegamePath == "" then
        Logging.warning("[RealisticCropRotation] Load skipped: savegame path unavailable")
        return
    end

    local filePath = savegamePath .. "realisticCropRotation.xml"
    if not fileExists(filePath) then
        return
    end

    local xmlFile = loadXMLFile("realisticCropRotation", filePath)
    if xmlFile == nil or xmlFile == 0 then
        Logging.warning("[RealisticCropRotation] Failed to load save file: %s", filePath)
        return
    end

    local version = getXMLInt(xmlFile, "realisticCropRotation#version") or 1
    if version > RealisticCropRotationRepository.SAVE_VERSION then
        Logging.warning("[RealisticCropRotation] Save file version %d is newer than supported %d. Some data may be ignored.",
            version, RealisticCropRotationRepository.SAVE_VERSION)
    end

    resetStorage(self)

    local farmlandIndex = 0
    while true do
        local farmlandKey = string.format("realisticCropRotation.farmland(%d)", farmlandIndex)
        if not hasXMLProperty(xmlFile, farmlandKey) then break end

        local farmlandId = getXMLInt(xmlFile, farmlandKey .. "#id")
        if farmlandId ~= nil and farmlandId > 0 then
            local activeCrop = getXMLString(xmlFile, farmlandKey .. "#lastKnownActiveCrop")
            if activeCrop ~= nil and activeCrop ~= "" then
                self.lastKnownActiveCrop[farmlandId] = string.upper(tostring(activeCrop))
            end
            local activeGrowthState = getXMLInt(xmlFile, farmlandKey .. "#lastKnownGrowthState")
            if activeGrowthState ~= nil and activeGrowthState >= 0 then
                self.lastKnownGrowthState[farmlandId] = activeGrowthState
            end

            local entries = {}
            local entryIndex = 0
            while true do
                local entryKey = string.format("%s.entry(%d)", farmlandKey, entryIndex)
                if not hasXMLProperty(xmlFile, entryKey) then break end
                local crop = getXMLString(xmlFile, entryKey .. "#crop")
                if crop ~= nil and crop ~= "" then
                    table.insert(entries, { crop = string.upper(tostring(crop)) })
                end
                entryIndex = entryIndex + 1
                if entryIndex >= RealisticCropRotationRepository.MAX_HISTORY then break end
            end
            if #entries > 0 then
                self.history[farmlandId] = entries
            end

            local plan = readPlan(xmlFile, farmlandKey, "plan")
            if plan ~= nil then self.plans[farmlandId] = plan end

            local coverPlan = readPlan(xmlFile, farmlandKey, "coverPlan")
            if coverPlan ~= nil then self.coverPlans[farmlandId] = coverPlan end
        end

        farmlandIndex = farmlandIndex + 1
    end

    delete(xmlFile)
end
