-- Copyright © 2026 Squallqt. All rights reserved.
-- CRUD + XML persistence for per-farmland crop history, active crop state,
-- rotation plans, and applied residue state.
RealisticCropRotationRepository = {}
local RealisticCropRotationRepository_mt = Class(RealisticCropRotationRepository)

RealisticCropRotationRepository.SAVE_VERSION = 1
RealisticCropRotationRepository.MAX_HISTORY = 4

local function getPersistenceCounts(history, plans, lastKnownActiveCrop, appliedResidue)
    local historyFarmlands = 0
    local historyEntries = 0
    for _, entries in pairs(history or {}) do
        if entries ~= nil and #entries > 0 then
            historyFarmlands = historyFarmlands + 1
            historyEntries = historyEntries + #entries
        end
    end

    local planFarmlands = 0
    for _, plan in pairs(plans or {}) do
        if plan ~= nil then
            for i = 1, 4 do
                if plan[i] ~= nil and plan[i] ~= "" then
                    planFarmlands = planFarmlands + 1
                    break
                end
            end
        end
    end

    local activeCropFarmlands = 0
    for _, cropName in pairs(lastKnownActiveCrop or {}) do
        if cropName ~= nil and cropName ~= "" then
            activeCropFarmlands = activeCropFarmlands + 1
        end
    end

    local appliedResidueFarmlands = 0
    for _, entry in pairs(appliedResidue or {}) do
        if entry ~= nil and entry.crop ~= nil and entry.crop ~= "" then
            appliedResidueFarmlands = appliedResidueFarmlands + 1
        end
    end

    return historyFarmlands, historyEntries, planFarmlands, activeCropFarmlands, appliedResidueFarmlands
end

function RealisticCropRotationRepository.new()
    local self = setmetatable({}, RealisticCropRotationRepository_mt)
    self.history = {}
    self.plans   = {}
    self.lastKnownActiveCrop = {}
    self.lastKnownGrowthState = {}
    -- Legacy residue payload retained for old saves and MP sync compatibility.
    self.appliedResidue = {}
    return self
end

function RealisticCropRotationRepository:clear()
    self.history = {}
    self.plans   = {}
    self.lastKnownActiveCrop = {}
    self.lastKnownGrowthState = {}
    self.appliedResidue = {}
end

function RealisticCropRotationRepository:getHistory(farmlandId)
    local entries = self.history[farmlandId]
    if entries == nil then return {} end
    return entries
end

function RealisticCropRotationRepository:getHistoryNoAlloc(farmlandId)
    return self.history[farmlandId]
end

function RealisticCropRotationRepository:getAllHistory()
    return self.history
end

function RealisticCropRotationRepository:getAppliedResidue(farmlandId)
    return self.appliedResidue[farmlandId] or self.appliedResidue[tostring(farmlandId)]
end

function RealisticCropRotationRepository:getAllAppliedResidues()
    return self.appliedResidue
end

function RealisticCropRotationRepository:clearAppliedResidue(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local changed = self.appliedResidue[numericFarmlandId] ~= nil
        or self.appliedResidue[tostring(numericFarmlandId)] ~= nil
    self.appliedResidue[numericFarmlandId] = nil
    self.appliedResidue[tostring(numericFarmlandId)] = nil
    return changed
end

function RealisticCropRotationRepository:recordAppliedResidue(farmlandId, cropName, stateChange, sprayLevel, unit)
    -- Legacy writer retained for compatibility; current dev has no active nitrogen/PF caller.
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end
    if cropName == nil or cropName == "" then return false end

    local normalizedCropName = string.upper(tostring(cropName))
    local numericStateChange = tonumber(stateChange) or 0
    local numericSprayLevel = tonumber(sprayLevel) or 0
    local normalizedUnit = tostring(unit or "STATE")

    local existing = self.appliedResidue[numericFarmlandId]
        or self.appliedResidue[tostring(numericFarmlandId)]
    if existing ~= nil
        and existing.crop == normalizedCropName
        and (tonumber(existing.stateChange) or 0) == numericStateChange
        and (tonumber(existing.sprayLevel) or 0) == numericSprayLevel
        and tostring(existing.unit or "STATE") == normalizedUnit then
        return false
    end

    self.appliedResidue[numericFarmlandId] = {
        crop = normalizedCropName,
        stateChange = numericStateChange,
        sprayLevel = numericSprayLevel,
        unit = normalizedUnit,
    }
    self.appliedResidue[tostring(numericFarmlandId)] = nil
    return true
end

function RealisticCropRotationRepository:pushEntry(farmlandId, cropName, allowDuplicate)
    local entries = self.history[farmlandId]
    if entries == nil then
        entries = {}
        self.history[farmlandId] = entries
    end

    -- One entry per actual rotation change: ignore a crop that is already the most recent.
    -- This is what keeps the history from growing on every tool pass over the same crop.
    if not allowDuplicate and entries[1] ~= nil and entries[1].crop == cropName then
        return false
    end

    table.insert(entries, 1, { crop = cropName })
    while #entries > RealisticCropRotationRepository.MAX_HISTORY do
        table.remove(entries, #entries)
    end
    return true
end

function RealisticCropRotationRepository:getPlan(farmlandId)
    return self.plans[farmlandId] or {"","","",""}
end

function RealisticCropRotationRepository:getAllPlans()
    return self.plans
end

function RealisticCropRotationRepository:setPlanYear(farmlandId, yearIdx, family)
    yearIdx = tonumber(yearIdx) or 0
    if yearIdx < 1 or yearIdx > 4 then return end
    if self.plans[farmlandId] == nil then
        self.plans[farmlandId] = {"","","",""}
    end
    self.plans[farmlandId][yearIdx] = tostring(family or "")
end

function RealisticCropRotationRepository:clearPlan(farmlandId)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    local stringFarmlandId = tostring(numericFarmlandId)
    local changed = self.plans[numericFarmlandId] ~= nil or self.plans[stringFarmlandId] ~= nil
    self.plans[numericFarmlandId] = nil
    self.plans[stringFarmlandId] = nil
    return changed
end

function RealisticCropRotationRepository:getLastKnownActiveCrop(farmlandId)
    return self.lastKnownActiveCrop[farmlandId] or self.lastKnownActiveCrop[tostring(farmlandId)]
end

function RealisticCropRotationRepository:getAllLastKnownActiveCrops()
    return self.lastKnownActiveCrop
end

function RealisticCropRotationRepository:getLastKnownGrowthState(farmlandId)
    return tonumber(self.lastKnownGrowthState[farmlandId] or self.lastKnownGrowthState[tostring(farmlandId)])
end

function RealisticCropRotationRepository:getAllLastKnownGrowthStates()
    return self.lastKnownGrowthState
end

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

function RealisticCropRotationRepository:replaceAll(newHistory, newPlans, newLastKnownActiveCrop, newAppliedResidue, newLastKnownGrowthState)
    self.history = newHistory or {}
    self.plans   = newPlans or {}
    self.lastKnownActiveCrop = newLastKnownActiveCrop or {}
    self.lastKnownGrowthState = newLastKnownGrowthState or {}
    self.appliedResidue = newAppliedResidue or {}
end

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

    local allIds = {}
    local seen = {}
    for farmlandId in pairs(self.history) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and not seen[n] then seen[n] = true; table.insert(allIds, n) end
    end
    for farmlandId in pairs(self.plans) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and not seen[n] then seen[n] = true; table.insert(allIds, n) end
    end
    for farmlandId in pairs(self.lastKnownActiveCrop) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and not seen[n] then seen[n] = true; table.insert(allIds, n) end
    end
    for farmlandId in pairs(self.lastKnownGrowthState) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and not seen[n] then seen[n] = true; table.insert(allIds, n) end
    end
    for farmlandId in pairs(self.appliedResidue) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and not seen[n] then seen[n] = true; table.insert(allIds, n) end
    end
    table.sort(allIds)

    local farmlandIndex = 0
    for _, numericFarmlandId in ipairs(allIds) do
        local entries = self.history[numericFarmlandId]
        local hasHistory = entries ~= nil and #entries > 0
        local plan = self.plans[numericFarmlandId]
        local hasPlan = false
        if plan ~= nil then
            for i = 1, 4 do if plan[i] ~= nil and plan[i] ~= "" then hasPlan = true; break end end
        end
        local activeCrop = self.lastKnownActiveCrop[numericFarmlandId]
            or self.lastKnownActiveCrop[tostring(numericFarmlandId)]
        local hasActiveCrop = activeCrop ~= nil and activeCrop ~= ""
        local activeGrowthState = tonumber(self.lastKnownGrowthState[numericFarmlandId]
            or self.lastKnownGrowthState[tostring(numericFarmlandId)])
        local hasActiveGrowthState = activeGrowthState ~= nil and activeGrowthState >= 0

        local applied = self.appliedResidue[numericFarmlandId] or self.appliedResidue[tostring(numericFarmlandId)]
        local hasApplied = applied ~= nil and applied.crop ~= nil and applied.crop ~= ""

        if hasHistory or hasPlan or hasActiveCrop or hasActiveGrowthState or hasApplied then
            local farmlandKey = string.format("realisticCropRotation.farmland(%d)", farmlandIndex)
            setXMLInt(xmlFile, farmlandKey .. "#id", numericFarmlandId)
            if hasActiveCrop then
                setXMLString(xmlFile, farmlandKey .. "#lastKnownActiveCrop", tostring(activeCrop))
            end
            if hasActiveGrowthState then
                setXMLInt(xmlFile, farmlandKey .. "#lastKnownGrowthState", math.floor(activeGrowthState + 0.5))
            end
            if hasApplied then
                -- Legacy residue fields are kept to avoid dropping old save data.
                setXMLString(xmlFile, farmlandKey .. "#appliedResidueCrop", tostring(applied.crop or ""))
                setXMLString(xmlFile, farmlandKey .. "#appliedResidueUnit", tostring(applied.unit or "STATE"))
                setXMLInt(xmlFile, farmlandKey .. "#appliedResidueStateChange", tonumber(applied.stateChange) or 0)
                setXMLInt(xmlFile, farmlandKey .. "#appliedResidueSprayLevel", tonumber(applied.sprayLevel) or 0)
            end

            if hasHistory then
                for i, entry in ipairs(entries) do
                    if i > RealisticCropRotationRepository.MAX_HISTORY then break end
                    if entry ~= nil then
                        local entryKey = string.format("%s.entry(%d)", farmlandKey, i - 1)
                        setXMLString(xmlFile, entryKey .. "#crop", tostring(entry.crop or ""))
                    end
                end
            end

            if hasPlan then
                local planKey = farmlandKey .. ".plan(0)"
                for pi = 1, 4 do
                    if plan[pi] ~= nil and plan[pi] ~= "" then
                        setXMLString(xmlFile, planKey .. "#year" .. pi, plan[pi])
                    end
                end
            end

            farmlandIndex = farmlandIndex + 1
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)

    local historyFarmlands, historyEntries, planFarmlands, activeCropFarmlands, appliedResidueFarmlands =
        getPersistenceCounts(self.history, self.plans, self.lastKnownActiveCrop, self.appliedResidue)
    Logging.info("[RealisticCropRotation] Saved realisticCropRotation.xml historyFarmlands=%d entries=%d plans=%d activeCrops=%d appliedResidues=%d path=%s",
        historyFarmlands, historyEntries, planFarmlands, activeCropFarmlands, appliedResidueFarmlands, tostring(filePath))
end

function RealisticCropRotationRepository:loadFromXML(savegamePath)
    if savegamePath == nil or savegamePath == "" then
        Logging.warning("[RealisticCropRotation] Load skipped: savegame path unavailable")
        return
    end

    local filePath = savegamePath .. "realisticCropRotation.xml"
    if not fileExists(filePath) then
        Logging.info("[RealisticCropRotation] No realisticCropRotation.xml found at %s", tostring(filePath))
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

    self.history = {}
    self.plans   = {}
    self.lastKnownActiveCrop = {}
    self.lastKnownGrowthState = {}
    self.appliedResidue = {}

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

            local appliedCrop = getXMLString(xmlFile, farmlandKey .. "#appliedResidueCrop")
            if appliedCrop ~= nil and appliedCrop ~= "" then
                -- Legacy residue fields are loaded for compatibility only.
                self.appliedResidue[farmlandId] = {
                    crop = string.upper(tostring(appliedCrop)),
                    unit = getXMLString(xmlFile, farmlandKey .. "#appliedResidueUnit") or "STATE",
                    stateChange = getXMLInt(xmlFile, farmlandKey .. "#appliedResidueStateChange") or 0,
                    sprayLevel = getXMLInt(xmlFile, farmlandKey .. "#appliedResidueSprayLevel") or 0,
                }
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

            local planKey = farmlandKey .. ".plan(0)"
            if hasXMLProperty(xmlFile, planKey) then
                local plan = {"","","",""}
                local hasPlan = false
                for pi = 1, 4 do
                    local val = getXMLString(xmlFile, planKey .. "#year" .. pi)
                    if val ~= nil and val ~= "" then
                        plan[pi] = val
                        hasPlan = true
                    end
                end
                if hasPlan then self.plans[farmlandId] = plan end
            end
        end

        farmlandIndex = farmlandIndex + 1
    end

    local historyFarmlands, historyEntries, planFarmlands, activeCropFarmlands, appliedResidueFarmlands =
        getPersistenceCounts(self.history, self.plans, self.lastKnownActiveCrop, self.appliedResidue)
    Logging.info("[RealisticCropRotation] Loaded realisticCropRotation.xml historyFarmlands=%d entries=%d plans=%d activeCrops=%d appliedResidues=%d path=%s (format v%d)",
        historyFarmlands, historyEntries, planFarmlands, activeCropFarmlands, appliedResidueFarmlands, tostring(filePath), version)
    delete(xmlFile)
end
