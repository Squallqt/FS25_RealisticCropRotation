-- Copyright © 2026 Squallqt. All rights reserved.
-- Server-authoritative disease layer: soil inoculum from rotation history drives infection and progressive crop destruction.
RealisticCropRotationDisease = {}
local RealisticCropRotationDisease_mt = Class(RealisticCropRotationDisease)

RealisticCropRotationDisease.INFECTION_SCALE = 0.6  -- infection probability = load * this * weatherMod
RealisticCropRotationDisease.RAIN_BONUS = 1.6       -- fungal diseases (SCLEROTINIA) are amplified by rain
RealisticCropRotationDisease.INOCULUM_SEED = 0.12   -- inoculum a first host establishes on clean soil
RealisticCropRotationDisease.INOCULUM_GROWTH = 2.2  -- population multiplier per back-to-back host year
RealisticCropRotationDisease.INOCULUM_RESIDUAL = 0.1 -- fraction left after `interval` host-free years
RealisticCropRotationDisease.INITIAL_SEVERITY = 0.10
-- Per-pathogen rates come from cropConfig; these are fallbacks, calibrated at REFERENCE_DAYS_PER_PERIOD and rescaled by periodScale.
RealisticCropRotationDisease.REFERENCE_DAYS_PER_PERIOD = 9 -- calibration baseline for the day-based constants below
RealisticCropRotationDisease.DEFAULT_DAILY_GROWTH = 0.04 -- severity gained per in-game day at the reference (fallback)
RealisticCropRotationDisease.DESTROY_SEVERITY = 0.25 -- latent period: damage only above this (fallback)
RealisticCropRotationDisease.LOAD_SPEED_GAIN = 1.0  -- heavy soil inoculum speeds the epidemic (x1..x2 by load)
RealisticCropRotationDisease.INCUBATION_DAYS = 3    -- warm-weather latent period before severity climbs, at the reference
-- Fungal favourability by temperature (Celsius): full speed on the optimal plateau, tapering to a floor at frost/heat.
RealisticCropRotationDisease.TEMP_MIN = 3           -- at/below: coldest favourability (TEMP_FLOOR)
RealisticCropRotationDisease.TEMP_OPT_LOW = 10
RealisticCropRotationDisease.TEMP_OPT_HIGH = 25
RealisticCropRotationDisease.TEMP_MAX = 32          -- at/above: hottest favourability (TEMP_FLOOR)
RealisticCropRotationDisease.TEMP_FLOOR = 0.5       -- residual favourability at frost/extreme heat
-- Destruction targets a real area fraction of the parcel (measured via executeGet), so the dead share follows the curve regardless of noise distribution.
RealisticCropRotationDisease.DESTROY_PERLIN_OCTAVES = 6    -- minOctave: ~32 m organic foci (THE size knob; lower = bigger)
RealisticCropRotationDisease.DESTROY_PERLIN_FREQUENCY = 3  -- numOctave: added detail layers -> rough, irregular edges
RealisticCropRotationDisease.DESTROY_PERLIN_PERSISTENCE = 0.5
RealisticCropRotationDisease.DESTROY_PERLIN_MAX = 10000     -- noise value range (GREATER cut is 0..this)
RealisticCropRotationDisease.DESTROY_DEAD_FRACTION_MAX = 0.90 -- dead share of the parcel at full severity (fallback)
RealisticCropRotationDisease.DESTROY_RAMP_POWER = 1.5      -- gentle convex severity->dead ramp, spread across the range
RealisticCropRotationDisease.DESTROY_BAND_AREA = 0.06      -- extra area fraction of the scattered transition band
-- Transition band: an independent, finer-grained Perlin noise gives the edge a scattered/speckled look instead of a smooth contour.
RealisticCropRotationDisease.SPECKLE_FRACTION = 0.5         -- share of the band cleared as scattered cells
RealisticCropRotationDisease.SPECKLE_PERLIN_OCTAVES = 10    -- minOctave: much finer grain than the main shape
RealisticCropRotationDisease.SPECKLE_PERLIN_FREQUENCY = 4   -- numOctave: extra detail layers for a scattered look
RealisticCropRotationDisease.SPECKLE_PERLIN_PERSISTENCE = 0.5
RealisticCropRotationDisease.DESTROY_SEARCH_ITERATIONS = 14 -- binary-search steps matching area to a Perlin threshold
RealisticCropRotationDisease.DESTROY_SEARCH_TOLERANCE = 0.01 -- area precision that ends the search early
RealisticCropRotationDisease.DAILY_BUDGET_PER_FRAME = 1   -- fields whose daily disease step runs per frame (load spreading)

local soilUptakePrepareWarningShown = false
local soilUptakeConsumeWarningShown = false

-- Predictive-risk band thresholds: the worst pathogen load (getRisk) maps to a band 1..3 shown by the in-game map's pressure view.
RealisticCropRotationDisease.RISK_BAND_LOW_THRESHOLD = 0.10
RealisticCropRotationDisease.RISK_BAND_MODERATE_THRESHOLD = 0.25
RealisticCropRotationDisease.RISK_BAND_HIGH_THRESHOLD = 0.50

---Creates the disease layer bound to the rotation manager.
-- @param table manager
-- @return RealisticCropRotationDisease instance
function RealisticCropRotationDisease.new(manager, grid)
    soilUptakePrepareWarningShown = false
    soilUptakeConsumeWarningShown = false
    local self = setmetatable({}, RealisticCropRotationDisease_mt)
    self.manager = manager
    self.grid = grid
    self.state = {}          -- farmlandId -> group -> { severity, seed } (seed fixes the destruction scatter)
    self.crop = {}           -- farmlandId -> crop name the state belongs to
    self.lastRiskBand = {}   -- farmlandId -> band last painted into the risk display map
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

---Current air temperature (Celsius), or nil when the weather is unavailable.
local function currentTemperature()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil or env.weather == nil or type(env.weather.getCurrentTemperature) ~= "function" then
        return nil
    end
    return env.weather:getCurrentTemperature()
end

---Temperature favourability [TEMP_FLOOR..1]: 1 on the optimal plateau, tapering to the floor at frost/heat.
-- @param number temperature Celsius (or nil)
-- @return number factor
local function temperatureFactor(temperature)
    local D = RealisticCropRotationDisease
    local t = tonumber(temperature)
    if t == nil then return 1 end
    if t >= D.TEMP_OPT_LOW and t <= D.TEMP_OPT_HIGH then return 1 end
    if t < D.TEMP_OPT_LOW then
        if t <= D.TEMP_MIN then return D.TEMP_FLOOR end
        return D.TEMP_FLOOR + (1 - D.TEMP_FLOOR) * (t - D.TEMP_MIN) / (D.TEMP_OPT_LOW - D.TEMP_MIN)
    end
    if t >= D.TEMP_MAX then return D.TEMP_FLOOR end
    return D.TEMP_FLOOR + (1 - D.TEMP_FLOOR) * (D.TEMP_MAX - t) / (D.TEMP_MAX - D.TEMP_OPT_HIGH)
end

---Ratio of the save's days-per-period to REFERENCE_DAYS_PER_PERIOD; scales disease timing to any season length.
-- @return number scale (1 when the setting cannot be read)
local function periodScale()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local actual = env ~= nil and tonumber(env.daysPerPeriod) or nil
    if actual == nil or actual <= 0 then return 1 end
    return actual / RealisticCropRotationDisease.REFERENCE_DAYS_PER_PERIOD
end

---Weather modifier for a pathogen group: rain and temperature both modulate fungal groups only.
-- @param boolean raining
-- @param number temperature Celsius
-- @param string group Pathogen group name
-- @return number modifier
local function weatherModifier(raining, temperature, group)
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local fungal = config ~= nil and config.diseaseFungal ~= nil and config.diseaseFungal[group] == true
    if not fungal then return 1 end
    local rain = 1
    if raining then
        local factor = config ~= nil and config.diseaseWeatherFactors ~= nil and config.diseaseWeatherFactors[group] or nil
        rain = tonumber(factor) or RealisticCropRotationDisease.RAIN_BONUS
    end
    return rain * temperatureFactor(temperature)
end

---Stable overlay grid state (1..N) for a pathogen group, from cropConfig <diseaseGroup state=>.
-- @param string group Pathogen group name
-- @return integer state id (>= 1, fallback when config unavailable)
local function diseaseStateForGroup(group)
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local state = config ~= nil and config.diseaseStates ~= nil and config.diseaseStates[group] or nil
    return tonumber(state) or 1
end

---Fills a field's whole polygon with a pathogen's overlay colour on the persistent map grid.
-- @param table grid
-- @param table field
-- @param string group
local function paintInfectionPresence(grid, field, group)
    if grid == nil or grid.mapId == nil or field == nil
        or DensityMapModifier == nil or g_terrainNode == nil
        or type(field.getDensityMapPolygon) ~= "function" then
        return
    end
    local diseaseState = diseaseStateForGroup(group)
    if diseaseState == nil or diseaseState <= 0 then return end
    local polygon = field:getDensityMapPolygon()
    if polygon == nil then return end
    local gridModifier = DensityMapModifier.new(grid.mapId, 0, grid.numChannels, g_terrainNode)
    polygon:applyToModifier(gridModifier)
    gridModifier:executeSet(diseaseState)
    grid.changeRevision = (grid.changeRevision or 0) + 1
end

---Pathogen groups ordered by their stable overlay state id (cropConfig). Single source for the map overlay row order and the planner disease advice.
-- @return table list array of { group=, state= } sorted by state id, then group name
function RealisticCropRotationDisease.getOrderedGroups()
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

---Localized display name for a pathogen group (g_i18n key rcr_disease_name_<lowergroup>).
-- @param string group
-- @return string name
local function diseaseDisplayName(group)
    local key = "rcr_disease_name_" .. string.lower(tostring(group))
    if g_i18n ~= nil and type(g_i18n.hasText) == "function" and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return tostring(group)
end

---Public accessor for a pathogen group's display name, reused by the HUD/notifications/panels.
-- @param string group
-- @return string name
function RealisticCropRotationDisease:getDisplayName(group)
    return diseaseDisplayName(group)
end

---Reference treatment family for a pathogen group, from cropConfig (FUNGICIDE | NEMATICIDE | NONE).
-- @param string group
-- @return string treatment ("NONE" when unknown)
function RealisticCropRotationDisease:getTreatment(group)
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local t = config ~= nil and config.diseaseTreatments ~= nil and config.diseaseTreatments[group] or nil
    return t ~= nil and tostring(t) or "NONE"
end

---Localized treatment label for a pathogen group (g_i18n key rcr_disease_treatment_<lowergroup>).
-- @param string group
-- @return string label
function RealisticCropRotationDisease:getTreatmentName(group)
    local key = "rcr_disease_treatment_" .. string.lower(tostring(group))
    if g_i18n ~= nil and type(g_i18n.hasText) == "function" and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return key
end

---Soil inoculum load per pathogen from the field's rotation history alone; persists between crops.
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

    -- Walk oldest -> newest: a host multiplies the load, a host-free year decays it toward `residual`.
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

---Server: a living host at its pathogen's growth window may be infected by the field's load, rolled once per crop cycle.
-- @param integer farmlandId
-- @param boolean freshCycle True on any new planting; resets treatment only, never disease state
function RealisticCropRotationDisease:evaluateInfection(farmlandId, freshCycle)
    if g_server == nil then return end
    local mgr = self.manager
    if mgr == nil then return end
    local cropName, _, growthState = mgr:getActiveCropInfo(farmlandId)
    local field = type(mgr.getFieldByFarmlandId) == "function" and mgr:getFieldByFarmlandId(farmlandId) or nil

    -- Reset stays gated to a confirmed rotation to a different crop, never a momentary "no crop" read or same-crop replant.
    local previousCrop = self.crop[farmlandId]
    if cropName ~= nil then
        local rotated = previousCrop ~= nil and previousCrop ~= cropName
        if rotated then
            self.state[farmlandId] = nil
            -- Also drops the previous crop's foliar protection; soil nematicide keeps its independent countdown.
            if field ~= nil and self.grid ~= nil and type(self.grid.clearField) == "function" then
                self.grid:clearField(field)
            end
        elseif freshCycle and field ~= nil and self.grid ~= nil and type(self.grid.clearFieldProtectionFamily) == "function" then
            -- Same-crop replant ends foliar protection; soil nematicide follows its timed lifecycle.
            self.grid:clearFieldProtectionFamily(field, "FUNGICIDE")
        end
        self.crop[farmlandId] = cropName
    end
    if cropName == nil then return end -- no active infection without a living host

    local hostGroups = cropDiseaseGroups(cropName)
    if hostGroups == nil then return end
    local maturity = cropMaturity(cropName)
    -- Growth fraction toward maturity, or nil when the stage cannot be read (then we do not block).
    local frac = (maturity ~= nil and maturity > 0 and growthState ~= nil) and (growthState / maturity) or nil

    local windows = (RealisticCropRotation.cropConfig and RealisticCropRotation.cropConfig.diseaseWindows) or {}
    local raining = isRaining()
    local temperature = currentTemperature()
    for group, load in pairs(self:getLoad(farmlandId)) do
        if hostGroups[group] then
            local state = self.state[farmlandId]
            local alreadyInfected = state ~= nil and state[group] ~= nil
            -- No protection check here: spraying excludes the destructive consequence, not the infection start.
            if not alreadyInfected then
                local w = windows[group]
                -- Susceptible inside the growth window only; an unreadable stage never blocks.
                if w == nil or frac == nil or (frac >= w.from and frac <= (w.to or 1)) then
                    local chance = load * RealisticCropRotationDisease.INFECTION_SCALE * weatherModifier(raining, temperature, group)
                    if math.random() < chance then
                        self.state[farmlandId] = self.state[farmlandId] or {}
                        self.state[farmlandId][group] = {
                            severity = RealisticCropRotationDisease.INITIAL_SEVERITY,
                            -- seeds the Perlin destruction pattern; synced + saved so every client regenerates the identical dead area
                            seed = math.random(1, 1000000),
                            -- temperature-paced latent period, scaled to the save's calendar (periodScale)
                            incubation = RealisticCropRotationDisease.INCUBATION_DAYS * periodScale(),
                        }
                        -- Paints map presence for the new infection.
                        paintInfectionPresence(self.grid, field, group)
                        if RCRDiseaseNotificationEvent ~= nil
                            and type(RCRDiseaseNotificationEvent.sendEvent) == "function" then
                            RCRDiseaseNotificationEvent.sendEvent(farmlandId, group)
                        end
                    end
                end
            end
        end
    end
end

---Target dead area fraction for a severity: a gentle convex ramp from 0 at the latent threshold to the curve's deadFractionMax at full severity.
-- @param number severity
-- @param table curve Per-pathogen curve, or nil for module fallbacks
-- @return number fraction [0, deadFractionMax]
local function deadFractionForSeverity(severity, curve)
    local D = RealisticCropRotationDisease
    local destroySeverity = curve ~= nil and curve.destroySeverity or D.DESTROY_SEVERITY
    local deadFractionMax = curve ~= nil and curve.deadFractionMax or D.DESTROY_DEAD_FRACTION_MAX
    local power = curve ~= nil and curve.power or D.DESTROY_RAMP_POWER
    local sev = tonumber(severity) or 0
    local frac = math.max(0, math.min(1, (sev - destroySeverity) / math.max(1e-6, 1 - destroySeverity)))
    return deadFractionMax * (frac ^ power)
end

---Fraction of the field polygon whose Perlin field exceeds `threshold`, counted natively (executeGet, no write).
-- @param table field
-- @param integer seed
-- @param integer threshold
-- @param integer octaves
-- @param integer frequency
-- @param number persistence
-- @return number fraction [0,1]
local function perlinAreaFraction(field, seed, threshold, octaves, frequency, persistence)
    if field == nil or DensityMapModifier == nil or PerlinNoiseFilter == nil or g_terrainNode == nil
        or DensityValueCompareType == nil or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil
        or FieldDensityMap == nil or type(field.getDensityMapPolygon) ~= "function" then
        return 0
    end
    local polygon = field:getDensityMapPolygon()
    if polygon == nil then return 0 end
    local groundTypeMapId, groundFirstChannel, groundNumChannels =
        g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if groundTypeMapId == nil then return 0 end

    local modifier = DensityMapModifier.new(groundTypeMapId, groundFirstChannel, groundNumChannels, g_terrainNode)
    polygon:applyToModifier(modifier)
    local perlin = PerlinNoiseFilter.new(groundTypeMapId, octaves, frequency, persistence, tonumber(seed) or 1)
    perlin:setValueCompareParams(DensityValueCompareType.GREATER, threshold)

    local _, hits, total = modifier:executeGet(perlin)
    if total == nil or total <= 0 then return 0 end
    return (hits or 0) / total
end

---Binary-searches the Perlin GREATER threshold selecting `targetFraction` of the field; deterministic, so server and clients derive the same cut from the same seed + target.
-- @param table field
-- @param integer seed
-- @param number targetFraction
-- @param integer octaves
-- @param integer frequency
-- @param number persistence
-- @param integer hiBound
-- @return integer threshold
local function perlinThresholdForArea(field, seed, targetFraction, octaves, frequency, persistence, hiBound)
    local D = RealisticCropRotationDisease
    if targetFraction <= 0 then return D.DESTROY_PERLIN_MAX end
    if targetFraction >= 1 then return 0 end
    local lo, hi = 0, hiBound or D.DESTROY_PERLIN_MAX
    for _ = 1, D.DESTROY_SEARCH_ITERATIONS do
        local mid = math.floor((lo + hi) / 2)
        local area = perlinAreaFraction(field, seed, mid, octaves, frequency, persistence)
        if math.abs(area - targetFraction) <= D.DESTROY_SEARCH_TOLERANCE then return mid end
        -- Higher threshold selects fewer cells: too little selected area -> lower the threshold.
        if area < targetFraction then hi = mid else lo = mid end
        if hi - lo <= 1 then break end
    end
    return lo
end

---Deterministic second seed for the transition-band speckle noise, derived from the infection seed.
-- @param integer seed
-- @return integer
local function speckleSeedFor(seed)
    return ((tonumber(seed) or 1) * 7 + 13) % 1000000 + 1
end

---Per-pathogen destruction curve, from cropConfig with module fallbacks.
-- @param string group
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

---Builds a fresh eligible-fruit mask for one Perlin pass, preserving harvested and other terminal foliage states.
local function applyDestructionPass(desc, field, seed, threshold, protectionMapId, grid, speckled)
    local D = RealisticCropRotationDisease
    if grid == nil or grid.destructionMaskMapId == nil or field == nil or desc == nil
        or desc.terrainDataPlaneId == nil
        or DensityMapModifier == nil or DensityMapFilter == nil or PerlinNoiseFilter == nil
        or g_terrainNode == nil or DensityValueCompareType == nil or DensityCoordType == nil
        or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil or FieldDensityMap == nil
        or type(field.getDensityMapPolygon) ~= "function" then
        return false
    end
    local polygon = field:getDensityMapPolygon()
    if polygon == nil then return false end
    local groundTypeMapId = select(1, g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE))
    if groundTypeMapId == nil then return false end
    local minX, minZ, maxX, maxZ = RealisticCropRotationDiseaseGrid.fieldWorldBounds(field)
    if minX == nil then return false end

    -- Recomputed for every pass because protection and foliage state can change mid-epidemic.
    local clearModifier = DensityMapModifier.new(grid.destructionMaskMapId, 0, 1, g_terrainNode)
    clearModifier:setParallelogramWorldCoords(minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)
    clearModifier:executeSet(0)

    local maskModifier = DensityMapModifier.new(grid.destructionMaskMapId, 0, 1, g_terrainNode)
    polygon:applyToModifier(maskModifier)
    local shapePerlin = PerlinNoiseFilter.new(groundTypeMapId,
        D.DESTROY_PERLIN_OCTAVES, D.DESTROY_PERLIN_FREQUENCY, D.DESTROY_PERLIN_PERSISTENCE, tonumber(seed) or 1)
    shapePerlin:setValueCompareParams(DensityValueCompareType.GREATER, threshold)
    if protectionMapId ~= nil then
        local protectionFilter = DensityMapFilter.new(protectionMapId, 0, 1)
        protectionFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 0)
        maskModifier:executeSet(1, shapePerlin, protectionFilter)
    else
        maskModifier:executeSet(1, shapePerlin)
    end

    local eligibleFilter = DensityMapFilter.new(grid.destructionMaskMapId, 0, 1)
    eligibleFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)
    for _, state in ipairs(RealisticCropRotationSoilUptake.getTerminalDensityStates(desc)) do
        local terminalFilter = DensityMapFilter.new(
            desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels)
        terminalFilter:setValueCompareParams(DensityValueCompareType.EQUAL, state)
        maskModifier:executeSet(0, eligibleFilter, terminalFilter)
    end

    local writeModifier = DensityMapModifier.new(
        desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels, g_terrainNode)
    if DensityIndexCompareMode ~= nil then
        writeModifier:setNewTypeIndexMode(DensityIndexCompareMode.ZERO)
    end
    polygon:applyToModifier(writeModifier)
    if speckled then
        local speckleSeed = speckleSeedFor(seed)
        local speckleThreshold = perlinThresholdForArea(field, speckleSeed, D.SPECKLE_FRACTION,
            D.SPECKLE_PERLIN_OCTAVES, D.SPECKLE_PERLIN_FREQUENCY, D.SPECKLE_PERLIN_PERSISTENCE)
        local specklePerlin = PerlinNoiseFilter.new(groundTypeMapId,
            D.SPECKLE_PERLIN_OCTAVES, D.SPECKLE_PERLIN_FREQUENCY,
            D.SPECKLE_PERLIN_PERSISTENCE, speckleSeed)
        specklePerlin:setValueCompareParams(DensityValueCompareType.GREATER, speckleThreshold)
        writeModifier:executeSet(0, eligibleFilter, specklePerlin)
    else
        writeModifier:executeSet(0, eligibleFilter)
    end
    return true
end

---Applies one infection's real-crop destruction (Perlin core+band), then takes from the soil what those cells drew; server only.
local function destroyCropField(field, desc, farmlandId, seed, severity, curve, grid, protectionMapId, manager)
    local D = RealisticCropRotationDisease
    if field == nil or desc == nil or desc.terrainDataPlaneId == nil then return end
    local dead = deadFractionForSeverity(severity, curve)
    if dead <= 0 then return end
    local coreThreshold = perlinThresholdForArea(field, seed, dead,
        D.DESTROY_PERLIN_OCTAVES, D.DESTROY_PERLIN_FREQUENCY, D.DESTROY_PERLIN_PERSISTENCE)

    if g_server == nil then return end

    -- Each distinct target resolution gets a shared scratch mask.
    local uptakeSession = nil
    if RealisticCropRotationSoilUptake ~= nil
        and type(RealisticCropRotationSoilUptake.prepare) == "function" then
        local ok, result = pcall(
            RealisticCropRotationSoilUptake.prepare, manager, field, desc, farmlandId)
        if ok then
            uptakeSession = result
        elseif not soilUptakePrepareWarningShown then
            soilUptakePrepareWarningShown = true
            if Logging ~= nil and type(Logging.warning) == "function" then
                Logging.warning(
                    "[RealisticCropRotation] Disease soil snapshot failed; crop destruction continues without soil draw: %s",
                    tostring(result))
            end
        end
    end

    -- Scattered edge: only a random subset of cells in the band just outside the core is cleared.
    local bandFraction = math.min(1, dead + D.DESTROY_BAND_AREA)
    local bandThreshold = perlinThresholdForArea(field, seed, bandFraction,
        D.DESTROY_PERLIN_OCTAVES, D.DESTROY_PERLIN_FREQUENCY, D.DESTROY_PERLIN_PERSISTENCE, coreThreshold)
    applyDestructionPass(desc, field, seed, bandThreshold, protectionMapId, grid, true)
    applyDestructionPass(desc, field, seed, coreThreshold, protectionMapId, grid, false)

    -- Only cells that were standing before and empty afterwards consume soil inputs.
    if uptakeSession ~= nil and RealisticCropRotationSoilUptake ~= nil
        and type(RealisticCropRotationSoilUptake.consume) == "function" then
        local ok, errorMessage = pcall(RealisticCropRotationSoilUptake.consume, uptakeSession)
        if not ok and not soilUptakeConsumeWarningShown then
            soilUptakeConsumeWarningShown = true
            if Logging ~= nil and type(Logging.warning) == "function" then
                Logging.warning(
                    "[RealisticCropRotation] Disease soil draw failed after crop destruction: %s",
                    tostring(errorMessage))
            end
        end
    end
end

---Server: advances every infection on a field by one in-game day (drained from the daily queue), growing the destroyed area.
-- @param integer farmlandId
function RealisticCropRotationDisease:propagate(farmlandId)
    if g_server == nil then return end
    local groups = self.state[farmlandId]
    if groups == nil then return end

    local mgr = self.manager
    local field = (mgr ~= nil and type(mgr.getFieldByFarmlandId) == "function")
        and mgr:getFieldByFarmlandId(farmlandId) or nil
    local activeDesc = nil
    if mgr ~= nil and type(mgr.invalidateActiveCropCache) == "function"
        and type(mgr.getActiveCropInfo) == "function" then
        mgr:invalidateActiveCropCache(farmlandId)
        local activeCropName, fruitTypeIndex = mgr:getActiveCropInfo(farmlandId)
        if activeCropName ~= nil and fruitTypeIndex ~= nil
            and activeCropName == self.crop[farmlandId]
            and g_fruitTypeManager ~= nil then
            activeDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
        end
    end
    local raining = isRaining()
    local temperature = currentTemperature()
    local loads = self:getLoad(farmlandId)
    -- dailyGrowth is calibrated at REFERENCE_DAYS_PER_PERIOD; dividing by periodScale keeps it constant across season-length configs.
    local scale = periodScale()
    local destructionAttempted = false

    for group, s in pairs(groups) do
        if s.incubation ~= nil and s.incubation > 0 then
            -- Temperature-paced incubation: warm days burn it down fast, frost nearly stalls it.
            s.incubation = s.incubation - temperatureFactor(temperature)
            if s.incubation <= 0 then s.incubation = nil end
        else
            s.incubation = nil
            local curve = self:getCurve(group)
            -- Rain + temperature drive fungal speed; heavier soil inoculum accelerates the epidemic.
            local loadSpeed = 1 + RealisticCropRotationDisease.LOAD_SPEED_GAIN * math.min(1, loads[group] or 0)
            local growth = (curve.dailyGrowth / scale) * weatherModifier(raining, temperature, group) * loadSpeed
            s.severity = math.min(1, (s.severity or 0) + growth)
            if s.severity >= curve.destroySeverity and activeDesc ~= nil then
                -- Per-cell exclusion map for this group's treatment family; nil for NONE-treatment groups (rotation-only, no product shields them).
                local treatment = self:getTreatment(group)
                local protectionMapId = nil
                if self.grid ~= nil then
                    if treatment == "FUNGICIDE" then protectionMapId = self.grid.fungicideProtectionMapId
                    elseif treatment == "NEMATICIDE" then protectionMapId = self.grid.nematicideProtectionMapId end
                end
                destroyCropField(field, activeDesc, farmlandId, s.seed, s.severity, curve,
                    self.grid, protectionMapId, mgr)
                destructionAttempted = true
            end
        end
    end
    if destructionAttempted and mgr ~= nil
        and type(mgr.invalidateActiveCropCache) == "function" then
        mgr:invalidateActiveCropCache(farmlandId)
    end
end

---Server: queues every field with an active infection for its daily disease step (on MessageType.DAY_CHANGED).
function RealisticCropRotationDisease:enqueueDailyProgress()
    if g_server == nil then return end
    for farmlandId, groups in pairs(self.state) do
        if groups ~= nil and next(groups) ~= nil and not self.dayQueued[farmlandId] then
            self.dayQueued[farmlandId] = true
            self.dayQueue[#self.dayQueue + 1] = farmlandId
        end
    end
end

---Server: drains up to DAILY_BUDGET_PER_FRAME fields from the daily queue, requesting a coalesced broadcast when any advanced.
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

---Repaints the runtime risk display map off the UI path; incremental by default, `force` repaints every owned field.
-- @param boolean force
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

    -- Clients never run the destruction loop; they rebuild the active-infection overlay from the synced seed + severity instead.
    if g_server == nil then
        self:rebuildGridFromState()
        -- Risk derives from the synced history, so a sync is the client's cue to repaint any bands that moved.
        self:refreshRiskMap(false)
    end
end

---Order-independent signature of the active infection set.
function RealisticCropRotationDisease:destructionSignature()
    local sig = 0
    for farmlandId, groups in pairs(self.state) do
        local fid = tonumber(farmlandId) or 0
        for group in pairs(groups) do
            -- Farmland id + stable state id per group.
            sig = sig + fid + diseaseStateForGroup(group)
        end
    end
    return sig
end

---Repaints the persistent grid's presence colours from the synced infection state.
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
        if field ~= nil then
            for group in pairs(groups) do
                paintInfectionPresence(grid, field, group)
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

---Native aggregate check (executeGet): fraction of the field's polygon area marked protected.
-- @param table field
-- @param integer protectionMapId Protection density-map id, or nil
-- @return number coverage fraction [0,1]
local function getProtectionCoverage(field, protectionMapId)
    if field == nil or protectionMapId == nil or DensityMapModifier == nil or DensityMapFilter == nil
        or g_terrainNode == nil or DensityValueCompareType == nil
        or type(field.getDensityMapPolygon) ~= "function" then
        return 0
    end
    local polygon = field:getDensityMapPolygon()
    if polygon == nil then return 0 end

    local modifier = DensityMapModifier.new(protectionMapId, 0, 1, g_terrainNode)
    polygon:applyToModifier(modifier)

    local filter = DensityMapFilter.new(protectionMapId, 0, 1)
    filter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)

    local _, protectedPixels, totalPixels = modifier:executeGet(filter)
    if totalPixels == nil or totalPixels <= 0 then return 0 end
    return (protectedPixels or 0) / totalPixels
end

function RealisticCropRotationDisease:consoleDump(farmlandId)
    local ids = collectDiseaseFarmlandIds(self.manager, farmlandId)
    if #ids == 0 then return "No Realistic Crop Rotation farmland found" end

    local temperature = currentTemperature()
    Logging.info(
        "[RealisticCropRotation] weather temperature=%.1fC factor=%.2f raining=%s periodScale=%.2f",
        temperature, temperatureFactor(temperature), tostring(isRaining()), periodScale())

    for _, id in ipairs(ids) do
        local cropName, _, growthState = nil, nil, nil
        if self.manager ~= nil and type(self.manager.getActiveCropInfo) == "function" then
            cropName, _, growthState = self.manager:getActiveCropInfo(id)
        end

        -- Protected coverage uses the SAME per-cell exclusion the daily destroy pass reads, measured natively (no pixel loop).
        local protStr = "n/a"
        local field = (self.manager ~= nil and type(self.manager.getFieldByFarmlandId) == "function")
            and self.manager:getFieldByFarmlandId(id) or nil
        if field ~= nil and self.grid ~= nil then
            local fungCov = getProtectionCoverage(field, self.grid.fungicideProtectionMapId)
            local nemaCov = getProtectionCoverage(field, self.grid.nematicideProtectionMapId)
            protStr = string.format("FUNGICIDE=%.0f%%,NEMATICIDE=%.0f%%", fungCov * 100, nemaCov * 100)
        end

        Logging.info(
            "[RealisticCropRotation] disease farmland=%d crop=%s growth=%s load={%s} state={%s} protect={%s}",
            id,
            tostring(cropName),
            tostring(growthState),
            formatDiseaseLoads(self:getLoad(id)),
            formatDiseaseState(self:getState(id)),
            protStr)
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

    -- Debug tool: forcing stays permissive (infects even a non-host crop), but warns the tester it's an artificial infection.
    local warning = ""
    local hostGroups = cropDiseaseGroups(cropName)
    if hostGroups == nil or not hostGroups[group] then
        local cropLabel = (cropName ~= nil and cropName ~= "") and tostring(cropName) or "(no crop)"
        warning = string.format("WARNING: %s is not a natural host for %s (forced infection for testing). ",
            cropLabel, self:getDisplayName(group))
    end

    self.state[id] = self.state[id] or {}
    self.state[id][group] = {
        severity = value,
        seed = math.random(1, 1000000),
    }
    self.crop[id] = cropName

    -- Paints map presence, then applies real destruction if severity already clears the threshold.
    if self.manager ~= nil and type(self.manager.getFieldByFarmlandId) == "function" then
        paintInfectionPresence(self.grid, self.manager:getFieldByFarmlandId(id), group)
    end
    self:propagate(id)

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
            if field ~= nil then
                self.grid:clearField(field)
                if type(self.grid.clearFieldProtectionFamily) == "function" then
                    self.grid:clearFieldProtectionFamily(field, "NEMATICIDE")
                end
            end
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
