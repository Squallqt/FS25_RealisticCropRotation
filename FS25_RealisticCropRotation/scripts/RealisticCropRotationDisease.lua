-- Copyright © 2026 Squallqt. All rights reserved.
-- Server-authoritative disease layer: local reservoirs and external exposure drive infection and progressive crop destruction.
RealisticCropRotationDisease = {}
local RealisticCropRotationDisease_mt = Class(RealisticCropRotationDisease)

RealisticCropRotationDisease.INFECTION_SCALE = 0.6  -- infection probability = load * this * weatherMod
RealisticCropRotationDisease.RAIN_BONUS = 1.6       -- weather-driven diseases are amplified by rain
RealisticCropRotationDisease.INOCULUM_FLOOR = RealisticCropRotationDiseaseModel.INOCULUM_FLOOR
RealisticCropRotationDisease.INITIAL_SEVERITY = 0.10
-- Per-pathogen rates come from cropConfig; these are fallbacks, calibrated at REFERENCE_DAYS_PER_PERIOD and rescaled by periodScale.
RealisticCropRotationDisease.REFERENCE_DAYS_PER_PERIOD = 9 -- calibration baseline for the day-based constants below
RealisticCropRotationDisease.DEFAULT_DAILY_GROWTH = 0.04 -- severity gained per in-game day at the reference (fallback)
RealisticCropRotationDisease.DESTROY_SEVERITY = 0.25 -- latent period: damage only above this (fallback)
RealisticCropRotationDisease.LOAD_SPEED_GAIN = 1.0  -- stronger effective pressure speeds the epidemic (x1..x2 by load)
RealisticCropRotationDisease.INCUBATION_DAYS = 3    -- warm-weather latent period before severity climbs, at the reference
-- Temperature response (Celsius): weather-driven growth and every incubation use the same optimal plateau and frost/heat floor.
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
RealisticCropRotationDisease.PRESENCE_PATCH_FRACTION = 0.55 -- field share one infection colours on the map overlay
RealisticCropRotationDisease.DAILY_BUDGET_PER_FRAME = 1   -- fields whose daily disease step runs per frame (load spreading)

local soilUptakePrepareWarningShown = false
local soilUptakeConsumeWarningShown = false

-- Predictive-risk band thresholds: the worst pathogen load (getRisk) maps to a band 1..3 shown by the in-game map's pressure view.
RealisticCropRotationDisease.RISK_BAND_LOW_THRESHOLD = 0.05
RealisticCropRotationDisease.RISK_BAND_MODERATE_THRESHOLD = 0.25
RealisticCropRotationDisease.RISK_BAND_HIGH_THRESHOLD = 0.50

---Creates the disease layer bound to the rotation manager.
-- @param table manager
-- @param table grid
-- @return RealisticCropRotationDisease instance
function RealisticCropRotationDisease.new(manager, grid)
    soilUptakePrepareWarningShown = false
    soilUptakeConsumeWarningShown = false
    local self = setmetatable({}, RealisticCropRotationDisease_mt)
    self.manager = manager
    self.grid = grid
    self.state = {}          -- farmlandId -> group -> { severity, seed } (seed fixes the destruction scatter)
    self.reservoir = {}      -- farmlandId -> group -> persistent local load
    self.crop = {}           -- farmlandId -> crop name the state belongs to
    self.growth = {}         -- farmlandId -> growth stage last seen, detects a replant of the same crop
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    self.lastReservoirYear = env ~= nil and tonumber(env.currentYear) or nil
    self.lastRiskBand = {}   -- farmlandId -> band last painted into the risk display map
    self.dayQueue = {}       -- FIFO of farmlandIds awaiting their daily disease step (load spreading)
    self.dayQueued = {}      -- farmlandId -> true, dedupes the queue
    return self
end

local function cropDiseaseGroups(cropName)
    if cropName == nil or cropName == "" then return nil end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil or config.diseases == nil then return nil end
    return config.diseases[string.upper(tostring(cropName))]
end

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

local function isRaining()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil or env.weather == nil or type(env.weather.getIsRaining) ~= "function" then
        return false
    end
    return env.weather:getIsRaining() == true
end

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

---Weather modifier for a pathogen group: rain and temperature modulate explicitly weather-driven groups.
-- @param boolean raining
-- @param number temperature Celsius
-- @param string group Pathogen group name
-- @return number modifier
local function weatherModifier(raining, temperature, group)
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local weatherDriven = config ~= nil
        and config.diseaseWeatherDriven ~= nil
        and config.diseaseWeatherDriven[group] == true
    if not weatherDriven then return 1 end
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

---Stages a parcel's paintable cells on the scratch mask: worked ground inside the parcel, narrowed by the infection's patch.
-- @param table grid
-- @param table region
-- @param table perlin Patch filter, or nil for the whole worked ground
-- @param table groundFilter
-- @return table filter Scratch-mask filter, or nil
local function stageParcelPatch(grid, region, perlin, groundFilter)
    if grid.destructionMaskMapId == nil or DensityMapModifier == nil or DensityMapFilter == nil
        or DensityValueCompareType == nil or DensityCoordType == nil or g_terrainNode == nil then
        return nil
    end
    local minX, minZ, maxX, maxZ = RealisticCropRotationManager.regionWorldBounds(region)
    local outsideFilter = RealisticCropRotationManager.makeOutsideRegionFilter(region)
    if minX == nil or outsideFilter == nil then return nil end

    local maskModifier = DensityMapModifier.new(grid.destructionMaskMapId, 0, 1, g_terrainNode)
    maskModifier:setParallelogramWorldCoords(minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)
    maskModifier:executeSet(0)
    if perlin ~= nil then
        maskModifier:executeSet(1, perlin, groundFilter)
    else
        maskModifier:executeSet(1, groundFilter)
    end
    maskModifier:executeSet(0, outsideFilter)

    local patchFilter = DensityMapFilter.new(grid.destructionMaskMapId, 0, 1)
    patchFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)
    return patchFilter
end

---Paints a pathogen's overlay colour over its own Perlin patch.
-- @param table grid
-- @param table region
-- @param string group
-- @param integer seed Infection seed, nil fills the whole region
local function paintInfectionPresence(grid, region, group, seed)
    if grid.mapId == nil or region == nil
        or DensityMapModifier == nil or g_terrainNode == nil then
        return
    end
    local diseaseState = diseaseStateForGroup(group)
    if diseaseState <= 0 then return end
    local gridModifier = DensityMapModifier.new(grid.mapId, 0, grid.numChannels, g_terrainNode)
    if not RealisticCropRotationManager.applyRegionToModifier(region, gridModifier) then return end

    -- Each infection keeps its own patch.
    local perlin = nil
    local groundTypeMapId = (g_currentMission ~= nil and g_currentMission.fieldGroundSystem ~= nil
        and FieldDensityMap ~= nil)
        and select(1, g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)) or nil
    if seed ~= nil and groundTypeMapId ~= nil and PerlinNoiseFilter ~= nil and DensityValueCompareType ~= nil then
        local D = RealisticCropRotationDisease
        perlin = PerlinNoiseFilter.new(groundTypeMapId,
            D.DESTROY_PERLIN_OCTAVES, D.DESTROY_PERLIN_FREQUENCY, D.DESTROY_PERLIN_PERSISTENCE, seed)
        perlin:setValueCompareParams(DensityValueCompareType.GREATER,
            math.floor(D.DESTROY_PERLIN_MAX * (1 - D.PRESENCE_PATCH_FRACTION)))
    end

    -- Painted on worked ground only.
    local groundFilter = RealisticCropRotationManager.makeFieldGroundFilter()
    if region.filter ~= nil then
        local patchFilter = stageParcelPatch(grid, region, perlin, groundFilter)
        if patchFilter == nil then return end
        gridModifier:executeSet(diseaseState, patchFilter)
    elseif perlin ~= nil then
        gridModifier:executeSet(diseaseState, perlin, groundFilter)
    else
        gridModifier:executeSet(diseaseState, groundFilter)
    end
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

---Effective pathogen load for a specific standing crop, without mutating the reservoir.
-- @param integer farmlandId
-- @param string cropName
-- @return table load group -> [0,1]
local function effectiveLoadForCrop(self, farmlandId, cropName)
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if config == nil then return {} end
    return RealisticCropRotationDiseaseModel.buildHostLoad(
        self.reservoir[tonumber(farmlandId) or farmlandId],
        config.diseaseAmbient,
        cropDiseaseGroups(cropName),
        RealisticCropRotationDisease.INOCULUM_FLOOR)
end

---Inoculum that can infect the standing crop: local reservoir plus current external exposure.
-- @param integer farmlandId
-- @return table load group -> [0,1]
function RealisticCropRotationDisease:getLoad(farmlandId)
    return effectiveLoadForCrop(self, farmlandId, self.manager:getPendingHistoryCrop(farmlandId))
end

---Predictive pressure for the standing crop, using the same non-mutating sources as the infection roll.
-- @param integer farmlandId
-- @return table pressure group -> [0,1]
function RealisticCropRotationDisease:getPressure(farmlandId)
    return effectiveLoadForCrop(self, farmlandId, self.manager:getPendingHistoryCrop(farmlandId))
end

---Local field reservoir for diagnostics and synchronization.
-- @param integer farmlandId
-- @return table reservoir group -> [0,1], or nil
function RealisticCropRotationDisease:getReservoir(farmlandId)
    return self.reservoir[tonumber(farmlandId) or farmlandId]
end

---Ends the tracked crop cycle and deposits its real outbreaks into the local reservoir.
-- The active outbreak and foliar protection are then cleared exactly once.
-- @param integer farmlandId
-- @param string completedCropName Crop whose cycle ended
-- @return boolean changed
function RealisticCropRotationDisease:finishCropCycle(farmlandId, completedCropName)
    if g_server == nil then return false end
    local id = tonumber(farmlandId)
    if id == nil or id <= 0 then return false end

    local trackedCrop = self.crop[id]
    local completedCrop = completedCropName
    if completedCrop ~= nil and completedCrop ~= "" then
        completedCrop = string.upper(tostring(completedCrop))
    else
        completedCrop = trackedCrop
    end
    if trackedCrop ~= nil and completedCrop ~= nil
        and string.upper(tostring(trackedCrop)) ~= completedCrop then
        return false
    end

    local activeGroups = self.state[id]
    local hostGroups = cropDiseaseGroups(completedCrop)
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local reservoirClasses = config ~= nil and config.diseaseReservoirClasses or {}
    local reservoirChanged = false

    if activeGroups ~= nil and hostGroups ~= nil then
        local fieldReservoir = self.reservoir[id] or {}
        for group, data in pairs(activeGroups) do
            if hostGroups[group] then
                local previous = fieldReservoir[group] or 0
                local updated = RealisticCropRotationDiseaseModel.depositOutbreak(
                    previous,
                    data ~= nil and data.severity or 0,
                    reservoirClasses[group],
                    RealisticCropRotationDisease.INOCULUM_FLOOR)
                if updated ~= previous then
                    reservoirChanged = true
                    if updated > 0 then
                        fieldReservoir[group] = updated
                    else
                        fieldReservoir[group] = nil
                    end
                end
            end
        end
        if next(fieldReservoir) ~= nil then
            self.reservoir[id] = fieldReservoir
        else
            self.reservoir[id] = nil
        end
    end

    local activeChanged = activeGroups ~= nil
    self.state[id] = nil
    self.crop[id] = nil
    self.growth[id] = nil
    local region = self.manager:getFieldRegion(id)
    if region ~= nil then
        self.grid:clearField(region, id)
    end
    return reservoirChanged or activeChanged
end

---Applies the exact completed-crop steps accepted into rotation history.
-- @param integer farmlandId
-- @param table completedCrops Array of crop names
-- @return boolean changed
function RealisticCropRotationDisease:applyCompletedCrops(farmlandId, completedCrops)
    local changed = false
    for _, cropName in ipairs(completedCrops or {}) do
        if not RealisticCropRotation.isFallowCrop(cropName)
            and self:finishCropCycle(farmlandId, cropName) then
            changed = true
        end
    end
    return changed
end

---Ages every local reservoir by completed calendar years.
-- @param integer currentYear Current mission year
-- @return boolean reservoirChanged
function RealisticCropRotationDisease:advanceCalendar(currentYear)
    if g_server == nil then return false end
    local year = tonumber(currentYear)
    if year == nil then return false end
    year = math.floor(year)

    if self.lastReservoirYear == nil then
        self.lastReservoirYear = year
        return false
    end

    local elapsedYears = year - math.floor(tonumber(self.lastReservoirYear) or year)
    if elapsedYears <= 0 then return false end

    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local annualRetention = config ~= nil and config.diseaseAnnualRetention or {}
    local reservoirClasses = config ~= nil and config.diseaseReservoirClasses or {}
    local changed = false
    local agedReservoir = {}
    for farmlandId, groups in pairs(self.reservoir) do
        local agedGroups = {}
        for group, value in pairs(groups) do
            local aged = RealisticCropRotationDiseaseModel.ageReservoirValue(
                value,
                annualRetention[group],
                elapsedYears,
                RealisticCropRotationDisease.INOCULUM_FLOOR,
                reservoirClasses[group])
            if aged ~= value then
                changed = true
            end
            if aged > 0 then agedGroups[group] = aged end
        end
        if next(agedGroups) ~= nil then agedReservoir[farmlandId] = agedGroups end
    end
    self.reservoir = agedReservoir
    self.lastReservoirYear = year
    return changed
end

---True when the same crop dropped from a mature stage back to an early one.
-- @param string cropName
-- @param integer fruitTypeIndex
-- @param integer previousGrowth Growth stage this layer last saw
-- @param integer growthState Current growth stage
-- @param boolean rotated True when the crop already changed
-- @return boolean isReplant
function RealisticCropRotationDisease:isReplant(cropName, fruitTypeIndex, previousGrowth, growthState, rotated)
    if rotated or previousGrowth == nil or growthState == nil then return false end
    local service = self.manager.service

    local fruitType = service:getFruitTypeForCrop(cropName, fruitTypeIndex)
    if fruitType == nil or fruitType.regrows == true then return false end
    return service:isFreshReplantingGrowthDrop(fruitType, previousGrowth, growthState)
end

---Fungicide-treated share of a parcel's worked ground, safe when the grid or region is unavailable.
-- @param table region
-- @return number coverage [0,1]
function RealisticCropRotationDisease:getFungicideCoverage(region)
    return region ~= nil and self.grid:getProtectionCoverage(region, "FUNGICIDE") or 0
end

---Server: rolls infection once per period for a living host inside its pathogen's growth window.
-- @param integer farmlandId
function RealisticCropRotationDisease:evaluateInfection(farmlandId)
    if g_server == nil then return end
    local mgr = self.manager
    local cropName, fruitTypeIndex, growthState = mgr:getActiveCropInfo(farmlandId)
    local region = mgr:getFieldRegion(farmlandId)

    -- New planting: closes the previous cycle before tracking the new crop.
    local previousCrop = self.crop[farmlandId]
    local previousGrowth = self.growth[farmlandId]
    if cropName ~= nil then
        local rotated = previousCrop ~= nil and previousCrop ~= cropName
        if rotated or self:isReplant(cropName, fruitTypeIndex, previousGrowth, growthState, rotated) then
            self:finishCropCycle(farmlandId, previousCrop)
        end
        self.crop[farmlandId] = cropName
        self.growth[farmlandId] = growthState
    end
    if cropName == nil then
        -- No host left: the infection ends with the crop.
        local standing = mgr:getPendingHistoryCrop(farmlandId)
        if standing == nil and self.state[farmlandId] ~= nil then
            self:finishCropCycle(farmlandId, previousCrop)
        end
        return
    end

    local hostGroups = cropDiseaseGroups(cropName)
    if hostGroups == nil then return end
    local maturity = cropMaturity(cropName)
    -- Growth fraction toward maturity, or nil when the stage cannot be read (then we do not block).
    local frac = (maturity ~= nil and maturity > 0 and growthState ~= nil) and (growthState / maturity) or nil

    local windows = (RealisticCropRotation.cropConfig and RealisticCropRotation.cropConfig.diseaseWindows) or {}
    local raining = isRaining()
    local temperature = currentTemperature()
    -- Fungicide-treated ground share, resolved once and only when a FUNGICIDE group needs it.
    local fungicideCoverage = nil
    for group, load in pairs(effectiveLoadForCrop(self, farmlandId, cropName)) do
        if hostGroups[group] then
            local state = self.state[farmlandId]
            local alreadyInfected = state ~= nil and state[group] ~= nil
            if not alreadyInfected then
                local w = windows[group]
                -- Susceptible inside the growth window only; an unreadable stage never blocks.
                if w == nil or frac == nil or (frac >= w.from and frac <= (w.to or 1)) then
                    local chance = load * RealisticCropRotationDisease.INFECTION_SCALE * weatherModifier(raining, temperature, group)
                    -- Preventive fungicide lowers the outbreak chance in proportion to the treated area; other families are unaffected.
                    if self:getTreatment(group) == "FUNGICIDE" then
                        if fungicideCoverage == nil then fungicideCoverage = self:getFungicideCoverage(region) end
                        chance = chance * (1 - fungicideCoverage)
                    end
                    if math.random() < chance then
                        self.state[farmlandId] = self.state[farmlandId] or {}
                        self.state[farmlandId][group] = {
                            severity = RealisticCropRotationDisease.INITIAL_SEVERITY,
                            -- seeds the Perlin destruction pattern; synced + saved so every client regenerates the identical dead area
                            seed = math.random(1, 1000000),
                            -- temperature-paced latent period, scaled to the save's calendar (periodScale)
                            incubation = RealisticCropRotationDisease.INCUBATION_DAYS * periodScale(),
                        }
                        paintInfectionPresence(self.grid, region, group, self.state[farmlandId][group].seed)
                        RCRDiseaseNotificationEvent.sendEvent(farmlandId, group)
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

---Fraction of a region whose Perlin field exceeds `threshold`, counted natively (executeGet, no write).
-- @param table region
-- @param integer seed
-- @param integer threshold
-- @param integer octaves
-- @param integer frequency
-- @param number persistence
-- @param number knownGroundPixels Worked-ground pixel count, recounted when nil
-- @return number fraction [0,1]
-- @return number groundPixels
local function perlinAreaFraction(region, seed, threshold, octaves, frequency, persistence, knownGroundPixels)
    if region == nil or DensityMapModifier == nil or PerlinNoiseFilter == nil or g_terrainNode == nil
        or DensityValueCompareType == nil or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil
        or FieldDensityMap == nil then
        return 0
    end
    local groundTypeMapId, groundFirstChannel, groundNumChannels =
        g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
    if groundTypeMapId == nil then return 0 end

    local modifier = DensityMapModifier.new(groundTypeMapId, groundFirstChannel, groundNumChannels, g_terrainNode)
    if not RealisticCropRotationManager.applyRegionToModifier(region, modifier) then return 0 end
    local perlin = PerlinNoiseFilter.new(groundTypeMapId, octaves, frequency, persistence, tonumber(seed) or 1)
    perlin:setValueCompareParams(DensityValueCompareType.GREATER, threshold)

    -- Worked-ground pixels counted in their own pass, reused across a whole search.
    local groundFilter = RealisticCropRotationManager.makeFieldGroundFilter()
    local _, hits = modifier:executeGet(perlin, groundFilter, region.filter)
    local pixels = tonumber(knownGroundPixels)
    if pixels == nil then
        local _, counted = modifier:executeGet(groundFilter, region.filter)
        pixels = tonumber(counted)
    end
    if pixels == nil or pixels <= 0 then return 0, nil end
    return (hits or 0) / pixels, pixels
end

---Binary-searches the deterministic Perlin GREATER threshold selecting `targetFraction` of the region.
-- @param table region
-- @param integer seed
-- @param number targetFraction
-- @param integer octaves
-- @param integer frequency
-- @param number persistence
-- @param integer hiBound
-- @return integer threshold
local function perlinThresholdForArea(region, seed, targetFraction, octaves, frequency, persistence, hiBound)
    local D = RealisticCropRotationDisease
    if targetFraction <= 0 then return D.DESTROY_PERLIN_MAX end
    if targetFraction >= 1 then return 0 end
    local lo, hi = 0, hiBound or D.DESTROY_PERLIN_MAX
    local groundPixels = nil
    for _ = 1, D.DESTROY_SEARCH_ITERATIONS do
        local mid = math.floor((lo + hi) / 2)
        local area
        area, groundPixels = perlinAreaFraction(region, seed, mid, octaves, frequency, persistence, groundPixels)
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

local function applyDestructionPass(desc, region, seed, threshold, protectionMapId, grid, speckled)
    local D = RealisticCropRotationDisease
    if grid.destructionMaskMapId == nil or region == nil or desc == nil
        or desc.terrainDataPlaneId == nil
        or DensityMapModifier == nil or DensityMapFilter == nil or PerlinNoiseFilter == nil
        or g_terrainNode == nil or DensityValueCompareType == nil or DensityCoordType == nil
        or g_currentMission == nil or g_currentMission.fieldGroundSystem == nil or FieldDensityMap == nil then
        return false
    end
    local groundTypeMapId = select(1, g_currentMission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE))
    if groundTypeMapId == nil then return false end
    local minX, minZ, maxX, maxZ = RealisticCropRotationManager.regionWorldBounds(region)
    if minX == nil then return false end

    -- Recomputed for every pass because protection and foliage state can change mid-epidemic.
    local clearModifier = DensityMapModifier.new(grid.destructionMaskMapId, 0, 1, g_terrainNode)
    clearModifier:setParallelogramWorldCoords(minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)
    clearModifier:executeSet(0)

    local maskModifier = DensityMapModifier.new(grid.destructionMaskMapId, 0, 1, g_terrainNode)
    if not RealisticCropRotationManager.applyRegionToModifier(region, maskModifier) then return false end
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

    -- Parcel mask folded into the scratch mask.
    local outsideFilter = RealisticCropRotationManager.makeOutsideRegionFilter(region)
    if outsideFilter ~= nil then
        maskModifier:executeSet(0, outsideFilter)
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
    if not RealisticCropRotationManager.applyRegionToModifier(region, writeModifier) then return false end
    if speckled then
        local speckleSeed = speckleSeedFor(seed)
        local speckleThreshold = perlinThresholdForArea(region, speckleSeed, D.SPECKLE_FRACTION,
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

local function destroyCropField(region, desc, farmlandId, seed, severity, curve, grid, protectionMapId, manager)
    local D = RealisticCropRotationDisease
    if region == nil or desc == nil or desc.terrainDataPlaneId == nil then return end
    local dead = deadFractionForSeverity(severity, curve)
    if dead <= 0 then return end
    local coreThreshold = perlinThresholdForArea(region, seed, dead,
        D.DESTROY_PERLIN_OCTAVES, D.DESTROY_PERLIN_FREQUENCY, D.DESTROY_PERLIN_PERSISTENCE)

    if g_server == nil then return end

    -- Each distinct target resolution gets a shared scratch mask.
    local uptakeSession = nil
    local ok, result = pcall(
        RealisticCropRotationSoilUptake.prepare, manager, region, desc, farmlandId)
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

    -- Scattered edge: only a random subset of cells in the band just outside the core is cleared.
    local bandFraction = math.min(1, dead + D.DESTROY_BAND_AREA)
    local bandThreshold = perlinThresholdForArea(region, seed, bandFraction,
        D.DESTROY_PERLIN_OCTAVES, D.DESTROY_PERLIN_FREQUENCY, D.DESTROY_PERLIN_PERSISTENCE, coreThreshold)
    applyDestructionPass(desc, region, seed, bandThreshold, protectionMapId, grid, true)
    applyDestructionPass(desc, region, seed, coreThreshold, protectionMapId, grid, false)

    -- Only cells that were standing before and empty afterwards consume soil inputs.
    if uptakeSession ~= nil then
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
    local region = mgr:getFieldRegion(farmlandId)
    local activeDesc = nil
    local hostCropName = nil
    mgr:invalidateActiveCropCache(farmlandId)
    local fruitTypeIndex
    hostCropName, fruitTypeIndex = mgr:getActiveCropInfo(farmlandId)
    if hostCropName ~= nil and fruitTypeIndex ~= nil
        and hostCropName == self.crop[farmlandId]
        and g_fruitTypeManager ~= nil then
        activeDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    end

    -- An outbreak ends with its crop; its final severity is deposited before active state is cleared.
    if hostCropName == nil then
        local standing = mgr:getPendingHistoryCrop(farmlandId)
        if standing == nil then
            self:finishCropCycle(farmlandId, self.crop[farmlandId])
            return
        end
    elseif hostCropName ~= self.crop[farmlandId] then
        self:finishCropCycle(farmlandId, self.crop[farmlandId])
        return
    end
    local raining = isRaining()
    local temperature = currentTemperature()
    local loads = effectiveLoadForCrop(self, farmlandId, hostCropName)
    -- dailyGrowth is calibrated at REFERENCE_DAYS_PER_PERIOD; dividing by periodScale keeps it constant across season-length configs.
    local scale = periodScale()
    local destructionAttempted = false
    -- Fungicide-treated ground share, resolved once and only when a FUNGICIDE group needs it.
    local fungicideCoverage = nil

    for group, s in pairs(groups) do
        if s.incubation ~= nil and s.incubation > 0 then
            -- Temperature-paced incubation: warm days burn it down fast, frost nearly stalls it.
            s.incubation = s.incubation - temperatureFactor(temperature)
            if s.incubation <= 0 then s.incubation = nil end
        elseif activeDesc ~= nil then
            -- Severity climbs only under a living host.
            s.incubation = nil
            local curve = self:getCurve(group)
            -- Weather drives sensitive groups; stronger effective pressure accelerates the epidemic.
            local loadSpeed = 1 + RealisticCropRotationDisease.LOAD_SPEED_GAIN * math.min(1, loads[group] or 0)
            local growth = (curve.dailyGrowth / scale) * weatherModifier(raining, temperature, group) * loadSpeed
            -- Curative fungicide freezes the climb in proportion to the treated area; other families are unaffected.
            if self:getTreatment(group) == "FUNGICIDE" then
                if fungicideCoverage == nil then fungicideCoverage = self:getFungicideCoverage(region) end
                growth = growth * (1 - fungicideCoverage)
            end
            s.severity = math.min(1, (s.severity or 0) + growth)
            if s.severity >= curve.destroySeverity then
                -- Per-cell exclusion map for this group's treatment family; nil for NONE-treatment groups (rotation-only, no product shields them).
                local treatment = self:getTreatment(group)
                local protectionMapId = nil
                if treatment == "FUNGICIDE" then protectionMapId = self.grid.fungicideProtectionMapId
                elseif treatment == "NEMATICIDE" then protectionMapId = self.grid.nematicideProtectionMapId end
                destroyCropField(region, activeDesc, farmlandId, s.seed, s.severity, curve,
                    self.grid, protectionMapId, mgr)
                destructionAttempted = true
            end
        end
    end
    if destructionAttempted then
        mgr:invalidateActiveCropCache(farmlandId)
    end
end

function RealisticCropRotationDisease:enqueueDailyProgress()
    if g_server == nil then return end
    for farmlandId, groups in pairs(self.state) do
        if groups ~= nil and next(groups) ~= nil and not self.dayQueued[farmlandId] then
            self.dayQueued[farmlandId] = true
            self.dayQueue[#self.dayQueue + 1] = farmlandId
        end
    end
end

---Drains up to the requested number of farmland entries from the daily disease queue.
-- @param RealisticCropRotationDisease self
-- @param number budget
-- @return integer processed
local function drainDailyQueueBudget(self, budget)
    local processed = 0
    while processed < budget do
        local farmlandId = table.remove(self.dayQueue, 1)
        if farmlandId == nil then break end
        self.dayQueued[farmlandId] = nil
        self:propagate(farmlandId)
        processed = processed + 1
    end
    return processed
end

---Server: drains the per-frame daily queue budget, broadcasts when fields advance, and returns the processed count.
-- @return integer processed
function RealisticCropRotationDisease:processDailyQueue()
    if g_server == nil or #self.dayQueue == 0 then return 0 end
    local processed = drainDailyQueueBudget(self, RealisticCropRotationDisease.DAILY_BUDGET_PER_FRAME)
    if processed > 0 then
        RealisticCropRotation.requestBroadcast()
    end
    return processed
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

---Predictive disease risk for a field: the worst pathogen pressure, standing crop included, in [0,1].
-- @param integer farmlandId
-- @return number risk
function RealisticCropRotationDisease:getRisk(farmlandId)
    local risk = 0
    for _, load in pairs(self:getPressure(farmlandId)) do
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
    if grid.riskMapId == nil then return end

    if force then
        grid:clearRiskMap()
        self.lastRiskBand = {}
    end

    for _, farmlandId in ipairs(mgr:getOwnedRotationFarmlandIds() or {}) do
        local id = tonumber(farmlandId)
        if id ~= nil and id > 0 then
            local band = self:getRiskBand(id)
            if band ~= self.lastRiskBand[id] then
                local region = mgr:getFieldRegion(id)
                if region ~= nil and grid:paintFarmlandRisk(region, id, band) then
                    self.lastRiskBand[id] = band
                end
            end
        end
    end
end

---Copies active disease state into a network-safe table.
-- @return table state
-- @return table crop
-- @return table reservoir
function RealisticCropRotationDisease:getSyncData()
    local outState = {}
    local outCrop = {}
    local outReservoir = {}

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

    for farmlandId, groups in pairs(self.reservoir or {}) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and groups ~= nil then
            for group, value in pairs(groups) do
                local normalized = RealisticCropRotationDiseaseModel.normalizeLoad(
                    value,
                    RealisticCropRotationDisease.INOCULUM_FLOOR)
                if normalized > 0 then
                    outReservoir[n] = outReservoir[n] or {}
                    outReservoir[n][string.upper(tostring(group))] = normalized
                end
            end
        end
    end

    return outState, outCrop, outReservoir
end

---Applies active disease state received from the server.
-- @param table state
-- @param table crop
-- @param table reservoir
function RealisticCropRotationDisease:applySyncData(state, crop, reservoir)
    self.state = {}
    self.crop = {}
    self.reservoir = {}

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

    for farmlandId, groups in pairs(reservoir or {}) do
        local n = tonumber(farmlandId)
        if n ~= nil and n > 0 and groups ~= nil then
            for group, value in pairs(groups) do
                local normalized = RealisticCropRotationDiseaseModel.normalizeLoad(
                    value,
                    RealisticCropRotationDisease.INOCULUM_FLOOR)
                if normalized > 0 then
                    self.reservoir[n] = self.reservoir[n] or {}
                    self.reservoir[n][string.upper(tostring(group))] = normalized
                end
            end
        end
    end

    -- Clients never run the destruction loop; they rebuild the active-infection overlay from the synced seed + severity instead.
    if g_server == nil then
        self:rebuildGridFromState()
        -- Risk derives from the synced history, so a sync is the client's cue to repaint any bands that moved.
        self:refreshRiskMap(false)
    end
end

---Worst infection on a field: highest severity, ties broken by overlay state id.
-- @param integer farmlandId
-- @param function isEnabled Optional predicate on the group name
-- @return string group, or nil
-- @return number severity
function RealisticCropRotationDisease:getWorstGroup(farmlandId, isEnabled)
    local groups = self:getState(farmlandId)
    local bestGroup, bestSeverity, bestState = nil, -1, nil
    for group, s in pairs(groups or {}) do
        if isEnabled == nil or isEnabled(group) then
            local severity = tonumber(s.severity) or 0
            local state = diseaseStateForGroup(group)
            if severity > bestSeverity
                or (severity == bestSeverity and bestState ~= nil and state < bestState) then
                bestGroup, bestSeverity, bestState = group, severity, state
            end
        end
    end
    if bestGroup == nil then return nil, 0 end
    return bestGroup, bestSeverity
end

---Order-independent signature of the active infection set.
-- @return string signature
function RealisticCropRotationDisease:destructionSignature()
    local parts = {}
    for farmlandId, groups in pairs(self.state) do
        local fid = math.floor(tonumber(farmlandId) or 0)
        for group, data in pairs(groups) do
            local groupName = tostring(group)
            local seed = math.floor(tonumber(data.seed) or 0)
            local severity = tonumber(data.severity) or 0
            parts[#parts + 1] = string.format(
                "%d:%d:%s:%d:%.9g", fid, #groupName, groupName, seed, severity)
        end
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

---Repaints one parcel's overlay from its infection state, weakest colour first (stronger paints last, on top).
-- @param table grid
-- @param table region
-- @param table stateForField group -> { severity, seed }
local function repaintFieldOverlay(grid, region, stateForField)
    if region == nil or stateForField == nil then return end
    local ordered = {}
    for group, s in pairs(stateForField) do
        ordered[#ordered + 1] = { group = group, severity = tonumber(s.severity) or 0, seed = s.seed }
    end
    table.sort(ordered, function(a, b)
        if a.severity == b.severity then return tostring(a.group) > tostring(b.group) end
        return a.severity < b.severity
    end)
    for _, entry in ipairs(ordered) do
        paintInfectionPresence(grid, region, entry.group, entry.seed)
    end
end

function RealisticCropRotationDisease:rebuildGridFromState()
    local grid = self.grid
    if grid.mapId == nil then return end
    local signature = self:destructionSignature()
    if signature == self.lastGridSignature then return end
    self.lastGridSignature = signature

    local mgr = self.manager
    grid:clearAll()
    for farmlandId in pairs(self.state) do
        local fid = tonumber(farmlandId)
        repaintFieldOverlay(grid, mgr:getFieldRegion(fid), self.state[farmlandId])
    end
end

local function sortedDiseaseFarmlandIds(state, reservoir)
    local seen = {}
    for farmlandId in pairs(state or {}) do
        local id = tonumber(farmlandId)
        if id ~= nil and id > 0 then seen[id] = true end
    end
    for farmlandId in pairs(reservoir or {}) do
        local id = tonumber(farmlandId)
        if id ~= nil and id > 0 then seen[id] = true end
    end
    local ids = {}
    for id in pairs(seen) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

local function sortedDiseaseGroupNames(groups)
    local names = {}
    for group in pairs(groups or {}) do names[#names + 1] = tostring(group) end
    table.sort(names)
    return names
end

---Persists active outbreaks and local reservoirs to the savegame folder.
-- @param string savegamePath Savegame folder path (trailing slash)
function RealisticCropRotationDisease:saveToXML(savegamePath)
    if savegamePath == nil or savegamePath == "" then return end
    local xmlFile = createXMLFile("rcrDisease", savegamePath .. "realisticCropRotationDisease.xml", "realisticCropRotationDisease")
    if xmlFile == nil or xmlFile == 0 then return end

    if self.lastReservoirYear ~= nil then
        setXMLInt(xmlFile, "realisticCropRotationDisease#lastReservoirYear",
            math.floor(tonumber(self.lastReservoirYear) or 0))
    end

    for fi, farmlandId in ipairs(sortedDiseaseFarmlandIds(self.state, self.reservoir)) do
        local groups = self.state[farmlandId] or {}
        local fKey = string.format("realisticCropRotationDisease.farmland(%d)", fi - 1)
        setXMLInt(xmlFile, fKey .. "#id", farmlandId)
        if self.crop[farmlandId] ~= nil then setXMLString(xmlFile, fKey .. "#crop", tostring(self.crop[farmlandId])) end
        if self.growth[farmlandId] ~= nil then setXMLInt(xmlFile, fKey .. "#growth", math.floor(self.growth[farmlandId])) end
        for gi, group in ipairs(sortedDiseaseGroupNames(groups)) do
            local s = groups[group]
            local gKey = string.format("%s.group(%d)", fKey, gi - 1)
            setXMLString(xmlFile, gKey .. "#name", group)
            setXMLFloat(xmlFile, gKey .. "#severity", s.severity or 0)
            setXMLInt(xmlFile, gKey .. "#seed", math.floor(tonumber(s.seed) or 0))
            -- Latent period, kept across reloads.
            if s.incubation ~= nil then setXMLFloat(xmlFile, gKey .. "#incubation", s.incubation) end
        end

        local fieldReservoir = self.reservoir[farmlandId] or {}
        for ri, group in ipairs(sortedDiseaseGroupNames(fieldReservoir)) do
            local rKey = string.format("%s.reservoir(%d)", fKey, ri - 1)
            setXMLString(xmlFile, rKey .. "#name", group)
            setXMLFloat(xmlFile, rKey .. "#load", fieldReservoir[group])
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

    self.state, self.crop, self.growth, self.reservoir = {}, {}, {}, {}
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    local currentYear = environment ~= nil and tonumber(environment.currentYear) or nil
    self.lastReservoirYear =
        getXMLInt(xmlFile, "realisticCropRotationDisease#lastReservoirYear") or currentYear

    local fi = 0
    while true do
        local fKey = string.format("realisticCropRotationDisease.farmland(%d)", fi)
        if not hasXMLProperty(xmlFile, fKey) then break end
        local id = getXMLInt(xmlFile, fKey .. "#id")
        if id ~= nil then
            self.crop[id] = getXMLString(xmlFile, fKey .. "#crop")
            self.growth[id] = getXMLInt(xmlFile, fKey .. "#growth")
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
                        incubation = getXMLFloat(xmlFile, gKey .. "#incubation"),
                    }
                end
                gi = gi + 1
            end

            local ri = 0
            while true do
                local rKey = string.format("%s.reservoir(%d)", fKey, ri)
                if not hasXMLProperty(xmlFile, rKey) then break end
                local name = getXMLString(xmlFile, rKey .. "#name")
                local load = RealisticCropRotationDiseaseModel.normalizeLoad(
                    getXMLFloat(xmlFile, rKey .. "#load"),
                    RealisticCropRotationDisease.INOCULUM_FLOOR)
                if name ~= nil and name ~= "" and load > 0 then
                    self.reservoir[id] = self.reservoir[id] or {}
                    self.reservoir[id][string.upper(tostring(name))] = load
                end
                ri = ri + 1
            end
        end
        fi = fi + 1
    end

    delete(xmlFile)
end

function RealisticCropRotationDisease:registerConsoleCommands()
    if self.consoleCommandsRegistered or type(addConsoleCommand) ~= "function" then return end

    addConsoleCommand("rcrDisease", "Print Realistic Crop Rotation disease state", "consoleDump", self, "[farmlandId]")
    addConsoleCommand("rcrDiseaseInfect", "Force a disease infection: rcrDiseaseInfect <farmlandId> <group> [attackLevel]", "consoleInfect", self, "farmlandId; group; [attackLevel]")
    addConsoleCommand("rcrDiseaseTick", "Run one disease update tick: rcrDiseaseTick [farmlandId]", "consoleTick", self, "[farmlandId]")
    addConsoleCommand("rcrDiseaseClear", "Clear all disease data: rcrDiseaseClear [farmlandId]", "consoleClear", self, "[farmlandId]")

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

local function formatDiseaseValues(values, nestedField)
    values = values or {}
    local groups = {}
    for group in pairs(values) do
        groups[#groups + 1] = tostring(group)
    end
    table.sort(groups)

    if #groups == 0 then return "none" end

    local parts = {}
    for _, group in ipairs(groups) do
        local value = values[group]
        if nestedField ~= nil then
            local data = value or {}
            value = data[nestedField]
        end
        parts[#parts + 1] = string.format("%s=%.3f", group, tonumber(value) or 0)
    end
    return table.concat(parts, ", ")
end

local function formatDiseaseLoads(load)
    return formatDiseaseValues(load)
end

local function formatDiseaseState(state)
    return formatDiseaseValues(state, "severity")
end

local function collectDiseaseFarmlandIds(manager, farmlandId)
    local n = tonumber(farmlandId)
    if n ~= nil and n > 0 then return { n } end

    local out = {}
    for _, id in ipairs(manager:getOwnedRotationFarmlandIds() or {}) do
        local numericId = tonumber(id)
        if numericId ~= nil and numericId > 0 then out[#out + 1] = numericId end
    end
    table.sort(out)
    return out
end

local function requestDiseaseConsoleBroadcast()
    RealisticCropRotation.requestBroadcast()
end

function RealisticCropRotationDisease:consoleDump(farmlandId)
    local ids = collectDiseaseFarmlandIds(self.manager, farmlandId)
    if #ids == 0 then return "No Realistic Crop Rotation farmland found" end

    local temperature = currentTemperature()
    -- Temperature formatted as a string, nil-safe.
    Logging.info(
        "[RealisticCropRotation] weather temperature=%s factor=%.2f raining=%s periodScale=%.2f",
        temperature ~= nil and string.format("%.1fC", temperature) or "n/a",
        temperatureFactor(temperature), tostring(isRaining()), periodScale())

    for _, id in ipairs(ids) do
        local cropName, _, growthState = self.manager:getActiveCropInfo(id)

        -- Protected coverage uses the SAME per-cell exclusion the daily destroy pass reads, measured natively (no pixel loop).
        local protStr = "n/a"
        local region = self.manager:getFieldRegion(id)
        if region ~= nil then
            local fungCov = self.grid:getProtectionCoverage(region, "FUNGICIDE")
            local nemaCov = self.grid:getProtectionCoverage(region, "NEMATICIDE")
            protStr = string.format("FUNGICIDE=%.0f%%,NEMATICIDE=%.0f%%", fungCov * 100, nemaCov * 100)
        end

        -- Load feeds the infection roll, pressure feeds the map, reservoir is the saved local source.
        Logging.info(
            "[RealisticCropRotation] disease farmland=%d crop=%s growth=%s fieldRisk={%s} effectiveRisk={%s} mapRisk={%s} riskBand=%d active={%s} protection={%s}",
            id,
            tostring(cropName),
            tostring(growthState),
            formatDiseaseLoads(self:getReservoir(id)),
            formatDiseaseLoads(self:getLoad(id)),
            formatDiseaseLoads(self:getPressure(id)),
            self:getRiskBand(id),
            formatDiseaseState(self:getState(id)),
            protStr)
    end

    return string.format("Printed disease state for %d farmland(s)", #ids)
end

function RealisticCropRotationDisease:consoleInfect(farmlandId, groupName, severity)
    -- Relayed to the server when typed on a client, master users only.
    if g_server == nil then
        return RCRAdminCommandEvent ~= nil
            and RCRAdminCommandEvent.request("rcrDiseaseInfect", farmlandId, groupName, severity)
            or "rcrDiseaseInfect is available on server/host only"
    end

    local id = tonumber(farmlandId)
    if id == nil or id <= 0 then
        return "Usage: rcrDiseaseInfect <farmlandId> <group> [attackLevel]"
    end

    local group = groupName ~= nil and string.upper(tostring(groupName)) or nil
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    if group == nil or group == "" or config == nil
        or config.diseasePlannerIntervals == nil
        or config.diseasePlannerIntervals[group] == nil then
        local known = {}
        if config ~= nil and config.diseasePlannerIntervals ~= nil then
            for g in pairs(config.diseasePlannerIntervals) do known[#known + 1] = g end
            table.sort(known)
        end
        return "Unknown disease group. Known groups: " .. (#known > 0 and table.concat(known, ", ") or "(none loaded)")
    end

    local value = tonumber(severity) or RealisticCropRotationDisease.INITIAL_SEVERITY
    value = math.max(0, math.min(1, value))

    local cropName, fruitTypeIndex = self.manager:getActiveCropInfo(id)

    -- Debug tool: forcing stays permissive (infects even a non-host crop), but warns the tester it's an artificial infection.
    local warning = ""
    local hostGroups = cropDiseaseGroups(cropName)
    if hostGroups == nil or not hostGroups[group] then
        local cropLabel = (cropName ~= nil and cropName ~= "") and tostring(cropName) or "(no crop)"
        warning = string.format("WARNING: %s cannot naturally be affected by %s (forced infection for testing). ",
            cropLabel, self:getDisplayName(group))
    end

    self.state[id] = self.state[id] or {}
    self.state[id][group] = {
        severity = value,
        seed = math.random(1, 1000000),
    }
    self.crop[id] = cropName

    -- Paints map presence, then applies destruction at the exact forced attack level without advancing a disease day.
    local region = self.manager:getFieldRegion(id)
    paintInfectionPresence(self.grid, region, group, self.state[id][group].seed)
    local curve = self:getCurve(group)
    if value >= curve.destroySeverity then
        local activeDesc = fruitTypeIndex ~= nil and g_fruitTypeManager ~= nil
            and g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex) or nil
        local treatment = self:getTreatment(group)
        local protectionMapId = nil
        if treatment == "FUNGICIDE" then protectionMapId = self.grid.fungicideProtectionMapId
        elseif treatment == "NEMATICIDE" then protectionMapId = self.grid.nematicideProtectionMapId end
        destroyCropField(region, activeDesc, id, self.state[id][group].seed, value, curve,
            self.grid, protectionMapId, self.manager)
        self.manager:invalidateActiveCropCache(id)
    end

    requestDiseaseConsoleBroadcast()
    return warning .. string.format("Forced %s infection on farmland %d (attack level %.3f)", group, id, value)
end

function RealisticCropRotationDisease:consoleTick(farmlandId)
    -- Relayed to the server when typed on a client, master users only.
    if g_server == nil then
        return RCRAdminCommandEvent ~= nil
            and RCRAdminCommandEvent.request("rcrDiseaseTick", farmlandId)
            or "rcrDiseaseTick is available on server/host only"
    end

    local ids = collectDiseaseFarmlandIds(self.manager, farmlandId)
    if #ids == 0 then return "No Realistic Crop Rotation farmland found" end

    for _, id in ipairs(ids) do
        self:update(id)
    end

    requestDiseaseConsoleBroadcast()
    return string.format("Updated disease state for %d farmland(s)", #ids)
end

function RealisticCropRotationDisease:consoleClear(farmlandId)
    -- Relayed to the server when typed on a client, master users only.
    if g_server == nil then
        return RCRAdminCommandEvent ~= nil
            and RCRAdminCommandEvent.request("rcrDiseaseClear", farmlandId)
            or "rcrDiseaseClear is available on server/host only"
    end

    local id = tonumber(farmlandId)
    if id ~= nil and id > 0 then
        self.state[id] = nil
        self.reservoir[id] = nil
        self.crop[id] = nil
        self.growth[id] = nil
        local region = self.manager:getFieldRegion(id)
        if region ~= nil then
            self.grid:clearFieldDisease(region, id)
        end
        requestDiseaseConsoleBroadcast()
        return string.format("Cleared all disease data for farmland %d", id)
    end

    self.state = {}
    self.reservoir = {}
    self.crop = {}
    self.growth = {}
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    self.lastReservoirYear = environment ~= nil and tonumber(environment.currentYear) or nil
    self.dayQueue = {}
    self.dayQueued = {}
    self.grid:clearAll()
    requestDiseaseConsoleBroadcast()
    return "Cleared all disease data"
end
