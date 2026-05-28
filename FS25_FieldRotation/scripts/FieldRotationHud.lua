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

-- Adds the current growth tier line (e.g. "Growing"). data is the
-- engine-populated FieldState handed to PlayerHUDUpdater.fieldAddFarmland, so
-- lastFruitTypeIndex / lastGrowthState are valid on MP clients without any
-- extra sampling. The tier classification lives on FieldRotationManager so
-- the card and the HUD agree on the wording.
function FieldRotationHud.addGrowthStageLine(fieldBox, data)
    if fieldBox == nil or fieldBox.addLine == nil then return end
    if data == nil or g_fruitTypeManager == nil then return end
    if FieldRotationManager == nil or FieldRotationManager.classifyGrowthStage == nil then return end

    local fruitTypeIndex = tonumber(data.lastFruitTypeIndex)
    local unknownFruitType = (FruitType ~= nil and FruitType.UNKNOWN) or 0
    if fruitTypeIndex == nil or fruitTypeIndex == unknownFruitType then return end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType == nil then return end

    local stageKey = FieldRotationManager.classifyGrowthStage(fruitType, data.lastGrowthState)
    if stageKey == nil then return end

    local label = FieldRotationHud.getText("fr_hud_growth_stage")
    fieldBox:addLine(label, FieldRotationHud.getText(stageKey))
end

function FieldRotationHud.fieldAddFarmland(self, data, fieldBox)
    local farmlandId = data ~= nil and data.farmlandId or nil
    FieldRotationHud.addGrowthStageLine(fieldBox, data)
    FieldRotationHud.addHistoryLines(fieldBox, farmlandId)
    FieldRotationHud.addCatchCropLine(fieldBox, data)
end

if PlayerHUDUpdater ~= nil and PlayerHUDUpdater.fieldAddFarmland ~= nil
    and Utils ~= nil and Utils.appendedFunction ~= nil then
    PlayerHUDUpdater.fieldAddFarmland = Utils.appendedFunction(PlayerHUDUpdater.fieldAddFarmland, FieldRotationHud.fieldAddFarmland)
end
