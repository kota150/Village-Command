-- Village Command - Village Points: raid points and loot priority. The page and dialogs are in PointsUI.lua.
--
-- Guildmates earn Village Points for raiding (on time, each boss kill, optionally time in the raid) and are
-- charged Loot Points when an officer awards them an item. Priority is Village Points divided by Loot
-- Points (plus a base, so newcomers don't jump the queue), and both fade by the same share every week.
-- Decay is worked out from the dates, never stored, so every copy of the ledger gives the same standings.
--
-- In a raid nothing is sent: addons can't talk there, and Village Command keeps still in instances anyway.
-- Each client keeps a report of what it saw: when it entered, who from the guild was in the raid (online,
-- in the same zone) and for how long, and every boss kill with who was there. Once out it sends that report
-- to the guild. An officer's client collects the reports and settles the raid:
--   yes/no facts (was this boss killed? was Mira there for it?) go by majority vote, an officer breaking ties;
--   numbers (when someone arrived, how long they stayed) use the median, which ignores outliers;
--   a raid needs reports from at least 3 clients (Rules) or one officer, or it waits for an officer to approve;
--   one officer settles (the first by name among those who reported; others step in if it doesn't happen).
-- Reports that disagree with the result are flagged for officers. Loot is never voted on: only officers
-- record loot, and only officers' changes are taken on their word. A client that hasn't had its report
-- settled sends it again when an officer says hello, so officers who were still inside catch up.
--
-- Messages can't be signed, but the server tells us who sent each one, so a report counts as the sender's
-- own vote, and ledger entries are only taken straight from an officer (or from two guildmates who agree).
local _,VC=...
if type(VC)~='table' then VC=VC_NS or {} end
local now,later,DAY=VC.now,VC.later,VC.DAY
local function settings() return VC.settings() end
local function log(s,always) VC.log(s,always) end
local T,F=VC.to36,VC.from36
local HOUR,WEEK=3600,7*86400
local POINTS_VERSION='1'
-- Weeks start Tuesday 15:00 UTC (the US weekly reset). The Discord companion uses the same numbers.
local EPOCH=486000
-- Points older than this many weeks have faded to almost nothing and drop off (and stop being shared).
local WINDOW=26
VC.VP_WINDOW,VC.VP_EPOCH=WINDOW,EPOCH
-- An officer waits this long after the first report before settling, and for this long without a new one.
local COLLECT,QUIET=300,90
-- Late reports within this long after settling are still counted (the raid is settled again).
local LATE=1800
-- Own reports are kept, and sent again to officers, for this long.
local KEEP_REPORTS=7*DAY

VC.VP_RULES={
  {key='onTime',label='On time',default=10,min=0,max=500,hint='Village Points for being in the raid by the start (plus the grace minutes).'},
  {key='perBoss',label='Each boss kill',default=15,min=0,max=500,hint='Village Points for each boss killed while you were there.'},
  {key='perHour',label='Each hour',default=0,min=0,max=500,hint='Village Points for each hour in the raid (0: off).'},
  {key='bench',label='Bench share %',default=50,min=0,max=100,hint='Players on standby get this share of what the raid earned.'},
  {key='decay',label='Decay % a week',default=10,min=0,max=50,hint='Both Village and Loot Points fade by this share every week.'},
  {key='base',label='Base Loot Points',default=50,min=1,max=1000,hint='Everyone starts with this many Loot Points, so a newcomer with one raid isn\'t first in line.'},
  {key='quorum',label='Reports needed',default=3,min=1,max=10,hint='Reports from this many clients settle a raid on their own; fewer need an officer\'s.'},
  {key='grace',label='Grace minutes',default=15,min=0,max=120,hint='How late after the raid started still counts as on time.'},
  {key='scale',label='Loot cost %',default=100,min=1,max=1000,hint='Suggested loot cost: item level times the slot weight times this.'},
  {key='minGuild',label='Guildmates needed',default=5,min=2,max=40,hint='A raid counts once this many guildmates are in it together. Only raid instances ever count: never dungeons, even in a raid group.'},
}
VC.VP_RULE={}
for _,r in ipairs(VC.VP_RULES) do VC.VP_RULE[r.key]=r end

VC.vpSync={sent=0,received=0,merged=0,rejected=0,lastDump=0,lastBegin=0,dumpsTo={},pending={},resentAt={},uAt={}}

-- Saved data --------------------------------------------------------------------------------------
-- g.vp.rules: {u, by, [key]=number}
-- g.vp.led[id]: {id,u,t,by,k('v' Village Points, 'l' Loot Points),amt,who(member id),n(name),x(undone),why}
-- g.vp.raids[key]: {key,u,t(start),e(end),by,inst,iname,bosses,att(attendees),rep(reports),fl={flags},rids={}}
-- g.vp.mine[rid]: this client's own raid reports. g.vp.inbox[from:rid]: reports received (officers only).
function VC.vpData()
  local g=VC.guildData()
  if not g then return nil end
  g.vp=g.vp or {}
  local p=g.vp
  p.rules=p.rules or {u=0}
  p.led=p.led or {}; p.raids=p.raids or {}; p.mine=p.mine or {}; p.inbox=p.inbox or {}
  return p
end
function VC.vpRule(key)
  local p=VC.vpData()
  local v=p and tonumber(p.rules[key])
  if v==nil then v=VC.VP_RULE[key].default end
  return v
end
function VC.vpWeek(t) return math.floor(((t or now())-EPOCH)/WEEK) end
-- How much of an entry from time t is left today.
function VC.vpFactor(t,at)
  local w=VC.vpWeek(at or now())-VC.vpWeek(t)
  if w<0 then w=0 end
  if w>=WINDOW then return 0 end
  return (1-VC.vpRule('decay')/100)^w
end
local function hash(text,h)
  h=h or 5381
  for i=1,#text do h=(h*33+text:byte(i))%4294967296 end
  return h
end
local function myName() return VC.boardMyName and VC.boardMyName() or ((UnitName and (UnitName('player'))) or '?') end
local function newId() return T(now())..T(math.random(36*36,36*36*36-1)) end
local function cleanText(text,max) return VC.boardCleanText(text,max) end
local function memberName(id) local m=VC.byId[id or ''] return m and m.short end
local function median(list)
  local n=#list
  if n==0 then return nil end
  local s={}
  for i,v in ipairs(list) do s[i]=v end
  table.sort(s)
  if n%2==1 then return s[(n+1)/2] end
  return (s[n/2]+s[n/2+1])/2
end
VC.vpMedian=median
function VC.vpOfficer(id) return VC.trusted(id or VC.myId()) end

-- Standings ---------------------------------------------------------------------------------------
-- Everyone with points in the window: {id,name,vp,lp,pr,raids,last}, highest priority first.
function VC.vpStandings(at)
  local p=VC.vpData()
  local out={}
  if not p then return out end
  at=at or now()
  local by={}
  local base=VC.vpRule('base')
  for _,e in pairs(p.led) do
    if not e.x then
      local f=VC.vpFactor(e.t,at)
      if f>0 then
        local s=by[e.who]
        if not s then s={id=e.who,name=memberName(e.who) or e.n,vp=0,lp=base,raids={},last=0}; by[e.who]=s end
        if e.k=='l' then s.lp=s.lp+e.amt*f else s.vp=s.vp+e.amt*f end
        local raid=e.id:match('^(.-)%.')
        if raid and p.raids[raid] and e.t>=at-30*DAY then s.raids[raid]=true end
        if e.t>s.last then s.last=e.t end
      end
    end
  end
  for _,s in pairs(by) do
    local n=0
    for _ in pairs(s.raids) do n=n+1 end
    s.raids=n
    if s.lp<1 then s.lp=1 end
    s.pr=math.max(0,s.vp)/s.lp
    out[#out+1]=s
  end
  table.sort(out,function(a,c) if a.pr~=c.pr then return a.pr>c.pr end if a.vp~=c.vp then return a.vp>c.vp end return a.name<c.name end)
  return out
end
function VC.vpStanding(id)
  local list=VC.vpStandings()
  for i,s in ipairs(list) do if s.id==id then return s,i,#list end end
  return nil,nil,#list
end
-- A member's entries, newest first.
function VC.vpHistory(id,limit)
  local p=VC.vpData()
  local out={}
  if not p then return out end
  for _,e in pairs(p.led) do if e.who==id and (not limit or VC.vpFactor(e.t)>0) then out[#out+1]=e end end
  table.sort(out,function(a,c) if a.t~=c.t then return a.t>c.t end return a.id>c.id end)
  return out
end
function VC.vpRecentRaids(days)
  local p=VC.vpData()
  local out={}
  if not p then return out end
  local cutoff=now()-(days or 30)*DAY
  for _,r in pairs(p.raids) do if r.t>=cutoff then out[#out+1]=r end end
  table.sort(out,function(a,c) return a.t>c.t end)
  return out
end
function VC.vpRecentLoot(limit)
  local p=VC.vpData()
  local out={}
  if not p then return out end
  for _,e in pairs(p.led) do if e.k=='l' and not e.x and VC.vpFactor(e.t)>0 then out[#out+1]=e end end
  table.sort(out,function(a,c) return a.t>c.t end)
  while limit and #out>limit do table.remove(out) end
  return out
end
function VC.fmtPoints(v) return tostring(math.floor((v or 0)+.5)) end
function VC.fmtPriority(v) return string.format('%.2f',v or 0) end

-- Renown: the community score (events attended, bounties earned, levels gained), never used for loot.
function VC.renown()
  local g=VC.guildData()
  local out={}
  if not g then return out end
  local by={}
  local function add(id,field,n)
    if not (id and VC.byId[id]) then return end
    local s=by[id] or {id=id,name=VC.byId[id].short,events=0,bounties=0,levels=0,score=0}
    s[field]=s[field]+n
    by[id]=s
  end
  if VC.attendanceStats then for _,e in ipairs((VC.attendanceStats(60))) do add(e.id,'events',e.n) end end
  if VC.bountyHunters then for _,h in ipairs(VC.bountyHunters(90)) do add(VC.nameId(h.name),'bounties',h.n) end end
  local cutoff=now()-30*DAY
  for id,rec in pairs(g.members or {}) do
    local before,top=nil,0
    for _,e in ipairs(rec.levels or {}) do
      if e[1]<cutoff then before=e[2] elseif e[2]>top then top=e[2] end
    end
    if before and top>before then add(id,'levels',top-before) end
  end
  for _,s in pairs(by) do
    s.score=s.events*3+s.bounties*5+s.levels
    if s.score>0 then out[#out+1]=s end
  end
  table.sort(out,function(a,c) if a.score~=c.score then return a.score>c.score end return a.name<c.name end)
  return out
end

-- Loot cost ---------------------------------------------------------------------------------------
VC.VP_SLOTS={INVTYPE_HEAD=1,INVTYPE_CHEST=1,INVTYPE_ROBE=1,INVTYPE_LEGS=1,INVTYPE_2HWEAPON=1,
  INVTYPE_SHOULDER=.75,INVTYPE_HAND=.75,INVTYPE_WAIST=.75,INVTYPE_FEET=.75,INVTYPE_TRINKET=.75,
  INVTYPE_WEAPON=.75,INVTYPE_WEAPONMAINHAND=.75,INVTYPE_WEAPONOFFHAND=.5,INVTYPE_HOLDABLE=.5,INVTYPE_SHIELD=.5,
  INVTYPE_WRIST=.5,INVTYPE_NECK=.5,INVTYPE_CLOAK=.5,INVTYPE_FINGER=.5,INVTYPE_RANGED=.5,INVTYPE_RANGEDRIGHT=.5,
  INVTYPE_THROWN=.3,INVTYPE_RELIC=.3}
local getItemInfo=(C_Item and C_Item.GetItemInfo) or GetItemInfo
-- Suggested Loot Points for an item (link or id): item level x slot weight x Rules' loot cost %.
function VC.vpCost(item)
  local id=type(item)=='number' and item or VC.itemIdFrom(item)
  if not (id and getItemInfo) then return nil end
  local ok,name,link,quality,ilvl,_,_,_,_,slot=pcall(getItemInfo,id)
  if not ok or type(ilvl)~='number' or VC.isSecret(ilvl) then return nil end
  local weight=VC.VP_SLOTS[slot] or .5
  return math.max(1,math.floor(ilvl*weight*VC.vpRule('scale')/100+.5)),name,link
end

-- Officers' changes -------------------------------------------------------------------------------
local function send(line) if VC.syncOn() then VC.syncQueue(line) end end
function VC.vpEncodeEntry(e)
  return 'P|L|'..e.id..'~'..T(e.u)..'~'..T(e.t)..'~'..(e.by or '')..'~'..e.k..'~'..math.floor(e.amt)..'~'..(e.n or '')..'~'..(e.x and '1' or '')..'~'..(e.why or '')
end
function VC.vpSendEntry(e) send(VC.vpEncodeEntry(e)) end
-- Adds or changes one ledger entry. Officers only; returns the entry or nil and why.
local function putEntry(spec)
  local p=VC.vpData()
  local me=VC.myId()
  if not (p and me) then return nil,'Not in a guild.' end
  if not VC.vpOfficer(me) then return nil,'Only officers (Settings > Trust shared history from) can change Village Points.' end
  local who=spec.who
  if not (who and VC.byId[who]) then return nil,'Nobody called '..tostring(spec.name or '?')..' in the guild.' end
  local amt=math.floor(tonumber(spec.amt) or 0)
  if amt==0 and not spec.x then return nil,'Give an amount.' end
  if math.abs(amt)>100000 then return nil,'That\'s more points than makes sense.' end
  local id=spec.id or newId()
  local old=p.led[id]
  local e={id=id,u=math.max(now(),old and old.u+1 or 0),t=spec.t or (old and old.t) or now(),by=myName(),k=spec.k,amt=amt,who=who,n=VC.byId[who].short,
    x=spec.x or nil,why=cleanText(spec.why or '',60)}
  if old and not e.x and not old.x and old.amt==e.amt and old.k==e.k and old.why==e.why then return old end
  p.led[id]=e
  VC.vpSendEntry(e)
  VC.requestRedraw()
  return e
end
VC.vpPutEntry=putEntry
-- Loot: charge `cost` Loot Points (the suggested cost when nil) for an item.
function VC.vpAward(name,item,cost)
  local who=VC.nameId(name or '')
  local itemName,link
  if item and item~='' then
    local suggested
    suggested,itemName,link=VC.vpCost(item)
    cost=cost or suggested
    itemName=itemName or cleanText(item,50)
  end
  if not cost then return nil,'Say how many Loot Points (no item level to suggest one from).' end
  return putEntry({who=who,name=name,k='l',amt=cost,why=itemName or 'Loot'})
end
-- Village Points by hand, plus or minus.
function VC.vpAdjust(name,amt,why)
  return putEntry({who=VC.nameId(name or ''),name=name,k='v',amt=amt,why=(why and why~='') and why or 'Adjusted by hand'})
end
-- Standby for the latest raid (or `key`): the Rules' bench share of what the raid earned.
function VC.vpBench(name,key)
  local raid=key and VC.vpData().raids[key] or VC.vpRecentRaids(14)[1]
  if not raid then return nil,'No raid from the last two weeks to bench for.' end
  local who=VC.nameId(name or '')
  local full=VC.vpRule('onTime')+VC.vpRule('perBoss')*(raid.bosses and #raid.bosses or 0)
  local amt=math.floor(full*VC.vpRule('bench')/100+.5)
  if amt<=0 then return nil,'The bench share is 0 (Rules).' end
  return putEntry({id=raid.key..'.'..T(hash(who or ''))..'.b',t=raid.t,who=who,name=name,k='v',amt=amt,why='Bench: '..(raid.iname or 'raid')})
end
-- Undo: the newest entry you made that isn't undone yet (or `id`).
function VC.vpUndo(id)
  local p=VC.vpData()
  if not p then return nil end
  local e=id and p.led[id]
  if not e then
    local me=myName()
    for _,x in pairs(p.led) do if x.by==me and not x.x and (not e or x.u>e.u) then e=x end end
  end
  if not e then return nil,'Nothing of yours to undo.' end
  return putEntry({id=e.id,t=e.t,who=e.who,name=e.n,k=e.k,amt=e.amt,why=e.why,x=true})
end
function VC.vpSetRule(key,value)
  local p=VC.vpData()
  local r=VC.VP_RULE[key]
  if not (p and r) then return nil,'No rule called '..tostring(key)..'.' end
  if not VC.vpOfficer() then return nil,'Only officers can change the rules.' end
  value=tonumber(value)
  if not value then return nil,'Give a number.' end
  value=math.max(r.min,math.min(r.max,math.floor(value+.5)))
  p.rules[key]=value
  p.rules.u=math.max(now(),(p.rules.u or 0)+1); p.rules.by=myName()
  VC.vpSendRules()
  VC.requestRedraw()
  return value
end
function VC.vpSendRules()
  local p=VC.vpData()
  if not p or (p.rules.u or 0)==0 then return end
  local parts={}
  for _,r in ipairs(VC.VP_RULES) do parts[#parts+1]=tostring(VC.vpRule(r.key)) end
  send('P|O|'..T(p.rules.u)..'~'..(p.rules.by or '')..'~'..table.concat(parts,','))
end

-- In the raid: keeping a report --------------------------------------------------------------------
local function instance()
  local inInstance,kind=false,nil
  if IsInInstance then inInstance,kind=IsInInstance() end
  if not inInstance or VC.isSecret(inInstance) then return nil end
  if kind~=nil and (VC.isSecret(kind) or kind~='raid') then return nil end
  local name,_,_,_,_,_,_,id
  if GetInstanceInfo then name,_,_,_,_,_,_,id=GetInstanceInfo() end
  name=VC.clean(name)
  id=(not VC.isSecret(id) and tonumber(id)) or hash(name)%100000
  return id,name
end
VC.vpInstance=instance
-- Guildmates in the raid who are online and in your zone (from the raid roster where the game has it).
function VC.vpPresent()
  local out={}
  if not (IsInRaid and IsInRaid()) then return out end
  local n=(GetNumGroupMembers and tonumber((GetNumGroupMembers()))) or 0
  local myZone=GetRealZoneText and VC.clean(GetRealZoneText()) or ''
  local seen={}
  for i=1,n do
    local id=VC.unitId('raid'..i)
    if id and VC.byId[id] and not seen[id] then
      local ok=true
      if GetRaidRosterInfo then
        local _,_,_,_,_,_,zone,online=GetRaidRosterInfo(i)
        if online==false then ok=false end
        zone=VC.clean(zone)
        if ok and zone~='' and myZone~='' and zone~=myZone then ok=false end
      end
      if ok and UnitIsConnected then
        local c=UnitIsConnected('raid'..i)
        if c==false then ok=false end
      end
      if ok then seen[id]=true; out[#out+1]=id end
    end
  end
  return out
end
local function current()
  local p=VC.vpData()
  return p and p.mine[p.cur or '']
end
-- Start a report, or carry on the one from this raid if you were out for less than half an hour.
local function startReport(inst,iname,t)
  local p=VC.vpData()
  local cur=current()
  if cur then return cur end
  for _,r in pairs(p.mine) do
    if r.inst==inst and (r.last or 0)>=t-LATE and not r.settled then
      p.cur=r.rid; r.left=nil; r.done=nil; r.v=(r.v or 1)+1
      return r
    end
  end
  local r={rid=newId(),inst=inst,iname=iname,start=t,last=t,kills={},seen={},v=1}
  p.mine[r.rid]=r; p.cur=r.rid
  log('Keeping a raid report for |cffffd100'..(iname~='' and iname or 'this raid')..'|r. It\'s shared with officers once you\'re out.')
  return r
end
local sinceLocal=0
-- Every 20 seconds out of combat, even inside: only reads the raid. Nothing is sent from here.
function VC.pointsLocalTick(elapsed)
  sinceLocal=sinceLocal+elapsed
  if sinceLocal<20 then return end
  sinceLocal=0
  -- In combat it waits; the time is counted at the next sample (boss kills are noted as they happen).
  if InCombatLockdown and InCombatLockdown() then return end
  local p=VC.vpData()
  if not (p and VC.myId()) then return end
  local t=now()
  local inst,iname=instance()
  local present=inst and VC.vpPresent() or {}
  local cur=current()
  if inst and #present>=VC.vpRule('minGuild') then
    if not cur then cur=startReport(inst,iname,t) end
    if cur.inst==inst then
      cur.left=nil
      -- Up to 10 minutes between samples (a long fight); longer means they weren't really here.
      local gap=math.min(t-(cur.sample or t),600)
      for _,id in ipairs(present) do
        local s=cur.seen[id]
        if not s then s={f=t,l=t,m=0}; cur.seen[id]=s end
        -- Time counts between two samples that both found them here.
        if s.ps==cur.sample then s.m=s.m+gap end
        s.ps=t; s.l=t
      end
      cur.sample=t; cur.last=t
      return
    end
  end
  -- Out of the raid (or it broke up): the report is finished two minutes later, unless you go back in.
  if cur then
    cur.left=cur.left or t
    if t-cur.left>=120 then
      cur.done=true; cur.e=cur.last; p.cur=nil; cur.sentAt=nil
      VC.vpOwnReportToInbox(cur)
    end
  end
end
-- A boss died (ENCOUNTER_END with success, or BOSS_KILL).
function VC.vpBossKill(encounter,name)
  local p=VC.vpData()
  if not p then return end
  local t=now()
  local inst,iname=instance()
  if not inst then return end
  local present=VC.vpPresent()
  local cur=current()
  if not cur then
    if #present<VC.vpRule('minGuild') then return end
    cur=startReport(inst,iname,t)
  end
  encounter=(not VC.isSecret(encounter) and tonumber(encounter)) or 0
  name=cleanText(VC.clean(name),30)
  for _,k in ipairs(cur.kills) do
    if (encounter>0 and k.e==encounter) or (encounter==0 and k.n==name) then return end
  end
  cur.kills[#cur.kills+1]={e=encounter,n=name,t=t,w=present}
  for _,id in ipairs(present) do
    local s=cur.seen[id]
    if not s then cur.seen[id]={f=t,l=t,m=0} else s.l=math.max(s.l,t) end
  end
  log('Noted the kill: |cffffd100'..(name~='' and name or 'boss')..'|r with '..#present..' guildmates.')
end

-- Sending and receiving reports --------------------------------------------------------------------
-- R|rid~inst~start~end~version~instance name     K|rid~index~encounter~time~boss
-- A|rid~index;name;name...  (who was there for kill `index`)     T|rid;name:first:last:minutes;...
-- E|rid~kills~people        (the end: the counts say whether every piece arrived)
local function packed(head,pieces)
  local line=''
  for _,piece in ipairs(pieces) do
    if #line>0 and #head+#line+#piece+1>236 then send(head..line); line='' end
    line=line..';'..piece
  end
  if #line>0 then send(head..line) end
end
function VC.vpSendReport(r)
  send('P|R|'..r.rid..'~'..T(r.inst)..'~'..T(r.start)..'~'..T(r.e or r.last)..'~'..(r.v or 1)..'~'..(r.iname or ''))
  for i,k in ipairs(r.kills) do
    send('P|K|'..r.rid..'~'..i..'~'..(k.e or 0)..'~'..T(k.t)..'~'..(k.n or ''))
    local names={}
    for _,id in ipairs(k.w or {}) do names[#names+1]=memberName(id) or id end
    packed('P|A|'..r.rid..'~'..i,names)
  end
  local pieces,people={},0
  for id,s in pairs(r.seen) do
    local n=memberName(id)
    if n then people=people+1; pieces[#pieces+1]=n..':'..T(s.f)..':'..T(s.l)..':'..math.floor(s.m/60+.5) end
  end
  table.sort(pieces)
  packed('P|T|'..r.rid,pieces)
  send('P|E|'..r.rid..'~'..#r.kills..'~'..people)
  r.sentAt=now()
  VC.vpSync.sent=VC.vpSync.sent+1
end
-- The officer's own report goes straight into their own inbox.
function VC.vpOwnReportToInbox(r)
  if not VC.vpOfficer() then return end
  local p=VC.vpData()
  local me=VC.myId()
  local times={}
  for id,s in pairs(r.seen) do times[id]={f=s.f,l=s.l,m=math.floor(s.m/60+.5)} end
  local kills={}
  for i,k in ipairs(r.kills) do kills[i]={e=k.e,n=k.n,t=k.t,w=k.w} end
  local key=me..':'..r.rid
  local old=p.inbox[key]
  p.inbox[key]={rid=r.rid,from=me,fromName=myName(),inst=r.inst,iname=r.iname,start=r.start,e=r.e or r.last,v=r.v,kills=kills,times=times,done=true,
    at=now(),first=old and old.first or now()}
end
local building={}
local function inboxKey(from,rid) return from..':'..rid end
local function mergeReport(kind,rest,senderId)
  if not VC.vpOfficer() then return false end
  local p=VC.vpData()
  if kind=='R' then
    local rid,inst,start,e,v,iname=rest:match('^(%w+)~(%w+)~(%w+)~(%w+)~(%d+)~(.*)$')
    if not rid then return false end
    start,e=F(start),F(e)
    if not (start and e and start>now()-KEEP_REPORTS and e>=start and e<=now()+600 and e-start<12*HOUR) then return false end
    building[inboxKey(senderId,rid)]={rid=rid,from=senderId,fromName=memberName(senderId),inst=F(inst),iname=cleanText(iname,40),start=start,e=e,v=tonumber(v),kills={},times={}}
    return true
  end
  local rid=rest:match('^(%w+)')
  local r=rid and building[inboxKey(senderId,rid)]
  if not r then return false end
  if kind=='K' then
    local i,enc,t,name=rest:match('^%w+~(%d+)~(%d+)~(%w+)~(.*)$')
    i,t=tonumber(i),F(t)
    if not (i and i>=1 and i<=40 and t) then return false end
    r.kills[i]={e=tonumber(enc) or 0,n=cleanText(name,30),t=t,w={}}
  elseif kind=='A' then
    local i,list=rest:match('^%w+~(%d+)(.*)$')
    local k=i and r.kills[tonumber(i)]
    if not k then return false end
    for name in (list or ''):gmatch('[^;]+') do
      local id=VC.nameId(name)
      if id and VC.byId[id] then k.w[#k.w+1]=id end
    end
  elseif kind=='T' then
    for piece in (rest:match('^%w+(.*)$') or ''):gmatch('[^;]+') do
      local name,f,l,m=piece:match('^([^:]+):(%w+):(%w+):(%d+)$')
      local id=name and VC.nameId(name)
      f,l=F(f),F(l)
      if id and VC.byId[id] and f and l then r.times[id]={f=f,l=l,m=math.min(12*60,tonumber(m) or 0)} end
    end
  elseif kind=='E' then
    local nk,np=rest:match('^%w+~(%d+)~(%d+)$')
    local people=0
    for _ in pairs(r.times) do people=people+1 end
    building[inboxKey(senderId,rid)]=nil
    if tonumber(nk)~=#r.kills or tonumber(np)~=people then VC.vpSync.rejected=VC.vpSync.rejected+1; return false end
    for i=1,#r.kills do if not r.kills[i] then return false end end
    local key=inboxKey(senderId,rid)
    local old=p.inbox[key]
    r.done=true; r.at=now(); r.first=old and old.first or now()
    p.inbox[key]=r
    return true
  end
  return true
end

-- Settling ------------------------------------------------------------------------------------------
-- Reports from the same instance whose times overlap are the same raid.
function VC.vpGroups()
  local p=VC.vpData()
  local list={}
  for key,r in pairs(p.inbox) do if r.done and not r.used then r.key=key; list[#list+1]=r end end
  table.sort(list,function(a,c) if a.inst~=c.inst then return a.inst<c.inst end return a.start<c.start end)
  local groups={}
  local g
  for _,r in ipairs(list) do
    if g and g.inst==r.inst and r.start<=g.e+15*60 then
      g.reports[#g.reports+1]=r; g.e=math.max(g.e,r.e)
      g.first=math.min(g.first,r.first or r.at); g.last=math.max(g.last,r.at)
    else
      g={inst=r.inst,iname=r.iname,start=r.start,e=r.e,reports={r},first=r.first or r.at,last=r.at}
      groups[#groups+1]=g
    end
  end
  return groups
end
local function raidFor(group)
  local p=VC.vpData()
  for _,raid in pairs(p.raids) do
    if raid.inst==group.inst and group.start<=(raid.e or raid.t)+15*60 and group.e>=raid.t-15*60 then return raid end
  end
end
-- Works out the raid from its reports. Returns the result: {start,e,bosses,earn={[id]=points},people,flags}.
function VC.vpTally(reports)
  local n=#reports
  local kills,order={},{}
  for ri,r in ipairs(reports) do
    local mine={}
    for _,k in ipairs(r.kills) do
      local key=(k.e and k.e>0) and ('e'..k.e) or ('n'..(k.n or ''))
      if not mine[key] then
        mine[key]=true
        local x=kills[key]
        if not x then x={key=key,n=k.n,ts={},seen={},trustedSeen=false,count={},trustedHas={}}; kills[key]=x; order[#order+1]=key end
        if (x.n or '')=='' then x.n=k.n end
        x.ts[#x.ts+1]=k.t; x.seen[#x.seen+1]=ri
        if VC.trusted(r.from) then x.trustedSeen=true end
        for _,id in ipairs(k.w or {}) do
          x.count[id]=(x.count[id] or 0)+1
          if VC.trusted(r.from) then x.trustedHas[id]=true end
        end
      end
    end
  end
  local function majority(yes,of,tieBreak) return yes*2>of or (yes*2==of and yes>0 and tieBreak) end
  local real={}
  for _,key in ipairs(order) do
    local x=kills[key]
    if majority(#x.seen,n,x.trustedSeen) then x.t=median(x.ts); real[#real+1]=x end
  end
  table.sort(real,function(a,c) return a.t<c.t end)
  local starts,ends={},{}
  for _,r in ipairs(reports) do starts[#starts+1]=r.start; ends[#ends+1]=r.e end
  local start,e=median(starts),median(ends)
  local ids={}
  for _,r in ipairs(reports) do for id in pairs(r.times) do ids[id]=true end end
  for _,x in ipairs(real) do for id in pairs(x.count) do ids[id]=true end end
  local earn,detail,people={}, {},0
  local onTime,perBoss,perHour,grace=VC.vpRule('onTime'),VC.vpRule('perBoss'),VC.vpRule('perHour'),VC.vpRule('grace')*60
  for id in pairs(ids) do
    if VC.byId[id] then
      local firsts,mins,listed,trustedListed={}, {},0,false
      for _,r in ipairs(reports) do
        local s=r.times[id]
        if s then listed=listed+1; firsts[#firsts+1]=s.f; if VC.trusted(r.from) then trustedListed=true end end
        mins[#mins+1]=s and s.m or 0
      end
      local there=majority(listed,n,trustedListed)
      local first=median(firsts)
      local minutes=median(mins) or 0
      local bosses=0
      for _,x in ipairs(real) do if majority(x.count[id] or 0,#x.seen,x.trustedHas[id]) then bosses=bosses+1 end end
      local ontime=there and first and first<=start+grace
      local amt=(ontime and onTime or 0)+perBoss*bosses+math.floor(perHour*minutes/60)
      if amt>0 then
        earn[id]=amt; people=people+1
        detail[id]={bosses=bosses,onTime=ontime and true or false,minutes=minutes}
      end
    end
  end
  -- Reports that disagree with the result, for officers to look at.
  local flags={}
  local realKey={}
  for _,x in ipairs(real) do realKey[x.key]=x end
  for _,r in ipairs(reports) do
    local who=r.fromName or memberName(r.from) or r.from
    local extra=0
    for _,k in ipairs(r.kills) do
      local key=(k.e and k.e>0) and ('e'..k.e) or ('n'..(k.n or ''))
      if not realKey[key] then extra=extra+1 end
    end
    if extra>0 then flags[#flags+1]=who..'\'s client reported '..extra..' kill'..(extra==1 and '' or 's')..' the others didn\'t see' end
    local off=0
    for id,s in pairs(r.times) do
      local d=detail[id]
      if (d and math.abs(s.m-d.minutes)>30) or (not d and s.m>30) then off=off+1 end
    end
    if off>0 and n>1 then flags[#flags+1]=who..'\'s client had different times for '..off..' '..(off==1 and 'person' or 'people') end
    if #flags>=6 then break end
  end
  local bosses={}
  for _,x in ipairs(real) do bosses[#bosses+1]=(x.n and x.n~='') and x.n or 'Boss' end
  return {start=start,e=e,bosses=bosses,earn=earn,detail=detail,people=people,flags=flags}
end
function VC.vpEncodeRaid(r)
  local head='P|W|'..r.key..'~'..T(r.u)..'~'..T(r.t)..'~'..T(r.e or r.t)..'~'..(r.by or '')..'~'..T(r.inst)..'~'..(r.rep or 0)..'~'..(r.att or 0)..'~'..(r.iname or '')..'~'
  local names=''
  for _,b in ipairs(r.bosses or {}) do
    local piece=(#names>0 and ',' or '')..b:gsub(',',' ')
    if #head+#names+#piece>240 then break end
    names=names..piece
  end
  return head..names
end
function VC.vpSendRaid(r)
  send(VC.vpEncodeRaid(r))
  for _,f in ipairs(r.fl or {}) do send('P|F|'..r.key..'~'..f:sub(1,200)) end
end
local function sendSettled(raid)
  local pieces={}
  for k in pairs(raid.rids or {}) do pieces[#pieces+1]=k end
  table.sort(pieces)
  packed('P|U|'..raid.key,pieces)
  VC.vpSync.uAt[raid.key]=now()
end
-- Settles a raid from a group of reports (again, if it was settled before and more reports came in).
function VC.vpSettle(group,force)
  local p=VC.vpData()
  local me=VC.myId()
  if not (p and VC.vpOfficer(me)) then return nil end
  local result=VC.vpTally(group.reports)
  local raid=raidFor(group)
  local t=now()
  if not raid then
    raid={key=T(group.inst)..T(math.floor(result.start/60)),inst=group.inst,rids={}}
    p.raids[raid.key]=raid
  end
  raid.u=math.max(t,(raid.u or 0)+1); raid.t=math.floor(result.start); raid.e=math.floor(result.e)
  raid.by=myName(); raid.iname=group.iname; raid.bosses=result.bosses; raid.att=result.people; raid.fl=result.flags
  raid.settledAt=raid.settledAt or t; raid.forced=force or raid.forced
  for _,r in ipairs(group.reports) do
    r.used=true
    raid.rids[(r.fromName or memberName(r.from) or r.from)..':'..r.rid]=true
  end
  local n=0
  for _ in pairs(raid.rids) do n=n+1 end
  raid.rep=n
  local why=(raid.iname~='' and raid.iname or 'Raid')..': '..#result.bosses..' boss'..(#result.bosses==1 and '' or 'es')
  local made={}
  for id,amt in pairs(result.earn) do
    local d=result.detail[id]
    local eid=raid.key..'.'..T(hash(id))
    made[eid]=true
    putEntry({id=eid,t=raid.t,who=id,k='v',amt=amt,why=why..(d.onTime and ', on time' or '')})
  end
  -- Anyone a re-count no longer credits loses that raid's points.
  for eid,e in pairs(p.led) do
    if eid:sub(1,#raid.key+1)==raid.key..'.' and not eid:find('%.b$') and not made[eid] and not e.x then
      putEntry({id=eid,t=e.t,who=e.who,k=e.k,amt=e.amt,why=e.why,x=true})
    end
  end
  VC.vpSendRaid(raid)
  sendSettled(raid)
  local mine=p.mine
  for k in pairs(raid.rids) do
    local name,rid=k:match('^(.-):(%w+)$')
    if VC.nameId(name)==me and mine[rid] then mine[rid].settled=true end
  end
  log('Settled |cffffd100'..(raid.iname~='' and raid.iname or 'the raid')..'|r from '..raid.rep..' report'..(raid.rep==1 and '' or 's')..': '..#result.bosses..' bosses, '..result.people..' guildmates earned Village Points.'..(#result.flags>0 and (' |cffff9030'..#result.flags..' flagged for officers (Village Points tab).|r') or ''),true)
  VC.requestRedraw()
  return raid,result
end
-- Raids waiting: not enough reports and no officer's (officers can approve them on the Village Points tab).
function VC.vpPending()
  local out={}
  if not VC.vpOfficer() then return out end
  for _,g in ipairs(VC.vpGroups()) do
    if not raidFor(g) and not VC.vpQuorum(g) then out[#out+1]=g end
  end
  return out
end
function VC.vpQuorum(group)
  if #group.reports>=VC.vpRule('quorum') then return true end
  for _,r in ipairs(group.reports) do if VC.trusted(r.from) then return true end end
  return false
end
function VC.vpApprove(group) return VC.vpSettle(group,true) end
-- Whose turn it is to settle: the first officer by name among those who reported.
local function settler(group)
  local best
  for _,r in ipairs(group.reports) do if VC.trusted(r.from) and (not best or r.from<best) then best=r.from end end
  return best
end
function VC.vpSettleDue(t)
  local p=VC.vpData()
  local me=VC.myId()
  if not (p and me and VC.vpOfficer(me)) then return end
  for _,g in ipairs(VC.vpGroups()) do
    local raid=raidFor(g)
    if raid then
      if raid.by==myName() and t-(raid.settledAt or 0)<LATE then
        if t-g.last>=QUIET then
          -- Late reports: count them in with the ones already used.
          local all={}
          for _,r in pairs(p.inbox) do
            if r.done and r.inst==g.inst and r.start<=(raid.e or raid.t)+15*60 and r.e>=raid.t-15*60 then all[#all+1]=r end
          end
          VC.vpSettle({inst=g.inst,iname=g.iname,start=raid.t,e=raid.e,reports=all})
        end
      else
        -- Too late to count, or someone else's raid: tell them it's settled so they stop sending.
        for _,r in ipairs(g.reports) do r.used=true end
        if (VC.vpSync.uAt[raid.key] or 0)<t-600 then sendSettled(raid) end
      end
    elseif VC.vpQuorum(g) then
      local who=settler(g)
      local wait=COLLECT
      if who and who~=me then wait=COLLECT+240 elseif not who then
        g.reports[1].jitter=g.reports[1].jitter or math.random(0,60)
        wait=COLLECT+g.reports[1].jitter
      end
      if t-g.first>=wait and t-g.last>=QUIET then VC.vpSettle(g) end
    end
  end
end

-- Sharing the ledger ------------------------------------------------------------------------------
-- L|id~u~time~by~kind~amount~name~undone~why    one ledger entry (taken from an officer, or two guildmates)
-- W|key~u~start~end~by~instance~reports~people~instance name~bosses    a settled raid
-- F|key~text   a flag on a raid (officers)      U|key;reporter:rid;...   these reports are settled
-- O|u~by~values   the rules       G|version|rules u|week:hash,...   hello: what we hold, week by week
-- B|weeks begin and Y|week:hash,... end of a copy of the weeks that differed.
local function weekOf(t) return VC.vpWeek(now())-VC.vpWeek(t) end
function VC.vpBuckets()
  local p=VC.vpData()
  local keys={}
  if not p then return {} end
  for id,e in pairs(p.led) do
    local w=weekOf(e.t)
    if w>=0 and w<WINDOW then keys[w]=keys[w] or {}; table.insert(keys[w],id..':'..e.u) end
  end
  for key,r in pairs(p.raids) do
    local w=weekOf(r.t)
    if w>=0 and w<WINDOW then keys[w]=keys[w] or {}; table.insert(keys[w],'r'..key..':'..r.u) end
  end
  local out={}
  for w,list in pairs(keys) do
    table.sort(list)
    local h=5381
    for _,k in ipairs(list) do h=hash(k,h) end
    out[w]=T(h%1679616)
  end
  return out
end
function VC.vpDigest()
  local b=VC.vpBuckets()
  local parts={}
  for w=0,WINDOW-1 do if b[w] then parts[#parts+1]=T(w)..':'..b[w] end end
  return table.concat(parts,',')
end
local function parseDigest(text)
  local out={}
  for w,h in (text or ''):gmatch('(%w+):(%w+)') do out[F(w)]=h end
  return out
end
-- The weeks where two digests differ.
local function differing(mine,theirs)
  local out={}
  for w=0,WINDOW-1 do if mine[w]~=theirs[w] then out[#out+1]=w end end
  return out
end
function VC.vpSendWeeks(weeks)
  local p=VC.vpData()
  if not (p and VC.syncOn()) then return end
  local want={}
  for _,w in ipairs(weeks) do want[w]=true end
  local list={}
  for w in pairs(want) do list[#list+1]=T(w) end
  table.sort(list)
  send('P|B|'..table.concat(list,','))
  VC.vpSendRules()
  local raids,entries={},{}
  for _,r in pairs(p.raids) do if want[weekOf(r.t)] then raids[#raids+1]=r end end
  for _,e in pairs(p.led) do if want[weekOf(e.t)] then entries[#entries+1]=e end end
  table.sort(raids,function(a,c) return a.t<c.t end)
  table.sort(entries,function(a,c) if a.t~=c.t then return a.t<c.t end return a.id<c.id end)
  for _,r in ipairs(raids) do VC.vpSendRaid(r) end
  for _,e in ipairs(entries) do VC.vpSendEntry(e) end
  send('P|Y|'..VC.vpDigest())
  VC.vpSync.lastDump=now()
end
function VC.pointsHello()
  local p=VC.vpData()
  if not (VC.syncOn() and p and #VC.roster>0) then return end
  VC.vpSync.helloAt=now()
  send('P|G|'..POINTS_VERSION..'|'..T(p.rules.u or 0)..'|'..VC.vpDigest())
end
-- Taken on its word from an officer; from anyone else only once a second guildmate sends the same.
local function vouched(senderId,key,piece)
  if VC.trusted(senderId) then return true end
  local sy=VC.vpSync
  local p=sy.pending[key]
  if p and p.piece==piece and p.sender~=senderId then sy.pending[key]=nil; return true end
  sy.pending[key]={piece=piece,sender=senderId}
  sy.rejected=sy.rejected+1
  return false
end
local function sane(t) return t and t>1000000000 and t<=now()+600 end
function VC.vpMergeEntry(rest,senderId)
  local id,u,t,by,k,amt,name,x,why=rest:match('^([%w%.]+)~(%w+)~(%w+)~([^~]*)~([vl])~(%-?%d+)~([^~]*)~(1?)~(.*)$')
  if not id then return false end
  u,t,amt=F(u),F(t),tonumber(amt)
  local p=VC.vpData()
  local who=VC.nameId(name)
  local byId=VC.nameId(by)
  if not (p and sane(u) and sane(t) and amt and who and VC.byId[who] and byId and VC.trusted(byId)) then return false end
  local old=p.led[id]
  if old and u<=old.u then return false end
  if weekOf(t)>=WINDOW then return false end
  if not vouched(senderId,'L'..id,rest) then return false end
  p.led[id]={id=id,u=u,t=t,by=cleanText(by,40),k=k,amt=amt,who=who,n=VC.byId[who].short,x=(x=='1') or nil,why=cleanText(why,60)}
  return true
end
function VC.vpMergeRaid(rest,senderId)
  local key,u,t,e,by,inst,rep,att,iname,bosses=rest:match('^(%w+)~(%w+)~(%w+)~(%w+)~([^~]*)~(%w+)~(%d+)~(%d+)~([^~]*)~(.*)$')
  if not key then return false end
  u,t,e=F(u),F(t),F(e)
  local p=VC.vpData()
  local byId=VC.nameId(by)
  if not (p and sane(u) and sane(t) and byId and VC.trusted(byId)) then return false end
  local old=p.raids[key]
  if old and u<=old.u then return false end
  if not vouched(senderId,'W'..key,rest) then return false end
  local list={}
  for b in (bosses or ''):gmatch('[^,]+') do list[#list+1]=cleanText(b,30) end
  local r=old or {key=key,rids={}}
  r.u=u; r.t=t; r.e=e; r.by=cleanText(by,40); r.inst=F(inst); r.rep=tonumber(rep); r.att=tonumber(att); r.iname=cleanText(iname,40); r.bosses=list
  r.fl=old and old.u==u and old.fl or {}
  p.raids[key]=r
  return true
end
function VC.pointsMessage(rest,senderId)
  local sy=VC.vpSync
  local kind,body=(rest or ''):match('^(%a)|(.*)$')
  if not kind then return end
  sy.received=sy.received+1
  local p=VC.vpData()
  if not p then return end
  local did=false
  if kind=='L' then did=VC.vpMergeEntry(body,senderId)
  elseif kind=='W' then did=VC.vpMergeRaid(body,senderId)
  elseif kind=='F' then
    local key,text=body:match('^(%w+)~(.*)$')
    local r=key and p.raids[key]
    if r and VC.trusted(senderId) then
      r.fl=r.fl or {}
      local seen=false
      for _,f in ipairs(r.fl) do if f==text then seen=true end end
      if not seen and #r.fl<8 then r.fl[#r.fl+1]=cleanText(text,200); did=true end
    end
  elseif kind=='U' then
    if VC.trusted(senderId) then
      local me=VC.myId()
      for piece in (body:match('^%w+(.*)$') or ''):gmatch('[^;]+') do
        local name,rid=piece:match('^(.-):(%w+)$')
        if name and VC.nameId(name)==me and p.mine[rid] then p.mine[rid].settled=true; did=true end
        -- Another officer settled it: our copy of those reports is done with.
        local from=name and VC.nameId(name)
        local r=from and p.inbox[inboxKey(from,rid)]
        if r then r.used=true end
      end
    end
  elseif kind=='O' then
    local u,by,values=body:match('^(%w+)~([^~]*)~(.*)$')
    u=F(u)
    local byId=VC.nameId(by)
    if u and u>(p.rules.u or 0) and sane(u) and byId and VC.trusted(byId) and vouched(senderId,'O'..T(u),body) then
      local i=0
      for v in (values or ''):gmatch('[^,]+') do
        i=i+1
        local r=VC.VP_RULES[i]
        if r and tonumber(v) then p.rules[r.key]=math.max(r.min,math.min(r.max,tonumber(v))) end
      end
      p.rules.u=u; p.rules.by=cleanText(by,40)
      did=true
    end
  elseif kind=='R' or kind=='K' or kind=='A' or kind=='T' or kind=='E' then
    did=mergeReport(kind,body,senderId)
  elseif kind=='G' then
    local version,rulesU,theirs=body:match('^([^|]*)|(%w*)|(.*)$')
    if version~=POINTS_VERSION then return end
    -- An officer is here: send them any report of ours that isn't settled yet.
    if VC.trusted(senderId) then
      for rid,r in pairs(p.mine) do
        if r.done and not r.settled and r.start>now()-KEEP_REPORTS and (sy.resentAt[rid] or 0)<now()-60 then
          sy.resentAt[rid]=now()
          later(1+math.random()*4,function() VC.vpSendReport(r) end)
        end
      end
    end
    local weeks=differing(VC.vpBuckets(),parseDigest(theirs))
    if (F(rulesU) or 0)<(p.rules.u or 0) then VC.vpSendRules() end
    if #weeks==0 or now()-sy.lastDump<60 then return end
    -- Officers answer first: their copy is taken on its word, anyone else's needs a second guildmate's.
    later(VC.vpOfficer() and (1+math.random()*3) or (6+math.random()*6),function()
      if now()-sy.lastBegin<20 or now()-sy.lastDump<60 then return end
      VC.vpSendWeeks(weeks)
    end)
  elseif kind=='B' then
    sy.lastBegin=now()
  elseif kind=='Y' then
    local weeks=differing(VC.vpBuckets(),parseDigest(body))
    -- A member's copy still waits for a second guildmate to vouch for it: ask again, once, a little later
    -- (whoever just answered stays quiet for a minute, so someone else does).
    if not VC.trusted(senderId) and next(sy.pending) and not sy.askedAgain and sy.helloAt and now()-sy.helloAt<300 then
      sy.askedAgain=true
      later(25,function() VC.vpSync.lastDump=0; VC.pointsHello() end)
    end
    local mine=VC.vpDigest()
    local last=sy.dumpsTo[senderId]
    if #weeks>0 and (sy.helloAt and now()-sy.helloAt<300) and not (last and last.digest==mine and now()-last.at<600) and now()-sy.lastDump>30 then
      sy.dumpsTo[senderId]={digest=mine,at=now()}
      later(1+math.random()*3,function() VC.vpSendWeeks(weeks) end)
    end
  end
  if did then sy.merged=sy.merged+1; VC.requestRedraw() end
end

-- Housekeeping ------------------------------------------------------------------------------------
function VC.vpPrune()
  local p=VC.vpData()
  if not p then return end
  for id,e in pairs(p.led) do if weekOf(e.t)>=WINDOW then p.led[id]=nil end end
  for key,r in pairs(p.raids) do if weekOf(r.t)>=WINDOW then p.raids[key]=nil end end
  for rid,r in pairs(p.mine) do if r.start<now()-KEEP_REPORTS and rid~=p.cur then p.mine[rid]=nil end end
  for key,r in pairs(p.inbox) do if r.start<now()-KEEP_REPORTS-DAY then p.inbox[key]=nil end end
end
function VC.pointsLogin()
  VC.vpPrune()
  later(20,VC.pointsHello)
end
local sinceTick=0
-- Out of combat and instances, every 5 seconds: send finished reports, settle raids (officers).
function VC.pointsTick(elapsed)
  sinceTick=sinceTick+elapsed
  if sinceTick<5 then return end
  sinceTick=0
  local p=VC.vpData()
  if not (p and VC.myId()) then return end
  local t=now()
  for _,r in pairs(p.mine) do
    if r.done and not r.settled and not r.sentAt then VC.vpSendReport(r) end
  end
  VC.vpSettleDue(t)
end
-- Back out of an instance: say hello, so reports that waited for an officer get to one.
function VC.pointsUnpaused()
  later(8+math.random()*4,VC.pointsHello)
end
function VC.pointsStatus()
  local sy=VC.vpSync
  local p=VC.vpData()
  local n,r=0,0
  if p then for _ in pairs(p.led) do n=n+1 end; for _ in pairs(p.raids) do r=r+1 end end
  return string.format('village points: %d entries, %d raids; %d messages received, %d merged, %d not trusted, %d reports sent%s',
    n,r,sy.received,sy.merged,sy.rejected,sy.sent,sy.lastError and ('; last error: '..sy.lastError) or '')
end

-- Boss kills ----------------------------------------------------------------------------------------
local killFrame=CreateFrame('Frame')
for _,event in ipairs({'ENCOUNTER_END','BOSS_KILL'}) do pcall(killFrame.RegisterEvent,killFrame,event) end
killFrame:SetScript('OnEvent',function(_,event,a,b,c,d,e)
  if not VC.ready then return end
  local ok,err
  if event=='ENCOUNTER_END' then
    if e==1 or e==true then ok,err=pcall(VC.vpBossKill,a,b) else return end
  else ok,err=pcall(VC.vpBossKill,a,b) end
  if not ok then VC.vpSync.lastError=tostring(err) end
end)
