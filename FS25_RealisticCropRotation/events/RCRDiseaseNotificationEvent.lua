-- Copyright © 2026 Squallqt. All rights reserved.
-- Server notification for a new disease, displayed only to players in the farmland owner's farm.
RCRDiseaseNotificationEvent = {}
local RCRDiseaseNotificationEvent_mt = Class(RCRDiseaseNotificationEvent, Event)

InitEventClass(RCRDiseaseNotificationEvent, "RCRDiseaseNotificationEvent")

function RCRDiseaseNotificationEvent.emptyNew()
    return Event.new(RCRDiseaseNotificationEvent_mt)
end

function RCRDiseaseNotificationEvent.new(farmId, farmlandId, group)
    local self = RCRDiseaseNotificationEvent.emptyNew()
    self.farmId = tonumber(farmId) or 0
    self.farmlandId = tonumber(farmlandId) or 0
    self.group = tostring(group or "")
    return self
end

function RCRDiseaseNotificationEvent:readStream(streamId, connection)
    if not connection:getIsServer() then return end

    self.farmId = streamReadInt32(streamId)
    self.farmlandId = streamReadInt32(streamId)
    self.group = streamReadString(streamId)
    self:run(connection)
end

function RCRDiseaseNotificationEvent:writeStream(streamId, _connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.farmlandId)
    streamWriteString(streamId, self.group)
end

function RCRDiseaseNotificationEvent:run(_connection)
    if g_currentMission == nil or type(g_currentMission.getFarmId) ~= "function"
        or g_currentMission:getFarmId() ~= self.farmId
        or type(g_currentMission.addIngameNotification) ~= "function"
        or FSBaseMission == nil or g_i18n == nil then
        return
    end

    local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
    local diseaseName = disease ~= nil and disease:getDisplayName(self.group) or self.group
    -- Player-facing field label.
    local manager = RealisticCropRotation ~= nil and RealisticCropRotation.manager or nil
    local fieldLabel = manager ~= nil
        and manager:getFarmlandLabel(self.farmlandId) or tostring(self.farmlandId)
    local text = string.format(
        g_i18n:getText("rcr_disease_notification"), diseaseName, fieldLabel)
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text)
end

function RCRDiseaseNotificationEvent.sendEvent(farmlandId, group)
    if g_server == nil or g_farmlandManager == nil
        or type(g_farmlandManager.getFarmlandOwner) ~= "function" then return end
    local farmId = tonumber(g_farmlandManager:getFarmlandOwner(farmlandId))
    if farmId == nil or farmId <= 0 then return end

    local event = RCRDiseaseNotificationEvent.new(farmId, farmlandId, group)
    g_server:broadcastEvent(event, false)
    if g_client ~= nil then event:run(nil) end
end
