local _, Addon = ...

local FORMAT = 1
local EMPTY = {}
local CITY_MAPS = { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true }
local QUEST_FIELDS = { 1, 2, 3, 4, 5, 6, 7, 10, 12, 13, 16, 17, 18, 19, 20, 21, 22, 24, 25, 27, 30, 31, 32, 33, 34, 35, 36 }
local GATES = {
    [9] = "all", [10] = "any", [11] = "exclusive", [17] = "next", [19] = "parent",
    [20] = "breadcrumb", [23] = "max", [24] = "untilQuest", [25] = "starting", [27] = "disabled",
}
local RESTRICTIONS = { 13, 14, 15, 16, 21, 22, 26 }
local importRunning = false

local function version(addonName)
    return C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")
end

local function areaMaps(provider)
    local zoneDB = provider.Support and provider.Support.Get("ZoneDB")
    local private = zoneDB and zoneDB.private
    local result = {}
    if not private then return result end
    for _, field in ipairs({ "areaIdToUiMapId", "areaIdToUiMapIdOverride" }) do
        local data = private[field]
        if type(data) == "string" then
            -- The provider stores a Lua table literal. Read the numeric pairs as data.
            for area, map in data:gmatch("%[(%d+)%]%s*=%s*(%d+)") do
                result[tonumber(area)] = tonumber(map)
            end
        elseif type(data) == "table" then
            for area, map in pairs(data) do
                if type(area) == "number" and type(map) == "number" then result[area] = map end
            end
        end
    end
    return result
end

local function outdoorMap(map, foreverMaps)
    return map and (foreverMaps[map] or (map >= 1411 and map <= 1452 and map ~= 1414 and map ~= 1415))
end

local function hasRequirement(value)
    if type(value) == "table" then
        for _, field in pairs(value) do
            if field ~= 0 then return true end
        end
        return false
    end
    return value ~= nil and value ~= false and value ~= 0
end

local function dungeonIndex(journal)
    local dungeons, assigned = {}, {}
    for name, record in pairs(journal) do
        local low, high
        if type(record.level) == "string" then
            low, high = record.level:gsub("–", "-"):match("(%d+)%s*%-%s*(%d+)")
        end
        if low and type(record.quests) == "table" then
            local entries, seen = {}, {}
            for _, item in ipairs(record.quests) do
                local id = tonumber(item.id)
                if id and id > 0 and not seen[id] then
                    assigned[id], seen[id] = true, true
                    local pickup = (item.pickup or ""):lower()
                    local inside = item.startsInDungeon or pickup:find("inside", 1, true) ~= nil
                    local pin
                    local start = item.startMap
                    if type(start) == "table" and type(start.mapID) == "number"
                        and type(start.x) == "number" and type(start.y) == "number"
                        and start.x >= 0 and start.x <= 1 and start.y >= 0 and start.y <= 1 then
                        pin = { map = start.mapID, x = start.x * 100, y = start.y * 100, name = start.targetName }
                    end
                    entries[#entries + 1] = { id = id, name = item.name, side = item.faction, class = item.classOnly,
                        minimum = tonumber(item.requires) or 0, inside = inside or nil, pin = pin }
                end
            end
            if #entries > 0 then
                dungeons[#dungeons + 1] = { name = name, min = tonumber(low), max = tonumber(high), quests = entries }
            end
        end
    end
    table.sort(dungeons, function(a, b) return a.name < b.name end)
    return dungeons, assigned
end

local function coordinates(spawns, maps, foreverMaps)
    local results = {}
    for area, points in pairs(spawns or EMPTY) do
        local map = maps[area]
        if map and (outdoorMap(map, foreverMaps) or CITY_MAPS[map]) then
            for _, point in ipairs(points) do
                local x, y = point[1], point[2]
                if type(x) == "number" and type(y) == "number" and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
                    results[#results + 1] = { map = map, x = x, y = y }
                    break
                end
            end
        end
    end
    table.sort(results, function(a, b)
        if a.map ~= b.map then return a.map < b.map end
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)
    return results
end

local function chooseStarter(givers, preferred, npcs, objects)
    local picked, side, mixed
    for index = 1, 2 do
        local get = index == 1 and npcs or objects
        for _, id in ipairs((givers and givers[index]) or EMPTY) do
            local source = get(id)
            for _, point in ipairs(source.points) do
                if picked and side ~= source.side then mixed = true end
                if not picked or (point.map == preferred and picked.map ~= preferred) then
                    picked = { map = point.map, x = point.x, y = point.y, name = source.name }
                    side = source.side
                end
            end
        end
    end
    return picked, not mixed and side or nil
end

local function importCatalog(provider, journal)
    local maps = areaMaps(provider)
    if not next(maps) then error("QuestieDB did not expose its Forever map data.") end
    local foreverMaps = {}
    for _, area in ipairs({ 16591, 16593 }) do
        if maps[area] then foreverMaps[maps[area]] = true end
    end
    local dungeons, assigned = dungeonIndex(journal)
    local quests, npcCache, objectCache = {}, {}, {}
    local function npc(id)
        if not npcCache[id] then
            local fields = provider.Npc.GetAll(id, { 1, 4, 5, 6, 7, 13 }) or EMPTY
            npcCache[id] = { name = fields[1], min = fields[2], max = fields[3], rank = fields[4],
                points = coordinates(fields[5], maps, foreverMaps), side = fields[6] }
        end
        return npcCache[id]
    end
    local function object(id)
        if not objectCache[id] then
            local fields = provider.Object.GetAll(id, { 1, 4 }) or EMPTY
            objectCache[id] = { name = fields[1], points = coordinates(fields[2], maps, foreverMaps) }
        end
        return objectCache[id]
    end

    local outdoorCount = 0
    local clock = debugprofilestop
    local batchStart = clock and clock()
    for index, id in ipairs(provider.Quest.GetAllIds()) do
        local row = provider.Quest.GetAll(id, QUEST_FIELDS)
        local name, minimum, level = row and row[1], row and row[4] or 0, row and row[5]
        if name and level and level >= -1 and level <= 65 and minimum <= 60 then
            local area = row[12] or 0
            local map = maps[area]
            local start, side = chooseStarter(row[2], map, npc, object)
            local finish = chooseStarter(row[3], map, npc, object)
            if (not map or map == 0) and area >= 0 and start then map = start.map end
            local quest = { name = name, level = level, min = minimum, race = row[6], class = row[7],
                start = start, finish = finish }
            if side == "A" or side == "H" then quest.side = side end
            for field, key in pairs(GATES) do
                if hasRequirement(row[field]) then quest[key] = row[field] end
            end
            for _, field in ipairs(RESTRICTIONS) do
                if hasRequirement(row[field]) then quest.restricted = true break end
            end
            local repeatable = (row[18] or 0) % 2 == 1
            if outdoorMap(map, foreverMaps) and not assigned[id] and start and not repeatable then
                quest.map = map
                outdoorCount = outdoorCount + 1
                for _, objective in ipairs((row[8] and row[8][1]) or EMPTY) do
                    if objective[1] then
                        local enemy = npc(objective[1])
                        if enemy.min and enemy.max and enemy.min > 0 and enemy.max > 0 then
                            quest.enemyMin = math.min(quest.enemyMin or enemy.min, enemy.min)
                            quest.enemyMax = math.max(quest.enemyMax or enemy.max, enemy.max)
                        end
                        if enemy.rank and enemy.rank >= 1 and enemy.rank <= 3 then quest.elite = true end
                    end
                end
            end
            quests[id] = quest
        end
        if index % 45 == 0 or (batchStart and index % 5 == 0 and clock() - batchStart >= 2.5) then
            coroutine.yield()
            batchStart = clock and clock()
        end
    end

    if outdoorCount < 50 or #dungeons < 3 then error("The source addons returned an incomplete catalog.") end
    return { format = FORMAT, quests = quests, dungeons = dungeons, foreverMaps = foreverMaps,
        questieVersion = version("QuestieDB"), journalVersion = version("ForeverDungeonJournal") }
end

local function activate(snapshot)
    Addon.quests, Addon.dungeons, Addon.foreverMaps = snapshot.quests, snapshot.dungeons, snapshot.foreverMaps
    Addon.Engine.UseCatalog()
end

function Addon.EnsureLocalCatalog(rebuild, inform, openPanel)
    if importRunning then inform("The local quest catalog is still building.") return end
    local saved = LevelZonesCatalogDB
    if not rebuild and type(saved) == "table" and saved.format == FORMAT
        and type(saved.quests) == "table" and next(saved.quests)
        and type(saved.dungeons) == "table" and #saved.dungeons >= 3 and type(saved.foreverMaps) == "table" then
        if Addon.quests ~= saved.quests then activate(saved) end
        openPanel()
        return
    end
    local provider = LibQuestieDB
    local journal = ForeverDungeonJournal_NS and ForeverDungeonJournal_NS.DB
    if not provider or not provider.Quest or not provider.Quest.GetAll or not provider.Quest.GetAllIds
        or not provider.Npc or not provider.Object or type(journal) ~= "table" then
        inform("For the first catalog build, enable QuestieDB and DungeonJournal for WoW Forever, then log in again.")
        return
    end
    inform("Building the quest catalog from your local addons…")
    importRunning = true
    local task = coroutine.create(function() return importCatalog(provider, journal) end)
    local function step()
        local ok, snapshot = coroutine.resume(task)
        if not ok then
            importRunning = false
            inform("Catalog build failed: " .. tostring(snapshot))
        elseif coroutine.status(task) == "dead" then
            importRunning = false
            LevelZonesCatalogDB = snapshot
            activate(snapshot)
            inform("Catalog ready. WoW saves it when you log out, then you can disable the source addons.")
            openPanel()
        else
            C_Timer.After(0, step)
        end
    end
    step()
end
