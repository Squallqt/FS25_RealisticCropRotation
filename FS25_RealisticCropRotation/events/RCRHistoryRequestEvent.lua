-- Copyright © 2026 Squallqt. All rights reserved.
-- Client->server request for a full history snapshot. Server replies with RCRHistoryResponseEvent.
RCRHistoryRequestEvent = {}
local RCRHistoryRequestEvent_mt = Class(RCRHistoryRequestEvent, Event)

InitEventClass(RCRHistoryRequestEvent, "RCRHistoryRequestEvent")

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

    if g_currentMission == nil or g_currentMission.realisticCropRotationManager == nil then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: manager not available, ignoring request")
        return
    end

    if connection == nil then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: connection is nil, cannot reply")
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
