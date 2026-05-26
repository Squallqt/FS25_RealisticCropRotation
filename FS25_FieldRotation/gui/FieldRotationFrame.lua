-- Copyright © 2026 Squallqt. All rights reserved.
FieldRotationFrame = {}
local FieldRotationFrame_mt = Class(FieldRotationFrame, TabbedMenuFrameElement)

-- Internal tab indices
FieldRotationFrame.TAB = { HISTORY = 1, PLANNING = 2 }

-- Crop family classification is driven by cropConfig.xml.
-- FieldRotation.cropConfig is loaded once at mod init by main.lua.

-- Advice: N-1 family drives the recommendation
-- COVER never appears as N-1 (excluded from history), no entry needed.
FieldRotationFrame.ADVICE_KEY = {
    CEREAL    = "fr_advice_afterCereal",
    LEGUME    = "fr_advice_afterLegume",
    OILSEED   = "fr_advice_afterOilseed",
    ROOT      = "fr_advice_afterRoot",
    VEGETABLE = "fr_advice_afterVegetable",
    FORAGE    = "fr_advice_afterForage",
}

-- Recommended family for the conseil slot, keyed by N-1 family
FieldRotationFrame.ADVICE_FAMILY = {
    CEREAL    = "LEGUME",
    LEGUME    = "CEREAL",
    OILSEED   = "CEREAL",
    ROOT      = "CEREAL",
    VEGETABLE = "CEREAL",
    FORAGE    = "CEREAL",
}

-- Family badge RGBA — Lua-only (XML constraint does not apply)
FieldRotationFrame.FAMILY_RGBA = {
    CEREAL    = {0.761, 0.365, 0.000, 1.0},  -- amber
    LEGUME    = {0.325, 0.565, 0.071, 1.0},  -- green
    OILSEED   = {0.800, 0.700, 0.000, 1.0},  -- golden yellow
    ROOT      = {0.600, 0.180, 0.100, 1.0},  -- dark red
    VEGETABLE = {0.180, 0.580, 0.380, 1.0},  -- teal green
    FORAGE    = {0.200, 0.480, 0.280, 1.0},  -- grass green
    COVER     = {0.420, 0.300, 0.100, 1.0},  -- earthy brown
}

-- slot index 1..4 maps to history newest-first (history[1] = N-1)
FieldRotationFrame.SLOT_HISTORY_IDX = { 4, 3, 2, 1 }

-- Vanilla spray state labels
FieldRotationFrame.SPRAY_LABEL_KEY = {
    [0] = "fr_n_none", [1] = "fr_n_partial", [2] = "fr_n_full",
}

-- Max pixel widths (must match profile sizes)
FieldRotationFrame.N_BAR_MAX_WIDTH     = 1192
FieldRotationFrame.N_BAR_HEIGHT        = 14
FieldRotationFrame.SCORE_BAR_MAX_WIDTH = 280

-- Global overview crop badge layout (pixel values, converted at runtime)
-- Goal: center the whole pair [crop icon + 5px gap + crop text] inside each 170x30 badge.
FieldRotationFrame.GROUP_BADGE_X          = {132, 334, 536, 738}
FieldRotationFrame.GROUP_BADGE_Y          = 18
FieldRotationFrame.GROUP_BADGE_W          = 170
FieldRotationFrame.GROUP_BADGE_H          = 30
FieldRotationFrame.GROUP_ICON_W           = 20
FieldRotationFrame.GROUP_ICON_H           = 20
FieldRotationFrame.GROUP_ICON_TEXT_GAP    = 5
FieldRotationFrame.GROUP_TEXT_SIZE_PX     = 11

-- Season name l10n keys indexed by currentSeason (0-based)
FieldRotationFrame.SEASON_KEY = {
    [0] = "fr_season_spring", [1] = "fr_season_summer",
    [2] = "fr_season_autumn", [3] = "fr_season_winter",
}

function FieldRotationFrame.new(i18n, messageCenter)
    local self = FieldRotationFrame:superClass().new(nil, FieldRotationFrame_mt)
    self.name          = "FieldRotationFrame"
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

function FieldRotationFrame:copyAttributes(src)
    FieldRotationFrame:superClass().copyAttributes(self, src)
    self.i18n          = src.i18n
    self.messageCenter = src.messageCenter
    self.totalAreaHa   = src.totalAreaHa or 0
    self.isSubscribedToFarmlandChanges = false
end

function FieldRotationFrame:delete()
    self:unsubscribeFarmlandChanges()
    self.farmlandList = nil
    FieldRotationFrame:superClass().delete(self)
end

function FieldRotationFrame:onGuiSetupFinished()
    FieldRotationFrame:superClass().onGuiSetupFinished(self)
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

function FieldRotationFrame:initialize()
    FieldRotationFrame:superClass().initialize(self)

    -- Setup sidebar view tab selector
    if self.viewSelector ~= nil then
        self.viewSelector:setTexts({
            self.i18n:getText("fr_tab_history"),
            self.i18n:getText("fr_tab_planning"),
        })
        self.viewSelector:setState(FieldRotationFrame.TAB.HISTORY, false)

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
function FieldRotationFrame:onCreate()
end

function FieldRotationFrame:onFrameOpen()
    FieldRotationFrame:superClass().onFrameOpen(self)
    self:subscribeFarmlandChanges()
    self:populateSidebar()
    if FieldRotation ~= nil and FieldRotation.requestServerSync ~= nil then
        FieldRotation.requestServerSync("frameOpen")
    end
    self:updateContainerVisibility()
    self:linkFocusNavigation()
end

function FieldRotationFrame:onFrameClose()
    self:unsubscribeFarmlandChanges()
    FieldRotationFrame:superClass().onFrameClose(self)
end

function FieldRotationFrame:getMenuButtonInfo()
    return {}
end

-- ===========================================================================
--  HELPERS
-- ===========================================================================

function FieldRotationFrame:getCurrentFarmId()
    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
        return g_localPlayer.farmId
    end
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        return g_currentMission:getFarmId()
    end
    return -1
end

function FieldRotationFrame:getManager()
    if g_currentMission == nil then return nil end
    return g_currentMission.fieldRotationManager
end

function FieldRotationFrame:checkBonus(farmlandId)
    return self:getActiveNitrogenResidueKgHa(farmlandId) ~= nil
end

---Returns the currently active rotation nitrogen residue in kg/ha for the selected farmland.
-- The service stores the residue as PF state changes; keep the conversion centralized
-- through FieldRotationService:getNitrogenKgPerHaFromStateChange instead of duplicating
-- PF constants in the UI.
-- @param integer farmlandId Farmland identifier
-- @return number|nil residueKgHa Active residue in kg/ha, or nil when no residue exists
function FieldRotationFrame:getActiveNitrogenResidueKgHa(farmlandId)
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

function FieldRotationFrame:getActiveNitrogenResidueText(farmlandId)
    local residueKgHa = self:getActiveNitrogenResidueKgHa(farmlandId)
    if residueKgHa == nil then
        return nil
    end

    return string.format("+%d kg/ha", math.floor(residueKgHa + 0.5))
end

function FieldRotationFrame:updateResiduePill(pillBg, pillText, farmlandId)
    local residueText = self:getActiveNitrogenResidueText(farmlandId)
    local hasBonus = residueText ~= nil
    if pillBg ~= nil then
        pillBg:applyProfile(hasBonus and "frStatusPillBgBonus" or "frStatusPillBg")
    end
    if pillText ~= nil then
        pillText:setText(hasBonus and residueText or self.i18n:getText("fr_status_no_bonus"))
    end
end

function FieldRotationFrame:getCropFamily(cropName)
    if cropName == nil or cropName == "" then return "UNKNOWN" end
    local config = FieldRotation ~= nil and FieldRotation.cropConfig or nil
    if config == nil or config.families == nil then return "UNKNOWN" end
    return config.families[string.upper(cropName)] or "UNKNOWN"
end

function FieldRotationFrame:getCropDisplayName(cropName)
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

function FieldRotationFrame:buildFarmlandList()
    local mgr = self:getManager()
    if mgr == nil or mgr.getOwnedFarmlands == nil then return {} end
    return mgr:getOwnedFarmlands() or {}
end

function FieldRotationFrame:formatAreaHa(areaHa)
    return string.format("%.1f ha", tonumber(areaHa) or 0)
end

function FieldRotationFrame:calculateTotalAreaHa(farmlandList)
    local total = 0
    for _, entry in ipairs(farmlandList or {}) do
        total = total + (tonumber(entry.areaHa) or 0)
    end
    return total
end

function FieldRotationFrame:updateOverviewTotalArea()
    if self.overviewTotalArea == nil then return end
    local label = self.i18n:getText("fr_overview_total_area")
    self.overviewTotalArea:setText(string.format(label, self.totalAreaHa or 0))
end

function FieldRotationFrame:subscribeFarmlandChanges()
    if self.isSubscribedToFarmlandChanges then return end
    if self.messageCenter ~= nil and self.messageCenter.subscribe ~= nil
        and MessageType ~= nil and MessageType.FARMLAND_OWNER_CHANGED ~= nil then
        self.messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, self.onFarmlandOwnerChanged, self)
        self.isSubscribedToFarmlandChanges = true
    end
end

function FieldRotationFrame:unsubscribeFarmlandChanges()
    if not self.isSubscribedToFarmlandChanges then return end
    if self.messageCenter ~= nil and self.messageCenter.unsubscribe ~= nil
        and MessageType ~= nil and MessageType.FARMLAND_OWNER_CHANGED ~= nil then
        self.messageCenter:unsubscribe(MessageType.FARMLAND_OWNER_CHANGED, self)
    end
    self.isSubscribedToFarmlandChanges = false
end

function FieldRotationFrame:onFarmlandOwnerChanged(_farmlandId, _farmId, _loadFromSavegame)
    self:populateSidebar()
end

function FieldRotationFrame:isHistoryTab()
    return self.viewSelector == nil
        or self.viewSelector:getState() == FieldRotationFrame.TAB.HISTORY
end

function FieldRotationFrame:updateContainerVisibility()
    local hasFields = #(self.farmlandList or {}) > 0
    local isHistory = self:isHistoryTab()
    if self.emptyText        ~= nil then self.emptyText:setVisible(not hasFields) end
    if self.detailsContainer ~= nil then self.detailsContainer:setVisible(hasFields and isHistory) end
    if self.planningContainer ~= nil then self.planningContainer:setVisible(hasFields and not isHistory) end
end

function FieldRotationFrame:linkFocusNavigation()
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

function FieldRotationFrame:getPlanForFarmland(farmlandId)
    local mgr = self:getManager()
    if mgr ~= nil and mgr.getRotationPlan ~= nil then
        return mgr:getRotationPlan(farmlandId)
    end
    return {"","","",""}
end

-- ===========================================================================
--  CROP LIST (built once from fruitTypeManager; drives plan slot selectors)
-- ===========================================================================

function FieldRotationFrame:buildPlanCropList()
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
                    -- Exclude pure cover crops from the rotation plan.
                    -- Exception: dualUse crops (e.g. MUSTARD = crop + cover).
                    local cfg = FieldRotation ~= nil and FieldRotation.cropConfig or nil
                    local family = cfg ~= nil and cfg.families ~= nil and cfg.families[name] or nil
                    local isDualUse = cfg ~= nil and cfg.dualUse ~= nil and cfg.dualUse[name] == true
                    if family ~= "COVER" or isDualUse then
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
        table.insert(cropTexts, cropName == "" and self.i18n:getText("fr_plan_none")
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

function FieldRotationFrame:populateSidebar()
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

function FieldRotationFrame:getNumberOfSections()
    return 1
end

function FieldRotationFrame:getNumberOfItemsInSection(list, _section)
    if list == self.listPlanOverview then
        return #(self.rotationGroups or {})
    end
    return #(self.farmlandList or {})
end

function FieldRotationFrame:getCellTypeForItemInSection(list, _section, _index)
    if list == self.listPlanOverview then return "groupRow" end
    return "field"
end

function FieldRotationFrame:getTitleForSectionHeader(_list, _section)
    return nil
end

function FieldRotationFrame:getSectionHeaderHeight(_list, _section)
    return 0
end

function FieldRotationFrame:populateCellForItemInSection(list, _section, index, cell)
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
                line = line .. "  \xc2\xb7  " .. self.i18n:getText("fr_family_" .. string.lower(family))
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
                cropLineEl:setText(self.i18n:getText("fr_sidebar_no_active_crop"))
            end
        end
    end
end

function FieldRotationFrame:onListSelectionChanged(_list, _section, index, _cell)
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

function FieldRotationFrame:onViewChanged()
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
--  DETAIL PANEL (tab 1 — history / nitrogen / advice / pH)
-- ===========================================================================

function FieldRotationFrame:updateDetailPanel(farmlandId)
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
        local seasonKey = FieldRotationFrame.SEASON_KEY[seasonIdx] or "fr_season_spring"
        self.detailSeason:setText(
            "\xc2\xb7  " .. self.i18n:getText("fr_season_label") .. ": "
            .. string.upper(self.i18n:getText(seasonKey)) .. "  \xc2\xb7"
        )
    end

    self:updateResiduePill(self.statusPillBg, self.statusPillText, farmlandId)

    local mgr = self:getManager()
    local history = (mgr ~= nil) and (mgr:getHistory(farmlandId) or {}) or {}

    for slotIdx = 1, 4 do
        local histIdx  = FieldRotationFrame.SLOT_HISTORY_IDX[slotIdx]
        local hEntry   = history[histIdx]
        local cropName = hEntry and hEntry.crop or nil
        self:updateTimelineSlot(slotIdx, cropName, self:getCropFamily(cropName), false)
    end
    local n1crop = history[1] and history[1].crop or nil
    local n1family = self:getCropFamily(n1crop)
    local recommendedFamily = FieldRotationFrame.ADVICE_FAMILY[n1family] or "UNKNOWN"
    self:updateTimelineSlot(5, nil, recommendedFamily, true)

    self:updateNitrogenGauge(farmlandId)
    self:updateSoilPHGauge(farmlandId)
    self:updateAdvice(history)
    self:updateYieldCard(farmlandId)
end

-- ---------------------------------------------------------------------------
--  Timeline slot (slotId 1..5) — history tab
-- ---------------------------------------------------------------------------

function FieldRotationFrame:updateTimelineSlot(slotId, cropName, family, isFuture)
    local pfx = "slot" .. tostring(slotId)
    local iconEl   = self[pfx .. "Icon"]
    local nameEl   = self[pfx .. "CropName"]
    local badgeBg  = self[pfx .. "BadgeBg"]
    local badgeTxt = self[pfx .. "BadgeText"]

    if iconEl ~= nil then
        local loaded = false
        if cropName ~= nil and not isFuture and g_fruitTypeManager ~= nil then
            local fruitType = g_fruitTypeManager:getFruitTypeByName(cropName)
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

    if nameEl ~= nil then
        if cropName ~= nil and not isFuture then
            nameEl:setText(self:getCropDisplayName(cropName))
        elseif isFuture then
            nameEl:setText((family == nil or family == "UNKNOWN") and "?" or "")
        else
            nameEl:setText(self.i18n:getText("fr_slot_empty"))
        end
    end

    local showBadge = (family ~= nil) and (family ~= "UNKNOWN")
    if badgeBg ~= nil then
        badgeBg:setVisible(showBadge)
        if showBadge then
            local c = FieldRotationFrame.FAMILY_RGBA[family]
            if c ~= nil then
                badgeBg.color = {c[1], c[2], c[3], c[4]}
            end
        end
    end
    if badgeTxt ~= nil then
        badgeTxt:setVisible(showBadge)
        if showBadge then
            badgeTxt:setText(self.i18n:getText("fr_family_" .. string.lower(family)))
        end
    end
end

-- ---------------------------------------------------------------------------
--  Nitrogen gauge
-- ---------------------------------------------------------------------------

function FieldRotationFrame:setStatusBarFill(barFill, ratio)
    ratio = math.max(0, math.min(1, tonumber(ratio) or 0))

    local fillW = math.floor(FieldRotationFrame.N_BAR_MAX_WIDTH * ratio)
    if barFill ~= nil then
        if barFill.setSize ~= nil then
            local fillSize = GuiUtils ~= nil and GuiUtils.getNormalizedScreenValues ~= nil
                and GuiUtils.getNormalizedScreenValues(
                    string.format("%dpx %dpx", fillW, FieldRotationFrame.N_BAR_HEIGHT)
                ) or nil
            if fillSize ~= nil then
                barFill:setSize(fillSize[1], fillSize[2])
            end
        end
        barFill:setVisible(fillW > 0)
    end
end

function FieldRotationFrame:updateNitrogenGauge(farmlandId)
    local mgr = self:getManager()
    local ratio = 0
    local labelKey = "fr_n_none"
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

            labelKey = "fr_n_available"
            valueText = string.format("%.0f kg/ha", kgHa)

            if targetKgHa > 0 then
                needText = string.format(self.i18n:getText("fr_n_crop_need"), targetKgHa)
            end
        end
    end

    if valueText == nil then
        local sprayLevel = 0
        if mgr ~= nil and mgr.getCurrentSprayLevel ~= nil then
            sprayLevel = mgr:getCurrentSprayLevel(farmlandId) or 0
        end
        sprayLevel = math.max(0, math.min(2, tonumber(sprayLevel) or 0))
        ratio = sprayLevel / 2.0
        labelKey = FieldRotationFrame.SPRAY_LABEL_KEY[sprayLevel] or "fr_n_none"
    end

    self:setStatusBarFill(self.nitrogenBarFill, ratio)

    if self.nitrogenStateLabel ~= nil then
        self.nitrogenStateLabel:setText(self.i18n:getText(labelKey))
    end

    if self.nitrogenValueLabel ~= nil then
        if valueText ~= nil then
            self.nitrogenValueLabel:setText(valueText)
        end
        self.nitrogenValueLabel:setVisible(valueText ~= nil)
    end

    if self.nitrogenNeedLabel ~= nil then
        if needText ~= nil then
            self.nitrogenNeedLabel:setText(needText)
        end
        self.nitrogenNeedLabel:setVisible(needText ~= nil)
    end
end

-- ---------------------------------------------------------------------------
--  Soil pH / lime gauge
-- ---------------------------------------------------------------------------

function FieldRotationFrame:updateSoilPHGauge(farmlandId)
    local mgr = self:getManager()
    local ratio = 0
    local labelKey = "fr_lime_none"
    local valueText = nil

    if mgr ~= nil and mgr.getPHLevel ~= nil then
        local actualPH, targetPH, minPH, maxPH = mgr:getPHLevel(farmlandId)
        if actualPH ~= nil then
            minPH = tonumber(minPH) or 0
            maxPH = tonumber(maxPH) or 0
            labelKey = "fr_lime_average_pf"
            if targetPH ~= nil then
                ratio = targetPH > 0 and (actualPH / targetPH) or 0
                valueText = string.format("%.2f / %.2f pH", actualPH, targetPH)
            else
                ratio = maxPH > minPH and ((actualPH - minPH) / (maxPH - minPH)) or 0
                valueText = string.format("%.2f pH", actualPH)
            end
        end
    end

    if valueText == nil then
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
            labelKey = "fr_lime_none"
        elseif limeLevel >= maxLevel then
            labelKey = "fr_lime_full"
        else
            labelKey = "fr_lime_partial"
        end
    end

    self:setStatusBarFill(self.limeBarFill, ratio)

    if self.limeStateLabel ~= nil then
        self.limeStateLabel:setText(self.i18n:getText(labelKey))
    end

    if self.limeValueLabel ~= nil then
        self.limeValueLabel:setText(valueText or "")
        self.limeValueLabel:setVisible(valueText ~= nil)
    end
end

-- ---------------------------------------------------------------------------
--  Yield card
-- ---------------------------------------------------------------------------

function FieldRotationFrame:updateYieldCard(farmlandId)
    local mgr = self:getManager()
    local estimate = nil
    if mgr ~= nil and mgr.getYieldEstimate ~= nil then
        estimate = mgr:getYieldEstimate(farmlandId)
    end

    local totalText = "-"
    local yieldText = "-"
    local hasEstimate = estimate ~= nil

    if hasEstimate then
        local totalLiters = tonumber(estimate.totalLiters) or 0
        local yieldPerArea = tonumber(estimate.yieldPerArea) or 0
        local areaUnit = tostring(estimate.areaUnit or "ha")

        if g_i18n ~= nil and g_i18n.formatVolume ~= nil then
            totalText = g_i18n:formatVolume(totalLiters, 0)
        else
            totalText = string.format("%d L", math.floor(totalLiters + 0.5))
        end

        yieldText = string.format("%.2f T/%s", yieldPerArea, areaUnit)
    end

    if self.yieldTotalValue ~= nil then
        if self.yieldTotalValue.applyProfile ~= nil then
            self.yieldTotalValue:applyProfile(hasEstimate and "frYieldKpiValue" or "frYieldKpiValueNA")
        end
        self.yieldTotalValue:setText(totalText)
    end

    if self.yieldPerHaValue ~= nil then
        if self.yieldPerHaValue.applyProfile ~= nil then
            self.yieldPerHaValue:applyProfile(hasEstimate and "frYieldKpiValue" or "frYieldKpiValueNA")
        end
        self.yieldPerHaValue:setText(yieldText)
    end
end

-- ---------------------------------------------------------------------------
--  Agronomic advice
-- ---------------------------------------------------------------------------

function FieldRotationFrame:updateAdvice(history)
    if self.adviceText == nil then return end
    history = history or {}
    local n1crop   = history[1] and history[1].crop or nil
    local n1family = self:getCropFamily(n1crop)
    local key      = FieldRotationFrame.ADVICE_KEY[n1family]
    self.adviceText:setText(
        key ~= nil and self.i18n:getText(key)
                   or self.i18n:getText("fr_advice_insufficient"))
end

-- ===========================================================================
--  PLANNING PANEL (tab 2)
-- ===========================================================================

function FieldRotationFrame:updatePlanningPanel(farmlandId)
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
        local seasonKey = FieldRotationFrame.SEASON_KEY[seasonIdx] or "fr_season_spring"
        self.planSeason:setText(
            "\xc2\xb7  " .. self.i18n:getText("fr_season_label") .. ": "
            .. string.upper(self.i18n:getText(seasonKey)) .. "  \xc2\xb7"
        )
    end

    self:updatePlanSlots(farmlandId)
    local plan = self:getPlanForFarmland(farmlandId)
    self:updateScoreCard(plan)
    self:updateResiduePill(self.planStatusPillBg, self.planStatusPillText, farmlandId)
end

-- ---------------------------------------------------------------------------
--  Plan slots — crop selector + icon + family badge
-- ---------------------------------------------------------------------------

function FieldRotationFrame:updatePlanSlots(farmlandId)
    local plan = self:getPlanForFarmland(farmlandId)
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

function FieldRotationFrame:getPlanFromSelectors()
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

function FieldRotationFrame:updatePlanSlotVisualsFromSelectors()
    local plan = self:getPlanFromSelectors()
    for i = 1, 4 do
        local cropName = plan[i] or ""
        local iconEl   = self.planSlotIcon      ~= nil and self.planSlotIcon[i]
        local badgeBg  = self.planSlotBadge     ~= nil and self.planSlotBadge[i]
        local badgeTxt = self.planSlotBadgeText ~= nil and self.planSlotBadgeText[i]
        self:applySlotCropIcon(iconEl, cropName)
        self:applySlotBadge(badgeBg, badgeTxt, self:getCropFamily(cropName))
    end
    self:updateScoreCard(plan)
end

function FieldRotationFrame:onServerSyncReceived()
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

function FieldRotationFrame:applySlotCropIcon(iconEl, cropName)
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

function FieldRotationFrame:applySlotBadge(badgeBg, badgeTxt, family)
    local showBadge = family ~= nil and family ~= "" and family ~= "UNKNOWN"
    if badgeBg ~= nil then
        badgeBg:setVisible(showBadge)
        if showBadge then
            local c = FieldRotationFrame.FAMILY_RGBA[family]
            if c ~= nil then
                badgeBg.color = {c[1], c[2], c[3], c[4]}
            end
        end
    end
    if badgeTxt ~= nil then
        badgeTxt:setVisible(showBadge)
        if showBadge then
            badgeTxt:setText(self.i18n:getText("fr_family_" .. string.lower(family)))
        end
    end
end

-- ---------------------------------------------------------------------------
--  Plan slot onClick handlers
-- ---------------------------------------------------------------------------

function FieldRotationFrame:onChangePlanSlot1() self:handlePlanSlotChange(1) end
function FieldRotationFrame:onChangePlanSlot2() self:handlePlanSlotChange(2) end
function FieldRotationFrame:onChangePlanSlot3() self:handlePlanSlotChange(3) end
function FieldRotationFrame:onChangePlanSlot4() self:handlePlanSlotChange(4) end

function FieldRotationFrame:handlePlanSlotChange(slotIdx)
    if self.isApplyingServerSync then return end
    if self.selectedId == nil then return end
    local sel = self.planSlotSelector ~= nil and self.planSlotSelector[slotIdx]
    if sel == nil then return end

    local state    = sel:getState()
    local cropName = (self.planCropList ~= nil and self.planCropList[state]) or ""

    local isClientOnly = g_currentMission ~= nil and g_currentMission.getIsServer ~= nil
        and not g_currentMission:getIsServer()

    if isClientOnly then
        if g_client ~= nil and g_client.getServerConnection ~= nil and FRPlanUpdateEvent ~= nil then
            local connection = g_client:getServerConnection()
            if connection ~= nil then
                connection:sendEvent(FRPlanUpdateEvent.new(self.selectedId, slotIdx, cropName))
            end
        else
            Logging.warning("[FieldRotation][MP] Plan update not sent: client connection or event unavailable")
        end
    else
        local mgr = self:getManager()
        local changed = false
        if mgr ~= nil and mgr.setRotationPlanYear ~= nil then
            changed = mgr:setRotationPlanYear(self.selectedId, slotIdx, cropName)
        end
        if changed and FieldRotation ~= nil and FieldRotation.requestBroadcast ~= nil then
            FieldRotation.requestBroadcast()
        end
    end

    local iconEl   = self.planSlotIcon      ~= nil and self.planSlotIcon[slotIdx]
    local badgeBg  = self.planSlotBadge     ~= nil and self.planSlotBadge[slotIdx]
    local badgeTxt = self.planSlotBadgeText ~= nil and self.planSlotBadgeText[slotIdx]
    self:applySlotCropIcon(iconEl, cropName)
    self:applySlotBadge(badgeBg, badgeTxt, self:getCropFamily(cropName))

    local plan = self:getPlanFromSelectors()
    self:updateScoreCard(plan)

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

function FieldRotationFrame:updateScoreCard(plan)
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

function FieldRotationFrame:calcRotationScore(plan)
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

function FieldRotationFrame:getScoreTextKey(score, plan)
    local anyFilled = false
    for i = 1, 4 do if (plan[i] or "") ~= "" then anyFilled = true; break end end
    if not anyFilled   then return "fr_plan_none" end
    if score == 0      then return "fr_score_incomplete" end
    if score >= 80     then return "fr_score_excellent" end
    if score >= 60     then return "fr_score_good" end
    if score >= 40     then return "fr_score_fair" end
    return "fr_score_poor"
end

function FieldRotationFrame:getScoreLabel(score)
    if score >= 80 then return "fr_score_short_optimal", 0.325, 0.565, 0.071
    elseif score >= 60 then return "fr_score_short_good",  0.95,  0.85, 0.05
    elseif score >= 30 then return "fr_score_short_fair",  0.75,  0.45, 0.05
    elseif score >  0  then return "fr_score_short_poor",  0.75,  0.20, 0.05
    else                    return nil,                    0.30,  0.30, 0.30
    end
end

-- ===========================================================================
--  ROTATION GROUPS — overview of fields sharing the same crop rotation
-- ===========================================================================

function FieldRotationFrame:buildRotationGroups()
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

function FieldRotationFrame:getCompactGroupFieldNames(fieldNames)
    local parts = {}
    for i = 1, #(fieldNames or {}) do
        table.insert(parts, string.upper(tostring(fieldNames[i] or "")))
    end

    return table.concat(parts, "  |  ")
end

function FieldRotationFrame:layoutGroupBadgeContent(cell, slotIndex, displayText)
    if cell == nil or cell.getAttribute == nil then return end
    if GuiUtils == nil or GuiUtils.getNormalizedScreenValues == nil then return end
    if getTextWidth == nil then return end

    local iconEl  = cell:getAttribute("gCropIcon" .. slotIndex)
    local labelEl = cell:getAttribute("gLabel" .. slotIndex)
    if iconEl == nil or labelEl == nil then return end

    local badgeXpx = FieldRotationFrame.GROUP_BADGE_X[slotIndex]
    if badgeXpx == nil then return end

    local badgeSize = GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx %dpx",
        FieldRotationFrame.GROUP_BADGE_W,
        FieldRotationFrame.GROUP_BADGE_H
    ))
    local badgePos = GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx -%dpx",
        badgeXpx,
        FieldRotationFrame.GROUP_BADGE_Y
    ))
    local iconSize = GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx %dpx",
        FieldRotationFrame.GROUP_ICON_W,
        FieldRotationFrame.GROUP_ICON_H
    ))
    local gapSize = GuiUtils.getNormalizedScreenValues(string.format(
        "%dpx 0px",
        FieldRotationFrame.GROUP_ICON_TEXT_GAP
    ))

    -- The label profile uppercases text, so measure the rendered form.
    local measuredText = string.upper(tostring(displayText or ""))
    local textSize = labelEl.textSize
    if textSize == nil then
        textSize = GuiUtils.getNormalizedScreenValues(string.format(
            "0px %dpx",
            FieldRotationFrame.GROUP_TEXT_SIZE_PX
        ))[2]
    end

    local textWidth = getTextWidth(textSize, measuredText)
    local totalWidth = iconSize[1] + gapSize[1] + textWidth
    local startX = badgePos[1] + (badgeSize[1] - totalWidth) * 0.5

    local iconYpx = FieldRotationFrame.GROUP_BADGE_Y
        + math.floor((FieldRotationFrame.GROUP_BADGE_H - FieldRotationFrame.GROUP_ICON_H) * 0.5)
    local iconPosY = GuiUtils.getNormalizedScreenValues(string.format("0px -%dpx", iconYpx))[2]

    iconEl:setPosition(startX, iconPosY)
    labelEl:setPosition(startX + iconSize[1] + gapSize[1], badgePos[2])

    -- Keep the text element wide enough to avoid clipping/truncation.
    -- Its position is computed from textWidth, but the rendered box must not be reduced to textWidth.
    if labelEl.setSize ~= nil then
        labelEl:setSize(badgeSize[1], badgeSize[2])
    end
end

function FieldRotationFrame:populateGroupCell(index, cell)
    if cell == nil or cell.getAttribute == nil then return end
    local group = (self.rotationGroups or {})[index]
    if group == nil then return end
    local isEmptyGroup = group.key == "|||"

    local summaryEl = cell:getAttribute("gPlanSummary")
    if summaryEl ~= nil then
        summaryEl:setVisible(isEmptyGroup)
        if isEmptyGroup then
            summaryEl:setText(self.i18n:getText("fr_plan_none"))
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
                local c = FieldRotationFrame.FAMILY_RGBA[family] or {0.20, 0.20, 0.20, 0.60}
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
                self:layoutGroupBadgeContent(cell, i, displayName)
            end
        end

        local yearLabelEl = cell:getAttribute("gYearLabel" .. i)
        if yearLabelEl ~= nil then yearLabelEl:setVisible(show and not isEmptyGroup) end
    end

    -- Arrows: show only between two filled adjacent slots
    for i = 1, 3 do
        local arrowEl = cell:getAttribute("gArrow" .. i)
        if arrowEl ~= nil then
            local bothFilled = (group.plan[i] or "") ~= "" and (group.plan[i+1] or "") ~= ""
            arrowEl:setVisible(bothFilled)
        end
    end

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
