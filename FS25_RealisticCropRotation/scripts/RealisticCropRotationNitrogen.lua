-- Copyright © 2026 Squallqt. All rights reserved.
-- Phase 5: deposits rotation nitrogen residue when a crop is destroyed by tillage, mirroring how
-- Precision Farming deposits catch-crop nitrogen at destruction. ONE light append on the native
-- FSDensityMapUtil.updateDestroyCommonArea (the chokepoint PF itself hooks). The deposit writes the
-- PF nitrogen bitVectorMap directly via the engine DensityMapMultiModifier (the same primitive PF
-- uses internally for catch crops) -- the public nitrogenMap:add/set/updateNitrogenLevelAtArea is a
-- dead end: it routes through the fertilizer-spray channel and no-ops on any field that already has
-- a dose (proven: +8 on a virgin field, 0 on an established one). Idempotent per pixel by SET-to-
-- target: each crop pixel is raised TO (clean baseline + residue states), never by a delta, so the
-- many overlapping tool chunks that hit one coarse nitrogen pixel (the map is far coarser than the
-- chunk step) cannot push it past the target -- and save/reload / bare re-tillage never re-deposit.
RealisticCropRotationNitrogen = {}

-- 1 PF nitrogen state = 5 kg N/ha (PrecisionFarming.xml amountPerState=5).
RealisticCropRotationNitrogen.PF_STATE_KG = 5

local manager = nil
local installed = false
local sprayTypeFertilizer = nil
local fieldState = nil      -- reused FieldState for fruit reads
local nitrogenMap = nil     -- PF nitrogen map once resolved, nil while vanilla
local nitrogenDensity = nil -- cached { mapId, firstChannel, numChannels, maxValue } of the N bitVectorMap
local fieldGroundFilter = nil
local depositMultiModifiers = {}      -- keyed by map+delta, built once like the base game caches modifiers
local depositExecChanged, depositExecTotal = {}, {}
local DEPOSIT_STATS_LABEL = "rcrNResidue"
local lastLogFarmland, lastLogCrop = nil, nil   -- throttle the deposit log to one line per termination

-- Per-pixel "already deposited" guard: a scratch bit-vector map (same resolution as the nitrogen
-- map). Each termination uses a rolling id; a pixel is ADDed exactly once per id, so overlapping
-- tool chunks and tool lift/lower never re-add, while a later crop (next id) deposits again. This is
-- what lets us ADD a fixed dose on top of the existing gradient (like PF's catch crops) instead of
-- flattening it with a SET.
local residueGuardMap = nil
local GUARD_BITS = 8
local GUARD_MAX_ID = (2 ^ GUARD_BITS) - 1   -- 255; wraps (recreates the guard) after this many crops
local currentTerminationId = 0

-- The tool clears crop ahead of updateDestroyCommonArea, so the density map only reads the crop
-- on the first chunk of a pass. The crop seen when the tool bites is cached per farmland and
-- carried across the pass; the window expires between passes so later bare tillage deposits nothing.
local terminationCrop = {}            -- farmlandId -> { crop = name, time = ms }
local TERMINATION_WINDOW_MS = 1000

---Resolves and caches the PF nitrogen map; re-resolves while nil so a late PF load is picked up.
-- @return table nitrogenMap, or nil when Precision Farming is absent
local function getNitrogenMap()
    if nitrogenMap ~= nil then return nitrogenMap end
    if manager ~= nil and type(manager.getPrecisionFarming) == "function" then
        local pf = manager:getPrecisionFarming()
        if pf ~= nil and pf.nitrogenMap ~= nil and tonumber(pf.nitrogenMap.bitVectorMap) ~= nil then
            nitrogenMap = pf.nitrogenMap
        end
    end
    return nitrogenMap
end

---Resolves and caches the nitrogen bitVectorMap density handle (PF instance fields, dump-verified:
---bitVectorMap=180831, firstChannel=0, numChannels=6, maxValue=45).
-- @return table { mapId, firstChannel, numChannels, maxValue }, or nil
local function getNitrogenDensityData()
    if nitrogenDensity ~= nil then return nitrogenDensity end
    local nMap = getNitrogenMap()
    if nMap == nil then return nil end
    local mapId = tonumber(nMap.bitVectorMap)
    local fc = tonumber(nMap.firstChannel)
    local nc = tonumber(nMap.numChannels)
    local maxV = math.floor(tonumber(nMap.maxValue) or 45)
    if mapId == nil or fc == nil or nc == nil or maxV <= 0 then return nil end
    nitrogenDensity = { mapId = mapId, firstChannel = fc, numChannels = nc, maxValue = maxV }
    return nitrogenDensity
end

-- Reads the PF internal nitrogen state at a world position (validation log).
local function readNitrogenAt(x, z)
    local nMap = getNitrogenMap()
    if nMap == nil or type(nMap.getLevelAtWorldPos) ~= "function" then return nil end
    local ok, v = pcall(nMap.getLevelAtWorldPos, nMap, x, z)
    return (ok and tonumber(v)) or nil
end

---Filter restricting writes to actual field ground (fallback when a crop fruit filter is
---unavailable). Any non-zero ground type; 0 = not a field.
-- @return table DensityMapFilter, or nil
local function getFieldGroundFilter()
    if fieldGroundFilter ~= nil then return fieldGroundFilter end
    local mission = g_currentMission
    local fgs = mission ~= nil and mission.fieldGroundSystem or nil
    if fgs == nil or DensityMapFilter == nil or DensityValueCompareType == nil
        or FieldDensityMap == nil or FieldDensityMap.GROUND_TYPE == nil
        or type(fgs.getDensityMapData) ~= "function" then
        return nil
    end
    local mapId, fc, nc = fgs:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if mapId == nil or nc == nil then return nil end
    local maxGround = (2 ^ nc) - 1
    local filter = DensityMapFilter.new(mapId, fc, nc)
    filter:setValueCompareParams(DensityValueCompareType.BETWEEN, 1, maxGround)
    fieldGroundFilter = filter
    return filter
end

-- Cached per-fruit "crop present" filters (keyed by fruitTypeIndex).
local cropFruitFilters = {}

---Filter matching pixels that still carry the given fruit (any non-zero growth state). Depositing
---on these BEFORE the destroy call, then letting the destroy clear them to 0, makes the deposit
---idempotent per pixel: overlapping tool chunks re-cover already-destroyed (fruit=0) pixels and skip
---them. Uses the fruit's own density plane (desc.terrainDataPlaneId), like PF's ExtendedWeedControl.
-- @param integer fruitTypeIndex
-- @return table DensityMapFilter, or nil
local function getCropFruitFilter(fruitTypeIndex)
    if fruitTypeIndex == nil then return nil end
    local cached = cropFruitFilters[fruitTypeIndex]
    if cached ~= nil then return cached end
    if g_fruitTypeManager == nil or DensityMapFilter == nil or DensityValueCompareType == nil then return nil end
    local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if desc == nil or desc.terrainDataPlaneId == nil or desc.startStateChannel == nil
        or desc.numStateChannels == nil then
        return nil
    end
    local maxState = (2 ^ desc.numStateChannels) - 1
    local filter = DensityMapFilter.new(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels)
    filter:setValueCompareParams(DensityValueCompareType.BETWEEN, 1, maxState)
    cropFruitFilters[fruitTypeIndex] = filter
    return filter
end

---Resolves (creating once) the scratch guard bit-vector map, sized to the nitrogen map so one guard
---pixel maps to one nitrogen pixel. Returns nil if the engine bit-vector API is unavailable.
-- @param table data Nitrogen density data (for the map size)
-- @return integer guardMapId, or nil
local function getGuardMap(data)
    if residueGuardMap ~= nil then return residueGuardMap end
    if createBitVectorMap == nil or loadBitVectorMapNew == nil or getBitVectorMapSize == nil
        or g_terrainNode == nil then
        return nil
    end
    local sizeX = getBitVectorMapSize(data.mapId)
    if type(sizeX) ~= "number" or sizeX <= 0 then return nil end
    local m = createBitVectorMap("rcrResidueGuard")
    if m == nil then return nil end
    loadBitVectorMapNew(m, sizeX, sizeX, GUARD_BITS, false)   -- fresh => all zeroes
    residueGuardMap = m
    return m
end

---Cached multi-modifier that ADDs addStates to each nitrogen pixel (clamped to maxValue), but ONLY
---where the guard is below terminationId -- then stamps the guard with terminationId. So a pixel is
---raised exactly once per termination no matter how many overlapping tool chunks or lift/lower passes
---hit it, while the existing per-soil gradient is preserved (ADD, not SET). Mirrors how PF tracks a
---fruit-destroy once per nitrogen pixel for its catch-crop deposit.
-- @return table DensityMapMultiModifier, or nil
local function getDepositAddModifier(data, addStates, terminationId)
    local guardMap = getGuardMap(data)
    if guardMap == nil then return nil end
    if DensityMapModifier == nil or DensityMapMultiModifier == nil or DensityMapFilter == nil
        or DensityValueCompareType == nil or g_terrainNode == nil then
        return nil
    end
    local key = string.format("%d|%d|%d|%d|%d",
        data.mapId, data.firstChannel, data.numChannels, addStates, terminationId)
    local cached = depositMultiModifiers[key]
    if cached ~= nil then return cached end

    local nModifier = DensityMapModifier.new(data.mapId, data.firstChannel, data.numChannels, g_terrainNode)
    local guardModifier = DensityMapModifier.new(guardMap, 0, GUARD_BITS, g_terrainNode)
    -- "not yet deposited for this id": guard in [0, id-1] (ids are monotonic within a wrap cycle).
    local guardFilter = DensityMapFilter.new(guardMap, 0, GUARD_BITS)
    guardFilter:setValueCompareParams(DensityValueCompareType.BETWEEN, 0, terminationId - 1)

    local multiModifier = DensityMapMultiModifier.new()
    -- Descending so a pixel raised from s to s+addStates is not matched again by a lower source state.
    for s = data.maxValue - 1, 0, -1 do
        local valueFilter = DensityMapFilter.new(data.mapId, data.firstChannel, data.numChannels)
        valueFilter:setValueCompareParams(DensityValueCompareType.EQUAL, s)
        local target = math.min(s + addStates, data.maxValue)
        multiModifier:addExecuteSetWithStats(DEPOSIT_STATS_LABEL, target, nModifier, valueFilter, guardFilter)
    end
    -- Stamp the worked pixels with the id (runs after the nitrogen writes), so later chunks skip them.
    multiModifier:addExecuteSet(terminationId, guardModifier, guardFilter)

    depositMultiModifiers[key] = multiModifier
    return multiModifier
end

---Advances to the next termination id, recreating the guard (zeroed) and dropping the modifier cache
---on wrap so stale ids never collide.
-- @return integer terminationId
local function nextTerminationId()
    if currentTerminationId >= GUARD_MAX_ID then
        if residueGuardMap ~= nil and delete ~= nil then delete(residueGuardMap) end
        residueGuardMap = nil
        for k in pairs(depositMultiModifiers) do depositMultiModifiers[k] = nil end
        currentTerminationId = 1
    else
        currentTerminationId = currentTerminationId + 1
    end
    return currentTerminationId
end

-- Grid offsets across the worked parallelogram (start + a*width + b*height).
local RealisticCropRotationNitrogen_SAMPLES = { 0.5, 0.15, 0.85 }

---Crop being destroyed in a worked area. A single centre point is unreliable: consecutive
---tool chunks overlap, so the centre often reads NONE (already destroyed) while the forward
---edge still carries standing crop. Sampling a grid (early-exit on first crop) mirrors how the
---probe detected the destroyed crop across a moving pass. Read BEFORE the tool clears the area.
-- @return string cropName, or nil
-- @return integer fruitTypeIndex, or nil
-- @return number sampleX On-crop sample position (validation read), or nil
-- @return number sampleZ
local function detectDestroyedCrop(sx, sz, wx, wz, hx, hz)
    if fieldState == nil then
        if FieldState == nil or type(FieldState.new) ~= "function" then return nil end
        fieldState = FieldState.new()
    end
    if g_fruitTypeManager == nil then return nil end
    local dwx, dwz = wx - sx, wz - sz
    local dhx, dhz = hx - sx, hz - sz
    for _, a in ipairs(RealisticCropRotationNitrogen_SAMPLES) do
        for _, b in ipairs(RealisticCropRotationNitrogen_SAMPLES) do
            local x = sx + dwx * a + dhx * b
            local z = sz + dwz * a + dhz * b
            local ok = pcall(fieldState.update, fieldState, x, z)
            if ok and fieldState.isValid then
                local fruitTypeIndex = tonumber(fieldState.fruitTypeIndex)
                if fruitTypeIndex ~= nil and fruitTypeIndex > 0 then
                    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
                    if fruitType ~= nil and fruitType.name then
                        return string.upper(fruitType.name), fruitTypeIndex, x, z
                    end
                end
            end
        end
    end
    return nil
end

---Deposits `states` of nitrogen residue over the worked area by writing the PF nitrogen
---bitVectorMap directly (the engine multi-modifier PF uses for catch crops). Vanilla falls back to
---a coarse fertilizer pass. Must never raise: it wraps a core density-map function (pcall-guarded
---by the caller).
-- @param integer states Residue delta in nitrogen states (added on top of the existing value)
-- @param integer terminationId Guard id for this termination (one ADD per pixel per id)
-- @return boolean deposited
-- @return string mode "pf" or "vanilla"
-- @return number changedPixels (pf path; -1 when unknown)
local function depositResidue(sx, sz, wx, wz, hx, hz, states, terminationId)
    local data = getNitrogenDensityData()
    if data ~= nil then
        -- Precision Farming present: ADD the residue to the nitrogen map, guarded so each pixel is
        -- raised once. Returns within this block on every path so a PF field is never also sprayed.
        if DensityCoordType == nil then return false end
        local addStates = math.floor(tonumber(states) or 0)
        if addStates <= 0 or terminationId == nil or terminationId <= 0 then return false end
        local multiModifier = getDepositAddModifier(data, addStates, terminationId)
        if multiModifier == nil then return false end
        multiModifier:updateParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
        multiModifier:resetStats()
        multiModifier:execute(nil, depositExecChanged, depositExecTotal)
        local nMap = getNitrogenMap()
        if nMap ~= nil and type(nMap.setMinimapRequiresUpdate) == "function" then
            nMap:setMinimapRequiresUpdate(true)
        end
        return true, "pf", depositExecChanged[DEPOSIT_STATS_LABEL] or 0
    end
    -- No Precision Farming: the residue adds ONE vanilla fertilizer level over the area (modDesc).
    if FSDensityMapUtil ~= nil and type(FSDensityMapUtil.updateSprayArea) == "function"
        and sprayTypeFertilizer ~= nil and (tonumber(states) or 0) > 0 then
        FSDensityMapUtil.updateSprayArea(sx, sz, wx, wz, hx, hz, sprayTypeFertilizer, 1)
        return true, "vanilla", -1
    end
    return false
end

---Installs the residue deposit (server only, once). On each crop-destruction chunk it deposits
---the terminated crop's n1 plus the previously recorded crop's n2, the same way PF deposits a
---catch crop at destruction.
-- @param table rcrManager Active RealisticCropRotationManager
function RealisticCropRotationNitrogen.install(rcrManager)
    if installed then return end
    if g_currentMission == nil or g_currentMission.getIsServer == nil or not g_currentMission:getIsServer() then return end
    if Utils == nil or type(Utils.overwrittenFunction) ~= "function" or FSDensityMapUtil == nil then return end
    if type(FSDensityMapUtil.updateDestroyCommonArea) ~= "function" then return end
    if rcrManager == nil or rcrManager.service == nil then return end

    manager = rcrManager
    sprayTypeFertilizer = SprayType ~= nil and SprayType.FERTILIZER or nil
    installed = true

    FSDensityMapUtil.updateDestroyCommonArea = Utils.overwrittenFunction(FSDensityMapUtil.updateDestroyCommonArea,
        function(sx, superFunc, sz, wx, wz, hx, hz, ...)
            -- Resolve the terminated crop BEFORE the tool clears the area. The crop is only readable
            -- on the first chunk (the tool cuts ahead of this call), so the residue (states) and its
            -- guard id are computed ONCE per crop lifecycle and reused on every later chunk/pass;
            -- recomputed only when a DIFFERENT crop is detected on the field.
            local cropName, fruitTypeIndex, farmlandId, states, terminationId
            if type(sx) == "number" and type(wx) == "number" and type(hx) == "number"
                and g_farmlandManager ~= nil
                and type(g_farmlandManager.getFarmlandIdAtWorldPosition) == "function" then
                local cx = sx + (wx - sx) * 0.5 + (hx - sx) * 0.5
                local cz = sz + (wz - sz) * 0.5 + (hz - sz) * 0.5
                farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(cx, cz)
                if farmlandId ~= nil and farmlandId > 0 then
                    local now = (g_currentMission ~= nil and g_currentMission.time) or 0
                    local cached = terminationCrop[farmlandId]
                    if cached ~= nil and (now - cached.time) <= TERMINATION_WINDOW_MS then
                        cropName, fruitTypeIndex, states, terminationId = cached.crop, cached.fruitIndex, cached.states, cached.id
                        cached.time = now
                    else
                        local detectedCrop, detectedFruit = detectDestroyedCrop(sx, sz, wx, wz, hx, hz)
                        if detectedCrop ~= nil then
                            if cached ~= nil and cached.crop == detectedCrop then
                                -- Same crop as before the window lapsed: reuse its residue and guard id.
                                cropName, fruitTypeIndex, states, terminationId = detectedCrop, detectedFruit, cached.states, cached.id
                                cached.fruitIndex, cached.time = detectedFruit, now
                            else
                                -- New crop: residue = this crop's n1 + the PREVIOUS crop's n2 (reconcile-fed
                                -- history[1]); a fresh guard id so its pixels each deposit once.
                                states = manager.service:getResidueStatesForTermination(farmlandId, detectedCrop)
                                cropName, fruitTypeIndex = detectedCrop, detectedFruit
                                terminationId = (states ~= nil and states > 0) and nextTerminationId() or nil
                                terminationCrop[farmlandId] = { crop = detectedCrop, fruitIndex = detectedFruit,
                                    states = states, id = terminationId, time = now }
                            end
                        end
                    end
                end
            end

            -- ADD the residue to each worked pixel once (guarded by terminationId), BEFORE the destroy.
            -- Logged once per (farmland, crop) termination, not per chunk.
            if cropName ~= nil and farmlandId ~= nil and states ~= nil and states > 0 and terminationId ~= nil then
                local firstLog = (lastLogFarmland ~= farmlandId or lastLogCrop ~= cropName)
                local ok, deposited, mode = pcall(depositResidue, sx, sz, wx, wz, hx, hz, states, terminationId)
                if firstLog and ok and deposited then
                    lastLogFarmland, lastLogCrop = farmlandId, cropName
                    Logging.info("[RealisticCropRotation] residue deposited: farmland=%d crop=%s residue=%d states (id=%d) mode=%s",
                        farmlandId, cropName, states, terminationId, tostring(mode))
                elseif firstLog and not ok then
                    lastLogFarmland, lastLogCrop = farmlandId, cropName
                    Logging.info("[RealisticCropRotation] residue deposit error: farmland=%d crop=%s err=%s",
                        farmlandId, cropName, tostring(deposited))
                end
            end

            return superFunc(sx, sz, wx, wz, hx, hz, ...)
        end)

    Logging.info("[RealisticCropRotation] nitrogen residue active (server): deposit on crop destruction via %s",
        getNitrogenMap() ~= nil and "Precision Farming nitrogen map" or "vanilla fertilizer")
end
