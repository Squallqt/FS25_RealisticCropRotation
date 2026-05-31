-- Copyright © 2026 Squallqt. All rights reserved.
RealisticCropRotationFrame = {}
local RealisticCropRotationFrame_mt = Class(RealisticCropRotationFrame, TabbedMenuFrameElement)

-- Internal tab indices
RealisticCropRotationFrame.TAB = { HISTORY = 1, PLANNING = 2 }

-- Crop family classification is driven by cropConfig.xml.
-- RealisticCropRotation.cropConfig is loaded once at mod init by main.lua.

-- Advice follows the current timeline card.
-- COVER does not drive a recommendation because it is not a main crop.
RealisticCropRotationFrame.ADVICE_KEY = {
    CEREAL    = "rcr_advice_afterCereal",
    LEGUME    = "rcr_advice_afterLegume",
    OILSEED   = "rcr_advice_afterOilseed",
    ROOT      = "rcr_advice_afterRoot",
    VEGETABLE = "rcr_advice_afterVegetable",
    FORAGE    = "rcr_advice_afterForage",
}

-- Family badge RGBA — Lua-only (XML constraint does not apply)
RealisticCropRotationFrame.FAMILY_RGBA = {
    CEREAL    = {0.761, 0.365, 0.000, 1.0},  -- amber
    LEGUME    = {0.325, 0.565, 0.071, 1.0},  -- green
    OILSEED   = {0.800, 0.700, 0.000, 1.0},  -- golden yellow
    ROOT      = {0.600, 0.180, 0.100, 1.0},  -- dark red
    VEGETABLE = {0.180, 0.580, 0.380, 1.0},  -- teal green
    FORAGE    = {0.200, 0.480, 0.280, 1.0},  -- grass green
    COVER     = {0.420, 0.300, 0.100, 1.0},  -- earthy brown
}

-- slot index 1..4 maps to history newest-first (history[1] = N-1)
RealisticCropRotationFrame.SLOT_HISTORY_IDX = { 4, 3, 2, 1 }

-- Vanilla spray state labels
RealisticCropRotationFrame.SPRAY_LABEL_KEY = {
    [0] = "rcr_n_none", [1] = "rcr_n_partial", [2] = "rcr_n_full",
}

-- Max pixel widths (must match profile sizes)
RealisticCropRotationFrame.N_BAR_MAX_WIDTH     = 1192
RealisticCropRotationFrame.N_BAR_HEIGHT        = 14
RealisticCropRotationFrame.SCORE_BAR_MAX_WIDTH = 280

-- Global overview crop badge layout (pixel values, converted at runtime)
-- Goal: center the whole pair [crop icon + 5px gap + crop text] inside each crop badge.
RealisticCropRotationFrame.GROUP_BADGE_Y          = 18
RealisticCropRotationFrame.GROUP_BADGE_W          = 170
RealisticCropRotationFrame.GROUP_BADGE_H          = 30
RealisticCropRotationFrame.GROUP_ICON_W           = 20
RealisticCropRotationFrame.GROUP_ICON_H           = 20
RealisticCropRotationFrame.GROUP_ICON_TEXT_GAP    = 5
RealisticCropRotationFrame.GROUP_BADGE_PADDING_X  = 20

-- Season name l10n keys indexed by currentSeason (0-based)
RealisticCropRotationFrame.SEASON_KEY = {
    [0] = "rcr_season_spring", [1] = "rcr_season_summer",
    [2] = "rcr_season_autumn", [3] = "rcr_season_winter",
}

function RealisticCropRotationFrame.new(i18n, messageCenter)
    local self = RealisticCropRotationFrame:superClass().new(nil, RealisticCropRotationFrame_mt)
    self.name          = "RealisticCropRotationFrame"
    self.i18n          = i18n or g_i18n
    self.messageCenter = messageCenter or g_messageCenter
    self.farmlandList  = {}
    self.selectedId    = nil
    self.planCropList  = {""}  -- index 1 = no crop; populated in initialize()
    self.rotationGroups = {}   -- rebuilt when plans change
    self.totalAreaHa   = 0
    self.isSubscribedToFarmlandChanges = false
    return self
end

function RealisticCropRotationFrame:copyAttributes(src)
    RealisticCropRotationFrame:superClass().copyAttributes(self, src)
    self.i18n          = src.i18n
    self.messageCenter = src.messageCenter
    self.totalAreaHa   = src.totalAreaHa or 0
    self.isSubscribedToFarmlandChanges = false
end

function RealisticCropRotationFrame:delete()
    self:unsubscribeFarmlandChanges()
    self.farmlandList = nil
    RealisticCropRotationFrame:superClass().delete(self)
end

function RealisticCropRotationFrame:onGuiSetupFinished()
    RealisticCropRotationFrame:superClass().onGuiSetupFinished(self)
    if self.listFields ~= nil then
        self.listFields:setDataSource(self)
        self.listFields:setDelegate(self)
    end
    if self.listPlanOverview ~= nil then
        self.listPlanOverview:setDataSource(self)
        self.listPlanOverview:setDelegate(self)
    end
    self:linkFocusNavigation()
end

function RealisticCropRotationFrame:initialize()
    RealisticCropRotationFrame:superClass().initialize(self)

    -- Setup sidebar view tab selector
    if self.viewSelector ~= nil then
        self.viewSelector:setTexts({
            self.i18n:getText("rcr_tab_history"),
            self.i18n:getText("rcr_tab_planning"),
        })
        self.viewSelector:setState(RealisticCropRotationFrame.TAB.HISTORY, false)

        if self.viewSelectorDotBox ~= nil then
            for i = 1, #self.viewSelectorDotBox.elements do
                local idx = i
                self.viewSelectorDotBox.elements[i].getIsSelected = function()
                    return self.viewSelector:getState() == idx
                end
            end
            self.viewSelectorDotBox:invalidateLayout()
        end
    end

end

-- onCreate: entry point per spec; actual population deferred to onFrameOpen
function RealisticCropRotationFrame:onCreate()
end

function RealisticCropRotationFrame:onFrameOpen()
    RealisticCropRotationFrame:superClass().onFrameOpen(self)
    self:subscribeFarmlandChanges()
    self:populateSidebar()
    if RealisticCropRotation ~= nil and RealisticCropRotation.requestServerSync ~= nil then
        RealisticCropRotation.requestServerSync("frameOpen")
    end
    self:updateContainerVisibility()
    self:linkFocusNavigation()
end

function RealisticCropRotationFrame:onFrameClose()
    self:unsubscribeFarmlandChanges()
    RealisticCropRotationFrame:superClass().onFrameClose(self)
end

function RealisticCropRotationFrame:getMenuButtonInfo()
    return {}
end

-- ===========================================================================
--  HELPERS
-- ===========================================================================

function RealisticCropRotationFrame:getCurrentFarmId()
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
        return g_localPlayer.farmId
    end
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        return g_currentMission:getFarmId()
    end
    return -1
end

function RealisticCropRotationFrame:getManager()
    if g_currentMission == nil then return nil end
    return g_currentMission.realisticCropRotationManager
end

function RealisticCropRotationFrame:checkBonus(farmlandId)
    return self:getActiveNitrogenResidueKgHa(farmlandId) ~= nil
end

---Returns the currently active rotation nitrogen residue in kg/ha for the selected farmland.
-- The service stores the residue as PF state changes; keep the conversion centralized
-- through RealisticCropRotationService:getNitrogenKgPerHaFromStateChange instead of duplicating
-- PF constants in the UI.
-- @param integer farmlandId Farmland identifier
-- @return number|nil residueKgHa Active residue in kg/ha, or nil when no residue exists
function RealisticCropRotationFrame:getActiveNitrogenResidueKgHa(farmlandId)
    local mgr = self:getManager()
    if mgr == nil or mgr.getPendingBonus == nil then
        return nil
    end

    local bonus = mgr:getPendingBonus(farmlandId)
    if bonus == nil then
        return nil
    end

    local totalStateChange = (tonumber(bonus.n1StateChange) or 0) + (tonumber(bonus.n2StateChange) or 0)
    if totalStateChange <= 0 then
        return nil
    end

    if mgr.service ~= nil and mgr.service.getNitrogenKgPerHaFromStateChange ~= nil then
        local ok, residueKgHa = pcall(
            mgr.service.getNitrogenKgPerHaFromStateChange,
            mgr.service,
            totalStateChange
        )

        if ok and type(residueKgHa) == "number" and residueKgHa > 0 then
            return residueKgHa
        end
    end

    return nil
end

function RealisticCropRotationFrame:getActiveNitrogenResidueText(farmlandId)
    local residueKgHa = self:getActiveNitrogenResidueKgHa(farmlandId)
    if residueKgHa == nil then
        return nil
    end

    return string.format(self.i18n:getText("rcr_status_current_residue"), math.floor(residueKgHa + 0.5))
end

function RealisticCropRotationFrame:updateResiduePill(pillBg, pillText, farmlandId)
    local residueText = self:getActiveNitrogenResidueText(farmlandId)
    local hasBonus = residueText ~= nil
    local text = hasBonus and residueText or self.i18n:getText("rcr_status_current_no_residue")
    if pillBg ~= nil then
        pillBg:applyProfile(hasBonus and "frStatusPillBgBonus" or "frStatusPillBg")
    end
    if pillText ~= nil then
        pillText:setText(text)
    end
    self:resizePillToText(pillBg, pillText, text)
end

function RealisticCropRotationFrame:getPlanNitrogenResidueKgHa(plan)
    local mgr = self:getManager()
    if mgr == nil or mgr.service == nil then return nil end

    local service = mgr.service
    if type(service.getResidueEntry) ~= "function"
        or type(service.getNitrogenKgPerHaFromStateChange) ~= "function" then
        return nil
    end

    local totalStateChange = 0
    for i = 1, 4 do
        local cropName = plan ~= nil and plan[i] or nil
        if cropName ~= nil and cropName ~= "" then
            local entry = service:getResidueEntry(string.upper(tostring(cropName)))
            if entry ~= nil then
                totalStateChange = totalStateChange + (tonumber(entry.n1) or 0) + (tonumber(entry.n2) or 0)
            end
        end
    end

    if totalStateChange <= 0 then return nil end

    local ok, residueKgHa = pcall(
        service.getNitrogenKgPerHaFromStateChange,
        service,
        totalStateChange
    )
    if ok and type(residueKgHa) == "number" and residueKgHa > 0 then
        return residueKgHa
    end
    return nil
end

function RealisticCropRotationFrame:getPlanNitrogenResidueText(plan)
    local residueKgHa = self:getPlanNitrogenResidueKgHa(plan)
    if residueKgHa == nil then return nil end
    return string.format(self.i18n:getText("rcr_status_planned_residue"), math.floor(residueKgHa + 0.5))
end

function RealisticCropRotationFrame:updatePlannedResiduePill(pillBg, pillText, plan)
    local residueText = self:getPlanNitrogenResidueText(plan)
    local hasBonus = residueText ~= nil
    local text = hasBonus and residueText or self.i18n:getText("rcr_status_planned_no_residue")
    if pillBg ~= nil then
        pillBg:applyProfile(hasBonus and "frStatusPillBgBonus" or "frStatusPillBg")
    end
    if pillText ~= nil then
        pillText:setText(text)
    end
    self:resizePillToText(pillBg, pillText, text)
end

function RealisticCropRotationFrame:getPlanSlotNitrogenResidueKgHa(plan, slotIdx)
    local mgr = self:getManager()
    if mgr == nil or mgr.service == nil then return nil end

    local service = mgr.service
    if type(service.getResidueEntry) ~= "function"
        or type(service.getNitrogenKgPerHaFromStateChange) ~= "function" then
        return nil
    end

    slotIdx = tonumber(slotIdx)
    if slotIdx == nil or slotIdx < 1 or slotIdx > 4 then return nil end

    local totalStateChange = 0
    local function addResidue(cropName, residueKey)
        if cropName == nil or cropName == "" then return end
        local entry = service:getResidueEntry(string.upper(tostring(cropName)))
        if entry ~= nil then
            totalStateChange = totalStateChange + (tonumber(entry[residueKey]) or 0)
        end
    end

    local n1SourceIdx = ((slotIdx - 2) % 4) + 1
    local n2SourceIdx = ((slotIdx - 3) % 4) + 1
    addResidue(plan ~= nil and plan[n1SourceIdx] or nil, "n1")
    addResidue(plan ~= nil and plan[n2SourceIdx] or nil, "n2")

    if totalStateChange <= 0 then return nil end

    local ok, residueKgHa = pcall(
        service.getNitrogenKgPerHaFromStateChange,
        service,
        totalStateChange
    )
    if ok and type(residueKgHa) == "number" and residueKgHa > 0 then
        return residueKgHa
    end
    return nil
end

function RealisticCropRotationFrame:updatePlanSlotYearLabel(slotIdx, plan)
    local yearEl = self.planSlotYear ~= nil and self.planSlotYear[slotIdx]
    if yearEl == nil then return end

    local baseText = self.i18n:getText("rcr_plan_year" .. tostring(slotIdx))
    local residueKgHa = self:getPlanSlotNitrogenResidueKgHa(plan, slotIdx)

    if residueKgHa ~= nil then
        if yearEl.applyProfile ~= nil then
            yearEl:applyProfile("frPlanSlotYearResidue")
        end
        yearEl:setText(string.format("%s  \xc2\xb7  +%d kg/ha", baseText, math.floor(residueKgHa + 0.5)))
    else
        if yearEl.applyProfile ~= nil then
            yearEl:applyProfile("frPlanSlotYear")
        end
        yearEl:setText(baseText)
    end
end

function RealisticCropRotationFrame:updatePlanSlotYearLabels(plan)
    for i = 1, 4 do
        self:updatePlanSlotYearLabel(i, plan)
    end
end

function RealisticCropRotationFrame:getCropFamily(cropName)
    if cropName == nil or cropName == "" then return "UNKNOWN" end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.families == nil then return "UNKNOWN" end
    return config.families[string.upper(cropName)] or "UNKNOWN"
end

function RealisticCropRotationFrame:getCropDisplayName(cropName)
    if cropName == nil or cropName == "" then return "" end
    local normalizedName = string.upper(tostring(cropName))

    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil then
        local fruitType = g_fruitTypeManager:getFruitTypeByName(normalizedName)
        if fruitType ~= nil then
            if g_fruitTypeManager.getFillTypeByFruitTypeIndex ~= nil and fruitType.index ~= nil then
                local fillType = g_fruitTypeManager:getFillTypeByFruitTypeIndex(fruitType.index)
                if fillType ~= nil and fillType.title ~= nil and fillType.title ~= "" then
                    return fillType.title
                end
            end
            if fruitType.fillType ~= nil and fruitType.fillType.title ~= nil
                and fruitType.fillType.title ~= "" then
                return fruitType.fillType.title
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

function RealisticCropRotationFrame:buildFarmlandList()
    local mgr = self:getManager()
    if mgr == nil or mgr.getOwnedFarmlands == nil then return {} end
    return mgr:getOwnedFarmlands() or {}
end

function RealisticCropRotationFrame:formatAreaHa(areaHa)
    return string.format("%.1f ha", tonumber(areaHa) or 0)
end

function RealisticCropRotationFrame:calculateTotalAreaHa(farmlandList)
    local total = 0
    for _, entry in ipairs(farmlandList or {}) do
        total = total + (tonumber(entry.areaHa) or 0)
    end
    return total
end

function RealisticCropRotationFrame:updateOverviewTotalArea()
    if self.overviewTotalArea == nil then return end
    local label = self.i18n:getText("rcr_overview_total_area")
    self.overviewTotalArea:setText(string.format(label, self.totalAreaHa or 0))
end

function RealisticCropRotationFrame:getElementOriginalSize(element)
    if element == nil or element.size == nil then return nil end
    if element._frOriginalSize == nil then
        element._frOriginalSize = {element.size[1], element.size[2]}
    end
    return element._frOriginalSize
end

function RealisticCropRotationFrame:getElementOriginalPosition(element)
    if element == nil or element.position == nil then return nil end
    if element._frOriginalPosition == nil then
        element._frOriginalPosition = {element.position[1], element.position[2]}
    end
    return element._frOriginalPosition
end

function RealisticCropRotationFrame:getTextRenderWidth(textElement, text)
    if textElement == nil or getTextWidth == nil then return nil end

    local value = tostring(text or "")
    if textElement.textUpperCase then
        if utf8ToUpper ~= nil then
            value = utf8ToUpper(value)
        else
            value = string.upper(value)
        end
    end

    if setTextBold ~= nil then
        setTextBold(textElement.textBold == true)
    end
    local width = getTextWidth(textElement.defaultTextSize or textElement.textSize, value)
    if setTextBold ~= nil then
        setTextBold(false)
    end

    return width
end

function RealisticCropRotationFrame:resizePillToText(pillBg, pillText, text)
    if pillBg == nil or pillText == nil then return end
    if pillBg.setSize == nil or pillText.setSize == nil then return end

    local bgSize = self:getElementOriginalSize(pillBg)
    local textSize = self:getElementOriginalSize(pillText)
    if bgSize == nil or textSize == nil then return end

    local textWidth = self:getTextRenderWidth(pillText, text)
    if textWidth == nil then return end

    local padding = 20 * (g_pixelSizeScaledX or g_pixelSizeX or 0)
    local width = textWidth + padding
    if pillBg.parent ~= nil and pillBg.parent.absSize ~= nil
        and (pillBg.parent.absSize[1] or 0) > 0 then
        width = math.min(width, pillBg.parent.absSize[1])
    end

    pillBg:setSize(width, bgSize[2])
    pillText:setSize(width, textSize[2])

    if pillBg.parent ~= nil and pillBg.parent.invalidateLayout ~= nil then
        pillBg.parent:invalidateLayout()
    end
end

function RealisticCropRotationFrame:updateMainHeaderTitle()
    if self.menuHeaderTitle == nil then return end
    local key = self:isHistoryTab() and "rcr_tab_history" or "rcr_tab_planning"
    self.menuHeaderTitle:setText(self.i18n:getText(key))
end

function RealisticCropRotationFrame:subscribeFarmlandChanges()
    if self.isSubscribedToFarmlandChanges then return end
    if self.messageCenter ~= nil and self.messageCenter.subscribe ~= nil
        and MessageType ~= nil and MessageType.FARMLAND_OWNER_CHANGED ~= nil then
        self.messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, self.onFarmlandOwnerChanged, self)
        self.isSubscribedToFarmlandChanges = true
    end
end

function RealisticCropRotationFrame:unsubscribeFarmlandChanges()
    if not self.isSubscribedToFarmlandChanges then return end
    if self.messageCenter ~= nil and self.messageCenter.unsubscribe ~= nil
        and MessageType ~= nil and MessageType.FARMLAND_OWNER_CHANGED ~= nil then
        self.messageCenter:unsubscribe(MessageType.FARMLAND_OWNER_CHANGED, self)
    end
    self.isSubscribedToFarmlandChanges = false
end

function RealisticCropRotationFrame:onFarmlandOwnerChanged(_farmlandId, _farmId, _loadFromSavegame)
    self:populateSidebar()
end

function RealisticCropRotationFrame:isHistoryTab()
    return self.viewSelector == nil
        or self.viewSelector:getState() == RealisticCropRotationFrame.TAB.HISTORY
end

function RealisticCropRotationFrame:updateContainerVisibility()
    local hasFields = #(self.farmlandList or {}) > 0
    local isHistory = self:isHistoryTab()
    if self.emptyText        ~= nil then self.emptyText:setVisible(not hasFields) end
    if self.detailsContainer ~= nil then self.detailsContainer:setVisible(hasFields and isHistory) end
    if self.planningContainer ~= nil then self.planningContainer:setVisible(hasFields and not isHistory) end
    self:updateMainHeaderTitle()
end

function RealisticCropRotationFrame:linkFocusNavigation()
    if FocusManager == nil then return end

    local hasFields = #(self.farmlandList or {}) > 0
    local selectors = self.planSlotSelector
    local firstSelector = selectors ~= nil and selectors[1] or nil

    if self.listFields ~= nil and FocusManager.RIGHT ~= nil then
        local target = (hasFields and not self:isHistoryTab()) and firstSelector or nil
        FocusManager:linkElements(self.listFields, FocusManager.RIGHT, target)
    end

    if selectors == nil then return end

    for i = 1, 4 do
        local selector = selectors[i]
        if selector ~= nil then
            local previousElement = i > 1 and selectors[i - 1] or self.listFields
            local nextElement = i < 4 and selectors[i + 1] or self.listFields

            if FocusManager.TOP ~= nil then
                FocusManager:linkElements(selector, FocusManager.TOP, previousElement)
            end
            if FocusManager.BOTTOM ~= nil then
                FocusManager:linkElements(selector, FocusManager.BOTTOM, nextElement)
            end
        end
    end
end

function RealisticCropRotationFrame:getPlanForFarmland(farmlandId)
    local mgr = self:getManager()
    if mgr ~= nil and mgr.getRotationPlan ~= nil then
        return mgr:getRotationPlan(farmlandId)
    end
    return {"","","",""}
end

-- ===========================================================================
--  CROP LIST (built once from fruitTypeManager; drives plan slot selectors)
-- ===========================================================================

function RealisticCropRotationFrame:buildPlanCropList()
    self.planCropList = {""}  -- index 1 = no crop

    -- Include all plantable crops on this map (including modded ones from any modhub map).
    -- Filter: next(harvestTransitions) ~= nil ensures the table is non-empty, meaning the
    -- crop has at least one harvest or forage state defined (FruitTypeDesc.lua line 629).
    -- Empty {} means decorative/non-harvestable fruit types (trees, weeds, etc.).
    if g_fruitTypeManager ~= nil then
        local fruitsTable = g_fruitTypeManager.fruitTypes
        if fruitsTable == nil and g_fruitTypeManager.getFruitTypes ~= nil then
            fruitsTable = g_fruitTypeManager:getFruitTypes()
        end

        if fruitsTable ~= nil then
            local nameSet = {}
            for _, fruitType in pairs(fruitsTable) do
                if fruitType ~= nil and fruitType.name ~= nil
                    and fruitType.harvestTransitions ~= nil
                    and next(fruitType.harvestTransitions) ~= nil
                    and fruitType.fillType ~= nil
                    and fruitType.fillType.hudOverlayFilename ~= nil then
                    local name = string.upper(fruitType.name)
                    local cfg = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
                    local family = cfg ~= nil and cfg.families ~= nil and cfg.families[name] or nil
                    if family ~= "COVER" then
                        if not nameSet[name] then
                            nameSet[name] = true
                            table.insert(self.planCropList, name)
                        end
                    end
                end
            end
        end
    end

    -- Sort alphabetically by localized display name
    table.sort(self.planCropList, function(a, b)
        if a == "" then return true end
        if b == "" then return false end
        return self:getCropDisplayName(a) < self:getCropDisplayName(b)
    end)

    -- Wire selectors
    local cropTexts = {}
    for _, cropName in ipairs(self.planCropList) do
        table.insert(cropTexts, cropName == "" and self.i18n:getText("rcr_plan_none")
                                               or self:getCropDisplayName(cropName))
    end

    if self.planSlotSelector ~= nil then
        for i = 1, 4 do
            if self.planSlotSelector[i] ~= nil then
                self.planSlotSelector[i]:setTexts(cropTexts)
                self.planSlotSelector[i]:setState(1, false)
            end
        end
    end
end

-- ===========================================================================
--  SIDEBAR — SmoothList data source
-- ===========================================================================

function RealisticCropRotationFrame:populateSidebar()
    local previousSelectedId = self.selectedId
    self.farmlandList = self:buildFarmlandList()
    self.totalAreaHa = self:calculateTotalAreaHa(self.farmlandList)
    self:buildPlanCropList()
    self.selectedId = nil
    if self.listFields ~= nil then
        self.listFields:reloadData()
        if #self.farmlandList > 0 then
            local selectedIndex = 1
            if previousSelectedId ~= nil then
                for index, entry in ipairs(self.farmlandList) do
                    if entry.farmlandId == previousSelectedId then
                        selectedIndex = index
                        break
                    end
                end
            end
            if self.listFields.setSelectedItem ~= nil then
                self.listFields:setSelectedItem(selectedIndex, 1, true)
            end
            self.selectedId = self.farmlandList[selectedIndex].farmlandId
        end
    end
    self:buildRotationGroups()
    self:updateOverviewTotalArea()
    if self.listPlanOverview ~= nil then
        self.listPlanOverview:reloadData()
    end
    self:updateContainerVisibility()
    if self:isHistoryTab() then
        self:updateDetailPanel(self.selectedId)
    else
        self:updatePlanningPanel(self.selectedId)
    end
end

function RealisticCropRotationFrame:getNumberOfSections()
    return 1
end

function RealisticCropRotationFrame:getNumberOfItemsInSection(list, _section)
    if list == self.listPlanOverview then
        return #(self.rotationGroups or {})
    end
    return #(self.farmlandList or {})
end

function RealisticCropRotationFrame:getCellTypeForItemInSection(list, _section, _index)
    if list == self.listPlanOverview then return "groupRow" end
    return "field"
end

function RealisticCropRotationFrame:getTitleForSectionHeader(_list, _section)
    return nil
end

function RealisticCropRotationFrame:getSectionHeaderHeight(_list, _section)
    return 0
end

function RealisticCropRotationFrame:populateCellForItemInSection(list, _section, index, cell)
    if list == self.listPlanOverview then
        self:populateGroupCell(index, cell)
        return
    end

    if cell == nil or cell.getAttribute == nil then return end
    local entry = (self.farmlandList or {})[index]
    if entry == nil then return end

    local mgr      = self:getManager()

    -- Line 1: field name + area
    local nameEl = cell:getAttribute("fieldName")
    local areaEl = cell:getAttribute("fieldArea")
    if nameEl ~= nil then nameEl:setText(string.upper(tostring(entry.name or ""))) end
    if areaEl ~= nil then areaEl:setText(string.format("%.1f ha", tonumber(entry.areaHa) or 0)) end

    -- Real-state resolution order, never the history:
    --   1. Active crop on the parcel (server snapshot on MP clients; density map
    --      first, then fieldState fallback on the server/local host).
    --   2. Native ground state on local host/server, looked up via
    --      MapOverlayGenerator.L10N_SYMBOL.
    --   3. "Aucune culture" neutral fallback. NEVER "Jachère" — fallow is an
    --      agronomic choice, not a generic "no crop here" indicator.
    local activeCropName = nil
    if mgr ~= nil and mgr.getActiveCropName ~= nil then
        activeCropName = mgr:getActiveCropName(entry.farmlandId)
    end

    local iconFruitType = nil
    if activeCropName ~= nil and g_fruitTypeManager ~= nil
        and g_fruitTypeManager.getFruitTypeByName ~= nil then
        iconFruitType = g_fruitTypeManager:getFruitTypeByName(tostring(activeCropName))
    end

    local iconEl = cell:getAttribute("cropIcon")
    if iconEl ~= nil then
        local loaded = false
        if iconFruitType ~= nil and iconFruitType.fillType ~= nil
            and iconFruitType.fillType.hudOverlayFilename ~= nil then
            if iconEl.setImageFilename ~= nil then
                iconEl:setImageFilename(iconFruitType.fillType.hudOverlayFilename)
            end
            if iconEl.setImageUVs ~= nil then
                iconEl:setImageUVs(nil, 0, 0, 0, 1, 1, 0, 1, 1)
            end
            iconEl:setVisible(true)
            loaded = true
        end
        if not loaded then iconEl:setVisible(false) end
    end

    local cropLineEl = cell:getAttribute("cropLine")
    if cropLineEl ~= nil then
        if activeCropName ~= nil then
            local family = self:getCropFamily(activeCropName)
            local line   = self:getCropDisplayName(activeCropName)
            if family ~= "UNKNOWN" then
                line = line .. "  \xc2\xb7  " .. self.i18n:getText("rcr_family_" .. string.lower(family))
            end
            cropLineEl:setText(line)
        else
            local groundLabel = nil
            if mgr ~= nil and type(mgr.getCurrentGroundStateLabel) == "function" then
                groundLabel = mgr:getCurrentGroundStateLabel(entry.farmlandId)
            end
            if groundLabel ~= nil and groundLabel ~= "" then
                cropLineEl:setText(groundLabel)
            else
                cropLineEl:setText(self.i18n:getText("rcr_sidebar_no_active_crop"))
            end
        end
    end
end

function RealisticCropRotationFrame:onListSelectionChanged(_list, _section, index, _cell)
    if _list ~= self.listFields then return end
    if self.farmlandList == nil then return end
    local entry = (self.farmlandList or {})[index]
    if entry ~= nil then
        self.selectedId = entry.farmlandId
        if self:isHistoryTab() then
            self:updateDetailPanel(entry.farmlandId)
        else
            self:updatePlanningPanel(entry.farmlandId)
        end
    end
end

-- ===========================================================================
--  TAB SWITCHING
-- ===========================================================================

function RealisticCropRotationFrame:onViewChanged()
    self:updateContainerVisibility()
    if self:isHistoryTab() then
        self:updateDetailPanel(self.selectedId)
    else
        self:updateOverviewTotalArea()
        self:updatePlanningPanel(self.selectedId)
    end
    self:linkFocusNavigation()

    if FocusManager ~= nil and self.listFields ~= nil and #(self.farmlandList or {}) > 0 then
        FocusManager:setFocus(self.listFields)
    end
end

-- ===========================================================================
--  DETAIL PANEL (tab 1 — history / current crop / nitrogen / advice / pH)
-- ===========================================================================

function RealisticCropRotationFrame:getCurrentSlotData(farmlandId)
    local mgr = self:getManager()
    local activeCropName = nil
    if mgr ~= nil and type(mgr.getActiveCropName) == "function" then
        activeCropName = mgr:getActiveCropName(farmlandId)
    end

    if activeCropName ~= nil and activeCropName ~= "" then
        return activeCropName, self:getCropFamily(activeCropName), nil
    end

    local groundLabel = nil
    if mgr ~= nil and type(mgr.getCurrentGroundStateLabel) == "function" then
        groundLabel = mgr:getCurrentGroundStateLabel(farmlandId)
    end
    if groundLabel ~= nil and groundLabel ~= "" then
        return nil, "UNKNOWN", groundLabel
    end

    return nil, "UNKNOWN", self.i18n:getText("rcr_sidebar_no_active_crop")
end

function RealisticCropRotationFrame:updateDetailPanel(farmlandId)
    local farmlandList = self.farmlandList or {}
    if #farmlandList == 0 then return end

    local entry = nil
    for _, e in ipairs(farmlandList) do
        if e.farmlandId == farmlandId then entry = e; break end
    end
    if entry == nil then return end

    if self.detailTitle ~= nil then
        self.detailTitle:setText(
            string.upper(tostring(entry.name or ""))
            .. "  |  "
            .. string.format("%.1f ha", tonumber(entry.areaHa) or 0)
        )
    end

    if self.detailSeason ~= nil then
        local seasonIdx = (g_currentMission ~= nil and g_currentMission.environment ~= nil)
            and (g_currentMission.environment.currentSeason or 0) or 0
        local seasonKey = RealisticCropRotationFrame.SEASON_KEY[seasonIdx] or "rcr_season_spring"
        self.detailSeason:setText(
            "\xc2\xb7  " .. self.i18n:getText("rcr_season_label") .. ": "
            .. string.upper(self.i18n:getText(seasonKey)) .. "  \xc2\xb7"
        )
    end

    local mgr = self:getManager()
    if mgr ~= nil and type(mgr.reconcileActiveCropForFarmland) == "function" then
        local changed = mgr:reconcileActiveCropForFarmland(farmlandId)
        if changed and RealisticCropRotation ~= nil and type(RealisticCropRotation.requestBroadcast) == "function" then
            RealisticCropRotation.requestBroadcast()
        end
    end

    self:updateResiduePill(self.statusPillBg, self.statusPillText, farmlandId)

    local history = (mgr ~= nil) and (mgr:getHistory(farmlandId) or {}) or {}

    for slotIdx = 1, 4 do
        local histIdx  = RealisticCropRotationFrame.SLOT_HISTORY_IDX[slotIdx]
        local hEntry   = history[histIdx]
        local cropName = hEntry and hEntry.crop or nil
        self:updateTimelineSlot(slotIdx, cropName, self:getCropFamily(cropName), nil)
    end

    local currentCropName, currentFamily, currentFallbackText = self:getCurrentSlotData(farmlandId)
    self:updateTimelineSlot(5, currentCropName, currentFamily, currentFallbackText)

    self:updateNitrogenGauge(farmlandId)
    self:updateSoilPHGauge(farmlandId)
    self:updateAdvice(currentFamily)
    self:updateYieldCard(farmlandId)
end

-- ---------------------------------------------------------------------------
--  Timeline slot (slotId 1..5) — history tab
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:updateTimelineSlot(slotId, cropName, family, fallbackText)
    local pfx = "slot" .. tostring(slotId)
    local iconEl   = self[pfx .. "Icon"]
    local nameEl   = self[pfx .. "CropName"]
    local badgeBg  = self[pfx .. "BadgeBg"]
    local badgeTxt = self[pfx .. "BadgeText"]

    if iconEl ~= nil then
        self:applySlotCropIcon(iconEl, cropName)
    end

    if nameEl ~= nil then
        if cropName ~= nil and cropName ~= "" then
            nameEl:setText(self:getCropDisplayName(cropName))
        elseif fallbackText ~= nil and fallbackText ~= "" then
            nameEl:setText(fallbackText)
        else
            nameEl:setText(self.i18n:getText("rcr_slot_empty"))
        end
    end

    local showBadge = cropName ~= nil and cropName ~= "" and (family ~= nil) and (family ~= "UNKNOWN")
    if badgeBg ~= nil then
        badgeBg:setVisible(showBadge)
        if showBadge then
            local c = RealisticCropRotationFrame.FAMILY_RGBA[family]
            if c ~= nil then
                badgeBg.color = {c[1], c[2], c[3], c[4]}
            end
        end
    end
    if badgeTxt ~= nil then
        badgeTxt:setVisible(showBadge)
        if showBadge then
            local familyText = self.i18n:getText("rcr_family_" .. string.lower(family))
            badgeTxt:setText(familyText)
            self:resizePillToText(badgeBg, badgeTxt, familyText)
        end
    end
end

-- ---------------------------------------------------------------------------
--  Nitrogen gauge
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:setStatusBarFill(barFill, ratio)
    ratio = math.max(0, math.min(1, tonumber(ratio) or 0))

    local fillW = math.floor(RealisticCropRotationFrame.N_BAR_MAX_WIDTH * ratio)
    if barFill ~= nil then
        if barFill.setSize ~= nil then
            local fillSize = GuiUtils ~= nil and GuiUtils.getNormalizedScreenValues ~= nil
                and GuiUtils.getNormalizedScreenValues(
                    string.format("%dpx %dpx", fillW, RealisticCropRotationFrame.N_BAR_HEIGHT)
                ) or nil
            if fillSize ~= nil then
                barFill:setSize(fillSize[1], fillSize[2])
            end
        end
        barFill:setVisible(fillW > 0)
    end
end

function RealisticCropRotationFrame:updateNitrogenGauge(farmlandId)
    local mgr = self:getManager()
    local ratio = 0
    local labelKey = "rcr_n_none"
    local stateText = nil
    local valueText = nil
    local needText = nil

    if mgr ~= nil and mgr.getNitrogenLevel ~= nil then
        local kgHa, targetKgHa, mapMaxKgHa = mgr:getNitrogenLevel(farmlandId)
        if kgHa ~= nil then
            kgHa = tonumber(kgHa) or 0
            targetKgHa = tonumber(targetKgHa) or 0
            mapMaxKgHa = tonumber(mapMaxKgHa) or 0

            -- With an active crop, Precision Farming evaluates nitrogen against
            -- the crop target. Without a crop target, the gauge falls back to the
            -- nitrogen map's global capacity.
            if targetKgHa > 0 then
                ratio = kgHa / targetKgHa
            elseif mapMaxKgHa > 0 then
                ratio = kgHa / mapMaxKgHa
            end
            ratio = math.max(0, math.min(1, ratio))

            labelKey = "rcr_n_available"
            stateText = string.format(self.i18n:getText("rcr_n_average_value"), kgHa)

            if targetKgHa > 0 then
                needText = string.format(self.i18n:getText("rcr_n_crop_need"), targetKgHa)
            end
        end
    end

    if stateText == nil then
        local sprayLevel = 0
        if mgr ~= nil and mgr.getCurrentSprayLevel ~= nil then
            sprayLevel = mgr:getCurrentSprayLevel(farmlandId) or 0
        end
        sprayLevel = math.max(0, math.min(2, tonumber(sprayLevel) or 0))
        ratio = sprayLevel / 2.0
        labelKey = RealisticCropRotationFrame.SPRAY_LABEL_KEY[sprayLevel] or "rcr_n_none"
    end

    self:setStatusBarFill(self.nitrogenBarFill, ratio)

    if self.nitrogenStateLabel ~= nil then
        self.nitrogenStateLabel:setText(stateText or self.i18n:getText(labelKey))
    end

    if self.nitrogenValueLabel ~= nil then
        if needText ~= nil then
            self.nitrogenValueLabel:setText(needText)
        end
        self.nitrogenValueLabel:setVisible(needText ~= nil)
    end

end

-- ---------------------------------------------------------------------------
--  Soil pH / lime gauge
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:updateSoilPHGauge(farmlandId)
    local mgr = self:getManager()
    local ratio = 0
    local labelKey = "rcr_lime_none"
    local stateText = nil
    local valueText = nil

    if mgr ~= nil and mgr.getPHLevel ~= nil then
        local actualPH, targetPH, minPH, maxPH = mgr:getPHLevel(farmlandId)
        if actualPH ~= nil then
            minPH = tonumber(minPH) or 0
            maxPH = tonumber(maxPH) or 0
            labelKey = "rcr_lime_average_pf"
            if targetPH ~= nil then
                ratio = targetPH > 0 and (actualPH / targetPH) or 0
                stateText = string.format(self.i18n:getText("rcr_lime_average_value"), actualPH)
                valueText = string.format(self.i18n:getText("rcr_lime_target"), targetPH)
            else
                ratio = maxPH > minPH and ((actualPH - minPH) / (maxPH - minPH)) or 0
                stateText = string.format(self.i18n:getText("rcr_lime_average_value"), actualPH)
            end
        end
    end

    if stateText == nil then
        local limeLevel = 0
        local maxLevel = 1
        if mgr ~= nil and mgr.getCurrentLimeLevel ~= nil then
            limeLevel, maxLevel = mgr:getCurrentLimeLevel(farmlandId)
        end

        limeLevel = tonumber(limeLevel) or 0
        maxLevel = math.max(1, tonumber(maxLevel) or 1)
        ratio = limeLevel / maxLevel
        valueText = string.format("%d / %d", limeLevel, maxLevel)

        if limeLevel <= 0 then
            labelKey = "rcr_lime_none"
        elseif limeLevel >= maxLevel then
            labelKey = "rcr_lime_full"
        else
            labelKey = "rcr_lime_partial"
        end
    end

    self:setStatusBarFill(self.limeBarFill, ratio)

    if self.limeStateLabel ~= nil then
        self.limeStateLabel:setText(stateText or self.i18n:getText(labelKey))
    end

    if self.limeValueLabel ~= nil then
        self.limeValueLabel:setText(valueText or "")
        self.limeValueLabel:setVisible(valueText ~= nil)
    end
end

-- ---------------------------------------------------------------------------
--  Yield card
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:updateYieldCard(farmlandId)
    local mgr = self:getManager()
    local info = nil
    if mgr ~= nil and mgr.getFieldCropInfo ~= nil then
        info = mgr:getFieldCropInfo(farmlandId)
    end

    local totalText = "-"
    local weedText = "-"
    local stageText = "-"
    local hasYield = info ~= nil and info.totalLiters ~= nil
    local hasStage = info ~= nil and info.growthStageText ~= nil
    local hasWeed = info ~= nil and info.weedActionText ~= nil

    if hasYield then
        local totalLiters = tonumber(info.totalLiters) or 0
        if g_i18n ~= nil and g_i18n.formatVolume ~= nil then
            totalText = g_i18n:formatVolume(totalLiters, 0)
        else
            totalText = string.format("%d L", math.floor(totalLiters + 0.5))
        end
    end

    if hasWeed then weedText = info.weedActionText end
    if hasStage then stageText = info.growthStageText end

    if self.yieldTotalValue ~= nil then
        if self.yieldTotalValue.applyProfile ~= nil then
            self.yieldTotalValue:applyProfile(hasYield and "frYieldKpiValue" or "frYieldKpiValueNA")
        end
        self.yieldTotalValue:setText(totalText)
    end

    -- Weed and stage KPIs use a smaller dedicated profile because their
    -- composed text strings ("(<stage>) · <tool>" and "(X/Y) · <tier>") would
    -- not fit one line at the default 26px size used for the litre value.
    if self.yieldPerHaValue ~= nil then
        if self.yieldPerHaValue.applyProfile ~= nil then
            self.yieldPerHaValue:applyProfile(hasWeed and "frYieldKpiValueSmall" or "frYieldKpiValueNA")
        end
        self.yieldPerHaValue:setText(weedText)
    end

    if self.yieldStageValue ~= nil then
        if self.yieldStageValue.applyProfile ~= nil then
            self.yieldStageValue:applyProfile(hasStage and "frYieldKpiValueSmall" or "frYieldKpiValueNA")
        end
        self.yieldStageValue:setText(stageText)
    end
end

-- ---------------------------------------------------------------------------
--  Agronomic advice
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:updateAdvice(currentFamily)
    if self.adviceText == nil then return end
    local key = RealisticCropRotationFrame.ADVICE_KEY[currentFamily]
    self.adviceText:setText(
        key ~= nil and self.i18n:getText(key)
                   or self.i18n:getText("rcr_advice_no_current_crop"))
end

-- ===========================================================================
--  PLANNING PANEL (tab 2)
-- ===========================================================================

function RealisticCropRotationFrame:updatePlanningPanel(farmlandId)
    local farmlandList = self.farmlandList or {}
    if #farmlandList == 0 then return end

    local entry = nil
    for _, e in ipairs(farmlandList) do
        if e.farmlandId == farmlandId then entry = e; break end
    end
    if entry == nil then return end

    if self.planTitle ~= nil then
        self.planTitle:setText(
            string.upper(tostring(entry.name or ""))
            .. "  |  "
            .. string.format("%.1f ha", tonumber(entry.areaHa) or 0)
        )
    end
    if self.planSeason ~= nil then
        local seasonIdx = (g_currentMission ~= nil and g_currentMission.environment ~= nil)
            and (g_currentMission.environment.currentSeason or 0) or 0
        local seasonKey = RealisticCropRotationFrame.SEASON_KEY[seasonIdx] or "rcr_season_spring"
        self.planSeason:setText(
            "\xc2\xb7  " .. self.i18n:getText("rcr_season_label") .. ": "
            .. string.upper(self.i18n:getText(seasonKey)) .. "  \xc2\xb7"
        )
    end

    self:updatePlanSlots(farmlandId)
    local plan = self:getPlanForFarmland(farmlandId)
    self:updateScoreCard(plan)
    self:updatePlannedResiduePill(self.planStatusPillBg, self.planStatusPillText, plan)
end

-- ---------------------------------------------------------------------------
--  Plan slots — crop selector + icon + family badge
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:updatePlanSlots(farmlandId)
    local plan = self:getPlanForFarmland(farmlandId)
    self:updatePlanSlotYearLabels(plan)
    for i = 1, 4 do
        local sel      = self.planSlotSelector  ~= nil and self.planSlotSelector[i]
        local iconEl   = self.planSlotIcon      ~= nil and self.planSlotIcon[i]
        local badgeBg  = self.planSlotBadge     ~= nil and self.planSlotBadge[i]
        local badgeTxt = self.planSlotBadgeText ~= nil and self.planSlotBadgeText[i]

        local cropName = plan[i] or ""

        -- Sync MultiTextOption state to saved crop
        if sel ~= nil then
            local state = 1
            for idx, name in ipairs(self.planCropList) do
                if name == cropName then state = idx; break end
            end
            sel:setState(state, false)
        end

        self:applySlotCropIcon(iconEl, cropName)
        self:applySlotBadge(badgeBg, badgeTxt, self:getCropFamily(cropName))
    end
end

function RealisticCropRotationFrame:getPlanFromSelectors()
    local plan = {"", "", "", ""}
    for i = 1, 4 do
        local sel = self.planSlotSelector ~= nil and self.planSlotSelector[i]
        if sel ~= nil and self.planCropList ~= nil then
            local state = sel:getState()
            plan[i] = self.planCropList[state] or ""
        end
    end
    return plan
end

function RealisticCropRotationFrame:updatePlanSlotVisualsFromSelectors()
    local plan = self:getPlanFromSelectors()
    self:updatePlanSlotYearLabels(plan)
    for i = 1, 4 do
        local cropName = plan[i] or ""
        local iconEl   = self.planSlotIcon      ~= nil and self.planSlotIcon[i]
        local badgeBg  = self.planSlotBadge     ~= nil and self.planSlotBadge[i]
        local badgeTxt = self.planSlotBadgeText ~= nil and self.planSlotBadgeText[i]
        self:applySlotCropIcon(iconEl, cropName)
        self:applySlotBadge(badgeBg, badgeTxt, self:getCropFamily(cropName))
    end
    self:updateScoreCard(plan)
    self:updatePlannedResiduePill(self.planStatusPillBg, self.planStatusPillText, plan)
end

function RealisticCropRotationFrame:onServerSyncReceived()
    if self.isApplyingServerSync then
        return
    end

    self.isApplyingServerSync = true

    -- In the history tab it is safe to rebuild the sidebar/details from the
    -- authoritative server snapshot.
    -- In the planner tab, do NOT call populateSidebar/updatePlanSlots here:
    -- server snapshots can arrive while the user is clicking MultiTextOption
    -- arrows. Re-setting selector state during that interaction makes the
    -- control appear to skip crops or fail to advance.
    if self:isHistoryTab() then
        self:populateSidebar()
    else
        self:buildRotationGroups()
        if self.listPlanOverview ~= nil then
            self.listPlanOverview:reloadData()
        end
        self:updatePlanSlotVisualsFromSelectors()
    end

    self.isApplyingServerSync = false
end

function RealisticCropRotationFrame:applySlotCropIcon(iconEl, cropName)
    if iconEl == nil then return end
    if cropName == nil or cropName == "" then
        iconEl:setVisible(false)
        return
    end
    local loaded = false
    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil then
        local fruitType = g_fruitTypeManager:getFruitTypeByName(string.upper(cropName))
        if fruitType ~= nil and fruitType.fillType ~= nil
            and fruitType.fillType.hudOverlayFilename ~= nil then
            if iconEl.setImageFilename ~= nil then
                iconEl:setImageFilename(fruitType.fillType.hudOverlayFilename)
            end
            if iconEl.setImageUVs ~= nil then
                iconEl:setImageUVs(nil, 0, 0, 0, 1, 1, 0, 1, 1)
            end
            iconEl:setVisible(true)
            loaded = true
        end
    end
    if not loaded then iconEl:setVisible(false) end
end

function RealisticCropRotationFrame:applySlotBadge(badgeBg, badgeTxt, family)
    local showBadge = family ~= nil and family ~= "" and family ~= "UNKNOWN"
    if badgeBg ~= nil then
        badgeBg:setVisible(showBadge)
        if showBadge then
            local c = RealisticCropRotationFrame.FAMILY_RGBA[family]
            if c ~= nil then
                badgeBg.color = {c[1], c[2], c[3], c[4]}
            end
        end
    end
    if badgeTxt ~= nil then
        badgeTxt:setVisible(showBadge)
        if showBadge then
            local familyText = self.i18n:getText("rcr_family_" .. string.lower(family))
            badgeTxt:setText(familyText)
            self:resizePillToText(badgeBg, badgeTxt, familyText)
        end
    end
end

-- ---------------------------------------------------------------------------
--  Plan slot onClick handlers
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:onChangePlanSlot1() self:handlePlanSlotChange(1) end
function RealisticCropRotationFrame:onChangePlanSlot2() self:handlePlanSlotChange(2) end
function RealisticCropRotationFrame:onChangePlanSlot3() self:handlePlanSlotChange(3) end
function RealisticCropRotationFrame:onChangePlanSlot4() self:handlePlanSlotChange(4) end

function RealisticCropRotationFrame:handlePlanSlotChange(slotIdx)
    if self.isApplyingServerSync then return end
    if self.selectedId == nil then return end
    local sel = self.planSlotSelector ~= nil and self.planSlotSelector[slotIdx]
    if sel == nil then return end

    local state    = sel:getState()
    local cropName = (self.planCropList ~= nil and self.planCropList[state]) or ""

    local isClientOnly = g_currentMission ~= nil and g_currentMission.getIsServer ~= nil
        and not g_currentMission:getIsServer()

    if isClientOnly then
        if g_client ~= nil and g_client.getServerConnection ~= nil and RCRPlanUpdateEvent ~= nil then
            local connection = g_client:getServerConnection()
            if connection ~= nil then
                connection:sendEvent(RCRPlanUpdateEvent.new(self.selectedId, slotIdx, cropName))
            end
        else
            Logging.warning("[RealisticCropRotation][MP] Plan update not sent: client connection or event unavailable")
        end
    else
        local mgr = self:getManager()
        local changed = false
        if mgr ~= nil and mgr.setRotationPlanYear ~= nil then
            changed = mgr:setRotationPlanYear(self.selectedId, slotIdx, cropName)
        end
        if changed and RealisticCropRotation ~= nil and RealisticCropRotation.requestBroadcast ~= nil then
            RealisticCropRotation.requestBroadcast()
        end
    end

    local iconEl   = self.planSlotIcon      ~= nil and self.planSlotIcon[slotIdx]
    local badgeBg  = self.planSlotBadge     ~= nil and self.planSlotBadge[slotIdx]
    local badgeTxt = self.planSlotBadgeText ~= nil and self.planSlotBadgeText[slotIdx]
    self:applySlotCropIcon(iconEl, cropName)
    self:applySlotBadge(badgeBg, badgeTxt, self:getCropFamily(cropName))

    local plan = self:getPlanFromSelectors()
    self:updatePlanSlotYearLabels(plan)
    self:updateScoreCard(plan)
    self:updatePlannedResiduePill(self.planStatusPillBg, self.planStatusPillText, plan)

    -- Keep the overview refreshed from the repository. On MP clients this may
    -- lag one server snapshot behind, but it avoids using local optimistic data
    -- as saved truth. The slot cards themselves are updated directly above.
    self:buildRotationGroups()
    if self.listPlanOverview ~= nil then
        self.listPlanOverview:reloadData()
    end
end

-- ---------------------------------------------------------------------------
--  Score card
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:updateScoreCard(plan)
    if self.scoreText == nil then return end
    plan = plan or {"","","",""}

    local score    = self:calcRotationScore(plan)
    local scoreKey = self:getScoreTextKey(score, plan)
    self.scoreText:setText(self.i18n:getText(scoreKey))

    -- Cursor positioner: width = f(score) moves the cursor dot along the track
    -- Track width=400px, cursor=14px → positioner range: 14..400px
    -- positionerW = (score/100) * (400-14) + 14
    if self.scoreCursorPos ~= nil and self.scoreCursorPos.setSize ~= nil then
        local trackW   = 400
        local cursorW  = 14
        local posW = math.floor((score / 100) * (trackW - cursorW) + cursorW)
        local posSize = GuiUtils ~= nil and GuiUtils.getNormalizedScreenValues ~= nil
            and GuiUtils.getNormalizedScreenValues(string.format("%dpx 14px", posW)) or nil
        if posSize ~= nil then self.scoreCursorPos:setSize(posSize[1], posSize[2]) end
    end

    -- Cursor color matches score zone (Lua-only, XML constraint does not apply)
    if self.scoreCursor ~= nil then
        if score >= 80 then
            self.scoreCursor.color = {0.325, 0.565, 0.071, 1.0}
        elseif score >= 50 then
            self.scoreCursor.color = {0.95, 0.85, 0.05, 1.0}
        else
            self.scoreCursor.color = {0.75, 0.20, 0.05, 1.0}
        end
    end
end

function RealisticCropRotationFrame:calcRotationScore(plan)
    local families = {}
    local hasLegume = false
    for i = 1, 4 do
        local crop = plan[i] or ""
        if crop ~= "" then
            local fam = self:getCropFamily(crop)
            if fam ~= "UNKNOWN" then
                families[i] = fam
                if fam == "LEGUME" then hasLegume = true end
            end
        end
    end

    local filledCount = 0
    for _ in pairs(families) do filledCount = filledCount + 1 end
    if filledCount < 2 then return 0 end

    local score = 100
    for i = 1, 3 do
        if families[i] ~= nil and families[i+1] ~= nil and families[i] == families[i+1] then
            score = score - 25
        end
    end
    if hasLegume then score = math.min(100, score + 10) end

    local seen = {}
    for _, fam in pairs(families) do seen[fam] = true end
    local uniqueCount = 0
    for _ in pairs(seen) do uniqueCount = uniqueCount + 1 end
    if uniqueCount == 1 then score = math.max(0, score - 20) end

    return math.max(0, math.min(100, score))
end

function RealisticCropRotationFrame:getScoreTextKey(score, plan)
    local anyFilled = false
    for i = 1, 4 do if (plan[i] or "") ~= "" then anyFilled = true; break end end
    if not anyFilled   then return "rcr_plan_none" end
    if score == 0      then return "rcr_score_incomplete" end
    if score >= 80     then return "rcr_score_excellent" end
    if score >= 60     then return "rcr_score_good" end
    if score >= 40     then return "rcr_score_fair" end
    return "rcr_score_poor"
end

function RealisticCropRotationFrame:getScoreLabel(score)
    if score >= 80 then return "rcr_score_short_optimal", 0.325, 0.565, 0.071
    elseif score >= 60 then return "rcr_score_short_good",  0.95,  0.85, 0.05
    elseif score >= 30 then return "rcr_score_short_fair",  0.75,  0.45, 0.05
    elseif score >  0  then return "rcr_score_short_poor",  0.75,  0.20, 0.05
    else                    return nil,                    0.30,  0.30, 0.30
    end
end

-- ===========================================================================
--  ROTATION GROUPS — overview of fields sharing the same crop rotation
-- ===========================================================================

function RealisticCropRotationFrame:buildRotationGroups()
    local groups   = {}
    local groupMap = {}

    for _, entry in ipairs(self.farmlandList or {}) do
        local plan = self:getPlanForFarmland(entry.farmlandId)
        -- Key by exact crop sequence
        local key = (plan[1] or "") .. "|" .. (plan[2] or "")
                 .. "|" .. (plan[3] or "") .. "|" .. (plan[4] or "")

        if groupMap[key] == nil then
            table.insert(groups, {
                key        = key,
                plan       = plan,
                fieldNames = {},
                areaHa     = 0,
                score      = self:calcRotationScore(plan),
            })
            groupMap[key] = #groups
        end
        local group = groups[groupMap[key]]
        table.insert(group.fieldNames, entry.name)
        group.areaHa = (group.areaHa or 0) + (tonumber(entry.areaHa) or 0)
    end

    -- Sort: non-empty plans first, then by field count (desc), then by score (desc)
    local emptyKey = "|||"
    table.sort(groups, function(a, b)
        local aEmpty = (a.key == emptyKey)
        local bEmpty = (b.key == emptyKey)
        if aEmpty ~= bEmpty then return not aEmpty end
        if #a.fieldNames ~= #b.fieldNames then return #a.fieldNames > #b.fieldNames end
        return a.score > b.score
    end)

    self.rotationGroups = groups
end

function RealisticCropRotationFrame:getCompactGroupFieldNames(fieldNames)
    local parts = {}
    for i = 1, #(fieldNames or {}) do
        table.insert(parts, string.upper(tostring(fieldNames[i] or "")))
    end

    return table.concat(parts, "  |  ")
end

function RealisticCropRotationFrame:layoutGroupBadgeContent(cell, slotIndex, displayText, badgeX)
    if cell == nil or cell.getAttribute == nil then return end
    if GuiUtils == nil or GuiUtils.getNormalizedScreenValues == nil then return end
    if getTextWidth == nil then return end

    local iconEl  = cell:getAttribute("gCropIcon" .. slotIndex)
    local labelEl = cell:getAttribute("gLabel" .. slotIndex)
    local badgeEl = cell:getAttribute("gBadge" .. slotIndex)
    local yearLabelEl = cell:getAttribute("gYearLabel" .. slotIndex)
    if iconEl == nil or labelEl == nil then return end

    local originalBadgePos = self:getElementOriginalPosition(badgeEl)
    if originalBadgePos == nil then return end

    local badgeSize = GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx %dpx",
        RealisticCropRotationFrame.GROUP_BADGE_W,
        RealisticCropRotationFrame.GROUP_BADGE_H
    ))
    local badgePos = {
        badgeX or originalBadgePos[1],
        originalBadgePos[2],
    }
    local iconSize = GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx %dpx",
        RealisticCropRotationFrame.GROUP_ICON_W,
        RealisticCropRotationFrame.GROUP_ICON_H
    ))
    local gapSize = GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx 0px",
        RealisticCropRotationFrame.GROUP_ICON_TEXT_GAP
    ))
    local paddingSize = GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx 0px",
        RealisticCropRotationFrame.GROUP_BADGE_PADDING_X
    ))

    local textWidth = self:getTextRenderWidth(labelEl, displayText)
    if textWidth == nil then return end

    local badgeWidth = math.min(
        badgeSize[1],
        math.max(iconSize[1] + gapSize[1] + paddingSize[1], iconSize[1] + gapSize[1] + textWidth + paddingSize[1])
    )
    local textBoxWidth = math.max(0, badgeWidth - iconSize[1] - gapSize[1] - paddingSize[1])
    local renderedTextWidth = math.min(textWidth, textBoxWidth)
    local totalWidth = iconSize[1] + gapSize[1] + renderedTextWidth
    local startX = badgePos[1] + (badgeWidth - totalWidth) * 0.5

    local iconYpx = RealisticCropRotationFrame.GROUP_BADGE_Y
        + math.floor((RealisticCropRotationFrame.GROUP_BADGE_H - RealisticCropRotationFrame.GROUP_ICON_H) * 0.5)
    local iconPosY = GuiUtils.getNormalizedScreenValues(string.format("0px -%dpx", iconYpx))[2]

    if badgeEl ~= nil and badgeEl.setPosition ~= nil and badgeEl.setSize ~= nil then
        badgeEl:setPosition(badgePos[1], badgePos[2])
        badgeEl:setSize(badgeWidth, badgeSize[2])
    end
    if yearLabelEl ~= nil and yearLabelEl.setPosition ~= nil and yearLabelEl.setSize ~= nil then
        yearLabelEl:setPosition(badgePos[1], yearLabelEl.position[2])
        yearLabelEl:setSize(badgeWidth, yearLabelEl.size[2])
    end

    iconEl:setPosition(startX, iconPosY)
    labelEl:setPosition(startX + iconSize[1] + gapSize[1], badgePos[2])
    if labelEl.setSize ~= nil then
        labelEl:setSize(textBoxWidth, badgeSize[2])
    end
    if labelEl.setText ~= nil then
        labelEl:setText(displayText or "")
    end

    return badgeWidth
end

function RealisticCropRotationFrame:getGroupConnectorGaps(cell, slotIndex)
    if cell == nil or cell.getAttribute == nil then return 0, 0 end

    local badgeEl = cell:getAttribute("gBadge" .. slotIndex)
    local arrowEl = cell:getAttribute("gArrow" .. slotIndex)
    local nextBadgeEl = cell:getAttribute("gBadge" .. tostring(slotIndex + 1))
    local badgePos = self:getElementOriginalPosition(badgeEl)
    local arrowPos = self:getElementOriginalPosition(arrowEl)
    local nextBadgePos = self:getElementOriginalPosition(nextBadgeEl)
    local badgeSize = self:getElementOriginalSize(badgeEl)
    local arrowSize = self:getElementOriginalSize(arrowEl)

    if badgePos == nil or arrowPos == nil or nextBadgePos == nil
        or badgeSize == nil or arrowSize == nil then
        return 0, 0
    end

    local gapBeforeArrow = math.max(0, arrowPos[1] - (badgePos[1] + badgeSize[1]))
    local gapAfterArrow = math.max(0, nextBadgePos[1] - (arrowPos[1] + arrowSize[1]))
    return gapBeforeArrow, gapAfterArrow
end

function RealisticCropRotationFrame:layoutGroupRow(cell, group)
    if cell == nil or cell.getAttribute == nil or group == nil then return end

    local currentX = nil
    for i = 1, 4 do
        local cropName = group.plan[i] or ""
        local isFilled = cropName ~= ""

        if isFilled then
            local badgeEl = cell:getAttribute("gBadge" .. i)
            local originalBadgePos = self:getElementOriginalPosition(badgeEl)
            currentX = currentX or (originalBadgePos ~= nil and originalBadgePos[1] or nil)

            local gapBeforeArrow, gapAfterArrow = 0, 0
            if i < 4 then
                gapBeforeArrow, gapAfterArrow = self:getGroupConnectorGaps(cell, i)
            end

            local displayName = self:getCropDisplayName(cropName)
            local badgeWidth = self:layoutGroupBadgeContent(cell, i, displayName, currentX)

            if badgeWidth ~= nil and currentX ~= nil and i < 4 then
                local nextFilled = (group.plan[i + 1] or "") ~= ""
                local arrowEl = cell:getAttribute("gArrow" .. i)
                if arrowEl ~= nil then
                    arrowEl:setVisible(nextFilled)
                    if nextFilled then
                        local arrowPos = self:getElementOriginalPosition(arrowEl)
                        local arrowSize = self:getElementOriginalSize(arrowEl)
                        if arrowPos ~= nil and arrowSize ~= nil then
                            local arrowX = currentX + badgeWidth + gapBeforeArrow
                            arrowEl:setPosition(arrowX, arrowPos[2])
                            currentX = arrowX + arrowSize[1] + gapAfterArrow
                        else
                            currentX = nil
                        end
                    else
                        currentX = nil
                    end
                else
                    currentX = nil
                end
            else
                currentX = nil
            end
        else
            currentX = nil
            local arrowEl = cell:getAttribute("gArrow" .. i)
            if arrowEl ~= nil then
                arrowEl:setVisible(false)
            end
        end
    end
end

function RealisticCropRotationFrame:populateGroupCell(index, cell)
    if cell == nil or cell.getAttribute == nil then return end
    local group = (self.rotationGroups or {})[index]
    if group == nil then return end
    local isEmptyGroup = group.key == "|||"

    local summaryEl = cell:getAttribute("gPlanSummary")
    if summaryEl ~= nil then
        summaryEl:setVisible(isEmptyGroup)
        if isEmptyGroup then
            summaryEl:setText(self.i18n:getText("rcr_plan_none"))
        end
    end

    -- 4 crop zones: badge bg + icon + crop name label
    for i = 1, 4 do
        local cropName = group.plan[i] or ""
        local family   = self:getCropFamily(cropName)
        local show     = cropName ~= ""

        local badgeEl = cell:getAttribute("gBadge" .. i)
        if badgeEl ~= nil then
            badgeEl:setVisible(show)
            if show then
                local c = RealisticCropRotationFrame.FAMILY_RGBA[family] or {0.20, 0.20, 0.20, 0.60}
                badgeEl.color = {c[1], c[2], c[3], 0.55}
            end
        end

        local iconEl = cell:getAttribute("gCropIcon" .. i)
        if iconEl ~= nil then
            self:applySlotCropIcon(iconEl, cropName)
        end

        local labelEl = cell:getAttribute("gLabel" .. i)
        if labelEl ~= nil then
            labelEl:setVisible(show)
            if show then
                local displayName = self:getCropDisplayName(cropName)
                labelEl:setText(displayName)
            end
        end

        local yearLabelEl = cell:getAttribute("gYearLabel" .. i)
        if yearLabelEl ~= nil then yearLabelEl:setVisible(show and not isEmptyGroup) end
    end

    self:layoutGroupRow(cell, group)

    -- Count
    local countEl = cell:getAttribute("gCount")
    if countEl ~= nil then
        countEl:setText("x " .. #group.fieldNames)
    end
    local areaEl = cell:getAttribute("gArea")
    if areaEl ~= nil then
        areaEl:setText(self:formatAreaHa(group.areaHa))
    end

    -- Score label
    local scoreEl = cell:getAttribute("gScore")
    if scoreEl ~= nil then
        local scoreLabelKey, r, g, b = self:getScoreLabel(group.score)
        local scoreLabel = scoreLabelKey ~= nil and self.i18n:getText(scoreLabelKey) or ""
        scoreEl:setText(scoreLabel)
        if scoreEl.setVisible ~= nil then scoreEl:setVisible(scoreLabel ~= "") end
        scoreEl.textColor = {r, g, b, 1.0}
    end

    -- Field names — bottom strip, uses TextElement scrolling for long lists.
    local namesEl = cell:getAttribute("gFieldNames")
    if namesEl ~= nil then
        namesEl:setText(self:getCompactGroupFieldNames(group.fieldNames))
    end
end
