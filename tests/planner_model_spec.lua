local modelPath = "FS25_RealisticCropRotation/scripts/RealisticCropRotationPlannerModel.lua"
dofile(modelPath)

local M = RealisticCropRotationPlannerModel
local testsRun = 0

local function assertEqual(actual, expected, label)
    testsRun = testsRun + 1
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

local function assertTableSize(values, expected, label)
    assertEqual(#(values or {}), expected, label)
end

local familyIntervals = {
    CEREAL = 2,
    OILSEED = 3,
    ROOT = 4,
}
local diseaseIntervals = {
    SOIL = 4,
    SEASONAL = 6,
}
local relevant = {
    SOIL = true,
    SEASONAL = false,
}

local function slot(family, diseases, hasCover)
    return {
        family = family,
        diseases = diseases or {},
        hasCover = hasCover == true,
    }
end

do
    local length, hasGap = M.getCycleInfo({"A", "B", nil, nil}, 4)
    assertEqual(length, 2, "two-year prefix length")
    assertEqual(hasGap, false, "two-year trailing blanks")
    assertEqual(M.getNextIndex(2, length), 1, "two-year modulo")

    length, hasGap = M.getCycleInfo({"A", "B", "C", nil}, 4)
    assertEqual(length, 3, "three-year prefix length")
    assertEqual(hasGap, false, "three-year trailing blank")
    assertEqual(M.getNextIndex(3, length), 1, "three-year modulo")

    length, hasGap = M.getCycleInfo({"A", "B", "C", "D"}, 4)
    assertEqual(length, 4, "four-year prefix length")
    assertEqual(hasGap, false, "four-year no gap")
    assertEqual(M.getNextIndex(4, length), 1, "four-year modulo")
end

do
    local candidate = M.getWorstNextCandidate(
        {"A", "B", "A", "C"}, "A", 4,
        function(_, nextCrop)
            return { penalty = nextCrop == "C" and 30 or 10 }
        end)
    assertEqual(candidate.slotIndex, 3, "repeated crop checks every occurrence")
    assertEqual(candidate.nextSlotIndex, 4, "repeated crop keeps real next slot")
    assertEqual(candidate.nextCrop, "C", "repeated crop retains worst next conflict")
end

do
    local length, hasGap = M.getCycleInfo({"A", nil, "C", "D"}, 4)
    assertEqual(length, 1, "internal gap does not compress")
    assertEqual(hasGap, true, "internal gap is incomplete")
    local indices = M.findCropSlots({"A", nil, "A", "D"}, "A", 4)
    assertTableSize(indices, 1, "slots beyond gap excluded")
    local candidate = M.getWorstNextCandidate(
        {"A", "B", nil, "D"}, "A", 4,
        function() return { penalty = 10 } end)
    assertEqual(candidate, nil, "internal gap blocks next-step advice")
end

do
    local gaps = M.getCyclicGaps({1}, 2)
    assertTableSize(gaps, 1, "single host in two-year cycle")
    assertEqual(gaps[1].years, 2, "two-year unique-host return")

    gaps = M.getCyclicGaps({1}, 3)
    assertEqual(gaps[1].years, 3, "three-year unique-host return")

    gaps = M.getCyclicGaps({1}, 4)
    assertEqual(gaps[1].years, 4, "four-year unique-host return")
end

do
    local twoYears = {
        slot("OILSEED", { SOIL = true }),
        slot("CEREAL"),
    }
    local familyPenalty = M.calculateFamilyPenalty(twoYears, familyIntervals, 20)
    local diseasePenalty = M.calculateDiseasePenalty(twoYears, familyIntervals, diseaseIntervals, relevant, 10)
    assertEqual(familyPenalty, 20, "two-year unique oilseed family return")
    assertEqual(diseasePenalty, 10, "two-year unique host disease beyond family baseline")

    local threeYears = {
        slot("OILSEED", { SOIL = true }),
        slot("CEREAL"),
        slot("CEREAL"),
    }
    familyPenalty = M.calculateFamilyPenalty(threeYears, familyIntervals, 20)
    diseasePenalty = M.calculateDiseasePenalty(threeYears, familyIntervals, diseaseIntervals, relevant, 10)
    assertEqual(diseasePenalty, 10, "three-year unique host disease return")

    local fourYears = {
        slot("OILSEED", { SOIL = true }),
        slot("CEREAL"),
        slot("CEREAL"),
        slot("ROOT"),
    }
    diseasePenalty = M.calculateDiseasePenalty(fourYears, familyIntervals, diseaseIntervals, relevant, 10)
    assertEqual(diseasePenalty, 0, "four-year unique host disease return")
end

do
    local withFallow = {
        slot("OILSEED", { SOIL = true }),
        slot("FALLOW"),
        slot("CEREAL"),
    }
    local diseasePenalty = M.calculateDiseasePenalty(withFallow, familyIntervals, diseaseIntervals, relevant, 10)
    assertEqual(diseasePenalty, 10, "fallow counts as one cycle year")
end

do
    local seasonalOnly = {
        slot("CEREAL", { SEASONAL = true }),
        slot("ROOT"),
    }
    local diseasePenalty, events = M.calculateDiseasePenalty(
        seasonalOnly, familyIntervals, diseaseIntervals, relevant, 10)
    assertEqual(diseasePenalty, 0, "seasonal disease ignored")
    assertTableSize(events, 0, "seasonal disease emits no event")
end

do
    local withoutCover = {
        slot("ROOT"),
        slot("CEREAL"),
        slot("CEREAL"),
    }
    local withCover = {
        slot("ROOT", nil, true),
        slot("CEREAL"),
        slot("CEREAL"),
    }
    local basePenalty = M.calculateFamilyPenalty(withoutCover, familyIntervals, 20)
    local coveredPenalty = M.calculateFamilyPenalty(withCover, familyIntervals, 20)
    assertEqual(coveredPenalty, basePenalty, "cover does not change sanitary spacing")
end

do
    local conflict = M.evaluateImmediateConflict(
        slot("CEREAL", { SOIL = true, SEASONAL = true }),
        slot("CEREAL", { SOIL = true, SEASONAL = true }),
        familyIntervals, diseaseIntervals, relevant, 20, 10)
    assertEqual(conflict.kind, "disease", "rotation-relevant disease wins immediate conflict")
    assertEqual(conflict.group, "SOIL", "seasonal group excluded from immediate conflict")
    assertEqual(conflict.penalty, 40, "family plus disease excess penalty")
end

print(string.format("planner_model_spec: %d assertions passed", testsRun))
