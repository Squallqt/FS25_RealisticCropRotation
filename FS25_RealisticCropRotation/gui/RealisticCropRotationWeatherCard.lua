-- Copyright © 2026 Squallqt. All rights reserved.
-- Self-contained weather card presenter for the in-game menu header.
RealisticCropRotationWeatherCard = {}
local RealisticCropRotationWeatherCard_mt = { __index = RealisticCropRotationWeatherCard }

RealisticCropRotationWeatherCard.DAY_LENGTH_MS = 86400000
RealisticCropRotationWeatherCard.REFRESH_INTERVAL_MS = 5000

-- Layout values are kept in pixels and converted at runtime so the card remains resolution-safe.
RealisticCropRotationWeatherCard.TITLE_GAP_PX = 24
RealisticCropRotationWeatherCard.CONTENT_LEFT_PX = 76
RealisticCropRotationWeatherCard.CONDITION_DIVIDER_GAP_PX = 14
RealisticCropRotationWeatherCard.DIVIDER_WIDTH_PX = 1
RealisticCropRotationWeatherCard.DIVIDER_TIMING_GAP_PX = 14
RealisticCropRotationWeatherCard.RIGHT_PADDING_PX = 12

-- Weather data is presentation-only: engine constants are resolved lazily after the mission exists.
RealisticCropRotationWeatherCard.WEATHER_TYPES = {
    { constant = "SUN",              textKey = "rcr_weather_sun",              sliceId = "gui.icon_weather_sun",             color = {0.52, 0.62, 0.12, 1.00} },
    { constant = "PARTIALLY_CLOUDY", textKey = "rcr_weather_partially_cloudy", sliceId = "gui.icon_weather_partiallyCloudy", color = {0.24, 0.47, 0.53, 1.00} },
    { constant = "CLOUDY",           textKey = "rcr_weather_cloudy",           sliceId = "gui.icon_weather_cloudy",          color = {0.34, 0.41, 0.45, 1.00} },
    { constant = "RAIN",             textKey = "rcr_weather_rain",             sliceId = "gui.icon_weather_rain",            color = {0.18, 0.48, 0.66, 1.00}, isOperational = true },
    { constant = "SNOW",             textKey = "rcr_weather_snow",             sliceId = "gui.icon_weather_snow",            color = {0.52, 0.68, 0.76, 1.00}, isOperational = true },
    { constant = "HAIL",             textKey = "rcr_weather_hail",             sliceId = "gui.icon_weather_hail",            color = {0.48, 0.43, 0.68, 1.00}, isOperational = true },
    { constant = "TWISTER",          textKey = "rcr_weather_twister",          sliceId = "gui.icon_weather_twister",         color = {0.72, 0.31, 0.15, 1.00}, isOperational = true },
    { constant = "THUNDER",          textKey = "rcr_weather_thunder",          sliceId = "gui.icon_weather_thunder",         color = {0.78, 0.58, 0.10, 1.00}, isOperational = true },
}

local function trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function cleanLeadingSeparator(text)
    text = trim(text)
    text = text:gsub("^[·|:]+%s*", "")
    return trim(text)
end

local function setVisible(element, visible)
    if element ~= nil and element.setVisible ~= nil then
        element:setVisible(visible == true)
    end
end

local function setText(element, text)
    if element ~= nil and element.setText ~= nil then
        element:setText(text or "")
    end
end

local function setElementColor(element, color)
    if element == nil or color == nil then return end

    local rgba = {color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1}
    element.color = {rgba[1], rgba[2], rgba[3], rgba[4]}
    element.colorSelected = {rgba[1], rgba[2], rgba[3], rgba[4]}
    element.colorFocused = {rgba[1], rgba[2], rgba[3], rgba[4]}
    element.colorHighlighted = {rgba[1], rgba[2], rgba[3], rgba[4]}
    element.colorPressed = {rgba[1], rgba[2], rgba[3], rgba[4]}

    if element.setImageColor ~= nil then
        element:setImageColor(nil, rgba[1], rgba[2], rgba[3], rgba[4])
    end
end

function RealisticCropRotationWeatherCard.new(owner, i18n)
    local self = setmetatable({}, RealisticCropRotationWeatherCard_mt)
    self.owner = owner
    self.i18n = i18n or g_i18n
    self.controls = {}
    self.refreshTimerMs = 0
    self.lastSignature = nil
    self.cardRightEdge = nil
    return self
end

---Binds the GUI controls after the XML tree has been instantiated.
-- @param table controls
function RealisticCropRotationWeatherCard:bind(controls)
    self.controls = controls or {}
    self.lastSignature = nil
    self.cardRightEdge = nil
    setVisible(self.controls.root, false)
end

---Returns the active mission weather object.
-- @return table weather, or nil
function RealisticCropRotationWeatherCard:getWeather()
    local mission = g_currentMission
    if mission == nil or mission.environment == nil then return nil end
    return mission.environment.weather
end

---Returns the presentation spec matching an engine weather type.
-- @param integer weatherType
-- @return table spec, or nil
function RealisticCropRotationWeatherCard:getWeatherTypeSpec(weatherType)
    if weatherType == nil or WeatherType == nil then return nil end

    for _, spec in ipairs(RealisticCropRotationWeatherCard.WEATHER_TYPES) do
        local value = WeatherType[spec.constant]
        if value ~= nil and value == weatherType then
            return spec
        end
    end

    return nil
end

---Resolves the engine weather type referenced by a forecast item.
-- @param table weather
-- @param table item
-- @return integer weatherType, or nil
function RealisticCropRotationWeatherCard:getForecastWeatherType(weather, item)
    if weather == nil or item == nil or type(weather.getWeatherObjectByIndex) ~= "function" then return nil end
    if item.season == nil or item.objectIndex == nil then return nil end

    local ok, weatherObject = pcall(weather.getWeatherObjectByIndex, weather, item.season, item.objectIndex)
    if not ok or weatherObject == nil then return nil end
    return weatherObject.weatherType
end

---Returns milliseconds from now to a forecast day/dayTime pair.
-- @param table environment
-- @param integer day
-- @param integer dayTime
-- @return integer deltaMs, or nil
function RealisticCropRotationWeatherCard:getForecastDeltaMs(environment, day, dayTime)
    if environment == nil or environment.currentMonotonicDay == nil or environment.dayTime == nil then return nil end
    if day == nil or dayTime == nil then return nil end

    return (day - environment.currentMonotonicDay) * RealisticCropRotationWeatherCard.DAY_LENGTH_MS
        + (dayTime - environment.dayTime)
end

---Normalizes one engine forecast item into a UI-safe event model.
-- @param table weather
-- @param table environment
-- @param table item
-- @return table event, or nil
function RealisticCropRotationWeatherCard:normalizeForecastItem(weather, environment, item)
    if item == nil or item.startDay == nil or item.startDayTime == nil then return nil end

    local weatherType = self:getForecastWeatherType(weather, item)
    local spec = self:getWeatherTypeSpec(weatherType)
    if spec == nil then return nil end

    local duration = math.max(0, tonumber(item.duration) or 0)
    local endDay = item.startDay
    local endDayTime = item.startDayTime + duration

    if type(environment.getDayAndDayTime) == "function" then
        endDay, endDayTime = environment:getDayAndDayTime(endDayTime, item.startDay)
    elseif endDayTime >= RealisticCropRotationWeatherCard.DAY_LENGTH_MS then
        endDay = endDay + math.floor(endDayTime / RealisticCropRotationWeatherCard.DAY_LENGTH_MS)
        endDayTime = endDayTime % RealisticCropRotationWeatherCard.DAY_LENGTH_MS
    end

    local startDelta = self:getForecastDeltaMs(environment, item.startDay, item.startDayTime)
    local endDelta = self:getForecastDeltaMs(environment, endDay, endDayTime)
    if startDelta == nil or endDelta == nil or endDelta <= startDelta then return nil end

    return {
        spec = spec,
        weatherType = weatherType,
        startDay = item.startDay,
        startDayTime = item.startDayTime,
        endDay = endDay,
        endDayTime = endDayTime,
        startDelta = startDelta,
        endDelta = endDelta,
        dayOffset = math.max(0, item.startDay - environment.currentMonotonicDay),
        isCurrent = startDelta <= 0 and endDelta > 0,
        isOperational = spec.isOperational == true,
    }
end

---Selects the most useful event: current disruptive weather, next disruptive, current calm, then next calm.
-- @return table event, or nil
function RealisticCropRotationWeatherCard:selectForecastEvent()
    local weather = self:getWeather()
    if weather == nil or type(weather.forecastItems) ~= "table" or #weather.forecastItems == 0 then return nil end

    local environment = weather.owner or (g_currentMission ~= nil and g_currentMission.environment or nil)
    if environment == nil or environment.currentMonotonicDay == nil or environment.dayTime == nil then return nil end

    local events = {}
    for _, item in ipairs(weather.forecastItems) do
        local event = self:normalizeForecastItem(weather, environment, item)
        if event ~= nil and event.endDelta > 0 then
            events[#events + 1] = event
        end
    end

    table.sort(events, function(a, b)
        if a.startDelta == b.startDelta then return a.endDelta < b.endDelta end
        return a.startDelta < b.startDelta
    end)

    local currentOperational, nextOperational, currentEvent, nextEvent
    for _, event in ipairs(events) do
        if event.isCurrent then
            currentEvent = currentEvent or event
            if event.isOperational then currentOperational = currentOperational or event end
        elseif event.startDelta > 0 then
            nextEvent = nextEvent or event
            if event.isOperational then nextOperational = nextOperational or event end
        end
    end

    return currentOperational or nextOperational or currentEvent or nextEvent
end

---Formats a day time in the player's clock format.
-- @param integer dayTime
-- @return string
function RealisticCropRotationWeatherCard:formatTime(dayTime)
    local normalized = (tonumber(dayTime) or 0) % RealisticCropRotationWeatherCard.DAY_LENGTH_MS
    local totalMinutes = math.floor(normalized / 60000 + 0.5)
    if totalMinutes >= 1440 then totalMinutes = 0 end

    if Utils ~= nil and Utils.formatTime ~= nil then
        return Utils.formatTime(totalMinutes)
    end

    local hour = math.floor(totalMinutes / 60)
    local minute = totalMinutes - hour * 60
    return string.format("%02d:%02d", hour, minute)
end

---Formats a localized countdown without embedding it in a sentence.
-- @param integer deltaMs
-- @return string
function RealisticCropRotationWeatherCard:formatLeadTime(deltaMs)
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

---Builds the schedule line (time window plus localized day context when needed).
-- @param table event
-- @return string
function RealisticCropRotationWeatherCard:buildWindowText(event)
    local startText = self:formatTime(event.startDayTime)
    local endText = self:formatTime(event.endDayTime)

    if event.dayOffset <= 0 then
        return startText .. "-" .. endText
    elseif event.dayOffset == 1 then
        return cleanLeadingSeparator(string.format(
            self.i18n:getText("rcr_weather_tomorrow"), "", startText, endText))
    end

    return cleanLeadingSeparator(string.format(
        self.i18n:getText("rcr_weather_later"), "", event.dayOffset, startText, endText))
end

---Builds the secondary state line while reusing the existing localized weather templates.
-- @param table event
-- @return string
function RealisticCropRotationWeatherCard:buildStatusText(event)
    if event.isCurrent then
        local key = event.isOperational and "rcr_weather_current_operational" or "rcr_weather_current_calm"
        return cleanLeadingSeparator(string.format(
            self.i18n:getText(key), "", self:formatTime(event.endDayTime)))
    end

    if event.dayOffset <= 0 then
        local fullText = string.format(
            self.i18n:getText("rcr_weather_soon"),
            "",
            self:formatTime(event.startDayTime),
            self:formatTime(event.endDayTime),
            self:formatLeadTime(event.startDelta)
        )
        local separator = string.find(fullText, "·", 1, true)
        if separator ~= nil then
            return trim(string.sub(fullText, separator + 2))
        end
        return cleanLeadingSeparator(fullText)
    end

    return ""
end

---Builds the complete view model consumed by the card renderer.
-- @return table model, or nil
function RealisticCropRotationWeatherCard:buildViewModel()
    local event = self:selectForecastEvent()
    if event == nil or event.spec == nil then return nil end

    local condition = self.i18n:getText(event.spec.textKey)
    if condition == nil or condition == "" or event.spec.sliceId == nil then return nil end

    local window = self:buildWindowText(event)
    local status = self:buildStatusText(event)

    return {
        condition = condition,
        window = window,
        status = status,
        sliceId = event.spec.sliceId,
        color = event.spec.color,
        signature = table.concat({
            tostring(event.weatherType),
            tostring(event.startDay),
            tostring(event.startDayTime),
            tostring(event.endDay),
            tostring(event.endDayTime),
            tostring(event.isCurrent),
            condition,
            window,
            status,
        }, "|")
    }
end

---Returns the normalized screen width for a pixel value.
-- @param number pixels
-- @return number
function RealisticCropRotationWeatherCard:px(pixels)
    if self.owner ~= nil and self.owner.getNormalizedPixelWidth ~= nil then
        return self.owner:getNormalizedPixelWidth(pixels)
    end
    return (g_pixelSizeScaledX or g_pixelSizeX or 0) * (tonumber(pixels) or 0)
end

---Measures text through the frame's shared font-aware helper.
-- @param table element
-- @param string text
-- @return number width
function RealisticCropRotationWeatherCard:measure(element, text)
    if self.owner ~= nil and self.owner.getTextRenderWidth ~= nil then
        return self.owner:getTextRenderWidth(element, text) or 0
    end
    return 0
end

---Caches the exact right edge from the XML-authored card position.
function RealisticCropRotationWeatherCard:captureRightEdge()
    local root = self.controls.root
    if self.cardRightEdge == nil and root ~= nil and root.absPosition ~= nil and root.absSize ~= nil then
        self.cardRightEdge = root.absPosition[1] + root.absSize[1]
    end
end

---Returns the width available between the menu title and the card's fixed right edge.
-- @return number normalized width, or nil
function RealisticCropRotationWeatherCard:getAvailableWidth()
    local root = self.controls.root
    local title = self.controls.menuHeaderTitle
    if root == nil or title == nil or title.absPosition == nil then return nil end

    self:captureRightEdge()
    if self.cardRightEdge == nil then return nil end

    local titleWidth = self:measure(title, title.text or "")
    local titleRight = title.absPosition[1] + titleWidth
    return self.cardRightEdge - titleRight - self:px(RealisticCropRotationWeatherCard.TITLE_GAP_PX)
end

---Keeps the card vertically aligned to the existing menu logo without changing its authored right edge.
function RealisticCropRotationWeatherCard:alignToMenuLogo()
    local root = self.controls.root
    local logo = self.controls.menuHeaderIconBg
    if root == nil or logo == nil or root.setAbsolutePosition == nil then return end
    if root.absPosition == nil or logo.absPosition == nil then return end

    self:captureRightEdge()
    local x = root.absPosition[1]
    if self.cardRightEdge ~= nil and root.size ~= nil then
        x = self.cardRightEdge - root.size[1]
    end
    root:setAbsolutePosition(x, logo.absPosition[2])
end

---Resizes the card from the rendered text widths; the right edge stays fixed, longer text expands it left.
-- @param table model
function RealisticCropRotationWeatherCard:layout(model)
    local c = self.controls
    local root = c.root
    if root == nil or root.setSize == nil then return end

    local contentLeft = self:px(RealisticCropRotationWeatherCard.CONTENT_LEFT_PX)
    local conditionDividerGap = self:px(RealisticCropRotationWeatherCard.CONDITION_DIVIDER_GAP_PX)
    local dividerWidth = self:px(RealisticCropRotationWeatherCard.DIVIDER_WIDTH_PX)
    local dividerTimingGap = self:px(RealisticCropRotationWeatherCard.DIVIDER_TIMING_GAP_PX)
    local rightPadding = self:px(RealisticCropRotationWeatherCard.RIGHT_PADDING_PX)

    local conditionTextWidth = self:measure(c.condition, model.condition)
    local windowTextWidth = self:measure(c.window, model.window)
    local statusTextWidth = model.status ~= "" and self:measure(c.status, model.status) or 0
    local timingTextWidth = math.max(windowTextWidth, statusTextWidth)

    local targetWidth = contentLeft
        + conditionTextWidth
        + conditionDividerGap
        + dividerWidth
        + dividerTimingGap
        + timingTextWidth
        + rightPadding
    local availableWidth = self:getAvailableWidth()
    if availableWidth ~= nil and availableWidth > 0 then
        targetWidth = math.min(targetWidth, availableWidth)
    end

    -- If the title constrains the card, only the condition column shrinks; timing and padding stay intact.
    local fixedWidth = contentLeft
        + conditionDividerGap
        + dividerWidth
        + dividerTimingGap
        + timingTextWidth
        + rightPadding
    local fittedConditionWidth = math.max(0, targetWidth - fixedWidth)
    local rootHeight = root.size ~= nil and root.size[2] or 0
    root:setSize(targetWidth, rootHeight)

    if c.shadow ~= nil and c.shadow.setSize ~= nil and c.shadow.size ~= nil then
        -- The XML-authored +3px x offset is preserved, so the shadow extends 3px to the right.
        c.shadow:setSize(targetWidth, c.shadow.size[2])
    end
    for _, element in ipairs({c.background, c.accent}) do
        if element ~= nil and element.setSize ~= nil and element.size ~= nil then
            element:setSize(targetWidth, element.size[2])
        end
    end

    if c.condition ~= nil then
        if c.condition.setSize ~= nil and c.condition.size ~= nil then
            c.condition:setSize(fittedConditionWidth, c.condition.size[2])
        end
        if c.condition.setPosition ~= nil and self.owner ~= nil
            and self.owner.getElementOriginalPosition ~= nil then
            local original = self.owner:getElementOriginalPosition(c.condition)
            if original ~= nil then
                c.condition:setPosition(contentLeft, original[2])
            end
        end
    end

    local dividerX = contentLeft + fittedConditionWidth + conditionDividerGap
    if c.divider ~= nil and c.divider.setPosition ~= nil and self.owner ~= nil
        and self.owner.getElementOriginalPosition ~= nil then
        local original = self.owner:getElementOriginalPosition(c.divider)
        if original ~= nil then
            c.divider:setPosition(dividerX, original[2])
        end
    end

    for _, element in ipairs({c.window, c.status}) do
        if element ~= nil and element.setSize ~= nil and element.size ~= nil then
            element:setSize(timingTextWidth, element.size[2])
        end
    end

    if c.window ~= nil and c.window.setPosition ~= nil and self.owner ~= nil
        and self.owner.getElementOriginalPosition ~= nil then
        local original = self.owner:getElementOriginalPosition(c.window)
        if original ~= nil then
            -- Without a live/countdown state, the exact schedule becomes the sole centred message.
            c.window:setPosition(original[1], model.status == "" and 0 or original[2])
        end
    end

    if root.invalidateLayout ~= nil then root:invalidateLayout() end
    self:alignToMenuLogo()
end

---Applies one view model to the bound controls.
-- @param table model
function RealisticCropRotationWeatherCard:render(model)
    local c = self.controls
    if model == nil then
        setVisible(c.root, false)
        setText(c.condition, "")
        setText(c.window, "")
        setText(c.status, "")
        return
    end

    setText(c.condition, model.condition)
    setText(c.window, model.window)
    setText(c.status, model.status)
    setVisible(c.status, model.status ~= "")
    setVisible(c.icon, true)

    if c.icon ~= nil and c.icon.setImageSlice ~= nil then
        c.icon:setImageSlice(nil, model.sliceId)
    end

    setElementColor(c.accent, model.color)
    setElementColor(c.iconBackground, model.color)

    -- Apply measured geometry while hidden so the first visible frame is already final.
    self:layout(model)
    setVisible(c.root, true)
end

---Forces or conditionally refreshes the card from live mission data.
-- @param boolean force
function RealisticCropRotationWeatherCard:refresh(force)
    local model = self:buildViewModel()
    local signature = model ~= nil and model.signature or "hidden"
    if not force and signature == self.lastSignature then return end

    self.lastSignature = signature
    self:render(model)
end

---Throttled live refresh used while the menu page is open.
-- @param integer dt Frame delta in milliseconds
function RealisticCropRotationWeatherCard:update(dt)
    self.refreshTimerMs = self.refreshTimerMs + (tonumber(dt) or 0)
    if self.refreshTimerMs < RealisticCropRotationWeatherCard.REFRESH_INTERVAL_MS then return end

    self.refreshTimerMs = self.refreshTimerMs % RealisticCropRotationWeatherCard.REFRESH_INTERVAL_MS
    self:refresh(false)
end
