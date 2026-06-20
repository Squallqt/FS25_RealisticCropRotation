-- Copyright © 2026 Squallqt. All rights reserved.
-- Mod bootstrap: source loading, lifecycle + density-map hooks, broadcast coalescing.
local modDirectory = g_currentModDirectory
local modName = g_currentModName

source(modDirectory .. "scripts/RealisticCropRotationRepository.lua")
source(modDirectory .. "scripts/RealisticCropRotationService.lua")
source(modDirectory .. "scripts/RealisticCropRotationManager.lua")
source(modDirectory .. "scripts/RealisticCropRotationNitrogen.lua")
source(modDirectory .. "scripts/RealisticCropRotationHud.lua")
source(modDirectory .. "events/RCRHistoryRequestEvent.lua")
source(modDirectory .. "events/RCRHistoryResponseEvent.lua")
source(modDirectory .. "events/RCRPlanUpdateEvent.lua")
source(modDirectory .. "gui/RealisticCropRotationFrame.lua")

RealisticCropRotation = {}
RealisticCropRotation.modDirectory = modDirectory
RealisticCropRotation.modName = modName
RealisticCropRotation.manager = nil
RealisticCropRotation.frame = nil
RealisticCropRotation.pendingSyncData = nil
RealisticCropRotation.isEnabled = true
RealisticCropRotation.cropConfig = nil
RealisticCropRotation.guiProfilesLoaded = false
RealisticCropRotation.tabListFixApplied = false
RealisticCropRotation.SPECIAL_CROP_FALLOW = "__FALLOW"

function RealisticCropRotation.isFallowCrop(cropName)
    return cropName ~= nil
        and string.upper(tostring(cropName)) == RealisticCropRotation.SPECIAL_CROP_FALLOW
end

-- Loads cropConfig.xml once at mod init.
-- Returns a config table: { families, nitrogen, coverCrops }.
---Loads cropConfig.xml into a families/nitrogen/coverCrops table.
-- @return table config Crop config, or nil on failure
local function loadCropConfig()
    local filePath = modDirectory .. "cropConfig.xml"
    local xmlFile = loadXMLFile("RealisticCropRotationCropConfig", filePath)
    if xmlFile == nil or xmlFile == 0 then
        Logging.error("[RealisticCropRotation] Failed to load cropConfig.xml at %s", tostring(filePath))
        return nil
    end

    local config = { families = {}, nitrogen = {}, coverCrops = {} }
    local i = 0
    while true do
        local key = string.format("realisticCropRotationCrops.crop(%d)", i)
        if not hasXMLProperty(xmlFile, key) then break end

        local name    = getXMLString(xmlFile, key .. "#name")
        local family  = getXMLString(xmlFile, key .. "#family")
        local n1      = getXMLInt(xmlFile,    key .. "#n1") or 0
        local n2      = getXMLInt(xmlFile,    key .. "#n2") or 0
        local cover   = getXMLBool(xmlFile,   key .. "#cover") or false

        if name ~= nil and name ~= "" then
            name = string.upper(name)
            if family ~= nil and family ~= "" then
                config.families[name] = string.upper(family)
            end
            if n1 > 0 or n2 > 0 then
                config.nitrogen[name] = { n1 = n1, n2 = n2 }
            end
            if cover then config.coverCrops[name] = true end
        end
        i = i + 1
    end

    delete(xmlFile)
    Logging.info("[RealisticCropRotation] cropConfig.xml loaded: %d crops", i)
    return config
end

-- Broadcast coalescing: hooks request a broadcast instead of emitting one
-- per density-map change.
RealisticCropRotation.BROADCAST_DEBOUNCE_MS = 500
RealisticCropRotation.broadcastDirty = false
RealisticCropRotation.broadcastTimerMs = 0
RealisticCropRotation.broadcastUpdateable = nil
RealisticCropRotation.farmlandOwnerChangeListener = nil
RealisticCropRotation.periodChangedListener = nil

---Marks the rotation state dirty so a single coalesced broadcast fires soon (server).
function RealisticCropRotation.requestBroadcast()
    if g_server == nil then return end
    RealisticCropRotation.broadcastDirty = true
    RealisticCropRotation.broadcastTimerMs = RealisticCropRotation.BROADCAST_DEBOUNCE_MS
end

---Asks the server for a full rotation snapshot (client).
-- @param string _reason Diagnostic label (unused)
function RealisticCropRotation.requestServerSync(_reason)
    if g_client == nil or RCRHistoryRequestEvent == nil then return end
    if type(g_client.getServerConnection) ~= "function" then return end
    local connection = g_client:getServerConnection()
    if connection ~= nil then
        connection:sendEvent(RCRHistoryRequestEvent.new())
    end
end

---Broadcasts the rotation snapshot to all clients now (server).
local function flushRealisticCropRotationBroadcast()
    RealisticCropRotation.broadcastDirty = false
    RealisticCropRotation.broadcastTimerMs = 0
    if g_server ~= nil and RCRHistoryResponseEvent ~= nil then
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
    if RealisticCropRotation.manager == nil or type(RealisticCropRotation.manager.clearRotationPlan) ~= "function" then return end

    local changed = RealisticCropRotation.manager:clearRotationPlan(farmlandId)
    if changed then
        Logging.info("[RealisticCropRotation] Rotation plan cleared after farmland owner change: farmland=%s",
            tostring(farmlandId))
        refreshRealisticCropRotationFrame()
        RealisticCropRotation.requestBroadcast()
    end
end

---Reconciles active crops for all owned farmlands on a period change (server).
local function onPeriodChanged()
    if g_currentMission == nil or not g_currentMission:getIsServer() then return end
    if RealisticCropRotation.manager == nil
        or type(RealisticCropRotation.manager.getOwnedRotationFarmlandIds) ~= "function"
        or type(RealisticCropRotation.manager.reconcileActiveCropForFarmland) ~= "function" then
        return
    end

    local changed = false
    for _, farmlandId in ipairs(RealisticCropRotation.manager:getOwnedRotationFarmlandIds()) do
        if RealisticCropRotation.manager:reconcileActiveCropForFarmland(farmlandId) then
            changed = true
        end
    end

    if changed then
        refreshRealisticCropRotationFrame()
        RealisticCropRotation.requestBroadcast()
    end
end

---Refreshes the open menu frame after a state change (history or planning tab).
function refreshRealisticCropRotationFrame()
    if RealisticCropRotation.frame == nil then return end
    local frame = RealisticCropRotation.frame
    -- Planning tab active (MP): only rebuild overview, never reset calendar selectors.
    if type(frame.isHistoryTab) == "function" and not frame:isHistoryTab() then
        if type(frame.buildRotationGroups) == "function" then
            frame:buildRotationGroups()
        end
        if frame.listPlanOverview ~= nil then
            frame.listPlanOverview:reloadData()
        end
        if type(frame.updateCalendarVisualsFromSelectors) == "function" then
            frame:updateCalendarVisualsFromSelectors()
        end
    elseif frame.populateSidebar ~= nil then
        frame:populateSidebar()
    elseif frame.updateDetailPanel ~= nil then
        frame:updateDetailPanel(frame.selectedId)
    end
end

---Forces the tab-list alignment offset back to 0 (adding a tab leaves a stale offset).
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
-- @param string frameFieldName Field name exposed on g_inGameMenu
-- @param function predicateFunc Page visibility predicate
-- @param string|integer insertPosition Tab index, or a sibling page field name to insert after
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

---Resolves the current savegame folder path with a trailing slash.
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

---Loads GUI profiles + menu icon config (once). Skipped on dedicated server.
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

---Mission-load hook: builds the manager, loads/saves state, wires server listeners.
local function loadedMission()
    -- Reload crop config here to guarantee the engine XML API is fully ready.
    if RealisticCropRotation.cropConfig == nil then
        RealisticCropRotation.cropConfig = loadCropConfig()
    end

    loadGuiAssets()

    RealisticCropRotation.manager = RealisticCropRotationManager.new()
    RealisticCropRotation.manager:initialize()

    local savegameFolderPath = resolveSavegameFolderPath()

    if g_currentMission:getIsServer() then
        RealisticCropRotation.manager:loadFromXML(savegameFolderPath)
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
        RealisticCropRotationNitrogen.install(RealisticCropRotation.manager)
    end

    g_currentMission.realisticCropRotationManager = RealisticCropRotation.manager

    if g_currentMission:getIsServer() and type(g_currentMission.addUpdateable) == "function" then
        RealisticCropRotation.broadcastUpdateable = {
            update = function(_self, dt)
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
            RealisticCropRotation.pendingSyncData = nil
        end
        RealisticCropRotation.requestServerSync("loadedMission")
    end
end

---Builds the GUI page + menu tab once the in-game menu is ready (skipped on dedicated server).
local function loadInGameMenuGui()
    if g_gui == nil or type(g_gui.loadProfiles) ~= "function" then return end
    if g_inGameMenu == nil then return end

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

---Save hook: persists rotation state (server only).
local function onSaveToXMLFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then return end
    if not g_currentMission:getIsServer() then return end
    if RealisticCropRotation.manager == nil then return end

    local savegameFolderPath = resolveSavegameFolderPath()
    RealisticCropRotation.manager:saveToXML(savegameFolderPath)
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

---Mod entry point: loads config and installs the engine hooks.
local function initRealisticCropRotation()
    RealisticCropRotation.cropConfig = loadCropConfig()

    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)

    InGameMenu.onLoadMapFinished = Utils.appendedFunction(InGameMenu.onLoadMapFinished, function(_inGameMenu)
        loadInGameMenuGui()
    end)

    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, onSaveToXMLFile)
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, sendInitialClientState)

    BaseMission.delete = Utils.appendedFunction(BaseMission.delete, function()
        if g_currentMission ~= nil and RealisticCropRotation.broadcastUpdateable ~= nil
            and type(g_currentMission.removeUpdateable) == "function" then
            g_currentMission:removeUpdateable(RealisticCropRotation.broadcastUpdateable)
        end
        if g_messageCenter ~= nil and RealisticCropRotation.farmlandOwnerChangeListener ~= nil then
            g_messageCenter:unsubscribeAll(RealisticCropRotation.farmlandOwnerChangeListener)
        end
        if g_messageCenter ~= nil and RealisticCropRotation.periodChangedListener ~= nil then
            g_messageCenter:unsubscribeAll(RealisticCropRotation.periodChangedListener)
        end
        RealisticCropRotation.broadcastUpdateable = nil
        RealisticCropRotation.farmlandOwnerChangeListener = nil
        RealisticCropRotation.periodChangedListener = nil
        RealisticCropRotation.broadcastDirty = false
        RealisticCropRotation.broadcastTimerMs = 0

        if RealisticCropRotation.manager ~= nil then
            RealisticCropRotation.manager:cleanup()
            RealisticCropRotation.manager = nil
        end
        if g_currentMission ~= nil then
            g_currentMission.realisticCropRotationManager = nil
        end
        RealisticCropRotation.frame = nil
        RealisticCropRotation.pendingSyncData = nil
    end)
end

initRealisticCropRotation()
