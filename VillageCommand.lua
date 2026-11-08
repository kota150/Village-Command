-- Village Command - guild overview and progression suite for Classic Era, WoW: Forever and retail.
-- Online members, the full roster with notes and officer notes, mass promote / demote / set rank / notes,
-- fun stats, progression tracking, and one window that ties in GuildForge (professions) and Un-Nina Bank
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
-- A white circle (the portrait mask) so vertex colors show true; tinting a dark texture stays dark.
local DOT_TEXTURE='Interface\\CharacterFrame\\TempPortraitAlphaMask'
local CONTENT_W=684
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
-- The same rules GuildForge and Un-Nina Bank use, so a character matches across all three addons.
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
  local name=UnitName and UnitName('player')
  if not name or isSecret(name) then return nil end
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
function VC.readRoster()
  local list,byId={},{}
  VC.rosterHasOffline=false
  if IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo then
    for i=1,(tonumber(GetNumGuildMembers()) or 0) do
      local name,rankName,rankIndex,level,class,zone,note,officerNote,online,_,classFile,points,_,mobile,_,_,guid=GetGuildRosterInfo(i)
      local id=VC.nameId(name)
      if id and not byId[id] then
        local m={index=i,name=name,id=id,short=VC.displayName(name),rank=clean(rankName),
          rankIndex=tonumber(not isSecret(rankIndex) and rankIndex) or 0,level=tonumber(not isSecret(level) and level) or 0,
          class=clean(class),classFile=clean(classFile),zone=clean(zone),note=clean(note),officerNote=clean(officerNote),
          online=(online and not isSecret(online)) and true or false,mobile=mobile and not isSecret(mobile) and true or nil,
          points=tonumber(not isSecret(points) and points),guid=(type(guid)=='string' and not isSecret(guid)) and guid or nil}
        if m.online then m.away=0 else m.away=awayFor(i); VC.rosterHasOffline=true end
        list[#list+1]=m; byId[id]=m
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
  for i=1,(tonumber(GetNumGuildMembers()) or 0) do
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
  local n=GuildControlGetNumRanks and tonumber(GuildControlGetNumRanks()) or 0
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
function VC.perms()
  local CG=C_GuildInfo or {}
  return {
    promote=anyTrue(CanGuildPromote,CG.CanGuildPromote),
    demote=anyTrue(CanGuildDemote,CG.CanGuildDemote),
    publicNote=anyTrue(CanEditPublicNote,CG.CanEditPublicNote),
    officerNote=anyTrue(CanEditOfficerNote,CG.CanEditOfficerNote),
    viewOfficer=anyTrue(CanViewOfficerNote,CG.CanViewOfficerNote),
  }
end
-- Whether one step up (dir 1) or down (dir -1) from rank `from` is allowed; false plus the reason if not.
-- You can only move people who rank below you, and never to your own rank or above.
function VC.canStep(m,from,dir,perms)
  perms=perms or VC.perms()
  local me=VC.myRankIndex()
  if not me then return false,'Your guild rank isn\'t known yet' end
  if m.id==VC.myId() then return false,'You can\'t change your own rank' end
  if dir>0 then
    if not perms.promote then return false,'Your rank can\'t promote' end
    if from-1<=me then return false,'Already as high as you can promote' end
  else
    if not perms.demote then return false,'Your rank can\'t demote' end
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
function VC.stepRank(m,dir)
  local CG=C_GuildInfo or {}
  if dir>0 then return callFirst({m.name},GuildPromote,CG.Promote) end
  return callFirst({m.name},GuildDemote,CG.Demote)
end
-- Notes are written by roster index on Classic, by GUID on retail.
function VC.writeNote(m,text,officer)
  local index=VC.indexOf(m.id)
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
function VC.runJob(job)
  local m=VC.byId[job.id]
  if not m then return 'skip','left the guild' end
  if job.kind=='step' then
    local ok,why=VC.canStep(m,job.from,job.dir)
    if not ok then return 'skip',why end
    local done,err=VC.stepRank(m,job.dir)
    if not done then return 'fail',err end
    -- The roster catches up a moment later; keep the local copy right for the rest of the queue.
    m.rankIndex=job.from-job.dir
    return 'ok'
  elseif job.kind=='note' then
    local perms=VC.perms()
    if job.officer and not perms.officerNote then return 'skip','Your rank can\'t edit officer notes' end
    if not job.officer and not perms.publicNote then return 'skip','Your rank can\'t edit public notes' end
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
  local result,why=VC.runJob(job)
  if result=='ok' then q.done=q.done+1
  elseif result=='fail' then q.failed=q.failed+1; q.errors[#q.errors+1]=(VC.byId[job.id] and VC.byId[job.id].short or job.id)..': '..tostring(why)
  else q.skipped=q.skipped+1; q.errors[#q.errors+1]=(VC.byId[job.id] and VC.byId[job.id].short or job.id)..': '..tostring(why) end
  q.wait=math.max(.2,tonumber(settings().throttle) or .6)
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
-- Selected members in roster order (rank, then name) so a mass action reads the way the list does.
function VC.selectedMembers()
  local list={}
  for _,m in ipairs(VC.roster) do if VC.selected[m.id] then list[#list+1]=m end end
  table.sort(list,function(a,b) if a.rankIndex~=b.rankIndex then return a.rankIndex<b.rankIndex end return a.short<b.short end)
  return list
end
-- One step per member for promote/demote; several for "set rank", walking one rank at a time.
function VC.rankJobs(members,dir,target)
  local jobs,skipped,perms={},{},VC.perms()
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
StaticPopupDialogs=StaticPopupDialogs or {}
StaticPopupDialogs.VILLAGECOMMAND_CONFIRM={
  text='%s', button1=YES or 'Yes', button2=NO or 'No',
  OnAccept=function(self,data) if type(data)=='function' then data() end end,
  timeout=0, whileDead=true, hideOnEscape=true,
}
StaticPopupDialogs.VILLAGECOMMAND_RESET={
  text='Reset Village Command\'s statistics for this guild?\n\nLevel history, the activity feed and online records start over. Notes and ranks in the game are not touched.',
  button1=YES or 'Yes', button2=NO or 'No',
  OnAccept=function() VC.resetStats() end,
  timeout=0, whileDead=true, hideOnEscape=true,
}
-- Asks first (unless confirmations are off), naming the first few people the change touches.
function VC.confirm(question,members,run)
  if not settings().confirm then run(); return end
  local names={}
  for i=1,math.min(#members,6) do names[i]=members[i].short end
  local who=table.concat(names,', ')..(#members>6 and (' and '..(#members-6)..' more') or '')
  if StaticPopup_Show then StaticPopup_Show('VILLAGECOMMAND_CONFIRM',question..'\n\n'..who,nil,run) else run() end
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
  local perms=VC.perms()
  if officer and not perms.officerNote then log('Your rank can\'t edit officer notes.',true); return end
  if not officer and not perms.publicNote then log('Your rank can\'t edit public notes.',true); return end
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
function VC.event(g,kind,name,detail)
  g.events[#g.events+1]={t=now(),k=kind,n=name,d=detail}
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
      if logJoins then VC.event(g,'join',m.short,'joined at level '..m.level) end
    else
      local was=rec.level or m.level
      -- A level can only drop through bad data (a renamed or re-rolled character); start its history over.
      if m.level<was then rec.levels={{t,m.level}}; was=m.level end
      if m.level>was then
        for lvl=was+1,m.level do
          if lvl%10==0 or lvl==maxLevel then VC.event(g,'ding',m.short,lvl==maxLevel and ('hit the level cap ('..lvl..')') or ('reached level '..lvl)) end
        end
        rec.levels=rec.levels or {}
        rec.levels[#rec.levels+1]={t,m.level}
        while #rec.levels>40 do table.remove(rec.levels,1) end
      end
      if rec.rank and m.rankIndex~=rec.rank then
        VC.event(g,m.rankIndex<rec.rank and 'promote' or 'demote',m.short,(m.rankIndex<rec.rank and 'promoted to ' or 'demoted to ')..(names[m.rankIndex] or m.rank))
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
          if not VC.byId[id] then VC.event(g,'leave',rec.name or id,'left the guild'); g.members[id]=nil end
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
-- Un-Nina Bank (folder GuildBankToons): its public API for opening tabs, and its helper table for gold and
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
  log('Un-Nina Bank isn\'t loaded. Install it (CurseForge: Un-Nina Bank) to see the guild bank here.',true)
end
function VC.bankSummary()
  if not VC.bankAPI() then return nil end
  local s={gold=tonumber(bankCall('currentGold','*')) or 0,banks={},requests={},open=0}
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
    tinsert(UISpecialFrames,'VillageCommandMenu')
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
    local w=(b.text.GetStringWidth and tonumber(b.text:GetStringWidth()) or 0)+28
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
    c:SetSize((CONTENT_W-18)/4,58); c:SetPoint('TOPLEFT',(i-1)*((CONTENT_W-18)/4+6),0)
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
  b.label=fontString(b,'GameFontHighlight'); b.label:SetPoint('LEFT',26,0); b.label:SetWidth(190)
  b.bar=CreateFrame('StatusBar',nil,b); b.bar:SetSize(300,13); b.bar:SetPoint('LEFT',222,0)
  b.bar:SetStatusBarTexture('Interface\\TargetingFrame\\UI-StatusBar')
  local bg=b.bar:CreateTexture(nil,'BACKGROUND'); bg:SetAllPoints(); bg:SetColorTexture(0,0,0,.55)
  b.bar.text=fontString(b.bar,'GameFontHighlightSmall','CENTER'); b.bar.text:SetPoint('CENTER',0,0)
  b.value=fontString(b,'GameFontHighlightSmall','RIGHT'); b.value:SetPoint('RIGHT',-8,0); b.value:SetWidth(160)
  addHighlight(b,.2)
  return b
end
factories.line=function()
  local b=CreateFrame('Button',nil,pageContent)
  b:SetHeight(20)
  b.stripe=b:CreateTexture(nil,'BACKGROUND'); b.stripe:SetAllPoints()
  b.dot=b:CreateTexture(nil,'ARTWORK'); b.dot:SetTexture(DOT_TEXTURE); b.dot:SetSize(9,9); b.dot:SetPoint('LEFT',8,0)
  b.icon=b:CreateTexture(nil,'ARTWORK'); b.icon:SetSize(16,16); b.icon:SetPoint('LEFT',4,0); b.icon:SetTexCoord(.07,.93,.07,.93)
  b.text=fontString(b,'GameFontHighlight'); b.text:SetPoint('LEFT',26,0); b.text:SetWidth(420)
  b.right=fontString(b,'GameFontHighlightSmall','RIGHT'); b.right:SetPoint('RIGHT',-8,0); b.right:SetWidth(250)
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
  for i=1,4 do
    local b=smallButton(f,'',150,22)
    b:SetPoint('LEFT',(i-1)*158+4,0)
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
-- Page layout: widgets stack down the scroll content.
local cursor=0
local function place(w,height,indent)
  w:SetPoint('TOPLEFT',pageContent,'TOPLEFT',indent or 0,cursor)
  w:SetWidth(CONTENT_W-(indent or 0))
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
  for i,c in ipairs(f.cards) do
    local card=list[i]
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
  local slot=(CONTENT_W-24)/math.max(1,n)
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
  local h=height or math.max(16,(f.text.GetStringHeight and tonumber(f.text:GetStringHeight()) or 14)+6)
  f:SetHeight(h)
  return place(f,h)
end

-- Pages ---------------------------------------------------------------------------------------------
VC.tabs={
  {key='overview',label='Overview',icon='Interface\\Icons\\INV_Misc_Map_01',sub='Who\'s on, what\'s new, and your other guild addons'},
  {key='roster',label='Roster',icon='Interface\\Icons\\Spell_Holy_PrayerOfFortitude',sub='Every member: notes, officer notes, promote and demote, one or many at once'},
  {key='progress',label='Progression',icon='Interface\\Icons\\INV_Misc_PocketWatch_01',sub='Milestones, this week\'s growth, top climbers and the activity feed'},
  {key='stats',label='Fun Stats',icon='Interface\\Icons\\INV_Misc_Spyglass_03',sub='Classes, levels, busiest hours and the guild\'s superlatives'},
  {key='forge',label='Professions',icon='Interface\\Icons\\Trade_BlackSmithing',sub='From GuildForge: who crafts what, top skills, crafters online'},
  {key='bank',label='Guild Bank',icon='Interface\\Icons\\INV_Misc_Bag_10_Blue',sub='From Un-Nina Bank: gold, bank toons and open requests'},
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
  if VC.bankToons()[m.id] then GameTooltip:AddLine('Guild bank toon (Un-Nina Bank)',.85,.67,.33) end
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
    ding='Interface\\Icons\\Spell_Holy_SurgeOfLight',promote='Interface\\Icons\\Spell_Holy_GreaterBlessingofKings',
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
VC.pages.overview=function()
  local s=VC.stats()
  local maxLevel=VC.maxLevel()
  VC.cards({
    {value=tostring(s.total),label='Members',sub=VC.rosterComplete() and 'whole roster' or 'online only: tick Show offline',onClick=function() VC.selectTab('roster') end},
    {value='|cff40ff40'..s.online..'|r',label='Online now',sub=s.total>0 and (math.floor(s.online*100/s.total+.5)..'% of the guild') or ''},
    {value=tostring(s.maxed),label='At level '..maxLevel,sub=s.total>0 and (math.floor(s.maxed*100/s.total+.5)..'% capped') or ''},
    {value=string.format('%.1f',s.average),label='Average level',sub=s.topClass and ('most are '..(s.classes[s.topClass].label or s.topClass)) or ''},
  })
  if not (InCombatLockdown and InCombatLockdown()) and GetGuildRosterMOTD then
    local ok,motd=pcall(GetGuildRosterMOTD)
    if ok and type(motd)=='string' and not isSecret(motd) and motd~='' then
      VC.section('Message of the day')
      VC.note('|cff40ff40'..motd:gsub('|','||')..'|r')
    end
  end
  local online={}
  for _,m in ipairs(VC.roster) do if m.online then online[#online+1]=m end end
  table.sort(online,function(a,b) if a.rankIndex~=b.rankIndex then return a.rankIndex<b.rankIndex end return a.short<b.short end)
  VC.section('Online now ('..#online..')','click someone to open them in the roster')
  stripe=0
  for _,m in ipairs(online) do
    VC.line(VC.colorName(m)..'  |cff909090'..m.level..'  '..m.rank..'|r',m.zone..(m.mobile and ' (mobile)' or ''),
      {online=true,onClick=function() VC.focusMember(m.id) end,onEnter=function(self) VC.memberTooltip(self,m) end})
  end
  if #online==0 then VC.note('|cff909090No one is online'..(#VC.roster==0 and ' (the roster hasn\'t loaded yet)' or '')..'.|r') end
  VC.section('Recent activity')
  stripe=0
  VC.feed(8)
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
    VC.line('|cffd8aa55Un-Nina Bank|r  '..VC.money(bank.gold)..'  ·  '..bank.open..' open request'..(bank.open==1 and '' or 's'),'Open Un-Nina Bank',
      {icon='Interface\\Icons\\INV_Misc_Bag_10_Blue',onClick=function() VC.openBank() end})
  elseif VC.bankAPI() then
    VC.line('|cffd8aa55Un-Nina Bank|r  no bank toons set up for this guild yet','Open Un-Nina Bank',
      {icon='Interface\\Icons\\INV_Misc_Bag_10_Blue',onClick=function() VC.openBank('gm') end})
  else
    VC.line('|cff909090Un-Nina Bank|r  not installed: the guild bank, requests and donations','',{icon='Interface\\Icons\\INV_Misc_Bag_10_Blue'})
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
  VC.buttons({{label='Reset statistics',func=function() StaticPopup_Show('VILLAGECOMMAND_RESET') end,tip='Start the history, records and activity feed over for this guild.'}})
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
  VC.section('Professions','members · top skill · online now')
  stripe=0
  for _,name in ipairs(VC.professionList) do
    local p=summary[name]
    local right=p.count>0 and ((p.topName and (p.topName..' '..p.top) or '')..'  ·  |cff40ff40'..p.online..' online|r') or '|cff909090nobody yet|r'
    VC.bar(name,p.top,math.max(p.max,300,1),p.count..' member'..(p.count==1 and '' or 's'),{.9,.55,.25},VC.professionIcons[name],right,function(self)
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
VC.pages.bank=function()
  if not VC.bankAPI() then
    VC.section('Un-Nina Bank')
    VC.note('Install |cffd8aa55Un-Nina Bank|r to see the guild bank here: bank toons\' bags and gold, requests and donations, browsable even while the bank toons are offline.')
    return
  end
  VC.buttons({
    {label='Open bank',func=function() VC.openBank('items') end},
    {label='Requests',func=function() VC.openBank('requests') end},
    {label='Ledger',func=function() VC.openBank('donations') end},
    {label='Goals',func=function() VC.openBank('goals') end},
  })
  if not VC.hasBank() then
    VC.note('This guild has no bank toons yet. The guild master or an officer adds them on Un-Nina Bank\'s Guild tab.')
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
  {key='name',label='Name',x=40,w=140},
  {key='level',label='Lvl',x=184,w=30},
  {key='rank',label='Rank',x=218,w=100},
  {key='zone',label='Zone / last online',x=322,w=124},
  {key='note',label='Note',x=450,w=120},
  {key='officer',label='Officer note',x=574,w=100},
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
  local perms=VC.perms()
  local up,upWhy=VC.canStep(m,m.rankIndex,1,perms)
  local down,downWhy=VC.canStep(m,m.rankIndex,-1,perms)
  local invite=(C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
  local tell=ChatFrame_SendTell or (ChatFrameUtil and ChatFrameUtil.SendTell)
  VC.showMenu(anchor,{
    {text='Whisper '..m.short,func=function() if tell then tell(m.name) end end,disabled=not tell},
    {text='Invite to group',func=function() if invite then invite(m.name) end end,disabled=not invite or not m.online},
    {text='Promote',func=function() VC.startJobs('Promote '..m.short,(VC.rankJobs({m},1))) end,disabled=not up,tip=upWhy},
    {text='Demote',func=function() VC.startJobs('Demote '..m.short,(VC.rankJobs({m},-1))) end,disabled=not down,tip=downWhy},
    {text=VC.selected[m.id] and 'Untick' or 'Tick for a mass action',func=function() VC.toggleSelect(m.id); requestRedraw() end},
  })
end
function VC.drawRows()
  if not rosterPage or not rosterPage:IsShown() then return end
  local list=VC.filtered()
  local scroll=rosterPage.scroll
  local content=rosterPage.content
  content:SetHeight(math.max(1,#list*ROW_H))
  local width=tonumber(scroll:GetWidth()) or 0
  if width>100 then content:SetWidth(width) end
  local offset=scroll:GetVerticalScroll() or 0
  local height=tonumber(scroll:GetHeight()) or 300
  local first=math.floor(offset/ROW_H)+1
  local count=math.ceil(height/ROW_H)+1
  local canView=VC.perms().viewOfficer
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
  p.count:SetText(#list..' shown  ·  |cffffd100'..n..' ticked|r')
  local perms=VC.perms()
  local busy=VC.busy()
  local function set(b,ok,why)
    if ok and not busy then b:Enable() else b:Disable() end
    b.why=busy and ('Working: '..(VC.queue.label or '')..'. Wait or cancel.') or why
  end
  set(p.promote,n>0 and perms.promote,n==0 and 'Tick members first' or 'Your rank can\'t promote')
  set(p.demote,n>0 and perms.demote,n==0 and 'Tick members first' or 'Your rank can\'t demote')
  set(p.setRank,n>0 and (perms.promote or perms.demote),n==0 and 'Tick members first' or 'Your rank can\'t change ranks')
  set(p.massNote,n>0 and perms.publicNote,n==0 and 'Tick members first' or 'Your rank can\'t edit public notes')
  set(p.massOfficer,n>0 and perms.officerNote,n==0 and 'Tick members first' or 'Your rank can\'t edit officer notes')
  p.cancel:SetShown(busy)
  if busy then
    local q=VC.queue
    p.progress:SetText(string.format('|cffffd100Working|r %d / %d',q.pos,#q.list))
  else p.progress:SetText('') end
  -- The editor for the clicked member.
  local m=VC.focus and VC.byId[VC.focus]
  local e=p.editor
  if m then
    e.name:SetText(VC.colorName(m)..'  |cffa0a0a0Level '..m.level..' '..m.class..'  ·  '..m.rank..'  ·  '..(m.online and ('|cff40ff40'..(m.zone~='' and m.zone or 'online')..'|r') or ('last online '..VC.agoText(m.away)))..'|r')
    -- Refill the boxes only for a different member or when the note changed in the game, so half-typed
    -- text survives the roster refreshing.
    local officerText=perms.viewOfficer and m.officerNote or ''
    if e.shownFor~=m.id or (e.lastNote~=m.note and not e.note:HasFocus()) then e.note:SetText(m.note) end
    if e.shownFor~=m.id or (e.lastOfficer~=officerText and not e.officer:HasFocus()) then e.officer:SetText(officerText) end
    e.shownFor,e.lastNote,e.lastOfficer=m.id,m.note,officerText
    e.note.syncPlaceholder(e.note); e.officer.syncPlaceholder(e.officer)
    enable(e.note,perms.publicNote); enable(e.saveNote,perms.publicNote)
    enable(e.officer,perms.officerNote); enable(e.saveOfficer,perms.officerNote)
    local up,upWhy=VC.canStep(m,m.rankIndex,1,perms)
    local down,downWhy=VC.canStep(m,m.rankIndex,-1,perms)
    set(e.promote,up,upWhy); set(e.demote,down,downWhy)
    e:Show(); p.editorHint:Hide()
  else
    e:Hide(); p.editorHint:Show()
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
  listFrame:SetPoint('TOPLEFT',6,-54); listFrame:SetPoint('BOTTOMRIGHT',-6,104)
  skin(listFrame,.5,.55,.45,.28)
  local scroll=CreateFrame('ScrollFrame','VillageCommandRosterScroll',listFrame,'UIPanelScrollFrameTemplate')
  scroll:SetPoint('TOPLEFT',4,-4); scroll:SetPoint('BOTTOMRIGHT',-26,4)
  local content=CreateFrame('Frame',nil,scroll); content:SetSize(CONTENT_W,1)
  scroll:SetScrollChild(content)
  scroll:HookScript('OnVerticalScroll',function() VC.drawRows() end)
  scroll:HookScript('OnSizeChanged',function() VC.drawRows() end)
  p.scroll,p.content=scroll,content
  -- The editor for one member
  local e=CreateFrame('Frame',nil,p,BACKDROP_TEMPLATE)
  e:SetPoint('BOTTOMLEFT',6,32); e:SetPoint('BOTTOMRIGHT',-6,32); e:SetHeight(70); skin(e,.8)
  p.editor=e
  e.name=fontString(e,'GameFontNormal'); e.name:SetPoint('TOPLEFT',10,-8); e.name:SetWidth(560)
  local function noteField(label,x,officer)
    local l=fontString(e,'GameFontDisableSmall'); l:SetPoint('TOPLEFT',x,-30); l:SetText(label)
    local box=editBox(e,180,officer and 'Officer note' or 'Public note')
    box:SetPoint('TOPLEFT',x+4,-42); box:SetMaxLetters(NOTE_MAX)
    box:SetScript('OnTextChanged',function(self) self.syncPlaceholder(self) end)
    local save=smallButton(e,'Save',50,20); save:SetPoint('LEFT',box,'RIGHT',6,0)
    local function commit()
      local m=VC.focus and VC.byId[VC.focus]
      if not m then return end
      box:ClearFocus()
      local text=VC.trimNote(box:GetText())
      local old=officer and m.officerNote or m.note
      if text==old then return end
      VC.startJobs((officer and 'Officer note for ' or 'Note for ')..m.short,{{kind='note',id=m.id,officer=officer,text=text}})
    end
    save:SetScript('OnClick',commit)
    box:SetScript('OnEnterPressed',commit)
    return box,save
  end
  e.note,e.saveNote=noteField('Public note',8,false)
  e.officer,e.saveOfficer=noteField('Officer note',258,true)
  e.promote=smallButton(e,'Promote',80,20); e.promote:SetPoint('TOPRIGHT',-10,-30)
  e.demote=smallButton(e,'Demote',80,20); e.demote:SetPoint('TOPRIGHT',e.promote,'BOTTOMRIGHT',0,-2)
  e.promote:SetScript('OnClick',function() local m=VC.byId[VC.focus or ''] if m then VC.startJobs('Promote '..m.short,(VC.rankJobs({m},1))) end end)
  e.demote:SetScript('OnClick',function() local m=VC.byId[VC.focus or ''] if m then VC.startJobs('Demote '..m.short,(VC.rankJobs({m},-1))) end end)
  for _,b in ipairs({e.promote,e.demote}) do
    b:SetScript('OnEnter',function(self) if self.why then tooltip(self,self:GetText(),self.why) end end)
    b:SetScript('OnLeave',GameTooltip_Hide)
  end
  p.editorHint=fontString(p,'GameFontDisableSmall','CENTER'); p.editorHint:SetPoint('BOTTOM',p,'BOTTOM',0,62)
  p.editorHint:SetText('Click a member to edit their notes. Tick boxes (or shift-click a range) for mass actions; right-click for more.')
  -- Mass actions
  local bar=CreateFrame('Frame',nil,p)
  bar:SetPoint('BOTTOMLEFT',6,4); bar:SetPoint('BOTTOMRIGHT',-6,4); bar:SetHeight(26)
  local function action(label,width,anchor,fn)
    local b=smallButton(bar,label,width,22)
    b:SetPoint(unpack(anchor))
    b:SetScript('OnClick',fn)
    b:SetScript('OnEnter',function(self) if self.why then tooltip(self,label,self.why) end end)
    b:SetScript('OnLeave',GameTooltip_Hide)
    return b
  end
  local tick=action('Tick...',64,{'LEFT',0,0},function(self)
    VC.showMenu(self,{
      {text='Everyone shown',func=function() for _,m in ipairs(VC.filtered()) do VC.selected[m.id]=true end; requestRedraw() end},
      {text='Online members shown',func=function() for _,m in ipairs(VC.filtered()) do if m.online then VC.selected[m.id]=true end end; requestRedraw() end},
      {text='Invert',func=function() for _,m in ipairs(VC.filtered()) do VC.toggleSelect(m.id) end; requestRedraw() end},
      {text='Nobody',func=function() wipe(VC.selected); requestRedraw() end},
    })
  end)
  p.promote=action('Promote',76,{'LEFT',tick,'RIGHT',6,0},function() VC.massRank(1) end)
  p.demote=action('Demote',76,{'LEFT',p.promote,'RIGHT',4,0},function() VC.massRank(-1) end)
  p.setRank=action('Set rank...',90,{'LEFT',p.demote,'RIGHT',4,0},function(self)
    local names=VC.rankNames()
    local me=VC.myRankIndex() or 0
    local items={}
    for i=0,VC.lowestRank() do
      if names[i] then items[#items+1]={text=names[i],disabled=i<=me,tip=i<=me and 'Only ranks below yours' or nil,func=function() VC.massRank(0,i,names[i]) end} end
    end
    VC.showMenu(self,items)
  end)
  p.massNote=action('Public notes...',104,{'LEFT',p.setRank,'RIGHT',10,0},function() VC.openNoteDialog(false) end)
  p.massOfficer=action('Officer notes...',104,{'LEFT',p.massNote,'RIGHT',4,0},function() VC.openNoteDialog(true) end)
  p.progress=fontString(bar,'GameFontHighlightSmall','RIGHT'); p.progress:SetPoint('RIGHT',-70,0); p.progress:SetWidth(100)
  p.cancel=smallButton(bar,'Cancel',64,22); p.cancel:SetPoint('RIGHT',0,0); p.cancel:SetScript('OnClick',VC.cancelJobs)
  p.cancel:Hide()
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
    tinsert(UISpecialFrames,'VillageCommandNoteDialog')
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
  headerSub:SetText(tab.sub)
  local q=VC.queue
  local work=VC.busy() and ('  |  |cffffd100'..q.label..' '..q.pos..'/'..#q.list..'|r') or ''
  status:SetText(string.format('|cffffd100%s|r  |  %d / %d online%s',guild or 'Not in a guild',VC.onlineCount(),#VC.roster,work))
  if tab.key=='roster' then
    pageScroll:GetParent():Hide(); rosterPage:Show()
    VC.refreshRoster()
    return
  end
  rosterPage:Hide(); pageScroll:GetParent():Show()
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
  local y=-50
  local checks={}
  local function check(label,hint,get,set)
    local c=CreateFrame('CheckButton',nil,panel,'UICheckButtonTemplate')
    c:SetSize(26,26); c:SetPoint('TOPLEFT',16,y)
    local text=panel:CreateFontString(nil,'OVERLAY','GameFontHighlight'); text:SetPoint('LEFT',c,'RIGHT',4,1); text:SetText(label)
    local sub=panel:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); sub:SetPoint('TOPLEFT',text,'BOTTOMLEFT',0,-2); sub:SetText(hint)
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
  local function stepper(label,hint,get,change,format)
    local text=panel:CreateFontString(nil,'OVERLAY','GameFontHighlight'); text:SetPoint('TOPLEFT',22,y-4)
    local minus=smallButton(panel,'-',24,20); minus:SetPoint('TOPLEFT',250,y)
    local value=fontString(panel,'GameFontHighlight','CENTER'); value:SetPoint('LEFT',minus,'RIGHT',4,0); value:SetWidth(50)
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
  local reset=smallButton(panel,'Reset statistics',140,22); reset:SetPoint('TOPLEFT',22,y-6)
  reset:SetScript('OnClick',function() StaticPopup_Show('VILLAGECOMMAND_RESET') end)
  local version=fontString(panel,'GameFontDisableSmall','RIGHT'); version:SetPoint('BOTTOMRIGHT',-14,12); version:SetText('Village Command v'..VERSION)
  panel:SetScript('OnShow',function() for _,c in ipairs(checks) do c:SetChecked(c.get() and true or false) end end)
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
  f:SetSize(760,600); f:SetPoint('CENTER'); f:SetFrameStrata('DIALOG'); f:SetToplevel(true)
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag('LeftButton'); f:SetClampedToScreen(true)
  f:SetScript('OnDragStart',f.StartMoving); f:SetScript('OnDragStop',f.StopMovingOrSizing)
  f:SetScale(settings().scale or 1)
  if f.SetBackdrop then
    f:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
  end
  local tint=f:CreateTexture(nil,'BACKGROUND',nil,1)
  tint:SetPoint('TOPLEFT',11,-12); tint:SetPoint('BOTTOMRIGHT',-12,11); tint:SetColorTexture(.16,.11,.06,.55)
  tinsert(UISpecialFrames,'VillageCommandWindow')
  local banner=f:CreateTexture(nil,'ARTWORK')
  banner:SetTexture('Interface\\DialogFrame\\UI-DialogBox-Header'); banner:SetSize(340,64); banner:SetPoint('TOP',0,12)
  local title=f:CreateFontString(nil,'OVERLAY','GameFontNormal')
  title:SetPoint('TOP',banner,'TOP',0,-14); title:SetText('Village Command')
  local close=CreateFrame('Button',nil,f,'UIPanelCloseButton')
  close:SetPoint('TOPRIGHT',-6,-6)
  local refresh=smallButton(f,'Refresh',80,22); refresh:SetPoint('TOPLEFT',22,-36)
  refresh:SetScript('OnClick',function() VC.requestRoster(); requestRedraw() end)
  setTip(refresh,'Refresh','Asks the game for the latest guild roster.')
  local gear=CreateFrame('Button',nil,f)
  gear:SetSize(22,22); gear:SetPoint('LEFT',refresh,'RIGHT',8,0)
  gear:SetNormalTexture('Interface\\Icons\\INV_Misc_Gear_01')
  gear:SetHighlightTexture('Interface\\Buttons\\ButtonHilight-Square','ADD')
  setTip(gear,'Settings')
  local forge=smallButton(f,'GuildForge',96,22); forge:SetPoint('TOPRIGHT',-136,-36)
  forge:SetScript('OnClick',VC.openForge)
  setTip(forge,'GuildForge','Opens GuildForge: guild professions, recipes and craft requests.')
  local bank=smallButton(f,'Un-Nina Bank',104,22); bank:SetPoint('LEFT',forge,'RIGHT',4,0)
  bank:SetScript('OnClick',function() VC.openBank() end)
  setTip(bank,'Un-Nina Bank','Opens Un-Nina Bank: the guild bank, requests and donations.')
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
  f:SetScript('OnHide',function() VC.hideMenu(); if VC.noteDialog then VC.noteDialog:Hide() end end)
  f:Hide()
end
function VC.open(tab)
  if not window then VC.makeWindow() end
  if tab then VillageCommandDB.ui.tab=tab end
  window:Show()
  VC.requestRoster()
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
  text:SetText('Settings live in the Village Command window. Click the VC minimap button or type /vc.')
  local open=CreateFrame('Button',nil,panel,'UIPanelButtonTemplate')
  open:SetSize(200,24); open:SetPoint('TOPLEFT',text,'BOTTOMLEFT',0,-12); open:SetText('Open Village Command')
  open:SetScript('OnClick',function() VC.open(); window.settingsPanel:Show() end)
  Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel,'Village Command'))
end

-- Minimap button: a "VC" bubble with a green badge counting guildmates online. Same ring as LibDBIcon
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
  local bg=b:CreateTexture(nil,'BACKGROUND')
  bg:SetTexture('Interface\\Minimap\\UI-Minimap-Background'); bg:SetSize(24,24); bg:SetPoint('CENTER')
  bg:SetVertexColor(.12,.22,.1)
  local border=b:CreateTexture(nil,'OVERLAY')
  border:SetTexture('Interface\\Minimap\\MiniMap-TrackingBorder'); border:SetSize(50,50); border:SetPoint('TOPLEFT')
  local text=b:CreateFontString(nil,'ARTWORK')
  text:SetFont('Fonts\\FRIZQT__.TTF',10,'OUTLINE'); text:SetPoint('CENTER',bg,'CENTER',0,0)
  text:SetTextColor(1,.82,0); text:SetText('VC')
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
  local pages={roster='roster',overview='overview',progress='progress',progression='progress',stats='stats',fun='stats',
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
  elseif command=='status' then
    local p=VC.perms()
    log(string.format('v%s; guild=%s; members=%d; online=%d; roster complete=%s; your rank=%s',VERSION,tostring(VC.guildName()),#VC.roster,VC.onlineCount(),tostring(VC.rosterComplete()),tostring(VC.myRankIndex())),true)
    log(string.format('can promote=%s demote=%s public notes=%s officer notes=%s view officer notes=%s; GuildForge=%s; Un-Nina Bank=%s',
      tostring(p.promote),tostring(p.demote),tostring(p.publicNote),tostring(p.officerNote),tostring(p.viewOfficer),tostring(VC.hasForge()),tostring(VC.bankAPI()~=nil)),true)
  elseif command=='quiet' then
    VillageCommandDB.settings.quiet=not VillageCommandDB.settings.quiet
    log('Quiet mode '..(VillageCommandDB.settings.quiet and 'on' or 'off')..'.',true)
  else
    log('/vc opens the window. Pages: /vc roster, progress, stats, forge, bank. Also: online lists who\'s on; settings; minimap toggles the button; cancel stops a mass change; status shows what your rank can do; quiet toggles chat messages.',true)
  end
end

-- Events --------------------------------------------------------------------------------------------
for _,event in ipairs({'PLAYER_LOGIN','PLAYER_GUILD_UPDATE','GUILD_ROSTER_UPDATE','GUILD_RANKS_UPDATE','GUILD_MOTD','PLAYER_REGEN_ENABLED'}) do
  pcall(frame.RegisterEvent,frame,event)
end
frame:SetScript('OnEvent',function(_,event)
  if event=='PLAYER_LOGIN' then
    VC.initDB()
    VC.makeMinimapButton()
    VC.registerOptions()
    VC.requestRoster()
    VC.ready=true
    log('v'..VERSION..' loaded. Click the VC minimap button or type /vc to open.')
  elseif not VC.ready then return
  elseif event=='GUILD_ROSTER_UPDATE' or event=='PLAYER_GUILD_UPDATE' or event=='GUILD_RANKS_UPDATE' then
    rosterDirty=true
  else requestRedraw() end
end)
frame:SetScript('OnUpdate',function(_,elapsed)
  if not VC.ready then return end
  VC.tickJobs(elapsed)
  -- Roster updates come in bursts; read it at most every second and a half.
  sinceRead=sinceRead+elapsed
  if rosterDirty and sinceRead>=1.5 then
    rosterDirty=false; sinceRead=0
    VC.readRoster(); VC.track()
    if not VC.sampledOnce and #VC.roster>0 then VC.sampledOnce=true; VC.sample() end
    requestRedraw()
  end
  sinceUpdate=sinceUpdate+elapsed
  if updatePending and sinceUpdate>=.25 then VC.update() end
  -- The server answers roster requests at most every 10 seconds; ask more often while the window is open.
  sinceRoster=sinceRoster+elapsed
  if sinceRoster>=((window and window:IsShown()) and 20 or 90) then sinceRoster=0; VC.requestRoster() end
  sinceSample=sinceSample+elapsed
  if sinceSample>=300 then sinceSample=0; VC.sample() end
end)
