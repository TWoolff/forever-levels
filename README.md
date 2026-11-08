# Forever Levels

The addon for the [Forever Levels](https://foreverlevels.com) leveling guide for World of Warcraft: Forever. It saves each of your characters' finished quests, quest log, race, class, talents, level, reputation, profession skills, play times, hearthstone, gold, riding, what they hold, flight paths and dungeon kills in a file on your computer. You drop that file on the guide, and it ticks the quests your main has done and fills in their race, class, spec, level, skills and standing with each reputation.

By TWoolff. MIT licence. Get it from [CurseForge](https://www.curseforge.com/wow/addons/forever-levels).

## What it does

- **It saves,** for every character you log in with, in one file for your whole account: every quest the character has finished and the ones in its quest log, their race, faction, class and level, the points spent in each talent tree, their profession skills, their standing with each reputation in their reputation panel, when and how fast they played and their time played, their hearthstone's inn and whether they know riding, the items in their bags, worn and in their bank, the flight paths they know, their dungeon boss kills, what it saw happen (quests picked up and handed in, bosses killed), when it last saved, and the game's version.
- **It never sends anything anywhere.** Addons can't reach the internet, and this one has nothing to send. The guide reads the file in your browser; nothing is uploaded.
- **It shows three small things in the game,** each with its own checkbox in the game's Options > AddOns > Forever Levels, all on at first:
  - **XP an hour:** hover the XP bar, and its tooltip shows your XP an hour this session and the time to your next level at it. It's the guide's session pace: the session runs through `/reload`s and breaks of under an hour, and a stretch of over 30 minutes with no XP isn't counted. It shows once the session has 15 minutes of play that gained XP.
  - **Level-ups in chat:** one line at each level: "Level 25 · 1 h 52 min played at level 24 · 19,000 XP an hour this session".
  - **Biggest crits:** your biggest crit and crit heal, on the XP bar's tooltip, and a line in chat from level 10 when a new one is at least a quarter above the last. Forever's combat log is closed to addons, so a crit is read from the hit your target takes, and a crit heal from the heal you take. Neither says whose it was, so they're counted only out of a group, where they're yours or your pet's.

  No window, no slash commands, and never a guide: it says what happened, never where to go.
- **It doesn't read other addons' data.**

## Where the file is

`WTF/Account/<your account>/SavedVariables/ForeverLevels.lua`, in your game folder. The game writes it when you type `/reload`, log out or quit, never in between. The `ForeverLevels.lua.bak` beside it is the save before last.

## The file

One saved variable, `ForeverLevelsDB`, for the whole account. Keys come in no fixed order.

```lua
ForeverLevelsDB = {
  ["format"] = 1,
  ["characters"] = {
    ["Player-4620-017887F2"] = {
      ["name"] = "Miss Ranxerox",
      ["realm"] = "Classic Beta PvE 2",
      ["race"] = "Skyborne",
      ["raceId"] = 96,
      ["faction"] = "Horde",
      ["class"] = "DRUID",
      ["classId"] = 11,
      ["talentPoints"] = { 0, 9, 0 },
      ["level"] = 18,
      ["skills"] = {
        { ["skillLine"] = 171, ["skill"] = 58, ["max"] = 150 },
      },
      ["quests"] = { 869, 5041 },
      ["reputation"] = { [76] = 250, [72] = -42000, [2778] = 4200, [2787] = 750 },
      ["savedAt"] = 1792462952,
      ["build"] = { ["version"] = "1.60.1", ["build"] = "70450", ["interface"] = 16001 },
    },
  },
}
```

- **`format`** goes up only for a change that breaks this shape, such as a renamed or retyped field. An added field doesn't raise it. The guide reads every format the addon has shipped.
- **`characters`** is keyed by the character's GUID. Once a character is in, it stays.
- **For each character:**

  | Field | From |
  |---|---|
  | `name` | `GetUnitName("player", true)`: first name and surname |
  | `realm` | `GetRealmName()` |
  | `race`, `raceId` | `UnitRace("player")`: the race's token and ID |
  | `faction` | `UnitFactionGroup("player")`: `Horde` or `Alliance` |
  | `class`, `classId` | `UnitClass("player")`: the class's token and ID |
  | `talentPoints` | `C_ClassTalents.GetActiveConfigID()`, `C_Traits.GetConfigInfo()`, `C_Traits.GetGroupDisplayInfoByTreeID()` and `C_Traits.GetGroupCurrencyInfo()`: the points spent in each of the three talent trees, in the trees' order, for the spec group in use |
  | `level` | `UnitLevel("player")`, or the new level from `PLAYER_LEVEL_UP` |
  | `skills` | `GetProfessions()` and `GetProfessionInfo()`: one `{ skillLine, skill, max }` for each profession learned, sorted by skill line |
  | `quests` | `C_QuestLog.GetAllCompletedQuestIDs()`: the whole quest history, sorted |
  | `reputation` | `C_Reputation.GetNumFactions()` and `C_Reputation.GetFactionDataByIndex()`'s `currentStanding`: the total for each reputation the reputation panel lists, the guide's or not, by the game's faction ID. A header is skipped unless it has a bar of its own, and one saved before that a collapsed header hides is read with `C_Reputation.GetFactionDataByID()`. Totals run below 0 from Hated up |
  | `savedAt` | `time()`, in epoch seconds, at every read and at logout |
  | `build` | `GetBuildInfo()`: the game's version, build and interface number |
  | `log`, `ready` | `C_QuestLog.GetNumQuestLogEntries()` and `GetInfo()`, headers skipped: the quest IDs in the quest log, and those `C_QuestLog.IsComplete()`, each sorted |
  | `sightings` | What it saw happen, oldest first, the newest 500 kept. Each has `kind`, `at` (epoch seconds) and the character's `level`. `pickup` (`QUEST_ACCEPTED`): `quest`; `npc`, the quest giver's NPC ID from `UnitGUID("npc")` at the `QUEST_DETAIL` before, none for an item; `xp`, `GetRewardXP()` there, none for a reading of 0 (a quest from one of Forever's objects reads 0 there though it pays); `map`, `x`, `y`, `C_Map`'s position to one decimal, none in a dungeon; `questLevel`, the log's `difficultyLevel`. `handIn` (`QUEST_COMPLETE`, the window at a turn-in, which may still be closed): `quest`, `xp`, `questLevel`, `npc`, `map`, `x`, `y`. `turnIn` (`QUEST_TURNED_IN`): `quest`, `xp`, its `xpReward`. While Well-Rested (spell 429959, from the Cozy Sleeping Bag) is up, which adds 1% a stack to the XP shown and paid, a `pickup`, `handIn` or `turnIn` has no `xp`. `kill` (`ENCOUNTER_END` with success): `encounter`, `name`, `difficulty`, `groupSize`, and `instance`, `GetInstanceInfo()`'s 8th value |
  | `plays` | Play stretches, oldest first, the newest 200 kept. A login starts one; a `/reload` continues it. Each has `from` and `to`, each `{ at, level, xp, rested, money }` (`time()`, `UnitLevel`, `UnitXP`, `GetXPExhaustion()` or 0, `GetMoney()` in copper), `to` moved on at each `PLAYER_XP_UPDATE`, `PLAYER_MONEY` and logout; `idle`, the seconds of stretches over 30 minutes with no XP, the one since the last gain included; `idleBefore` and `lastXp`, which it's counted from; `skills`, each skill line's rank at the start; and `zone`, `C_Map.GetBestMapForUnit("player")`, moved at each zone change |
  | `levelUps` | `{ level, at, played }` at each `PLAYER_LEVEL_UP`: the level reached, when, and the total time played then. None for a level reached before this login's `/played` reply |
  | `played` | `{ total, level }`, in seconds: `/played`'s reply (`TIME_PLAYED_MSG`), counted forward with `GetTime()` at each save and at logout. Its chat line is hidden: see below |
  | `bind` | `GetBindLocation()`: the hearthstone's inn |
  | `riding`, `journeyman` | `C_SpellBook.IsSpellKnown()`: true once Apprentice (33388) or Journeyman Riding (33391) is known, and once Journeyman is. Neither goes back to false |
  | `bossKills` | `GetStatistic(14821, i)` for each of the Boss Kills category's statistics, as the Statistics frame walks them: each statistic's count above 0, by its ID |
  | `items` | Item IDs, each list sorted with no repeats: `bags` (the keyring, the backpack and its bags, `C_Container`), `worn` (`GetInventoryItemID` for slots 1–19), and `bank` with `bankAt`, the character bank as last seen open, since its slots read only then |
  | `flightPaths` | The TaxiNodes IDs known, sorted: at each `TAXIMAP_OPENED`, the nodes of `C_TaxiMap.GetAllTaxiNodes(GetTaxiMapID())` with `state` 0 (the flight master's own) or 1 (reachable), added to those saved. A flight master's map shows only its own continent, so each fills in from its own flight masters. Not `GetTaxiNodesForMap()`, which reads every flight path as discovered |
  | `session` | The session so far, for XP an hour: `{ xp, time, lastSeen }`, the XP gained, the seconds of play counted, and when it was last seen (epoch seconds) |
  | `crits` | `{ damage, heal }`, each `{ amount, target, level }`: the biggest crit and crit heal, the target's name, and the character's level then |
- **`show`**, for the whole account: `{ pace, levelUps, crits }`, the three checkboxes. The guide reads none of `show`, `session` or `crits`.

## When it reads

| Event | What it reads |
|---|---|
| `PLAYER_LOGIN` | Everything but the flight paths |
| `QUEST_TURNED_IN` | The quests, 1 s later |
| `SKILL_LINES_CHANGED`, `CHAT_MSG_SKILL`, `LEARNED_SPELL_IN_SKILL_LINE` | The skills, 1 s after the first of a burst |
| `PLAYER_LEVEL_UP` | The level |
| `UPDATE_FACTION` | The reputations, 1 s after the first of a burst |
| `TRAIT_CONFIG_LIST_UPDATED`, `TRAIT_CONFIG_UPDATED`, `ACTIVE_COMBAT_CONFIG_CHANGED`, `ACTIVE_TALENT_GROUP_CHANGED`, `PLAYER_TALENT_UPDATE` | The talents, 1 s after the first of a burst |
| `PLAYER_LOGOUT` | Only the time, the play's end and the time played |
| `PLAYER_ENTERING_WORLD`, at a login or `/reload` | A new play, or the same one after a `/reload`; 5 s later, one `RequestTimePlayed()` |
| `TIME_PLAYED_MSG` | The time played, from any addon's request |
| `QUEST_DETAIL`, `QUEST_ACCEPTED`, `QUEST_COMPLETE`, `QUEST_TURNED_IN`, `ENCOUNTER_END` | A sighting |
| `QUEST_ACCEPTED`, `QUEST_REMOVED`, `QUEST_LOG_UPDATE`, `QUEST_TURNED_IN` | The quest log, 1 s after the last of a burst |
| `PLAYER_XP_UPDATE`, `PLAYER_MONEY`, `ZONE_CHANGED_NEW_AREA` | The play |
| `HEARTHSTONE_BOUND` | The hearthstone |
| `LEARNED_SPELL_IN_SKILL_LINE` | Riding too |
| `CRITERIA_UPDATE` | The boss statistics |
| `BAG_UPDATE_DELAYED`, `PLAYER_EQUIPMENT_CHANGED`, `BANKFRAME_OPENED`, `PLAYERBANKSLOTS_CHANGED`, `BANKFRAME_CLOSED` | What it holds; the bank only while it's open |
| `TAXIMAP_OPENED` | The flight paths, as the map opens |

**`/played`'s chat line** is hidden for the addon's own request only: a wrapper on `ChatFrameUtil.DisplayTimePlayed`, put in when the file loads, drops the line while the request is out, and lets it through again on the frame after the reply, or after 10 s with none. A `/played` you type while it's out still prints.

What it shows in the game, it reads from these:

| Event | What for |
|---|---|
| `PLAYER_XP_UPDATE` | The session's XP and time |
| `PLAYER_LEVEL_UP` | The level-up line, 1 s later |
| `PLAYER_ENTERING_WORLD` | 5 s later, one `RequestTimePlayed()`, for the level-up line's time played. Its reply's chat line is dropped, and only that one: typing `/played` shows it as ever |
| `TIME_PLAYED_MSG` | The time played at this level, counted on from there with `GetTime()` |
| `UNIT_COMBAT`, for `target` and `player` | A crit the target takes, and a crit heal the player takes, out of a group |

The game reads an empty quest list and no skills at logout, so they're never read then, and neither are the talents. An empty quest list never replaces one that isn't empty, since a finished quest stays finished. A read of no reputations is never saved either: every character has met its city, so it means the game hasn't loaded them yet. A header collapsed in the reputation panel hides the reputations under it, and the addon never opens one: a reputation saved before is then read by its ID, with `C_Reputation.GetFactionDataByID()`, but one under a header that's been collapsed since before its first read isn't saved until the header is opened. A client function that's missing or fails leaves its field as it was.

## After a game patch

If your AddOns list says Forever Levels is out of date, tick "Load out of date AddOns" there until the update reaches you.

---

Forever Levels is free, and always will be. If it's saved you time, you can support it on Ko-fi: [ko-fi.com/foreverlevels](https://ko-fi.com/foreverlevels)
