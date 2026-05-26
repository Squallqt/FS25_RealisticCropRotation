-- Copyright © 2026 Squallqt. All rights reserved.
-- CRUD + XML persistence for per-farmland crop history, rotation plans, and
-- the period that validates the external nitrogen application mask.
FieldRotationRepository = {}
local FieldRotationRepository_mt = Class(FieldRotationRepository)

FieldRotationRepository.SAVE_VERSION = 1
FieldRotationRepository.MAX_HISTORY = 4

local function getPersistenceCounts(history, plans)
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

    return historyFarmlands, historyEntries, planFarmlands
end

function FieldRotationRepository.new()
    local self = setmetatable({}, FieldRotationRepository_mt)
    self.history = {}
    self.plans   = {}
    self.nitrogenMaskPeriod = 0
    return self
end

function FieldRotationRepository:clear()
    self.history = {}
    self.plans   = {}
    self.nitrogenMaskPeriod = 0
end

function FieldRotationRepository:getHistory(farmlandId)
    local entries = self.history[farmlandId]
    if entries == nil then return {} end
    return entries
end

function FieldRotationRepository:getHistoryNoAlloc(farmlandId)
    return self.history[farmlandId]
end

function FieldRotationRepository:getAllHistory()
    return self.history
end

function FieldRotationRepository:pushEntry(farmlandId, cropName, period, year)
    local entries = self.history[farmlandId]
    if entries == nil then
        entries = {}
        self.history[farmlandId] = entries
    end

    local numericYear = tonumber(year) or 0
    if numericYear > 0 and entries[1] ~= nil and tonumber(entries[1].year) == numericYear then
        if entries[1].crop == cropName then
            return false
        end
        entries[1].crop = cropName
        entries[1].period = period
        entries[1].year = numericYear
        return true
    end

    table.insert(entries, 1, { crop = cropName, period = period, year = numericYear })
    while #entries > FieldRotationRepository.MAX_HISTORY do
        table.remove(entries, #entries)
    end
    return true
end

function FieldRotationRepository:getPlan(farmlandId)
    return self.plans[farmlandId] or {"","","",""}
end

function FieldRotationRepository:getAllPlans()
    return self.plans
end

function FieldRotationRepository:setPlanYear(farmlandId, yearIdx, family)
    yearIdx = tonumber(yearIdx) or 0
    if yearIdx < 1 or yearIdx > 4 then return end
    if self.plans[farmlandId] == nil then
        self.plans[farmlandId] = {"","","",""}
    end
    self.plans[farmlandId][yearIdx] = tostring(family or "")
end

function FieldRotationRepository:replaceAll(newHistory, newPlans)
    self.history = newHistory or {}
    self.plans   = newPlans or {}
end

function FieldRotationRepository:getNitrogenMaskPeriod()
    return tonumber(self.nitrogenMaskPeriod) or 0
end

function FieldRotationRepository:setNitrogenMaskPeriod(period)
    self.nitrogenMaskPeriod = tonumber(period) or 0
end

function FieldRotationRepository:saveToXML(savegamePath)
    if savegamePath == nil or savegamePath == "" then
        Logging.warning("[FieldRotation] Save skipped: savegame path unavailable")
        return
    end

    local filePath = savegamePath .. "fieldRotation.xml"
    local xmlFile = createXMLFile("fieldRotation", filePath, "fieldRotation")
    if xmlFile == nil or xmlFile == 0 then
        Logging.error("[FieldRotation] Failed to create save file: %s", filePath)
        return
    end

    setXMLInt(xmlFile, "fieldRotation#version", FieldRotationRepository.SAVE_VERSION)
    if self.nitrogenMaskPeriod ~= nil and self.nitrogenMaskPeriod > 0 then
        setXMLInt(xmlFile, "fieldRotation#nitrogenMaskPeriod", self.nitrogenMaskPeriod)
    end

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

        if hasHistory or hasPlan then
            local farmlandKey = string.format("fieldRotation.farmland(%d)", farmlandIndex)
            setXMLInt(xmlFile, farmlandKey .. "#id", numericFarmlandId)

            if hasHistory then
                for i, entry in ipairs(entries) do
                    if i > FieldRotationRepository.MAX_HISTORY then break end
                    if entry ~= nil then
                        local entryKey = string.format("%s.entry(%d)", farmlandKey, i - 1)
                        setXMLString(xmlFile, entryKey .. "#crop", tostring(entry.crop or ""))
                        setXMLInt(xmlFile, entryKey .. "#period", tonumber(entry.period) or 0)
                        local year = tonumber(entry.year) or 0
                        if year > 0 then
                            setXMLInt(xmlFile, entryKey .. "#year", year)
                        end
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

    local historyFarmlands, historyEntries, planFarmlands = getPersistenceCounts(self.history, self.plans)
    Logging.info("[FieldRotation] Saved fieldRotation.xml historyFarmlands=%d entries=%d plans=%d path=%s",
        historyFarmlands, historyEntries, planFarmlands, tostring(filePath))
end

function FieldRotationRepository:loadFromXML(savegamePath)
    if savegamePath == nil or savegamePath == "" then
        Logging.warning("[FieldRotation] Load skipped: savegame path unavailable")
        return
    end

    local filePath = savegamePath .. "fieldRotation.xml"
    if not fileExists(filePath) then
        Logging.info("[FieldRotation] No fieldRotation.xml found at %s", tostring(filePath))
        return
    end

    local xmlFile = loadXMLFile("fieldRotation", filePath)
    if xmlFile == nil or xmlFile == 0 then
        Logging.warning("[FieldRotation] Failed to load save file: %s", filePath)
        return
    end

    local version = getXMLInt(xmlFile, "fieldRotation#version") or 1
    if version > FieldRotationRepository.SAVE_VERSION then
        Logging.warning("[FieldRotation] Save file version %d is newer than supported %d. Some data may be ignored.",
            version, FieldRotationRepository.SAVE_VERSION)
    end

    self.history = {}
    self.plans   = {}
    self.nitrogenMaskPeriod = getXMLInt(xmlFile, "fieldRotation#nitrogenMaskPeriod") or 0

    local farmlandIndex = 0
    while true do
        local farmlandKey = string.format("fieldRotation.farmland(%d)", farmlandIndex)
        if not hasXMLProperty(xmlFile, farmlandKey) then break end

        local farmlandId = getXMLInt(xmlFile, farmlandKey .. "#id")
        if farmlandId ~= nil and farmlandId > 0 then
            local entries = {}
            local entryIndex = 0
            while true do
                local entryKey = string.format("%s.entry(%d)", farmlandKey, entryIndex)
                if not hasXMLProperty(xmlFile, entryKey) then break end
                local crop = getXMLString(xmlFile, entryKey .. "#crop")
                local period = getXMLInt(xmlFile, entryKey .. "#period")
                local year = getXMLInt(xmlFile, entryKey .. "#year") or 0
                if crop ~= nil and crop ~= "" and period ~= nil then
                    table.insert(entries, { crop = crop, period = period, year = year })
                end
                entryIndex = entryIndex + 1
                if entryIndex >= FieldRotationRepository.MAX_HISTORY then break end
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

    local historyFarmlands, historyEntries, planFarmlands = getPersistenceCounts(self.history, self.plans)
    Logging.info("[FieldRotation] Loaded fieldRotation.xml historyFarmlands=%d entries=%d plans=%d path=%s (format v%d)",
        historyFarmlands, historyEntries, planFarmlands, tostring(filePath), version)
    delete(xmlFile)
end
