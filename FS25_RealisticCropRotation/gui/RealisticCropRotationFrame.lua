-- Copyright © 2026 Squallqt. All rights reserved.
RealisticCropRotationFrame = {}
local RealisticCropRotationFrame_mt = Class(RealisticCropRotationFrame, TabbedMenuFrameElement)

-- Internal tab indices
RealisticCropRotationFrame.TAB = { HISTORY = 1, PLANNING = 2 }
RealisticCropRotationFrame.DAY_LENGTH_MS = 86400000

RealisticCropRotationFrame.HERO_PILL_HEIGHT_PX = 28
RealisticCropRotationFrame.HERO_PILL_MIN_W_PX = 96
RealisticCropRotationFrame.HERO_PILL_MAX_W_PX = 420
RealisticCropRotationFrame.HERO_PILL_TEXT_PADDING_PX = 24
RealisticCropRotationFrame.HERO_WEATHER_ICON_PX = 22
RealisticCropRotationFrame.HERO_WEATHER_LEFT_PAD_PX = 14
RealisticCropRotationFrame.HERO_WEATHER_RIGHT_PAD_PX = 16
RealisticCropRotationFrame.HERO_WEATHER_ICON_TEXT_GAP_PX = 8
RealisticCropRotationFrame.HERO_TITLE_PILL_GAP_PX = 24

-- Vanilla weather types and icon slices, mirrored from GameInfoDisplay.lua.
RealisticCropRotationFrame.WEATHER_TYPES = {
    { constant = "SUN",              textKey = "rcr_weather_sun",              sliceId = "gui.icon_weather_sun",             color = {0.34, 0.40, 0.10, 0.86} },
    { constant = "PARTIALLY_CLOUDY", textKey = "rcr_weather_partially_cloudy", sliceId = "gui.icon_weather_partiallyCloudy", color = {0.23, 0.32, 0.34, 0.86} },
    { constant = "CLOUDY",           textKey = "rcr_weather_cloudy",           sliceId = "gui.icon_weather_cloudy",          color = {0.22, 0.27, 0.30, 0.86} },
    { constant = "RAIN",             textKey = "rcr_weather_rain",             sliceId = "gui.icon_weather_rain",            color = {0.04, 0.20, 0.28, 0.86}, isOperational = true },
    { constant = "SNOW",             textKey = "rcr_weather_snow",             sliceId = "gui.icon_weather_snow",            color = {0.22, 0.28, 0.32, 0.86}, isOperational = true },
    { constant = "HAIL",             textKey = "rcr_weather_hail",             sliceId = "gui.icon_weather_hail",            color = {0.24, 0.22, 0.34, 0.86}, isOperational = true },
    { constant = "TWISTER",          textKey = "rcr_weather_twister",          sliceId = "gui.icon_weather_twister",         color = {0.34, 0.16, 0.10, 0.88}, isOperational = true },
    { constant = "THUNDER",          textKey = "rcr_weather_thunder",          sliceId = "gui.icon_weather_thunder",         color = {0.30, 0.22, 0.08, 0.88}, isOperational = true },
}

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

RealisticCropRotationFrame.COVER_CROP_NAMES = {
    "OILSEEDRADISH",
    "FLOWERINGCATCHCROP",
}

-- Minimum number of growth-possible months a cover must accumulate (between
-- sowing and destruction) before it can release its nitrogen residue. Growth is
-- counted only in months where the crop actually advances its state -- winter
-- stalls do not count -- and may continue past the sowing window, since sowing
-- (plantingAllowed) and growing (growthMapping) are independent windows.
RealisticCropRotationFrame.COVER_MIN_GROWTH_MONTHS = 1

-- Rotation score: minimum recommended return interval (in years) per family
-- before the same family should reappear in the plan. FORAGE has no entry
-- (no constraint). Mirrors the agronomic advice text (rcr_advice_after*).
RealisticCropRotationFrame.FAMILY_MIN_INTERVAL = {
    CEREAL    = 2,
    OILSEED   = 3,
    LEGUME    = 3,
    VEGETABLE = 3,
    ROOT      = 4,
}

RealisticCropRotationFrame.SCORE_FAMILY_PENALTY_PER_YEAR = 20
RealisticCropRotationFrame.SCORE_LEGUME_CEREAL_BONUS = 5
RealisticCropRotationFrame.SCORE_DIVERSITY_BONUS_MAX = 10

-- Max pixel widths (must match profile sizes)
-- N_BAR_MAX_WIDTH: keep in sync with guiProfiles.xml frNitrogenTrack size (1192px)
RealisticCropRotationFrame.N_BAR_MAX_WIDTH     = 1192
RealisticCropRotationFrame.N_BAR_HEIGHT        = 14

-- Global overview crop badge layout (pixel values, converted at runtime)
-- Goal: center the whole pair [crop icon + 5px gap + crop text] inside each crop badge.
RealisticCropRotationFrame.GROUP_BADGE_Y          = 18
RealisticCropRotationFrame.GROUP_BADGE_W          = 300
RealisticCropRotationFrame.GROUP_BADGE_H          = 30
RealisticCropRotationFrame.GROUP_ICON_W           = 20
RealisticCropRotationFrame.GROUP_ICON_H           = 20
RealisticCropRotationFrame.GROUP_ICON_TEXT_GAP    = 5
RealisticCropRotationFrame.GROUP_BADGE_PADDING_X  = 20

-- Annual calendar layout in pixels. The XML container is 1240 x 154 px.
RealisticCropRotationFrame.CALENDAR_AXIS_X = 94
RealisticCropRotationFrame.CALENDAR_AXIS_W = 1130
RealisticCropRotationFrame.CALENDAR_GRID_H = 188
-- Season boundaries: FS25 has 3 periods (months) per season, so 1 line out of 3
-- (indices 1,4,7,10,13) is drawn thick to mark the start of each season.
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

function RealisticCropRotationFrame:getWeather()
    if g_currentMission == nil or g_currentMission.environment == nil then return nil end
    return g_currentMission.environment.weather
end

function RealisticCropRotationFrame:getWeatherTypeSpec(weatherType)
    if weatherType == nil or WeatherType == nil then return nil end

    for _, spec in ipairs(RealisticCropRotationFrame.WEATHER_TYPES) do
        local weatherTypeValue = WeatherType[spec.constant]
        if weatherTypeValue ~= nil and weatherType == weatherTypeValue then
            return spec
        end
    end

    return nil
end

function RealisticCropRotationFrame:getForecastWeatherType(weather, forecastItem)
    if weather == nil or forecastItem == nil or weather.getWeatherObjectByIndex == nil then return nil end
    if forecastItem.season == nil or forecastItem.objectIndex == nil then return nil end
    local weatherObject = weather:getWeatherObjectByIndex(forecastItem.season, forecastItem.objectIndex)
    return weatherObject ~= nil and weatherObject.weatherType or nil
end

function RealisticCropRotationFrame:getWeatherSliceId(weatherType)
    local spec = self:getWeatherTypeSpec(weatherType)
    return spec ~= nil and spec.sliceId or nil
end

function RealisticCropRotationFrame:getWeatherPillColor(weatherType)
    local spec = self:getWeatherTypeSpec(weatherType)
    return spec ~= nil and spec.color or {0.22, 0.27, 0.30, 0.86}
end

function RealisticCropRotationFrame:getWeatherLabel(weatherType)
    local spec = self:getWeatherTypeSpec(weatherType)
    return spec ~= nil and self.i18n:getText(spec.textKey) or nil
end

function RealisticCropRotationFrame:getForecastDeltaMs(environment, day, dayTime)
    if environment == nil or environment.currentMonotonicDay == nil or environment.dayTime == nil then return nil end
    if day == nil or dayTime == nil then return nil end
    return (day - environment.currentMonotonicDay) * RealisticCropRotationFrame.DAY_LENGTH_MS
        + (dayTime - environment.dayTime)
end

function RealisticCropRotationFrame:getForecastEventFromItem(weather, environment, item)
    if item == nil or item.startDay == nil or item.startDayTime == nil then return nil end

    local weatherType = self:getForecastWeatherType(weather, item)
    local weatherSpec = self:getWeatherTypeSpec(weatherType)
    if weatherSpec == nil then return nil end

    local endDay = item.startDay
    local endDayTime = item.startDayTime + (tonumber(item.duration) or 0)
    if environment.getDayAndDayTime ~= nil then
        endDay, endDayTime = environment:getDayAndDayTime(endDayTime, item.startDay)
    elseif endDayTime >= RealisticCropRotationFrame.DAY_LENGTH_MS then
        endDay = endDay + math.floor(endDayTime / RealisticCropRotationFrame.DAY_LENGTH_MS)
        endDayTime = endDayTime % RealisticCropRotationFrame.DAY_LENGTH_MS
    end

    local startDelta = self:getForecastDeltaMs(environment, item.startDay, item.startDayTime)
    local endDelta = self:getForecastDeltaMs(environment, endDay, endDayTime)
    if startDelta == nil or endDelta == nil then return nil end

    return {
        weatherType = weatherType,
        startDay = item.startDay,
        startDayTime = item.startDayTime,
        endDay = endDay,
        endDayTime = endDayTime,
        startDelta = startDelta,
        endDelta = endDelta,
        dayOffset = math.max(0, item.startDay - environment.currentMonotonicDay),
        isOperational = weatherSpec.isOperational == true,
    }
end

function RealisticCropRotationFrame:getWeatherEvent()
    local weather = self:getWeather()
    if weather == nil or weather.forecastItems == nil or #weather.forecastItems == 0 then return nil end

    local environment = weather.owner
    if environment == nil or environment.currentMonotonicDay == nil or environment.dayTime == nil then return nil end

    local currentEvent = nil
    local nextWeatherEvent = nil
    local nextOperationalEvent = nil

    for i = 1, #weather.forecastItems do
        local event = self:getForecastEventFromItem(weather, environment, weather.forecastItems[i])
        if event ~= nil and event.startDelta <= 0 and event.endDelta > 0 then
            event.isCurrent = true
            currentEvent = event
            if event.isOperational == true then
                return event
            end
            break
        end
    end

    for i = 1, #weather.forecastItems do
        local event = self:getForecastEventFromItem(weather, environment, weather.forecastItems[i])
        if event ~= nil and event.startDelta > 0 then
            event.isCurrent = false
            if nextWeatherEvent == nil then
                nextWeatherEvent = event
            end
            if event.isOperational == true then
                nextOperationalEvent = event
                break
            end
        end
    end

    return nextOperationalEvent or currentEvent or nextWeatherEvent
end

function RealisticCropRotationFrame:formatForecastTime(dayTime)
    local normalizedDayTime = (tonumber(dayTime) or 0) % RealisticCropRotationFrame.DAY_LENGTH_MS
    local totalMinutes = math.floor(normalizedDayTime / 60000 + 0.5)
    if totalMinutes >= 1440 then
        totalMinutes = 0
    end

    if Utils ~= nil and Utils.formatTime ~= nil then
        return Utils.formatTime(totalMinutes)
    end

    local hour = math.floor(totalMinutes / 60)
    local minute = totalMinutes - hour * 60
    return string.format("%02d:%02d", hour, minute)
end

function RealisticCropRotationFrame:formatForecastLeadTime(deltaMs)
    local minutes = math.max(1, math.floor((tonumber(deltaMs) or 0) / 60000 + 0.5))
    local hours = math.floor(minutes / 60)
    local remainingMinutes = minutes - hours * 60

    if hours <= 0 then
        return string.format(self.i18n:getText("rcr_time_minutes"), minutes)
    elseif remainingMinutes <= 0 then
        return string.format(self.i18n:getText("rcr_time_hours"), hours)
    end

    return string.format(self.i18n:getText("rcr_time_hours_minutes"), hours, remainingMinutes)
end

function RealisticCropRotationFrame:getWeatherPillText(event)
    if event == nil then return nil end

    local weatherLabel = self:getWeatherLabel(event.weatherType)
    if weatherLabel == nil then return nil end

    if event.isCurrent == true then
        local key = event.isOperational == true and "rcr_weather_current_operational" or "rcr_weather_current_calm"
        return string.format(self.i18n:getText(key), weatherLabel, self:formatForecastTime(event.endDayTime))
    end

    local startTimeText = self:formatForecastTime(event.startDayTime)
    local endTimeText = self:formatForecastTime(event.endDayTime)
    local dayOffset = event.dayOffset or 0
    if dayOffset <= 0 then
        return string.format(
            self.i18n:getText("rcr_weather_soon"),
            weatherLabel,
            startTimeText,
            endTimeText,
            self:formatForecastLeadTime(event.startDelta)
        )
    elseif dayOffset == 1 then
        return string.format(self.i18n:getText("rcr_weather_tomorrow"), weatherLabel, startTimeText, endTimeText)
    end

    return string.format(self.i18n:getText("rcr_weather_later"), weatherLabel, dayOffset, startTimeText, endTimeText)
end

function RealisticCropRotationFrame:updateWeatherPill(pill, pillBg, pillIcon, pillText)
    local event = self:getWeatherEvent()
    local text = self:getWeatherPillText(event)
    local sliceId = event ~= nil and self:getWeatherSliceId(event.weatherType) or nil
    local show = text ~= nil and text ~= "" and sliceId ~= nil

    if pill ~= nil then
        pill:setVisible(show)
        pill._frWeatherPillVisible = show
    end
    if pillText ~= nil then
        pillText:setText(show and text or "")
    end
    if pillIcon ~= nil then
        pillIcon:setVisible(show)
        if show and pillIcon.setImageSlice ~= nil then
            pillIcon:setImageSlice(nil, sliceId)
        end
    end
    if pillBg ~= nil and show then
        pillBg.color = self:getWeatherPillColor(event.weatherType)
    end

    if show then
        return self:resizeWeatherPillToText(pill, pillBg, pillIcon, pillText, text)
    end

    return nil
end

function RealisticCropRotationFrame:updateResiduePill(pillBg, pillText, farmlandId)
    local text = self.i18n:getText("rcr_status_current_no_residue")
    if pillBg ~= nil then
        pillBg:applyProfile("frStatusPillBg")
    end
    if pillText ~= nil then
        pillText:setText(text)
    end
    return self:resizeHeroPillToText(pillBg, pillText, text)
end

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
        if cropName ~= nil and cropName ~= "" then
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

function RealisticCropRotationFrame:getPlanNitrogenResidueText(plan, coverPlan)
    local residueKgHa = self:getPlanNitrogenResidueKgHa(plan, coverPlan)
    if residueKgHa == nil then return nil end
    return string.format(self.i18n:getText("rcr_status_planned_residue"), math.floor(residueKgHa + 0.5))
end

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

function RealisticCropRotationFrame:getCropFamily(cropName)
    if cropName == nil or cropName == "" then return "UNKNOWN" end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.families == nil then return "UNKNOWN" end
    return config.families[string.upper(cropName)] or "UNKNOWN"
end

-- FillTypeManager is the canonical source for display info (title, icon):
-- every fillType has both, whereas a fruitType only has a fillType link
-- when it is harvestable (catch crops like FLOWERINGCATCHCROP have none).
function RealisticCropRotationFrame:getFillTypeForCrop(cropName)
    if cropName == nil or cropName == "" then return nil end
    if g_fillTypeManager == nil or g_fillTypeManager.getFillTypeByName == nil then return nil end
    return g_fillTypeManager:getFillTypeByName(string.upper(tostring(cropName)))
end

function RealisticCropRotationFrame:getCropDisplayName(cropName)
    if cropName == nil or cropName == "" then return "" end
    local normalizedName = string.upper(tostring(cropName))

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

function RealisticCropRotationFrame:buildFarmlandList()
    local mgr = self:getManager()
    if mgr == nil or mgr.getOwnedFarmlands == nil then return {} end
    return mgr:getOwnedFarmlands() or {}
end

function RealisticCropRotationFrame:formatAreaHa(areaHa)
    return string.format("%.1f ha", tonumber(areaHa) or 0)
end

function RealisticCropRotationFrame:getIsColorBlindMode()
    if g_gameSettings == nil or GameSettings == nil
        or GameSettings.SETTING == nil
        or GameSettings.SETTING.USE_COLORBLIND_MODE == nil
        or type(g_gameSettings.getValue) ~= "function" then
        return false
    end

    return g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE) == true
end

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

function RealisticCropRotationFrame:getFruitTypeMapColor(fruitType)
    if fruitType == nil then return nil end

    local color = self:getIsColorBlindMode()
        and fruitType.colorBlindMapColor
        or fruitType.defaultMapColor

    return self:copyGuiColor(color)
end

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

function RealisticCropRotationFrame:getNormalizedPixelSize(wPx, hPx)
    if GuiUtils == nil or GuiUtils.getNormalizedScreenValues == nil then return nil end
    return GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx %dpx",
        math.floor((tonumber(wPx) or 0) + 0.5),
        math.floor((tonumber(hPx) or 0) + 0.5)
    ))
end

function RealisticCropRotationFrame:getNormalizedPixelWidth(wPx)
    local size = self:getNormalizedPixelSize(wPx, 0)
    return size ~= nil and size[1] or ((g_pixelSizeScaledX or g_pixelSizeX or 0) * (tonumber(wPx) or 0))
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

function RealisticCropRotationFrame:resizePillToText(pillBg, pillText, text, options)
    if pillBg == nil or pillText == nil then return end
    if pillBg.setSize == nil or pillText.setSize == nil then return end

    options = options or {}
    local bgSize = self:getElementOriginalSize(pillBg)
    local textSize = self:getElementOriginalSize(pillText)
    if bgSize == nil or textSize == nil then return end

    local textWidth = self:getTextRenderWidth(pillText, text)
    if textWidth == nil then return end

    local padding = self:getNormalizedPixelWidth(options.paddingPx or 20)
    local width = textWidth + padding
    if options.minWidthPx ~= nil then
        width = math.max(width, self:getNormalizedPixelWidth(options.minWidthPx))
    end
    if options.maxWidthPx ~= nil then
        width = math.min(width, self:getNormalizedPixelWidth(options.maxWidthPx))
    end
    if pillBg.parent ~= nil and pillBg.parent.absSize ~= nil
        and (pillBg.parent.absSize[1] or 0) > 0 then
        width = math.min(width, pillBg.parent.absSize[1])
    end

    pillBg:setSize(width, bgSize[2])
    pillText:setSize(width, textSize[2])

    if pillBg.parent ~= nil and pillBg.parent.invalidateLayout ~= nil then
        pillBg.parent:invalidateLayout()
    end

    return width
end

function RealisticCropRotationFrame:resizeHeroPillToText(pillBg, pillText, text)
    return self:resizePillToText(pillBg, pillText, text, {
        paddingPx = RealisticCropRotationFrame.HERO_PILL_TEXT_PADDING_PX,
        minWidthPx = RealisticCropRotationFrame.HERO_PILL_MIN_W_PX,
        maxWidthPx = RealisticCropRotationFrame.HERO_PILL_MAX_W_PX,
    })
end

function RealisticCropRotationFrame:resizeWeatherPillToText(pill, pillBg, pillIcon, pillText, text)
    if pill == nil or pillBg == nil or pillIcon == nil or pillText == nil then return nil end
    if pill.setSize == nil or pillBg.setSize == nil or pillText.setSize == nil then return nil end
    if pillIcon.setPosition == nil or pillText.setPosition == nil then return nil end

    local textWidth = self:getTextRenderWidth(pillText, text)
    if textWidth == nil then return nil end

    local iconSize = self:getNormalizedPixelSize(
        RealisticCropRotationFrame.HERO_WEATHER_ICON_PX,
        RealisticCropRotationFrame.HERO_WEATHER_ICON_PX
    )
    local heightSize = self:getNormalizedPixelSize(0, RealisticCropRotationFrame.HERO_PILL_HEIGHT_PX)
    if iconSize == nil or heightSize == nil then return nil end

    local leftPad = self:getNormalizedPixelWidth(RealisticCropRotationFrame.HERO_WEATHER_LEFT_PAD_PX)
    local rightPad = self:getNormalizedPixelWidth(RealisticCropRotationFrame.HERO_WEATHER_RIGHT_PAD_PX)
    local iconTextGap = self:getNormalizedPixelWidth(RealisticCropRotationFrame.HERO_WEATHER_ICON_TEXT_GAP_PX)
    local minWidth = self:getNormalizedPixelWidth(RealisticCropRotationFrame.HERO_PILL_MIN_W_PX)
    local maxWidth = self:getNormalizedPixelWidth(RealisticCropRotationFrame.HERO_PILL_MAX_W_PX)

    local width = leftPad + iconSize[1] + iconTextGap + textWidth + rightPad
    width = math.max(width, minWidth)
    width = math.min(width, maxWidth)

    local textBoxWidth = math.max(0, width - leftPad - iconSize[1] - iconTextGap - rightPad)
    local textX = leftPad + iconSize[1] + iconTextGap

    pill:setSize(width, heightSize[2])
    pillBg:setSize(width, heightSize[2])
    pillIcon:setPosition(leftPad, 0)
    if pillIcon.setSize ~= nil then
        pillIcon:setSize(iconSize[1], iconSize[2])
    end
    pillText:setPosition(textX, 0)
    pillText:setSize(textBoxWidth, pillText.size[2])

    if pill.parent ~= nil and pill.parent.invalidateLayout ~= nil then
        pill.parent:invalidateLayout()
    end

    return width
end

function RealisticCropRotationFrame:layoutHeroPills(titleElement, weatherPill, statusPillBg)
    local hero = titleElement ~= nil and titleElement.parent or nil
    if hero == nil and weatherPill ~= nil then hero = weatherPill.parent end
    if hero == nil and statusPillBg ~= nil then hero = statusPillBg.parent end
    if hero == nil then return end

    local heroSize = self:getElementOriginalSize(hero)
    if heroSize == nil then return end

    local gap = self:getNormalizedPixelWidth(RealisticCropRotationFrame.HERO_TITLE_PILL_GAP_PX)

    local weatherLeft = nil
    if weatherPill ~= nil and weatherPill._frWeatherPillVisible == true and weatherPill.setPosition ~= nil then
        local weatherWidth = weatherPill.size ~= nil and weatherPill.size[1] or nil
        if weatherWidth ~= nil then
            weatherLeft = math.max(0, (heroSize[1] - weatherWidth) * 0.5)
            weatherPill:setPosition(weatherLeft, 0)
        end
    end

    local statusLeft = nil
    if statusPillBg ~= nil and statusPillBg.position ~= nil and statusPillBg.size ~= nil then
        statusLeft = heroSize[1] + statusPillBg.position[1] - statusPillBg.size[1]
    end

    if titleElement ~= nil and titleElement.setSize ~= nil then
        local titlePos = self:getElementOriginalPosition(titleElement)
        local titleSize = self:getElementOriginalSize(titleElement)
        if titlePos ~= nil and titleSize ~= nil then
            local titleLimit = heroSize[1]
            if weatherLeft ~= nil then titleLimit = math.min(titleLimit, weatherLeft) end
            if statusLeft ~= nil then titleLimit = math.min(titleLimit, statusLeft) end
            local titleWidth = math.max(0, titleLimit - titlePos[1] - gap)
            titleElement:setSize(titleWidth, titleSize[2])
        end
    end
end

-- Calendar legend: each item is "<label> <square>" (square to the RIGHT of
-- the text). The whole block is right-aligned to the legend container's right
-- edge (the container itself is anchorTopRight, flush with the calendar panel).
--
-- Reading order left-to-right is Sowing, Harvest, Cover. To keep the block
-- hugging the right edge while item widths depend on the localized text, items
-- are placed from the right edge leftward in reverse order (Cover first), so
-- the visible result reads Sowing -> Harvest -> Cover with no hardcoded widths.
--
-- All maths are in NORMALIZED screen units (same convention as resizePillToText
-- and layoutGroupBadgeContent): getTextRenderWidth returns normalized widths,
-- and setPosition/setSize consume normalized values directly. Fixed pixel
-- constants are converted once via GuiUtils.getNormalizedScreenValues.
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

    -- cursorX = right edge of the next (leftward) item, in normalized units,
    -- measured from the container's own left edge (children are anchorTopLeft).
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

function RealisticCropRotationFrame:getPlanForFarmland(farmlandId)
    local mgr = self:getManager()
    if mgr ~= nil and mgr.getRotationPlan ~= nil then
        return mgr:getRotationPlan(farmlandId)
    end
    return {"","","",""}
end

function RealisticCropRotationFrame:getCoverPlanForFarmland(farmlandId)
    local mgr = self:getManager()
    if mgr ~= nil and mgr.getRotationCoverPlan ~= nil then
        return mgr:getRotationCoverPlan(farmlandId)
    end
    return {"","","",""}
end

-- ===========================================================================
--  CROP LIST (built once from fruitTypeManager; drives plan slot selectors)
-- ===========================================================================

function RealisticCropRotationFrame:buildPlanCropList()
    self.planCropList = {""}  -- index 1 = no crop
    self.coverCropList = {""}
    -- Only offer cover crops whose fruitType is actually registered on this map
    -- (e.g. FLOWERINGCATCHCROP is a map-specific foliage, not present everywhere).
    -- No fillType/icon requirement here: catch-crop-only fruitTypes have no
    -- harvest fillType linkage (see getFillTypeForCrop/applySlotCropIcon fallback).
    for _, cropName in ipairs(RealisticCropRotationFrame.COVER_CROP_NAMES) do
        local available = g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil
            and g_fruitTypeManager:getFruitTypeByName(cropName) ~= nil
        if available then
            table.insert(self.coverCropList, cropName)
        end
    end

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
    --   3. Neutral "no crop" fallback. NEVER the fallow label — fallow is an
    --      agronomic choice, not a generic "no crop here" indicator.
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

    local iconBgColor = nil
    local soilStateIndex = nil
    local soilStateIndexResolved = false
    if activeCropName == nil and mgr ~= nil
        and type(mgr.getCurrentSoilStateIndex) == "function" then
        soilStateIndexResolved = true
        soilStateIndex = mgr:getCurrentSoilStateIndex(entry.farmlandId)
    end
    if iconFruitType ~= nil then
        iconBgColor = self:getFruitTypeMapColor(iconFruitType)
    elseif soilStateIndex ~= nil then
        iconBgColor = self:getSoilStateMapColor(soilStateIndex)
    elseif mgr ~= nil and type(mgr.getCurrentGroundStateIndex) == "function" then
        iconBgColor = self:getGroundStateMapColor(mgr:getCurrentGroundStateIndex(entry.farmlandId))
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
                local badgeKey = family == "COVER" and "rcr_cover_crop" or "rcr_family_" .. string.lower(family)
                line = line .. "  ·  " .. self.i18n:getText(badgeKey)
            end
            cropLineEl:setText(line)
        else
            local groundLabel = nil
            if mgr ~= nil and type(mgr.getCurrentSoilStateLabel) == "function"
                and (soilStateIndex ~= nil or not soilStateIndexResolved) then
                groundLabel = mgr:getCurrentSoilStateLabel(entry.farmlandId, soilStateIndex)
            end
            if mgr ~= nil and type(mgr.getCurrentGroundStateLabel) == "function" then
                groundLabel = groundLabel or mgr:getCurrentGroundStateLabel(entry.farmlandId)
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
    if mgr ~= nil and type(mgr.getCurrentSoilStateLabel) == "function" then
        groundLabel = mgr:getCurrentSoilStateLabel(farmlandId)
    end
    if mgr ~= nil and type(mgr.getCurrentGroundStateLabel) == "function" then
        groundLabel = groundLabel or mgr:getCurrentGroundStateLabel(farmlandId)
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

    local mgr = self:getManager()
    self:updateWeatherPill(self.weatherPill, self.weatherPillBg, self.weatherPillIcon, self.weatherPillText)
    self:updateResiduePill(self.statusPillBg, self.statusPillText, farmlandId)
    self:layoutHeroPills(self.detailTitle, self.weatherPill, self.statusPillBg)

    local history = (mgr ~= nil) and (mgr:getHistory(farmlandId) or {}) or {}

    -- Slot 1 is the current crop (leftmost); slots 2..5 are history N-1..N-4
    -- (history[1] = N-1), so the strip reads from the present on the left
    -- back into the past on the right.
    local currentCropName, currentFamily, currentFallbackText = self:getCurrentSlotData(farmlandId)
    local currentBadgeKey = currentFamily == "COVER" and "rcr_cover_crop" or nil
    self:updateTimelineSlot(1, currentCropName, currentFamily, currentFallbackText, currentBadgeKey)

    for histIdx = 1, 4 do
        local hEntry   = history[histIdx]
        local cropName = hEntry and hEntry.crop or nil
        self:updateTimelineSlot(histIdx + 1, cropName, self:getCropFamily(cropName), nil)
    end

    self:updateNitrogenGauge(farmlandId)
    self:updateSoilPHGauge(farmlandId)
    self:updateAdvice(currentFamily)
    self:updateYieldCard(farmlandId)
end

-- ---------------------------------------------------------------------------
--  Timeline slot (slotId 1..5) — history tab
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:updateTimelineSlot(slotId, cropName, family, fallbackText, badgeTextKey)
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
            local familyText = self.i18n:getText(badgeTextKey or "rcr_family_" .. string.lower(family))
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

-- ---------------------------------------------------------------------------
--  Nitrogen gauge
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:updateNitrogenGauge(farmlandId)
    local mgr = self:getManager()
    local ratio = 0
    local labelKey = "rcr_n_none"
    local stateText = nil
    local valueText = nil

    -- Precision Farming path: PF nitrogen average when PF is installed. false =
    -- soil not analysed ("not sampled"); nil = no PF -> vanilla fallback.
    if mgr ~= nil and mgr.getNitrogenLevel ~= nil then
        local actualN, targetN, minN, maxN = mgr:getNitrogenLevel(farmlandId)
        if actualN == false then
            labelKey = "rcr_soil_not_sampled"
            stateText = self.i18n:getText("rcr_soil_not_sampled")
            ratio = 0
        elseif actualN ~= nil then
            minN = tonumber(minN) or 0
            maxN = tonumber(maxN) or 0
            labelKey = "rcr_n_average_pf"
            if targetN ~= nil then
                ratio = targetN > 0 and (actualN / targetN) or 0
                stateText = string.format(self.i18n:getText("rcr_n_average_value"), actualN)
                valueText = string.format(self.i18n:getText("rcr_n_crop_need"), targetN)
            else
                ratio = maxN > minN and ((actualN - minN) / (maxN - minN)) or 0
                stateText = string.format(self.i18n:getText("rcr_n_average_value"), actualN)
            end
        end
    end

    -- Vanilla fallback: base-game fertilisation level (SPRAY_LEVEL).
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

    self:setStatusBarFill(self.nitrogenBarFill, ratio)

    if self.nitrogenStateLabel ~= nil then
        self.nitrogenStateLabel:setText(stateText or self.i18n:getText(labelKey))
    end

    if self.nitrogenValueLabel ~= nil then
        self.nitrogenValueLabel:setText(valueText or "")
        self.nitrogenValueLabel:setVisible(valueText ~= nil)
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
        if actualPH == false then
            labelKey = "rcr_soil_not_sampled"
            stateText = self.i18n:getText("rcr_soil_not_sampled")
            ratio = 0
        elseif actualPH ~= nil then
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
    local hasStage = info ~= nil and info.growthStageText ~= nil
    local hasWeed = info ~= nil and info.weedActionText ~= nil

    -- Yield KPI: a standing crop shows the POTENTIAL yield in t/ha (PF's "Potentiel
    -- de rendement", full-field, exact); once harvested (no standing crop) it shows
    -- the REAL harvested LITRES from PF's statistics.
    local function fmtTHa(v) return string.format("%.1f t/ha", v) end
    local function fmtL(v)
        if g_i18n ~= nil and g_i18n.formatVolume ~= nil then return g_i18n:formatVolume(v, 0) end
        return string.format("%d L", math.floor(v + 0.5))
    end
    local hasYield = false
    if info ~= nil and info.potentialTHa ~= nil then
        totalText, hasYield = fmtTHa(tonumber(info.potentialTHa) or 0), true
    else
        local harvested = (mgr ~= nil and mgr.getHarvestedYield ~= nil)
            and mgr:getHarvestedYield(farmlandId) or nil
        if harvested ~= nil and harvested > 0 then
            totalText, hasYield = fmtL(harvested), true
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

    -- Weed and stage KPIs use a smaller dedicated profile because their text
    -- (the weed tool name, and "(X/Y) · <tier>" for stage) would not fit one
    -- line at the default 26px size used for the litre value.
    --
    -- The weed KPI mirrors the on-foot HUD line: its header carries the game's
    -- weed stage label (info.weedHeader) and its value the game's tool
    -- recommendation (info.weedActionText). When no weed applies, the header
    -- falls back to the static "rcr_weed_header" caption.
    if self.weedHeaderText ~= nil then
        local headerText = (hasWeed and info.weedHeader ~= nil)
            and info.weedHeader
            or self.i18n:getText("rcr_weed_header")
        self.weedHeaderText:setText(headerText)
    end

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

    self:updateCalendar(farmlandId)
    local plan = self:getPlanForFarmland(farmlandId)
    local coverPlan = self:getCoverPlanForFarmland(farmlandId)
    self:updateScoreCard(plan, coverPlan)
    self:updateWeatherPill(self.planWeatherPill, self.planWeatherPillBg, self.planWeatherPillIcon, self.planWeatherPillText)
    self:updatePlannedResiduePill(self.planStatusPillBg, self.planStatusPillText, plan, coverPlan)
    self:layoutHeroPills(self.planTitle, self.planWeatherPill, self.planStatusPillBg)
end

-- ---------------------------------------------------------------------------
--  Annual calendar — crop selector + sow window + cover marker
-- ---------------------------------------------------------------------------

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

function RealisticCropRotationFrame:getCalendarGrowthMode()
    return g_currentMission ~= nil
        and g_currentMission.missionInfo ~= nil
        and g_currentMission.missionInfo.growthMode
        or nil
end

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

-- Per calendar flags index, whether the cover crop is actively growing toward
-- harvest in that period -- i.e. the period is inside its growing season, not
-- winter dormancy. Derived from the game's own data:
--   * harvest-ready state = fruitType.minHarvestingGrowthState (radish=2, the
--     flowering catch crop=4 in vanilla data);
--   * a period qualifies when a plant one step below that state advances into it
--     (growthDataSeasonal.periods[p].growthMapping[minHarvest-1] >= minHarvest).
-- This single rule fits both shapes of cover: the radish, whose harvest-ready
-- state IS its first visible state (so germinating 1->2 is its growth, possible
-- only Mar-Oct), and the catch crop, which needs real vegetative growth 3->4
-- (possible only Apr-Nov). Winter periods stall or regress that final step.
--
-- Returns nil when the growth data cannot be read (no growthMapping, or no such
-- transition anywhere) so callers treat it as "unknown" and skip the growth
-- constraint rather than hiding the cover.
function RealisticCropRotationFrame:getCropGrowthPeriods(cropName, periodCount, firstPeriod)
    if cropName == nil or cropName == "" then return nil end
    if g_fruitTypeManager == nil or type(g_fruitTypeManager.getFruitTypeByName) ~= "function" then return nil end

    local fruitDesc = g_fruitTypeManager:getFruitTypeByName(string.upper(tostring(cropName)))
    if fruitDesc == nil then return nil end

    local data = fruitDesc.growthDataSeasonal
    if type(data) ~= "table" or type(data.periods) ~= "table" then return nil end

    local mature = tonumber(fruitDesc.minHarvestingGrowthState)
    if mature == nil or mature < 2 then return nil end
    local finalStep = mature - 1

    periodCount = math.max(1, tonumber(periodCount) or 12)
    firstPeriod = tonumber(firstPeriod) or 1
    local grow = {}
    local anyGrowth = false
    for i = 1, periodCount do
        local period = ((firstPeriod - 1 + i - 1) % periodCount) + 1
        local pd = data.periods[period]
        local advances = false
        if pd ~= nil and type(pd.growthMapping) == "table" then
            local nextState = pd.growthMapping[finalStep]
            advances = type(nextState) == "number" and nextState >= mature
        end
        grow[i] = advances
        if advances then anyGrowth = true end
    end

    if not anyGrowth then return nil end
    return grow
end

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

function RealisticCropRotationFrame:getCropPlantingWindow(cropName, periodCount, firstPeriod)
    local plant = self:getCropPeriodFlags(cropName, periodCount, firstPeriod)
    if plant == nil then return nil end

    local bestStart, bestLen = nil, 0
    for _, run in ipairs(self:getFlagRuns(plant, periodCount)) do
        if run.len > bestLen then
            bestStart, bestLen = run.start, run.len
        end
    end

    if bestStart == nil or bestLen <= 0 then return nil end
    return bestStart, bestLen
end

function RealisticCropRotationFrame:getCropHarvestWindow(cropName, periodCount, firstPeriod)
    local _, harvest = self:getCropPeriodFlags(cropName, periodCount, firstPeriod)
    if harvest == nil then return nil end

    local bestStart, bestLen = nil, 0
    for _, run in ipairs(self:getFlagRuns(harvest, periodCount)) do
        if run.len > bestLen then
            bestStart, bestLen = run.start, run.len
        end
    end

    if bestStart == nil or bestLen <= 0 then return nil end
    return bestStart, bestLen
end

-- Thick on season boundaries (every CALENDAR_SEASON_LEN-th line: 1,4,7,10,13),
-- thin otherwise. Index is 1-based across the 13 grid lines.
function RealisticCropRotationFrame:getCalendarGridLineWidth(i)
    local seasonLen = RealisticCropRotationFrame.CALENDAR_SEASON_LEN
    if seasonLen >= 1 and ((i - 1) % seasonLen) == 0 then
        return RealisticCropRotationFrame.CALENDAR_GRID_W_THICK
    end
    return RealisticCropRotationFrame.CALENDAR_GRID_W_THIN
end

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
        -- Fraction of the way through the current month. Defaults to mid-column
        -- (0.5) and is refined to the real day-in-period when the environment
        -- exposes it (env.plannedDaysPerPeriod + env:getDayInPeriodFromDay).
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
            -- Inset each end by the width of the grid line that bounds it, so the
            -- bar ends sit cleanly between the lines instead of under them. The
            -- bounding lines are at indices startP (left) and startP+lenP (right).
            local leftInset  = self:getCalendarGridLineWidth(startP)
            local rightInset = self:getCalendarGridLineWidth(startP + lenP)
            local x = axisX + ((startP - 1) * periodW) + leftInset
            local w = (lenP * periodW) - leftInset - rightInset
            self:setElementPixelPosition(bar, x, y)
            self:setElementPixelSize(bar, math.max(4, w), LANE_H)

            -- The pixel-based x/w above are rounded independently from the grid
            -- lines' own positions, which can leave a 1px mismatch between a bar
            -- edge and its bounding line (e.g. flush on one side, a 1px gap on
            -- the other). Snap the bar's left/right edges to the bounding grid
            -- lines' actual rendered edges so both sides line up identically.
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

    -- cover crop: planting only (covers are never harvested), middle lane, tinted to its
    -- planner-card colour (RGB) so it reads as the cover and not a main crop.
    local cStart, cLen = nil, nil
    if hasCover then
        cStart, cLen = longestRun(self:getCropPeriodFlags(coverCropName, periodCount, firstPeriod))
    end
    if placeBar(coverMarker, cStart, cLen, COVER_Y, hasCover) then
        coverMarker.color = RealisticCropRotationFrame.FAMILY_RGBA[self:getCropFamily(coverCropName)]
            or RealisticCropRotationFrame.FAMILY_RGBA.COVER
    end
end

function RealisticCropRotationFrame:copyFourSlotPlan(plan)
    local copy = {"", "", "", ""}
    for i = 1, 4 do
        copy[i] = plan ~= nil and (plan[i] or "") or ""
    end
    return copy
end

function RealisticCropRotationFrame:getCalendarEditSlotIndex()
    local slotIdx = math.floor(tonumber(self.calendarEditSlotIdx) or 1)
    slotIdx = math.max(1, math.min(4, slotIdx))
    self.calendarEditSlotIdx = slotIdx
    return slotIdx
end

function RealisticCropRotationFrame:setSelectorStateFromCrop(selector, list, cropName)
    if selector == nil or list == nil then return end
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
        self.calendarLocalPlan ~= nil and self.calendarLocalPlan[slotIdx] or ""
    )
    self:setSelectorStateFromCrop(
        self.calendarEditCoverSelector,
        self.coverCropList,
        self.calendarLocalCoverPlan ~= nil and self.calendarLocalCoverPlan[slotIdx] or ""
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
    self:layoutHeroPills(self.planTitle, self.planWeatherPill, self.planStatusPillBg)
end

function RealisticCropRotationFrame:updateCalendar(farmlandId)
    self.calendarLocalPlan = self:copyFourSlotPlan(self:getPlanForFarmland(farmlandId))
    self.calendarLocalCoverPlan = self:copyFourSlotPlan(self:getCoverPlanForFarmland(farmlandId))
    self:updateCalendarEditorSelectorsFromSlot()
    self:renderCalendarFromLocalPlans()
end

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

function RealisticCropRotationFrame:updateCalendarVisualsFromSelectors()
    self.calendarLocalPlan = self:getPlanFromSelectors()
    self.calendarLocalCoverPlan = self:getCoverPlanFromSelectors()
    self:renderCalendarFromLocalPlans()
end

function RealisticCropRotationFrame:onServerSyncReceived()
    if self.isApplyingServerSync then
        return
    end

    self.isApplyingServerSync = true

    -- In the history tab it is safe to rebuild the sidebar/details from the
    -- authoritative server snapshot.
    -- In the planner tab, do NOT call populateSidebar/updateCalendar here:
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
        self:updateCalendarVisualsFromSelectors()
    end

    self.isApplyingServerSync = false
end

function RealisticCropRotationFrame:applySlotCropIcon(iconEl, cropName)
    if iconEl == nil then return end
    if cropName == nil or cropName == "" then
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

-- ---------------------------------------------------------------------------
--  Calendar editor onClick handlers
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:onChangeCalendarEditStep()
    if self.isApplyingServerSync then return end
    self.calendarEditSlotIdx = self:getCalendarEditSlotIndex()
    self:updateCalendarEditorSelectorsFromSlot()
    self:renderCalendarFromLocalPlans()
end

-- Lets the user select a calendar row by clicking it directly
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

function RealisticCropRotationFrame:onChangeCalendarEditCrop()
    self:handleCalendarCropChange(self:getCalendarEditSlotIndex())
end

function RealisticCropRotationFrame:onChangeCalendarEditCover()
    self:handleCalendarCoverChange(self:getCalendarEditSlotIndex())
end

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

    -- Keep the overview refreshed from the repository. On MP clients this may
    -- lag one server snapshot behind, but it avoids using local optimistic data
    -- as saved truth. The calendar itself is updated directly above.
    self:buildRotationGroups()
    if self.listPlanOverview ~= nil then
        self.listPlanOverview:reloadData()
    end
end

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

-- ---------------------------------------------------------------------------
--  Score card
-- ---------------------------------------------------------------------------

function RealisticCropRotationFrame:updateScoreCard(plan, coverPlan)
    if self.scoreText == nil then return end
    plan = plan or {"","","",""}
    coverPlan = coverPlan or {"","","",""}

    local score    = self:calcRotationScore(plan, coverPlan)
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

function RealisticCropRotationFrame:calcRotationScore(plan, coverPlan)
    local families = {}
    for i = 1, 4 do
        local crop = plan[i] or ""
        if crop ~= "" then
            local fam = self:getCropFamily(crop)
            if fam ~= "UNKNOWN" then
                families[i] = fam
            end
        end
    end

    local filledCount = 0
    for _ in pairs(families) do filledCount = filledCount + 1 end
    if filledCount < 2 then return 0 end

    -- With only 2 slots filled, there is a single transition and not enough
    -- information to call the rotation "excellent" yet (years 3-4 are still
    -- unknown). Cap the starting score so such plans land in "good" at best;
    -- penalties still apply in full. From 3 filled slots on, a real rotation
    -- pattern exists and the full 0..100 range (incl. bonuses) is available.
    local score = (filledCount >= 3) and 100 or 70

    -- Family return-interval penalty: for every pair of slots sharing the
    -- same family, penalize if they are closer together than the family's
    -- minimum recommended interval. A cover crop right after the earlier
    -- slot halves the penalty (it helps break the cycle). No wraparound:
    -- the plan is a 4-year window, not a repeating cycle.
    for i = 1, 3 do
        for j = i + 1, 4 do
            local fam = families[i]
            if fam ~= nil and fam == families[j] then
                local minInterval = RealisticCropRotationFrame.FAMILY_MIN_INTERVAL[fam]
                if minInterval ~= nil then
                    local interval = j - i
                    if interval < minInterval then
                        local penalty = (minInterval - interval) * RealisticCropRotationFrame.SCORE_FAMILY_PENALTY_PER_YEAR
                        local coverCrop = coverPlan ~= nil and coverPlan[i] or ""
                        if coverCrop ~= nil and coverCrop ~= "" then
                            penalty = penalty / 2
                        end
                        score = score - penalty
                    end
                end
            end
        end
    end

    if filledCount >= 3 then
        -- Legume directly followed by a cereal: the returned nitrogen is put to good use.
        for i = 1, 3 do
            if families[i] == "LEGUME" and families[i + 1] == "CEREAL" then
                score = score + RealisticCropRotationFrame.SCORE_LEGUME_CEREAL_BONUS
            end
        end

        -- Diversity bonus: share of distinct families among filled slots.
        local seen = {}
        for _, fam in pairs(families) do seen[fam] = true end
        local uniqueCount = 0
        for _ in pairs(seen) do uniqueCount = uniqueCount + 1 end
        score = score + (uniqueCount / filledCount) * RealisticCropRotationFrame.SCORE_DIVERSITY_BONUS_MAX
    end

    -- A rotation that returns zero nitrogen to the soil (no legume/forage
    -- credit, no cover crop) cannot be "excellent" regardless of family
    -- diversity or interval spacing: the mod's whole premise is that good
    -- rotations build up a residue. Cap such plans at the same ceiling as
    -- incomplete (2-slot) plans, i.e. "good" at best.
    if self:getPlanNitrogenResidueKgHa(plan, coverPlan) == nil then
        score = math.min(score, 70)
    end

    return math.max(0, math.min(100, math.floor(score + 0.5)))
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
            })
            groupMap[key] = #groups
        end
        local group = groups[groupMap[key]]
        table.insert(group.fieldNames, entry.name)
        group.areaHa = (group.areaHa or 0) + (tonumber(entry.areaHa) or 0)
    end

    -- Sort: non-empty plans first, then by field count (desc), then by score (desc)
    local emptyKey = "||||||||"
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

-- Formats a planting window [start, start+len-1] (period indices, possibly
-- wrapping past periodCount) as a month range (e.g. "Sep-Oct"), using the
-- same month-key mapping as the calendar tab axis (flags index i <->
-- CALENDAR_MONTH_KEYS[i]).
function RealisticCropRotationFrame:formatCalendarPeriodRange(start, len, periodCount)
    if start == nil or len == nil or len <= 0 then return "" end

    local startKey = RealisticCropRotationFrame.CALENDAR_MONTH_KEYS[((start - 1) % 12) + 1]
    local startLabel = self.i18n:getText(startKey)
    if len <= 1 then return startLabel end

    local endIndex = ((start - 1 + len - 1) % periodCount) + 1
    local endKey = RealisticCropRotationFrame.CALENDAR_MONTH_KEYS[((endIndex - 1) % 12) + 1]
    local endLabel = self.i18n:getText(endKey)
    return startLabel .. "-" .. endLabel
end

-- Cover crop sowing window for a rotation slot, derived entirely from game data
-- (no hard-coded dates). For each candidate month it answers one question: "if
-- the cover is sown this month, can it still accumulate its minimum growth before
-- the next main crop is sown (and so release its residue)?". A month qualifies
-- when all of:
--   (1) it is in the free window between this slot's crop being harvested and the
--       next crop being sown. The rotation cycles, so "next" is the next NON-EMPTY
--       slot going forward (in a 3-crop plan, slot 3's next is slot 1).
--   (2) the cover may be sown that month (growthDataSeasonal.plantingAllowed).
--   (3) at least COVER_MIN_GROWTH_MONTHS growth-possible months remain before the
--       next crop is sown (growthDataSeasonal.growthMapping). Growth is counted
--       only in months where the crop actually advances -- winter stalls do not
--       count -- and may run past the sowing window, since sowing and growing are
--       separate windows.
-- Constraints whose runtime data the engine does not expose are skipped, so a
-- cover is never hidden merely for lack of that data.
function RealisticCropRotationFrame:getRotationAwareCoverSowingText(group, slotIndex, periodCount, firstPeriod)
    local coverName = group.coverPlan[slotIndex] or ""
    if coverName == "" then return "" end

    -- (1a) The field is free only once this slot's own main crop is harvested.
    local mainCrop = group.plan[slotIndex] or ""
    local harvestStart, harvestLen = self:getCropHarvestWindow(mainCrop, periodCount, firstPeriod)
    if harvestStart == nil then return "" end
    local fieldFreeStart = ((harvestStart - 1 + harvestLen) % periodCount) + 1

    -- (1b) The destruction deadline is when the next main crop is sown. The
    -- rotation cycles, so "next" is the next non-empty slot going forward (a
    -- 3-crop plan's slot 3 wraps to slot 1, not the empty slot 4).
    local nextCrop = ""
    for step = 1, 3 do
        local idx = ((slotIndex - 1 + step) % 4) + 1
        local c = group.plan[idx] or ""
        if c ~= "" then nextCrop = c; break end
    end
    local nextStart = self:getCropPlantingWindow(nextCrop, periodCount, firstPeriod)
    if nextStart == nil or nextStart == fieldFreeStart then return "" end

    -- Free window [fieldFreeStart .. nextStart-1], walked by offset 0..freeLen-1.
    local freeLen = ((nextStart - 1 - fieldFreeStart) % periodCount) + 1

    local plantable = self:getCropPeriodFlags(coverName, periodCount, firstPeriod)
    local growsIn = self:getCropGrowthPeriods(coverName, periodCount, firstPeriod)

    -- Growth-possible months still available from a candidate sowing month up to
    -- the deadline. Growth happens only in growth-possible months and may continue
    -- after the sowing window has closed. If the engine did not expose growth data
    -- for this cover, do not restrict on it.
    local function growthMonthsAvailable(fromOffset)
        if growsIn == nil then
            return RealisticCropRotationFrame.COVER_MIN_GROWTH_MONTHS
        end
        local count = 0
        for o = fromOffset, freeLen - 1 do
            local p = ((fieldFreeStart - 1 + o) % periodCount) + 1
            if growsIn[p] then count = count + 1 end
        end
        return count
    end

    -- Keep the contiguous run of months that are both sowable and leave enough
    -- growth before the deadline. The start slides forward to the first such month.
    local needed = RealisticCropRotationFrame.COVER_MIN_GROWTH_MONTHS
    local sowStart, sowLen = nil, 0
    for offset = 0, freeLen - 1 do
        local p = ((fieldFreeStart - 1 + offset) % periodCount) + 1
        local valid = (plantable == nil or plantable[p] == true)
            and growthMonthsAvailable(offset) >= needed

        if valid then
            if sowStart == nil then sowStart = p end
            sowLen = sowLen + 1
        elseif sowStart ~= nil then
            break
        end
    end

    if sowStart == nil or sowLen <= 0 then return "" end
    return self:formatCalendarPeriodRange(sowStart, sowLen, periodCount)
end

-- Cover crop recap, displayed on its own line. For each rotation slot with
-- a planned cover crop, states the cover crop's name and its rotation-aware
-- sowing period (month range), so the player knows when to sow it.
function RealisticCropRotationFrame:getGroupCoverRecapText(group)
    if group == nil or group.coverPlan == nil then return "" end

    local periodCount, firstPeriod = self:getCalendarPeriodInfo()
    local yearKeys = { "rcr_plan_year1", "rcr_plan_year2", "rcr_plan_year3", "rcr_plan_year4" }

    local parts = {}
    for i = 1, 4 do
        local coverName = group.coverPlan[i] or ""
        if coverName ~= "" then
            local sowingPeriod = self:getRotationAwareCoverSowingText(group, i, periodCount, firstPeriod)
            if sowingPeriod ~= "" then
                table.insert(parts, string.format(
                    self.i18n:getText("rcr_overview_cover_entry"),
                    self.i18n:getText(yearKeys[i]),
                    self:getCropDisplayName(coverName),
                    sowingPeriod
                ))
            end
        end
    end

    return table.concat(parts, "   ·   ")
end

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

function RealisticCropRotationFrame:getGroupSlotDisplay(group, slotIndex, firstFilled, lastFilled)
    local plan = group ~= nil and group.plan or nil
    local cropName = plan ~= nil and (plan[slotIndex] or "") or ""
    if cropName ~= "" then
        return true, true, self:getCropDisplayName(cropName), cropName
    end

    if firstFilled ~= nil and lastFilled ~= nil
        and slotIndex > firstFilled and slotIndex < lastFilled then
        return true, false, self.i18n:getText("rcr_plan_none"), ""
    end

    return false, false, "", ""
end

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

    local badgeWidth = math.min(
        badgeSize[1],
        math.max(iconWidth + iconTextGap + paddingSize[1], iconWidth + iconTextGap + textWidth + paddingSize[1])
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

            local badgeWidth = self:layoutGroupBadgeContent(cell, i, displayName, currentX, hasCrop)

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
