local testCount = 0
local failures = {}

local function fail(message, level)
    error(message, (level or 1) + 1)
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 1)
    end
end

local function assertNear(actual, expected, message)
    if math.abs((tonumber(actual) or 0) - (tonumber(expected) or 0)) > 1e-9 then
        fail(string.format("%s: expected %.12f, got %.12f", message, expected, actual), 1)
    end
end

local function assertNil(actual, message)
    if actual ~= nil then
        fail(string.format("%s: expected nil, got %s", message, tostring(actual)), 1)
    end
end

local function test(name, body)
    testCount = testCount + 1
    local ok, failure = pcall(body)
    if not ok then
        failures[#failures + 1] = name .. ": " .. tostring(failure)
    end
end

function Class(classTable, baseClass)
    if baseClass ~= nil then
        local classMeta = getmetatable(classTable) or {}
        classMeta.__index = baseClass
        setmetatable(classTable, classMeta)
    end
    return { __index = classTable }
end

Event = {}
function Event.new(meta)
    return setmetatable({}, meta)
end

function InitEventClass()
end

Logging = {
    info = function() end,
    warning = function() end,
    error = function() end,
}

local xmlRegistry = {}

local function recordXMLWrite(xmlFile, kind, key, value)
    xmlFile.values[key] = value
    xmlFile.writes[#xmlFile.writes + 1] = {
        kind = kind,
        key = key,
        value = value,
    }
end

function createXMLFile(_, path, root)
    local xmlFile = {
        path = path,
        root = root,
        values = {},
        writes = {},
    }
    xmlRegistry[path] = xmlFile
    return xmlFile
end

function saveXMLFile()
end

function delete()
end

function fileExists(path)
    return xmlRegistry[path] ~= nil
end

function loadXMLFile(_, path)
    return xmlRegistry[path]
end

function setXMLInt(xmlFile, key, value)
    recordXMLWrite(xmlFile, "int", key, value)
end

function setXMLFloat(xmlFile, key, value)
    recordXMLWrite(xmlFile, "float", key, value)
end

function setXMLString(xmlFile, key, value)
    recordXMLWrite(xmlFile, "string", key, value)
end

function getXMLInt(xmlFile, key)
    return xmlFile.values[key]
end

function getXMLFloat(xmlFile, key)
    return xmlFile.values[key]
end

function getXMLString(xmlFile, key)
    return xmlFile.values[key]
end

function hasXMLProperty(xmlFile, key)
    if xmlFile.values[key] ~= nil then
        return true
    end
    local attributePrefix = key .. "#"
    local childPrefix = key .. "."
    for candidate in pairs(xmlFile.values) do
        if string.sub(candidate, 1, #attributePrefix) == attributePrefix
            or string.sub(candidate, 1, #childPrefix) == childPrefix then
            return true
        end
    end
    return false
end

local function resetXML()
    xmlRegistry = {}
end

local function canonicalWrites(xmlFile)
    local out = {}
    for _, write in ipairs(xmlFile.writes) do
        out[#out + 1] = string.format(
            "%s|%s|%s",
            write.kind,
            write.key,
            tostring(write.value))
    end
    return table.concat(out, "\n")
end

local function newDisease(year)
    g_currentMission = {
        environment = {
            currentYear = year,
        },
    }
    return RealisticCropRotationDisease.new({}, {})
end

RealisticCropRotationDiseaseModel =
    dofile("FS25_RealisticCropRotation/scripts/RealisticCropRotationDiseaseModel.lua")
dofile("FS25_RealisticCropRotation/scripts/RealisticCropRotationDisease.lua")

test("completed outbreaks deposit once while seasonal groups stay external", function()
    g_server = {}
    local clearCount = 0
    RealisticCropRotation = {
        cropConfig = {
            diseases = {
                WHEAT = {
                    FUSARIUM = true,
                    RUST = true,
                },
            },
            diseaseReservoirClasses = {
                FUSARIUM = "RECENT",
                RUST = "NONE",
            },
        },
    }
    local disease = RealisticCropRotationDisease.new({
        getFieldRegion = function() return {} end,
    }, {
        clearField = function() clearCount = clearCount + 1 end,
    })
    disease.state[8] = {
        FUSARIUM = { severity = 0.64, seed = 10 },
        RUST = { severity = 0.82, seed = 11 },
    }
    disease.crop[8] = "WHEAT"

    assertEqual(disease:finishCropCycle(8, "WHEAT"), true, "first completed cycle")
    assertNear(disease.reservoir[8].FUSARIUM, 0.64, "Fusarium deposit")
    assertNil(disease.reservoir[8].RUST, "seasonal rust deposit")
    assertNil(disease.state[8], "active state cleared")
    assertEqual(clearCount, 1, "field cleared")

    assertEqual(disease:finishCropCycle(8, "WHEAT"), false, "duplicate completion")
    assertNear(disease.reservoir[8].FUSARIUM, 0.64, "duplicate leaves reservoir unchanged")
end)

test("calendar aging applies each completed year exactly once", function()
    g_server = {}
    RealisticCropRotation = {
        cropConfig = {
            diseaseAnnualRetention = {
                TAKEALL = 0.10,
                CLUBROOT = 0.82,
            },
        },
    }
    local disease = newDisease(2030)
    disease.reservoir[3] = {
        TAKEALL = 0.80,
        CLUBROOT = 0.80,
    }

    assertEqual(disease:advanceCalendar(2031), true, "first elapsed year")
    assertNear(disease.reservoir[3].TAKEALL, 0.08, "take-all one year")
    assertNear(disease.reservoir[3].CLUBROOT, 0.656, "clubroot one year")
    assertEqual(disease:advanceCalendar(2031), false, "same year is idempotent")
    assertNear(disease.reservoir[3].TAKEALL, 0.08, "same-year take-all")
    assertNear(disease.reservoir[3].CLUBROOT, 0.656, "same-year clubroot")
end)

test("effective load uses only standing hosts and does not mutate the reservoir", function()
    g_server = {}
    RealisticCropRotation = {
        cropConfig = {
            diseases = {
                WHEAT = {
                    FUSARIUM = true,
                    RUST = true,
                },
            },
            diseaseAmbient = {
                FUSARIUM = 0.05,
                RUST = 0.10,
                CLUBROOT = 0.01,
            },
        },
    }
    local disease = RealisticCropRotationDisease.new({
        getPendingHistoryCrop = function() return "WHEAT" end,
    }, {})
    disease.reservoir[5] = {
        FUSARIUM = 0.43,
        CLUBROOT = 0.71,
    }

    local load = disease:getLoad(5)
    local pressure = disease:getPressure(5)
    assertNear(load.FUSARIUM, 0.43, "reservoir dominates exposure")
    assertNear(load.RUST, 0.10, "seasonal exposure")
    assertNil(load.CLUBROOT, "non-host reservoir hidden")
    assertNear(pressure.FUSARIUM, load.FUSARIUM, "pressure matches roll")
    assertNear(disease.reservoir[5].CLUBROOT, 0.71, "reservoir input unchanged")
end)

test("save includes a reservoir-only farmland", function()
    resetXML()
    local disease = newDisease(2028)
    disease.reservoir[17] = {
        CLUBROOT = 0.61,
    }
    disease:saveToXML("reservoirOnly/")

    local xmlFile = xmlRegistry["reservoirOnly/realisticCropRotationDisease.xml"]
    assertEqual(xmlFile.values["realisticCropRotationDisease#reservoirVersion"], 1, "save format")
    assertEqual(xmlFile.values["realisticCropRotationDisease#lastReservoirYear"], 2028, "saved year")
    assertEqual(xmlFile.values["realisticCropRotationDisease.farmland(0)#id"], 17, "farmland id")
    assertNil(xmlFile.values["realisticCropRotationDisease.farmland(0).group(0)#name"],
        "reservoir-only active group")
    assertEqual(xmlFile.values["realisticCropRotationDisease.farmland(0).reservoir(0)#name"],
        "CLUBROOT", "reservoir name")
    assertNear(xmlFile.values["realisticCropRotationDisease.farmland(0).reservoir(0)#load"],
        0.61, "reservoir load")
end)

test("save keeps active outbreaks and reservoirs on the same farmland", function()
    resetXML()
    local disease = newDisease(2029)
    disease.state[4] = {
        FUSARIUM = {
            severity = 0.42,
            seed = 12345,
            incubation = 1.75,
        },
    }
    disease.crop[4] = "MAIZE"
    disease.growth[4] = 5
    disease.reservoir[4] = {
        FUSARIUM = 0.42,
        SCLEROTINIA = 0.18,
    }
    disease:saveToXML("activeAndReservoir/")

    local values = xmlRegistry["activeAndReservoir/realisticCropRotationDisease.xml"].values
    local base = "realisticCropRotationDisease.farmland(0)"
    assertEqual(values[base .. "#id"], 4, "farmland id")
    assertEqual(values[base .. "#crop"], "MAIZE", "active crop")
    assertEqual(values[base .. "#growth"], 5, "growth")
    assertEqual(values[base .. ".group(0)#name"], "FUSARIUM", "active group")
    assertNear(values[base .. ".group(0)#severity"], 0.42, "active severity")
    assertEqual(values[base .. ".group(0)#seed"], 12345, "active seed")
    assertNear(values[base .. ".group(0)#incubation"], 1.75, "active incubation")
    assertEqual(values[base .. ".reservoir(0)#name"], "FUSARIUM", "first reservoir group")
    assertEqual(values[base .. ".reservoir(1)#name"], "SCLEROTINIA", "second reservoir group")
end)

test("save order is deterministic for farmlands and disease groups", function()
    resetXML()
    local first = newDisease(2030)
    first.reservoir[20] = { SCLEROTINIA = 0.20, BCN = 0.30 }
    first.reservoir[3] = { PHOMA = 0.40, CLUBROOT = 0.50 }
    first.state[11] = {
        TAKEALL = { severity = 0.21, seed = 11 },
        FUSARIUM = { severity = 0.22, seed = 12 },
    }
    first.crop[11] = "WHEAT"
    first:saveToXML("orderedFirst/")

    local second = newDisease(2030)
    second.state[11] = {
        FUSARIUM = { severity = 0.22, seed = 12 },
        TAKEALL = { severity = 0.21, seed = 11 },
    }
    second.crop[11] = "WHEAT"
    second.reservoir[3] = { CLUBROOT = 0.50, PHOMA = 0.40 }
    second.reservoir[20] = { BCN = 0.30, SCLEROTINIA = 0.20 }
    second:saveToXML("orderedSecond/")

    local firstXML = xmlRegistry["orderedFirst/realisticCropRotationDisease.xml"]
    local secondXML = xmlRegistry["orderedSecond/realisticCropRotationDisease.xml"]
    assertEqual(canonicalWrites(firstXML), canonicalWrites(secondXML), "canonical serialization")
    assertEqual(firstXML.values["realisticCropRotationDisease.farmland(0)#id"], 3, "first farmland")
    assertEqual(firstXML.values["realisticCropRotationDisease.farmland(1)#id"], 11, "second farmland")
    assertEqual(firstXML.values["realisticCropRotationDisease.farmland(2)#id"], 20, "third farmland")
end)

test("version 1 save-load-save roundtrip is identical", function()
    resetXML()
    local source = newDisease(2031)
    source.lastReservoirYear = 2027
    source.state[12] = {
        FUSARIUM = {
            severity = 0.44,
            seed = 6789,
            incubation = 2.25,
        },
    }
    source.crop[12] = "MAIZE"
    source.growth[12] = 6
    source.reservoir[12] = {
        BCN = 0.27,
        FUSARIUM = 0.44,
    }
    source.reservoir[30] = {
        CLUBROOT = 0.72,
    }
    source:saveToXML("versionOne/")
    local originalWrites =
        canonicalWrites(xmlRegistry["versionOne/realisticCropRotationDisease.xml"])

    local loaded = newDisease(2038)
    loaded:loadFromXML("versionOne/")
    assertEqual(loaded.lastReservoirYear, 2027, "loaded reservoir year")
    assertEqual(loaded.crop[12], "MAIZE", "loaded crop")
    assertEqual(loaded.growth[12], 6, "loaded growth")
    assertNear(loaded.state[12].FUSARIUM.severity, 0.44, "loaded severity")
    assertEqual(loaded.state[12].FUSARIUM.seed, 6789, "loaded seed")
    assertNear(loaded.state[12].FUSARIUM.incubation, 2.25, "loaded incubation")
    assertNear(loaded.reservoir[12].BCN, 0.27, "loaded BCN")
    assertNear(loaded.reservoir[12].FUSARIUM, 0.44, "loaded FUSARIUM")
    assertNear(loaded.reservoir[30].CLUBROOT, 0.72, "loaded CLUBROOT")

    loaded:saveToXML("versionOneRoundtrip/")
    assertEqual(
        canonicalWrites(xmlRegistry["versionOneRoundtrip/realisticCropRotationDisease.xml"]),
        originalWrites,
        "version 1 roundtrip")
end)

test("legacy migration preserves active outbreaks and starts a clean reservoir at current year", function()
    resetXML()
    local path = "legacy/realisticCropRotationDisease.xml"
    local xmlFile = createXMLFile("legacyDisease", path, "realisticCropRotationDisease")
    setXMLInt(xmlFile, "realisticCropRotationDisease#lastReservoirYear", 1998)
    local base = "realisticCropRotationDisease.farmland(0)"
    setXMLInt(xmlFile, base .. "#id", 6)
    setXMLString(xmlFile, base .. "#crop", "BARLEY")
    setXMLInt(xmlFile, base .. "#growth", 4)
    setXMLString(xmlFile, base .. ".group(0)#name", "TAKEALL")
    setXMLFloat(xmlFile, base .. ".group(0)#severity", 0.36)
    setXMLInt(xmlFile, base .. ".group(0)#seed", 2468)
    setXMLFloat(xmlFile, base .. ".group(0)#incubation", 0.75)
    setXMLString(xmlFile, base .. ".reservoir(0)#name", "TAKEALL")
    setXMLFloat(xmlFile, base .. ".reservoir(0)#load", 0.91)

    local migrated = newDisease(2033)
    migrated:loadFromXML("legacy/")
    assertEqual(migrated.lastReservoirYear, 2033, "migration year")
    assertEqual(migrated.crop[6], "BARLEY", "legacy crop")
    assertEqual(migrated.growth[6], 4, "legacy growth")
    assertNear(migrated.state[6].TAKEALL.severity, 0.36, "legacy severity")
    assertEqual(migrated.state[6].TAKEALL.seed, 2468, "legacy seed")
    assertNear(migrated.state[6].TAKEALL.incubation, 0.75, "legacy incubation")
    assertNil(migrated.reservoir[6], "legacy reservoir must not be reconstructed")

    migrated:saveToXML("migrated/")
    local migratedValues = xmlRegistry["migrated/realisticCropRotationDisease.xml"].values
    assertEqual(migratedValues["realisticCropRotationDisease#reservoirVersion"], 1,
        "migrated save version")
    assertEqual(migratedValues["realisticCropRotationDisease#lastReservoirYear"], 2033,
        "migrated save year")
end)

test("getSyncData copies values and applySyncData fully replaces state crop and reservoir", function()
    local source = newDisease(2034)
    source.state["5"] = {
        FUSARIUM = { severity = 0.52, seed = 9876 },
    }
    source.crop["5"] = "MAIZE"
    source.reservoir["5"] = {
        BCN = 0.41,
        CLUBROOT = 0.009,
    }

    local state, crop, reservoir = source:getSyncData()
    source.state["5"].FUSARIUM.severity = 0.99
    source.crop["5"] = "WHEAT"
    source.reservoir["5"].BCN = 0.99
    assertNear(state[5].FUSARIUM.severity, 0.52, "copied severity")
    assertEqual(crop[5], "MAIZE", "copied crop")
    assertNear(reservoir[5].BCN, 0.41, "copied reservoir")
    assertNil(reservoir[5].CLUBROOT, "sub-floor reservoir is not synchronized")

    local target = newDisease(2034)
    target.state[99] = { RUST = { severity = 0.80, seed = 1 } }
    target.crop[99] = "WHEAT"
    target.reservoir[99] = { PHOMA = 0.70 }
    target:applySyncData(state, crop, reservoir)

    assertNil(target.state[99], "stale active state")
    assertNil(target.crop[99], "stale crop")
    assertNil(target.reservoir[99], "stale reservoir")
    assertNear(target.state[5].FUSARIUM.severity, 0.52, "applied severity")
    assertEqual(target.state[5].FUSARIUM.seed, 9876, "applied seed")
    assertEqual(target.crop[5], "MAIZE", "applied crop")
    assertNear(target.reservoir[5].BCN, 0.41, "applied reservoir")

    target:applySyncData({}, {}, {})
    assertNil(next(target.state), "empty state replacement")
    assertNil(next(target.crop), "empty crop replacement")
    assertNil(next(target.reservoir), "empty reservoir replacement")
end)

local streams = {}

local function newStream()
    local stream = {
        tokens = {},
        position = 1,
    }
    streams[stream] = stream
    return stream
end

local function writeToken(streamId, kind, value)
    streamId.tokens[#streamId.tokens + 1] = {
        kind = kind,
        value = value,
    }
end

local function readToken(streamId, kind)
    local token = streamId.tokens[streamId.position]
    if token == nil then
        fail(string.format("stream underflow while reading %s at token %d", kind, streamId.position), 1)
    end
    if token.kind ~= kind then
        fail(string.format(
            "stream type mismatch at token %d: expected %s, got %s",
            streamId.position,
            kind,
            tostring(token.kind)), 1)
    end
    streamId.position = streamId.position + 1
    return token.value
end

function streamWriteInt8(streamId, value) writeToken(streamId, "Int8", value) end
function streamWriteUInt8(streamId, value) writeToken(streamId, "UInt8", value) end
function streamWriteInt16(streamId, value) writeToken(streamId, "Int16", value) end
function streamWriteInt32(streamId, value) writeToken(streamId, "Int32", value) end
function streamWriteFloat32(streamId, value) writeToken(streamId, "Float32", value) end
function streamWriteString(streamId, value) writeToken(streamId, "String", value) end

function streamReadInt8(streamId) return readToken(streamId, "Int8") end
function streamReadUInt8(streamId) return readToken(streamId, "UInt8") end
function streamReadInt16(streamId) return readToken(streamId, "Int16") end
function streamReadInt32(streamId) return readToken(streamId, "Int32") end
function streamReadFloat32(streamId) return readToken(streamId, "Float32") end
function streamReadString(streamId) return readToken(streamId, "String") end

RealisticCropRotationRepository = {
    MAX_HISTORY = 4,
}

RealisticCropRotationTreatmentLifecycle = {
    getSyncData = function()
        return {}
    end,
    applySyncData = function()
    end,
}

dofile("FS25_RealisticCropRotation/events/RCRHistoryResponseEvent.lua")

local function newManager(service)
    return {
        service = service or {
            getSyncData = function()
                return {}, {}, {}
            end,
            applySyncData = function()
            end,
        },
        getAllRotationPlans = function()
            return {}
        end,
        getAllRotationCoverPlans = function()
            return {}
        end,
    }
end

test("empty network snapshot writes exactly eight section counts", function()
    g_currentMission = {
        realisticCropRotationManager = nil,
    }
    RealisticCropRotation = {}
    local stream = newStream()
    RCRHistoryResponseEvent.new():writeStream(stream, nil)

    assertEqual(#stream.tokens, 8, "empty snapshot token count")
    for index, token in ipairs(stream.tokens) do
        assertEqual(token.kind, "Int16", "empty section type " .. index)
        assertEqual(token.value, 0, "empty section count " .. index)
    end
end)

test("network reservoir section is deterministically ordered", function()
    local disease = newDisease(2035)
    disease.reservoir[9] = {
        SCLEROTINIA = 0.25,
        PHOMA = 0.35,
    }
    disease.reservoir[2] = {
        CLUBROOT = 0.45,
        BCN = 0.55,
    }
    RealisticCropRotation = {
        disease = disease,
    }
    g_currentMission = {
        realisticCropRotationManager = newManager(),
    }

    local stream = newStream()
    RCRHistoryResponseEvent.new():writeStream(stream, nil)

    for index = 1, 7 do
        assertEqual(stream.tokens[index].kind, "Int16", "section count type " .. index)
        assertEqual(stream.tokens[index].value, 0, "empty section count " .. index)
    end
    assertEqual(stream.tokens[8].kind, "Int16", "reservoir section type")
    assertEqual(stream.tokens[8].value, 2, "reservoir farmland count")
    assertEqual(stream.tokens[9].value, 2, "first reservoir farmland")
    assertEqual(stream.tokens[11].value, "BCN", "first group on first farmland")
    assertEqual(stream.tokens[13].value, "CLUBROOT", "second group on first farmland")
    assertEqual(stream.tokens[15].value, 9, "second reservoir farmland")
    assertEqual(stream.tokens[17].value, "PHOMA", "first group on second farmland")
    assertEqual(stream.tokens[19].value, "SCLEROTINIA", "second group on second farmland")
end)

test("network snapshot roundtrips the reservoir and fully replaces stale client data", function()
    local source = newDisease(2036)
    source.state[7] = {
        FUSARIUM = { severity = 0.48, seed = 7654 },
    }
    source.crop[7] = "MAIZE"
    source.reservoir[7] = {
        BCN = 0.39,
        FUSARIUM = 0.48,
    }
    source.reservoir[22] = {
        CLUBROOT = 0.68,
    }

    RealisticCropRotation = {
        disease = source,
    }
    g_currentMission = {
        realisticCropRotationManager = newManager(),
    }
    local stream = newStream()
    RCRHistoryResponseEvent.new():writeStream(stream, nil)

    local target = newDisease(2036)
    target.state[99] = { RUST = { severity = 0.88, seed = 9 } }
    target.crop[99] = "WHEAT"
    target.reservoir[99] = { PHOMA = 0.77 }
    local appliedTreatment
    RealisticCropRotationTreatmentLifecycle.applySyncData = function(data)
        appliedTreatment = data
    end
    local serviceApplied = false
    local clientManager = newManager({
        applySyncData = function()
            serviceApplied = true
        end,
    })
    g_currentMission = {
        realisticCropRotationManager = clientManager,
        getIsServer = function()
            return false
        end,
    }
    RealisticCropRotation = {
        disease = target,
    }
    stream.position = 1
    local connection = {
        getIsServer = function()
            return true
        end,
    }
    RCRHistoryResponseEvent.emptyNew():readStream(stream, connection)

    assertEqual(stream.position, #stream.tokens + 1, "complete snapshot consumption")
    assertEqual(serviceApplied, true, "rotation service sync")
    assertEqual(type(appliedTreatment), "table", "treatment sync")
    assertNil(target.state[99], "stale network active state")
    assertNil(target.crop[99], "stale network crop")
    assertNil(target.reservoir[99], "stale network reservoir")
    assertNear(target.state[7].FUSARIUM.severity, 0.48, "roundtrip severity")
    assertEqual(target.state[7].FUSARIUM.seed, 7654, "roundtrip seed")
    assertEqual(target.crop[7], "MAIZE", "roundtrip crop")
    assertNear(target.reservoir[7].BCN, 0.39, "roundtrip BCN")
    assertNear(target.reservoir[7].FUSARIUM, 0.48, "roundtrip FUSARIUM")
    assertNear(target.reservoir[22].CLUBROOT, 0.68, "roundtrip CLUBROOT")
end)

if #failures > 0 then
    error(string.format(
        "%d/%d persistence and sync tests failed:\n%s",
        #failures,
        testCount,
        table.concat(failures, "\n")), 0)
end

print(string.format("persistence_sync_spec: %d/%d tests passed", testCount, testCount))
