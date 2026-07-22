-- Copyright © 2026 Squallqt. All rights reserved.
-- Treatment consumption and expiry wiring for harvested or mown areas.
RealisticCropRotationTreatmentLifecycle = {}
RealisticCropRotationTreatmentLifecycle.NEMATICIDE_DURATION_PERIODS = 3
local installed = false
local nematicidePeriodsRemaining = {}

---Starts the countdown on the sole farmland selected for the sprayed area.
-- @param integer farmlandId
function RealisticCropRotationTreatmentLifecycle.onNematicideApplied(farmlandId)
    farmlandId = tonumber(farmlandId)
    if farmlandId == nil or farmlandId <= 0 then return end
    nematicidePeriodsRemaining[farmlandId] = RealisticCropRotationTreatmentLifecycle.NEMATICIDE_DURATION_PERIODS
end

function RealisticCropRotationTreatmentLifecycle.getSyncData()
    local data = {}
    for farmlandId, remaining in pairs(nematicidePeriodsRemaining) do
        data[farmlandId] = remaining
    end
    return data
end

function RealisticCropRotationTreatmentLifecycle.getNematicidePeriodsRemaining(farmlandId)
    return nematicidePeriodsRemaining[tonumber(farmlandId) or farmlandId]
end

function RealisticCropRotationTreatmentLifecycle.applySyncData(received)
    received = received or {}
    local manager = RealisticCropRotation ~= nil and RealisticCropRotation.manager or nil
    local grid = RealisticCropRotation ~= nil and RealisticCropRotation.grid or nil
    if manager ~= nil and grid ~= nil and type(manager.getFieldByFarmlandId) == "function"
        and type(grid.clearFieldProtectionFamily) == "function" then
        for farmlandId in pairs(nematicidePeriodsRemaining) do
            if received[farmlandId] == nil then
                local field = manager:getFieldByFarmlandId(farmlandId)
                if field ~= nil then grid:clearFieldProtectionFamily(field, "NEMATICIDE") end
            end
        end
    end

    nematicidePeriodsRemaining = {}
    for farmlandId, remaining in pairs(received) do
        local id, value = tonumber(farmlandId), tonumber(remaining)
        if id ~= nil and id > 0 and value ~= nil then nematicidePeriodsRemaining[id] = value end
    end
end

function RealisticCropRotationTreatmentLifecycle.onPeriodChanged()
    if g_server == nil then return false end
    local manager = RealisticCropRotation ~= nil and RealisticCropRotation.manager or nil
    local grid = RealisticCropRotation ~= nil and RealisticCropRotation.grid or nil
    if manager == nil or grid == nil
        or type(manager.getFieldByFarmlandId) ~= "function"
        or type(grid.clearFieldProtectionFamily) ~= "function" then
        return false
    end

    local changed = false
    for farmlandId, remaining in pairs(nematicidePeriodsRemaining) do
        remaining = remaining - 1
        if remaining <= 0 then
            local field = manager:getFieldByFarmlandId(farmlandId)
            if field ~= nil then
                grid:clearFieldProtectionFamily(field, "NEMATICIDE")
            end
            nematicidePeriodsRemaining[farmlandId] = nil
            changed = true
        else
            nematicidePeriodsRemaining[farmlandId] = remaining
        end
    end
    return changed
end

function RealisticCropRotationTreatmentLifecycle.saveToXML(savegamePath)
    if g_server == nil or savegamePath == nil or savegamePath == "" then return end
    local xmlFile = createXMLFile("rcrTreatmentLifecycle",
        savegamePath .. "realisticCropRotationTreatmentLifecycle.xml", "realisticCropRotationTreatmentLifecycle")
    if xmlFile == nil or xmlFile == 0 then return end

    local index = 0
    for farmlandId, remaining in pairs(nematicidePeriodsRemaining) do
        local key = string.format("realisticCropRotationTreatmentLifecycle.nematicide(%d)", index)
        setXMLInt(xmlFile, key .. "#farmlandId", farmlandId)
        setXMLInt(xmlFile, key .. "#remainingPeriods", remaining)
        index = index + 1
    end
    saveXMLFile(xmlFile)
    delete(xmlFile)
end

function RealisticCropRotationTreatmentLifecycle.loadFromXML(savegamePath)
    nematicidePeriodsRemaining = {}
    if g_server == nil or savegamePath == nil or savegamePath == "" then return end
    local filePath = savegamePath .. "realisticCropRotationTreatmentLifecycle.xml"
    if fileExists == nil or not fileExists(filePath) then return end
    local xmlFile = loadXMLFile("rcrTreatmentLifecycle", filePath)
    if xmlFile == nil or xmlFile == 0 then return end

    local index = 0
    while true do
        local key = string.format("realisticCropRotationTreatmentLifecycle.nematicide(%d)", index)
        if not hasXMLProperty(xmlFile, key) then break end
        local farmlandId = getXMLInt(xmlFile, key .. "#farmlandId")
        local remaining = getXMLInt(xmlFile, key .. "#remainingPeriods")
        if farmlandId ~= nil and farmlandId > 0 and remaining ~= nil and remaining > 0 then
            nematicidePeriodsRemaining[farmlandId] = remaining
        end
        index = index + 1
    end
    delete(xmlFile)
end

function RealisticCropRotationTreatmentLifecycle.delete()
    nematicidePeriodsRemaining = {}
end

local function clearCutFungicide(sx, sz, wx, wz, hx, hz)
    local grid = RealisticCropRotation ~= nil and RealisticCropRotation.grid or nil
    if grid == nil or type(grid.clearProtectionArea) ~= "function" then return end
    grid:clearProtectionArea("FUNGICIDE", sx, sz, wx, wz, hx, hz)
end

function RealisticCropRotationTreatmentLifecycle.install()
    if installed or Utils == nil or type(Utils.overwrittenFunction) ~= "function"
        or FSDensityMapUtil == nil then
        return
    end

    if type(FSDensityMapUtil.cutFruitArea) == "function" then
        FSDensityMapUtil.cutFruitArea = Utils.overwrittenFunction(FSDensityMapUtil.cutFruitArea,
            function(fruitIndex, superFunc, sx, sz, wx, wz, hx, hz, ...)
                local area, totalArea, sprayFactor, plowFactor, limeFactor, weedFactor,
                    stubbleFactor, rollerFactor, beeYieldBonusPerc, growthState,
                    pixelsSum, terrainDetailPixelsSum = superFunc(fruitIndex, sx, sz, wx, wz, hx, hz, ...)
                if (area or 0) > 0 then
                    clearCutFungicide(sx, sz, wx, wz, hx, hz)
                end
                return area, totalArea, sprayFactor, plowFactor, limeFactor, weedFactor,
                    stubbleFactor, rollerFactor, beeYieldBonusPerc, growthState,
                    pixelsSum, terrainDetailPixelsSum
            end)
    end

    if type(FSDensityMapUtil.updateMowerArea) == "function" then
        FSDensityMapUtil.updateMowerArea = Utils.overwrittenFunction(FSDensityMapUtil.updateMowerArea,
            function(fruitType, superFunc, sx, sz, wx, wz, hx, hz, ...)
                local changedArea, totalArea, sprayFactor, plowFactor, limeFactor, weedFactor,
                    stubbleFactor, rollerFactor, beeYieldBonusPerc, growthState,
                    pixelsSum = superFunc(fruitType, sx, sz, wx, wz, hx, hz, ...)
                if (changedArea or 0) > 0 then
                    clearCutFungicide(sx, sz, wx, wz, hx, hz)
                end
                return changedArea, totalArea, sprayFactor, plowFactor, limeFactor, weedFactor,
                    stubbleFactor, rollerFactor, beeYieldBonusPerc, growthState, pixelsSum
            end)
    end

    installed = true
end
