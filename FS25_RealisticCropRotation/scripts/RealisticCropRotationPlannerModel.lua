-- Copyright © 2026 Squallqt. All rights reserved.
-- Pure rotation-cycle calculations shared by the planner score and advice.
RealisticCropRotationPlannerModel = {}

local PlannerModel = RealisticCropRotationPlannerModel

PlannerModel.NEXT_STEP_STATUS = {
    OK = "OK",
    NO_PLAN = "NO_PLAN",
    INCOMPLETE_GAP = "INCOMPLETE_GAP",
    INCOMPLETE_SHORT = "INCOMPLETE_SHORT",
    NO_HISTORY = "NO_HISTORY",
    NOT_ALIGNED = "NOT_ALIGNED",
    AMBIGUOUS = "AMBIGUOUS",
}

local function isOccupied(value)
    return value ~= nil and tostring(value) ~= ""
end

local function normalizeName(value)
    if not isOccupied(value) then return nil end
    return string.upper(tostring(value))
end

local function sortedKeys(values)
    local keys = {}
    for key in pairs(values or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

---Returns the contiguous cycle length and whether a filled slot exists after its first gap.
-- Trailing empty slots shorten the cycle; later filled slots never get compressed into it.
-- @param table plan
-- @param integer maxSlots
-- @return integer length
-- @return boolean hasInternalGap
function PlannerModel.getCycleInfo(plan, maxSlots)
    local limit = tonumber(maxSlots) or 4
    local length = 0
    local ended = false
    local hasInternalGap = false

    for index = 1, limit do
        if isOccupied(plan ~= nil and plan[index] or nil) then
            if ended then
                hasInternalGap = true
            else
                length = index
            end
        else
            ended = true
        end
    end

    return length, hasInternalGap
end

---Returns the next slot on a cycle of the supplied real length.
-- @param integer index
-- @param integer cycleLength
-- @return integer nextIndex, or nil
function PlannerModel.getNextIndex(index, cycleLength)
    local position = tonumber(index)
    local length = tonumber(cycleLength)
    if position == nil or length == nil or length < 1 or position < 1 or position > length then
        return nil
    end
    return (position % length) + 1
end

---Returns every occurrence of a crop inside the contiguous cycle.
-- @param table plan
-- @param string cropName
-- @param integer maxSlots
-- @return table indices
-- @return integer cycleLength
-- @return boolean hasInternalGap
function PlannerModel.findCropSlots(plan, cropName, maxSlots)
    local length, hasInternalGap = PlannerModel.getCycleInfo(plan, maxSlots)
    local target = normalizeName(cropName)
    local indices = {}

    if target ~= nil then
        for index = 1, length do
            if normalizeName(plan[index]) == target then
                indices[#indices + 1] = index
            end
        end
    end

    return indices, length, hasInternalGap
end

---Returns the worst next step among every occurrence of a crop in the cycle.
-- The evaluator receives (currentCrop, nextCrop, slotIndex, nextSlotIndex) and
-- returns either nil or a conflict carrying a numeric penalty.
-- @param table plan
-- @param string cropName
-- @param integer maxSlots
-- @param function evaluator
-- @return table candidate { slotIndex, nextSlotIndex, nextCrop, conflict }, or nil
function PlannerModel.getWorstNextCandidate(plan, cropName, maxSlots, evaluator)
    local matchingSlots, cycleLength, hasInternalGap =
        PlannerModel.findCropSlots(plan, cropName, maxSlots)
    if hasInternalGap or cycleLength < 2 then return nil end

    local firstCandidate, worstCandidate
    for _, slotIndex in ipairs(matchingSlots) do
        local nextSlotIndex = PlannerModel.getNextIndex(slotIndex, cycleLength)
        local nextCrop = nextSlotIndex ~= nil and plan[nextSlotIndex] or nil
        if isOccupied(nextCrop) then
            local conflict = evaluator ~= nil
                and evaluator(cropName, nextCrop, slotIndex, nextSlotIndex) or nil
            local candidate = {
                slotIndex = slotIndex,
                nextSlotIndex = nextSlotIndex,
                nextCrop = nextCrop,
                conflict = conflict,
            }
            firstCandidate = firstCandidate or candidate
            if conflict ~= nil and (worstCandidate == nil
                or (tonumber(conflict.penalty) or 0) > (tonumber(worstCandidate.conflict.penalty) or 0)) then
                worstCandidate = candidate
            end
        end
    end

    return worstCandidate or firstCandidate
end

---Resolves the next cycle step from newest-first history without treating trailing empty slots as cycle entries.
-- Older history entries disambiguate repeated crops. If several matching positions remain, a result is
-- returned only when every position leads to the same next crop.
-- @param table plan
-- @param table history Newest-first crop entries ({ crop = name }) or crop-name strings
-- @param integer maxSlots
-- @return table result { status, cycleLength, previousCrop, anchorSlotIndex, nextSlotIndex, nextCrop }
function PlannerModel.resolveNextStepFromHistory(plan, history, maxSlots)
    local status = PlannerModel.NEXT_STEP_STATUS
    local cycleLength, hasInternalGap = PlannerModel.getCycleInfo(plan, maxSlots)

    if hasInternalGap then
        return { status = status.INCOMPLETE_GAP, cycleLength = cycleLength }
    end
    if cycleLength == 0 then
        return { status = status.NO_PLAN, cycleLength = cycleLength }
    end
    if cycleLength < 2 then
        return { status = status.INCOMPLETE_SHORT, cycleLength = cycleLength }
    end

    local historyNames = {}
    for _, entry in ipairs(history or {}) do
        local value = type(entry) == "table" and entry.crop or entry
        local name = normalizeName(value)
        if name ~= nil then
            historyNames[#historyNames + 1] = name
        end
    end
    if #historyNames == 0 then
        return { status = status.NO_HISTORY, cycleLength = cycleLength }
    end

    local previousCrop = historyNames[1]
    local matchingSlots = PlannerModel.findCropSlots(plan, previousCrop, maxSlots)
    if #matchingSlots == 0 then
        return {
            status = status.NOT_ALIGNED,
            cycleLength = cycleLength,
            previousCrop = previousCrop,
        }
    end

    local candidates = matchingSlots
    for historyIndex = 2, #historyNames do
        if #candidates <= 1 then break end

        local offset = historyIndex - 1
        local olderCrop = historyNames[historyIndex]
        local filtered = {}
        for _, slotIndex in ipairs(candidates) do
            local previousSlotIndex = ((slotIndex - offset - 1) % cycleLength) + 1
            if normalizeName(plan[previousSlotIndex]) == olderCrop then
                filtered[#filtered + 1] = slotIndex
            end
        end

        -- Older history may predate the current plan or contain a deliberate deviation.
        if #filtered == 0 then break end
        candidates = filtered
    end

    local firstByNextCrop = {}
    local nextCropCount = 0
    for _, slotIndex in ipairs(candidates) do
        local nextSlotIndex = PlannerModel.getNextIndex(slotIndex, cycleLength)
        local nextCrop = nextSlotIndex ~= nil and normalizeName(plan[nextSlotIndex]) or nil
        if nextCrop ~= nil and firstByNextCrop[nextCrop] == nil then
            firstByNextCrop[nextCrop] = {
                anchorSlotIndex = slotIndex,
                nextSlotIndex = nextSlotIndex,
            }
            nextCropCount = nextCropCount + 1
        end
    end

    if nextCropCount ~= 1 then
        return {
            status = status.AMBIGUOUS,
            cycleLength = cycleLength,
            previousCrop = previousCrop,
        }
    end

    local nextCrop, indices = next(firstByNextCrop)
    return {
        status = status.OK,
        cycleLength = cycleLength,
        previousCrop = previousCrop,
        anchorSlotIndex = indices.anchorSlotIndex,
        nextSlotIndex = indices.nextSlotIndex,
        nextCrop = nextCrop,
    }
end

---Returns every consecutive circular gap between sorted host positions.
-- A single host returns to itself after one complete cycle.
-- @param table positions
-- @param integer cycleLength
-- @return table gaps { from, to, years }
function PlannerModel.getCyclicGaps(positions, cycleLength)
    local length = tonumber(cycleLength) or 0
    local ordered = {}
    for _, position in ipairs(positions or {}) do
        local value = tonumber(position)
        if value ~= nil and value >= 1 and value <= length then
            ordered[#ordered + 1] = value
        end
    end
    table.sort(ordered)

    local gaps = {}
    if length < 1 or #ordered == 0 then return gaps end

    for index, position in ipairs(ordered) do
        local nextPosition = ordered[index + 1] or ordered[1]
        local years = nextPosition - position
        if years <= 0 then years = years + length end
        gaps[#gaps + 1] = {
            from = position,
            to = nextPosition,
            years = years,
        }
    end
    return gaps
end

local function collectPositions(slots, keyAccessor)
    local positionsByKey = {}
    for index, slot in ipairs(slots or {}) do
        for key in pairs(keyAccessor(slot) or {}) do
            positionsByKey[key] = positionsByKey[key] or {}
            positionsByKey[key][#positionsByKey[key] + 1] = index
        end
    end
    return positionsByKey
end

---Calculates family-spacing penalties on the complete circular cycle.
-- @param table slots { family, diseases }
-- @param table familyIntervals family->minimum return interval
-- @param number penaltyPerYear
-- @return number penalty
-- @return table conflictEvents
function PlannerModel.calculateFamilyPenalty(slots, familyIntervals, penaltyPerYear)
    local cycleLength = #(slots or {})
    local positionsByFamily = collectPositions(slots, function(slot)
        local family = slot ~= nil and slot.family or nil
        if family == nil or family == "UNKNOWN" or family == "FALLOW" then return nil end
        return { [family] = true }
    end)
    local penalty = 0
    local events = {}

    for _, family in ipairs(sortedKeys(positionsByFamily)) do
        local minInterval = tonumber(familyIntervals ~= nil and familyIntervals[family] or nil)
        if minInterval ~= nil and minInterval > 0 then
            for _, gap in ipairs(PlannerModel.getCyclicGaps(positionsByFamily[family], cycleLength)) do
                local deficit = minInterval - gap.years
                if deficit > 0 then
                    local amount = deficit * (tonumber(penaltyPerYear) or 0)
                    penalty = penalty + amount
                    events[#events + 1] = {
                        family = family,
                        from = gap.from,
                        to = gap.to,
                        years = gap.years,
                        minInterval = minInterval,
                        deficit = deficit,
                        penalty = amount,
                    }
                end
            end
        end
    end

    return penalty, events
end

---Calculates rotation-relevant disease penalties on the complete circular cycle.
-- For a transition already covered by a same-family rule, only the interval beyond
-- that family rule is charged. Multiple shared diseases on the same transition use
-- the single worst deficit.
-- @param table slots { family, diseases }
-- @param table familyIntervals family->minimum return interval
-- @param table diseaseIntervals group->minimum return interval
-- @param table diseaseRotationRelevant group->boolean
-- @param number penaltyPerYear
-- @return number penalty
-- @return table conflictEvents
function PlannerModel.calculateDiseasePenalty(slots, familyIntervals, diseaseIntervals, diseaseRotationRelevant, penaltyPerYear)
    local cycleLength = #(slots or {})
    local positionsByGroup = collectPositions(slots, function(slot)
        return slot ~= nil and slot.diseases or nil
    end)
    local worstByTransition = {}

    for _, group in ipairs(sortedKeys(positionsByGroup)) do
        local relevant = diseaseRotationRelevant ~= nil and diseaseRotationRelevant[group] == true
        local minInterval = tonumber(diseaseIntervals ~= nil and diseaseIntervals[group] or nil)
        if relevant and minInterval ~= nil and minInterval > 0 then
            for _, gap in ipairs(PlannerModel.getCyclicGaps(positionsByGroup[group], cycleLength)) do
                local fromSlot = slots[gap.from] or {}
                local toSlot = slots[gap.to] or {}
                local familyMinInterval
                if fromSlot.family ~= nil and fromSlot.family == toSlot.family then
                    familyMinInterval = tonumber(familyIntervals ~= nil and familyIntervals[fromSlot.family] or nil)
                end
                local baseline = gap.years
                if familyMinInterval ~= nil and familyMinInterval > baseline then
                    baseline = familyMinInterval
                end
                local deficit = minInterval - baseline
                if deficit > 0 then
                    local key = string.format("%d:%d", gap.from, gap.to)
                    local previous = worstByTransition[key]
                    if previous == nil or deficit > previous.deficit
                        or (deficit == previous.deficit and tostring(group) < tostring(previous.group)) then
                        worstByTransition[key] = {
                            group = group,
                            from = gap.from,
                            to = gap.to,
                            years = gap.years,
                            baseline = baseline,
                            minInterval = minInterval,
                            deficit = deficit,
                        }
                    end
                end
            end
        end
    end

    local penalty = 0
    local events = {}
    for _, key in ipairs(sortedKeys(worstByTransition)) do
        local event = worstByTransition[key]
        event.penalty = event.deficit * (tonumber(penaltyPerYear) or 0)
        penalty = penalty + event.penalty
        events[#events + 1] = event
    end
    return penalty, events
end

---Evaluates an immediate planned transition with the same anti-double-count rule as the score.
-- @param table fromSlot { family, diseases }
-- @param table toSlot { family, diseases }
-- @param table familyIntervals
-- @param table diseaseIntervals
-- @param table diseaseRotationRelevant
-- @param number familyPenaltyPerYear
-- @param number diseasePenaltyPerYear
-- @return table conflict, or nil
function PlannerModel.evaluateImmediateConflict(fromSlot, toSlot, familyIntervals, diseaseIntervals,
        diseaseRotationRelevant, familyPenaltyPerYear, diseasePenaltyPerYear)
    local familyA = fromSlot ~= nil and fromSlot.family or nil
    local familyB = toSlot ~= nil and toSlot.family or nil
    if familyA == nil or familyB == nil or familyA == "FALLOW" or familyB == "FALLOW"
        or familyA == "UNKNOWN" or familyB == "UNKNOWN" then
        return nil
    end

    local familyMinInterval
    if familyA == familyB then
        familyMinInterval = tonumber(familyIntervals ~= nil and familyIntervals[familyA] or nil)
    end
    local familyDeficit = familyMinInterval ~= nil and math.max(0, familyMinInterval - 1) or 0
    local diseaseBaseline = math.max(1, familyMinInterval or 1)
    local worstGroup, worstMinInterval, worstDeficit = nil, 0, 0
    local diseasesA = fromSlot.diseases or {}
    local diseasesB = toSlot.diseases or {}

    for group in pairs(diseasesA) do
        local relevant = diseaseRotationRelevant ~= nil and diseaseRotationRelevant[group] == true
        local minInterval = tonumber(diseaseIntervals ~= nil and diseaseIntervals[group] or nil)
        local deficit = relevant and minInterval ~= nil and (minInterval - diseaseBaseline) or 0
        if diseasesB[group] and deficit > 0
            and (deficit > worstDeficit
                or (deficit == worstDeficit and tostring(group) < tostring(worstGroup))) then
            worstGroup = group
            worstMinInterval = minInterval
            worstDeficit = deficit
        end
    end

    if worstGroup ~= nil then
        return {
            kind = "disease",
            group = worstGroup,
            yearsRemaining = worstMinInterval - 1,
            minInterval = worstMinInterval,
            penalty = familyDeficit * (tonumber(familyPenaltyPerYear) or 0)
                + worstDeficit * (tonumber(diseasePenaltyPerYear) or 0),
        }
    end

    if familyDeficit > 0 then
        return {
            kind = "family",
            family = familyA,
            yearsRemaining = familyMinInterval - 1,
            minInterval = familyMinInterval,
            penalty = familyDeficit * (tonumber(familyPenaltyPerYear) or 0),
        }
    end

    return nil
end
