-- Village Command - guild events and the bounty board: what they hold, how guildmates share them, and the
-- rules for who may change what. The pages and dialogs are in BoardUI.lua.
--
-- Events: raids, dungeon runs and other plans with a start time. Guildmates sign up as tank, healer or
-- damage, or say maybe or can't. The leader (or a trusted rank) can record attendance from their group,
-- which Village Command also does on its own 15 minutes after the start when the leader is in a group.
-- Bounties: "20 Thorium Bars, 5g" or "help with Jintha'Alor elites". Guildmates say they're hunting it,
-- report progress (counted from their bags for item bounties) and mark it sent; the poster marks it done
-- and names who earned it. Addons can't hold gold, so the reward is paid in the game by the poster.
--
-- Sharing works like history sharing: a short hello at login with a fingerprint of everything shared; if
-- someone's differs, one guildmate sends theirs and the other answers with what it has that they didn't.
-- Changes made while online go out straight away, one record at a time.
-- Trust: every change names who made it, and only the poster or a trusted rank (Settings > Trust shared
-- history from) may change an event or bounty; signups and hunts only change their own person. Messages
-- can't be signed, so a guildmate with a modified addon could still lie about that. Against it, a client
-- that sees a different copy of one of its own records (its events, bounties, signups, hunts) sends its own
-- again, so the real one wins whenever its owner is online.
local _,VC=...
if type(VC)~='table' then VC=VC_NS or {} end
local now,later,DAY=VC.now,VC.later,VC.DAY
local function settings() return VC.settings() end
local function log(s,always) VC.log(s,always) end
local HOUR=3600

local BOARD_VERSION='1'
-- How far back finished events and bounties are shared, and how long they're kept on this PC.
local SHARE_DAYS=14
local KEEP_DAYS=90
-- Per person, so one guildmate can't flood the board (the trusted ranks get more).
local MAX_EVENTS,MAX_BOUNTIES,MAX_TRUSTED=6,6,25
VC.BOARD_LIMITS={events=MAX_EVENTS,bounties=MAX_BOUNTIES,trusted=MAX_TRUSTED}
local TITLE_MAX,NOTE_MAX=40,90
-- Item calls moved into C_Item on retail; Classic Era and Forever still have the old globals.
local CI=C_Item or {}
local getItemInfo=CI.GetItemInfo or GetItemInfo
local getItemCount=CI.GetItemCount or GetItemCount
local getItemIcon=CI.GetItemIconByID or GetItemIcon
function VC.itemCount(id)
  if not (id and id>0 and getItemCount) then return 0 end
  local ok,n=pcall(getItemCount,id)
  return ok and tonumber(n) or 0
end
function VC.itemIcon(id)
  if not (id and id>0 and getItemIcon) then return nil end
  local ok,icon=pcall(getItemIcon,id)
  return ok and icon or nil
end

VC.EVENT_KINDS={
  {key='raid',label='Raid',icon='Interface\\Icons\\INV_Misc_Head_Dragon_01'},
  {key='dungeon',label='Dungeon',icon='Interface\\Icons\\INV_Misc_Key_03'},
  {key='pvp',label='PvP',icon='Interface\\Icons\\INV_Sword_27'},
  {key='level',label='Leveling',icon='Interface\\Icons\\Spell_Holy_SurgeOfLight'},
  {key='social',label='Social',icon='Interface\\Icons\\INV_Drink_05'},
  {key='other',label='Other',icon='Interface\\Icons\\INV_Misc_Note_01'},
}
VC.EVENT_KIND={}
for _,k in ipairs(VC.EVENT_KINDS) do VC.EVENT_KIND[k.key]=k end
-- Signup answers: tank, healer, damage (all "coming"), maybe, can't.
VC.SIGNUPS={
  {key='t',label='Tank',plural='Tanks',coming=true},
  {key='h',label='Healer',plural='Healers',coming=true},
  {key='d',label='Damage',plural='Damage',coming=true},
  {key='m',label='Maybe',plural='Maybe'},
  {key='n',label='Can\'t come',plural='Can\'t come'},
}
VC.SIGNUP={}
for _,s in ipairs(VC.SIGNUPS) do VC.SIGNUP[s.key]=s end

VC.boardSync={sent=0,received=0,merged=0,rejected=0,lastDump=0,lastBegin=0,dumpsTo={},reasserted=0}

-- Saved data --------------------------------------------------------------------------------------
-- g.board.ev[id]: {id,by,bn,title,kind,t,size,note,u,x,su={[id]={n,s,u}},att={[id]=name},attU}
-- g.board.bo[id]: {id,by,bn,title,item,qty,reward,exp,note,u,st('o' open,'d' done,'x' taken down),done,cl={[id]={n,st,have,u}}}
function VC.boardData()
  local g=VC.guildData()
  if not g then return nil end
  g.board=g.board or {}
  local b=g.board
  b.ev=b.ev or {}; b.bo=b.bo or {}
  return b
end
local function cleanText(text,max)
  text=tostring(text or ''):gsub('|c%x%x%x%x%x%x%x%x',''):gsub('|r',''):gsub('|H.-|h%[?(.-)%]?|h','%1')
  text=text:gsub('[~;|\r\n]',' '):gsub('%s+',' '):gsub('^%s+',''):gsub('%s+$','')
  if #text>max then
    text=text:sub(1,max)
    -- Don't leave half of a multi-byte letter at the end.
    while #text>0 and text:byte(#text)>=128 and text:byte(#text)<192 do text=text:sub(1,-2) end
    if #text>0 and text:byte(#text)>=192 then text=text:sub(1,-2) end
  end
  return text
end
VC.boardCleanText=cleanText
local function newId() return VC.to36(now())..VC.to36(math.random(36*36,36*36*36-1)) end
local function myName()
  local id=VC.myId()
  local m=id and VC.byId[id]
  return m and m.short or (UnitName and (UnitName('player'))) or '?'
end
VC.boardMyName=myName
local function isMine(rec) return rec.by==VC.myId() end
function VC.boardTrusted(id) return VC.trusted(id) end
-- May this person change (or take down) this event or bounty? Its poster, or a trusted rank.
function VC.canManage(rec,id)
  id=id or VC.myId()
  return rec~=nil and id~=nil and (rec.by==id or VC.trusted(id))
end
function VC.eventClosed(ev,t) return ev.x or (ev.t+6*HOUR)<(t or now()) end
function VC.bountyOpen(b,t) return b.st=='o' and (b.exp or 0)>(t or now()) end

-- Events ------------------------------------------------------------------------------------------
-- Upcoming (or under way) events, soonest first; cancelled ones stay a day so people see they're off.
function VC.upcomingEvents()
  local b=VC.boardData()
  local out={}
  if not b then return out end
  local t=now()
  for _,ev in pairs(b.ev) do
    if (ev.t+6*HOUR)>=t and not (ev.x and ev.u<t-DAY) then out[#out+1]=ev end
  end
  table.sort(out,function(a,c) if a.t~=c.t then return a.t<c.t end return a.id<c.id end)
  return out
end
-- Past events, newest first (within `days`).
function VC.pastEvents(days)
  local b=VC.boardData()
  local out={}
  if not b then return out end
  local t=now()
  for _,ev in pairs(b.ev) do
    if (ev.t+6*HOUR)<t and ev.t>=t-(days or 30)*DAY and not ev.x then out[#out+1]=ev end
  end
  table.sort(out,function(a,c) return a.t>c.t end)
  return out
end
-- Who's signed up, by answer: counts and lists of {id,n,s,m(member or nil)} sorted by name.
function VC.signupSummary(ev)
  local out={count=0,coming=0,lists={}}
  for _,s in ipairs(VC.SIGNUPS) do out.lists[s.key]={} end
  for id,su in pairs(ev.su or {}) do
    local list=out.lists[su.s]
    if list then
      list[#list+1]={id=id,n=su.n,s=su.s,u=su.u,m=VC.byId[id]}
      out.count=out.count+1
      if VC.SIGNUP[su.s].coming then out.coming=out.coming+1 end
    end
  end
  for _,list in pairs(out.lists) do table.sort(list,function(a,c) return (a.u or 0)<(c.u or 0) end) end
  return out
end
function VC.mySignup(ev) local su=ev.su and ev.su[VC.myId() or ''] return su and su.s end
local function countBy(field,id,t)
  local b=VC.boardData()
  local n=0
  if not b then return 0 end
  if field=='ev' then
    for _,ev in pairs(b.ev) do if ev.by==id and not VC.eventClosed(ev,t) then n=n+1 end end
  else
    for _,bo in pairs(b.bo) do if bo.by==id and VC.bountyOpen(bo,t) then n=n+1 end end
  end
  return n
end
function VC.boardRoomFor(field,id)
  id=id or VC.myId()
  local limit=VC.trusted(id) and MAX_TRUSTED or (field=='ev' and MAX_EVENTS or MAX_BOUNTIES)
  return countBy(field,id)<limit,limit
end

-- Saves a new event (spec without id) or changes one (spec.id). Returns the event, or nil and why.
function VC.saveEvent(spec)
  local b=VC.boardData()
  local me=VC.myId()
  if not (b and me) then return nil,'Not in a guild.' end
  local title=cleanText(spec.title,TITLE_MAX)
  if title=='' then return nil,'Give the event a name.' end
  local t=math.floor(tonumber(spec.t) or 0)
  if t<now()-HOUR then return nil,'That time has already passed.' end
  if t>now()+60*DAY then return nil,'Events can be planned up to 60 days ahead.' end
  local ev=spec.id and b.ev[spec.id]
  local isNew=not ev
  if ev then
    if not VC.canManage(ev) then return nil,'Only '..(ev.bn or 'its leader')..' or an officer can change this event.' end
  else
    local room,limit=VC.boardRoomFor('ev')
    if not room then return nil,'You already have '..limit..' upcoming events.' end
    ev={id=newId(),by=me,bn=myName(),su={}}
    b.ev[ev.id]=ev
    -- The leader is coming, as whatever they picked last time (damage at first).
    ev.su[me]={n=myName(),s=b.lastRole or 'd',u=now()}
  end
  ev.ed=myName()
  ev.title=title
  ev.kind=VC.EVENT_KIND[spec.kind or ''] and spec.kind or 'other'
  ev.t=t
  ev.size=math.max(0,math.min(40,math.floor(tonumber(spec.size) or 0)))
  ev.note=cleanText(spec.note,NOTE_MAX)
  ev.u=math.max(now(),(ev.u or 0)+1)
  VC.sendEvent(ev)
  if isNew then VC.sendSignups(ev,{me}) end
  VC.requestRedraw()
  return ev
end
function VC.cancelEvent(id)
  local b=VC.boardData()
  local ev=b and b.ev[id]
  if not (ev and VC.canManage(ev)) then return false end
  ev.x=true; ev.ed=myName(); ev.u=math.max(now(),(ev.u or 0)+1)
  VC.sendEvent(ev)
  VC.requestRedraw()
  return true
end
-- Sign yourself up: 't','h','d','m','n', or nil to take your name off.
function VC.signUp(id,answer)
  local b=VC.boardData()
  local ev=b and b.ev[id]
  local me=VC.myId()
  if not (ev and me) or ev.x then return false end
  if answer~=nil and not VC.SIGNUP[answer] then return false end
  ev.su=ev.su or {}
  local old=ev.su[me]
  -- Taking your name off is kept as "can't come", so the change still reaches everyone.
  ev.su[me]={n=myName(),s=answer or 'n',u=math.max(now(),(old and old.u or 0)+1)}
  if answer and VC.SIGNUP[answer].coming then b.lastRole=answer end
  VC.sendSignups(ev,{me})
  VC.requestRedraw()
  return true
end

-- Attendance: who from the guild is in your group right now.
local function unitId(unit)
  if not (UnitExists and UnitExists(unit)) then return nil end
  local name,second=UnitName(unit)
  if type(name)~='string' or VC.isSecret(name) or name=='' then return nil end
  if type(second)=='string' and not VC.isSecret(second) and second~='' then
    name=VC.forever and (name..' '..second) or (name..'-'..second)
  end
  return VC.nameId(name)
end
VC.unitId=unitId
function VC.groupMembers()
  local out={}
  local n=(GetNumGroupMembers and tonumber((GetNumGroupMembers()))) or 0
  local raid=IsInRaid and IsInRaid()
  if raid then
    for i=1,n do out[#out+1]=unitId('raid'..i) end
  else
    out[#out+1]=VC.myId()
    for i=1,4 do out[#out+1]=unitId('party'..i) end
  end
  local seen,list={},{}
  for _,id in ipairs(out) do if id and VC.byId[id] and not seen[id] then seen[id]=true; list[#list+1]=id end end
  return list,n
end
function VC.inGroup() return ((GetNumGroupMembers and tonumber((GetNumGroupMembers()))) or 0)>1 end
-- Adds everyone from the guild in your group to the event's attendance. Returns how many were added.
function VC.takeAttendance(id,quiet)
  local b=VC.boardData()
  local ev=b and b.ev[id]
  if not (ev and VC.canManage(ev)) then return nil,'Only the leader or an officer can take attendance.' end
  local list=VC.groupMembers()
  if #list<2 then return nil,'You\'re not in a group with guildmates.' end
  ev.att=ev.att or {}
  local added={}
  for _,mid in ipairs(list) do
    if not ev.att[mid] then ev.att[mid]=VC.byId[mid].short; added[#added+1]=mid end
  end
  ev.attU=now()
  if #added>0 then VC.sendAttendance(ev,added) end
  if not quiet then log('Attendance for '..ev.title..': '..#list..' guildmates in your group'..(#added<#list and (', '..#added..' new') or '')..'.',true) end
  VC.requestRedraw()
  return #added
end
function VC.attendanceCount(ev) local n=0; for _ in pairs(ev.att or {}) do n=n+1 end return n end
-- How many events with attendance each member was at, over the last `days` days: {id,n,name,of}, most first.
function VC.attendanceStats(days)
  local b=VC.boardData()
  local counts,names,total={}, {}, 0
  if not b then return {},0 end
  local cutoff=now()-(days or 60)*DAY
  for _,ev in pairs(b.ev) do
    if ev.att and next(ev.att) and ev.t>=cutoff and not ev.x then
      total=total+1
      for id,name in pairs(ev.att) do counts[id]=(counts[id] or 0)+1; names[id]=name end
    end
  end
  local out={}
  for id,n in pairs(counts) do out[#out+1]={id=id,n=n,name=(VC.byId[id] and VC.byId[id].short) or names[id],of=total} end
  table.sort(out,function(a,c) if a.n~=c.n then return a.n>c.n end return a.name<c.name end)
  return out,total
end

-- Bounties ----------------------------------------------------------------------------------------
function VC.openBounties()
  local b=VC.boardData()
  local out={}
  if not b then return out end
  local t=now()
  for _,bo in pairs(b.bo) do if VC.bountyOpen(bo,t) then out[#out+1]=bo end end
  table.sort(out,function(a,c) if (a.reward or 0)~=(c.reward or 0) then return (a.reward or 0)>(c.reward or 0) end return a.id<c.id end)
  return out
end
function VC.closedBounties(days)
  local b=VC.boardData()
  local out={}
  if not b then return out end
  local t=now()
  local cutoff=t-(days or 30)*DAY
  for _,bo in pairs(b.bo) do if not VC.bountyOpen(bo,t) and bo.u>=cutoff then out[#out+1]=bo end end
  table.sort(out,function(a,c) return a.u>c.u end)
  return out
end
-- Completed bounties per hunter over the last `days` days: {name,n,gold}, most first.
function VC.bountyHunters(days)
  local b=VC.boardData()
  local by={}
  if not b then return {} end
  local cutoff=now()-(days or 90)*DAY
  for _,bo in pairs(b.bo) do
    if bo.st=='d' and bo.done and bo.done~='' and bo.u>=cutoff then
      local id=VC.nameId(bo.done) or bo.done
      local e=by[id] or {name=(VC.byId[id] and VC.byId[id].short) or bo.done,n=0,gold=0}
      e.n=e.n+1; e.gold=e.gold+(bo.reward or 0)
      by[id]=e
    end
  end
  local out={}
  for _,e in pairs(by) do out[#out+1]=e end
  table.sort(out,function(a,c) if a.n~=c.n then return a.n>c.n end return a.name<c.name end)
  return out
end
function VC.bountyHunts(bo)
  local out={}
  for id,c in pairs(bo.cl or {}) do
    if c.st~='off' then out[#out+1]={id=id,n=c.n,st=c.st,have=c.have,u=c.u,m=VC.byId[id]} end
  end
  table.sort(out,function(a,c) return (a.u or 0)<(c.u or 0) end)
  return out
end
function VC.myHunt(bo) local c=bo.cl and bo.cl[VC.myId() or ''] return c and c.st~='off' and c or nil end
function VC.itemIdFrom(text)
  local id=tostring(text or ''):match('item:(%d+)')
  return id and tonumber(id) or nil
end
function VC.itemName(itemId)
  if not (itemId and itemId>0 and getItemInfo) then return nil end
  local ok,name,link=pcall(getItemInfo,itemId)
  if not ok then return nil end
  if type(name)=='string' and not VC.isSecret(name) then return name,link end
end
-- Saves a new bounty (spec without id) or changes one. spec: title or item link, qty, reward (copper), days, note.
function VC.saveBounty(spec)
  local b=VC.boardData()
  local me=VC.myId()
  if not (b and me) then return nil,'Not in a guild.' end
  local item=spec.item or VC.itemIdFrom(spec.title) or 0
  local title=cleanText(spec.title,TITLE_MAX)
  if title=='' and item>0 then title=VC.itemName(item) or ('Item '..item) end
  if title=='' then return nil,'Say what you\'re after: type it, or shift-click an item.' end
  local bo=spec.id and b.bo[spec.id]
  if bo then
    if not VC.canManage(bo) then return nil,'Only '..(bo.bn or 'its poster')..' or an officer can change this bounty.' end
  else
    local room,limit=VC.boardRoomFor('bo')
    if not room then return nil,'You already have '..limit..' open bounties.' end
    bo={id=newId(),by=me,bn=myName(),st='o',cl={}}
    b.bo[bo.id]=bo
  end
  bo.ed=myName()
  bo.title=title
  bo.item=item
  bo.qty=math.max(1,math.min(9999,math.floor(tonumber(spec.qty) or 1)))
  bo.reward=math.max(0,math.min(99999*10000,math.floor(tonumber(spec.reward) or 0)))
  local days=math.max(1,math.min(30,math.floor(tonumber(spec.days) or 7)))
  if not spec.id or spec.days then bo.exp=now()+days*DAY end
  bo.note=cleanText(spec.note,NOTE_MAX)
  bo.u=math.max(now(),(bo.u or 0)+1)
  VC.sendBounty(bo)
  VC.requestRedraw()
  return bo
end
-- Done (credit: a hunter's name, or '' for nobody in particular) or taken down.
function VC.closeBounty(id,done,credit)
  local b=VC.boardData()
  local bo=b and b.bo[id]
  if not (bo and VC.canManage(bo)) or bo.st~='o' then return false end
  bo.st=done and 'd' or 'x'
  bo.done=done and cleanText(credit,40) or nil
  bo.ed=myName()
  bo.u=math.max(now(),(bo.u or 0)+1)
  if done then VC.bountyNews(bo) end
  VC.sendBounty(bo)
  VC.requestRedraw()
  return true
end
-- Your hunt: 'on' (hunting it), 'sent' (handed in, waiting for the poster), 'off' (not any more).
function VC.hunt(id,state)
  local b=VC.boardData()
  local bo=b and b.bo[id]
  local me=VC.myId()
  if not (bo and me and VC.bountyOpen(bo)) or bo.by==me then return false end
  bo.cl=bo.cl or {}
  local old=bo.cl[me]
  local have=old and old.have or 0
  if bo.item and bo.item>0 then have=VC.itemCount(bo.item) end
  bo.cl[me]={n=myName(),st=state,have=have,u=math.max(now(),(old and old.u or 0)+1)}
  VC.sendClaims(bo,{me})
  VC.requestRedraw()
  return true
end
-- A completed bounty goes in the activity feed, once, dated when it was done.
function VC.bountyNews(bo)
  local g=VC.guildData()
  if not (g and bo.st=='d') then return end
  g.board.news=g.board.news or {}
  if g.board.news[bo.id] then return end
  g.board.news[bo.id]=bo.u
  if bo.u<now()-7*DAY then return end
  local who=(bo.done and bo.done~='') and bo.done or bo.bn
  local detail=(bo.done and bo.done~='') and ('earned the bounty: '..(bo.qty>1 and (bo.qty..' x ') or '')..bo.title..' for '..bo.bn)
    or ('closed the bounty: '..bo.title)
  local e={t=bo.u,k='bounty',n=who,d=detail}
  local at=#g.events+1
  while at>1 and g.events[at-1].t>e.t do at=at-1 end
  table.insert(g.events,at,e)
  while #g.events>400 do table.remove(g.events,1) end
end

-- Messages ----------------------------------------------------------------------------------------
-- V|id~u~name~editor~start~kind~size~x~title~note   an event (name: its leader; editor: who made this change)
-- S|eventId~u;name:answer:u;name:answer:u...        signups (each one only changes its own person)
-- A|eventId~u~recorder;name;name...                 attendance (added to, never taken away)
-- Q|id~u~name~editor~state~item~qty~reward~expires~done~title~note    a bounty
-- C|bountyId;name:state:have:u;...                  hunts
-- G|version|fingerprint  hello;  K| begin and Y|fingerprint end of a full copy.
local T,F=VC.to36,VC.from36
local function send(line) if VC.syncOn() then VC.syncQueue(line) end end
local function packed(head,pieces)
  local line=''
  for _,piece in ipairs(pieces) do
    if #line>0 and #head+#line+#piece+1>236 then send(head..line); line='' end
    line=line..';'..piece
  end
  if #line>0 then send(head..line) end
end
function VC.encodeEventRecord(ev)
  return 'V|'..ev.id..'~'..T(ev.u)..'~'..(ev.bn or '')..'~'..(ev.ed or ev.bn or '')..'~'..T(ev.t)..'~'..ev.kind..'~'..(ev.size or 0)..'~'..(ev.x and '1' or '')..'~'..(ev.title or '')..'~'..(ev.note or '')
end
function VC.encodeBountyRecord(bo)
  return 'Q|'..bo.id..'~'..T(bo.u)..'~'..(bo.bn or '')..'~'..(bo.ed or bo.bn or '')..'~'..bo.st..'~'..(bo.item or 0)..'~'..(bo.qty or 1)..'~'..T(bo.reward or 0)..'~'..T(bo.exp or 0)..'~'..(bo.done or '')..'~'..(bo.title or '')..'~'..(bo.note or '')
end
function VC.sendEvent(ev) send(VC.encodeEventRecord(ev)) end
function VC.sendBounty(bo) send(VC.encodeBountyRecord(bo)) end
function VC.sendSignups(ev,ids)
  local pieces={}
  for _,id in ipairs(ids) do
    local su=ev.su[id]
    if su then pieces[#pieces+1]=su.n..':'..su.s..':'..T(su.u) end
  end
  packed('S|'..ev.id,pieces)
end
function VC.sendAttendance(ev,ids)
  local pieces={}
  for _,id in ipairs(ids) do if ev.att[id] then pieces[#pieces+1]=ev.att[id] end end
  packed('A|'..ev.id..'~'..T(ev.attU or now())..'~'..VC.boardMyName(),pieces)
end
function VC.sendClaims(bo,ids)
  local pieces={}
  for _,id in ipairs(ids) do
    local c=bo.cl[id]
    if c then pieces[#pieces+1]=c.n..':'..c.st..':'..(c.have or 0)..':'..T(c.u) end
  end
  packed('C|'..bo.id,pieces)
end
-- What's shared: events from the last two weeks on, open bounties, and bounties closed in the last two weeks.
local function shared(b,t)
  local evs,bos={},{}
  local cutoff=t-SHARE_DAYS*DAY
  for id,ev in pairs(b.ev) do if ev.t>=cutoff then evs[#evs+1]=id end end
  for id,bo in pairs(b.bo) do if VC.bountyOpen(bo,t) or bo.u>=cutoff then bos[#bos+1]=id end end
  table.sort(evs); table.sort(bos)
  return evs,bos
end
function VC.boardDigest()
  local b=VC.boardData()
  if not b then return '0' end
  local evs,bos=shared(b,now())
  local keys={}
  for _,id in ipairs(evs) do
    local ev=b.ev[id]
    keys[#keys+1]='v'..id..':'..ev.u..':'..VC.attendanceCount(ev)
    local su={}
    for sid,s in pairs(ev.su or {}) do su[#su+1]=sid..'='..s.u end
    table.sort(su)
    keys[#keys+1]=table.concat(su,',')
  end
  for _,id in ipairs(bos) do
    local bo=b.bo[id]
    keys[#keys+1]='q'..id..':'..bo.u
    local cl={}
    for cid,c in pairs(bo.cl or {}) do cl[#cl+1]=cid..'='..c.u end
    table.sort(cl)
    keys[#keys+1]=table.concat(cl,',')
  end
  local h=5381
  for _,k in ipairs(keys) do for i=1,#k do h=(h*33+k:byte(i))%4294967296 end end
  return T(h)..'.'..(#evs+#bos)
end
function VC.sendBoard()
  local b=VC.boardData()
  if not (b and VC.syncOn()) then return end
  local evs,bos=shared(b,now())
  send('K|'..VC.boardDigest())
  for _,id in ipairs(evs) do
    local ev=b.ev[id]
    VC.sendEvent(ev)
    local ids={}
    for sid in pairs(ev.su or {}) do ids[#ids+1]=sid end
    table.sort(ids)
    VC.sendSignups(ev,ids)
    if ev.att and next(ev.att) then
      local att={}
      for aid in pairs(ev.att) do att[#att+1]=aid end
      table.sort(att)
      VC.sendAttendance(ev,att)
    end
  end
  for _,id in ipairs(bos) do
    local bo=b.bo[id]
    VC.sendBounty(bo)
    local ids={}
    for cid in pairs(bo.cl or {}) do ids[#ids+1]=cid end
    table.sort(ids)
    if #ids>0 then VC.sendClaims(bo,ids) end
  end
  send('Y|'..VC.boardDigest())
  VC.boardSync.lastDump=now()
end
function VC.boardHello()
  if not (VC.syncOn() and VC.boardData() and #VC.roster>0) then return end
  VC.boardSync.helloAt=now()
  send('G|'..BOARD_VERSION..'|'..VC.boardDigest())
end

-- Merging what guildmates send --------------------------------------------------------------------
local function sane(t,ahead) return t and t>1000000000 and t<=now()+(ahead or 600) end
-- Someone sent a different copy of a record that's ours: send ours again (once a minute at most), so ours wins.
local reassertAt={}
local function reassert(key,fn)
  if (reassertAt[key] or 0)>now()-60 then return end
  reassertAt[key]=now()
  VC.boardSync.reasserted=VC.boardSync.reasserted+1
  later(2+math.random()*3,fn)
end
-- The change has to come from the poster or a trusted rank (the editor named in the message). Changes to our
-- own records from anyone else are answered with ours, so ours wins.
local function allowedEditor(rec,by,editorId)
  return editorId~=nil and (editorId==by or VC.trusted(editorId))
end
function VC.mergeEventRecord(rest,senderId)
  local id,u,name,editor,start,kind,size,x,title,note=rest:match('^(%w+)~(%w+)~([^~]*)~([^~]*)~(%w+)~(%a+)~(%d*)~(1?)~([^~]*)~(.*)$')
  if not id then return false end
  u,start=F(u),F(start)
  local by=VC.nameId(name)
  local editorId=VC.nameId(editor)
  local b=VC.boardData()
  if not (b and by and VC.byId[by] and sane(u) and sane(start,61*DAY)) or start<now()-KEEP_DAYS*DAY then return false end
  local ev=b.ev[id]
  if (ev and ev.by~=by) or not allowedEditor(ev,by,editorId) then
    VC.boardSync.rejected=VC.boardSync.rejected+1
    if ev and isMine(ev) then reassert('v'..id,function() ev.u=math.min(now()+590,math.max(now(),ev.u+1,(u or 0)+1)); VC.sendEvent(ev) end) end
    return false
  end
  if ev and u<=ev.u then return false end
  if not ev then
    if start>now() and x~='1' and countBy('ev',by)>=(VC.trusted(by) and MAX_TRUSTED or MAX_EVENTS) then VC.boardSync.rejected=VC.boardSync.rejected+1; return false end
    ev={id=id,by=by,su={}}
    b.ev[id]=ev
    if settings().boardNews and VC.boardLive and start>now() and x~='1' then
      log('|cffffd100'..(VC.byId[by].short)..'|r posted an event: |cffffd100'..cleanText(title,TITLE_MAX)..'|r, '..VC.whenText(start)..'. /vc events',true)
    end
  end
  ev.bn=VC.byId[by].short; ev.ed=cleanText(editor,40); ev.u=u; ev.t=start
  ev.kind=VC.EVENT_KIND[kind] and kind or 'other'
  ev.size=math.max(0,math.min(40,tonumber(size) or 0))
  ev.x=(x=='1') or nil
  ev.title=cleanText(title,TITLE_MAX); ev.note=cleanText(note,NOTE_MAX)
  return true
end
-- Each signup only changes its own person. A different copy of our own is answered with ours.
function VC.mergeSignups(rest,senderId)
  local id,list=rest:match('^(%w+)(.*)$')
  local b=VC.boardData()
  local ev=b and id and b.ev[id]
  if not ev then return false end
  local changed=false
  local me=VC.myId()
  ev.su=ev.su or {}
  for piece in (list or ''):gmatch('[^;]+') do
    local name,s,u=piece:match('^([^:]+):(%a):(%w+)$')
    local sid=name and VC.nameId(name)
    u=F(u)
    if sid and VC.byId[sid] and VC.SIGNUP[s] and sane(u) then
      local mine=ev.su[sid]
      if sid==me and mine then
        if u~=mine.u or s~=mine.s then reassert('s'..id,function() mine.u=math.min(now()+590,math.max(now(),mine.u+1,u+1)); VC.sendSignups(ev,{me}) end) end
      elseif not mine or u>mine.u then
        ev.su[sid]={n=VC.byId[sid].short,s=s,u=u}; changed=true
      end
    end
  end
  return changed
end
function VC.mergeAttendance(rest,senderId)
  local id,u,recorder,list=rest:match('^(%w+)~(%w+)~([^;~]*)(.*)$')
  local b=VC.boardData()
  local ev=b and id and b.ev[id]
  u=F(u)
  if not (ev and sane(u)) then return false end
  -- Taken by the leader or a trusted rank; relayed by anyone.
  local rid=VC.nameId(recorder)
  if not (rid and VC.canManage(ev,rid)) then VC.boardSync.rejected=VC.boardSync.rejected+1; return false end
  local changed=false
  ev.att=ev.att or {}
  for name in (list or ''):gmatch('[^;]+') do
    local aid=VC.nameId(name)
    if aid and not ev.att[aid] then ev.att[aid]=(VC.byId[aid] and VC.byId[aid].short) or name; changed=true end
  end
  if changed then ev.attU=math.max(ev.attU or 0,u) end
  return changed
end
function VC.mergeBountyRecord(rest,senderId)
  local id,u,name,editor,st,item,qty,reward,exp,done,title,note=rest:match('^(%w+)~(%w+)~([^~]*)~([^~]*)~([odx])~(%d*)~(%d*)~(%w*)~(%w*)~([^~]*)~([^~]*)~(.*)$')
  if not id then return false end
  u,reward,exp=F(u),F(reward) or 0,F(exp) or 0
  local by=VC.nameId(name)
  local editorId=VC.nameId(editor)
  local b=VC.boardData()
  if not (b and by and VC.byId[by] and sane(u)) or exp>now()+31*DAY then return false end
  local bo=b.bo[id]
  if (bo and bo.by~=by) or not allowedEditor(bo,by,editorId) then
    VC.boardSync.rejected=VC.boardSync.rejected+1
    if bo and isMine(bo) then reassert('q'..id,function() bo.u=math.min(now()+590,math.max(now(),bo.u+1,(u or 0)+1)); VC.sendBounty(bo) end) end
    return false
  end
  if bo and u<=bo.u then return false end
  local isNew=not bo
  if isNew then
    if st=='o' and countBy('bo',by)>=(VC.trusted(by) and MAX_TRUSTED or MAX_BOUNTIES) then VC.boardSync.rejected=VC.boardSync.rejected+1; return false end
    bo={id=id,by=by,cl={}}
    b.bo[id]=bo
  end
  bo.bn=VC.byId[by].short; bo.ed=cleanText(editor,40); bo.u=u; bo.st=st
  bo.item=tonumber(item) or 0; bo.qty=math.max(1,tonumber(qty) or 1); bo.reward=reward; bo.exp=exp
  bo.done=(done~='' and cleanText(done,40)) or nil
  bo.title=cleanText(title,TITLE_MAX); bo.note=cleanText(note,NOTE_MAX)
  if st=='d' then VC.bountyNews(bo) end
  if isNew and st=='o' and exp>now() and settings().boardNews and VC.boardLive then
    log('|cffffd100'..bo.bn..'|r posted a bounty: |cffffd100'..(bo.qty>1 and (bo.qty..' x ') or '')..bo.title..'|r'..(reward>0 and (' for '..VC.money(reward)) or '')..'. /vc bounties',true)
  end
  return true
end
function VC.mergeClaims(rest,senderId)
  local id,list=rest:match('^(%w+)(.*)$')
  local b=VC.boardData()
  local bo=b and id and b.bo[id]
  if not bo then return false end
  local changed=false
  local me=VC.myId()
  bo.cl=bo.cl or {}
  for piece in (list or ''):gmatch('[^;]+') do
    local name,st,have,u=piece:match('^([^:]+):(%a+):(%d+):(%w+)$')
    local cid=name and VC.nameId(name)
    u=F(u)
    if cid and VC.byId[cid] and cid~=bo.by and (st=='on' or st=='off' or st=='sent') and sane(u) then
      local mine=bo.cl[cid]
      if cid==me and mine then
        if u~=mine.u or mine.st~=st then reassert('c'..id,function() mine.u=math.min(now()+590,math.max(now(),mine.u+1,u+1)); VC.sendClaims(bo,{me}) end) end
      elseif not mine or u>mine.u then
        bo.cl[cid]={n=VC.byId[cid].short,st=st,have=math.min(99999,tonumber(have) or 0),u=u}; changed=true
      end
    end
  end
  return changed
end
local MERGE={V=VC.mergeEventRecord,S=VC.mergeSignups,A=VC.mergeAttendance,Q=VC.mergeBountyRecord,C=VC.mergeClaims}
function VC.onBoardMessage(kind,rest,senderId)
  local sy=VC.boardSync
  if MERGE[kind] then
    sy.received=sy.received+1
    local ok,did=pcall(MERGE[kind],rest or '',senderId)
    if not ok then sy.lastError=tostring(did)
    elseif did then sy.merged=sy.merged+1; VC.requestRedraw() end
  elseif kind=='G' then
    sy.received=sy.received+1
    local version,theirs=(rest or ''):match('^([^|]*)|(.*)$')
    if version~=BOARD_VERSION or theirs==VC.boardDigest() then return end
    if now()-sy.lastDump<60 then return end
    later(1+math.random()*6,function()
      if now()-sy.lastBegin<20 or now()-sy.lastDump<60 then return end
      VC.sendBoard()
    end)
  elseif kind=='K' then
    sy.lastBegin=now()
  elseif kind=='Y' then
    -- Their copy has arrived; if ours still differs we hold something they don't. Send it back, once.
    local mine=VC.boardDigest()
    local last=sy.dumpsTo[senderId]
    if rest~=mine and (sy.helloAt and now()-sy.helloAt<300) and not (last and last.digest==mine and now()-last.at<600) and now()-sy.lastDump>30 then
      sy.dumpsTo[senderId]={digest=mine,at=now()}
      later(1+math.random()*3,VC.sendBoard)
    end
  end
end

-- Housekeeping, reminders, progress ---------------------------------------------------------------
function VC.pruneBoard()
  local b=VC.boardData()
  if not b then return end
  local cutoff=now()-KEEP_DAYS*DAY
  for id,ev in pairs(b.ev) do if ev.t<cutoff or (ev.x and ev.u<now()-SHARE_DAYS*DAY) then b.ev[id]=nil end end
  for id,bo in pairs(b.bo) do
    if not VC.bountyOpen(bo) and (bo.u<cutoff or (bo.st=='x' and bo.u<now()-SHARE_DAYS*DAY) or (bo.st=='o' and (bo.exp or 0)<now()-SHARE_DAYS*DAY)) then b.bo[id]=nil end
  end
  for id,t in pairs(b.news or {}) do if t<cutoff then b.news[id]=nil end end
end
function VC.boardLogin()
  VC.pruneBoard()
  later(16,function()
    VC.boardHello()
    -- Chat news only for what's posted from here on, not what a login catch-up brings in.
    later(60,function() VC.boardLive=true end)
  end)
end
-- "today 20:00", "tomorrow 19:30", "Fri 21 Nov 20:00".
function VC.whenText(t)
  if not date then return '' end
  local today=date('%Y%m%d',now())
  local day=date('%Y%m%d',t)
  local clock=date('%H:%M',t)
  if day==today then return 'today '..clock end
  if day==date('%Y%m%d',now()+DAY) then return 'tomorrow '..clock end
  if t>now() and t<now()+6*DAY then return date('%A',t)..' '..clock end
  return date('%a %d %b',t)..' '..clock
end
function VC.untilText(t)
  local d=t-now()
  if d<=0 then return d>-6*HOUR and 'under way' or 'over' end
  if d<HOUR then return 'in '..math.max(1,math.floor(d/60))..' min' end
  if d<DAY then return 'in '..math.floor(d/HOUR)..'h '..math.floor((d%HOUR)/60)..'m' end
  return 'in '..math.floor(d/DAY)..' day'..(math.floor(d/DAY)==1 and '' or 's')
end
VC.reminded={}
local sinceBoard,sinceLocal=0,0
-- Every few seconds, out of combat and instances: reminders, and bag counts for bounties you're hunting.
function VC.boardTick(elapsed)
  sinceBoard=sinceBoard+elapsed
  if sinceBoard<5 then return end
  sinceBoard=0
  local b=VC.boardData()
  local me=VC.myId()
  if not (b and me) then return end
  local t=now()
  if settings().eventReminders then
    for _,ev in pairs(b.ev) do
      local mine=ev.su and ev.su[me]
      local going=ev.by==me or (mine and (VC.SIGNUP[mine.s].coming or mine.s=='m'))
      if going and not ev.x then
        if t>=ev.t-15*60 and t<ev.t and not VC.reminded[ev.id..'s'] then
          VC.reminded[ev.id..'s']=true
          log('|cffffd100'..ev.title..'|r starts '..VC.untilText(ev.t)..' ('..date('%H:%M',ev.t)..'), led by '..ev.bn..'.',true)
        elseif t>=ev.t and t<ev.t+10*60 and not VC.reminded[ev.id..'g'] then
          VC.reminded[ev.id..'g']=true
          VC.reminded[ev.id..'s']=true
          log('|cffffd100'..ev.title..'|r is starting now. Whisper '..ev.bn..' for an invite.',true)
        end
      end
    end
  end
  -- Bag counts for item bounties you're hunting, shared at most every half minute each.
  do
    for _,bo in pairs(b.bo) do
      local c=bo.cl and bo.cl[me]
      if c and c.st=='on' and bo.item and bo.item>0 and VC.bountyOpen(bo,t) then
        local have=VC.itemCount(bo.item)
        if have~=c.have and (c.u or 0)<t-30 then
          c.have=have; c.u=math.max(t,(c.u or 0)+1)
          VC.sendClaims(bo,{me}); VC.requestRedraw()
        end
      end
    end
  end
end
-- Runs in raids and dungeons too (it only reads the group): attendance for the leader's own event, taken
-- once 15 minutes after the start, if they're in a group with guildmates.
function VC.boardLocalTick(elapsed)
  sinceLocal=sinceLocal+elapsed
  if sinceLocal<20 then return end
  sinceLocal=0
  if InCombatLockdown and InCombatLockdown() then return end
  local b=VC.boardData()
  local me=VC.myId()
  if not (b and me and VC.inGroup()) then return end
  local t=now()
  for _,ev in pairs(b.ev) do
    if ev.by==me and not ev.x and not ev.autoAtt and t>=ev.t+15*60 and t<ev.t+4*HOUR then
      ev.autoAtt=true
      local n=VC.takeAttendance(ev.id,true)
      if n then log('Took attendance for |cffffd100'..ev.title..'|r: '..VC.attendanceCount(ev)..' guildmates. Take it again from the Events page if more join later.',true) end
    end
  end
end
function VC.boardStatus()
  local sy=VC.boardSync
  local b=VC.boardData()
  local evs,bos=0,0
  if b then for _ in pairs(b.ev) do evs=evs+1 end; for _ in pairs(b.bo) do bos=bos+1 end end
  return string.format('events and bounties: %d events, %d bounties kept; %d messages received, %d merged, %d not trusted, %d own records re-sent; fingerprint %s%s',
    evs,bos,sy.received,sy.merged,sy.rejected,sy.reasserted,VC.boardDigest(),sy.lastError and ('; last error: '..sy.lastError) or '')
end
