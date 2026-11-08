-- Forever Levels: saves each character's finished quests, quest log, race, class, talents,
-- level, reputation, profession skills, play times, hearthstone, riding, what it holds, flight
-- paths, dungeon kills and the game's own counts for the Forever Levels guide,
-- https://foreverlevels.com.
--
-- Everything goes into ForeverLevelsDB, one account-wide saved variable. The game writes
-- it to WTF/Account/<account>/SavedVariables/ForeverLevels.lua on /reload, logout and
-- exit. The addon sends nothing and reads no other addon's data. What it shows in the game is
-- InGame.lua's, called from here, so nothing it does can stop a save.

local ADDON_NAME, ns = ...

-- Calls one of InGame.lua's hooks, if it's there, so an error in it leaves the save as it was.
local function inGame(name, ...)
  if type(ns[name]) == "function" then pcall(ns[name], ...) end
end

-- Goes up only for a change that breaks the file's shape, never for an added field.
local FORMAT = 1

local db, character

-- Retail's "secret" values can't be saved: treat one as no value.
local function plain(v)
  if issecretvalue and issecretvalue(v) then return nil end
  return v
end

-- Calls f and returns up to four of its results, or nothing if f is missing or errors,
-- so one changed client function leaves its field as it was and can't break the rest.
local function try(f, ...)
  if type(f) ~= "function" then return end
  local ok, a, b, c, d = pcall(f, ...)
  if ok then return plain(a), plain(b), plain(c), plain(d) end
end

-- Time played, counted forward from the last /played reply (addon 1.1, below), and when a thing
-- was first seen, with the time played then (the next addon release, below).
local countPlayed, stamp

local function readSavedAt()
  local now = try(time)
  if type(now) == "number" then character.savedAt = now end
  countPlayed()
end

local function readLevel(level)
  if type(level) ~= "number" then level = try(UnitLevel, "player") end
  if type(level) == "number" and level > 0 then character.level = level end
end

local function readCharacter()
  local name = try(GetUnitName, "player", true)
  if type(name) == "string" and name ~= "" then character.name = name end
  local realm = try(GetRealmName)
  if type(realm) == "string" and realm ~= "" then character.realm = realm end
  local _, race, raceId = try(UnitRace, "player")
  if type(race) == "string" then character.race = race end
  if type(raceId) == "number" then character.raceId = raceId end
  local faction = try(UnitFactionGroup, "player")
  if type(faction) == "string" then character.faction = faction end
  local _, class, classId = try(UnitClass, "player")
  if type(class) == "string" then character.class = class end
  if type(classId) == "number" then character.classId = classId end
  readLevel()
  local version, build, _, interface = try(GetBuildInfo)
  if type(version) == "string" then
    character.build = { version = version, build = build, interface = interface }
  end
end

-- The whole quest history. A finished quest stays finished, so an empty list never
-- replaces one that isn't: the client reads empty at logout, and could again elsewhere.
local function readQuests()
  local ids = try(C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs)
  if type(ids) ~= "table" then return end
  local list = {}
  for i = 1, #ids do
    if type(ids[i]) == "number" then list[#list + 1] = ids[i] end
  end
  if #list == 0 and character.quests and #character.quests > 0 then return end
  table.sort(list)
  character.quests = list
end

-- A rank trained (the climb build spec §2): `{ skillLine, cap, at, played }` when a skill line's
-- cap is above the one saved, a new profession's included, once each. A first read, or one after
-- a read of none, adds none: an empty read can't be told from no professions.
local function addRanks(skills)
  local before = character.skills
  if type(before) ~= "table" or #before == 0 then return end
  local caps = {}
  for _, s in ipairs(before) do caps[s.skillLine] = s.max end
  local ranks = type(character.ranks) == "table" and character.ranks or {}
  local function key(skillLine, cap) return tostring(skillLine) .. ":" .. tostring(cap) end
  local seen = {}
  for _, r in ipairs(ranks) do seen[key(r.skillLine, r.cap)] = true end
  for _, s in ipairs(skills) do
    local cap = caps[s.skillLine]
    if type(s.max) == "number" and (cap == nil or type(cap) == "number" and s.max > cap)
        and not seen[key(s.skillLine, s.max)] then
      local rank = stamp()
      rank.skillLine, rank.cap = s.skillLine, s.max
      ranks[#ranks + 1] = rank
    end
  end
  if #ranks > 0 then character.ranks = ranks end
end

-- Every profession learned, the guide's or not, sorted by skill line. Saved as read,
-- empty included, since a profession can be unlearned.
local function readSkills()
  if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then return end
  local ok, a, b, c, d, e = pcall(GetProfessions)
  if not ok then return end
  local skills = {}
  for _, index in ipairs({ a or false, b or false, c or false, d or false, e or false }) do
    if index then
      local info = { pcall(GetProfessionInfo, index) }
      if not info[1] then return end
      local skill, max, skillLine = plain(info[4]), plain(info[5]), plain(info[8])
      if type(skillLine) == "number" and type(skill) == "number" then
        skills[#skills + 1] = { skillLine = skillLine, skill = skill, max = max }
      end
    end
  end
  table.sort(skills, function(x, y) return x.skillLine < y.skillLine end)
  addRanks(skills)
  character.skills = skills
end

-- The points spent in each of the three talent trees, in the trees' order, read as Forever's
-- own talent frame reads them (Blizzard_PlayerSpells/Camelot in 1.60.1's UI source): the tree
-- from the active config, and each tree's points matched by its group ID. The active config
-- follows the spec group in use, so dual spec reads the one played. Errors on any missing piece.
local function talentPoints()
  local configID = C_ClassTalents.GetActiveConfigID()
  local trees = C_Traits.GetGroupDisplayInfoByTreeID(C_Traits.GetConfigInfo(configID).treeIDs[1])
  if #trees ~= 3 then return end
  table.sort(trees, function(x, y) return x.orderIndex < y.orderIndex end)
  local groupIDs = {}
  for i, tree in ipairs(trees) do groupIDs[i] = tree.groupID end
  -- A tree with no currency info has none spent, as the talent frame shows it.
  local spent = {}
  for _, group in ipairs(C_Traits.GetGroupCurrencyInfo(configID, groupIDs)) do
    spent[group.traitNodeGroupID] = group.currencyInfos[1] and group.currencyInfos[1].spent
  end
  local points = {}
  for i, groupID in ipairs(groupIDs) do
    local n = plain(spent[groupID] or 0)
    if type(n) ~= "number" then return end
    points[i] = n
  end
  return points
end

local function readTalents()
  local points = try(talentPoints)
  if type(points) == "table" then character.talentPoints = points end
end

-- Each reputation's total (currentStanding, the bar's), by the game's faction ID: every one the
-- reputation frame lists, as Forever's own frame lists them (Blizzard_UIPanels_Game/Camelot in 1.60.1's
-- UI source), the guide's or not, but a header without a bar. A collapsed header hides its own, and the
-- addon never opens one, so one saved before that isn't listed now is read by its ID. One the client
-- gives nothing for isn't saved. A read of none is never saved: every character has met its city, so it
-- means the client hasn't loaded them yet, as at login.
local function readReputation()
  if not C_Reputation then return end
  local totals, any = {}, false
  local function addTotal(data)
    if type(data) ~= "table" then return end
    local id, total = plain(data.factionID), plain(data.currentStanding)
    if type(id) == "number" and id > 0 and type(total) == "number" then
      totals[id] = total
      any = true
    end
  end
  local count = try(C_Reputation.GetNumFactions)
  for i = 1, type(count) == "number" and count or 0 do
    local data = try(C_Reputation.GetFactionDataByIndex, i)
    local hasBar = type(data) == "table" and (not plain(data.isHeader) or plain(data.isHeaderWithRep))
    if hasBar then addTotal(data) end
  end
  if type(character.reputation) == "table" then
    for id in pairs(character.reputation) do
      if totals[id] == nil then addTotal(try(C_Reputation.GetFactionDataByID, id)) end
    end
  end
  if any then character.reputation = totals end
end

-- A skill-up fires two events at once, and a talent change several: read once, 1 s after the
-- first of a burst.
local readPending = {}
local function readSoon(read)
  if not character or readPending[read] then return end
  readPending[read] = true
  C_Timer.After(1, function()
    readPending[read] = nil
    read()
    readSavedAt()
  end)
end


-- Addon 1.1 (the online and sharing build spec §2) ------------------------------------------

local SIGHTINGS_KEPT, PLAYS_KEPT = 500, 200
-- A stretch of over 30 minutes with no XP gained is idle.
local IDLE = 30 * 60
-- Apprentice and Journeyman Riding, skill line 762's spells in the client's SkillLineAbility
-- (1.60.1.70532). Journeyman replaces Apprentice, so either counts as riding.
local APPRENTICE_RIDING, JOURNEYMAN_RIDING = 33388, 33391
-- The Cozy Sleeping Bag's Well-Rested, which adds 1% a stack to a quest window's XP and to the
-- XP paid (the live check, Nov 2026).
local WELL_RESTED = 429959
-- The Statistics frame's Boss Kills category.
local BOSS_KILLS = 14821
-- The climb's Statistics (the climb build spec §2), by ID: the 8 a play's gain is kept for
-- (deaths, creatures killed, gold looted, gold from quests, quests completed, flight paths taken,
-- times hearthed, dungeons entered), then the 8 kept as totals only (deaths in dungeons, from
-- falling and from drowning, times camped, largest hit taken, most gold owned, largest hit dealt,
-- largest heal cast). Gold is in copper.
local PLAY_STATISTICS = { 60, 107, 333, 326, 98, 349, 353, 932 }
local TOTAL_STATISTICS = { 918, 114, 112, 64222, 527, 334, 193, 189 }
-- Enum.BagIndex: the keyring, the backpack, its four bags and the reagent bag; the character
-- bank and its nine tabs. Never the account bank's, which isn't the character's.
local BAGS = { -1, 0, 1, 2, 3, 4, 5 }
local BANK = { -2, 6, 7, 8, 9, 10, 11, 12, 13, 14 }

local function sortedKeys(set)
  local list = {}
  for k in pairs(set) do list[#list + 1] = k end
  table.sort(list)
  return list
end

local function round1(n)
  return math.floor(n * 10 + 0.5) / 10
end

-- The quest log: its quest IDs, and the ones complete, each sorted. Never read at logout,
-- where it reads empty, as the quest history does.
local function readLog()
  if not C_QuestLog then return end
  local n = try(C_QuestLog.GetNumQuestLogEntries)
  if type(n) ~= "number" then return end
  local log, ready = {}, {}
  for i = 1, n do
    local info = try(C_QuestLog.GetInfo, i)
    local id = type(info) == "table" and not plain(info.isHeader) and plain(info.questID)
    if type(id) == "number" and id > 0 then
      log[#log + 1] = id
      if try(C_QuestLog.IsComplete, id) then ready[#ready + 1] = id end
    end
  end
  table.sort(log)
  table.sort(ready)
  character.log, character.ready = log, ready
end

-- The level Forever shows before a logged quest's title, "[28]".
local function questLevel(id)
  if not C_QuestLog then return end
  local index = try(C_QuestLog.GetLogIndexForQuestID, id)
  local info = type(index) == "number" and try(C_QuestLog.GetInfo, index)
  local level = type(info) == "table" and plain(info.difficultyLevel)
  if type(level) == "number" then return level end
end

-- Sightings ---------------------------------------------------------------------------------

local function sight(kind, fields)
  local list = character.sightings
  if type(list) ~= "table" then
    list = {}
    character.sightings = list
  end
  fields.kind = kind
  fields.at = try(time)
  fields.level = try(UnitLevel, "player")
  list[#list + 1] = fields
  while #list > SIGHTINGS_KEPT do table.remove(list, 1) end
  return fields
end

-- The quest giver's NPC ID, from its GUID, "Creature-0-3767-1-29-4949-00004A2C3A". None for an
-- item or an object.
local function npcID()
  local guid = try(UnitGUID, "npc")
  if type(guid) ~= "string" then return end
  local kind, id = guid:match("^(%a+)%-[^-]*%-[^-]*%-[^-]*%-[^-]*%-(%d+)")
  if kind == "Creature" then return tonumber(id) end
end

-- Where the character stands, to one decimal place, or nothing in a dungeon.
local function place(fields)
  local map = C_Map and try(C_Map.GetBestMapForUnit, "player")
  if type(map) ~= "number" then return fields end
  local position = try(C_Map.GetPlayerMapPosition, map, "player")
  local x, y
  if type(position) == "table" then x, y = try(position.GetXY, position) end
  if type(x) == "number" and type(y) == "number" then
    fields.map, fields.x, fields.y = map, round1(x * 100), round1(y * 100)
  end
  return fields
end

-- Whether Well-Rested is up, read from the player's helpful auras as the live check read them.
local function wellRested()
  local auras = C_UnitAuras
  if not auras then return false end
  for i = 1, 40 do
    local aura = try(auras.GetAuraDataByIndex, "player", i, "HELPFUL")
    if type(aura) ~= "table" then return false end
    if plain(aura.spellId) == WELL_RESTED then return true end
  end
  return false
end

-- A quest window's XP, or none under Well-Rested, which adds to it.
local function windowXP()
  if not wellRested() then return try(GetRewardXP) end
end

-- The last quest window opened at a quest giver, until the quest's accepted.
local detail

-- A quest from one of Forever's objects isn't in the client's cache yet, so its window reads 0:
-- that reading is dropped. A quest that pays nothing gets its 0 from the hand-in.
local function onQuestDetail()
  local quest = try(GetQuestID)
  local xp = windowXP()
  detail = place({ quest = quest, npc = npcID(), xp = xp ~= 0 and xp or nil })
end

local function onQuestAccepted(quest)
  quest = plain(quest)
  if type(quest) ~= "number" then return end
  local fields = { quest = quest }
  if detail and detail.quest == quest then
    fields.npc, fields.xp, fields.map, fields.x, fields.y = detail.npc, detail.xp, detail.map, detail.x, detail.y
  else
    place(fields)
  end
  detail = nil
  local seen = sight("pickup", fields)
  C_Timer.After(1, function() seen.questLevel = questLevel(quest) end)
end

-- The quest window at a hand-in. The player can still close it: the guide pairs it with the quest
-- history.
local function onQuestComplete()
  local quest = try(GetQuestID)
  if type(quest) ~= "number" or quest <= 0 then return end
  sight("handIn", place({ quest = quest, xp = windowXP(), questLevel = questLevel(quest), npc = npcID() }))
end

local function onKill(encounter, name, difficulty, groupSize, success)
  if plain(success) ~= 1 then return end
  local ok, _, _, _, _, _, _, _, instance = pcall(GetInstanceInfo)
  sight("kill", { encounter = plain(encounter), name = plain(name), difficulty = plain(difficulty),
    groupSize = plain(groupSize), instance = ok and plain(instance) or nil })
end

-- Time played, from /played, its chat line hidden ---------------------------------------------
-- As "How the addon reads /played" (#307) decided: one request 5 s after a login or /reload, any
-- addon's reply used, counted forward with GetTime(). The client's line is dropped only while the
-- addon's own request is out, and a /played the player types prints as ever.

local reply -- { total, level, at }: the last reply, at its GetTime()
local armed = false
local original = ChatFrameUtil and ChatFrameUtil.DisplayTimePlayed

local function wrapper(chatFrame, ...)
  if armed then return end
  return original(chatFrame, ...)
end

-- At file load, so the wrapper sits under addons that load after this one.
if type(original) == "function" then ChatFrameUtil.DisplayTimePlayed = wrapper end

local function disarm()
  armed = false
end

if SlashCmdList and SlashCmdList.PLAYED then pcall(hooksecurefunc, SlashCmdList, "PLAYED", disarm) end

local function requestPlayed()
  if reply or not original or ChatFrameUtil.DisplayTimePlayed ~= wrapper then return end
  armed = true
  if not pcall(RequestTimePlayed) then armed = false end
  -- A lost reply can't mute /played for good.
  C_Timer.After(10, disarm)
end

local function onTimePlayed(total, atLevel)
  total, atLevel = plain(total), plain(atLevel)
  if type(total) == "number" and type(atLevel) == "number" then
    reply = { total = total, level = atLevel, at = GetTime() }
    countPlayed()
  end
  -- Every chat frame shows the reply in this same event, so the line is let through again after.
  if armed then C_Timer.After(0, disarm) end
end

-- The total and this level's time now, counted from the last reply; none without one this login.
local function playedNow()
  if not reply then return end
  local since = GetTime() - reply.at
  return { total = math.floor(reply.total + since), level = math.floor(reply.level + since) }
end
ns.playedNow = playedNow

function countPlayed()
  local now = playedNow()
  if now and character then character.played = now end
end

-- `{ at, played }`: now, and the total time played, left out while this login has no reply yet.
function stamp()
  local now = playedNow()
  return { at = try(time), played = now and now.total }
end
ns.stamp = stamp

-- Play times ----------------------------------------------------------------------------------

local function skillRanks()
  local ranks = {}
  for _, s in ipairs(type(character.skills) == "table" and character.skills or {}) do
    ranks[s.skillLine] = s.skill
  end
  return ranks
end

-- One end of a play: when, the level, XP and rested XP, and gold in copper.
local function playEnd()
  local rested = try(GetXPExhaustion)
  return { at = try(time), level = try(UnitLevel, "player"), xp = try(UnitXP, "player"),
    rested = type(rested) == "number" and rested or 0, money = try(GetMoney) }
end

local function zone()
  local map = C_Map and try(C_Map.GetBestMapForUnit, "player")
  if type(map) == "number" then return map end
end

local function currentPlay()
  local plays = character.plays
  return type(plays) == "table" and plays[#plays]
end

-- A login starts a play; a /reload continues it.
local function startPlay(reloading)
  local play = currentPlay()
  if reloading and type(play) == "table" then return end
  local plays = type(character.plays) == "table" and character.plays or {}
  character.plays = plays
  local now = playEnd()
  plays[#plays + 1] = { from = now, to = playEnd(), idle = 0, idleBefore = 0, lastXp = now.at,
    skills = skillRanks(), zone = zone() }
  while #plays > PLAYS_KEPT do table.remove(plays, 1) end
end

-- `idle` is `idleBefore`, the stretches with no XP between gains, and the one since the last gain
-- while it's over 30 minutes. At logout only the end's time moves: the game reads no XP, rested XP
-- or gold then, and the level the character logged in at (Nov 5, 1.60.1.70790).
local function updatePlay(gained, loggingOut)
  local play = currentPlay()
  if type(play) ~= "table" then return end
  local now = try(time)
  if type(now) ~= "number" then return end
  local since = now - (play.lastXp or now)
  if gained then
    if since > IDLE then play.idleBefore = (play.idleBefore or 0) + since end
    play.lastXp = now
    since = 0
  end
  play.idle = (play.idleBefore or 0) + (since > IDLE and since or 0)
  if loggingOut and type(play.to) == "table" then
    play.to.at = now
  else
    play.to = playEnd()
  end
end

-- One per level reached, with the total time played then, while this login has had a reply.
local function onLevelUp(level)
  level = plain(level)
  local now = playedNow()
  if type(level) == "number" and now then
    if type(character.levelUps) ~= "table" then character.levelUps = {} end
    local list = character.levelUps
    list[#list + 1] = { level = level, at = try(time), played = now.total }
    inGame("levelUp", level, now.level)
    reply = { total = now.total, level = 0, at = GetTime() }
    countPlayed()
  elseif type(level) == "number" then
    inGame("levelUp", level, nil)
  end
end

-- What the main has ---------------------------------------------------------------------------

local function readBind()
  local bind = try(GetBindLocation)
  if type(bind) == "string" and bind ~= "" then character.bind = bind end
end

local function known(spell)
  if C_SpellBook and type(C_SpellBook.IsSpellKnown) == "function" then
    return try(C_SpellBook.IsSpellKnown, spell) == true
  end
  return try(IsSpellKnown, spell) == true
end

-- Riding can't be unlearned, so neither reads false once it's true. Each is stamped when it's
-- first seen turning true, never when it was already true at the first read (the climb build spec,
-- decided 1).
local function readRiding()
  local journeyman = known(JOURNEYMAN_RIDING)
  local riding = character.riding == true or journeyman or known(APPRENTICE_RIDING)
  if riding and character.riding == false then character.ridingAt = stamp() end
  if journeyman and character.journeyman == false then character.journeymanAt = stamp() end
  character.riding = riding
  character.journeyman = character.journeyman == true or journeyman
end

-- Each Boss Kills statistic's count above 0, by its ID, as the Statistics frame walks them.
local function readBossKills()
  local n = try(GetCategoryNumAchievements, BOSS_KILLS)
  if type(n) ~= "number" then return end
  local kills = {}
  for i = 1, n do
    local quantity, _, id = try(GetStatistic, BOSS_KILLS, i)
    local count = tonumber(quantity)
    if type(id) == "number" and count and count > 0 then kills[id] = count end
  end
  character.bossKills = kills
end

-- The climb's Statistics: each total, and this play's gain for the 8 (the climb build spec §2).
-- "--", a count not started, is 0. A read where every one is 0 is skipped whole: it's the counts
-- before the server answers, and taken as a play's start it would put the character's whole life
-- into the play's gain. A total never goes down: a read below it is skipped for that Statistic (the
-- climb build spec, decided 2), and so is one that isn't a whole number. A play's gain counts from
-- this login's or /reload's first good read, which adds nothing (decided 3): `playStart` holds that
-- read and the play's gain then, in memory only, so a /reload adds nothing and a file from another
-- computer doesn't put that computer's play into this one. Read only from 5 s after entering the
-- world (`readingStatistics`), never at logout.
local playStart, readingStatistics = {}, false

-- A Statistic as a whole number, or none. "--", a count not started, is 0. Gold reads as the game's
-- money text, each coin a number and its icon, a coin of 0 left out ("1|TInterface\MoneyFrame\
-- UI-GoldIcon:0:0:2:0|t 73|T...SilverIcon...|t 91|T...CopperIcon...|t", the live check's file of
-- 2026-11-08), and is turned into copper. Text with anything else in it reads as none.
local COINS = { Gold = 10000, Silver = 100, Copper = 1 }
local COIN = "([%d,]+)|T[^|]-UI%-(%a+)Icon[^|]*|t"

local function statisticValue(value)
  if value == "--" then return 0 end
  if type(value) == "string" and value:find("|T", 1, true) then
    if value:gsub(COIN, ""):find("%S") then return end
    local copper, found = 0, false
    for amount, coin in value:gmatch(COIN) do
      local n = tonumber((amount:gsub(",", "")))
      if not n or not COINS[coin] then return end
      copper, found = copper + n * COINS[coin], true
    end
    return found and copper or nil
  end
  local n = tonumber(value)
  if n and n >= 0 and n == math.floor(n) then return n end
end

local function readStatistics()
  if not readingStatistics then return end
  local read, any = {}, false
  for _, list in ipairs({ PLAY_STATISTICS, TOTAL_STATISTICS }) do
    for _, id in ipairs(list) do
      local n = statisticValue(try(GetStatistic, id))
      if n then
        read[id] = n
        if n > 0 then any = true end
      end
    end
  end
  if not any then return end
  local totals = type(character.statistics) == "table" and character.statistics or {}
  for id, n in pairs(read) do
    if type(totals[id]) == "number" and n < totals[id] then read[id] = nil else totals[id] = n end
  end
  character.statistics = totals
  local play = currentPlay()
  if type(play) ~= "table" then return end
  local gains = type(play.statistics) == "table" and play.statistics or {}
  for _, id in ipairs(PLAY_STATISTICS) do
    local n = read[id]
    if n and not playStart[id] then
      playStart[id] = { total = n, gain = gains[id] or 0 }
    elseif n and n > playStart[id].total then
      gains[id] = playStart[id].gain + n - playStart[id].total
      play.statistics = gains
    end
  end
end

local function readCounts()
  readBossKills()
  readStatistics()
end

local function containerItems(bags)
  if not C_Container then return end
  local set = {}
  for _, bag in ipairs(bags) do
    local slots = try(C_Container.GetContainerNumSlots, bag)
    for slot = 1, type(slots) == "number" and slots or 0 do
      local id = try(C_Container.GetContainerItemID, bag, slot)
      if type(id) == "number" then set[id] = true end
    end
  end
  return sortedKeys(set)
end

local function items()
  if type(character.items) ~= "table" then character.items = {} end
  return character.items
end

local function readBags()
  local list = containerItems(BAGS)
  if list then items().bags = list end
end

local function readWorn()
  local set = {}
  for slot = 1, 19 do
    local id = try(GetInventoryItemID, "player", slot)
    if type(id) == "number" then set[id] = true end
  end
  items().worn = sortedKeys(set)
end

-- Its slots read only with the bank open, so it's kept as last seen until it's next opened.
local bankOpen = false
local function readBank()
  if not bankOpen then return end
  local list = containerItems(BANK)
  if list then
    items().bank = list
    items().bankAt = try(time)
  end
end

-- The flight paths known, from a flight master's map as it opens: each of its nodes with `state` 0
-- (this flight master's own) or 1 (reachable), added to those saved. Its map shows only its own
-- continent, and a path can't be forgotten. Not C_TaxiMap.GetTaxiNodesForMap, which reads every
-- flight path of both factions as discovered, on a level 1 too (the live check, Nov 2026).
local function readFlightPaths()
  if not C_TaxiMap then return end
  local taxiMap = try(GetTaxiMapID)
  local nodes = type(taxiMap) == "number" and try(C_TaxiMap.GetAllTaxiNodes, taxiMap)
  if type(nodes) ~= "table" then return end
  local set = {}
  for _, id in ipairs(type(character.flightPaths) == "table" and character.flightPaths or {}) do set[id] = true end
  for _, node in ipairs(nodes) do
    if type(node) == "table" then
      local id, state = plain(node.nodeID), plain(node.state)
      if type(id) == "number" and (state == 0 or state == 1) then set[id] = true end
    end
  end
  character.flightPaths = sortedKeys(set)
end

-- Events --------------------------------------------------------------------------------------

-- Which of these Forever fires on a talent change is unchecked, so all are registered, each
-- in case the client doesn't know it.
local TALENT_EVENTS = {
  TRAIT_CONFIG_LIST_UPDATED = true,
  TRAIT_CONFIG_UPDATED = true,
  ACTIVE_COMBAT_CONFIG_CHANGED = true,
  ACTIVE_TALENT_GROUP_CHANGED = true,
  PLAYER_TALENT_UPDATE = true,
}

-- Each read 1 s after the last event of a burst; never at logout.
local SOON = {
  QUEST_ACCEPTED = readLog,
  QUEST_REMOVED = readLog,
  QUEST_LOG_UPDATE = readLog,
  HEARTHSTONE_BOUND = readBind,
  CRITERIA_UPDATE = readCounts,
  PLAYER_EQUIPMENT_CHANGED = readWorn,
  PLAYERBANKSLOTS_CHANGED = readBank,
  UPDATE_FACTION = readReputation,
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("CHAT_MSG_SKILL")
-- Each in case the client doesn't know it.
for _, event in ipairs({ "LEARNED_SPELL_IN_SKILL_LINE", "PLAYER_ENTERING_WORLD", "QUEST_DETAIL",
  "QUEST_COMPLETE", "ENCOUNTER_END", "PLAYER_XP_UPDATE", "PLAYER_MONEY", "ZONE_CHANGED_NEW_AREA",
  "TIME_PLAYED_MSG", "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "TAXIMAP_OPENED" }) do
  pcall(frame.RegisterEvent, frame, event)
end
for event in pairs(SOON) do pcall(frame.RegisterEvent, frame, event) end
for event in pairs(TALENT_EVENTS) do pcall(frame.RegisterEvent, frame, event) end

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON_NAME then return end
    db = type(ForeverLevelsDB) == "table" and ForeverLevelsDB or {}
    ForeverLevelsDB = db
    db.format = FORMAT
    if type(db.characters) ~= "table" then db.characters = {} end
    frame:UnregisterEvent("ADDON_LOADED")
    inGame("loaded", db)

  elseif event == "PLAYER_LOGIN" then
    if not db then return end
    local guid = try(UnitGUID, "player")
    if type(guid) ~= "string" or guid == "" then return end
    character = type(db.characters[guid]) == "table" and db.characters[guid] or {}
    db.characters[guid] = character
    readCharacter()
    readQuests()
    readSkills()
    readTalents()
    readReputation()
    readLog()
    readBind()
    readRiding()
    readBossKills()
    readBags()
    readWorn()
    readSavedAt()
    inGame("loggedIn", character)

  elseif not character then
    return

  elseif event == "PLAYER_ENTERING_WORLD" then
    local isInitialLogin, isReloadingUi = ...
    if isInitialLogin or isReloadingUi then
      startPlay(isReloadingUi)
      -- The Statistics' first read rides on the same timer, so it's read straight away, not 1 s on.
      C_Timer.After(5, function()
        requestPlayed()
        readingStatistics = true
        readStatistics()
        readSavedAt()
      end)
    end

  elseif event == "QUEST_TURNED_IN" then
    local quest, xp = ...
    sight("turnIn", { quest = plain(quest), xp = not wellRested() and plain(xp) or nil })
    -- The quest isn't in the list yet when the event fires.
    C_Timer.After(1, function()
      readQuests()
      readLog()
      readSavedAt()
    end)

  elseif event == "QUEST_DETAIL" then
    onQuestDetail()

  elseif event == "QUEST_ACCEPTED" then
    onQuestAccepted(...)
    readSoon(readLog)

  elseif event == "QUEST_COMPLETE" then
    onQuestComplete()

  elseif event == "ENCOUNTER_END" then
    onKill(...)

  elseif event == "PLAYER_XP_UPDATE" then
    if ... == "player" then updatePlay(true) end

  elseif event == "PLAYER_MONEY" then
    updatePlay(false)

  elseif event == "ZONE_CHANGED_NEW_AREA" then
    local play = currentPlay()
    if type(play) == "table" then play.zone = zone() or play.zone end

  elseif event == "TIME_PLAYED_MSG" then
    onTimePlayed(...)

  elseif event == "PLAYER_LEVEL_UP" then
    readLevel((...))
    onLevelUp(...)
    readSavedAt()

  elseif event == "PLAYER_LOGOUT" then
    -- Quests, skills, XP and gold read empty here, so only the play's end time, time played and the
    -- time are set: the time the game writes the file. The Statistics still read here (the live
    -- check's file, 2026-11-08), so they're read a last time first.
    readStatistics()
    updatePlay(false, true)
    readSavedAt()
    inGame("loggingOut")

  elseif event == "BAG_UPDATE_DELAYED" then
    readSoon(readBags)
    if bankOpen then readSoon(readBank) end

  elseif event == "BANKFRAME_OPENED" then
    bankOpen = true
    readSoon(readBank)

  elseif event == "TAXIMAP_OPENED" then
    -- Read as it opens: the map's nodes are the open flight master's only.
    readFlightPaths()
    readSavedAt()

  elseif event == "BANKFRAME_CLOSED" then
    -- A change a moment before closing is read before the slots stop reading.
    readBank()
    bankOpen = false

  elseif event == "LEARNED_SPELL_IN_SKILL_LINE" then
    readSoon(readSkills)
    readSoon(readRiding)

  elseif SOON[event] then
    readSoon(SOON[event])

  elseif TALENT_EVENTS[event] then
    readSoon(readTalents)

  else
    readSoon(readSkills)
  end
end)
