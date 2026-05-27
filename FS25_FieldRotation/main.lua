-- Copyright © 2026 Squallqt. All rights reserved.
-- Mod bootstrap: source loading, mission lifecycle hooks, density-map hooks,
-- broadcast coalescing, period-change reset.
local modDirectory = g_currentModDirectory
local modName = g_currentModName

source(modDirectory .. "scripts/FieldRotationRepository.lua")
source(modDirectory .. "scripts/FieldRotationService.lua")
source(modDirectory .. "scripts/FieldRotationManager.lua")
source(modDirectory .. "scripts/FieldRotationHud.lua")
source(modDirectory .. "events/FRHistoryRequestEvent.lua")
source(modDirectory .. "events/FRHistoryResponseEvent.lua")
source(modDirectory .. "events/FRPlanUpdateEvent.lua")
source(modDirectory .. "gui/FieldRotationFrame.lua")

FieldRotation = {}
FieldRotation.modDirectory = modDirectory
FieldRotation.modName = modName
FieldRotation.manager = nil
FieldRotation.frame = nil
FieldRotation.pendingSyncData = nil
FieldRotation.isEnabled = true
FieldRotation.cropConfig = nil

-- Loads cropConfig.xml once at mod init.
-- Returns a config table: { families, nitrogen, coverCrops }
local function loadCropConfig()
    local filePath = modDirectory .. "cropConfig.xml"
    local xmlFile = loadXMLFile("FieldRotationCropConfig", filePath)
    if xmlFile == nil or xmlFile == 0 then
        Logging.error("[FieldRotation] Failed to load cropConfig.xml at %s", tostring(filePath))
        return nil
    end

    local config = { families = {}, nitrogen = {}, coverCrops = {} }
    local i = 0
    while true do
        local key = string.format("fieldRotationCrops.crop(%d)", i)
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
            if cover   then config.coverCrops[name] = true end
        end
        i = i + 1
    end

    delete(xmlFile)
    Logging.info("[FieldRotation] cropConfig.xml loaded: %d crops", i)
    return config
end

-- Broadcast coalescing: hooks request a broadcast instead of emitting one
-- per density-map change. Period changes are handled through GIANTS' message
-- center, matching the local gameSource pattern.
FieldRotation.BROADCAST_DEBOUNCE_MS = 500
FieldRotation.broadcastDirty = false
FieldRotation.broadcastTimerMs = 0
FieldRotation.broadcastUpdateable = nil
FieldRotation.periodChangeListener = nil
FieldRotation.lastObservedPeriod = 0
FieldRotation.lastObservedYear = 0

function FieldRotation.requestBroadcast()
    if g_server == nil then return end
    FieldRotation.broadcastDirty = true
    FieldRotation.broadcastTimerMs = FieldRotation.BROADCAST_DEBOUNCE_MS
end

function FieldRotation.requestServerSync(_reason)
    if g_client == nil or FRHistoryRequestEvent == nil then return end
    if type(g_client.getServerConnection) ~= "function" then return end
    local connection = g_client:getServerConnection()
    if connection ~= nil then
        connection:sendEvent(FRHistoryRequestEvent.new())
    end
end

local function flushFieldRotationBroadcast()
    FieldRotation.broadcastDirty = false
    FieldRotation.broadcastTimerMs = 0
    if g_server ~= nil and FRHistoryResponseEvent ~= nil then
        g_server:broadcastEvent(FRHistoryResponseEvent.new(), false)
    end
end

local refreshFieldRotationFrame

local function checkPeriodChange()
    if g_currentMission == nil or g_currentMission.environment == nil then return end
    local environment = g_currentMission.environment
    local currentPeriod = g_currentMission.environment.currentPeriod or 0
    local service = FieldRotation.manager ~= nil and FieldRotation.manager.service or nil
    local currentYear = service ~= nil and type(service.getCurrentYear) == "function"
        and service:getCurrentYear()
        or (tonumber(environment.currentYear) or 0)

    if currentYear > 0 and FieldRotation.lastObservedYear > 0
        and currentYear ~= FieldRotation.lastObservedYear then
        if currentYear ~= FieldRotation.lastObservedYear + 1 then
            Logging.warning("[FieldRotation] Year jump detected from %d to %d",
                FieldRotation.lastObservedYear, currentYear)
        end
        FieldRotation.lastObservedYear = currentYear
    elseif currentYear > 0 and FieldRotation.lastObservedYear == 0 then
        FieldRotation.lastObservedYear = currentYear
    end

    if currentPeriod == 0 then return end
    if currentPeriod ~= FieldRotation.lastObservedPeriod then
        FieldRotation.lastObservedPeriod = currentPeriod
        if FieldRotation.manager ~= nil and FieldRotation.manager.service ~= nil
            and type(FieldRotation.manager.service.resetNitrogenApplicationMaskForNewPeriod) == "function" then
            FieldRotation.manager.service:resetNitrogenApplicationMaskForNewPeriod()
        end
    end
end

function FieldRotation.consoleCommandToggle()
    FieldRotation.isEnabled = not FieldRotation.isEnabled
    local state = FieldRotation.isEnabled and "ENABLED" or "DISABLED"
    Logging.info("[FieldRotation] " .. state .. " via console")
    print("[FieldRotation] " .. state)
end

function refreshFieldRotationFrame()
    if FieldRotation.frame == nil then return end
    local frame = FieldRotation.frame
    -- Planning tab active (MP): only rebuild overview, never reset plan selectors.
    if type(frame.isHistoryTab) == "function" and not frame:isHistoryTab() then
        if type(frame.buildRotationGroups) == "function" then
            frame:buildRotationGroups()
        end
        if frame.listPlanOverview ~= nil then
            frame.listPlanOverview:reloadData()
        end
        if type(frame.updatePlanSlotVisualsFromSelectors) == "function" then
            frame:updatePlanSlotVisualsFromSelectors()
        end
    elseif frame.populateSidebar ~= nil then
        frame:populateSidebar()
    elseif frame.updateDetailPanel ~= nil then
        frame:updateDetailPanel(frame.selectedId)
    end
end

---Injects the FieldRotationFrame as a tab in the InGameMenu paging element.
function FieldRotation.addInGameMenuPage(frameFieldName, predicateFunc, insertPosition)
    if g_inGameMenu == nil then return nil end

    local frameRefPath = FieldRotation.modDirectory .. "gui/FieldRotationFrameRef.xml"
    local xmlFile = loadXMLFile("FieldRotationFrameRefXML", frameRefPath)
    if xmlFile == nil or xmlFile == 0 then
        Logging.error("[FieldRotation] Failed to load FrameReference XML: %s", tostring(frameRefPath))
        return nil
    end

    g_inGameMenu.controlIDs[frameFieldName] = nil
    g_gui:loadGuiRec(xmlFile, "FrameReferences", g_inGameMenu.pagingElement, g_inGameMenu)
    g_inGameMenu:exposeControlsAsFields(frameFieldName)
    g_inGameMenu.pagingElement:updatePageMapping()
    delete(xmlFile)

    local frame = g_gui:resolveFrameReference(g_inGameMenu[frameFieldName])
    if frame == nil then
        Logging.error("[FieldRotation] Could not resolve frame reference '%s'", tostring(frameFieldName))
        return nil
    end

    local targetPosition = #g_inGameMenu.pagingElement.elements + 1

    if type(insertPosition) == "number" then
        targetPosition = math.max(1, math.min(insertPosition, targetPosition))
    elseif type(insertPosition) == "string" then
        for i = 1, #g_inGameMenu.pagingElement.elements do
            local child = g_inGameMenu.pagingElement.elements[i]
            if child == g_inGameMenu[insertPosition] then
                targetPosition = i + 1
                break
            end
        end
    end

    g_inGameMenu:registerPage(frame, nil, predicateFunc)
    g_inGameMenu:addPageTab(frame, nil, nil, "fieldRotation.menuIcon")
    frame:onGuiSetupFinished()

    for i, element in ipairs(g_inGameMenu.pagingElement.elements) do
        if element == frame then
            if i ~= targetPosition then
                table.remove(g_inGameMenu.pagingElement.elements, i)
                table.insert(g_inGameMenu.pagingElement.elements, targetPosition, element)
            end
            break
        end
    end
    for i, page in ipairs(g_inGameMenu.pagingElement.pages) do
        if page.element == frame then
            if i ~= targetPosition then
                table.remove(g_inGameMenu.pagingElement.pages, i)
                table.insert(g_inGameMenu.pagingElement.pages, targetPosition, page)
            end
            break
        end
    end
    for i, pageFrame in ipairs(g_inGameMenu.pageFrames) do
        if pageFrame == frame then
            if i ~= targetPosition then
                table.remove(g_inGameMenu.pageFrames, i)
                table.insert(g_inGameMenu.pageFrames, targetPosition, pageFrame)
            end
            break
        end
    end

    g_inGameMenu.pagingElement:updateAbsolutePosition()
    g_inGameMenu.pagingElement:updatePageMapping()
    g_inGameMenu:rebuildTabList()

    return frame
end

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

local function loadedMission()
    -- Reload crop config here to guarantee the engine XML API is fully ready.
    if FieldRotation.cropConfig == nil then
        FieldRotation.cropConfig = loadCropConfig()
    end

    FieldRotation.manager = FieldRotationManager.new()
    FieldRotation.manager:initialize()

    local savegameFolderPath = resolveSavegameFolderPath()

    if g_currentMission:getIsServer() then
        FieldRotation.manager:loadFromXML(savegameFolderPath)
        if g_currentMission.environment ~= nil then
            FieldRotation.lastObservedPeriod = g_currentMission.environment.currentPeriod or 0
            if FieldRotation.manager.service ~= nil
                and type(FieldRotation.manager.service.getCurrentYear) == "function" then
                FieldRotation.lastObservedYear = FieldRotation.manager.service:getCurrentYear()
            else
                FieldRotation.lastObservedYear = tonumber(g_currentMission.environment.currentYear) or 0
            end
        end
        if g_messageCenter ~= nil and MessageType ~= nil and MessageType.PERIOD_CHANGED ~= nil then
            FieldRotation.periodChangeListener = {
                periodChanged = function()
                    checkPeriodChange()
                end,
            }
            g_messageCenter:subscribe(MessageType.PERIOD_CHANGED,
                FieldRotation.periodChangeListener.periodChanged,
                FieldRotation.periodChangeListener)
        else
            Logging.warning("[FieldRotation] Period change listener unavailable; nitrogen mask period reset disabled")
        end
    end

    g_currentMission.fieldRotationManager = FieldRotation.manager

    if g_currentMission:getIsServer() and type(g_currentMission.addUpdateable) == "function" then
        FieldRotation.broadcastUpdateable = {
            update = function(_self, dt)
                if not FieldRotation.broadcastDirty then return end
                FieldRotation.broadcastTimerMs = (FieldRotation.broadcastTimerMs or 0) - (dt or 0)
                if FieldRotation.broadcastTimerMs <= 0 then
                    flushFieldRotationBroadcast()
                end
            end,
        }
        g_currentMission:addUpdateable(FieldRotation.broadcastUpdateable)
    end

    if not g_currentMission:getIsServer() then
        if FieldRotation.pendingSyncData ~= nil then
            local pending = FieldRotation.pendingSyncData
            FieldRotation.manager.service:applySyncData(pending.history or {}, pending.plans or {})
            FieldRotation.pendingSyncData = nil
        end
        FieldRotation.requestServerSync("loadedMission")
    end

    -- GUI: profiles + icon slice + frame + InGameMenu tab injection.
    -- Skipped on dedicated server (g_gui is nil there).
    if g_gui ~= nil and type(g_gui.loadProfiles) == "function" then
        g_gui:loadProfiles(FieldRotation.modDirectory .. "gui/guiProfiles.xml")

        if g_overlayManager ~= nil
            and (g_overlayManager.textureConfigs == nil
                 or g_overlayManager.textureConfigs.fieldRotation == nil) then
            g_overlayManager:addTextureConfigFile(
                FieldRotation.modDirectory .. "images/menuIcon.xml",
                "fieldRotation")
        end

        local frame = FieldRotationFrame.new(g_i18n, g_messageCenter)
        g_gui:loadGui(FieldRotation.modDirectory .. "gui/FieldRotationFrame.xml",
                      "FieldRotationFrame", frame, true)

        local inGameMenuFrame = FieldRotation.addInGameMenuPage(
            "pageFieldRotation",
            function() return true end,
            "pageCalendar")

        if inGameMenuFrame ~= nil then
            FieldRotation.frame = inGameMenuFrame
            inGameMenuFrame:initialize()
        else
            FieldRotation.frame = frame
            frame:initialize()
        end
    end
end

local function onSaveToXMLFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then return end
    if not g_currentMission:getIsServer() then return end
    if FieldRotation.manager == nil then return end

    local savegameFolderPath = resolveSavegameFolderPath()
    FieldRotation.manager:saveToXML(savegameFolderPath)
end

local function sendInitialClientState(_self, connection)
    if g_server == nil then return end
    if connection == nil then return end
    if FieldRotation.manager == nil then return end
    connection:sendEvent(FRHistoryResponseEvent.new())
end

-- =========================================================================
-- Density-map destroy/sow hooks.
-- =========================================================================
--
-- One server-side path per hook:
--   1. Cheap farmland lookup (1 call).
--   2. Sample the pre-operation fruit type at the work area center.
--   3. Resolve active crop only when history can still change; cover-crop
--      nitrogen can still apply even after history was recorded this period.
--   4. Call the engine.
--   5. Push to history (server) if a real harvest/termination happened.
--   6. Apply the pending nitrogen residue inside the worked area.

local function getFarmlandIdAtArea(xw, xh, zw, zh)
    if g_farmlandManager == nil then return nil end
    local sampleX = (xw + xh) * 0.5
    local sampleZ = (zw + zh) * 0.5
    if type(g_farmlandManager.getFarmlandIdAtWorldPosition) == "function" then
        return g_farmlandManager:getFarmlandIdAtWorldPosition(sampleX, sampleZ)
    end
    if type(g_farmlandManager.getFarmlandAtWorldPosition) == "function" then
        return g_farmlandManager:getFarmlandAtWorldPosition(sampleX, sampleZ)
    end
    return nil
end

local function getFruitTypeIndexAtArea(xw, xh, zw, zh)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then return nil end
    local sampleX = (xw + xh) * 0.5
    local sampleZ = (zw + zh) * 0.5
    local idx = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(sampleX, sampleZ)
    if idx == nil or idx == FruitType.UNKNOWN then return nil end
    return idx
end

local function hasHookContext(farmlandId)
    if not FieldRotation.isEnabled then return false end
    if g_currentMission == nil or not g_currentMission:getIsServer() then return false end
    if FieldRotation.manager == nil or FieldRotation.manager.service == nil then return false end
    if farmlandId == nil or farmlandId == 0 then return false end
    return true
end

local function captureCropCandidate(farmlandId, currentPeriod, currentYear, xw, xh, zw, zh)
    local fruitTypeIndex = getFruitTypeIndexAtArea(xw, xh, zw, zh)
    if fruitTypeIndex == nil then return nil end

    local service = FieldRotation.manager.service
    local shouldResolveActiveCrop = true
    if type(service.hasRecordedThisPeriod) == "function"
        and service:hasRecordedThisPeriod(farmlandId, currentPeriod, currentYear) then
        shouldResolveActiveCrop = false
    end
    if type(service.isCoverCropForRotationHistory) == "function"
        and service:isCoverCropForRotationHistory(fruitTypeIndex, nil) then
        shouldResolveActiveCrop = false
    end

    local activeCropName = nil
    if shouldResolveActiveCrop
        and FieldRotation.manager ~= nil
        and type(FieldRotation.manager.getActiveCropName) == "function" then
        activeCropName = FieldRotation.manager:getActiveCropName(farmlandId)
    end
    return {
        farmlandId = farmlandId,
        fruitTypeIndex = fruitTypeIndex,
        activeCropName = activeCropName,
    }
end

local function recordTermination(sourceName, changedArea, cropCandidate)
    if cropCandidate == nil or changedArea == nil or changedArea <= 0 then return end
    if FieldRotation.manager == nil or FieldRotation.manager.service == nil then return end

    local changed = FieldRotation.manager.service:onCropTerminated(
        cropCandidate.farmlandId,
        cropCandidate.fruitTypeIndex,
        sourceName,
        cropCandidate.activeCropName)
    if changed then
        FieldRotation.manager:invalidateActiveCropCache(cropCandidate.farmlandId)
        refreshFieldRotationFrame()
        FieldRotation.requestBroadcast()
    end
end

local function applyTerminationNitrogen(sourceName, changedArea, xs, zs, xw, zw, xh, zh, farmlandId, cropCandidate)
    if changedArea == nil or changedArea <= 0 then return end
    local service = FieldRotation.manager.service
    if farmlandId == nil or farmlandId == 0 then return end

    local totalStateChange = service:getTerminationBonusStateChange(farmlandId)
    if cropCandidate ~= nil and cropCandidate.fruitTypeIndex ~= nil
        and type(service.getCoverCropTerminationStateChange) == "function" then
        totalStateChange = totalStateChange
            + service:getCoverCropTerminationStateChange(cropCandidate.fruitTypeIndex)
    end

    if totalStateChange <= 0 then return end
    service:applyNitrogenStateChangeAtArea(totalStateChange, xs, zs, xw, zw, xh, zh, sourceName)
end

local function wrapDensityMapDestroyHook(sourceName)
    return function(startWorldX, superFunc, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, ...)
        -- Always call the engine. Skip the mod work on early-out.
        local currentPeriod = (g_currentMission ~= nil and g_currentMission.environment ~= nil)
            and (g_currentMission.environment.currentPeriod or 0) or 0
        local farmlandId = getFarmlandIdAtArea(widthWorldX, heightWorldX, widthWorldZ, heightWorldZ)
        local shouldProcess = hasHookContext(farmlandId)
        local currentYear = shouldProcess and FieldRotation.manager.service:getCurrentYear() or 0

        local cropCandidate = nil
        if shouldProcess then
            cropCandidate = captureCropCandidate(farmlandId, currentPeriod, currentYear, widthWorldX, heightWorldX, widthWorldZ, heightWorldZ)
        end

        local changedArea, totalArea = superFunc(startWorldX, startWorldZ,
            widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, ...)

        if shouldProcess then
            recordTermination(sourceName, changedArea or 0, cropCandidate)
            applyTerminationNitrogen(sourceName, changedArea or 0,
                startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ,
                farmlandId, cropCandidate)
        end

        return changedArea, totalArea
    end
end

local function wrapDensityMapSowingHook(sourceName)
    return function(fruitIndex, superFunc, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, ...)
        local currentPeriod = (g_currentMission ~= nil and g_currentMission.environment ~= nil)
            and (g_currentMission.environment.currentPeriod or 0) or 0
        local farmlandId = getFarmlandIdAtArea(widthWorldX, heightWorldX, widthWorldZ, heightWorldZ)
        local shouldProcess = hasHookContext(farmlandId)
        local currentYear = shouldProcess and FieldRotation.manager.service:getCurrentYear() or 0

        local cropCandidate = nil
        if shouldProcess then
            cropCandidate = captureCropCandidate(farmlandId, currentPeriod, currentYear, widthWorldX, heightWorldX, widthWorldZ, heightWorldZ)
        end

        local changedArea, totalArea = superFunc(fruitIndex, startWorldX, startWorldZ,
            widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, ...)

        if shouldProcess then
            recordTermination(sourceName, changedArea or 0, cropCandidate)
            applyTerminationNitrogen(sourceName, changedArea or 0,
                startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ,
                farmlandId, cropCandidate)
        end

        return changedArea, totalArea
    end
end

-- =========================================================================
-- Init.
-- =========================================================================

local function initFieldRotation()
    FieldRotation.cropConfig = loadCropConfig()

    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, onSaveToXMLFile)
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, sendInitialClientState)

    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updateDestroyCommonArea ~= nil then
        FSDensityMapUtil.updateDestroyCommonArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updateDestroyCommonArea, wrapDensityMapDestroyHook("DESTROY_COMMON"))
    end
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updateCultivatorArea ~= nil then
        FSDensityMapUtil.updateCultivatorArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updateCultivatorArea, wrapDensityMapDestroyHook("CULTIVATOR"))
    end
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updateDiscHarrowArea ~= nil then
        FSDensityMapUtil.updateDiscHarrowArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updateDiscHarrowArea, wrapDensityMapDestroyHook("DISC_HARROW"))
    end
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updatePlowArea ~= nil then
        FSDensityMapUtil.updatePlowArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updatePlowArea, wrapDensityMapDestroyHook("PLOW"))
    end
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updateSowingArea ~= nil then
        FSDensityMapUtil.updateSowingArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updateSowingArea, wrapDensityMapSowingHook("SOWING"))
    end
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updateDirectSowingArea ~= nil then
        FSDensityMapUtil.updateDirectSowingArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updateDirectSowingArea, wrapDensityMapSowingHook("DIRECT_SOWING"))
    end

    BaseMission.delete = Utils.appendedFunction(BaseMission.delete, function()
        if g_currentMission ~= nil and FieldRotation.broadcastUpdateable ~= nil
            and type(g_currentMission.removeUpdateable) == "function" then
            g_currentMission:removeUpdateable(FieldRotation.broadcastUpdateable)
        end
        if g_messageCenter ~= nil and FieldRotation.periodChangeListener ~= nil then
            g_messageCenter:unsubscribeAll(FieldRotation.periodChangeListener)
        end
        FieldRotation.broadcastUpdateable = nil
        FieldRotation.periodChangeListener = nil
        FieldRotation.broadcastDirty = false
        FieldRotation.broadcastTimerMs = 0
        FieldRotation.lastObservedPeriod = 0
        FieldRotation.lastObservedYear = 0

        if FieldRotation.manager ~= nil then
            FieldRotation.manager:cleanup()
            FieldRotation.manager = nil
        end
        if g_currentMission ~= nil then
            g_currentMission.fieldRotationManager = nil
        end
        FieldRotation.frame = nil
        FieldRotation.pendingSyncData = nil
    end)

    addConsoleCommand("assolementToggle", "Enable / disable FieldRotation mod at runtime", "consoleCommandToggle", FieldRotation)
end

initFieldRotation()
