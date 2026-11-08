-- Forever Levels in the game: three small things, each with its own checkbox in the game's
-- Options > AddOns > Forever Levels, all on by default.
--
-- - XP an hour: the XP bar's tooltip shows the session's pace and the time to the next level
--   at it, as the guide works out session pace.
-- - Level-ups: one line in chat at each level, with the time played at the level before.
-- - Biggest crits: the character's biggest crit and crit heal, on the XP bar's tooltip, and a
--   line in chat when a new one is well above the last.
--
-- It says what happened, never where to go: the guide stays on https://foreverlevels.com.
-- ForeverLevels.lua calls ns.loaded, ns.loggedIn, ns.levelUp and ns.loggingOut, and reads
-- /played for the level-up line; nothing here can stop it saving.

local _, ns = ...

local HOUR = 3600
-- A stretch of over 30 minutes with no XP isn't counted as play, as the guide's pace leaves it out.
local IDLE = 30 * 60
-- Session pace shows once the session holds 15 minutes of play that gained XP.
local SHOWN_AFTER = 15 * 60
-- A break of under an hour, a /reload or a relog inside it, keeps the session going.
local SESSION_BREAK = HOUR
local MAX_LEVEL = 60
-- Records fall every few minutes early on, so chat names a new one only from level 10, and only
-- when it's at least a quarter above the last.
local CRIT_LEVEL = 10
local CRIT_STEP = 1.25

local PREFIX = "|cffe6b54aForever Levels:|r "

-- Retail's "secret" values can't be read: treat one as no value.
local function plain(v)
  if issecretvalue and issecretvalue(v) then return nil end
  return v
end

local db, character, show
-- The session as it's counted while logged in: when the open stretch began (GetTime()), and the
-- XP bar as last read.
local anchor, last

-- Text ----------------------------------------------------------------------------------------

local function thousands(n)
  local s = string.format("%d", math.floor(n + 0.5))
  local k
  repeat
    s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
  until k == 0
  return s
end

-- "19,000 XP an hour", to the nearest 100, as the guide writes it.
local function paceText(pace)
  return thousands(math.floor(pace / 100 + 0.5) * 100) .. " XP an hour"
end

-- As the guide writes hours: "~40 min" under an hour, to 5 minutes; "~1.5 h" under 10 h, to the
-- half hour; else "~16 h", to the hour.
local function hoursText(hours)
  if hours < 1 then
    local minutes = math.max(5, math.floor(hours * 60 / 5 + 0.5) * 5)
    return minutes >= 60 and "~1 h" or ("~" .. minutes .. " min")
  end
  if hours < 10 then
    local half = math.floor(hours * 2 + 0.5) / 2
    return "~" .. (half % 1 == 0 and string.format("%d", half) or string.format("%.1f", half)) .. " h"
  end
  return "~" .. string.format("%d", math.floor(hours + 0.5)) .. " h"
end

-- "1 h 52 min", "40 min", "2 d 3 h".
local function playedText(seconds)
  local minutes = math.floor(seconds / 60 + 0.5)
  local d, h, m = math.floor(minutes / 1440), math.floor(minutes / 60) % 24, minutes % 60
  if d > 0 then return h > 0 and (d .. " d " .. h .. " h") or (d .. " d") end
  if h > 0 then return m > 0 and (h .. " h " .. m .. " min") or (h .. " h") end
  return math.max(m, 1) .. " min"
end

local function say(text)
  DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

-- The session ---------------------------------------------------------------------------------

local function readBar()
  local level, xp, max = plain(UnitLevel("player")), plain(UnitXP("player")), plain(UnitXPMax("player"))
  if type(level) ~= "number" or type(xp) ~= "number" or type(max) ~= "number" then return end
  return { level = level, xp = xp, max = max }
end

-- The session's play that counts, the open stretch included while it's under 30 minutes.
local function sessionTime()
  local open = GetTime() - anchor
  return character.session.time + (open <= IDLE and open or 0)
end

local function sessionPace()
  local time, xp = sessionTime(), character.session.xp
  if time >= SHOWN_AFTER and xp > 0 then return xp / (time / HOUR) end
end

local function startSession()
  local now = time()
  local s = character.session
  if type(s) ~= "table" or type(s.lastSeen) ~= "number" or now - s.lastSeen >= SESSION_BREAK
    or type(s.time) ~= "number" or type(s.xp) ~= "number" then
    s = { time = 0, xp = 0 }
    character.session = s
  end
  s.lastSeen = now
  anchor = GetTime()
  last = readBar()
end

local function onXP()
  local now = readBar()
  if not now or not last then
    last = now
    return
  end
  local gained
  if now.level > last.level or now.xp < last.xp then
    -- A level gained: the rest of the old level, then what's into the new one.
    gained = (last.max - last.xp) + now.xp
  else
    gained = now.xp - last.xp
  end
  last = now
  if gained <= 0 then return end
  local t = GetTime()
  local s = character.session
  if t - anchor <= IDLE then s.time = s.time + (t - anchor) end
  anchor = t
  s.xp = s.xp + gained
  s.lastSeen = time()
end

-- Level-ups -----------------------------------------------------------------------------------

-- Called by ForeverLevels.lua at PLAYER_LEVEL_UP, with the seconds played at the level before, from
-- its /played reading, or none without a reply this login.
function ns.levelUp(level, atLevel)
  if not show or not show.levelUps or type(level) ~= "number" then return end
  -- A moment later, so the session's XP holds the level's last kill or quest.
  C_Timer.After(1, function()
    local parts = { "Level " .. level }
    if atLevel then parts[#parts + 1] = playedText(atLevel) .. " played at level " .. (level - 1) end
    local pace = sessionPace()
    if pace then parts[#parts + 1] = paceText(pace) .. " this session" end
    say(table.concat(parts, " · "))
  end)
end

-- Biggest crits -------------------------------------------------------------------------------
-- Forever closes the combat log to addons, so a crit is read from the hit the target takes, and
-- a crit heal from the heal the player takes, neither saying whose it was. Only out of a group
-- are they the player's own, or their pet's.

local function record(kind, amount, target)
  local crits = character.crits
  if type(crits) ~= "table" then
    crits = {}
    character.crits = crits
  end
  local old = crits[kind]
  local had = type(old) == "table" and type(old.amount) == "number"
  if had and amount <= old.amount then return end
  local level = plain(UnitLevel("player"))
  crits[kind] = { amount = amount, target = target, level = level }
  if not had or amount < old.amount * CRIT_STEP or type(level) ~= "number" or level < CRIT_LEVEL then return end
  if kind == "heal" then
    say("New biggest crit heal: " .. thousands(amount))
  else
    say("New biggest crit: " .. thousands(amount) .. (target and (" on " .. target) or ""))
  end
end

local function onCombat(unit, event, flag, amount)
  event, flag, amount = plain(event), plain(flag), plain(amount)
  if flag ~= "CRITICAL" or type(amount) ~= "number" or amount <= 0 or IsInGroup() then return end
  if unit == "target" and event == "WOUND" then
    if UnitIsUnit("target", "player") or not UnitCanAttack("player", "target") then return end
    local name = plain(UnitName("target"))
    record("damage", amount, type(name) == "string" and name ~= "" and name or nil)
  elseif unit == "player" and event == "HEAL" then
    record("heal", amount)
  end
end

-- The XP bar's tooltip ------------------------------------------------------------------------

local function line(tooltip, left, right)
  tooltip:AddDoubleLine(left, right, 1, 0.82, 0, 1, 1, 1)
end

local function addLines()
  if not character then return end
  local level = plain(UnitLevel("player"))
  local paceShown = show.pace and type(level) == "number" and level < MAX_LEVEL
  local crits = show.crits and type(character.crits) == "table" and character.crits or {}
  if not (paceShown or crits.damage or crits.heal) then return end
  local tooltip = GetAppropriateTooltip and GetAppropriateTooltip() or GameTooltip
  -- No tooltip without a rest state, so the lines make their own.
  if not tooltip:IsShown() then GameTooltip_SetDefaultAnchor(tooltip, UIParent) end
  tooltip:AddLine(" ")
  tooltip:AddLine("Forever Levels", 0.9, 0.71, 0.29)
  if paceShown then
    local pace = sessionPace()
    if pace then
      line(tooltip, "This session", paceText(pace))
      local bar = readBar()
      if bar and bar.max > bar.xp then
        line(tooltip, "Level " .. (bar.level + 1), hoursText((bar.max - bar.xp) / pace) .. " at this pace")
      end
    else
      tooltip:AddLine("XP an hour shows after 15 min of play this session", 0.7, 0.7, 0.7, true)
    end
  end
  if type(crits.damage) == "table" and type(crits.damage.amount) == "number" then
    local on = type(crits.damage.target) == "string" and (" on " .. crits.damage.target) or ""
    line(tooltip, "Biggest crit", thousands(crits.damage.amount) .. on)
  end
  if type(crits.heal) == "table" and type(crits.heal.amount) == "number" then
    line(tooltip, "Biggest crit heal", thousands(crits.heal.amount))
  end
  tooltip:Show()
end

-- Each of the two bar containers builds its own XP bar, and the XP bar moves to the second when a
-- reputation is watched, so both are hooked, each with its rested marker.
local hooked = {}
local function hookBars()
  local experience = StatusTrackingBarInfo and StatusTrackingBarInfo.BarsEnum
    and StatusTrackingBarInfo.BarsEnum.Experience
  if not experience then return end
  local containers = { MainStatusTrackingBarContainer or false, SecondaryStatusTrackingBarContainer or false }
  for _, container in ipairs(containers) do
    local bar = container and container.bars and container.bars[experience]
    if bar and not hooked[bar] then
      hooked[bar] = true
      bar:HookScript("OnEnter", addLines)
      if bar.ExhaustionTick then bar.ExhaustionTick:HookScript("OnEnter", addLines) end
    end
  end
end

-- Wiring --------------------------------------------------------------------------------------

local frame = CreateFrame("Frame")

local function listenForCrits()
  if show.crits then
    frame:RegisterUnitEvent("UNIT_COMBAT", "target", "player")
  else
    frame:UnregisterEvent("UNIT_COMBAT")
  end
end

local SETTINGS = {
  { key = "pace", name = "XP an hour",
    tooltip = "Your XP an hour this session, and the time to your next level at it, on the XP bar's tooltip." },
  { key = "levelUps", name = "Level-ups in chat",
    tooltip = "A line in chat at each level: the time you played at the level before, and your XP an hour." },
  { key = "crits", name = "Biggest crits",
    tooltip = "Your biggest crit and crit heal out of a group, on the XP bar's tooltip, and a line in chat"
      .. " when a new one is well above the last." },
}

local function registerSettings()
  if not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
  local category = Settings.RegisterVerticalLayoutCategory("Forever Levels")
  for _, s in ipairs(SETTINGS) do
    local setting = Settings.RegisterAddOnSetting(category, "ForeverLevels_" .. s.key, s.key, show,
      Settings.VarType.Boolean, s.name, Settings.Default.True)
    Settings.CreateCheckbox(category, setting, s.tooltip)
    if s.key == "crits" then setting:SetValueChangedCallback(listenForCrits) end
  end
  Settings.RegisterAddOnCategory(category)
end

function ns.loaded(saved)
  db = saved
  if type(db.show) ~= "table" then db.show = {} end
  show = db.show
  for _, s in ipairs(SETTINGS) do
    if type(show[s.key]) ~= "boolean" then show[s.key] = true end
  end
  pcall(registerSettings)
end

function ns.loggedIn(saved)
  if not show then return end
  character = saved
  startSession()
  frame:RegisterEvent("PLAYER_XP_UPDATE")
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")
  listenForCrits()
  hookBars()
end

-- Closes the open stretch, so a /reload or relog counts it and the break after it doesn't.
function ns.loggingOut()
  if not character then return end
  local s = character.session
  s.time = sessionTime()
  s.lastSeen = time()
end

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_XP_UPDATE" then
    if ... == "player" then onXP() end
  elseif event == "UNIT_COMBAT" then
    onCombat(...)
  elseif event == "PLAYER_ENTERING_WORLD" then
    hookBars()
  end
end)
