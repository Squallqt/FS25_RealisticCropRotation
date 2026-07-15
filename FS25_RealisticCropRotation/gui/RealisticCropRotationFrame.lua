-- Copyright © 2026 Squallqt. All rights reserved.
-- In-game menu page: rotation history, planning calendar, agronomy/disease panels and the fields overview.
RealisticCropRotationFrame = {}
local RealisticCropRotationFrame_mt = Class(RealisticCropRotationFrame, TabbedMenuFrameElement)

-- Internal tab indices
RealisticCropRotationFrame.TAB = { HISTORY = 1, PLANNING = 2 }
RealisticCropRotationFrame.HERO_PILL_MIN_W_PX = 96
RealisticCropRotationFrame.HERO_PILL_MAX_W_PX = 420
RealisticCropRotationFrame.HERO_PILL_TEXT_PADDING_PX = 24
RealisticCropRotationFrame.HERO_TITLE_PILL_GAP_PX = 24
local function isFallowCrop(cropName)
    return RealisticCropRotation ~= nil
        and type(RealisticCropRotation.isFallowCrop) == "function"
        and RealisticCropRotation.isFallowCrop(cropName)
end

local function getFamilyTextKey(family)
    if family == "COVER" then return "rcr_cover_crop" end
    if family == "FALLOW" then return "rcr_fallow" end
    return "rcr_family_" .. string.lower(family)
end

-- Crop family classification comes from cropConfig.xml, loaded once at mod init by main.lua.

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

RealisticCropRotationFrame.COVER_CROP_NAMES = {
    "OILSEEDRADISH",
    "FLOWERINGCATCHCROP",
}

-- Min recommended return interval (years) per family; FORAGE has no constraint.
RealisticCropRotationFrame.FAMILY_MIN_INTERVAL = {
    CEREAL    = 2,
    OILSEED   = 3,
    LEGUME    = 3,
    VEGETABLE = 3,
    ROOT      = 4,
}

RealisticCropRotationFrame.SCORE_BASE_FULL    = 60  -- 3+ crops: a real rotation pattern
RealisticCropRotationFrame.SCORE_BASE_PARTIAL = 40  -- only 2 crops
RealisticCropRotationFrame.SCORE_FAMILY_PENALTY_PER_YEAR = 20
RealisticCropRotationFrame.SCORE_LEGUME_CEREAL_BONUS = 8
RealisticCropRotationFrame.SCORE_DIVERSITY_BONUS_MAX = 25
RealisticCropRotationFrame.SCORE_RESIDUE_BONUS = 10  -- N-restoring crop/cover present
RealisticCropRotationFrame.SCORE_NO_RESIDUE_CAP = 79 -- no N returned: "excellent" stays locked
RealisticCropRotationFrame.SCORE_MONOCULTURE_CAP = 30 -- single-family plan: not a rotation, stays "poor"
RealisticCropRotationFrame.SCORE_DISEASE_PENALTY_PER_YEAR = 10 -- shared-pathogen spacing

-- Gauge tolerance: PF's own map legend can't show a gap this small, so treat it as "reached".
RealisticCropRotationFrame.PH_GAUGE_TOLERANCE = 0.1        -- pH units
RealisticCropRotationFrame.N_GAUGE_TOLERANCE_RATIO = 0.03  -- fraction of the crop's N requirement

-- Gap between a soil row's title and its gauge track.
RealisticCropRotationFrame.SOIL_ROW_TITLE_GAP_PX = 16

-- Global overview crop badge layout (pixel values, converted at runtime); centers the icon+text pair in the badge and leaves a safety margin for the text to avoid clipping.
RealisticCropRotationFrame.GROUP_BADGE_Y          = 18
RealisticCropRotationFrame.GROUP_BADGE_W          = 300
RealisticCropRotationFrame.GROUP_BADGE_H          = 30
RealisticCropRotationFrame.GROUP_ICON_W           = 20
RealisticCropRotationFrame.GROUP_ICON_H           = 20
RealisticCropRotationFrame.GROUP_ICON_TEXT_GAP    = 5
RealisticCropRotationFrame.GROUP_BADGE_PADDING_X  = 20
RealisticCropRotationFrame.GROUP_BADGE_TEXT_SAFETY_PX = 20

-- Annual calendar layout in pixels. The XML container is 1240 x 154 px.
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
end

---Unsubscribes and releases the frame.
function RealisticCropRotationFrame:delete()
    self:unsubscribeFarmlandChanges()
    self.farmlandList = nil
    self.weatherCard = nil
    RealisticCropRotationFrame:superClass().delete(self)
end

---Wires the list data sources/delegates once the GUI tree is built.
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

    if RealisticCropRotationWeatherCard ~= nil and self.weatherCard == nil then
        self.weatherCard = RealisticCropRotationWeatherCard.new(self, self.i18n)
        self.weatherCard:bind({
            root = self.headerWeatherPill,
            shadow = self.headerWeatherShadow,
            background = self.headerWeatherBg,
            accent = self.headerWeatherAccent,
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

    self:linkFocusNavigation()
    self:setupSectionLines()
end

---Lays out every section header's trailing line once (titles are static l10n text).
function RealisticCropRotationFrame:setupSectionLines()
    self:layoutSectionLine(self.historySectionLine, self.historySectionTitle)
    self:layoutSectionLine(self.adviceSectionLine, self.adviceSectionTitle)
    self:layoutSectionLine(self.soilSectionLine, self.soilSectionTitle)
    self:layoutSectionLine(self.fieldSectionLine, self.fieldSectionTitle)
    self:layoutSectionLine(self.planSectionLine, self.planSectionTitle)
    self:layoutSectionLine(self.scoreSectionLine, self.scoreSectionTitle)
    self:layoutSectionLine(self.overviewSectionLine, self.overviewSectionTitle, self.overviewTotalArea)
end

---Builds the sidebar view selector (history/planning tabs).
function RealisticCropRotationFrame:initialize()
    RealisticCropRotationFrame:superClass().initialize(self)

    -- Sidebar always lists fields, whichever sub-tab is active; the page title carries the mode.
    if self.viewSelector ~= nil then
        self.viewSelector:setTexts({
            self.i18n:getText("rcr_sidebar_fields"),
            self.i18n:getText("rcr_sidebar_fields"),
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

---Reconciles history (server), populates the sidebar and requests a server sync.
function RealisticCropRotationFrame:onFrameOpen()
    RealisticCropRotationFrame:superClass().onFrameOpen(self)
    self:subscribeFarmlandChanges()
    if g_currentMission ~= nil and g_currentMission:getIsServer() then
        local mgr = self:getManager()
        if mgr ~= nil and type(mgr.getOwnedFarmlands) == "function"
            and type(mgr.reconcileActiveCropForFarmland) == "function" then
            local changed = false
            for _, entry in ipairs(mgr:getOwnedFarmlands() or {}) do
                if mgr:reconcileActiveCropForFarmland(entry.farmlandId) then
                    changed = true
                end
            end
            if changed and RealisticCropRotation ~= nil
                and type(RealisticCropRotation.requestBroadcast) == "function" then
                RealisticCropRotation.requestBroadcast()
            end
        end
    end
    self:populateSidebar()
    self:layoutCalendarLegend()
    if RealisticCropRotation ~= nil and RealisticCropRotation.requestServerSync ~= nil then
        RealisticCropRotation.requestServerSync("frameOpen")
    end
    self:updateContainerVisibility()
    self:linkFocusNavigation()
end

---Unsubscribes from farmland change events when the frame closes.
function RealisticCropRotationFrame:onFrameClose()
    self:unsubscribeFarmlandChanges()
    RealisticCropRotationFrame:superClass().onFrameClose(self)
end

---Keeps the weather countdown synchronized while this menu frame is active.
-- @param integer dt Frame delta in milliseconds
function RealisticCropRotationFrame:update(dt)
    local superClass = RealisticCropRotationFrame:superClass()
    if superClass.update ~= nil then
        superClass.update(self, dt)
    end
    if self.weatherCard ~= nil then
        self.weatherCard:update(dt)
    end
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

-- HELPERS

---Returns the rotation manager from the current mission.
-- @return RealisticCropRotationManager manager, or nil
function RealisticCropRotationFrame:getManager()
    if g_currentMission == nil then return nil end
    return g_currentMission.realisticCropRotationManager
end

---Updates the detail-tab residue pill: crop residue (n1/n2) or catch-crop cover residue, in kg/ha.
-- @param table pillBg
-- @param table pillText
-- @param integer farmlandId
-- @return number width Resized pill width
function RealisticCropRotationFrame:updateResiduePill(pillBg, pillText, farmlandId)
    local text = self.i18n:getText("rcr_status_current_no_residue")
    local hasBonus = false

    local mgr = self:getManager()
    if mgr ~= nil and mgr.service ~= nil and type(mgr.getActiveCropInfo) == "function"
        and type(mgr.service.getResidueEntry) == "function"
        and type(mgr.service.getNitrogenKgPerHaFromStateChange) == "function" then
        local activeCropName, activeFruitTypeIndex = mgr:getActiveCropInfo(farmlandId)
        if activeCropName ~= nil and activeCropName ~= "" and not isFallowCrop(activeCropName) then
            local service = mgr.service
            local normalizedCropName = string.upper(tostring(activeCropName))
            local entry = service:getResidueEntry(normalizedCropName)
            if entry ~= nil and ((tonumber(entry.n1) or 0) + (tonumber(entry.n2) or 0)) > 0 then
                local n1Kg = math.floor((service:getNitrogenKgPerHaFromStateChange(tonumber(entry.n1) or 0) or 0) + 0.5)
                local n2Kg = math.floor((service:getNitrogenKgPerHaFromStateChange(tonumber(entry.n2) or 0) or 0) + 0.5)
                text = string.format(self.i18n:getText("rcr_status_current_residue"), n1Kg, n2Kg)
                hasBonus = true
            elseif type(service.isCoverCropForRotationHistory) == "function"
                and service:isCoverCropForRotationHistory(activeFruitTypeIndex, normalizedCropName) then
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
    end

    if pillBg ~= nil then
        pillBg:applyProfile(hasBonus and "frStatusPillBgBonus" or "frStatusPillBg")
    end
    if pillText ~= nil then
        pillText:setText(text)
    end
    return self:resizeHeroPillToText(pillBg, pillText, text)
end

---Total planned N residue (kg/ha) from a plan's crops + cover crops.
-- @param table plan 4-slot crop plan
-- @param table coverPlan 4-slot cover plan
-- @return number residueKgHa, or nil when none
function RealisticCropRotationFrame:getPlanNitrogenResidueKgHa(plan, coverPlan)
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

    if type(service.getCoverResidueKgHa) == "function" then
        local ok, coverResidueKgHa = pcall(service.getCoverResidueKgHa, service, coverPlan)
        if ok and type(coverResidueKgHa) == "number" and coverResidueKgHa > 0 then
            residueKgHa = residueKgHa + coverResidueKgHa
        end
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
    if pillBg ~= nil then
        pillBg:applyProfile(hasBonus and "frStatusPillBgBonus" or "frStatusPillBg")
    end
    if pillText ~= nil then
        pillText:setText(text)
    end
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
    local mgr = self:getManager()
    if mgr == nil or mgr.getOwnedFarmlands == nil then return {} end
    return mgr:getOwnedFarmlands() or {}
end

---Formats a hectare value as "X.X ha".
-- @param number areaHa
-- @return string text
function RealisticCropRotationFrame:formatAreaHa(areaHa)
    return string.format("%.1f ha", tonumber(areaHa) or 0)
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

---Refreshes the overview total-area label.
function RealisticCropRotationFrame:updateOverviewTotalArea()
    if self.overviewTotalArea == nil then return end
    local label = self.i18n:getText("rcr_overview_total_area")
    self.overviewTotalArea:setText(string.format(label, self.totalAreaHa or 0))
    self:layoutSectionLine(self.overviewSectionLine, self.overviewSectionTitle, self.overviewTotalArea)
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
-- @param number alignWidth Width to align the track start to (the wider of this row's and its sibling row's title), instead of this row's own title width; nil uses this row's own width.
-- @return number trackWidth normalized, or nil
function RealisticCropRotationFrame:layoutSoilGaugeTrack(titleElement, titleText, trackElement, fillElement, stateLabelElement, alignWidth)
    if titleElement == nil or trackElement == nil then return nil end

    local titlePos = self:getElementOriginalPosition(titleElement)
    local titleSize = self:getElementOriginalSize(titleElement)
    local trackPos = self:getElementOriginalPosition(trackElement)
    local trackSize = self:getElementOriginalSize(trackElement)
    if titlePos == nil or titleSize == nil or trackPos == nil or trackSize == nil then return nil end

    local textWidth = self:getTextRenderWidth(titleElement, titleText)
    if textWidth == nil then return nil end

    if titleElement.setSize ~= nil then
        titleElement:setSize(textWidth, titleSize[2])
    end

    local gap = self:getNormalizedPixelWidth(RealisticCropRotationFrame.SOIL_ROW_TITLE_GAP_PX)
    local newLeft = titlePos[1] + (alignWidth ~= nil and alignWidth or textWidth) + gap
    local rightEdge = trackPos[1] + trackSize[1]
    local newWidth = math.max(0, rightEdge - newLeft)

    trackElement:setPosition(newLeft, trackPos[2])
    trackElement:setSize(newWidth, trackSize[2])

    if fillElement ~= nil and fillElement.setPosition ~= nil then
        fillElement:setPosition(newLeft, trackPos[2])
    end

    if stateLabelElement ~= nil and stateLabelElement.setPosition ~= nil then
        local statePos = self:getElementOriginalPosition(stateLabelElement)
        if statePos ~= nil then
            stateLabelElement:setPosition(newLeft, statePos[2])
        end
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
    if lineEl == nil or titleEl == nil or lineEl.parent == nil then return end
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

---Shrinks the hero title so it never runs under the status pill.
-- @param table titleElement
-- @param table statusPillBg
function RealisticCropRotationFrame:layoutHeroPills(titleElement, statusPillBg)
    local hero = titleElement ~= nil and titleElement.parent or nil
    if hero == nil and statusPillBg ~= nil then hero = statusPillBg.parent end
    if hero == nil then return end

    local heroSize = self:getElementOriginalSize(hero)
    if heroSize == nil then return end

    local gap = self:getNormalizedPixelWidth(RealisticCropRotationFrame.HERO_TITLE_PILL_GAP_PX)

    local statusLeft = nil
    if statusPillBg ~= nil and statusPillBg.position ~= nil and statusPillBg.size ~= nil then
        statusLeft = heroSize[1] + statusPillBg.position[1] - statusPillBg.size[1]
    end

    if titleElement ~= nil and titleElement.setSize ~= nil then
        local titlePos = self:getElementOriginalPosition(titleElement)
        local titleSize = self:getElementOriginalSize(titleElement)
        if titlePos ~= nil and titleSize ~= nil then
            local titleLimit = heroSize[1]
            if statusLeft ~= nil then titleLimit = math.min(titleLimit, statusLeft) end
            local titleWidth = math.max(0, titleLimit - titlePos[1] - gap)
            titleElement:setSize(titleWidth, titleSize[2])
        end
    end
end

---Lays out the right-aligned calendar legend, right-to-left so item widths follow localized text.
function RealisticCropRotationFrame:layoutCalendarLegend()
    local container = self.calendarLegend
    if container == nil then return end
    if GuiUtils == nil or GuiUtils.getNormalizedScreenValues == nil then return end

    local containerSize = self:getElementOriginalSize(container)
    if containerSize == nil then return end

    if self.calendarLegendSwatchCover ~= nil then
        self.calendarLegendSwatchCover.color = RealisticCropRotationFrame.FAMILY_RGBA.COVER
    end

    -- Fixed pixel constants -> normalized units (computed once).
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

    -- Right-to-left placement order (reverse of visible reading order).
    local items = {
        {label = self.calendarLegendLabelCover,   swatch = self.calendarLegendSwatchCover,   key = "rcr_calendar_legend_cover"},
        {label = self.calendarLegendLabelHarvest, swatch = self.calendarLegendSwatchHarvest, key = "rcr_calendar_legend_harvest"},
        {label = self.calendarLegendLabelSow,     swatch = self.calendarLegendSwatchSow,     key = "rcr_calendar_legend_sowing"},
    }

    -- cursorX = right edge of the next (leftward) item, normalized, measured from the container's own left edge (anchorTopLeft).
    local cursorX = containerSize[1]
    for _, item in ipairs(items) do
        if item.label ~= nil and item.swatch ~= nil
            and item.label.setPosition ~= nil and item.swatch.setPosition ~= nil then
            local text = self.i18n:getText(item.key)
            item.label:setText(text)

            local textWidth = self:getTextRenderWidth(item.label, text) or 0
            local labelSize = self:getElementOriginalSize(item.label)
            local labelH = labelSize ~= nil and labelSize[2] or swatchH

            -- Layout (left to right within the item): label, gap, swatch.
            local swatchX = cursorX - swatchW
            local textX   = swatchX - gapW - textWidth

            item.swatch:setPosition(swatchX, swatchY)
            item.swatch:setSize(swatchW, swatchH)

            item.label:setPosition(textX, 0)
            item.label:setSize(textWidth, labelH)

            cursorX = textX - itemGap
        end
    end
end

---Sets the menu header title from the active tab.
function RealisticCropRotationFrame:updateMainHeaderTitle()
    if self.menuHeaderTitle == nil then return end
    local key = self:isHistoryTab() and "rcr_tab_history" or "rcr_tab_planning"
    self.menuHeaderTitle:setText(self.i18n:getText(key))
end

---Subscribes to FARMLAND_OWNER_CHANGED so the sidebar tracks ownership.
function RealisticCropRotationFrame:subscribeFarmlandChanges()
    if self.isSubscribedToFarmlandChanges then return end
    if self.messageCenter ~= nil and self.messageCenter.subscribe ~= nil
        and MessageType ~= nil and MessageType.FARMLAND_OWNER_CHANGED ~= nil then
        self.messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, self.onFarmlandOwnerChanged, self)
        self.isSubscribedToFarmlandChanges = true
    end
end

---Unsubscribes from FARMLAND_OWNER_CHANGED.
function RealisticCropRotationFrame:unsubscribeFarmlandChanges()
    if not self.isSubscribedToFarmlandChanges then return end
    if self.messageCenter ~= nil and self.messageCenter.unsubscribe ~= nil
        and MessageType ~= nil and MessageType.FARMLAND_OWNER_CHANGED ~= nil then
        self.messageCenter:unsubscribe(MessageType.FARMLAND_OWNER_CHANGED, self)
    end
    self.isSubscribedToFarmlandChanges = false
end

---FARMLAND_OWNER_CHANGED handler: rebuilds the sidebar.
function RealisticCropRotationFrame:onFarmlandOwnerChanged(_farmlandId, _farmId, _loadFromSavegame)
    self:populateSidebar()
end

---True when the history tab is the active sidebar view.
-- @return boolean
function RealisticCropRotationFrame:isHistoryTab()
    return self.viewSelector == nil
        or self.viewSelector:getState() == RealisticCropRotationFrame.TAB.HISTORY
end

---Shows/hides the empty, details and planning containers for the active tab.
function RealisticCropRotationFrame:updateContainerVisibility()
    local hasFields = #(self.farmlandList or {}) > 0
    local isHistory = self:isHistoryTab()
    if self.emptyText        ~= nil then self.emptyText:setVisible(not hasFields) end
    if self.detailsContainer ~= nil then self.detailsContainer:setVisible(hasFields and isHistory) end
    if self.planningContainer ~= nil then self.planningContainer:setVisible(hasFields and not isHistory) end
    self:updateMainHeaderTitle()
    if self.weatherCard ~= nil then self.weatherCard:refresh(true) end
end

---Links gamepad focus between the field list and the calendar editor selectors.
function RealisticCropRotationFrame:linkFocusNavigation()
    if FocusManager == nil then return end

    local hasFields = #(self.farmlandList or {}) > 0
    local cropSelector = self.calendarEditCropSelector
    local coverSelector = self.calendarEditCoverSelector

    if self.listFields ~= nil and FocusManager.RIGHT ~= nil then
        local target = (hasFields and not self:isHistoryTab()) and cropSelector or nil
        FocusManager:linkElements(self.listFields, FocusManager.RIGHT, target)
    end

    if cropSelector ~= nil and coverSelector ~= nil and FocusManager.RIGHT ~= nil then
        FocusManager:linkElements(cropSelector, FocusManager.RIGHT, coverSelector)
    end
    if coverSelector ~= nil and cropSelector ~= nil and FocusManager.LEFT ~= nil then
        FocusManager:linkElements(coverSelector, FocusManager.LEFT, cropSelector)
    end
    if cropSelector ~= nil and self.listFields ~= nil and FocusManager.LEFT ~= nil then
        FocusManager:linkElements(cropSelector, FocusManager.LEFT, self.listFields)
    end
end

---Returns the 4-slot rotation plan for a farmland (empty plan as fallback).
-- @param integer farmlandId
-- @return table plan
function RealisticCropRotationFrame:getPlanForFarmland(farmlandId)
    local mgr = self:getManager()
    if mgr ~= nil and mgr.getRotationPlan ~= nil then
        return mgr:getRotationPlan(farmlandId)
    end
    return {"","","",""}
end

---Returns the 4-slot cover plan for a farmland (empty plan as fallback).
-- @param integer farmlandId
-- @return table coverPlan
function RealisticCropRotationFrame:getCoverPlanForFarmland(farmlandId)
    local mgr = self:getManager()
    if mgr ~= nil and mgr.getRotationCoverPlan ~= nil then
        return mgr:getRotationCoverPlan(farmlandId)
    end
    return {"","","",""}
end

-- CROP LIST (built once from fruitTypeManager; drives plan slot selectors)

---Builds the plantable-crop and cover-crop lists for the editor selectors.
function RealisticCropRotationFrame:buildPlanCropList()
    self.planCropList = {""}  -- index 1 = no crop
    self.coverCropList = {""}
    if RealisticCropRotation ~= nil and RealisticCropRotation.SPECIAL_CROP_FALLOW ~= nil then
        table.insert(self.planCropList, RealisticCropRotation.SPECIAL_CROP_FALLOW)
    end

    -- Only offer cover crops whose fruitType is registered on this map.
    for _, cropName in ipairs(RealisticCropRotationFrame.COVER_CROP_NAMES) do
        local available = g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil
            and g_fruitTypeManager:getFruitTypeByName(cropName) ~= nil
        if available then
            table.insert(self.coverCropList, cropName)
        end
    end

    -- All plantable crops on this map (harvestTransitions non-empty = harvestable).
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

    -- Wire the calendar editor selectors.
    local cropTexts = {}
    for _, cropName in ipairs(self.planCropList) do
        table.insert(cropTexts, cropName == "" and self.i18n:getText("rcr_plan_none")
                                               or self:getCropDisplayName(cropName))
    end

    if self.calendarEditCropSelector ~= nil then
        self.calendarEditCropSelector:setTexts(cropTexts)
        self.calendarEditCropSelector:setState(1, false)
    end

    local coverTexts = {}
    for _, cropName in ipairs(self.coverCropList) do
        table.insert(coverTexts, cropName == "" and self.i18n:getText("rcr_plan_none")
                                                or self:getCropDisplayName(cropName))
    end

    if self.calendarEditCoverSelector ~= nil then
        self.calendarEditCoverSelector:setTexts(coverTexts)
        self.calendarEditCoverSelector:setState(1, false)
    end
end

-- SIDEBAR — SmoothList data source

---Rebuilds the field list + overview, restoring the prior selection, and refreshes panels.
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

    local mgr      = self:getManager()

    -- Line 1: field name + area
    local nameEl = cell:getAttribute("fieldName")
    local areaEl = cell:getAttribute("fieldArea")
    if nameEl ~= nil then nameEl:setText(string.upper(tostring(entry.name or ""))) end
    if areaEl ~= nil then areaEl:setText(self:formatAreaHa(entry.areaHa)) end

    -- Real state, never history: active crop -> native ground state -> "no crop".
    local activeCropName = nil
    local activeFruitTypeIndex = nil
    if mgr ~= nil and type(mgr.getActiveCropInfo) == "function" then
        activeCropName, activeFruitTypeIndex = mgr:getActiveCropInfo(entry.farmlandId)
    elseif mgr ~= nil and mgr.getActiveCropName ~= nil then
        activeCropName = mgr:getActiveCropName(entry.farmlandId)
    end

    local iconFruitType = nil
    if activeFruitTypeIndex ~= nil and g_fruitTypeManager ~= nil
        and type(g_fruitTypeManager.getFruitTypeByIndex) == "function" then
        iconFruitType = g_fruitTypeManager:getFruitTypeByIndex(activeFruitTypeIndex)
    end
    if iconFruitType == nil and activeCropName ~= nil and g_fruitTypeManager ~= nil
        and type(g_fruitTypeManager.getFruitTypeByName) == "function" then
        iconFruitType = g_fruitTypeManager:getFruitTypeByName(tostring(activeCropName))
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

    -- No-crop fields: resolve the field status once (icon colour + text), MP-safe.
    local statusLabel, statusKind, statusIndex = nil, nil, nil
    if activeCropName == nil and mgr ~= nil
        and type(mgr.getCurrentFieldStatus) == "function" then
        statusLabel, statusKind, statusIndex = mgr:getCurrentFieldStatus(entry.farmlandId)
    end

    local iconBgColor = nil
    if iconFruitType ~= nil then
        iconBgColor = self:getFruitTypeMapColor(iconFruitType)
    elseif statusKind == "soil" then
        iconBgColor = self:getSoilStateMapColor(statusIndex)
    elseif statusKind == "ground" then
        iconBgColor = self:getGroundStateMapColor(statusIndex)
    end
    if iconBgReady then
        self:applyIconBackgroundColor(iconBgEl, iconBgColor)
    end

    local cropLineEl = cell:getAttribute("cropLine")
    if cropLineEl ~= nil then
        if activeCropName ~= nil then
            local family = self:getCropFamily(activeCropName)
            local line   = self:getCropDisplayName(activeCropName)
            if family ~= "UNKNOWN" then
                local badgeKey = getFamilyTextKey(family)
                line = line .. "  ·  " .. self.i18n:getText(badgeKey)
            end
            cropLineEl:setText(line)
        elseif statusLabel ~= nil and statusLabel ~= "" then
            cropLineEl:setText(statusLabel)
        else
            cropLineEl:setText(self.i18n:getText("rcr_sidebar_no_active_crop"))
        end
    end
end

---SmoothList delegate: updates the active panel when the field selection changes.
-- @param table _list
-- @param integer _section
-- @param integer index
-- @param table _cell
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

-- TAB SWITCHING

---View selector callback: switches the visible panel and restores focus.
function RealisticCropRotationFrame:onViewChanged()
    self:updateContainerVisibility()
    self:setMenuButtonInfoDirty()
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

-- DETAIL PANEL (tab 1 — history / current crop / nitrogen / advice / pH)

---Resolves the current timeline slot: active crop, else field status, else "no crop".
-- @param integer farmlandId
-- @return string cropName, or nil
-- @return string family
-- @return string fallbackText Status/empty text when there is no crop, or nil
function RealisticCropRotationFrame:getCurrentSlotData(farmlandId)
    local mgr = self:getManager()
    local activeCropName = nil
    if mgr ~= nil and type(mgr.getActiveCropName) == "function" then
        activeCropName = mgr:getActiveCropName(farmlandId)
    end

    if (activeCropName == nil or activeCropName == "") and RealisticCropRotation ~= nil
        and mgr ~= nil and type(mgr.isCurrentGapFallow) == "function" and mgr:isCurrentGapFallow(farmlandId) then
        activeCropName = RealisticCropRotation.SPECIAL_CROP_FALLOW
    end

    if activeCropName ~= nil and activeCropName ~= "" then
        return activeCropName, self:getCropFamily(activeCropName), nil
    end

    local statusLabel = nil
    if mgr ~= nil and type(mgr.getCurrentFieldStatus) == "function" then
        statusLabel = mgr:getCurrentFieldStatus(farmlandId)
    end
    if statusLabel ~= nil and statusLabel ~= "" then
        return nil, "UNKNOWN", statusLabel
    end

    return nil, "UNKNOWN", self.i18n:getText("rcr_sidebar_no_active_crop")
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

    if self.detailTitle ~= nil then
        self.detailTitle:setText(
            string.upper(tostring(entry.name or ""))
            .. "  |  "
            .. self:formatAreaHa(entry.areaHa)
        )
    end

    local mgr = self:getManager()
    self:updateResiduePill(self.statusPillBg, self.statusPillText, farmlandId)
    self:layoutHeroPills(self.detailTitle, self.statusPillBg)

    local history = (mgr ~= nil) and (mgr:getHistory(farmlandId) or {}) or {}

    -- Slot 1 = current crop; slots 2..5 = history N-1..N-4 (present on the left).
    local currentCropName, currentFamily, currentFallbackText = self:getCurrentSlotData(farmlandId)
    local currentBadgeKey = currentFamily == "COVER" and "rcr_cover_crop" or nil
    self:updateTimelineSlot(1, currentCropName, currentFamily, currentFallbackText, currentBadgeKey)

    for histIdx = 1, 4 do
        local hEntry   = history[histIdx]
        local cropName = hEntry and hEntry.crop or nil
        self:updateTimelineSlot(histIdx + 1, cropName, self:getCropFamily(cropName), nil)
    end

    -- Both soil gauges start at the same x (the wider of the two row titles) so neither track looks shorter just because its own label is narrower.
    local nitrogenTitleWidth = self:getTextRenderWidth(self.nitrogenRowTitle, self.i18n:getText("rcr_section_nitrogen"))
    local limeTitleWidth = self:getTextRenderWidth(self.limeRowTitle, self.i18n:getText("rcr_section_lime"))
    local sharedRowTitleWidth = (nitrogenTitleWidth ~= nil and limeTitleWidth ~= nil)
        and math.max(nitrogenTitleWidth, limeTitleWidth) or nil

    self:updateNitrogenGauge(farmlandId, sharedRowTitleWidth)
    self:updateSoilPHGauge(farmlandId, sharedRowTitleWidth)
    self:updateAdvice(currentFamily, farmlandId, currentCropName)
    self:updateFieldCard(farmlandId)
end

-- Timeline slot (slotId 1..5) — history tab

---Fills one history timeline slot: frame, avatar, crop name, family badge.
-- @param integer slotId Slot 1-5 (1 = current)
-- @param string cropName, or nil
-- @param string family
-- @param string fallbackText Text shown when no crop, or nil
-- @param string badgeTextKey Override badge i18n key, or nil
function RealisticCropRotationFrame:updateTimelineSlot(slotId, cropName, family, fallbackText, badgeTextKey)
    local pfx = "slot" .. tostring(slotId)
    local cardBg   = self[pfx .. "CardBg"]
    local frame    = self[pfx .. "Frame"]
    local avatarBg = self[pfx .. "AvatarBg"]
    local iconEl   = self[pfx .. "Icon"]
    local nameEl   = self[pfx .. "CropName"]
    local badgeBg  = self[pfx .. "BadgeBg"]
    local badgeTxt = self[pfx .. "BadgeText"]

    local hasCrop = cropName ~= nil and cropName ~= ""
    local dashOnly = not hasCrop and (fallbackText == nil or fallbackText == "")
    local familyColor = hasCrop and RealisticCropRotationFrame.FAMILY_RGBA[family] or nil

    if cardBg ~= nil then
        cardBg:setVisible(not dashOnly)
    end
    if frame ~= nil then
        frame:setVisible(not dashOnly)
    end

    if avatarBg ~= nil then
        avatarBg:setVisible(hasCrop)
        if hasCrop then
            -- Native crop color, not family color — the badge below already shows the family.
            local fruitType = g_fruitTypeManager ~= nil and type(g_fruitTypeManager.getFruitTypeByName) == "function"
                and g_fruitTypeManager:getFruitTypeByName(string.upper(cropName)) or nil
            local nativeColor = fruitType ~= nil and self:getFruitTypeMapColor(fruitType) or nil
            self:applyIconBackgroundColor(avatarBg, nativeColor or familyColor or RealisticCropRotationFrame.FAMILY_RGBA.FALLOW)
        end
    end

    if iconEl ~= nil then
        self:applySlotCropIcon(iconEl, cropName)
    end

    if nameEl ~= nil then
        if hasCrop then
            nameEl:applyProfile("frSlotCropName")
            nameEl:setText(self:getCropDisplayName(cropName))
        elseif dashOnly then
            nameEl:applyProfile("frSlotCropNameEmpty")
            nameEl:setText("-")
        else
            nameEl:applyProfile("frSlotCropNameCentered")
            nameEl:setText(fallbackText)
        end
    end

    local showBadge = hasCrop and (family ~= nil) and (family ~= "UNKNOWN")
    if badgeBg ~= nil then
        badgeBg:setVisible(showBadge)
        if showBadge and familyColor ~= nil then
            badgeBg.color = {familyColor[1], familyColor[2], familyColor[3], familyColor[4]}
        end
    end
    if badgeTxt ~= nil then
        badgeTxt:setVisible(showBadge)
        if showBadge then
            local familyText = self.i18n:getText(badgeTextKey or getFamilyTextKey(family))
            badgeTxt:setText(familyText)
            self:resizePillToText(badgeBg, badgeTxt, familyText)
        end
    end
end

---Returns false (soil not sampled), true (PF data available), or nil (no PF installed).
function RealisticCropRotationFrame:getSoilAnalysisState(farmlandId)
    local mgr = self:getManager()
    if mgr == nil then return nil end

    local hasAnalysedValue = false
    if type(mgr.getNitrogenLevel) == "function" then
        local actualN = mgr:getNitrogenLevel(farmlandId)
        if actualN == false then return false end
        hasAnalysedValue = hasAnalysedValue or actualN ~= nil
    end

    if type(mgr.getPHLevel) == "function" then
        local actualPH = mgr:getPHLevel(farmlandId)
        if actualPH == false then return false end
        hasAnalysedValue = hasAnalysedValue or actualPH ~= nil
    end

    return hasAnalysedValue and true or nil
end

-- Status bars (shared by the nitrogen and pH gauges)

---Sets a status bar fill width from a 0..1 ratio.
-- @param table barFill
-- @param number ratio Clamped to [0, 1]
-- @param number maxWidth Track width (normalized units) at ratio 1
function RealisticCropRotationFrame:setStatusBarFill(barFill, ratio, maxWidth)
    if barFill == nil then return end
    ratio = math.max(0, math.min(1, tonumber(ratio) or 0))
    maxWidth = math.max(0, tonumber(maxWidth) or 0)

    if barFill.setSize ~= nil then
        local fillSize = self:getElementOriginalSize(barFill)
        local height = fillSize ~= nil and fillSize[2] or 0
        barFill:setSize(maxWidth * ratio, height)
    end
    barFill:setVisible(maxWidth * ratio > 0)
end

-- Nitrogen gauge

---Updates the nitrogen gauge: PF average vs crop need, with a vanilla SPRAY_LEVEL fallback.
-- @param integer farmlandId
-- @param number sharedRowTitleWidth Shared row-title width (the wider of the N/pH titles), so both gauges align; nil falls back to this row's own title width.
function RealisticCropRotationFrame:updateNitrogenGauge(farmlandId, sharedRowTitleWidth)
    local mgr = self:getManager()
    local ratio = 0
    local labelKey = "rcr_n_none"
    local stateText = nil
    local valueText = nil

    -- Precision Farming path: false = soil not analysed ("not sampled"); nil = no PF -> vanilla fallback.
    if mgr ~= nil and mgr.getNitrogenLevel ~= nil then
        local actualN, targetN = mgr:getNitrogenLevel(farmlandId)
        if actualN == false then
            labelKey = "rcr_soil_value_unmeasured"
            stateText = self.i18n:getText("rcr_soil_value_unmeasured")
            valueText = self.i18n:getText("rcr_n_crop_need_unavailable")
            ratio = 0
        elseif actualN ~= nil then
            labelKey = "rcr_n_average_pf"
            stateText = string.format(self.i18n:getText("rcr_n_average_value"), actualN)
            if targetN ~= nil and targetN > 0 then
                -- Crop planted: fill against the requirement, full once reached (within tolerance).
                local tolerance = targetN * RealisticCropRotationFrame.N_GAUGE_TOLERANCE_RATIO
                ratio = math.min((actualN + tolerance) / targetN, 1)
                -- Bar is full within tolerance: say so instead of a "need" figure actual already exceeds.
                valueText = (ratio >= 1) and self.i18n:getText("rcr_n_full")
                    or string.format(self.i18n:getText("rcr_n_crop_need"), targetN)
            else
                -- No crop planted: empty gauge, just the soil's real average N.
                ratio = 0
            end
        end
    end

    -- Vanilla fallback: fertilisation level (SPRAY_LEVEL).
    if stateText == nil then
        local nLevel = 0
        local maxLevel = 1
        if mgr ~= nil and mgr.getCurrentNitrogenLevel ~= nil then
            nLevel, maxLevel = mgr:getCurrentNitrogenLevel(farmlandId)
        end

        nLevel = tonumber(nLevel) or 0
        maxLevel = math.max(1, tonumber(maxLevel) or 1)
        ratio = nLevel / maxLevel
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

    if self.nitrogenStateLabel ~= nil then
        self.nitrogenStateLabel:setText(stateText or self.i18n:getText(labelKey))
    end

    if self.nitrogenValueLabel ~= nil then
        if self.nitrogenValueLabel.applyProfile ~= nil then
            self.nitrogenValueLabel:applyProfile(labelKey == "rcr_soil_value_unmeasured"
                and "frSoilValueUnavailableTop" or "frSoilValueTop")
        end
        self.nitrogenValueLabel:setText(valueText or "")
        self.nitrogenValueLabel:setVisible(valueText ~= nil)
    end
end

-- Soil pH / lime gauge

---Updates the pH gauge: PF average vs soil optimal, with a vanilla LIME_LEVEL fallback.
-- @param integer farmlandId
-- @param number sharedRowTitleWidth Shared row-title width (the wider of the N/pH titles), so both gauges align; nil falls back to this row's own title width.
function RealisticCropRotationFrame:updateSoilPHGauge(farmlandId, sharedRowTitleWidth)
    local mgr = self:getManager()
    local ratio = 0
    local labelKey = "rcr_lime_none"
    local stateText = nil
    local valueText = nil

    if mgr ~= nil and mgr.getPHLevel ~= nil then
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
                -- Full once reached (within tolerance): PF's own map legend can't show a smaller gap.
                local tol = RealisticCropRotationFrame.PH_GAUGE_TOLERANCE
                ratio = targetPH > 0 and math.min((actualPH + tol) / targetPH, 1) or 0
                stateText = string.format(self.i18n:getText("rcr_lime_average_value"), actualPH)
                -- Bar is full within tolerance: say so instead of a target figure actual already meets.
                valueText = (ratio >= 1) and self.i18n:getText("rcr_lime_full")
                    or string.format(self.i18n:getText("rcr_lime_target"), targetPH)
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

    local trackWidth = self:layoutSoilGaugeTrack(self.limeRowTitle, self.i18n:getText("rcr_section_lime"),
        self.limeTrack, self.limeBarFill, self.limeStateLabel, sharedRowTitleWidth)
    self:setStatusBarFill(self.limeBarFill, ratio, trackWidth)

    if self.limeStateLabel ~= nil then
        self.limeStateLabel:setText(stateText or self.i18n:getText(labelKey))
    end

    if self.limeValueLabel ~= nil then
        if self.limeValueLabel.applyProfile ~= nil then
            self.limeValueLabel:applyProfile(labelKey == "rcr_soil_value_unmeasured"
                and "frSoilValueUnavailableBottom" or "frSoilValueBottom")
        end
        self.limeValueLabel:setText(valueText or "")
        self.limeValueLabel:setVisible(valueText ~= nil)
    end
end

-- Field card (soil work / weed / growth)

---Updates the field card: required soil work, weed line, and growth stage.
-- @param integer farmlandId
function RealisticCropRotationFrame:updateFieldCard(farmlandId)
    local mgr = self:getManager()
    local info = nil
    if mgr ~= nil and mgr.getFieldCropInfo ~= nil then
        info = mgr:getFieldCropInfo(farmlandId)
    end

    local hasStage = info ~= nil and info.growthStageText ~= nil
    local growthIsAction = info ~= nil and info.growthIsAction == true
    local hasWeed  = info ~= nil and info.weedActionText ~= nil
    local weedText  = hasWeed and info.weedActionText or "-"
    local stageText = hasStage and info.growthStageText or "-"

    -- Single source (getCurrentFieldStatus), shared with the sidebar, so the same state always gets the same label.
    local actionLabel, statusKind, statusIndex = nil, nil, nil
    if mgr ~= nil and type(mgr.getCurrentFieldStatus) == "function" then
        actionLabel, statusKind, statusIndex = mgr:getCurrentFieldStatus(farmlandId)
    end
    local hasAction = actionLabel ~= nil and actionLabel ~= ""
    local indices = MapOverlayGenerator ~= nil and MapOverlayGenerator.SOIL_STATE_INDEX or nil
    local isPriority = hasAction and statusKind == "soil" and indices ~= nil
        and (statusIndex == indices.NEEDS_PLOWING or statusIndex == indices.NEEDS_ROLLING)
    local actionText = hasAction and actionLabel or "-"

    if self.requiredActionValue ~= nil then
        if self.requiredActionValue.applyProfile ~= nil then
            -- Small size (18px) for any real text (avoids clipping); NA's 26px is only right for "-".
            local profile = isPriority and "frFieldKpiValueSmall"
                or (hasAction and "frFieldKpiValueSmallNA" or "frFieldKpiValueNA")
            self.requiredActionValue:applyProfile(profile)
        end
        self.requiredActionValue:setText(actionText)
    end

    -- Weed KPI reuses the on-foot HUD line: header = game stage label, value = tool.
    if self.weedHeaderText ~= nil then
        local headerText = (hasWeed and info.weedHeader ~= nil)
            and info.weedHeader
            or self.i18n:getText("rcr_weed_header")
        self.weedHeaderText:setText(headerText)
    end

    if self.weedValue ~= nil then
        if self.weedValue.applyProfile ~= nil then
            self.weedValue:applyProfile(hasWeed and "frFieldKpiValueSmall" or "frFieldKpiValueNA")
        end
        self.weedValue:setText(weedText)
    end

    if self.growthValue ~= nil then
        if self.growthValue.applyProfile ~= nil then
            -- Orange only when ready to prepare/harvest (an action); plain growing is grey.
            local profile = growthIsAction and "frFieldKpiValueSmall"
                or (hasStage and "frFieldKpiValueSmallNA" or "frFieldKpiValueNA")
            self.growthValue:applyProfile(profile)
        end
        self.growthValue:setText(stageText)
    end
end

-- Agronomic advice

---Refreshes the advice status/rotation card.
-- @param string currentFamily
-- @param integer farmlandId
-- @param string currentCropName
function RealisticCropRotationFrame:updateAdvice(currentFamily, farmlandId, currentCropName)
    if self.adviceText == nil then return end
    self:updateAdviceStatusCard(currentFamily, farmlandId, currentCropName)
end

---Finds the plan slot matching a crop name (first match wins, no disambiguation when a crop repeats).
-- @param table plan 4-slot plan
-- @param string cropName
-- @return integer slotIdx, or nil
function RealisticCropRotationFrame:findPlanSlotForCrop(plan, cropName)
    if plan == nil or cropName == nil or cropName == "" then return nil end
    local normalized = string.upper(tostring(cropName))
    for i = 1, 4 do
        if plan[i] == normalized then return i end
    end
    return nil
end

---Evaluates a one-year rotation step (cropA now, cropB next) for a conflict, using calcRotationScore's own rules.
-- @param string cropA Current crop name
-- @param string cropB Next-planned crop name
-- @return table conflict { kind = "family"|"disease", label, yearsRemaining, minInterval }, or nil
function RealisticCropRotationFrame:evaluateRotationStep(cropA, cropB)
    if cropA == nil or cropA == "" or cropB == nil or cropB == "" then return nil end
    if isFallowCrop(cropA) or isFallowCrop(cropB) then return nil end

    local famA = self:getCropFamily(cropA)
    local famB = self:getCropFamily(cropB)
    local familyMinInterval = (famA == famB and famA ~= "UNKNOWN")
        and RealisticCropRotationFrame.FAMILY_MIN_INTERVAL[famA] or nil
    -- A same-family pair's own interval floors the comparison, so the conflict reports only the interval left beyond the family rule.
    local diseaseBaseline = familyMinInterval ~= nil and math.max(1, familyMinInterval) or 1

    local diseasesA = self:getCropDiseases(cropA)
    local diseasesB = self:getCropDiseases(cropB)
    local diseaseIntervals = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig
        and RealisticCropRotation.cropConfig.diseaseIntervals or {}
    local worstGroup, worstMinInterval = nil, 0
    for group in pairs(diseasesA) do
        if diseasesB[group] then
            local minInterval = tonumber(diseaseIntervals[group])
            if minInterval ~= nil and diseaseBaseline < minInterval and minInterval > worstMinInterval then
                worstGroup, worstMinInterval = group, minInterval
            end
        end
    end

    if worstGroup ~= nil then
        local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
        local label = (disease ~= nil and type(disease.getDisplayName) == "function")
            and disease:getDisplayName(worstGroup) or tostring(worstGroup)
        return { kind = "disease", label = label, yearsRemaining = worstMinInterval - 1, minInterval = worstMinInterval }
    end

    if familyMinInterval ~= nil and familyMinInterval > 1 then
        return {
            kind = "family",
            label = self.i18n:getText(getFamilyTextKey(famA)),
            yearsRemaining = familyMinInterval - 1,
            minInterval = familyMinInterval,
        }
    end

    return nil
end

---Returns the pressure tip for the crop's single worst hosted disease (high beats moderate, ties by soil load), or nil.
-- @param integer farmlandId
-- @param string currentCropName
-- @return string text, or nil
function RealisticCropRotationFrame:getWorstPressureAdviceText(farmlandId, currentCropName)
    local cropDiseases = self:getCropDiseases(currentCropName)
    if next(cropDiseases) == nil then return nil end

    local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
    if disease == nil or type(disease.getLoad) ~= "function" then return nil end
    local D = RealisticCropRotationDisease
    if D == nil then return nil end

    local load = disease:getLoad(farmlandId)
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
        return self.i18n:getText(key)
    end
    return nil
end

---Refreshes the advice card: active outbreak > planned-step evaluation > per-family fallback, plus a soil-analysis note.
-- @param string currentFamily
-- @param integer farmlandId
-- @param string currentCropName
function RealisticCropRotationFrame:updateAdviceStatusCard(currentFamily, farmlandId, currentCropName)
    local visualState = "Neutral"
    local badgeSymbol = "i"
    local title = self.i18n:getText("rcr_advice_title_status")
    local text

    -- 1) Active outbreak: the worst infection actually happening on this field right now.
    local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
    local activeState = (disease ~= nil and type(disease.getState) == "function")
        and disease:getState(farmlandId) or nil
    local worstGroup, worstSeverity = nil, 0
    for group, s in pairs(activeState or {}) do
        if (s.severity or 0) > worstSeverity then
            worstGroup, worstSeverity = group, s.severity or 0
        end
    end

    if worstGroup ~= nil then
        visualState = "Danger"
        badgeSymbol = "!"
        title = self.i18n:getText("rcr_advice_title_outbreak")
        text = string.format(self.i18n:getText("rcr_advice_outbreak"),
            disease:getDisplayName(worstGroup),
            math.floor(worstSeverity * 100 + 0.5),
            disease:getTreatmentName(worstGroup))
    else
        -- 2) Planned-rotation-step evaluation, only for a real (non-fallow, known) current crop.
        local plan = self:getPlanForFarmland(farmlandId)
        local slotIdx = (currentFamily ~= "FALLOW" and currentFamily ~= "UNKNOWN")
            and self:findPlanSlotForCrop(plan, currentCropName) or nil
        local nextCrop = slotIdx ~= nil and plan[(slotIdx % 4) + 1] or nil
        nextCrop = (nextCrop ~= nil and nextCrop ~= "") and nextCrop or nil

        if nextCrop ~= nil then
            local nextSlotIdx = (slotIdx % 4) + 1
            local yearLabel = self.i18n:getText("rcr_plan_year" .. nextSlotIdx)
            local nextCropLabel = self:getCropDisplayName(nextCrop)
            local conflict = self:evaluateRotationStep(currentCropName, nextCrop)

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
        else
            -- 3) No confirmed next step: today's generic per-family advice, unchanged wording.
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

    if self.adviceCardBg ~= nil and self.adviceCardBg.applyProfile ~= nil then
        self.adviceCardBg:applyProfile("frAdviceCardBg" .. visualState)
    end
    if self.adviceStatusBadgeBg ~= nil and self.adviceStatusBadgeBg.applyProfile ~= nil then
        self.adviceStatusBadgeBg:applyProfile("frAdviceStatusBadgeBg" .. visualState)
    end
    if self.adviceTitle ~= nil and self.adviceTitle.applyProfile ~= nil then
        self.adviceTitle:applyProfile("frAdviceTitle" .. visualState)
    end
    if self.adviceStatusBadgeText ~= nil then
        self.adviceStatusBadgeText:setText(badgeSymbol)
    end
    if self.adviceTitle ~= nil then
        self.adviceTitle:setText(title)
    end
    self.adviceText:setText(text)
end

-- PLANNING PANEL (tab 2)

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

    if self.planTitle ~= nil then
        self.planTitle:setText(
            string.upper(tostring(entry.name or ""))
            .. "  |  "
            .. self:formatAreaHa(entry.areaHa)
        )
    end

    self:updateCalendar(farmlandId)
    local plan = self:getPlanForFarmland(farmlandId)
    local coverPlan = self:getCoverPlanForFarmland(farmlandId)
    self:updateScoreCard(plan, coverPlan)
    self:updatePlannedResiduePill(self.planStatusPillBg, self.planStatusPillText, plan, coverPlan)
    self:layoutHeroPills(self.planTitle, self.planStatusPillBg)
end

-- Annual calendar — crop selector + sow window + cover marker

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
        local labelEl = self.calendarMonthLabel ~= nil and self.calendarMonthLabel[i] or nil
        if labelEl ~= nil then
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
        end

        local gridEl = self.calendarMonthGridLine ~= nil and self.calendarMonthGridLine[i] or nil
        if gridEl ~= nil then
            local show = i <= periodCount
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
    end

    -- 13th grid line marks the right edge of the grid, after the last visible month
    local lastGridEl = self.calendarMonthGridLine ~= nil and self.calendarMonthGridLine[13] or nil
    if lastGridEl ~= nil then
        local lineW = self:getCalendarGridLineWidth(13)
        self:setElementPixelPosition(
            lastGridEl,
            RealisticCropRotationFrame.CALENDAR_AXIS_X + (periodCount * periodW) - (lineW - 1) * 0.5,
            38
        )
        self:setElementPixelSize(lastGridEl, lineW, RealisticCropRotationFrame.CALENDAR_GRID_H)
        lastGridEl:setVisible(periodCount > 0)
    end

    local marker = self.calendarTodayMarker
    if marker ~= nil then
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
    end

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
    local rowBg = self.calendarRowBg ~= nil and self.calendarRowBg[slotIdx] or nil
    local cropIcon = self.calendarCropIcon ~= nil and self.calendarCropIcon[slotIdx] or nil
    local coverIcon = self.calendarCoverIcon ~= nil and self.calendarCoverIcon[slotIdx] or nil
    local cropBar = self.calendarCropBar ~= nil and self.calendarCropBar[slotIdx] or nil
    local coverMarker = self.calendarCoverMarker ~= nil and self.calendarCoverMarker[slotIdx] or nil

    if rowBg ~= nil then
        local active = slotIdx == self:getCalendarEditSlotIndex()
        if active then
            rowBg.color = {0.35, 0.55, 0.00, 0.26}
        else
            rowBg:applyProfile(slotIdx % 2 == 1 and "frCalendarRowBgOdd" or "frCalendarRowBgEven")
        end
        rowBg:setVisible(true)
    end

    self:applySlotCropIcon(cropIcon, cropName)
    self:applySlotCropIcon(coverIcon, coverCropName)

    local hasCrop = cropName ~= nil and cropName ~= ""
    local hasCover = coverCropName ~= nil and coverCropName ~= ""
    local axisX = RealisticCropRotationFrame.CALENDAR_AXIS_X
    local harvestBar = self.calendarHarvestBar ~= nil and self.calendarHarvestBar[slotIdx] or nil

    local SOW_Y, HARVEST_Y, COVER_Y, LANE_H = 3, 17, 31, 10

    local function longestRun(flags)
        local bestStart, bestLen = nil, 0
        if flags ~= nil then
            for _, run in ipairs(self:getFlagRuns(flags, periodCount)) do
                if run.len > bestLen then bestStart, bestLen = run.start, run.len end
            end
        end
        return bestStart, bestLen
    end

    local function placeBar(bar, startP, lenP, y, visible)
        if bar == nil then return false end
        local show = visible and startP ~= nil and lenP ~= nil and lenP > 0
        bar:setVisible(show)
        if show then
            -- Inset each end by its bounding grid-line width so the bar sits between lines.
            local leftInset  = self:getCalendarGridLineWidth(startP)
            local rightInset = self:getCalendarGridLineWidth(startP + lenP)
            local x = axisX + ((startP - 1) * periodW) + leftInset
            local w = (lenP * periodW) - leftInset - rightInset
            self:setElementPixelPosition(bar, x, y)
            self:setElementPixelSize(bar, math.max(4, w), LANE_H)

            -- Snap the bar edges to the bounding grid lines (avoids 1px rounding mismatch).
            local leftLine  = self.calendarMonthGridLine ~= nil and self.calendarMonthGridLine[startP] or nil
            local rightLine = self.calendarMonthGridLine ~= nil and self.calendarMonthGridLine[startP + lenP] or nil
            if leftLine ~= nil and rightLine ~= nil and bar.parent ~= nil then
                local leftEdge  = leftLine.absPosition[1] + leftLine.absSize[1]
                local rightEdge = rightLine.absPosition[1]
                bar:setPosition(leftEdge - bar.parent.absPosition[1], nil)
                bar:setSize(math.max(0.0001, rightEdge - leftEdge), nil)
            end
        end
        return show
    end

    -- main crop: planting (green, top) + harvest (orange, bottom)
    local plantFlags, harvestFlags = self:getCropPeriodFlags(cropName, periodCount, firstPeriod)
    local pStart, pLen = longestRun(plantFlags)
    local hStart, hLen = longestRun(harvestFlags)
    placeBar(cropBar, pStart, pLen, SOW_Y, hasCrop)
    placeBar(harvestBar, hStart, hLen, HARVEST_Y, hasCrop)

    -- cover crop: planting only (never harvested), middle lane, tinted to its planner-card colour to read as a cover, not a main crop.
    local cStart, cLen = nil, nil
    if hasCover then
        cStart, cLen = longestRun(self:getCropPeriodFlags(coverCropName, periodCount, firstPeriod))
    end
    if placeBar(coverMarker, cStart, cLen, COVER_Y, hasCover) then
        coverMarker.color = RealisticCropRotationFrame.FAMILY_RGBA[self:getCropFamily(coverCropName)]
            or RealisticCropRotationFrame.FAMILY_RGBA.COVER
    end
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
    if selector == nil or list == nil then return end
    local state = 1
    for idx, name in ipairs(list) do
        if name == cropName then state = idx; break end
    end
    selector:setState(state, false)
end

---Syncs the crop/cover editor selectors to the active slot's local plan.
function RealisticCropRotationFrame:updateCalendarEditorSelectorsFromSlot()
    local slotIdx = self:getCalendarEditSlotIndex()
    self:setSelectorStateFromCrop(
        self.calendarEditCropSelector,
        self.planCropList,
        self.calendarLocalPlan ~= nil and self.calendarLocalPlan[slotIdx] or ""
    )
    self:setSelectorStateFromCrop(
        self.calendarEditCoverSelector,
        self.coverCropList,
        self.calendarLocalCoverPlan ~= nil and self.calendarLocalCoverPlan[slotIdx] or ""
    )
end

---Redraws the calendar axis + 4 rows from the local plans and refreshes score/pill.
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
    local sourcePlan = self.calendarLocalPlan
    if sourcePlan == nil and self.selectedId ~= nil then
        sourcePlan = self:getPlanForFarmland(self.selectedId)
    end
    local plan = self:copyFourSlotPlan(sourcePlan)
    local slotIdx = self:getCalendarEditSlotIndex()
    local sel = self.calendarEditCropSelector
    if sel ~= nil and self.planCropList ~= nil then
        plan[slotIdx] = self.planCropList[sel:getState()] or ""
    end
    return plan
end

---Builds the cover plan with the active slot overridden by the cover selector.
-- @return table coverPlan
function RealisticCropRotationFrame:getCoverPlanFromSelectors()
    local sourceCoverPlan = self.calendarLocalCoverPlan
    if sourceCoverPlan == nil and self.selectedId ~= nil then
        sourceCoverPlan = self:getCoverPlanForFarmland(self.selectedId)
    end
    local coverPlan = self:copyFourSlotPlan(sourceCoverPlan)
    local slotIdx = self:getCalendarEditSlotIndex()
    local sel = self.calendarEditCoverSelector
    if sel ~= nil and self.coverCropList ~= nil then
        coverPlan[slotIdx] = self.coverCropList[sel:getState()] or ""
    end
    return coverPlan
end

---Rebuilds local plans from the selectors and redraws the calendar (no save).
function RealisticCropRotationFrame:updateCalendarVisualsFromSelectors()
    self.calendarLocalPlan = self:getPlanFromSelectors()
    self.calendarLocalCoverPlan = self:getCoverPlanFromSelectors()
    self:renderCalendarFromLocalPlans()
end

---Applies a server snapshot: rebuilds the history tab, but never disrupts the planner mid-edit.
function RealisticCropRotationFrame:onServerSyncReceived()
    if self.isApplyingServerSync then
        return
    end

    self.isApplyingServerSync = true

    -- History tab: safe to rebuild from the server snapshot. Planner tab: never rebuild here, it would disrupt the MultiTextOption.
    if self:isHistoryTab() then
        self:populateSidebar()
    else
        self:buildRotationGroups()
        if self.listPlanOverview ~= nil then
            self.listPlanOverview:reloadData()
        end
        self:updateCalendarVisualsFromSelectors()
    end

    self.isApplyingServerSync = false
end

---Sets a crop icon element to the crop's HUD overlay, or hides it.
-- @param table iconEl
-- @param string cropName
function RealisticCropRotationFrame:applySlotCropIcon(iconEl, cropName)
    if iconEl == nil then return end
    if cropName == nil or cropName == "" then
        iconEl:setVisible(false)
        return
    end
    if isFallowCrop(cropName) then
        iconEl:setVisible(false)
        return
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
end

-- Calendar editor onClick handlers

---Edit-slot selector callback: re-syncs the editor selectors and redraws.
function RealisticCropRotationFrame:onChangeCalendarEditStep()
    if self.isApplyingServerSync then return end
    self.calendarEditSlotIdx = self:getCalendarEditSlotIndex()
    self:updateCalendarEditorSelectorsFromSlot()
    self:renderCalendarFromLocalPlans()
end

---Selects a calendar row when its row button is clicked.
-- @param table button The clicked row button
function RealisticCropRotationFrame:onCalendarRowClicked(button)
    if self.isApplyingServerSync or self.calendarRowButton == nil then return end

    for slotIdx, rowButton in ipairs(self.calendarRowButton) do
        if rowButton == button then
            self.calendarEditSlotIdx = slotIdx
            self:onChangeCalendarEditStep()
            break
        end
    end
end

---Crop selector callback: applies the change to the active slot.
function RealisticCropRotationFrame:onChangeCalendarEditCrop()
    self:handleCalendarCropChange(self:getCalendarEditSlotIndex())
end

---Cover selector callback: applies the change to the active slot.
function RealisticCropRotationFrame:onChangeCalendarEditCover()
    self:handleCalendarCoverChange(self:getCalendarEditSlotIndex())
end

---Writes a slot's main crop (event on MP client, direct on server) and refreshes the UI.
-- @param integer slotIdx Slot 1-4
function RealisticCropRotationFrame:handleCalendarCropChange(slotIdx)
    if self.isApplyingServerSync then return end
    if self.selectedId == nil then return end
    local sel = self.calendarEditCropSelector
    if sel == nil then return end

    local state    = sel:getState()
    local cropName = (self.planCropList ~= nil and self.planCropList[state]) or ""
    self.calendarLocalPlan = self:copyFourSlotPlan(self.calendarLocalPlan)
    self.calendarLocalPlan[slotIdx] = cropName

    local isClientOnly = g_currentMission ~= nil and g_currentMission.getIsServer ~= nil
        and not g_currentMission:getIsServer()

    if isClientOnly then
        if g_client ~= nil and g_client.getServerConnection ~= nil and RCRPlanUpdateEvent ~= nil then
            local connection = g_client:getServerConnection()
            if connection ~= nil then
                connection:sendEvent(RCRPlanUpdateEvent.new(self.selectedId, slotIdx, cropName, false))
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

    self:renderCalendarFromLocalPlans()

    -- Refresh the overview from the repository (may lag one MP snapshot, never optimistic data).
    self:buildRotationGroups()
    if self.listPlanOverview ~= nil then
        self.listPlanOverview:reloadData()
    end
end

---Writes a slot's cover crop (event on MP client, direct on server) and refreshes the UI.
-- @param integer slotIdx Slot 1-4
function RealisticCropRotationFrame:handleCalendarCoverChange(slotIdx)
    if self.isApplyingServerSync then return end
    if self.selectedId == nil then return end
    local sel = self.calendarEditCoverSelector
    if sel == nil then return end

    local state = sel:getState()
    local cropName = (self.coverCropList ~= nil and self.coverCropList[state]) or ""
    self.calendarLocalCoverPlan = self:copyFourSlotPlan(self.calendarLocalCoverPlan)
    self.calendarLocalCoverPlan[slotIdx] = cropName

    local isClientOnly = g_currentMission ~= nil and g_currentMission.getIsServer ~= nil
        and not g_currentMission:getIsServer()

    if isClientOnly then
        if g_client ~= nil and g_client.getServerConnection ~= nil and RCRPlanUpdateEvent ~= nil then
            local connection = g_client:getServerConnection()
            if connection ~= nil then
                connection:sendEvent(RCRPlanUpdateEvent.new(self.selectedId, slotIdx, cropName, true))
            end
        else
            Logging.warning("[RealisticCropRotation][MP] Cover plan update not sent: client connection or event unavailable")
        end
    else
        local mgr = self:getManager()
        local changed = false
        if mgr ~= nil and mgr.setRotationCoverPlanYear ~= nil then
            changed = mgr:setRotationCoverPlanYear(self.selectedId, slotIdx, cropName)
        end
        if changed and RealisticCropRotation ~= nil and RealisticCropRotation.requestBroadcast ~= nil then
            RealisticCropRotation.requestBroadcast()
        end
    end

    self:renderCalendarFromLocalPlans()

    self:buildRotationGroups()
    if self.listPlanOverview ~= nil then
        self.listPlanOverview:reloadData()
    end
end

---"Clear plan" button: confirms before wiping the selected farmland's rotation plan.
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
    local isClientOnly = g_currentMission ~= nil and g_currentMission.getIsServer ~= nil
        and not g_currentMission:getIsServer()

    if isClientOnly then
        if g_client ~= nil and g_client.getServerConnection ~= nil and RCRPlanUpdateEvent ~= nil then
            local connection = g_client:getServerConnection()
            if connection ~= nil then
                for slotIdx = 1, 4 do
                    connection:sendEvent(RCRPlanUpdateEvent.new(farmlandId, slotIdx, "", false))
                    connection:sendEvent(RCRPlanUpdateEvent.new(farmlandId, slotIdx, "", true))
                end
            end
        else
            Logging.warning("[RealisticCropRotation][MP] Plan clear not sent: client connection or event unavailable")
        end
    else
        local mgr = self:getManager()
        local changed = mgr ~= nil and mgr.clearRotationPlan ~= nil and mgr:clearRotationPlan(farmlandId)
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
    if self.listPlanOverview ~= nil then
        self.listPlanOverview:reloadData()
    end
end

-- Score card

---Updates the rotation score card (number + label) from a plan.
-- @param table plan
-- @param table coverPlan
function RealisticCropRotationFrame:updateScoreCard(plan, coverPlan)
    if self.scoreText == nil then return end
    plan = plan or {"","","",""}
    coverPlan = coverPlan or {"","","",""}

    local score    = self:calcRotationScore(plan, coverPlan)
    local scoreKey = self:getScoreTextKey(score, plan)
    self.scoreText:setText(self.i18n:getText(scoreKey))

    -- Cursor x = (score/100)*(400-14)+14 px along the 400px track (14px cursor).
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
        elseif score >= 60 then
            self.scoreCursor.color = {0.95, 0.85, 0.05, 1.0}
        elseif score >= 40 then
            self.scoreCursor.color = {0.75, 0.45, 0.05, 1.0}
        elseif score >= 20 then
            self.scoreCursor.color = {0.75, 0.20, 0.05, 1.0}
        else
            self.scoreCursor.color = {0.55, 0.05, 0.05, 1.0}
        end
    end
end

---Scores a rotation 0-100 from family/pathogen spacing, legume->cereal bonus, diversity and residue.
-- @param table plan
-- @param table coverPlan
-- @return integer score
function RealisticCropRotationFrame:calcRotationScore(plan, coverPlan)
    -- Ordered ring of scoring families (fallow excluded: it is a neutral break, not a crop).
    local ring      = {}
    local ringCover = {}
    local ringDis   = {}
    for i = 1, 4 do
        local crop = plan[i] or ""
        if crop ~= "" then
            local fam = self:getCropFamily(crop)
            if fam ~= "UNKNOWN" and fam ~= "FALLOW" then
                ring[#ring + 1] = fam
                ringDis[#ring]  = self:getCropDiseases(crop)
                local coverCrop = coverPlan ~= nil and coverPlan[i] or ""
                ringCover[#ring] = coverCrop ~= nil and coverCrop ~= ""
            end
        end
    end

    local n = #ring
    if n < 2 then return 0 end

    -- Distinct families in the rotation.
    local seen = {}
    for _, fam in ipairs(ring) do seen[fam] = true end
    local uniqueCount = 0
    for _ in pairs(seen) do uniqueCount = uniqueCount + 1 end

    -- Build the score upward: a bare rotation is the floor, good agronomy earns points.
    local score = (n >= 3) and RealisticCropRotationFrame.SCORE_BASE_FULL
                            or  RealisticCropRotationFrame.SCORE_BASE_PARTIAL

    -- Penalize same-family crops closer than their min return interval, on a cyclic ring.
    for a = 1, n - 1 do
        for b = a + 1, n do
            if ring[a] == ring[b] then
                local minInterval = RealisticCropRotationFrame.FAMILY_MIN_INTERVAL[ring[a]]
                if minInterval ~= nil then
                    local forward  = b - a
                    local interval = math.min(forward, n - forward)
                    if interval < minInterval then
                        local penalty = (minInterval - interval) * RealisticCropRotationFrame.SCORE_FAMILY_PENALTY_PER_YEAR
                        -- a cover sown in the shorter gap halves the penalty
                        local gapStart = (forward <= n - forward) and a or b
                        if ringCover[gapStart] then penalty = penalty / 2 end
                        score = score - penalty
                    end
                end
            end
        end
    end

    -- Shared-pathogen pressure: same-family pairs already pay the family penalty above, so this adds only the extra disease interval beyond it.
    local diseaseIntervals = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig
        and RealisticCropRotation.cropConfig.diseaseIntervals or {}
    for a = 1, n - 1 do
        for b = a + 1, n do
            local forward  = b - a
            local interval = math.min(forward, n - forward)
            local familyMinInterval = ring[a] == ring[b] and RealisticCropRotationFrame.FAMILY_MIN_INTERVAL[ring[a]] or nil
            local diseaseBaseline = familyMinInterval ~= nil and math.max(interval, familyMinInterval) or interval
            local worst = 0
            for group in pairs(ringDis[a] or {}) do
                if (ringDis[b] or {})[group] then
                    local minInterval = diseaseIntervals[group]
                    if minInterval ~= nil and diseaseBaseline < minInterval then
                        local pen = (minInterval - diseaseBaseline) * RealisticCropRotationFrame.SCORE_DISEASE_PENALTY_PER_YEAR
                        if pen > worst then worst = pen end
                    end
                end
            end
            score = score - worst
        end
    end

    if n >= 3 then
        -- Legume directly followed by a cereal (cyclic): the returned nitrogen is put to use.
        for k = 1, n do
            local nextK = (k % n) + 1
            if ring[k] == "LEGUME" and ring[nextK] == "CEREAL" then
                score = score + RealisticCropRotationFrame.SCORE_LEGUME_CEREAL_BONUS
            end
        end

        -- Diversity bonus: share of distinct families among the rotation crops.
        score = score + (uniqueCount / n) * RealisticCropRotationFrame.SCORE_DIVERSITY_BONUS_MAX
    end

    -- Nitrogen restored (legume/cover) rewards; none keeps "excellent" out of reach.
    if self:getPlanNitrogenResidueKgHa(plan, coverPlan) ~= nil then
        score = score + RealisticCropRotationFrame.SCORE_RESIDUE_BONUS
    else
        score = math.min(score, RealisticCropRotationFrame.SCORE_NO_RESIDUE_CAP)
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
    local anyFilled, cropCount = false, 0
    for i = 1, 4 do
        local crop = plan[i] or ""
        if crop ~= "" then
            anyFilled = true
            local fam = self:getCropFamily(crop)
            if fam ~= "UNKNOWN" and fam ~= "FALLOW" then cropCount = cropCount + 1 end
        end
    end
    if not anyFilled then return "rcr_plan_none" end
    if cropCount < 2 then return "rcr_score_incomplete" end
    if score >= 80   then return "rcr_score_excellent" end
    if score >= 60   then return "rcr_score_good" end
    if score >= 40   then return "rcr_score_fair" end
    if score >= 20   then return "rcr_score_poor" end
    return "rcr_score_bad"
end

---Returns the short score badge key + RGB colour for a score.
-- @param integer score
-- @return string i18nKey, or nil
-- @return number r
-- @return number g
-- @return number b
function RealisticCropRotationFrame:getScoreLabel(score)
    if score >= 80 then return "rcr_score_short_optimal", 0.325, 0.565, 0.071
    elseif score >= 60 then return "rcr_score_short_good",  0.95,  0.85, 0.05
    elseif score >= 40 then return "rcr_score_short_fair",  0.75,  0.45, 0.05
    elseif score >= 20 then return "rcr_score_short_poor",  0.75,  0.20, 0.05
    else                    return "rcr_score_short_bad",   0.55,  0.05, 0.05
    end
end

-- ROTATION GROUPS — overview of fields sharing the same crop rotation

---Groups owned fields by identical plan+cover sequence for the overview.
function RealisticCropRotationFrame:buildRotationGroups()
    local groups   = {}
    local groupMap = {}

    for _, entry in ipairs(self.farmlandList or {}) do
        local plan = self:getPlanForFarmland(entry.farmlandId)
        local coverPlan = self:getCoverPlanForFarmland(entry.farmlandId)
        -- Key by exact main crop and cover crop sequence
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

---Cover recap line: each slot's cover crop name.
-- @param table group
-- @return string text
function RealisticCropRotationFrame:getGroupCoverRecapText(group)
    if group == nil or group.coverPlan == nil then return "" end

    local yearKeys = { "rcr_plan_year1", "rcr_plan_year2", "rcr_plan_year3", "rcr_plan_year4" }

    local parts = {}
    for i = 1, 4 do
        local coverName = group.coverPlan[i] or ""
        if coverName ~= "" then
            table.insert(parts, string.format(
                self.i18n:getText("rcr_overview_cover_entry"),
                self.i18n:getText(yearKeys[i]),
                self:getCropDisplayName(coverName)
            ))
        end
    end

    return table.concat(parts, "   ·   ")
end

---Returns the first and last filled slot indices of a plan.
-- @param table plan
-- @return integer firstFilled, or nil
-- @return integer lastFilled, or nil
function RealisticCropRotationFrame:getGroupPlanBounds(plan)
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
    local labelEl = cell:getAttribute("gLabel" .. slotIndex)
    local badgeEl = cell:getAttribute("gBadge" .. slotIndex)
    local yearLabelEl = cell:getAttribute("gYearLabel" .. slotIndex)
    if labelEl == nil or (showIcon and iconEl == nil) then return end

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
    local iconPosY = GuiUtils.getNormalizedScreenValues(string.format("0px -%dpx", iconYpx))[2]

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

    local firstFilled, lastFilled = self:getGroupPlanBounds(group.plan)
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

---Fills an overview group cell: badges, count, area, score, residue, field names, cover recap.
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

    -- 4 crop zones: main crop badges.
    local firstFilled, lastFilled = self:getGroupPlanBounds(group.plan)
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

    -- Total rotation residue — text and calculation come from the shared planning helper.
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

    -- Field names — bottom strip, uses TextElement scrolling for long lists.
    local namesEl = cell:getAttribute("gFieldNames")
    if namesEl ~= nil then
        namesEl:setText(self:getCompactGroupFieldNames(group.fieldNames))
    end

    -- Cover crop recap — own line between the badge row and field names.
    local coverRecapEl = cell:getAttribute("gCoverRecap")
    if coverRecapEl ~= nil then
        local coverRecap = self:getGroupCoverRecapText(group)
        coverRecapEl:setVisible(coverRecap ~= "")
        if coverRecap ~= "" then
            coverRecapEl:setText(coverRecap)
        end
    end
end
