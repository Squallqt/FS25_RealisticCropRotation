local assertions = 0

local function assertEqual(actual, expected, label)
    assertions = assertions + 1
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
    end
end

function Class(classTable)
    return { __index = classTable }
end

RealisticCropRotation = {
    SPECIAL_CROP_FALLOW = "__FALLOW",
}

dofile("FS25_RealisticCropRotation/scripts/RealisticCropRotationService.lua")

local function newRepository(lastCrop, lastGrowth)
    local repository = {
        lastCrop = lastCrop,
        lastGrowth = lastGrowth,
    }
    function repository:getLastKnownActiveCrop()
        return self.lastCrop
    end
    function repository:getLastKnownGrowthState()
        return self.lastGrowth
    end
    function repository:setLastKnownActiveCrop(_, cropName)
        local changed = self.lastCrop ~= cropName
        self.lastCrop = cropName
        return changed
    end
    function repository:setLastKnownGrowthState(_, growthState)
        local changed = self.lastGrowth ~= growthState
        self.lastGrowth = growthState
        return changed
    end
    return repository
end

local function newService(lastCrop, lastGrowth)
    local service = RealisticCropRotationService.new(newRepository(lastCrop, lastGrowth))
    service.pushed = {}
    function service:pushHistoryCrop(_, cropName)
        if cropName == nil then return false end
        self.pushed[#self.pushed + 1] = cropName
        return true
    end
    function service:pushFallowIfPlanned()
        return false
    end
    return service
end

do
    local service = newService(nil, nil)
    local changed, completed = service:reconcileActiveCrop(1, "wheat", 1, 2, false)
    assertEqual(changed, true, "initial active crop tracking")
    assertEqual(#completed, 0, "initial read completes no crop")
    assertEqual(service.repository.lastCrop, "WHEAT", "initial crop normalized")
end

do
    local service = newService("WHEAT", 6)
    local changed, completed = service:reconcileActiveCrop(2, "maize", 2, 1, false)
    assertEqual(changed, true, "real crop change")
    assertEqual(#completed, 1, "one completed crop")
    assertEqual(completed[1], "WHEAT", "exact completed crop")
    assertEqual(service.repository.lastCrop, "MAIZE", "new crop tracked")
end

do
    local service = newService("WHEAT", 6)
    function service:getFruitTypeForCrop()
        return { regrows = false }
    end
    function service:isFreshReplantingGrowthDrop()
        return true
    end

    local changed, completed = service:reconcileActiveCrop(3, "WHEAT", 1, 1, false)
    assertEqual(changed, true, "same-crop replant")
    assertEqual(#completed, 1, "replant completes one cycle")
    assertEqual(completed[1], "WHEAT", "replant completed crop")
end

do
    local service = newService("WHEAT", 6)
    function service:pushFallowIfPlanned()
        return true
    end

    local changed, completed = service:reconcileActiveCrop(4, "MAIZE", 2, 1, false)
    assertEqual(changed, true, "crop change with planned fallow")
    assertEqual(#completed, 2, "crop and fallow steps")
    assertEqual(completed[1], "WHEAT", "crop precedes fallow")
    assertEqual(completed[2], "__FALLOW", "fallow step explicit")
end

print(string.format("reconcile_spec: %d assertions passed", assertions))
