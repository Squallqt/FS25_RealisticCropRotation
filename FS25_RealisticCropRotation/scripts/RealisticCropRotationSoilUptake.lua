-- Copyright © 2026 Squallqt. All rights reserved.
-- Applies the configured harvest soil draw only to crop cells newly destroyed by disease.
RealisticCropRotationSoilUptake = {}

local MASK_NUM_CHANNELS = 1
local maskContexts = {}
local maskContextCount = 0
local writers = {}
local soilFilters = {}
local valueFilters = {}
local cropFilterCache = {}
local phStateCache = {}
local pfConfigCache = nil
local warned = {}

local function warnOnce(key, message, ...)
    if warned[key] then return end
    warned[key] = true
    if Logging ~= nil and type(Logging.warning) == "function" then
        Logging.warning("[RealisticCropRotation] " .. message, ...)
    end
end

local function setWorldArea(modifier, minX, minZ, maxX, maxZ)
    modifier:setParallelogramWorldCoords(
        minX, minZ, maxX, minZ, minX, maxZ, DensityCoordType.POINT_POINT_POINT)
end

local function setInclusiveRounding(modifier)
    if modifier ~= nil and DensityRoundingMode ~= nil
        and DensityRoundingMode.INCLUSIVE ~= nil then
        modifier:setPolygonRoundingMode(DensityRoundingMode.INCLUSIVE)
    end
end

local function getMapSize(mapId)
    if mapId == nil or getBitVectorMapSize == nil then return nil end
    local sizeX, sizeY = getBitVectorMapSize(mapId)
    sizeX, sizeY = tonumber(sizeX), tonumber(sizeY)
    if sizeX == nil or sizeX <= 0 then return nil end
    if sizeY == nil or sizeY <= 0 then sizeY = sizeX end
    return math.floor(sizeX), math.floor(sizeY)
end

local function getMaskContext(target)
    local sizeX, sizeY = getMapSize(target ~= nil and target.mapId or nil)
    if sizeX == nil or createBitVectorMap == nil or loadBitVectorMapNew == nil
        or DensityMapModifier == nil or DensityMapFilter == nil
        or DensityValueCompareType == nil or g_terrainNode == nil then
        return nil
    end

    local key = string.format("%d|%d", sizeX, sizeY)
    if maskContexts[key] ~= nil then return maskContexts[key] end

    maskContextCount = maskContextCount + 1
    local mapId = createBitVectorMap(string.format("rcrDiseaseSoilMask_%d", maskContextCount))
    if mapId == nil then return nil end
    loadBitVectorMapNew(mapId, sizeX, sizeY, MASK_NUM_CHANNELS, false)

    local modifier = DensityMapModifier.new(mapId, 0, MASK_NUM_CHANNELS, g_terrainNode)
    local filter = DensityMapFilter.new(mapId, 0, MASK_NUM_CHANNELS)
    if modifier == nil or filter == nil then
        if delete ~= nil then delete(mapId) end
        return nil
    end
    setInclusiveRounding(modifier)
    filter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)

    local context = {
        key = key,
        mapId = mapId,
        modifier = modifier,
        filter = filter,
    }
    maskContexts[key] = context
    return context
end

---Returns density values that represent harvested or otherwise terminal foliage.
-- @param table desc Fruit type descriptor
-- @return table states Sorted density values
function RealisticCropRotationSoilUptake.getTerminalDensityStates(desc)
    if desc == nil then return {} end
    local excludedStates = {}
    for state, isCut in pairs(desc.cutStates or {}) do
        local numericState = tonumber(state)
        if isCut and numericState ~= nil then
            excludedStates[math.floor(numericState) + 1] = true
        end
    end
    if next(excludedStates) == nil then
        local cutState = math.floor(tonumber(desc.cutState) or 0)
        if cutState > 0 then excludedStates[cutState + 1] = true end
    end
    local witheredState = tonumber(desc.witheredState)
    if witheredState ~= nil then excludedStates[math.floor(witheredState) + 1] = true end
    local mulchedState = math.floor(tonumber(desc.mulchedState) or 0)
    if mulchedState > 0 then excludedStates[mulchedState + 1] = true end
    local rolledCutState = math.floor(tonumber(desc.rolledCutState) or 0)
    if rolledCutState > 0 then excludedStates[rolledCutState + 1] = true end

    local states = {}
    for state in pairs(excludedStates) do states[#states + 1] = state end
    table.sort(states)
    return states
end

local function getCropFilters(desc)
    if desc == nil or desc.terrainDataPlaneId == nil
        or DensityMapFilter == nil or DensityValueCompareType == nil then
        return nil
    end

    if cropFilterCache[desc] ~= nil then return cropFilterCache[desc] end

    local firstChannel = tonumber(desc.startStateChannel)
    local numChannels = math.floor(tonumber(desc.numStateChannels) or 0)
    if firstChannel == nil or numChannels <= 0 then return nil end

    local present = DensityMapFilter.new(desc.terrainDataPlaneId, firstChannel, numChannels)
    if present == nil then return nil end
    present:setValueCompareParams(DensityValueCompareType.BETWEEN, 1, (2 ^ numChannels) - 1)

    local excluded = {}
    local states = RealisticCropRotationSoilUptake.getTerminalDensityStates(desc)
    for _, state in ipairs(states) do
        local filter = DensityMapFilter.new(desc.terrainDataPlaneId, firstChannel, numChannels)
        if filter ~= nil then
            filter:setValueCompareParams(DensityValueCompareType.EQUAL, state)
            excluded[#excluded + 1] = filter
        end
    end

    local filters = { present = present, excluded = excluded }
    cropFilterCache[desc] = filters
    return filters
end

local function snapshotContext(context, region, cropFilters, minX, minZ, maxX, maxZ)
    setWorldArea(context.modifier, minX, minZ, maxX, maxZ)
    context.modifier:executeSet(0)

    if not RealisticCropRotationManager.applyRegionToModifier(region, context.modifier) then return nil end
    local _, paintedPixels = context.modifier:executeSetWithStats(1, cropFilters.present)
    paintedPixels = tonumber(paintedPixels) or 0

    -- Parcel mask folded into the snapshot mask.
    local outsideFilter = RealisticCropRotationManager.makeOutsideRegionFilter(region)
    if outsideFilter ~= nil then
        local _, droppedPixels = context.modifier:executeSetWithStats(0, outsideFilter)
        paintedPixels = paintedPixels - (tonumber(droppedPixels) or 0)
    end

    for _, filter in ipairs(cropFilters.excluded) do
        local _, removedPixels = context.modifier:executeSetWithStats(
            0, context.filter, filter)
        paintedPixels = paintedPixels - (tonumber(removedPixels) or 0)
    end
    return math.max(0, paintedPixels)
end

local function targetFromValueMap(valueMap)
    if valueMap == nil then return nil end
    local mapId = tonumber(valueMap.bitVectorMap)
    local firstChannel = tonumber(valueMap.firstChannel)
    local numChannels = math.floor(tonumber(valueMap.numChannels) or 0)
    if mapId == nil or firstChannel == nil or numChannels <= 0 then return nil end
    return {
        mapId = mapId,
        firstChannel = firstChannel,
        numChannels = numChannels,
        maxValue = math.floor(tonumber(valueMap.maxValue) or ((2 ^ numChannels) - 1)),
        valueMap = valueMap,
    }
end

local function targetFromVanillaLayer(layer)
    local system = g_currentMission ~= nil and g_currentMission.fieldGroundSystem or nil
    if system == nil or layer == nil or type(system.getDensityMapData) ~= "function" then
        return nil
    end

    local mapId, firstChannel, numChannels = system:getDensityMapData(layer)
    mapId, firstChannel = tonumber(mapId), tonumber(firstChannel)
    numChannels = math.floor(tonumber(numChannels) or 0)
    if mapId == nil or firstChannel == nil or numChannels <= 0 then return nil end

    return {
        mapId = mapId,
        firstChannel = firstChannel,
        numChannels = numChannels,
    }
end

local function soilTarget(soilMap)
    if soilMap == nil then return nil end
    local mapId = tonumber(soilMap.bitVectorMap)
    local firstChannel = tonumber(soilMap.typeFirstChannel)
    local numChannels = math.floor(tonumber(soilMap.typeNumChannels) or 0)
    if mapId == nil or firstChannel == nil or numChannels <= 0 then return nil end
    return {
        mapId = mapId,
        firstChannel = firstChannel,
        numChannels = numChannels,
    }
end

local function normalizePath(path)
    if path == nil then return nil end
    return string.lower(tostring(path):gsub("\\", "/"):gsub("/+", "/"))
end

local function joinPath(baseDirectory, filename)
    if baseDirectory == nil or filename == nil then return nil end
    filename = tostring(filename)
    if Utils ~= nil and type(Utils.getFilename) == "function" then
        local ok, resolved = pcall(Utils.getFilename, filename, baseDirectory)
        if ok and resolved ~= nil and resolved ~= "" then return resolved end
    end
    if filename:sub(1, 1) == "$" or filename:match("^%a:[/\\]")
        or filename:sub(1, 1) == "/" then
        return filename:sub(1, 1) == "$" and nil or filename
    end
    local base = tostring(baseDirectory)
    if base:sub(-1) ~= "/" and base:sub(-1) ~= "\\" then base = base .. "/" end
    return base .. filename
end

local function readFruitRequirements(xmlFile, rootKey)
    local requirements = {}
    local index = 0
    while true do
        local key = string.format("%s.fruitRequirement(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then break end

        local name = getXMLString(xmlFile, key .. "#fruitTypeName")
        if name ~= nil and name ~= "" then
            name = string.upper(tostring(name))
            local soils = {}
            local soilIndex = 0
            while true do
                local soilKey = string.format("%s.soil(%d)", key, soilIndex)
                if not hasXMLProperty(xmlFile, soilKey) then break end
                local typeIndex = tonumber(getXMLInt(xmlFile, soilKey .. "#soilTypeIndex"))
                -- Disease is not a forage cutter, so use the default non-forage reduction.
                local reduction = tonumber(getXMLFloat(xmlFile, soilKey .. "#reduction"))
                if typeIndex ~= nil and reduction ~= nil then
                    soils[math.floor(typeIndex)] = reduction
                end
                soilIndex = soilIndex + 1
            end
            requirements[name] = soils
        end
        index = index + 1
    end
    return requirements
end

local function parseNumberRange(value)
    if value == nil then return nil end
    local numbers = {}
    for token in tostring(value):gmatch("[^%s]+") do
        local number = tonumber(token)
        if number ~= nil then numbers[#numbers + 1] = number end
    end
    if #numbers < 2 then return nil end
    return numbers[1], numbers[2]
end

local function readPHTransformations(xmlFile)
    local transformations = {}
    local index = 0
    while true do
        local key = string.format(
            "precisionFarming.pHMap.valueTransformations.valueTransformation(%d)", index)
        if not hasXMLProperty(xmlFile, key) then break end

        local soilTypeIndex = tonumber(getXMLInt(xmlFile, key .. "#soilTypeIndex"))
        local decreaseKey = key .. ".decreasePerHarvest"
        local decrease = tonumber(getXMLFloat(xmlFile, decreaseKey .. "#value"))
        local minValue, maxValue = parseNumberRange(getXMLString(xmlFile, decreaseKey .. "#range"))
        if soilTypeIndex ~= nil and decrease ~= nil and minValue ~= nil and maxValue ~= nil then
            transformations[math.floor(soilTypeIndex)] = {
                decrease = decrease,
                minValue = minValue,
                maxValue = maxValue,
            }
        end
        index = index + 1
    end
    return transformations
end

local function findSelectedMapConfig(pf)
    local mission = g_currentMission
    local baseDirectory = mission ~= nil and mission.loadedMapBaseDirectory or nil
    local mapFilename = pf ~= nil and pf.mapFilename or nil
    if baseDirectory == nil or mapFilename == nil or fileExists == nil
        or loadXMLFile == nil or hasXMLProperty == nil then
        return nil
    end

    local modDescFilename = joinPath(baseDirectory, "modDesc.xml")
    if modDescFilename == nil or not fileExists(modDescFilename) then return nil end
    local modDesc = loadXMLFile("rcrPFMapModDesc", modDescFilename)
    if modDesc == nil or modDesc == 0 then return nil end

    local selected = nil
    local expectedMapFilename = normalizePath(mapFilename)
    local index = 0
    while true do
        local key = string.format("modDesc.maps.map(%d)", index)
        if not hasXMLProperty(modDesc, key) then break end
        local configFilename = joinPath(baseDirectory,
            getXMLString(modDesc, key .. "#configFilename"))
        if configFilename ~= nil and fileExists(configFilename) then
            local mapXML = loadXMLFile("rcrPFMapConfigProbe", configFilename)
            if mapXML ~= nil and mapXML ~= 0 then
                local configuredMapFilename = joinPath(baseDirectory,
                    getXMLString(mapXML, "map.filename"))
                if normalizePath(configuredMapFilename) == expectedMapFilename then
                    selected = configFilename
                end
                delete(mapXML)
            end
        end
        if selected ~= nil then break end
        index = index + 1
    end
    delete(modDesc)
    return selected
end

local function sameReductions(first, second)
    if first == nil or second == nil then return first == second end
    for soilTypeIndex, value in pairs(first) do
        if tonumber(second[soilTypeIndex]) ~= tonumber(value) then return false end
    end
    for soilTypeIndex, value in pairs(second) do
        if tonumber(first[soilTypeIndex]) ~= tonumber(value) then return false end
    end
    return true
end

local function getPFConfiguration(pf)
    local configFilename = pf ~= nil and pf.configFileName or nil
    local cacheKey = string.format("%s|%s", tostring(configFilename), tostring(pf ~= nil and pf.mapFilename))
    if pfConfigCache ~= nil and pfConfigCache.key == cacheKey then return pfConfigCache end

    local result = {
        key = cacheKey,
        baseRequirements = {},
        mapRequirements = {},
        pHTransformations = {},
    }
    pfConfigCache = result

    if configFilename == nil or fileExists == nil or not fileExists(configFilename)
        or loadXMLFile == nil then
        warnOnce("pfConfigMissing", "Precision Farming configuration is unavailable; disease nitrogen and pH draw is skipped")
        return result
    end

    local xmlFile = loadXMLFile("rcrPFConfiguration", configFilename)
    if xmlFile == nil or xmlFile == 0 then
        warnOnce("pfConfigUnreadable", "Precision Farming configuration '%s' could not be read", tostring(configFilename))
        return result
    end
    result.baseRequirements = readFruitRequirements(
        xmlFile, "precisionFarming.nitrogenMap.fruitRequirements")
    result.pHTransformations = readPHTransformations(xmlFile)
    delete(xmlFile)

    local mapConfigFilename = findSelectedMapConfig(pf)
    if mapConfigFilename ~= nil then
        local mapXML = loadXMLFile("rcrPFSelectedMapConfiguration", mapConfigFilename)
        if mapXML ~= nil and mapXML ~= 0 then
            result.mapRequirements = readFruitRequirements(
                mapXML, "map.precisionFarming.fruitRequirements")
            delete(mapXML)
        end
    end
    return result
end

local function getCropReductions(configuration, desc)
    local cropName = desc ~= nil and desc.name ~= nil and string.upper(tostring(desc.name)) or nil
    if cropName == nil then return nil end

    local base = configuration.baseRequirements[cropName]
    local map = configuration.mapRequirements[cropName]
    if base ~= nil and map ~= nil and not sameReductions(base, map) then
        warnOnce("pfRequirementConflict_" .. cropName,
            "Precision Farming defines conflicting base and map nitrogen reductions for '%s'; disease nitrogen draw is skipped for this crop",
            cropName)
        return nil
    end
    local reductions = map or base
    if reductions == nil then
        warnOnce("pfRequirementMissing_" .. cropName,
            "Precision Farming has no nitrogen reduction for crop '%s'; disease nitrogen draw is skipped for this crop",
            cropName)
    end
    return reductions
end

local function getStateStep(valueMap, methodName, propertyName)
    if valueMap == nil then return nil end
    local method = valueMap[methodName]
    if type(method) == "function" then
        local ok, value = pcall(method, valueMap, 1)
        value = ok and tonumber(value) or nil
        if value ~= nil and value > 0 then return value end
    end
    local value = tonumber(valueMap[propertyName])
    return value ~= nil and value > 0 and value or nil
end

local function exactStateCount(realValue, stateStep, warningKey, label)
    if realValue == nil or stateStep == nil then return nil end
    local raw = realValue / stateStep
    local states = math.floor(raw + 0.5)
    if math.abs(raw - states) > 0.0001 then
        warnOnce(warningKey, "%s %.4f is not representable by the active map step %.4f; this disease soil draw is skipped",
            label, realValue, stateStep)
        return nil
    end
    return states
end

local function internalPHState(pHMap, maxState, realValue, findUpper)
    if pHMap == nil or type(pHMap.getPhValueFromInternalValue) ~= "function" then return nil end
    local cacheKey = string.format("%s|%d|%.6f|%s",
        tostring(pHMap.bitVectorMap or pHMap), maxState, realValue, tostring(findUpper))
    if phStateCache[cacheKey] ~= nil then
        return phStateCache[cacheKey] ~= false and phStateCache[cacheKey] or nil
    end
    local selected = nil
    for state = 0, maxState do
        local ok, value = pcall(pHMap.getPhValueFromInternalValue, pHMap, state)
        value = ok and tonumber(value) or nil
        if value ~= nil then
            if findUpper then
                if value <= realValue + 0.0001 then selected = state end
            elseif value >= realValue - 0.0001 then
                phStateCache[cacheKey] = state
                return state
            end
        end
    end
    phStateCache[cacheKey] = selected ~= nil and selected or false
    return selected
end

local function addTarget(session, target)
    local context = getMaskContext(target)
    if context == nil then return end
    target.context = context
    session.targets[#session.targets + 1] = target
    session.contexts[context.key] = context
end

local function buildPFSession(session, pf, desc)
    local soil = soilTarget(pf.soilMap)
    if soil == nil then
        warnOnce("pfSoilMapMissing", "Precision Farming soil map is unavailable; disease nitrogen and pH draw is skipped")
        return
    end
    local configuration = getPFConfiguration(pf)

    local nitrogenMap = pf.nitrogenMap
    local nitrogen = targetFromValueMap(nitrogenMap)
    local reductions = getCropReductions(configuration, desc)
    local nitrogenStep = getStateStep(nitrogenMap, "getNitrogenFromChangedStates", "amountPerState")
    if nitrogen ~= nil and reductions ~= nil and nitrogenStep ~= nil then
        local reductionStates = {}
        for soilTypeIndex, reduction in pairs(reductions) do
            local states = exactStateCount(reduction, nitrogenStep,
                string.format("pfNReduction_%s_%d", tostring(desc.name), soilTypeIndex),
                "Precision Farming nitrogen reduction")
            if states ~= nil and states > 0 then reductionStates[soilTypeIndex] = states end
        end
        if next(reductionStates) ~= nil then
            nitrogen.kind = "pfNitrogen"
            nitrogen.soil = soil
            nitrogen.reductionStates = reductionStates
            addTarget(session, nitrogen)
        end
    end

    if desc.consumesLime ~= false then
        local pHMap = pf.pHMap
        local pH = targetFromValueMap(pHMap)
        local pHStep = getStateStep(pHMap, "getPhValueFromChangedStates", "pHValuePerState")
        if pH ~= nil and pHStep ~= nil then
            local transformations = {}
            for soilTypeIndex, transformation in pairs(configuration.pHTransformations) do
                local states = exactStateCount(transformation.decrease, pHStep,
                    string.format("pfPHDecrease_%d", soilTypeIndex),
                    "Precision Farming pH decrease")
                local minState = internalPHState(pHMap, pH.maxValue, transformation.minValue, false)
                local maxState = internalPHState(pHMap, pH.maxValue, transformation.maxValue, true)
                if states ~= nil and states > 0 and minState ~= nil and maxState ~= nil then
                    transformations[soilTypeIndex] = {
                        states = states,
                        minState = minState,
                        maxState = maxState,
                    }
                end
            end
            if next(transformations) ~= nil then
                pH.kind = "pfPH"
                pH.soil = soil
                pH.transformations = transformations
                addTarget(session, pH)
            end
        end
    end
end

local function buildVanillaSession(session, desc)
    if FieldDensityMap == nil then return end
    if desc.resetsSpray ~= false and FieldDensityMap.SPRAY_LEVEL ~= nil then
        local spray = targetFromVanillaLayer(FieldDensityMap.SPRAY_LEVEL)
        if spray ~= nil then
            spray.kind = "vanillaSpray"
            addTarget(session, spray)
        end
    end
    if desc.consumesLime ~= false and FieldDensityMap.LIME_LEVEL ~= nil then
        local lime = targetFromVanillaLayer(FieldDensityMap.LIME_LEVEL)
        if lime ~= nil then
            lime.kind = "vanillaLime"
            addTarget(session, lime)
        end
    end
end

---Captures standing crop at every soil target's native resolution before disease destruction.
-- @param table manager RCR manager
-- @param table region Read region
-- @param table desc Fruit type being destroyed
-- @param integer farmlandId
-- @return table session, or nil
function RealisticCropRotationSoilUptake.prepare(manager, region, desc, farmlandId)
    if g_server == nil or region == nil or desc == nil
        or DensityCoordType == nil or DensityMapModifier == nil
        or DensityMapFilter == nil or DensityValueCompareType == nil then
        return nil
    end

    local minX, minZ, maxX, maxZ = RealisticCropRotationManager.regionWorldBounds(region)
    local cropFilters = getCropFilters(desc)
    if minX == nil or cropFilters == nil then return nil end

    local session = {
        manager = manager,
        farmlandId = tonumber(farmlandId),
        region = region,
        cropFilters = cropFilters,
        minX = minX,
        minZ = minZ,
        maxX = maxX,
        maxZ = maxZ,
        targets = {},
        contexts = {},
        snapshotPixels = {},
    }

    local pf = manager:getPrecisionFarming()
    if pf ~= nil then
        buildPFSession(session, pf, desc)
    else
        buildVanillaSession(session, desc)
    end
    if #session.targets == 0 then return nil end

    for key, context in pairs(session.contexts) do
        local pixels = snapshotContext(context, region, cropFilters, minX, minZ, maxX, maxZ)
        if pixels == nil then return nil end
        session.snapshotPixels[key] = pixels
    end
    return session
end

local function getWriter(target)
    local key = string.format("%d|%d|%d", target.mapId, target.firstChannel, target.numChannels)
    if writers[key] ~= nil then return writers[key] end
    local modifier = DensityMapModifier.new(
        target.mapId, target.firstChannel, target.numChannels, g_terrainNode)
    setInclusiveRounding(modifier)
    writers[key] = modifier
    return modifier
end

local function getSoilFilter(soil, soilTypeIndex)
    local rawValue = math.floor(soilTypeIndex) - 1
    local key = string.format("%d|%d|%d|%d",
        soil.mapId, soil.firstChannel, soil.numChannels, rawValue)
    if soilFilters[key] ~= nil then return soilFilters[key] end
    local filter = DensityMapFilter.new(soil.mapId, soil.firstChannel, soil.numChannels)
    if filter ~= nil then
        filter:setValueCompareParams(DensityValueCompareType.EQUAL, rawValue)
        soilFilters[key] = filter
    end
    return filter
end

local function getValueFilter(target, compareType, firstValue, secondValue)
    local key = string.format("%d|%d|%d|%s|%s|%s",
        target.mapId, target.firstChannel, target.numChannels,
        tostring(compareType), tostring(firstValue), tostring(secondValue))
    if valueFilters[key] ~= nil then return valueFilters[key] end
    local filter = DensityMapFilter.new(target.mapId, target.firstChannel, target.numChannels)
    if filter ~= nil then
        if secondValue == nil then
            filter:setValueCompareParams(compareType, firstValue)
        else
            filter:setValueCompareParams(compareType, firstValue, secondValue)
        end
        valueFilters[key] = filter
    end
    return filter
end

local function consumePFNitrogen(session, target)
    local writer = getWriter(target)
    if writer == nil then return false end
    setWorldArea(writer, session.minX, session.minZ, session.maxX, session.maxZ)

    local attempted = false
    for soilTypeIndex, reductionStates in pairs(target.reductionStates or {}) do
        local states = math.min(math.max(math.floor(tonumber(reductionStates) or 0), 0), target.maxValue)
        local soilFilter = getSoilFilter(target.soil, soilTypeIndex)
        if states > 0 and soilFilter ~= nil then
            if states > 1 then
                local lowFilter = getValueFilter(target, DensityValueCompareType.BETWEEN, 1, states - 1)
                if lowFilter ~= nil then
                    writer:executeSet(0, target.context.filter, soilFilter, lowFilter)
                end
            end
            local safeFilter = getValueFilter(target, DensityValueCompareType.BETWEEN, states, target.maxValue)
            if safeFilter ~= nil then
                writer:executeAdd(-states, target.context.filter, soilFilter, safeFilter)
            end
            attempted = true
        end
    end
    return attempted
end

local function consumePFPH(session, target)
    local writer = getWriter(target)
    if writer == nil then return false end
    setWorldArea(writer, session.minX, session.minZ, session.maxX, session.maxZ)

    local attempted = false
    for soilTypeIndex, transformation in pairs(target.transformations or {}) do
        local soilFilter = getSoilFilter(target.soil, soilTypeIndex)
        if soilFilter ~= nil and transformation.states > 0 then
            -- Keep the result inside the configured pH range.
            local lowLastState = math.min(
                transformation.maxState,
                transformation.minState + transformation.states - 1)
            if transformation.minState <= lowLastState then
                local lowFilter = getValueFilter(target, DensityValueCompareType.BETWEEN,
                    transformation.minState, lowLastState)
                if lowFilter ~= nil then
                    writer:executeSet(
                        transformation.minState, target.context.filter, soilFilter, lowFilter)
                    attempted = true
                end
            end

            local firstState = transformation.minState + transformation.states
            if firstState <= transformation.maxState then
                local valueFilter = getValueFilter(
                    target, DensityValueCompareType.BETWEEN, firstState, transformation.maxState)
                if valueFilter ~= nil then
                    writer:executeAdd(-transformation.states,
                        target.context.filter, soilFilter, valueFilter)
                    attempted = true
                end
            end
        end
    end
    return attempted
end

---Applies a vanilla soil-layer change where the captured crop disappeared.
-- @param table session
-- @param table target
-- @param integer change Zero clears the layer; a negative value is added
local function consumeVanillaLayer(session, target, change)
    local writer = getWriter(target)
    if writer == nil then return end
    setWorldArea(writer, session.minX, session.minZ, session.maxX, session.maxZ)
    local positiveFilter = getValueFilter(target, DensityValueCompareType.GREATER, 0, nil)
    if positiveFilter == nil then return end
    if change == 0 then
        writer:executeSet(0, target.context.filter, positiveFilter)
    else
        writer:executeAdd(change, target.context.filter, positiveFilter)
    end
end

local VANILLA_LAYER_CHANGE = {
    vanillaSpray = 0,
    vanillaLime = -1,
}

---Consumes nitrogen and lime only where the captured standing crop disappeared.
-- @param table session Session returned by prepare
function RealisticCropRotationSoilUptake.consume(session)
    if session == nil or session.region == nil or session.cropFilters == nil then return end
    if session.consumed then return end
    session.consumed = true

    local activeContexts = {}
    for key, context in pairs(session.contexts) do
        if not RealisticCropRotationManager.applyRegionToModifier(session.region, context.modifier) then return end
        local _, survivingPixels = context.modifier:executeSetWithStats(
            0, context.filter, session.cropFilters.present)
        local killedPixels = (tonumber(session.snapshotPixels[key]) or 0)
            - (tonumber(survivingPixels) or 0)
        if killedPixels > 0 then activeContexts[key] = true end
    end

    local pfNitrogenUpdated = false
    local pfPHUpdated = false
    for _, target in ipairs(session.targets) do
        if activeContexts[target.context.key] then
            if target.kind == "pfNitrogen" then
                pfNitrogenUpdated = consumePFNitrogen(session, target) or pfNitrogenUpdated
            elseif target.kind == "pfPH" then
                pfPHUpdated = consumePFPH(session, target) or pfPHUpdated
            else
                local vanillaChange = VANILLA_LAYER_CHANGE[target.kind]
                if vanillaChange ~= nil then
                    consumeVanillaLayer(session, target, vanillaChange)
                end
            end
        end
    end

    for _, target in ipairs(session.targets) do
        local shouldNotify = (target.kind == "pfNitrogen" and pfNitrogenUpdated)
            or (target.kind == "pfPH" and pfPHUpdated)
        if shouldNotify
            and target.valueMap ~= nil
            and type(target.valueMap.setMinimapRequiresUpdate) == "function" then
            target.valueMap:setMinimapRequiresUpdate(true)
        end
    end

end

function RealisticCropRotationSoilUptake.delete()
    if delete ~= nil then
        for _, context in pairs(maskContexts) do
            if context.mapId ~= nil then delete(context.mapId) end
        end
    end
    maskContexts = {}
    maskContextCount = 0
    writers = {}
    soilFilters = {}
    valueFilters = {}
    cropFilterCache = {}
    phStateCache = {}
    pfConfigCache = nil
    warned = {}
end
