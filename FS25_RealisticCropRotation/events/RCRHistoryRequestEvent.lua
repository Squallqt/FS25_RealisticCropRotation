-- Copyright © 2026 Squallqt. All rights reserved.
-- Client->server request for farm-visible or selected-field reconciliation.
RCRHistoryRequestEvent = {}
local RCRHistoryRequestEvent_mt = Class(RCRHistoryRequestEvent, Event)

InitEventClass(RCRHistoryRequestEvent, "RCRHistoryRequestEvent")

---Creates empty event instance
-- @return RCRHistoryRequestEvent instance Empty event
function RCRHistoryRequestEvent.emptyNew()
    local self = Event.new(RCRHistoryRequestEvent_mt)
    return self
end

---Normalizes a farmland id list for network transfer.
-- @param table? farmlandIds
-- @return table normalizedIds
local function normalizeFarmlandIds(farmlandIds)
    local result = {}
    local seen = {}
    for _, farmlandId in ipairs(farmlandIds or {}) do
        local numericId = math.floor(tonumber(farmlandId) or 0)
        if numericId > 0 and not seen[numericId] then
            result[#result + 1] = numericId
            seen[numericId] = true
        end
    end
    return result
end

---Returns the farm id authenticated by the request connection.
-- @param Connection connection
-- @return integer farmId, or nil
local function getRequestFarmId(connection)
    if connection == nil or g_currentMission == nil or g_currentMission.userManager == nil
        or g_currentMission.userManager.getUserIdByConnection == nil then return nil end

    local userId = g_currentMission.userManager:getUserIdByConnection(connection)
    if userId == nil or g_farmManager == nil or g_farmManager.getFarmByUserId == nil then return nil end
    local farm = g_farmManager:getFarmByUserId(userId)
    return farm ~= nil and tonumber(farm.farmId) or nil
end

---Creates initialized request event.
-- @param integer? selectedFarmlandId Farmland to reconcile first
-- @param boolean? selectedOnly True to reconcile only the selected farmland
-- @param table? farmlandIds Exact sidebar farmland ids for a full refresh
-- @return RCRHistoryRequestEvent instance The new event instance
function RCRHistoryRequestEvent.new(selectedFarmlandId, selectedOnly, farmlandIds)
    local self = RCRHistoryRequestEvent.emptyNew()
    self.selectedFarmlandId = math.floor(tonumber(selectedFarmlandId) or 0)
    self.selectedOnly = selectedOnly == true
    self.farmlandIds = normalizeFarmlandIds(farmlandIds)
    return self
end

---Reads the request and schedules server reconciliation.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRHistoryRequestEvent:readStream(streamId, connection)
    self.selectedFarmlandId = streamReadInt32(streamId)
    self.selectedOnly = streamReadBool(streamId)
    local farmlandCount = math.max(0, streamReadInt16(streamId))
    self.farmlandIds = {}
    for _ = 1, farmlandCount do
        self.farmlandIds[#self.farmlandIds + 1] = streamReadInt32(streamId)
    end
    if g_server == nil then return end

    if connection == nil then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: connection is nil, cannot reply")
        return
    end

    local manager = g_currentMission ~= nil and g_currentMission.realisticCropRotationManager or nil
    if manager == nil then
        Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: manager not available")
    end

    if manager ~= nil then
        local farmId = getRequestFarmId(connection)
        if farmId == nil then
            Logging.warning("[RealisticCropRotation] RCRHistoryRequestEvent: requester farm unavailable")
            return
        end
        RealisticCropRotation.requestMenuReconcile(
            self.selectedFarmlandId, self.selectedOnly, self.farmlandIds, connection, farmId)
    end
end

---Writes the selected farmland priority and exact sidebar scope.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRHistoryRequestEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, math.floor(tonumber(self.selectedFarmlandId) or 0))
    streamWriteBool(streamId, self.selectedOnly == true)
    local farmlandIds = normalizeFarmlandIds(self.farmlandIds)
    streamWriteInt16(streamId, #farmlandIds)
    for _, farmlandId in ipairs(farmlandIds) do
        streamWriteInt32(streamId, farmlandId)
    end
end
