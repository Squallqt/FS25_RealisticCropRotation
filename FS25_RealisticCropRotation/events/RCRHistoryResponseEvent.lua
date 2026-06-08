-- Copyright © 2026 Squallqt. All rights reserved.
-- Server->client full rotation snapshot. Sent on late-join and on explicit
-- RCRHistoryRequestEvent. Payload: history + plans + last known active crops
-- + applied residue state.
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

    local activeCropCount = streamReadInt16(streamId)
    local receivedLastKnownActiveCrop = {}
    for _ = 1, activeCropCount do
        local farmlandId = streamReadInt32(streamId)
        local cropName = streamReadString(streamId)
        if farmlandId > 0 and cropName ~= nil and cropName ~= "" then
            receivedLastKnownActiveCrop[farmlandId] = string.upper(tostring(cropName))
        end
    end

    -- Legacy residue payload; kept for old save/MP wire compatibility.
    local appliedResidueCount = streamReadInt16(streamId)
    local receivedAppliedResidue = {}
    for _ = 1, appliedResidueCount do
        local farmlandId = streamReadInt32(streamId)
        local cropName = streamReadString(streamId)
        local unit = streamReadString(streamId)
        local stateChange = streamReadInt16(streamId)
        local sprayLevel = streamReadInt8(streamId)
        if farmlandId > 0 and cropName ~= nil and cropName ~= "" then
            receivedAppliedResidue[farmlandId] = {
                crop = string.upper(tostring(cropName)),
                unit = unit ~= nil and unit ~= "" and unit or "STATE",
                stateChange = stateChange or 0,
                sprayLevel = sprayLevel or 0,
            }
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
                lastKnownActiveCrop = receivedLastKnownActiveCrop,
                appliedResidue = receivedAppliedResidue,
            }
        end
        Logging.warning("[RealisticCropRotation] RCRHistoryResponseEvent: manager not available, historyFarmlands=%d entries=%d plans=%d activeCrops=%d appliedResidues=%d buffered",
            farmlandCount, totalEntries, planCount, activeCropCount, appliedResidueCount)
        return
    end

    if manager.service ~= nil and type(manager.service.applySyncData) == "function" then
        manager.service:applySyncData(received, receivedPlans, receivedLastKnownActiveCrop, receivedAppliedResidue)
    end

    Logging.info("[RealisticCropRotation][MP] Sync received historyFarmlands=%d entries=%d plans=%d activeCrops=%d appliedResidues=%d",
        farmlandCount, totalEntries, planCount, activeCropCount, appliedResidueCount)

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
        return
    end

    local history, lastKnownActiveCrop, appliedResidue = manager.service:getSyncData()
    history = history or {}
    lastKnownActiveCrop = lastKnownActiveCrop or {}
    -- Legacy residue payload; no current dev runtime applies nitrogen/PF effects.
    appliedResidue = appliedResidue or {}
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

    local appliedResidueFarmlandIds = {}
    for farmlandId, entry in pairs(appliedResidue) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and entry ~= nil and entry.crop ~= nil and entry.crop ~= "" then
            table.insert(appliedResidueFarmlandIds, n)
        end
    end

    streamWriteInt16(streamId, #appliedResidueFarmlandIds)
    for _, farmlandId in ipairs(appliedResidueFarmlandIds) do
        local entry = appliedResidue[farmlandId] or appliedResidue[tostring(farmlandId)] or {}
        streamWriteInt32(streamId, farmlandId)
        streamWriteString(streamId, tostring(entry.crop or ""))
        streamWriteString(streamId, tostring(entry.unit or "STATE"))
        streamWriteInt16(streamId, tonumber(entry.stateChange) or 0)
        streamWriteInt8(streamId, tonumber(entry.sprayLevel) or 0)
    end

    local _, entryCount = countHistory(history)
    Logging.info("[RealisticCropRotation][MP] Sync sent historyFarmlands=%d entries=%d plans=%d activeCrops=%d appliedResidues=%d",
        #farmlandIds, entryCount, #planFarmlandIds, #activeCropFarmlandIds, #appliedResidueFarmlandIds)
end
