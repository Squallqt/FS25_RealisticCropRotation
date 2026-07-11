-- Copyright © 2026 Squallqt. All rights reserved.
-- Native in-game map disease overlay: three sub-pages (active infections / disease risk / treatment
-- coverage), all coloured from existing BitVectorMaps off the UI path -- no Lua pixel iteration, no map built here.
-- The table must survive source() reloads, so closures reference the GLOBAL name, never a captured self.

RealisticCropRotationDiseaseMap = RealisticCropRotationDiseaseMap or {}

RealisticCropRotationDiseaseMap.PAGE_FIELD = "rcrDiseaseMapPageIndex"
RealisticCropRotationDiseaseMap.UPDATE_INTERVAL_MS = 1000

-- Per-disease overlay colours, keyed by the stable state id (cropConfig <diseaseGroup state=>). Two
-- variants per entry: [false] = default palette, [true] = colour-blind-safe (Okabe-Ito based).
-- 1 SCLEROTINIA 2 PHOMA 3 PIETIN 4 SEPTORIOSE 5 ROUILLE 6 FUSARIOSE 7 MILDIOU 8 BCN 9 HERNIE
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

-- Fallback overlay texture base resolution, used only when MapOverlayGenerator.OVERLAY_RESOLUTION is
-- unavailable (adjustedOverlaySize reads the real value first). Display texture only, independent of the source data maps.
RealisticCropRotationDiseaseMap.OVERLAY_BASE_RESOLUTION = 512

RealisticCropRotationDiseaseMap.SUB_PAGE_INFECTIONS = 1
RealisticCropRotationDiseaseMap.SUB_PAGE_PRESSURE = 2
RealisticCropRotationDiseaseMap.SUB_PAGE_TREATMENT = 3
RealisticCropRotationDiseaseMap.activeSubPage = RealisticCropRotationDiseaseMap.activeSubPage or 1

RealisticCropRotationDiseaseMap.RISK_COLOR_LOW      = {0.13, 0.68, 0.36, 1}
RealisticCropRotationDiseaseMap.RISK_COLOR_MODERATE = {0.94, 0.62, 0.08, 1}
RealisticCropRotationDiseaseMap.RISK_COLOR_HIGH     = {0.86, 0.17, 0.14, 1}

-- Treatment-coverage colours: sampled directly from the sprayer products' own HUD fill icons
-- (hud/hud_fill_fungicide.dds / hud_fill_nematicide.dds dominant panel colour), so the map reads
-- consistently with the fill-type icon the player already associates with each product.
RealisticCropRotationDiseaseMap.TREATMENT_COLOR_FUNGICIDE  = {0.00, 0.31, 0.25, 1}
RealisticCropRotationDiseaseMap.TREATMENT_COLOR_NEMATICIDE = {0.00, 0.25, 0.50, 1}


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

---Pathogen groups ordered by their stable overlay state id, straight from the crop config (data-driven).
-- @return table list array of { group, state } sorted by state id
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

---Overlay colour for a disease's grid state id (colour-blind aware); falls back to a generic colour beyond the palette.
local function infectionStateColor(state, colorBlind)
    local entry = RealisticCropRotationDiseaseMap.STATE_COLORS[state]
        or RealisticCropRotationDiseaseMap.STATE_COLOR_FALLBACK
    return entry[colorBlind == true] or entry[false] or {1, 1, 1, 1}
end

---Filter rows for the infection sub-page: one per disease, built from config (l10n name, colour by state id).
-- Row order matches self.filter and renderInfectionOverlay (both walk orderedDiseaseGroups).
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

---Filter rows for the treatment-coverage sub-page: one per product family, reusing the fillType l10n titles (rcr_fillType_fungicide / rcr_fillType_nematicide).
local function getTreatmentDisplayItems()
    local fung = RealisticCropRotationDiseaseMap.TREATMENT_COLOR_FUNGICIDE
    local nema = RealisticCropRotationDiseaseMap.TREATMENT_COLOR_NEMATICIDE
    return {
        { colors = { [false] = {fung}, [true] = {fung} }, description = getText("rcr_fillType_fungicide"),  isActive = true },
        { colors = { [false] = {nema}, [true] = {nema} }, description = getText("rcr_fillType_nematicide"), isActive = true },
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

function RealisticCropRotationDiseaseMap:isTreatmentPage()
    return self.activeSubPage == self.SUB_PAGE_TREATMENT
end


-- ============================================================================
-- Filter data sync
-- ============================================================================

---Ensures self.filter is exactly n entries (new diseases default shown), keeping rows index-aligned.
-- @param integer n
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
    elseif self:isTreatmentPage() then
        self.treatmentFilter = self.treatmentFilter or { true, true }
        frame.dataTables[pageIndex] = getTreatmentDisplayItems()
        frame.filterStates[pageIndex] = self.treatmentFilter
        frame.numSelectedFilters[pageIndex] = countSelected(self.treatmentFilter, 2)
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

---Overlay texture size, scaled from OVERLAY_BASE_RESOLUTION by the performance profile (independent of source map resolution).
-- @return integer size
local function adjustedOverlaySize()
    local base = RealisticCropRotationDiseaseMap.OVERLAY_BASE_RESOLUTION
    if MapOverlayGenerator ~= nil and MapOverlayGenerator.OVERLAY_RESOLUTION ~= nil
        and MapOverlayGenerator.OVERLAY_RESOLUTION.FIELDS ~= nil
        and type(MapOverlayGenerator.OVERLAY_RESOLUTION.FIELDS[1]) == "number" then
        base = MapOverlayGenerator.OVERLAY_RESOLUTION.FIELDS[1]
    end
    if Utils == nil or type(Utils.getPerformanceClassId) ~= "function"
        or GS_PROFILE_LOW == nil or GS_PROFILE_HIGH == nil then
        return base
    end
    local profileClass = Utils.getPerformanceClassId()
    if profileClass <= GS_PROFILE_LOW then
        return base
    elseif profileClass >= GS_PROFILE_HIGH and not Platform.isMobile
        and not (g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
            and g_currentMission.missionDynamicInfo.isMultiplayer and g_currentMission:getIsServer()) then
        return base * 4
    else
        return base * 2
    end
end

---Creates two value overlays per sub-page (double-buffered) so async regeneration into the hidden slot avoids a blank gap on refresh.
function RealisticCropRotationDiseaseMap:createRuntimeObjects()
    if createDensityMapVisualizationOverlay == nil then return end
    local grid = getGrid()
    if grid == nil then return end
    local size = adjustedOverlaySize()

    if self.infectionOverlayIds == nil and grid.mapId ~= nil then
        self.infectionOverlayIds = {
            createDensityMapVisualizationOverlay("rcrInfectionOverlayA", size, size),
            createDensityMapVisualizationOverlay("rcrInfectionOverlayB", size, size),
        }
        self.infectionActiveSlot = nil  -- nothing generated yet: draw() shows nothing until slot 1 is ready
        self.infectionPendingSlot = nil
    end

    if self.riskOverlayIds == nil and grid.riskMapId ~= nil then
        self.riskOverlayIds = {
            createDensityMapVisualizationOverlay("rcrRiskOverlayA", size, size),
            createDensityMapVisualizationOverlay("rcrRiskOverlayB", size, size),
        }
        self.riskActiveSlot = nil
        self.riskPendingSlot = nil
    end

    if self.treatmentOverlayIds == nil and grid.fungicideProtectionMapId ~= nil then
        self.treatmentOverlayIds = {
            createDensityMapVisualizationOverlay("rcrTreatmentOverlayA", size, size),
            createDensityMapVisualizationOverlay("rcrTreatmentOverlayB", size, size),
        }
        self.treatmentActiveSlot = nil
        self.treatmentPendingSlot = nil
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
    if self.treatmentOverlayIds ~= nil then
        for _, id in ipairs(self.treatmentOverlayIds) do delete(id) end
        self.treatmentOverlayIds = nil
    end
    self.infectionActiveSlot, self.infectionPendingSlot = nil, nil
    self.riskActiveSlot, self.riskPendingSlot = nil, nil
    self.treatmentActiveSlot, self.treatmentPendingSlot = nil, nil
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

    -- Only the display controls we own: each view's CONTENT lives in the display maps, whose revisions
    -- (grid.changeRevision / grid.riskRevision / grid.protectionRevision) are tracked in updateOverlay.
    if subPage == self.SUB_PAGE_PRESSURE then
        local rf = self.riskFilter or {}
        parts[#parts + 1] = string.format("%s%s%s",
            rf[1] and "1" or "0", rf[2] and "1" or "0", rf[3] and "1" or "0")
    elseif subPage == self.SUB_PAGE_TREATMENT then
        local tf = self.treatmentFilter or {}
        parts[#parts + 1] = string.format("%s%s", tf[1] and "1" or "0", tf[2] and "1" or "0")
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

    -- One native paint per enabled disease, straight from the destruction grid, showing the real organic
    -- Perlin patches rather than a solid fill. Row order matches orderedDiseaseGroups, so filter[i] gates disease i.
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

---Colours the pressure view from the runtime risk-band map: one native call per band (1..3), painted off the UI path by Disease:refreshRiskMap.
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
-- Treatment-coverage view — render straight from the two per-cell protection maps.
-- ============================================================================

---Colours the treatment-coverage view from the two per-cell protection maps written by the sprayer (same coverage the daily destroy pass excludes).
function RealisticCropRotationDiseaseMap:renderTreatmentOverlay()
    local grid = getGrid()
    if grid == nil or self.treatmentOverlayIds == nil then return false end
    if grid.fungicideProtectionMapId == nil and grid.nematicideProtectionMapId == nil then return false end

    -- Regenerate into the slot NOT currently displayed (double-buffered) -- see renderInfectionOverlay.
    local slot = (self.treatmentActiveSlot == 1) and 2 or 1
    local overlayId = self.treatmentOverlayIds[slot]
    if overlayId == nil or overlayId == 0 then return false end

    local filter = self.treatmentFilter or { true, true }
    local protectionChannels = RealisticCropRotationDiseaseGrid.PROTECTION_NUM_CHANNELS

    resetDensityMapVisualizationOverlay(overlayId)
    setOverlayColor(overlayId, 1, 1, 1, 1)

    if filter[1] ~= false and grid.fungicideProtectionMapId ~= nil then
        local c = RealisticCropRotationDiseaseMap.TREATMENT_COLOR_FUNGICIDE
        setDensityMapVisualizationOverlayStateColor(
            overlayId, grid.fungicideProtectionMapId, 0, 0, 0, protectionChannels, 1, c[1], c[2], c[3])
    end
    if filter[2] ~= false and grid.nematicideProtectionMapId ~= nil then
        local c = RealisticCropRotationDiseaseMap.TREATMENT_COLOR_NEMATICIDE
        setDensityMapVisualizationOverlayStateColor(
            overlayId, grid.nematicideProtectionMapId, 0, 0, 0, protectionChannels, 1, c[1], c[2], c[3])
    end

    generateDensityMapVisualizationOverlay(overlayId)
    self.treatmentPendingSlot = slot
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

    -- Safety belt (pressure view only): a risk band can move between gameplay repaints (e.g. a harvest);
    -- this is an incremental per-field Lua comparison, native passes only for what actually moved.
    if self:isPressurePage() and type(disease.refreshRiskMap) == "function" then
        disease:refreshRiskMap(false)
    end

    local buildKey = self:buildKey()
    local revision
    if self:isPressurePage() then
        revision = grid.riskRevision or 0
    elseif self:isTreatmentPage() then
        revision = grid.protectionRevision or 0
    else
        revision = grid.changeRevision or 0
    end
    if not force and self.lastBuildKey == buildKey and revision == (self.lastRevision or -1) then return end

    local ok
    if self:isPressurePage() then
        ok = self:renderRiskOverlay()
    elseif self:isTreatmentPage() then
        ok = self:renderTreatmentOverlay()
    else
        ok = self:renderInfectionOverlay()
    end

    if ok then
        self.lastBuildKey = buildKey
        self.lastRevision = revision
    end
end

---Draws the active view's overlay (double-buffered): a finished background slot becomes the new active slot, so the map is never blank after the first generation.
function RealisticCropRotationDiseaseMap:draw(x, y, width, height)
    local overlayIds, pendingSlotField, activeSlotField
    if self:isPressurePage() then
        overlayIds, pendingSlotField, activeSlotField = self.riskOverlayIds, "riskPendingSlot", "riskActiveSlot"
    elseif self:isTreatmentPage() then
        overlayIds, pendingSlotField, activeSlotField = self.treatmentOverlayIds, "treatmentPendingSlot", "treatmentActiveSlot"
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

    -- Clone the map-overview selector to build the three-way sub-selector.
    if frame.filterBox ~= nil and frame.mapOverviewSelector ~= nil then
        self.subSelector = frame.mapOverviewSelector:clone(frame.filterBox)
        self.subSelector:setTexts({
            getText("rcr_disease_sub_infections"),
            getText("rcr_disease_sub_pressure"),
            getText("rcr_disease_sub_treatment"),
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
            local numSubPages = 3
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
