-- Copyright © 2026 Squallqt. All rights reserved.
-- Client->server rotation plan update. Server remains authoritative for saved plans.
RCRPlanUpdateEvent = {}
local RCRPlanUpdateEvent_mt = Class(RCRPlanUpdateEvent, Event)

InitEventClass(RCRPlanUpdateEvent, "RCRPlanUpdateEvent")

local function rejectPlanUpdate(connection, message, ...)
    Logging.warning(message, ...)
    if connection ~= nil then
        connection:sendEvent(RCRHistoryResponseEvent.new())
    end
end

---Creates an empty event instance for deserialization.
-- @return RCRPlanUpdateEvent instance Empty event
function RCRPlanUpdateEvent.emptyNew()
    local self = Event.new(RCRPlanUpdateEvent_mt)
    return self
end

---Creates a plan-update event.
-- @param integer farmlandId Target farmland
-- @param integer yearIdx Year slot (1-4)
-- @param string cropName Crop name ("" to clear)
-- @param boolean isCover Cover-plan flag
-- @return RCRPlanUpdateEvent instance The new event instance
function RCRPlanUpdateEvent.new(farmlandId, yearIdx, cropName, isCover)
    local self = RCRPlanUpdateEvent.emptyNew()
    self.farmlandId = tonumber(farmlandId) or 0
    self.yearIdx = tonumber(yearIdx) or 0
    self.cropName = tostring(cropName or "")
    self.isCover = isCover == true
    return self
end

---Reads the plan update from the stream and applies it server-side.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRPlanUpdateEvent:readStream(streamId, connection)
    self.farmlandId = streamReadInt32(streamId)
    self.yearIdx = streamReadInt8(streamId)
    self.cropName = streamReadString(streamId)
    self.isCover = streamReadInt8(streamId) == 1

    self:run(connection)
end

---Writes the plan update to the stream.
-- @param integer streamId Network stream identifier
-- @param Connection connection Network connection
function RCRPlanUpdateEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, tonumber(self.farmlandId) or 0)
    streamWriteInt8(streamId, tonumber(self.yearIdx) or 0)
    streamWriteString(streamId, tostring(self.cropName or ""))
    streamWriteInt8(streamId, self.isCover and 1 or 0)
end

---Validates ownership + crop, then applies the plan update (server-authoritative).
-- @param Connection connection Requesting client connection
function RCRPlanUpdateEvent:run(connection)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end

    local manager = g_currentMission.realisticCropRotationManager
    local isCoverUpdate = self.isCover == true
    if manager == nil
        or (not isCoverUpdate and manager.setRotationPlanYear == nil)
        or (isCoverUpdate and manager.setRotationCoverPlanYear == nil) then
        Logging.warning("[RealisticCropRotation][MP] Plan update ignored: manager unavailable")
        return
    end

    self.cropName = string.upper(tostring(self.cropName or ""))

    -- Auth: reject unless the requesting client's farm owns the target farmland.
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
        return rejectPlanUpdate(connection,
            "[RealisticCropRotation][MP] Plan update rejected (auth): farmland=%s requesterFarm=%s ownerFarm=%s",
            tostring(self.farmlandId), tostring(userFarmId), tostring(farmlandOwnerId))
    end

    -- cropName must be empty, fallow, or a registered fruit with a configured rotation family.
    if self.cropName ~= "" then
        local isFallowCrop = RealisticCropRotation.isFallowCrop(self.cropName)

        if isFallowCrop then
            if isCoverUpdate then
                return rejectPlanUpdate(connection,
                    "[RealisticCropRotation][MP] Cover plan update rejected (invalid cover): farmland=%s crop=%s",
                    tostring(self.farmlandId), tostring(self.cropName))
            end
        else
            local fruitType = g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil
                and g_fruitTypeManager:getFruitTypeByName(self.cropName)
                or nil
            if fruitType == nil then
                return rejectPlanUpdate(connection,
                    "[RealisticCropRotation][MP] Plan update rejected (unknown crop): farmland=%s crop=%s",
                    tostring(self.farmlandId), tostring(self.cropName))
            end

            local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
            local family = config ~= nil and config.families ~= nil and config.families[self.cropName] or nil
            local isConfiguredCover = config ~= nil and config.coverCrops ~= nil
                and config.coverCrops[self.cropName] == true
            if isCoverUpdate then
                if not isConfiguredCover or family ~= "COVER" then
                    return rejectPlanUpdate(connection,
                        "[RealisticCropRotation][MP] Cover plan update rejected (invalid cover): farmland=%s crop=%s",
                        tostring(self.farmlandId), tostring(self.cropName))
                end
            elseif family == nil then
                return rejectPlanUpdate(connection,
                    "[RealisticCropRotation][MP] Main plan update rejected (unconfigured crop): farmland=%s crop=%s",
                    tostring(self.farmlandId), tostring(self.cropName))
            elseif family == "COVER" or isConfiguredCover then
                return rejectPlanUpdate(connection,
                    "[RealisticCropRotation][MP] Main plan update rejected (cover in main plan): farmland=%s crop=%s",
                    tostring(self.farmlandId), tostring(self.cropName))
            end
        end
    end

    local changed, valid
    if isCoverUpdate then
        changed, valid = manager:setRotationCoverPlanYear(self.farmlandId, self.yearIdx, self.cropName)
    else
        changed, valid = manager:setRotationPlanYear(self.farmlandId, self.yearIdx, self.cropName)
    end
    if not valid then
        return rejectPlanUpdate(connection,
            "[RealisticCropRotation][MP] Plan update ignored: invalid payload farmland=%s year=%s crop=%s cover=%s",
            tostring(self.farmlandId), tostring(self.yearIdx), tostring(self.cropName), tostring(isCoverUpdate))
    end

    if changed and RealisticCropRotation ~= nil and RealisticCropRotation.requestBroadcast ~= nil then
        RealisticCropRotation.requestBroadcast()
    end
end
