-- Copyright © 2026 Squallqt. All rights reserved.
-- Pure disease-reservoir rules shared by runtime code and deterministic tests.
RealisticCropRotationDiseaseModel = RealisticCropRotationDiseaseModel or {}
local Model = RealisticCropRotationDiseaseModel

Model.RESERVOIR_CLASS_NONE = "NONE"
Model.RESERVOIR_CLASS_MIXED = "MIXED"
Model.RESERVOIR_CLASS_RECENT = "RECENT"
Model.RESERVOIR_CLASS_PERSISTENT = "PERSISTENT"
Model.INOCULUM_FLOOR = 0.01

---Clamps a numeric value to the unit interval.
-- @param number value
-- @return number value in [0,1]
function Model.clamp01(value)
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric or numeric <= 0 then
        return 0
    end
    if numeric >= 1 then
        return 1
    end
    return numeric
end

---Normalizes a load and drops values below the inoculum floor.
-- The comparison deliberately remains strict: a load equal to the floor survives,
-- matching the existing disease implementation.
-- @param number value
-- @param number floor Optional floor in [0,1]
-- @return number normalized load in [0,1]
function Model.normalizeLoad(value, floor)
    local normalizedFloor = floor
    if normalizedFloor == nil then
        normalizedFloor = Model.INOCULUM_FLOOR
    end
    normalizedFloor = Model.clamp01(normalizedFloor)

    local normalized = Model.clamp01(value)
    if normalized < normalizedFloor then
        return 0
    end
    return normalized
end

---Normalizes the configured reservoir class.
-- Unknown or missing classes are seasonal and therefore non-transmissible.
-- @param string reservoirClass
-- @return string NONE, MIXED, RECENT or PERSISTENT
function Model.normalizeReservoirClass(reservoirClass)
    local normalized = string.upper(tostring(reservoirClass or ""))
    if normalized == Model.RESERVOIR_CLASS_MIXED then
        return Model.RESERVOIR_CLASS_MIXED
    end
    if normalized == Model.RESERVOIR_CLASS_RECENT then
        return Model.RESERVOIR_CLASS_RECENT
    end
    if normalized == Model.RESERVOIR_CLASS_PERSISTENT then
        return Model.RESERVOIR_CLASS_PERSISTENT
    end
    return Model.RESERVOIR_CLASS_NONE
end

---Returns whether a disease class can leave a field reservoir.
-- @param string reservoirClass
-- @return boolean
function Model.hasReservoir(reservoirClass)
    return Model.normalizeReservoirClass(reservoirClass) ~= Model.RESERVOIR_CLASS_NONE
end

---Deposits a completed real outbreak into the field reservoir.
-- Seasonal diseases leave the existing value untouched. For reservoir diseases,
-- only the greatest of the previous load and final outbreak severity is retained.
-- @param number currentLoad
-- @param number finalSeverity
-- @param string reservoirClass
-- @param number floor Optional inoculum floor
-- @return number updated reservoir load
function Model.depositOutbreak(currentLoad, finalSeverity, reservoirClass, floor)
    local current = Model.normalizeLoad(currentLoad, floor)
    if not Model.hasReservoir(reservoirClass) then
        return current
    end

    local severity = Model.normalizeLoad(finalSeverity, floor)
    return math.max(current, severity)
end

---Applies completed calendar-year decay to one reservoir value.
-- @param number value
-- @param number annualRetention Fraction retained after one calendar year
-- @param integer elapsedYears Number of completed calendar years
-- @param number floor Optional inoculum floor
-- @param string reservoirClass Optional reservoir class; persistent contamination never clears by aging alone
-- @return number aged reservoir load
function Model.ageReservoirValue(value, annualRetention, elapsedYears, floor, reservoirClass)
    local current = Model.normalizeLoad(value, floor)
    if current == 0 then
        return 0
    end

    local retention = Model.clamp01(annualRetention)
    local years = tonumber(elapsedYears) or 0
    if years < 0 then
        years = 0
    end
    years = math.floor(years)

    local aged = current * retention ^ years
    local normalizedFloor = Model.clamp01(floor == nil and Model.INOCULUM_FLOOR or floor)
    if Model.normalizeReservoirClass(reservoirClass) == Model.RESERVOIR_CLASS_PERSISTENT
        and aged > 0 and aged < normalizedFloor then
        return normalizedFloor
    end
    return Model.normalizeLoad(aged, normalizedFloor)
end

---Combines a local reservoir with current external exposure.
-- @param number reservoirLoad
-- @param number externalExposure
-- @param number floor Optional inoculum floor
-- @return number effective load
function Model.combineExposure(reservoirLoad, externalExposure, floor)
    local reservoir = Model.normalizeLoad(reservoirLoad, floor)
    local exposure = Model.normalizeLoad(externalExposure, floor)
    return math.max(reservoir, exposure)
end

---Builds effective loads for the pathogen groups hosted by a standing crop.
-- Inputs are never mutated and groups below the inoculum floor are omitted.
-- @param table reservoirByGroup group -> local reservoir load
-- @param table exposureByGroup group -> external exposure
-- @param table hostGroups group -> true for the standing crop's hosts
-- @param number floor Optional inoculum floor
-- @return table group -> effective load
function Model.buildHostLoad(reservoirByGroup, exposureByGroup, hostGroups, floor)
    local reservoir = type(reservoirByGroup) == "table" and reservoirByGroup or {}
    local exposure = type(exposureByGroup) == "table" and exposureByGroup or {}
    local hosts = type(hostGroups) == "table" and hostGroups or {}
    local out = {}

    for group, isHost in pairs(hosts) do
        if isHost == true then
            local load = Model.combineExposure(reservoir[group], exposure[group], floor)
            if load > 0 then
                out[group] = load
            end
        end
    end
    return out
end

return Model
