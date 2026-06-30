-- Copyright © 2026 Squallqt. All rights reserved.
-- Server-authoritative disease layer: soil inoculum load from the rotation history, infection gate,
-- per-field state, spreading foci and progressive crop destruction. The load (sclerotia, nematode
-- cysts) persists between crops, even on a bare field; an actual infection needs a living host of
-- that pathogen at its own growth window.
RealisticCropRotationDisease = {}
local RealisticCropRotationDisease_mt = Class(RealisticCropRotationDisease)

RealisticCropRotationDisease.INFECTION_SCALE = 0.6  -- infection probability = load * this * weatherMod
RealisticCropRotationDisease.RAIN_BONUS = 1.6       -- fungal diseases (SCLEROTINIA) are amplified by rain
RealisticCropRotationDisease.INOCULUM_SEED = 0.12   -- inoculum a first host establishes on clean soil
RealisticCropRotationDisease.INOCULUM_GROWTH = 2.2  -- population multiplier per back-to-back host year
RealisticCropRotationDisease.INOCULUM_RESIDUAL = 0.1 -- fraction left after `interval` host-free years
RealisticCropRotationDisease.INITIAL_SEVERITY = 0.10
RealisticCropRotationDisease.SEVERITY_GROWTH = 0.12 -- severity gained per period; ~6-8 periods to full
RealisticCropRotationDisease.DESTROY_SEVERITY = 0.25 -- latent period: damage only above this
-- Destruction = one organic Perlin field over the parcel. The noise cut (threshold) drops as the
-- infection progresses, so the dead area grows and merges over time toward DESTROY_DEAD_FRACTION_MAX
-- at full severity (a devastated field). One pass clips the fruit AND the overlay grid to the parcel.
RealisticCropRotationDisease.DESTROY_PERLIN_OCTAVES = 11    -- PerlinNoiseFilter octaves (organic soil-noise look)
RealisticCropRotationDisease.DESTROY_PERLIN_FREQUENCY = 1
RealisticCropRotationDisease.DESTROY_PERLIN_PERSISTENCE = 0.5
RealisticCropRotationDisease.DESTROY_PERLIN_MAX = 10000     -- noise value range (GREATER cut is 0..this)
RealisticCropRotationDisease.DESTROY_DEAD_FRACTION_MAX = 0.90 -- dead share of the parcel at full severity
RealisticCropRotationDisease.PLOW_INOCULUM_FACTOR = 0.65    -- deep ploughing buries ~35% of sclerotia/cysts

---Creates the disease layer bound to the rotation manager.
-- @param table manager
-- @return RealisticCropRotationDisease instance
function RealisticCropRotationDisease.new(manager, grid)
    local self = setmetatable({}, RealisticCropRotationDisease_mt)
    self.manager = manager
    self.grid = grid
    self.state = {}          -- farmlandId -> group -> { severity, seed } (seed fixes the destruction scatter)
    self.crop = {}           -- farmlandId -> crop name the state belongs to
    self.plowDiscount = {}   -- farmlandId -> true when deep ploughing was applied this cycle
    self.cropActive = {}     -- farmlandId -> true while a crop grows; drives the discount reset at harvest
    return self
end

---Disease groups the named crop hosts (from cropConfig). nil when none.
local function cropDiseaseGroups(cropName)
    if cropName == nil or cropName == "" then return nil end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.diseases == nil then return nil end
    return config.diseases[string.upper(tostring(cropName))]
end

---First usable growth state of a crop (maturity reference for the infection window), or nil.
local function cropMaturity(cropName)
    if cropName == nil or g_fruitTypeManager == nil or type(g_fruitTypeManager.getFruitTypeByName) ~= "function" then
        return nil
    end
    local fruitType = g_fruitTypeManager:getFruitTypeByName(string.upper(tostring(cropName)))
    if fruitType == nil then return nil end
    local maturity = tonumber(fruitType.minHarvestingGrowthState) or 0
    if maturity <= 0 then return nil end
    local minPrep = tonumber(fruitType.minPreparingGrowthState) or -1
    if minPrep >= 1 and minPrep < maturity then maturity = minPrep end
    return maturity
end

---True when it is currently raining (free moisture for fungal sporulation).
local function isRaining()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil or env.weather == nil or type(env.weather.getIsRaining) ~= "function" then
        return false
    end
    return env.weather:getIsRaining() == true
end

---Weather modifier for a pathogen group. Rain only amplifies fungal pathogens
---(sporulation needs free moisture); soil nematodes like BCN are not rain-driven.
-- @param boolean raining Current rain state (sampled once per evaluation)
-- @param string group Pathogen group name
-- @return number modifier RAIN_BONUS for fungal groups under rain, else 1
local function weatherModifier(raining, group)
    if not raining then return 1 end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local fungal = config ~= nil and config.diseaseFungal ~= nil and config.diseaseFungal[group] == true
    return fungal and RealisticCropRotationDisease.RAIN_BONUS or 1
end

---Soil inoculum load per pathogen, from the field history alone -- it persists between crops, even
---on a bare field. Rises the more recently and the more often a host of that group returned.
-- @param integer farmlandId
-- @return table load group -> [0,1]
function RealisticCropRotationDisease:getLoad(farmlandId)
    local out = {}
    local mgr = self.manager
    if mgr == nil then return out end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.diseaseIntervals == nil then return out end

    local intervals = config.diseaseIntervals
    local history = mgr:getHistory(farmlandId) or {}
    local seed = RealisticCropRotationDisease.INOCULUM_SEED
    local growth = RealisticCropRotationDisease.INOCULUM_GROWTH
    local residual = RealisticCropRotationDisease.INOCULUM_RESIDUAL

    -- Walk the rotation oldest -> newest. A host multiplies the pathogen population; a host-free
    -- year decays it (decay set so only `residual` survives after `interval` years). A single host
    -- on clean soil only establishes the low seed level; repeating a host within its interval
    -- compounds it toward 1, while spacing hosts by the interval keeps it near zero.
    for step = #history, 1, -1 do
        local crop = history[step] ~= nil and history[step].crop or nil
        local groups = cropDiseaseGroups(crop)
        for group, rawInterval in pairs(intervals) do
            local interval = tonumber(rawInterval) or 0
            if interval > 0 then
                local cur = out[group] or 0
                if groups ~= nil and groups[group] then
                    if cur < seed then cur = seed else cur = math.min(1, cur * growth) end
                else
                    cur = cur * residual ^ (1 / interval)
                end
                out[group] = cur
            end
        end
    end

    -- Noise floor first: a load this low means no meaningful inoculum, regardless of ploughing.
    -- Ploughing then buries surface inoculum (partial, ~35%) but never resets a real load to zero
    -- -- only a host-free rotation does that. So a ploughed load is clamped to the floor, never dropped.
    local plowed = self.plowDiscount[farmlandId]
    local floor = seed * 0.5
    for group, value in pairs(out) do
        if value < floor then
            out[group] = nil
        elseif plowed then
            out[group] = math.max(floor, value * RealisticCropRotationDisease.PLOW_INOCULUM_FACTOR)
        else
            out[group] = value
        end
    end
    return out
end

---Server: a living host of a pathogen, at that pathogen's growth window, may be infected by the
---field's load. Rolled once per pathogen per crop cycle; seeds the destruction pattern on infection.
-- @param integer farmlandId
function RealisticCropRotationDisease:evaluateInfection(farmlandId)
    if g_server == nil then return end
    local mgr = self.manager
    if mgr == nil then return end
    local cropName, _, growthState = mgr:getActiveCropInfo(farmlandId)

    if self.crop[farmlandId] ~= cropName then
        self.state[farmlandId] = nil
        self.crop[farmlandId] = cropName
        if self.grid ~= nil and type(self.grid.clearField) == "function" then
            local field = type(mgr.getFieldByFarmlandId) == "function" and mgr:getFieldByFarmlandId(farmlandId) or nil
            if field ~= nil then self.grid:clearField(field) end
        end
    end
    if cropName == nil then return end -- no active infection without a living host

    local hostGroups = cropDiseaseGroups(cropName)
    if hostGroups == nil then return end
    local maturity = cropMaturity(cropName)
    -- Growth fraction toward maturity, or nil when the stage cannot be read (then we do not block).
    local frac = (maturity ~= nil and maturity > 0 and growthState ~= nil) and (growthState / maturity) or nil

    local windows = (RealisticCropRotation.cropConfig and RealisticCropRotation.cropConfig.diseaseWindows) or {}
    local raining = isRaining()
    for group, load in pairs(self:getLoad(farmlandId)) do
        if hostGroups[group] then
            local state = self.state[farmlandId]
            local alreadyInfected = state ~= nil and state[group] ~= nil
            if not alreadyInfected then
                local w = windows[group]
                -- Susceptible inside the growth window only; an unreadable stage never blocks.
                if w == nil or frac == nil or (frac >= w.from and frac <= (w.to or 1)) then
                    local chance = load * RealisticCropRotationDisease.INFECTION_SCALE * weatherModifier(raining, group)
                    if math.random() < chance then
                        self.state[farmlandId] = self.state[farmlandId] or {}
                        self.state[farmlandId][group] = {
                            severity = RealisticCropRotationDisease.INITIAL_SEVERITY,
                            -- seeds the Perlin destruction pattern; synced + saved so every client
                            -- regenerates the identical dead area (see applyPerlinDestruction)
                            seed = math.random(1, 1000000),
                            new = true, -- latent: established this period, no damage until next
                        }
                        Logging.info("[RealisticCropRotation] %s infected farmland %s (load %.2f)",
                            tostring(group), tostring(farmlandId), load)
                        if g_currentMission ~= nil and type(g_currentMission.addIngameNotification) == "function"
                            and FSBaseMission ~= nil and g_i18n ~= nil then
                            local diseaseKey = group == "SCLEROTINIA" and "rcr_disease_name_sclerotinia" or "rcr_disease_name_bcn"
                            local diseaseName = g_i18n:getText(diseaseKey)
                            local text = string.format(g_i18n:getText("rcr_disease_notification"), diseaseName, tostring(farmlandId))
                            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text)
                        end
                    end
                end
            end
        end
    end
end

---Reads the live crop on a field straight from its field state,
---bypassing the cached, normalised lookup. Returns fruit type index and growth state, or nil.
-- @param table field game Field object
-- @return integer fruitTypeIndex, or nil
-- @return integer growthState
local function getFieldCrop(field)
    if field == nil then return nil, 0 end
    local fieldState = nil
    if type(field.getFieldState) == "function" then
        fieldState = field:getFieldState()
    else
        fieldState = field.fieldState
    end
    if fieldState == nil then return nil, 0 end
    return fieldState.fruitTypeIndex, tonumber(fieldState.growthState) or 0
end

---World-space axis-aligned bounding box of a field from its polygon corner nodes, or nil.
local function fieldWorldBounds(field)
    if field == nil or getWorldTranslation == nil then return nil end
    local points = field.polygonPoints
    if type(points) ~= "table" or #points == 0 then return nil end
    local minX, maxX, minZ, maxZ
    for _, node in ipairs(points) do
        if node ~= nil then
            local x, _, z = getWorldTranslation(node)
            if type(x) == "number" and type(z) == "number" then
                if minX == nil or x < minX then minX = x end
                if maxX == nil or x > maxX then maxX = x end
                if minZ == nil or z < minZ then minZ = z end
                if maxZ == nil or z > maxZ then maxZ = z end
            end
        end
    end
    if minX == nil then return nil end
    return minX, minZ, maxX, maxZ
end

---Perlin "GREATER" cut for a severity: high (nothing dies) at the latent threshold, dropping toward
---DESTROY_DEAD_FRACTION_MAX of the parcel at full severity. Lowering the cut as severity climbs is
---what makes the dead area grow and merge organically over time.
local function severityThreshold(severity)
    local D = RealisticCropRotationDisease
    local frac = math.max(0, math.min(1, ((tonumber(severity) or 0) - D.DESTROY_SEVERITY) / math.max(1e-6, 1 - D.DESTROY_SEVERITY)))
    local deadFraction = frac * D.DESTROY_DEAD_FRACTION_MAX
    return math.floor((1 - deadFraction) * D.DESTROY_PERLIN_MAX)
end

---Applies one organic destruction pass to a density map: writes `value` wherever a Perlin noise
---field exceeds `threshold` AND the cell belongs to `farmlandId`. Two verified filters (farmland +
---Perlin). The Perlin is bound to the ground-type map, so the fruit pass and the grid pass mask the
---SAME world regions (overlay matches the ground), and -- since it is purely a function of the
---static ground-type map, the seed and the threshold -- every machine produces the identical result.
-- @param integer targetMapId, firstChannel, numChannels target density map + channels
-- @param integer value value to write (0 to clear crop, disease state for the grid)
-- @param boolean clearTypeMode true for the fruit plane (clear the type index, as the base game does)
-- @param table bbox { minX, minZ, maxX, maxZ } field world bounds
-- @param integer farmlandId, seed, threshold
local function applyPerlinDestruction(targetMapId, firstChannel, numChannels, value, clearTypeMode, bbox, farmlandId, seed, threshold)
    if targetMapId == nil or DensityMapModifier == nil or DensityMapFilter == nil
        or PerlinNoiseFilter == nil or g_terrainNode == nil or g_farmlandManager == nil
        or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil
        or FieldDensityMap == nil or getBitVectorMapNumChannels == nil then
        return false
    end
    local groundTypeMapId = select(1, g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE))
    local farmlandLocalMap = type(g_farmlandManager.getLocalMap) == "function" and g_farmlandManager:getLocalMap() or nil
    if groundTypeMapId == nil or farmlandLocalMap == nil then return false end

    local modifier = DensityMapModifier.new(targetMapId, firstChannel, numChannels, g_terrainNode)
    if clearTypeMode and DensityIndexCompareMode ~= nil then
        modifier:setNewTypeIndexMode(DensityIndexCompareMode.ZERO) -- clears the fruit type, like the base game
    end
    modifier:setParallelogramWorldCoords(bbox.minX, bbox.minZ, bbox.maxX, bbox.minZ, bbox.minX, bbox.maxZ, DensityCoordType.POINT_POINT_POINT)

    local perlin = PerlinNoiseFilter.new(groundTypeMapId,
        RealisticCropRotationDisease.DESTROY_PERLIN_OCTAVES,
        RealisticCropRotationDisease.DESTROY_PERLIN_FREQUENCY,
        RealisticCropRotationDisease.DESTROY_PERLIN_PERSISTENCE,
        tonumber(seed) or 1)
    perlin:setValueCompareParams(DensityValueCompareType.GREATER, threshold)

    local farmlandFilter = DensityMapFilter.new(farmlandLocalMap, 0, getBitVectorMapNumChannels(farmlandLocalMap))
    farmlandFilter:setValueCompareParams(DensityValueCompareType.EQUAL, farmlandId)

    modifier:executeSet(value, farmlandFilter, perlin)
    return true
end

---Applies the current destruction for one infection. On the SERVER it writes 0 into the real crop
---density map (server-authoritative, engine-synced to clients); on every machine it writes the
---disease state into the overlay grid over the SAME world regions. Idempotent and cheap (one native
---modifier pass each); as severity climbs the threshold drops, so re-applying each tick grows the
---dead area. The farmland filter keeps both inside the source parcel; on the fruit it also lands
---only on crop cells (= the cultivable field), since margins/tracks carry no crop to clear.
-- @param table field game Field object carrying the crop
-- @param integer farmlandId, seed; @param number severity; @param integer diseaseState; @param table grid
local function destroyCropField(field, farmlandId, seed, severity, diseaseState, grid)
    if field == nil then return end
    local minX, minZ, maxX, maxZ = fieldWorldBounds(field)
    if minX == nil then return end
    local bbox = { minX = minX, minZ = minZ, maxX = maxX, maxZ = maxZ }
    local threshold = severityThreshold(severity)

    -- Real crop (server only; the engine replicates the density change to clients).
    if g_server ~= nil and g_fruitTypeManager ~= nil then
        local fruitTypeIndex = getFieldCrop(field)
        if fruitTypeIndex ~= nil then
            local desc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
            if desc ~= nil and desc.terrainDataPlaneId ~= nil then
                applyPerlinDestruction(desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels,
                    0, true, bbox, farmlandId, seed, threshold)
            end
        end
    end

    -- Overlay grid (server and client) over the same world regions.
    if grid ~= nil and grid.mapId ~= nil and diseaseState ~= nil and diseaseState > 0 then
        if applyPerlinDestruction(grid.mapId, 0, grid.numChannels, diseaseState, false, bbox, farmlandId, seed, threshold) then
            grid.changeRevision = (grid.changeRevision or 0) + 1
        end
    end
end

---Server: grows the severity of every infection on a field and destroys more of the crop as the
---infection progresses (the Perlin cut drops with severity). Called each period tick; re-applying
---the (cheap, native) pass each tick simply grows the dead area.
-- @param integer farmlandId
function RealisticCropRotationDisease:propagate(farmlandId)
    if g_server == nil then return end
    local groups = self.state[farmlandId]
    if groups == nil then return end

    local mgr = self.manager
    local field = (mgr ~= nil and type(mgr.getFieldByFarmlandId) == "function")
        and mgr:getFieldByFarmlandId(farmlandId) or nil

    for group, s in pairs(groups) do
        if s.new then
            s.new = nil
        else
            s.severity = math.min(1, (s.severity or 0) + RealisticCropRotationDisease.SEVERITY_GROWTH)
            if s.severity >= RealisticCropRotationDisease.DESTROY_SEVERITY then
                local diseaseState = group == "SCLEROTINIA" and 1 or 2
                destroyCropField(field, farmlandId, s.seed, s.severity, diseaseState, self.grid)
            end
        end
    end
end

---Manages the plough discount lifecycle so the reduction actually covers the next crop. The
---discount must survive the whole crop, since the infection only rolls inside the growth window
---(mid/late growth) -- clearing it at sowing (frac~0) would lose the effect before it matters. So
---it is held while a crop grows and only cleared at harvest (crop -> bare), when the next crop must
---earn a fresh one. The live plough hook (installPlowHook) is the primary detector; the bare-field
---sampling here is a fallback for platforms where the hook cannot install.
-- @param integer farmlandId
function RealisticCropRotationDisease:checkPlowReduction(farmlandId)
    if g_server == nil then return end
    local mgr = self.manager
    if mgr == nil then return end
    self.cropActive = self.cropActive or {}
    local cropName = mgr:getActiveCropInfo(farmlandId)

    -- Crop growing: keep the discount so it still applies during the infection window.
    if cropName ~= nil then
        self.cropActive[farmlandId] = true
        return
    end

    -- Bare field. If a crop was just harvested, the discount earned for it has done its job (it
    -- covered that crop's infection window) -- clear it so the next crop must earn a fresh plough.
    if self.cropActive[farmlandId] then
        self.plowDiscount[farmlandId] = nil
        self.cropActive[farmlandId] = nil
    end

    -- Already discounted this bare-soil period.
    if self.plowDiscount[farmlandId] then return end

    -- Fallback latch: earn the discount if the bare field is currently ploughed. Also re-latches
    -- when harvest+plough happened between two ticks (the harvest reset above runs first).
    if FieldGroundType == nil then return end
    local field = type(mgr.getFieldByFarmlandId) == "function" and mgr:getFieldByFarmlandId(farmlandId) or nil
    if field == nil then return end

    local fieldState = type(field.getFieldState) == "function" and field:getFieldState() or field.fieldState
    if fieldState == nil then return end
    if fieldState.groundType == FieldGroundType.PLOWED then
        self.plowDiscount[farmlandId] = true
        Logging.info("[RealisticCropRotation] Deep ploughing reduced inoculum on farmland %s", tostring(farmlandId))
    end
end

---Latches the plough inoculum discount for a farmland (server). Idempotent within a crop
---cycle: the discount is earned once and reset at the next sowing (checkPlowReduction).
---Called from the live FSDensityMapUtil.updatePlowArea hook, so it is captured even when the
---player harvests, ploughs and re-sows between two disease ticks.
-- @param integer farmlandId
function RealisticCropRotationDisease:onPlowed(farmlandId)
    if g_server == nil then return end
    local id = tonumber(farmlandId)
    if id == nil or id <= 0 then return end
    if self.plowDiscount[id] then return end -- already latched this cycle

    self.plowDiscount[id] = true
    Logging.info("[RealisticCropRotation] Deep ploughing reduced inoculum on farmland %s", tostring(id))
    if RealisticCropRotation ~= nil and type(RealisticCropRotation.requestBroadcast) == "function" then
        RealisticCropRotation.requestBroadcast()
    end
end

---Installs a server-side hook on the engine plough so the inoculum discount is latched at the
---exact moment a field is ploughed. This hook is a technical necessity: once a field is
---harvested, ploughed and re-sown, the transient PLOWED ground state is gone before the next
---disease tick, so tick-sampling (checkPlowReduction) cannot observe it. One overwrite of the
---existing engine entry point is the lightest reliable capture (the base game already routes all
---ploughing through it). Idempotent; the global disease is resolved at call time so the hook
---survives the disease object being recreated across missions.
function RealisticCropRotationDisease.installPlowHook()
    if RealisticCropRotationDisease._plowHookInstalled then return end
    if g_currentMission == nil or type(g_currentMission.getIsServer) ~= "function"
        or not g_currentMission:getIsServer() then return end
    if Utils == nil or type(Utils.overwrittenFunction) ~= "function"
        or FSDensityMapUtil == nil or type(FSDensityMapUtil.updatePlowArea) ~= "function" then return end

    RealisticCropRotationDisease._plowHookInstalled = true
    FSDensityMapUtil.updatePlowArea = Utils.overwrittenFunction(
        FSDensityMapUtil.updatePlowArea,
        function(sx, superFunc, sz, wx, wz, hx, hz, ...)
            local changedArea, totalArea = superFunc(sx, sz, wx, wz, hx, hz, ...)

            -- Per-call cost is one native farmland read; onPlowed early-returns once the field is
            -- latched, so the work happens once per ploughed field per cycle, not per work area.
            local disease = RealisticCropRotation ~= nil and RealisticCropRotation.disease or nil
            local fm = g_farmlandManager
            if disease ~= nil and fm ~= nil and type(fm.getFarmlandIdAtWorldPosition) == "function"
                and type(sx) == "number" and type(sz) == "number"
                and type(wx) == "number" and type(wz) == "number"
                and type(hx) == "number" and type(hz) == "number" then
                -- Centroid of the worked parallelogram resolves to the farmland.
                local cx = sx + ((wx - sx) + (hx - sx)) * 0.5
                local cz = sz + ((wz - sz) + (hz - sz)) * 0.5
                local farmlandId = fm:getFarmlandIdAtWorldPosition(cx, cz)
                if farmlandId ~= nil and farmlandId > 0 then
                    disease:onPlowed(farmlandId)
                end
            end

            return changedArea, totalArea
        end)
end

---Server: one field's per-period disease step (infection gate + propagation/destruction).
-- @param integer farmlandId
function RealisticCropRotationDisease:update(farmlandId)
    self:evaluateInfection(farmlandId)
    self:propagate(farmlandId)
    self:checkPlowReduction(farmlandId)
end

---Current infection state for a field (group -> { severity, seed }), or nil.
-- @param integer farmlandId
-- @return table state, or nil
function RealisticCropRotationDisease:getState(farmlandId)
    return self.state[tonumber(farmlandId) or farmlandId]
end

---Predictive disease risk for a field: the worst pathogen load from the rotation history, in [0,1].
---Client-safe (reads only the synced history), so the map can colour every field before it strikes.
-- @param integer farmlandId
-- @return number risk
function RealisticCropRotationDisease:getRisk(farmlandId)
    local risk = 0
    for _, load in pairs(self:getLoad(farmlandId)) do
        if load > risk then risk = load end
    end
    return risk
end

---Worst active infection severity on a field, in [0,1] (0 when none). Server-authoritative.
-- @param integer farmlandId
-- @return number severity
function RealisticCropRotationDisease:getSeverity(farmlandId)
    local sev = 0
    local st = self.state[tonumber(farmlandId) or farmlandId]
    if st ~= nil then
        for _, s in pairs(st) do
            if (s.severity or 0) > sev then sev = s.severity end
        end
    end
    return sev
end

---Copies active disease state into a network-safe table.
-- @return table state
-- @return table crop
function RealisticCropRotationDisease:getSyncData()
    local outState = {}
    local outCrop = {}

    for farmlandId, groups in pairs(self.state or {}) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and groups ~= nil then
            outState[n] = {}
            for group, data in pairs(groups) do
                local groupName = tostring(group)
                outState[n][groupName] = {
                    severity = tonumber(data.severity) or 0,
                    seed = tonumber(data.seed) or 0,
                }
            end
        end
    end

    for farmlandId, cropName in pairs(self.crop or {}) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and cropName ~= nil and cropName ~= "" then
            outCrop[n] = tostring(cropName)
        end
    end

    local outPlow = {}
    for farmlandId, discounted in pairs(self.plowDiscount or {}) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and discounted then outPlow[n] = true end
    end

    return outState, outCrop, outPlow
end

---Applies active disease state received from the server.
-- @param table state
-- @param table crop
-- @param table plow
function RealisticCropRotationDisease:applySyncData(state, crop, plow)
    self.state = {}
    self.crop = {}
    self.plowDiscount = {}

    for farmlandId, groups in pairs(state or {}) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and groups ~= nil then
            self.state[n] = {}
            for group, data in pairs(groups) do
                local groupName = string.upper(tostring(group))
                self.state[n][groupName] = {
                    severity = tonumber(data.severity) or 0,
                    seed = tonumber(data.seed) or 0,
                }
            end
        end
    end

    for farmlandId, cropName in pairs(crop or {}) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and cropName ~= nil and cropName ~= "" then
            self.crop[n] = tostring(cropName)
        end
    end

    for farmlandId, discounted in pairs(plow or {}) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and discounted then
            self.plowDiscount[n] = true
        end
    end

    -- Clients never run the destruction loop, so they rebuild the active-infection overlay grid
    -- from the synced seed + severity. The server keeps its persistent .grle (the real destruction).
    if g_server == nil then
        self:rebuildGridFromState()
    end
end

---Cheap order-independent signature of the destruction-relevant state, to skip rebuilds when a
---sync carried no change to it (e.g. a rotation-plan edit triggered the broadcast).
function RealisticCropRotationDisease:destructionSignature()
    local sig = 0
    for farmlandId, groups in pairs(self.state) do
        local fid = tonumber(farmlandId) or 0
        for _, s in pairs(groups) do
            local severity = tonumber(s.severity) or 0
            if severity >= RealisticCropRotationDisease.DESTROY_SEVERITY then
                -- severity drives the destroyed share; seed fixes the scatter -> both change the grid
                sig = sig + fid + severity + (tonumber(s.seed) or 0) % 100000
            end
        end
    end
    return sig
end

---Repaints the persistent grid from the synced infection state (client overlay only). Applies the
---SAME Perlin destruction the server applied (from the infection seed + the severity threshold), so
---the grid is identical to the host's -- no bitmap is transferred, only the seed and severity.
function RealisticCropRotationDisease:rebuildGridFromState()
    local grid = self.grid
    if grid == nil or grid.mapId == nil then return end
    if type(grid.clearAll) ~= "function" then return end

    local signature = self:destructionSignature()
    if signature == self.lastGridSignature then return end
    self.lastGridSignature = signature

    local mgr = self.manager
    grid:clearAll()
    for farmlandId, groups in pairs(self.state) do
        local fid = tonumber(farmlandId)
        local field = (mgr ~= nil and type(mgr.getFieldByFarmlandId) == "function")
            and mgr:getFieldByFarmlandId(fid) or nil
        for group, s in pairs(groups) do
            if field ~= nil and (s.severity or 0) >= RealisticCropRotationDisease.DESTROY_SEVERITY then
                local diseaseState = group == "SCLEROTINIA" and 1 or 2
                -- grid only (no fruit) on the client; the field arg of nil for the crop is skipped inside
                destroyCropField(field, fid, s.seed, s.severity, diseaseState, grid)
            end
        end
    end
end

---Persists the infection state to the savegame folder.
-- @param string savegamePath Savegame folder path (trailing slash)
function RealisticCropRotationDisease:saveToXML(savegamePath)
    if savegamePath == nil or savegamePath == "" then return end
    local xmlFile = createXMLFile("rcrDisease", savegamePath .. "realisticCropRotationDisease.xml", "realisticCropRotationDisease")
    if xmlFile == nil or xmlFile == 0 then return end

    local fi = 0
    for farmlandId, groups in pairs(self.state) do
        local fKey = string.format("realisticCropRotationDisease.farmland(%d)", fi)
        setXMLInt(xmlFile, fKey .. "#id", farmlandId)
        if self.crop[farmlandId] ~= nil then setXMLString(xmlFile, fKey .. "#crop", tostring(self.crop[farmlandId])) end
        local gi = 0
        for group, s in pairs(groups) do
            local gKey = string.format("%s.group(%d)", fKey, gi)
            setXMLString(xmlFile, gKey .. "#name", group)
            setXMLFloat(xmlFile, gKey .. "#severity", s.severity or 0)
            setXMLInt(xmlFile, gKey .. "#seed", math.floor(tonumber(s.seed) or 0))
            gi = gi + 1
        end
        fi = fi + 1
    end

    local pi = 0
    for farmlandId, discounted in pairs(self.plowDiscount) do
        if discounted then
            local pKey = string.format("realisticCropRotationDisease.plowed(%d)", pi)
            setXMLInt(xmlFile, pKey .. "#id", farmlandId)
            pi = pi + 1
        end
    end

    -- cropActive must persist too: a save taken after harvest but before the cleanup tick would
    -- otherwise lose it on reload, and the discount would carry to the next crop without a new plough.
    local ci = 0
    for farmlandId, active in pairs(self.cropActive or {}) do
        if active then
            local cKey = string.format("realisticCropRotationDisease.cropActive(%d)", ci)
            setXMLInt(xmlFile, cKey .. "#id", farmlandId)
            ci = ci + 1
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
end

---Loads the infection state from the savegame folder.
-- @param string savegamePath Savegame folder path (trailing slash)
function RealisticCropRotationDisease:loadFromXML(savegamePath)
    if savegamePath == nil or savegamePath == "" then return end
    local filePath = savegamePath .. "realisticCropRotationDisease.xml"
    if fileExists == nil or not fileExists(filePath) then return end
    local xmlFile = loadXMLFile("rcrDisease", filePath)
    if xmlFile == nil or xmlFile == 0 then return end

    self.state, self.crop = {}, {}
    local fi = 0
    while true do
        local fKey = string.format("realisticCropRotationDisease.farmland(%d)", fi)
        if not hasXMLProperty(xmlFile, fKey) then break end
        local id = getXMLInt(xmlFile, fKey .. "#id")
        if id ~= nil then
            self.crop[id] = getXMLString(xmlFile, fKey .. "#crop")
            local gi = 0
            while true do
                local gKey = string.format("%s.group(%d)", fKey, gi)
                if not hasXMLProperty(xmlFile, gKey) then break end
                local name = getXMLString(xmlFile, gKey .. "#name")
                if name ~= nil and name ~= "" then
                    self.state[id] = self.state[id] or {}
                    self.state[id][name] = {
                        severity = getXMLFloat(xmlFile, gKey .. "#severity") or 0,
                        seed = getXMLInt(xmlFile, gKey .. "#seed") or math.random(1, 1000000),
                    }
                end
                gi = gi + 1
            end
        end
        fi = fi + 1
    end

    self.plowDiscount = {}
    local pi = 0
    while true do
        local pKey = string.format("realisticCropRotationDisease.plowed(%d)", pi)
        if not hasXMLProperty(xmlFile, pKey) then break end
        local id = getXMLInt(xmlFile, pKey .. "#id")
        if id ~= nil then self.plowDiscount[id] = true end
        pi = pi + 1
    end

    self.cropActive = {}
    local ci = 0
    while true do
        local cKey = string.format("realisticCropRotationDisease.cropActive(%d)", ci)
        if not hasXMLProperty(xmlFile, cKey) then break end
        local id = getXMLInt(xmlFile, cKey .. "#id")
        if id ~= nil then self.cropActive[id] = true end
        ci = ci + 1
    end

    delete(xmlFile)
end

function RealisticCropRotationDisease:registerConsoleCommands()
    if self.consoleCommandsRegistered or type(addConsoleCommand) ~= "function" then return end

    addConsoleCommand("rcrDisease", "Print Realistic Crop Rotation disease state", "consoleDump", self, "[farmlandId]")
    addConsoleCommand("rcrDiseaseInfect", "Force a disease infection: rcrDiseaseInfect <farmlandId> <group> [severity]", "consoleInfect", self, "farmlandId; group; [severity]")
    addConsoleCommand("rcrDiseaseTick", "Run one disease update tick: rcrDiseaseTick [farmlandId]", "consoleTick", self, "[farmlandId]")
    addConsoleCommand("rcrDiseaseClear", "Clear disease state: rcrDiseaseClear [farmlandId]", "consoleClear", self, "[farmlandId]")

    self.consoleCommandsRegistered = true
end

function RealisticCropRotationDisease:unregisterConsoleCommands()
    if not self.consoleCommandsRegistered or type(removeConsoleCommand) ~= "function" then return end

    removeConsoleCommand("rcrDisease")
    removeConsoleCommand("rcrDiseaseInfect")
    removeConsoleCommand("rcrDiseaseTick")
    removeConsoleCommand("rcrDiseaseClear")

    self.consoleCommandsRegistered = false
end

local function formatDiseaseLoads(load)
    local groups = {}
    for group in pairs(load or {}) do
        groups[#groups + 1] = tostring(group)
    end
    table.sort(groups)

    if #groups == 0 then return "none" end

    local parts = {}
    for _, group in ipairs(groups) do
        parts[#parts + 1] = string.format("%s=%.3f", group, tonumber(load[group]) or 0)
    end
    return table.concat(parts, ", ")
end

local function formatDiseaseState(state)
    local groups = {}
    for group in pairs(state or {}) do
        groups[#groups + 1] = tostring(group)
    end
    table.sort(groups)

    if #groups == 0 then return "none" end

    local parts = {}
    for _, group in ipairs(groups) do
        local data = state[group] or {}
        parts[#parts + 1] = string.format("%s=%.3f", group, tonumber(data.severity) or 0)
    end
    return table.concat(parts, ", ")
end

local function collectDiseaseFarmlandIds(manager, farmlandId)
    local n = tonumber(farmlandId)
    if n ~= nil and n > 0 then return { n } end
    if manager == nil or type(manager.getOwnedRotationFarmlandIds) ~= "function" then return {} end

    local out = {}
    for _, id in ipairs(manager:getOwnedRotationFarmlandIds() or {}) do
        local numericId = tonumber(id)
        if numericId ~= nil and numericId > 0 then out[#out + 1] = numericId end
    end
    table.sort(out)
    return out
end

local function requestDiseaseConsoleBroadcast()
    if RealisticCropRotation ~= nil and type(RealisticCropRotation.requestBroadcast) == "function" then
        RealisticCropRotation.requestBroadcast()
    end
end

function RealisticCropRotationDisease:consoleDump(farmlandId)
    local ids = collectDiseaseFarmlandIds(self.manager, farmlandId)
    if #ids == 0 then return "No Realistic Crop Rotation farmland found" end

    for _, id in ipairs(ids) do
        local cropName, _, growthState = nil, nil, nil
        if self.manager ~= nil and type(self.manager.getActiveCropInfo) == "function" then
            cropName, _, growthState = self.manager:getActiveCropInfo(id)
        end

        print(string.format(
            "[RealisticCropRotation] disease farmland=%d crop=%s growth=%s load={%s} state={%s}",
            id,
            tostring(cropName),
            tostring(growthState),
            formatDiseaseLoads(self:getLoad(id)),
            formatDiseaseState(self:getState(id))))
    end

    return string.format("Printed disease state for %d farmland(s)", #ids)
end

function RealisticCropRotationDisease:consoleInfect(farmlandId, groupName, severity)
    if g_server == nil then return "rcrDiseaseInfect is available on server/host only" end

    local id = tonumber(farmlandId)
    if id == nil or id <= 0 then
        return "Usage: rcrDiseaseInfect <farmlandId> <group> [severity]"
    end

    local group = groupName ~= nil and string.upper(tostring(groupName)) or nil
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if group == nil or group == "" or config == nil or config.diseaseIntervals == nil or config.diseaseIntervals[group] == nil then
        return "Unknown disease group. Use SCLEROTINIA or BCN"
    end

    local value = tonumber(severity) or RealisticCropRotationDisease.INITIAL_SEVERITY
    value = math.max(0, math.min(1, value))

    local cropName = nil
    if self.manager ~= nil and type(self.manager.getActiveCropInfo) == "function" then
        cropName = self.manager:getActiveCropInfo(id)
    end

    self.state[id] = self.state[id] or {}
    self.state[id][group] = {
        severity = value,
        seed = math.random(1, 1000000),
    }
    self.crop[id] = cropName

    requestDiseaseConsoleBroadcast()
    return string.format("Forced %s infection on farmland %d (severity %.3f)", group, id, value)
end

function RealisticCropRotationDisease:consoleTick(farmlandId)
    if g_server == nil then return "rcrDiseaseTick is available on server/host only" end

    local ids = collectDiseaseFarmlandIds(self.manager, farmlandId)
    if #ids == 0 then return "No Realistic Crop Rotation farmland found" end

    for _, id in ipairs(ids) do
        self:update(id)
    end

    requestDiseaseConsoleBroadcast()
    return string.format("Updated disease state for %d farmland(s)", #ids)
end

function RealisticCropRotationDisease:consoleClear(farmlandId)
    if g_server == nil then return "rcrDiseaseClear is available on server/host only" end

    local id = tonumber(farmlandId)
    if id ~= nil and id > 0 then
        self.state[id] = nil
        self.crop[id] = nil
        if self.grid ~= nil and type(self.grid.clearField) == "function" and self.manager ~= nil then
            local field = type(self.manager.getFieldByFarmlandId) == "function" and self.manager:getFieldByFarmlandId(id) or nil
            if field ~= nil then self.grid:clearField(field) end
        end
        requestDiseaseConsoleBroadcast()
        return string.format("Cleared disease state for farmland %d", id)
    end

    self.state = {}
    self.crop = {}
    if self.grid ~= nil and type(self.grid.clearAll) == "function" then
        self.grid:clearAll()
    end
    requestDiseaseConsoleBroadcast()
    return "Cleared all disease state"
end
