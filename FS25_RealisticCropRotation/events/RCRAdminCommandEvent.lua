-- Copyright © 2026 Squallqt. All rights reserved.
-- Client->server relay for the admin disease commands.
RCRAdminCommandEvent = {}
local RCRAdminCommandEvent_mt = Class(RCRAdminCommandEvent, Event)

InitEventClass(RCRAdminCommandEvent, "RCRAdminCommandEvent")

-- Commands a master user may relay, mapped to their handler on the disease layer.
local HANDLERS = {
    rcrDiseaseInfect = function(disease, a, b, c) return disease:consoleInfect(a, b, c) end,
    rcrDiseaseTick   = function(disease, a)       return disease:consoleTick(a) end,
    rcrDiseaseClear  = function(disease, a)       return disease:consoleClear(a) end,
}

---Creates an empty event instance for deserialization.
-- @return RCRAdminCommandEvent instance
function RCRAdminCommandEvent.emptyNew()
    return Event.new(RCRAdminCommandEvent_mt)
end

---Creates an admin command event.
-- @param string command Console command name
-- @param string arg1, arg2, arg3 Console arguments
-- @return RCRAdminCommandEvent instance
function RCRAdminCommandEvent.new(command, arg1, arg2, arg3)
    local self = RCRAdminCommandEvent.emptyNew()
    self.command = tostring(command or "")
    self.arg1 = arg1 ~= nil and tostring(arg1) or ""
    self.arg2 = arg2 ~= nil and tostring(arg2) or ""
    self.arg3 = arg3 ~= nil and tostring(arg3) or ""
    return self
end

---Reads the command from the stream and runs it server-side.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRAdminCommandEvent:readStream(streamId, connection)
    self.command = streamReadString(streamId)
    self.arg1 = streamReadString(streamId)
    self.arg2 = streamReadString(streamId)
    self.arg3 = streamReadString(streamId)

    self:run(connection)
end

---Writes the command to the stream.
-- @param integer streamId Network stream identifier
function RCRAdminCommandEvent:writeStream(streamId)
    streamWriteString(streamId, tostring(self.command or ""))
    streamWriteString(streamId, tostring(self.arg1 or ""))
    streamWriteString(streamId, tostring(self.arg2 or ""))
    streamWriteString(streamId, tostring(self.arg3 or ""))
end

---True when the connection belongs to a master user.
-- @param Connection connection
-- @return boolean isMasterUser
local function isMasterUserConnection(connection)
    if connection == nil or g_currentMission == nil then return false end
    local userManager = g_currentMission.userManager
    if userManager == nil or type(userManager.getUserIdByConnection) ~= "function" then return false end

    local userId = userManager:getUserIdByConnection(connection)
    if userId == nil then return false end
    if type(userManager.getUserByUserId) ~= "function" then return false end

    local user = userManager:getUserByUserId(userId)
    return user ~= nil and user.isMasterUser == true
end

---Runs the relayed command after checking admin rights (server only).
-- @param Connection connection Requesting client connection
function RCRAdminCommandEvent:run(connection)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end

    local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
    local handler = HANDLERS[self.command]
    if disease == nil or handler == nil then
        Logging.warning("[RealisticCropRotation][MP] Admin command ignored: %s", tostring(self.command))
        return
    end

    if not isMasterUserConnection(connection) then
        Logging.warning("[RealisticCropRotation][MP] Admin command rejected (not a master user): %s",
            tostring(self.command))
        return
    end

    local ok, result = pcall(handler, disease,
        self.arg1 ~= "" and self.arg1 or nil,
        self.arg2 ~= "" and self.arg2 or nil,
        self.arg3 ~= "" and self.arg3 or nil)
    Logging.info("[RealisticCropRotation][MP] Admin command %s: %s", tostring(self.command), tostring(result))
    if not ok then
        Logging.warning("[RealisticCropRotation][MP] Admin command failed: %s", tostring(result))
    end
end

---Sends a console command to the server from a client.
-- @param string command Console command name
-- @param string arg1, arg2, arg3 Console arguments
-- @return string message Console feedback
function RCRAdminCommandEvent.request(command, arg1, arg2, arg3)
    if HANDLERS[command] == nil then return "Unknown admin command" end
    if g_currentMission ~= nil and g_currentMission.isMasterUser == false then
        return "Admin rights required: log in as admin on the server first"
    end
    if g_client == nil or type(g_client.getServerConnection) ~= "function" then
        return "No server connection"
    end

    local connection = g_client:getServerConnection()
    if connection == nil then return "No server connection" end

    connection:sendEvent(RCRAdminCommandEvent.new(command, arg1, arg2, arg3))
    return string.format("%s sent to the server; run rcrDisease to read the result", command)
end
