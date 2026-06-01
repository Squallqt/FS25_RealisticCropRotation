-- Copyright © 2026 Squallqt. All rights reserved.
-- Mod bootstrap: source loading, mission lifecycle hooks, density-map hooks,
-- broadcast coalescing.
local modDirectory = g_currentModDirectory
local modName = g_currentModName

source(modDirectory .. "scripts/RealisticCropRotationRepository.lua")
source(modDirectory .. "scripts/RealisticCropRotationService.lua")
source(modDirectory .. "scripts/RealisticCropRotationManager.lua")
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

-- Loads cropConfig.xml once at mod init.
-- Returns a config table: { families, nitrogen, coverCrops }
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
            if cover   then config.coverCrops[name] = true end
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
RealisticCropRotation.directSowingResidueSessions = {}

function RealisticCropRotation.requestBroadcast()
    if g_server == nil then return end
    RealisticCropRotation.broadcastDirty = true
    RealisticCropRotation.broadcastTimerMs = RealisticCropRotation.BROADCAST_DEBOUNCE_MS
end

function RealisticCropRotation.requestServerSync(_reason)
    if g_client == nil or RCRHistoryRequestEvent == nil then return end
    if type(g_client.getServerConnection) ~= "function" then return end
    local connection = g_client:getServerConnection()
    if connection ~= nil then
        connection:sendEvent(RCRHistoryRequestEvent.new())
    end
end

local function flushRealisticCropRotationBroadcast()
    RealisticCropRotation.broadcastDirty = false
    RealisticCropRotation.broadcastTimerMs = 0
    if g_server ~= nil and RCRHistoryResponseEvent ~= nil then
        g_server:broadcastEvent(RCRHistoryResponseEvent.new(), false)
    end
end

local refreshRealisticCropRotationFrame

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

function refreshRealisticCropRotationFrame()
    if RealisticCropRotation.frame == nil then return end
    local frame = RealisticCropRotation.frame
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

---Injects the RealisticCropRotationFrame as a tab in the InGameMenu paging element.
function RealisticCropRotation.addInGameMenuPage(frameFieldName, predicateFunc, insertPosition)
    if g_inGameMenu == nil then return nil end

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
    g_inGameMenu:addPageTab(frame, nil, nil, "realisticCropRotation.menuIcon")
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
    if RealisticCropRotation.cropConfig == nil then
        RealisticCropRotation.cropConfig = loadCropConfig()
    end

    RealisticCropRotation.directSowingResidueSessions = {}
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
                pending.lastKnownActiveCrop or {},
                pending.appliedResidue or {})
            RealisticCropRotation.pendingSyncData = nil
        end
        RealisticCropRotation.requestServerSync("loadedMission")
    end

    -- GUI: profiles + icon slice + frame + InGameMenu tab injection.
    -- Skipped on dedicated server (g_gui is nil there).
    if g_gui ~= nil and type(g_gui.loadProfiles) == "function" then
        g_gui:loadProfiles(RealisticCropRotation.modDirectory .. "gui/guiProfiles.xml")

        if g_overlayManager ~= nil
            and (g_overlayManager.textureConfigs == nil
                 or g_overlayManager.textureConfigs.realisticCropRotation == nil) then
            g_overlayManager:addTextureConfigFile(
                RealisticCropRotation.modDirectory .. "images/menuIcon.xml",
                "realisticCropRotation")
        end

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
end

local function onSaveToXMLFile()
    if g_currentMission == nil or g_currentMission.missionInfo == nil then return end
    if not g_currentMission:getIsServer() then return end
    if RealisticCropRotation.manager == nil then return end

    local savegameFolderPath = resolveSavegameFolderPath()
    RealisticCropRotation.manager:saveToXML(savegameFolderPath)
end

local function sendInitialClientState(_self, connection)
    if g_server == nil then return end
    if connection == nil then return end
    if RealisticCropRotation.manager == nil then return end
    connection:sendEvent(RCRHistoryResponseEvent.new())
end

-- =========================================================================
-- Density-map destroy/sow hooks.
-- =========================================================================
--
-- One server-side path per hook:
--   1. Cheap farmland lookup (1 call).
--   2. Sample the pre-operation fruit type at the work area center.
--   3. Resolve active crop before mutation for cover-crop filtering.
--   4. Call the engine.
--   5. Push to history only after cumulative significant field area changed.
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

local function getFruitTypeIndexAtArea(xs, zs, xw, zw, xh, zh)
    if FSDensityMapUtil == nil or FSDensityMapUtil.getFruitTypeIndexAtWorldPos == nil then return nil end

    local samples = {
        { 0.50, 0.50 },
        { 0.25, 0.50 },
        { 0.75, 0.50 },
        { 0.50, 0.25 },
        { 0.50, 0.75 },
    }
    local counts = {}
    for _, sample in ipairs(samples) do
        local u, v = sample[1], sample[2]
        local sampleX = xs + (xw - xs) * u + (xh - xs) * v
        local sampleZ = zs + (zw - zs) * u + (zh - zs) * v
        local idx = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(sampleX, sampleZ)
        if idx ~= nil and idx ~= FruitType.UNKNOWN then
            counts[idx] = (counts[idx] or 0) + 1
        end
    end

    local bestIndex = nil
    local bestCount = 0
    for idx, count in pairs(counts) do
        if count > bestCount then
            bestIndex = idx
            bestCount = count
        end
    end
    return bestIndex
end

local function hasHookContext(farmlandId)
    if not RealisticCropRotation.isEnabled then return false end
    if g_currentMission == nil or not g_currentMission:getIsServer() then return false end
    if RealisticCropRotation.manager == nil or RealisticCropRotation.manager.service == nil then return false end
    if farmlandId == nil or farmlandId == 0 then return false end
    return true
end

local function captureCropCandidate(farmlandId, xs, zs, xw, zw, xh, zh)
    local service = RealisticCropRotation.manager.service
    local activeCropName = RealisticCropRotation.manager:getActiveCropName(farmlandId)
    local repository = service.repository
    local knownCropName = repository ~= nil and repository:getLastKnownActiveCrop(farmlandId) or nil

    -- Sample the active fruit inside the work area. When harvested stubble is sparse and the
    -- samples miss, fall back to the field's known active crop so tillage keeps depositing across
    -- the worked pass.
    local fruitTypeIndex = getFruitTypeIndexAtArea(xs, zs, xw, zw, xh, zh)
    if fruitTypeIndex == nil then
        local fallbackCropName = activeCropName
        if fallbackCropName == nil or fallbackCropName == "" then
            fallbackCropName = knownCropName
        end
        if fallbackCropName == nil or fallbackCropName == "" then return nil end

        local fruitType = service:getFruitTypeByCropName(fallbackCropName)
        if fruitType == nil or fruitType.index == nil then return nil end
        fruitTypeIndex = fruitType.index
        activeCropName = fallbackCropName
    end

    return {
        farmlandId = farmlandId,
        fruitTypeIndex = fruitTypeIndex,
        activeCropName = activeCropName,
        residueCycle = service:getResidueCycle(farmlandId),
    }
end

local DIRECT_SOWING_SESSION_TIMEOUT_MS = 30000

local function getFruitTypeDesc(fruitTypeIndex)
    if g_fruitTypeManager == nil or fruitTypeIndex == nil then return nil end
    if type(g_fruitTypeManager.getFruitTypeByIndex) ~= "function" then return nil end
    return g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
end

local function addResidueState(states, seenStates, state)
    local numericState = tonumber(state)
    if numericState == nil or numericState <= 0 or seenStates[numericState] then return end
    seenStates[numericState] = true
    table.insert(states, numericState)
end

local function getResidueGrowthStates(fruitType)
    local states = {}
    local seenStates = {}

    if type(fruitType.cutStates) == "table" then
        for state, isCut in pairs(fruitType.cutStates) do
            if isCut then addResidueState(states, seenStates, state) end
        end
    end

    addResidueState(states, seenStates, fruitType.cutState)

    if type(fruitType.harvestTransitions) == "table" then
        for _, state in pairs(fruitType.harvestTransitions) do
            addResidueState(states, seenStates, state)
        end
    end

    addResidueState(states, seenStates, fruitType.witheredState)
    return states
end

local function hasResidueFruitArea(fruitTypeIndex, xs, zs, xw, zw, xh, zh)
    if fruitTypeIndex == nil or fruitTypeIndex == FruitType.UNKNOWN then return false end
    if DensityMapModifier == nil or DensityMapFilter == nil
        or DensityValueCompareType == nil or DensityCoordType == nil then
        return false
    end

    local fruitType = getFruitTypeDesc(fruitTypeIndex)
    if fruitType == nil or fruitType.terrainDataPlaneId == nil
        or fruitType.startStateChannel == nil or fruitType.numStateChannels == nil then
        return false
    end

    local residueStates = getResidueGrowthStates(fruitType)
    if residueStates[1] == nil then return false end

    local terrainRootNode = g_currentMission ~= nil and g_currentMission.terrainRootNode or g_terrainNode
    local modifier = DensityMapModifier.new(
        fruitType.terrainDataPlaneId,
        fruitType.startStateChannel,
        fruitType.numStateChannels,
        terrainRootNode)
    modifier:setParallelogramWorldCoords(xs, zs, xw, zw, xh, zh, DensityCoordType.POINT_POINT_POINT)

    local filter = DensityMapFilter.new(
        fruitType.terrainDataPlaneId,
        fruitType.startStateChannel,
        fruitType.numStateChannels)

    for _, state in ipairs(residueStates) do
        filter:setValueCompareParams(DensityValueCompareType.EQUAL, state)
        local _, area = modifier:executeGet(filter)
        if (area or 0) > 0 then return true end
    end

    return false
end

local function makeCropCandidateFromFruitType(farmlandId, fruitTypeIndex, residueCycle)
    local service = RealisticCropRotation.manager.service
    local cropName = service:getCropNameByFruitTypeIndex(fruitTypeIndex)
    if cropName == nil or cropName == "" then return nil end

    return {
        farmlandId = farmlandId,
        fruitTypeIndex = fruitTypeIndex,
        activeCropName = cropName,
        residueCycle = residueCycle or service:getResidueCycle(farmlandId),
    }
end

local function makeCropCandidateFromCropName(farmlandId, cropName, residueCycle)
    if cropName == nil or cropName == "" then return nil end
    local service = RealisticCropRotation.manager.service
    local fruitType = service:getFruitTypeByCropName(cropName)
    if fruitType == nil or fruitType.index == nil then return nil end
    return makeCropCandidateFromFruitType(farmlandId, fruitType.index, residueCycle)
end

local function getDirectSowingSession(farmlandId)
    local sessions = RealisticCropRotation.directSowingResidueSessions
    if sessions == nil then return nil end

    local numericFarmlandId = tonumber(farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return nil end

    local session = sessions[numericFarmlandId]
    if session == nil then return nil end

    local nowMs = tonumber(g_time) or 0
    if nowMs > 0 and (nowMs - (tonumber(session.tMs) or 0)) > DIRECT_SOWING_SESSION_TIMEOUT_MS then
        sessions[numericFarmlandId] = nil
        return nil
    end
    return session
end

local function storeDirectSowingSession(cropCandidate)
    if cropCandidate == nil then return end
    local numericFarmlandId = tonumber(cropCandidate.farmlandId)
    if numericFarmlandId == nil or numericFarmlandId <= 0 then return end

    RealisticCropRotation.directSowingResidueSessions[numericFarmlandId] = {
        fruitTypeIndex = cropCandidate.fruitTypeIndex,
        activeCropName = cropCandidate.activeCropName,
        residueCycle = cropCandidate.residueCycle,
        tMs = tonumber(g_time) or 0,
    }
end

local function captureDirectSowingCropCandidate(farmlandId, xs, zs, xw, zw, xh, zh)
    local service = RealisticCropRotation.manager.service
    local currentCycle = service:getResidueCycle(farmlandId)

    local session = getDirectSowingSession(farmlandId)
    if session ~= nil and hasResidueFruitArea(session.fruitTypeIndex, xs, zs, xw, zw, xh, zh) then
        session.tMs = tonumber(g_time) or 0
        return makeCropCandidateFromFruitType(farmlandId, session.fruitTypeIndex, session.residueCycle)
    end

    local fruitTypeIndex = getFruitTypeIndexAtArea(xs, zs, xw, zw, xh, zh)
    if fruitTypeIndex ~= nil and hasResidueFruitArea(fruitTypeIndex, xs, zs, xw, zw, xh, zh) then
        local candidate = makeCropCandidateFromFruitType(farmlandId, fruitTypeIndex, currentCycle)
        storeDirectSowingSession(candidate)
        return candidate
    end

    local repository = service.repository
    local entries = repository ~= nil and repository:getHistoryNoAlloc(farmlandId) or nil
    local cropNames = {}
    local seenCropNames = {}
    local function addCropName(cropName)
        if cropName == nil or cropName == "" or seenCropNames[cropName] then return end
        seenCropNames[cropName] = true
        table.insert(cropNames, cropName)
    end

    local lastKnownCrop = repository ~= nil and repository:getLastKnownActiveCrop(farmlandId) or nil
    addCropName(lastKnownCrop)
    if entries ~= nil and entries[1] ~= nil and entries[1].crop ~= nil and entries[1].crop ~= "" then
        addCropName(entries[1].crop)
    end
    local activeCropName = RealisticCropRotation.manager:getActiveCropName(farmlandId)
    addCropName(activeCropName)

    for _, cropName in ipairs(cropNames) do
        local candidate = makeCropCandidateFromCropName(farmlandId, cropName, currentCycle)
        if candidate ~= nil
            and hasResidueFruitArea(candidate.fruitTypeIndex, xs, zs, xw, zw, xh, zh) then
            storeDirectSowingSession(candidate)
            return candidate
        end
    end

    return nil
end

local function recordTermination(changedArea, cropCandidate, nextActiveCropName)
    if cropCandidate == nil or changedArea == nil or changedArea <= 0 then return false end
    if RealisticCropRotation.manager == nil then return false end

    local changed = RealisticCropRotation.manager:recordCropChangeFromHook(
        changedArea,
        cropCandidate,
        nextActiveCropName)
    if changed then
        RealisticCropRotation.manager:invalidateActiveCropCache(cropCandidate.farmlandId)
        refreshRealisticCropRotationFrame()
        RealisticCropRotation.requestBroadcast()
    end
    return changed
end

-- Deposit the residue AFTER superFunc: the tool's own engine pass runs inside superFunc and
-- would overwrite a pre-deposit (the "nitrogen only when the tool drops, then nothing" bug).
-- The crop is captured before superFunc (still standing); applied on the worked area after.
local function depositResidueAfterTermination(cropCandidate, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
    if cropCandidate == nil then return false end
    return RealisticCropRotation.manager.service:applyNitrogenResidueAtArea(cropCandidate,
        startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
end

local function wrapDensityMapDestroyHook()
    return function(startWorldX, superFunc, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, ...)
        local farmlandId = getFarmlandIdAtArea(widthWorldX, heightWorldX, widthWorldZ, heightWorldZ)
        local process = hasHookContext(farmlandId)

        local cropCandidate = nil
        if process then
            cropCandidate = captureCropCandidate(farmlandId,
                startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
        end

        local changedArea, totalArea = superFunc(startWorldX, startWorldZ,
            widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, ...)

        if process then
            -- Tillage only deposits the residue; it must NOT touch the rotation history. Only the
            -- seeder records a crop change (sowing hook below), so working stubble -- or running a
            -- tool over a grass strip outside the field -- never pushes a bogus history entry.
            -- Deposit only where the engine actually cultivated crop this call (changedArea > 0),
            -- so it fires across the whole pass and stops on already-bare ground.
            if (changedArea or 0) > 0 then
                depositResidueAfterTermination(cropCandidate,
                    startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
            end
        end

        return changedArea, totalArea
    end
end

local function wrapDensityMapSowingHook()
    return function(fruitIndex, superFunc, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, ...)
        local farmlandId = getFarmlandIdAtArea(widthWorldX, heightWorldX, widthWorldZ, heightWorldZ)
        local process = hasHookContext(farmlandId)

        local cropCandidate = nil
        local nextActiveCropName = nil
        if process then
            nextActiveCropName = RealisticCropRotation.manager.service:getCropNameByFruitTypeIndex(fruitIndex)
            cropCandidate = captureCropCandidate(farmlandId,
                startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
        end

        local changedArea, totalArea = superFunc(fruitIndex, startWorldX, startWorldZ,
            widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, ...)

        if process then
            -- Normal sowing starts the next crop cycle; it does not destroy stubble, so it never
            -- deposits residue. The PF idempotency lock is generation-based, so sowing never resets
            -- a density map in this hot path.
            recordTermination(changedArea or 0, cropCandidate, nextActiveCropName)
        end

        return changedArea, totalArea
    end
end

local function wrapDensityMapDirectSowingHook()
    return function(fruitIndex, superFunc, startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, ...)
        local farmlandId = getFarmlandIdAtArea(widthWorldX, heightWorldX, widthWorldZ, heightWorldZ)
        local process = hasHookContext(farmlandId)

        local residueCandidate = nil
        local rotationCandidate = nil
        local nextActiveCropName = nil
        if process then
            nextActiveCropName = RealisticCropRotation.manager.service:getCropNameByFruitTypeIndex(fruitIndex)
            residueCandidate = captureDirectSowingCropCandidate(farmlandId,
                startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
            rotationCandidate = residueCandidate or captureCropCandidate(farmlandId,
                startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
        end

        local changedArea, totalArea = superFunc(fruitIndex, startWorldX, startWorldZ,
            widthWorldX, widthWorldZ, heightWorldX, heightWorldZ, ...)

        if process and (changedArea or 0) > 0 then
            -- Direct sowing destroys the existing stubble and sows the next crop in the same
            -- native engine call. Deposit first for the terminated stubble, then record the crop
            -- transition for the next cycle.
            depositResidueAfterTermination(residueCandidate,
                startWorldX, startWorldZ, widthWorldX, widthWorldZ, heightWorldX, heightWorldZ)
            recordTermination(changedArea or 0, rotationCandidate, nextActiveCropName)
        end

        return changedArea, totalArea
    end
end

-- =========================================================================
-- Init.
-- =========================================================================

local function initRealisticCropRotation()
    RealisticCropRotation.cropConfig = loadCropConfig()

    Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, loadedMission)
    FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, onSaveToXMLFile)
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, sendInitialClientState)

    -- Hook only the tool entry points (not the internal updateDestroyCommonArea they call):
    -- one tool pass = one hooked call = one deposit, with no nesting and no re-entrancy guard.
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updateCultivatorArea ~= nil then
        FSDensityMapUtil.updateCultivatorArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updateCultivatorArea, wrapDensityMapDestroyHook())
    end
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updateDiscHarrowArea ~= nil then
        FSDensityMapUtil.updateDiscHarrowArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updateDiscHarrowArea, wrapDensityMapDestroyHook())
    end
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updatePlowArea ~= nil then
        FSDensityMapUtil.updatePlowArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updatePlowArea, wrapDensityMapDestroyHook())
    end
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updateSowingArea ~= nil then
        FSDensityMapUtil.updateSowingArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updateSowingArea, wrapDensityMapSowingHook())
    end
    if FSDensityMapUtil ~= nil and FSDensityMapUtil.updateDirectSowingArea ~= nil then
        FSDensityMapUtil.updateDirectSowingArea = Utils.overwrittenFunction(
            FSDensityMapUtil.updateDirectSowingArea, wrapDensityMapDirectSowingHook())
    end

    BaseMission.delete = Utils.appendedFunction(BaseMission.delete, function()
        if g_currentMission ~= nil and RealisticCropRotation.broadcastUpdateable ~= nil
            and type(g_currentMission.removeUpdateable) == "function" then
            g_currentMission:removeUpdateable(RealisticCropRotation.broadcastUpdateable)
        end
        if g_messageCenter ~= nil and RealisticCropRotation.farmlandOwnerChangeListener ~= nil then
            g_messageCenter:unsubscribeAll(RealisticCropRotation.farmlandOwnerChangeListener)
        end
        RealisticCropRotation.broadcastUpdateable = nil
        RealisticCropRotation.farmlandOwnerChangeListener = nil
        RealisticCropRotation.broadcastDirty = false
        RealisticCropRotation.broadcastTimerMs = 0
        RealisticCropRotation.directSowingResidueSessions = {}

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
