-- Copyright © 2026 Squallqt. All rights reserved.

FieldRotationHud = {}

FieldRotationHud.HISTORY_LABEL_KEYS = {
    "fr_hud_previous_n1",
    "fr_hud_previous_n2",
}


function FieldRotationHud.getFruitTypeDisplayName(fruitType)
    if fruitType == nil then
        return ""
    end

    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFillTypeByFruitTypeIndex ~= nil
        and fruitType.index ~= nil then
        local fillType = g_fruitTypeManager:getFillTypeByFruitTypeIndex(fruitType.index)
        if fillType ~= nil and fillType.title ~= nil and fillType.title ~= "" then
            return fillType.title
        end
    end

    if fruitType.fillType ~= nil and fruitType.fillType.title ~= nil
        and fruitType.fillType.title ~= "" then
        return fruitType.fillType.title
    end

    return ""
end

function FieldRotationHud.getText(key, fallback)
    if g_i18n ~= nil and g_i18n.getText ~= nil then
        local text = g_i18n:getText(key)
        if text ~= nil and text ~= "" and text ~= key then
            return text
        end
    end

    return fallback or key
end

function FieldRotationHud.getCropDisplayName(cropName)
    if cropName == nil or cropName == "" then
        return ""
    end

    local normalizedName = string.upper(tostring(cropName))

    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil then
        local fruitType = g_fruitTypeManager:getFruitTypeByName(normalizedName)
        if fruitType ~= nil then
            local fruitTitle = FieldRotationHud.getFruitTypeDisplayName(fruitType)
            if fruitTitle ~= "" then
                return fruitTitle
            end
        end
    end

    if g_fillTypeManager ~= nil and g_fillTypeManager.getFillTypeByName ~= nil then
        local fillType = g_fillTypeManager:getFillTypeByName(normalizedName)
        if fillType ~= nil and fillType.title ~= nil and fillType.title ~= "" then
            return fillType.title
        end
    end

    return normalizedName:sub(1, 1) .. string.lower(normalizedName:sub(2))
end

function FieldRotationHud.getActiveFruitType(data)
    local fruitTypeIndex = data ~= nil and data.lastFruitTypeIndex or nil
    local unknownFruitType = FruitType ~= nil and FruitType.UNKNOWN or 0
    if fruitTypeIndex == nil or fruitTypeIndex == unknownFruitType then
        return nil
    end

    if g_fruitTypeManager == nil or g_fruitTypeManager.getFruitTypeByIndex == nil then
        return nil
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then
        return nil
    end

    local growthState = data ~= nil and tonumber(data.lastGrowthState) or nil
    if growthState ~= nil then
        if fruitType.getIsCut ~= nil then
            local ok, isCut = pcall(fruitType.getIsCut, fruitType, growthState)
            if ok and isCut then
                return nil
            end
        end

        if fruitType.getIsWithered ~= nil then
            local ok, isWithered = pcall(fruitType.getIsWithered, fruitType, growthState)
            if ok and isWithered then
                return nil
            end
        end
    end

    return fruitType
end

function FieldRotationHud.addHistoryLines(fieldBox, farmlandId)
    if fieldBox == nil or fieldBox.addLine == nil then
        return
    end

    local manager = g_currentMission ~= nil and g_currentMission.fieldRotationManager or nil
    if manager == nil or manager.getHistory == nil then
        return
    end

    farmlandId = tonumber(farmlandId)
    if farmlandId == nil or farmlandId == 0 then
        return
    end

    local history = manager:getHistory(farmlandId) or {}
    for index, key in ipairs(FieldRotationHud.HISTORY_LABEL_KEYS) do
        local entry = history[index]
        local cropName = entry ~= nil and entry.crop or nil
        if cropName ~= nil and cropName ~= "" then
            local label = FieldRotationHud.getText(key)
            local value = FieldRotationHud.getCropDisplayName(cropName)
            if value ~= "" then
                fieldBox:addLine(label, value)
            end
        end
    end
end

function FieldRotationHud.addCatchCropLine(fieldBox, data)
    if fieldBox == nil or fieldBox.addLine == nil then return end

    local fruitType = FieldRotationHud.getActiveFruitType(data)
    if fruitType == nil then return end

    local fruitName = fruitType.name ~= nil and string.upper(tostring(fruitType.name)) or nil

    -- Check cover status: isCatchCrop (base game) or cover=true in cropConfig.xml
    local isCover = fruitType.isCatchCrop == true
    if not isCover and fruitName ~= nil then
        local config = FieldRotation ~= nil and FieldRotation.cropConfig or nil
        if config ~= nil and config.coverCrops ~= nil then
            isCover = config.coverCrops[fruitName] == true
        end
    end

    local label = FieldRotationHud.getText("fr_hud_cover_crop")
    local value = isCover
        and FieldRotationHud.getText("fr_hud_yes")
        or  FieldRotationHud.getText("fr_hud_no")

    fieldBox:addLine(label, value)
end

-- Computes the (tierText, numbers) pair used to override the base game's
-- pedestrian "Croissance:" line for the field hovered by the player. Returns
-- nil for both when the override does not apply (no fruit, terminal state,
-- no i18n). Resolving both here avoids paying the cost on every addLine call.
local function resolveGrowthOverride(data)
    if data == nil or g_fruitTypeManager == nil then return nil, nil end
    if FieldRotationManager == nil then return nil, nil end

    local unknownFruitType = (FruitType ~= nil and FruitType.UNKNOWN) or 0

    local fruitTypeIndex = tonumber(data.fruitTypeIndex)
    if fruitTypeIndex == nil or fruitTypeIndex == unknownFruitType then
        fruitTypeIndex = tonumber(data.lastFruitTypeIndex)
    end
    if fruitTypeIndex == nil or fruitTypeIndex == unknownFruitType then return nil, nil end

    local growthState = tonumber(data.growthState)
    if growthState == nil or growthState <= 0 then
        growthState = tonumber(data.lastGrowthState)
    end
    if growthState == nil or growthState <= 0 then return nil, nil end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then return nil, nil end

    local numbers = FieldRotationManager.getGrowthStageNumbers(fruitType, growthState)
    if numbers == nil then return nil, nil end

    local tierText = FieldRotationManager.getGrowthTierText(fruitType, growthState)
    if tierText == nil then return nil, nil end

    return tierText, numbers
end

function FieldRotationHud.fieldAddField(hudSelf, superFunc, data, fieldBox, ...)
    local hookData = data
    local hookFieldBox = fieldBox

    if (hookFieldBox == nil or hookFieldBox.addLine == nil)
            and data ~= nil and data.addLine ~= nil then
        hookFieldBox = data
        hookData = fieldBox
    end

    local tierText, numbers = resolveGrowthOverride(hookData)
    local originalAddLine = nil

    if tierText ~= nil and numbers ~= nil
            and hookFieldBox ~= nil and hookFieldBox.addLine ~= nil then
        originalAddLine = hookFieldBox.addLine
        hookFieldBox.addLine = function(boxSelf, label, value)
            if value == tierText then
                value = string.format("(%s) · %s", numbers, value)
            end
            return originalAddLine(boxSelf, label, value)
        end
    end

    superFunc(hudSelf, data, fieldBox, ...)

    if originalAddLine ~= nil then
        hookFieldBox.addLine = originalAddLine
    end
end

-- Extends PlayerHUDUpdater.fieldAddFarmland with FieldRotation-only complementary
-- rows. Growth replacement is handled exclusively in fieldAddField, which is
-- the runtime function that actually emits the base-game crop/growth rows.
-- Giants Utils.overwrittenFunction calling convention:
--   function(self, superFunc, ...originalArgs)
-- First arg = the object instance (self), second arg = original function.
function FieldRotationHud.fieldAddFarmland(hudSelf, superFunc, data, fieldBox)
    local farmlandId = data ~= nil and data.farmlandId or nil

    superFunc(hudSelf, data, fieldBox)

    FieldRotationHud.addHistoryLines(fieldBox, farmlandId)
    FieldRotationHud.addCatchCropLine(fieldBox, data)
end

if PlayerHUDUpdater ~= nil and Utils ~= nil and Utils.overwrittenFunction ~= nil then
    if PlayerHUDUpdater.fieldAddField ~= nil then
        PlayerHUDUpdater.fieldAddField = Utils.overwrittenFunction(PlayerHUDUpdater.fieldAddField, FieldRotationHud.fieldAddField)
    end

    if PlayerHUDUpdater.fieldAddFarmland ~= nil then
        PlayerHUDUpdater.fieldAddFarmland = Utils.overwrittenFunction(PlayerHUDUpdater.fieldAddFarmland, FieldRotationHud.fieldAddFarmland)
    end
end
