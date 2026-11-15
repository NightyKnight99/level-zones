local _, Addon = ...
local Engine = Addon.Engine
local player = "player"
local turnedIn = {}
local openedDungeons = {}
local mapInfo = {}
local frame
local refresh
local showSettings
local minimapButton
local updatePending
local worldUpdatePending
local snapshot
local stableChoice
local startupRequested = false
local zoneExpanded = false
local rows = {}
local rowCount, paperCount, useInk, pendingGap, zoneEnd
local layoutWidth, contentHeight
local paperStrips = {}
local MIN_SCALE, MAX_SCALE = .7, 1.5
local DEFAULT_WIDTH, MIN_WIDTH, MIN_HEIGHT = 392, 300, 115
local SCROLL_TOP, SCROLL_BOTTOM = 41, 20

local function settings()
    if type(LevelZonesDB) ~= "table" then LevelZonesDB = {} end
    if type(LevelZonesDB.skipped) ~= "table" then LevelZonesDB.skipped = {} end
    return LevelZonesDB
end

local function panelScale()
    local value = tonumber(settings().scale) or 1
    return math.max(MIN_SCALE, math.min(MAX_SCALE, value))
end

local function resizeBounds()
    local scale = panelScale()
    return math.max(MIN_WIDTH, math.min(900, (UIParent:GetWidth() - 30) / scale)),
        math.max(MIN_HEIGHT, math.min(850, UIParent:GetHeight() * .9 / scale))
end

local function applyPanelSize()
    local db = settings()
    local maxWidth, maxHeight = resizeBounds()
    local width = math.max(MIN_WIDTH, math.min(maxWidth, tonumber(db.width) or DEFAULT_WIDTH))
    if frame.SetResizeBounds then
        frame:SetResizeBounds(width, MIN_HEIGHT, width, maxHeight)
    else
        frame:SetMinResize(width, MIN_HEIGHT)
        frame:SetMaxResize(width, maxHeight)
    end
    frame:SetWidth(width)
    if db.height then
        frame:SetHeight(math.max(MIN_HEIGHT, math.min(maxHeight, tonumber(db.height) or MIN_HEIGHT)))
    end
end

local function anchorAtTop(x, top)
    frame:ClearAllPoints()
    frame:SetPoint("TOP", UIParent, "BOTTOMLEFT", x, top)
end

local function rememberPosition()
    local x, top = frame:GetCenter(), frame:GetTop()
    if not x or not top then return end
    local db = settings()
    db.x, db.top, db.y = x, top, nil
    anchorAtTop(x, top)
end

local function hidePanel()
    settings().hidden = true
    if frame then frame:Hide() end
    if _G.LevelZonesSettings then _G.LevelZonesSettings:Hide() end
    snapshot = nil
    turnedIn = {}
    for _, row in ipairs(rows) do
        row.button:SetScript("OnClick", nil)
        if row.check then row.check:SetScript("OnClick", nil) end
    end
end

local function info(map)
    if not map then return nil end
    if not mapInfo[map] then mapInfo[map] = C_Map.GetMapInfo(map) end
    return mapInfo[map]
end

local function mapName(map)
    local entry = info(map)
    return entry and entry.name or "Unknown area"
end

local function isZone(map)
    local entry = info(map)
    return entry and entry.mapType == Enum.UIMapType.Zone
end

local function continent(map)
    local entry = info(map)
    for _ = 1, 8 do
        if not entry then return nil end
        if entry.mapType == Enum.UIMapType.Continent then return entry.mapID end
        entry = info(entry.parentMapID)
    end
end

local function currentZone()
    local map = C_Map.GetBestMapForUnit(player)
    for _ = 1, 8 do
        if not map or isZone(map) then return map end
        local entry = info(map)
        if not entry or entry.mapType == Enum.UIMapType.Continent then return nil end
        map = entry.parentMapID
    end
end

local function questLog()
    local active = {}
    for index = 1, C_QuestLog.GetNumQuestLogEntries() do
        local entry = C_QuestLog.GetInfo(index)
        if entry and not entry.isHeader and entry.questID then
            local ready = false
            if C_QuestLog.IsComplete then ready = C_QuestLog.IsComplete(entry.questID) end
            local quest = { ready = ready == true or ready == 1, title = entry.title }
            local catalog = Addon.quests[entry.questID]
            if not quest.ready and catalog and catalog.objectives and C_QuestLog.GetQuestObjectives then
                for _, objective in ipairs(C_QuestLog.GetQuestObjectives(entry.questID) or {}) do
                    if not objective.finished and objective.type and objective.type ~= "log" then
                        quest.objectives = quest.objectives or {}
                        local text = (objective.text or ""):gsub("[:%s]*%d+%s*/%s*%d+%s*$", "")
                        quest.objectives[#quest.objectives + 1] = { kind = objective.type, text = text }
                    end
                end
            end
            active[entry.questID] = quest
        end
    end
    return active
end

local noObjectives = {}
local function sameQuestLog(previous, current)
    for id, quest in pairs(previous) do
        local other = current[id]
        if not other or quest.ready ~= other.ready or quest.title ~= other.title then return false end
        local before, after = quest.objectives or noObjectives, other.objectives or noObjectives
        if #before ~= #after then return false end
        for index, objective in ipairs(before) do
            if objective.kind ~= after[index].kind or objective.text ~= after[index].text then return false end
        end
    end
    for id in pairs(current) do
        if not previous[id] then return false end
    end
    return true
end

local function context(active)
    local map = currentZone()
    local _, classToken, class = UnitClass(player)
    local _, _, race = UnitRace(player)
    local faction = UnitFactionGroup(player)
    local continentID = continent(map)
    local position = map and C_Map.GetPlayerMapPosition(map, player)
    local worldMap, origin, midpoint
    if position and continentID and C_Map.GetWorldPosFromMapPos and CreateVector2D then
        worldMap, origin = C_Map.GetWorldPosFromMapPos(map, position)
        midpoint = CreateVector2D(.5, .5)
    end
    local cache = {}
    local now = GetTime()
    for id, deadline in pairs(turnedIn) do
        if deadline < now or C_QuestLog.IsQuestFlaggedCompleted(id) then turnedIn[id] = nil end
    end
    local ctx = {
        level = UnitLevel(player), map = map, faction = faction,
        side = faction == "Alliance" and "A" or faction == "Horde" and "H" or nil,
        class = class, classToken = classToken, race = race, active = active or questLog(), isZone = isZone,
    }
    if position then ctx.x, ctx.y = position.x * 100, position.y * 100 end
    function ctx.completed(id)
        if turnedIn[id] then return true end
        if cache[id] == nil then cache[id] = C_QuestLog.IsQuestFlaggedCompleted(id) == true end
        return cache[id]
    end
    function ctx.travelCost(destination)
        if not continentID then return 0 end
        if continent(destination) ~= continentID then return 5 end
        if origin then
            local targetMap, target = C_Map.GetWorldPosFromMapPos(destination, midpoint)
            if target and worldMap == targetMap then
                local distance = math.sqrt((origin.x - target.x) ^ 2 + (origin.y - target.y) ^ 2)
                return math.min(5, distance / 2600)
            end
        end
        return 1
    end
    return ctx
end

local function nameOf(id, fallback)
    local title = snapshot.titles[id]
    if not title then
        local active = snapshot.ctx.active[id]
        title = active and active.title or (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id))
        if not title or title == "" then title = fallback or (Addon.quests[id] or {}).name or ("Quest " .. id) end
        snapshot.titles[id] = title
    end
    return title
end

local function message(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd36aLevel Zones:|r " .. text)
end

local function pinDescription(pin)
    if not pin then return nil end
    return string.format("%s%s (%.1f, %.1f)", pin.name and (pin.name .. ", ") or "",
        mapName(pin.map), pin.x, pin.y)
end

local function viewZone(map)
    if InCombatLockdown() then
        message("Open " .. mapName(map) .. " after combat.")
    elseif WorldMapFrame and WorldMapFrame.SetMapID then
        WorldMapFrame:Show()
        WorldMapFrame:SetMapID(map)
    end
end

local function showPin(pin)
    if InCombatLockdown() then
        message(pinDescription(pin))
        return
    end
    local placed = false
    if C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates
        and (not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(pin.map)) then
        local point = UiMapPoint.CreateFromCoordinates(pin.map, pin.x / 100, pin.y / 100)
        placed = pcall(C_Map.SetUserWaypoint, point)
        if placed and C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
            pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
        end
    end
    if WorldMapFrame and WorldMapFrame.SetMapID then
        WorldMapFrame:Show()
        WorldMapFrame:SetMapID(pin.map)
    end
    message((placed and "Waypoint: " or "") .. pinDescription(pin))
end

local colors = {
    gold = {1, .83, .39}, normal = {.97, .91, .79}, muted = {.78, .73, .65},
    green = {.63, .86, .46},
}
local ink = {
    gold = {.31, .13, .06}, normal = {.16, .09, .04}, muted = {.26, .17, .09},
    green = {.11, .25, .07},
}

local function paper(first)
    paperCount = paperCount + 1
    local texture = paperStrips[paperCount]
    if not texture then
        texture = frame.body:CreateTexture(nil, "BACKGROUND")
        if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("QuestDetailsBackgrounds") then
            texture:SetAtlas("QuestDetailsBackgrounds")
        else
            texture:SetColorTexture(.87, .67, .42, 1)
        end
        paperStrips[paperCount] = texture
    end
    texture.firstRow, texture.lastRow = first, rowCount
    texture:Show()
end

local function newRow()
    local row = CreateFrame("Frame", nil, frame.body)
    row:SetFrameLevel(frame.body:GetFrameLevel() + 1)
    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.label:SetPoint("TOPLEFT", 4, -3)
    row.label:SetJustifyH("LEFT")
    row.label:SetJustifyV("TOP")
    row.label:SetWordWrap(true)
    row.button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.button:SetSize(101, 22)
    row.button:SetPoint("TOPRIGHT", -3, -1)
    return row
end

local function line(text, style, buttonText, callback, indent, checked)
    rowCount = rowCount + 1
    local row = rows[rowCount]
    if not row then
        row = newRow()
        rows[rowCount] = row
    end
    local offset = indent or 4
    row.gap, pendingGap = pendingGap, 0
    if row.indent ~= offset then
        row.indent = offset
        row.label:ClearAllPoints()
        row.label:SetPoint("TOPLEFT", row, "TOPLEFT", offset, -3)
    end
    local font = style == "zoneTitle" and GameFontNormalLarge or GameFontHighlight
    if font and row.font ~= font then
        row.label:SetFontObject(font)
        row.font, row.measure = font, true
    end
    local color = (useInk and ink or colors)[style == "zoneTitle" and "gold" or style or "normal"]
    if row.color ~= color then
        row.color = color
        row.label:SetTextColor(unpack(color))
        row.label:SetShadowColor(0, 0, 0, useInk and 0 or 1)
    end
    if row.text ~= text then
        row.text, row.measure = text, true
        row.label:SetText(text)
    end
    if buttonText then
        if row.buttonText ~= buttonText then row.button:SetText(buttonText) end
        row.button:SetScript("OnClick", callback)
        row.button:Show()
    else
        row.button:SetScript("OnClick", nil)
        row.button:Hide()
    end
    row.buttonText = buttonText
    if checked ~= nil then
        if not row.check then
            row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.check:SetSize(24, 24)
            row.check:SetPoint("TOPRIGHT", -5, 0)
        end
        row.check:SetChecked(checked)
        row.check:SetScript("OnClick", callback)
        row.check:Show()
    elseif row.check then
        row.check:SetScript("OnClick", nil)
        row.check:Hide()
    end
    local controlWidth = buttonText and 110 or (checked ~= nil and 34 or 0)
    if row.controlWidth ~= controlWidth then row.measure = true end
    row.controlWidth = controlWidth
    row:Show()
end

local function questCount(count)
    return string.format("%d %s", count, count == 1 and "quest" or "quests")
end

local function reflow(contentChanged)
    if not frame or not frame:IsShown() or not rowCount then return end
    local width = frame:GetWidth() - 38
    local widthChanged = width ~= layoutWidth
    if contentChanged or widthChanged then
        layoutWidth = width
        if widthChanged then frame.body:SetWidth(width) end
        local y = 1
        for index = 1, rowCount do
            local row = rows[index]
            y = y + row.gap
            if row:GetWidth() ~= width then row:SetWidth(width) end
            if row.y ~= y then
                row.y = y
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 0, -y)
            end
            local labelWidth = math.max(55, width - row.indent - math.max(6, row.controlWidth))
            if row.labelWidth ~= labelWidth then
                row.labelWidth, row.measure = labelWidth, true
                row.label:SetWidth(labelWidth)
            end
            if row.measure then
                row.height = math.max(row.controlWidth > 0 and 24 or 18, math.ceil(row.label:GetStringHeight()) + 7)
                row:SetHeight(row.height)
                row.measure = nil
            end
            y = y + row.height
            if index == zoneEnd then
                local height = y + 3
                frame.zoneBorder:SetSize(width, height)
                frame.zoneFill:SetSize(width - 2, height - 2)
                y = y + 8
            end
        end
        for index = 1, paperCount do
            local texture = paperStrips[index]
            local first, last = rows[texture.firstRow], rows[texture.lastRow]
            texture:ClearAllPoints()
            texture:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 0, -first.y)
            texture:SetSize(width, last.y + last.height - first.y)
        end
        contentHeight = y
        frame.body:SetHeight(math.max(1, contentHeight))
    end
    if not frame.resizeStart and not settings().height then
        local _, resizeMaxHeight = resizeBounds()
        local maxHeight = math.min(resizeMaxHeight, math.max(160, math.min(600, UIParent:GetHeight() * .7 / panelScale())))
        local height = math.max(MIN_HEIGHT, math.min(maxHeight, contentHeight + SCROLL_TOP + SCROLL_BOTTOM))
        if frame:GetHeight() ~= height then frame:SetHeight(height) end
    end
    local current = frame.scroll:GetVerticalScroll()
    local maxScroll = math.max(0, contentHeight - frame.scroll:GetHeight())
    if current > maxScroll then frame.scroll:SetVerticalScroll(maxScroll) end
end

local function zoneWork(bucket)
    local parts = {}
    if bucket.objectives > 0 then
        parts[#parts + 1] = bucket.objectives .. (bucket.objectives == 1 and " objective left" or " objectives left")
    elseif bucket.active > 0 then
        parts[#parts + 1] = bucket.active .. " in your log"
    end
    if bucket.ready > 0 then parts[#parts + 1] = bucket.ready .. " to pick up" end
    if bucket.turnin > 0 then parts[#parts + 1] = bucket.turnin .. " to turn in" end
    if #parts == 0 and bucket.unlocks and bucket.unlocks > 0 then
        return questCount(bucket.unlocks) .. " behind a prequest"
    end
    return table.concat(parts, " · ")
end

local function outdoorRows(ctx, result)
    local here, nextZone = result.current, result.choices[1]
    local db = settings()
    local zone = ctx.map and mapName(ctx.map) or (GetRealZoneText() or "Your area")
    local moving = result.advice == "move"
    local unsure = result.advice == "unsure"
    local action = moving and "Head there now" or (result.advice == "wrap" and "Wrap up here" or "Stay here")
    pendingGap = 5
    line("Best zone right now", "muted", zoneExpanded and "Less" or "Details", function()
        zoneExpanded = not zoneExpanded
        refresh()
    end, 11)
    line(unsure and "No clear pick" or (moving and mapName(nextZone.map) or zone), "zoneTitle", nil, nil, 11)
    if not unsure then
        local work = zoneWork(moving and nextZone or here)
        line(action .. (work ~= "" and (" · " .. work) or ""), "normal", nil, nil, 11)
    end
    if nextZone and not moving and not unsure then
        line("After that: " .. mapName(nextZone.map), "muted", nil, nil, 11)
    end
    if nextZone and nextZone.unlockQuest and (result.advice == "wrap" or zoneExpanded) then
        line(nameOf(nextZone.unlockQuest) .. " can open " .. questCount(nextZone.unlocks) ..
            " in " .. mapName(nextZone.map) .. ".", "muted", nil, nil, 11)
    end
    zoneEnd = rowCount
    if not zoneExpanded then return end
    local first = rowCount + 1
    useInk = true
    if nextZone then
        line((moving and "Why this zone?" or "Up next") .. "\n" .. mapName(nextZone.map), "gold", "View Zone",
            function() viewZone(nextZone.map) end)
        local work = zoneWork(nextZone)
        local canSkip = not db.skippedZone
        line(work, "normal", canSkip and "Skip for now", canSkip and function()
            db.skippedZone, db.skippedZoneLevel = nextZone.map, ctx.level
            stableChoice, snapshot.outdoor = nil, nil
            refresh()
        end)
    end
    if db.skippedZone then
        line(mapName(db.skippedZone) .. " skipped until Lv " .. (ctx.level + 1), "muted", "Undo", function()
            db.skippedZone, db.skippedZoneLevel = nil, nil
            stableChoice, snapshot.outdoor = nil, nil
            refresh()
        end)
    end
    if here.nearby > 0 then line(questCount(here.nearby) .. " start near you.", "muted") end
    if here.enemyMin and here.enemyMax then
        line(string.format("Quest enemies here: levels %d–%d", here.enemyMin, here.enemyMax), "muted")
    end
    if here.groups > 0 then line(here.groups .. " tougher or group quests nearby.", "muted") end
    if here.returnLevel then line("Check this zone again around level " .. here.returnLevel .. ".", "muted") end
    for index = 2, math.min(3, #result.choices) do
        local candidate = result.choices[index]
        local levels = candidate.minLevel and string.format(" · Lv %d–%d", candidate.minLevel, candidate.maxLevel) or ""
        line(mapName(candidate.map) .. levels .. "\n" .. zoneWork(candidate) ..
            " · " .. Engine.ZoneAlternativeReason(nextZone, candidate), "normal")
    end
    if result.upcoming then
        line(mapName(result.upcoming.map) .. " · Quests around Lv " .. result.upcoming.futureLevel, "muted")
    end
    local prefersForever = not not db.preferForever
    local priorityText = prefersForever and "New Forever zone priority: ACTIVE" or "New Forever zone priority: OFF"
    line(priorityText, "normal", nil, function(check)
        db.preferForever = check:GetChecked()
        stableChoice, snapshot.outdoor = nil, nil
        refresh()
    end, nil, prefersForever)
    line("Panel size", "muted", "Adjust", showSettings)
    useInk = false
    paper(first)
end

local groupList = {
    {"turnin", "Ready to turn in"}, {"pickup", "Ready to pick up"}, {"locked", "Prerequisites"},
    {"inside", "Starts inside"}, {"active", "In your log"}, {"later", "Higher level"},
    {"check", "Check requirements"}, {"complete", "Completed"},
}

local function groupCount(groups, name)
    return groups[name] and #groups[name] or 0
end

local function dungeonSummary(result, ctx)
    local groups = result.groups
    local active, pickup, turnin = groupCount(groups, "active"), groupCount(groups, "pickup"), groupCount(groups, "turnin")
    local inside, locked, check = groupCount(groups, "inside"), groupCount(groups, "locked"), groupCount(groups, "check")
    local nearby = 0
    for _, item in ipairs(groups.pickup or {}) do
        local entry = item.entry
        local pin = entry.pin or (Addon.quests[entry.id] or {}).start
        if pin and pin.map == ctx.map and ctx.x and (ctx.x - pin.x) ^ 2 + (ctx.y - pin.y) ^ 2 <= 225 then
            nearby = nearby + 1
        end
    end
    local parts = {}
    if ctx.level < result.dungeon.min then
        parts[#parts + 1] = "Better at Lv " .. result.dungeon.min
    elseif not result.lower and turnin + pickup + locked + check == 0 and active + inside > 0 then
        parts[#parts + 1] = "Ready to run"
    end
    if turnin > 0 then parts[#parts + 1] = turnin .. " to turn in" end
    if active > 0 then parts[#parts + 1] = active .. " in your log" end
    if pickup > 0 then
        parts[#parts + 1] = pickup .. " to pick up" .. (nearby > 0 and (" (" .. nearby .. " nearby)") or "")
    end
    if locked > 0 then parts[#parts + 1] = locked .. " locked" end
    if inside > 0 then parts[#parts + 1] = inside .. (inside == 1 and " starts inside" or " start inside") end
    if check > 0 then parts[#parts + 1] = check .. " to check" end
    if #parts > 0 then return table.concat(parts, " · ") end
    if groups.later then return #groups.later .. " higher-level" end
    return "Listed quests completed"
end

local function questRow(ctx, item, state)
    local entry = item.entry
    local id = entry.id
    local quest = Addon.quests[id] or {}
    local title = nameOf(id, entry.name)
    local pin = nil
    local detail = nil
    if state == "pickup" then
        pin = entry.pin or quest.start
        detail = pinDescription(pin)
    elseif state == "turnin" then
        pin = quest.finish
        detail = pinDescription(pin)
    elseif state == "locked" then
        local prequest, location, preState = Engine.Prequest(ctx, item.gate)
        if prequest then
            pin = location
            local verb = preState == "turnin" and "Turn in " or (preState == "active" and "Finish " or "Start with ")
            if preState == "later" then verb = "Later: " end
            detail = verb .. nameOf(prequest) .. (pin and (" · " .. pinDescription(pin)) or "")
        else
            detail = "Requires " .. nameOf(item.gate)
        end
    elseif state == "inside" then
        detail = "Pick this up during the run."
    elseif state == "later" then
        detail = "Requires level " .. item.gate .. "."
    elseif state == "check" then
        detail = "The catalog does not confirm this pickup."
    end
    local onClick
    if pin then onClick = function() showPin(pin) end end
    line(title .. (detail and ("\n" .. detail) or ""), state == "complete" and "green" or "normal",
        onClick and "Show on map", onClick, 13)
end

local function dungeonRows(ctx, results)
    pendingGap = 6
    local db = settings()
    line("Dungeons", "gold", db.dungeonsHidden and "Show all" or "Hide all", function()
        db.dungeonsHidden = not db.dungeonsHidden
        refresh()
    end)
    if not results then return end
    line("Lower-level dungeons", "muted", db.showLowerDungeons and "Hide lower" or "Show lower", function()
        db.showLowerDungeons = not db.showLowerDungeons
        snapshot.dungeons = nil
        refresh()
    end)
    for _, result in ipairs(results) do
        local name = result.dungeon.name
        if result.skipped then
            line(name .. " · skipped", "muted", "Restore", function()
                settings().skipped[name] = nil
                snapshot.dungeons = nil
                refresh()
            end)
        else
            local opened = openedDungeons[name]
            local range = string.format(" · Lv %d–%d", result.dungeon.min, result.dungeon.max)
            line(name .. range .. "\n" .. dungeonSummary(result, ctx), "normal", opened and "Collapse" or "Quests", function()
                openedDungeons[name] = not openedDungeons[name]
                refresh()
            end)
            if opened then
                local first = rowCount + 1
                useInk = true
                for _, category in ipairs(groupList) do
                    local group = result.groups[category[1]]
                    if group then
                        line(category[2], "gold", nil, nil, 9)
                        for _, item in ipairs(group) do questRow(ctx, item, category[1]) end
                    end
                end
                line("Hide this dungeon from recommendations.", "muted", "Skip dungeon", function()
                    settings().skipped[name] = true
                    snapshot.dungeons = nil
                    refresh()
                end, 9)
                useInk = false
                paper(first)
            end
        end
    end
end

refresh = function(requery, active)
    if not frame or not frame:IsShown() then return end
    if requery or not snapshot then
        local inInstance, kind = IsInInstance()
        snapshot = { ctx = context(active), titles = {}, inDungeon = inInstance and (kind == "party" or kind == "raid") }
    end
    local ctx = snapshot.ctx
    local db = settings()
    if db.skippedZoneLevel ~= ctx.level then db.skippedZone, db.skippedZoneLevel = nil, nil end
    local faction = ctx.faction or "Horde"
    frame.crest:SetTexture("Interface\\TargetingFrame\\UI-PVP-" .. faction)
    if faction == "Alliance" then
        frame.headerColor:SetColorTexture(.11, .20, .32, 1)
        frame.zoneBorder:SetColorTexture(.30, .42, .57, 1)
        frame.zoneFill:SetColorTexture(.13, .19, .26, 1)
    else
        frame.headerColor:SetColorTexture(.29, .13, .10, 1)
        frame.zoneBorder:SetColorTexture(.48, .33, .18, 1)
        frame.zoneFill:SetColorTexture(.24, .17, .11, 1)
    end
    frame.location:SetText(string.format("%s  ·  Lv %d", ctx.map and mapName(ctx.map) or (GetRealZoneText() or ""), ctx.level))
    local previousRows, previousPaper = rowCount or 0, paperCount or 0
    rowCount, paperCount, pendingGap, useInk = 0, 0, 0, false
    if snapshot.inDungeon then
        pendingGap = 5
        line("In a dungeon", "gold", nil, nil, 11)
        line("Outdoor suggestions resume when you leave.", "muted", nil, nil, 11)
        zoneEnd = rowCount
    else
        if not snapshot.outdoor then
            local previousMap = stableChoice and stableChoice.level == ctx.level and stableChoice.map == ctx.map
                and stableChoice.destination
            snapshot.outdoor = Engine.Outdoor(ctx, db.preferForever, db.skippedZone, previousMap)
            local choice = snapshot.outdoor.choices[1]
            stableChoice = choice and { level = ctx.level, map = ctx.map, destination = choice.map }
        end
        outdoorRows(ctx, snapshot.outdoor)
    end
    local dungeons
    if not db.dungeonsHidden then
        if not snapshot.dungeons then snapshot.dungeons = Engine.Dungeons(ctx, db.skipped, db.showLowerDungeons) end
        dungeons = snapshot.dungeons
    end
    dungeonRows(ctx, dungeons)
    for index = rowCount + 1, previousRows do
        local row = rows[index]
        row.button:SetScript("OnClick", nil)
        if row.check then row.check:SetScript("OnClick", nil) end
        row:Hide()
    end
    for index = paperCount + 1, previousPaper do paperStrips[index]:Hide() end
    reflow(true)
end

local function createWindow()
    frame = CreateFrame("Frame", "LevelZonesWindow", UIParent, "BackdropTemplate")
    frame:SetSize(DEFAULT_WIDTH, 180)
    frame:SetScale(panelScale())
    frame:SetPoint("TOPRIGHT", UIParent, "RIGHT", -54, 120)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    applyPanelSize()
    frame:EnableMouse(true)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 22, insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    frame:SetBackdropColor(.15, .125, .10, .99)
    frame:SetBackdropBorderColor(.82, .72, .53)

    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT", 8, -8)
    header:SetPoint("TOPRIGHT", -8, -8)
    header:SetHeight(31)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() frame:StartMoving() end)
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        rememberPosition()
    end)
    frame.headerColor = header:CreateTexture(nil, "BACKGROUND")
    frame.headerColor:SetAllPoints()
    frame.crest = header:CreateTexture(nil, "ARTWORK")
    frame.crest:SetSize(23, 23)
    frame.crest:SetPoint("LEFT", 5, 0)
    local title = header:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("LEFT", frame.crest, "RIGHT", 4, 0)
    title:SetText("Level Zones")
    local close = CreateFrame("Button", nil, header, "UIPanelCloseButton")
    close:SetPoint("RIGHT", 3, 0)
    close:SetScript("OnClick", hidePanel)
    frame.location = header:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    frame.location:SetPoint("RIGHT", close, "LEFT", -4, 0)
    frame.location:SetPoint("LEFT", title, "RIGHT", 5, 0)
    frame.location:SetJustifyH("RIGHT")
    frame.location:SetWordWrap(false)

    frame.scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", 9, -SCROLL_TOP)
    frame.scroll:SetPoint("BOTTOMRIGHT", -27, SCROLL_BOTTOM)
    frame.body = CreateFrame("Frame", nil, frame.scroll)
    frame.body:SetSize(354, 1)
    frame.zoneBorder = frame.body:CreateTexture(nil, "BACKGROUND", nil, 0)
    frame.zoneFill = frame.body:CreateTexture(nil, "BACKGROUND", nil, 1)
    frame.zoneBorder:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 0, -1)
    frame.zoneFill:SetPoint("TOPLEFT", frame.zoneBorder, "TOPLEFT", 1, -1)
    frame.scroll:SetScrollChild(frame.body)

    local grip = CreateFrame("Button", "LevelZonesResizeGrip", frame)
    grip:SetHeight(15)
    grip:SetPoint("BOTTOMLEFT", 8, 4)
    grip:SetPoint("BOTTOMRIGHT", -8, 4)
    grip:SetFrameLevel(frame:GetFrameLevel() + 8)
    grip:EnableMouse(true)
    local bar = grip:CreateTexture(nil, "ARTWORK")
    bar:SetSize(30, 3)
    bar:SetPoint("CENTER")
    bar:SetColorTexture(.54, .39, .22, 1)
    grip:SetScript("OnEnter", function() bar:SetColorTexture(.85, .64, .33, 1) end)
    grip:SetScript("OnLeave", function() bar:SetColorTexture(.54, .39, .22, 1) end)
    grip:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        rememberPosition()
        frame.resizeStart = frame:GetHeight()
        frame:StartSizing("BOTTOM")
    end)
    local function finishResize()
        local start = frame.resizeStart
        if not start then return end
        frame:StopMovingOrSizing()
        frame.resizeStart = nil
        local height = frame:GetHeight()
        if math.abs(height - start) > .5 then settings().height = height end
        rememberPosition()
        reflow()
    end
    grip:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then finishResize() end
    end)
    grip:SetScript("OnHide", finishResize)
    frame:SetScript("OnSizeChanged", function()
        if not frame.resizeStart or frame.resizePending then return end
        frame.resizePending = true
        C_Timer.After(.04, function()
            frame.resizePending = false
            if frame.resizeStart then reflow() end
        end)
    end)
    local db = settings()
    if type(db.x) == "number" and type(db.top) == "number" then
        anchorAtTop(db.x, db.top)
    elseif type(db.x) == "number" and type(db.y) == "number" then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", db.x, db.y)
    end
    frame:Hide()
end

SLASH_LEVELZONES1 = "/lvlzones"
local function openPanel()
    settings().hidden = false
    if not frame then createWindow() end
    frame:Show()
    refresh(true)
    if type(settings().y) == "number" then rememberPosition() end
end

local function requestPanel(rebuild)
    startupRequested = true
    if Addon.EnsureLocalCatalog then
        Addon.EnsureLocalCatalog(rebuild, message, openPanel)
    else
        openPanel()
    end
end

local function togglePanel()
    if frame and frame:IsShown() then
        hidePanel()
    else
        requestPanel(false)
    end
end

local function applyScale(value)
    local db = settings()
    local oldScale = panelScale()
    db.scale = math.max(MIN_SCALE, math.min(MAX_SCALE, value))
    if not frame then return end
    local x, top = frame:GetCenter(), frame:GetTop()
    frame:SetScale(db.scale)
    applyPanelSize()
    if db.x and x and top then
        db.x, db.top, db.y = x * oldScale / db.scale, top * oldScale / db.scale, nil
        anchorAtTop(db.x, db.top)
    end
    reflow()
end

showSettings = function()
    local window = _G.LevelZonesSettings
    if not window then
        window = CreateFrame("Frame", "LevelZonesSettings", UIParent, "BackdropTemplate")
        window:SetSize(260, 134)
        window:SetPoint("CENTER")
        window:SetFrameStrata("DIALOG")
        window:SetClampedToScreen(true)
        window:EnableMouse(true)
        window:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 18, insets = { left = 5, right = 5, top = 5, bottom = 5 },
        })
        window:SetBackdropColor(.15, .125, .10, 1)
        local title = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        title:SetPoint("TOPLEFT", 13, -13)
        title:SetText("Level Zones size")
        local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -1, -1)
        close:SetScript("OnClick", function() window:Hide() end)
        local slider = CreateFrame("Slider", "LevelZonesScaleSlider", window, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", 22, -54)
        slider:SetPoint("TOPRIGHT", -22, -54)
        slider:SetMinMaxValues(MIN_SCALE, MAX_SCALE)
        slider:SetValueStep(.05)
        slider:SetObeyStepOnDrag(true)
        local label = window:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        label:SetPoint("BOTTOM", slider, "TOP", 0, 3)
        local low, high = _G.LevelZonesScaleSliderLow, _G.LevelZonesScaleSliderHigh
        if low then low:SetText("70%") end
        if high then high:SetText("150%") end
        slider:SetScript("OnValueChanged", function(_, value)
            label:SetText(string.format("%d%%", math.floor(value * 100 + .5)))
            if math.abs(value - panelScale()) > .0001 then applyScale(value) end
        end)
        label:SetText(string.format("%d%%", math.floor(panelScale() * 100 + .5)))
        slider:SetValue(panelScale())
        local reset = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        reset:SetSize(96, 22)
        reset:SetPoint("BOTTOM", 0, 12)
        reset:SetText("Auto fit")
        reset:SetScript("OnClick", function()
            settings().height = nil
            if frame then applyPanelSize() end
            reflow()
        end)
        window:Show()
    elseif window:IsShown() then
        window:Hide()
    else
        window:Show()
    end
end

local function positionMinimapButton()
    local angle = settings().minimapAngle or math.rad(220)
    local rx, ry = Minimap:GetWidth() / 2 + 3, Minimap:GetHeight() / 2 + 3
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * rx, math.sin(angle) * ry)
end

local function createMinimapButton()
    if minimapButton or not Minimap then return end
    minimapButton = CreateFrame("Button", "LevelZonesMinimapButton", Minimap)
    minimapButton:SetSize(30, 30)
    minimapButton:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")
    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
    icon:SetTexCoord(.08, .92, .08, .92)
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    local rim = minimapButton:CreateTexture(nil, "OVERLAY")
    rim:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    rim:SetSize(52, 52)
    rim:SetPoint("TOPLEFT", -1, 0)
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    minimapButton:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then showSettings() else togglePanel() end
    end)
    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Level Zones")
        GameTooltip:AddLine("Left-click: Show or hide the panel", 1, 1, 1)
        GameTooltip:AddLine("Right-click: Adjust size", 1, 1, 1)
        GameTooltip:AddLine("Drag to move this button", 1, 1, 1)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local x, y = GetCursorPosition()
            local cx, cy = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            settings().minimapAngle = math.atan2(y / scale - cy, x / scale - cx)
            positionMinimapButton()
        end)
    end)
    minimapButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    positionMinimapButton()
end

SlashCmdList.LEVELZONES = function(command)
    local rebuild = command and command:match("^%s*rebuild%s*$") ~= nil
    if rebuild then requestPanel(true) else togglePanel() end
end

local events = CreateFrame("Frame")
for _, event in ipairs({
    "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED",
    "ZONE_CHANGED_INDOORS", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN",
}) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, id)
    if event == "PLAYER_ENTERING_WORLD" then createMinimapButton() end
    if event == "PLAYER_ENTERING_WORLD" and not startupRequested then
        startupRequested = true
        if not settings().hidden then requestPanel(false) end
        return
    end
    if not frame or not frame:IsShown() then return end
    if event == "QUEST_TURNED_IN" and id then turnedIn[id] = GetTime() + 8 end
    if event ~= "QUEST_LOG_UPDATE" then worldUpdatePending = true end
    if updatePending then return end
    updatePending = true
    C_Timer.After(.3, function()
        updatePending = false
        local requery = worldUpdatePending
        worldUpdatePending = false
        if not frame:IsShown() then return end
        if requery or not snapshot then
            refresh(true)
        else
            local active = questLog()
            if not sameQuestLog(snapshot.ctx.active, active) then refresh(true, active) end
        end
    end)
end)
