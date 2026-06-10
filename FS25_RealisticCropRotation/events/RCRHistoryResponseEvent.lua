-- Copyright © 2026 Squallqt. All rights reserved.
-- Server->client full rotation snapshot. Sent on late-join and on explicit
-- RCRHistoryRequestEvent. Payload: history + plans + last known active crops
-- + last known growth states.
RCRHistoryResponseEvent = {}
local RCRHistoryResponseEvent_mt = Class(RCRHistoryResponseEvent, Event)

InitEventClass(RCRHistoryResponseEvent, "RCRHistoryResponseEvent")

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

function RCRHistoryResponseEvent.emptyNew()
    return Event.new(RCRHistoryResponseEvent_mt)
end

function RCRHistoryResponseEvent.new()
    return RCRHistoryResponseEvent.emptyNew()
end

function RCRHistoryResponseEvent:readStream(streamId, _connection)
    local farmlandCount = streamReadInt16(streamId)
    local received = {}
    local totalEntries = 0

    for _ = 1, farmlandCount do
        local farmlandId = streamReadInt32(streamId)
        local entryCount = streamReadInt8(streamId)
        local entries = {}
        for _ = 1, entryCount do
            local crop = streamReadString(streamId)
            table.insert(entries, { crop = crop })
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

    local coverPlanCount = streamReadInt16(streamId)
    local receivedCoverPlans = {}
    for _ = 1, coverPlanCount do
        local farmlandId = streamReadInt32(streamId)
        local coverPlan = {"","","",""}
        local hasCoverPlan = false
        for i = 1, 4 do
            local cropName = streamReadString(streamId)
            if cropName ~= nil and cropName ~= "" then
                coverPlan[i] = cropName
                hasCoverPlan = true
            end
        end
        if farmlandId > 0 and hasCoverPlan then
            receivedCoverPlans[farmlandId] = coverPlan
        end
    end

    local activeCropCount = streamReadInt16(streamId)
    local receivedLastKnownActiveCrop = {}
    for _ = 1, activeCropCount do
        local farmlandId = streamReadInt32(streamId)
        local cropName = streamReadString(streamId)
        if farmlandId > 0 and cropName ~= nil and cropName ~= "" then
            receivedLastKnownActiveCrop[farmlandId] = string.upper(tostring(cropName))
        end
    end

    local growthStateCount = streamReadInt16(streamId)
    local receivedLastKnownGrowthState = {}
    for _ = 1, growthStateCount do
        local farmlandId = streamReadInt32(streamId)
        local growthState = streamReadInt16(streamId)
        if farmlandId > 0 and growthState ~= nil and growthState >= 0 then
            receivedLastKnownGrowthState[farmlandId] = growthState
        end
    end

    -- A server replicating its own event back to itself: discard.
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil and g_currentMission:getIsServer() then
        return
    end

    local manager = g_currentMission ~= nil and g_currentMission.realisticCropRotationManager or nil
    if manager == nil then
        if RealisticCropRotation ~= nil then
            RealisticCropRotation.pendingSyncData = {
                history = received,
                plans = receivedPlans,
                coverPlans = receivedCoverPlans,
                lastKnownActiveCrop = receivedLastKnownActiveCrop,
                lastKnownGrowthState = receivedLastKnownGrowthState,
            }
        end
        Logging.warning("[RealisticCropRotation] RCRHistoryResponseEvent: manager not available, historyFarmlands=%d entries=%d plans=%d coverPlans=%d activeCrops=%d growthStates=%d buffered",
            farmlandCount, totalEntries, planCount, coverPlanCount, activeCropCount, growthStateCount)
        return
    end

    if manager.service ~= nil and type(manager.service.applySyncData) == "function" then
        manager.service:applySyncData(received, receivedPlans, receivedCoverPlans, receivedLastKnownActiveCrop, receivedLastKnownGrowthState)
    end

    Logging.info("[RealisticCropRotation][MP] Sync received historyFarmlands=%d entries=%d plans=%d coverPlans=%d activeCrops=%d growthStates=%d",
        farmlandCount, totalEntries, planCount, coverPlanCount, activeCropCount, growthStateCount)

    if RealisticCropRotation ~= nil and RealisticCropRotation.frame ~= nil then
        if type(RealisticCropRotation.frame.onServerSyncReceived) == "function" then
            RealisticCropRotation.frame:onServerSyncReceived()
        elseif type(RealisticCropRotation.frame.populateSidebar) == "function" then
            RealisticCropRotation.frame:populateSidebar()
        elseif type(RealisticCropRotation.frame.updateDetailPanel) == "function" then
            RealisticCropRotation.frame:updateDetailPanel(RealisticCropRotation.frame.selectedId)
        end
    end
end

function RCRHistoryResponseEvent:writeStream(streamId, _connection)
    local manager = g_currentMission ~= nil and g_currentMission.realisticCropRotationManager or nil
    if manager == nil or manager.service == nil or type(manager.service.getSyncData) ~= "function" then
        streamWriteInt16(streamId, 0)
        streamWriteInt16(streamId, 0)
        streamWriteInt16(streamId, 0)
        streamWriteInt16(streamId, 0)
        streamWriteInt16(streamId, 0)
        return
    end

    local history, lastKnownActiveCrop, lastKnownGrowthState = manager.service:getSyncData()
    history = history or {}
    lastKnownActiveCrop = lastKnownActiveCrop or {}
    lastKnownGrowthState = lastKnownGrowthState or {}
    local plans = type(manager.getAllRotationPlans) == "function" and manager:getAllRotationPlans() or {}
    local coverPlans = type(manager.getAllRotationCoverPlans) == "function" and manager:getAllRotationCoverPlans() or {}

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
        streamWriteInt8(streamId, math.min(#entries, RealisticCropRotationRepository.MAX_HISTORY))
        for i, entry in ipairs(entries) do
            if i > RealisticCropRotationRepository.MAX_HISTORY then break end
            streamWriteString(streamId, tostring(entry.crop or ""))
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

    local coverPlanFarmlandIds = {}
    for farmlandId, coverPlan in pairs(coverPlans) do
        local n = tonumber(farmlandId)
        local hasCoverPlan = false
        if coverPlan ~= nil then
            for i = 1, 4 do if coverPlan[i] ~= nil and coverPlan[i] ~= "" then hasCoverPlan = true; break end end
        end
        if n ~= nil and n > 0 and hasCoverPlan then
            table.insert(coverPlanFarmlandIds, n)
        end
    end

    streamWriteInt16(streamId, #coverPlanFarmlandIds)
    for _, farmlandId in ipairs(coverPlanFarmlandIds) do
        local coverPlan = coverPlans[farmlandId] or coverPlans[tostring(farmlandId)] or {"","","",""}
        streamWriteInt32(streamId, farmlandId)
        for i = 1, 4 do
            streamWriteString(streamId, tostring(coverPlan[i] or ""))
        end
    end

    local activeCropFarmlandIds = {}
    for farmlandId, cropName in pairs(lastKnownActiveCrop) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and cropName ~= nil and cropName ~= "" then
            table.insert(activeCropFarmlandIds, n)
        end
    end

    streamWriteInt16(streamId, #activeCropFarmlandIds)
    for _, farmlandId in ipairs(activeCropFarmlandIds) do
        local cropName = lastKnownActiveCrop[farmlandId] or lastKnownActiveCrop[tostring(farmlandId)] or ""
        streamWriteInt32(streamId, farmlandId)
        streamWriteString(streamId, tostring(cropName))
    end

    local growthStateFarmlandIds = {}
    for farmlandId, growthState in pairs(lastKnownGrowthState) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and tonumber(growthState) ~= nil then
            table.insert(growthStateFarmlandIds, n)
        end
    end

    streamWriteInt16(streamId, #growthStateFarmlandIds)
    for _, farmlandId in ipairs(growthStateFarmlandIds) do
        local growthState = tonumber(lastKnownGrowthState[farmlandId] or lastKnownGrowthState[tostring(farmlandId)]) or 0
        streamWriteInt32(streamId, farmlandId)
        streamWriteInt16(streamId, math.max(0, math.floor(growthState + 0.5)))
    end

    local _, entryCount = countHistory(history)
    Logging.info("[RealisticCropRotation][MP] Sync sent historyFarmlands=%d entries=%d plans=%d coverPlans=%d activeCrops=%d growthStates=%d",
        #farmlandIds, entryCount, #planFarmlandIds, #coverPlanFarmlandIds, #activeCropFarmlandIds, #growthStateFarmlandIds)
end
