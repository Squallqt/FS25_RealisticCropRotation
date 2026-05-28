-- Copyright © 2026 Squallqt. All rights reserved.
-- Client->server request for a full history snapshot. Server replies with FRHistoryResponseEvent.
FRHistoryRequestEvent = {}
local FRHistoryRequestEvent_mt = Class(FRHistoryRequestEvent, Event)

InitEventClass(FRHistoryRequestEvent, "FRHistoryRequestEvent")

---Creates empty event instance
-- @return FRHistoryRequestEvent instance Empty event
function FRHistoryRequestEvent.emptyNew()
    local self = Event.new(FRHistoryRequestEvent_mt)
    return self
end

---Creates initialized request event
-- @return FRHistoryRequestEvent instance The new event instance
function FRHistoryRequestEvent.new()
    local self = FRHistoryRequestEvent.emptyNew()
    return self
end

---Reads request from network stream (no payload). Server replies on receipt.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function FRHistoryRequestEvent:readStream(streamId, connection)
    if g_server == nil then return end

    if g_currentMission == nil or g_currentMission.fieldRotationManager == nil then
        Logging.warning("[FieldRotation] FRHistoryRequestEvent: manager not available, ignoring request")
        return
    end

    if connection == nil then
        Logging.warning("[FieldRotation] FRHistoryRequestEvent: connection is nil, cannot reply")
        return
    end

    Logging.info("[FieldRotation][MP] Sync request received")
    connection:sendEvent(FRHistoryResponseEvent.new())
end

---Writes request to network stream (no payload).
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function FRHistoryRequestEvent:writeStream(streamId, connection)
    -- No payload: presence of the event is the request.
end
