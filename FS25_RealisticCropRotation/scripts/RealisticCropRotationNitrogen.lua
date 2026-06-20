-- Copyright © 2026 Squallqt. All rights reserved.
-- Deposits configured rotation nitrogen residue on fruit pixels destroyed by native tillage.
RealisticCropRotationNitrogen = {}
RealisticCropRotationNitrogen.PF_STATE_KG = 5

local manager = nil
local installed = false
local nitrogenMap = nil
local targetData = nil
local transition = nil
local pfWriters = {}
local vanillaModifier = nil
local vanillaLevelFilter = nil

---Returns PF nitrogen density data, or nil when PF is absent.
local function getPFData()
    if targetData ~= nil and targetData.mode == "pf" then return targetData end
    if nitrogenMap == nil and manager ~= nil and type(manager.getPrecisionFarming) == "function" then
        local pf = manager:getPrecisionFarming()
        nitrogenMap = pf ~= nil and pf.nitrogenMap or nil
    end
    if nitrogenMap == nil then return nil end

    local mapId = tonumber(nitrogenMap.bitVectorMap)
    local firstChannel = tonumber(nitrogenMap.firstChannel)
    local numChannels = tonumber(nitrogenMap.numChannels)
    local maxValue = math.floor(tonumber(nitrogenMap.maxValue) or 45)
    if mapId == nil or firstChannel == nil or numChannels == nil or maxValue <= 0 then return nil end

    targetData = {
        mode = "pf",
        mapId = mapId,
        firstChannel = firstChannel,
        numChannels = numChannels,
        maxValue = maxValue,
    }
    return targetData
end

---Returns vanilla spray-level density data.
local function getVanillaData()
    if targetData ~= nil and targetData.mode == "vanilla" then return targetData end
    local mission = g_currentMission
    local system = mission ~= nil and mission.fieldGroundSystem or nil
    if system == nil or FieldDensityMap == nil or FieldDensityMap.SPRAY_LEVEL == nil then return nil end

    local mapId, firstChannel, numChannels = system:getDensityMapData(FieldDensityMap.SPRAY_LEVEL)
    local maxValue = system:getMaxValue(FieldDensityMap.SPRAY_LEVEL)
    mapId, firstChannel, numChannels, maxValue = tonumber(mapId), tonumber(firstChannel),
        tonumber(numChannels), math.floor(tonumber(maxValue) or 0)
    if mapId == nil or firstChannel == nil or numChannels == nil or maxValue <= 0 then return nil end

    targetData = {
        mode = "vanilla",
        mapId = mapId,
        firstChannel = firstChannel,
        numChannels = numChannels,
        maxValue = maxValue,
    }
    return targetData
end

local function getTargetData()
    return getPFData() or getVanillaData()
end

---Returns every non-cover fruit type with a density plane (any termination can carry the previous n2).
local function getConfiguredCrops()
    local result = {}
    if g_fruitTypeManager == nil or type(g_fruitTypeManager.getFruitTypes) ~= "function" then
        return result
    end
    local config = RealisticCropRotation ~= nil and RealisticCropRotation.cropConfig or nil
    local coverCrops = (config ~= nil and config.coverCrops) or {}

    local entries = {}
    for _, desc in pairs(g_fruitTypeManager:getFruitTypes()) do
        if desc ~= nil and desc.name ~= nil and desc.isCatchCrop ~= true
            and desc.terrainDataPlaneId ~= nil and desc.startStateChannel ~= nil
            and (tonumber(desc.numStateChannels) or 0) > 0 then
            local name = string.upper(tostring(desc.name))
            if not coverCrops[name] then
                local maxState = (2 ^ math.floor(tonumber(desc.numStateChannels) or 0)) - 1
                if maxState > 0 and entries[name] == nil then
                    entries[name] = { name = name, desc = desc, maxState = maxState }
                end
            end
        end
    end

    local names = {}
    for name in pairs(entries) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do table.insert(result, entries[name]) end
    return result
end

local function setArea(modifier, sx, sz, wx, wz, hx, hz)
    modifier:setParallelogramWorldCoords(
        sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
end

local function setMaskArea(context, modifier, sx, sz, wx, wz, hx, hz)
    sx, sz = (sx + context.halfTerrain) * context.scaleX,
        (sz + context.halfTerrain) * context.scaleY
    wx, wz = (wx + context.halfTerrain) * context.scaleX,
        (wz + context.halfTerrain) * context.scaleY
    hx, hz = (hx + context.halfTerrain) * context.scaleX,
        (hz + context.halfTerrain) * context.scaleY
    modifier:setParallelogramDensityMapCoords(
        sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
end

local function deleteTransition()
    if transition ~= nil and transition.mapIds ~= nil and delete ~= nil then
        for _, mapId in ipairs(transition.mapIds) do
            delete(mapId)
        end
    end
    transition = nil
    pfWriters = {}
    vanillaModifier = nil
    vanillaLevelFilter = nil
end

local function discardTransition(context)
    if context ~= nil and context.mapIds ~= nil and delete ~= nil then
        for _, mapId in ipairs(context.mapIds) do
            delete(mapId)
        end
    end
    return nil
end

local function createMask(context, name, sizeX, sizeY, numChannels)
    local mapId = createBitVectorMap(name)
    if mapId == nil then return nil end
    table.insert(context.mapIds, mapId)
    loadBitVectorMapNew(mapId, sizeX, sizeY, numChannels, false)

    local modifier = DensityMapModifier.new(mapId, 0, numChannels, g_terrainNode)
    if modifier ~= nil and DensityRoundingMode ~= nil and DensityRoundingMode.INCLUSIVE ~= nil then
        modifier:setPolygonRoundingMode(DensityRoundingMode.INCLUSIVE)
    end
    return mapId, modifier
end

---Builds cached two-bit transition masks: 1=regular, 2=pre-mulched, 3=rejected.
local function getTransition(data)
    if data == nil or createBitVectorMap == nil or loadBitVectorMapNew == nil
        or getBitVectorMapSize == nil or DensityMapModifier == nil
        or DensityMapFilter == nil or DensityValueCompareType == nil
        or DensityCoordType == nil or g_terrainNode == nil then
        return nil
    end

    local key = string.format("%s|%d", data.mode, data.mapId)
    if transition ~= nil and transition.key == key then return transition end
    deleteTransition()

    local crops = getConfiguredCrops()
    if #crops == 0 then return nil end
    local sizeX, sizeY = getBitVectorMapSize(data.mapId)
    sizeX, sizeY = tonumber(sizeX), tonumber(sizeY)
    if sizeX == nil or sizeX <= 0 then return nil end
    if sizeY == nil or sizeY <= 0 then sizeY = sizeX end
    local terrainSize = g_currentMission ~= nil and tonumber(g_currentMission.terrainSize) or nil
    if terrainSize == nil or terrainSize <= 0 then return nil end

    local context = {
        key = key,
        mapIds = {},
        maskGroups = {},
        crops = crops,
        data = data,
        halfTerrain = terrainSize * 0.5,
        scaleX = sizeX / terrainSize,
        scaleY = sizeY / terrainSize,
    }
    for index, crop in ipairs(crops) do
        local desc = crop.desc
        local groupIndex = math.floor((index - 1) / 3) + 1
        local group = context.maskGroups[groupIndex]
        if group == nil then
            local groupChannels = math.min(3, #crops - (groupIndex - 1) * 3) * 2
            local groupMapId, groupModifier = createMask(
                context, string.format("rcrResidueTransition_%d", groupIndex),
                sizeX, sizeY, groupChannels)
            if groupModifier == nil then
                return discardTransition(context)
            end
            group = { mapId = groupMapId, modifier = groupModifier }
            context.maskGroups[groupIndex] = group
        end

        crop.mapId = group.mapId
        crop.channel = ((index - 1) % 3) * 2
        crop.modifier = DensityMapModifier.new(crop.mapId, crop.channel, 2, g_terrainNode)
        if crop.modifier == nil then
            return discardTransition(context)
        end
        if DensityRoundingMode ~= nil and DensityRoundingMode.INCLUSIVE ~= nil then
            crop.modifier:setPolygonRoundingMode(DensityRoundingMode.INCLUSIVE)
        end

        crop.mulchedState = math.floor(tonumber(desc.mulchedState) or 0)
        crop.presentFilter = DensityMapFilter.new(
            desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels)
        crop.regularMaskFilter = DensityMapFilter.new(crop.mapId, crop.channel, 2)
        crop.preMulchedMaskFilter = DensityMapFilter.new(crop.mapId, crop.channel, 2)
        crop.depositMaskFilter = DensityMapFilter.new(crop.mapId, crop.channel, 2)
        if crop.presentFilter == nil or crop.regularMaskFilter == nil
            or crop.preMulchedMaskFilter == nil or crop.depositMaskFilter == nil then
            return discardTransition(context)
        end

        crop.presentFilter:setValueCompareParams(DensityValueCompareType.BETWEEN, 1, crop.maxState)
        crop.regularMaskFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)
        crop.preMulchedMaskFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 2)
        crop.depositMaskFilter:setValueCompareParams(DensityValueCompareType.BETWEEN, 1, 2)

        if crop.mulchedState > 0 then
            crop.mulchedFilter = DensityMapFilter.new(
                desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels)
            crop.notMulchedFilter = DensityMapFilter.new(
                desc.terrainDataPlaneId, desc.startStateChannel, desc.numStateChannels)
            if crop.mulchedFilter == nil or crop.notMulchedFilter == nil then
                return discardTransition(context)
            end
            crop.mulchedFilter:setValueCompareParams(
                DensityValueCompareType.EQUAL, crop.mulchedState)
            crop.notMulchedFilter:setValueCompareParams(
                DensityValueCompareType.NOTEQUAL, crop.mulchedState)
        end
    end

    if data.mode == "vanilla" then
        context.unionMapId, context.unionModifier = createMask(
            context, "rcrResidueTransitionUnion", sizeX, sizeY, 1)
        context.unionFilter = context.unionMapId ~= nil
            and DensityMapFilter.new(context.unionMapId, 0, 1) or nil
        if context.unionModifier == nil or context.unionFilter == nil then
            return discardTransition(context)
        end
        context.unionFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)
    end

    transition = context
    return transition
end

---Captures crop pixels before native destruction.
local function capture(context, sx, sz, wx, wz, hx, hz)
    for _, group in ipairs(context.maskGroups) do
        setMaskArea(context, group.modifier, sx, sz, wx, wz, hx, hz)
        group.modifier:executeSet(0)
    end

    local active = {}
    for _, crop in ipairs(context.crops) do
        setMaskArea(context, crop.modifier, sx, sz, wx, wz, hx, hz)

        local _, regularPixels
        local preMulchedPixels = 0
        if crop.mulchedState > 0 then
            _, regularPixels = crop.modifier:executeSetWithStats(
                1, crop.presentFilter, crop.notMulchedFilter)
            _, preMulchedPixels = crop.modifier:executeSetWithStats(2, crop.mulchedFilter)
        else
            _, regularPixels = crop.modifier:executeSetWithStats(1, crop.presentFilter)
        end
        if (tonumber(regularPixels) or 0) + (tonumber(preMulchedPixels) or 0) > 0 then
            table.insert(active, crop)
        end
    end
    return active
end

---Keeps only transitions into the destroyed state, including final plough-out.
local function retainDestroyed(active)
    for _, crop in ipairs(active) do
        if crop.mulchedState > 0 then
            crop.modifier:executeSet(
                3, crop.regularMaskFilter, crop.presentFilter, crop.notMulchedFilter)
            crop.modifier:executeSet(3, crop.preMulchedMaskFilter, crop.presentFilter)
        else
            crop.modifier:executeSet(3, crop.regularMaskFilter, crop.presentFilter)
        end
    end
end

---Cached PF writer for a residue size: add states below the cap, clamp the rest to maxValue.
local function getPFWriter(data, states)
    local key = string.format("%d|%d|%d|%d",
        data.mapId, data.firstChannel, data.numChannels, states)
    if pfWriters[key] ~= nil then return pfWriters[key] end
    if DensityMapModifier == nil or DensityMapFilter == nil or DensityValueCompareType == nil
        or g_terrainNode == nil then
        return nil
    end

    local modifier = DensityMapModifier.new(
        data.mapId, data.firstChannel, data.numChannels, g_terrainNode)
    if DensityRoundingMode ~= nil and DensityRoundingMode.INCLUSIVE ~= nil then
        modifier:setPolygonRoundingMode(DensityRoundingMode.INCLUSIVE)
    end
    local belowFilter = DensityMapFilter.new(data.mapId, data.firstChannel, data.numChannels)
    belowFilter:setValueCompareParams(DensityValueCompareType.BETWEEN, 0, data.maxValue - states)
    local nearFilter = DensityMapFilter.new(data.mapId, data.firstChannel, data.numChannels)
    nearFilter:setValueCompareParams(
        DensityValueCompareType.BETWEEN, data.maxValue - states + 1, data.maxValue)

    pfWriters[key] = { modifier = modifier, belowFilter = belowFilter, nearFilter = nearFilter }
    return pfWriters[key]
end

local function depositPF(context, active, farmlandId, sx, sz, wx, wz, hx, hz)
    local deposited = false
    for _, crop in ipairs(active) do
        local states = math.floor(tonumber(
            manager.service:getResidueStatesForTermination(farmlandId, crop.name)) or 0)
        if states > 0 then
            states = math.min(states, context.data.maxValue)
            local writer = getPFWriter(context.data, states)
            if writer ~= nil then
                writer.modifier:setParallelogramWorldCoords(
                    sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
                -- Clamp the cap band first, then add to the rest -> min(V + states, maxValue).
                writer.modifier:executeSet(
                    context.data.maxValue, crop.depositMaskFilter, writer.nearFilter)
                writer.modifier:executeAdd(states, crop.depositMaskFilter, writer.belowFilter)
                deposited = true
            end
        end
    end
    if deposited and nitrogenMap ~= nil and type(nitrogenMap.setMinimapRequiresUpdate) == "function" then
        nitrogenMap:setMinimapRequiresUpdate(true)
    end
end

local function depositVanilla(context, active, farmlandId, sx, sz, wx, wz, hx, hz)
    local required = false
    setMaskArea(context, context.unionModifier, sx, sz, wx, wz, hx, hz)
    context.unionModifier:executeSet(0)
    for _, crop in ipairs(active) do
        if manager.service:getResidueStatesForTermination(farmlandId, crop.name) > 0 then
            required = true
            context.unionModifier:executeSet(1, crop.depositMaskFilter)
        end
    end
    if not required then return end

    local data = context.data
    if vanillaModifier == nil then
        vanillaModifier = DensityMapModifier.new(
            data.mapId, data.firstChannel, data.numChannels, g_terrainNode)
        vanillaLevelFilter = DensityMapFilter.new(data.mapId, data.firstChannel, data.numChannels)
        vanillaLevelFilter:setValueCompareParams(DensityValueCompareType.BETWEEN, 0, data.maxValue - 1)
    end
    setArea(vanillaModifier, sx, sz, wx, wz, hx, hz)
    vanillaModifier:executeAdd(1, context.unionFilter, vanillaLevelFilter)
end

local function getFarmlandId(sx, sz, wx, wz, hx, hz)
    if g_farmlandManager == nil
        or type(g_farmlandManager.getFarmlandIdAtWorldPosition) ~= "function" then
        return nil
    end
    local x = sx + (wx - sx) * 0.5 + (hx - sx) * 0.5
    local z = sz + (wz - sz) * 0.5 + (hz - sz) * 0.5
    local farmlandId = tonumber(g_farmlandManager:getFarmlandIdAtWorldPosition(x, z))
    return farmlandId ~= nil and farmlandId > 0 and farmlandId or nil
end

local function process(context, active, farmlandId, sx, sz, wx, wz, hx, hz)
    retainDestroyed(active)
    if farmlandId ~= nil then
        if context.data.mode == "pf" then
            depositPF(context, active, farmlandId, sx, sz, wx, wz, hx, hz)
        else
            depositVanilla(context, active, farmlandId, sx, sz, wx, wz, hx, hz)
        end
    end
    for _, group in ipairs(context.maskGroups) do
        group.modifier:executeSet(0)
    end
    if context.unionModifier ~= nil then
        context.unionModifier:executeSet(0)
    end
end

local function resetContext(context)
    if context == nil then return end
    for _, group in ipairs(context.maskGroups) do
        group.modifier:executeSet(0)
    end
    if context.unionModifier ~= nil then
        context.unionModifier:executeSet(0)
    end
end

local function prepare(sx, sz, wx, wz, hx, hz)
    local context = getTransition(getTargetData())
    if context == nil then return nil end
    return context, capture(context, sx, sz, wx, wz, hx, hz),
        getFarmlandId(sx, sz, wx, wz, hx, hz)
end

function RealisticCropRotationNitrogen.delete()
    deleteTransition()
    manager = nil
    nitrogenMap = nil
    targetData = nil
end

function RealisticCropRotationNitrogen.install(rcrManager)
    if rcrManager == nil or rcrManager.service == nil then return end
    manager = rcrManager
    if installed then return end
    if g_currentMission == nil or type(g_currentMission.getIsServer) ~= "function"
        or not g_currentMission:getIsServer() then return end
    if Utils == nil or type(Utils.overwrittenFunction) ~= "function" or FSDensityMapUtil == nil
        or type(FSDensityMapUtil.updateDestroyCommonArea) ~= "function" then return end

    installed = true
    FSDensityMapUtil.updateDestroyCommonArea = Utils.overwrittenFunction(
        FSDensityMapUtil.updateDestroyCommonArea,
        function(sx, superFunc, sz, wx, wz, hx, hz, ...)
            local context, active, farmlandId
            if type(sx) == "number" and type(sz) == "number" and type(wx) == "number"
                and type(wz) == "number" and type(hx) == "number" and type(hz) == "number" then
                local ok, preparedContext, preparedActive, preparedFarmlandId =
                    pcall(prepare, sx, sz, wx, wz, hx, hz)
                if ok then
                    context, active, farmlandId = preparedContext, preparedActive, preparedFarmlandId
                else
                    Logging.error(
                        "[RealisticCropRotation] residue mask capture failed: %s",
                        tostring(preparedContext))
                end
            end

            local changedArea, totalArea = superFunc(sx, sz, wx, wz, hx, hz, ...)
            if context ~= nil and active ~= nil and #active > 0 then
                local ok, err = pcall(process, context, active, farmlandId, sx, sz, wx, wz, hx, hz)
                if not ok then
                    pcall(resetContext, context)
                    Logging.error("[RealisticCropRotation] residue deposit failed: %s", tostring(err))
                end
            end
            return changedArea, totalArea
        end)

    Logging.info("[RealisticCropRotation] nitrogen residue active (server): transient native mask")
end
