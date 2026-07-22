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

---Creates initialized request event.
-- @param integer selectedFarmlandId Farmland to reconcile first, or nil
-- @return RCRHistoryRequestEvent instance The new event instance
function RCRHistoryRequestEvent.new(selectedFarmlandId)
    local self = RCRHistoryRequestEvent.emptyNew()
    self.selectedFarmlandId = math.floor(tonumber(selectedFarmlandId) or 0)
    return self
end

---Reads the request; the server replies immediately, then schedules reconciliation.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRHistoryRequestEvent:readStream(streamId, connection)
    self.selectedFarmlandId = streamReadInt32(streamId)
    if g_server == nil then return end

    if connection == nil then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: connection is nil, cannot reply")
        return
    end

    local manager = g_currentMission ~= nil and g_currentMission.realisticCropRotationManager or nil
    if manager == nil then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: manager not available, replying without reconcile")
    end

    if RCRHistoryResponseEvent == nil or type(RCRHistoryResponseEvent.new) ~= "function" then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: response event unavailable, cannot reply")
    else
        connection:sendEvent(RCRHistoryResponseEvent.new())
    end

    if manager ~= nil and RealisticCropRotation ~= nil
        and type(RealisticCropRotation.requestMenuReconcile) == "function" then
        RealisticCropRotation.requestMenuReconcile(self.selectedFarmlandId)
    end
end

---Writes the selected farmland priority.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRHistoryRequestEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, math.floor(tonumber(self.selectedFarmlandId) or 0))
end
