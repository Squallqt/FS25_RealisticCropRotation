-- Copyright © 2026 Squallqt. All rights reserved.

RealisticCropRotationHud = {}

RealisticCropRotationHud.HISTORY_LABEL_KEYS = {
    "rcr_hud_previous_n1",
    "rcr_hud_previous_n2",
}


---Returns the localized display title for a fruit type.
-- @param table fruitType
-- @return string title
function RealisticCropRotationHud.getFruitTypeDisplayName(fruitType)
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

---i18n lookup with a fallback when the key is missing.
-- @param string key
-- @param string fallback
-- @return string text
function RealisticCropRotationHud.getText(key, fallback)
    if g_i18n ~= nil and g_i18n.getText ~= nil then
        local text = g_i18n:getText(key)
        if text ~= nil and text ~= "" and text ~= key then
            return text
        end
    end

    return fallback or key
end

---Returns the localized display name for a crop name.
-- @param string cropName
-- @return string displayName
function RealisticCropRotationHud.getCropDisplayName(cropName)
    if cropName == nil or cropName == "" then
        return ""
    end

    local normalizedName = string.upper(tostring(cropName))

    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil then
        local fruitType = g_fruitTypeManager:getFruitTypeByName(normalizedName)
        if fruitType ~= nil then
            local fruitTitle = RealisticCropRotationHud.getFruitTypeDisplayName(fruitType)
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

---Appends the rotation history rows (N-1..N-4) to a field-info box.
-- @param table fieldBox Field-info box with addLine
-- @param integer farmlandId
function RealisticCropRotationHud.addHistoryLines(fieldBox, farmlandId)
    if fieldBox == nil or fieldBox.addLine == nil then
        return
    end

    local manager = g_currentMission ~= nil and g_currentMission.realisticCropRotationManager or nil
    if manager == nil or manager.getHistory == nil then
        return
    end

    farmlandId = tonumber(farmlandId)
    if farmlandId == nil or farmlandId == 0 then
        return
    end

    local history = manager:getHistory(farmlandId) or {}
    for index, key in ipairs(RealisticCropRotationHud.HISTORY_LABEL_KEYS) do
        local entry = history[index]
        local cropName = entry ~= nil and entry.crop or nil
        if cropName ~= nil and cropName ~= "" then
            local label = RealisticCropRotationHud.getText(key)
            local value = RealisticCropRotationHud.getCropDisplayName(cropName)
            if value ~= "" then
                fieldBox:addLine(label, value)
            end
        end
    end

    RealisticCropRotationHud.addDiseaseLine(fieldBox, farmlandId)
end

---World position -> a grid's local cell coordinates. Same formula the native FarmlandManager uses for
---its own local map (FarmlandManager:convertWorldToLocalPosition): floor(mapSize * (world + terrainSize
---/ 2) / terrainSize). Trivial, no loop.
-- @param number worldX, worldZ; @param integer mapSize
-- @return integer localX, localZ, or nil when unavailable
local function worldToGridCell(worldX, worldZ, mapSize)
    if g_currentMission == nil or g_currentMission.terrainSize == nil or mapSize == nil then return nil end
    local terrainSize = g_currentMission.terrainSize
    return math.floor(mapSize * (worldX + terrainSize * 0.5) / terrainSize),
        math.floor(mapSize * (worldZ + terrainSize * 0.5) / terrainSize)
end

---True when the given world position is marked protected in the given per-cell map: one native point
---read (getBitVectorMapPoint), no loop.
local function isPointProtected(protectionMapId, mapSize, worldX, worldZ)
    if protectionMapId == nil or getBitVectorMapPoint == nil or worldX == nil then return false end
    local localX, localZ = worldToGridCell(worldX, worldZ, mapSize)
    if localX == nil then return false end
    return (getBitVectorMapPoint(protectionMapId, localX, localZ, 0, 1) or 0) > 0
end

---Appends a disease status line to the field-info box when an infection is active AND the player is
---NOT standing on a cell already sprayed for that group's treatment family. Curative/preventive
---spraying excludes cells from destruction one cell at a time (RealisticCropRotationDiseaseGrid:
---paintProtection), so the farmland-level severity alone can no longer tell "active" apart from
---"already treated here" -- checking the player's own position against the SAME per-cell protection map
---the destroy pass reads is what makes the two agree.
-- @param table fieldBox Field-info box with addLine
-- @param integer farmlandId
function RealisticCropRotationHud.addDiseaseLine(fieldBox, farmlandId)
    if fieldBox == nil or fieldBox.addLine == nil then return end

    local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
    if disease == nil or type(disease.getState) ~= "function" then return end

    local groups = disease:getState(farmlandId)
    if groups == nil then return end

    local grid = RealisticCropRotation ~= nil and RealisticCropRotation.grid or nil
    local px, pz = nil, nil
    if g_localPlayer ~= nil and g_localPlayer.rootNode ~= nil and getWorldTranslation ~= nil then
        px, _, pz = getWorldTranslation(g_localPlayer.rootNode)
    end

    local label = RealisticCropRotationHud.getText("rcr_disease_hud_label", "Disease")
    for group, s in pairs(groups) do
        if (s.severity or 0) > 0 then
            local protectedHere = false
            if grid ~= nil and px ~= nil and type(disease.getTreatment) == "function" then
                local treatment = disease:getTreatment(group)
                local protectionMapId = nil
                if treatment == "FUNGICIDE" then protectionMapId = grid.fungicideProtectionMapId
                elseif treatment == "NEMATICIDE" then protectionMapId = grid.nematicideProtectionMapId end
                protectedHere = isPointProtected(protectionMapId, grid.size, px, pz)
            end

            if not protectedHere then
                local diseaseName = (type(disease.getDisplayName) == "function") and disease:getDisplayName(group) or tostring(group)
                local value = string.format(RealisticCropRotationHud.getText("rcr_disease_hud_active", "%s (active)"), diseaseName)
                fieldBox:addLine(label, value, true)
                return
            end
        end
    end
end
---Resolves the (tierText, numbers) override for the on-foot "Croissance:" line.
-- @param table data Field-info data
-- @return string tierText Tier label, or nil
-- @return string numbers "X/Y" progress, or nil
local function resolveGrowthOverride(data)
    if data == nil or g_fruitTypeManager == nil then return nil, nil end
    if RealisticCropRotationManager == nil then return nil, nil end

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

    local numbers = RealisticCropRotationManager.getGrowthStageNumbers(fruitType, growthState)
    if numbers == nil then return nil, nil end

    local tierText = RealisticCropRotationManager.getGrowthTierText(fruitType, growthState)
    if tierText == nil then return nil, nil end

    return tierText, numbers
end

---Overwrite of PlayerHUDUpdater.fieldAddField: injects the numeric growth into the growth row.
-- @param table hudSelf PlayerHUDUpdater instance
-- @param function superFunc Original function
-- @param table data Field-info data
-- @param table fieldBox Field-info box
function RealisticCropRotationHud.fieldAddField(hudSelf, superFunc, data, fieldBox, ...)
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

---Overwrite of PlayerHUDUpdater.fieldAddFarmland: appends our rotation history rows.
-- @param table hudSelf PlayerHUDUpdater instance
-- @param function superFunc Original function
-- @param table data Field-info data
-- @param table fieldBox Field-info box
function RealisticCropRotationHud.fieldAddFarmland(hudSelf, superFunc, data, fieldBox)
    RealisticCropRotationHud.hudInstance = hudSelf
    local farmlandId = data ~= nil and data.farmlandId or nil

    superFunc(hudSelf, data, fieldBox)

    RealisticCropRotationHud.addHistoryLines(fieldBox, farmlandId)
end

if PlayerHUDUpdater ~= nil and Utils ~= nil and Utils.overwrittenFunction ~= nil then
    if PlayerHUDUpdater.fieldAddField ~= nil then
        PlayerHUDUpdater.fieldAddField = Utils.overwrittenFunction(PlayerHUDUpdater.fieldAddField, RealisticCropRotationHud.fieldAddField)
    end

    if PlayerHUDUpdater.fieldAddFarmland ~= nil then
        PlayerHUDUpdater.fieldAddFarmland = Utils.overwrittenFunction(PlayerHUDUpdater.fieldAddFarmland, RealisticCropRotationHud.fieldAddFarmland)
    end
end

-- Mirror of the base-game weed row: call the real (stripped) fieldAddWeed with a
-- capture box, read back the exact (label, value). nil when no weed line applies.
RealisticCropRotationHud.hudInstance = nil

---Mirrors the base-game weed row via the real fieldAddWeed + a capture box.
-- @param table data Field-info data (weedState, fruitTypeIndex, growthState, farmlandId)
-- @return string label Weed stage label, or nil
-- @return string value Tool recommendation, or nil
function RealisticCropRotationHud.getWeedLineFromGame(data)
    if data == nil or PlayerHUDUpdater == nil or PlayerHUDUpdater.fieldAddWeed == nil then
        return nil
    end

    -- Canonical instance is the local player's HUD updater (Player.lua:363);
    -- fall back to the instance seen by our live HUD hooks.
    local hudUpdater = (g_localPlayer ~= nil and g_localPlayer.hudUpdater)
        or RealisticCropRotationHud.hudInstance
    if hudUpdater == nil then
        return nil
    end

    local capturedLabel, capturedValue
    local captureBox = setmetatable({
        addLine = function(_, label, value)
            capturedLabel, capturedValue = label, value
        end,
    }, { __index = function() return function() end end })

    local ok = pcall(PlayerHUDUpdater.fieldAddWeed, hudUpdater, data, captureBox)
    if not ok then
        return nil
    end

    return capturedLabel, capturedValue
end
