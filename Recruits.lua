-- Village Command - recruitment: who invited whom, and a leaderboard of recruiters.
--
-- The game's guild event log is the server's own record of invites and joins, with both names, so it can't
-- be faked or misread. It only holds the last 100 or so events, though, so every Village Command reads it
-- now and then, keeps who joined on whose invite, and shares that with guildmates so it outlives the log.
-- A recruit counts for whoever invited them while they're in the guild: leaving takes them off the board,
-- and someone who leaves and comes back counts for whoever invited them back.
local _,VC=...
if type(VC)~='table' then VC=VC_NS or {} end
local now,later,DAY=VC.now,VC.later,VC.DAY
local T,F=VC.to36,VC.from36
local HOUR=3600
local RECRUIT_VERSION='1'
-- Log times are "so many days and hours ago", so two reads (or two guildmates) differ by an hour or so.
local SAME=3*HOUR
-- An invite waits this long for its join: the join can arrive after the invite has left the log.
local INVITE_KEEP=7*DAY
-- How often the log is read (out of combat and instances).
local READ_EVERY=300

VC.recruitSync={received=0,merged=0,rejected=0,sent=0,reads=0,lastDump=0,lastBegin=0,dumpsTo={},pending={}}

local function send(line) if VC.syncOn() then VC.syncQueue(line); VC.recruitSync.sent=VC.recruitSync.sent+1 end end
local function plain(text) return (tostring(text or ''):gsub('[~;|]','')) end
local function sane(t) return t and t>1000000000 and t<=now()+600 end

-- by[recruit id]={by=inviter id (nil: not known), bn=inviter's name, n=recruit's name, t=joined, src='log'/'sync'}
-- inv[invitee id]={by=inviter id, bn=inviter's name, t=invited}: invites still waiting for their join.
function VC.recruitData()
  local g=VC.guildData()
  if not g then return nil end
  g.rec=g.rec or {}
  g.rec.by=g.rec.by or {}
  g.rec.inv=g.rec.inv or {}
  return g.rec
end

-- Records a join. Returns true when it changed anything. A later join (they left and came back) replaces an
-- earlier one; the same join can gain an inviter we didn't know. The log we read ourselves beats a copy.
function VC.setRecruit(who,name,by,byName,t,src)
  local r=VC.recruitData()
  if not (r and who and t) then return false end
  if by=='' then by=nil end
  if by==who then return false end
  local old=r.by[who]
  local same=old and math.abs(t-old.t)<SAME
  if old then
    if t<old.t-SAME then return false end
    if same then
      if (old.by or '')==(by or '') or not by then return false end
      if old.src=='log' and src~='log' and old.by then return false end
    end
  end
  r.by[who]={by=by,bn=by and plain(byName) or nil,n=plain(name),t=same and old.t or t,src=src}
  return true
end

-- The guild event log ------------------------------------------------------------------------------
local function ago(y,mo,d,h)
  return ((((tonumber(y) or 0)*365+(tonumber(mo) or 0)*30+(tonumber(d) or 0))*24)+(tonumber(h) or 0))*HOUR
end
function VC.queryGuildLog()
  if VC.paused and VC.paused() then return end
  if QueryGuildEventLog then pcall(QueryGuildEventLog) end
end
-- Reads what the game has of the log. Returns how many joins changed something.
function VC.readGuildLog()
  local r=VC.recruitData()
  if not (r and GetNumGuildEvents and GetGuildEventInfo and #VC.roster>0) then return 0 end
  local n=tonumber((GetNumGuildEvents())) or 0
  if n<=0 then return 0 end
  VC.recruitSync.reads=VC.recruitSync.reads+1
  VC.recruitSync.logSize=n
  local t=now()
  local all={}
  for i=1,n do
    local ok,kind,p1,p2,_,y,mo,d,h=pcall(GetGuildEventInfo,i)
    if ok and type(kind)=='string' and not VC.isSecret(kind) and not VC.isSecret(p1) and not VC.isSecret(p2) then
      all[#all+1]={i=i,k=kind,a=p1,b=p2,t=t-ago(y,mo,d,h)}
    end
  end
  if #all==0 then return 0 end
  -- Oldest first. The game doesn't say which end of the log is newest, so look at the times; within the
  -- same hour keep the log's own order, and an invite always comes before the join it led to.
  local newestFirst=all[1].t>all[#all].t
  table.sort(all,function(a,b)
    if math.abs(a.t-b.t)>=HOUR then return a.t<b.t end
    if (a.k=='invite')~=(b.k=='invite') then return a.k=='invite' end
    if newestFirst then return a.i>b.i end
    return a.i<b.i
  end)
  local complete=VC.rosterComplete()
  local changed=0
  for _,e in ipairs(all) do
    if e.k=='invite' then
      local who,by=VC.nameId(e.b),VC.nameId(e.a)
      local old=who and r.inv[who]
      if who and by and (not old or e.t>=old.t-SAME) then r.inv[who]={by=by,bn=plain(VC.displayName(e.a)),t=e.t} end
    elseif e.k=='join' then
      local who=VC.nameId(e.a)
      -- Someone no longer in the guild doesn't count, so isn't kept.
      if who and (VC.byId[who] or not complete) then
        local inv=r.inv[who]
        local by,bn
        if inv and inv.t<=e.t+SAME and inv.t>=e.t-INVITE_KEEP then by,bn=inv.by,inv.bn end
        local m=VC.byId[who]
        if VC.setRecruit(who,m and m.short or VC.displayName(e.a),by,bn,e.t,'log') then changed=changed+1 end
      end
    end
  end
  VC.pruneRecruits()
  if changed>0 then VC.requestRedraw() end
  return changed
end
-- Leavers come off the board (once the roster is known to be whole); old invites that never led anywhere go.
function VC.pruneRecruits()
  local r=VC.recruitData()
  if not r then return end
  if VC.rosterComplete() then
    for who in pairs(r.by) do if not VC.byId[who] then r.by[who]=nil end end
  end
  for who,inv in pairs(r.inv) do if inv.t<now()-INVITE_KEEP then r.inv[who]=nil end end
end

-- The leaderboard ---------------------------------------------------------------------------------
-- Everyone who brought in a guildmate who's still here, most first: {id, name, m (if still here), n, month,
-- list={{m=recruit, t=joined}}}.
function VC.recruiters()
  local r=VC.recruitData()
  local out,byId={},{}
  if not r then return out end
  local month=now()-30*DAY
  for who,rec in pairs(r.by) do
    local m=VC.byId[who]
    if rec.by and m then
      local e=byId[rec.by]
      if not e then
        local im=VC.byId[rec.by]
        e={id=rec.by,m=im,name=im and im.short or rec.bn or rec.by,n=0,month=0,list={}}
        byId[rec.by]=e; out[#out+1]=e
      end
      e.n=e.n+1
      if rec.t>=month then e.month=e.month+1 end
      e.list[#e.list+1]={m=m,t=rec.t}
    end
  end
  for _,e in ipairs(out) do table.sort(e.list,function(a,b) return a.t>b.t end) end
  table.sort(out,function(a,b)
    if a.n~=b.n then return a.n>b.n end
    if a.month~=b.month then return a.month>b.month end
    return a.name<b.name
  end)
  return out
end
-- Who invited this member, if known: the inviter's name, the join time, and the inviter if still here.
function VC.invitedBy(id)
  local r=VC.recruitData()
  local rec=r and r.by[id or '']
  if not (rec and rec.by) then return nil end
  local im=VC.byId[rec.by]
  return im and im.short or rec.bn or rec.by,rec.t,im
end
function VC.recruitMemberLines(tip,m)
  local name,t=VC.invitedBy(m.id)
  if name then tip:AddLine('Invited by '..name..(date and (' on '..date('%d %b %Y',t)) or ''),.7,.85,1) end
  for i,e in ipairs(VC.recruiters()) do
    if e.id==m.id then
      tip:AddLine('Recruited '..e.n..' guildmate'..(e.n==1 and '' or 's')..' still here (#'..i..' recruiter)',.7,.85,1)
      break
    end
  end
end
-- The text for /vc recruits.
function VC.recruitsCommand(arg)
  local name=(arg or ''):gsub('^%s+',''):gsub('%s+$','')
  if name~='' then
    local id=VC.nameId(name)
    local m=id and VC.byId[id]
    if not m then VC.log('Nobody called '..name..' in the guild.',true); return end
    local by,t=VC.invitedBy(id)
    VC.log(m.short..(by and (' joined on '..by..'\'s invite'..(date and (', '..date('%d %b %Y',t)) or '')..'.') or ': who invited them isn\'t known (they joined before Village Command saw it).'),true)
    for _,e in ipairs(VC.recruiters()) do
      if e.id==id then
        local names={}
        for _,x in ipairs(e.list) do names[#names+1]=x.m.short end
        VC.log(m.short..' recruited '..e.n..' still here: '..table.concat(names,', '),true)
      end
    end
    return
  end
  local list=VC.recruiters()
  if #list==0 then VC.log('No recruits yet. Village Command reads the guild\'s event log for who invited whom, from when it\'s installed.',true); return end
  VC.log('Top recruiters (guildmates still here who joined on their invite):',true)
  for i=1,math.min(10,#list) do
    local e=list[i]
    VC.log(string.format('   %d. %s  %d%s',i,e.name,e.n,e.month>0 and ('  (+'..e.month..' this month)') or ''),true)
  end
end

-- Sharing -----------------------------------------------------------------------------------------
-- Guildmates compare a fingerprint of who invited whom (times left out: they're only accurate to the
-- hour), and send their list when it differs: I|H|version|digest, then I|B, I|D|pieces..., I|Z|digest.
local function shared()
  local r=VC.recruitData()
  local list={}
  if not r then return list end
  for who,rec in pairs(r.by) do if VC.byId[who] then list[#list+1]={who=who,rec=rec} end end
  table.sort(list,function(a,b) return a.who<b.who end)
  return list
end
function VC.recruitDigest()
  local h=5381
  local n=0
  for _,x in ipairs(shared()) do
    local key=x.who..'>'..(x.rec.by or '')
    for i=1,#key do h=(h*33+key:byte(i))%4294967296 end
    n=n+1
  end
  return T(h)..'.'..n
end
function VC.recruitHello()
  if not (VC.syncOn() and VC.recruitData() and #VC.roster>0) then return end
  VC.recruitSync.helloAt=now()
  send('I|H|'..RECRUIT_VERSION..'|'..VC.recruitDigest())
end
function VC.sendRecruits()
  local sy=VC.recruitSync
  send('I|B')
  local line=''
  for _,x in ipairs(shared()) do
    local rec=x.rec
    local piece=x.who..'~'..(rec.by or '')..'~'..plain(rec.bn)..'~'..T(rec.t)
    if #line>0 and #line+#piece+1>236 then send('I|D|'..line); line='' end
    line=(#line>0) and (line..';'..piece) or piece
  end
  if #line>0 then send('I|D|'..line) end
  send('I|Z|'..VC.recruitDigest())
  sy.lastDump=now()
end
-- Taken on its word from a trusted rank; from anyone else once a second guildmate sends the same.
function VC.mergeRecruit(piece,senderId)
  local who,by,bn,t=piece:match('^([^~]+)~([^~]*)~([^~]*)~(%w+)$')
  t=F(t)
  local m=who and VC.byId[who]
  if not (m and sane(t)) then return false end
  if by=='' then by,bn=nil,nil end
  if by and VC.nameId(bn)~=by then return false end
  local r=VC.recruitData()
  local old=r and r.by[who]
  if not r then return false end
  -- Already what we have.
  if old and (old.by or '')==(by or '') and math.abs(old.t-t)<SAME then return false end
  if old and t<old.t-SAME then return false end
  if not VC.trusted(senderId) then
    local sy=VC.recruitSync
    local key=who..'>'..(by or '')
    local p=sy.pending[who]
    if not (p and p.key==key and p.sender~=senderId) then
      sy.pending[who]={key=key,sender=senderId}
      sy.rejected=sy.rejected+1
      return false
    end
    sy.pending[who]=nil
  end
  return VC.setRecruit(who,m.short,by,bn,t,'sync')
end
function VC.recruitMessage(rest,senderId)
  local sy=VC.recruitSync
  local kind,body=(rest or ''):match('^(%a)|?(.*)$')
  if not kind then return end
  sy.received=sy.received+1
  if kind=='D' then
    local changed=false
    for piece in body:gmatch('[^;]+') do
      local ok,did=pcall(VC.mergeRecruit,piece,senderId)
      if ok and did then changed=true; sy.merged=sy.merged+1 end
    end
    if changed then VC.requestRedraw() end
  elseif kind=='H' then
    local version,theirs=body:match('^([^|]*)|(.*)$')
    if version~=RECRUIT_VERSION or theirs==VC.recruitDigest() or now()-sy.lastDump<60 then return end
    -- Trusted ranks answer first: their copy is taken on its word, anyone else's needs a second guildmate's.
    later(VC.trusted(VC.myId()) and (1+math.random()*3) or (6+math.random()*6),function()
      if now()-sy.lastBegin<20 or now()-sy.lastDump<60 then return end
      VC.sendRecruits()
    end)
  elseif kind=='B' then
    sy.lastBegin=now()
  elseif kind=='Z' then
    -- A member's list waits for a second guildmate to vouch for it: ask again, once, a little later.
    if not VC.trusted(senderId) and next(sy.pending) and not sy.askedAgain and sy.helloAt and now()-sy.helloAt<300 then
      sy.askedAgain=true
      later(25,function() VC.recruitSync.lastDump=0; VC.recruitHello() end)
    end
    -- Theirs has arrived; if ours still differs we hold something they don't. Send it back, once.
    local mine=VC.recruitDigest()
    local last=sy.dumpsTo[senderId]
    if body~=mine and sy.helloAt and now()-sy.helloAt<300 and not (last and last.digest==mine and now()-last.at<600) and now()-sy.lastDump>30 then
      sy.dumpsTo[senderId]={digest=mine,at=now()}
      later(1+math.random()*3,VC.sendRecruits)
    end
  end
end

-- Timing ------------------------------------------------------------------------------------------
function VC.recruitLogin()
  later(14,VC.queryGuildLog)
  later(24,function() VC.readGuildLog(); VC.recruitHello() end)
end
local sinceRead=0
-- Out of combat and instances: ask the server for the log every few minutes (its answer is read on arrival).
function VC.recruitTick(elapsed)
  sinceRead=sinceRead+elapsed
  if sinceRead<READ_EVERY then return end
  sinceRead=0
  VC.queryGuildLog()
end
function VC.recruitStatus()
  local sy=VC.recruitSync
  local r=VC.recruitData()
  local n,known=0,0
  if r then for who,rec in pairs(r.by) do if VC.byId[who] then n=n+1; if rec.by then known=known+1 end end end end
  return string.format('recruits: %d joins recorded (%d with a known inviter); guild log %s, read %d times; %d messages received, %d merged, %d not trusted%s',
    n,known,(GetNumGuildEvents and GetGuildEventInfo) and ((sy.logSize or 0)..' events') or 'not available',sy.reads,sy.received,sy.merged,sy.rejected,
    sy.lastError and ('; last error: '..sy.lastError) or '')
end

local logFrame=CreateFrame('Frame')
pcall(logFrame.RegisterEvent,logFrame,'GUILD_EVENT_LOG_UPDATE')
logFrame:SetScript('OnEvent',function()
  if not VC.ready then return end
  local ok,err=pcall(VC.readGuildLog)
  if not ok then VC.recruitSync.lastError=tostring(err) end
end)
