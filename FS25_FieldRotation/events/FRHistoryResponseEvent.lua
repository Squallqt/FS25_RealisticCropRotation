-- Copyright © 2026 Squallqt. All rights reserved.
-- Server->client full rotation snapshot. Sent on late-join and on explicit
-- FRHistoryRequestEvent. Payload: history + plans + server-authoritative active
-- crops. The local game sources do not prove field.fieldState is authoritative
-- on clients, so clients must not infer active crops from it.
FRHistoryResponseEvent = {}
local FRHistoryResponseEvent_mt = Class(FRHistoryResponseEvent, Event)

InitEventClass(FRHistoryResponseEvent, "FRHistoryResponseEvent")

local function countHistory(history)
    local farmlandCount = 0
    local entryCount = 0
    for _, entries in pairs(history or {}) do
        if entries ~= nil and #entries > 0 then
            farmlandCount = farmlandCount + 1
            entryCount = entryCount + #entries
        end
    end
    return farmlandCount, entryCount
end

local function getSortedActiveCropIds(activeCrops)
    local ids = {}
    for farmlandId, cropName in pairs(activeCrops or {}) do
        local numericFarmlandId = tonumber(farmlandId)
        if numericFarmlandId ~= nil and numericFarmlandId > 0
            and cropName ~= nil and cropName ~= "" then
            table.insert(ids, numericFarmlandId)
        end
    end
    table.sort(ids)
    return ids
end

function FRHistoryResponseEvent.emptyNew()
    return Event.new(FRHistoryResponseEvent_mt)
end

function FRHistoryResponseEvent.new()
    return FRHistoryResponseEvent.emptyNew()
end

function FRHistoryResponseEvent:readStream(streamId, _connection)
    local farmlandCount = streamReadInt16(streamId)
    local received = {}
    local totalEntries = 0

    for _ = 1, farmlandCount do
        local farmlandId = streamReadInt32(streamId)
        local entryCount = streamReadInt8(streamId)
        local entries = {}
        for _ = 1, entryCount do
            local crop = streamReadString(streamId)
            local period = streamReadInt16(streamId)
            local year = streamReadInt32(streamId)
            table.insert(entries, { crop = crop, period = period, year = year })
        end
        if farmlandId > 0 and #entries > 0 then
            received[farmlandId] = entries
            totalEntries = totalEntries + #entries
        end
    end

    local planCount = streamReadInt16(streamId)
    local receivedPlans = {}
    for _ = 1, planCount do
        local farmlandId = streamReadInt32(streamId)
        local plan = {"","","",""}
        local hasPlan = false
        for i = 1, 4 do
            local cropName = streamReadString(streamId)
            if cropName ~= nil and cropName ~= "" then
                plan[i] = cropName
                hasPlan = true
            end
        end
        if farmlandId > 0 and hasPlan then
            receivedPlans[farmlandId] = plan
        end
    end

    local activeCropCount = streamReadInt16(streamId)
    local receivedActiveCrops = {}
    for _ = 1, activeCropCount do
        local farmlandId = streamReadInt32(streamId)
        local cropName = streamReadString(streamId)
        if farmlandId > 0 and cropName ~= nil and cropName ~= "" then
            receivedActiveCrops[farmlandId] = cropName
        end
    end

    -- A server replicating its own event back to itself: discard.
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil and g_currentMission:getIsServer() then
        return
    end

    local manager = g_currentMission ~= nil and g_currentMission.fieldRotationManager or nil
    if manager == nil then
        if FieldRotation ~= nil then
            FieldRotation.pendingSyncData = {
                history = received,
                plans = receivedPlans,
                activeCrops = receivedActiveCrops,
            }
        end
        Logging.warning("[FieldRotation] FRHistoryResponseEvent: manager not available, historyFarmlands=%d entries=%d plans=%d activeCrops=%d buffered",
            farmlandCount, totalEntries, planCount, activeCropCount)
        return
    end

    if manager.service ~= nil and type(manager.service.applySyncData) == "function" then
        manager.service:applySyncData(received, receivedPlans)
    end
    if type(manager.setSyncedActiveCrops) == "function" then
        manager:setSyncedActiveCrops(receivedActiveCrops)
    end

    Logging.info("[FieldRotation][MP] Sync received historyFarmlands=%d entries=%d plans=%d activeCrops=%d",
        farmlandCount, totalEntries, planCount, activeCropCount)

    if FieldRotation ~= nil and FieldRotation.frame ~= nil then
        if type(FieldRotation.frame.onServerSyncReceived) == "function" then
            FieldRotation.frame:onServerSyncReceived()
        elseif type(FieldRotation.frame.populateSidebar) == "function" then
            FieldRotation.frame:populateSidebar()
        elseif type(FieldRotation.frame.updateDetailPanel) == "function" then
            FieldRotation.frame:updateDetailPanel(FieldRotation.frame.selectedId)
        end
    end
end

function FRHistoryResponseEvent:writeStream(streamId, _connection)
    local manager = g_currentMission ~= nil and g_currentMission.fieldRotationManager or nil
    if manager == nil or manager.service == nil or type(manager.service.getSyncData) ~= "function" then
        streamWriteInt16(streamId, 0)
        streamWriteInt16(streamId, 0)
        streamWriteInt16(streamId, 0)
        return
    end

    local history = manager.service:getSyncData() or {}
    local plans = type(manager.getAllRotationPlans) == "function" and manager:getAllRotationPlans() or {}

    local farmlandIds = {}
    for farmlandId, entries in pairs(history) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and entries ~= nil and #entries > 0 then
            table.insert(farmlandIds, n)
        end
    end

    streamWriteInt16(streamId, #farmlandIds)
    for _, farmlandId in ipairs(farmlandIds) do
        local entries = history[farmlandId] or history[tostring(farmlandId)] or {}
        streamWriteInt32(streamId, farmlandId)
        streamWriteInt8(streamId, math.min(#entries, FieldRotationRepository.MAX_HISTORY))
        for i, entry in ipairs(entries) do
            if i > FieldRotationRepository.MAX_HISTORY then break end
            streamWriteString(streamId, tostring(entry.crop or ""))
            streamWriteInt16(streamId, tonumber(entry.period) or 0)
            streamWriteInt32(streamId, tonumber(entry.year) or 0)
        end
    end

    local planFarmlandIds = {}
    for farmlandId, plan in pairs(plans) do
        local n = tonumber(farmlandId)
        local hasPlan = false
        if plan ~= nil then
            for i = 1, 4 do if plan[i] ~= nil and plan[i] ~= "" then hasPlan = true; break end end
        end
        if n ~= nil and n > 0 and hasPlan then
            table.insert(planFarmlandIds, n)
        end
    end

    streamWriteInt16(streamId, #planFarmlandIds)
    for _, farmlandId in ipairs(planFarmlandIds) do
        local plan = plans[farmlandId] or plans[tostring(farmlandId)] or {"","","",""}
        streamWriteInt32(streamId, farmlandId)
        for i = 1, 4 do
            streamWriteString(streamId, tostring(plan[i] or ""))
        end
    end

    local activeCrops = type(manager.getCurrentActiveCropSnapshot) == "function"
        and manager:getCurrentActiveCropSnapshot()
        or {}
    local activeCropIds = getSortedActiveCropIds(activeCrops)
    streamWriteInt16(streamId, #activeCropIds)
    for _, farmlandId in ipairs(activeCropIds) do
        streamWriteInt32(streamId, farmlandId)
        streamWriteString(streamId, tostring(activeCrops[farmlandId] or activeCrops[tostring(farmlandId)] or ""))
    end

    local _, entryCount = countHistory(history)
    Logging.info("[FieldRotation][MP] Sync sent historyFarmlands=%d entries=%d plans=%d activeCrops=%d",
        #farmlandIds, entryCount, #planFarmlandIds, #activeCropIds)
end
