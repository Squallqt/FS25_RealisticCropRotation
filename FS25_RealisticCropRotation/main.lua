-- Copyright © 2026 Squallqt. All rights reserved.
-- Mod bootstrap: source loading, lifecycle + density-map hooks, broadcast coalescing.
local modDirectory = g_currentModDirectory

source(modDirectory .. "scripts/RealisticCropRotationRepository.lua")
source(modDirectory .. "scripts/RealisticCropRotationPlannerModel.lua")
source(modDirectory .. "scripts/RealisticCropRotationService.lua")
source(modDirectory .. "scripts/RealisticCropRotationManager.lua")
source(modDirectory .. "scripts/RealisticCropRotationNitrogen.lua")
source(modDirectory .. "scripts/RealisticCropRotationSoilUptake.lua")
source(modDirectory .. "scripts/RealisticCropRotationDiseaseModel.lua")
source(modDirectory .. "scripts/RealisticCropRotationDisease.lua")
source(modDirectory .. "scripts/RealisticCropRotationDiseaseGrid.lua")
source(modDirectory .. "scripts/RealisticCropRotationTreatmentLifecycle.lua")
source(modDirectory .. "scripts/RealisticCropRotationDiseaseMap.lua")
source(modDirectory .. "scripts/RealisticCropRotationHud.lua")
source(modDirectory .. "scripts/RealisticCropRotationSprayerProducts.lua")
source(modDirectory .. "events/RCRAdminCommandEvent.lua")
source(modDirectory .. "events/RCRDiseaseNotificationEvent.lua")
source(modDirectory .. "events/RCRHistoryRequestEvent.lua")
source(modDirectory .. "events/RCRHistoryResponseEvent.lua")
source(modDirectory .. "events/RCRPlanUpdateEvent.lua")
source(modDirectory .. "gui/RealisticCropRotationWeatherCard.lua")
source(modDirectory .. "gui/RealisticCropRotationFrame.lua")

RealisticCropRotation = {}
RealisticCropRotation.modDirectory = modDirectory
RealisticCropRotation.manager = nil
RealisticCropRotation.disease = nil
RealisticCropRotation.grid = nil
RealisticCropRotation.frame = nil
RealisticCropRotation.pendingSyncData = nil
RealisticCropRotation.cropConfig = nil
RealisticCropRotation.guiProfilesLoaded = false
RealisticCropRotation.tabListFixApplied = false
RealisticCropRotation.SPECIAL_CROP_FALLOW = "__FALLOW"

function RealisticCropRotation.isFallowCrop(cropName)
    return cropName ~= nil
        and string.upper(tostring(cropName)) == RealisticCropRotation.SPECIAL_CROP_FALLOW
end

---Loads cropConfig.xml into the crop and disease-group configuration table.
-- @return table config Crop configuration, or nil when the XML cannot be loaded
local function loadCropConfig()
    local filePath = modDirectory .. "cropConfig.xml"
    local xmlFile = loadXMLFile("RealisticCropRotationCropConfig", filePath)
    if xmlFile == nil or xmlFile == 0 then
        Logging.error("[RealisticCropRotation] Failed to load cropConfig.xml at %s", tostring(filePath))
        return nil
    end

    local config = {
        families = {},
        nitrogen = {},
        coverCrops = {},
        coverCropNames = {},
        diseases = {},
        diseasePlannerIntervals = {},
        diseaseRotationRelevant = {},
        diseaseReservoirClasses = {},
        diseaseAnnualRetention = {},
        diseaseWindows = {},
        diseaseWeatherDriven = {},
        diseaseCurves = {},
        diseaseStates = {},
        diseaseTreatments = {},
        diseaseWeatherFactors = {},
        diseaseAmbient = {},
    }
    local i = 0
    while true do
        local key = string.format("realisticCropRotationCrops.crop(%d)", i)
        if not hasXMLProperty(xmlFile, key) then break end

        local name    = getXMLString(xmlFile, key .. "#name")
        local family  = getXMLString(xmlFile, key .. "#family")
        local n1      = getXMLInt(xmlFile,    key .. "#n1") or 0
        local n2      = getXMLInt(xmlFile,    key .. "#n2") or 0
        local cover   = getXMLBool(xmlFile,   key .. "#cover") or false
        local disease = getXMLString(xmlFile, key .. "#disease")

        if name ~= nil and name ~= "" then
            name = string.upper(name)
            if family ~= nil and family ~= "" then
                config.families[name] = string.upper(family)
            end
            if n1 > 0 or n2 > 0 then
                config.nitrogen[name] = { n1 = n1, n2 = n2 }
            end
            if cover then
                if not config.coverCrops[name] then
                    config.coverCropNames[#config.coverCropNames + 1] = name
                end
                config.coverCrops[name] = true
            end
            if disease ~= nil and disease ~= "" then
                local set = {}
                for g in string.gmatch(disease, "%S+") do set[string.upper(g)] = true end
                config.diseases[name] = set
            end
        end
        i = i + 1
    end

    -- Shared-pathogen groups: `autoState` gives a deterministic overlay id (parse order) when a group omits #state.
    local j = 0
    local autoState = 0
    while true do
        local gkey = string.format("realisticCropRotationCrops.diseaseGroups.diseaseGroup(%d)", j)
        if not hasXMLProperty(xmlFile, gkey) then break end
        local gname = getXMLString(xmlFile, gkey .. "#name")
        local gint  = getXMLInt(xmlFile, gkey .. "#plannerInterval")
        if gname ~= nil and gname ~= "" and gint ~= nil then
            local upper = string.upper(gname)
            autoState = autoState + 1
            config.diseasePlannerIntervals[upper] = gint
            config.diseaseRotationRelevant[upper] =
                getXMLBool(xmlFile, gkey .. "#rotationRelevant") == true
            config.diseaseReservoirClasses[upper] =
                string.upper(tostring(getXMLString(xmlFile, gkey .. "#reservoirClass") or "NONE"))
            config.diseaseAnnualRetention[upper] =
                getXMLFloat(xmlFile, gkey .. "#annualRetention") or 0
            local from = getXMLFloat(xmlFile, gkey .. "#infectFrom")
            local to   = getXMLFloat(xmlFile, gkey .. "#infectTo")
            if from ~= nil and to ~= nil then
                config.diseaseWindows[upper] = { from = from, to = to }
            end
            -- Only explicitly weather-driven groups receive rain and temperature modifiers.
            config.diseaseWeatherDriven[upper] =
                getXMLBool(xmlFile, gkey .. "#weatherDriven") == true
            -- Stable per-disease overlay id, with parse order as the fallback.
            local state = getXMLInt(xmlFile, gkey .. "#state")
            config.diseaseStates[upper] = (state ~= nil and state > 0) and state or autoState
            -- Treatment family used by the field panel and sprayer logic.
            local treatment = getXMLString(xmlFile, gkey .. "#treatment")
            config.diseaseTreatments[upper] = (treatment ~= nil and treatment ~= "") and string.upper(treatment) or "NONE"
            -- Optional rain multiplier for weather-driven disease groups.
            config.diseaseWeatherFactors[upper] = getXMLFloat(xmlFile, gkey .. "#weatherFactor")
            -- Regional background inoculum floor used by the infection roll.
            config.diseaseAmbient[upper] = getXMLFloat(xmlFile, gkey .. "#ambient") or 0
            -- Optional daily growth, destruction threshold and maximum destroyed share.
            config.diseaseCurves[upper] = {
                dailyGrowth     = getXMLFloat(xmlFile, gkey .. "#dailyGrowth"),
                destroySeverity = getXMLFloat(xmlFile, gkey .. "#destroySeverity"),
                deadFractionMax = getXMLFloat(xmlFile, gkey .. "#deadFractionMax"),
            }
        end
        j = j + 1
    end

    delete(xmlFile)
    return config
end

-- Broadcast coalescing: hooks request a broadcast instead of emitting one per density-map change.
RealisticCropRotation.BROADCAST_DEBOUNCE_MS = 500
RealisticCropRotation.MENU_RECONCILE_COOLDOWN_MS = 2000
RealisticCropRotation.broadcastDirty = false
RealisticCropRotation.broadcastTimerMs = 0
RealisticCropRotation.broadcastUpdateable = nil
RealisticCropRotation.menuReconcileQueue = nil
RealisticCropRotation.lastMenuReconcileMs = nil
RealisticCropRotation.farmlandOwnerChangeListener = nil
RealisticCropRotation.periodChangedListener = nil
RealisticCropRotation.dayChangedListener = nil
RealisticCropRotation.hudMapUpdateable = nil

---Marks rotation state dirty so one coalesced server broadcast is sent.
function RealisticCropRotation.requestBroadcast()
    if g_server == nil then return end
    RealisticCropRotation.broadcastDirty = true
    RealisticCropRotation.broadcastTimerMs = RealisticCropRotation.BROADCAST_DEBOUNCE_MS
end

---Asks the server for a full rotation snapshot (client).
-- @param integer selectedFarmlandId Farmland to reconcile first, or nil
function RealisticCropRotation.requestServerSync(selectedFarmlandId)
    if g_client == nil then return end
    if type(g_client.getServerConnection) ~= "function" then return end
    local connection = g_client:getServerConnection()
    if connection ~= nil then
        connection:sendEvent(RCRHistoryRequestEvent.new(selectedFarmlandId))
    end
end

---Moves the selected farmland to the next unprocessed position in a reconcile queue.
-- @param table queue Active menu reconcile queue
-- @param integer selectedFarmlandId Farmland to prioritize, or nil
local function prioritizeMenuReconcile(queue, selectedFarmlandId)
    local selected = tonumber(selectedFarmlandId)
    if queue == nil or selected == nil or selected <= 0 then return end

    local nextIndex = math.max(1, math.floor(tonumber(queue.index) or 1))
    for index = nextIndex, #(queue.farmlandIds or {}) do
        if tonumber(queue.farmlandIds[index]) == selected then
            queue.farmlandIds[nextIndex], queue.farmlandIds[index] =
                queue.farmlandIds[index], queue.farmlandIds[nextIndex]
            return
        end
    end
end

---Schedules authoritative crop reconciliation without blocking menu opening.
-- @param integer selectedFarmlandId Farmland to reconcile first, or nil
-- @return boolean scheduled True when a queue is active or newly scheduled
function RealisticCropRotation.requestMenuReconcile(selectedFarmlandId)
    if g_currentMission == nil or not g_currentMission:getIsServer() then return false end
    local manager = RealisticCropRotation.manager
    if manager == nil then return false end

    local queue = RealisticCropRotation.menuReconcileQueue
    if queue ~= nil then
        prioritizeMenuReconcile(queue, selectedFarmlandId)
        return true
    end

    local nowMs = tonumber(g_time) or 0
    local lastMs = tonumber(RealisticCropRotation.lastMenuReconcileMs)
    if lastMs ~= nil and nowMs >= lastMs
        and nowMs - lastMs < RealisticCropRotation.MENU_RECONCILE_COOLDOWN_MS then
        return false
    end

    local farmlandIds = manager:getOwnedRotationFarmlandIds() or {}
    if #farmlandIds == 0 then return false end

    queue = {
        farmlandIds = farmlandIds,
        index = 1,
        changed = false,
    }
    prioritizeMenuReconcile(queue, selectedFarmlandId)
    RealisticCropRotation.menuReconcileQueue = queue
    RealisticCropRotation.lastMenuReconcileMs = nowMs
    return true
end

---Reconciles one queued farmland per frame and emits one final coalesced broadcast.
local function processMenuReconcileQueue()
    local queue = RealisticCropRotation.menuReconcileQueue
    if queue == nil then return end

    local manager = RealisticCropRotation.manager
    if manager == nil then
        RealisticCropRotation.menuReconcileQueue = nil
        return
    end

    local farmlandId = queue.farmlandIds[queue.index]
    if farmlandId == nil then
        RealisticCropRotation.menuReconcileQueue = nil
        return
    end
    queue.index = queue.index + 1

    manager:invalidateActiveCropCache(farmlandId)
    local rotationChanged, completedCrops =
        manager:reconcileActiveCropForFarmland(farmlandId)
    local diseaseChanged = RealisticCropRotation.disease ~= nil
        and RealisticCropRotation.disease:applyCompletedCrops(farmlandId, completedCrops)
        or false
    if rotationChanged or diseaseChanged then
        queue.changed = true
    end
    if diseaseChanged then
        queue.diseaseChanged = true
    end

    local frame = RealisticCropRotation.frame
    if frame ~= nil then
        frame:onMenuReconcileFarmland(farmlandId)
    end

    if queue.index > #queue.farmlandIds then
        RealisticCropRotation.menuReconcileQueue = nil
        if queue.diseaseChanged and RealisticCropRotation.disease ~= nil then
            RealisticCropRotation.disease:refreshRiskMap(false)
        end
        if frame ~= nil then
            frame:onMenuReconcileComplete(queue.changed)
        end
        RealisticCropRotation.requestBroadcast()
    end
end

---Broadcasts the current rotation snapshot to every connected client.
local function flushRealisticCropRotationBroadcast()
    RealisticCropRotation.broadcastDirty = false
    RealisticCropRotation.broadcastTimerMs = 0
    if g_server ~= nil then
        g_server:broadcastEvent(RCRHistoryResponseEvent.new(), false)
    end
end

local refreshRealisticCropRotationFrame

---Clears the rotation plan when a farmland changes owner (not on savegame load).
-- @param integer farmlandId Farmland whose owner changed
-- @param integer _farmId New owner farm id (unused)
-- @param boolean loadFromSavegame True when triggered by savegame load
local function onFarmlandOwnerChanged(farmlandId, _farmId, loadFromSavegame)
    if loadFromSavegame then return end

    local changed = RealisticCropRotation.manager:clearRotationPlan(farmlandId)
    if changed then
        refreshRealisticCropRotationFrame()
        RealisticCropRotation.requestBroadcast()
    end

    -- Ownership changed: repaint the risk map so bought and sold fields match their new visibility.
    RealisticCropRotation.disease:refreshRiskMap(true)
end

---Reconciles active crops and evaluates disease infection for owned farmlands on a period change.
local function onPeriodChanged()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end

    local environment = g_currentMission.environment
    local changed = RealisticCropRotation.disease:advanceCalendar(
        environment ~= nil and environment.currentYear or nil)
    if RealisticCropRotationTreatmentLifecycle.onPeriodChanged() then
        changed = true
    end
    local diseaseUpdated = false
    for _, farmlandId in ipairs(RealisticCropRotation.manager:getOwnedRotationFarmlandIds()) do
        local rotationChanged, completedCrops =
            RealisticCropRotation.manager:reconcileActiveCropForFarmland(farmlandId)
        if rotationChanged then
            changed = true
        end
        if RealisticCropRotation.disease:applyCompletedCrops(farmlandId, completedCrops) then
            changed = true
        end
        -- Infection rolls run per period; severity and destruction progress daily.
        RealisticCropRotation.disease:evaluateInfection(farmlandId)
        diseaseUpdated = true
    end

    if changed then
        refreshRealisticCropRotationFrame()
    end
    if changed or diseaseUpdated then
        RealisticCropRotation.requestBroadcast()
    end

    RealisticCropRotation.disease:refreshRiskMap(false)
end

---Queues daily disease progression for incremental processing across frames.
local function onDayChanged()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    RealisticCropRotation.disease:enqueueDailyProgress()
end

---Refreshes the open history or planning frame after authoritative state changes.
function refreshRealisticCropRotationFrame()
    if RealisticCropRotation.frame == nil then return end
    RealisticCropRotation.frame:onServerSyncReceived()
end

---Forces the tab-list alignment offset back to zero after inserting the custom page.
local function applyTabListAlignmentFix()
    if RealisticCropRotation.tabListFixApplied then return end
    if InGameMenu == nil or InGameMenu.rebuildTabList == nil then return end

    InGameMenu.rebuildTabList = Utils.prependedFunction(InGameMenu.rebuildTabList, function(self)
        if self.pagingTabList ~= nil then
            self.pagingTabList.listItemAlignmentOffset = 0
        end
    end)

    RealisticCropRotation.tabListFixApplied = true
end

---Injects the RealisticCropRotationFrame as a tab in the InGameMenu paging element.
-- @param string frameFieldName Field name to expose on the menu
-- @param function predicateFunc Page visibility predicate
-- @param number|string insertPosition Insert index, or sibling field name to insert after
-- @return table frame The registered frame, or nil on failure
function RealisticCropRotation.addInGameMenuPage(frameFieldName, predicateFunc, insertPosition)
    if g_inGameMenu == nil then return nil end

    applyTabListAlignmentFix()

    local frameRefPath = RealisticCropRotation.modDirectory .. "gui/RealisticCropRotationFrameRef.xml"
    local xmlFile = loadXMLFile("RealisticCropRotationFrameRefXML", frameRefPath)
    if xmlFile == nil or xmlFile == 0 then
        Logging.error("[RealisticCropRotation] Failed to load FrameReference XML: %s", tostring(frameRefPath))
        return nil
    end

    g_inGameMenu.controlIDs[frameFieldName] = nil
    g_gui:loadGuiRec(xmlFile, "FrameReferences", g_inGameMenu.pagingElement, g_inGameMenu)
    g_inGameMenu:exposeControlsAsFields(frameFieldName)
    g_inGameMenu.pagingElement:updatePageMapping()
    delete(xmlFile)

    local frame = g_gui:resolveFrameReference(g_inGameMenu[frameFieldName])
    if frame == nil then
        Logging.error("[RealisticCropRotation] Could not resolve frame reference '%s'", tostring(frameFieldName))
        return nil
    end

    local targetPosition = #g_inGameMenu.pageFrames + 1

    if type(insertPosition) == "number" then
        targetPosition = math.max(1, math.min(#g_inGameMenu.pageFrames + 1, insertPosition))
    elseif type(insertPosition) == "string" then
        for i, child in ipairs(g_inGameMenu.pageFrames) do
            if child == g_inGameMenu[insertPosition] then
                targetPosition = math.min(#g_inGameMenu.pageFrames + 1, i + 1)
                break
            end
        end
    end

    g_inGameMenu[frameFieldName] = frame
    g_inGameMenu.pagingElement:removePageByElement(frame)

    local _, actualPosition = g_inGameMenu:registerPage(frame, targetPosition, predicateFunc)
    g_inGameMenu:addPageTab(frame, nil, nil, "realisticCropRotation.menuIcon")
    g_inGameMenu.pagingElement:addPage(string.upper(frameFieldName), frame, g_i18n:getText("realisticCropRotation_menu_title"), actualPosition)
    frame:onGuiSetupFinished()

    g_inGameMenu.pagingElement:updateAbsolutePosition()
    g_inGameMenu.pagingElement:updatePageMapping()
    g_inGameMenu:rebuildTabList()

    return frame
end

---Resolves the current savegame folder and ensures it has a trailing separator.
-- @return string path Savegame folder path, or nil when unavailable
local function resolveSavegameFolderPath()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then return nil end
    local path = g_currentMission.missionInfo.savegameDirectory
    if path == nil then
        local idx = g_currentMission.missionInfo.savegameIndex
        if idx ~= nil and getUserProfileAppPath ~= nil then
            path = ("%ssavegame%d"):format(getUserProfileAppPath(), idx)
        end
    end
    if path == nil or path == "" then return nil end
    local lastChar = path:sub(-1)
    if lastChar ~= "/" and lastChar ~= "\\" then path = path .. "/" end
    return path
end

---Loads GUI profiles and the menu icon texture configuration once.
local function loadGuiAssets()
    if g_gui == nil or type(g_gui.loadProfiles) ~= "function" then return end

    if not RealisticCropRotation.guiProfilesLoaded then
        g_gui:loadProfiles(RealisticCropRotation.modDirectory .. "gui/guiProfiles.xml")
        RealisticCropRotation.guiProfilesLoaded = true
    end

    if g_overlayManager ~= nil
        and (g_overlayManager.textureConfigs == nil
            or g_overlayManager.textureConfigs.realisticCropRotation == nil) then
        g_overlayManager:addTextureConfigFile(
            RealisticCropRotation.modDirectory .. "images/gui.xml",
            "realisticCropRotation")
    end
end

---Creates and registers treatment maps while the mission density-map synchronizer accepts maps.
local function initDiseaseTerrain(mission)
    if mission == nil or RealisticCropRotation.grid ~= nil then return end

    RealisticCropRotation.grid = RealisticCropRotationDiseaseGrid.new()
    local savegameFolderPath = mission:getIsServer() and resolveSavegameFolderPath() or nil
    RealisticCropRotation.grid:loadMap(savegameFolderPath, mission.densityMapSyncer)
end

---Builds runtime services, loads persisted state and registers mission listeners.
local function loadedMission()
    RealisticCropRotation.menuReconcileQueue = nil
    RealisticCropRotation.lastMenuReconcileMs = nil

    -- Reload crop config here to guarantee the engine XML API is fully ready.
    if RealisticCropRotation.cropConfig == nil then
        RealisticCropRotation.cropConfig = loadCropConfig()
    end

    loadGuiAssets()
    -- Wires RCR sprayer products; without this, Sprayer:onStartWorkAreaProcessing() gets a nil sprayType and aborts.
    RealisticCropRotationSprayerProducts.onMissionLoaded()

    RealisticCropRotation.manager = RealisticCropRotationManager.new()
    RealisticCropRotation.manager:initialize()

    initDiseaseTerrain(g_currentMission)
    RealisticCropRotation.disease = RealisticCropRotationDisease.new(RealisticCropRotation.manager, RealisticCropRotation.grid)
    RealisticCropRotation.disease:registerConsoleCommands()

    local savegameFolderPath = resolveSavegameFolderPath()

    if g_currentMission:getIsServer() then
        RealisticCropRotation.manager:loadFromXML(savegameFolderPath)
        RealisticCropRotation.disease:loadFromXML(savegameFolderPath)
        local environment = g_currentMission.environment
        RealisticCropRotation.disease:advanceCalendar(
            environment ~= nil and environment.currentYear or nil)
        -- Paint the initial risk map during loading, never on menu open.
        RealisticCropRotation.disease:refreshRiskMap(true)
        RealisticCropRotationTreatmentLifecycle.loadFromXML(savegameFolderPath)
        if g_messageCenter ~= nil and MessageType ~= nil and MessageType.FARMLAND_OWNER_CHANGED ~= nil then
            RealisticCropRotation.farmlandOwnerChangeListener = {
                ownerChanged = function(_self, farmlandId, farmId, loadFromSavegame)
                    onFarmlandOwnerChanged(farmlandId, farmId, loadFromSavegame)
                end,
            }
            g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED,
                RealisticCropRotation.farmlandOwnerChangeListener.ownerChanged,
                RealisticCropRotation.farmlandOwnerChangeListener)
        else
            Logging.warning("[RealisticCropRotation] Farmland owner listener unavailable; rotation plans cannot be cleared on sale")
        end
        if g_messageCenter ~= nil and MessageType ~= nil and MessageType.PERIOD_CHANGED ~= nil then
            RealisticCropRotation.periodChangedListener = {
                periodChanged = function(_self)
                    onPeriodChanged()
                end,
            }
            g_messageCenter:subscribe(MessageType.PERIOD_CHANGED,
                RealisticCropRotation.periodChangedListener.periodChanged,
                RealisticCropRotation.periodChangedListener)
        else
            Logging.warning("[RealisticCropRotation] Period change listener unavailable; crop rotation history cannot be reconciled automatically")
        end
        if g_messageCenter ~= nil and MessageType ~= nil and MessageType.DAY_CHANGED ~= nil then
            RealisticCropRotation.dayChangedListener = {
                dayChanged = function(_self)
                    onDayChanged()
                end,
            }
            g_messageCenter:subscribe(MessageType.DAY_CHANGED,
                RealisticCropRotation.dayChangedListener.dayChanged,
                RealisticCropRotation.dayChangedListener)
        else
            Logging.warning("[RealisticCropRotation] Day change listener unavailable; disease will not progress day by day")
        end
        RealisticCropRotationNitrogen.install(RealisticCropRotation.manager)
    end

    -- GIANTS runs cutter/mower density-map work on the server and nearby clients; mirror both paths so map coverage updates immediately.
    RealisticCropRotationTreatmentLifecycle.install()

    g_currentMission.realisticCropRotationManager = RealisticCropRotation.manager

    if g_currentMission:getIsServer() and type(g_currentMission.addUpdateable) == "function" then
        RealisticCropRotation.broadcastUpdateable = {
            update = function(_self, dt)
                -- Menu reconciliation is authoritative and limited to one farmland per frame.
                processMenuReconcileQueue()
                -- Daily disease work is also drained incrementally to keep frame time bounded.
                RealisticCropRotation.disease:processDailyQueue()
                if not RealisticCropRotation.broadcastDirty then return end
                RealisticCropRotation.broadcastTimerMs = (RealisticCropRotation.broadcastTimerMs or 0) - (dt or 0)
                if RealisticCropRotation.broadcastTimerMs <= 0 then
                    flushRealisticCropRotationBroadcast()
                end
            end,
        }
        g_currentMission:addUpdateable(RealisticCropRotation.broadcastUpdateable)
    end

    if not g_currentMission:getIsServer() then
        if RealisticCropRotation.pendingSyncData ~= nil then
            local pending = RealisticCropRotation.pendingSyncData
            RealisticCropRotation.manager.service:applySyncData(
                pending.history or {},
                pending.plans or {},
                pending.coverPlans or {},
                pending.lastKnownActiveCrop or {},
                pending.lastKnownGrowthState or {})
            RealisticCropRotation.disease:applySyncData(
                pending.diseaseState or {},
                pending.diseaseCrop or {},
                pending.diseaseReservoir or {})
            RealisticCropRotationTreatmentLifecycle.applySyncData(pending.nematicideCountdown or {})
            RealisticCropRotation.pendingSyncData = nil
        end
        -- The server already pushes the initial snapshot through FSBaseMission.sendInitialClientState.
        -- The menu requests later refreshes, after event ids are ready.
    end

    if g_currentMission:getIsClient()
        and RealisticCropRotationDiseaseMap ~= nil
        and not RealisticCropRotationDiseaseMap:tryHookHudInstance() then
        RealisticCropRotation.hudMapUpdateable = {
            update = function(updateable)
                if RealisticCropRotationDiseaseMap:tryHookHudInstance() then
                    g_currentMission:removeUpdateable(updateable)
                    RealisticCropRotation.hudMapUpdateable = nil
                end
            end,
        }
        g_currentMission:addUpdateable(RealisticCropRotation.hudMapUpdateable)
    end
end

---Builds the GUI page and menu tab once the in-game menu is available.
local function loadInGameMenuGui()
    if g_gui == nil or type(g_gui.loadProfiles) ~= "function" then return end
    if g_inGameMenu == nil then return end
    RealisticCropRotationDiseaseMap:install()

    if g_inGameMenu.pageRealisticCropRotation ~= nil then
        RealisticCropRotation.frame = g_inGameMenu.pageRealisticCropRotation
        return
    end

    loadGuiAssets()

    local frame = RealisticCropRotationFrame.new(g_i18n, g_messageCenter)
    g_gui:loadGui(RealisticCropRotation.modDirectory .. "gui/RealisticCropRotationFrame.xml",
                  "RealisticCropRotationFrame", frame, true)

    local inGameMenuFrame = RealisticCropRotation.addInGameMenuPage(
        "pageRealisticCropRotation",
        function() return true end,
        "pageCalendar")

    if inGameMenuFrame ~= nil then
        RealisticCropRotation.frame = inGameMenuFrame
        inGameMenuFrame:initialize()
    else
        RealisticCropRotation.frame = frame
        frame:initialize()
    end
end

---Persists server-side rotation, treatment and disease state with the savegame.
local function onSaveToXMLFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then return end
    if not g_currentMission:getIsServer() then return end
    if RealisticCropRotation.manager == nil then return end

    local savegameFolderPath = resolveSavegameFolderPath()
    RealisticCropRotation.manager:saveToXML(savegameFolderPath)
    if RealisticCropRotation.grid ~= nil then
        RealisticCropRotation.grid:saveMap(savegameFolderPath)
    end
    if RealisticCropRotation.disease ~= nil then
        RealisticCropRotation.disease:saveToXML(savegameFolderPath)
    end
    RealisticCropRotationTreatmentLifecycle.saveToXML(savegameFolderPath)
end

---Sends the initial rotation snapshot to a joining client (server).
-- @param table _self FSBaseMission instance (unused)
-- @param Connection connection Joining client connection
local function sendInitialClientState(_self, connection)
    if g_server == nil then return end
    if connection == nil then return end
    if RealisticCropRotation.manager == nil then return end
    connection:sendEvent(RCRHistoryResponseEvent.new())
end

---Loads configuration and installs the mission and menu hooks for the mod.
local function initRealisticCropRotation()
    RealisticCropRotation.cropConfig = loadCropConfig()

    RealisticCropRotationSprayerProducts.registerMaterialHolder(modDirectory)

    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)
    FSBaseMission.initTerrain = Utils.appendedFunction(FSBaseMission.initTerrain, initDiseaseTerrain)

    InGameMenu.onLoadMapFinished = Utils.appendedFunction(InGameMenu.onLoadMapFinished, function(_inGameMenu)
        loadInGameMenuGui()
    end)

    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, onSaveToXMLFile)
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, sendInitialClientState)

    RealisticCropRotationDiseaseMap:install()

    BaseMission.delete = Utils.appendedFunction(BaseMission.delete, function()
        if g_currentMission ~= nil and RealisticCropRotation.broadcastUpdateable ~= nil
            and type(g_currentMission.removeUpdateable) == "function" then
            g_currentMission:removeUpdateable(RealisticCropRotation.broadcastUpdateable)
        end
        if g_currentMission ~= nil and RealisticCropRotation.hudMapUpdateable ~= nil
            and type(g_currentMission.removeUpdateable) == "function" then
            g_currentMission:removeUpdateable(RealisticCropRotation.hudMapUpdateable)
        end
        if g_messageCenter ~= nil and RealisticCropRotation.farmlandOwnerChangeListener ~= nil then
            g_messageCenter:unsubscribeAll(RealisticCropRotation.farmlandOwnerChangeListener)
        end
        if g_messageCenter ~= nil and RealisticCropRotation.periodChangedListener ~= nil then
            g_messageCenter:unsubscribeAll(RealisticCropRotation.periodChangedListener)
        end
        if g_messageCenter ~= nil and RealisticCropRotation.dayChangedListener ~= nil then
            g_messageCenter:unsubscribeAll(RealisticCropRotation.dayChangedListener)
        end
        RealisticCropRotation.broadcastUpdateable = nil
        RealisticCropRotation.hudMapUpdateable = nil
        RealisticCropRotation.menuReconcileQueue = nil
        RealisticCropRotation.lastMenuReconcileMs = nil
        RealisticCropRotation.farmlandOwnerChangeListener = nil
        RealisticCropRotation.periodChangedListener = nil
        RealisticCropRotation.dayChangedListener = nil
        RealisticCropRotation.broadcastDirty = false
        RealisticCropRotation.broadcastTimerMs = 0

        RealisticCropRotationNitrogen.delete()
        RealisticCropRotationSoilUptake.delete()
        RealisticCropRotationTreatmentLifecycle.delete()
        RealisticCropRotationDiseaseMap:delete()
        if RealisticCropRotation.disease ~= nil then
            RealisticCropRotation.disease:unregisterConsoleCommands()
        end
        if RealisticCropRotation.manager ~= nil then
            RealisticCropRotation.manager:cleanup()
            RealisticCropRotation.manager = nil
        end
        if RealisticCropRotation.disease ~= nil then
            RealisticCropRotation.disease = nil
        end
        if RealisticCropRotation.grid ~= nil then
            RealisticCropRotation.grid:deleteMap()
            RealisticCropRotation.grid = nil
        end
        if g_currentMission ~= nil then
            g_currentMission.realisticCropRotationManager = nil
        end
        RealisticCropRotation.frame = nil
        RealisticCropRotation.pendingSyncData = nil
        RealisticCropRotationSprayerProducts.onMissionDeleted()
    end)
end

initRealisticCropRotation()
