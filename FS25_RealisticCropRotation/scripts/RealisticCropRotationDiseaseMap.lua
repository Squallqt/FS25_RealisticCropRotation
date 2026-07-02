-- Copyright © 2026 Squallqt. All rights reserved.
-- Native in-game map disease overlay for Realistic Crop Rotation.
--
-- Two sub-pages share a single in-game map page. The rendering follows the reference
-- BMP (FS25_CropDiseases) overlay pattern: each view is coloured directly from an
-- existing BitVectorMap -- nothing but native setDensityMapVisualizationOverlayStateColor
-- calls and one async GPU generation (no healthy-field base layer, by design choice).
-- NO map is built or painted here: display maps are maintained off the UI path, at
-- gameplay events (load / period tick / ownership / MP sync). ZERO Lua pixel iteration.
--   1. "Active infections" — reads the persistent disease grid
--      (RealisticCropRotation.grid, clipped to worked soil at write time).
--   2. "Disease risk"      — reads the runtime risk-band map (grid.riskMapId,
--      painted on worked soil per owned field by RealisticCropRotationDisease).
--
-- Lifecycle: the table MUST survive source() reloads, so it is only created when
-- absent and constants are assigned individually. Every closure installed by
-- install() references the GLOBAL name RealisticCropRotationDiseaseMap, never a
-- captured self/alias, so reloads rebind cleanly.

RealisticCropRotationDiseaseMap = RealisticCropRotationDiseaseMap or {}

RealisticCropRotationDiseaseMap.PAGE_FIELD = "rcrDiseaseMapPageIndex"
RealisticCropRotationDiseaseMap.UPDATE_INTERVAL_MS = 1000

-- Grid states (must match Disease.lua: SCLEROTINIA=1, BCN=2).
RealisticCropRotationDiseaseMap.STATE_SCLEROTINIA = 1
RealisticCropRotationDiseaseMap.STATE_BCN = 2

-- Risk bands (cell values of the runtime risk map, written by Disease:refreshRiskMap).
RealisticCropRotationDiseaseMap.RISK_LOW = 1
RealisticCropRotationDiseaseMap.RISK_MODERATE = 2
RealisticCropRotationDiseaseMap.RISK_HIGH = 3

RealisticCropRotationDiseaseMap.SUB_PAGE_INFECTIONS = 1
RealisticCropRotationDiseaseMap.SUB_PAGE_PRESSURE = 2
RealisticCropRotationDiseaseMap.activeSubPage = RealisticCropRotationDiseaseMap.activeSubPage or 1

RealisticCropRotationDiseaseMap.RISK_COLOR_LOW      = {0.13, 0.68, 0.36, 1}
RealisticCropRotationDiseaseMap.RISK_COLOR_MODERATE = {0.94, 0.62, 0.08, 1}
RealisticCropRotationDiseaseMap.RISK_COLOR_HIGH     = {0.86, 0.17, 0.14, 1}


-- ============================================================================
-- Local helpers — ALL declared before any method that references them.
-- ============================================================================

---i18n lookup with a fallback when the key is missing.
local function getText(key, fallback)
    if g_i18n ~= nil and type(g_i18n.hasText) == "function" and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    if g_i18n ~= nil and type(g_i18n.getText) == "function" then
        local text = g_i18n:getText(key)
        if text ~= nil and text ~= key then return text end
    end
    return fallback or key
end

---Reads a colour table from MapOverlayGenerator[name][colorBlind].
local function colorFor(name, colorBlind)
    if MapOverlayGenerator ~= nil then
        local byMode = MapOverlayGenerator[name]
        if byMode ~= nil then
            local color = byMode[colorBlind == true] or byMode[false] or byMode[true]
            if color ~= nil then return color end
        end
    end
    return {1, 1, 1, 1}
end

---The disease model (client-safe reads only).
local function getDisease()
    return RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
end

---The persistent disease grid (BitVectorMap wrapper).
local function getGrid()
    return RealisticCropRotation ~= nil and RealisticCropRotation.grid or nil
end

---Infection-state colour for the grid overlay.
local function infectionStateColor(state, colorBlind)
    if state == RealisticCropRotationDiseaseMap.STATE_SCLEROTINIA then
        return colorFor("FRUIT_COLOR_NEEDS_LIME", colorBlind)
    elseif state == RealisticCropRotationDiseaseMap.STATE_BCN then
        return colorFor("FRUIT_COLOR_WITHERED", colorBlind)
    end
    return colorFor("FRUIT_COLOR_WITHERED", colorBlind)
end

---Filter list rows for the infection sub-page.
local function getInfectionDisplayItems(colorBlind)
    local sclerotiniaColor = infectionStateColor(RealisticCropRotationDiseaseMap.STATE_SCLEROTINIA, colorBlind)
    local bcnColor = infectionStateColor(RealisticCropRotationDiseaseMap.STATE_BCN, colorBlind)
    return {
        { colors = { [false] = {sclerotiniaColor}, [true] = {sclerotiniaColor} }, description = getText("rcr_disease_name_sclerotinia", "Sclerotinia"), isActive = true },
        { colors = { [false] = {bcnColor},         [true] = {bcnColor} },         description = getText("rcr_disease_name_bcn", "Nematode"),         isActive = true },
    }
end

---Filter list rows for the risk sub-page.
local function getRiskDisplayItems()
    local low = RealisticCropRotationDiseaseMap.RISK_COLOR_LOW
    local mod = RealisticCropRotationDiseaseMap.RISK_COLOR_MODERATE
    local high = RealisticCropRotationDiseaseMap.RISK_COLOR_HIGH
    return {
        { colors = { [false] = {low},  [true] = {low} },  description = getText("rcr_disease_risk_low", "Low risk"),           isActive = true },
        { colors = { [false] = {mod},  [true] = {mod} },  description = getText("rcr_disease_risk_moderate", "Moderate risk"), isActive = true },
        { colors = { [false] = {high}, [true] = {high} }, description = getText("rcr_disease_risk_high", "High risk"),         isActive = true },
    }
end

---Count selected filter entries.
local function countSelected(filter, n)
    local count = 0
    for i = 1, (n or 2) do
        if filter[i] then count = count + 1 end
    end
    return count
end

---Ensure the map-overview selector forwards clicks to the frame handler.
local function ensureSelectorCallback(frame)
    if frame == nil or frame.mapOverviewSelector == nil then return end
    if frame.rcrDiseaseMapSelectorCallbackSet then return end
    function frame.mapOverviewSelector.onClickCallback(_, state)
        frame:onClickMapOverviewSelector(state)
    end
    frame.rcrDiseaseMapSelectorCallbackSet = true
end


-- ============================================================================
-- Page / state queries
-- ============================================================================

function RealisticCropRotationDiseaseMap:getPageIndex(frame)
    return frame ~= nil and frame[self.PAGE_FIELD] or nil
end

function RealisticCropRotationDiseaseMap:isPageActive(frame)
    local pageIndex = self:getPageIndex(frame)
    return pageIndex ~= nil
        and frame.mapOverviewSelector ~= nil
        and frame.mapOverviewSelector:getState() == pageIndex
end

function RealisticCropRotationDiseaseMap:isPressurePage()
    return self.activeSubPage == self.SUB_PAGE_PRESSURE
end


-- ============================================================================
-- Filter data sync
-- ============================================================================

function RealisticCropRotationDiseaseMap:syncFilterData(frame)
    local pageIndex = self:getPageIndex(frame)
    if frame == nil or pageIndex == nil then return end
    if frame.dataTables == nil or frame.filterStates == nil or frame.numSelectedFilters == nil then return end

    self.activeSubPage = self.activeSubPage or self.SUB_PAGE_INFECTIONS

    if self:isPressurePage() then
        self.riskFilter = self.riskFilter or { true, true, true }
        frame.dataTables[pageIndex] = getRiskDisplayItems()
        frame.filterStates[pageIndex] = self.riskFilter
        frame.numSelectedFilters[pageIndex] = countSelected(self.riskFilter, 3)
    else
        self.filter = self.filter or { true, true }
        frame.dataTables[pageIndex] = getInfectionDisplayItems(self.isColorBlindMode == true)
        frame.filterStates[pageIndex] = self.filter
        frame.numSelectedFilters[pageIndex] = countSelected(self.filter, 2)
    end

    if frame.buttonDeselectAllText ~= nil and InGameMenuMapFrame ~= nil and InGameMenuMapFrame.L10N_SYMBOL ~= nil then
        local symbol = frame.numSelectedFilters[pageIndex] == 0
            and InGameMenuMapFrame.L10N_SYMBOL.SELECT_ALL
            or InGameMenuMapFrame.L10N_SYMBOL.DESELECT_ALL
        frame.buttonDeselectAllText:setText(g_i18n:getText(symbol))
    end
end


-- ============================================================================
-- Runtime objects
-- ============================================================================

---Creates the two value overlays once (one per sub-page). A custom BitVectorMap is
---sampled 1:1 by its overlay, so each overlay uses its source map's exact size
---(grid / risk map). Nothing else is allocated on the UI path.
function RealisticCropRotationDiseaseMap:createRuntimeObjects()
    if createDensityMapVisualizationOverlay == nil then return end
    local grid = getGrid()
    if grid == nil then return end

    if self.infectionOverlayId == nil and grid.mapId ~= nil and grid.size ~= nil then
        self.infectionOverlayId = createDensityMapVisualizationOverlay("rcrInfectionOverlay", grid.size, grid.size)
        self.infectionOverlayReady = false
    end

    if self.riskOverlayId == nil and grid.riskMapId ~= nil and grid.riskMapSize ~= nil then
        self.riskOverlayId = createDensityMapVisualizationOverlay("rcrRiskOverlay", grid.riskMapSize, grid.riskMapSize)
        self.riskOverlayReady = false
    end
end

function RealisticCropRotationDiseaseMap:delete()
    if self.infectionOverlayId ~= nil then
        delete(self.infectionOverlayId)
        self.infectionOverlayId = nil
    end
    if self.riskOverlayId ~= nil then
        delete(self.riskOverlayId)
        self.riskOverlayId = nil
    end
    self.infectionOverlayReady = false
    self.riskOverlayReady = false
    self.lastBuildKey = nil
end


-- ============================================================================
-- Build key — decides when the overlay must be regenerated.
-- ============================================================================

function RealisticCropRotationDiseaseMap:buildKey()
    local parts = {}
    local subPage = self.activeSubPage or self.SUB_PAGE_INFECTIONS
    parts[#parts + 1] = string.format("P%d", subPage)
    parts[#parts + 1] = self.isColorBlindMode == true and "CB1" or "CB0"

    -- Only the display controls we own: the CONTENT of both views lives in the display maps,
    -- whose revisions (grid.changeRevision / grid.riskRevision) are tracked in updateOverlay.
    if subPage == self.SUB_PAGE_PRESSURE then
        local rf = self.riskFilter or {}
        parts[#parts + 1] = string.format("%s%s%s",
            rf[1] and "1" or "0", rf[2] and "1" or "0", rf[3] and "1" or "0")
    else
        local f = self.filter or {}
        parts[#parts + 1] = string.format("%s%s", f[1] and "1" or "0", f[2] and "1" or "0")
    end

    return table.concat(parts, "|")
end


-- ============================================================================
-- Infection view — render straight from the persistent grid (no iteration).
-- ============================================================================

function RealisticCropRotationDiseaseMap:renderInfectionOverlay()
    local grid = getGrid()
    if grid == nil or grid.mapId == nil or self.infectionOverlayId == nil or self.infectionOverlayId == 0 then
        return false
    end

    local filter = self.filter or { true, true }
    local colorBlind = self.isColorBlindMode == true

    resetDensityMapVisualizationOverlay(self.infectionOverlayId)
    setOverlayColor(self.infectionOverlayId, 1, 1, 1, 1)

    -- Grid states drawn directly, no mask (the grid is clipped to worked soil at write time).
    if filter[1] then
        local c = infectionStateColor(self.STATE_SCLEROTINIA, colorBlind)
        setDensityMapVisualizationOverlayStateColor(
            self.infectionOverlayId, grid.mapId, 0, 0, 0, grid.numChannels, self.STATE_SCLEROTINIA, c[1], c[2], c[3])
    end
    if filter[2] then
        local c = infectionStateColor(self.STATE_BCN, colorBlind)
        setDensityMapVisualizationOverlayStateColor(
            self.infectionOverlayId, grid.mapId, 0, 0, 0, grid.numChannels, self.STATE_BCN, c[1], c[2], c[3])
    end

    generateDensityMapVisualizationOverlay(self.infectionOverlayId)
    self.infectionOverlayReady = false
    return true
end


-- ============================================================================
-- Risk view — render straight from the runtime risk-band map (no iteration).
-- ============================================================================

---Colours the pressure view straight from the runtime risk-band map: one native call per band
---(1..3). The map's cells already hold each owned field's band on its worked-soil cells only
---(painted off the UI path by Disease:refreshRiskMap), so there is no per-field loop, no mask and
---no map work here -- exactly the reference mod's value-overlay pattern.
function RealisticCropRotationDiseaseMap:renderRiskOverlay()
    local grid = getGrid()
    if grid == nil or grid.riskMapId == nil or self.riskOverlayId == nil or self.riskOverlayId == 0 then
        return false
    end

    local riskFilter = self.riskFilter or { true, true, true }

    resetDensityMapVisualizationOverlay(self.riskOverlayId)
    setOverlayColor(self.riskOverlayId, 1, 1, 1, 1)

    local colors = { self.RISK_COLOR_LOW, self.RISK_COLOR_MODERATE, self.RISK_COLOR_HIGH }
    for band = 1, 3 do
        if riskFilter[band] then
            local c = colors[band]
            setDensityMapVisualizationOverlayStateColor(
                self.riskOverlayId, grid.riskMapId, 0, 0, 0, grid.riskNumChannels, band, c[1], c[2], c[3])
        end
    end

    generateDensityMapVisualizationOverlay(self.riskOverlayId)
    self.riskOverlayReady = false
    return true
end


-- ============================================================================
-- Overlay update / draw
-- ============================================================================

function RealisticCropRotationDiseaseMap:updateOverlay(force)
    local disease = getDisease()
    local grid = getGrid()
    if disease == nil or grid == nil then return end

    self:createRuntimeObjects()

    -- Safety belt: a band can move between gameplay repaints (e.g. a harvest just changed the
    -- history). Incremental only -- a pure Lua band comparison per owned field (the pre-refactor
    -- code ran the same getRisk loop every tick), with native passes only for bands that moved.
    if self:isPressurePage() and type(disease.refreshRiskMap) == "function" then
        disease:refreshRiskMap(false)
    end

    local buildKey = self:buildKey()
    local revision
    if self:isPressurePage() then
        revision = grid.riskRevision or 0
    else
        revision = grid.changeRevision or 0
    end
    if not force and self.lastBuildKey == buildKey and revision == (self.lastRevision or -1) then return end

    local ok
    if self:isPressurePage() then
        ok = self:renderRiskOverlay()
    else
        ok = self:renderInfectionOverlay()
    end

    if ok then
        self.lastBuildKey = buildKey
        self.lastRevision = revision
    end
end

---Draws the active view's overlay on the map rect. The overlay waits for its async
---generation once, then keeps rendering (the reference mod's ready-gated draw).
function RealisticCropRotationDiseaseMap:draw(x, y, width, height)
    local overlayId, ready
    if self:isPressurePage() then
        if self.riskOverlayId ~= nil and not self.riskOverlayReady
            and getIsDensityMapVisualizationOverlayReady(self.riskOverlayId) then
            self.riskOverlayReady = true
        end
        overlayId, ready = self.riskOverlayId, self.riskOverlayReady
    else
        if self.infectionOverlayId ~= nil and not self.infectionOverlayReady
            and getIsDensityMapVisualizationOverlayReady(self.infectionOverlayId) then
            self.infectionOverlayReady = true
        end
        overlayId, ready = self.infectionOverlayId, self.infectionOverlayReady
    end

    if ready and overlayId ~= nil and overlayId ~= 0 then
        setOverlayUVs(overlayId, 0, 0, 0, 1, 1, 0, 1, 1)
        renderOverlay(overlayId, x, y, width, height)
    end
end


-- ============================================================================
-- Sub-selector layout
-- ============================================================================

function RealisticCropRotationDiseaseMap:getLayoutOffsets()
    local _, selectorOffset = getNormalizedScreenValues(0, 80)
    local _, dotOffset = getNormalizedScreenValues(0, 75)
    local _, filterOffset = getNormalizedScreenValues(0, 60)
    return selectorOffset, dotOffset, filterOffset
end

function RealisticCropRotationDiseaseMap:applySubPageLayout(frame)
    if frame == nil or self.subSelector == nil or self.subDotBox == nil then return end

    local selectorOffset, dotOffset, filterOffset = self:getLayoutOffsets()

    if self.subSelectorBaseY ~= nil then
        self.subSelector:setPosition(nil, self.subSelectorBaseY - selectorOffset)
    end
    if self.subDotBoxBaseY ~= nil then
        self.subDotBox:setPosition(nil, self.subDotBoxBaseY - dotOffset)
    end

    frame.filterListContainer:setPosition(nil, self.filterListContainerBaseY - filterOffset)
    frame.filterListContainer:setSize(nil, self.filterListContainerBaseH - filterOffset, true)
    frame.filterList:setSize(nil, self.filterListBaseH - filterOffset, true)
    frame.filterListSlider:setSize(nil, self.filterListSliderBaseH - filterOffset, true)
    frame.filterListSlider.elements[1]:setSize(nil, self.filterListSliderElementBaseH - filterOffset, true)
    frame.buttonDeselectAllContainer:setPosition(nil, self.buttonDeselectAllAdjustedY)
end

function RealisticCropRotationDiseaseMap:restoreDefaultLayout(frame)
    if frame == nil or self.filterListContainerBaseY == nil then return end

    frame.filterListContainer:setPosition(nil, self.filterListContainerBaseY)
    frame.filterListContainer:setSize(nil, self.filterListContainerBaseH, true)
    frame.filterList:setSize(nil, self.filterListBaseH, true)
    frame.filterListSlider:setSize(nil, self.filterListSliderBaseH, true)
    frame.filterListSlider.elements[1]:setSize(nil, self.filterListSliderElementBaseH, true)
    frame.buttonDeselectAllContainer:setPosition(nil, self.buttonDeselectAllDefaultY)
end

function RealisticCropRotationDiseaseMap:onSubSelectorChanged(frame, state)
    self.activeSubPage = state
    self.lastBuildKey = nil
    self:syncFilterData(frame)
    if frame.filterList ~= nil then frame.filterList:reloadData() end
    self:updateOverlay(true)
end

function RealisticCropRotationDiseaseMap:showSubSelector(frame, visible)
    if self.subSelector ~= nil then self.subSelector:setVisible(visible) end
    if self.subDotBox ~= nil then self.subDotBox:setVisible(visible) end
    if visible then
        self:applySubPageLayout(frame)
    else
        self:restoreDefaultLayout(frame)
    end
end


-- ============================================================================
-- Page creation
-- ============================================================================

function RealisticCropRotationDiseaseMap:ensureMapPage(frame)
    if frame == nil or frame[self.PAGE_FIELD] ~= nil then return end
    if frame.mapSelectorTexts == nil or frame.mapOverviewSelector == nil then return end
    if frame.dataTables == nil or frame.filterStates == nil or frame.numSelectedFilters == nil then return end

    table.insert(frame.mapSelectorTexts, getText("rcr_section_disease_map", "Diseases"))
    local pageIndex = #frame.mapSelectorTexts
    frame[self.PAGE_FIELD] = pageIndex
    frame.mapOverviewSelector:setTexts(frame.mapSelectorTexts)

    self.filter = self.filter or { true, true }
    self.riskFilter = self.riskFilter or { true, true, true }

    frame.dataTables[pageIndex] = {}
    frame.filterStates[pageIndex] = self.filter
    frame.numSelectedFilters[pageIndex] = countSelected(self.filter, 2)

    -- Add a dot to the main category dot box for our new top-level page.
    if frame.subCategoryDotBox ~= nil and frame.subCategoryDotBox.elements ~= nil and #frame.subCategoryDotBox.elements > 0 then
        frame.subCategoryDotBox.elements[1]:clone(frame.subCategoryDotBox)
        for index, dot in ipairs(frame.subCategoryDotBox.elements) do
            local currentIndex = index
            function dot.getIsSelected()
                return frame.mapOverviewSelector:getState() == currentIndex
            end
        end
        if type(frame.subCategoryDotBox.invalidateLayout) == "function" then
            frame.subCategoryDotBox:invalidateLayout()
        end
    end

    self.activeSubPage = self.SUB_PAGE_INFECTIONS

    -- Capture the default filter-list layout so we can restore it later.
    self.filterListContainerBaseY = frame.filterListContainer.position[2]
    self.filterListContainerBaseH = frame.filterListContainer.size[2]
    self.filterListBaseH = frame.filterList.size[2]
    self.filterListSliderBaseH = frame.filterListSlider.size[2]
    self.filterListSliderElementBaseH = frame.filterListSlider.elements[1].size[2]
    self.buttonDeselectAllDefaultY = frame.buttonDeselectAllContainer.position[2]
    local _, btnOffset = getNormalizedScreenValues(0, 16)
    self.buttonDeselectAllAdjustedY = frame.buttonDeselectAllContainer.position[2] + btnOffset

    -- Clone the map-overview selector to build the two-way sub-selector.
    if frame.filterBox ~= nil and frame.mapOverviewSelector ~= nil then
        self.subSelector = frame.mapOverviewSelector:clone(frame.filterBox)
        self.subSelector:setTexts({
            getText("rcr_disease_sub_infections", "Active infections"),
            getText("rcr_disease_sub_pressure", "Disease risk"),
        })
        self.subSelectorBaseY = self.subSelector.position[2]
        function self.subSelector.onClickCallback(_, subState)
            RealisticCropRotationDiseaseMap:onSubSelectorChanged(frame, subState)
        end
        if type(self.subSelector.addDefaultElements) == "function" then
            self.subSelector:addDefaultElements()
        end
        self.subSelector:setVisible(false)

        -- Clone the dot box for the sub-page indicator.
        if frame.subCategoryDotBox ~= nil then
            self.subDotBox = frame.subCategoryDotBox:clone(frame.filterBox)
            self.subDotBoxBaseY = self.subDotBox.position[2]
            local numSubPages = 2
            while #self.subDotBox.elements > numSubPages do
                self.subDotBox.elements[#self.subDotBox.elements]:delete()
            end
            while #self.subDotBox.elements < numSubPages do
                self.subDotBox.elements[1]:clone(self.subDotBox)
            end
            for index, dot in ipairs(self.subDotBox.elements) do
                local ci = index
                function dot.getIsSelected()
                    return RealisticCropRotationDiseaseMap.subSelector ~= nil
                        and RealisticCropRotationDiseaseMap.subSelector:getState() == ci
                end
            end
            if type(self.subDotBox.invalidateLayout) == "function" then
                self.subDotBox:invalidateLayout()
            end
            self.subDotBox:setVisible(false)
        end
    end

    self:syncFilterData(frame)
    ensureSelectorCallback(frame)
end


-- ============================================================================
-- Install — wires the InGameMenuMapFrame overwrites.
-- ============================================================================

function RealisticCropRotationDiseaseMap:install()
    if RealisticCropRotationDiseaseMap._overwrites_installed or InGameMenuMapFrame == nil or Utils == nil then return end

    RealisticCropRotationDiseaseMap.filter = RealisticCropRotationDiseaseMap.filter or { true, true }
    RealisticCropRotationDiseaseMap.riskFilter = RealisticCropRotationDiseaseMap.riskFilter or { true, true, true }
    RealisticCropRotationDiseaseMap.isColorBlindMode = false
    if g_gameSettings ~= nil and GameSettings ~= nil and GameSettings.SETTING ~= nil then
        RealisticCropRotationDiseaseMap.isColorBlindMode =
            g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE) == true
    end

    InGameMenuMapFrame.onLoadMapFinished = Utils.overwrittenFunction(InGameMenuMapFrame.onLoadMapFinished, function(frame, superFunc, ...)
        superFunc(frame, ...)
        ensureSelectorCallback(frame)
        if frame.ingameMap ~= nil then
            frame.ingameMap.onDrawPostIngameMapCallback = InGameMenuMapFrame.onDrawPostIngameMap
            frame.ingameMap.onDrawPostIngameMapHotspotsCallback = InGameMenuMapFrame.onDrawPostIngameMapHotspots
            frame.ingameMap.onClickMapCallback = InGameMenuMapFrame.onClickMap
        end
    end)

    InGameMenuMapFrame.setupMapOverview = Utils.overwrittenFunction(InGameMenuMapFrame.setupMapOverview, function(frame, superFunc, ...)
        superFunc(frame, ...)
        RealisticCropRotationDiseaseMap:ensureMapPage(frame)
        if RealisticCropRotationDiseaseMap:isPageActive(frame) and frame.filterList ~= nil then
            frame.filterList:reloadData()
        end
    end)

    InGameMenuMapFrame.onClickMapOverviewSelector = Utils.overwrittenFunction(InGameMenuMapFrame.onClickMapOverviewSelector, function(frame, superFunc, state, ...)
        superFunc(frame, state, ...)
        if state == RealisticCropRotationDiseaseMap:getPageIndex(frame) then
            RealisticCropRotationDiseaseMap:showSubSelector(frame, true)
            RealisticCropRotationDiseaseMap:syncFilterData(frame)
            if frame.filterListContainer ~= nil then frame.filterListContainer:setVisible(true) end
            if frame.buttonDeselectAllContainer ~= nil then frame.buttonDeselectAllContainer:setVisible(true) end
            if frame.filterList ~= nil then frame.filterList:reloadData() end
            local subState = RealisticCropRotationDiseaseMap.subSelector ~= nil
                and RealisticCropRotationDiseaseMap.subSelector:getState()
                or RealisticCropRotationDiseaseMap.SUB_PAGE_INFECTIONS
            RealisticCropRotationDiseaseMap:onSubSelectorChanged(frame, subState)
        else
            RealisticCropRotationDiseaseMap:showSubSelector(frame, false)
        end
    end)

    InGameMenuMapFrame.getHasChangeableFilterList = Utils.overwrittenFunction(InGameMenuMapFrame.getHasChangeableFilterList, function(frame, superFunc, ...)
        return superFunc(frame, ...) or RealisticCropRotationDiseaseMap:isPageActive(frame)
    end)

    InGameMenuMapFrame.generateOverviewOverlay = Utils.overwrittenFunction(InGameMenuMapFrame.generateOverviewOverlay, function(frame, superFunc, ...)
        superFunc(frame, ...)
        if RealisticCropRotationDiseaseMap:isPageActive(frame) then
            RealisticCropRotationDiseaseMap:syncFilterData(frame)
            RealisticCropRotationDiseaseMap:updateOverlay(true)
        end
    end)

    InGameMenuMapFrame.onDrawPostIngameMap = Utils.overwrittenFunction(InGameMenuMapFrame.onDrawPostIngameMap, function(frame, superFunc, element, ingameMap, ...)
        if RealisticCropRotationDiseaseMap:isPageActive(frame) then
            local previousHideOverlay = frame.hideContentOverlay
            frame.hideContentOverlay = true
            superFunc(frame, element, ingameMap, ...)
            frame.hideContentOverlay = previousHideOverlay

            local layout = frame.ingameMapBase ~= nil and frame.ingameMapBase.fullScreenLayout or nil
            if layout ~= nil and type(layout.getMapSize) == "function" and type(layout.getMapPosition) == "function" then
                local width, height = layout:getMapSize()
                local x, y = layout:getMapPosition()
                RealisticCropRotationDiseaseMap:draw(x + width * 0.25, y + height * 0.25, width * 0.5, height * 0.5)
            end
            if frame.dynamicMapImageLoadingBg ~= nil then frame.dynamicMapImageLoadingBg:setVisible(false) end
            return
        end
        superFunc(frame, element, ingameMap, ...)
    end)

    InGameMenuMapFrame.update = Utils.overwrittenFunction(InGameMenuMapFrame.update, function(frame, superFunc, dt, ...)
        superFunc(frame, dt, ...)

        if not RealisticCropRotationDiseaseMap:isPageActive(frame) then
            RealisticCropRotationDiseaseMap.updateTimerMs = 0
            return
        end

        RealisticCropRotationDiseaseMap:applySubPageLayout(frame)
        RealisticCropRotationDiseaseMap:syncFilterData(frame)
        RealisticCropRotationDiseaseMap.updateTimerMs =
            (RealisticCropRotationDiseaseMap.updateTimerMs or 0) + (dt or 0)
        if RealisticCropRotationDiseaseMap.updateTimerMs >= RealisticCropRotationDiseaseMap.UPDATE_INTERVAL_MS then
            RealisticCropRotationDiseaseMap.updateTimerMs = 0
            RealisticCropRotationDiseaseMap:updateOverlay(false)
        end
    end)

    InGameMenuMapFrame.setColorBlindMode = Utils.overwrittenFunction(InGameMenuMapFrame.setColorBlindMode, function(frame, superFunc, isColorBlindMode, ...)
        superFunc(frame, isColorBlindMode, ...)
        RealisticCropRotationDiseaseMap.isColorBlindMode = isColorBlindMode == true
        if RealisticCropRotationDiseaseMap:isPageActive(frame) then
            RealisticCropRotationDiseaseMap:syncFilterData(frame)
            RealisticCropRotationDiseaseMap:updateOverlay(true)
        end
    end)

    RealisticCropRotationDiseaseMap._overwrites_installed = true
end
