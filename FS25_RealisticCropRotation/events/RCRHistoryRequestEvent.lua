-- Copyright © 2026 Squallqt. All rights reserved.
-- Client->server request for a full history snapshot. Server replies with RCRHistoryResponseEvent.
RCRHistoryRequestEvent = {}
local RCRHistoryRequestEvent_mt = Class(RCRHistoryRequestEvent, Event)

InitEventClass(RCRHistoryRequestEvent, "RCRHistoryRequestEvent")

local HISTORY_REQUEST_RECONCILE_COOLDOWN_MS = 2000

local function reconcileHistoryForRequest(manager)
    if manager == nil
        or type(manager.getOwnedRotationFarmlandIds) ~= "function"
        or type(manager.reconcileActiveCropForFarmland) ~= "function" then
        return false
    end

    local nowMs = tonumber(g_time) or 0
    local lastMs = tonumber(manager.lastHistoryRequestReconcileMs)
    if lastMs ~= nil and nowMs >= lastMs
        and nowMs - lastMs < HISTORY_REQUEST_RECONCILE_COOLDOWN_MS then
        return false
    end

    manager.lastHistoryRequestReconcileMs = nowMs

    local changed = false
    for _, farmlandId in ipairs(manager:getOwnedRotationFarmlandIds() or {}) do
        if manager:reconcileActiveCropForFarmland(farmlandId) then
            changed = true
        end
    end
    return changed
end

---Creates empty event instance
-- @return RCRHistoryRequestEvent instance Empty event
function RCRHistoryRequestEvent.emptyNew()
    local self = Event.new(RCRHistoryRequestEvent_mt)
    return self
end

---Creates initialized request event
-- @return RCRHistoryRequestEvent instance The new event instance
function RCRHistoryRequestEvent.new()
    local self = RCRHistoryRequestEvent.emptyNew()
    return self
end

---Reads request from network stream (no payload). Server replies on receipt.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRHistoryRequestEvent:readStream(streamId, connection)
    if g_server == nil then return end

    if connection == nil then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: connection is nil, cannot reply")
        return
    end

    local manager = g_currentMission ~= nil and g_currentMission.realisticCropRotationManager or nil
    if manager == nil then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: manager not available, replying without reconcile")
    elseif reconcileHistoryForRequest(manager)
        and RealisticCropRotation ~= nil
        and type(RealisticCropRotation.requestBroadcast) == "function" then
        RealisticCropRotation.requestBroadcast()
    end

    if RCRHistoryResponseEvent == nil or type(RCRHistoryResponseEvent.new) ~= "function" then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: response event unavailable, cannot reply")
        return
    end

    Logging.info("[RealisticCropRotation][MP] Sync request received")
    connection:sendEvent(RCRHistoryResponseEvent.new())
end

---Writes request to network stream (no payload).
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRHistoryRequestEvent:writeStream(streamId, connection)
    -- No payload: presence of the event is the request.
end
