-- Copyright © 2026 Squallqt. All rights reserved.
-- Client->server rotation plan update. Server remains authoritative for saved plans.
FRPlanUpdateEvent = {}
local FRPlanUpdateEvent_mt = Class(FRPlanUpdateEvent, Event)

InitEventClass(FRPlanUpdateEvent, "FRPlanUpdateEvent")

function FRPlanUpdateEvent.emptyNew()
    local self = Event.new(FRPlanUpdateEvent_mt)
    return self
end

function FRPlanUpdateEvent.new(farmlandId, yearIdx, cropName)
    local self = FRPlanUpdateEvent.emptyNew()
    self.farmlandId = tonumber(farmlandId) or 0
    self.yearIdx = tonumber(yearIdx) or 0
    self.cropName = tostring(cropName or "")
    return self
end

function FRPlanUpdateEvent:readStream(streamId, connection)
    self.farmlandId = streamReadInt32(streamId)
    self.yearIdx = streamReadInt8(streamId)
    self.cropName = streamReadString(streamId)

    self:run(connection)
end

function FRPlanUpdateEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, tonumber(self.farmlandId) or 0)
    streamWriteInt8(streamId, tonumber(self.yearIdx) or 0)
    streamWriteString(streamId, tostring(self.cropName or ""))
end

function FRPlanUpdateEvent:run(connection)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end

    local manager = g_currentMission.fieldRotationManager
    if manager == nil or manager.setRotationPlanYear == nil then
        Logging.warning("[FieldRotation][MP] Plan update ignored: manager unavailable")
        return
    end

    -- P0-4 auth: resolve the requesting client's farm via the userManager and
    -- reject the event unless that farm owns the target farmland. Pattern from
    -- gameSource/objects/WashingStationEvent.lua run().
    local userFarmId = nil
    if connection ~= nil and g_currentMission.userManager ~= nil
        and g_currentMission.userManager.getUserIdByConnection ~= nil then
        local userId = g_currentMission.userManager:getUserIdByConnection(connection)
        if userId ~= nil and g_farmManager ~= nil and g_farmManager.getFarmByUserId ~= nil then
            local farm = g_farmManager:getFarmByUserId(userId)
            if farm ~= nil then
                userFarmId = farm.farmId
            end
        end
    end

    local farmlandOwnerId = nil
    if g_farmlandManager ~= nil and g_farmlandManager.getFarmlandOwner ~= nil then
        farmlandOwnerId = g_farmlandManager:getFarmlandOwner(self.farmlandId)
    end

    if userFarmId == nil or farmlandOwnerId == nil or userFarmId ~= farmlandOwnerId then
        Logging.warning("[FieldRotation][MP] Plan update rejected (auth): farmland=%s requesterFarm=%s ownerFarm=%s",
            tostring(self.farmlandId), tostring(userFarmId), tostring(farmlandOwnerId))
        return
    end

    -- P0-4 validation: cropName must be either empty (clear-slot) or a known fruit type.
    if self.cropName ~= nil and self.cropName ~= "" then
        local fruitType = g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil
            and g_fruitTypeManager:getFruitTypeByName(self.cropName)
            or nil
        if fruitType == nil then
            Logging.warning("[FieldRotation][MP] Plan update rejected (unknown crop): farmland=%s crop=%s",
                tostring(self.farmlandId), tostring(self.cropName))
            return
        end
    end

    local changed = manager:setRotationPlanYear(self.farmlandId, self.yearIdx, self.cropName)
    if not changed then
        Logging.warning("[FieldRotation][MP] Plan update ignored: invalid payload farmland=%s year=%s crop=%s",
            tostring(self.farmlandId), tostring(self.yearIdx), tostring(self.cropName))
        return
    end

    Logging.info("[FieldRotation][MP] Plan update applied farmland=%s year=%s crop=%s",
        tostring(self.farmlandId), tostring(self.yearIdx), tostring(self.cropName))

    if FieldRotation ~= nil and FieldRotation.requestBroadcast ~= nil then
        FieldRotation.requestBroadcast()
    end
end
