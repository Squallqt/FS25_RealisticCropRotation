local Model = dofile("FS25_RealisticCropRotation/scripts/RealisticCropRotationDiseaseModel.lua")

local FLOOR = 0.01
local GROUPS = {
    SCLEROTINIA = {
        reservoirClass = Model.RESERVOIR_CLASS_MIXED,
        annualRetention = 0.56,
        externalExposure = 0.03
    },
    PHOMA = {
        reservoirClass = Model.RESERVOIR_CLASS_RECENT,
        annualRetention = 0.46,
        externalExposure = 0.02
    },
    TAKEALL = {
        reservoirClass = Model.RESERVOIR_CLASS_RECENT,
        annualRetention = 0.10,
        externalExposure = 0.01
    },
    SEPTORIA = {
        reservoirClass = Model.RESERVOIR_CLASS_RECENT,
        annualRetention = 0.10,
        externalExposure = 0.09
    },
    RUST = {
        reservoirClass = Model.RESERVOIR_CLASS_NONE,
        annualRetention = 0,
        externalExposure = 0.10
    },
    FUSARIUM = {
        reservoirClass = Model.RESERVOIR_CLASS_RECENT,
        annualRetention = 0.32,
        externalExposure = 0.05
    },
    LATEBLIGHT = {
        reservoirClass = Model.RESERVOIR_CLASS_NONE,
        annualRetention = 0,
        externalExposure = 0.10
    },
    BCN = {
        reservoirClass = Model.RESERVOIR_CLASS_PERSISTENT,
        annualRetention = 0.70,
        externalExposure = 0.01
    },
    CLUBROOT = {
        reservoirClass = Model.RESERVOIR_CLASS_PERSISTENT,
        annualRetention = 0.82,
        externalExposure = 0.01
    }
}

local testCount = 0
local failures = {}

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
    end
end

local function assertNear(actual, expected, message)
    if math.abs(actual - expected) > 1e-12 then
        error(string.format("%s: expected %.15f, got %.15f", message, expected, actual), 2)
    end
end

local function assertTableUnchanged(actual, expected, message)
    for key, value in pairs(expected) do
        assertEqual(actual[key], value, message .. " [" .. tostring(key) .. "]")
    end
    for key in pairs(actual) do
        if expected[key] == nil then
            error(message .. ": unexpected key " .. tostring(key), 2)
        end
    end
end

local function test(name, body)
    testCount = testCount + 1
    local ok, failure = pcall(body)
    if not ok then
        failures[#failures + 1] = name .. ": " .. tostring(failure)
    end
end

test("nine validated disease groups are covered", function()
    local count = 0
    for _ in pairs(GROUPS) do
        count = count + 1
    end
    assertEqual(count, 9, "group count")
end)

test("clamp and load normalization are deterministic", function()
    assertEqual(Model.clamp01(nil), 0, "nil clamp")
    assertEqual(Model.clamp01(-0.5), 0, "negative clamp")
    assertEqual(Model.clamp01(1.5), 1, "upper clamp")
    assertNear(Model.clamp01("0.25"), 0.25, "numeric string clamp")
    assertEqual(Model.normalizeLoad(FLOOR - 0.000001), 0, "below-floor load")
    assertNear(Model.normalizeLoad(FLOOR), FLOOR, "floor load survives")
end)

test("reservoir classes normalize without an implicit persistent fallback", function()
    assertEqual(Model.normalizeReservoirClass("mixed"), Model.RESERVOIR_CLASS_MIXED, "mixed class")
    assertEqual(Model.normalizeReservoirClass("recent"), Model.RESERVOIR_CLASS_RECENT, "recent class")
    assertEqual(Model.normalizeReservoirClass("persistent"), Model.RESERVOIR_CLASS_PERSISTENT, "persistent class")
    assertEqual(Model.normalizeReservoirClass("unknown"), Model.RESERVOIR_CLASS_NONE, "unknown class")
    assertEqual(Model.normalizeReservoirClass(nil), Model.RESERVOIR_CLASS_NONE, "missing class")
end)

test("a healthy host creates no reservoir", function()
    assertEqual(Model.depositOutbreak(0, 0, Model.RESERVOIR_CLASS_RECENT), 0, "clean recent reservoir")
    assertEqual(Model.depositOutbreak(0, nil, Model.RESERVOIR_CLASS_PERSISTENT), 0, "clean persistent reservoir")
    assertNear(Model.depositOutbreak(0.35, 0, Model.RESERVOIR_CLASS_RECENT), 0.35,
        "healthy crop preserves existing reservoir")
end)

test("seasonal diseases never transmit an outbreak to the reservoir", function()
    assertEqual(Model.depositOutbreak(0, 0.90, Model.RESERVOIR_CLASS_NONE), 0, "clean seasonal field")
    assertNear(Model.depositOutbreak(0.25, 0.90, Model.RESERVOIR_CLASS_NONE), 0.25,
        "seasonal deposition leaves existing value untouched")
    assertEqual(Model.depositOutbreak(0, 0.90, "SEASONAL"), 0, "seasonal alias is non-transmissible")
end)

test("real outbreaks retain the greater final load", function()
    assertNear(Model.depositOutbreak(0.70, 0.40, Model.RESERVOIR_CLASS_RECENT), 0.70,
        "weaker outbreak")
    assertNear(Model.depositOutbreak(0.40, 0.70, Model.RESERVOIR_CLASS_PERSISTENT), 0.70,
        "stronger outbreak")
end)

test("lower final treated severity leaves a lower future reservoir", function()
    local untreated = Model.depositOutbreak(0, 0.80, Model.RESERVOIR_CLASS_RECENT)
    local treated = Model.depositOutbreak(0, 0.25, Model.RESERVOIR_CLASS_RECENT)
    assertNear(untreated, 0.80, "untreated severity")
    assertNear(treated, 0.25, "treated severity")
    if treated >= untreated then
        error("treated reservoir must remain below untreated reservoir")
    end
end)

test("calendar-year aging composes for all reservoir groups", function()
    for group, spec in pairs(GROUPS) do
        if Model.hasReservoir(spec.reservoirClass) then
            local direct = Model.ageReservoirValue(
                0.90, spec.annualRetention, 3, FLOOR, spec.reservoirClass)
            local composed = Model.ageReservoirValue(
                Model.ageReservoirValue(
                    0.90, spec.annualRetention, 1, FLOOR, spec.reservoirClass),
                spec.annualRetention,
                2,
                FLOOR,
                spec.reservoirClass
            )
            assertNear(composed, direct, group .. " annual composition")
        end
    end
end)

test("calendar-year aging uses the existing strict inoculum floor", function()
    assertNear(Model.ageReservoirValue(0.10, 0.10, 1), FLOOR, "load equal to floor")
    assertEqual(Model.ageReservoirValue(0.10, 0.10, 2), 0, "load below floor")
    assertNear(Model.ageReservoirValue(0.45, 0.70, -1), 0.45, "negative years normalize to zero")
end)

test("persistent reservoirs never clear from calendar aging alone", function()
    assertNear(Model.ageReservoirValue(
        FLOOR, 0.82, 1, FLOOR, Model.RESERVOIR_CLASS_PERSISTENT),
        FLOOR,
        "persistent floor")
    assertEqual(Model.ageReservoirValue(
        FLOOR, 0.82, 1, FLOOR, Model.RESERVOIR_CLASS_RECENT),
        0,
        "recent residue clears below floor")
end)

test("effective exposure is the maximum source and respects the floor", function()
    assertNear(Model.combineExposure(0.60, 0.09), 0.60, "reservoir dominates")
    assertNear(Model.combineExposure(0.02, 0.09), 0.09, "external exposure dominates")
    assertEqual(Model.combineExposure(0.009, 0.008), 0, "both sources below floor")
end)

test("all nine groups expose only their configured standing hosts", function()
    local exposure = {}
    local hosts = {}
    for group, spec in pairs(GROUPS) do
        exposure[group] = spec.externalExposure
        hosts[group] = true
    end

    local loads = Model.buildHostLoad({}, exposure, hosts)
    for group, spec in pairs(GROUPS) do
        assertNear(loads[group], spec.externalExposure, group .. " external exposure")
    end
end)

test("host load construction does not mutate inputs or leak non-host groups", function()
    local reservoir = { SCLEROTINIA = 0.40, PHOMA = 0.30, RUST = 0.20 }
    local exposure = { SCLEROTINIA = 0.03, PHOMA = 0.02, RUST = 0.10 }
    local hosts = { SCLEROTINIA = true, PHOMA = false }
    local reservoirBefore = { SCLEROTINIA = 0.40, PHOMA = 0.30, RUST = 0.20 }
    local exposureBefore = { SCLEROTINIA = 0.03, PHOMA = 0.02, RUST = 0.10 }
    local hostsBefore = { SCLEROTINIA = true, PHOMA = false }

    local loads = Model.buildHostLoad(reservoir, exposure, hosts)
    assertNear(loads.SCLEROTINIA, 0.40, "host load")
    assertEqual(loads.PHOMA, nil, "false host")
    assertEqual(loads.RUST, nil, "missing host")
    assertTableUnchanged(reservoir, reservoirBefore, "reservoir input")
    assertTableUnchanged(exposure, exposureBefore, "exposure input")
    assertTableUnchanged(hosts, hostsBefore, "host input")
end)

test("seasonal groups have exposure but no inherited outbreak load", function()
    for group, spec in pairs(GROUPS) do
        if spec.reservoirClass == Model.RESERVOIR_CLASS_NONE then
            local deposited = Model.depositOutbreak(0, 0.85, spec.reservoirClass)
            local loads = Model.buildHostLoad({ [group] = deposited }, { [group] = spec.externalExposure },
                { [group] = true })
            assertEqual(deposited, 0, group .. " deposited reservoir")
            assertNear(loads[group], spec.externalExposure, group .. " seasonal exposure")
        end
    end
end)

if #failures > 0 then
    error(string.format("%d/%d disease model tests failed:\n%s", #failures, testCount,
        table.concat(failures, "\n")), 0)
end

print(string.format("Disease model: %d/%d tests passed", testCount, testCount))
