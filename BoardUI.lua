-- Village Command - the Events and Bounties pages, their dialogs, and the lines they add to the Overview,
-- member tooltips and the minimap tooltip. The data and sharing are in Board.lua.
local _,VC=...
if type(VC)~='table' then VC=VC_NS or {} end
local now,DAY=VC.now,VC.DAY
local ui=VC.ui
local BACKDROP_TEMPLATE=BackdropTemplateMixin and 'BackdropTemplate' or nil

table.insert(VC.tabs,3,{key='events',label='Events',icon='Interface\\Icons\\INV_Misc_Head_Dragon_01',
  sub='Raids, dungeon runs and get-togethers: sign up, see who\'s coming, and who showed up'})
table.insert(VC.tabs,4,{key='bounties',label='Bounties',icon='Interface\\Icons\\INV_Misc_Coin_02',
  sub='Post what you need, hunt what others need, and see who earned the most'})

local function colorFor(id,name)
  local m=VC.byId[id or '']
  if m then return VC.colorName(m) end
  return '|cffc0c0c0'..(name or '?')..'|r'
end
local function plural(n,word,many) return n..' '..(n==1 and word or (many or (word..'s'))) end
local function whisper(id)
  local m=VC.byId[id or '']
  if not m then return end
  local tell=ChatFrame_SendTell or (ChatFrameUtil and ChatFrameUtil.SendTell)
  if tell then tell(m.name) end
end
local function signupLine(ev)
  local s=VC.signupSummary(ev)
  local L=s.lists
  local parts={}
  local roles={}
  if #L.t>0 then roles[#roles+1]=plural(#L.t,'tank') end
  if #L.h>0 then roles[#roles+1]=plural(#L.h,'healer') end
  if #L.d>0 then roles[#roles+1]=#L.d..' damage' end
  parts[#parts+1]='|cff40ff40'..s.coming..(ev.size>0 and ('/'..ev.size) or '')..' coming|r'..(#roles>0 and (': '..table.concat(roles,', ')) or '')
  if #L.m>0 then parts[#parts+1]=#L.m..' maybe' end
  if #L.n>0 then parts[#parts+1]=#L.n..' can\'t' end
  return table.concat(parts,'  ·  '),s
end

-- Events page -------------------------------------------------------------------------------------
function VC.announceEvent(ev)
  local text,s=signupLine(ev)
  text=text:gsub('|c%x%x%x%x%x%x%x%x',''):gsub('|r','')
  local line='[Village Command] '..ev.title..', '..VC.whenText(ev.t)..', led by '..ev.bn..'. '..text..'. Sign up: /vc events'
  local say=(C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  if say then say(line:sub(1,250),'GUILD') end
end
function VC.drawEvent(ev)
  local kind=VC.EVENT_KIND[ev.kind] or VC.EVENT_KIND.other
  local closed=VC.eventClosed(ev)
  local heading=ev.x and ('|cff909090'..kind.label..': '..ev.title..'  (cancelled)|r') or ('|cffffd100'..kind.label..':|r '..ev.title)
  VC.section(heading,VC.whenText(ev.t)..'  ·  '..VC.untilText(ev.t))
  local summary,s=signupLine(ev)
  VC.line('Led by '..colorFor(ev.by,ev.bn)..'  ·  '..summary,ev.note~='' and ('|cffa0a0a0'..ev.note..'|r') or '',{icon=kind.icon})
  if ev.x then
    VC.note('|cffff6060Cancelled'..((ev.ed and ev.ed~=ev.bn) and (' by '..ev.ed) or '')..'.|r')
    return
  end
  -- Your answer: five buttons, yours marked.
  local mine=VC.mySignup(ev)
  if not closed then
    local buttons={}
    for _,a in ipairs(VC.SIGNUPS) do
      buttons[#buttons+1]={label=(mine==a.key) and ('|cff40ff40'..a.label..' (you)|r') or a.label,func=function() VC.signUp(ev.id,a.key) end,
        tip=a.coming and ('Sign up as '..a.label:lower()..'.') or (a.key=='m' and 'Not sure yet: you\'re listed as maybe.' or 'Let the leader know you won\'t make it.')}
    end
    VC.buttons(buttons)
  end
  for _,a in ipairs(VC.SIGNUPS) do
    local list=s.lists[a.key]
    if #list>0 then
      local names={}
      for _,e in ipairs(list) do names[#names+1]=colorFor(e.id,e.n) end
      VC.note('|cffffd100'..a.plural..' ('..#list..'):|r  '..table.concat(names,', '))
    end
  end
  -- Classes among those coming, so a raid leader sees what's missing at a glance.
  if s.coming>0 then
    local classes,order={},{}
    for _,a in ipairs(VC.SIGNUPS) do
      if a.coming then for _,e in ipairs(s.lists[a.key]) do
        local m=e.m
        if m and m.class~='' then
          if not classes[m.class] then classes[m.class]={n=0,file=m.classFile}; order[#order+1]=m.class end
          classes[m.class].n=classes[m.class].n+1
        end
      end end
    end
    table.sort(order,function(a,c) if classes[a].n~=classes[c].n then return classes[a].n>classes[c].n end return a<c end)
    local parts={}
    for _,c in ipairs(order) do
      local r,g,b=VC.classColor(classes[c].file)
      parts[#parts+1]=string.format('|cff%02x%02x%02x%d %s|r',r*255,g*255,b*255,classes[c].n,c)
    end
    if #parts>0 then VC.note('|cffa0a0a0Classes:|r  '..table.concat(parts,', ')) end
  end
  local att=VC.attendanceCount(ev)
  if att>0 then
    local names={}
    for id,name in pairs(ev.att) do names[#names+1]=colorFor(id,name) end
    table.sort(names)
    VC.note('|cff40ff40Attended ('..att..'):|r  '..table.concat(names,', '))
  end
  local leader={}
  if VC.canManage(ev) then
    leader[#leader+1]={label='Edit',func=function() VC.openEventDialog(ev.id) end}
    leader[#leader+1]={label='Cancel event',func=function()
      VC.ask('Cancel '..ev.title..' ('..VC.whenText(ev.t)..')?\n\nEveryone signed up sees it\'s off.',function() VC.cancelEvent(ev.id) end)
    end}
    leader[#leader+1]={label='Take attendance',disabled=not VC.inGroup(),func=function() VC.takeAttendance(ev.id) end,
      tip=VC.inGroup() and 'Adds everyone from the guild in your group to who attended. You can take it more than once; nobody is taken off.'
        or 'Join a group or raid with the people who came first. Village Command also takes it on its own 15 minutes after the start, if you\'re the leader and in a group.'}
    leader[#leader+1]={label='Announce in guild',disabled=closed,func=function() VC.announceEvent(ev) end,tip='Posts one line about this event in guild chat.'}
  elseif not closed and ev.by~=VC.myId() then
    leader[#leader+1]={label='Whisper '..(ev.bn or 'leader'),func=function() whisper(ev.by) end}
  end
  if #leader>0 then VC.buttons(leader) end
end
VC.pages.events=function()
  local db=VillageCommandDB.ui
  local upcoming=VC.upcomingEvents()
  local room,limit=VC.boardRoomFor('ev')
  VC.note('Plan a raid, dungeon run or get-together and guildmates running Village Command sign up as tank, healer or damage. Reminders come 15 minutes before. The leader\'s attendance (taken from their group) builds the Regulars list.')
  VC.buttons({
    {label='New event',disabled=not room,func=function() VC.openEventDialog() end,
      tip=room and 'Name, type, day and time, how many you need, and a note.' or ('You already have '..limit..' upcoming events.')},
    {label=db.pastEvents and 'Hide past events' or 'Show past events',func=function() db.pastEvents=not db.pastEvents; VC.requestRedraw() end},
  })
  if #upcoming==0 then
    VC.section('Nothing planned yet')
    VC.note('|cff909090Click New event to plan one. Everyone in the guild running Village Command sees it, even if they log in later.|r')
  end
  for _,ev in ipairs(upcoming) do VC.drawEvent(ev) end
  local stats,total=VC.attendanceStats(60)
  if total>0 then
    VC.section('Regulars',plural(total,'event')..' with attendance in the last 60 days')
    VC.resetStripe()
    for i=1,math.min(10,#stats) do
      local e=stats[i]
      VC.bar(colorFor(e.id,e.name),e.n,total,e.n..' of '..total,{.35,.75,.35},nil,math.floor(e.n/total*100+.5)..'%',
        VC.byId[e.id] and function(self) VC.memberTooltip(self,VC.byId[e.id]) end or nil)
    end
  end
  if db.pastEvents then
    local past=VC.pastEvents(30)
    VC.section('Past events',#past>0 and 'last 30 days' or '')
    VC.resetStripe()
    if #past==0 then VC.note('|cff909090None in the last 30 days.|r') end
    for _,ev in ipairs(past) do
      local kind=VC.EVENT_KIND[ev.kind] or VC.EVENT_KIND.other
      local att=VC.attendanceCount(ev)
      local s=VC.signupSummary(ev)
      VC.line('|cffffd100'..ev.title..'|r  |cff909090'..(date and date('%a %d %b %H:%M',ev.t) or '')..', led by '..ev.bn..'|r',
        (att>0 and (att..' attended') or 'no attendance taken')..'  ·  '..s.coming..' signed up',
        {icon=kind.icon,onEnter=function(self)
          GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
          GameTooltip:AddLine(ev.title,1,.82,0)
          GameTooltip:AddLine((date and date('%A %d %B, %H:%M',ev.t) or '')..', led by '..ev.bn,1,1,1)
          local names={}
          for id,name in pairs(ev.att or {}) do names[#names+1]=(VC.byId[id] and VC.byId[id].short) or name end
          table.sort(names)
          if #names>0 then GameTooltip:AddLine('Attended: '..table.concat(names,', '),.7,1,.7,true) end
          if att==0 and VC.canManage(ev) then GameTooltip:AddLine('Click to take attendance from your group now.',.7,.7,.7) end
          GameTooltip:Show()
        end,onClick=function() if VC.canManage(ev) and VC.inGroup() then VC.takeAttendance(ev.id) end end})
    end
  end
end

-- Bounties page -----------------------------------------------------------------------------------
local function bountyLabel(bo)
  local _,link=VC.itemName(bo.item)
  local text=link or ('|cffffd100'..bo.title..'|r')
  return (bo.qty>1 and (bo.qty..' x ') or '')..text
end
function VC.creditMenu(anchor,bo)
  local items={}
  for _,h in ipairs(VC.bountyHunts(bo)) do
    items[#items+1]={text=h.n..(h.st=='sent' and '  (sent)' or ''),func=function() VC.closeBounty(bo.id,true,h.n) end}
  end
  items[#items+1]={text='Someone not listed: done, no name',func=function() VC.closeBounty(bo.id,true,'') end}
  VC.showMenu(anchor,items)
end
function VC.drawBounty(bo)
  local reward=(bo.reward or 0)>0 and ('|cffffd100'..VC.money(bo.reward)..'|r') or '|cff909090no reward|r'
  VC.section(bountyLabel(bo),reward..'  ·  ends '..VC.untilText(bo.exp)..'  ·  posted by '..bo.bn)
  local itemName,link,icon
  if bo.item>0 then
    itemName,link=VC.itemName(bo.item)
    icon=VC.itemIcon(bo.item)
    local have=VC.itemCount(bo.item)
    VC.line((link or bo.title)..(bo.qty>1 and ('  x'..bo.qty) or ''),'You have '..have,{icon=icon or 'Interface\\Icons\\INV_Misc_QuestionMark',onEnter=function(self)
      GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
      GameTooltip:SetHyperlink('item:'..bo.item)
      GameTooltip:Show()
    end})
  end
  if bo.note~='' then VC.note('|cffa0a0a0'..bo.note..'|r') end
  local hunts=VC.bountyHunts(bo)
  if #hunts>0 then
    local parts={}
    for _,h in ipairs(hunts) do
      local extra=h.st=='sent' and ' |cff40ff40(sent)|r' or ((bo.item>0 and (h.have or 0)>0) and (' |cffa0a0a0'..math.min(h.have,bo.qty)..'/'..bo.qty..'|r') or '')
      parts[#parts+1]=colorFor(h.id,h.n)..extra
    end
    VC.note('|cffffd100Hunting:|r  '..table.concat(parts,', '))
  end
  local buttons={}
  if VC.canManage(bo) then
    buttons[#buttons+1]={label='Done...',func=function(self) VC.creditMenu(self,bo) end,tip='Mark it done and say who earned it. Pay the reward in the game (mail or trade).'}
    buttons[#buttons+1]={label='Edit',disabled=bo.by~=VC.myId(),func=function() VC.openBountyDialog(bo.id) end}
    buttons[#buttons+1]={label='Take down',func=function()
      VC.ask('Take down the bounty for '..bo.title..'?',function() VC.closeBounty(bo.id,false) end)
    end}
  end
  if bo.by~=VC.myId() then
    local mine=VC.myHunt(bo)
    if not mine then
      table.insert(buttons,1,{label='I\'m on it',func=function() VC.hunt(bo.id,'on') end,tip='Tell the guild you\'re hunting this. For items, your bag count is shared as you collect.'})
    else
      table.insert(buttons,1,{label=mine.st=='sent' and 'Not sent yet' or 'Mark sent',func=function() VC.hunt(bo.id,mine.st=='sent' and 'on' or 'sent') end,
        tip='Handed it over (mail or trade)? Mark it sent so '..bo.bn..' knows to check.'})
      table.insert(buttons,2,{label='Stop hunting',func=function() VC.hunt(bo.id,'off') end})
    end
    buttons[#buttons+1]={label='Whisper '..bo.bn,func=function() whisper(bo.by) end}
  end
  VC.buttons(buttons)
end
VC.pages.bounties=function()
  local db=VillageCommandDB.ui
  local open=VC.openBounties()
  local me=VC.myId()
  local offered,mineN,hunting=0,0,0
  for _,bo in ipairs(open) do
    offered=offered+(bo.reward or 0)
    if bo.by==me then mineN=mineN+1 end
    if VC.myHunt(bo) then hunting=hunting+1 end
  end
  local hunters=VC.bountyHunters(90)
  VC.cards({
    {value=tostring(#open),label='Open bounties',sub='posted by guildmates'},
    {value=VC.money(offered),label='Rewards offered',sub='paid by the poster in game'},
    {value=tostring(hunting),label='You\'re hunting',sub=hunting>0 and 'shown on each bounty' or 'click I\'m on it'},
    {value=hunters[1] and hunters[1].name or '-',label='Top bounty hunter',sub=hunters[1] and (plural(hunters[1].n,'bounty','bounties')..' in 90 days') or 'nobody yet'},
  })
  local room,limit=VC.boardRoomFor('bo')
  VC.buttons({
    {label='Post a bounty',disabled=not room,func=function() VC.openBountyDialog() end,
      tip=room and 'What you need (type it or shift-click an item), how many, the reward and how long it stays up.' or ('You already have '..limit..' open bounties.')},
    {label=db.finishedBounties and 'Hide finished' or 'Show finished',func=function() db.finishedBounties=not db.finishedBounties; VC.requestRedraw() end},
  })
  if #open==0 then
    VC.section('No open bounties')
    VC.note('|cff909090Need 20 Thorium Bars, a hand with an elite quest, or a rare drop? Post a bounty with a reward and guildmates can take it on.|r')
  end
  for _,bo in ipairs(open) do VC.drawBounty(bo) end
  if #hunters>0 then
    VC.section('Bounty hunters','completed in the last 90 days')
    VC.resetStripe()
    for i=1,math.min(10,#hunters) do
      local h=hunters[i]
      VC.bar(colorFor(VC.nameId(h.name),h.name),h.n,hunters[1].n,plural(h.n,'bounty','bounties'),{.95,.75,.25},nil,h.gold>0 and VC.money(h.gold) or '')
    end
  end
  if db.finishedBounties then
    local done=VC.closedBounties(30)
    VC.section('Finished','last 30 days')
    VC.resetStripe()
    if #done==0 then VC.note('|cff909090None in the last 30 days.|r') end
    for _,bo in ipairs(done) do
      local what=bo.st=='d' and ((bo.done and bo.done~='') and ('|cff40ff40Earned by '..bo.done..'|r') or '|cff40ff40Done|r')
        or (bo.st=='x' and '|cff909090Taken down|r' or '|cff909090Ran out of time|r')
      VC.line(bountyLabel(bo)..'  |cff909090for '..bo.bn..'|r',what..'  ·  '..VC.agoText(now()-bo.u),
        {icon=VC.itemIcon(bo.item) or 'Interface\\Icons\\INV_Misc_Coin_02'})
    end
  end
end

-- Dialogs -----------------------------------------------------------------------------------------
local function dialog(name,w,h,title)
  local d=CreateFrame('Frame',name,UIParent,BACKDROP_TEMPLATE)
  d:SetSize(w,h); d:SetPoint('CENTER',0,60); d:SetFrameStrata('FULLSCREEN_DIALOG'); d:EnableMouse(true); d:SetClampedToScreen(true)
  d:SetMovable(true); d:RegisterForDrag('LeftButton'); d:SetScript('OnDragStart',d.StartMoving); d:SetScript('OnDragStop',d.StopMovingOrSizing)
  if d.SetBackdrop then
    d:SetBackdrop({bgFile='Interface\\DialogFrame\\UI-DialogBox-Background',edgeFile='Interface\\DialogFrame\\UI-DialogBox-Border',tile=true,tileSize=32,edgeSize=32,insets={left=11,right=12,top=12,bottom=11}})
  end
  -- The dialog backdrop is see-through; a solid backing keeps the page behind from showing through.
  local backing=d:CreateTexture(nil,'BACKGROUND',nil,1)
  backing:SetPoint('TOPLEFT',12,-12); backing:SetPoint('BOTTOMRIGHT',-12,12); backing:SetColorTexture(.07,.05,.035,.96)
  VC.closeOnEscape(d,3)
  d.title=ui.fontString(d,'GameFontNormal','CENTER'); d.title:SetPoint('TOP',0,-18)
  d.y=-46
  function d.label(text)
    local l=ui.fontString(d,'GameFontHighlightSmall','RIGHT'); l:SetPoint('TOPLEFT',20,d.y-4); l:SetWidth(110); l:SetText(text)
    return l
  end
  function d.box(width,placeholder,maxLetters,numeric)
    local e=ui.editBox(d,width,placeholder)
    e:SetPoint('TOPLEFT',144,d.y); e:SetMaxLetters(maxLetters or 40)
    if numeric and e.SetNumeric then e:SetNumeric(true) end
    e:SetScript('OnTextChanged',function(self) self.syncPlaceholder(self) end)
    e:SetScript('OnEnterPressed',function(self) self:ClearFocus() end)
    return e
  end
  function d.menuButton(width,x)
    local b=ui.smallButton(d,'',width,22); b:SetPoint('TOPLEFT',x or 140,d.y)
    return b
  end
  d.error=ui.fontString(d,'GameFontHighlightSmall','CENTER'); d.error:SetPoint('BOTTOM',0,48); d.error:SetWidth(w-40)
  d.save=ui.smallButton(d,SAVE or 'Save',100,22); d.save:SetPoint('BOTTOMRIGHT',d,'BOTTOM',-6,20)
  d.cancel=ui.smallButton(d,CANCEL or 'Cancel',100,22); d.cancel:SetPoint('BOTTOMLEFT',d,'BOTTOM',6,20)
  d.cancel:SetScript('OnClick',function() d:Hide() end)
  d:HookScript('OnHide',VC.hideMenu)
  d:Hide()
  return d
end
VC.makeDialog=dialog

-- The day at midnight, `offset` days from today.
local function dayStart(offset)
  local t=date('*t',now()+(offset or 0)*DAY)
  t.hour,t.min,t.sec=0,0,0
  return time(t)
end
local function atTime(day,hour,minute)
  local t=date('*t',day+12*3600)
  t.hour,t.min,t.sec=hour,minute,0
  return time(t)
end
function VC.openEventDialog(id)
  local d=VC.eventDialog
  if not d then
    d=dialog('VillageCommandEventDialog',400,330)
    VC.eventDialog=d
    d.label('Name'); d.name=d.box(220,'e.g. Molten Core',40); d.y=d.y-30
    d.label('Type'); d.kind=d.menuButton(150); d.y=d.y-30
    d.kind:SetScript('OnClick',function(self)
      local items={}
      for _,k in ipairs(VC.EVENT_KINDS) do items[#items+1]={text=k.label,func=function() d.spec.kind=k.key; d.refresh() end} end
      VC.showMenu(self,items)
    end)
    d.label('Day'); d.day=d.menuButton(150); d.y=d.y-30
    d.day:SetScript('OnClick',function(self)
      local items={}
      for i=0,20 do
        local day=dayStart(i)
        items[#items+1]={text=(i==0 and 'Today' or i==1 and 'Tomorrow' or date('%A',day))..date(' %d %b',day),func=function() d.spec.day=day; d.refresh() end}
      end
      VC.showMenu(self,items)
    end)
    d.label('Time'); d.hour=d.menuButton(70); d.minute=d.menuButton(70,214); d.y=d.y-30
    d.hour:SetScript('OnClick',function(self)
      local items={}
      for h=0,23 do items[#items+1]={text=string.format('%02d',h),func=function() d.spec.hour=h; d.refresh() end} end
      VC.showMenu(self,items)
    end)
    d.minute:SetScript('OnClick',function(self)
      local items={}
      for _,m in ipairs({0,15,30,45}) do items[#items+1]={text=string.format(':%02d',m),func=function() d.spec.minute=m; d.refresh() end} end
      VC.showMenu(self,items)
    end)
    d.label('Players wanted'); d.size=d.box(50,'any',2,true); d.y=d.y-30
    d.label('Note'); d.note=d.box(220,'optional: "bring fire resist"',90); d.y=d.y-30
    d.when=ui.fontString(d,'GameFontDisableSmall','CENTER'); d.when:SetPoint('TOP',0,d.y-2); d.when:SetWidth(360)
    function d.refresh()
      local sp=d.spec
      d.kind:SetText((VC.EVENT_KIND[sp.kind] or VC.EVENT_KIND.other).label)
      local offset=math.floor((sp.day-dayStart(0))/DAY+.5)
      d.day:SetText((offset==0 and 'Today' or offset==1 and 'Tomorrow' or date('%A',sp.day))..date(' %d %b',sp.day))
      d.hour:SetText(string.format('%02d',sp.hour)); d.minute:SetText(string.format(':%02d',sp.minute))
      local t=atTime(sp.day,sp.hour,sp.minute)
      d.when:SetText('Starts '..VC.whenText(t)..' your time ('..VC.untilText(t)..'). Guildmates see it in their own time.')
      d.error:SetText('')
    end
    d.save:SetScript('OnClick',function()
      local sp=d.spec
      local ev,why=VC.saveEvent({id=sp.id,title=d.name:GetText(),kind=sp.kind,t=atTime(sp.day,sp.hour,sp.minute),size=d.size:GetText(),note=d.note:GetText()})
      if ev then d:Hide() else d.error:SetText('|cffff6060'..(why or 'Couldn\'t save that.')..'|r') end
    end)
  end
  local b=VC.boardData()
  local ev=id and b and b.ev[id]
  if ev then
    local t=date('*t',ev.t)
    local day=date('*t',ev.t); day.hour,day.min,day.sec=0,0,0
    d.spec={id=ev.id,kind=ev.kind,day=time(day),hour=t.hour,minute=t.min}
    d.name:SetText(ev.title); d.size:SetText(ev.size>0 and tostring(ev.size) or ''); d.note:SetText(ev.note or '')
    d.title:SetText('Edit event')
  else
    d.spec={kind='raid',day=dayStart(1),hour=20,minute=0}
    d.name:SetText(''); d.size:SetText(''); d.note:SetText('')
    d.title:SetText('New event')
  end
  for _,e in ipairs({d.name,d.size,d.note}) do e.syncPlaceholder(e) end
  d:Show()
  d.refresh()
end

local DURATIONS={3,7,14,30}
function VC.openBountyDialog(id)
  local d=VC.bountyDialog
  if not d then
    d=dialog('VillageCommandBountyDialog',420,300)
    VC.bountyDialog=d
    d.label('Wanted'); d.what=d.box(240,'Type it, or shift-click an item',120); d.y=d.y-30
    d.label('How many'); d.qty=d.box(50,'1',4,true); d.y=d.y-30
    d.label('Reward'); d.gold=d.box(60,'gold',5,true)
    d.silver=d.box(40,'silver',2,true); d.silver:ClearAllPoints(); d.silver:SetPoint('LEFT',d.gold,'RIGHT',12,0); d.y=d.y-30
    d.label('Stays up'); d.days=d.menuButton(120); d.y=d.y-30
    d.days:SetScript('OnClick',function(self)
      local items={}
      for _,n in ipairs(DURATIONS) do items[#items+1]={text=n..' days',func=function() d.spec.days=n; d.refresh() end} end
      VC.showMenu(self,items)
    end)
    d.label('Note'); d.note=d.box(240,'optional: "mail to me", "can trade in Org"',90); d.y=d.y-30
    d.hint=ui.fontString(d,'GameFontDisableSmall','CENTER'); d.hint:SetPoint('TOP',0,d.y-2); d.hint:SetWidth(380)
    d.hint:SetText('Addons can\'t hold gold: you pay the reward in the game when it\'s done.')
    function d.refresh()
      d.days:SetText(d.spec.days and (d.spec.days..' days') or 'as it is')
      d.error:SetText('')
    end
    d.save:SetScript('OnClick',function()
      local reward=(tonumber(d.gold:GetText()) or 0)*10000+(tonumber(d.silver:GetText()) or 0)*100
      local text=d.what:GetText() or ''
      local bo,why=VC.saveBounty({id=d.spec.id,title=text,item=VC.itemIdFrom(text) or d.spec.item,qty=d.qty:GetText(),reward=reward,days=d.spec.days,note=d.note:GetText()})
      if bo then d:Hide() else d.error:SetText('|cffff6060'..(why or 'Couldn\'t save that.')..'|r') end
    end)
    -- Shift-clicking an item while "Wanted" has focus puts its link there.
    local function insert(link)
      if d:IsShown() and d.what:HasFocus() and type(link)=='string' and link:find('|Hitem:',1,true) then d.what:SetText(link) end
    end
    if hooksecurefunc then
      if ChatEdit_InsertLink then hooksecurefunc('ChatEdit_InsertLink',insert) end
      if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil,'InsertLink',insert) end
    end
  end
  local b=VC.boardData()
  local bo=id and b and b.bo[id]
  if bo then
    d.spec={id=bo.id,item=bo.item}
    local _,link=VC.itemName(bo.item)
    d.what:SetText(link or bo.title); d.qty:SetText(tostring(bo.qty)); d.note:SetText(bo.note or '')
    d.gold:SetText((bo.reward or 0)>=10000 and tostring(math.floor(bo.reward/10000)) or '')
    d.silver:SetText((bo.reward or 0)%10000>=100 and tostring(math.floor((bo.reward%10000)/100)) or '')
    d.title:SetText('Edit bounty')
  else
    d.spec={days=7}
    for _,e in ipairs({d.what,d.qty,d.gold,d.silver,d.note}) do e:SetText('') end
    d.title:SetText('Post a bounty')
  end
  for _,e in ipairs({d.what,d.qty,d.gold,d.silver,d.note}) do e.syncPlaceholder(e) end
  d:Show()
  d.refresh()
end

-- Lines for other pages and tooltips --------------------------------------------------------------
function VC.boardOverview()
  local upcoming=VC.upcomingEvents()
  local open=VC.openBounties()
  local live={}
  for _,ev in ipairs(upcoming) do if not ev.x then live[#live+1]=ev end end
  VC.section('Coming up',#live>0 and 'click to sign up' or '')
  VC.resetStripe()
  if #live==0 then
    VC.line('|cff909090No events planned. Plan a raid or dungeon run on the Events tab.|r','New event',{icon='Interface\\Icons\\INV_Misc_Head_Dragon_01',onClick=function() VC.selectTab('events') end})
  end
  for i=1,math.min(3,#live) do
    local ev=live[i]
    local kind=VC.EVENT_KIND[ev.kind] or VC.EVENT_KIND.other
    local s=VC.signupSummary(ev)
    local mine=VC.mySignup(ev)
    VC.line('|cffffd100'..ev.title..'|r  '..VC.whenText(ev.t)..'  |cff909090'..VC.untilText(ev.t)..'|r',
      s.coming..(ev.size>0 and ('/'..ev.size) or '')..' coming'..(mine and ('  ·  you: '..VC.SIGNUP[mine].label) or '  ·  |cffffd100not answered|r'),
      {icon=kind.icon,onClick=function() VC.selectTab('events') end})
  end
  if #open>0 then
    local offered=0
    for _,bo in ipairs(open) do offered=offered+(bo.reward or 0) end
    VC.line(plural(#open,'open bounty','open bounties')..(offered>0 and (', '..VC.money(offered)..' in rewards') or ''),'Bounties',
      {icon='Interface\\Icons\\INV_Misc_Coin_02',onClick=function() VC.selectTab('bounties') end})
  end
end
function VC.boardMemberLines(tip,m)
  local b=VC.boardData()
  if not b then return end
  for _,ev in ipairs(VC.upcomingEvents()) do
    local su=not ev.x and ev.su and ev.su[m.id]
    if su and VC.SIGNUP[su.s].coming then
      tip:AddLine('Signed up for '..ev.title..' ('..VC.whenText(ev.t)..') as '..VC.SIGNUP[su.s].label:lower(),.6,.85,1)
      break
    end
  end
  local stats,total=VC.attendanceStats(60)
  if total>0 then
    for _,e in ipairs(stats) do
      if e.id==m.id then tip:AddLine('At '..e.n..' of the guild\'s last '..total..' events (60 days)',.7,.7,.7); break end
    end
  end
end
function VC.boardMinimapLines(tip)
  for _,ev in ipairs(VC.upcomingEvents()) do
    if not ev.x then
      local s=VC.signupSummary(ev)
      tip:AddLine('Next: '..ev.title..', '..VC.whenText(ev.t)..' ('..s.coming..' coming)',.6,.85,1)
      break
    end
  end
  local open=#VC.openBounties()
  if open>0 then tip:AddLine(plural(open,'open bounty','open bounties'),1,.82,0) end
end
