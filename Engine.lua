local _, Addon = ...
local Engine = {}
Addon.Engine = Engine

local quests = {}
local empty = {}
local outdoorByLevel = {}
function Engine.UseCatalog()
    quests = Addon.quests or empty
    outdoorByLevel = {}
    for id, quest in pairs(quests) do
        if quest.map then
            local level = math.max(0, quest.level)
            local list = outdoorByLevel[level]
            if not list then
                list = {}
                outdoorByLevel[level] = list
            end
            list[#list + 1] = id
        end
    end
end
Engine.UseCatalog()

local function inMask(mask, id)
    return not mask or mask == 0 or (id and math.floor(mask / 2 ^ (id - 1)) % 2 == 1)
end

local function fitsCharacter(ctx, quest, entry)
    local side = entry and entry.side
    if side == "Alliance" or side == "Horde" then
        if side ~= ctx.faction then return false end
    elseif quest.side and quest.side ~= ctx.side then
        return false
    end
    return (not entry or not entry.class or entry.class == ctx.classToken)
        and inMask(quest.race, ctx.race)
        and inMask(quest.class, ctx.class)
end

local function hasQuest(ctx, id)
    return id and (ctx.active[id] or ctx.completed(id))
end

local function allRequirementDone(ctx, id)
    if ctx.completed(math.abs(id)) then return true end
    if id > 0 then
        for _, alternative in ipairs((quests[id] or empty).exclusive or empty) do
            if ctx.completed(alternative) then return true end
        end
    end
    return false
end

local function requirement(ctx, quest)
    if quest.parent and not ctx.active[quest.parent] then return quest.parent end
    if quest.starting and not hasQuest(ctx, quest.starting) then return quest.starting end
    for _, id in ipairs(quest.all or empty) do
        if not allRequirementDone(ctx, id) then return math.abs(id) end
    end
    if quest.any and quest.any[1] then
        for _, id in ipairs(quest.any) do
            if ctx.completed(id) then return nil end
        end
        -- Favor an alternative already in the log or available to this character.
        for _, id in ipairs(quest.any) do
            if ctx.active[id] then return id end
        end
        for _, id in ipairs(quest.any) do
            if quests[id] and fitsCharacter(ctx, quests[id]) then return id end
        end
        return quest.any[1]
    end
end

local function unavailable(ctx, quest)
    if quest.max and ctx.level > quest.max then return true end
    if quest.untilQuest and ctx.completed(quest.untilQuest) then return true end
    if quest.disabled and ctx.active[quest.disabled] then return true end
    if hasQuest(ctx, quest.next) or hasQuest(ctx, quest.breadcrumb) then return true end
    for _, id in ipairs(quest.exclusive or empty) do
        if hasQuest(ctx, id) then return true end
    end
    return false
end

function Engine.State(ctx, id, entry)
    local quest = quests[id] or empty
    if not fitsCharacter(ctx, quest, entry) then return "unavailable" end
    if ctx.completed(id) then return "complete" end
    local active = ctx.active[id]
    if active then return active.ready and "turnin" or "active" end
    local minimum = math.max(quest.min or 0, entry and entry.minimum or 0)
    if ctx.level < minimum then return "later", minimum end
    if unavailable(ctx, quest) then return "unavailable" end
    local missing = requirement(ctx, quest)
    if missing then return "locked", missing end
    if quest.restricted then return "check" end
    if entry and entry.inside then return "inside" end
    if quest.start or (entry and entry.pin) then return "pickup" end
    return "check"
end

function Engine.Prequest(ctx, id)
    local visited = {}
    while id and not visited[id] do
        visited[id] = true
        local quest = quests[id]
        local state, missing = Engine.State(ctx, id)
        if state ~= "locked" then
            if state == "turnin" then return id, quest and quest.finish, state end
            return id, quest and quest.start, state
        end
        id = missing
    end
end

local function bucketFor(buckets, map)
    if not buckets[map] then
        buckets[map] = { map = map, ready = 0, active = 0, turnin = 0, groups = 0, unlocks = 0,
            nearby = 0, hubs = {}, cluster = 0 }
    end
    return buckets[map]
end

local function addPickup(bucket, quest, ctx)
    bucket.ready = bucket.ready + 1
    local level = quest.level > 0 and quest.level or ctx.level
    bucket.minLevel = math.min(bucket.minLevel or level, level)
    bucket.maxLevel = math.max(bucket.maxLevel or level, level)
    if quest.enemyMin then
        bucket.enemyMin = math.min(bucket.enemyMin or quest.enemyMin, quest.enemyMin)
        bucket.enemyMax = math.max(bucket.enemyMax or quest.enemyMax, quest.enemyMax)
    end
    local pin = quest.start
    if pin and pin.map == bucket.map then
        local x, y = math.floor(pin.x / 10), math.floor(pin.y / 10)
        local key = x * 16 + y
        bucket.hubs[key] = (bucket.hubs[key] or 0) + 1
        bucket.cluster = math.max(bucket.cluster, bucket.hubs[key])
        if ctx.map == pin.map and ctx.x and (ctx.x - pin.x) ^ 2 + (ctx.y - pin.y) ^ 2 <= 225 then
            bucket.nearby = bucket.nearby + 1
        end
    end
end

function Engine.Outdoor(ctx, preferForever)
    local buckets = {}
    local localBucket = ctx.map and bucketFor(buckets, ctx.map)
    local currentLevel = ctx.level
    local minLevel, maxLevel = currentLevel - 5, currentLevel + 9
    local function inspect(id)
        local quest = quests[id]
        local level = quest.level > 0 and quest.level or currentLevel
        if ctx.isZone(quest.map) then
            local state, gate = Engine.State(ctx, id)
            local suitable = level <= currentLevel + 3 and (quest.enemyMax or level) <= currentLevel + 5
            if state == "turnin" then
                local map = quest.finish and quest.finish.map or quest.map
                local bucket = bucketFor(buckets, map)
                bucket.turnin = bucket.turnin + 1
            elseif state == "active" then
                local bucket = bucketFor(buckets, quest.map)
                if suitable and not quest.elite and level >= currentLevel - 6 then
                    bucket.active = bucket.active + 1
                else
                    bucket.groups = bucket.groups + 1
                end
            elseif state == "pickup" and suitable then
                local bucket = bucketFor(buckets, quest.map)
                if quest.elite then bucket.groups = bucket.groups + 1
                else addPickup(bucket, quest, ctx) end
            elseif (state == "later" or state == "pickup") and not suitable and quest.map == ctx.map then
                local at = math.max(quest.min, level - 3)
                if at > currentLevel then
                    localBucket.returnLevel = math.min(localBucket.returnLevel or at, at)
                end
            elseif state == "locked" and suitable and localBucket and quest.map ~= ctx.map then
                local prequest = quests[gate]
                if prequest and ctx.active[gate] and (prequest.map == ctx.map or (prequest.finish and prequest.finish.map == ctx.map)) then
                    local bucket = bucketFor(buckets, quest.map)
                    bucket.unlocks = bucket.unlocks + 1
                    if not bucket.unlockQuest or ctx.active[gate].ready then bucket.unlockQuest = gate end
                end
            end
        end
    end
    for _, id in ipairs(outdoorByLevel[0] or empty) do inspect(id) end
    for level = math.max(1, minLevel), maxLevel do
        for _, id in ipairs(outdoorByLevel[level] or empty) do inspect(id) end
    end
    for id in pairs(ctx.active) do
        local quest = quests[id]
        if quest and quest.map and quest.level > 0 and (quest.level < minLevel or quest.level > maxLevel) then
            inspect(id)
        end
    end

    local choices = {}
    for map, bucket in pairs(buckets) do
        if map ~= ctx.map and ctx.isZone(map) and (bucket.ready + bucket.active > 0 or bucket.unlocks > 0) then
            local travel = ctx.travelCost(map)
            local foreverBonus = preferForever and Addon.foreverMaps[map] and 2 or 0
            bucket.score = math.min(bucket.ready, 14) + bucket.active * 1.6 + math.min(bucket.cluster, 5) * 0.7
                + math.min(bucket.unlocks, 4) * 0.45 + foreverBonus - travel
            choices[#choices + 1] = bucket
        end
    end
    table.sort(choices, function(a, b)
        if a.score == b.score then return a.map < b.map end
        return a.score > b.score
    end)

    local here = localBucket or { ready = 0, active = 0, turnin = 0, nearby = 0, groups = 0 }
    local nextZone = choices[1]
    local localWork = here.ready + here.active
    local advice = "stay"
    if nextZone and localWork <= 2 and nextZone.ready + nextZone.active >= math.max(2, localWork + 2) then
        advice = (here.turnin > 0 or here.active > 0 or nextZone.unlockQuest) and "wrap" or "move"
    elseif nextZone and localWork == 0 and nextZone.unlockQuest then
        advice = "wrap"
    elseif localWork == 0 and here.turnin > 0 then
        advice = "wrap"
    elseif localWork == 0 then
        advice = nextZone and nextZone.ready + nextZone.active > 0 and "move" or "unsure"
    end
    return { advice = advice, current = here, choices = choices }
end

function Engine.Dungeons(ctx, skipped)
    local result = {}
    for _, dungeon in ipairs(Addon.dungeons) do
        local isSkipped = skipped[dungeon.name]
        local inRange = ctx.level >= dungeon.min - 3 and ctx.level <= dungeon.max + 1
        local distance = math.abs(ctx.level - dungeon.min)
        if isSkipped then
            result[#result + 1] = { dungeon = dungeon, skipped = true, distance = distance }
        else
            local inLog = false
            if not inRange then
                for _, entry in ipairs(dungeon.quests) do
                    if ctx.active[entry.id] then inLog = true break end
                end
            end
            if inRange or inLog then
                local groups, pending = {}, 0
                for _, entry in ipairs(dungeon.quests) do
                    local state, gate = Engine.State(ctx, entry.id, entry)
                    if state ~= "unavailable" then
                        groups[state] = groups[state] or {}
                        groups[state][#groups[state] + 1] = { entry = entry, gate = gate }
                        if state ~= "complete" and state ~= "later" then pending = pending + 1 end
                    end
                end
                if groups.active or groups.turnin or (inRange and pending > 0) then
                    result[#result + 1] = { dungeon = dungeon, groups = groups, distance = distance, inRange = inRange }
                end
            end
        end
    end
    table.sort(result, function(a, b)
        if a.distance == b.distance then return a.dungeon.name < b.dungeon.name end
        return a.distance < b.distance
    end)
    return result
end
