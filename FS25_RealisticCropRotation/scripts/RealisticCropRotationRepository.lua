-- Copyright © 2026 Squallqt. All rights reserved.
-- CRUD + XML persistence for per-farmland crop history, active crop state,
-- rotation plans, and the period that validates the external nitrogen
-- application mask.
RealisticCropRotationRepository = {}
local RealisticCropRotationRepository_mt = Class(RealisticCropRotationRepository)

RealisticCropRotationRepository.SAVE_VERSION = 1
RealisticCropRotationRepository.MAX_HISTORY = 4

local function getPersistenceCounts(history, plans, lastKnownActiveCrop)
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

    return historyFarmlands, historyEntries, planFarmlands, activeCropFarmlands
end

function RealisticCropRotationRepository.new()
    local self = setmetatable({}, RealisticCropRotationRepository_mt)
    self.history = {}
    self.plans   = {}
    self.lastKnownActiveCrop = {}
    self.nitrogenMaskPeriod = 0
    return self
end

function RealisticCropRotationRepository:clear()
    self.history = {}
    self.plans   = {}
    self.lastKnownActiveCrop = {}
    self.nitrogenMaskPeriod = 0
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

function RealisticCropRotationRepository:pushEntry(farmlandId, cropName)
    local entries = self.history[farmlandId]
    if entries == nil then
        entries = {}
        self.history[farmlandId] = entries
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

function RealisticCropRotationRepository:setLastKnownActiveCrop(farmlandId, cropName)
    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return false end

    if cropName == nil or cropName == "" then
        local stringFarmlandId = tostring(numericFarmlandId)
        local changed = self.lastKnownActiveCrop[numericFarmlandId] ~= nil
            or self.lastKnownActiveCrop[stringFarmlandId] ~= nil
        self.lastKnownActiveCrop[numericFarmlandId] = nil
        self.lastKnownActiveCrop[stringFarmlandId] = nil
        return changed
    end

    local normalizedCropName = string.upper(tostring(cropName))
    local changed = self.lastKnownActiveCrop[numericFarmlandId] ~= normalizedCropName
    self.lastKnownActiveCrop[numericFarmlandId] = normalizedCropName
    self.lastKnownActiveCrop[tostring(numericFarmlandId)] = nil
    return changed
end

function RealisticCropRotationRepository:replaceAll(newHistory, newPlans, newLastKnownActiveCrop)
    self.history = newHistory or {}
    self.plans   = newPlans or {}
    self.lastKnownActiveCrop = newLastKnownActiveCrop or {}
end

function RealisticCropRotationRepository:getNitrogenMaskPeriod()
    return tonumber(self.nitrogenMaskPeriod) or 0
end

function RealisticCropRotationRepository:setNitrogenMaskPeriod(period)
    self.nitrogenMaskPeriod = tonumber(period) or 0
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
    if self.nitrogenMaskPeriod ~= nil and self.nitrogenMaskPeriod > 0 then
        setXMLInt(xmlFile, "realisticCropRotation#nitrogenMaskPeriod", self.nitrogenMaskPeriod)
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
    for farmlandId in pairs(self.lastKnownActiveCrop) do
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

        if hasHistory or hasPlan or hasActiveCrop then
            local farmlandKey = string.format("realisticCropRotation.farmland(%d)", farmlandIndex)
            setXMLInt(xmlFile, farmlandKey .. "#id", numericFarmlandId)
            if hasActiveCrop then
                setXMLString(xmlFile, farmlandKey .. "#lastKnownActiveCrop", tostring(activeCrop))
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

    local historyFarmlands, historyEntries, planFarmlands, activeCropFarmlands =
        getPersistenceCounts(self.history, self.plans, self.lastKnownActiveCrop)
    Logging.info("[RealisticCropRotation] Saved realisticCropRotation.xml historyFarmlands=%d entries=%d plans=%d activeCrops=%d path=%s",
        historyFarmlands, historyEntries, planFarmlands, activeCropFarmlands, tostring(filePath))
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
    self.nitrogenMaskPeriod = getXMLInt(xmlFile, "realisticCropRotation#nitrogenMaskPeriod") or 0

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

    local historyFarmlands, historyEntries, planFarmlands, activeCropFarmlands =
        getPersistenceCounts(self.history, self.plans, self.lastKnownActiveCrop)
    Logging.info("[RealisticCropRotation] Loaded realisticCropRotation.xml historyFarmlands=%d entries=%d plans=%d activeCrops=%d path=%s (format v%d)",
        historyFarmlands, historyEntries, planFarmlands, activeCropFarmlands, tostring(filePath), version)
    delete(xmlFile)
end
