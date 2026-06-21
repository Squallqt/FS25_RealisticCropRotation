-- Copyright © 2026 Squallqt. All rights reserved.
-- Client->server rotation plan update. Server remains authoritative for saved plans.
RCRPlanUpdateEvent = {}
local RCRPlanUpdateEvent_mt = Class(RCRPlanUpdateEvent, Event)

InitEventClass(RCRPlanUpdateEvent, "RCRPlanUpdateEvent")

local VALID_COVER_CROPS = {
    OILSEEDRADISH = true,
    FLOWERINGCATCHCROP = true,
}

---Creates an empty event instance for deserialization.
-- @return RCRPlanUpdateEvent instance Empty event
function RCRPlanUpdateEvent.emptyNew()
    local self = Event.new(RCRPlanUpdateEvent_mt)
    return self
end

---Creates a plan-update event.
-- @param integer farmlandId Target farmland id
-- @param integer yearIdx Rotation year slot (1-4)
-- @param string cropName Crop name, or "" to clear the slot
-- @param boolean isCover True for the cover plan, false for the main plan
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
        Logging.warning("[RealisticCropRotation][MP] Plan update rejected (auth): farmland=%s requesterFarm=%s ownerFarm=%s",
            tostring(self.farmlandId), tostring(userFarmId), tostring(farmlandOwnerId))
        return
    end

    -- cropName must be empty, a known fruit type, or the internal fallow token.
    if self.cropName ~= nil and self.cropName ~= "" then
        local isFallowCrop = RealisticCropRotation ~= nil
            and type(RealisticCropRotation.isFallowCrop) == "function"
            and RealisticCropRotation.isFallowCrop(self.cropName)

        if isFallowCrop then
            if isCoverUpdate then
                Logging.warning("[RealisticCropRotation][MP] Cover plan update rejected (invalid cover): farmland=%s crop=%s",
                    tostring(self.farmlandId), tostring(self.cropName))
                return
            end
        else
            local fruitType = g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil
                and g_fruitTypeManager:getFruitTypeByName(self.cropName)
                or nil
            if fruitType == nil then
                Logging.warning("[RealisticCropRotation][MP] Plan update rejected (unknown crop): farmland=%s crop=%s",
                    tostring(self.farmlandId), tostring(self.cropName))
                return
            end

            local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
            local family = config ~= nil and config.families ~= nil and config.families[self.cropName] or nil
            if isCoverUpdate then
                if not VALID_COVER_CROPS[self.cropName] or family ~= "COVER" then
                    Logging.warning("[RealisticCropRotation][MP] Cover plan update rejected (invalid cover): farmland=%s crop=%s",
                        tostring(self.farmlandId), tostring(self.cropName))
                    return
                end
            elseif family == "COVER" or VALID_COVER_CROPS[self.cropName] then
                Logging.warning("[RealisticCropRotation][MP] Main plan update rejected (cover in main plan): farmland=%s crop=%s",
                    tostring(self.farmlandId), tostring(self.cropName))
                return
            end
        end
    end

    local changed = false
    if isCoverUpdate then
        changed = manager:setRotationCoverPlanYear(self.farmlandId, self.yearIdx, self.cropName)
    else
        changed = manager:setRotationPlanYear(self.farmlandId, self.yearIdx, self.cropName)
    end
    if not changed then
        Logging.warning("[RealisticCropRotation][MP] Plan update ignored: invalid payload farmland=%s year=%s crop=%s cover=%s",
            tostring(self.farmlandId), tostring(self.yearIdx), tostring(self.cropName), tostring(isCoverUpdate))
        return
    end

    if RealisticCropRotation ~= nil and RealisticCropRotation.requestBroadcast ~= nil then
        RealisticCropRotation.requestBroadcast()
    end
end
