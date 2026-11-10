-- Village Command - guild overview and progression suite for Classic Era, WoW: Forever and retail.
-- Online members, the full roster with notes and officer notes, mass promote / demote / set rank / notes,
-- fun stats, progression tracking, and one window that ties in GuildForge (professions) and Un-Ninja Bank
-- (guild bank). Both are optional: their pages say how to get them when they aren't installed.
-- The release packager writes the git tag into the TOC; an unpackaged checkout still shows the placeholder.
-- Look the addon up by the folder WoW loaded it from: the modern lookup errors on an unknown name.
local addonName=...
local GetMetadata=(C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local VERSION
if GetMetadata and type(addonName)=='string' then
  local ok,value=pcall(GetMetadata,addonName,'Version')
  if ok then VERSION=value end
end
if type(VERSION)~='string' or VERSION:find('@',1,true) then VERSION='dev' end
VERSION=VERSION:gsub('^v','')
-- Note: wrap a call in extra parentheses before tonumber, tonumber((f())): many WoW functions return more
-- than one value, and a second value would be taken as tonumber's number base.
-- Helper functions live in one table: WoW's Lua allows at most 200 locals at the top of a file. It's the
-- addon's private table, which WoW passes in second (and the tests use to look inside).
local VC=select(2,...)
if type(VC)~='table' then VC={} end
VC.version=VERSION
local frame=CreateFrame('Frame')
local window, status, headerIcon, headerTitle, headerSub
local pageScroll, pageContent, rosterPage
local minimapButton
local BACKDROP_TEMPLATE=BackdropTemplateMixin and 'BackdropTemplate' or nil
-- The addon's icon: the guild tabard (minimap button, AddOns list, Options).
VC.ICON='Interface\\Icons\\INV_Shirt_GuildTabard_01'
-- A white circle (the portrait mask) so vertex colors show true; tinting a dark texture stays dark.
local DOT_TEXTURE='Interface\\CharacterFrame\\TempPortraitAlphaMask'
local CONTENT_W=826
local ROW_H=18
-- Guild notes hold 31 characters; counted in bytes here so accented letters never overflow.
local NOTE_MAX=31
local DAY=86400
local isSecret=function(value) return type(issecretvalue)=='function' and issecretvalue(value) end
local function now() return (time and time()) or 0 end
local function settings() return VillageCommandDB and VillageCommandDB.settings or {} end
local function log(s,always)
  if not always and settings().quiet then return end
  print('|cffd8aa55Village Command:|r '..tostring(s))
end
VC.log=log
local function later(seconds,fn)
  if C_Timer and C_Timer.After then C_Timer.After(seconds,fn) else fn() end
end
-- Plain text from the game: secret values (Midnight) and nil become ''.
local function clean(value)
  if value==nil or isSecret(value) then return '' end
  return tostring(value)
end
local updatePending, sinceUpdate, sinceRoster, sinceSample = false, 0, 0, 0
local rosterDirty, sinceRead = false, 0
local function requestRedraw() updatePending=true end
VC.requestRedraw=requestRedraw

-- Names ---------------------------------------------------------------------------------------------
-- The same rules GuildForge and Un-Ninja Bank use, so a character matches across all three addons.
local function realm() return (GetRealmName and GetRealmName()) or 'Unknown' end
VC.forever=(function() local iface=GetBuildInfo and select(4,GetBuildInfo()); return type(iface)=='number' and iface>=16000 and iface<17000 end)()
local function normalizeRealm(server) return (server or ''):gsub('[^%w]',''):lower() end
function VC.splitName(name)
  if type(name)~='string' or isSecret(name) or name=='' then return nil end
  local own=normalizeRealm(realm())
  local start=1
  while true do
    local dash=name:find('-',start,true)
    if not dash then break end
    if normalizeRealm(name:sub(dash+1))==own then name=name:sub(1,dash-1); break end
    start=dash+1
  end
  -- Forever: "First" plus an optional surname; a realm part always contains a digit there.
  if VC.forever then
    local parts={}
    for part in name:gmatch('[^%s%-]+') do
      if part:find('%d') or #parts==2 then break end
      parts[#parts+1]=part
    end
    if #parts==0 then return nil end
    return table.concat(parts,' '),realm()
  end
  local character,server=name:match('^([^-]+)%-(.+)$')
  if not character then return name,realm() end
  return character,server
end
function VC.nameId(name)
  local character,server=VC.splitName(name)
  if not character then return nil end
  if VC.forever then return (character:gsub('%s',''):lower()) end
  return character:gsub('%s',''):lower()..'-'..normalizeRealm(server)
end
-- "Bob" for your own realm, "Bob-Faerlina" for anyone from another realm; "Bob Smith" on Forever.
function VC.displayName(name)
  local character,server=VC.splitName(name)
  if not character then return clean(name) end
  if normalizeRealm(server)==normalizeRealm(realm()) then return character end
  return character..'-'..server:gsub('%s','')
end
function VC.myId()
  local name,surname
  if UnitName then name,surname=UnitName('player') end
  if not name or isSecret(name) then return nil end
  -- Forever: UnitName's second value is the surname, and guildmates see "First Surname".
  if VC.forever and type(surname)=='string' and not isSecret(surname) and surname~='' then name=name..' '..surname end
  return VC.nameId(name)
end

-- Saved data ----------------------------------------------------------------------------------------
function VC.initDB()
  VillageCommandDB=VillageCommandDB or {}
  local d=VillageCommandDB
  d.guilds=d.guilds or {}
  d.minimap=d.minimap or {angle=225,hide=false}
  d.ui=d.ui or {}
  if not d.ui.tab then d.ui.tab='overview' end
  d.ui.sort=d.ui.sort or {key='rank',desc=false}
  if d.ui.climbDays==nil then d.ui.climbDays=7 end
  d.settings=d.settings or {}
  local s=d.settings
  if s.scale==nil then s.scale=1 end
  if s.quiet==nil then s.quiet=false end
  if s.history==nil then s.history=true end
  if s.confirm==nil then s.confirm=true end
  -- Seconds between rank or note changes in a mass action; the server drops changes sent too quickly.
  if s.throttle==nil then s.throttle=0.6 end
  -- Celebrations when a guildmate levels up: a message at these levels, a big one at the level cap.
  if s.celebrate==nil then s.celebrate=true end
  if s.celebrateLevels==nil then s.celebrateLevels='20, 40, 50' end
  if s.celebrateCap==nil then s.celebrateCap=true end
  if s.celebrateSound==nil then s.celebrateSound=true end
  -- History sync with guildmates running Village Command, and whose word is taken on its own.
  if s.share==nil then s.share=true end
  if s.trustRank==nil then s.trustRank=1 end
  -- Promote helper: how many /gpromote lines one click carries.
  if s.batch==nil then s.batch=5 end
end
function VC.guildName()
  if not (IsInGuild and IsInGuild()) then return nil end
  local name=GetGuildInfo and GetGuildInfo('player')
  if type(name)~='string' or isSecret(name) or name=='' then return nil end
  return name
end
-- History is kept per guild; Forever has no realms that matter, so its guilds are keyed by name alone.
function VC.guildKey()
  local name=VC.guildName()
  if not name then return nil end
  if VC.forever then return name end
  return name..' - '..realm()
end
function VC.guildData()
  local k=VC.guildKey()
  if not (k and VillageCommandDB) then return nil end
  local g=VillageCommandDB.guilds[k]
  if not g then
    g={members={},events={},hours={},peak={n=0,t=0}}
    VillageCommandDB.guilds[k]=g
  end
  return g
end

-- Roster --------------------------------------------------------------------------------------------
VC.roster, VC.byId, VC.selected = {}, {}, {}
VC.rosterHasOffline=false
function VC.requestRoster()
  if VC.paused and VC.paused() then return end
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
  elseif GuildRoster then GuildRoster() end
end
-- Seconds since a member was last online, from the roster's years/months/days/hours.
local function awayFor(i)
  if not GetGuildRosterLastOnline then return nil end
  local years,months,days,hours=GetGuildRosterLastOnline(i)
  if isSecret(years) or not tonumber(years) then return nil end
  return ((((years*365)+(tonumber(months) or 0)*30+(tonumber(days) or 0))*24)+(tonumber(hours) or 0))*3600
end
-- One roster entry as a member table, or nil for an entry without a usable name.
function VC.readMember(i)
  local name,rankName,rankIndex,level,class,zone,note,officerNote,online,_,classFile,points,_,mobile,_,_,guid=GetGuildRosterInfo(i)
  local id=VC.nameId(name)
  if not id then return nil end
  local m={index=i,name=name,id=id,short=VC.displayName(name),rank=clean(rankName),
    rankIndex=tonumber(not isSecret(rankIndex) and rankIndex) or 0,level=tonumber(not isSecret(level) and level) or 0,
    class=clean(class),classFile=clean(classFile),zone=clean(zone),note=clean(note),officerNote=clean(officerNote),
    online=(online and not isSecret(online)) and true or false,mobile=mobile and not isSecret(mobile) and true or nil,
    points=tonumber(not isSecret(points) and points),guid=(type(guid)=='string' and not isSecret(guid)) and guid or nil}
  if m.online then m.away=0 else m.away=awayFor(i) end
  return m
end
function VC.readRoster()
  local list,byId={},{}
  VC.rosterHasOffline=false
  VC.badEntries=0
  if IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo then
    for i=1,(tonumber((GetNumGuildMembers())) or 0) do
      -- An entry the game hands back oddly is skipped (and reported once), never the whole roster.
      local ok,m=pcall(VC.readMember,i)
      if not ok then
        VC.badEntries=VC.badEntries+1
        VC.reportError('roster entry '..i..': '..tostring(m))
      elseif m and not byId[m.id] then
        if not m.online then VC.rosterHasOffline=true end
        list[#list+1]=m; byId[m.id]=m
      end
    end
  end
  VC.roster,VC.byId=list,byId
  for id in pairs(VC.selected) do if not byId[id] then VC.selected[id]=nil end end
  if VC.focus and not byId[VC.focus] then VC.focus=nil end
  VC.filterDirty=true
  VC.rosterReadAt=now()
end
-- The roster can be trusted for who left only when it includes offline members.
function VC.rosterComplete()
  return #VC.roster>0 and (VC.rosterHasOffline or (GetGuildRosterShowOffline and GetGuildRosterShowOffline()) and true or false)
end
function VC.onlineCount()
  local n=0
  for _,m in ipairs(VC.roster) do if m.online then n=n+1 end end
  return n
end
-- The roster index of a member right now: it shifts as the roster re-sorts, so look it up just before acting.
function VC.indexOf(id)
  if not (GetNumGuildMembers and GetGuildRosterInfo) then return nil end
  for i=1,(tonumber((GetNumGuildMembers())) or 0) do
    if VC.nameId((GetGuildRosterInfo(i)))==id then return i end
  end
end
function VC.maxLevel()
  for _,fn in ipairs({GetMaxLevelForPlayerExpansion,GetMaxPlayerLevel}) do
    if type(fn)=='function' then
      local ok,v=pcall(fn)
      if ok and tonumber(v) and v>0 then return tonumber(v) end
    end
  end
  return tonumber(MAX_PLAYER_LEVEL) or 60
end
function VC.classColor(classFile)
  local c=RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile or '']
  if c then return c.r,c.g,c.b end
  return .75,.75,.75
end
function VC.colorName(m)
  local r,g,b=VC.classColor(m.classFile)
  return string.format('|cff%02x%02x%02x%s|r',r*255,g*255,b*255,m.short or '?')
end

-- Ranks and permissions -----------------------------------------------------------------------------
-- Rank 0 is the guild master; higher numbers are lower ranks.
function VC.rankNames()
  local names={}
  local n=GuildControlGetNumRanks and tonumber((GuildControlGetNumRanks())) or 0
  for i=1,n do
    local ok,name=pcall(GuildControlGetRankName,i)
    if ok and type(name)=='string' and not isSecret(name) then names[i-1]=name end
  end
  for _,m in ipairs(VC.roster) do if not names[m.rankIndex] and m.rank~='' then names[m.rankIndex]=m.rank end end
  return names
end
function VC.lowestRank()
  local low=0
  for i in pairs(VC.rankNames()) do if i>low then low=i end end
  return low
end
function VC.myRankIndex()
  if not GetGuildInfo then return nil end
  local _,_,index=GetGuildInfo('player')
  if isSecret(index) then return nil end
  return tonumber(index)
end
local function anyTrue(...)
  for i=1,select('#',...) do
    local fn=select(i,...)
    if type(fn)=='function' then
      local ok,v=pcall(fn)
      if ok and not isSecret(v) then return v and true or false end
    end
  end
  return false
end
-- Actions the game keeps for its own guild window. Each version of the game differs, and Blizzard changes it,
-- so Village Command learns it: when the game blocks one of its calls (ADDON_ACTION_FORBIDDEN / _BLOCKED) it
-- remembers that for this version of the game and stops offering it. 'all' means never from an addon;
-- 'mass' means only one member at a time, straight from a click.
VC.flavor=(function()
  if VC.forever then return 'forever' end
  local iface=GetBuildInfo and tonumber((select(4,GetBuildInfo()))) or 0
  if iface>=100000 then return 'retail' end
  return 'classic'
end)()
-- Already known, so nobody has to see the game's popup to find out. WoW Forever (tested in game, Nov 2026)
-- keeps every rank and note change for its own guild window, even one member from a click.
VC.knownBlocked={forever={officerNote='all',publicNote='all',promote='all',demote='all'}}
VC.features={promote='promoting',demote='demoting',publicNote='public notes',officerNote='officer notes'}
function VC.blockedSaved()
  if not VillageCommandDB then return {} end
  VillageCommandDB.blocked=VillageCommandDB.blocked or {}
  VillageCommandDB.blocked[VC.flavor]=VillageCommandDB.blocked[VC.flavor] or {}
  return VillageCommandDB.blocked[VC.flavor]
end
function VC.blockLevel(feature)
  return VC.blockedSaved()[feature] or (VC.knownBlocked[VC.flavor] or {})[feature]
end
function VC.markBlocked(feature,level)
  if VC.blockLevel(feature)=='all' then return end
  VC.blockedSaved()[feature]=level
end
VC.GUILD_WINDOW_HINT='Use the game\'s guild window instead (Guild & Communities, J).'
-- True when the game lets addons change no ranks or notes at all: the roster is for looking, not editing.
VC.TICK_HINT='Tick members (or shift-click a range) to promote, demote or note many at once'
VC.LOCKED_TEXT='Notes change in the guild window (J); promote from the checklist with the Promote helper.'
function VC.gameLocked()
  for feature in pairs(VC.features) do if VC.blockLevel(feature)~='all' then return false end end
  return true
end
function VC.blockedWhy(feature,mass)
  local level=VC.blockLevel(feature)
  if level=='all' then return 'This version of WoW only lets its own guild window change '..VC.features[feature]..'. '..VC.GUILD_WINDOW_HINT end
  if level=='mass' and mass then return 'This version of WoW only allows '..VC.features[feature]..' one member at a time: click a member and use the editor below the list.' end
end
-- What your rank may do, less what the game keeps for itself. mass: for a queued change to several members.
-- perms.why[feature] says why something is off when the game, not your rank, is the reason.
function VC.perms(mass)
  local CG=C_GuildInfo or {}
  local p={
    promote=anyTrue(CanGuildPromote,CG.CanGuildPromote),
    demote=anyTrue(CanGuildDemote,CG.CanGuildDemote),
    publicNote=anyTrue(CanEditPublicNote,CG.CanEditPublicNote),
    officerNote=anyTrue(CanEditOfficerNote,CG.CanEditOfficerNote),
    viewOfficer=anyTrue(CanViewOfficerNote,CG.CanViewOfficerNote),
    why={},
  }
  for feature in pairs(VC.features) do
    local why=p[feature] and VC.blockedWhy(feature,mass)
    if why then p[feature]=false; p.why[feature]=why end
  end
  return p
end
-- The reason an action is off: the game's, if it's the game; otherwise your rank's.
function VC.deny(perms,feature,rankText) return perms.why[feature] or rankText end
-- Whether one step up (dir 1) or down (dir -1) from rank `from` is allowed; false plus the reason if not.
-- You can only move people who rank below you, and never to your own rank or above.
function VC.canStep(m,from,dir,perms)
  perms=perms or VC.perms()
  local me=VC.myRankIndex()
  if not me then return false,'Your guild rank isn\'t known yet' end
  if m.id==VC.myId() then return false,'You can\'t change your own rank' end
  if dir>0 then
    if not perms.promote then return false,VC.deny(perms,'promote','Your rank can\'t promote') end
    if from-1<=me then return false,'Already as high as you can promote' end
  else
    if not perms.demote then return false,VC.deny(perms,'demote','Your rank can\'t demote') end
    if from<=me then return false,'Ranked at or above you' end
    if from>=VC.lowestRank() then return false,'Already the lowest rank' end
  end
  return true
end
local function callFirst(args,...)
  for i=1,select('#',...) do
    local fn=select(i,...)
    if type(fn)=='function' then return pcall(fn,unpack(args)) end
  end
  return false,'This version of the game has no way for addons to do that'
end
-- What Village Command last asked the game to do, so a blocked-action event can be pinned on the right feature.
function VC.calling(feature) VC.lastCall={feature=feature,click=VC.inClick and true or false} end
function VC.stepRank(m,dir)
  local CG=C_GuildInfo or {}
  VC.calling(dir>0 and 'promote' or 'demote')
  if dir>0 then return callFirst({m.name},GuildPromote,CG.Promote) end
  return callFirst({m.name},GuildDemote,CG.Demote)
end
-- Notes are written by roster index on Classic, by GUID on retail.
function VC.writeNote(m,text,officer)
  local index=VC.indexOf(m.id)
  VC.calling(officer and 'officerNote' or 'publicNote')
  if officer and GuildRosterSetOfficerNote and index then return pcall(GuildRosterSetOfficerNote,index,text) end
  if not officer and GuildRosterSetPublicNote and index then return pcall(GuildRosterSetPublicNote,index,text) end
  if C_GuildInfo and C_GuildInfo.SetNote and m.guid then return pcall(C_GuildInfo.SetNote,m.guid,text,not officer) end
  if not index then return false,'Not in the roster any more' end
  return false,'This version of the game has no way for addons to set notes'
end
-- Fits a note to 31 bytes without cutting a multi-byte letter in half; drops line breaks and pipes.
function VC.trimNote(text)
  text=tostring(text or ''):gsub('[\r\n|]',' ')
  if #text<=NOTE_MAX then return text end
  text=text:sub(1,NOTE_MAX)
  local i=#text
  while i>1 and text:byte(i)>=128 and text:byte(i)<192 do i=i-1 end
  local lead=text:byte(i)
  local need=(lead>=240 and 4) or (lead>=224 and 3) or (lead>=192 and 2) or 1
  if #text-i+1<need then text=text:sub(1,i-1) end
  return text
end
-- {date} {level} {rank} {class} {name} in a mass note become each member's own values.
function VC.expandNote(template,m)
  local today=date and date('%m/%d') or ''
  local values={date=today,level=tostring(m.level or ''),rank=m.rank or '',class=m.class or '',name=m.short or ''}
  return (tostring(template or ''):gsub('{(%a+)}',function(word) return values[word:lower()] end))
end
VC.noteModes={
  {key='replace',label='Replace'},
  {key='append',label='Add to end'},
  {key='prepend',label='Add to start'},
  {key='clear',label='Clear'},
}
function VC.composeNote(old,template,mode,m)
  local add=VC.expandNote(template,m)
  old=old or ''
  if mode=='clear' then return '' end
  if mode=='append' then return VC.trimNote(old~='' and (old..' '..add) or add) end
  if mode=='prepend' then return VC.trimNote(old~='' and (add..' '..old) or add) end
  return VC.trimNote(add)
end

-- Mass actions --------------------------------------------------------------------------------------
-- Rank and note changes run one at a time, a moment apart, so the server takes every one of them.
VC.queue={list={},pos=0,done=0,failed=0,skipped=0,wait=0}
function VC.busy() return VC.queue.pos<#VC.queue.list end
-- Jobs: {kind='step', id=, dir=1|-1, from=rankIndex} or {kind='note', id=, officer=bool, text=}.
function VC.startJobs(label,jobs)
  if #jobs==0 then log('Nothing to do: '..label..'.',true); return end
  if VC.busy() then log('Still working on '..VC.queue.label..'. Wait for it or cancel it first.',true); return end
  VC.queue={list=jobs,pos=0,done=0,failed=0,skipped=0,wait=0,label=label,errors={}}
  log('Started: '..label..' ('..#jobs..' change'..(#jobs==1 and '' or 's')..').',true)
  requestRedraw()
end
function VC.cancelJobs()
  if not VC.busy() then return end
  local left=#VC.queue.list-VC.queue.pos
  VC.queue.list={unpack(VC.queue.list,1,VC.queue.pos)}
  log('Cancelled '..VC.queue.label..'; '..left..' change'..(left==1 and '' or 's')..' not made.',true)
  VC.finishJobs()
end
function VC.runJob(job,single)
  local m=VC.byId[job.id]
  if not m then return 'skip','left the guild' end
  if job.kind=='step' then
    local ok,why=VC.canStep(m,job.from,job.dir,VC.perms(not single))
    if not ok then return 'skip',why end
    local done,err=VC.stepRank(m,job.dir)
    if not done then return 'fail',err end
    -- The roster catches up a moment later; keep the local copy right for the rest of the queue.
    m.rankIndex=job.from-job.dir
    return 'ok'
  elseif job.kind=='note' then
    local perms=VC.perms(not single)
    if job.officer and not perms.officerNote then return 'skip',VC.deny(perms,'officerNote','Your rank can\'t edit officer notes') end
    if not job.officer and not perms.publicNote then return 'skip',VC.deny(perms,'publicNote','Your rank can\'t edit public notes') end
    local done,err=VC.writeNote(m,job.text,job.officer)
    if not done then return 'fail',err end
    if job.officer then m.officerNote=job.text else m.note=job.text end
    return 'ok'
  end
  return 'skip','unknown change'
end
function VC.tickJobs(elapsed)
  local q=VC.queue
  if not VC.busy() then return end
  q.wait=q.wait-elapsed
  if q.wait>0 then return end
  -- Wait out combat: nothing here is protected, but a fight is no time for a hundred roster changes.
  if InCombatLockdown and InCombatLockdown() then q.wait=1; return end
  q.pos=q.pos+1
  local job=q.list[q.pos]
  VC.inJob=true
  local ok,result,why=pcall(VC.runJob,job)
  VC.inJob=false
  if not ok then result,why='fail',result end
  local blocked=VC.blockedNow
  if blocked then result,why='fail','blocked by the game'; VC.blockedNow=nil end
  q.last=result
  if result=='ok' then q.done=q.done+1
  elseif result=='fail' then q.failed=q.failed+1; q.errors[#q.errors+1]=(VC.byId[job.id] and VC.byId[job.id].short or job.id)..': '..tostring(why)
  else q.skipped=q.skipped+1; q.errors[#q.errors+1]=(VC.byId[job.id] and VC.byId[job.id].short or job.id)..': '..tostring(why) end
  q.wait=math.max(.2,tonumber(settings().throttle) or .6)
  if blocked and VC.busy() then
    local left=#q.list-q.pos
    q.skipped=q.skipped+left; q.list={unpack(q.list,1,q.pos)}; q.blockedAt=q.pos
  end
  if not VC.busy() then VC.finishJobs() end
  requestRedraw()
end
function VC.finishJobs()
  local q=VC.queue
  log(string.format('%s finished: %d done, %d skipped, %d failed.',q.label or 'Changes',q.done,q.skipped,q.failed),true)
  for i=1,math.min(#(q.errors or {}),5) do log('   '..q.errors[i],true) end
  if #(q.errors or {})>5 then log('   and '..(#q.errors-5)..' more.',true) end
  later(1.5,VC.requestRoster)
  requestRedraw()
end
-- One member, straight from the click: the game allows some changes only during a click, never from a queue.
-- Several steps (set rank) still go through the queue.
function VC.runNow(label,jobs)
  if #jobs~=1 then VC.startJobs(label,jobs); return end
  if VC.busy() then log('Still working on '..VC.queue.label..'. Wait for it or cancel it first.',true); return end
  VC.inClick=true; VC.inJob=true
  local ok,result,why=pcall(VC.runJob,jobs[1],true)
  VC.inClick=false; VC.inJob=false
  if VC.blockedNow then VC.blockedNow=nil -- already explained in chat
  elseif not ok then log(label..' failed: '..tostring(result),true)
  elseif result=='ok' then log(label..'.',true)
  else log(label..': '..tostring(why),true) end
  later(1.5,VC.requestRoster)
  requestRedraw()
end
-- The game blocked a call of ours. Stop, remember it for this version of the game, and say what to do instead;
-- the roster is read again so nothing shows a change that didn't happen. The game may report it during the
-- call (then tickJobs / runNow finish the bookkeeping) or a moment after (then it's done here).
function VC.onBlocked(event,fn)
  local call=VC.lastCall
  if not call then return end
  VC.lastCall=nil
  local level=(event=='ADDON_ACTION_FORBIDDEN' or call.click) and 'all' or 'mass'
  VC.markBlocked(call.feature,level)
  VC.blockedNow=call.feature
  log('The game blocked '..VC.features[call.feature]..' ('..tostring(fn or '?')..'). '..(VC.blockedWhy(call.feature,true) or '')..' Village Command won\'t try that again on this version of the game.',true)
  if not VC.inJob then VC.stopForBlock() end
  later(1,VC.requestRoster); VC.readSoon(true)
  requestRedraw()
end
-- Every block the game blames on Village Command, whatever caused it, with the function the game names, how
-- often, and whether it was in combat: /vc blocked lists them so a stray one can be tracked down.
VC.blockLog={}
function VC.noteBlocked(event,fn)
  local key=(event=='ADDON_ACTION_FORBIDDEN' and 'forbidden ' or 'blocked ')..tostring(fn or '?')
  local e=VC.blockLog[key] or {n=0}
  VC.blockLog[key]=e
  e.n=e.n+1; e.at=now(); e.combat=(InCombatLockdown and InCombatLockdown()) and true or false
  e.page=window and window:IsShown() and VillageCommandDB and VillageCommandDB.ui and VillageCommandDB.ui.tab or nil
  if e.n==1 and VC.ready and not VC.lastCall then
    log('The game blocked '..tostring(fn or 'an action')..(e.combat and ' in combat' or '')..' and blamed Village Command. /vc blocked lists these; please send what it says.',true)
  end
end
function VC.printBlocked()
  local keys={}
  for k in pairs(VC.blockLog) do keys[#keys+1]=k end
  table.sort(keys,function(a,b) return VC.blockLog[a].n>VC.blockLog[b].n end)
  if #keys==0 then log('The game hasn\'t blocked anything from Village Command since you logged in.',true); return end
  for _,k in ipairs(keys) do
    local e=VC.blockLog[k]
    log(string.format('%s: %d time%s, last %ds ago%s%s',k,e.n,e.n==1 and '' or 's',now()-(e.at or now()),e.combat and ', in combat' or '',e.page and (', on '..tostring(e.page)) or ''),true)
  end
end
-- The change that was blocked counts as failed, and nothing else in the queue is tried.
function VC.stopForBlock()
  local q=VC.queue
  VC.blockedNow=nil
  if q.blockedAt or (q.pos or 0)==0 then return end
  local wasBusy=VC.busy()
  if q.last=='ok' then q.done=q.done-1; q.failed=q.failed+1; q.last='fail' end
  q.blockedAt=q.pos
  local left=#q.list-q.pos
  if left>0 then q.skipped=q.skipped+left; q.list={unpack(q.list,1,q.pos)} end
  if wasBusy then VC.finishJobs() end
end
-- Selected members in roster order (rank, then name) so a mass action reads the way the list does.
function VC.selectedMembers()
  local list={}
  for _,m in ipairs(VC.roster) do if VC.selected[m.id] then list[#list+1]=m end end
  table.sort(list,function(a,b) if a.rankIndex~=b.rankIndex then return a.rankIndex<b.rankIndex end return a.short<b.short end)
  return list
end
-- One step per member for promote/demote; several for "set rank", walking one rank at a time.
function VC.rankJobs(members,dir,target,single)
  local jobs,skipped,perms={},{},VC.perms(not single)
  for _,m in ipairs(members) do
    local from=m.rankIndex
    local goal=target or (from-dir)
    local step=goal<from and 1 or -1
    if goal==from then skipped[#skipped+1]=m.short..': already that rank'
    else
      local ok,why=VC.canStep(m,from,step,perms)
      -- Check the whole walk up front so nobody ends up half way.
      local at=from
      while ok and at~=goal do ok,why=VC.canStep(m,at,step,perms); at=at-step end
      if ok then
        at=from
        while at~=goal do jobs[#jobs+1]={kind='step',id=m.id,dir=step,from=at}; at=at-step end
      else skipped[#skipped+1]=m.short..': '..why end
    end
  end
  return jobs,skipped
end
function VC.noteJobs(members,template,mode,officer)
  local jobs={}
  for _,m in ipairs(members) do
    local old=officer and m.officerNote or m.note
    local text=VC.composeNote(old,template,mode,m)
    if text~=old then jobs[#jobs+1]={kind='note',id=m.id,officer=officer,text=text} end
  end
  return jobs
end
-- Asks first (unless confirmations are off), naming the first few people the change touches.
function VC.confirm(question,members,run)
  if not settings().confirm then run(); return end
  local names={}
  for i=1,math.min(#members,6) do names[i]=members[i].short end
  local who=table.concat(names,', ')..(#members>6 and (' and '..(#members-6)..' more') or '')
  VC.ask(question..'\n\n'..who,run)
end
function VC.massRank(dir,target,targetName)
  local members=VC.selectedMembers()
  if #members==0 then log('Select members first: tick them in the roster.',true); return end
  local jobs,skipped=VC.rankJobs(members,dir,target)
  if #jobs==0 then
    log('No one selected can be changed:',true)
    for i=1,math.min(#skipped,5) do log('   '..skipped[i],true) end
    return
  end
  local verb=target and ('Set '..#members..' member'..(#members==1 and '' or 's')..' to '..(targetName or 'that rank'))
    or ((dir>0 and 'Promote ' or 'Demote ')..#members..' member'..(#members==1 and '' or 's'))
  local extra=#skipped>0 and ('\n|cffff8040'..#skipped..' can\'t be changed and will be skipped.|r') or ''
  VC.confirm(verb..'?'..extra,members,function()
    for i=1,math.min(#skipped,5) do log('Skipping '..skipped[i],true) end
    VC.startJobs(verb,jobs)
  end)
end
function VC.massNote(template,mode,officer)
  local members=VC.selectedMembers()
  if #members==0 then log('Select members first: tick them in the roster.',true); return end
  local perms=VC.perms(true)
  if officer and not perms.officerNote then log(VC.deny(perms,'officerNote','Your rank can\'t edit officer notes.'),true); return end
  if not officer and not perms.publicNote then log(VC.deny(perms,'publicNote','Your rank can\'t edit public notes.'),true); return end
  local jobs=VC.noteJobs(members,template,mode,officer)
  local what=(officer and 'officer note' or 'public note')
  if #jobs==0 then log('Every selected '..what..' already reads that way.',true); return end
  VC.confirm('Change the '..what..' of '..#jobs..' member'..(#jobs==1 and '' or 's')..'?',members,function()
    VC.startJobs('Set '..what..'s',jobs)
  end)
end

-- History and progression -------------------------------------------------------------------------
-- Village Command watches the roster and remembers levels, ranks, joins and leaves, so progression and
-- stats grow the longer it runs. Nothing is shared over the network: it's what this client has seen.
-- id and v (the level or rank index) let an event be shared with guildmates and rebuilt in their words.
function VC.event(g,kind,name,detail,id,v)
  g.events[#g.events+1]={t=now(),k=kind,n=name,d=detail,id=id,v=v}
  while #g.events>400 do table.remove(g.events,1) end
end
function VC.track()
  local g=VC.guildData()
  if not g or #VC.roster==0 or not settings().history then return end
  local t,maxLevel=now(),VC.maxLevel()
  local logJoins=g.baseline~=nil
  local names=VC.rankNames()
  for _,m in ipairs(VC.roster) do
    local rec=g.members[m.id]
    if not rec then
      rec={first=t,levels={{t,m.level}}}
      g.members[m.id]=rec
      if logJoins then VC.event(g,'join',m.short,'joined at level '..m.level,m.id,m.level) end
    else
      local was=rec.level or m.level
      -- A level can only drop through bad data (a renamed or re-rolled character); start its history over.
      if m.level<was then rec.levels={{t,m.level}}; was=m.level end
      if m.level>was then
        for lvl=was+1,m.level do
          if lvl%10==0 or lvl==maxLevel then VC.event(g,'ding',m.short,lvl==maxLevel and ('hit the level cap ('..lvl..')') or ('reached level '..lvl),m.id,lvl) end
        end
        rec.levels=rec.levels or {}
        rec.levels[#rec.levels+1]={t,m.level}
        while #rec.levels>40 do table.remove(rec.levels,1) end
      end
      if rec.rank and m.rankIndex~=rec.rank then
        VC.event(g,m.rankIndex<rec.rank and 'promote' or 'demote',m.short,(m.rankIndex<rec.rank and 'promoted to ' or 'demoted to ')..(names[m.rankIndex] or m.rank),m.id,m.rankIndex)
      end
    end
    rec.level,rec.rank,rec.name,rec.class=m.level,m.rankIndex,m.short,m.classFile
    if m.online then rec.seen=t elseif m.away then rec.seen=math.max(rec.seen or 0,t-m.away) end
  end
  if VC.rosterComplete() then
    if logJoins then
      local known=0
      for _ in pairs(g.members) do known=known+1 end
      -- A half-loaded roster isn't half the guild leaving.
      if #VC.roster>=known*.5 then
        for id,rec in pairs(g.members) do
          if not VC.byId[id] then VC.event(g,'leave',rec.name or id,'left the guild',id); g.members[id]=nil end
        end
      end
    end
    g.baseline=g.baseline or t
  end
end
-- Every few minutes: how many are online at this hour, for "busiest hour" and the peak record.
function VC.sample()
  local g=VC.guildData()
  if not g or #VC.roster==0 or not settings().history then return end
  local online=VC.onlineCount()
  local hour=tonumber(date and date('%H')) or 0
  local slot=g.hours[hour] or {s=0,n=0}
  slot.s,slot.n=slot.s+online,slot.n+1
  g.hours[hour]=slot
  -- By weekday too, for the weekly rhythm heat map: key weekday*24+hour, Sunday = 0.
  local wday=tonumber(date and date('%w')) or 0
  g.week=g.week or {}
  local w=g.week[wday*24+hour] or {s=0,n=0}
  w.s,w.n=w.s+online,w.n+1
  g.week[wday*24+hour]=w
  if online>(g.peak.n or 0) then g.peak={n=online,t=now()} end
  for _,m in ipairs(VC.roster) do
    local rec=m.online and g.members[m.id]
    if rec then
      rec.on=(rec.on or 0)+1
      if hour<5 then rec.night=(rec.night or 0)+1 elseif hour<9 then rec.dawn=(rec.dawn or 0)+1 end
    end
  end
end
function VC.resetStats()
  local k=VC.guildKey()
  if k and VillageCommandDB then VillageCommandDB.guilds[k]=nil end
  VC.track(); requestRedraw()
  log('Statistics reset for this guild.',true)
end
-- Celebrations ----------------------------------------------------------------------------------------
-- When the roster shows a guildmate passed one of the chosen levels since this session first saw them, the
-- screen says so: a raid-warning style message, or a big banner with fireworks for the level cap. Only
-- level-ups seen this session count, so logging in doesn't replay old news. Nothing is sent to anyone.
VC.sessionLevel={}
function VC.celebrationLevels()
  local set={}
  for n in tostring(settings().celebrateLevels or ''):gmatch('%d+') do set[tonumber(n)]=true end
  return set
end
function VC.checkDings()
  local s=settings()
  local maxLevel,levels=VC.maxLevel(),VC.celebrationLevels()
  for _,m in ipairs(VC.roster) do
    local was=VC.sessionLevel[m.id]
    if was and m.level>was and s.celebrate then
      -- One celebration per member per update: the biggest level they passed.
      local best,big
      for lvl=was+1,m.level do
        if lvl==maxLevel and s.celebrateCap then best,big=lvl,true
        elseif levels[lvl] and not big then best=lvl end
      end
      if best then VC.celebrate(m,best,big) end
    end
    VC.sessionLevel[m.id]=m.level
  end
end
local function playSound(kit,fallback)
  if not settings().celebrateSound or not PlaySound then return end
  local id=(SOUNDKIT and SOUNDKIT[kit]) or fallback
  if id then pcall(PlaySound,id,'Master') end
end
function VC.celebrate(m,level,big)
  log(VC.colorName(m)..' reached level '..level..'!'..(big and ' The whole village salutes you!' or ' Congratz!'),true)
  if big then VC.bigCelebration(m,level); return end
  VC.shout(VC.colorName(m)..' |cffffd100reached level '..level..'! Congratz!|r')
  playSound('RAID_WARNING',8959)
end
-- Raid-warning style text in a frame of our own. Writing into Blizzard's RaidWarningFrame taints it, and
-- then the game blocks its own boss and raid warnings in combat and blames Village Command.
local SHOUT_TIME=6
function VC.shout(text)
  local f=VC.shoutFrame
  if not f then
    f=CreateFrame('Frame','VillageCommandShout',UIParent)
    VC.shoutFrame=f
    f:SetSize(800,90); f:SetPoint('TOP',0,-180); f:SetFrameStrata('HIGH')
    f:EnableMouse(false)
    f.lines={}
    for i=1,3 do
      local t=f:CreateFontString(nil,'OVERLAY','GameFontNormalHuge'); t:SetPoint('TOP',0,-(i-1)*30)
      t:SetShadowOffset(2,-2); f.lines[i]={text=t,age=SHOUT_TIME}
    end
    f:SetScript('OnUpdate',function(self,elapsed)
      local any=false
      for _,l in ipairs(self.lines) do
        l.age=l.age+elapsed
        if l.age<SHOUT_TIME then any=true; l.text:SetAlpha(math.min(1,(SHOUT_TIME-l.age)/1.5)) else l.text:SetText('') end
      end
      if not any then self:Hide() end
    end)
    f:Hide()
  end
  -- Newest on top; older ones move down.
  for i=#f.lines,2,-1 do
    local a,b=f.lines[i],f.lines[i-1]
    a.text:SetText(b.text:GetText() or ''); a.age=b.age
  end
  f.lines[1].text:SetText(text); f.lines[1].age=0
  f:Show()
end
-- The big one: a banner across the top of the screen with fireworks, for a few seconds. Click to dismiss.
VC.partyQueue={}
local PARTY_TIME=7
function VC.bigCelebration(m,level)
  local f=VC.party
  if not f then
    f=CreateFrame('Button','VillageCommandCelebration',UIParent)
    VC.party=f
    f:SetSize(680,170); f:SetPoint('TOP',0,-130); f:SetFrameStrata('FULLSCREEN_DIALOG')
    f:RegisterForClicks('LeftButtonUp','RightButtonUp')
    local band=f:CreateTexture(nil,'BACKGROUND'); band:SetPoint('TOPLEFT',0,-30); band:SetPoint('BOTTOMRIGHT',0,20); band:SetColorTexture(0,0,0,.6)
    for _,edge in ipairs({'TOP','BOTTOM'}) do
      local line=f:CreateTexture(nil,'BORDER'); line:SetHeight(2); line:SetColorTexture(1,.78,.25,.9)
      line:SetPoint(edge..'LEFT',band,edge..'LEFT'); line:SetPoint(edge..'RIGHT',band,edge..'RIGHT')
    end
    f.glow=f:CreateTexture(nil,'BORDER'); f.glow:SetTexture('Interface\\Cooldown\\star4'); f.glow:SetSize(320,320); f.glow:SetPoint('CENTER')
    f.glow:SetBlendMode('ADD'); f.glow:SetVertexColor(1,.8,.3,.55)
    f.icon=f:CreateTexture(nil,'ARTWORK'); f.icon:SetTexture(VC.ICON); f.icon:SetSize(52,52); f.icon:SetPoint('TOP',0,-2)
    f.title=f:CreateFontString(nil,'OVERLAY','GameFontNormalHuge'); f.title:SetPoint('TOP',f.icon,'BOTTOM',0,-6)
    if f.title.SetFont then pcall(f.title.SetFont,f.title,'Fonts\\MORPHEUS.TTF',34,'OUTLINE') end
    f.title:SetTextColor(1,.82,.2)
    f.sub=f:CreateFontString(nil,'OVERLAY','GameFontHighlightLarge'); f.sub:SetPoint('TOP',f.title,'BOTTOM',0,-6)
    f.sparks={}
    for i=1,30 do
      local t=f:CreateTexture(nil,'OVERLAY'); t:SetTexture('Interface\\Cooldown\\star4'); t:SetBlendMode('ADD'); t:SetSize(18,18)
      f.sparks[i]=t
    end
    -- New frames start out shown; this one waits hidden until there's something to celebrate.
    f.t=PARTY_TIME; f:Hide()
    f:SetScript('OnClick',function(self) self.t=PARTY_TIME end)
    f:SetScript('OnUpdate',function(self,elapsed)
      self.t=(self.t or 0)+elapsed
      local t=self.t
      if t>=PARTY_TIME then
        self:Hide()
        local nextOne=table.remove(VC.partyQueue,1)
        if nextOne then VC.bigCelebration(nextOne[1],nextOne[2]) end
        return
      end
      self:SetAlpha(math.min(1,t/.3,(PARTY_TIME-t)/1))
      if self.glow.SetRotation then self.glow:SetRotation(t*.6) end
      -- Bursts of stars from the middle, every two and a half seconds.
      local burst=t%2.5
      for i,sp in ipairs(self.sparks) do
        local a=sp.angle or 0
        local d=(sp.speed or 100)*burst
        sp:ClearAllPoints(); sp:SetPoint('CENTER',self,'CENTER',math.cos(a)*d,math.sin(a)*d*.55)
        sp:SetAlpha(math.max(0,1-burst/2.2))
        sp:SetVertexColor(sp.r or 1,sp.g or .8,sp.b or .3)
      end
    end)
  end
  if f:IsShown() and (f.t or 0)<PARTY_TIME then VC.partyQueue[#VC.partyQueue+1]={m,level}; return end
  f.title:SetText(level==VC.maxLevel() and ('Level '..level..'!') or ('Level '..level))
  f.sub:SetText(VC.colorName(m)..' |cffffffffreached level '..level..'. The whole village salutes you!|r')
  local palette={{1,.82,.2},{1,.5,.2},{.4,.8,1},{.6,1,.4},{1,.4,.8}}
  for i,sp in ipairs(f.sparks) do
    sp.angle=(i/#f.sparks)*2*math.pi+math.random()*.3
    sp.speed=90+math.random()*170
    local c=palette[(i%#palette)+1]
    sp.r,sp.g,sp.b=c[1],c[2],c[3]
  end
  f.t=0; f:SetAlpha(0); f:Show()
  playSound('LEVELUPSOUND',888)
end
function VC.previewCelebration(big)
  local me=VC.byId[VC.myId() or ''] or {short=UnitName and UnitName('player') or 'You',classFile=select(2,UnitClass and UnitClass('player') or nil),level=VC.maxLevel()}
  VC.celebrate(me,big and VC.maxLevel() or 20,big)
end

-- History sync -----------------------------------------------------------------------------------------
-- Guildmates running Village Command share what they've seen, so "days in the guild", level history and the
-- activity feed cover everyone's playtime, not just yours. At login a client says hello with a fingerprint
-- of its history; if someone's differs, one of them (not everyone: the first to start silences the rest)
-- sends theirs in compact chunks, and the other sends back what it has that they didn't. Both merge, so the
-- fingerprints end up matching and later hellos cost one message. About 50 bytes a member: a 120-member
-- guild's full history is some 30 messages, sent at Blizzard's pace (a burst, then about one a second).
-- Online-by-hour samples stay local: merging averages from several people double-counts.
-- Trust: anyone may add level history consistent with today's roster; earlier "first seen" dates and joins,
-- leaves and rank changes come from the trusted ranks (Settings), or for first-seen, two people who agree.
local SYNC_PREFIX='VCMD'
local SYNC_VERSION='1'
local SYNC_DAYS=30
VC.sync={out={},allowance=8,sent=0,received=0,merged=0,rejected=0,lastDump=0,lastBegin=0,dumpsTo={},pending={}}
local B36='0123456789abcdefghijklmnopqrstuvwxyz'
function VC.to36(n)
  n=math.floor(tonumber(n) or 0)
  if n<=0 then return '0' end
  local out=''
  while n>0 do local d=n%36; out=B36:sub(d+1,d+1)..out; n=math.floor(n/36) end
  return out
end
function VC.from36(text) return tonumber(text or '',36) end
function VC.syncOn() return settings().share~=false and IsInGuild and IsInGuild() and true or false end
-- Blizzard restricts addon chat in instances and combat; elsewhere always send (see GuildForge's notes:
-- Forever reports "restricted" nearly all the time while messages still arrive).
function VC.messagingBlocked()
  local inInstance=IsInInstance and IsInInstance()
  local inCombat=InCombatLockdown and InCombatLockdown()
  if not inInstance and not inCombat then return false end
  local C=C_ChatInfo or {}
  for _,name in ipairs({'AreOutgoingAddonChatMessagesRestricted','InChatMessagingLockdown'}) do
    if C[name] and C[name]()==true then return true end
  end
  return false
end
function VC.syncQueue(payload) VC.sync.out[#VC.sync.out+1]=payload end
function VC.syncDrain(elapsed)
  local sy=VC.sync
  sy.allowance=math.min(8,sy.allowance+elapsed*.9)
  if #sy.out==0 or sy.allowance<1 or VC.messagingBlocked() then return end
  local fn=(C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if not fn then wipe(sy.out); return end
  local ok,result=pcall(fn,SYNC_PREFIX,sy.out[1],'GUILD')
  -- The game refused it for pace: keep it and try again in a moment. Anything else: drop it.
  if ok and type(result)=='number' and result~=0 and (result==3 or result==8) then sy.allowance=0; return end
  table.remove(sy.out,1)
  sy.allowance=sy.allowance-1
  sy.sent=sy.sent+1
end
-- The fingerprint: everyone's first-seen date and last five level changes, and how many recent events.
-- Two clients with the same shared history get the same fingerprint, whatever else they hold locally.
-- The last five level changes, read as merging would keep them (levels only go up, one entry per level).
local function lastLevels(rec)
  local clean,top={},0
  for _,e in ipairs(rec.levels or {}) do if e[2]>top then clean[#clean+1]=e; top=e[2] end end
  local out={}
  for i=math.max(1,#clean-4),#clean do out[#out+1]=clean[i] end
  return out
end
function VC.digest()
  local g=VC.guildData()
  if not g then return '0' end
  local keys={}
  for id,rec in pairs(g.members) do
    if VC.byId[id] then
      local parts={id,math.floor(rec.first or 0)}
      for _,e in ipairs(lastLevels(rec)) do parts[#parts+1]=e[2]..'@'..math.floor(e[1]) end
      keys[#keys+1]=table.concat(parts,':')
    end
  end
  table.sort(keys)
  local h=5381
  for _,k in ipairs(keys) do for i=1,#k do h=(h*33+k:byte(i))%4294967296 end end
  local seen,count,cutoff={},0,now()-SYNC_DAYS*DAY
  for _,e in ipairs(g.events) do
    local key=VC.eventKey(e)
    if e.t>=cutoff and key and not seen[key] then seen[key]=true; count=count+1 end
  end
  return VC.to36(h)..'.'..count
end
local KIND_CODE={join='j',leave='l',ding='d',promote='p',demote='x'}
local CODE_KIND={j='join',l='leave',d='ding',p='promote',x='demote'}
-- The level or rank an event is about (older events only kept the words, so read it back from those).
function VC.eventValue(e)
  if e.v then return e.v end
  if e.k=='ding' or e.k=='join' then return tonumber((e.d or ''):match('(%d+)%)?$')) end
  if e.k=='promote' or e.k=='demote' then
    local rank=(e.d or ''):match('to (.+)$')
    for i,name in pairs(VC.rankNames()) do if name==rank then return i end end
  end
end
function VC.eventKey(e)
  local id=e.id or VC.nameId(e.n)
  if not id or not KIND_CODE[e.k] then return nil end
  return e.k..':'..id..':'..tostring(VC.eventValue(e) or '')
end
function VC.eventText(kind,v)
  local maxLevel=VC.maxLevel()
  if kind=='join' then return 'joined at level '..(v or '?') end
  if kind=='leave' then return 'left the guild' end
  if kind=='ding' then return v==maxLevel and ('hit the level cap ('..v..')') or ('reached level '..(v or '?')) end
  local rank=v and VC.rankNames()[v] or ('rank '..tostring(v))
  return (kind=='promote' and 'promoted to ' or 'demoted to ')..rank
end
-- Encoded pieces. Member: id~first~level@time,level@time. Event: time~kind~name~value. Times in base 36.
function VC.encodeMember(id,rec)
  local parts={}
  for _,e in ipairs(lastLevels(rec)) do parts[#parts+1]=e[2]..'@'..VC.to36(e[1]) end
  return id..'~'..VC.to36(rec.first or 0)..'~'..table.concat(parts,',')
end
function VC.encodeEvent(e)
  local v=VC.eventValue(e)
  local name=tostring(e.n or ''):gsub('[~;|]','')
  return VC.to36(e.t)..'~'..KIND_CODE[e.k]..'~'..name..'~'..(v and tostring(v) or '')
end
-- Packs pieces into messages of at most 240 bytes: "M|piece;piece;...".
local function pack(kind,pieces)
  local line=''
  for _,piece in ipairs(pieces) do
    if #line>0 and #line+#piece+1>238 then VC.syncQueue(kind..'|'..line); line='' end
    line=(#line>0) and (line..';'..piece) or piece
  end
  if #line>0 then VC.syncQueue(kind..'|'..line) end
end
function VC.sendHistory()
  local g=VC.guildData()
  if not (g and VC.syncOn()) then return end
  local members,events={},{}
  for id,rec in pairs(g.members) do if VC.byId[id] and rec.first then members[#members+1]=VC.encodeMember(id,rec) end end
  table.sort(members)
  local cutoff=now()-SYNC_DAYS*DAY
  for _,e in ipairs(g.events) do if e.t>=cutoff and KIND_CODE[e.k] then events[#events+1]=VC.encodeEvent(e) end end
  VC.syncQueue('B|'..VC.digest())
  pack('M',members); pack('E',events)
  VC.syncQueue('Z|'..VC.digest())
  VC.sync.lastDump=now()
end
function VC.sayHello()
  if not (VC.syncOn() and VC.guildData() and #VC.roster>0) then return end
  VC.sync.helloAt=now()
  VC.syncQueue('H|'..SYNC_VERSION..'|'..VC.digest())
end
-- Ranks whose word is taken on its own: the guild master and ranks down to Settings > Trust history from.
function VC.trusted(senderId)
  local m=VC.byId[senderId or '']
  return m~=nil and m.rankIndex<=(tonumber(settings().trustRank) or 1)
end
function VC.mergeMember(piece,senderId,trusted)
  local id,first,levels=piece:match('^([^~]+)~([^~]*)~(.*)$')
  local m=id and VC.byId[id]
  local g=VC.guildData()
  local rec=m and g and g.members[id]
  if not rec then return false end
  local changed=false
  local t=now()
  local f=VC.from36(first)
  if f and f>1000000000 and f<=t+600 and f<(rec.first or math.huge)-3600 then
    local p=VC.sync.pending[id]
    if trusted then rec.first=f; changed=true
    elseif p and p.sender~=senderId and math.abs(p.first-f)<DAY then rec.first=math.max(p.first,f); changed=true; VC.sync.pending[id]=nil
    else VC.sync.pending[id]={first=f,sender=senderId}; VC.sync.rejected=VC.sync.rejected+1 end
  end
  -- Level history: any entry that fits what the roster says today, earliest time per level kept.
  local list=rec.levels or {}
  local have={}
  for _,e in ipairs(list) do have[e[2]]=e end
  for lv,stamp in (levels or ''):gmatch('(%d+)@(%w+)') do
    lv,stamp=tonumber(lv),VC.from36(stamp)
    if lv and stamp and lv>=1 and lv<=m.level and stamp<=t+600 and stamp>1000000000 then
      local mine=have[lv]
      if not mine then list[#list+1]={stamp,lv}; have[lv]={stamp,lv}; changed=true
      elseif stamp<mine[1] then mine[1]=stamp; changed=true end
    end
  end
  if changed then
    table.sort(list,function(a,b) if a[1]~=b[1] then return a[1]<b[1] end return a[2]<b[2] end)
    local clean,top={},0
    -- Levels only go up, one entry per level (the earliest).
    for _,e in ipairs(list) do if e[2]>top then clean[#clean+1]=e; top=e[2] end end
    while #clean>40 do table.remove(clean,1) end
    rec.levels=clean
    if rec.first and clean[1] and clean[1][1]<rec.first and trusted then rec.first=clean[1][1] end
  end
  return changed
end
function VC.mergeEvent(piece,trusted)
  local stamp,code,name,v=piece:match('^(%w+)~(%a)~([^~]+)~(%-?%d*)$')
  local kind=CODE_KIND[code or '']
  local g=VC.guildData()
  if not (kind and g) then return false end
  local t=VC.from36(stamp)
  v=tonumber(v)
  if not t or t>now()+600 or t<now()-SYNC_DAYS*DAY then return false end
  local id=VC.nameId(name)
  local m=id and VC.byId[id]
  if kind=='ding' then
    if not (m and v and v<=m.level) then return false end
  elseif not trusted then VC.sync.rejected=VC.sync.rejected+1; return false
  elseif kind=='leave' and m then return false end
  local key=kind..':'..tostring(id)..':'..tostring(v or '')
  for _,e in ipairs(g.events) do
    if VC.eventKey(e)==key and math.abs(e.t-t)<2*DAY then return false end
  end
  local e={t=t,k=kind,n=m and m.short or name,d=VC.eventText(kind,v),id=id,v=v,shared=true}
  local at=#g.events+1
  while at>1 and g.events[at-1].t>t do at=at-1 end
  table.insert(g.events,at,e)
  while #g.events>400 do table.remove(g.events,1) end
  return true
end
function VC.onSyncMessage(msg,sender)
  local senderId=VC.nameId(sender)
  if not senderId or senderId==VC.myId() or not VC.syncOn() then return end
  local sy=VC.sync
  sy.received=sy.received+1
  local kind,rest=msg:match('^(%a)|(.*)$')
  if kind=='H' then
    local version,theirs=rest:match('^([^|]*)|(.*)$')
    if version~=SYNC_VERSION or theirs==VC.digest() then return end
    -- Someone's history differs from ours: answer after a random moment, unless someone else starts first.
    if now()-sy.lastDump<60 then return end
    later(1+math.random()*6,function()
      if now()-sy.lastBegin<20 or now()-sy.lastDump<60 then return end
      VC.sendHistory()
    end)
  elseif kind=='B' then
    sy.lastBegin=now()
  elseif kind=='M' or kind=='E' then
    local trusted=VC.trusted(senderId)
    local changed=false
    for piece in rest:gmatch('[^;]+') do
      local ok,did
      if kind=='M' then ok,did=pcall(VC.mergeMember,piece,senderId,trusted)
      else ok,did=pcall(VC.mergeEvent,piece,trusted) end
      if ok and did then changed=true; sy.merged=sy.merged+1 end
    end
    if changed then requestRedraw() end
  elseif kind=='Z' then
    -- Their history has arrived. If ours still differs we hold something they don't: send it back, once.
    -- Only once per version of our history, so two clients that can't agree (trust rules) don't ping-pong.
    local mine=VC.digest()
    local last=sy.dumpsTo[senderId]
    if rest~=mine and (sy.helloAt and now()-sy.helloAt<300) and not (last and last.digest==mine and now()-last.at<600) and now()-sy.lastDump>30 then
      sy.dumpsTo[senderId]={digest=mine,at=now()}
      later(1+math.random()*3,VC.sendHistory)
    end
  end
end

-- Levels the whole guild gained on each of the last `days` days, oldest first (from each member's level history).
function VC.levelsByDay(days)
  local g=VC.guildData()
  local out={}
  for i=1,days do out[i]=0 end
  if not g then return out end
  local t=now()
  local today=t
  if date and time then local d=date('*t',t); d.hour,d.min,d.sec=0,0,0; today=time(d) end
  for _,rec in pairs(g.members) do
    local levels=rec.levels or {}
    for i=2,#levels do
      local gain=levels[i][2]-levels[i-1][2]
      local ago=math.floor((today-levels[i][1])/DAY)+1
      if levels[i][1]>=today then ago=0 end
      local index=days-ago
      if gain>0 and index>=1 and index<=days then out[index]=out[index]+gain end
    end
  end
  return out
end
-- Members who hit the level cap while Village Command was watching, newest first: {name=, t=}.
function VC.hallOfFame()
  local g=VC.guildData()
  local list={}
  for i=#(g and g.events or {}),1,-1 do
    local e=g.events[i]
    if e.k=='ding' and e.d and e.d:find('level cap',1,true) then list[#list+1]={name=e.n,t=e.t} end
  end
  return list
end
-- Levels gained in the last `days` days, from what this client has seen.
function VC.gained(rec,days,t)
  if not rec then return 0 end
  local cutoff=(t or now())-days*DAY
  local base
  for _,e in ipairs(rec.levels or {}) do
    if e[1]<=cutoff then base=e[2] else break end
  end
  if not base then base=rec.levels and rec.levels[1] and rec.levels[1][2] end
  return math.max(0,(rec.level or 0)-(base or rec.level or 0))
end
function VC.climbers(days)
  local g=VC.guildData()
  local list={}
  if not g then return list end
  local t=now()
  for _,m in ipairs(VC.roster) do
    local rec=g.members[m.id]
    local n=VC.gained(rec,days,t)
    if n>0 then list[#list+1]={m=m,n=n,from=m.level-n} end
  end
  table.sort(list,function(a,b) if a.n~=b.n then return a.n>b.n end return a.m.short<b.m.short end)
  return list
end
function VC.eventsSince(seconds)
  local g=VC.guildData()
  local counts={join=0,leave=0,ding=0,promote=0,demote=0}
  if not g then return counts end
  local cutoff=now()-seconds
  for _,e in ipairs(g.events) do if e.t>=cutoff and counts[e.k] then counts[e.k]=counts[e.k]+1 end end
  return counts
end

-- Promotion checklist -------------------------------------------------------------------------------
-- Officers set rules ("Genin -> Chunin: level 20+, 14+ days in the guild, online in the last 7 days") and
-- Village Command lists who qualifies. Where the game lets addons promote (Classic Era) they can all be promoted
-- at once; where it doesn't (WoW Forever) it's a checklist for the game's guild window, and each member drops
-- off as the roster shows their new rank. Rules and skips are kept per guild, on this PC.
function VC.rules()
  local g=VC.guildData()
  if not g then return {} end
  g.rules=g.rules or {}
  return g.rules
end
function VC.ruleText(r)
  local parts={}
  if (r.minLevel or 0)>0 then parts[#parts+1]='level '..r.minLevel..'+' end
  if (r.minDays or 0)>0 then parts[#parts+1]=r.minDays..'+ days in the guild' end
  if (r.activeDays or 0)>0 then parts[#parts+1]='online in the last '..r.activeDays..' day'..(r.activeDays==1 and '' or 's') end
  return #parts>0 and table.concat(parts,'  ·  ') or 'everyone at that rank'
end
-- Days in the guild, as far as this PC knows: from when Village Command first saw them.
function VC.daysIn(m,t)
  local g=VC.guildData()
  local rec=g and g.members[m.id]
  if not rec or not rec.first then return 0 end
  return math.floor(((t or now())-rec.first)/DAY)
end
function VC.ruleMatches(r,m,t)
  t=t or now()
  if m.rankIndex~=r.from then return false end
  if (r.minLevel or 0)>0 and m.level<r.minLevel then return false end
  if (r.minDays or 0)>0 and VC.daysIn(m,t)<r.minDays then return false end
  if (r.activeDays or 0)>0 and not m.online and (m.away or 1e12)>r.activeDays*DAY then return false end
  return true
end
-- Who's ready (online first, then highest level), who's skipped, and who this rule's promotion reached this week.
function VC.ruleMembers(r)
  local ready,skipped,t={},{},now()
  r.skip=r.skip or {}
  for _,m in ipairs(VC.roster) do
    if VC.ruleMatches(r,m,t) then
      if r.skip[m.id] then skipped[#skipped+1]=m else ready[#ready+1]=m end
    end
  end
  -- A skip only lasts while they're still at that rank and in the guild.
  for id in pairs(r.skip) do local m=VC.byId[id]; if not m or m.rankIndex~=r.from then r.skip[id]=nil end end
  local function order(a,b)
    if a.online~=b.online then return a.online end
    if a.level~=b.level then return a.level>b.level end
    return a.short<b.short
  end
  table.sort(ready,order); table.sort(skipped,order)
  local done={}
  local g=VC.guildData()
  local target='promoted to '..(VC.rankNames()[r.to] or '?')
  for _,e in ipairs(g and g.events or {}) do
    if e.k=='promote' and e.d==target and e.t>=t-7*DAY then done[#done+1]=e.n end
  end
  return ready,skipped,done
end
-- Everyone ready under any rule, once each.
function VC.readyForPromotion()
  local seen,list={},{}
  for _,r in ipairs(VC.rules()) do
    for _,m in ipairs(r.off and {} or (VC.ruleMembers(r))) do
      if not seen[m.id] then seen[m.id]=r; list[#list+1]=m end
    end
  end
  return list,seen
end
function VC.saveRule(index,r)
  local rules=VC.rules()
  if index and rules[index] then r.skip=rules[index].skip; r.off=rules[index].off; rules[index]=r else rules[#rules+1]=r end
  requestRedraw()
end
function VC.deleteRule(index)
  table.remove(VC.rules(),index)
  requestRedraw()
end
-- Classic Era: promote everyone a rule lists, through the usual confirmation and queue.
function VC.promoteRule(r)
  local ready=VC.ruleMembers(r)
  wipe(VC.selected)
  for _,m in ipairs(ready) do VC.selected[m.id]=true end
  VC.massRank(0,r.to,VC.rankNames()[r.to])
end

-- Other addons --------------------------------------------------------------------------------------
-- GuildForge: reads its saved data (professions per member) and opens its window. Looked up on every use,
-- since it can load after us.
local function addonLoaded(name)
  local fn=(C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  if type(fn)~='function' then return false end
  local ok,loaded=pcall(fn,name)
  return ok and loaded and true or false
end
function VC.hasForge() return type(GuildForgeDB)=='table' or (SlashCmdList and SlashCmdList.GUILDFORGE~=nil) or addonLoaded('GuildForge') end
function VC.openForge()
  if SlashCmdList and SlashCmdList.GUILDFORGE then SlashCmdList.GUILDFORGE(''); return true end
  if GuildForge_OnAddonCompartmentClick then GuildForge_OnAddonCompartmentClick(nil,'LeftButton'); return true end
  log('GuildForge isn\'t loaded. Install it (CurseForge: GuildForge) to see professions here.',true)
end
-- {[nameId]={{name=,rank=,max=},...}} for the current guild, or nil.
function VC.forgeProfessions()
  local d=GuildForgeDB
  if type(d)~='table' or type(d.guilds)~='table' then return nil end
  local name=VC.guildName()
  if not name then return nil end
  local bucket=d.guilds[name] or d.guilds[name..' - '..realm()]
  if type(bucket)~='table' or type(bucket.members)~='table' then return nil end
  local out={}
  for who,record in pairs(bucket.members) do
    local id=VC.nameId(who)
    if id and type(record)=='table' and type(record.professions)=='table' then out[id]=record.professions end
  end
  return out
end
VC.professionList={'Alchemy','Blacksmithing','Enchanting','Engineering','Leatherworking','Tailoring','Cooking','First Aid','Fishing','Herbalism','Mining','Skinning'}
VC.professionIcons={
  Alchemy='Interface\\Icons\\Trade_Alchemy', Blacksmithing='Interface\\Icons\\Trade_BlackSmithing',
  Enchanting='Interface\\Icons\\Trade_Engraving', Engineering='Interface\\Icons\\Trade_Engineering',
  Leatherworking='Interface\\Icons\\Trade_LeatherWorking', Tailoring='Interface\\Icons\\Trade_Tailoring',
  Cooking='Interface\\Icons\\INV_Misc_Food_15', ['First Aid']='Interface\\Icons\\Spell_Holy_SealOfSacrifice',
  Fishing='Interface\\Icons\\Trade_Fishing', Herbalism='Interface\\Icons\\Spell_Nature_NatureTouchGrow',
  Mining='Interface\\Icons\\Trade_Mining', Skinning='Interface\\Icons\\INV_Misc_Pelt_Wolf_01',
}
-- Per profession: members (current roster only), top skill and who has it, online count.
function VC.professionSummary()
  local profs=VC.forgeProfessions()
  if not profs then return nil end
  local out={}
  for _,name in ipairs(VC.professionList) do out[name]={name=name,count=0,online=0,top=0,max=0,maxed=0,members={}} end
  for id,list in pairs(profs) do
    local m=VC.byId[id]
    if m or #VC.roster==0 then
      for _,p in ipairs(list) do
        local s=type(p)=='table' and out[p.name]
        if s then
          s.count=s.count+1
          s.members[#s.members+1]={m=m,id=id,rank=tonumber(p.rank) or 0,max=tonumber(p.max) or 0}
          if m and m.online then s.online=s.online+1 end
          if (tonumber(p.rank) or 0)>s.top then s.top=tonumber(p.rank) or 0; s.topName=m and m.short or id end
          if (tonumber(p.max) or 0)>s.max then s.max=tonumber(p.max) or 0 end
          if (tonumber(p.rank) or 0)>=300 then s.maxed=s.maxed+1 end
        end
      end
    end
  end
  return out
end
-- Un-Ninja Bank (folder GuildBankToons): its public API for opening tabs, and its helper table for gold and
-- requests. Every call is wrapped: a newer bank that changes a helper only hides a line here.
function VC.bankAPI()
  local api=GuildBankToonsAPI
  if type(api)~='table' then return nil end
  if not VC.bankHooked and type(api.RegisterCallback)=='function' then
    VC.bankHooked=true
    pcall(api.RegisterCallback,requestRedraw)
  end
  return api
end
function VC.hasBank()
  local api=VC.bankAPI()
  if not api then return false end
  local ok,has=pcall(api.HasBank)
  return ok and has==true
end
local function bankCall(name,...)
  local GV=GuildBankToons
  if type(GV)~='table' or type(GV[name])~='function' then return nil end
  local ok,a,b=pcall(GV[name],...)
  if ok then return a,b end
end
function VC.openBank(tab)
  local api=VC.bankAPI()
  if api and type(api.Open)=='function' then pcall(api.Open,tab); return true end
  log('Un-Ninja Bank isn\'t loaded. Install it (CurseForge: Un-Ninja Bank) to see the guild bank here.',true)
end
function VC.bankSummary()
  if not VC.bankAPI() then return nil end
  local s={gold=tonumber((bankCall('currentGold','*'))) or 0,banks={},requests={},open=0}
  local g=bankCall('guild')
  local snaps=type(g)=='table' and type(g.banks)=='table' and g.banks or {}
  for _,b in ipairs(bankCall('bankList') or {}) do
    if type(b)=='table' then
      local snap=snaps[b.id]
      s.banks[#s.banks+1]={name=b.name,tab=b.tab,gold=snap and tonumber(snap.gold) or nil,id=VC.nameId(b.name)}
    end
  end
  for _,r in ipairs(bankCall('requestList') or {}) do
    if type(r)=='table' and (r.status=='open' or r.status=='approved') then
      s.open=s.open+1
      s.requests[#s.requests+1]={by=r.by and VC.displayName(r.by) or '?',status=r.status,text=bankCall('describe',r,true) or '?'}
    end
  end
  local series=bankCall('goldSeries',14,'*')
  s.series=type(series)=='table' and series or nil
  return s
end
function VC.money(copper)
  copper=math.floor(tonumber(copper) or 0)
  local fn=GetCoinTextureString or (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString)
  if fn then
    local ok,text=pcall(fn,copper)
    if ok and type(text)=='string' then return text end
  end
  return math.floor(copper/10000)..'g'
end
-- Bank toons by name, for the "Bank toon" tag in the roster.
function VC.bankToons()
  local set={}
  for _,b in ipairs(bankCall('bankList') or {}) do
    if type(b)=='table' and not b.tab and b.name then local id=VC.nameId(b.name); if id then set[id]=true end end
  end
  return set
end

-- Stats ---------------------------------------------------------------------------------------------
function VC.agoText(age)
  if not age then return 'unknown' end
  if age<3600 then return 'within 1h' end
  if age<DAY then return math.floor(age/3600)..'h ago' end
  if age<DAY*60 then return math.floor(age/DAY)..'d ago' end
  return math.floor(age/(DAY*30))..'mo ago'
end
-- Mains named in alt notes: "Alt of Bob", "Bob's alt", "Bob alt".
function VC.altOwner(note)
  note=(note or ''):lower()
  if not note:find('alt') then return nil end
  local who=note:match('alt%s+of%s+([%a\128-\255]+)') or note:match('([%a\128-\255]+)\'s%s+alt') or note:match('^([%a\128-\255]+)%s+alt')
  if who and who~='an' and who~='the' and who~='my' then return who end
  return '?'
end
function VC.stats()
  local s={total=#VC.roster,online=0,maxed=0,levelSum=0,classes={},zones={},ranks={},brackets={},noNote=0,alts=0,altOwners={}}
  local maxLevel=VC.maxLevel()
  for _,m in ipairs(VC.roster) do
    if m.online then
      s.online=s.online+1
      if m.zone~='' then s.zones[m.zone]=(s.zones[m.zone] or 0)+1 end
    end
    if m.level>=maxLevel then s.maxed=s.maxed+1 end
    s.levelSum=s.levelSum+m.level
    local c=s.classes[m.classFile] or {n=0,label=m.class~='' and m.class or m.classFile,file=m.classFile}
    c.n=c.n+1; s.classes[m.classFile]=c
    s.ranks[m.rankIndex]=(s.ranks[m.rankIndex] or 0)+1
    local bracket=math.floor(m.level/10)
    s.brackets[bracket]=(s.brackets[bracket] or 0)+1
    if m.note=='' then s.noNote=s.noNote+1 end
    local owner=VC.altOwner(m.note)
    if owner then
      s.alts=s.alts+1
      if owner~='?' then s.altOwners[owner]=(s.altOwners[owner] or 0)+1 end
    end
    if m.points and (not s.achiever or m.points>s.achiever.points) then s.achiever=m end
    if not m.online and m.away and (not s.wanderer or m.away>s.wanderer.away) then s.wanderer=m end
  end
  s.average=s.total>0 and (s.levelSum/s.total) or 0
  local function top(map)
    local best,n
    for k,v in pairs(map) do local c=type(v)=='table' and v.n or v; if not n or c>n or (c==n and tostring(k)<tostring(best)) then best,n=k,c end end
    return best,n
  end
  s.hotZone,s.hotZoneN=top(s.zones)
  s.topClass=top(s.classes)
  s.altKing,s.altKingN=top(s.altOwners)
  local rare,rareN
  for k,c in pairs(s.classes) do if k~='' and (not rareN or c.n<rareN or (c.n==rareN and k<rare)) then rare,rareN=k,c.n end end
  s.rareClass=rare
  local g=VC.guildData()
  if g then
    local bestHour,bestAvg
    for h=0,23 do
      local slot=g.hours[h]
      if slot and slot.n>0 and (not bestAvg or slot.s/slot.n>bestAvg) then bestHour,bestAvg=h,slot.s/slot.n end
    end
    s.busyHour,s.busyAvg=bestHour,bestAvg
    s.peak=g.peak
    local t=now()
    for id,rec in pairs(g.members) do
      local m=VC.byId[id]
      if m then
        local gain=VC.gained(rec,7,t)
        if gain>0 and (not s.dinger or gain>s.dingerN) then s.dinger,s.dingerN=m,gain end
        if (rec.night or 0)>0 and (not s.owl or rec.night>s.owlN) then s.owl,s.owlN=m,rec.night end
        if (rec.dawn or 0)>0 and (not s.bird or rec.dawn>s.birdN) then s.bird,s.birdN=m,rec.dawn end
        if (rec.on or 0)>0 and (not s.regular or rec.on>s.regularN) then s.regular,s.regularN=m,rec.on end
        if g.baseline and rec.first>g.baseline and (not s.newest or rec.first>s.newestT) then s.newest,s.newestT=m,rec.first end
      end
    end
  end
  return s
end

-- Widgets -------------------------------------------------------------------------------------------
-- The same parchment and gold look as GuildForge.
local function skin(f,alpha,r,g,b)
  if not f.SetBackdrop then return end
  f:SetBackdrop({bgFile='Interface\\Tooltips\\UI-Tooltip-Background',edgeFile='Interface\\Tooltips\\UI-Tooltip-Border',tile=true,tileSize=16,edgeSize=12,insets={left=3,right=3,top=3,bottom=3}})
  f:SetBackdropColor(.08,.06,.04,alpha or .9)
  f:SetBackdropBorderColor(r or .78,g or .62,b or .32,1)
end
VC.skin=skin
local function addHighlight(b,alpha)
  local hl=b:CreateTexture(nil,'HIGHLIGHT')
  hl:SetTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight')
  hl:SetBlendMode('ADD'); hl:SetAllPoints(); hl:SetAlpha(alpha or .45)
  return hl
end
local function fontString(parent,template,justify)
  local fs=parent:CreateFontString(nil,'OVERLAY',template)
  fs:SetJustifyH(justify or 'LEFT')
  if fs.SetWordWrap then fs:SetWordWrap(false) end
  return fs
end
local function smallButton(parent,label,width,height)
  local b=CreateFrame('Button',nil,parent,'UIPanelButtonTemplate')
  b:SetSize(width,height or 20); b:SetText(label)
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  return b
end
-- Escape closes our windows, newest dialog first. Not through UISpecialFrames: the game menu and logging
-- out walk that list, and an addon's entries there taint them, so the game blocks its own Log Out and
-- menu buttons and blames the addon. Instead one small frame listens for Escape while one of ours is open,
-- and lets every other key (and Escape, once ours are closed or in combat) carry on to the game.
VC.escFrames={}
function VC.escCatcher()
  local c=VC.escFrame
  if c then return c end
  c=CreateFrame('Frame','VillageCommandEscape',UIParent)
  VC.escFrame=c
  c:SetFrameStrata('FULLSCREEN_DIALOG'); c:SetSize(1,1); c:SetPoint('TOPLEFT')
  c:EnableKeyboard(true)
  if c.SetPropagateKeyboardInput then c:SetPropagateKeyboardInput(true) end
  c:SetScript('OnKeyDown',function(self,key)
    -- The game won't let addons change key passing in combat; there Escape just goes on to the game.
    if InCombatLockdown and InCombatLockdown() then return end
    local top
    if key=='ESCAPE' then
      for _,e in ipairs(VC.escFrames) do
        if e.frame:IsShown() and (not top or e.order<top.order) then top=e end
      end
    end
    if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(not top) end
    if top then top.frame:Hide() end
  end)
  c:Hide()
  return c
end
function VC.escUpdate()
  local any=false
  for _,e in ipairs(VC.escFrames) do if e.frame:IsShown() then any=true; break end end
  local c=VC.escCatcher()
  if any then c:Show() return end
  c:Hide()
  if c.SetPropagateKeyboardInput and not (InCombatLockdown and InCombatLockdown()) then c:SetPropagateKeyboardInput(true) end
end
-- order: lower closes first (menus, then the confirmation, then dialogs, then the main window).
function VC.closeOnEscape(frame,order)
  VC.escFrames[#VC.escFrames+1]={frame=frame,order=order}
  frame:HookScript('OnShow',VC.escUpdate)
  frame:HookScript('OnHide',VC.escUpdate)
end
-- Yes/No question in a box of our own: Blizzard's shared popups are also used for logging out, and an
-- addon's popup taints them.
function VC.ask(text,onYes)
  local d=VC.askFrame
  if not d then
    d=CreateFrame('Frame','VillageCommandConfirm',UIParent,BACKDROP_TEMPLATE)
    VC.askFrame=d
    d:SetSize(360,140); d:SetPoint('CENTER',0,140); d:SetFrameStrata('FULLSCREEN_DIALOG'); d:SetToplevel(true)
    d:EnableMouse(true); d:SetClampedToScreen(true)
    if d.SetBackdrop then
      d:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
    end
    d.text=d:CreateFontString(nil,'OVERLAY','GameFontHighlight')
    d.text:SetPoint('TOP',0,-22); d.text:SetWidth(310); d.text:SetJustifyH('CENTER')
    d.yes=smallButton(d,YES or 'Yes',110,22); d.yes:SetPoint('BOTTOMRIGHT',d,'BOTTOM',-6,18)
    d.no=smallButton(d,NO or 'No',110,22); d.no:SetPoint('BOTTOMLEFT',d,'BOTTOM',6,18)
    d.yes:SetScript('OnClick',function() local run=d.run; d.run=nil; d:Hide(); if run then run() end end)
    d.no:SetScript('OnClick',function() d.run=nil; d:Hide() end)
    VC.closeOnEscape(d,2)
    d:Hide()
  end
  d.run=onYes
  d.text:SetText(text)
  local h=d.text.GetStringHeight and d.text:GetStringHeight() or 0
  d:SetHeight(math.max(120,(tonumber(h) or 0)+80))
  d:Show()
end
local function tooltip(owner,title,...)
  GameTooltip:SetOwner(owner,'ANCHOR_RIGHT')
  GameTooltip:AddLine(title,1,.82,0)
  for i=1,select('#',...) do
    local line=select(i,...)
    if line then GameTooltip:AddLine(line,.85,.85,.85,true) end
  end
  GameTooltip:Show()
end
local function setTip(w,title,...)
  local lines={...}
  w:SetScript('OnEnter',function(self) tooltip(self,title,unpack(lines)) end)
  w:SetScript('OnLeave',GameTooltip_Hide)
end
local function editBox(parent,width,placeholderText)
  local e=CreateFrame('EditBox',nil,parent,'InputBoxTemplate')
  e:SetSize(width,20); e:SetAutoFocus(false)
  local ph=e:CreateFontString(nil,'OVERLAY','GameFontDisableSmall')
  ph:SetPoint('LEFT',2,0); ph:SetText(placeholderText or '')
  e.placeholder=ph
  local function sync(self) ph:SetShown(self:GetText()=='' and not self:HasFocus()) end
  e.syncPlaceholder=sync
  e:SetScript('OnEscapePressed',function(self) self:ClearFocus() end)
  e:SetScript('OnEditFocusGained',sync)
  e:SetScript('OnEditFocusLost',function(self) self:HighlightText(0,0); sync(self) end)
  return e
end
local function enable(w,on)
  if w.SetEnabled then w:SetEnabled(on and true or false) elseif on then w:Enable() else w:Disable() end
end
local function setDot(texture,online)
  if online then texture:SetVertexColor(.2,1,.2) else texture:SetVertexColor(.4,.4,.4) end
end

-- A small pick-one menu, shared by every button that needs one (works the same on every client).
function VC.showMenu(anchor,items)
  local m=VC.menu
  if not m then
    m=CreateFrame('Frame','VillageCommandMenu',UIParent,BACKDROP_TEMPLATE)
    skin(m,.97); m:SetFrameStrata('FULLSCREEN_DIALOG'); m:EnableMouse(true); m:SetClampedToScreen(true)
    m.buttons={}
    VC.closeOnEscape(m,1)
    VC.menu=m
  end
  if m:IsShown() and m.anchor==anchor then m:Hide(); return end
  m.anchor=anchor
  for _,b in ipairs(m.buttons) do b:Hide() end
  local width=150
  for i,item in ipairs(items) do
    local b=m.buttons[i]
    if not b then
      b=CreateFrame('Button',nil,m)
      b:SetHeight(18)
      b.text=fontString(b,'GameFontHighlightSmall'); b.text:SetPoint('LEFT',6,0); b.text:SetPoint('RIGHT',-6,0)
      addHighlight(b,.35)
      m.buttons[i]=b
    end
    b:ClearAllPoints(); b:SetPoint('TOPLEFT',6,-6-(i-1)*18); b:SetPoint('RIGHT',-6,0)
    b.text:SetText(item.text)
    b.text:SetTextColor(item.disabled and .5 or 1,item.disabled and .5 or 1,item.disabled and .5 or 1)
    b:SetScript('OnClick',function() m:Hide(); if not item.disabled and item.func then item.func() end end)
    if item.tip then setTip(b,item.text,item.tip) else b:SetScript('OnEnter',nil); b:SetScript('OnLeave',nil) end
    b:Show()
    local w=(b.text.GetStringWidth and tonumber((b.text:GetStringWidth())) or 0)+28
    if w>width then width=w end
  end
  m:SetSize(width,#items*18+12)
  m:ClearAllPoints(); m:SetPoint('TOPLEFT',anchor,'BOTTOMLEFT',0,-2)
  m:Show()
end
function VC.hideMenu() if VC.menu then VC.menu:Hide() end end

-- Pooled widgets for the scrolling pages ------------------------------------------------------------
local factories={}
factories.section=function()
  local b=CreateFrame('Frame',nil,pageContent)
  b:SetHeight(26)
  b.label=fontString(b,'GameFontNormal'); b.label:SetPoint('BOTTOMLEFT',4,5)
  b.extra=fontString(b,'GameFontDisableSmall','RIGHT'); b.extra:SetPoint('BOTTOMRIGHT',-6,6)
  local line=b:CreateTexture(nil,'ARTWORK'); line:SetHeight(1); line:SetColorTexture(.85,.68,.3,.55)
  line:SetPoint('BOTTOMLEFT',2,1); line:SetPoint('BOTTOMRIGHT',-2,1)
  return b
end
-- A row of up to four stat tiles: a big number, a label, and a small line under it.
factories.cards=function()
  local f=CreateFrame('Frame',nil,pageContent)
  f:SetHeight(62)
  f.cards={}
  for i=1,4 do
    local c=CreateFrame('Button',nil,f,BACKDROP_TEMPLATE)
    skin(c,.8)
    c:SetHeight(58)
    c.value=fontString(c,'GameFontNormalLarge'); c.value:SetPoint('TOPLEFT',10,-9); c.value:SetPoint('RIGHT',-8,0)
    c.label=fontString(c,'GameFontHighlightSmall'); c.label:SetPoint('TOPLEFT',c.value,'BOTTOMLEFT',0,-4); c.label:SetPoint('RIGHT',-8,0)
    c.sub=fontString(c,'GameFontDisableSmall'); c.sub:SetPoint('TOPLEFT',c.label,'BOTTOMLEFT',0,-2); c.sub:SetPoint('RIGHT',-8,0)
    f.cards[i]=c
  end
  return f
end
factories.bar=function()
  local b=CreateFrame('Button',nil,pageContent)
  b:SetHeight(20)
  b.icon=b:CreateTexture(nil,'ARTWORK'); b.icon:SetSize(16,16); b.icon:SetPoint('LEFT',4,0); b.icon:SetTexCoord(.07,.93,.07,.93)
  b.label=fontString(b,'GameFontHighlight'); b.label:SetPoint('LEFT',26,0); b.label:SetWidth(170)
  -- The bar stretches between the label and the value, so the row always fits the page.
  b.value=fontString(b,'GameFontHighlightSmall','RIGHT'); b.value:SetPoint('RIGHT',-8,0); b.value:SetWidth(150)
  b.bar=CreateFrame('StatusBar',nil,b); b.bar:SetHeight(13)
  b.bar:SetPoint('LEFT',202,0); b.bar:SetPoint('RIGHT',b.value,'LEFT',-10,0)
  b.bar:SetStatusBarTexture('Interface\\TargetingFrame\\UI-StatusBar')
  local bg=b.bar:CreateTexture(nil,'BACKGROUND'); bg:SetAllPoints(); bg:SetColorTexture(0,0,0,.55)
  b.bar.text=fontString(b.bar,'GameFontHighlightSmall','CENTER'); b.bar.text:SetPoint('LEFT',4,0); b.bar.text:SetPoint('RIGHT',-4,0)
  addHighlight(b,.2)
  return b
end
factories.line=function()
  local b=CreateFrame('Button',nil,pageContent)
  b:SetHeight(20)
  b:RegisterForClicks('LeftButtonUp','RightButtonUp')
  b.stripe=b:CreateTexture(nil,'BACKGROUND'); b.stripe:SetAllPoints()
  b.dot=b:CreateTexture(nil,'ARTWORK'); b.dot:SetTexture(DOT_TEXTURE); b.dot:SetSize(9,9); b.dot:SetPoint('LEFT',8,0)
  b.icon=b:CreateTexture(nil,'ARTWORK'); b.icon:SetSize(16,16); b.icon:SetPoint('LEFT',4,0); b.icon:SetTexCoord(.07,.93,.07,.93)
  b.right=fontString(b,'GameFontHighlightSmall','RIGHT'); b.right:SetPoint('RIGHT',-8,0); b.right:SetWidth(250)
  b.text=fontString(b,'GameFontHighlight'); b.text:SetPoint('LEFT',26,0); b.text:SetPoint('RIGHT',b.right,'LEFT',-10,0)
  addHighlight(b,.3)
  return b
end
-- Vertical bars (online by hour, gold by day) with a label under every few.
factories.chart=function()
  local f=CreateFrame('Frame',nil,pageContent,BACKDROP_TEMPLATE)
  f:SetHeight(108); skin(f,.6,.55,.45,.28)
  f.bars,f.labels={},{}
  for i=1,24 do
    local t=f:CreateTexture(nil,'ARTWORK'); t:SetColorTexture(1,.82,.25,.85)
    f.bars[i]=t
    local l=fontString(f,'GameFontDisableSmall','CENTER'); f.labels[i]=l
  end
  f.caption=fontString(f,'GameFontDisableSmall','RIGHT'); f.caption:SetPoint('TOPRIGHT',-8,-6)
  return f
end
factories.buttons=function()
  local f=CreateFrame('Frame',nil,pageContent)
  f:SetHeight(28)
  f.buttons={}
  for i=1,5 do
    local b=smallButton(f,'',146,22)
    b:SetPoint('LEFT',(i-1)*154+4,0)
    f.buttons[i]=b
  end
  return f
end
factories.note=function()
  local f=CreateFrame('Frame',nil,pageContent)
  f.text=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
  f.text:SetPoint('TOPLEFT',6,-2); f.text:SetPoint('RIGHT',-6,0); f.text:SetJustifyH('LEFT'); f.text:SetJustifyV('TOP')
  if f.text.SetWordWrap then f.text:SetWordWrap(true) end
  return f
end
local pools={}
local function acquire(kind)
  local pool=pools[kind]
  if not pool then pool={used=0}; pools[kind]=pool end
  pool.used=pool.used+1
  local w=pool[pool.used]
  if not w then w=factories[kind](); pool[pool.used]=w end
  w:ClearAllPoints(); w:Show()
  return w
end
function VC.releaseAll()
  for _,pool in pairs(pools) do
    for i=1,#pool do pool[i]:Hide() end
    pool.used=0
  end
end
-- Page layout: widgets stack down the scroll content, as wide as the scroll area really is (the game's
-- scroll bar and borders take a different amount on each client).
local cursor=0
local pageWidth=CONTENT_W
local function place(w,height,indent)
  w:SetPoint('TOPLEFT',pageContent,'TOPLEFT',indent or 0,cursor)
  w:SetWidth(pageWidth-(indent or 0))
  cursor=cursor-height
  return w
end
function VC.section(label,extra)
  local b=acquire('section')
  b.label:SetText(label); b.extra:SetText(extra or '')
  cursor=cursor-4
  return place(b,28)
end
function VC.cards(list)
  local f=acquire('cards')
  local w=(pageWidth-18)/4
  for i,c in ipairs(f.cards) do
    local card=list[i]
    c:ClearAllPoints(); c:SetPoint('TOPLEFT',(i-1)*(w+6),0); c:SetWidth(w)
    c:SetShown(card~=nil)
    if card then
      c.value:SetText(card.value or '')
      c.label:SetText(card.label or '')
      c.sub:SetText(card.sub or '')
      if card.tip then setTip(c,card.label or '',card.tip) else c:SetScript('OnEnter',nil); c:SetScript('OnLeave',nil) end
      c:SetScript('OnClick',card.onClick)
    end
  end
  return place(f,66)
end
function VC.bar(label,value,max,text,color,icon,right,onEnter)
  local b=acquire('bar')
  b.icon:SetShown(icon~=nil); if icon then b.icon:SetTexture(icon) end
  b.label:SetText(label)
  b.bar:SetMinMaxValues(0,math.max(1,max or 1)); b.bar:SetValue(math.min(value or 0,math.max(1,max or 1)))
  b.bar:SetStatusBarColor(color and color[1] or 1,color and color[2] or .72,color and color[3] or .2)
  b.bar.text:SetText(text or '')
  b.value:SetText(right or '')
  b:SetScript('OnEnter',onEnter); b:SetScript('OnLeave',onEnter and GameTooltip_Hide or nil)
  return place(b,21)
end
local stripe=0
function VC.line(text,right,opts)
  opts=opts or {}
  local b=acquire('line')
  stripe=stripe+1
  b.stripe:SetColorTexture(1,1,1,stripe%2==0 and .04 or 0)
  b.dot:SetShown(opts.online~=nil); if opts.online~=nil then setDot(b.dot,opts.online) end
  b.icon:SetShown(opts.icon~=nil); if opts.icon then b.icon:SetTexture(opts.icon) end
  b.text:SetPoint('LEFT',(opts.online~=nil or opts.icon) and 26 or 8,0)
  b.text:SetText(text); b.right:SetText(right or '')
  b:SetScript('OnClick',opts.onClick)
  b:SetScript('OnEnter',opts.onEnter); b:SetScript('OnLeave',opts.onEnter and GameTooltip_Hide or nil)
  return place(b,20)
end
-- values: up to 24 numbers (false = unknown); labels[i] under bar i when given.
function VC.chart(values,labels,caption,color,formatTip)
  local f=acquire('chart')
  local maxV=0
  for _,v in ipairs(values) do if v and v>maxV then maxV=v end end
  local n=#values
  local slot=(pageWidth-24)/math.max(1,n)
  for i=1,24 do
    local bar,label=f.bars[i],f.labels[i]
    local v=values[i]
    if i<=n then
      local h=(v and maxV>0) and math.max(1,(v/maxV)*70) or 1
      bar:ClearAllPoints(); bar:SetPoint('BOTTOMLEFT',f,'BOTTOMLEFT',12+(i-1)*slot+2,20)
      bar:SetSize(math.max(2,slot-4),h)
      bar:SetColorTexture(color and color[1] or 1,color and color[2] or .82,color and color[3] or .25,v and .85 or .25)
      bar:Show()
      label:ClearAllPoints(); label:SetPoint('BOTTOM',bar,'BOTTOM',0,-15)
      label:SetText(labels and labels[i] or ''); label:Show()
    else bar:Hide(); label:Hide() end
  end
  f.caption:SetText(caption or '')
  f:EnableMouse(formatTip~=nil)
  if formatTip then
    f:SetScript('OnEnter',function(self)
      GameTooltip:SetOwner(self,'ANCHOR_CURSOR')
      formatTip(GameTooltip)
      GameTooltip:Show()
    end)
    f:SetScript('OnLeave',GameTooltip_Hide)
  else f:SetScript('OnEnter',nil); f:SetScript('OnLeave',nil) end
  return place(f,112)
end
function VC.buttons(list)
  local f=acquire('buttons')
  for i,b in ipairs(f.buttons) do
    local spec=list[i]
    b:SetShown(spec~=nil)
    if spec then
      b:SetText(spec.label)
      if spec.disabled then b:Disable() else b:Enable() end
      b:SetScript('OnClick',function() if not spec.disabled then spec.func() end end)
      if spec.tip then setTip(b,spec.label,spec.tip) else b:SetScript('OnEnter',nil); b:SetScript('OnLeave',nil) end
    end
  end
  return place(f,30)
end
function VC.note(text,height)
  local f=acquire('note')
  f.text:SetText(text)
  local h=height or math.max(16,(f.text.GetStringHeight and tonumber((f.text:GetStringHeight())) or 14)+6)
  f:SetHeight(h)
  return place(f,h)
end

-- Graphs --------------------------------------------------------------------------------------------
-- Panels sit side by side in rows; each graph draws into one with pooled textures, text, lines and hover
-- spots, so a redraw reuses what the last one made. Everything is plain textures (and CreateLine where the
-- client has it), so it looks the same on Classic Era, Forever and retail.
factories.panel=function()
  local f=CreateFrame('Frame',nil,pageContent,BACKDROP_TEMPLATE)
  skin(f,.6,.55,.45,.28)
  f.title=fontString(f,'GameFontNormal'); f.title:SetPoint('TOPLEFT',10,-9)
  f.sub=fontString(f,'GameFontDisableSmall','RIGHT'); f.sub:SetPoint('TOPRIGHT',-10,-10)
  f.texs,f.fss,f.lns,f.spots={},{},{},{}
  return f
end
local function panelReset(f)
  for _,list in ipairs({f.texs,f.lns,f.spots}) do for _,x in ipairs(list) do x:Hide() end end
  for _,list in pairs(f.fss) do for _,x in ipairs(list) do x:Hide() end end
  f.nt,f.nl,f.ns,f.nf=0,0,0,{}
end
-- A texture: a solid color (r,g,b,a) or a file (path, then vertex color r,g,b,a).
local function ptex(f,layer,path,r,g,b,a)
  f.nt=f.nt+1
  local t=f.texs[f.nt]
  if not t then t=f:CreateTexture(nil,'ARTWORK'); f.texs[f.nt]=t end
  t:ClearAllPoints(); t:SetDrawLayer(layer or 'ARTWORK'); t:SetTexCoord(0,1,0,1); t:SetAlpha(1)
  if path then t:SetTexture(path); t:SetVertexColor(r or 1,g or 1,b or 1,a or 1)
  else t:SetColorTexture(r or 1,g or 1,b or 1,a or 1); t:SetVertexColor(1,1,1,1) end
  t:Show()
  return t
end
local function pfs(f,template,justify)
  template=template or 'GameFontHighlightSmall'
  f.fss[template]=f.fss[template] or {}
  local n=(f.nf[template] or 0)+1
  f.nf[template]=n
  local fs=f.fss[template][n]
  if not fs then fs=f:CreateFontString(nil,'OVERLAY',template); if fs.SetWordWrap then fs:SetWordWrap(false) end; f.fss[template][n]=fs end
  fs:ClearAllPoints(); fs:SetJustifyH(justify or 'LEFT'); fs:SetTextColor(1,1,1); fs:SetWidth(0); fs:Show()
  if template=='GameFontNormal' or template=='GameFontNormalLarge' or template=='GameFontNormalHuge' then fs:SetTextColor(1,.82,0) end
  if template=='GameFontDisableSmall' then fs:SetTextColor(.6,.6,.6) end
  return fs
end
-- A straight line from (x1,y1) to (x2,y2), measured from the panel's bottom left. nil on clients without lines.
local function pline(f,x1,y1,x2,y2,r,g,b,a,thick)
  if not f.CreateLine then return nil end
  f.nl=f.nl+1
  local l=f.lns[f.nl]
  if not l then l=f:CreateLine(nil,'ARTWORK'); if not l then return nil end; f.lns[f.nl]=l end
  l:SetColorTexture(r,g,b,a or 1); l:SetThickness(thick or 2)
  l:SetStartPoint('BOTTOMLEFT',f,x1,y1); l:SetEndPoint('BOTTOMLEFT',f,x2,y2)
  l:Show()
  return l
end
-- An invisible hover spot with its own tooltip.
local function pspot(f,x,y,w,h,onEnter,onClick)
  f.ns=f.ns+1
  local s=f.spots[f.ns]
  if not s then s=CreateFrame('Button',nil,f); f.spots[f.ns]=s end
  s:ClearAllPoints(); s:SetPoint('TOPLEFT',x,-y); s:SetSize(math.max(1,w),math.max(1,h))
  s:SetScript('OnEnter',onEnter); s:SetScript('OnLeave',onEnter and GameTooltip_Hide or nil)
  s:SetScript('OnClick',onClick)
  s:Show()
  return s
end
VC.graph={tex=ptex,fs=pfs,line=pline,spot=pspot}
local PANEL_TOP=32
-- A row of panels: list of {title=, sub=, weight=, draw=function(f,w,h)}.
function VC.panels(height,list)
  local gap,total=8,0
  for _,p in ipairs(list) do total=total+(p.weight or 1) end
  local x=0
  local usable=pageWidth-gap*(#list-1)
  for _,p in ipairs(list) do
    local w=math.floor(usable*(p.weight or 1)/total)
    local f=acquire('panel')
    panelReset(f)
    f:SetPoint('TOPLEFT',pageContent,'TOPLEFT',x,cursor)
    f:SetSize(w,height)
    f.title:SetText(p.title or ''); f.sub:SetText(p.sub or '')
    local ok,err=pcall(p.draw,f,w,height)
    if not ok then
      VC.panelErrors=VC.panelErrors or {}
      VC.panelErrors[#VC.panelErrors+1]=(p.title or '?')..': '..tostring(err)
      local e=pfs(f,'GameFontDisableSmall'); e:SetPoint('CENTER'); e:SetText('Couldn\'t draw: '..tostring(err))
    end
    x=x+w+gap
  end
  cursor=cursor-height-8
end
local function empty(f,text)
  local e=pfs(f,'GameFontDisableSmall','CENTER'); e:SetPoint('CENTER',0,-8); e:SetWidth(0); e:SetText(text)
end

-- Beaded ring (a donut chart made of dots) with a legend. segments: {value=, label=, color={r,g,b}}.
function VC.drawRing(f,w,h,segments,center,centerSub)
  local total=0
  for _,s in ipairs(segments) do total=total+s.value end
  if total<=0 then empty(f,'No data yet'); return end
  local radius=math.min((h-PANEL_TOP-14)/2,w*.22)
  local cx,cy=14+radius,-(PANEL_TOP+4+radius)
  -- Three rings of dots; each dot takes the color of the slice its angle falls in, clockwise from the top.
  for ring=0,2 do
    local r=radius-ring*6
    local count=math.floor(2*math.pi*r/7.5)
    for i=0,count-1 do
      local frac=(i+.5)/count
      local acc,color=0,segments[#segments].color
      for _,s in ipairs(segments) do acc=acc+s.value/total; if frac<=acc then color=s.color; break end end
      local angle=math.pi/2-frac*2*math.pi
      local d=ptex(f,'ARTWORK',DOT_TEXTURE,color[1],color[2],color[3],1)
      d:SetSize(6.5,6.5); d:SetPoint('CENTER',f,'TOPLEFT',cx+math.cos(angle)*r,cy+math.sin(angle)*r)
    end
  end
  local c=pfs(f,'GameFontNormalLarge','CENTER'); c:SetPoint('CENTER',f,'TOPLEFT',cx,cy+6); c:SetText(center or total)
  local cs=pfs(f,'GameFontDisableSmall','CENTER'); cs:SetPoint('TOP',c,'BOTTOM',0,-2); cs:SetText(centerSub or '')
  -- Legend: up to as many rows as fit, biggest first.
  local x,y=cx+radius+18,-(PANEL_TOP+2)
  local rows=math.floor((h-PANEL_TOP-8)/15)
  for i,s in ipairs(segments) do
    if i>rows then break end
    local sw=ptex(f,'ARTWORK',nil,s.color[1],s.color[2],s.color[3],1); sw:SetSize(9,9); sw:SetPoint('TOPLEFT',x,y-3)
    local l=pfs(f,'GameFontHighlightSmall'); l:SetPoint('TOPLEFT',x+14,y-1); l:SetWidth(w-x-62); l:SetText(s.label)
    local v=pfs(f,'GameFontDisableSmall','RIGHT'); v:SetPoint('TOPRIGHT',-10,y-1); v:SetText(math.floor(s.value*100/total+.5)..'%')
    y=y-15
  end
end
-- Half-circle gauge of dots, filled from the left, with the value in the middle.
function VC.drawGauge(f,w,h,value,max,big,small,color)
  color=color or {1,.82,.25}
  local radius=math.min(w/2-18,h-PANEL_TOP-30)
  local cx,cy=w/2,-(h-24)
  local frac=max>0 and math.min(1,value/max) or 0
  for ring=0,1 do
    local r=radius-ring*7
    local count=math.floor(math.pi*r/8)
    for i=0,count do
      local t=i/count
      local angle=math.pi-t*math.pi
      local on=t<=frac and frac>0
      local d=ptex(f,'ARTWORK',DOT_TEXTURE,on and color[1] or .25,on and color[2] or .22,on and color[3] or .2,on and 1 or .8)
      d:SetSize(7,7); d:SetPoint('CENTER',f,'TOPLEFT',cx+math.cos(angle)*r,cy+math.sin(angle)*r)
    end
  end
  local b=pfs(f,'GameFontNormalLarge','CENTER'); b:SetPoint('BOTTOM',f,'TOPLEFT',cx,cy+8); b:SetText(big)
  local s=pfs(f,'GameFontDisableSmall','CENTER'); s:SetPoint('TOP',b,'BOTTOM',0,-3); s:SetText(small or '')
end
-- Line graph with a soft filled area and points. values: numbers or false (unknown). mark: index to highlight.
function VC.drawLine(f,w,h,values,labels,color,mark,tipFn)
  color=color or {.35,.8,1}
  local n=#values
  local maxV=0
  for _,v in ipairs(values) do if v and v>maxV then maxV=v end end
  if maxV<=0 then empty(f,'Fills in as you play: Village Command samples who\'s online every few minutes.'); return end
  local x0,x1,y0,y1=34,w-14,22,h-PANEL_TOP-8
  local step=(x1-x0)/math.max(1,n-1)
  -- Grid and scale
  for i=0,2 do
    local y=y0+(y1-y0)*i/2
    local g=ptex(f,'BACKGROUND',nil,1,1,1,.06); g:SetHeight(1); g:SetPoint('BOTTOMLEFT',x0,y); g:SetPoint('BOTTOMRIGHT',-14,y)
    local l=pfs(f,'GameFontDisableSmall','RIGHT'); l:SetPoint('RIGHT',f,'BOTTOMLEFT',x0-4,y); l:SetText(string.format(maxV<10 and '%.1f' or '%d',maxV*i/2))
  end
  local function pt(i,v) return x0+(i-1)*step,y0+(y1-y0)*v/maxV end
  if mark and mark>=1 and mark<=n then
    local mx=pt(mark,0)
    local m=ptex(f,'BACKGROUND',nil,1,.82,0,.18); m:SetSize(math.max(4,step),y1-y0); m:SetPoint('BOTTOM',f,'BOTTOMLEFT',mx,y0)
  end
  local prevX,prevY
  for i=1,n do
    local v=values[i]
    if v then
      local x,y=pt(i,v)
      local area=ptex(f,'BORDER',nil,color[1],color[2],color[3],.18); area:SetSize(math.max(2,step),math.max(1,y-y0)); area:SetPoint('BOTTOM',f,'BOTTOMLEFT',x,y0)
      if prevX and not pline(f,prevX,prevY,x,y,color[1],color[2],color[3],1,2) then
        -- No lines on this client: a dotted trail instead.
        for k=1,3 do local d=ptex(f,'ARTWORK',DOT_TEXTURE,color[1],color[2],color[3],.8); d:SetSize(3,3); d:SetPoint('CENTER',f,'BOTTOMLEFT',prevX+(x-prevX)*k/4,prevY+(y-prevY)*k/4) end
      end
      local d=ptex(f,'OVERLAY',DOT_TEXTURE,i==mark and 1 or color[1],i==mark and .82 or color[2],i==mark and 0 or color[3],1)
      d:SetSize(i==mark and 9 or 6,i==mark and 9 or 6); d:SetPoint('CENTER',f,'BOTTOMLEFT',x,y)
      prevX,prevY=x,y
    end -- hours not sampled yet are bridged, so early data still reads as a line
    if labels and labels[i] and labels[i]~='' then
      local l=pfs(f,'GameFontDisableSmall','CENTER'); l:SetPoint('TOP',f,'BOTTOMLEFT',pt(i,0),y0-3); l:SetText(labels[i])
    end
  end
  if tipFn then pspot(f,x0,PANEL_TOP,x1-x0,h-PANEL_TOP-6,function(self) GameTooltip:SetOwner(self,'ANCHOR_CURSOR'); tipFn(GameTooltip); GameTooltip:Show() end) end
end
-- Podium for the top three: {m=, n=, text=}. First place in the middle, tallest.
function VC.drawPodium(f,w,h,top)
  if #top==0 then empty(f,'No level-ups seen this week yet. Be the first!'); return end
  local colors={{1,.82,0},{.78,.8,.86},{.85,.52,.25}}
  local heights={.62,.46,.34}
  local slots={2,1,3}
  local bw=math.min(110,(w-40)/3)
  local base=12
  local area=h-PANEL_TOP-46
  for pos=1,3 do
    local place=slots[pos]
    local e=top[place]
    local x=w/2+(pos-2)*(bw+8)
    local bh=area*heights[place]
    local c=colors[place]
    local block=ptex(f,'ARTWORK',nil,c[1]*.55,c[2]*.55,c[3]*.55,.95); block:SetSize(bw,bh); block:SetPoint('BOTTOM',f,'BOTTOMLEFT',x,base)
    local top2=ptex(f,'OVERLAY',nil,c[1],c[2],c[3],1); top2:SetSize(bw,4); top2:SetPoint('TOP',block,'TOP',0,0)
    local num=pfs(f,'GameFontNormalLarge','CENTER'); num:SetPoint('TOP',block,'TOP',0,-8); num:SetText(place); num:SetTextColor(c[1],c[2],c[3])
    if e then
      local gain=pfs(f,'GameFontHighlight','CENTER'); gain:SetPoint('TOP',num,'BOTTOM',0,-2); gain:SetText(e.text)
      local name=pfs(f,'GameFontHighlight','CENTER'); name:SetPoint('BOTTOM',block,'TOP',0,4); name:SetWidth(bw+6); name:SetText(VC.colorName(e.m))
      pspot(f,x-bw/2,h-base-bh-20,bw,bh+20,function(self) VC.memberTooltip(self,e.m) end,function() VC.focusMember(e.m.id) end)
    else
      local name=pfs(f,'GameFontDisableSmall','CENTER'); name:SetPoint('BOTTOM',block,'TOP',0,4); name:SetText('up for grabs')
    end
  end
end
-- Leaderboard rows: {label=, value=, max=, text=, color=, m=}.
function VC.drawLeaders(f,w,h,rows,emptyText)
  if #rows==0 then empty(f,emptyText or 'Nobody yet'); return end
  local y=PANEL_TOP+2
  local nameW=math.floor(w*.36)
  local rowH=math.max(16,math.min(22,math.floor((h-PANEL_TOP-8)/#rows)))
  for i,r in ipairs(rows) do
    if y+rowH>h-4 then break end
    local rank=pfs(f,'GameFontDisableSmall','RIGHT'); rank:SetPoint('TOPLEFT',4,-(y+3)); rank:SetWidth(16); rank:SetText(i)
    local name=pfs(f,'GameFontHighlightSmall'); name:SetPoint('TOPLEFT',24,-(y+3)); name:SetWidth(nameW-24); name:SetText(r.label)
    local bx,bw=nameW+4,w-nameW-60
    local bg=ptex(f,'BACKGROUND',nil,0,0,0,.5); bg:SetSize(bw,rowH-7); bg:SetPoint('TOPLEFT',bx,-(y+3))
    local c=r.color or {1,.72,.2}
    local fill=ptex(f,'ARTWORK',nil,c[1],c[2],c[3],.9); fill:SetSize(math.max(1,bw*math.min(1,(r.value or 0)/math.max(1,r.max or 1))),rowH-7); fill:SetPoint('TOPLEFT',bx,-(y+3))
    local t=pfs(f,'GameFontHighlightSmall','RIGHT'); t:SetPoint('TOPRIGHT',-8,-(y+3)); t:SetText(r.text or '')
    if r.m then pspot(f,0,y,w,rowH,function(self) VC.memberTooltip(self,r.m) end,function() VC.focusMember(r.m.id) end) end
    y=y+rowH
  end
end
-- Vertical bars, each its own color. values: numbers; labels under; counts on top.
function VC.drawBars(f,w,h,values,labels,colorFn,tipFn)
  local maxV=0
  for _,v in ipairs(values) do if v>maxV then maxV=v end end
  if maxV<=0 then empty(f,'No data yet'); return end
  local n=#values
  local x0,x1,y0=12,w-12,20
  local slot=(x1-x0)/n
  local top=h-PANEL_TOP-24
  for i,v in ipairs(values) do
    local bh=math.max(2,(v/maxV)*(top-y0))
    local r,g,b=colorFn(i,n)
    local x=x0+(i-.5)*slot
    local bar=ptex(f,'ARTWORK',nil,r,g,b,.9); bar:SetSize(math.max(3,slot-6),bh); bar:SetPoint('BOTTOM',f,'BOTTOMLEFT',x,y0)
    local cap=ptex(f,'OVERLAY',nil,math.min(1,r+.25),math.min(1,g+.25),math.min(1,b+.25),1); cap:SetSize(math.max(3,slot-6),2); cap:SetPoint('TOP',bar,'TOP')
    if v>0 then local c=pfs(f,'GameFontHighlightSmall','CENTER'); c:SetPoint('BOTTOM',bar,'TOP',0,2); c:SetText(v) end
    local l=pfs(f,'GameFontDisableSmall','CENTER'); l:SetPoint('TOP',f,'BOTTOMLEFT',x,y0-3); l:SetText(labels[i] or '')
    if tipFn then pspot(f,x-slot/2,PANEL_TOP,slot,h-PANEL_TOP,function(self) GameTooltip:SetOwner(self,'ANCHOR_RIGHT'); tipFn(GameTooltip,i); GameTooltip:Show() end) end
  end
end
-- Heat map: rows x cols of cells, brighter for busier. grid[row][col] = number or nil.
function VC.drawHeat(f,w,h,grid,rowLabels,colLabels,tipFn)
  local maxV=0
  for _,row in ipairs(grid) do for _,v in pairs(row) do if v>maxV then maxV=v end end end
  if maxV<=0 then empty(f,'Fills in as you play: who\'s online, by day and hour.'); return end
  local rows,cols=#grid,#colLabels
  local x0,y0=36,PANEL_TOP+2
  local cw=(w-x0-10)/cols
  local ch=(h-y0-18)/rows
  for r=1,rows do
    local l=pfs(f,'GameFontDisableSmall','RIGHT'); l:SetPoint('RIGHT',f,'TOPLEFT',x0-4,-(y0+(r-.5)*ch)); l:SetText(rowLabels[r])
    for c=1,cols do
      local v=grid[r][c]
      local t=v and v/maxV or 0
      local cell=ptex(f,'ARTWORK',nil,.15+.85*t,.12+.7*t,.08+.15*t,v and (.35+.65*t) or .12)
      cell:SetSize(math.max(1,cw-1),math.max(1,ch-1)); cell:SetPoint('TOPLEFT',x0+(c-1)*cw,-(y0+(r-1)*ch))
    end
  end
  for c=1,cols do
    if colLabels[c]~='' then local l=pfs(f,'GameFontDisableSmall','CENTER'); l:SetPoint('TOP',f,'TOPLEFT',x0+(c-.5)*cw,-(y0+rows*ch+2)); l:SetText(colLabels[c]) end
  end
  if tipFn then pspot(f,x0,y0,cw*cols,ch*rows,function(self) GameTooltip:SetOwner(self,'ANCHOR_CURSOR'); tipFn(GameTooltip); GameTooltip:Show() end) end
end
-- Name tiles in columns, for who's online: dot, class-colored name, level.
function VC.drawNames(f,w,h,members,more)
  if #members==0 then empty(f,'No one is online right now.'); return end
  local cols=math.max(1,math.floor(w/170))
  local cw=(w-16)/cols
  local rowH=18
  local fit=math.floor((h-PANEL_TOP-6)/rowH)*cols
  for i,m in ipairs(members) do
    if i>fit then break end
    local col,row=(i-1)%cols,math.floor((i-1)/cols)
    local x,y=10+col*cw,PANEL_TOP+row*rowH
    local d=ptex(f,'ARTWORK',DOT_TEXTURE,.2,1,.2,1); d:SetSize(8,8); d:SetPoint('TOPLEFT',x,-(y+5))
    local n=pfs(f,'GameFontHighlightSmall'); n:SetPoint('TOPLEFT',x+13,-(y+3)); n:SetWidth(cw-48); n:SetText(VC.colorName(m))
    local lv=pfs(f,'GameFontDisableSmall','RIGHT'); lv:SetPoint('TOPLEFT',x+cw-36,-(y+3)); lv:SetWidth(28); lv:SetText(m.level)
    pspot(f,x,y,cw,rowH,function(self) VC.memberTooltip(self,m) end,function() VC.focusMember(m.id) end)
  end
  if #members>fit or more then
    f.sub:SetText((#members>fit and ('+'..(#members-fit)..' more  ·  ') or '')..'click a name to open it in the roster')
  end
end

-- Pages ---------------------------------------------------------------------------------------------
VC.tabs={
  {key='overview',label='Overview',icon='Interface\\Icons\\INV_Misc_Map_01',sub='Who\'s on, what\'s new, and your other guild addons'},
  {key='roster',label='Roster',icon='Interface\\Icons\\Spell_Holy_PrayerOfFortitude',sub='Every member: notes, officer notes, promote and demote, one or many at once',
    lockedSub='Every member, with notes and officer notes. Search, filter and sort the whole guild'},
  {key='promos',label='Promotions',icon='Interface\\Icons\\Spell_Magic_GreaterBlessingofKings',sub='Rules for who\'s ready to promote, and a checklist that ticks itself off'},
  {key='progress',label='Progression',icon='Interface\\Icons\\INV_Misc_PocketWatch_01',sub='Milestones, this week\'s growth, top climbers and the activity feed'},
  {key='stats',label='Fun Stats',icon='Interface\\Icons\\INV_Misc_Spyglass_03',sub='Classes, levels, busiest hours and the guild\'s superlatives'},
  {key='forge',label='Professions',icon='Interface\\Icons\\Trade_BlackSmithing',sub='From GuildForge: who crafts what, top skills, crafters online'},
  {key='bank',label='Guild Bank',icon='Interface\\Icons\\INV_Misc_Bag_10_Blue',sub='From Un-Ninja Bank: gold, bank toons and open requests'},
}
VC.pages={}
function VC.memberTooltip(owner,m)
  GameTooltip:SetOwner(owner,'ANCHOR_RIGHT')
  GameTooltip:AddLine(m.short,VC.classColor(m.classFile))
  GameTooltip:AddLine('Level '..m.level..' '..m.class..'  ·  '..m.rank,1,1,1)
  if m.online then GameTooltip:AddLine('Online'..(m.zone~='' and (' in '..m.zone) or '')..(m.mobile and ' (mobile)' or ''),.3,1,.3)
  else GameTooltip:AddLine('Last online '..VC.agoText(m.away),.6,.6,.6) end
  if m.note~='' then GameTooltip:AddLine('Note: '..m.note,.9,.9,.6,true) end
  if m.officerNote~='' then GameTooltip:AddLine('Officer note: '..m.officerNote,.6,.85,1,true) end
  local g=VC.guildData()
  local rec=g and g.members[m.id]
  if rec then
    local week=VC.gained(rec,7)
    if week>0 then GameTooltip:AddLine('+'..week..' level'..(week==1 and '' or 's')..' this week',1,.82,0) end
    if g.baseline and rec.first>g.baseline then GameTooltip:AddLine('Joined '..VC.agoText(now()-rec.first),.7,.7,.7) end
  end
  local profs=VC.forgeProfessions()
  for _,p in ipairs(profs and profs[m.id] or {}) do
    if type(p)=='table' then GameTooltip:AddDoubleLine(p.name,(p.rank or 0)..'/'..(p.max or 0),.8,.8,.8,1,1,1) end
  end
  if VC.bankToons()[m.id] then GameTooltip:AddLine('Guild bank toon (Un-Ninja Bank)',.85,.67,.33) end
  local _,readyBy=VC.readyForPromotion()
  if readyBy[m.id] then GameTooltip:AddLine('Ready for promotion to '..(VC.rankNames()[readyBy[m.id].to] or '?'),1,.82,0) end
  if m.points then GameTooltip:AddLine(m.points..' achievement points',.7,.7,.7) end
  GameTooltip:AddLine(' ')
  GameTooltip:AddLine('|cffffd100Click|r  open in the roster',.7,.7,.7)
  GameTooltip:Show()
end
function VC.focusMember(id)
  VC.focus=id
  VC.selectTab('roster')
  VC.scrollToFocus=true
end
local function eventIcon(kind)
  return ({join='Interface\\Icons\\Spell_Holy_PrayerOfFortitude',leave='Interface\\Icons\\Ability_Rogue_Sprint',
    ding='Interface\\Icons\\Spell_Holy_SurgeOfLight',promote='Interface\\Icons\\Spell_Magic_GreaterBlessingofKings',
    demote='Interface\\Icons\\Spell_Shadow_CurseOfTounges'})[kind] or 'Interface\\Icons\\INV_Misc_Note_01'
end
function VC.feed(limit)
  local g=VC.guildData()
  local events=g and g.events or {}
  if #events==0 then
    VC.note('|cff909090Nothing yet. Joins, leaves, level milestones and rank changes show up here as Village Command sees them.|r')
    return
  end
  for i=#events,math.max(1,#events-limit+1),-1 do
    local e=events[i]
    VC.line('|cffffd100'..e.n..'|r '..(e.d or e.k),'|cff909090'..VC.agoText(now()-e.t)..'|r',{icon=eventIcon(e.k)})
  end
end
-- The overview is a dashboard: a different kind of graph for each question, and leaderboards that show
-- how well everyone's doing.
VC.pages.overview=function()
  local s=VC.stats()
  local g=VC.guildData()
  local maxLevel=VC.maxLevel()
  local weekLevels=0
  local climbers=VC.climbers(7)
  for _,c in ipairs(climbers) do weekLevels=weekLevels+c.n end
  VC.cards({
    {value=tostring(s.total),label='Members',sub=VC.rosterComplete() and 'whole roster' or 'online only: tick Show offline',onClick=function() VC.selectTab('roster') end},
    {value=string.format('%.1f',s.average),label='Average level',sub=s.topClass and ('most are '..(s.classes[s.topClass].label or s.topClass)) or ''},
    {value='|cffffd100+'..weekLevels..'|r',label='Levels this week',sub=#climbers..' member'..(#climbers==1 and '' or 's')..' leveled up',onClick=function() VC.selectTab('progress') end},
    {value=tostring(s.peak and s.peak.n or 0),label='Most online at once',sub=s.peak and (s.peak.t or 0)>0 and date and date('%b %d',s.peak.t) or 'recorded as you play'},
  })
  if not (InCombatLockdown and InCombatLockdown()) and GetGuildRosterMOTD then
    local ok,motd=pcall(GetGuildRosterMOTD)
    if ok and type(motd)=='string' and not isSecret(motd) and motd~='' then VC.note('|cff40ff40'..motd:gsub('|','||')..'|r') end
  end
  -- Who's in the village: class mix, how many are on, how many made the cap.
  local classes={}
  for _,c in pairs(s.classes) do
    local r,gr,b=VC.classColor(c.file)
    classes[#classes+1]={value=c.n,label=(c.label~='' and c.label) or 'Unknown',color={r,gr,b}}
  end
  table.sort(classes,function(a,b) if a.value~=b.value then return a.value>b.value end return a.label<b.label end)
  local pct=function(n) return s.total>0 and math.floor(n*100/s.total+.5) or 0 end
  VC.panels(180,{
    {title='Class mix',weight=1.5,draw=function(f,w,h) VC.drawRing(f,w,h,classes,s.total,'members') end},
    {title='Online now',weight=1,draw=function(f,w,h) VC.drawGauge(f,w,h,s.online,math.max(1,s.total),'|cff40ff40'..s.online..'|r',pct(s.online)..'% of the guild',{.25,1,.35}) end},
    {title='Level '..maxLevel..' club',weight=1,draw=function(f,w,h) VC.drawGauge(f,w,h,s.maxed,math.max(1,s.total),'|cffffd100'..s.maxed..'|r',pct(s.maxed)..'% at the cap',{1,.72,.15}) end},
  })
  -- Who's doing well: this week's podium and the race to the cap.
  local top={}
  for i=1,3 do if climbers[i] then top[i]={m=climbers[i].m,text='+'..climbers[i].n..' level'..(climbers[i].n==1 and '' or 's')} end end
  local race={}
  for _,m in ipairs(VC.roster) do if m.level<maxLevel then race[#race+1]=m end end
  table.sort(race,function(a,b) if a.level~=b.level then return a.level>b.level end return a.short<b.short end)
  local raceRows={}
  for i=1,math.min(#race,7) do
    local m=race[i]
    local gain=VC.gained(g and g.members[m.id],7)
    local r,gr,b=VC.classColor(m.classFile)
    raceRows[i]={label=VC.colorName(m),value=m.level,max=maxLevel,color={r,gr,b},m=m,text=m.level..(gain>0 and (' |cff40ff40+'..gain..'|r') or '')}
  end
  VC.panels(200,{
    {title='Climbers of the week',sub='levels gained in 7 days',draw=function(f,w,h) VC.drawPodium(f,w,h,top) end},
    {title='Race to '..maxLevel,sub='closest to the cap  ·  +this week',draw=function(f,w,h) VC.drawLeaders(f,w,h,raceRows,'Everyone is at the cap!') end},
  })
  -- When the village is awake: a typical day as a line, the week as a heat map.
  local hours,hourLabels={},{}
  for h=0,23 do
    local slot=g and g.hours[h]
    hours[h+1]=(slot and slot.n>0) and slot.s/slot.n or false
    hourLabels[h+1]=h%3==0 and tostring(h) or ''
  end
  local nowHour=(tonumber(date and date('%H')) or 0)+1
  VC.panels(170,{
    {title='A typical day',sub='average online by hour  ·  now is highlighted',draw=function(f,w,h)
      VC.drawLine(f,w,h,hours,hourLabels,{.35,.8,1},nowHour,function(tip)
        tip:AddLine('Average online by hour',1,.82,0)
        for i=1,24 do if hours[i] then tip:AddDoubleLine(string.format('%02d:00',i-1),string.format('%.1f',hours[i]),.8,.8,.8,1,1,1) end end
      end)
    end},
  })
  local days={'Mon','Tue','Wed','Thu','Fri','Sat','Sun'}
  local grid,best,bestAvg={},nil,0
  for r=1,7 do
    local wday=r%7 -- Monday first; the game counts Sunday as 0
    grid[r]={}
    for h=0,23 do
      local slot=g and g.week and g.week[wday*24+h]
      if slot and slot.n>0 then
        grid[r][h+1]=slot.s/slot.n
        if slot.s/slot.n>bestAvg then bestAvg,best=slot.s/slot.n,days[r]..' '..string.format('%02d:00',h) end
      end
    end
  end
  local cols={}
  for h=0,23 do cols[h+1]=h%6==0 and tostring(h) or '' end
  local fame=VC.hallOfFame()
  local fameRows={}
  for i=1,math.min(#fame,8) do
    local e=fame[i]
    fameRows[i]={label='|cffffd100'..e.name..'|r',value=1,max=1,color={.85,.65,.15},text=date and date('%b %d',e.t) or '',m=VC.byId[VC.nameId(e.name) or '']}
  end
  VC.panels(190,{
    {title='Weekly rhythm',sub=best and ('busiest: '..best) or '',weight=1.7,draw=function(f,w,h)
      VC.drawHeat(f,w,h,grid,days,cols,function(tip) tip:AddLine('Weekly rhythm',1,.82,0); if best then tip:AddLine('Busiest: '..best..string.format(' (%.1f online)',bestAvg),1,1,1) end end)
    end},
    {title='Hall of fame',sub='reached level '..maxLevel,weight=1,draw=function(f,w,h) VC.drawLeaders(f,w,h,fameRows,'Nobody yet: who\'ll be first?') end},
  })
  -- How fast the guild grows: levels per day, and where everyone is.
  local perDay=VC.levelsByDay(14)
  local dayLabels={}
  for i=1,14 do dayLabels[i]=(i%2==0 or i==14) and (date and date('%d',now()-(14-i)*DAY) or '') or '' end
  local spread,spreadLabels={},{}
  for b=0,math.floor(maxLevel/10) do
    if b*10<=maxLevel then
      spread[#spread+1]=s.brackets[b] or 0
      spreadLabels[#spreadLabels+1]=b==0 and '1-9' or (b*10==maxLevel and tostring(maxLevel) or (b*10)..'s')
    end
  end
  VC.panels(160,{
    {title='Levels gained per day',sub='whole guild, last 14 days',draw=function(f,w,h)
      VC.drawBars(f,w,h,perDay,dayLabels,function() return .3,.85,.45 end,function(tip,i)
        tip:AddLine((date and date('%A %b %d',now()-(14-i)*DAY)) or ('Day '..i),1,.82,0); tip:AddLine(perDay[i]..' levels gained',1,1,1)
      end)
    end},
    {title='Level spread',sub='members by level',draw=function(f,w,h)
      VC.drawBars(f,w,h,spread,spreadLabels,function(i,n) local t=(i-1)/math.max(1,n-1); return .3+.7*t,.5+.32*t,1-.8*t end)
    end},
  })
  -- Who's on right now, as a compact grid.
  local online={}
  for _,m in ipairs(VC.roster) do if m.online then online[#online+1]=m end end
  table.sort(online,function(a,b) if a.rankIndex~=b.rankIndex then return a.rankIndex<b.rankIndex end return a.short<b.short end)
  local perRow=math.max(1,math.floor(pageWidth/170))
  local rowsNeeded=math.min(6,math.max(1,math.ceil(#online/perRow)))
  VC.panels(32+rowsNeeded*18+10,{{title='Online now ('..#online..')',draw=function(f,w,h) VC.drawNames(f,w,h,online) end}})
  VC.section('Recent activity')
  stripe=0
  VC.feed(5)
  VC.section('Your guild addons')
  stripe=0
  local forge=VC.professionSummary()
  if forge then
    local covered=0
    for _,p in pairs(forge) do if p.count>0 then covered=covered+1 end end
    VC.line('|cffe7c483GuildForge|r  '..covered..' of '..#VC.professionList..' professions covered','Open GuildForge',
      {icon=VC.professionIcons.Blacksmithing,onClick=VC.openForge})
  else
    VC.line('|cff909090GuildForge|r  not installed: guild professions, recipes and crafters','',{icon=VC.professionIcons.Blacksmithing})
  end
  local bank=VC.hasBank() and VC.bankSummary()
  if bank then
    VC.line('|cffd8aa55Un-Ninja Bank|r  '..VC.money(bank.gold)..'  ·  '..bank.open..' open request'..(bank.open==1 and '' or 's'),'Open Un-Ninja Bank',
      {icon='Interface\\Icons\\INV_Misc_Bag_10_Blue',onClick=function() VC.openBank() end})
  elseif VC.bankAPI() then
    VC.line('|cffd8aa55Un-Ninja Bank|r  no bank toons set up for this guild yet','Open Un-Ninja Bank',
      {icon='Interface\\Icons\\INV_Misc_Bag_10_Blue',onClick=function() VC.openBank('gm') end})
  else
    VC.line('|cff909090Un-Ninja Bank|r  not installed: the guild bank, requests and donations','',{icon='Interface\\Icons\\INV_Misc_Bag_10_Blue'})
  end
end
local MILESTONES={10,25,50,75,100,150,200,250,300,400,500,750,1000}
VC.pages.progress=function()
  local s=VC.stats()
  local maxLevel=VC.maxLevel()
  VC.section('Milestones')
  local nextSize=MILESTONES[#MILESTONES]
  for _,n in ipairs(MILESTONES) do if s.total<n then nextSize=n; break end end
  VC.bar('Roster size',s.total,nextSize,s.total..' / '..nextSize,{.3,.7,1},'Interface\\Icons\\Spell_Holy_PrayerOfFortitude','next milestone: '..nextSize)
  VC.bar('At the level cap',s.maxed,math.max(1,s.total),s.maxed..' / '..s.total,{1,.72,.2},'Interface\\Icons\\Spell_Holy_SurgeOfLight','level '..maxLevel)
  VC.bar('Average level',s.average,maxLevel,string.format('%.1f / %d',s.average,maxLevel),{.4,1,.4},'Interface\\Icons\\INV_Misc_PocketWatch_01')
  local forge=VC.professionSummary()
  if forge then
    local covered,artisans=0,0
    for _,p in pairs(forge) do if p.count>0 then covered=covered+1 end; artisans=artisans+p.maxed end
    VC.bar('Professions covered',covered,#VC.professionList,covered..' / '..#VC.professionList,{.9,.55,.25},VC.professionIcons.Blacksmithing,'from GuildForge')
    VC.bar('Skills at 300',artisans,math.max(artisans,s.total),tostring(artisans),{.64,.21,.93},VC.professionIcons.Enchanting,'across all members')
  end
  local week=VC.eventsSince(7*DAY)
  local levels=0
  for _,c in ipairs(VC.climbers(7)) do levels=levels+c.n end
  VC.section('This week')
  VC.cards({
    {value='|cffffd100+'..levels..'|r',label='Levels gained',sub=week.ding..' milestone dings'},
    {value='|cff40ff40'..week.join..'|r',label='New members',sub=week.leave..' left'},
    {value=tostring(week.promote),label='Promotions',sub=week.demote..' demotions'},
    {value=s.peak and tostring(s.peak.n or 0) or '0',label='Most online at once',sub=s.peak and s.peak.t and s.peak.t>0 and (date and date('%b %d',s.peak.t) or '') or 'not sampled yet'},
  })
  local days=VillageCommandDB.ui.climbDays or 7
  VC.section('Top climbers, last '..days..' days','click the button to switch')
  VC.buttons({
    {label='Last 7 days',disabled=days==7,func=function() VillageCommandDB.ui.climbDays=7; requestRedraw() end},
    {label='Last 30 days',disabled=days==30,func=function() VillageCommandDB.ui.climbDays=30; requestRedraw() end},
  })
  stripe=0
  local climbers=VC.climbers(days)
  local best=climbers[1] and climbers[1].n or 1
  for i=1,math.min(#climbers,15) do
    local c=climbers[i]
    VC.bar(i..'. '..VC.colorName(c.m),c.n,best,'+'..c.n,{VC.classColor(c.m.classFile)},nil,'level '..c.from..' -> '..c.m.level,
      function(self) VC.memberTooltip(self,c.m) end)
  end
  if #climbers==0 then VC.note('|cff909090No level-ups seen yet. Village Command records levels as it sees the roster, so this fills in over the coming days.|r') end
  VC.section('Activity feed')
  stripe=0
  VC.feed(40)
end
VC.pages.stats=function()
  local s=VC.stats()
  local g=VC.guildData()
  local function who(m,extra) return m and (VC.colorName(m)..(extra and ('  |cff909090'..extra..'|r') or '')) or '|cff909090not yet known|r' end
  VC.cards({
    {value=s.peak and tostring(s.peak.n or 0) or '0',label='Peak online',sub=s.peak and s.peak.t and s.peak.t>0 and date and date('%b %d, %H:%M',s.peak.t) or 'recorded as you play'},
    {value=s.busyHour and string.format('%02d:00',s.busyHour) or '-',label='Busiest hour',sub=s.busyAvg and string.format('%.1f online on average',s.busyAvg) or 'needs a few sessions'},
    {value=s.hotZone or '-',label='Hot spot',sub=s.hotZoneN and (s.hotZoneN..' guildmates there now') or 'nobody out and about'},
    {value=s.rareClass and s.classes[s.rareClass] and s.classes[s.rareClass].label or '-',label='Rarest class',sub='the guild could use more'},
  })
  VC.section('Superlatives')
  stripe=0
  VC.line('Ding champion',who(s.dinger,s.dingerN and ('+'..s.dingerN..' levels this week')),{icon='Interface\\Icons\\Spell_Holy_SurgeOfLight',onEnter=s.dinger and function(self) VC.memberTooltip(self,s.dinger) end})
  VC.line('Night owl',who(s.owl,s.owlN and (s.owlN..' late-night sightings')),{icon='Interface\\Icons\\Spell_Shadow_Twilight'})
  VC.line('Early bird',who(s.bird,s.birdN and (s.birdN..' dawn sightings')),{icon='Interface\\Icons\\Spell_Holy_HolyBolt'})
  VC.line('Always around',who(s.regular,s.regularN and ('online in '..s.regularN..' samples')),{icon='Interface\\Icons\\INV_Misc_PocketWatch_01'})
  VC.line('Fresh blood',who(s.newest,s.newestT and ('joined '..VC.agoText(now()-s.newestT))),{icon='Interface\\Icons\\Spell_Holy_PrayerOfFortitude'})
  VC.line('Wanderer',who(s.wanderer,s.wanderer and ('last seen '..VC.agoText(s.wanderer.away))),{icon='Interface\\Icons\\Ability_Rogue_Sprint'})
  VC.line('Alt army',s.altKing and ('|cffffd100'..s.altKing:gsub('^%l',string.upper)..'|r  |cff909090'..s.altKingN..' alts in notes|r') or ('|cff909090'..s.alts..' notes mention an alt|r'),{icon='Interface\\Icons\\INV_Misc_GroupNeedMore'})
  VC.line('Blank slates',s.noNote..' member'..(s.noNote==1 and '' or 's')..' without a public note',{icon='Interface\\Icons\\INV_Misc_Note_01'})
  if s.achiever then VC.line('Achievement hunter',who(s.achiever,s.achiever.points..' points'),{icon='Interface\\Icons\\INV_Misc_Coin_01'}) end
  VC.section('When the village is awake','average online by hour, from your sessions')
  local values,labels={},{}
  for h=0,23 do
    local slot=g and g.hours[h]
    values[h+1]=(slot and slot.n>0) and slot.s/slot.n or false
    labels[h+1]=h%3==0 and tostring(h) or ''
  end
  VC.chart(values,labels,'hours of the day',nil,function(tip)
    tip:AddLine('Average online by hour',1,.82,0)
    for h=0,23 do if values[h+1] then tip:AddDoubleLine(string.format('%02d:00',h),string.format('%.1f',values[h+1]),.8,.8,.8,1,1,1) end end
  end)
  VC.section('Classes')
  local classes={}
  for _,c in pairs(s.classes) do classes[#classes+1]=c end
  table.sort(classes,function(a,b) if a.n~=b.n then return a.n>b.n end return tostring(a.label)<tostring(b.label) end)
  local most=classes[1] and classes[1].n or 1
  for _,c in ipairs(classes) do
    VC.bar(c.label~='' and c.label or 'Unknown',c.n,most,tostring(c.n),{VC.classColor(c.file)},nil,math.floor(c.n*100/math.max(1,s.total)+.5)..'%')
  end
  VC.section('Levels')
  local maxLevel=VC.maxLevel()
  local top=0
  for _,n in pairs(s.brackets) do if n>top then top=n end end
  for b=0,math.floor(maxLevel/10) do
    local n=s.brackets[b] or 0
    local lo,hi=math.max(1,b*10),math.min(maxLevel,b*10+9)
    if lo<=maxLevel then VC.bar(lo==hi and ('Level '..lo) or ('Levels '..lo..'-'..hi),n,math.max(1,top),tostring(n),{.4,.75,1}) end
  end
  VC.section('Ranks')
  local names=VC.rankNames()
  for i=0,VC.lowestRank() do
    if names[i] or s.ranks[i] then VC.bar(names[i] or ('Rank '..i),s.ranks[i] or 0,math.max(1,s.total),tostring(s.ranks[i] or 0),{.85,.68,.3}) end
  end
  VC.buttons({{label='Reset statistics',func=function() VC.ask('Reset Village Command\'s statistics for this guild?\n\nLevel history, the activity feed and online records start over. Notes and ranks in the game are not touched.',VC.resetStats) end,tip='Start the history, records and activity feed over for this guild.'}})
end
VC.pages.forge=function()
  local summary=VC.professionSummary()
  if not summary then
    VC.section('GuildForge')
    VC.note(VC.hasForge() and 'GuildForge is loaded but hasn\'t heard from this guild yet. Open it and press Sync Guild, then come back.'
      or 'Install |cffe7c483GuildForge|r to see your guild\'s professions here: who has each one, the top skill, and who\'s online to craft. It shares professions and recipes between guildmates automatically.')
    if VC.hasForge() then VC.buttons({{label='Open GuildForge',func=VC.openForge}}) end
    return
  end
  VC.buttons({{label='Open GuildForge',func=VC.openForge,tip='Recipes, reagents, craft requests and cooldowns.'}})
  VC.section('Professions','(members) · best crafter · online now')
  stripe=0
  for _,name in ipairs(VC.professionList) do
    local p=summary[name]
    -- Name and member count on the left, the best crafter's skill in the bar, who's online on the right.
    local label=name..'  |cff909090('..p.count..')|r'
    local inBar=p.count>0 and p.topName and (p.topName..'  '..p.top..(p.max>0 and ('/'..p.max) or '')) or ''
    local right=p.count==0 and '|cff909090nobody yet|r' or (p.online>0 and ('|cff40ff40'..p.online..' online|r') or '|cff909090none online|r')
    VC.bar(label,p.top,math.max(p.max,300,1),inBar,{.9,.55,.25},VC.professionIcons[name],right,function(self)
      GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
      GameTooltip:AddLine(name,1,.82,0)
      table.sort(p.members,function(a,b) return a.rank>b.rank end)
      for i=1,math.min(#p.members,20) do
        local e=p.members[i]
        local label=e.m and VC.colorName(e.m) or e.id
        GameTooltip:AddDoubleLine(label..(e.m and e.m.online and '  |cff40ff40online|r' or ''),e.rank..'/'..e.max,1,1,1,1,1,1)
      end
      if #p.members>20 then GameTooltip:AddLine('and '..(#p.members-20)..' more',.6,.6,.6) end
      GameTooltip:Show()
    end)
  end
  VC.section('Crafters online now')
  stripe=0
  local profs=VC.forgeProfessions() or {}
  local any=false
  for _,m in ipairs(VC.roster) do
    if m.online and profs[m.id] then
      local parts={}
      for _,p in ipairs(profs[m.id]) do if type(p)=='table' then parts[#parts+1]=p.name..' '..(p.rank or 0) end end
      if #parts>0 then
        any=true
        VC.line(VC.colorName(m),table.concat(parts,', '),{online=true,onClick=function() VC.focusMember(m.id) end,onEnter=function(self) VC.memberTooltip(self,m) end})
      end
    end
  end
  if not any then VC.note('|cff909090No crafters online right now.|r') end
end
VC.pages.promos=function()
  local rules=VC.rules()
  local names=VC.rankNames()
  local locked=VC.gameLocked()
  VC.note(locked and 'Set a rule and Village Command lists who qualifies. Promote them in the game\'s guild window (J); each one drops off this list as the roster shows their new rank.'
    or 'Set a rule and Village Command lists who qualifies. Promote them all at once with Promote all, or one at a time from the roster.')
  VC.buttons({{label='Add a rule',func=function() VC.openRuleDialog() end,tip='Pick a rank to promote from and to, and what someone needs to qualify.'}})
  if #rules==0 then
    VC.section('No rules yet')
    VC.note('|cff909090For example: '..(names[VC.lowestRank()] or 'Initiate')..' -> '..(names[math.max(0,VC.lowestRank()-1)] or 'Member')..' at level 10+, after 7 days in the guild, if they\'ve been online in the last week.|r')
    return
  end
  for i,r in ipairs(rules) do
    local ready,skipped,done=VC.ruleMembers(r)
    local heading=(names[r.from] or ('Rank '..r.from))..'  ->  '..(names[r.to] or ('Rank '..r.to))
    if r.off then
      -- A rule that's switched off keeps its settings but lists nobody and counts nowhere.
      VC.section('|cff909090'..heading..'  (off)|r','switched off')
      VC.note('|cff707070'..VC.ruleText(r)..'|r')
      VC.buttons({
        {label='Turn on',func=function() r.off=nil; requestRedraw() end},
        {label='Edit rule',func=function() VC.openRuleDialog(i) end},
        {label='Delete rule',func=function() VC.ask('Delete the rule '..heading..'?',function() VC.deleteRule(i) end) end},
      })
    else
    VC.section(heading,#ready..' ready'..(#skipped>0 and ('  ·  '..#skipped..' skipped') or '')..'  ·  right-click someone to skip')
    VC.note('|cffa0a0a0'..VC.ruleText(r)..'|r')
    local buttons={
      {label='Turn off',func=function() r.off=true; requestRedraw() end,tip='Keep the rule but stop listing and counting anyone for it.'},
      {label='Edit rule',func=function() VC.openRuleDialog(i) end},
      {label='Delete rule',func=function()
        VC.ask('Delete the rule '..(names[r.from] or '?')..' -> '..(names[r.to] or '?')..'?',function() VC.deleteRule(i) end)
      end},
    }
    if locked then
      buttons[#buttons+1]={label='Promote helper',disabled=#ready==0,func=function() VC.openPromoteHelper(i) end,
        tip='A small window that promotes the next few people here with each click: the game runs a /gpromote line for each, which works on WoW Forever even though addons can\'t promote directly.'}
    else
      local perms=VC.perms(true)
      buttons[#buttons+1]={label='Promote all '..#ready,disabled=#ready==0 or not perms.promote,func=function() VC.promoteRule(r) end,
        tip=perms.promote and 'Promotes everyone listed, one at a time, after asking.' or VC.deny(perms,'promote','Your rank can\'t promote')}
    end
    if #skipped>0 then
      buttons[#buttons+1]={label=r.showSkipped and 'Hide skipped' or ('Show skipped ('..#skipped..')'),func=function() r.showSkipped=not r.showSkipped; requestRedraw() end}
    end
    VC.buttons(buttons)
    stripe=0
    local function row(m,isSkipped)
      local days=VC.daysIn(m)
      VC.line(VC.colorName(m)..'  |cff909090'..m.level..'|r'..(isSkipped and '  |cff909090(skipped)|r' or ''),
        (m.online and ('|cff40ff40'..(m.zone~='' and m.zone or 'online')..'|r') or ('|cff909090'..VC.agoText(m.away)..'|r'))..'  ·  '..days..'d in guild',
        {online=m.online,onEnter=function(self) VC.memberTooltip(self,m) end,onClick=function(self,mouse)
          if mouse=='RightButton' then
            VC.showMenu(self,{
              {text=isSkipped and 'Put back on the list' or 'Skip for this rule',func=function() r.skip=r.skip or {}; r.skip[m.id]=(not isSkipped) or nil; requestRedraw() end},
              {text='Open in the roster',func=function() VC.focusMember(m.id) end},
            })
          else VC.focusMember(m.id) end
        end})
    end
    for _,m in ipairs(ready) do row(m,false) end
    if #ready==0 then VC.note('|cff909090Nobody is ready right now.|r') end
    if r.showSkipped then for _,m in ipairs(skipped) do row(m,true) end end
    if #done>0 then VC.note('|cff40ff40Promoted this week:|r '..table.concat(done,', ')) end
    end
  end
  VC.note('|cff909090Days in the guild count from when Village Command first saw each member on this PC.|r')
end
VC.pages.bank=function()
  if not VC.bankAPI() then
    VC.section('Un-Ninja Bank')
    VC.note('Install |cffd8aa55Un-Ninja Bank|r to see the guild bank here: bank toons\' bags and gold, requests and donations, browsable even while the bank toons are offline.')
    return
  end
  VC.buttons({
    {label='Open bank',func=function() VC.openBank('items') end},
    {label='Requests',func=function() VC.openBank('requests') end},
    {label='Ledger',func=function() VC.openBank('donations') end},
    {label='Goals',func=function() VC.openBank('goals') end},
  })
  if not VC.hasBank() then
    VC.note('This guild has no bank toons yet. The guild master or an officer adds them on Un-Ninja Bank\'s Guild tab.')
    VC.buttons({{label='Set up bank toons',func=function() VC.openBank('gm') end}})
    return
  end
  local b=VC.bankSummary()
  local week
  if b.series then
    local first=b.series[#b.series-7]
    local last=b.series[#b.series]
    if first and last then week=last-first end
  end
  VC.cards({
    {value=VC.money(b.gold),label='Bank gold',sub=#b.banks..' bank toon'..(#b.banks==1 and '' or 's')..' and tabs'},
    {value=week and ((week>=0 and '|cff40ff40+' or '|cffff6060-')..VC.money(math.abs(week))..'|r') or '-',label='Last 7 days',sub='change in bank gold'},
    {value=tostring(b.open),label='Open requests',sub='waiting or approved',onClick=function() VC.openBank('requests') end},
    {value=tostring(VC.onlineCount()),label='Guildmates online',sub='who could donate'},
  })
  if b.series then
    local values,labels={},{}
    for i,v in ipairs(b.series) do values[i]=v and v/10000 or false; labels[i]=(i==#b.series and 'today') or ((#b.series-i)%7==0 and ((#b.series-i)..'d') or '') end
    VC.section('Bank gold, last '..#b.series..' days')
    VC.chart(values,labels,'gold at the end of each day',{.95,.8,.3},function(tip)
      tip:AddLine('Bank gold by day',1,.82,0)
      for i,v in ipairs(b.series) do if v then tip:AddDoubleLine((#b.series-i)==0 and 'Today' or ((#b.series-i)..' days ago'),VC.money(v),.8,.8,.8,1,1,1) end end
    end)
  end
  VC.section('Bank toons and tabs')
  stripe=0
  for _,bank in ipairs(b.banks) do
    local m=bank.id and VC.byId[bank.id]
    VC.line(bank.tab and ('|cffd8aa55'..bank.name..'|r') or (m and VC.colorName(m) or bank.name),bank.gold and VC.money(bank.gold) or '',
      {online=(not bank.tab) and (m and m.online or false) or nil,icon=bank.tab and 'Interface\\Icons\\INV_Misc_Bag_10_Blue' or nil})
  end
  VC.section('Open requests ('..b.open..')')
  stripe=0
  for i=1,math.min(#b.requests,15) do
    local r=b.requests[i]
    VC.line('|cffffd100'..r.by..'|r  '..r.text,r.status=='approved' and '|cff40ff40Approved|r' or '|cffffd100Waiting|r',{onClick=function() VC.openBank('requests') end})
  end
  if b.open==0 then VC.note('|cff909090No open requests.|r') end
end

-- Roster page ---------------------------------------------------------------------------------------
-- A virtual list (only the visible rows exist) so a thousand-member guild scrolls smoothly.
VC.filters={text='',rank=nil,minLevel=nil,awayDays=nil}
VC.columns={
  {key='name',label='Name',x=40,w=170},
  {key='level',label='Lvl',x=214,w=30},
  {key='rank',label='Rank',x=250,w=118},
  {key='zone',label='Zone / last online',x=372,w=150},
  {key='note',label='Note',x=526,w=160},
  {key='officer',label='Officer note',x=690,w=126},
}
local sorters={
  name=function(m) return m.short:lower() end,
  level=function(m) return m.level end,
  rank=function(m) return m.rankIndex end,
  zone=function(m) return m.online and -1 or (m.away or 1e12) end,
  note=function(m) return m.note:lower() end,
  officer=function(m) return m.officerNote:lower() end,
}
function VC.filtered()
  if not VC.filterDirty and VC.filterCache then return VC.filterCache end
  local f,list=VC.filters,{}
  local text=(f.text or ''):lower()
  local onlineOnly=VillageCommandDB.ui.onlineOnly
  for _,m in ipairs(VC.roster) do
    local ok=true
    if onlineOnly and not m.online then ok=false end
    if ok and f.rank and m.rankIndex~=f.rank then ok=false end
    if ok and f.minLevel and m.level<f.minLevel then ok=false end
    if ok and f.maxLevel and m.level>f.maxLevel then ok=false end
    if ok and f.awayDays and (m.online or (m.away or 0)<f.awayDays*DAY) then ok=false end
    if ok and text~='' then
      ok=(m.short:lower():find(text,1,true) or m.note:lower():find(text,1,true) or m.officerNote:lower():find(text,1,true)
        or m.zone:lower():find(text,1,true) or m.class:lower():find(text,1,true) or m.rank:lower():find(text,1,true)) and true or false
    end
    if ok then list[#list+1]=m end
  end
  local sort=VillageCommandDB.ui.sort
  local key=sorters[sort.key] or sorters.rank
  table.sort(list,function(a,b)
    local x,y=key(a),key(b)
    if x~=y then if sort.desc then return x>y end return x<y end
    if a.rankIndex~=b.rankIndex then return a.rankIndex<b.rankIndex end
    return a.short<b.short
  end)
  VC.filterCache,VC.filterDirty=list,false
  return list
end
local rows={}
local function makeRow(parent)
  local b=CreateFrame('Button',nil,parent)
  b:SetHeight(ROW_H)
  b:RegisterForClicks('LeftButtonUp','RightButtonUp')
  b.stripe=b:CreateTexture(nil,'BACKGROUND'); b.stripe:SetAllPoints()
  b.sel=b:CreateTexture(nil,'BORDER'); b.sel:SetAllPoints()
  b.sel:SetTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight'); b.sel:SetBlendMode('ADD'); b.sel:SetVertexColor(1,.75,.2)
  b.check=CreateFrame('CheckButton',nil,b,'UICheckButtonTemplate'); b.check:SetSize(20,20); b.check:SetPoint('LEFT',2,0)
  b.dot=b:CreateTexture(nil,'ARTWORK'); b.dot:SetTexture(DOT_TEXTURE); b.dot:SetSize(8,8); b.dot:SetPoint('LEFT',26,0)
  b.cells={}
  for _,c in ipairs(VC.columns) do
    local fs=fontString(b,c.key=='name' and 'GameFontHighlight' or 'GameFontHighlightSmall',c.key=='level' and 'CENTER' or 'LEFT')
    fs:SetPoint('LEFT',c.x,0); fs:SetWidth(c.w)
    b.cells[c.key]=fs
  end
  addHighlight(b,.3)
  return b
end
function VC.toggleSelect(id,value)
  if value==nil then value=not VC.selected[id] end
  VC.selected[id]=value or nil
end
function VC.rowClick(b,mouse)
  local m=b.member
  if not m then return end
  if mouse=='RightButton' then VC.memberMenu(b,m); return end
  local list=VC.filtered()
  if IsShiftKeyDown and IsShiftKeyDown() and VC.anchorId then
    -- Shift-click ticks everyone between the last clicked row and this one.
    local a,z
    for i,x in ipairs(list) do if x.id==VC.anchorId then a=i end; if x.id==m.id then z=i end end
    if a and z then for i=math.min(a,z),math.max(a,z) do VC.selected[list[i].id]=true end end
  elseif IsControlKeyDown and IsControlKeyDown() then
    VC.toggleSelect(m.id)
  end
  VC.anchorId=m.id
  VC.focus=m.id
  requestRedraw()
end
function VC.memberMenu(anchor,m)
  local perms=VC.perms(false)
  local up,upWhy=VC.canStep(m,m.rankIndex,1,perms)
  local down,downWhy=VC.canStep(m,m.rankIndex,-1,perms)
  local invite=(C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
  local tell=ChatFrame_SendTell or (ChatFrameUtil and ChatFrameUtil.SendTell)
  local items={
    {text='Whisper '..m.short,func=function() if tell then tell(m.name) end end,disabled=not tell},
    {text='Invite to group',func=function() if invite then invite(m.name) end end,disabled=not invite or not m.online},
  }
  -- Rank changes and ticking only where the game lets addons change anything.
  if not VC.gameLocked() then
    items[#items+1]={text='Promote',func=function() VC.runNow('Promoted '..m.short,(VC.rankJobs({m},1,nil,true))) end,disabled=not up,tip=upWhy}
    items[#items+1]={text='Demote',func=function() VC.runNow('Demoted '..m.short,(VC.rankJobs({m},-1,nil,true))) end,disabled=not down,tip=downWhy}
    items[#items+1]={text=VC.selected[m.id] and 'Untick' or 'Tick for a mass action',func=function() VC.toggleSelect(m.id); requestRedraw() end}
  end
  VC.showMenu(anchor,items)
end
function VC.drawRows()
  if not rosterPage or not rosterPage:IsShown() then return end
  local list=VC.filtered()
  local scroll=rosterPage.scroll
  local content=rosterPage.content
  content:SetHeight(math.max(1,#list*ROW_H))
  local width=tonumber((scroll:GetWidth())) or 0
  if width>100 then content:SetWidth(width) end
  local offset=scroll:GetVerticalScroll() or 0
  local height=tonumber((scroll:GetHeight())) or 300
  local first=math.floor(offset/ROW_H)+1
  local count=math.ceil(height/ROW_H)+1
  local canView=VC.perms().viewOfficer
  local locked=VC.gameLocked()
  for i=1,count do
    local b=rows[i]
    if not b then b=makeRow(content); rows[i]=b end
    local index=first+i-1
    local m=list[index]
    b.member=m
    if m then
      b:ClearAllPoints(); b:SetPoint('TOPLEFT',content,'TOPLEFT',0,-(index-1)*ROW_H); b:SetPoint('RIGHT',content,'RIGHT',0,0)
      b.stripe:SetColorTexture(1,1,1,index%2==0 and .04 or 0)
      b.sel:SetShown(VC.focus==m.id)
      b.check:SetChecked(VC.selected[m.id] and true or false)
      b.check:SetShown(not locked)
      b.check:SetScript('OnClick',function(self) VC.toggleSelect(m.id,self:GetChecked() and true or false); VC.anchorId=m.id; VC.updateActionBar() end)
      setDot(b.dot,m.online)
      b.cells.name:SetText(VC.colorName(m)..(m.mobile and ' |cff909090(m)|r' or ''))
      b.cells.level:SetText(m.level)
      b.cells.rank:SetText(m.rank)
      b.cells.zone:SetText(m.online and m.zone or ('|cff909090'..VC.agoText(m.away)..'|r'))
      b.cells.note:SetText(m.note)
      b.cells.officer:SetText(canView and ('|cff99ccff'..m.officerNote..'|r') or '|cff606060hidden|r')
      b:SetScript('OnClick',VC.rowClick)
      b:SetScript('OnEnter',function(self) VC.memberTooltip(self,m) end)
      b:SetScript('OnLeave',GameTooltip_Hide)
      b:Show()
    else b:Hide() end
  end
  for i=count+1,#rows do rows[i]:Hide() end
end
function VC.updateActionBar()
  if not rosterPage then return end
  local p=rosterPage
  local n=0
  for _ in pairs(VC.selected) do n=n+1 end
  local list=VC.filtered()
  p.count:SetText(#list..' shown')
  p.ticked:SetText(n>0 and ('|cffffd100'..n..' ticked|r') or '|cff909090Nothing ticked|r')
  local perms=VC.perms(true)
  local single=VC.perms(false)
  local busy=VC.busy()
  local function set(b,ok,why)
    if ok and not busy then b:Enable() else b:Disable() end
    b.why=busy and ('Working: '..(VC.queue.label or '')..'. Wait or cancel.') or why
  end
  set(p.promote,n>0 and perms.promote,n==0 and 'Tick members first' or VC.deny(perms,'promote','Your rank can\'t promote'))
  set(p.demote,n>0 and perms.demote,n==0 and 'Tick members first' or VC.deny(perms,'demote','Your rank can\'t demote'))
  set(p.setRank,n>0 and (perms.promote or perms.demote),n==0 and 'Tick members first' or VC.deny(perms,'promote',VC.deny(perms,'demote','Your rank can\'t change ranks')))
  set(p.massNote,n>0 and perms.publicNote,n==0 and 'Tick members first' or VC.deny(perms,'publicNote','Your rank can\'t edit public notes'))
  set(p.massOfficer,n>0 and perms.officerNote,n==0 and 'Tick members first' or VC.deny(perms,'officerNote','Your rank can\'t edit officer notes'))
  -- Where the game keeps every rank and note change for itself, there's nothing to tick for: say so instead.
  local locked=VC.gameLocked()
  p.tick:SetShown(not locked); p.ticked:SetShown(not locked); p.all:SetShown(not locked)
  p.checklist:SetShown(locked)
  if locked then
    local ready=#(VC.readyForPromotion())
    p.checklist:SetText(ready>0 and ('Promotions ('..ready..')') or 'Promotion checklist')
  end
  p.barHint:SetText(locked and VC.LOCKED_TEXT or VC.TICK_HINT)
  p.barHint:ClearAllPoints(); p.barHint:SetPoint('RIGHT',-12,0)
  p.working:SetShown(busy)
  p.actions:SetShown(n>0 and not busy and not locked)
  p.barHint:SetShown(locked or (n==0 and not busy))
  if busy then
    local q=VC.queue
    p.progress:SetText(string.format('|cffffd100%s|r  %d / %d',q.label or 'Working',q.pos,#q.list))
  end
  -- The editor for the clicked member.
  local m=VC.focus and VC.byId[VC.focus]
  local e=p.editor
  if m then
    e.name:SetText(VC.colorName(m)..'  |cffa0a0a0Level '..m.level..' '..m.class..'  ·  '..m.rank..'  ·  '..(m.online and ('|cff40ff40'..(m.zone~='' and m.zone or 'online')..'|r') or ('last online '..VC.agoText(m.away)))..'|r')
    -- Refill the boxes only for a different member or when the note changed in the game, so half-typed
    -- text survives the roster refreshing.
    local officerText=single.viewOfficer and m.officerNote or ''
    if e.shownFor~=m.id or (e.lastNote~=m.note and not e.note:HasFocus()) then e.note:SetText(m.note) end
    if e.shownFor~=m.id or (e.lastOfficer~=officerText and not e.officer:HasFocus()) then e.officer:SetText(officerText) end
    e.shownFor,e.lastNote,e.lastOfficer=m.id,m.note,officerText
    e.note.syncPlaceholder(e.note); e.officer.syncPlaceholder(e.officer)
    -- A note the game won't let us change stays readable in its box; Save says why it's off.
    enable(e.note,single.publicNote); set(e.saveNote,single.publicNote,VC.deny(single,'publicNote','Your rank can\'t edit public notes'))
    enable(e.officer,single.officerNote); set(e.saveOfficer,single.officerNote,VC.deny(single,'officerNote','Your rank can\'t edit officer notes'))
    e.officerLabel:SetText(single.why.officerNote and '|cff909090Officer|r' or 'Officer')
    e.officerHint:SetShown(single.why.officerNote~=nil and single.viewOfficer)
    local up,upWhy=VC.canStep(m,m.rankIndex,1,single)
    local down,downWhy=VC.canStep(m,m.rankIndex,-1,single)
    set(e.promote,up,upWhy); set(e.demote,down,downWhy)
    -- Read-only where the game keeps every change for itself: notes stay readable, no dead buttons.
    for _,b in ipairs({e.saveNote,e.saveOfficer,e.promote,e.demote}) do b:SetShown(not locked) end
    if locked then e.officerHint:Hide() end
    e.lockedHint:SetShown(locked)
    e.fields:Show(); e.hint:Hide()
  else
    e.fields:Hide(); e.hint:Show()
  end
end
function VC.buildRosterPage(parent)
  local p=CreateFrame('Frame',nil,parent)
  p:SetAllPoints()
  rosterPage=p
  -- Filters
  local search=editBox(p,150,'Search names, notes, zones...')
  search:SetPoint('TOPLEFT',14,-8)
  search:SetScript('OnTextChanged',function(self) self.syncPlaceholder(self); VC.filters.text=self:GetText() or ''; VC.filterDirty=true; requestRedraw() end)
  search:SetScript('OnEnterPressed',function(self) self:ClearFocus() end)
  p.search=search
  local online=CreateFrame('CheckButton',nil,p,'UICheckButtonTemplate')
  online:SetSize(24,24); online:SetPoint('LEFT',search,'RIGHT',8,0)
  local onlineLabel=fontString(p,'GameFontHighlightSmall'); onlineLabel:SetPoint('LEFT',online,'RIGHT',0,1); onlineLabel:SetText('Online only')
  online:SetScript('OnClick',function(self) VillageCommandDB.ui.onlineOnly=self:GetChecked() and true or false; VC.filterDirty=true; requestRedraw() end)
  p.online=online
  local offline=CreateFrame('CheckButton',nil,p,'UICheckButtonTemplate')
  offline:SetSize(24,24); offline:SetPoint('LEFT',onlineLabel,'RIGHT',8,-1)
  local offlineLabel=fontString(p,'GameFontHighlightSmall'); offlineLabel:SetPoint('LEFT',offline,'RIGHT',0,1); offlineLabel:SetText('Show offline')
  offline:SetScript('OnClick',function(self)
    if SetGuildRosterShowOffline then SetGuildRosterShowOffline(self:GetChecked() and true or false) end
    VC.requestRoster()
  end)
  setTip(offline,'Show offline','The game only lists offline members when this is on (it\'s the same box as in the guild window). Village Command needs it to notice who left.')
  p.offline=offline
  local rankFilter=smallButton(p,'Any rank',110,22)
  rankFilter:SetPoint('LEFT',offlineLabel,'RIGHT',10,0)
  rankFilter:SetScript('OnClick',function(self)
    local names=VC.rankNames()
    local items={{text='Any rank',func=function() VC.filters.rank=nil; self:SetText('Any rank'); VC.filterDirty=true; requestRedraw() end}}
    for i=0,VC.lowestRank() do
      if names[i] then items[#items+1]={text=names[i],func=function() VC.filters.rank=i; self:SetText(names[i]); VC.filterDirty=true; requestRedraw() end} end
    end
    VC.showMenu(self,items)
  end)
  local more=smallButton(p,'More filters',100,22)
  more:SetPoint('LEFT',rankFilter,'RIGHT',6,0)
  local function numberFilter(field,label,value)
    return {text=label,func=function() VC.filters[field]=value; VC.filterDirty=true; requestRedraw() end}
  end
  more:SetScript('OnClick',function(self)
    local maxLevel=VC.maxLevel()
    VC.showMenu(self,{
      {text='Clear level and away filters',func=function() VC.filters.minLevel=nil; VC.filters.maxLevel=nil; VC.filters.awayDays=nil; VC.filterDirty=true; requestRedraw() end},
      numberFilter('minLevel','At the level cap ('..maxLevel..')',maxLevel),
      numberFilter('minLevel','Level '..math.floor(maxLevel/2)..' and up',math.floor(maxLevel/2)),
      {text='Below level 10',func=function() VC.filters.minLevel=nil; VC.filters.maxLevel=9; VC.filterDirty=true; requestRedraw() end},
      numberFilter('awayDays','Away 14+ days',14),
      numberFilter('awayDays','Away 30+ days',30),
      numberFilter('awayDays','Away 90+ days',90),
    })
  end)
  setTip(more,'More filters','Level and time-away filters. Combine them with a rank to tick, say, every Initiate at the cap, or everyone away for 30 days.')
  p.count=fontString(p,'GameFontHighlightSmall','RIGHT'); p.count:SetPoint('TOPRIGHT',-14,-12)
  -- Column headers (click to sort)
  local all=CreateFrame('CheckButton',nil,p,'UICheckButtonTemplate')
  all:SetSize(20,20); all:SetPoint('TOPLEFT',10,-34)
  all:SetScript('OnClick',function(self)
    local on=self:GetChecked() and true or false
    for _,m in ipairs(VC.filtered()) do VC.selected[m.id]=on or nil end
    requestRedraw()
  end)
  setTip(all,'Tick all shown','Ticks (or unticks) everyone the filters show.')
  p.all=all
  p.headers={}
  for _,c in ipairs(VC.columns) do
    local h=CreateFrame('Button',nil,p)
    h:SetSize(c.w,18); h:SetPoint('TOPLEFT',c.x+8,-35)
    h.text=fontString(h,'GameFontNormalSmall',c.key=='level' and 'CENTER' or 'LEFT'); h.text:SetAllPoints()
    h.key=c.key; h.label=c.label
    addHighlight(h,.25)
    h:SetScript('OnClick',function(self)
      local sort=VillageCommandDB.ui.sort
      if sort.key==self.key then sort.desc=not sort.desc else sort.key=self.key; sort.desc=(self.key=='level') end
      VC.filterDirty=true; requestRedraw()
    end)
    p.headers[#p.headers+1]=h
  end
  -- The list
  local listFrame=CreateFrame('Frame',nil,p,BACKDROP_TEMPLATE)
  listFrame:SetPoint('TOPLEFT',6,-54); listFrame:SetPoint('BOTTOMRIGHT',-6,114)
  skin(listFrame,.5,.55,.45,.28)
  local scroll=CreateFrame('ScrollFrame','VillageCommandRosterScroll',listFrame,'UIPanelScrollFrameTemplate')
  scroll:SetPoint('TOPLEFT',4,-4); scroll:SetPoint('BOTTOMRIGHT',-26,4)
  local content=CreateFrame('Frame',nil,scroll); content:SetSize(CONTENT_W,1)
  scroll:SetScrollChild(content)
  scroll:HookScript('OnVerticalScroll',function() VC.drawRows() end)
  scroll:HookScript('OnSizeChanged',function() VC.drawRows() end)
  p.scroll,p.content=scroll,content
  -- The editor for the clicked member: one skinned strip that's always there, with a hint when no one is picked.
  local e=CreateFrame('Frame',nil,p,BACKDROP_TEMPLATE)
  e:SetPoint('BOTTOMLEFT',6,38); e:SetPoint('BOTTOMRIGHT',-6,38); e:SetHeight(72); skin(e,.8)
  p.editor=e
  e.hint=fontString(e,'GameFontDisableSmall','CENTER'); e.hint:SetPoint('CENTER',0,0)
  e.hint:SetText('Click a member to see their notes and rank here.  Right-click a member for whisper, invite and more.')
  e.fields=CreateFrame('Frame',nil,e); e.fields:SetAllPoints()
  local fields=e.fields
  e.name=fontString(fields,'GameFontNormal'); e.name:SetPoint('TOPLEFT',10,-8); e.name:SetPoint('RIGHT',-10,0)
  local function noteField(label,x,officer)
    local l=fontString(fields,'GameFontDisableSmall','RIGHT'); l:SetPoint('TOPLEFT',x,-36); l:SetWidth(44); l:SetText(label)
    local box=editBox(fields,150,officer and 'Officer note' or 'Public note')
    box:SetPoint('LEFT',l,'RIGHT',10,0); box:SetMaxLetters(NOTE_MAX)
    box:SetScript('OnTextChanged',function(self) self.syncPlaceholder(self) end)
    local save=smallButton(fields,'Save',46,20); save:SetPoint('LEFT',box,'RIGHT',6,0)
    save:SetScript('OnEnter',function(self) if self.why then tooltip(self,label..' note',self.why) end end)
    save:SetScript('OnLeave',GameTooltip_Hide)
    box.label=l
    local function commit()
      local m=VC.focus and VC.byId[VC.focus]
      if not m then return end
      box:ClearFocus()
      local text=VC.trimNote(box:GetText())
      local old=officer and m.officerNote or m.note
      if text==old then return end
      VC.runNow((officer and 'Saved the officer note for ' or 'Saved the note for ')..m.short,{{kind='note',id=m.id,officer=officer,text=text}})
    end
    save:SetScript('OnClick',commit)
    box:SetScript('OnEnterPressed',commit)
    return box,save
  end
  e.note,e.saveNote=noteField('Note',4,false)
  e.officer,e.saveOfficer=noteField('Officer',270,true)
  e.officerLabel=e.officer.label
  -- Where officer notes can only be changed in the game's guild window: say so under the box.
  e.officerHint=fontString(fields,'GameFontDisableSmall'); e.officerHint:SetPoint('TOPLEFT',e.officer,'BOTTOMLEFT',-2,-1)
  e.officerHint:SetText('Change in the game\'s guild window (J)')
  e.lockedHint=fontString(fields,'GameFontDisableSmall','RIGHT'); e.lockedHint:SetPoint('TOPRIGHT',-12,-38); e.lockedHint:SetWidth(200)
  e.lockedHint:SetText('Notes: the game\'s guild window (J).\nPromote: Promotions tab, Promote helper.')
  if e.lockedHint.SetWordWrap then e.lockedHint:SetWordWrap(true) end
  e.demote=smallButton(fields,'Demote',72,20); e.demote:SetPoint('TOPRIGHT',-10,-34)
  e.promote=smallButton(fields,'Promote',72,20); e.promote:SetPoint('RIGHT',e.demote,'LEFT',-4,0)
  e.promote:SetScript('OnClick',function() local m=VC.byId[VC.focus or ''] if m then VC.runNow('Promoted '..m.short,(VC.rankJobs({m},1,nil,true))) end end)
  e.demote:SetScript('OnClick',function() local m=VC.byId[VC.focus or ''] if m then VC.runNow('Demoted '..m.short,(VC.rankJobs({m},-1,nil,true))) end end)
  for _,b in ipairs({e.promote,e.demote}) do
    b:SetScript('OnEnter',function(self) if self.why then tooltip(self,self:GetText(),self.why) end end)
    b:SetScript('OnLeave',GameTooltip_Hide)
  end
  -- Mass actions: what's ticked on the left, the actions on the right. With nothing ticked the actions make
  -- way for a hint, and while changes are going out they make way for the progress and Cancel.
  local bar=CreateFrame('Frame',nil,p,BACKDROP_TEMPLATE)
  bar:SetPoint('BOTTOMLEFT',6,4); bar:SetPoint('BOTTOMRIGHT',-6,4); bar:SetHeight(32); skin(bar,.8)
  p.bar=bar
  local function action(parent,label,width,fn)
    local b=smallButton(parent,label,width,22)
    b:SetScript('OnClick',fn)
    b:SetScript('OnEnter',function(self) if self.why then tooltip(self,label,self.why) end end)
    b:SetScript('OnLeave',GameTooltip_Hide)
    return b
  end
  local tick=action(bar,'Tick...',70,function(self)
    VC.showMenu(self,{
      {text='Everyone shown',func=function() for _,m in ipairs(VC.filtered()) do VC.selected[m.id]=true end; requestRedraw() end},
      {text='Online members shown',func=function() for _,m in ipairs(VC.filtered()) do if m.online then VC.selected[m.id]=true end end; requestRedraw() end},
      {text='Invert',func=function() for _,m in ipairs(VC.filtered()) do VC.toggleSelect(m.id) end; requestRedraw() end},
      {text='Nobody',func=function() wipe(VC.selected); requestRedraw() end},
    })
  end)
  tick:SetPoint('LEFT',6,0)
  p.tick=tick
  -- Where the game keeps promotions for its guild window, the checklist takes the mass actions' place.
  p.checklist=action(bar,'Promotion checklist',150,function() VC.selectTab('promos') end)
  p.checklist:SetPoint('LEFT',6,0)
  p.checklist.why='Who\'s ready to promote under your rules, to work through in the game\'s guild window.'
  p.checklist:Hide()
  tick.why='Tick everyone shown, everyone online, invert, or clear. Shift-click rows to tick a range.'
  p.ticked=fontString(bar,'GameFontHighlightSmall'); p.ticked:SetPoint('LEFT',tick,'RIGHT',10,0); p.ticked:SetWidth(110)
  p.barHint=fontString(bar,'GameFontDisableSmall','RIGHT'); p.barHint:SetPoint('RIGHT',-12,0)
  p.barHint:SetText(VC.TICK_HINT)
  p.actions=CreateFrame('Frame',nil,bar); p.actions:SetAllPoints()
  local actions=p.actions
  p.massOfficer=action(actions,'Officer notes...',104,function() VC.openNoteDialog(true) end)
  p.massOfficer:SetPoint('RIGHT',-6,0)
  p.massNote=action(actions,'Public notes...',100,function() VC.openNoteDialog(false) end)
  p.massNote:SetPoint('RIGHT',p.massOfficer,'LEFT',-4,0)
  local divider=actions:CreateTexture(nil,'ARTWORK'); divider:SetSize(1,20); divider:SetColorTexture(.85,.68,.3,.45)
  divider:SetPoint('RIGHT',p.massNote,'LEFT',-8,0)
  p.setRank=action(actions,'Set rank...',86,function(self)
    local names=VC.rankNames()
    local me=VC.myRankIndex() or 0
    local items={}
    for i=0,VC.lowestRank() do
      if names[i] then items[#items+1]={text=names[i],disabled=i<=me,tip=i<=me and 'Only ranks below yours' or nil,func=function() VC.massRank(0,i,names[i]) end} end
    end
    VC.showMenu(self,items)
  end)
  p.setRank:SetPoint('RIGHT',divider,'LEFT',-8,0)
  p.demote=action(actions,'Demote',72,function() VC.massRank(-1) end)
  p.demote:SetPoint('RIGHT',p.setRank,'LEFT',-4,0)
  p.promote=action(actions,'Promote',72,function() VC.massRank(1) end)
  p.promote:SetPoint('RIGHT',p.demote,'LEFT',-4,0)
  p.working=CreateFrame('Frame',nil,bar); p.working:SetAllPoints()
  p.cancel=smallButton(p.working,'Cancel',70,22); p.cancel:SetPoint('RIGHT',-6,0); p.cancel:SetScript('OnClick',VC.cancelJobs)
  p.progress=fontString(p.working,'GameFontHighlightSmall','RIGHT'); p.progress:SetPoint('RIGHT',p.cancel,'LEFT',-10,0); p.progress:SetWidth(330)
  p.working:Hide()
  p:SetScript('OnShow',function() VC.drawRows() end)
  return p
end
function VC.refreshRoster()
  if not rosterPage then return end
  local p=rosterPage
  p.online:SetChecked(VillageCommandDB.ui.onlineOnly and true or false)
  p.offline:SetChecked(GetGuildRosterShowOffline and GetGuildRosterShowOffline() and true or false)
  local sort=VillageCommandDB.ui.sort
  for _,h in ipairs(p.headers) do
    h.text:SetText(h.label..(sort.key==h.key and (sort.desc and ' v' or ' ^') or ''))
  end
  if VC.scrollToFocus and VC.focus then
    VC.scrollToFocus=nil
    -- Clear the filters that would hide the member being opened.
    VC.filters.text=''; VC.filters.rank=nil; VC.filters.minLevel=nil; VC.filters.maxLevel=nil; VC.filters.awayDays=nil
    p.search:SetText('')
    VC.filterDirty=true
    for i,m in ipairs(VC.filtered()) do
      if m.id==VC.focus then p.scroll:SetVerticalScroll(math.max(0,(i-4)*ROW_H)); break end
    end
  end
  VC.drawRows()
  VC.updateActionBar()
end

-- Promote helper -------------------------------------------------------------------------------------
-- Where the game won't let addons call promote (WoW Forever), it still runs the /gpromote chat command (tested in game, Nov 2026)
-- from a secure button: the game's own button code runs it when you click, as if you'd typed it. This
-- small window shows the next member on a rule's checklist with such a button, and watches the roster to
-- see whether the click worked. One click carries several /gpromote lines (a macro, up to 255 characters);
-- each needs a real click, so it's never fully automatic. There's no chat command for notes.
-- Secure buttons can't be shown, hidden, moved or changed in combat, so this window is separate from the
-- main one, is hidden in combat by the game's own state driver, and is only ever updated out of combat:
-- it can never be left pointing at the wrong member.
VC.helperState={}
local function inCombat() return InCombatLockdown and InCombatLockdown() end
-- Macros hold 255 characters: as many "/gpromote Name" lines as fit, up to the batch size.
local MACRO_MAX=255
function VC.helperBatchSize() return math.max(1,math.min(10,tonumber(settings().batch) or 5)) end
-- Who's next: members already part way up a multi-step rule, then the rest of the list. Anyone the game
-- didn't promote twice is set aside for this session so the queue can't get stuck on them.
function VC.helperQueue()
  local h,st=VC.helper,VC.helperState
  local r=h and VC.rules()[st.rule or 0]
  if not r or r.off then return {},r end
  st.started,st.fails=st.started or {},st.fails or {}
  local skip=r.skip or {}
  local queue,seen={},{}
  local function add(m)
    if m and not seen[m.id] and not skip[m.id] and (st.fails[m.id] or 0)<2 then seen[m.id]=true; queue[#queue+1]=m end
  end
  for id in pairs(st.started) do
    local m=VC.byId[id]
    if m and m.rankIndex>r.to and m.rankIndex<=r.from then add(m) end
  end
  table.sort(queue,function(a,b) return a.short<b.short end)
  for _,m in ipairs((VC.ruleMembers(r))) do add(m) end
  return queue,r
end
function VC.helperBatch(queue)
  local batch,lines,size={},{},0
  for _,m in ipairs(queue) do
    if #batch>=VC.helperBatchSize() then break end
    local line='/gpromote '..m.name
    if size+#line+(#lines>0 and 1 or 0)>MACRO_MAX then break end
    batch[#batch+1]=m; lines[#lines+1]=line; size=size+#line+(#lines>1 and 1 or 0)
  end
  return batch,table.concat(lines,'\n')
end
function VC.helperRefresh()
  local h,st=VC.helper,VC.helperState
  if not h or not h:IsShown() or inCombat() then return end
  local queue,r=VC.helperQueue()
  local names=VC.rankNames()
  h.size:SetText(VC.helperBatchSize()..' per click')
  local function idle(text)
    h.who:SetText(text); h.promote:SetAttribute('macrotext',''); h.promote.batch={}; h.promote:SetText('Promote'); h.promote:Disable(); h.skip:Disable()
  end
  if not r then idle('|cff909090That rule is gone or switched off.|r'); h.count:SetText(''); return end
  h.title:SetText((names[r.from] or '?')..'  ->  '..(names[r.to] or '?'))
  local aside=0
  for _,n in pairs(st.fails or {}) do if n>=2 then aside=aside+1 end end
  h.count:SetText(#queue..' to go'..(aside>0 and ('  ·  '..aside..' set aside') or ''))
  if #queue==0 then idle('|cff40ff40Everyone on this list is done.|r'); return end
  local batch,macro=VC.helperBatch(queue)
  local shown={}
  for i=1,math.min(#batch,4) do shown[i]=VC.colorName(batch[i]) end
  h.who:SetText('Next: '..table.concat(shown,', ')..(#batch>4 and (' and '..(#batch-4)..' more') or ''))
  h.promote:SetAttribute('type','macro')
  h.promote:SetAttribute('macrotext',macro)
  h.promote.batch=batch
  h.promote:SetText(#batch==1 and 'Promote 1' or ('Promote '..#batch))
  if st.pending then h.promote:Disable() else h.promote:Enable() end
  h.skip:Enable()
end
-- After a click: wait for the roster to show who moved up, then say who did and who didn't.
function VC.helperClicked()
  local h,st=VC.helper,VC.helperState
  local batch=h and h.promote.batch or {}
  if #batch==0 then return end
  local list={}
  st.started=st.started or {}
  for _,m in ipairs(batch) do list[#list+1]={id=m.id,rank=m.rankIndex,name=m.short}; st.started[m.id]=true end
  st.pending={at=now(),list=list}
  h.status:SetText('|cffffd100Promoting '..#list..'...|r')
  h.promote:Disable()
  VC.requestRoster(); VC.readSoon(true)
  later(2,function() VC.requestRoster(); VC.readSoon(true) end)
  later(5,function() VC.requestRoster(); VC.readSoon(true) end)
  later(9,VC.helperCheck)
end
function VC.helperCheck()
  local h,st=VC.helper,VC.helperState
  local p=st.pending
  if not (h and p) then return end
  local done,missed={},{}
  for _,e in ipairs(p.list) do
    local m=VC.byId[e.id]
    if m and m.rankIndex<e.rank then done[#done+1]=e.name else missed[#missed+1]=e end
  end
  -- Resolve as soon as everyone moved; otherwise give the roster a few seconds to catch up.
  if #missed>0 and now()-p.at<8 then return end
  st.pending=nil
  st.fails=st.fails or {}
  if #done>0 then
    st.worked=(st.worked or 0)+#done
    VillageCommandDB.gpromote=VillageCommandDB.gpromote or {}
    VillageCommandDB.gpromote[VC.flavor]='works'
  end
  local missedNames={}
  for _,e in ipairs(missed) do st.fails[e.id]=(st.fails[e.id] or 0)+1; missedNames[#missedNames+1]=e.name end
  if #missed==0 then
    h.status:SetText('|cff40ff40Promoted '..#done..'.|r')
    log('Promoted '..table.concat(done,', ')..'.',true)
  elseif #done>0 then
    -- The server only takes so many in a row; from now on send that many per click (remembered).
    local was=VC.helperBatchSize()
    if #done<was then VillageCommandDB.settings.batch=#done end
    h.status:SetText('|cffffd100Promoted '..#done..' of '..#p.list..'.|r Now '..VC.helperBatchSize()..' per click.')
    log('Promoted '..table.concat(done,', ')..'. Didn\'t go through: '..table.concat(missedNames,', ')..' (they\'re first next click). The server only took '..#done..' in a row, so the helper now sends '..VC.helperBatchSize()..' per click. You can change it with the - and + under the button.',true)
  else
    h.status:SetText('|cffff6060Nobody was promoted.|r See chat for what the game said.')
    log('The game didn\'t promote '..table.concat(missedNames,', ')..' from the promote helper. If chat shows an error, please send what it said; if it says nothing, try 1 per click.',true)
  end
  VC.helperRefresh()
end
function VC.openPromoteHelper(ruleIndex)
  if inCombat() then log('The promote helper opens out of combat.',true); return end
  local h=VC.helper
  if not h then
    h=CreateFrame('Frame','VillageCommandPromoteHelper',UIParent,BACKDROP_TEMPLATE)
    VC.helper=h
    h:SetSize(400,170); h:SetFrameStrata('DIALOG'); h:SetClampedToScreen(true)
    h:SetMovable(true); h:EnableMouse(true); h:RegisterForDrag('LeftButton')
    h:SetScript('OnDragStart',function(self) if not inCombat() then self:StartMoving() end end)
    h:SetScript('OnDragStop',h.StopMovingOrSizing)
    if h.SetBackdrop then
      h:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
    end
    local head=fontString(h,'GameFontDisableSmall','CENTER'); head:SetPoint('TOP',0,-16); head:SetText('Promote helper')
    h.title=fontString(h,'GameFontNormal','CENTER'); h.title:SetPoint('TOP',head,'BOTTOM',0,-4)
    h.who=fontString(h,'GameFontHighlight','CENTER'); h.who:SetPoint('TOP',h.title,'BOTTOM',0,-10); h.who:SetWidth(350)
    -- The secure button: the game runs its /gpromote when you click it.
    local b=CreateFrame('Button','VillageCommandPromoteHelperButton',h,'SecureActionButtonTemplate,UIPanelButtonTemplate')
    b:SetSize(130,24); b:SetPoint('BOTTOMRIGHT',h,'BOTTOM',-4,52); b:SetText('Promote')
    -- Newer clients act on the key-down or key-up half of a click depending on a setting; listen for that half only.
    local down=GetCVarBool and GetCVarBool('ActionButtonUseKeyDown')
    b:RegisterForClicks(down and 'LeftButtonDown' or 'LeftButtonUp')
    b:SetAttribute('type','macro'); b:SetAttribute('macrotext','')
    b:SetScript('PostClick',function() VC.helperClicked() end)
    h.promote=b
    -- Skip takes the first name off the next click (and off the rule's list).
    h.skip=smallButton(h,'Skip first',90,24); h.skip:SetPoint('BOTTOMLEFT',h,'BOTTOM',4,52)
    h.skip:SetScript('OnClick',function()
      local m=(b.batch or {})[1]
      local r=VC.rules()[VC.helperState.rule or 0]
      if m and r and not inCombat() then r.skip=r.skip or {}; r.skip[m.id]=true; VC.helperRefresh(); requestRedraw() end
    end)
    setTip(h.skip,'Skip first','Takes the first name off this click and skips them for this rule.')
    -- How many names one click carries.
    h.size=fontString(h,'GameFontHighlightSmall','CENTER'); h.size:SetPoint('TOP',b,'BOTTOM',58,-6); h.size:SetWidth(80)
    local less=smallButton(h,'-',22,18); less:SetPoint('RIGHT',h.size,'LEFT',-2,0)
    local more=smallButton(h,'+',22,18); more:SetPoint('LEFT',h.size,'RIGHT',2,0)
    local function change(d)
      if inCombat() then return end
      VillageCommandDB.settings.batch=math.max(1,math.min(10,VC.helperBatchSize()+d)); VC.helperRefresh()
    end
    less:SetScript('OnClick',function() change(-1) end); more:SetScript('OnClick',function() change(1) end)
    setTip(more,'Names per click','One click runs a /gpromote line for each name, up to this many (and as many as fit in a macro). Lower it if some don\'t go through.')
    h.count=fontString(h,'GameFontDisableSmall','LEFT'); h.count:SetPoint('BOTTOMLEFT',18,16); h.count:SetWidth(150)
    h.status=fontString(h,'GameFontHighlightSmall','RIGHT'); h.status:SetPoint('BOTTOMRIGHT',-18,16); h.status:SetWidth(230)
    local close=CreateFrame('Button',nil,h,'UIPanelCloseButton'); close:SetPoint('TOPRIGHT',-6,-6)
    close:SetScript('OnClick',function() VC.closePromoteHelper() end)
    h:Hide()
  end
  VC.helperState={rule=ruleIndex}
  h:ClearAllPoints()
  if window and window:IsShown() then h:SetPoint('TOP',window,'BOTTOM',0,-6) else h:SetPoint('CENTER',0,-120) end
  -- Anchored to the window only to place it; then it stands on its own so moving the window never moves it.
  local left,top=h:GetLeft(),h:GetTop()
  h:ClearAllPoints()
  if left and top then h:SetPoint('TOPLEFT',UIParent,'BOTTOMLEFT',left,top) else h:SetPoint('CENTER',UIParent,'CENTER',0,-200) end
  h:Show()
  if RegisterStateDriver then RegisterStateDriver(h,'visibility','[combat] hide; show') end
  h.status:SetText('')
  VC.helperRefresh()
end
function VC.closePromoteHelper()
  local h=VC.helper
  if not h then return end
  if inCombat() then VC.helperCloseAfterCombat=true; return end
  if UnregisterStateDriver then UnregisterStateDriver(h,'visibility') end
  h:Hide()
  VC.helperState={}
end

-- The rule editor: from and to ranks (menus), and three numbers. 0 or empty means "any".
function VC.openRuleDialog(index)
  local d=VC.ruleDialog
  if not d then
    d=CreateFrame('Frame','VillageCommandRuleDialog',UIParent,BACKDROP_TEMPLATE)
    d:SetSize(380,250); d:SetPoint('CENTER',0,60); d:SetFrameStrata('FULLSCREEN_DIALOG'); d:EnableMouse(true)
    d:SetMovable(true); d:RegisterForDrag('LeftButton'); d:SetScript('OnDragStart',d.StartMoving); d:SetScript('OnDragStop',d.StopMovingOrSizing)
    if d.SetBackdrop then
      d:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
    end
    VC.closeOnEscape(d,3)
    d.title=fontString(d,'GameFontNormal','CENTER'); d.title:SetPoint('TOP',0,-18)
    local y=-46
    local function label(text)
      local l=fontString(d,'GameFontHighlightSmall','RIGHT'); l:SetPoint('TOPLEFT',24,y-4); l:SetWidth(150); l:SetText(text)
      return l
    end
    local function rankButton(field)
      local b=smallButton(d,'',150,22); b:SetPoint('TOPLEFT',186,y)
      b:SetScript('OnClick',function(self)
        local names=VC.rankNames()
        local items={}
        for i=0,VC.lowestRank() do
          if names[i] then items[#items+1]={text=names[i],func=function() d.rule[field]=i; d.refresh() end} end
        end
        VC.showMenu(self,items)
      end)
      y=y-28
      return b
    end
    local function numberBox(field)
      local e=editBox(d,50,'any')
      e:SetPoint('TOPLEFT',190,y); e:SetMaxLetters(3)
      if e.SetNumeric then e:SetNumeric(true) end
      e:SetScript('OnTextChanged',function(self) self.syncPlaceholder(self); d.rule[field]=tonumber(self:GetText() or '') or 0; d.refresh(true) end)
      e:SetScript('OnEnterPressed',function(self) self:ClearFocus() end)
      y=y-28
      return e
    end
    label('Promote from'); d.from=rankButton('from')
    label('Promote to'); d.to=rankButton('to')
    label('Level at least'); d.level=numberBox('minLevel')
    label('Days in the guild at least'); d.days=numberBox('minDays')
    label('Online within (days)'); d.active=numberBox('activeDays')
    d.preview=fontString(d,'GameFontHighlightSmall','CENTER'); d.preview:SetPoint('TOP',0,y-4); d.preview:SetWidth(330)
    d.save=smallButton(d,SAVE or 'Save',100,22); d.save:SetPoint('BOTTOMRIGHT',d,'BOTTOM',-6,20)
    d.cancel=smallButton(d,CANCEL or 'Cancel',100,22); d.cancel:SetPoint('BOTTOMLEFT',d,'BOTTOM',6,20)
    d.cancel:SetScript('OnClick',function() d:Hide() end)
    d.save:SetScript('OnClick',function()
      local r=d.rule
      if not (r.to<r.from) then return end
      d:Hide()
      VC.saveRule(d.index,{from=r.from,to=r.to,minLevel=r.minLevel or 0,minDays=r.minDays or 0,activeDays=r.activeDays or 0})
    end)
    -- Rank buttons and the "who qualifies" count follow every change; boxes aren't refilled while typing.
    function d.refresh(typing)
      local r,names=d.rule,VC.rankNames()
      d.from:SetText(names[r.from] or ('Rank '..r.from))
      d.to:SetText(names[r.to] or ('Rank '..r.to))
      if not typing then
        d.level:SetText((r.minLevel or 0)>0 and tostring(r.minLevel) or '')
        d.days:SetText((r.minDays or 0)>0 and tostring(r.minDays) or '')
        d.active:SetText((r.activeDays or 0)>0 and tostring(r.activeDays) or '')
        for _,e in ipairs({d.level,d.days,d.active}) do e.syncPlaceholder(e) end
      end
      if r.to<r.from then
        d.save:Enable()
        local ready=VC.ruleMembers({from=r.from,to=r.to,minLevel=r.minLevel,minDays=r.minDays,activeDays=r.activeDays,skip={}})
        d.preview:SetText('|cffffd100'..#ready..'|r member'..(#ready==1 and '' or 's')..' qualify right now')
      else
        d.save:Disable()
        d.preview:SetText('|cffff6060"Promote to" has to be a higher rank than "Promote from".|r')
      end
    end
    VC.ruleDialog=d
  end
  local existing=index and VC.rules()[index]
  local low=VC.lowestRank()
  d.index=existing and index or nil
  d.rule=existing and {from=existing.from,to=existing.to,minLevel=existing.minLevel,minDays=existing.minDays,activeDays=existing.activeDays}
    or {from=low,to=math.max(0,low-1),minLevel=10,minDays=7,activeDays=7}
  d.title:SetText(existing and 'Edit promotion rule' or 'New promotion rule')
  d:Show()
  d.refresh()
end

-- The mass note dialog: a note template, how to combine it with what's there, and a preview.
function VC.openNoteDialog(officer)
  local d=VC.noteDialog
  if not d then
    d=CreateFrame('Frame','VillageCommandNoteDialog',UIParent,BACKDROP_TEMPLATE)
    d:SetSize(380,190); d:SetPoint('CENTER',0,80); d:SetFrameStrata('FULLSCREEN_DIALOG'); d:EnableMouse(true)
    d:SetMovable(true); d:RegisterForDrag('LeftButton'); d:SetScript('OnDragStart',d.StartMoving); d:SetScript('OnDragStop',d.StopMovingOrSizing)
    if d.SetBackdrop then
      d:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
    end
    VC.closeOnEscape(d,3)
    d.title=fontString(d,'GameFontNormal','CENTER'); d.title:SetPoint('TOP',0,-18)
    d.box=editBox(d,300,'e.g. Raider {date}')
    d.box:SetPoint('TOP',0,-46); d.box:SetMaxLetters(NOTE_MAX)
    d.mode=smallButton(d,'',140,22); d.mode:SetPoint('TOPLEFT',38,-74)
    d.tokens=fontString(d,'GameFontDisableSmall'); d.tokens:SetPoint('LEFT',d.mode,'RIGHT',10,0)
    d.tokens:SetText('{date} {level} {rank} {class} {name}')
    d.preview=fontString(d,'GameFontHighlightSmall'); d.preview:SetPoint('TOPLEFT',38,-108); d.preview:SetWidth(310)
    d.ok=smallButton(d,'Apply',100,22); d.ok:SetPoint('BOTTOMRIGHT',d,'BOTTOM',-6,20)
    d.cancel=smallButton(d,CANCEL or 'Cancel',100,22); d.cancel:SetPoint('BOTTOMLEFT',d,'BOTTOM',6,20)
    d.cancel:SetScript('OnClick',function() d:Hide() end)
    local function preview()
      local mode=VC.noteModes[d.modeIndex].key
      d.box:SetShown(mode~='clear')
      local first=VC.selectedMembers()[1]
      if first then
        local old=d.officer and first.officerNote or first.note
        d.preview:SetText('|cff909090'..first.short..':|r  "'..old..'"  ->  "|cffffd100'..VC.composeNote(old,d.box:GetText(),mode,first)..'|r"')
      else d.preview:SetText('|cff909090Tick members first.|r') end
    end
    d.updatePreview=preview
    d.box:SetScript('OnTextChanged',function(self) self.syncPlaceholder(self); preview() end)
    d.box:SetScript('OnEnterPressed',function() d.ok:Click() end)
    d.mode:SetScript('OnClick',function()
      d.modeIndex=d.modeIndex%#VC.noteModes+1
      d.mode:SetText('Mode: '..VC.noteModes[d.modeIndex].label)
      preview()
    end)
    d.ok:SetScript('OnClick',function()
      d:Hide()
      VC.massNote(d.box:GetText(),VC.noteModes[d.modeIndex].key,d.officer)
    end)
    d.modeIndex=1
    VC.noteDialog=d
  end
  d.officer=officer
  local n=#VC.selectedMembers()
  d.title:SetText((officer and 'Officer note' or 'Public note')..' for '..n..' member'..(n==1 and '' or 's'))
  d.mode:SetText('Mode: '..VC.noteModes[d.modeIndex].label)
  d:Show()
  d.updatePreview()
end

-- Window --------------------------------------------------------------------------------------------
function VC.update()
  updatePending=false; sinceUpdate=0
  VC.refreshMinimap()
  if not (window and window:IsShown()) then return end
  local key=VillageCommandDB.ui.tab
  local tab
  for _,t in ipairs(VC.tabs) do if t.key==key then tab=t end end
  tab=tab or VC.tabs[1]
  for _,b in ipairs(window.tabButtons) do b:SetChecked(b.key==tab.key) end
  headerIcon:SetTexture(tab.icon)
  local guild=VC.guildName()
  headerTitle:SetText(tab.label..(guild and ('  |cffa0a0a0<'..guild..'>|r') or ''))
  headerSub:SetText(VC.gameLocked() and tab.lockedSub or tab.sub)
  local q=VC.queue
  local work=VC.busy() and ('  |  |cffffd100'..q.label..' '..q.pos..'/'..#q.list..'|r') or ''
  status:SetText(string.format('|cffffd100%s|r  |  %d / %d online%s',guild or 'Not in a guild',VC.onlineCount(),#VC.roster,work))
  if tab.key=='roster' then
    pageScroll:GetParent():Hide(); rosterPage:Show()
    VC.refreshRoster()
    return
  end
  rosterPage:Hide(); pageScroll:GetParent():Show()
  local visible=tonumber((pageScroll:GetWidth())) or 0
  pageWidth=visible>200 and math.floor(visible-4) or CONTENT_W
  pageContent:SetWidth(pageWidth)
  VC.releaseAll()
  cursor=-2; stripe=0
  if not guild then
    VC.note('You\'re not in a guild. Village Command comes alive once you join one.')
  else
    VC.pages[tab.key]()
  end
  pageContent:SetHeight(math.max(1,-cursor+10))
end
function VC.selectTab(key)
  VillageCommandDB.ui.tab=key
  VC.hideMenu()
  if pageScroll then pageScroll:SetVerticalScroll(0) end
  if not (window and window:IsShown()) then VC.open() else VC.update() end
end
local function setScale(value)
  value=math.max(.7,math.min(1.4,math.floor(value*20+.5)/20))
  VillageCommandDB.settings.scale=value
  if window then window:SetScale(value) end
  return value
end
function VC.makeSettingsPanel(f,inset)
  local panel=CreateFrame('Frame',nil,f,BACKDROP_TEMPLATE)
  panel:SetPoint('TOPLEFT',inset,'TOPLEFT'); panel:SetPoint('BOTTOMRIGHT',inset,'BOTTOMRIGHT')
  panel:SetFrameStrata('FULLSCREEN_DIALOG'); skin(panel,1)
  local backing=panel:CreateTexture(nil,'BACKGROUND',nil,-8)
  backing:SetPoint('TOPLEFT',3,-3); backing:SetPoint('BOTTOMRIGHT',-3,3); backing:SetColorTexture(.07,.05,.035,1)
  panel:EnableMouse(true); panel:Hide()
  panel:EnableMouseWheel(true); panel:SetScript('OnMouseWheel',function() end)
  local title=panel:CreateFontString(nil,'OVERLAY','GameFontNormalLarge'); title:SetPoint('TOPLEFT',18,-16); title:SetText('Settings')
  local y,colX=-50,16
  local checks={}
  local function check(label,hint,get,set)
    local c=CreateFrame('CheckButton',nil,panel,'UICheckButtonTemplate')
    c:SetSize(26,26); c:SetPoint('TOPLEFT',colX,y)
    local text=panel:CreateFontString(nil,'OVERLAY','GameFontHighlight'); text:SetPoint('LEFT',c,'RIGHT',4,1); text:SetText(label)
    local sub=panel:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); sub:SetPoint('TOPLEFT',text,'BOTTOMLEFT',0,-2); sub:SetText(hint)
    sub:SetWidth(380); sub:SetJustifyH('LEFT')
    if sub.SetWordWrap then sub:SetWordWrap(true) end
    c.get=get
    c:SetScript('OnClick',function(self) set(self:GetChecked() and true or false); requestRedraw() end)
    checks[#checks+1]=c
    y=y-44
  end
  check('Show minimap button','Left-click opens Village Command, right-click opens the roster. Also /vc minimap.',
    function() return not VillageCommandDB.minimap.hide end,
    function(v) VillageCommandDB.minimap.hide=not v; if minimapButton then minimapButton:SetShown(v) end end)
  check('Ask before mass changes','Promote, demote, set rank and note changes for ticked members ask first, naming who they touch.',
    function() return settings().confirm end, function(v) VillageCommandDB.settings.confirm=v end)
  check('Record history','Levels, ranks, joins, leaves and online times, for Progression and Fun Stats. Kept on this PC only.',
    function() return settings().history end, function(v) VillageCommandDB.settings.history=v end)
  check('Quiet mode','Only print messages in chat for things you did.',
    function() return settings().quiet end, function(v) VillageCommandDB.settings.quiet=v end)
  check('Share history with guildmates','Compare level history, first-seen dates and activity with guildmates running Village Command, so it covers everyone\'s playtime. A few small messages at login.',
    function() return settings().share~=false end, function(v) VillageCommandDB.settings.share=v; if v then later(1,VC.sayHello) end end)
  local function stepper(label,hint,get,change,format)
    local text=panel:CreateFontString(nil,'OVERLAY','GameFontHighlight'); text:SetPoint('TOPLEFT',22,y-4)
    local minus=smallButton(panel,'-',24,20); minus:SetPoint('TOPLEFT',250,y)
    local value=fontString(panel,'GameFontHighlight','CENTER'); value:SetPoint('LEFT',minus,'RIGHT',4,0); value:SetWidth(110)
    local plus=smallButton(panel,'+',24,20); plus:SetPoint('LEFT',value,'RIGHT',4,0)
    local sub=panel:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); sub:SetPoint('TOPLEFT',text,'BOTTOMLEFT',0,-4); sub:SetText(hint)
    text:SetText(label)
    local function show() value:SetText(format(get())) end
    minus:SetScript('OnClick',function() change(-1); show() end)
    plus:SetScript('OnClick',function() change(1); show() end)
    show()
    y=y-48
  end
  stepper('Window scale','Also: drag the window by its edges to move it.',function() return settings().scale or 1 end,
    function(dir) setScale((settings().scale or 1)+dir*.05) end,function(v) return math.floor(v*100+.5)..'%' end)
  stepper('Pause between mass changes','Slower is safer: the server ignores changes sent too fast.',function() return settings().throttle or .6 end,
    function(dir) VillageCommandDB.settings.throttle=math.max(.2,math.min(3,(settings().throttle or .6)+dir*.1)) end,
    function(v) return string.format('%.1fs',v) end)
  stepper('Trust shared history from','Joins, leaves, rank changes and earlier first-seen dates are taken from these ranks (and higher) on their own.',
    function() return tonumber(settings().trustRank) or 1 end,
    function(dir) VillageCommandDB.settings.trustRank=math.max(0,math.min(VC.lowestRank(),(tonumber(settings().trustRank) or 1)+dir)) end,
    function(v) return VC.rankNames()[v] or ('Rank '..v) end)
  local reset=smallButton(panel,'Reset statistics',140,22); reset:SetPoint('TOPLEFT',22,y-6)
  reset:SetScript('OnClick',function() VC.ask('Reset Village Command\'s statistics for this guild?\n\nLevel history, the activity feed and online records start over. Notes and ranks in the game are not touched.',VC.resetStats) end)
  -- Celebrations, in the right-hand column.
  colX,y=440,-50
  local head=panel:CreateFontString(nil,'OVERLAY','GameFontNormal'); head:SetPoint('TOPLEFT',colX+4,-30); head:SetText('Celebrations')
  check('Celebrate guildmates\' level-ups','A message on your screen when a guildmate reaches one of the levels below.',
    function() return settings().celebrate end, function(v) VillageCommandDB.settings.celebrate=v end)
  local levelsLabel=panel:CreateFontString(nil,'OVERLAY','GameFontHighlight'); levelsLabel:SetPoint('TOPLEFT',colX+6,y-4); levelsLabel:SetText('At levels')
  local levels=editBox(panel,170,'e.g. 20, 40, 50')
  levels:SetPoint('TOPLEFT',colX+80,y); levels:SetMaxLetters(60)
  levels:SetScript('OnTextChanged',function(self) self.syncPlaceholder(self); VillageCommandDB.settings.celebrateLevels=self:GetText() or '' end)
  levels:SetScript('OnEnterPressed',function(self) self:ClearFocus() end)
  local levelsHint=panel:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); levelsHint:SetPoint('TOPLEFT',levelsLabel,'BOTTOMLEFT',0,-6)
  levelsHint:SetText('Any levels, separated by commas. Leave empty for none.')
  y=y-48
  check('Big celebration at the level cap','A banner with fireworks across the screen when someone hits level '..VC.maxLevel()..'.',
    function() return settings().celebrateCap end, function(v) VillageCommandDB.settings.celebrateCap=v end)
  check('Play a sound','The raid warning sound, and the level-up fanfare for the big one.',
    function() return settings().celebrateSound end, function(v) VillageCommandDB.settings.celebrateSound=v end)
  local preview=smallButton(panel,'Preview',90,22); preview:SetPoint('TOPLEFT',colX+6,y-4)
  preview:SetScript('OnClick',function() VC.previewCelebration(false) end)
  local previewBig=smallButton(panel,'Preview the big one',150,22); previewBig:SetPoint('LEFT',preview,'RIGHT',6,0)
  previewBig:SetScript('OnClick',function() VC.previewCelebration(true) end)
  panel.levels=levels
  local version=fontString(panel,'GameFontDisableSmall','RIGHT'); version:SetPoint('BOTTOMRIGHT',-14,12); version:SetText('Village Command v'..VERSION)
  panel:SetScript('OnShow',function()
    for _,c in ipairs(checks) do c:SetChecked(c.get() and true or false) end
    panel.levels:SetText(settings().celebrateLevels or '')
  end)
  return panel
end
local function makeTab(index,tab)
  local t=CreateFrame('CheckButton',nil,window)
  t.key=tab.key
  t:SetSize(32,32)
  t:SetPoint('TOPLEFT',window,'TOPRIGHT',-6,-44-(index-1)*38)
  local bg=t:CreateTexture(nil,'BACKGROUND')
  bg:SetTexture('Interface\\SpellBook\\SpellBook-SkillLineTab'); bg:SetSize(64,64); bg:SetPoint('TOPLEFT',-3,11)
  t:SetNormalTexture(tab.icon)
  t:SetHighlightTexture('Interface\\Buttons\\ButtonHilight-Square','ADD')
  t:SetCheckedTexture('Interface\\Buttons\\CheckButtonHilight')
  local checked=t:GetCheckedTexture(); if checked then checked:SetBlendMode('ADD') end
  t:SetScript('OnClick',function() VC.selectTab(tab.key) end)
  setTip(t,tab.label,tab.sub)
  window.tabButtons[#window.tabButtons+1]=t
end
function VC.makeWindow()
  local f=CreateFrame('Frame','VillageCommandWindow',UIParent,BACKDROP_TEMPLATE)
  window=f
  f:SetSize(900,680); f:SetPoint('CENTER'); f:SetFrameStrata('DIALOG'); f:SetToplevel(true)
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag('LeftButton'); f:SetClampedToScreen(true)
  f:SetScript('OnDragStart',f.StartMoving); f:SetScript('OnDragStop',f.StopMovingOrSizing)
  f:SetScale(settings().scale or 1)
  if f.SetBackdrop then
    f:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
  end
  local tint=f:CreateTexture(nil,'BACKGROUND',nil,1)
  tint:SetPoint('TOPLEFT',11,-12); tint:SetPoint('BOTTOMRIGHT',-12,11); tint:SetColorTexture(.16,.11,.06,.55)
  VC.closeOnEscape(f,9)
  local banner=f:CreateTexture(nil,'ARTWORK')
  banner:SetTexture('Interface\\DialogFrame\\UI-DialogBox-Header'); banner:SetSize(340,64); banner:SetPoint('TOP',0,12)
  local title=f:CreateFontString(nil,'OVERLAY','GameFontNormal')
  title:SetPoint('TOP',banner,'TOP',0,-14); title:SetText('Village Command')
  local close=CreateFrame('Button',nil,f,'UIPanelCloseButton')
  close:SetPoint('TOPRIGHT',-6,-6)
  local refresh=smallButton(f,'Refresh',80,22); refresh:SetPoint('TOPLEFT',22,-36)
  refresh:SetScript('OnClick',function() VC.requestRoster(); VC.readSoon(true) end)
  setTip(refresh,'Refresh','Asks the game for the latest guild roster.')
  local gear=CreateFrame('Button',nil,f)
  gear:SetSize(22,22); gear:SetPoint('LEFT',refresh,'RIGHT',8,0)
  gear:SetNormalTexture('Interface\\Icons\\INV_Misc_Gear_01')
  gear:SetHighlightTexture('Interface\\Buttons\\ButtonHilight-Square','ADD')
  setTip(gear,'Settings')
  local forge=smallButton(f,'GuildForge',96,22); forge:SetPoint('TOPRIGHT',-148,-36)
  forge:SetScript('OnClick',VC.openForge)
  setTip(forge,'GuildForge','Opens GuildForge: guild professions, recipes and craft requests.')
  local bank=smallButton(f,'Un-Ninja Bank',116,22); bank:SetPoint('LEFT',forge,'RIGHT',4,0)
  bank:SetScript('OnClick',function() VC.openBank() end)
  setTip(bank,'Un-Ninja Bank','Opens Un-Ninja Bank: the guild bank, requests and donations.')
  f.forgeButton,f.bankButton=forge,bank
  local header=CreateFrame('Frame',nil,f,BACKDROP_TEMPLATE)
  header:SetPoint('TOPLEFT',16,-64); header:SetPoint('TOPRIGHT',-16,-64); header:SetHeight(52); skin(header,.8)
  headerIcon=header:CreateTexture(nil,'ARTWORK'); headerIcon:SetSize(38,38); headerIcon:SetPoint('LEFT',8,0); headerIcon:SetTexCoord(.07,.93,.07,.93)
  headerTitle=header:CreateFontString(nil,'OVERLAY','GameFontNormalLarge'); headerTitle:SetPoint('TOPLEFT',headerIcon,'TOPRIGHT',10,-2)
  headerSub=header:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall'); headerSub:SetPoint('BOTTOMLEFT',headerIcon,'BOTTOMRIGHT',10,3)
  local inset=CreateFrame('Frame',nil,f,BACKDROP_TEMPLATE)
  inset:SetPoint('TOPLEFT',16,-120); inset:SetPoint('BOTTOMRIGHT',-16,36); skin(inset,.75,.55,.45,.28)
  local pageHolder=CreateFrame('Frame',nil,inset); pageHolder:SetAllPoints()
  pageScroll=CreateFrame('ScrollFrame','VillageCommandScrollFrame',pageHolder,'UIPanelScrollFrameTemplate')
  pageScroll:SetPoint('TOPLEFT',8,-8); pageScroll:SetPoint('BOTTOMRIGHT',-30,8)
  pageContent=CreateFrame('Frame',nil,pageScroll); pageContent:SetSize(CONTENT_W,100)
  pageScroll:SetScrollChild(pageContent)
  VC.buildRosterPage(inset)
  rosterPage:Hide()
  f.settingsPanel=VC.makeSettingsPanel(f,inset)
  gear:SetScript('OnClick',function() f.settingsPanel:SetShown(not f.settingsPanel:IsShown()) end)
  status=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall'); status:SetPoint('BOTTOMLEFT',22,17)
  local hint=f:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); hint:SetPoint('BOTTOMRIGHT',-22,17)
  hint:SetText('/vc help for commands')
  f.tabButtons={}
  for i,tab in ipairs(VC.tabs) do makeTab(i,tab) end
  f:HookScript('OnHide',function() VC.hideMenu(); if VC.noteDialog then VC.noteDialog:Hide() end end)
  f:Hide()
end
function VC.open(tab)
  if not window then VC.makeWindow() end
  if tab then VillageCommandDB.ui.tab=tab end
  window:Show()
  VC.requestRoster()
  VC.readSoon(true)
  VC.update()
end
function VC.toggle()
  if window and window:IsShown() then window:Hide() else VC.open() end
end
VC.window=function() return window end
-- Esc > Options > AddOns entry on clients with the modern Settings panel.
function VC.registerOptions()
  if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
  local panel=CreateFrame('Frame')
  local text=panel:CreateFontString(nil,'OVERLAY','GameFontHighlight')
  text:SetPoint('TOPLEFT',16,-16)
  text:SetText('Settings live in the Village Command window. Click the Village Command minimap button (the guild tabard) or type /vc.')
  local open=CreateFrame('Button',nil,panel,'UIPanelButtonTemplate')
  open:SetSize(200,24); open:SetPoint('TOPLEFT',text,'BOTTOMLEFT',0,-12); open:SetText('Open Village Command')
  open:SetScript('OnClick',function() VC.open(); window.settingsPanel:Show() end)
  Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel,'Village Command'))
end

-- Minimap button: the guild tabard with a green badge counting guildmates online. Same ring as LibDBIcon
-- buttons (and GuildForge's), following square minimaps.
VC.minimapShapes={
  ROUND={true,true,true,true}, SQUARE={false,false,false,false},
  ['CORNER-TOPLEFT']={false,false,false,true}, ['CORNER-TOPRIGHT']={false,false,true,false},
  ['CORNER-BOTTOMLEFT']={false,true,false,false}, ['CORNER-BOTTOMRIGHT']={true,false,false,false},
  ['SIDE-LEFT']={false,true,false,true}, ['SIDE-RIGHT']={true,false,true,false},
  ['SIDE-TOP']={false,false,true,true}, ['SIDE-BOTTOM']={true,true,false,false},
  ['TRICORNER-TOPLEFT']={false,true,true,true}, ['TRICORNER-TOPRIGHT']={true,false,true,true},
  ['TRICORNER-BOTTOMLEFT']={true,true,false,true}, ['TRICORNER-BOTTOMRIGHT']={true,true,true,false},
}
function VC.minimapOffset(degrees)
  local angle=math.rad(degrees or 225)
  local x,y=math.cos(angle),math.sin(angle)
  local q=1
  if x<0 then q=q+1 end
  if y>0 then q=q+2 end
  local shape=GetMinimapShape and GetMinimapShape() or 'ROUND'
  local round=(VC.minimapShapes[shape] or VC.minimapShapes.ROUND)[q]
  local w,h=Minimap:GetWidth()/2+5,Minimap:GetHeight()/2+5
  if round then return x*w,y*h end
  local dw,dh=math.sqrt(2*w*w)-10,math.sqrt(2*h*h)-10
  return math.max(-w,math.min(x*dw,w)),math.max(-h,math.min(y*dh,h))
end
local function positionMinimap()
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint('CENTER',Minimap,'CENTER',VC.minimapOffset(VillageCommandDB.minimap.angle))
end
local function showMinimapTooltip(self)
  GameTooltip:SetOwner(self,'ANCHOR_LEFT')
  GameTooltip:AddLine('Village Command',1,.82,0)
  local guild=VC.guildName()
  if guild then
    GameTooltip:AddLine('<'..guild..'>  '..VC.onlineCount()..' of '..#VC.roster..' online',1,1,1)
    local online={}
    for _,m in ipairs(VC.roster) do if m.online then online[#online+1]=m end end
    table.sort(online,function(a,b) if a.rankIndex~=b.rankIndex then return a.rankIndex<b.rankIndex end return a.short<b.short end)
    for i=1,math.min(#online,15) do GameTooltip:AddDoubleLine('   '..VC.colorName(online[i]),online[i].zone,1,1,1,.6,.6,.6) end
    if #online>15 then GameTooltip:AddLine('   and '..(#online-15)..' more',.6,.6,.6) end
    local ready=#(VC.readyForPromotion())
    if ready>0 then GameTooltip:AddLine(ready..' ready for promotion',1,.82,0) end
    if VC.hasBank() then
      local b=VC.bankSummary()
      if b then GameTooltip:AddLine('Guild bank: '..VC.money(b.gold)..(b.open>0 and ('  ·  '..b.open..' open requests') or ''),.85,.67,.33) end
    end
  else GameTooltip:AddLine('Not in a guild',.6,.6,.6) end
  GameTooltip:AddLine(' ')
  GameTooltip:AddLine('|cffffd100Left-click|r  open Village Command',.85,.85,.85)
  GameTooltip:AddLine('|cffffd100Right-click|r  open the roster',.85,.85,.85)
  GameTooltip:AddLine('|cffffd100Drag|r  move this button',.85,.85,.85)
  GameTooltip:Show()
end
function VC.refreshMinimap()
  if not minimapButton then return end
  minimapButton.count:SetText(VC.onlineCount())
  if GameTooltip:IsOwned(minimapButton) then showMinimapTooltip(minimapButton) end
end
function VC.makeMinimapButton()
  local b=CreateFrame('Button','VillageCommandMinimapButton',Minimap)
  minimapButton=b
  b:SetSize(31,31); b:SetFrameStrata('MEDIUM'); b:SetFrameLevel(8)
  b:RegisterForClicks('LeftButtonUp','RightButtonUp'); b:RegisterForDrag('LeftButton')
  b:SetHighlightTexture('Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight')
  -- Laid out like LibDBIcon's buttons so it sits right among other addons' minimap buttons.
  local bg=b:CreateTexture(nil,'BACKGROUND')
  bg:SetTexture('Interface\\Minimap\\UI-Minimap-Background'); bg:SetSize(20,20); bg:SetPoint('TOPLEFT',7,-5)
  local icon=b:CreateTexture(nil,'ARTWORK')
  icon:SetTexture(VC.ICON); icon:SetSize(17,17); icon:SetPoint('TOPLEFT',7,-6); icon:SetTexCoord(.05,.95,.05,.95)
  b.icon=icon
  local border=b:CreateTexture(nil,'OVERLAY')
  border:SetTexture('Interface\\Minimap\\MiniMap-TrackingBorder'); border:SetSize(50,50); border:SetPoint('TOPLEFT')
  -- The icon dips while the button is held, like the game's own minimap buttons.
  b:SetScript('OnMouseDown',function() icon:SetTexCoord(0,1,0,1) end)
  b:SetScript('OnMouseUp',function() icon:SetTexCoord(.05,.95,.05,.95) end)
  local badge=CreateFrame('Frame',nil,b)
  badge:SetSize(15,15); badge:SetPoint('CENTER',b,'TOPLEFT',28,-26); badge:SetFrameLevel(b:GetFrameLevel()+2)
  local badgeBg=badge:CreateTexture(nil,'ARTWORK')
  badgeBg:SetTexture(DOT_TEXTURE); badgeBg:SetAllPoints(); badgeBg:SetVertexColor(.1,.5,.1)
  b.count=badge:CreateFontString(nil,'OVERLAY')
  b.count:SetFont('Fonts\\FRIZQT__.TTF',8,'OUTLINE'); b.count:SetPoint('CENTER',0,0); b.count:SetTextColor(1,1,1)
  b:SetScript('OnClick',function(_,mouse) if mouse=='RightButton' then VC.open('roster') else VC.toggle() end end)
  b:SetScript('OnEnter',showMinimapTooltip)
  b:SetScript('OnLeave',GameTooltip_Hide)
  b:SetScript('OnDragStart',function(self)
    self:SetScript('OnUpdate',function()
      local mx,my=Minimap:GetCenter()
      local px,py=GetCursorPosition()
      local scale=Minimap:GetEffectiveScale()
      VillageCommandDB.minimap.angle=math.deg(math.atan2(py/scale-my,px/scale-mx))
      positionMinimap()
    end)
  end)
  b:SetScript('OnDragStop',function(self) self:SetScript('OnUpdate',nil) end)
  positionMinimap()
  b:SetShown(not VillageCommandDB.minimap.hide)
  VC.refreshMinimap()
end
function VillageCommand_OnCompartmentClick(_,mouse)
  if mouse=='RightButton' then VC.open('roster') else VC.toggle() end
end

-- Slash commands ------------------------------------------------------------------------------------
SLASH_VILLAGECOMMAND1='/villagecommand'; SLASH_VILLAGECOMMAND2='/vc'; SLASH_VILLAGECOMMAND3='/village'
SlashCmdList.VILLAGECOMMAND=function(message)
  local command,arg=(message or ''):match('^%s*(%S*)%s*(.-)%s*$')
  command=(command or ''):lower()
  if not VillageCommandDB then return end
  local pages={promos='promos',promotions='promos',promote='promos',checklist='promos',roster='roster',overview='overview',progress='progress',progression='progress',stats='stats',fun='stats',
    forge='forge',professions='forge',prof='forge',bank='bank'}
  if command=='' then VC.toggle()
  elseif pages[command] then VC.open(pages[command])
  elseif command=='online' or command=='who' then
    local online={}
    for _,m in ipairs(VC.roster) do if m.online then online[#online+1]=m end end
    table.sort(online,function(a,b) return a.short<b.short end)
    log(#online..' of '..#VC.roster..' online:',true)
    for _,m in ipairs(online) do log('   '..VC.colorName(m)..' '..m.level..'  '..m.rank..'  |cff909090'..m.zone..'|r',true) end
  elseif command=='settings' or command=='config' or command=='options' then VC.open(); window.settingsPanel:Show()
  elseif command=='minimap' then
    VillageCommandDB.minimap.hide=not VillageCommandDB.minimap.hide
    if minimapButton then minimapButton:SetShown(not VillageCommandDB.minimap.hide) end
    log('Minimap button '..(VillageCommandDB.minimap.hide and 'hidden' or 'shown')..'.',true)
  elseif command=='cancel' then VC.cancelJobs()
  elseif command=='sync' then
    if not VC.syncOn() then log('Sharing history is off (Settings), or you\'re not in a guild.',true)
    else VC.sync.lastDump=0; VC.sayHello(); log('Asked guildmates running Village Command to compare history.',true) end
  elseif command=='unblock' then
    if VillageCommandDB.blocked then VillageCommandDB.blocked[VC.flavor]=nil end
    log('Forgot the actions the game blocked; Village Command will try them again (the game says so if they\'re still blocked).',true)
    requestRedraw()
  elseif command=='blocked' then VC.printBlocked()
  elseif command=='status' then
    local p=VC.perms()
    log(string.format('v%s; guild=%s; members=%d (game reports %s); online=%d; roster complete=%s; your rank=%s',VERSION,tostring(VC.guildName()),#VC.roster,
      tostring(GetNumGuildMembers and GetNumGuildMembers()),VC.onlineCount(),tostring(VC.rosterComplete()),tostring(VC.myRankIndex())),true)
    if VC.lastError then log('last roster error: '..VC.lastError,true) end
    local blocked={}
    for feature in pairs(VC.features) do local l=VC.blockLevel(feature); if l then blocked[#blocked+1]=VC.features[feature]..' ('..(l=='all' and 'guild window only' or 'one at a time')..')' end end
    table.sort(blocked)
    if #blocked>0 then log('blocked by the game on '..VC.flavor..': '..table.concat(blocked,', '),true) end
    local gp=VillageCommandDB.gpromote and VillageCommandDB.gpromote[VC.flavor]
    if gp then log('/gpromote from the promote helper: '..gp,true) end
    local sy=VC.sync
    log(string.format('history sync %s: %d messages sent, %d received, %d pieces merged, %d not trusted, %d waiting; fingerprint %s%s',
      VC.syncOn() and 'on' or 'off',sy.sent,sy.received,sy.merged,sy.rejected,#sy.out,VC.digest(),sy.lastError and ('; last error: '..sy.lastError) or ''),true)
    log(string.format('can promote=%s demote=%s public notes=%s officer notes=%s view officer notes=%s; GuildForge=%s; Un-Ninja Bank=%s',
      tostring(p.promote),tostring(p.demote),tostring(p.publicNote),tostring(p.officerNote),tostring(p.viewOfficer),tostring(VC.hasForge()),tostring(VC.bankAPI()~=nil)),true)
  elseif command=='quiet' then
    VillageCommandDB.settings.quiet=not VillageCommandDB.settings.quiet
    log('Quiet mode '..(VillageCommandDB.settings.quiet and 'on' or 'off')..'.',true)
  else
    log('/vc opens the window. Pages: /vc roster, progress, stats, forge, bank. Also: online lists who\'s on; settings; minimap toggles the button; cancel stops a mass change; sync compares history with guildmates now; status shows what your rank can do and the sync counters; unblock retries actions the game blocked before; blocked lists what the game blocked this session; quiet toggles chat messages.',true)
  end
end

-- Events --------------------------------------------------------------------------------------------
for _,event in ipairs({'PLAYER_LOGIN','PLAYER_ENTERING_WORLD','PLAYER_GUILD_UPDATE','GUILD_ROSTER_UPDATE','GUILD_RANKS_UPDATE','GUILD_MOTD','PLAYER_REGEN_ENABLED',
  'ADDON_ACTION_FORBIDDEN','ADDON_ACTION_BLOCKED','CHAT_MSG_ADDON'}) do
  pcall(frame.RegisterEvent,frame,event)
end
-- Reads the roster the game already has. Don't wait for GUILD_ROSTER_UPDATE: the roster often arrives during
-- the loading screen, before this addon is ready, and the server ignores roster requests made within about
-- 10 seconds of another addon's, so no new event may come for a while.
function VC.paused()
  if InCombatLockdown and InCombatLockdown() then return true end
  local inInstance=IsInInstance and IsInInstance()
  return inInstance and true or false
end
function VC.readSoon(now)
  rosterDirty=true
  if now then sinceRead=math.max(sinceRead,1.5) end
end
function VC.reportError(err)
  VC.lastError=tostring(err)
  if not VC.errorShown then
    VC.errorShown=true
    log('Couldn\'t read part of the guild roster ('..VC.lastError..'). Please report this with what /vc status prints.',true)
  end
end
-- Reading and tracking are protected: one bad roster entry must not stop the roster loading every time after.
function VC.loadRoster()
  local ok,err=pcall(VC.readRoster)
  if ok then ok,err=pcall(VC.track) end
  if ok then ok,err=pcall(VC.checkDings) end
  if not ok then VC.reportError(err); return end
  if not VC.sampledOnce and #VC.roster>0 then VC.sampledOnce=true; VC.sample() end
  if VC.helperState.pending then VC.helperCheck() end
  VC.helperRefresh()
end
frame:SetScript('OnEvent',function(_,event,...)
  if event=='CHAT_MSG_ADDON' then
    local prefix,msg,channel,sender=...
    if prefix==SYNC_PREFIX and channel=='GUILD' and VC.ready and not VC.paused() and type(msg)=='string' and not isSecret(msg) and not isSecret(sender) then
      local ok,err=pcall(VC.onSyncMessage,msg,sender)
      if not ok then VC.sync.lastError=tostring(err) end
    end
    return
  end
  if event=='ADDON_ACTION_FORBIDDEN' or event=='ADDON_ACTION_BLOCKED' then
    local who,fn=...
    if who==addonName then
      VC.noteBlocked(event,fn)
      if VC.ready then VC.onBlocked(event,fn) end
    end
    return
  end
  if event=='PLAYER_LOGIN' then
    VC.initDB()
    VC.makeMinimapButton()
    VC.registerOptions()
    VC.requestRoster()
    VC.ready=true
    VC.readSoon(true)
    local register=(C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if register then pcall(register,SYNC_PREFIX) end
    -- Say hello once the roster and guild have loaded.
    later(12,VC.sayHello)
    log('v'..VERSION..' loaded. Click the guild tabard on the minimap or type /vc to open.')
  elseif not VC.ready then return
  elseif event=='GUILD_ROSTER_UPDATE' or event=='PLAYER_GUILD_UPDATE' or event=='GUILD_RANKS_UPDATE' or event=='PLAYER_ENTERING_WORLD' then
    VC.readSoon()
  else
    if event=='PLAYER_REGEN_ENABLED' then
      if VC.helperCloseAfterCombat then VC.helperCloseAfterCombat=nil; VC.closePromoteHelper() else VC.helperRefresh() end
    end
    requestRedraw()
  end
end)
frame:SetScript('OnUpdate',function(_,elapsed)
  if not VC.ready then return end
  VC.tickJobs(elapsed)
  -- In combat or an instance (dungeon, raid, battleground) Village Command sits still: no roster requests
  -- or reads, no redraws, no sync messages, no samples, no celebrations. Forever (Midnight) blocks some of
  -- these there and blames the addon; it all catches up the moment you're out.
  if VC.paused() then VC.pausedForCombat=true; return end
  if VC.pausedForCombat then VC.pausedForCombat=nil; VC.readSoon(true); requestRedraw() end
  VC.syncDrain(elapsed)
  -- Roster updates come in bursts; read it at most every second and a half.
  sinceRead=sinceRead+elapsed
  if rosterDirty and sinceRead>=1.5 then
    rosterDirty=false; sinceRead=0
    VC.loadRoster()
    requestRedraw()
  end
  sinceUpdate=sinceUpdate+elapsed
  if updatePending and sinceUpdate>=.25 then VC.update() end
  -- The server answers roster requests at most every 10 seconds; ask more often while the window is open,
  -- and read what the game has each time in case the answer came without an event.
  sinceRoster=sinceRoster+elapsed
  if sinceRoster>=((window and window:IsShown()) and 15 or 60) then sinceRoster=0; VC.requestRoster(); VC.readSoon() end
  sinceSample=sinceSample+elapsed
  if sinceSample>=300 then sinceSample=0; VC.sample() end
end)
