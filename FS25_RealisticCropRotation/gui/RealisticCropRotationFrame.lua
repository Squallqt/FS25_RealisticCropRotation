-- Copyright © 2026 Squallqt. All rights reserved.
-- In-game menu page: rotation history, planning calendar, agronomy/disease panels and the fields overview.
RealisticCropRotationFrame = {}
local RealisticCropRotationFrame_mt = Class(RealisticCropRotationFrame, TabbedMenuFrameElement)
local PlannerModel = RealisticCropRotationPlannerModel

RealisticCropRotationFrame.TAB = { HISTORY = 1, PLANNING = 2 }
RealisticCropRotationFrame.DETAIL_REFRESH_INTERVAL_MS = 5000
RealisticCropRotationFrame.HERO_PILL_MIN_W_PX = 96
RealisticCropRotationFrame.HERO_PILL_MAX_W_PX = 420
RealisticCropRotationFrame.HERO_PILL_TEXT_PADDING_PX = 24
RealisticCropRotationFrame.HERO_TITLE_PILL_GAP_PX = 24
local function isFallowCrop(cropName)
    return RealisticCropRotation.isFallowCrop(cropName)
end

local function getFamilyTextKey(family)
    if family == "COVER" then return "rcr_cover_crop" end
    if family == "FALLOW" then return "rcr_fallow" end
    return "rcr_family_" .. string.lower(family)
end

-- Advice follows the current timeline card; COVER never drives a recommendation (not a main crop).
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
    FALLOW    = {0.20, 0.20, 0.20, 0.60},    -- neutral, no crop/cover implication
}

RealisticCropRotationFrame.FAMILY_MIN_INTERVAL = {
    CEREAL    = 2,
    OILSEED   = 3,
    LEGUME    = 3,
    VEGETABLE = 3,
    ROOT      = 4,
}

RealisticCropRotationFrame.SCORE_BASE_FULL    = 85  -- 3+ crops: a real rotation pattern
RealisticCropRotationFrame.SCORE_BASE_PARTIAL = 55  -- only 2 crops
RealisticCropRotationFrame.SCORE_FAMILY_PENALTY_PER_YEAR = 20
RealisticCropRotationFrame.SCORE_LEGUME_CEREAL_BONUS = 8
RealisticCropRotationFrame.SCORE_SOWING_ALTERNATION_BONUS = 10 -- winter and spring sowings in the same cycle
RealisticCropRotationFrame.SCORE_RESIDUE_BONUS = 10  -- N-restoring crop/cover present
RealisticCropRotationFrame.SCORE_MONOCULTURE_CAP = 30 -- single-family plan: not a rotation, stays "poor"
RealisticCropRotationFrame.SCORE_DISEASE_PENALTY_PER_YEAR = 10 -- shared-pathogen spacing

-- Gap between a soil row's title and its gauge track.
RealisticCropRotationFrame.SOIL_ROW_TITLE_GAP_PX = 16

-- Global overview crop badge layout, in pixels, converted at runtime.
RealisticCropRotationFrame.GROUP_BADGE_Y          = 16.5
RealisticCropRotationFrame.GROUP_BADGE_H          = 26
RealisticCropRotationFrame.GROUP_ICON_W           = 20
RealisticCropRotationFrame.GROUP_ICON_H           = 20
RealisticCropRotationFrame.GROUP_ICON_TEXT_GAP    = 5
RealisticCropRotationFrame.GROUP_BADGE_PADDING_X  = 10
RealisticCropRotationFrame.GROUP_BADGE_TEXT_SAFETY_PX = 10

-- History timeline geometry (pixels; converted at runtime). 5 slot cards of 224px joined by 25px connectors.
RealisticCropRotationFrame.TIMELINE_SLOT_COUNT     = 5
RealisticCropRotationFrame.TIMELINE_CARD_W_PX      = 224
RealisticCropRotationFrame.TIMELINE_CONNECTOR_W_PX = 25

-- Annual calendar layout in pixels. The XML container is 1240 x 238 px.
RealisticCropRotationFrame.CALENDAR_AXIS_X = 94
RealisticCropRotationFrame.CALENDAR_AXIS_W = 1130
RealisticCropRotationFrame.CALENDAR_GRID_H = 188
-- Season boundary: every 3rd grid line (indices 1,4,7,10,13) is drawn thick to mark a season start.
RealisticCropRotationFrame.CALENDAR_SEASON_LEN     = 3
RealisticCropRotationFrame.CALENDAR_GRID_W_THIN    = 1
RealisticCropRotationFrame.CALENDAR_GRID_W_THICK   = 2

RealisticCropRotationFrame.CALENDAR_MONTH_KEYS = {
    "rcr_calendar_month_1",
    "rcr_calendar_month_2",
    "rcr_calendar_month_3",
    "rcr_calendar_month_4",
    "rcr_calendar_month_5",
    "rcr_calendar_month_6",
    "rcr_calendar_month_7",
    "rcr_calendar_month_8",
    "rcr_calendar_month_9",
    "rcr_calendar_month_10",
    "rcr_calendar_month_11",
    "rcr_calendar_month_12",
}

---Creates the menu frame element.
-- @param table i18n
-- @param table messageCenter
-- @return RealisticCropRotationFrame instance
function RealisticCropRotationFrame.new(i18n, messageCenter)
    local self = RealisticCropRotationFrame:superClass().new(nil, RealisticCropRotationFrame_mt)
    self.hasCustomMenuButtons = true
    self.name          = "RealisticCropRotationFrame"
    self.i18n          = i18n or g_i18n
    self.messageCenter = messageCenter or g_messageCenter
    self.farmlandList  = {}
    self.selectedId    = nil
    self.planCropList  = {""}  -- index 1 = no crop; populated in initialize()
    self.coverCropList = {""}  -- index 1 = no cover; populated in initialize()
    self.rotationGroups = {}   -- rebuilt when plans change
    self.calendarEditSlotIdx = 1
    self.calendarLocalPlan = {"", "", "", ""}
    self.calendarLocalCoverPlan = {"", "", "", ""}
    self.totalAreaHa   = 0
    self.isSubscribedToFarmlandChanges = false
    self.weatherCard = nil
    self.refreshTimerMs = 0
    self.isMenuOpen = false
    return self
end

---Copies frame attributes from a cloned source element.
-- @param table src
function RealisticCropRotationFrame:copyAttributes(src)
    RealisticCropRotationFrame:superClass().copyAttributes(self, src)
    self.i18n          = src.i18n
    self.messageCenter = src.messageCenter
    self.totalAreaHa   = src.totalAreaHa or 0
    self.isSubscribedToFarmlandChanges = false
    self.weatherCard = nil
    self.refreshTimerMs = 0
    self.isMenuOpen = false
end

function RealisticCropRotationFrame:delete()
    self:unsubscribeFarmlandChanges()
    self.farmlandList = nil
    self.rotationGroups = nil
    self.planCropList = nil
    self.coverCropList = nil
    self.calendarLocalPlan = nil
    self.calendarLocalCoverPlan = nil
    self.selectedId = nil
    self.weatherCard = nil
    self.isMenuOpen = false
    RealisticCropRotationFrame:superClass().delete(self)
end

function RealisticCropRotationFrame:onGuiSetupFinished()
    RealisticCropRotationFrame:superClass().onGuiSetupFinished(self)
    self.listFields:setDataSource(self)
    self.listFields:setDelegate(self)
    self.listPlanOverview:setDataSource(self)
    self.listPlanOverview:setDelegate(self)

    if self.weatherCard == nil then
        self.weatherCard = RealisticCropRotationWeatherCard.new(self, self.i18n)
        self.weatherCard:bind({
            root = self.headerWeatherPill,
            shadow = self.headerWeatherShadow,
            background = self.headerWeatherBg,
            accent = self.headerWeatherAccent,
            accentBottom = self.headerWeatherAccentBottom,
            iconBackground = self.headerWeatherIconBg,
            icon = self.headerWeatherIcon,
            condition = self.headerWeatherText,
            divider = self.headerWeatherDivider,
            window = self.headerWeatherWindow,
            status = self.headerWeatherStatus,
            menuHeaderTitle = self.menuHeaderTitle,
            menuHeaderIconBg = self.menuHeaderIconBg,
        })
    end

    self:setupSectionLines()
end

function RealisticCropRotationFrame:setupSectionLines()
    self:layoutSectionLine(self.historySectionLine, self.historySectionTitle)
    self:layoutSectionLine(self.adviceSectionLine, self.adviceSectionTitle)
    self:layoutSectionLine(self.soilSectionLine, self.soilSectionTitle)
    self:layoutSectionLine(self.fieldSectionLine, self.fieldSectionTitle)
    self:layoutSectionLine(self.planSectionLine, self.planSectionTitle)
    self:layoutSectionLine(self.scoreSectionLine, self.scoreSectionTitle)
    self:layoutOverviewSectionHeader()
end

function RealisticCropRotationFrame:initialize()
    RealisticCropRotationFrame:superClass().initialize(self)

    self.viewSelector:setTexts({
        self.i18n:getText("rcr_sidebar_fields"),
        self.i18n:getText("rcr_sidebar_fields"),
    })
    self.viewSelector:setState(RealisticCropRotationFrame.TAB.HISTORY, false)

    for i = 1, #self.viewSelectorDotBox.elements do
        local idx = i
        self.viewSelectorDotBox.elements[i].getIsSelected = function()
            return self.viewSelector:getState() == idx
        end
    end
    self.viewSelectorDotBox:invalidateLayout()

    self:buildPlanCropList()
    self:layoutCalendarLegend()
end

function RealisticCropRotationFrame:onFrameOpen()
    RealisticCropRotationFrame:superClass().onFrameOpen(self)
    self.isMenuOpen = true
    self.refreshTimerMs = 0
    self:subscribeFarmlandChanges()
    self:setupOverviewCoverLegend()
    self:populateSidebar()
    self:setMenuButtonInfoDirty()
    RealisticCropRotation.requestMenuReconcile(self.selectedId)
    if FocusManager ~= nil and self.listFields:getItemCount() > 0 then
        FocusManager:setFocus(self.listFields)
    end
end

function RealisticCropRotationFrame:onFrameClose()
    self.isMenuOpen = false
    self:unsubscribeFarmlandChanges()
    RealisticCropRotationFrame:superClass().onFrameClose(self)
end

---Refreshes the selected panel immediately after its authoritative reconciliation.
-- @param integer farmlandId Reconciled farmland
function RealisticCropRotationFrame:onMenuReconcileFarmland(farmlandId)
    if not self.isMenuOpen or tonumber(farmlandId) ~= tonumber(self.selectedId) then return end
    if self:isHistoryTab() then
        local selectedIndex = self.listFields:getSelectedIndexInSection()
        local selectedCell = self.listFields:getElementAtSectionIndex(1, selectedIndex)
        if selectedCell ~= nil then
            self:populateCellForItemInSection(self.listFields, 1, selectedIndex, selectedCell)
        end
        self:updateDetailPanel(self.selectedId)
    else
        self:updatePlanningPanel(self.selectedId)
    end
end

---Reloads stored sidebar rows after a reconcile batch changed repository state.
-- @param boolean changed True when at least one farmland changed
-- @param boolean fullBatch True when the full farmland batch completed
function RealisticCropRotationFrame:onMenuReconcileComplete(changed, fullBatch)
    if not self.isMenuOpen or not changed or not fullBatch then return end
    self.listFields:reloadData()
end

---Keeps the weather card and the history detail panel synchronized while this menu frame is active.
-- @param integer dt Frame delta in milliseconds
function RealisticCropRotationFrame:update(dt)
    local superClass = RealisticCropRotationFrame:superClass()
    if superClass.update ~= nil then
        superClass.update(self, dt)
    end

    self.refreshTimerMs = self.refreshTimerMs + dt
    if self.refreshTimerMs < RealisticCropRotationFrame.DETAIL_REFRESH_INTERVAL_MS then return end
    self.refreshTimerMs = 0

    if self.weatherCard ~= nil then
        self.weatherCard:refresh(false)
    end
    if self.selectedId ~= nil and self:isHistoryTab() then
        RealisticCropRotation.requestMenuReconcile(self.selectedId, true)
        self:updateDetailPanel(self.selectedId)
    end
end

function RealisticCropRotationFrame:inputEvent(action, value, eventUsed)
    value = value or 0

    if not eventUsed and FocusManager:hasFocus(self.listFields)
        and action == InputAction.MENU_AXIS_UP_DOWN
        and value > g_analogStickVTolerance
        and self.listFields:getSelectedIndexInSection() <= 1 then

        if not FocusManager:isFocusInputLocked(action, value) then
            FocusManager:lockFocusInput(action, 250, value)
            FocusManager:setFocus(self.viewSelector, FocusManager.TOP)
        end
        return true
    end

    if not eventUsed and FocusManager:hasFocus(self.viewSelector)
        and action == InputAction.MENU_AXIS_UP_DOWN
        and value < -g_analogStickVTolerance then

        if not FocusManager:isFocusInputLocked(action, value) then
            FocusManager:lockFocusInput(action, 250, value)
            FocusManager:setFocus(self.listFields, FocusManager.BOTTOM)
        end
        return true
    end

    return RealisticCropRotationFrame:superClass().inputEvent(self, action, value, eventUsed)
end

---Returns the menu button info: back + page nav always, plus "Clear plan" while Planning is active.
-- @return table buttons
function RealisticCropRotationFrame:getMenuButtonInfo()
    local buttons = {
        { inputAction = InputAction.MENU_BACK },
        { inputAction = InputAction.MENU_PAGE_PREV },
        { inputAction = InputAction.MENU_PAGE_NEXT },
    }
    if not self:isHistoryTab() and self.selectedId ~= nil then
        table.insert(buttons, {
            text = self.i18n:getText("rcr_clear_plan_button"),
            inputAction = InputAction.MENU_CANCEL,
            callback = function() self:onClickClearPlan() end,
        })
    end
    return buttons
end

---Returns the rotation manager from the current mission.
-- @return RealisticCropRotationManager manager
function RealisticCropRotationFrame:getManager()
    return g_currentMission.realisticCropRotationManager
end

---Returns the authoritative active crop stored by the repository.
-- @param integer farmlandId
-- @return string cropName, or nil
-- @return integer fruitTypeIndex, or nil
function RealisticCropRotationFrame:getActiveCropInfoForDisplay(farmlandId)
    local mgr = self:getManager()
    local cropName = mgr.repository:getLastKnownActiveCrop(farmlandId)
    local fruitType = cropName ~= nil and cropName ~= ""
        and g_fruitTypeManager ~= nil
        and type(g_fruitTypeManager.getFruitTypeByName) == "function"
        and g_fruitTypeManager:getFruitTypeByName(tostring(cropName)) or nil
    if fruitType ~= nil and fruitType.shownOnMap == false then
        return nil, nil
    end
    return cropName, fruitType ~= nil and fruitType.index or nil
end

---Updates the detail-tab residue pill: crop residue (n1/n2) or catch-crop cover residue, in kg/ha.
-- @param table pillBg
-- @param table pillText
-- @param integer farmlandId
-- @return number width Resized pill width
function RealisticCropRotationFrame:updateResiduePill(pillBg, pillText, farmlandId)
    local text = self.i18n:getText("rcr_status_current_no_residue")
    local hasBonus = false

    local service = self:getManager().service
    local activeCropName, activeFruitTypeIndex = self:getActiveCropInfoForDisplay(farmlandId)
    if activeCropName ~= nil and activeCropName ~= "" and not isFallowCrop(activeCropName) then
        local normalizedCropName = string.upper(tostring(activeCropName))
        local entry = service:getResidueEntry(normalizedCropName)
        if entry ~= nil and ((tonumber(entry.n1) or 0) + (tonumber(entry.n2) or 0)) > 0 then
            local n1Kg = math.floor((service:getNitrogenKgPerHaFromStateChange(tonumber(entry.n1) or 0) or 0) + 0.5)
            local n2Kg = math.floor((service:getNitrogenKgPerHaFromStateChange(tonumber(entry.n2) or 0) or 0) + 0.5)
            text = string.format(self.i18n:getText("rcr_status_current_residue"), n1Kg, n2Kg)
            hasBonus = true
        elseif service:isCoverCropForRotationHistory(activeFruitTypeIndex, normalizedCropName) then
            local coverResidueKg = RealisticCropRotationService ~= nil
                and tonumber(RealisticCropRotationService.COVER_CROP_RESIDUE_KG_HA) or 0
            if coverResidueKg > 0 then
                text = string.format(
                    self.i18n:getText("rcr_status_current_residue"),
                    math.floor(coverResidueKg + 0.5),
                    0
                )
                hasBonus = true
            end
        end
    end

    pillBg:applyProfile(hasBonus and "frStatusPillBgBonus" or "frStatusPillBg")
    pillText:setText(text)
    return self:resizeHeroPillToText(pillBg, pillText, text)
end

---Total planned N residue (kg/ha) from a plan's crops + cover crops.
-- @param table plan 4-slot crop plan
-- @param table coverPlan 4-slot cover plan
-- @return number residueKgHa, or nil when none
function RealisticCropRotationFrame:getPlanNitrogenResidueKgHa(plan, coverPlan)
    local service = self:getManager().service
    local cycleLength, hasInternalGap = PlannerModel.getCycleInfo(plan, 4)
    if hasInternalGap then return nil end
    local totalStateChange = 0
    for i = 1, cycleLength do
        local cropName = plan ~= nil and plan[i] or nil
        if cropName ~= nil and cropName ~= "" and not isFallowCrop(cropName) then
            local entry = service:getResidueEntry(string.upper(tostring(cropName)))
            if entry ~= nil then
                totalStateChange = totalStateChange + (tonumber(entry.n1) or 0) + (tonumber(entry.n2) or 0)
            end
        end
    end

    local residueKgHa = 0
    if totalStateChange > 0 then
        local ok, fromState = pcall(
            service.getNitrogenKgPerHaFromStateChange,
            service,
            totalStateChange
        )
        if ok and type(fromState) == "number" and fromState > 0 then
            residueKgHa = residueKgHa + fromState
        end
    end

    local ok, coverResidueKgHa = pcall(
        service.getCoverResidueKgHa,
        service,
        coverPlan,
        cycleLength)
    if ok and type(coverResidueKgHa) == "number" and coverResidueKgHa > 0 then
        residueKgHa = residueKgHa + coverResidueKgHa
    end

    if residueKgHa <= 0 then return nil end
    return residueKgHa
end

---Localized planned-residue label for a plan, or nil when there is none.
-- @param table plan
-- @param table coverPlan
-- @return string text, or nil
function RealisticCropRotationFrame:getPlanNitrogenResidueText(plan, coverPlan)
    local residueKgHa = self:getPlanNitrogenResidueKgHa(plan, coverPlan)
    if residueKgHa == nil then return nil end
    return string.format(self.i18n:getText("rcr_status_planned_residue"), math.floor(residueKgHa + 0.5))
end

---Updates the planned-residue pill (planning tab) and resizes it.
-- @param table pillBg
-- @param table pillText
-- @param table plan
-- @param table coverPlan
-- @return number width Resized pill width
function RealisticCropRotationFrame:updatePlannedResiduePill(pillBg, pillText, plan, coverPlan)
    local residueText = self:getPlanNitrogenResidueText(plan, coverPlan)
    local hasBonus = residueText ~= nil
    local text = hasBonus and residueText or self.i18n:getText("rcr_status_planned_no_residue")
    pillBg:applyProfile(hasBonus and "frStatusPillBgBonus" or "frStatusPillBg")
    pillText:setText(text)
    return self:resizeHeroPillToText(pillBg, pillText, text)
end

---Returns a crop's family from cropConfig.xml.
-- @param string cropName
-- @return string family, or "UNKNOWN"
function RealisticCropRotationFrame:getCropFamily(cropName)
    if cropName == nil or cropName == "" then return "UNKNOWN" end
    if isFallowCrop(cropName) then
        return "FALLOW"
    end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.families == nil then return "UNKNOWN" end
    return config.families[string.upper(cropName)] or "UNKNOWN"
end

---Returns the set of shared-pathogen groups a crop hosts (from cropConfig.xml).
-- @param string cropName
-- @return table set group->true (empty when none)
function RealisticCropRotationFrame:getCropDiseases(cropName)
    if cropName == nil or cropName == "" then return {} end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.diseases == nil then return {} end
    return config.diseases[string.upper(cropName)] or {}
end

---Returns the fillType for a crop (title/icon source); nil when not harvestable.
-- @param string cropName
-- @return table fillType, or nil
function RealisticCropRotationFrame:getFillTypeForCrop(cropName)
    if cropName == nil or cropName == "" then return nil end
    if g_fillTypeManager == nil or g_fillTypeManager.getFillTypeByName == nil then return nil end
    return g_fillTypeManager:getFillTypeByName(string.upper(tostring(cropName)))
end

---Localized display name for a crop (fillType title, else fruitType, else capitalized).
-- @param string cropName
-- @return string displayName
function RealisticCropRotationFrame:getCropDisplayName(cropName)
    if cropName == nil or cropName == "" then return "" end
    local normalizedName = string.upper(tostring(cropName))
    if isFallowCrop(normalizedName) then
        return self.i18n:getText("rcr_fallow")
    end

    local fillType = self:getFillTypeForCrop(normalizedName)
    if fillType ~= nil and fillType.title ~= nil and fillType.title ~= "" then
        return fillType.title
    end

    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil then
        local fruitType = g_fruitTypeManager:getFruitTypeByName(normalizedName)
        if fruitType ~= nil and fruitType.fillType ~= nil and fruitType.fillType.title ~= nil
            and fruitType.fillType.title ~= "" then
            return fruitType.fillType.title
        end
    end

    return normalizedName:sub(1, 1) .. string.lower(normalizedName:sub(2))
end

---Returns the owned-farmland rows from the manager.
-- @return table rows
function RealisticCropRotationFrame:buildFarmlandList()
    return self:getManager():getOwnedFarmlands() or {}
end

---Formats a hectare value as "X.XX ha".
-- @param number areaHa
-- @return string text
function RealisticCropRotationFrame:formatAreaHa(areaHa)
    return string.format("%.2f ha", tonumber(areaHa) or 0)
end

---True when the game's colour-blind mode is enabled.
-- @return boolean
function RealisticCropRotationFrame:getIsColorBlindMode()
    if g_gameSettings == nil or GameSettings == nil
        or GameSettings.SETTING == nil
        or GameSettings.SETTING.USE_COLORBLIND_MODE == nil
        or type(g_gameSettings.getValue) ~= "function" then
        return false
    end

    return g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE) == true
end

---Copies a GUI colour (Color object or array) to a plain { r, g, b, a } table.
-- @param table color
-- @return table rgba, or nil
function RealisticCropRotationFrame:copyGuiColor(color)
    if color == nil then return nil end

    local r, g, b, a
    if type(color) == "table" and type(color.unpack) == "function" then
        r, g, b, a = color:unpack()
    elseif type(color) == "table" then
        r, g, b, a = color[1], color[2], color[3], color[4]
    end

    if r == nil or g == nil or b == nil then return nil end
    return { r, g, b, a or 1 }
end

---Returns the map colour for a fruit type (colour-blind aware).
-- @param table fruitType
-- @return table rgba, or nil
function RealisticCropRotationFrame:getFruitTypeMapColor(fruitType)
    if fruitType == nil then return nil end

    local color = self:getIsColorBlindMode()
        and fruitType.colorBlindMapColor
        or fruitType.defaultMapColor

    return self:copyGuiColor(color)
end

---Returns the native map colour for a ground state (colour-blind aware).
-- @param integer groundStateIndex GROWTH_STATE_INDEX
-- @return table rgba, or nil
function RealisticCropRotationFrame:getGroundStateMapColor(groundStateIndex)
    if groundStateIndex == nil or MapOverlayGenerator == nil
        or MapOverlayGenerator.GROWTH_STATE_INDEX == nil then
        return nil
    end

    local indices = MapOverlayGenerator.GROWTH_STATE_INDEX
    local colorByMode = nil

    if groundStateIndex == indices.CULTIVATED then
        colorByMode = MapOverlayGenerator.FRUIT_COLOR_CULTIVATED
    elseif groundStateIndex == indices.PLOWED then
        colorByMode = MapOverlayGenerator.FRUIT_COLOR_PLOWED
    elseif groundStateIndex == indices.SEEDBED then
        colorByMode = MapOverlayGenerator.FRUIT_COLOR_SEEDBED
    elseif groundStateIndex == indices.STUBBLE_TILLAGE then
        colorByMode = MapOverlayGenerator.FRUIT_COLOR_STUBBLE_TILLAGE
    end

    if colorByMode == nil then return nil end
    return self:copyGuiColor(colorByMode[self:getIsColorBlindMode()])
end

---Returns the native map colour for a soil state (colour-blind aware).
-- @param integer soilStateIndex SOIL_STATE_INDEX
-- @return table rgba, or nil
function RealisticCropRotationFrame:getSoilStateMapColor(soilStateIndex)
    if soilStateIndex == nil or MapOverlayGenerator == nil
        or MapOverlayGenerator.SOIL_STATE_INDEX == nil then
        return nil
    end

    local indices = MapOverlayGenerator.SOIL_STATE_INDEX
    local colorByMode = nil

    if soilStateIndex == indices.NEEDS_PLOWING then
        colorByMode = MapOverlayGenerator.FRUIT_COLOR_NEEDS_PLOWING
    elseif soilStateIndex == indices.NEEDS_ROLLING then
        colorByMode = MapOverlayGenerator.FRUIT_COLOR_NEEDS_ROLLING
    elseif soilStateIndex == indices.MULCHED then
        colorByMode = MapOverlayGenerator.FRUIT_COLOR_MULCHED
    elseif soilStateIndex == indices.WATERED then
        colorByMode = MapOverlayGenerator.FRUIT_COLOR_WATERED
    end

    if colorByMode == nil then return nil end
    return self:copyGuiColor(colorByMode[self:getIsColorBlindMode()])
end

---Sets all colour states of an icon element and makes it visible.
-- @param table element
-- @param table color RGBA
function RealisticCropRotationFrame:applyIconBackgroundColor(element, color)
    if element == nil or color == nil then return end

    local guiColor = { color[1], color[2], color[3], color[4] or 1 }
    element.color = guiColor
    element.colorSelected = { guiColor[1], guiColor[2], guiColor[3], guiColor[4] }
    element.colorFocused = { guiColor[1], guiColor[2], guiColor[3], guiColor[4] }
    element.colorHighlighted = { guiColor[1], guiColor[2], guiColor[3], guiColor[4] }
    element.colorPressed = { guiColor[1], guiColor[2], guiColor[3], guiColor[4] }
    element:setVisible(true)
end

---Sums the hectares across a farmland list.
-- @param table farmlandList
-- @return number totalHa
function RealisticCropRotationFrame:calculateTotalAreaHa(farmlandList)
    local total = 0
    for _, entry in ipairs(farmlandList or {}) do
        total = total + (tonumber(entry.areaHa) or 0)
    end
    return total
end

function RealisticCropRotationFrame:updateOverviewTotalArea()
    local label = self.i18n:getText("rcr_overview_total_area")
    self.overviewTotalArea:setText(string.format(label, self.totalAreaHa or 0))
    self:layoutOverviewSectionHeader()
end

---Returns an element's first-seen size, caching it for later restores.
-- @param table element
-- @return table size { w, h }, or nil
function RealisticCropRotationFrame:getElementOriginalSize(element)
    if element == nil or element.size == nil then return nil end
    if element._frOriginalSize == nil then
        element._frOriginalSize = {element.size[1], element.size[2]}
    end
    return element._frOriginalSize
end

---Returns an element's first-seen position, caching it for later restores.
-- @param table element
-- @return table position { x, y }, or nil
function RealisticCropRotationFrame:getElementOriginalPosition(element)
    if element == nil or element.position == nil then return nil end
    if element._frOriginalPosition == nil then
        element._frOriginalPosition = {element.position[1], element.position[2]}
    end
    return element._frOriginalPosition
end

---Converts a pixel size to normalized screen units.
-- @param number wPx
-- @param number hPx
-- @return table size { w, h } normalized, or nil
function RealisticCropRotationFrame:getNormalizedPixelSize(wPx, hPx)
    if GuiUtils == nil or GuiUtils.getNormalizedScreenValues == nil then return nil end
    return GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx %dpx",
        math.floor((tonumber(wPx) or 0) + 0.5),
        math.floor((tonumber(hPx) or 0) + 0.5)
    ))
end

---Converts a pixel width to a normalized screen width.
-- @param number wPx
-- @return number width normalized
function RealisticCropRotationFrame:getNormalizedPixelWidth(wPx)
    local size = self:getNormalizedPixelSize(wPx, 0)
    return size ~= nil and size[1] or ((g_pixelSizeScaledX or g_pixelSizeX or 0) * (tonumber(wPx) or 0))
end

---Measures the rendered width of text in an element's font (normalized units).
-- @param table textElement
-- @param string text
-- @return number width, or nil
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

---Starts a soil gauge track after its title's rendered width (varies per language) and realigns the state label above it to the same left edge.
-- @param table titleElement
-- @param string titleText
-- @param table trackElement
-- @param table fillElement
-- @param table stateLabelElement
-- @param number alignWidth Width to align the track start to, or nil for this row's own title width
-- @return number trackWidth normalized, or nil
function RealisticCropRotationFrame:layoutSoilGaugeTrack(titleElement, titleText, trackElement, fillElement, stateLabelElement, alignWidth)
    local titlePos = self:getElementOriginalPosition(titleElement)
    local titleSize = self:getElementOriginalSize(titleElement)
    local trackPos = self:getElementOriginalPosition(trackElement)
    local trackSize = self:getElementOriginalSize(trackElement)
    if titlePos == nil or titleSize == nil or trackPos == nil or trackSize == nil then return nil end

    local textWidth = self:getTextRenderWidth(titleElement, titleText)
    if textWidth == nil then return nil end

    titleElement:setSize(textWidth, titleSize[2])

    local gap = self:getNormalizedPixelWidth(RealisticCropRotationFrame.SOIL_ROW_TITLE_GAP_PX)
    local newLeft = titlePos[1] + (alignWidth ~= nil and alignWidth or textWidth) + gap
    local rightEdge = trackPos[1] + trackSize[1]
    local newWidth = math.max(0, rightEdge - newLeft)

    trackElement:setPosition(newLeft, trackPos[2])
    trackElement:setSize(newWidth, trackSize[2])

    fillElement:setPosition(newLeft, trackPos[2])

    local statePos = self:getElementOriginalPosition(stateLabelElement)
    if statePos ~= nil then
        stateLabelElement:setPosition(newLeft, statePos[2])
    end

    return newWidth
end

---Resizes a pill (bg + text) to fit its text within padding/min/max bounds.
-- @param table pillBg
-- @param table pillText
-- @param string text
-- @param table options { paddingPx, minWidthPx, maxWidthPx, leftOffsetPx (icon zone reserved before text) }
-- @return number width, or nil
function RealisticCropRotationFrame:resizePillToText(pillBg, pillText, text, options)
    if pillBg == nil or pillText == nil then return end
    if pillBg.setSize == nil or pillText.setSize == nil then return end

    options = options or {}
    local bgSize = self:getElementOriginalSize(pillBg)
    local textSize = self:getElementOriginalSize(pillText)
    if bgSize == nil or textSize == nil then return end

    local textWidth = self:getTextRenderWidth(pillText, text)
    if textWidth == nil then return end

    local leftOffset = self:getNormalizedPixelWidth(options.leftOffsetPx or 0)
    local padding = self:getNormalizedPixelWidth(options.paddingPx or 20)
    local width = leftOffset + textWidth + padding
    if options.minWidthPx ~= nil then
        width = math.max(width, self:getNormalizedPixelWidth(options.minWidthPx))
    end
    if options.maxWidthPx ~= nil then
        width = math.min(width, self:getNormalizedPixelWidth(options.maxWidthPx))
    end

    pillBg:setSize(width, bgSize[2])
    pillText:setSize(width - leftOffset, textSize[2])

    if pillBg.parent ~= nil and pillBg.parent.invalidateLayout ~= nil then
        pillBg.parent:invalidateLayout()
    end

    return width
end

---Resizes a hero status pill using the hero padding/min/max constants.
-- @param table pillBg
-- @param table pillText
-- @param string text
-- @return number width, or nil
function RealisticCropRotationFrame:resizeHeroPillToText(pillBg, pillText, text)
    return self:resizePillToText(pillBg, pillText, text, {
        paddingPx = RealisticCropRotationFrame.HERO_PILL_TEXT_PADDING_PX,
        minWidthPx = RealisticCropRotationFrame.HERO_PILL_MIN_W_PX,
        maxWidthPx = RealisticCropRotationFrame.HERO_PILL_MAX_W_PX,
    })
end

---Starts a section header's trailing line after its title, stopping before an optional right-side sibling text.
-- @param table lineEl
-- @param table titleEl
-- @param table rightBoundaryEl Right-aligned sibling text the line must stop before, or nil
function RealisticCropRotationFrame:layoutSectionLine(lineEl, titleEl, rightBoundaryEl)
    local textWidth = self:getTextRenderWidth(titleEl, titleEl.text)
    if textWidth == nil then return end

    local parentAbsX = lineEl.parent.absPosition[1]
    local gap = self:getNormalizedPixelWidth(12)
    local rightInset = self:getNormalizedPixelWidth(26)
    local maxRightAbs = parentAbsX + lineEl.parent.absSize[1] - rightInset

    if rightBoundaryEl ~= nil then
        local rightTextWidth = self:getTextRenderWidth(rightBoundaryEl, rightBoundaryEl.text) or 0
        local boundaryRightEdge = rightBoundaryEl.absPosition[1] + rightBoundaryEl.absSize[1]
        maxRightAbs = math.min(maxRightAbs, boundaryRightEdge - rightTextWidth - gap)
    end

    local lineXAbs = titleEl.absPosition[1] + textWidth + gap
    local lineWidth = math.max(maxRightAbs - lineXAbs, 0)

    lineEl:setPosition(lineXAbs - parentAbsX, lineEl.position[2])
    lineEl:setSize(lineWidth, lineEl.size[2])
end

---Lays out the overview header with a centred cover-crop legend between two divider segments.
function RealisticCropRotationFrame:layoutOverviewSectionHeader()
    local leftLine = self.overviewSectionLine
    local rightLine = self.overviewSectionLineRight
    local titleEl = self.overviewSectionTitle
    local totalAreaEl = self.overviewTotalArea
    local legendBgEl = self.overviewCoverLegendIconBg
    local legendIconEl = self.overviewCoverLegendIcon
    local legendTextEl = self.overviewCoverLegendText
    if leftLine == nil or rightLine == nil or titleEl == nil or totalAreaEl == nil
        or legendBgEl == nil or legendIconEl == nil or legendTextEl == nil then
        return
    end

    local titleWidth = self:getTextRenderWidth(titleEl, titleEl.text)
    local legendTextWidth = self:getTextRenderWidth(legendTextEl, legendTextEl.text)
    if titleWidth == nil or legendTextWidth == nil then return end

    local parentAbsX = leftLine.parent.absPosition[1]
    local lineGap = self:getNormalizedPixelWidth(12)
    local legendGap = self:getNormalizedPixelWidth(6)
    local rightInset = self:getNormalizedPixelWidth(26)
    local lineStartAbs = titleEl.absPosition[1] + titleWidth + lineGap
    local maxRightAbs = parentAbsX + leftLine.parent.absSize[1] - rightInset
    local totalAreaTextWidth = self:getTextRenderWidth(totalAreaEl, totalAreaEl.text) or 0
    local totalAreaRightEdge = totalAreaEl.absPosition[1] + totalAreaEl.absSize[1]
    maxRightAbs = math.min(maxRightAbs, totalAreaRightEdge - totalAreaTextWidth - lineGap)

    local legendBgSize = self:getElementOriginalSize(legendBgEl)
    local legendBgPos = self:getElementOriginalPosition(legendBgEl)
    local legendIconPos = self:getElementOriginalPosition(legendIconEl)
    local legendTextPos = self:getElementOriginalPosition(legendTextEl)
    if legendBgSize == nil or legendBgPos == nil or legendIconPos == nil or legendTextPos == nil then return end

    local legendWidth = legendBgSize[1] + legendGap + legendTextWidth
    local availableWidth = math.max(0, maxRightAbs - lineStartAbs)
    local legendXAbs = lineStartAbs + math.max(0, (availableWidth - legendWidth) * 0.5)
    local leftLineWidth = math.max(0, legendXAbs - lineGap - lineStartAbs)
    local rightLineXAbs = legendXAbs + legendWidth + lineGap
    local rightLineWidth = math.max(0, maxRightAbs - rightLineXAbs)

    leftLine:setPosition(lineStartAbs - parentAbsX, leftLine.position[2])
    leftLine:setSize(leftLineWidth, leftLine.size[2])
    rightLine:setPosition(rightLineXAbs - parentAbsX, rightLine.position[2])
    rightLine:setSize(rightLineWidth, rightLine.size[2])

    local legendX = legendXAbs - parentAbsX
    legendBgEl:setPosition(legendX, legendBgPos[2])
    legendIconEl:setPosition(legendX, legendIconPos[2])
    legendTextEl:setPosition(legendX + legendBgSize[1] + legendGap, legendTextPos[2])
    legendTextEl:setSize(legendTextWidth, legendTextEl.size[2])
end

---Loads the first available configured cover crop as the overview legend sample.
function RealisticCropRotationFrame:setupOverviewCoverLegend()
    local iconBgEl = self.overviewCoverLegendIconBg
    local iconEl = self.overviewCoverLegendIcon
    if iconBgEl == nil or iconEl == nil then return end

    local coverName = self.coverCropList ~= nil and self.coverCropList[2] or nil
    local loaded = self:applySlotCropIcon(iconEl, coverName)
    iconBgEl:setVisible(false)
    if loaded and g_fruitTypeManager ~= nil
        and type(g_fruitTypeManager.getFruitTypeByName) == "function" then
        local fruitType = g_fruitTypeManager:getFruitTypeByName(string.upper(coverName))
        local nativeColor = self:getFruitTypeMapColor(fruitType)
        if nativeColor ~= nil then
            self:applyIconBackgroundColor(iconBgEl, nativeColor)
        end
    end

    self:layoutOverviewSectionHeader()
end

---Shrinks the hero title so it never runs under the status pill.
-- @param table titleElement
-- @param table statusPillBg
function RealisticCropRotationFrame:layoutHeroPills(titleElement, statusPillBg)
    local hero = titleElement.parent

    local heroSize = self:getElementOriginalSize(hero)
    if heroSize == nil then return end

    local gap = self:getNormalizedPixelWidth(RealisticCropRotationFrame.HERO_TITLE_PILL_GAP_PX)

    local statusLeft = heroSize[1] + statusPillBg.position[1] - statusPillBg.size[1]

    local titlePos = self:getElementOriginalPosition(titleElement)
    local titleSize = self:getElementOriginalSize(titleElement)
    if titlePos ~= nil and titleSize ~= nil then
        local titleLimit = math.min(heroSize[1], statusLeft)
        local titleWidth = math.max(0, titleLimit - titlePos[1] - gap)
        titleElement:setSize(titleWidth, titleSize[2])
    end
end

function RealisticCropRotationFrame:layoutCalendarLegend()
    local container = self.calendarLegend
    if GuiUtils == nil or GuiUtils.getNormalizedScreenValues == nil then return end

    local containerSize = self:getElementOriginalSize(container)
    if containerSize == nil then return end

    self.calendarLegendSwatchCover.color = RealisticCropRotationFrame.FAMILY_RGBA.COVER

    local SWATCH_PX = 14
    local TEXT_SWATCH_GAP_PX = 4
    local ITEM_GAP_PX = 16
    local SWATCH_Y_PX = 4

    local swatchSize  = GuiUtils.getNormalizedScreenValues(string.format("%dpx %dpx", SWATCH_PX, SWATCH_PX))
    local gapNorm     = GuiUtils.getNormalizedScreenValues(string.format("%dpx 0px", TEXT_SWATCH_GAP_PX))
    local itemGapNorm = GuiUtils.getNormalizedScreenValues(string.format("%dpx 0px", ITEM_GAP_PX))
    local swatchYNorm = GuiUtils.getNormalizedScreenValues(string.format("0px -%dpx", SWATCH_Y_PX))

    local swatchW = swatchSize[1]
    local swatchH = swatchSize[2]
    local gapW    = gapNorm[1]
    local itemGap = itemGapNorm[1]
    local swatchY = swatchYNorm[2]

    local items = {
        {label = self.calendarLegendLabelCover,   swatch = self.calendarLegendSwatchCover,   key = "rcr_calendar_legend_cover"},
        {label = self.calendarLegendLabelHarvest, swatch = self.calendarLegendSwatchHarvest, key = "rcr_calendar_legend_harvest"},
        {label = self.calendarLegendLabelSow,     swatch = self.calendarLegendSwatchSow,     key = "rcr_calendar_legend_sowing"},
    }

    -- Place legend items from right to left.
    local cursorX = containerSize[1]
    for _, item in ipairs(items) do
        local text = self.i18n:getText(item.key)
        item.label:setText(text)

        local textWidth = self:getTextRenderWidth(item.label, text) or 0
        local labelSize = self:getElementOriginalSize(item.label)
        local labelH = labelSize ~= nil and labelSize[2] or swatchH

        local swatchX = cursorX - swatchW
        local textX   = swatchX - gapW - textWidth

        item.swatch:setPosition(swatchX, swatchY)
        item.swatch:setSize(swatchW, swatchH)

        item.label:setPosition(textX, 0)
        item.label:setSize(textWidth, labelH)

        cursorX = textX - itemGap
    end
end

function RealisticCropRotationFrame:updateMainHeaderTitle()
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

---True when the history tab is the active sidebar view.
-- @return boolean
function RealisticCropRotationFrame:isHistoryTab()
    return self.viewSelector:getState() == RealisticCropRotationFrame.TAB.HISTORY
end

function RealisticCropRotationFrame:updateContainerVisibility()
    local hasFields = #(self.farmlandList or {}) > 0
    local isHistory = self:isHistoryTab()
    self.emptyText:setVisible(not hasFields)
    self.detailsContainer:setVisible(hasFields and isHistory)
    self.planningContainer:setVisible(hasFields and not isHistory)
    self:updateMainHeaderTitle()
    if self.weatherCard ~= nil then self.weatherCard:refresh(true) end
end

---Returns the 4-slot rotation plan for a farmland (empty plan as fallback).
-- @param integer farmlandId
-- @return table plan
function RealisticCropRotationFrame:getPlanForFarmland(farmlandId)
    return self:getManager():getRotationPlan(farmlandId)
end

---Returns the 4-slot cover plan for a farmland (empty plan as fallback).
-- @param integer farmlandId
-- @return table coverPlan
function RealisticCropRotationFrame:getCoverPlanForFarmland(farmlandId)
    return self:getManager():getRotationCoverPlan(farmlandId)
end

function RealisticCropRotationFrame:buildPlanCropList()
    self.planCropList = {""}  -- index 1 = no crop
    self.coverCropList = {""}
    if RealisticCropRotation ~= nil and RealisticCropRotation.SPECIAL_CROP_FALLOW ~= nil then
        table.insert(self.planCropList, RealisticCropRotation.SPECIAL_CROP_FALLOW)
    end

    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local coverCropNames = config ~= nil and config.coverCropNames or {}
    for _, cropName in ipairs(coverCropNames) do
        local available = g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil
            and g_fruitTypeManager:getFruitTypeByName(cropName) ~= nil
        if available then
            table.insert(self.coverCropList, cropName)
        end
    end

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
                    local family = self:getCropFamily(name)
                    if family ~= "UNKNOWN" and family ~= "COVER" then
                        if not nameSet[name] then
                            nameSet[name] = true
                            table.insert(self.planCropList, name)
                        end
                    end
                end
            end
        end
    end

    table.sort(self.planCropList, function(a, b)
        if a == "" then return true end
        if b == "" then return false end
        return self:getCropDisplayName(a) < self:getCropDisplayName(b)
    end)

    local cropTexts = {}
    for _, cropName in ipairs(self.planCropList) do
        table.insert(cropTexts, cropName == "" and self.i18n:getText("rcr_plan_none")
                                               or self:getCropDisplayName(cropName))
    end

    self.calendarEditCropSelector:setTexts(cropTexts)
    self.calendarEditCropSelector:setState(1, false)

    local coverTexts = {}
    for _, cropName in ipairs(self.coverCropList) do
        table.insert(coverTexts, cropName == "" and self.i18n:getText("rcr_plan_none")
                                                or self:getCropDisplayName(cropName))
    end

    self.calendarEditCoverSelector:setTexts(coverTexts)
    self.calendarEditCoverSelector:setState(1, false)
end

---Rebuilds the field list + overview, restoring the prior selection, and refreshes panels.
function RealisticCropRotationFrame:populateSidebar()
    local previousSelectedId = self.selectedId
    self.farmlandList = self:buildFarmlandList()
    self.totalAreaHa = self:calculateTotalAreaHa(self.farmlandList)
    self.selectedId = nil
    self.isRestoringSidebarSelection = true
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
        self.listFields:setSelectedItem(1, selectedIndex, true)
        self.selectedId = self.farmlandList[selectedIndex].farmlandId
    end
    self.isRestoringSidebarSelection = false
    if not self:isHistoryTab() then
        self:buildRotationGroups()
        self:updateOverviewTotalArea()
        self.listPlanOverview:reloadData()
    end
    self:updateContainerVisibility()
    if self:isHistoryTab() then
        self:updateDetailPanel(self.selectedId)
    else
        self:updatePlanningPanel(self.selectedId)
    end
end

---SmoothList data source: number of sections.
-- @return integer count
function RealisticCropRotationFrame:getNumberOfSections()
    return 1
end

---SmoothList data source: item count for a list/section.
-- @param table list
-- @param integer _section
-- @return integer count
function RealisticCropRotationFrame:getNumberOfItemsInSection(list, _section)
    if list == self.listPlanOverview then
        return #(self.rotationGroups or {})
    end
    return #(self.farmlandList or {})
end

---SmoothList data source: cell template id for an item.
-- @param table list
-- @param integer _section
-- @param integer _index
-- @return string cellType
function RealisticCropRotationFrame:getCellTypeForItemInSection(list, _section, _index)
    if list == self.listPlanOverview then return "groupRow" end
    return "field"
end

---SmoothList data source: section header title (none).
-- @param table _list
-- @param integer _section
-- @return string title, or nil
function RealisticCropRotationFrame:getTitleForSectionHeader(_list, _section)
    return nil
end

---SmoothList data source: section header height (none).
-- @param table _list
-- @param integer _section
-- @return number height
function RealisticCropRotationFrame:getSectionHeaderHeight(_list, _section)
    return 0
end

---SmoothList delegate: fills a cell for an item (group row or field row).
-- @param table list
-- @param integer _section
-- @param integer index
-- @param table cell
function RealisticCropRotationFrame:populateCellForItemInSection(list, _section, index, cell)
    if list == self.listPlanOverview then
        self:populateGroupCell(index, cell)
        return
    end

    if cell == nil or cell.getAttribute == nil then return end
    local entry = (self.farmlandList or {})[index]
    if entry == nil then return end

    local nameEl = cell:getAttribute("fieldName")
    local areaEl = cell:getAttribute("fieldArea")
    if nameEl ~= nil then nameEl:setText(string.upper(tostring(entry.name or ""))) end
    if areaEl ~= nil then areaEl:setText(self:formatAreaHa(entry.areaHa)) end

    -- Open immediately from the authoritative snapshot; live reconciliation runs across frames.
    local state = self:resolveCurrentFieldState(entry.farmlandId, false)

    local iconFruitType = nil
    if state.kind == "CROP" and state.cropName ~= nil and g_fruitTypeManager ~= nil
        and type(g_fruitTypeManager.getFruitTypeByName) == "function" then
        iconFruitType = g_fruitTypeManager:getFruitTypeByName(tostring(state.cropName))
    end

    local iconBgEl = cell:getAttribute("cropIconBackground")
    if iconBgEl ~= nil then
        iconBgEl:setVisible(false)
    end
    local iconBgReady = iconBgEl ~= nil

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

    local iconBgColor = nil
    if iconFruitType ~= nil then
        iconBgColor = self:getFruitTypeMapColor(iconFruitType)
    elseif state.kind == "STATUS" and state.statusKind == "soil" then
        iconBgColor = self:getSoilStateMapColor(state.statusIndex)
    elseif state.kind == "STATUS" and state.statusKind == "ground" then
        iconBgColor = self:getGroundStateMapColor(state.statusIndex)
    end
    if iconBgReady then
        self:applyIconBackgroundColor(iconBgEl, iconBgColor)
    end

    local cropLineEl = cell:getAttribute("cropLine")
    if cropLineEl ~= nil then
        local line = state.label
        if state.kind == "CROP" and state.family ~= nil and state.family ~= "UNKNOWN" then
            line = line .. "  ·  " .. self.i18n:getText(getFamilyTextKey(state.family))
        end
        cropLineEl:setText(line)
    end
end

---SmoothList delegate: updates the active panel when the field selection changes.
-- @param table _list
-- @param integer _section
-- @param integer index
-- @param table _cell
function RealisticCropRotationFrame:onListSelectionChanged(_list, _section, index, _cell)
    if _list ~= self.listFields then return end
    local entry = self.farmlandList[index]
    if entry ~= nil then
        -- Population renders the selected panel once; SmoothList also calls its delegate when focus enters.
        if self.isRestoringSidebarSelection or self.selectedId == entry.farmlandId then return end
        self.selectedId = entry.farmlandId
        if self:isHistoryTab() then
            if self.isMenuOpen then
                RealisticCropRotation.requestMenuReconcile(self.selectedId, true)
            end
            self:updateDetailPanel(entry.farmlandId)
        else
            self:updatePlanningPanel(entry.farmlandId)
        end
    end
end

function RealisticCropRotationFrame:onViewChanged()
    self:updateContainerVisibility()
    self:setMenuButtonInfoDirty()
    if self:isHistoryTab() then
        if self.isMenuOpen and self.selectedId ~= nil then
            RealisticCropRotation.requestMenuReconcile(self.selectedId, true)
        end
        self:updateDetailPanel(self.selectedId)
    else
        self:buildRotationGroups()
        self:updateOverviewTotalArea()
        self.listPlanOverview:reloadData()
        self:updatePlanningPanel(self.selectedId)
    end
end

---True when the plan schedules a fallow for the gap after a crop (nil reads the last history crop).
-- @param integer farmlandId
-- @param string currentCrop Crop currently on the field, or nil when bare
-- @return boolean isFallowGap
function RealisticCropRotationFrame:isPlannedFallowGap(farmlandId, currentCrop)
    if currentCrop == nil then
        return self:getManager():isCurrentGapFallow(farmlandId)
    end
    if isFallowCrop(currentCrop) then return false end
    local plan = self:getPlanForFarmland(farmlandId)
    local slots, cycleLength, hasInternalGap =
        self:findPlanSlotsForCrop(plan, currentCrop)
    if hasInternalGap or #slots == 0 then return false end
    for _, slot in ipairs(slots) do
        local nextSlot = PlannerModel.getNextIndex(slot, cycleLength)
        if nextSlot == nil or not isFallowCrop(plan[nextSlot]) then return false end
    end
    return true
end

---Resolves a field's current display state, shared by the sidebar and the detail card.
-- @param integer farmlandId
-- @param boolean inferFallow Show a planned fallow over a harvested or bare field (detail card only)
-- @return table state { kind = "CROP"|"FALLOW"|"STATUS"|"NONE", cropName, family, label, statusKind, statusIndex }
function RealisticCropRotationFrame:resolveCurrentFieldState(farmlandId, inferFallow)
    local cropName = self:getActiveCropInfoForDisplay(farmlandId)
    local belowFloor = false
    if inferFallow and cropName ~= nil then
        local liveCropName, _, _, liveBelowFloor = self:getManager():getActiveCropInfo(farmlandId)
        if liveBelowFloor and string.upper(tostring(liveCropName or "")) == string.upper(tostring(cropName)) then
            belowFloor = true
        end
    end
    local hasCrop = cropName ~= nil and cropName ~= ""

    -- A planned fallow overrides a harvested (stubble) or bare field; a growing crop always wins.
    if inferFallow and (not hasCrop or belowFloor)
        and self:isPlannedFallowGap(farmlandId, hasCrop and cropName or nil) then
        local fallow = RealisticCropRotation.SPECIAL_CROP_FALLOW
        return { kind = "FALLOW", cropName = fallow, family = "FALLOW", label = self:getCropDisplayName(fallow) }
    end

    if hasCrop then
        return { kind = "CROP", cropName = cropName,
                 family = self:getCropFamily(cropName), label = self:getCropDisplayName(cropName) }
    end

    local statusLabel, statusKind, statusIndex = self:getManager():getCurrentFieldStatus(farmlandId)
    if statusLabel ~= nil and statusLabel ~= "" then
        return { kind = "STATUS", label = statusLabel, statusKind = statusKind, statusIndex = statusIndex }
    end

    return { kind = "NONE", label = self.i18n:getText("rcr_sidebar_no_active_crop") }
end

---Resolves the current timeline slot from the shared field state (planned fallow included).
-- @param integer farmlandId
-- @return string cropName, or nil
-- @return string family
-- @return string fallbackText Status/empty text when there is no crop, or nil
-- @return table avatarColor RGBA for a field-status avatar, or nil
function RealisticCropRotationFrame:getCurrentSlotData(farmlandId)
    local state = self:resolveCurrentFieldState(farmlandId, true)

    if state.kind == "CROP" or state.kind == "FALLOW" then
        return state.cropName, state.family, nil, nil
    end

    local avatarColor = nil
    if state.kind == "STATUS" then
        if state.statusKind == "soil" then
            avatarColor = self:getSoilStateMapColor(state.statusIndex)
        elseif state.statusKind == "ground" then
            avatarColor = self:getGroundStateMapColor(state.statusIndex)
        end
    end
    return nil, "UNKNOWN", state.label, avatarColor
end

---Refreshes the whole history detail panel for a farmland (title, pills, timeline, gauges).
-- @param integer farmlandId
function RealisticCropRotationFrame:updateDetailPanel(farmlandId)
    local farmlandList = self.farmlandList or {}
    if #farmlandList == 0 then return end

    local entry = nil
    for _, e in ipairs(farmlandList) do
        if e.farmlandId == farmlandId then entry = e; break end
    end
    if entry == nil then return end

    self.detailTitle:setText(
        string.upper(tostring(entry.name or ""))
        .. "  |  "
        .. self:formatAreaHa(entry.areaHa)
    )

    local mgr = self:getManager()
    self:updateResiduePill(self.statusPillBg, self.statusPillText, farmlandId)
    self:layoutHeroPills(self.detailTitle, self.statusPillBg)

    local history = mgr:getHistory(farmlandId) or {}

    local statusLabel, statusKind, statusIndex = mgr:getCurrentFieldStatus(farmlandId)

    local currentCropName, currentFamily, currentFallbackText, currentAvatarColor =
        self:getCurrentSlotData(farmlandId)
    local currentBadgeKey = currentFamily == "COVER" and "rcr_cover_crop" or nil

    -- The timeline never reaches further back than the player plans ahead: a 3-year plan stops at N-3. An unplanned field keeps the full 4-year depth.
    local _, planLastYear = self:getPlanBounds(self:getPlanForFarmland(farmlandId))
    local historyCount = 0
    for histIdx = 1, math.min(4, planLastYear or 4) do
        local hEntry = history[histIdx]
        if hEntry ~= nil and hEntry.crop ~= nil and hEntry.crop ~= "" then
            historyCount = histIdx
        else
            break
        end
    end

    self:updateTimelineSlot(1, currentCropName, currentFamily, currentFallbackText, currentBadgeKey, currentAvatarColor)
    for histIdx = 1, 4 do
        local cropName = (histIdx <= historyCount) and history[histIdx].crop or nil
        self:updateTimelineSlot(histIdx + 1, cropName, self:getCropFamily(cropName), nil)
    end
    self:layoutHistoryTimeline(1 + historyCount)

    -- Align all gauge tracks to the widest row title.
    local nitrogenTitleWidth = self:getTextRenderWidth(self.nitrogenRowTitle, self.i18n:getText("rcr_section_nitrogen"))
    local limeTitleWidth = self:getTextRenderWidth(self.limeRowTitle, self.i18n:getText("rcr_section_lime"))
    local treatmentTitleWidth = self:getTextRenderWidth(self.treatmentRowTitle, self.i18n:getText("rcr_treatment_hud_label"))
    local sharedRowTitleWidth = nil
    for _, w in pairs({ nitrogenTitleWidth, limeTitleWidth, treatmentTitleWidth }) do
        sharedRowTitleWidth = math.max(sharedRowTitleWidth or 0, w)
    end

    local _, activeFruitTypeIndex = self:getActiveCropInfoForDisplay(farmlandId)
    self:updateNitrogenGauge(farmlandId, sharedRowTitleWidth, activeFruitTypeIndex, true)
    self:updateSoilPHGauge(farmlandId, sharedRowTitleWidth)
    self:updateTreatmentGauge(farmlandId, sharedRowTitleWidth)
    self:updateAdvice(currentFamily, farmlandId, currentCropName)
    self:updateFieldCard(farmlandId, statusLabel, statusKind, statusIndex)
end

---Fills one timeline slot: frame, avatar, crop name, family badge.
-- @param integer slotId Slot 1-5 (1 = current)
-- @param string cropName, or nil
-- @param string family
-- @param string fallbackText Text shown when no crop, or nil
-- @param string badgeTextKey Override badge i18n key, or nil
-- @param table avatarColor RGBA colouring the avatar for a no-crop field-status slot, or nil
function RealisticCropRotationFrame:updateTimelineSlot(slotId, cropName, family, fallbackText, badgeTextKey, avatarColor)
    local pfx = "slot" .. tostring(slotId)
    local cardBg   = self[pfx .. "CardBg"]
    local frame    = self[pfx .. "Frame"]
    local avatarBg = self[pfx .. "AvatarBg"]
    local iconEl   = self[pfx .. "Icon"]
    local nameEl   = self[pfx .. "CropName"]
    local badgeBg  = self[pfx .. "BadgeBg"]
    local badgeTxt = self[pfx .. "BadgeText"]

    local hasCrop = cropName ~= nil and cropName ~= ""
    -- Empty (no crop, no status text) = a slot past the history run: hide it entirely so the centred layout leaves no gap.
    local isEmpty = not hasCrop and (fallbackText == nil or fallbackText == "")
    local familyColor = hasCrop and RealisticCropRotationFrame.FAMILY_RGBA[family] or nil

    cardBg:setVisible(not isEmpty)
    frame:setVisible(not isEmpty)

    avatarBg:setVisible(hasCrop or avatarColor ~= nil)
    if hasCrop then
        -- Native crop color, not family color — the badge below already shows the family.
        local fruitType = g_fruitTypeManager ~= nil and type(g_fruitTypeManager.getFruitTypeByName) == "function"
            and g_fruitTypeManager:getFruitTypeByName(string.upper(cropName)) or nil
        local nativeColor = fruitType ~= nil and self:getFruitTypeMapColor(fruitType) or nil
        self:applyIconBackgroundColor(avatarBg, nativeColor or familyColor or RealisticCropRotationFrame.FAMILY_RGBA.FALLOW)
    elseif avatarColor ~= nil then
        self:applyIconBackgroundColor(avatarBg, avatarColor)
    end

    self:applySlotCropIcon(iconEl, cropName)

    nameEl:setVisible(not isEmpty)
    if hasCrop or avatarColor ~= nil then
        nameEl:applyProfile("frSlotCropName")
        nameEl:setText(hasCrop and self:getCropDisplayName(cropName) or fallbackText)
    elseif not isEmpty then
        nameEl:applyProfile("frSlotCropNameCentered")
        nameEl:setText(fallbackText)
    end

    local showBadge = hasCrop and (family ~= nil) and (family ~= "UNKNOWN")
    badgeBg:setVisible(showBadge)
    if showBadge and familyColor ~= nil then
        badgeBg.color = {familyColor[1], familyColor[2], familyColor[3], familyColor[4]}
    end
    badgeTxt:setVisible(showBadge)
    if showBadge then
        local familyText = self.i18n:getText(badgeTextKey or getFamilyTextKey(family))
        badgeTxt:setText(familyText)
        self:resizePillToText(badgeBg, badgeTxt, familyText)
    end
end

---Centres the visible history cards in the strip; empty tail slots and their connectors/rail labels are hidden so nothing is left blank.
-- @param integer visibleCount Leading slots that carry a card (1-5)
function RealisticCropRotationFrame:layoutHistoryTimeline(visibleCount)
    local slotCount = RealisticCropRotationFrame.TIMELINE_SLOT_COUNT
    visibleCount = math.max(1, math.min(slotCount, math.floor(tonumber(visibleCount) or 1)))

    for i = 1, slotCount do
        local rail = self["slot" .. i .. "Rail"]
        rail:setVisible(i <= visibleCount)
    end
    for i = 1, slotCount - 1 do
        local connector = self["slot" .. i .. "Connector"]
        connector:setVisible(i < visibleCount)
    end

    -- Centre partial history rows without moving a full row.
    local strip = self.historyTimeline
    local originalPos = self:getElementOriginalPosition(strip)
    if originalPos == nil then return end

    local pitch = self:getNormalizedPixelWidth(
        RealisticCropRotationFrame.TIMELINE_CARD_W_PX + RealisticCropRotationFrame.TIMELINE_CONNECTOR_W_PX
    )
    local offset = pitch * (slotCount - visibleCount) * 0.5

    -- Shift snapped to a whole screen pixel, keeping the 1px borders flush.
    local screenPixel = g_pixelSizeX
    if screenPixel ~= nil and screenPixel > 0 then
        offset = math.floor(offset / screenPixel + 0.5) * screenPixel
    end

    strip:setPosition(originalPos[1] + offset, originalPos[2])
end

function RealisticCropRotationFrame:getSoilAnalysisState(farmlandId)
    local mgr = self:getManager()

    local hasAnalysedValue = false
    local actualN = mgr:getNitrogenLevel(farmlandId)
    if actualN == false then return false end
    hasAnalysedValue = hasAnalysedValue or actualN ~= nil

    local actualPH = mgr:getPHLevel(farmlandId)
    if actualPH == false then return false end
    hasAnalysedValue = hasAnalysedValue or actualPH ~= nil

    return hasAnalysedValue and true or nil
end

---Sets a status bar fill width from a 0..1 ratio.
-- @param table barFill
-- @param number ratio Clamped to [0, 1]
-- @param number maxWidth Track width (normalized units) at ratio 1
function RealisticCropRotationFrame:setStatusBarFill(barFill, ratio, maxWidth)
    ratio = math.max(0, math.min(1, tonumber(ratio) or 0))
    maxWidth = math.max(0, tonumber(maxWidth) or 0)

    local fillSize = self:getElementOriginalSize(barFill)
    local height = fillSize ~= nil and fillSize[2] or 0
    barFill:setSize(maxWidth * ratio, height)
    barFill:setVisible(maxWidth * ratio > 0)
end

---Updates the nitrogen gauge: PF average vs crop need, with a vanilla SPRAY_LEVEL fallback.
-- @param integer farmlandId
-- @param number sharedRowTitleWidth Shared row-title width (the wider of the N/pH titles), so both gauges align; nil falls back to this row's own title width.
-- @param integer activeFruitTypeIndex Known active fruit type, or nil
-- @param boolean useProvidedFruitType True to avoid resolving the active crop again
function RealisticCropRotationFrame:updateNitrogenGauge(farmlandId, sharedRowTitleWidth, activeFruitTypeIndex, useProvidedFruitType)
    local mgr = self:getManager()
    local ratio = 0
    local labelKey = "rcr_n_none"
    local stateText = nil
    local valueText = nil

    -- Precision Farming path: false = soil not analysed ("not sampled"); nil = no PF -> vanilla fallback.
    local actualN, targetN = mgr:getNitrogenLevel(farmlandId, activeFruitTypeIndex, useProvidedFruitType)
    if actualN == false then
        labelKey = "rcr_soil_value_unmeasured"
        stateText = self.i18n:getText("rcr_soil_value_unmeasured")
        valueText = self.i18n:getText("rcr_n_crop_need_unavailable")
        ratio = 0
    elseif actualN ~= nil then
        labelKey = "rcr_n_average_pf"
        stateText = string.format(self.i18n:getText("rcr_n_average_value"), actualN)
        if targetN ~= nil and targetN > 0 then
            ratio = math.min(actualN / targetN, 1)
            valueText = string.format(self.i18n:getText("rcr_n_crop_need"), targetN)
        else
            ratio = 0
        end
    end

    if stateText == nil then
        local nLevel, maxLevel, fillRatio = mgr:getCurrentNitrogenLevel(farmlandId)

        nLevel = tonumber(nLevel) or 0
        maxLevel = math.max(1, tonumber(maxLevel) or 1)
        ratio = tonumber(fillRatio) or (nLevel / maxLevel)
        valueText = string.format("%d / %d", nLevel, maxLevel)

        if nLevel <= 0 then
            labelKey = "rcr_n_none"
        elseif nLevel >= maxLevel then
            labelKey = "rcr_n_full"
        else
            labelKey = "rcr_n_partial"
        end
    end

    local trackWidth = self:layoutSoilGaugeTrack(self.nitrogenRowTitle, self.i18n:getText("rcr_section_nitrogen"),
        self.nitrogenTrack, self.nitrogenBarFill, self.nitrogenStateLabel, sharedRowTitleWidth)
    self:setStatusBarFill(self.nitrogenBarFill, ratio, trackWidth)

    self.nitrogenStateLabel:setText(stateText or self.i18n:getText(labelKey))
    self.nitrogenValueLabel:applyProfile(labelKey == "rcr_soil_value_unmeasured"
        and "frSoilValueUnavailableTop" or "frSoilValueTop")
    self.nitrogenValueLabel:setText(valueText or "")
    self.nitrogenValueLabel:setVisible(valueText ~= nil)
end

---Updates the pH gauge: PF average vs soil optimal, with a vanilla LIME_LEVEL fallback.
-- @param integer farmlandId
-- @param number sharedRowTitleWidth Shared row-title width (the wider of the N/pH titles), so both gauges align; nil falls back to this row's own title width.
function RealisticCropRotationFrame:updateSoilPHGauge(farmlandId, sharedRowTitleWidth)
    local mgr = self:getManager()
    local ratio = 0
    local labelKey = "rcr_lime_none"
    local stateText = nil
    local valueText = nil

    local actualPH, targetPH, minPH, maxPH = mgr:getPHLevel(farmlandId)
    if actualPH == false then
        labelKey = "rcr_soil_value_unmeasured"
        stateText = self.i18n:getText("rcr_soil_value_unmeasured")
        valueText = self.i18n:getText("rcr_lime_status_unavailable")
        ratio = 0
    elseif actualPH ~= nil then
        minPH = tonumber(minPH) or 0
        maxPH = tonumber(maxPH) or 0
        labelKey = "rcr_lime_average_pf"
        if targetPH ~= nil then
            ratio = targetPH > 0 and math.min(actualPH / targetPH, 1) or 0
            stateText = string.format(self.i18n:getText("rcr_lime_average_value"), actualPH)
            valueText = string.format(self.i18n:getText("rcr_lime_target"), targetPH)
        else
            ratio = maxPH > minPH and ((actualPH - minPH) / (maxPH - minPH)) or 0
            stateText = string.format(self.i18n:getText("rcr_lime_average_value"), actualPH)
        end
    end

    if stateText == nil then
        local limeLevel, maxLevel, fillRatio = mgr:getCurrentLimeLevel(farmlandId)

        limeLevel = tonumber(limeLevel) or 0
        maxLevel = math.max(1, tonumber(maxLevel) or 1)
        ratio = tonumber(fillRatio) or (limeLevel / maxLevel)
        valueText = string.format("%d / %d", limeLevel, maxLevel)

        if limeLevel <= 0 then
            labelKey = "rcr_lime_none"
        elseif limeLevel >= maxLevel then
            labelKey = "rcr_lime_full"
        else
            labelKey = "rcr_lime_partial"
        end
    end

    local trackWidth = self:layoutSoilGaugeTrack(self.limeRowTitle, self.i18n:getText("rcr_section_lime"),
        self.limeTrack, self.limeBarFill, self.limeStateLabel, sharedRowTitleWidth)
    self:setStatusBarFill(self.limeBarFill, ratio, trackWidth)

    self.limeStateLabel:setText(stateText or self.i18n:getText(labelKey))
    self.limeValueLabel:applyProfile(labelKey == "rcr_soil_value_unmeasured"
        and "frSoilValueUnavailableBottom" or "frSoilValueBottom")
    self.limeValueLabel:setText(valueText or "")
    self.limeValueLabel:setVisible(valueText ~= nil)
end

RealisticCropRotationFrame.TREATMENT_COMPLETE_THRESHOLD = 0.95

---Updates the treatment gauge: treated-area share, disease-control status, and remaining protection.
-- @param integer farmlandId
-- @param number sharedRowTitleWidth Shared row-title width (widest of the three), so all tracks align; nil falls back to this row's own title width.
function RealisticCropRotationFrame:updateTreatmentGauge(farmlandId, sharedRowTitleWidth)
    local mgr = self:getManager()
    local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
    local grid = RealisticCropRotation ~= nil and RealisticCropRotation.grid or nil
    local region = mgr:getFieldRegion(farmlandId)

    local coverageOf = function(fam)
        return (grid ~= nil and region ~= nil)
            and grid:getProtectionCoverage(region, fam) or 0
    end

    -- Show the least protected active disease; severity breaks ties.
    local state = disease ~= nil and disease:getState(farmlandId) or nil
    local anyActive = false
    local hasRotationOnlyActive = false
    local family, coverage, worstSeverity = nil, 0, -1
    if state ~= nil then
        for group, s in pairs(state) do
            local severity = tonumber(s.severity) or 0
            if disease:isOutbreakVisible(group, s) then
                anyActive = true
                local treatment = disease:getTreatment(group)
                if treatment == "NONE" then
                    hasRotationOnlyActive = true
                elseif treatment == "FUNGICIDE" or treatment == "NEMATICIDE" then
                    local cov = coverageOf(treatment)
                    if family == nil or cov < coverage or (cov == coverage and severity > worstSeverity) then
                        family, coverage, worstSeverity = treatment, cov, severity
                    end
                end
            end
        end
    end
    if not anyActive then
        local fung, nema = coverageOf("FUNGICIDE"), coverageOf("NEMATICIDE")
        if fung > 0 or nema > 0 then
            if nema > fung then family, coverage = "NEMATICIDE", nema else family, coverage = "FUNGICIDE", fung end
        end
    end

    local complete = RealisticCropRotationFrame.TREATMENT_COMPLETE_THRESHOLD

    local subject = (family == "FUNGICIDE" and self.i18n:getText("rcr_fillType_fungicide"))
        or (family == "NEMATICIDE" and self.i18n:getText("rcr_fillType_nematicide"))
        or self.i18n:getText("rcr_treatment_hud_label")

    local levelText
    if coverage <= 0.005 then
        levelText = string.format("%s %s", subject, self.i18n:getText("rcr_treatment_absent"))
    elseif coverage >= complete then
        levelText = string.format("%s %s", subject, self.i18n:getText("rcr_treatment_complete"))
    else
        levelText = string.format("%s %s", subject,
            string.format(self.i18n:getText("rcr_treatment_partial"), math.floor(coverage * 100 + 0.5)))
    end

    -- Disease status follows the shown family's coverage; rotation-only outbreaks keep a completed treatment from claiming full control.
    local diseaseKey = "rcr_treatment_disease_absent"
    if anyActive then
        if family ~= nil and coverage >= complete then
            diseaseKey = hasRotationOnlyActive
                and "rcr_treatment_disease_partially_controlled"
                or "rcr_treatment_disease_controlled"
        else
            diseaseKey = "rcr_treatment_disease_active"
        end
    end
    local stateText = string.format("%s · %s", levelText, self.i18n:getText(diseaseKey))

    local valueText = nil
    if coverage > 0.005 then
        if family == "FUNGICIDE" then
            valueText = self.i18n:getText("rcr_treatment_until_harvest")
        elseif family == "NEMATICIDE" then
            local remaining = RealisticCropRotationTreatmentLifecycle.getNematicidePeriodsRemaining(farmlandId)
            if remaining ~= nil then
                valueText = string.format(self.i18n:getText("rcr_treatment_months"), remaining)
            end
        end
    end

    local trackWidth = self:layoutSoilGaugeTrack(self.treatmentRowTitle, self.i18n:getText("rcr_treatment_hud_label"),
        self.treatmentTrack, self.treatmentBarFill, self.treatmentStateLabel, sharedRowTitleWidth)
    self:setStatusBarFill(self.treatmentBarFill, coverage >= complete and 1 or coverage, trackWidth)

    self.treatmentStateLabel:setText(stateText)
    self.treatmentValueLabel:setText(valueText or "")
    self.treatmentValueLabel:setVisible(valueText ~= nil)
end

---Updates the field card: required soil work, weed line, growth stage, and visible disease.
-- @param integer farmlandId
-- @param string actionLabel Field status label resolved by the caller, or nil
-- @param string statusKind "soil" or "ground", or nil
-- @param integer statusIndex Native state index, or nil
function RealisticCropRotationFrame:updateFieldCard(farmlandId, actionLabel, statusKind, statusIndex)
    local info = self:getManager():getFieldCropInfo(farmlandId)

    local hasStage = info ~= nil and info.growthStageText ~= nil
    local growthIsAction = info ~= nil and info.growthIsAction == true
    local hasWeed  = info ~= nil and info.weedActionText ~= nil
    local weedText  = hasWeed and info.weedActionText or "-"
    local stageText = hasStage and info.growthStageText or "-"

    local hasAction = actionLabel ~= nil and actionLabel ~= ""
    local indices = MapOverlayGenerator ~= nil and MapOverlayGenerator.SOIL_STATE_INDEX or nil
    local isPriority = hasAction and statusKind == "soil" and indices ~= nil
        and (statusIndex == indices.NEEDS_PLOWING or statusIndex == indices.NEEDS_ROLLING)
    local actionText = hasAction and actionLabel or "-"

    -- Small size (18px) for any real text (avoids clipping); NA's 26px is only right for "-".
    local actionProfile = isPriority and "frFieldKpiValueSmall"
        or (hasAction and "frFieldKpiValueSmallNA" or "frFieldKpiValueNA")
    self.requiredActionValue:applyProfile(actionProfile)
    self.requiredActionValue:setText(actionText)

    local headerText = (hasWeed and info.weedHeader ~= nil)
        and info.weedHeader
        or self.i18n:getText("rcr_weed_header")
    self.weedHeaderText:setText(headerText)

    self.weedValue:applyProfile(hasWeed and "frFieldKpiValueSmall" or "frFieldKpiValueNA")
    self.weedValue:setText(weedText)

    -- Orange only when ready to prepare/harvest (an action); plain growing is grey.
    local growthProfile = growthIsAction and "frFieldKpiValueSmall"
        or (hasStage and "frFieldKpiValueSmallNA" or "frFieldKpiValueNA")
    self.growthValue:applyProfile(growthProfile)
    self.growthValue:setText(stageText)

    local worstDiseaseGroup = self:getWorstActiveDisease(farmlandId)
    local diseaseHeaderText = self.i18n:getText("rcr_section_disease_map")
    local diseaseText = "-"

    if worstDiseaseGroup ~= nil then
        diseaseHeaderText = string.format(
            self.i18n:getText("rcr_disease_header_active"),
            RealisticCropRotation.disease:getDisplayName(worstDiseaseGroup)
        )

        local treatment = RealisticCropRotation.disease:getTreatment(worstDiseaseGroup)
        local treatmentKey = (treatment == "FUNGICIDE" and "rcr_fillType_fungicide")
            or (treatment == "NEMATICIDE" and "rcr_fillType_nematicide")
            or "rcr_disease_treatment_none"
        diseaseText = self.i18n:getText(treatmentKey)
    end

    self.diseaseHeaderText:setText(diseaseHeaderText)
    self.diseaseValue:applyProfile(worstDiseaseGroup ~= nil and "frFieldKpiValueSmall" or "frFieldKpiValueNA")
    self.diseaseValue:setText(diseaseText)
end

---Refreshes the advice status/rotation card.
-- @param string currentFamily
-- @param integer farmlandId
-- @param string currentCropName
function RealisticCropRotationFrame:updateAdvice(currentFamily, farmlandId, currentCropName)
    self:updateAdviceStatusCard(currentFamily, farmlandId, currentCropName)
end

---Finds every plan slot matching a crop name inside the contiguous cycle.
-- @param table plan 4-slot plan
-- @param string cropName
-- @return table slotIndices
-- @return integer cycleLength
-- @return boolean hasInternalGap
function RealisticCropRotationFrame:findPlanSlotsForCrop(plan, cropName)
    return PlannerModel.findCropSlots(plan, cropName, 4)
end

---Evaluates a one-year rotation step (cropA now, cropB next) for a conflict, using calcRotationScore's own rules.
-- @param string cropA Current crop name
-- @param string cropB Next-planned crop name
-- @return table conflict { kind = "family"|"disease", label, yearsRemaining, minInterval }, or nil
function RealisticCropRotationFrame:evaluateRotationStep(cropA, cropB)
    if cropA == nil or cropA == "" or cropB == nil or cropB == "" then return nil end
    if isFallowCrop(cropA) or isFallowCrop(cropB) then return nil end

    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or {}
    local conflict = PlannerModel.evaluateImmediateConflict(
        { family = self:getCropFamily(cropA), diseases = self:getCropDiseases(cropA) },
        { family = self:getCropFamily(cropB), diseases = self:getCropDiseases(cropB) },
        RealisticCropRotationFrame.FAMILY_MIN_INTERVAL,
        config.diseasePlannerIntervals or {},
        config.diseaseRotationRelevant or {},
        RealisticCropRotationFrame.SCORE_FAMILY_PENALTY_PER_YEAR,
        RealisticCropRotationFrame.SCORE_DISEASE_PENALTY_PER_YEAR)

    if conflict ~= nil and conflict.kind == "disease" then
        local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
        conflict.label = disease ~= nil and disease:getDisplayName(conflict.group) or tostring(conflict.group)
    elseif conflict ~= nil and conflict.kind == "family" then
        conflict.label = self.i18n:getText(getFamilyTextKey(conflict.family))
    end
    return conflict
end

---Returns the worst immediate next step among every matching occurrence of the current crop.
-- @param table plan 4-slot plan
-- @param string currentCropName
-- @return table candidate { slotIndex, nextSlotIndex, nextCrop, conflict }, or nil
function RealisticCropRotationFrame:getWorstPlannedNextStep(plan, currentCropName)
    return PlannerModel.getWorstNextCandidate(plan, currentCropName, 4,
        function(_, nextCrop)
            return isFallowCrop(nextCrop) and nil
                or self:evaluateRotationStep(currentCropName, nextCrop)
        end)
end

---Returns the pressure tip for the crop's single worst hosted disease (high beats moderate, ties by soil load), or nil.
-- @param integer farmlandId
-- @param string currentCropName
-- @return string text, or nil
function RealisticCropRotationFrame:getWorstPressureAdviceText(farmlandId, currentCropName)
    local cropDiseases = self:getCropDiseases(currentCropName)
    if next(cropDiseases) == nil then return nil end

    local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
    if disease == nil then return nil end
    local D = RealisticCropRotationDisease
    if D == nil then return nil end

    local load = disease:getPressure(farmlandId)
    local bestBand, bestGroup, bestPressure = nil, nil, 0
    for group in pairs(cropDiseases) do
        local pressure = tonumber(load[group]) or 0
        local band = pressure >= D.RISK_BAND_HIGH_THRESHOLD and "high"
            or (pressure >= D.RISK_BAND_MODERATE_THRESHOLD and "moderate" or nil)
        if band ~= nil then
            local better = (bestBand == nil)
                or (band == "high" and bestBand == "moderate")
                or (band == bestBand and pressure > bestPressure)
            if better then
                bestBand, bestGroup, bestPressure = band, group, pressure
            end
        end
    end
    if bestGroup == nil then return nil end

    local key = "rcr_advice_pressure_" .. bestBand .. "_" .. string.lower(bestGroup)
    if type(self.i18n.hasText) == "function" and self.i18n:hasText(key) then
        local text = self.i18n:getText(key)
        if bestGroup == "BCN" then
            text = text .. " " .. self.i18n:getText("rcr_advice_nematicide_duration")
        end
        return text
    end
    return nil
end

---Worst infection actually active on a field right now (across all pathogen groups), or nil when healthy.
-- @param integer farmlandId
-- @return string worstGroup, or nil
-- @return number worstSeverity
function RealisticCropRotationFrame:getWorstActiveDisease(farmlandId)
    local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
    if disease == nil then return nil, 0 end
    return disease:getWorstGroup(farmlandId)
end

---Refreshes the advice card: visible outbreak > fallow year > planned-step evaluation > per-family fallback, plus a soil-analysis note.
-- @param string currentFamily
-- @param integer farmlandId
-- @param string currentCropName
function RealisticCropRotationFrame:updateAdviceStatusCard(currentFamily, farmlandId, currentCropName)
    local visualState = "Neutral"
    local badgeSymbol = "i"
    local title = ""
    local text

    -- Active outbreak.
    local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
    local worstGroup, worstSeverity = self:getWorstActiveDisease(farmlandId)

    if worstGroup ~= nil then
        visualState = "Danger"
        badgeSymbol = "!"
        title = self.i18n:getText("rcr_advice_title_outbreak")
        text = string.format(self.i18n:getText("rcr_advice_outbreak"),
            disease:getDisplayName(worstGroup),
            math.floor(worstSeverity * 100 + 0.5),
            disease:getTreatmentName(worstGroup))
        if worstGroup == "BCN" then
            text = text .. " " .. self.i18n:getText("rcr_advice_nematicide_duration")
        end
    elseif currentFamily == "FALLOW" then
        -- Fallow year in progress.
        visualState = "Ready"
        badgeSymbol = "OK"
        title = self.i18n:getText("rcr_advice_title_fallow")
        text = self.i18n:getText("rcr_advice_fallow_current")
    else
        -- Planned next crop.
        local plan = self:getPlanForFarmland(farmlandId)
        local candidate = (currentFamily ~= "UNKNOWN")
            and self:getWorstPlannedNextStep(plan, currentCropName) or nil
        local nextCrop = candidate ~= nil and candidate.nextCrop or nil

        if nextCrop ~= nil then
            local nextSlotIdx = candidate.nextSlotIndex
            local yearLabel = self.i18n:getText("rcr_plan_year" .. nextSlotIdx)
            if isFallowCrop(nextCrop) then
                visualState = "Ready"
                badgeSymbol = "OK"
                title = self.i18n:getText("rcr_advice_title_fallow")
                text = string.format(self.i18n:getText("rcr_advice_plan_next_fallow"), yearLabel)
            else
                local nextCropLabel = self:getCropDisplayName(nextCrop)
                local conflict = candidate.conflict

                if conflict == nil then
                    visualState = "Ready"
                    badgeSymbol = "OK"
                    title = self.i18n:getText("rcr_advice_title_ready")
                    text = string.format(self.i18n:getText("rcr_advice_plan_next_ok"), nextCropLabel, yearLabel)
                else
                    visualState = "Warning"
                    badgeSymbol = "!"
                    title = self.i18n:getText("rcr_advice_title_warning")
                    local key = conflict.kind == "disease"
                        and "rcr_advice_plan_next_conflict_disease"
                        or "rcr_advice_plan_next_conflict_family"
                    text = string.format(self.i18n:getText(key),
                        nextCropLabel, yearLabel, conflict.label, conflict.yearsRemaining, conflict.minInterval)
                end
            end
        else
            -- Generic current-crop advice.
            local key = RealisticCropRotationFrame.ADVICE_KEY[currentFamily]
            text = key ~= nil and self.i18n:getText(key) or self.i18n:getText("rcr_advice_no_current_crop")
        end

        -- Worst current disease-pressure tip only, so the card doesn't grow with the crop's disease count.
        local pressureText = self:getWorstPressureAdviceText(farmlandId, currentCropName)
        if pressureText ~= nil then
            text = text .. " " .. pressureText
        end
    end

    if self:getSoilAnalysisState(farmlandId) == false then
        text = text .. " " .. self.i18n:getText("rcr_advice_soil_analysis_required_body")
    end

    self.adviceCardBg:applyProfile("frAdviceCardBg" .. visualState)
    self.adviceTitle:applyProfile("frAdviceTitle" .. visualState)
    self.adviceStatusBadgeText:setText(badgeSymbol)
    self.adviceTitle:setText(title)

    -- Status state hides the header and vertically centers the badge and text.
    local isNeutral = visualState == "Neutral"
    self.adviceTitle:setVisible(not isNeutral)
    self.adviceTitleDivider:setVisible(not isNeutral)
    self.adviceStatusBadgeBg:applyProfile(isNeutral and "frAdviceStatusBadgeBgNeutralCentered"
        or ("frAdviceStatusBadgeBg" .. visualState))
    self.adviceStatusBadgeText:applyProfile(isNeutral and "frAdviceStatusBadgeTextCentered"
        or "frAdviceStatusBadgeText")
    self.adviceText:applyProfile(isNeutral and "frAdviceTextNeutral" or "frAdviceText")

    self.adviceText:setText(text)
end

---Refreshes the planning panel for a farmland (title, calendar, score, pills).
-- @param integer farmlandId
function RealisticCropRotationFrame:updatePlanningPanel(farmlandId)
    local farmlandList = self.farmlandList or {}
    if #farmlandList == 0 then return end

    local entry = nil
    for _, e in ipairs(farmlandList) do
        if e.farmlandId == farmlandId then entry = e; break end
    end
    if entry == nil then return end

    self.planTitle:setText(
        string.upper(tostring(entry.name or ""))
        .. "  |  "
        .. self:formatAreaHa(entry.areaHa)
    )

    self:updateCalendar(farmlandId)
end

---Sets an element's position from pixel coordinates (y is downward).
-- @param table element
-- @param number xPx
-- @param number yPx
function RealisticCropRotationFrame:setElementPixelPosition(element, xPx, yPx)
    if element == nil or element.setPosition == nil
        or GuiUtils == nil or GuiUtils.getNormalizedScreenValues == nil then
        return
    end

    local pos = GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx -%dpx",
        math.floor((tonumber(xPx) or 0) + 0.5),
        math.floor((tonumber(yPx) or 0) + 0.5)
    ))
    element:setPosition(pos[1], pos[2])
end

---Sets an element's size from pixel dimensions.
-- @param table element
-- @param number wPx
-- @param number hPx
function RealisticCropRotationFrame:setElementPixelSize(element, wPx, hPx)
    if element == nil or element.setSize == nil
        or GuiUtils == nil or GuiUtils.getNormalizedScreenValues == nil then
        return
    end

    local size = GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx %dpx",
        math.max(1, math.floor((tonumber(wPx) or 1) + 0.5)),
        math.max(1, math.floor((tonumber(hPx) or 1) + 0.5))
    ))
    element:setSize(size[1], size[2])
end

---Resolves the number of calendar periods/year and the first period index.
-- @return integer periodCount
-- @return integer firstPeriod
function RealisticCropRotationFrame:getCalendarPeriodInfo()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local candidates = {
        env ~= nil and env.numPeriods or nil,
        env ~= nil and env.numberOfPeriods or nil,
        env ~= nil and env.periodsPerYear or nil,
        env ~= nil and env.monthsPerYear or nil,
    }
    for _, value in ipairs(candidates) do
        local count = tonumber(value)
        if count ~= nil and count >= 1 and count <= 24 then
            return math.floor(count), 1
        end
    end

    if SeasonPeriod ~= nil
        and SeasonPeriod.EARLY_SPRING ~= nil
        and SeasonPeriod.LATE_WINTER ~= nil then
        local firstPeriod = tonumber(SeasonPeriod.EARLY_SPRING)
        local lastPeriod = tonumber(SeasonPeriod.LATE_WINTER)
        if firstPeriod ~= nil and lastPeriod ~= nil and lastPeriod >= firstPeriod then
            local count = lastPeriod - firstPeriod + 1
            if count >= 1 and count <= 24 then
                return count, firstPeriod
            end
        end
    end

    return 12, 1
end

---Returns the current month's column index (1..periodCount) in the calendar.
-- @param integer periodCount
-- @param integer firstPeriod
-- @return integer index
function RealisticCropRotationFrame:getCurrentCalendarPeriodIndex(periodCount, firstPeriod)
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local currentPeriod = env ~= nil and tonumber(env.currentPeriod) or nil
    periodCount = math.max(1, tonumber(periodCount) or 12)
    firstPeriod = tonumber(firstPeriod) or 1

    local index = currentPeriod ~= nil and (currentPeriod - firstPeriod + 1) or 1
    if index < 1 or index > periodCount then
        index = currentPeriod or 1
    end
    return math.max(1, math.min(periodCount, math.floor(index)))
end

---Per-period planting/harvest flags for a crop (calendar column order).
-- @param string cropName
-- @param integer periodCount
-- @param integer firstPeriod
-- @return table plant Booleans per column, or nil
-- @return table harvest Booleans per column, or nil
function RealisticCropRotationFrame:getCropPeriodFlags(cropName, periodCount, firstPeriod)
    if cropName == nil or cropName == "" then return nil, nil end
    if g_fruitTypeManager == nil or type(g_fruitTypeManager.getFruitTypeByName) ~= "function" then return nil, nil end

    local fruitDesc = g_fruitTypeManager:getFruitTypeByName(string.upper(tostring(cropName)))
    if fruitDesc == nil then return nil, nil end

    local data = fruitDesc.growthDataSeasonal
    if type(data) ~= "table" or type(data.periods) ~= "table" then return nil, nil end

    periodCount = math.max(1, tonumber(periodCount) or 12)
    firstPeriod = tonumber(firstPeriod) or 1
    local plant, harvest = {}, {}
    for i = 1, periodCount do
        local period = ((firstPeriod - 1 + i - 1) % periodCount) + 1
        local pd = data.periods[period]
        plant[i]   = pd ~= nil and pd.plantingAllowed == true
        harvest[i] = pd ~= nil and pd.isHarvestable == true
    end
    return plant, harvest
end

---Returns a crop's sowing season from its planting window.
-- @param string cropName
-- @return string "WINTER" when autumn/winter sowing is allowed, "SPRING" when only the first half of the year is, or nil
function RealisticCropRotationFrame:getCropSowingSeason(cropName)
    local periodCount, firstPeriod = self:getCalendarPeriodInfo()
    local plant = self:getCropPeriodFlags(cropName, periodCount, firstPeriod)
    if plant == nil then return nil end

    local autumnFirst = math.floor(periodCount / 2) + 1
    for i = autumnFirst, periodCount do
        if plant[i] then return "WINTER" end
    end
    for i = 1, autumnFirst - 1 do
        if plant[i] then return "SPRING" end
    end
    return nil
end

---Returns contiguous true-runs in a flag array as { start, len } entries.
-- @param table flags
-- @param integer periodCount
-- @return table runs
function RealisticCropRotationFrame:getFlagRuns(flags, periodCount)
    local runs = {}
    if type(flags) ~= "table" then return runs end
    periodCount = math.max(1, tonumber(periodCount) or #flags)
    local i = 1
    while i <= periodCount do
        if flags[i] then
            local start, len = i, 0
            while i <= periodCount and flags[i] do
                len = len + 1
                i = i + 1
            end
            table.insert(runs, { start = start, len = len })
        else
            i = i + 1
        end
    end
    return runs
end

---Grid line width: thick on season boundaries (every CALENDAR_SEASON_LEN-th line), thin otherwise.
-- @param integer i 1-based grid line index
-- @return integer widthPx
function RealisticCropRotationFrame:getCalendarGridLineWidth(i)
    local seasonLen = RealisticCropRotationFrame.CALENDAR_SEASON_LEN
    if seasonLen >= 1 and ((i - 1) % seasonLen) == 0 then
        return RealisticCropRotationFrame.CALENDAR_GRID_W_THICK
    end
    return RealisticCropRotationFrame.CALENDAR_GRID_W_THIN
end

---Lays out the calendar axis (month labels, grid lines, today marker).
-- @return integer periodCount
-- @return integer firstPeriod
-- @return number periodW Column width in pixels
function RealisticCropRotationFrame:updateCalendarAxis()
    local periodCount, firstPeriod = self:getCalendarPeriodInfo()
    local periodW = RealisticCropRotationFrame.CALENDAR_AXIS_W / math.max(1, periodCount)

    for i = 1, 12 do
        local labelEl = self.calendarMonthLabel[i]
        local show = i <= periodCount
        labelEl:setVisible(show)
        if show then
            local key = RealisticCropRotationFrame.CALENDAR_MONTH_KEYS[((i - 1) % 12) + 1]
            local labelW = math.min(86, periodW)
            labelEl:setText(self.i18n:getText(key))
            self:setElementPixelPosition(
                labelEl,
                RealisticCropRotationFrame.CALENDAR_AXIS_X + ((i - 1) * periodW) + ((periodW - labelW) * 0.5),
                38
            )
            self:setElementPixelSize(labelEl, labelW, 14)
        end

        local gridEl = self.calendarMonthGridLine[i]
        gridEl:setVisible(show)
        if show then
            local lineW = self:getCalendarGridLineWidth(i)
            -- Centre the (thick) line on the boundary so it grows symmetrically.
            self:setElementPixelPosition(
                gridEl,
                RealisticCropRotationFrame.CALENDAR_AXIS_X + ((i - 1) * periodW) - (lineW - 1) * 0.5,
                38
            )
            self:setElementPixelSize(gridEl, lineW, RealisticCropRotationFrame.CALENDAR_GRID_H)
        end
    end

    local lastGridEl = self.calendarMonthGridLine[13]
    local lineW = self:getCalendarGridLineWidth(13)
    self:setElementPixelPosition(
        lastGridEl,
        RealisticCropRotationFrame.CALENDAR_AXIS_X + (periodCount * periodW) - (lineW - 1) * 0.5,
        38
    )
    self:setElementPixelSize(lastGridEl, lineW, RealisticCropRotationFrame.CALENDAR_GRID_H)
    lastGridEl:setVisible(periodCount > 0)

    local marker = self.calendarTodayMarker
    local todayIndex = self:getCurrentCalendarPeriodIndex(periodCount, firstPeriod)
    -- Fraction through the current month (0.5 default, refined from env day-in-period).
    local dayFrac = 0.5
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env ~= nil and env.getDayInPeriodFromDay ~= nil then
        local daysPerPeriod = tonumber(env.plannedDaysPerPeriod)
        local currentDay = tonumber(env.currentDay)
        if daysPerPeriod ~= nil and daysPerPeriod > 0 and currentDay ~= nil then
            local dayInPeriod = tonumber(env:getDayInPeriodFromDay(currentDay))
            if dayInPeriod ~= nil and dayInPeriod >= 1 and dayInPeriod <= daysPerPeriod then
                dayFrac = (dayInPeriod - 0.5) / daysPerPeriod
            end
        end
    end
    local lineX = RealisticCropRotationFrame.CALENDAR_AXIS_X + ((todayIndex - 1) + dayFrac) * periodW
    self:setElementPixelPosition(marker, lineX - 36, 0)
    marker:setVisible(true)

    return periodCount, firstPeriod, periodW
end

---Renders one calendar row: row bg, crop/cover icons, sow/harvest/cover bars.
-- @param integer slotIdx Row 1-4
-- @param string cropName
-- @param string coverCropName
-- @param integer periodCount
-- @param integer firstPeriod
-- @param number periodW Column width in pixels
function RealisticCropRotationFrame:applyCalendarRow(slotIdx, cropName, coverCropName, periodCount, firstPeriod, periodW)
    local rowBg = self.calendarRowBg[slotIdx]
    local cropIcon = self.calendarCropIcon[slotIdx]
    local coverIcon = self.calendarCoverIcon[slotIdx]
    local cropBar = self.calendarCropBar[slotIdx]
    local cropBarContinuation = self.calendarCropBarContinuation[slotIdx]
    local coverMarker = self.calendarCoverMarker[slotIdx]
    local coverMarkerContinuation = self.calendarCoverMarkerContinuation[slotIdx]

    local active = slotIdx == self:getCalendarEditSlotIndex()
    if active then
        rowBg.color = {0.35, 0.55, 0.00, 0.26}
    else
        rowBg:applyProfile(slotIdx % 2 == 1 and "frCalendarRowBgOdd" or "frCalendarRowBgEven")
    end
    rowBg:setVisible(true)

    self:applySlotCropIcon(cropIcon, cropName)
    self:applySlotCropIcon(coverIcon, coverCropName)

    local hasCrop = cropName ~= nil and cropName ~= ""
    local hasCover = coverCropName ~= nil and coverCropName ~= ""
    local axisX = RealisticCropRotationFrame.CALENDAR_AXIS_X
    local harvestBar = self.calendarHarvestBar[slotIdx]
    local harvestBarContinuation = self.calendarHarvestBarContinuation[slotIdx]

    local SOW_Y, HARVEST_Y, COVER_Y, LANE_H = 3, 17, 31, 10

    local function placeBar(bar, run, y, visible)
        local show = visible and run ~= nil and run.len > 0
        bar:setVisible(show)
        if show then
            local startP = run.start
            local lenP = run.len

            -- Inset each end by its bounding grid-line width so the bar sits between lines.
            local leftInset  = self:getCalendarGridLineWidth(startP)
            local rightInset = self:getCalendarGridLineWidth(startP + lenP)
            local x = axisX + ((startP - 1) * periodW) + leftInset
            local w = (lenP * periodW) - leftInset - rightInset
            self:setElementPixelPosition(bar, x, y)
            self:setElementPixelSize(bar, math.max(4, w), LANE_H)

            -- Snap the bar edges to the bounding grid lines (avoids 1px rounding mismatch).
            local leftLine = self.calendarMonthGridLine[startP]
            local rightLine = self.calendarMonthGridLine[startP + lenP]
            local leftEdge = leftLine.absPosition[1] + leftLine.absSize[1]
            local rightEdge = rightLine.absPosition[1]
            bar:setPosition(leftEdge - bar.parent.absPosition[1], nil)
            bar:setSize(math.max(0.0001, rightEdge - leftEdge), nil)
        end
    end

    local function placeRuns(primaryBar, continuationBar, flags, y, visible)
        local runs = self:getFlagRuns(flags, periodCount)
        placeBar(primaryBar, runs[1], y, visible)
        placeBar(continuationBar, runs[2], y, visible)
    end

    local plantFlags, harvestFlags = self:getCropPeriodFlags(cropName, periodCount, firstPeriod)
    placeRuns(cropBar, cropBarContinuation, plantFlags, SOW_Y, hasCrop)
    placeRuns(harvestBar, harvestBarContinuation, harvestFlags, HARVEST_Y, hasCrop)

    -- Cover crops use the middle lane and are never harvested.
    local coverFlags = nil
    if hasCover then
        coverFlags = self:getCropPeriodFlags(coverCropName, periodCount, firstPeriod)
    end
    local coverColor = RealisticCropRotationFrame.FAMILY_RGBA[self:getCropFamily(coverCropName)]
        or RealisticCropRotationFrame.FAMILY_RGBA.COVER
    coverMarker.color = coverColor
    coverMarkerContinuation.color = coverColor
    placeRuns(coverMarker, coverMarkerContinuation, coverFlags, COVER_Y, hasCover)
end

---Returns a defensive 4-slot copy of a plan (empty strings for gaps).
-- @param table plan
-- @return table copy
function RealisticCropRotationFrame:copyFourSlotPlan(plan)
    local copy = {"", "", "", ""}
    for i = 1, 4 do
        copy[i] = plan ~= nil and (plan[i] or "") or ""
    end
    return copy
end

---Returns the clamped calendar editor slot index (1-4).
-- @return integer slotIdx
function RealisticCropRotationFrame:getCalendarEditSlotIndex()
    local slotIdx = math.floor(tonumber(self.calendarEditSlotIdx) or 1)
    slotIdx = math.max(1, math.min(4, slotIdx))
    self.calendarEditSlotIdx = slotIdx
    return slotIdx
end

---Sets a selector's state to the index of a crop in its list (1 when absent).
-- @param table selector
-- @param table list Crop name list
-- @param string cropName
function RealisticCropRotationFrame:setSelectorStateFromCrop(selector, list, cropName)
    local state = 1
    for idx, name in ipairs(list) do
        if name == cropName then state = idx; break end
    end
    selector:setState(state, false)
end

function RealisticCropRotationFrame:updateCalendarEditorSelectorsFromSlot()
    local slotIdx = self:getCalendarEditSlotIndex()
    self:setSelectorStateFromCrop(
        self.calendarEditCropSelector,
        self.planCropList,
        self.calendarLocalPlan[slotIdx] or ""
    )
    self:setSelectorStateFromCrop(
        self.calendarEditCoverSelector,
        self.coverCropList,
        self.calendarLocalCoverPlan[slotIdx] or ""
    )
end

function RealisticCropRotationFrame:renderCalendarFromLocalPlans()
    local plan = self.calendarLocalPlan or {"", "", "", ""}
    local coverPlan = self.calendarLocalCoverPlan or {"", "", "", ""}
    local periodCount, firstPeriod, periodW = self:updateCalendarAxis()

    for i = 1, 4 do
        self:applyCalendarRow(i, plan[i] or "", coverPlan[i] or "", periodCount, firstPeriod, periodW)
    end

    self:updateScoreCard(plan, coverPlan)
    self:updatePlannedResiduePill(self.planStatusPillBg, self.planStatusPillText, plan, coverPlan)
    self:layoutHeroPills(self.planTitle, self.planStatusPillBg)
end

---Loads a farmland's plans into the local editor state and renders the calendar.
-- @param integer farmlandId
function RealisticCropRotationFrame:updateCalendar(farmlandId)
    self.calendarLocalPlan = self:copyFourSlotPlan(self:getPlanForFarmland(farmlandId))
    self.calendarLocalCoverPlan = self:copyFourSlotPlan(self:getCoverPlanForFarmland(farmlandId))
    self:updateCalendarEditorSelectorsFromSlot()
    self:renderCalendarFromLocalPlans()
end

---Builds the main plan with the active slot overridden by the crop selector.
-- @return table plan
function RealisticCropRotationFrame:getPlanFromSelectors()
    return self:getPlanFromSelector(false)
end

---Builds the cover plan with the active slot overridden by the cover selector.
-- @return table coverPlan
function RealisticCropRotationFrame:getCoverPlanFromSelectors()
    return self:getPlanFromSelector(true)
end

---Builds a main or cover plan with the active slot overridden by its selector.
-- @param boolean isCover True for the cover-crop plan
-- @return table plan
function RealisticCropRotationFrame:getPlanFromSelector(isCover)
    local sourcePlan = self.calendarLocalPlan
    local selector = self.calendarEditCropSelector
    local cropList = self.planCropList
    if isCover then
        sourcePlan = self.calendarLocalCoverPlan
        selector = self.calendarEditCoverSelector
        cropList = self.coverCropList
    end
    if sourcePlan == nil and self.selectedId ~= nil then
        if isCover then
            sourcePlan = self:getCoverPlanForFarmland(self.selectedId)
        else
            sourcePlan = self:getPlanForFarmland(self.selectedId)
        end
    end
    local plan = self:copyFourSlotPlan(sourcePlan)
    local slotIdx = self:getCalendarEditSlotIndex()
    plan[slotIdx] = cropList[selector:getState()] or ""
    return plan
end

function RealisticCropRotationFrame:onServerSyncReceived()
    if self.isApplyingServerSync then
        return
    end

    self.isApplyingServerSync = true

    if self:isHistoryTab() then
        self:populateSidebar()
    else
        self:buildRotationGroups()
        self.listPlanOverview:reloadData()
        if self.selectedId ~= nil then
            self:updateCalendar(self.selectedId)
        end
    end

    self.isApplyingServerSync = false
end

---Sets a crop icon element to the crop's HUD overlay, or hides it.
-- @param table iconEl
-- @param string cropName
-- @return boolean loaded
function RealisticCropRotationFrame:applySlotCropIcon(iconEl, cropName)
    if iconEl == nil then return false end
    if cropName == nil or cropName == "" then
        iconEl:setVisible(false)
        return false
    end
    if isFallowCrop(cropName) then
        iconEl:setVisible(false)
        return false
    end

    local hudOverlayFilename = nil
    local fillType = self:getFillTypeForCrop(cropName)
    if fillType ~= nil and fillType.hudOverlayFilename ~= nil then
        hudOverlayFilename = fillType.hudOverlayFilename
    elseif g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil then
        local fruitType = g_fruitTypeManager:getFruitTypeByName(string.upper(cropName))
        if fruitType ~= nil and fruitType.fillType ~= nil
            and fruitType.fillType.hudOverlayFilename ~= nil then
            hudOverlayFilename = fruitType.fillType.hudOverlayFilename
        end
    end

    local loaded = false
    if hudOverlayFilename ~= nil then
        if iconEl.setImageFilename ~= nil then
            iconEl:setImageFilename(hudOverlayFilename)
        end
        if iconEl.setImageUVs ~= nil then
            iconEl:setImageUVs(nil, 0, 0, 0, 1, 1, 0, 1, 1)
        end
        iconEl:setVisible(true)
        loaded = true
    end
    if not loaded then iconEl:setVisible(false) end
    return loaded
end

function RealisticCropRotationFrame:onChangeCalendarEditStep()
    if self.isApplyingServerSync then return end
    self.calendarEditSlotIdx = self:getCalendarEditSlotIndex()
    self:updateCalendarEditorSelectorsFromSlot()
    self:renderCalendarFromLocalPlans()
end

---Selects a calendar row when its row button is clicked.
-- @param table button The clicked row button
function RealisticCropRotationFrame:onCalendarRowClicked(button)
    if self.isApplyingServerSync then return end

    for slotIdx, rowButton in ipairs(self.calendarRowButton) do
        if rowButton == button then
            self.calendarEditSlotIdx = slotIdx
            self:onChangeCalendarEditStep()
            break
        end
    end
end

function RealisticCropRotationFrame:onChangeCalendarEditCrop()
    self:handleCalendarCropChange(self:getCalendarEditSlotIndex())
end

function RealisticCropRotationFrame:onChangeCalendarEditCover()
    self:handleCalendarCoverChange(self:getCalendarEditSlotIndex())
end

---Writes a slot's main crop (event on MP client, direct on server) and refreshes the UI.
-- @param integer slotIdx Slot 1-4
function RealisticCropRotationFrame:handleCalendarCropChange(slotIdx)
    self:handleCalendarPlanChange(slotIdx, false)
end

---Writes a slot's cover crop (event on MP client, direct on server) and refreshes the UI.
-- @param integer slotIdx Slot 1-4
function RealisticCropRotationFrame:handleCalendarCoverChange(slotIdx)
    self:handleCalendarPlanChange(slotIdx, true)
end

---Writes a main or cover crop slot and refreshes the calendar and overview.
-- @param integer slotIdx Slot 1-4
-- @param boolean isCover True for the cover-crop plan
function RealisticCropRotationFrame:handleCalendarPlanChange(slotIdx, isCover)
    if self.isApplyingServerSync then return end
    if self.selectedId == nil then return end
    local selector = self.calendarEditCropSelector
    local cropList = self.planCropList
    local localPlanField = "calendarLocalPlan"
    if isCover then
        selector = self.calendarEditCoverSelector
        cropList = self.coverCropList
        localPlanField = "calendarLocalCoverPlan"
    end

    local isClientOnly = not g_currentMission:getIsServer()
    local connection = nil
    if isClientOnly then
        connection = g_client:getServerConnection()
        if connection == nil then
            Logging.warning(isCover
                and "[RealisticCropRotation][MP] Cover plan update not sent: no server connection"
                or "[RealisticCropRotation][MP] Plan update not sent: no server connection")
            self:updateCalendar(self.selectedId)
            return
        end
    end

    local cropName = cropList[selector:getState()] or ""
    self[localPlanField] = self:copyFourSlotPlan(self[localPlanField])
    self[localPlanField][slotIdx] = cropName
    if isClientOnly then
        connection:sendEvent(RCRPlanUpdateEvent.new(self.selectedId, slotIdx, cropName, isCover))
    else
        local mgr = self:getManager()
        local changed
        if isCover then
            changed = mgr:setRotationCoverPlanYear(self.selectedId, slotIdx, cropName)
        else
            changed = mgr:setRotationPlanYear(self.selectedId, slotIdx, cropName)
        end
        if changed and RealisticCropRotation ~= nil and RealisticCropRotation.requestBroadcast ~= nil then
            RealisticCropRotation.requestBroadcast()
        end
    end

    self:renderCalendarFromLocalPlans()

    self:buildRotationGroups()
    self.listPlanOverview:reloadData()
end

function RealisticCropRotationFrame:onClickClearPlan()
    if self.selectedId == nil or YesNoDialog == nil then return end

    local farmlandName = tostring(self.selectedId)
    for _, entry in ipairs(self.farmlandList or {}) do
        if entry.farmlandId == self.selectedId then farmlandName = entry.name or farmlandName break end
    end

    local farmlandId = self.selectedId
    YesNoDialog.show(function(yes)
        if yes then self:clearPlanForFarmland(farmlandId) end
    end, self, string.format(self.i18n:getText("rcr_clear_plan_confirm"), farmlandName))
end

---Clears a farmland's rotation plan (event on MP client, direct on server) and refreshes the UI.
-- @param integer farmlandId
function RealisticCropRotationFrame:clearPlanForFarmland(farmlandId)
    local isClientOnly = not g_currentMission:getIsServer()

    if isClientOnly then
        local connection = g_client:getServerConnection()
        if connection == nil then
            Logging.warning("[RealisticCropRotation][MP] Plan clear not sent: no server connection")
            if farmlandId == self.selectedId then
                self:updateCalendar(farmlandId)
            end
            return
        end
        for slotIdx = 1, 4 do
            connection:sendEvent(RCRPlanUpdateEvent.new(farmlandId, slotIdx, "", false))
            connection:sendEvent(RCRPlanUpdateEvent.new(farmlandId, slotIdx, "", true))
        end
    else
        local changed = self:getManager():clearRotationPlan(farmlandId)
        if changed and RealisticCropRotation ~= nil and RealisticCropRotation.requestBroadcast ~= nil then
            RealisticCropRotation.requestBroadcast()
        end
    end

    if farmlandId == self.selectedId then
        self.calendarLocalPlan = {"", "", "", ""}
        self.calendarLocalCoverPlan = {"", "", "", ""}
        self:renderCalendarFromLocalPlans()
    end

    self:buildRotationGroups()
    self.listPlanOverview:reloadData()
end

---Updates the rotation score card (number + label) from a plan.
-- @param table plan
-- @param table coverPlan
function RealisticCropRotationFrame:updateScoreCard(plan, coverPlan)
    plan = plan or {"","","",""}
    coverPlan = coverPlan or {"","","",""}

    local score    = self:calcRotationScore(plan, coverPlan)
    local scoreKey = self:getScoreTextKey(score, plan)
    self.scoreText:setText(self.i18n:getText(scoreKey))

    local trackW = 400
    local cursorW = 14
    local posW = math.floor((score / 100) * (trackW - cursorW) + cursorW)
    local posSize = GuiUtils ~= nil and GuiUtils.getNormalizedScreenValues ~= nil
        and GuiUtils.getNormalizedScreenValues(string.format("%dpx 14px", posW)) or nil
    if posSize ~= nil then self.scoreCursorPos:setSize(posSize[1], posSize[2]) end

    local _, r, g, b = self:getScoreLabel(score)
    self.scoreCursor.color = {r, g, b, 1.0}
end

---Scores a rotation 0-100 from family/pathogen spacing (fallow years included as spacing), legume->cereal sequencing, sowing alternation and restored nitrogen.
-- @param table plan
-- @param table coverPlan
-- @return integer score
function RealisticCropRotationFrame:calcRotationScore(plan, coverPlan)
    local cycleLength, hasInternalGap = PlannerModel.getCycleInfo(plan, 4)
    if hasInternalGap then return 0 end

    -- The contiguous plan prefix is the cycle. Fallow occupies a full spacing year.
    local slots = {}
    for i = 1, cycleLength do
        local crop = plan[i] or ""
        local family = self:getCropFamily(crop)
        if family == "FALLOW" then
            slots[#slots + 1] = { family = "FALLOW" }
        else
            slots[#slots + 1] = {
                family = family,
                diseases = self:getCropDiseases(crop),
                sowing = self:getCropSowingSeason(crop),
            }
        end
    end

    local m = #slots

    -- Real crops only (fallow is a break, not a crop): drives the rotation gate.
    local realIdx = {}
    for i = 1, m do
        if slots[i].family ~= "FALLOW" and slots[i].family ~= "UNKNOWN" then
            realIdx[#realIdx + 1] = i
        end
    end
    local n = #realIdx
    if n < 2 then return 0 end

    local seen = {}
    for _, i in ipairs(realIdx) do seen[slots[i].family] = true end
    local uniqueCount = 0
    for _ in pairs(seen) do uniqueCount = uniqueCount + 1 end

    local score = (n >= 3) and RealisticCropRotationFrame.SCORE_BASE_FULL
                            or  RealisticCropRotationFrame.SCORE_BASE_PARTIAL

    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or {}
    local familyPenalty = PlannerModel.calculateFamilyPenalty(
        slots,
        RealisticCropRotationFrame.FAMILY_MIN_INTERVAL,
        RealisticCropRotationFrame.SCORE_FAMILY_PENALTY_PER_YEAR)
    local diseasePenalty = PlannerModel.calculateDiseasePenalty(
        slots,
        RealisticCropRotationFrame.FAMILY_MIN_INTERVAL,
        config.diseasePlannerIntervals or {},
        config.diseaseRotationRelevant or {},
        RealisticCropRotationFrame.SCORE_DISEASE_PENALTY_PER_YEAR)
    score = score - familyPenalty - diseasePenalty

    if n >= 3 then
        -- Legume directly followed by a cereal (cyclic): the returned nitrogen is put to use; a fallow between them breaks the direct hand-off.
        for k = 1, m do
            local nextK = (k % m) + 1
            if slots[k].family == "LEGUME" and slots[nextK].family == "CEREAL" then
                score = score + RealisticCropRotationFrame.SCORE_LEGUME_CEREAL_BONUS
            end
        end
    end

    -- Sowing alternation: the cycle carries both a winter-sown and a spring-sown crop.
    local hasWinter, hasSpring = false, false
    for _, i in ipairs(realIdx) do
        if slots[i].sowing == "WINTER" then hasWinter = true
        elseif slots[i].sowing == "SPRING" then hasSpring = true end
    end
    if hasWinter and hasSpring then
        score = score + RealisticCropRotationFrame.SCORE_SOWING_ALTERNATION_BONUS
    end

    if self:getPlanNitrogenResidueKgHa(plan, coverPlan) ~= nil then
        score = score + RealisticCropRotationFrame.SCORE_RESIDUE_BONUS
    end

    -- A single-family plan is a monoculture: it stays "poor" even when the family carries no return-interval penalty.
    if uniqueCount == 1 then
        score = math.min(score, RealisticCropRotationFrame.SCORE_MONOCULTURE_CAP)
    end

    return math.max(0, math.min(100, math.floor(score + 0.5)))
end

---Returns the long score-description i18n key for a score/plan.
-- @param integer score
-- @param table plan
-- @return string i18nKey
function RealisticCropRotationFrame:getScoreTextKey(score, plan)
    local cycleLength, hasInternalGap = PlannerModel.getCycleInfo(plan, 4)
    if cycleLength == 0 and not hasInternalGap then return "rcr_plan_none" end
    if hasInternalGap then return "rcr_score_incomplete" end

    local cropCount = 0
    for i = 1, cycleLength do
        local crop = plan[i] or ""
        if crop ~= "" then
            local fam = self:getCropFamily(crop)
            if fam ~= "UNKNOWN" and fam ~= "FALLOW" then cropCount = cropCount + 1 end
        end
    end
    if cropCount < 2 then return "rcr_score_incomplete" end
    if score >= 80   then return "rcr_score_excellent" end
    if score >= 60   then return "rcr_score_good" end
    if score >= 40   then return "rcr_score_fair" end
    if score >= 20   then return "rcr_score_poor" end
    return "rcr_score_bad"
end

---Returns the short score badge key + RGB colour for a score.
-- @param integer score
-- @return string i18nKey
-- @return number r
-- @return number g
-- @return number b
function RealisticCropRotationFrame:getScoreLabel(score)
    if score >= 80 then return "rcr_score_short_optimal", 0.325, 0.565, 0.071
    elseif score >= 60 then return "rcr_score_short_good",  0.95,  0.85, 0.05
    elseif score >= 40 then return "rcr_score_short_fair",  0.75,  0.45, 0.05
    elseif score >= 20 then return "rcr_score_short_poor",  0.75,  0.20, 0.05
    else                    return "rcr_score_short_bad",   0.95,   0.0,  0.0
    end
end

function RealisticCropRotationFrame:buildRotationGroups()
    local groups   = {}
    local groupMap = {}

    for _, entry in ipairs(self.farmlandList or {}) do
        local plan = self:getPlanForFarmland(entry.farmlandId)
        local coverPlan = self:getCoverPlanForFarmland(entry.farmlandId)
        local key = (plan[1] or "") .. "|" .. (plan[2] or "")
                 .. "|" .. (plan[3] or "") .. "|" .. (plan[4] or "")
                 .. "||" .. (coverPlan[1] or "") .. "|" .. (coverPlan[2] or "")
                 .. "|" .. (coverPlan[3] or "") .. "|" .. (coverPlan[4] or "")

        if groupMap[key] == nil then
            table.insert(groups, {
                key        = key,
                plan       = plan,
                coverPlan  = coverPlan,
                fieldNames = {},
                areaHa     = 0,
                score      = self:calcRotationScore(plan, coverPlan),
                residueText = self:getPlanNitrogenResidueText(plan, coverPlan),
            })
            groupMap[key] = #groups
        end
        local group = groups[groupMap[key]]
        table.insert(group.fieldNames, entry.name)
        group.areaHa = (group.areaHa or 0) + (tonumber(entry.areaHa) or 0)
    end

    -- Unplanned rotations always sort last, regardless of field number.
    for i, group in ipairs(groups) do
        group.originalIndex = i
        group.isUnplanned = (group.plan[1] or "") == "" and (group.plan[2] or "") == ""
            and (group.plan[3] or "") == "" and (group.plan[4] or "") == ""
    end
    table.sort(groups, function(a, b)
        if a.isUnplanned ~= b.isUnplanned then return not a.isUnplanned end
        return a.originalIndex < b.originalIndex
    end)

    self.rotationGroups = groups
end

---Joins field names into one upper-cased "A | B | C" string.
-- @param table fieldNames
-- @return string text
function RealisticCropRotationFrame:getCompactGroupFieldNames(fieldNames)
    local parts = {}
    for i = 1, #(fieldNames or {}) do
        table.insert(parts, string.upper(tostring(fieldNames[i] or "")))
    end

    return table.concat(parts, "  |  ")
end

---Returns the first and last filled slot indices of a plan.
-- @param table plan
-- @return integer firstFilled, or nil
-- @return integer lastFilled, or nil
function RealisticCropRotationFrame:getPlanBounds(plan)
    local firstFilled, lastFilled = nil, nil
    for i = 1, 4 do
        if (plan ~= nil and (plan[i] or "") or "") ~= "" then
            firstFilled = firstFilled or i
            lastFilled = i
        end
    end
    return firstFilled, lastFilled
end

---Resolves how one overview slot renders: crop badge, unplanned slot, or hidden empty plan.
-- @param table group
-- @param integer slotIndex
-- @param integer firstFilled
-- @param integer lastFilled
-- @return boolean showSlot
-- @return boolean hasCrop
-- @return string displayText
-- @return string cropName
function RealisticCropRotationFrame:getGroupSlotDisplay(group, slotIndex, firstFilled, lastFilled)
    local plan = group ~= nil and group.plan or nil
    local cropName = plan ~= nil and (plan[slotIndex] or "") or ""
    if cropName ~= "" then
        return true, true, self:getCropDisplayName(cropName), cropName
    end

    if firstFilled ~= nil and lastFilled ~= nil then
        return true, false, self.i18n:getText("rcr_plan_none"), ""
    end

    return false, false, "", ""
end

---Lays out one overview crop badge (icon + centred label) and returns its width.
-- @param table cell
-- @param integer slotIndex
-- @param string displayText
-- @param number badgeX Override x position, or nil
-- @param boolean showIcon Defaults to true
-- @return number badgeWidth, or nil
function RealisticCropRotationFrame:layoutGroupBadgeContent(cell, slotIndex, displayText, badgeX, showIcon)
    if cell == nil or cell.getAttribute == nil then return end
    if GuiUtils == nil or GuiUtils.getNormalizedScreenValues == nil then return end
    if getTextWidth == nil then return end

    if showIcon == nil then showIcon = true end

    local iconEl  = cell:getAttribute("gCropIcon" .. slotIndex)
    local coverIconBgEl = cell:getAttribute("gCoverIconBg" .. slotIndex)
    local coverIconEl = cell:getAttribute("gCoverIcon" .. slotIndex)
    local labelEl = cell:getAttribute("gLabel" .. slotIndex)
    local badgeEl = cell:getAttribute("gBadge" .. slotIndex)
    local yearLabelEl = cell:getAttribute("gYearLabel" .. slotIndex)
    if labelEl == nil or (showIcon and iconEl == nil) then return end

    local originalBadgePos = self:getElementOriginalPosition(badgeEl)
    if originalBadgePos == nil then return end

    local badgeSize = GuiUtils.getNormalizedScreenValues(string.format(
        "0px %dpx",
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

    local iconWidth = showIcon and iconSize[1] or 0
    local iconTextGap = showIcon and gapSize[1] or 0
    local textSafety = self:getNormalizedPixelWidth(RealisticCropRotationFrame.GROUP_BADGE_TEXT_SAFETY_PX)

    local badgeWidth = math.max(
        iconWidth + iconTextGap + paddingSize[1],
        iconWidth + iconTextGap + textWidth + textSafety + paddingSize[1]
    )
    local textBoxWidth = math.max(0, badgeWidth - iconWidth - iconTextGap - paddingSize[1])
    local renderedTextWidth = math.min(textWidth, textBoxWidth)
    local totalWidth = iconWidth + iconTextGap + renderedTextWidth
    local startX = badgePos[1] + (badgeWidth - totalWidth) * 0.5

    local iconYpx = RealisticCropRotationFrame.GROUP_BADGE_Y
        + math.floor((RealisticCropRotationFrame.GROUP_BADGE_H - RealisticCropRotationFrame.GROUP_ICON_H) * 0.5)
    local iconPosY = GuiUtils.getNormalizedScreenValues(string.format("0px -%gpx", iconYpx))[2]

    if badgeEl ~= nil and badgeEl.setPosition ~= nil and badgeEl.setSize ~= nil then
        badgeEl:setPosition(badgePos[1], badgePos[2])
        badgeEl:setSize(badgeWidth, badgeSize[2])
    end
    if yearLabelEl ~= nil and yearLabelEl.setPosition ~= nil and yearLabelEl.setSize ~= nil then
        yearLabelEl:setPosition(badgePos[1], yearLabelEl.position[2])
        yearLabelEl:setSize(badgeWidth, yearLabelEl.size[2])
    end

    if showIcon then
        iconEl:setPosition(startX, iconPosY)
    end
    labelEl:setPosition(startX + iconWidth + iconTextGap, badgePos[2])
    if labelEl.setSize ~= nil then
        labelEl:setSize(textBoxWidth, badgeSize[2])
    end
    if labelEl.setText ~= nil then
        labelEl:setText(displayText or "")
    end
    local coverCenterX = badgePos[1] + badgeWidth * 0.5
    for _, coverEl in pairs({coverIconBgEl, coverIconEl}) do
        if coverEl.setPosition ~= nil then
            local coverSize = self:getElementOriginalSize(coverEl)
            local coverPos = self:getElementOriginalPosition(coverEl)
            if coverSize ~= nil and coverPos ~= nil then
                coverEl:setPosition(coverCenterX - coverSize[1] * 0.5, coverPos[2])
            end
        end
    end

    return badgeWidth
end

---Returns the original gaps before/after a slot's connector arrow (normalized units).
-- @param table cell
-- @param integer slotIndex
-- @return number gapBeforeArrow
-- @return number gapAfterArrow
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

---Lays out a whole overview group row: badges, connector arrows, packed left-to-right.
-- @param table cell
-- @param table group
function RealisticCropRotationFrame:layoutGroupRow(cell, group)
    if cell == nil or cell.getAttribute == nil or group == nil then return end

    local firstFilled, lastFilled = self:getPlanBounds(group.plan)
    local currentX = nil
    for i = 1, 4 do
        local showSlot, hasCrop, displayName = self:getGroupSlotDisplay(group, i, firstFilled, lastFilled)

        if showSlot then
            local badgeEl = cell:getAttribute("gBadge" .. i)
            local originalBadgePos = self:getElementOriginalPosition(badgeEl)
            currentX = currentX or (originalBadgePos ~= nil and originalBadgePos[1] or nil)

            local gapBeforeArrow, gapAfterArrow = 0, 0
            if i < 4 then
                gapBeforeArrow, gapAfterArrow = self:getGroupConnectorGaps(cell, i)
            end

            local showIcon = hasCrop and not isFallowCrop(group.plan ~= nil and group.plan[i] or nil)
            local badgeWidth = self:layoutGroupBadgeContent(cell, i, displayName, currentX, showIcon)

            if badgeWidth ~= nil and currentX ~= nil and i < 4 then
                local nextVisible = self:getGroupSlotDisplay(group, i + 1, firstFilled, lastFilled)
                local arrowEl = cell:getAttribute("gArrow" .. i)
                if arrowEl ~= nil then
                    arrowEl:setVisible(nextVisible)
                    if nextVisible then
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

---Fills an overview group cell: crop badges, cover icons, count, area, score, residue and field names.
-- @param integer index Group index
-- @param table cell
function RealisticCropRotationFrame:populateGroupCell(index, cell)
    if cell == nil or cell.getAttribute == nil then return end
    local group = (self.rotationGroups or {})[index]
    if group == nil then return end
    local isEmptyGroup = group.key == "||||||||"

    local summaryEl = cell:getAttribute("gPlanSummary")
    if summaryEl ~= nil then
        summaryEl:setVisible(isEmptyGroup)
        if isEmptyGroup then
            summaryEl:setText(self.i18n:getText("rcr_plan_none"))
        end
    end

    local firstFilled, lastFilled = self:getPlanBounds(group.plan)
    for i = 1, 4 do
        local show, hasCrop, displayName, cropName = self:getGroupSlotDisplay(group, i, firstFilled, lastFilled)
        local family = hasCrop and self:getCropFamily(cropName) or nil

        local badgeEl = cell:getAttribute("gBadge" .. i)
        if badgeEl ~= nil then
            badgeEl:setVisible(show)
            if show then
                if hasCrop then
                    local c = RealisticCropRotationFrame.FAMILY_RGBA[family] or {0.20, 0.20, 0.20, 0.60}
                    badgeEl.color = {c[1], c[2], c[3], 0.55}
                else
                    badgeEl:applyProfile("frGroupBadge")
                end
            end
        end

        local iconEl = cell:getAttribute("gCropIcon" .. i)
        if iconEl ~= nil then
            if hasCrop then
                self:applySlotCropIcon(iconEl, cropName)
            else
                iconEl:setVisible(false)
            end
        end

        local labelEl = cell:getAttribute("gLabel" .. i)
        if labelEl ~= nil then
            labelEl:setVisible(show)
            if show then
                labelEl:setText(displayName)
            end
        end

        local yearLabelEl = cell:getAttribute("gYearLabel" .. i)
        if yearLabelEl ~= nil then yearLabelEl:setVisible(show and not isEmptyGroup) end

        local coverIconBgEl = cell:getAttribute("gCoverIconBg" .. i)
        local coverIconEl = cell:getAttribute("gCoverIcon" .. i)
        if coverIconEl ~= nil then
            local coverName = group.coverPlan ~= nil and (group.coverPlan[i] or "") or ""
            local coverLoaded = false
            if show and coverName ~= "" then
                coverLoaded = self:applySlotCropIcon(coverIconEl, coverName)
            else
                coverIconEl:setVisible(false)
            end
            if coverIconBgEl ~= nil then
                coverIconBgEl:setVisible(false)
                if coverLoaded and g_fruitTypeManager ~= nil
                    and type(g_fruitTypeManager.getFruitTypeByName) == "function" then
                    local coverFruitType = g_fruitTypeManager:getFruitTypeByName(string.upper(coverName))
                    local nativeColor = self:getFruitTypeMapColor(coverFruitType)
                    if nativeColor ~= nil then
                        self:applyIconBackgroundColor(coverIconBgEl, nativeColor)
                    end
                end
            end
        end
    end

    self:layoutGroupRow(cell, group)

    local countEl = cell:getAttribute("gCount")
    if countEl ~= nil then
        countEl:setText("x " .. #group.fieldNames)
    end
    local areaEl = cell:getAttribute("gArea")
    if areaEl ~= nil then
        areaEl:setText(self:formatAreaHa(group.areaHa))
    end

    -- Unplanned rotations show no badge (calcRotationScore floors to 0, which reads as "Bad").
    local scoreEl = cell:getAttribute("gScore")
    if scoreEl ~= nil then
        local scoreLabel, r, g, b = "", 1, 1, 1
        if not group.isUnplanned then
            local scoreLabelKey
            scoreLabelKey, r, g, b = self:getScoreLabel(group.score)
            scoreLabel = scoreLabelKey ~= nil and self.i18n:getText(scoreLabelKey) or ""
        end
        scoreEl:setText(scoreLabel)
        if scoreEl.setVisible ~= nil then scoreEl:setVisible(scoreLabel ~= "") end
        scoreEl.textColor = {r, g, b, 1.0}
    end

    local residueCardEl = cell:getAttribute("gResidueCard")
    local residueBgEl = cell:getAttribute("gResidueBg")
    local residueTextEl = cell:getAttribute("gResidueText")
    local residueText = group.residueText
    if residueCardEl ~= nil then
        residueCardEl:setVisible(residueText ~= nil)
    end
    if residueTextEl ~= nil and residueText ~= nil then
        residueTextEl:setText(residueText)
        local residueWidth = self:resizePillToText(residueBgEl, residueTextEl, residueText, { minWidthPx = 228 })
        if residueWidth ~= nil and residueCardEl ~= nil and residueCardEl.setSize ~= nil then
            residueCardEl:setSize(residueWidth, residueCardEl.size[2])
        end
    end
    local metaColumnEl = cell:getAttribute("gMetaColumn")
    if metaColumnEl ~= nil and metaColumnEl.invalidateLayout ~= nil then
        metaColumnEl:invalidateLayout()
    end

    local namesEl = cell:getAttribute("gFieldNames")
    if namesEl ~= nil then
        namesEl:setText(self:getCompactGroupFieldNames(group.fieldNames))
    end

end
