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
-- Severity now advances DAY BY DAY (MessageType.DAY_CHANGED), not per period, so a crop dies in a
-- slow, credible creep instead of monthly leaps. The per-day increment, the latent threshold and the
-- destruction ceiling are PER PATHOGEN (cropConfig <diseaseGroup dailyGrowth/destroySeverity/
-- deadFractionMax>): a fungal blight (SCLEROTINIA) climbs fast and faster still under rain, a soil
-- nematode (BCN) crawls and never wipes the whole field. The constants below are only the fallbacks
-- used when a group omits the attribute.
RealisticCropRotationDisease.DEFAULT_DAILY_GROWTH = 0.04 -- severity gained per in-game day (fallback)
RealisticCropRotationDisease.DESTROY_SEVERITY = 0.25 -- latent period: damage only above this (fallback)
-- Destruction = one organic Perlin field over the parcel. The noise cut (threshold) drops as the
-- infection progresses, so the dead area grows and merges over the days toward deadFractionMax at
-- full severity (a devastated field). One pass clips the fruit AND the overlay grid to the parcel.
-- The dead share follows a mildly convex ramp (frac^DESTROY_RAMP_POWER) so early infection only
-- scatters a few spots and the field is engulfed gradually rather than in a single leap.
-- PerlinNoiseFilter.new(map, minOctave, numOctave, persistence, seed). minOctave is THE size knob:
-- wavelength ~= terrainSize / 2^minOctave, so 6 -> ~32 m organic patches (real irregular foci),
-- whereas 11 -> ~1 m "salt-and-pepper" speckle (unrealistic; that was a regression). numOctave adds
-- finer layers on top for ROUGH, irregular edges (no circles, no squares). These 32 m rough patches
-- were the user-validated look. Lower minOctave = bigger foci.
RealisticCropRotationDisease.DESTROY_PERLIN_OCTAVES = 6    -- minOctave: ~32 m organic foci (THE size knob; lower = bigger)
RealisticCropRotationDisease.DESTROY_PERLIN_FREQUENCY = 3  -- numOctave: added detail layers -> rough, irregular edges
RealisticCropRotationDisease.DESTROY_PERLIN_PERSISTENCE = 0.5
RealisticCropRotationDisease.DESTROY_PERLIN_MAX = 10000     -- noise value range (GREATER cut is 0..this)
RealisticCropRotationDisease.DESTROY_DEAD_FRACTION_MAX = 0.90 -- dead share of the parcel at full severity (fallback)
RealisticCropRotationDisease.DESTROY_RAMP_POWER = 1.6      -- convex severity->dead ramp (gentle near the latent threshold)
RealisticCropRotationDisease.DAILY_BUDGET_PER_FRAME = 1   -- fields whose daily disease step runs per frame (load spreading)

-- Predictive-risk band thresholds. The worst pathogen load (getRisk, from the rotation history) is
-- mapped to a band 1..3 painted into the runtime risk display map (grid.riskMapId) and shown by the
-- in-game map's pressure view; below the low threshold the field is left unpainted (band 0).
RealisticCropRotationDisease.RISK_BAND_LOW_THRESHOLD = 0.10
RealisticCropRotationDisease.RISK_BAND_MODERATE_THRESHOLD = 0.25
RealisticCropRotationDisease.RISK_BAND_HIGH_THRESHOLD = 0.50

---Creates the disease layer bound to the rotation manager.
-- @param table manager
-- @return RealisticCropRotationDisease instance
function RealisticCropRotationDisease.new(manager, grid)
    local self = setmetatable({}, RealisticCropRotationDisease_mt)
    self.manager = manager
    self.grid = grid
    self.state = {}          -- farmlandId -> group -> { severity, seed } (seed fixes the destruction scatter)
    self.crop = {}           -- farmlandId -> crop name the state belongs to
    self.lastRiskBand = {}   -- farmlandId -> band last painted into the risk display map
    self.lastInfectionState = {} -- farmlandId -> dominant disease state last painted into the infection display map
    self.dayQueue = {}       -- FIFO of farmlandIds awaiting their daily disease step (load spreading)
    self.dayQueued = {}      -- farmlandId -> true, dedupes the queue
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

---Weather modifier for a pathogen group. Rain only amplifies fungal pathogens (sporulation needs
---free moisture); soil animals/protists (BCN, clubroot) are not rain-driven. The multiplier is the
---group's own `weatherFactor` from the config (default RAIN_BONUS), so strongly weather-driven
---diseases (late blight, rusts, septoria) both infect AND destroy much faster in a wet spell.
-- @param boolean raining Current rain state (sampled once per evaluation)
-- @param string group Pathogen group name
-- @return number modifier weatherFactor for fungal groups under rain, else 1
local function weatherModifier(raining, group)
    if not raining then return 1 end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local fungal = config ~= nil and config.diseaseFungal ~= nil and config.diseaseFungal[group] == true
    if not fungal then return 1 end
    local factor = config ~= nil and config.diseaseWeatherFactors ~= nil and config.diseaseWeatherFactors[group] or nil
    return tonumber(factor) or RealisticCropRotationDisease.RAIN_BONUS
end

---Stable overlay grid state (1..N) for a pathogen group, from cropConfig <diseaseGroup state=>.
---Each disease gets its OWN id so the in-game map paints it with its own colour (individually
---distinguishable on the parcel). Purely static config data -> identical on every machine, so the
---client grid rebuild reproduces the host's painting deterministically.
-- @param string group Pathogen group name
-- @return integer state id (>= 1); 1 as a last-resort fallback when the config is unavailable
local function diseaseStateForGroup(group)
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local state = config ~= nil and config.diseaseStates ~= nil and config.diseaseStates[group] or nil
    return tonumber(state) or 1
end

---Localized display name for a pathogen group. Reads ONLY g_i18n (key rcr_disease_name_<lowergroup>);
---no hardcoded French fallback -- at worst it returns the group name itself when i18n is unavailable.
-- @param string group Pathogen group name
-- @return string name
local function diseaseDisplayName(group)
    local key = "rcr_disease_name_" .. string.lower(tostring(group))
    if g_i18n ~= nil and type(g_i18n.hasText) == "function" and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return tostring(group)
end

---Public accessor for a pathogen group's display name (reused by the HUD, notification, panels), so
---no caller re-implements the SCLEROTINIA/BCN/... name mapping.
-- @param string group Pathogen group name
-- @return string name
function RealisticCropRotationDisease:getDisplayName(group)
    return diseaseDisplayName(group)
end

---Reference treatment family for a pathogen group, from cropConfig (FUNGICIDE | NEMATICIDE | NONE).
---Used by field display/advice and by sprayer products that cure matching active infections.
-- @param string group Pathogen group name
-- @return string treatment ("NONE" when unknown)
function RealisticCropRotationDisease:getTreatment(group)
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local t = config ~= nil and config.diseaseTreatments ~= nil and config.diseaseTreatments[group] or nil
    return t ~= nil and tostring(t) or "NONE"
end

---Localized treatment label for a pathogen group. Reads ONLY g_i18n via key
---rcr_disease_treatment_<lowergroup>; at worst returns the key (no hardcoded final text).
-- @param string group Pathogen group name
-- @return string label
function RealisticCropRotationDisease:getTreatmentName(group)
    local key = "rcr_disease_treatment_" .. string.lower(tostring(group))
    if g_i18n ~= nil and type(g_i18n.hasText) == "function" and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return key
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

    -- A load this low means no meaningful inoculum; only host-free rotation decay removes pressure.
    local floor = seed * 0.5
    for group, value in pairs(out) do
        if value < floor then
            out[group] = nil
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
                            local diseaseName = diseaseDisplayName(group)
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

---Perlin "GREATER" cut for a severity under a pathogen's curve: high (nothing dies) at the latent
---threshold, dropping toward the curve's deadFractionMax of the parcel at full severity along a
---mildly convex ramp (frac^power). Lowering the cut as severity climbs is what makes the dead area
---grow and merge organically over the days; the convex ramp keeps early destruction to a few spots.
-- @param number severity current infection severity [0,1]
-- @param table curve { destroySeverity, deadFractionMax, power }, or nil for the module fallbacks
local function severityThreshold(severity, curve, cure)
    local D = RealisticCropRotationDisease
    local destroySeverity = curve ~= nil and curve.destroySeverity or D.DESTROY_SEVERITY
    local deadFractionMax = curve ~= nil and curve.deadFractionMax or D.DESTROY_DEAD_FRACTION_MAX
    local power = curve ~= nil and curve.power or D.DESTROY_RAMP_POWER
    local sev = tonumber(severity) or 0
    local frac = math.max(0, math.min(1, (sev - destroySeverity) / math.max(1e-6, 1 - destroySeverity)))
    local deadFraction = deadFractionMax * (frac ^ power)
    -- Curative coverage (0..1, raised by an RCR sprayer passing over the field) shrinks the painted /
    -- destroyed footprint: the effective dead fraction is scaled by (1 - cure), so RAISING the Perlin
    -- cut makes the foci recede from their edges toward their cores (small patches vanish first) until
    -- nothing is painted at full cure. Purely a function of (severity, seed, cure) + the static ground
    -- map, so server and every client compute the identical shrunk area from the synced scalar.
    local cureFactor = 1 - math.max(0, math.min(1, tonumber(cure) or 0))
    deadFraction = deadFraction * cureFactor
    return math.floor((1 - deadFraction) * D.DESTROY_PERLIN_MAX)
end

---Per-pathogen destruction curve, from cropConfig with module fallbacks. Purely static data, identical
---on every machine, so a client rebuilds the exact same dead area from the synced severity + seed.
-- @param string group Pathogen group name
-- @return table curve { dailyGrowth, destroySeverity, deadFractionMax, power }
function RealisticCropRotationDisease:getCurve(group)
    local D = RealisticCropRotationDisease
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local params = (config ~= nil and config.diseaseCurves ~= nil) and config.diseaseCurves[group] or nil
    return {
        dailyGrowth     = (params ~= nil and params.dailyGrowth)     or D.DEFAULT_DAILY_GROWTH,
        destroySeverity = (params ~= nil and params.destroySeverity) or D.DESTROY_SEVERITY,
        deadFractionMax = (params ~= nil and params.deadFractionMax) or D.DESTROY_DEAD_FRACTION_MAX,
        power           = D.DESTROY_RAMP_POWER,
    }
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

---Erases grid marks that landed outside the worked soil (parcel margins/tracks): the destruction
---pass paints farmland ∩ Perlin, so some cells fall on unworked parcel ground where no crop ever
---grew. Clearing them at WRITE time keeps the map overlay clean without any render-time mask (the
---overlay draws the grid directly, BMP-style). Same 2-filter modifier mechanism as the paint pass.
-- @param table grid overlay grid wrapper; @param table bbox field world bounds; @param integer farmlandId
local function clipGridToWorkedSoil(grid, bbox, farmlandId)
    if grid == nil or grid.mapId == nil or DensityMapModifier == nil or DensityMapFilter == nil
        or g_terrainNode == nil or g_farmlandManager == nil
        or type(g_farmlandManager.getLocalMap) ~= "function"
        or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil
        or FieldDensityMap == nil or getBitVectorMapNumChannels == nil then
        return
    end
    local groundTypeMapId, groundFirstChannel, groundNumChannels =
        g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    local farmlandLocalMap = g_farmlandManager:getLocalMap()
    if groundTypeMapId == nil or farmlandLocalMap == nil then return end

    local modifier = DensityMapModifier.new(grid.mapId, 0, grid.numChannels, g_terrainNode)
    modifier:setParallelogramWorldCoords(bbox.minX, bbox.minZ, bbox.maxX, bbox.minZ, bbox.minX, bbox.maxZ, DensityCoordType.POINT_POINT_POINT)

    local farmlandFilter = DensityMapFilter.new(farmlandLocalMap, 0, getBitVectorMapNumChannels(farmlandLocalMap))
    farmlandFilter:setValueCompareParams(DensityValueCompareType.EQUAL, farmlandId)

    local unworkedFilter = DensityMapFilter.new(groundTypeMapId, groundFirstChannel, groundNumChannels)
    unworkedFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 0)

    modifier:executeSet(0, farmlandFilter, unworkedFilter)
end

---Applies the current destruction for one infection. On the SERVER it writes 0 into the real crop
---density map (server-authoritative, engine-synced to clients); on every machine it writes the
---disease state into the overlay grid over the SAME world regions. Idempotent and cheap (one native
---modifier pass each); as severity climbs the threshold drops, so re-applying each tick grows the
---dead area. The farmland filter keeps both inside the source parcel; on the fruit it also lands
---only on crop cells (= the cultivable field), since margins/tracks carry no crop to clear.
-- @param table field game Field object carrying the crop
-- @param integer farmlandId, seed; @param number severity; @param table curve pathogen destruction curve
-- @param integer diseaseState; @param table grid
local function destroyCropField(field, farmlandId, seed, severity, curve, diseaseState, grid, cure)
    if field == nil then return end
    local minX, minZ, maxX, maxZ = fieldWorldBounds(field)
    if minX == nil then return end
    local bbox = { minX = minX, minZ = minZ, maxX = maxX, maxZ = maxZ }
    local threshold = severityThreshold(severity, curve, cure)

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

    -- Overlay grid (server and client) over the same world regions. The clip pass then erases the
    -- few marks that fell on unworked parcel ground, so the rendered overlay stays inside the field.
    if grid ~= nil and grid.mapId ~= nil and diseaseState ~= nil and diseaseState > 0 then
        if applyPerlinDestruction(grid.mapId, 0, grid.numChannels, diseaseState, false, bbox, farmlandId, seed, threshold) then
            clipGridToWorkedSoil(grid, bbox, farmlandId)
            grid.changeRevision = (grid.changeRevision or 0) + 1
        end
    end
end

---Server: advances every infection on a field by ONE in-game day and destroys a little more of the
---crop as the infection progresses (the Perlin cut drops with severity). Called once per day per field
---(drained from the daily queue); re-applying the cheap native pass each day simply grows the dead
---area. The per-day severity gain is the pathogen's own rate, amplified by rain for fungal groups.
-- @param integer farmlandId
function RealisticCropRotationDisease:propagate(farmlandId)
    if g_server == nil then return end
    local groups = self.state[farmlandId]
    if groups == nil then return end

    local mgr = self.manager
    local field = (mgr ~= nil and type(mgr.getFieldByFarmlandId) == "function")
        and mgr:getFieldByFarmlandId(farmlandId) or nil
    local raining = isRaining()

    for group, s in pairs(groups) do
        if s.new then
            s.new = nil -- established this day; severity only starts climbing the next day
        else
            local curve = self:getCurve(group)
            -- Fungal groups climb faster on a rainy day (weatherModifier); soil nematodes ignore it.
            local growth = curve.dailyGrowth * weatherModifier(raining, group)
            s.severity = math.min(1, (s.severity or 0) + growth)
            if s.severity >= curve.destroySeverity then
                local diseaseState = diseaseStateForGroup(group)
                destroyCropField(field, farmlandId, s.seed, s.severity, curve, diseaseState, self.grid, s.cure)
            end
        end
    end
end

---Server: curative product application on ONE field. Cures every ACTIVE infection whose reference
---treatment family matches the sprayed product (config.diseaseTreatments[group]): a fungicide clears
---the fungal groups, a nematicide clears the nematode (BCN). Groups whose treatment is "NONE" (take-all
---piétin, clubroot hernie) are never soigned by any product -- only the rotation manages them.
---
---Curative == PROGRESSIVE control of the active infection instance, proportional to the treated area.
---Each treatment window (an RCR sprayer actively passing over the field, gated per (vehicle, farmland,
---product) by the sprayer hook) adds `coverage` to the matching group's `cure` accumulator (0..1). As
---cure climbs the painted foci recede deterministically (severityThreshold scales the dead fraction by
---1-cure) on the SERVER (this repaint) and on every client (rebuildGridFromState from the synced cure),
---so the overlay disappears gradually behind the spraying -- not the whole field in one leap. A group is
---only REMOVED once fully covered (cure >= 1): progression stops and its foci are gone. "NONE" groups
---(piétin/hernie) match no product family and are never touched (rotation-only).
---
---It never touches the real crop density map, so crop already killed by the disease does NOT regrow (a
---fungicide protects/stops, it does not resurrect dead tissue) and yield already lost stays lost. The
---soil inoculum LOAD (rotation history) is untouched, so the field can be re-infected later if a
---susceptible host returns -- a spray is not a substitute for rotation.
---
---SERVER ONLY (state is server-authoritative). The caller triggers the existing broadcast so clients
---rebuild their overlay from the synced state. O(active groups on the field): no cell/pixel loop.
-- @param integer farmlandId
-- @param string treatmentType "FUNGICIDE" | "NEMATICIDE"
-- @param number coverage cure added this window (0..1); nil/<=0 means a full one-shot cure (console/debug)
-- @return integer treated number of matching infection groups advanced (cure raised) this window
function RealisticCropRotationDisease:treatField(farmlandId, treatmentType, coverage)
    if g_server == nil then return 0 end
    if treatmentType == nil then return 0 end
    local id = tonumber(farmlandId)
    if id == nil or id <= 0 then return 0 end

    local groups = self.state[id]
    if groups == nil then return 0 end

    local wanted = string.upper(tostring(treatmentType))
    if wanted ~= "FUNGICIDE" and wanted ~= "NEMATICIDE" then return 0 end

    -- Coverage added by this window (fraction of the field cured). nil/<=0 => full cure in one shot,
    -- so the console/debug one-shot and any legacy caller keep clearing the infection outright.
    local cov = tonumber(coverage)
    if cov == nil or cov <= 0 then cov = 1 end
    cov = math.min(1, cov)

    local treated = 0
    for group, s in pairs(groups) do
        -- Only groups whose reference treatment matches the product are cured; "NONE" groups
        -- (piétin/hernie) never match either family, so they are left untouched (rotation-only).
        if self:getTreatment(group) == wanted then
            s.cure = math.min(1, (s.cure or 0) + cov)
            treated = treated + 1
        end
    end

    if treated == 0 then return 0 end

    -- Fully-covered infections are cleared outright (progression stops, active foci gone); the rest
    -- keep a partial cure that will keep shrinking their foci on the next windows.
    for group, s in pairs(groups) do
        if self:getTreatment(group) == wanted and (s.cure or 0) >= 1 then
            groups[group] = nil
        end
    end

    local stillActive = next(groups) ~= nil
    if not stillActive then
        self.state[id] = nil
    end

    -- Realign THIS field's overlay foci with the reduced (cured/shrunk) state on the SERVER (clients
    -- realign from the synced state through applySyncData -> rebuildGridFromState). clearField only
    -- wipes the disease-foci OVERLAY grid, never the real crop, so cured tissue stays dead on the map.
    local mgr = self.manager
    local field = (mgr ~= nil and type(mgr.getFieldByFarmlandId) == "function")
        and mgr:getFieldByFarmlandId(id) or nil
    if field ~= nil and self.grid ~= nil and type(self.grid.clearField) == "function" then
        self.grid:clearField(field)
        if stillActive then
            -- Repaint the survivors' foci at their current cure (idempotent: same seed + unchanged
            -- severity, higher cure -> a strictly smaller dead area, no regrowth, no extra damage).
            for group, s in pairs(groups) do
                local curve = self:getCurve(group)
                if (s.severity or 0) >= curve.destroySeverity then
                    destroyCropField(field, id, s.seed, s.severity, curve, diseaseStateForGroup(group), self.grid, s.cure)
                end
            end
        end
    end

    -- Predictive risk is derived from the rotation history (getLoad), NOT from the active infection
    -- state, so curing an infection cannot move a risk band: no refreshRiskMap call is needed here.
    return treated
end

---Server: queues every field carrying an active infection for its daily disease step. Called on
---MessageType.DAY_CHANGED. The step itself is drained a few fields per frame (processDailyQueue), so
---a farm with many infected parcels never runs all the native passes in a single frame.
function RealisticCropRotationDisease:enqueueDailyProgress()
    if g_server == nil then return end
    for farmlandId, groups in pairs(self.state) do
        if groups ~= nil and next(groups) ~= nil and not self.dayQueued[farmlandId] then
            self.dayQueued[farmlandId] = true
            self.dayQueue[#self.dayQueue + 1] = farmlandId
        end
    end
end

---Server: drains up to DAILY_BUDGET_PER_FRAME fields from the daily queue, running one propagation
---(native modifier passes only) per field. Driven from the per-frame updateable so the day's work is
---spread across frames. Requests a single coalesced broadcast when it actually advanced something.
function RealisticCropRotationDisease:processDailyQueue()
    if g_server == nil or #self.dayQueue == 0 then return end
    local budget = RealisticCropRotationDisease.DAILY_BUDGET_PER_FRAME
    local processed = 0
    while processed < budget do
        local farmlandId = table.remove(self.dayQueue, 1)
        if farmlandId == nil then break end
        self.dayQueued[farmlandId] = nil
        self:propagate(farmlandId)
        processed = processed + 1
    end
    if processed > 0 and RealisticCropRotation ~= nil and type(RealisticCropRotation.requestBroadcast) == "function" then
        RealisticCropRotation.requestBroadcast()
    end
end

---Server: one field's per-period disease step (infection gate + propagation/destruction).
-- @param integer farmlandId
function RealisticCropRotationDisease:update(farmlandId)
    self:evaluateInfection(farmlandId)
    self:propagate(farmlandId)
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

---Display band of a field's predictive risk: 0 (none) .. 3 (high). Client-safe like getRisk.
-- @param integer farmlandId
-- @return integer band
function RealisticCropRotationDisease:getRiskBand(farmlandId)
    local risk = self:getRisk(farmlandId)
    if risk >= RealisticCropRotationDisease.RISK_BAND_HIGH_THRESHOLD then return 3 end
    if risk >= RealisticCropRotationDisease.RISK_BAND_MODERATE_THRESHOLD then return 2 end
    if risk >= RealisticCropRotationDisease.RISK_BAND_LOW_THRESHOLD then return 1 end
    return 0
end

---Repaints the runtime risk display map, OFF the UI path (BMP-style: the map overlay only ever
---renders existing maps; painting happens at gameplay events -- load, period tick, ownership
---change, MP sync). Incremental by default: only fields whose band changed since the last paint
---are repainted (usually none, at most a handful of native modifier passes). `force` wipes the map
---and repaints every owned field (load / ownership changes, where stale cells must be erased).
-- @param boolean force full wipe + repaint
function RealisticCropRotationDisease:refreshRiskMap(force)
    local grid = self.grid
    local mgr = self.manager
    if grid == nil or grid.riskMapId == nil or mgr == nil
        or type(mgr.getOwnedRotationFarmlandIds) ~= "function"
        or type(mgr.getFieldByFarmlandId) ~= "function"
        or type(grid.paintFarmlandRisk) ~= "function" then
        return
    end

    if force then
        grid:clearRiskMap()
        self.lastRiskBand = {}
    end

    for _, farmlandId in ipairs(mgr:getOwnedRotationFarmlandIds() or {}) do
        local id = tonumber(farmlandId)
        if id ~= nil and id > 0 then
            local band = self:getRiskBand(id)
            if band ~= self.lastRiskBand[id] then
                local field = mgr:getFieldByFarmlandId(id)
                if field ~= nil and grid:paintFarmlandRisk(field, id, band) then
                    self.lastRiskBand[id] = band
                end
            end
        end
    end
end

---Overlay state id of a field's DOMINANT active infection: the state (1..9) of the group with the
---highest severity, or 0 when the field has no active infection. A field counts as infected as soon
---as it carries ANY active entry (even a latent one, before any destruction) -- that is the meaning
---of "active foci". Reads the synced self.state + static config only, so it is deterministic across
---machines (client and server derive the same dominant state from the same synced state).
-- @param integer farmlandId
-- @return integer state 0 (none) or the dominant disease's overlay state id
function RealisticCropRotationDisease:dominantDiseaseState(farmlandId)
    local st = self.state[tonumber(farmlandId) or farmlandId]
    if st == nil then return 0 end
    local bestGroup, bestSeverity = nil, -1
    for group, s in pairs(st) do
        local sev = tonumber(s.severity) or 0
        if sev > bestSeverity then
            bestSeverity = sev
            bestGroup = group
        end
    end
    if bestGroup == nil then return 0 end
    return diseaseStateForGroup(bestGroup)
end

---Repaints the runtime infection display map ("active foci" view), OFF the UI path -- the exact twin
---of refreshRiskMap but driven by the active infection state instead of the predictive risk. Each
---owned field with an active infection is painted FULL in the colour of its DOMINANT disease (crisp
---field border, like the pressure view); a field with no active infection is cleared (state 0).
---Incremental by default: only fields whose dominant state changed since the last paint are repainted
---(usually none, at most a handful of native passes). `force` wipes the map and repaints every owned
---field (load / ownership changes / initial paint, where stale cells must be erased).
-- @param boolean force full wipe + repaint
function RealisticCropRotationDisease:refreshInfectionMap(force)
    local grid = self.grid
    local mgr = self.manager
    if grid == nil or grid.infectionMapId == nil or mgr == nil
        or type(mgr.getOwnedRotationFarmlandIds) ~= "function"
        or type(mgr.getFieldByFarmlandId) ~= "function"
        or type(grid.paintFarmlandInfection) ~= "function" then
        return
    end

    if force then
        grid:clearInfectionMap()
        self.lastInfectionState = {}
    end

    for _, farmlandId in ipairs(mgr:getOwnedRotationFarmlandIds() or {}) do
        local id = tonumber(farmlandId)
        if id ~= nil and id > 0 then
            local state = self:dominantDiseaseState(id)
            if state ~= self.lastInfectionState[id] then
                local field = mgr:getFieldByFarmlandId(id)
                if field ~= nil and grid:paintFarmlandInfection(field, id, state) then
                    self.lastInfectionState[id] = state
                end
            end
        end
    end
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
                    cure = tonumber(data.cure) or 0,
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

    return outState, outCrop
end

---Applies active disease state received from the server.
-- @param table state
-- @param table crop
function RealisticCropRotationDisease:applySyncData(state, crop)
    self.state = {}
    self.crop = {}

    for farmlandId, groups in pairs(state or {}) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and groups ~= nil then
            self.state[n] = {}
            for group, data in pairs(groups) do
                local groupName = string.upper(tostring(group))
                self.state[n][groupName] = {
                    severity = tonumber(data.severity) or 0,
                    seed = tonumber(data.seed) or 0,
                    cure = tonumber(data.cure) or 0,
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

    -- Clients never run the destruction loop, so they rebuild the active-infection overlay grid
    -- from the synced seed + severity. The server keeps its persistent .grle (the real destruction).
    if g_server == nil then
        self:rebuildGridFromState()
        -- Risk derives from the synced history, so a sync is the client's "state changed" event:
        -- repaint the bands that moved (all of them on the first sync, none on most others).
        self:refreshRiskMap(false)
        -- The active-foci view is painted from the same synced infection state (twin of the risk map),
        -- so a sync is also its "state changed" event: repaint the fields whose dominant disease moved.
        self:refreshInfectionMap(false)
    end
end

---Cheap order-independent signature of the destruction-relevant state, to skip rebuilds when a
---sync carried no change to it (e.g. a rotation-plan edit triggered the broadcast).
function RealisticCropRotationDisease:destructionSignature()
    local sig = 0
    for farmlandId, groups in pairs(self.state) do
        local fid = tonumber(farmlandId) or 0
        for group, s in pairs(groups) do
            local severity = tonumber(s.severity) or 0
            if severity >= self:getCurve(group).destroySeverity then
                -- severity drives the destroyed share; seed fixes the scatter; cure shrinks the foci
                -- -> all three change the grid, so a treatment window (cure rise) forces a client rebuild
                sig = sig + fid + severity + (tonumber(s.cure) or 0) * 7 + (tonumber(s.seed) or 0) % 100000
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
            local curve = self:getCurve(group)
            if field ~= nil and (s.severity or 0) >= curve.destroySeverity then
                local diseaseState = diseaseStateForGroup(group)
                -- grid only (no fruit) on the client; the field arg of nil for the crop is skipped inside.
                -- s.cure shrinks the painted foci exactly as the server did (same seed/severity/cure).
                destroyCropField(field, fid, s.seed, s.severity, curve, diseaseState, grid, s.cure)
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
            setXMLFloat(xmlFile, gKey .. "#cure", tonumber(s.cure) or 0)
            gi = gi + 1
        end
        fi = fi + 1
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
                        cure = getXMLFloat(xmlFile, gKey .. "#cure") or 0,
                    }
                end
                gi = gi + 1
            end
        end
        fi = fi + 1
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
        local known = {}
        if config ~= nil and config.diseaseIntervals ~= nil then
            for g in pairs(config.diseaseIntervals) do known[#known + 1] = g end
            table.sort(known)
        end
        return "Unknown disease group. Known groups: " .. (#known > 0 and table.concat(known, ", ") or "(none loaded)")
    end

    local value = tonumber(severity) or RealisticCropRotationDisease.INITIAL_SEVERITY
    value = math.max(0, math.min(1, value))

    local cropName = nil
    if self.manager ~= nil and type(self.manager.getActiveCropInfo) == "function" then
        cropName = self.manager:getActiveCropInfo(id)
    end

    -- Debug tool: forcing stays permissive (infect even a non-host crop), but warn when the crop in
    -- place is NOT a natural host of the group -- so the tester knows this is an artificial infection.
    local warning = ""
    local hostGroups = cropDiseaseGroups(cropName)
    if hostGroups == nil or not hostGroups[group] then
        local cropLabel = (cropName ~= nil and cropName ~= "") and tostring(cropName) or "(aucune culture)"
        warning = string.format("ATTENTION : %s n'est pas un hote naturel de %s (infection forcee pour test). ",
            cropLabel, self:getDisplayName(group))
    end

    self.state[id] = self.state[id] or {}
    self.state[id][group] = {
        severity = value,
        seed = math.random(1, 1000000),
    }
    self.crop[id] = cropName

    requestDiseaseConsoleBroadcast()
    return warning .. string.format("Forced %s infection on farmland %d (severity %.3f)", group, id, value)
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
    self.dayQueue = {}
    self.dayQueued = {}
    if self.grid ~= nil and type(self.grid.clearAll) == "function" then
        self.grid:clearAll()
    end
    requestDiseaseConsoleBroadcast()
    return "Cleared all disease state"
end
