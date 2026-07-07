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

-- Per-disease overlay colours, keyed by the STABLE state id (cropConfig <diseaseGroup state=>, also
-- read by Disease.lua diseaseStateForGroup). Each disease is painted with its OWN colour, so the
-- infection view distinguishes all 9 pathogens on the parcel (no more fungal/soil merge). Two
-- variants per entry: [false] = default palette, [true] = colour-blind-safe (Okabe-Ito based),
-- mirroring the base game's colour-blind handling. Hues are well separated for readability.
--   1 SCLEROTINIA (white mould)  2 PHOMA (brown)     3 PIETIN (violet)   4 SEPTORIOSE (blue)
--   5 ROUILLE (orange)           6 FUSARIOSE (yellow) 7 MILDIOU (magenta) 8 BCN (teal)  9 HERNIE (red)
RealisticCropRotationDiseaseMap.STATE_COLORS = {
    [1] = { [false] = {0.93, 0.93, 0.90, 1}, [true] = {0.95, 0.95, 0.95, 1} },
    [2] = { [false] = {0.60, 0.40, 0.18, 1}, [true] = {0.80, 0.40, 0.00, 1} },
    [3] = { [false] = {0.58, 0.32, 0.80, 1}, [true] = {0.80, 0.60, 0.70, 1} },
    [4] = { [false] = {0.15, 0.50, 0.90, 1}, [true] = {0.00, 0.45, 0.70, 1} },
    [5] = { [false] = {0.95, 0.55, 0.05, 1}, [true] = {0.90, 0.60, 0.00, 1} },
    [6] = { [false] = {0.95, 0.85, 0.22, 1}, [true] = {0.95, 0.90, 0.25, 1} },
    [7] = { [false] = {0.87, 0.15, 0.72, 1}, [true] = {0.35, 0.70, 0.90, 1} },
    [8] = { [false] = {0.10, 0.68, 0.62, 1}, [true] = {0.00, 0.60, 0.50, 1} },
    [9] = { [false] = {0.78, 0.13, 0.13, 1}, [true] = {0.60, 0.10, 0.10, 1} },
}
-- Last-resort colour for a state id beyond the palette (a 10th+ disease added without a colour).
RealisticCropRotationDiseaseMap.STATE_COLOR_FALLBACK = { [false] = {0.86, 0.17, 0.14, 1}, [true] = {0.80, 0.40, 0.00, 1} }

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

---Pathogen groups ordered by their stable overlay state id, straight from the crop config
---(data-driven: adding a <diseaseGroup> makes it appear here automatically). Client-safe:
---diseaseStates is static config, loaded on every machine at mod init.
-- @return table list array of { group = <NAME>, state = <id> } sorted by state id then name
local function orderedDiseaseGroups()
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local states = config ~= nil and config.diseaseStates or nil
    local out = {}
    if states == nil then return out end
    for group, state in pairs(states) do
        out[#out + 1] = { group = group, state = tonumber(state) or 0 }
    end
    table.sort(out, function(a, b)
        if a.state == b.state then return tostring(a.group) < tostring(b.group) end
        return a.state < b.state
    end)
    return out
end

---Number of pathogen groups the infection view lists (one filter row + one colour each).
local function diseaseCount()
    return #orderedDiseaseGroups()
end

---The disease model (client-safe reads only).
local function getDisease()
    return RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
end

---The persistent disease grid (BitVectorMap wrapper).
local function getGrid()
    return RealisticCropRotation ~= nil and RealisticCropRotation.grid or nil
end

---Overlay colour for a disease's grid state id, honouring colour-blind mode. Falls back to a
---generic colour for any state id beyond the defined palette.
local function infectionStateColor(state, colorBlind)
    local entry = RealisticCropRotationDiseaseMap.STATE_COLORS[state]
        or RealisticCropRotationDiseaseMap.STATE_COLOR_FALLBACK
    return entry[colorBlind == true] or entry[false] or {1, 1, 1, 1}
end

---Filter list rows for the infection sub-page: ONE row per disease, built dynamically from the
---config (name via l10n through the disease model, colour by the disease's stable state id). The
---row order matches self.filter and renderInfectionOverlay (both walk orderedDiseaseGroups).
local function getInfectionDisplayItems(colorBlind)
    local disease = getDisease()
    local items = {}
    for _, entry in ipairs(orderedDiseaseGroups()) do
        local color = infectionStateColor(entry.state, colorBlind)
        local name = (disease ~= nil and type(disease.getDisplayName) == "function")
            and disease:getDisplayName(entry.group) or tostring(entry.group)
        items[#items + 1] = {
            colors = { [false] = {color}, [true] = {color} },
            description = name,
            isActive = true,
        }
    end
    return items
end

---Filter list rows for the risk sub-page.
local function getRiskDisplayItems()
    local low = RealisticCropRotationDiseaseMap.RISK_COLOR_LOW
    local mod = RealisticCropRotationDiseaseMap.RISK_COLOR_MODERATE
    local high = RealisticCropRotationDiseaseMap.RISK_COLOR_HIGH
    return {
        { colors = { [false] = {low},  [true] = {low} },  description = getText("rcr_disease_risk_low"),      isActive = true },
        { colors = { [false] = {mod},  [true] = {mod} },  description = getText("rcr_disease_risk_moderate"), isActive = true },
        { colors = { [false] = {high}, [true] = {high} }, description = getText("rcr_disease_risk_high"),     isActive = true },
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

---Ensures self.filter is a boolean array of exactly n entries: new diseases default to shown,
---removed ones are trimmed. Keeps the filter list rows, self.filter and the overlay index-aligned
---(all three walk orderedDiseaseGroups in the same order).
-- @param integer n current disease count
-- @return table filter
function RealisticCropRotationDiseaseMap:ensureInfectionFilter(n)
    local filter = self.filter or {}
    for i = 1, n do
        if filter[i] == nil then filter[i] = true end
    end
    for i = #filter, n + 1, -1 do
        filter[i] = nil
    end
    self.filter = filter
    return filter
end

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
        local items = getInfectionDisplayItems(self.isColorBlindMode == true)
        local n = #items
        local filter = self:ensureInfectionFilter(n)
        frame.dataTables[pageIndex] = items
        frame.filterStates[pageIndex] = filter
        frame.numSelectedFilters[pageIndex] = countSelected(filter, n)
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

---Creates TWO value overlays per sub-page (double-buffered) instead of one. A custom BitVectorMap is
---sampled 1:1 by its overlay, so each overlay uses its source map's exact size (grid / risk map).
---Nothing else is allocated on the UI path.
---
---WHY double-buffered: generateDensityMapVisualizationOverlay() is async (GPU-side); a SINGLE overlay
---object has no valid texture between "regenerate requested" and "ready", so drawing must skip it
---meanwhile -- a real blank gap on every content refresh, not just a frequency issue. Regenerating into
---the OTHER (currently hidden) slot while the ACTIVE one keeps being drawn removes that gap entirely:
---the map only ever shows a slot that has ALREADY finished generating at least once. Same native calls
---as before (createDensityMapVisualizationOverlay / generateDensityMapVisualizationOverlay /
---getIsDensityMapVisualizationOverlayReady), just used twice per view -- no new native surface.
function RealisticCropRotationDiseaseMap:createRuntimeObjects()
    if createDensityMapVisualizationOverlay == nil then return end
    local grid = getGrid()
    if grid == nil then return end

    if self.infectionOverlayIds == nil and grid.mapId ~= nil and grid.size ~= nil then
        self.infectionOverlayIds = {
            createDensityMapVisualizationOverlay("rcrInfectionOverlayA", grid.size, grid.size),
            createDensityMapVisualizationOverlay("rcrInfectionOverlayB", grid.size, grid.size),
        }
        self.infectionActiveSlot = nil  -- nothing generated yet: draw() shows nothing until slot 1 is ready
        self.infectionPendingSlot = nil
    end

    if self.riskOverlayIds == nil and grid.riskMapId ~= nil and grid.riskMapSize ~= nil then
        self.riskOverlayIds = {
            createDensityMapVisualizationOverlay("rcrRiskOverlayA", grid.riskMapSize, grid.riskMapSize),
            createDensityMapVisualizationOverlay("rcrRiskOverlayB", grid.riskMapSize, grid.riskMapSize),
        }
        self.riskActiveSlot = nil
        self.riskPendingSlot = nil
    end
end

function RealisticCropRotationDiseaseMap:delete()
    if self.infectionOverlayIds ~= nil then
        for _, id in ipairs(self.infectionOverlayIds) do delete(id) end
        self.infectionOverlayIds = nil
    end
    if self.riskOverlayIds ~= nil then
        for _, id in ipairs(self.riskOverlayIds) do delete(id) end
        self.riskOverlayIds = nil
    end
    self.infectionActiveSlot, self.infectionPendingSlot = nil, nil
    self.riskActiveSlot, self.riskPendingSlot = nil, nil
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
        local n = diseaseCount()
        local bits = {}
        for i = 1, n do bits[i] = f[i] and "1" or "0" end
        parts[#parts + 1] = table.concat(bits)
    end

    return table.concat(parts, "|")
end


-- ============================================================================
-- Infection view — render straight from the persistent grid (no iteration).
-- ============================================================================

function RealisticCropRotationDiseaseMap:renderInfectionOverlay()
    local grid = getGrid()
    if grid == nil or grid.mapId == nil or self.infectionOverlayIds == nil then
        return false
    end

    -- Regenerate into the slot NOT currently displayed (double-buffered), so the map keeps showing the
    -- last-good result until the fresh one is ready -- see createRuntimeObjects for why.
    local slot = (self.infectionActiveSlot == 1) and 2 or 1
    local overlayId = self.infectionOverlayIds[slot]
    if overlayId == nil or overlayId == 0 then return false end

    local filter = self.filter or {}
    local colorBlind = self.isColorBlindMode == true

    resetDensityMapVisualizationOverlay(overlayId)
    setOverlayColor(overlayId, 1, 1, 1, 1)

    -- One native paint per enabled disease, straight from the destruction grid (grid.mapId), so the
    -- foci view shows the REAL organic disease patches (Perlin destruction, clipped to worked soil at
    -- write time) rather than a solid fill -- localised irregular outbreaks, not a full block. Each
    -- disease uses its own stable state id and colour. Row order == orderedDiseaseGroups (same as the
    -- filter list), so filter[i] gates disease i. Uninitialised entries (nil) default to shown.
    for i, entry in ipairs(orderedDiseaseGroups()) do
        if filter[i] ~= false then
            local c = infectionStateColor(entry.state, colorBlind)
            setDensityMapVisualizationOverlayStateColor(
                overlayId, grid.mapId, 0, 0, 0, grid.numChannels, entry.state, c[1], c[2], c[3])
        end
    end

    generateDensityMapVisualizationOverlay(overlayId)
    self.infectionPendingSlot = slot
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
    if grid == nil or grid.riskMapId == nil or self.riskOverlayIds == nil then
        return false
    end

    -- Regenerate into the slot NOT currently displayed (double-buffered) -- see renderInfectionOverlay.
    local slot = (self.riskActiveSlot == 1) and 2 or 1
    local overlayId = self.riskOverlayIds[slot]
    if overlayId == nil or overlayId == 0 then return false end

    local riskFilter = self.riskFilter or { true, true, true }

    resetDensityMapVisualizationOverlay(overlayId)
    setOverlayColor(overlayId, 1, 1, 1, 1)

    local colors = { self.RISK_COLOR_LOW, self.RISK_COLOR_MODERATE, self.RISK_COLOR_HIGH }
    for band = 1, 3 do
        if riskFilter[band] then
            local c = colors[band]
            setDensityMapVisualizationOverlayStateColor(
                overlayId, grid.riskMapId, 0, 0, 0, grid.riskNumChannels, band, c[1], c[2], c[3])
        end
    end

    generateDensityMapVisualizationOverlay(overlayId)
    self.riskPendingSlot = slot
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

    -- Safety belt (pressure view only): a risk band can move between gameplay repaints (e.g. a harvest
    -- just changed the history). Incremental -- a pure Lua comparison per owned field, native passes
    -- only for what moved. The foci view reads the destruction grid directly, mutated by the daily
    -- destruction pass, so it is tracked by grid.changeRevision instead.
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

---Draws the active view's overlay on the map rect (double-buffered -- see createRuntimeObjects). If the
---slot currently regenerating in the background has finished, it becomes the new active slot (swap);
---the map always draws whichever slot last finished successfully, so it is NEVER blank after the first
---generation -- a refresh only ever swaps between two already-valid textures, no visible gap.
function RealisticCropRotationDiseaseMap:draw(x, y, width, height)
    local overlayIds, pendingSlotField, activeSlotField
    if self:isPressurePage() then
        overlayIds, pendingSlotField, activeSlotField = self.riskOverlayIds, "riskPendingSlot", "riskActiveSlot"
    else
        overlayIds, pendingSlotField, activeSlotField = self.infectionOverlayIds, "infectionPendingSlot", "infectionActiveSlot"
    end
    if overlayIds == nil then return end

    local pendingSlot = self[pendingSlotField]
    if pendingSlot ~= nil and getIsDensityMapVisualizationOverlayReady(overlayIds[pendingSlot]) then
        self[activeSlotField] = pendingSlot
        self[pendingSlotField] = nil
    end

    local activeSlot = self[activeSlotField]
    if activeSlot == nil then return end -- nothing has finished generating yet

    local overlayId = overlayIds[activeSlot]
    if overlayId ~= nil and overlayId ~= 0 then
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

    table.insert(frame.mapSelectorTexts, getText("rcr_section_disease_map"))
    local pageIndex = #frame.mapSelectorTexts
    frame[self.PAGE_FIELD] = pageIndex
    frame.mapOverviewSelector:setTexts(frame.mapSelectorTexts)

    local diseaseN = diseaseCount()
    self.filter = self:ensureInfectionFilter(diseaseN)
    self.riskFilter = self.riskFilter or { true, true, true }

    frame.dataTables[pageIndex] = {}
    frame.filterStates[pageIndex] = self.filter
    frame.numSelectedFilters[pageIndex] = countSelected(self.filter, diseaseN)

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
            getText("rcr_disease_sub_infections"),
            getText("rcr_disease_sub_pressure"),
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

    -- Sized to the disease count lazily (ensureInfectionFilter) once the config/page exist.
    RealisticCropRotationDiseaseMap.filter = RealisticCropRotationDiseaseMap.filter or {}
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
