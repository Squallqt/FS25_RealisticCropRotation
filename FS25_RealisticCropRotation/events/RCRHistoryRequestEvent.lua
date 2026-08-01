-- Copyright © 2026 Squallqt. All rights reserved.
-- Client->server request for a full history snapshot or a selected-field reconciliation.
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
-- @param integer? selectedFarmlandId Farmland to reconcile first
-- @param boolean? selectedOnly True to reconcile only the selected farmland
-- @return RCRHistoryRequestEvent instance The new event instance
function RCRHistoryRequestEvent.new(selectedFarmlandId, selectedOnly)
    local self = RCRHistoryRequestEvent.emptyNew()
    self.selectedFarmlandId = math.floor(tonumber(selectedFarmlandId) or 0)
    self.selectedOnly = selectedOnly == true
    return self
end

---Reads the request and schedules server reconciliation.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRHistoryRequestEvent:readStream(streamId, connection)
    self.selectedFarmlandId = streamReadInt32(streamId)
    self.selectedOnly = streamReadBool(streamId)
    if g_server == nil then return end

    if connection == nil then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: connection is nil, cannot reply")
        return
    end

    local manager = g_currentMission ~= nil and g_currentMission.realisticCropRotationManager or nil
    if manager == nil then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: manager not available")
    end

    if not self.selectedOnly then
        connection:sendEvent(RCRHistoryResponseEvent.new())
    end

    if manager ~= nil then
        RealisticCropRotation.requestMenuReconcile(self.selectedFarmlandId, self.selectedOnly)
    end
end

---Writes the selected farmland priority.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRHistoryRequestEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, math.floor(tonumber(self.selectedFarmlandId) or 0))
    streamWriteBool(streamId, self.selectedOnly == true)
end
