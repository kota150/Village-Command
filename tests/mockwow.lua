-- Minimal stand-in for the WoW API: enough for Village Command to load, log in, read a guild roster,
-- draw every page and make rank and note changes. Set PLAYER, REALM, INTERFACE or MY_RANK before loading
-- to vary a scenario; tests edit ROSTER and fire GUILD_ROSTER_UPDATE to simulate the guild changing.
frames={}
local function newObj(kind,name,parent)
  local o={__scripts={},__kind=kind,__name=name,__shown=true,__text='',__parent=parent,__checked=false,__scroll=0}
  return setmetatable(o,{__index=function(t,k)
    if k=='SetScript' then return function(self,ev,fn) self.__scripts[ev]=fn end end
    if k=='HookScript' then return function(self,ev,fn)
      local old=self.__scripts[ev]
      self.__scripts[ev]=old and function(...) old(...); fn(...) end or fn
    end end
    if k=='GetScript' then return function(self,ev) return self.__scripts[ev] end end
    if k=='CreateTexture' or k=='CreateFontString' then return function(self) return newObj('region',nil,self) end end
    if k=='SetText' then return function(self,v) self.__text=v end end
    if k=='GetText' then return function(self) return self.__text or '' end end
    if k=='Show' then return function(self) self.__shown=true; local f=self.__scripts.OnShow; if f then f(self) end end end
    if k=='Hide' then return function(self) self.__shown=false; local f=self.__scripts.OnHide; if f then f(self) end end end
    if k=='SetShown' then return function(self,v) if v then self:Show() else self:Hide() end end end
    if k=='IsShown' then return function(self) return self.__shown end end
    if k=='Enable' or k=='Disable' then return function(self) self.__disabled=(k=='Disable') end end
    if k=='SetEnabled' then return function(self,v) self.__disabled=not v end end
    if k=='IsEnabled' then return function(self) return not self.__disabled end end
    if k=='SetChecked' then return function(self,v) self.__checked=v and true or false end end
    if k=='GetChecked' then return function(self) return self.__checked end end
    if k=='Click' then return function(self) local f=self.__scripts.OnClick; if f then f(self,'LeftButton') end end end
    if k=='GetParent' then return function(self) return self.__parent end end
    if k=='GetVerticalScroll' then return function(self) return self.__scroll end end
    if k=='SetVerticalScroll' then return function(self,v) self.__scroll=v end end
    if k=='GetHeight' then return function() return 300 end end
    if k=='GetWidth' or k=='GetStringHeight' or k=='GetStringWidth' or k=='GetFrameLevel' or k=='GetEffectiveScale' then return function() return 10 end end
    if k=='GetCenter' then return function() return 0,0 end end
    if k=='HasFocus' or k=='IsOwned' then return function() return false end end
    if k=='GetNormalTexture' or k=='GetCheckedTexture' or k=='GetFontString' then return function(self) return newObj('region',nil,self) end end
    if k=='RegisterEvent' then return function(self,ev) if not KNOWN_EVENTS[ev] then error('Attempt to register unknown event "'..ev..'"') end end end
    return function() return nil end
  end})
end
KNOWN_EVENTS={}
for _,e in ipairs({'PLAYER_LOGIN','PLAYER_GUILD_UPDATE','GUILD_ROSTER_UPDATE','GUILD_RANKS_UPDATE','GUILD_MOTD','PLAYER_REGEN_ENABLED'}) do KNOWN_EVENTS[e]=true end
function CreateFrame(kind,name,parent)
  local f=newObj(kind,name,parent); frames[#frames+1]=f
  if name then _G[name]=f end
  return f
end
UIParent=newObj('Frame'); Minimap=newObj('Frame'); WorldFrame=newObj('Frame')
GameTooltip=newObj('GameTooltip')
BackdropTemplateMixin={}
UISpecialFrames={}
SlashCmdList=SlashCmdList or {}
tinsert=table.insert
function wipe(t) for k in pairs(t) do t[k]=nil end return t end
function GameTooltip_Hide() end
YES,NO,CANCEL='Yes','No','Cancel'
CLOCK=1762100000
function time() return math.floor(CLOCK) end
function date(fmt,t) return os.date(fmt,t or math.floor(CLOCK)) end
function GetTime() return CLOCK-1762000000 end
timers={}
C_Timer={After=function(s,fn) timers[#timers+1]={at=CLOCK+(s or 0),fn=fn} end}
function GetCursorPosition() return 0,0 end
function InCombatLockdown() return IN_COMBAT==true end
function GetCoinTextureString(c) return math.floor(c/10000)..'g' end
RAID_CLASS_COLORS={WARRIOR={r=.78,g=.61,b=.43},MAGE={r=.41,g=.8,b=.94},PRIEST={r=1,g=1,b=1},ROGUE={r=1,g=.96,b=.41},HUNTER={r=.67,g=.83,b=.45}}

-- Popups: a test can say no with DECLINE_POPUPS; otherwise every confirmation is accepted at once.
POPUPS={}
StaticPopupDialogs={}
function StaticPopup_Show(which,text,_,data)
  POPUPS[#POPUPS+1]={which=which,text=text}
  if DECLINE_POPUPS then return end
  StaticPopupDialogs[which].OnAccept({},data)
end
PRINTED={}
function print(s) PRINTED[#PRINTED+1]=tostring(s) end

ADDON_FOLDER=ADDON_FOLDER or 'VillageCommand'
C_AddOns={GetAddOnMetadata=function(name,field)
  if name~=ADDON_FOLDER then error('Couldn\'t find AddOn "'..tostring(name)..'"') end
  return '@project-version@'
end,IsAddOnLoaded=function(name) return LOADED_ADDONS and LOADED_ADDONS[name] or false end}

REALM=REALM or 'Living Flame'
PLAYER=PLAYER or 'Arcbinky'
function GetRealmName() return REALM end
function UnitName() return PLAYER,SURNAME end
function GetBuildInfo() return '1.15.0',1,'',INTERFACE or 11509 end
function GetMaxPlayerLevel() return 60 end

-- The guild ------------------------------------------------------------------------------------------
RANKS={'Guild Master','Officer','Veteran','Member','Initiate'}
MY_RANK=MY_RANK or 1
function IsInGuild() return true end
function GetGuildInfo() return 'Hidden Leaf',RANKS[MY_RANK+1],MY_RANK end
function GuildControlGetNumRanks() return #RANKS end
function GuildControlGetRankName(i) return RANKS[i] end
function GetGuildRosterMOTD() return 'Raid Friday at 8!' end
SHOW_OFFLINE=true
function GetGuildRosterShowOffline() return SHOW_OFFLINE end
function SetGuildRosterShowOffline(v) SHOW_OFFLINE=v end
ROSTER_REQUESTS=0
C_GuildInfo={GuildRoster=function() ROSTER_REQUESTS=ROSTER_REQUESTS+1 end}
local classes={{'Warrior','WARRIOR'},{'Mage','MAGE'},{'Priest','PRIEST'},{'Rogue','ROGUE'},{'Hunter','HUNTER'}}
local zones={'Orgrimmar','Stranglethorn Vale','Blackrock Mountain','Tanaris'}
ROSTER={}
-- Forever names never contain digits, so there "Member20" is "Memberca" (each digit becomes a letter).
function TESTNAME(base)
  if INTERFACE==16001 then return (base:gsub('%d',function(d) return string.char(97+tonumber(d)) end)) end
  return base
end
local function suffix(name) name=TESTNAME(name); if INTERFACE==16001 then return name end return name..'-'..REALM:gsub('%s','') end
ROSTER[1]={name=suffix(PLAYER),rank=MY_RANK,level=60,class=1,online=true,note='Main',onote='',zone=1}
for i=2,30 do
  ROSTER[i]={name=suffix('Member'..i),rank=(i<=3 and 2) or (i<=10 and 3) or 4,level=(i*7)%60+1,class=(i%5)+1,
    online=(i%3==0),note=(i%4==0) and ('Alt of Member'..(i-1)) or '',onote=(i%5==0) and 'Trial' or '',zone=(i%4)+1,away=i*86400}
end
ROSTER[2].rank=0
function GetNumGuildMembers() return #ROSTER end
function GetGuildRosterInfo(i)
  local m=ROSTER[i]
  if not m then return nil end
  local c=classes[m.class]
  return m.name,RANKS[m.rank+1],m.rank,m.level,c[1],m.online and zones[m.zone] or '',m.note,m.onote,m.online,0,c[2]
end
function GetGuildRosterLastOnline(i)
  local m=ROSTER[i]
  if not m or m.online then return nil end
  local days=math.floor((m.away or 0)/86400)
  return 0,0,days,0
end
local function find(name) for _,m in ipairs(ROSTER) do if m.name==name then return m end end end
CALLS={}
CAN={promote=true,demote=true,publicNote=true,officerNote=true,viewOfficer=true}
function CanGuildPromote() return CAN.promote end
function CanGuildDemote() return CAN.demote end
function CanEditPublicNote() return CAN.publicNote end
function CanEditOfficerNote() return CAN.officerNote end
function CanViewOfficerNote() return CAN.viewOfficer end
-- The server's rules: only for people below you, never to your rank or above, never below the lowest.
function GuildPromote(name)
  CALLS[#CALLS+1]='promote '..name
  local m=find(name)
  if m and m.rank-1>MY_RANK then m.rank=m.rank-1 else CALLS[#CALLS]=CALLS[#CALLS]..' REFUSED' end
end
function GuildDemote(name)
  CALLS[#CALLS+1]='demote '..name
  local m=find(name)
  if m and m.rank>MY_RANK and m.rank<#RANKS-1 then m.rank=m.rank+1 else CALLS[#CALLS]=CALLS[#CALLS]..' REFUSED' end
end
function GuildRosterSetPublicNote(i,text)
  if #text>31 then error('note too long') end
  CALLS[#CALLS+1]='note '..ROSTER[i].name..' '..text; ROSTER[i].note=text
end
function GuildRosterSetOfficerNote(i,text)
  if #text>31 then error('note too long') end
  CALLS[#CALLS+1]='onote '..ROSTER[i].name..' '..text; ROSTER[i].onote=text
end

-- Test helpers -------------------------------------------------------------------------------------
function VC_TEST_fire(event,...)
  for _,f in ipairs(frames) do
    local h=f.__scripts.OnEvent
    if h then h(f,event,...) end
  end
end
function VC_TEST_tick(seconds)
  local step=0.1
  for _=1,math.floor((seconds or 0.1)/step+.5) do
    CLOCK=CLOCK+step
    local due={}
    for i=#timers,1,-1 do if timers[i].at<=CLOCK then due[#due+1]=timers[i].fn; table.remove(timers,i) end end
    for _,fn in ipairs(due) do fn() end
    for _,f in ipairs(frames) do
      local h=f.__scripts.OnUpdate
      if h then h(f,step) end
    end
  end
end
