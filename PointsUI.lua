-- Village Command - the Village Points page, its dialogs, /vc points, and the lines it adds to member
-- tooltips. The points themselves, the raid reports and sharing are in Points.lua.
local _,VC=...
if type(VC)~='table' then VC=VC_NS or {} end
local now,DAY=VC.now,VC.DAY
local ui=VC.ui
local function log(s,always) VC.log(s,always) end

table.insert(VC.tabs,5,{key='points',label='Village Points',icon='Interface\\Icons\\INV_Misc_Coin_17',
  sub='Raid points and loot priority: earned by raiding, spent on loot, the same for everyone'})

local function colorFor(id,name)
  local m=VC.byId[id or '']
  if m then return VC.colorName(m) end
  return '|cffc0c0c0'..(name or '?')..'|r'
end
local function plural(n,word,many) return n..' '..(n==1 and word or (many or (word..'s'))) end
local function day(t) return date and date('%a %d %b',t) or '' end

local function historyTooltip(self,s)
  GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
  GameTooltip:AddLine(s.name,1,.82,0)
  GameTooltip:AddDoubleLine('Village Points',VC.fmtPoints(s.vp),1,1,1,.4,1,.4)
  GameTooltip:AddDoubleLine('Loot Points','|cffff9a40'..VC.fmtPoints(s.lp)..'|r  (base '..VC.vpRule('base')..')',1,1,1)
  GameTooltip:AddDoubleLine('Priority',VC.fmtPriority(s.pr),1,1,1,1,.82,0)
  local list=VC.vpHistory(s.id,true)
  if #list>0 then GameTooltip:AddLine(' ') end
  for i=1,math.min(10,#list) do
    local e=list[i]
    local amt=(e.k=='l' and '|cffff9a40' or '|cff40ff40')..((e.k=='v' and e.amt>0) and '+' or '')..e.amt..(e.k=='l' and ' LP' or ' VP')..'|r'
    if e.x then amt='|cff707070'..amt:gsub('|c%x%x%x%x%x%x%x%x',''):gsub('|r','')..' (undone)|r' end
    GameTooltip:AddDoubleLine('|cffa0a0a0'..day(e.t)..'|r  '..(e.why or ''),amt,1,1,1)
  end
  if #list>10 then GameTooltip:AddLine('+'..(#list-10)..' more',.6,.6,.6) end
  GameTooltip:AddLine('Points fade by '..VC.vpRule('decay')..'% a week.',.6,.6,.6)
  GameTooltip:Show()
end
local function raidTooltip(self,r)
  GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
  GameTooltip:AddLine(r.iname~='' and r.iname or 'Raid',1,.82,0)
  GameTooltip:AddLine((date and date('%A %d %B, %H:%M',r.t) or '')..(r.e and r.e>r.t and (' to '..date('%H:%M',r.e)) or ''),1,1,1)
  if r.bosses and #r.bosses>0 then GameTooltip:AddLine('Bosses: '..table.concat(r.bosses,', '),.7,1,.7,true) end
  GameTooltip:AddLine(plural(r.att or 0,'guildmate')..' earned points, from '..plural(r.rep or 0,'report')..'. Settled by '..(r.by or '?')..'.',.8,.8,.8,true)
  if VC.vpOfficer() and r.fl and #r.fl>0 then
    GameTooltip:AddLine(' ')
    GameTooltip:AddLine('Flagged (officers only):',1,.6,.2)
    for _,f in ipairs(r.fl) do GameTooltip:AddLine('· '..f,1,.75,.5,true) end
  end
  GameTooltip:Show()
end

VC.pages.points=function()
  local db=VillageCommandDB.ui
  local officer=VC.vpOfficer()
  local me=VC.myId()
  local mine,place,total=VC.vpStanding(me)
  VC.note('Raiding earns |cff40ff40Village Points|r: '..VC.vpRule('onTime')..' for being on time and '..VC.vpRule('perBoss')..' for each boss kill'
    ..(VC.vpRule('perHour')>0 and (', plus '..VC.vpRule('perHour')..' an hour') or '')..'. Loot costs |cffff9a40Loot Points|r. '
    ..'Priority is Village Points ÷ Loot Points: highest goes first. Both fade '..VC.vpRule('decay')..'% a week. '
    ..'Nothing is sent inside a raid: everyone\'s Village Command keeps notes and compares them once you\'re out.')
  VC.cards({
    {value=mine and VC.fmtPoints(mine.vp) or '0',label='Your Village Points',sub=mine and (plural(mine.raids,'raid')..' in 30 days') or 'raid with the guild to earn some'},
    {value=mine and VC.fmtPoints(mine.lp) or tostring(VC.vpRule('base')),label='Your Loot Points',sub='base '..VC.vpRule('base')..' + loot you\'ve had'},
    {value=mine and VC.fmtPriority(mine.pr) or '-',label='Your priority',sub='Village ÷ Loot Points'},
    {value=place and ('#'..place) or '-',label='Your place',sub=place and ('of '..total..' on the list') or 'not on the list yet'},
  })
  if officer then
    VC.buttons({
      {label='Award loot...',func=function() VC.openAwardDialog() end,tip='Charge Loot Points for an item. Shift-click the item in; the cost is suggested from its item level and slot.'},
      {label='Adjust...',func=function() VC.openAdjustDialog() end,tip='Add or take away Village Points by hand, with a reason everyone can see.'},
      {label='Bench...',func=function() VC.openAdjustDialog('bench') end,tip='Players on standby for the latest raid get the Rules\' bench share of what it earned.'},
      {label='Rules...',func=function() VC.openRulesDialog() end,tip='Points for being on time and each boss, decay, base Loot Points, how many reports settle a raid.'},
      {label='Undo my last',func=function()
        local e,why=VC.vpUndo()
        if not e then log(why or 'Nothing to undo.',true) else log('Undid: '..e.n..' '..e.amt..(e.k=='l' and ' Loot Points' or ' Village Points')..' ('..(e.why or '')..').',true) end
      end,tip='Takes back the newest change you made.'},
    })
    local pending=VC.vpPending()
    if #pending>0 then
      VC.section('|cffff9030Waiting for an officer|r','fewer than '..VC.vpRule('quorum')..' reports and no officer\'s')
      VC.resetStripe()
      for _,g in ipairs(pending) do
        local names={}
        for _,r in ipairs(g.reports) do names[#names+1]=r.fromName or '?' end
        VC.line('|cffffd100'..(g.iname~='' and g.iname or 'Raid')..'|r  |cff909090'..day(g.start)..' '..(date and date('%H:%M',g.start) or '')..'|r',
          'from '..table.concat(names,', ')..'  ·  |cff40ff40click to approve|r',
          {icon='Interface\\Icons\\INV_Misc_Note_01',onClick=function()
            VC.ask('Settle '..(g.iname~='' and g.iname or 'this raid')..' from '..plural(#g.reports,'report')..'?\n\nFewer reports than the Rules ask for, so check the result.',function() VC.vpApprove(g) end)
          end})
      end
    end
  end
  local list=VC.vpStandings()
  VC.section('Standings',#list>0 and ('priority = Village Points ÷ Loot Points  ·  '..VC.vpRule('decay')..'% decay a week') or '')
  VC.resetStripe()
  if #list==0 then
    VC.note('|cff909090Nobody has points yet. Raid together with Village Command running: once you\'re out, an officer\'s Village Command settles the raid and everyone there earns Village Points.|r')
  end
  local shown=db.allStandings and #list or math.min(25,#list)
  for i=1,shown do
    local s=list[i]
    local m=VC.byId[s.id]
    VC.line(string.format('|cffa0a0a0%2d|r  %s',i,colorFor(s.id,s.name))..(s.id==me and '  |cff909090(you)|r' or ''),
      string.format('|cff40ff40%s VP|r  ·  |cffff9a40%s LP|r  ·  |cffffd100%s|r  ·  %s',VC.fmtPoints(s.vp),VC.fmtPoints(s.lp),VC.fmtPriority(s.pr),plural(s.raids,'raid')),
      {online=m and m.online or false,onEnter=function(self) historyTooltip(self,s) end,onClick=officer and function() VC.openAwardDialog(s.name) end or nil})
  end
  if #list>25 then
    VC.buttons({{label=db.allStandings and 'Show top 25' or ('Show all '..#list),func=function() db.allStandings=not db.allStandings; VC.requestRedraw() end}})
  end
  local raids=VC.vpRecentRaids(30)
  if #raids>0 then
    VC.section('Raids','last 30 days, settled from everyone\'s reports')
    VC.resetStripe()
    for i=1,math.min(10,#raids) do
      local r=raids[i]
      local flagged=officer and r.fl and #r.fl>0
      VC.line('|cffffd100'..(r.iname~='' and r.iname or 'Raid')..'|r  |cff909090'..day(r.t)..'|r'..(flagged and '  |cffff9030flagged|r' or ''),
        plural(#(r.bosses or {}),'boss','bosses')..'  ·  '..plural(r.att or 0,'guildmate')..'  ·  '..plural(r.rep or 0,'report'),
        {icon='Interface\\Icons\\INV_Misc_Head_Dragon_01',onEnter=function(self) raidTooltip(self,r) end})
    end
  end
  local loot=VC.vpRecentLoot(10)
  if #loot>0 then
    VC.section('Loot','newest first')
    VC.resetStripe()
    for _,e in ipairs(loot) do
      VC.line(colorFor(e.who,e.n)..'  '..(e.why or ''),'|cffff9a40'..e.amt..' LP|r  ·  '..day(e.t)..'  ·  by '..(e.by or '?'),{icon='Interface\\Icons\\INV_Misc_Bag_10'})
    end
  end
  local renown=VC.renown()
  VC.section('Renown','the guild\'s community score: never used for loot')
  VC.note('|cffa0a0a03 for each event attended (60 days), 5 for each bounty earned (90 days), 1 for each level gained (30 days).|r')
  VC.resetStripe()
  if #renown==0 then VC.note('|cff909090Nobody yet: come to events, take on bounties, level up.|r') end
  for i=1,math.min(10,#renown) do
    local s=renown[i]
    local parts={}
    if s.events>0 then parts[#parts+1]=plural(s.events,'event') end
    if s.bounties>0 then parts[#parts+1]=plural(s.bounties,'bounty','bounties') end
    if s.levels>0 then parts[#parts+1]=plural(s.levels,'level') end
    VC.bar(colorFor(s.id,s.name),s.score,renown[1].score,table.concat(parts,', '),{.55,.7,.95},nil,tostring(s.score))
  end
end

-- Dialogs -----------------------------------------------------------------------------------------
local function focusedBox(d,list)
  for _,e in ipairs(list) do if e:HasFocus() then return e end end
end
local function hookLinks(d,boxes,after)
  local function insert(link)
    if d:IsShown() and type(link)=='string' and link:find('|Hitem:',1,true) then
      local box=focusedBox(d,boxes) or boxes[1]
      box:SetText(link)
      if after then after() end
    end
  end
  if hooksecurefunc then
    if ChatEdit_InsertLink then hooksecurefunc('ChatEdit_InsertLink',insert) end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil,'InsertLink',insert) end
  end
end
function VC.openAwardDialog(name,item)
  local d=VC.awardDialog
  if not d then
    d=VC.makeDialog('VillageCommandAwardDialog',420,250)
    VC.awardDialog=d
    d.title:SetText('Award loot')
    d.label('Who'); d.who=d.box(200,'their name',40); d.y=d.y-30
    d.label('Item'); d.item=d.box(240,'shift-click the item',200); d.y=d.y-30
    d.label('Loot Points'); d.cost=d.box(70,'cost',6,true); d.y=d.y-30
    d.hint=ui.fontString(d,'GameFontDisableSmall','CENTER'); d.hint:SetPoint('TOP',0,d.y-2); d.hint:SetWidth(380)
    function d.suggest()
      local cost=VC.vpCost(d.item:GetText())
      d.hint:SetText(cost and ('Suggested: '..cost..' Loot Points (item level x slot x '..VC.vpRule('scale')..'%).') or 'Type the cost, or shift-click an item for a suggested one.')
      if cost and (d.cost:GetText() or '')=='' then d.cost:SetText(tostring(cost)) end
    end
    d.item:SetScript('OnTextChanged',function(self) self.syncPlaceholder(self); d.suggest() end)
    d.save:SetText('Award')
    d.save:SetScript('OnClick',function()
      local e,why=VC.vpAward(d.who:GetText(),d.item:GetText(),tonumber(d.cost:GetText()))
      if e then
        log(e.n..' gets '..(e.why or 'loot')..' for '..e.amt..' Loot Points.',true)
        d:Hide()
      else d.error:SetText('|cffff6060'..(why or 'Couldn\'t award that.')..'|r') end
    end)
    hookLinks(d,{d.item},d.suggest)
  end
  d.who:SetText(name or ''); d.item:SetText(item or ''); d.cost:SetText('')
  for _,e in ipairs({d.who,d.item,d.cost}) do e.syncPlaceholder(e) end
  d.error:SetText('')
  d:Show()
  d.suggest()
end
function VC.openAdjustDialog(mode)
  local d=VC.adjustDialog
  if not d then
    d=VC.makeDialog('VillageCommandAdjustDialog',420,230)
    VC.adjustDialog=d
    d.label('Who'); d.who=d.box(200,'their name',40); d.y=d.y-30
    d.amountLabel=d.label('Village Points'); d.amount=d.box(70,'e.g. 10 or -5',6); d.y=d.y-30
    d.reasonLabel=d.label('Reason'); d.reason=d.box(240,'everyone can see this',60); d.y=d.y-30
    d.hint=ui.fontString(d,'GameFontDisableSmall','CENTER'); d.hint:SetPoint('TOP',0,d.y-2); d.hint:SetWidth(380)
    d.save:SetScript('OnClick',function()
      local e,why
      if d.mode=='bench' then e,why=VC.vpBench(d.who:GetText())
      else e,why=VC.vpAdjust(d.who:GetText(),tonumber(d.amount:GetText()),d.reason:GetText()) end
      if e then log(e.n..': '..(e.amt>0 and '+' or '')..e.amt..' Village Points ('..(e.why or '')..').',true); d:Hide()
      else d.error:SetText('|cffff6060'..(why or 'Couldn\'t save that.')..'|r') end
    end)
  end
  d.mode=mode
  local bench=mode=='bench'
  local raid=VC.vpRecentRaids(14)[1]
  d.title:SetText(bench and 'Bench' or 'Adjust Village Points')
  for _,w in ipairs({d.amount,d.amountLabel,d.reason,d.reasonLabel}) do w:SetShown(not bench) end
  d.hint:SetText(bench and (raid and ('For '..(raid.iname~='' and raid.iname or 'the raid')..', '..day(raid.t)..': '..VC.vpRule('bench')..'% of what it earned.') or 'No raid in the last two weeks.')
    or 'Shows in their history with your name and the reason.')
  for _,e in ipairs({d.who,d.amount,d.reason}) do e:SetText(''); e.syncPlaceholder(e) end
  d.error:SetText('')
  d:Show()
end
function VC.openRulesDialog()
  local d=VC.rulesDialog
  if not d then
    d=VC.makeDialog('VillageCommandRulesDialog',420,90+#VC.VP_RULES*28)
    VC.rulesDialog=d
    d.title:SetText('Village Points rules')
    d.boxes={}
    for _,r in ipairs(VC.VP_RULES) do
      local l=d.label(r.label)
      local e=d.box(60,tostring(r.default),4,true)
      ui.setTip(e,r.label,r.hint..' ('..r.min..' to '..r.max..', default '..r.default..')')
      d.boxes[r.key]=e
      d.y=d.y-28
    end
    d.save:SetScript('OnClick',function()
      local changed=0
      for _,r in ipairs(VC.VP_RULES) do
        local v=tonumber(d.boxes[r.key]:GetText())
        if v and v~=VC.vpRule(r.key) then
          local ok,why=VC.vpSetRule(r.key,v)
          if not ok then d.error:SetText('|cffff6060'..why..'|r'); return end
          changed=changed+1
        end
      end
      if changed>0 then log('Village Points rules changed; every guildmate\'s standings follow.',true) end
      d:Hide()
    end)
  end
  for _,r in ipairs(VC.VP_RULES) do
    local e=d.boxes[r.key]
    e:SetText(tostring(VC.vpRule(r.key))); e.syncPlaceholder(e)
  end
  d.error:SetText('')
  d:Show()
end

-- Tooltips ----------------------------------------------------------------------------------------
function VC.pointsMemberLines(tip,m)
  local s,place=VC.vpStanding(m.id)
  if s then tip:AddLine(string.format('Village Points %s  ·  Loot Points %s  ·  priority %s (#%d)',VC.fmtPoints(s.vp),VC.fmtPoints(s.lp),VC.fmtPriority(s.pr),place),.55,1,.55) end
end

-- /vc points --------------------------------------------------------------------------------------
-- Splits "Name 25 the reason" (Forever names have a space) into the name, the first number and the rest.
local function nameNumberRest(text)
  local words={}
  for w in (text or ''):gmatch('%S+') do words[#words+1]=w end
  for i,w in ipairs(words) do
    if w:match('^[%+%-]?%d+$') then
      return table.concat(words,' ',1,i-1),tonumber(w),table.concat(words,' ',i+1)
    end
  end
  return table.concat(words,' '),nil,''
end
VC.vpParse=nameNumberRest
local HELP='/vc points opens the page. me (or a name): your standing. Officers: award Name [item] [cost]; add Name 10 reason (or -10); bench Name; undo; cost [item]; rules; set rule value; approve.'
function VC.pointsCommand(arg)
  local sub,rest=(arg or ''):match('^%s*(%S*)%s*(.-)%s*$')
  sub=(sub or ''):lower()
  local function say(e,why,fmt)
    if e then log(fmt(e),true) else log(why or 'Couldn\'t do that.',true) end
  end
  if sub=='' then VC.open('points')
  elseif sub=='help' then log(HELP,true)
  elseif sub=='award' or sub=='loot' then
    local link=rest:match('|c%x+|Hitem:.-|h|r') or rest:match('|Hitem:.-|h')
    local text=link and rest:gsub(link:gsub('%p','%%%0'),' ') or rest
    local name,cost=nameNumberRest(text)
    local e,why=VC.vpAward(name,link,cost)
    say(e,why,function(x) return x.n..' gets '..(x.why or 'loot')..' for '..x.amt..' Loot Points.' end)
  elseif sub=='add' or sub=='adjust' then
    local name,amt,why=nameNumberRest(rest)
    local e,err=VC.vpAdjust(name,amt,why)
    say(e,err,function(x) return x.n..': '..(x.amt>0 and '+' or '')..x.amt..' Village Points ('..x.why..').' end)
  elseif sub=='bench' then
    local e,why=VC.vpBench(rest)
    say(e,why,function(x) return x.n..': +'..x.amt..' Village Points ('..x.why..').' end)
  elseif sub=='undo' then
    local e,why=VC.vpUndo()
    say(e,why,function(x) return 'Undid: '..x.n..' '..x.amt..(x.k=='l' and ' Loot Points' or ' Village Points')..' ('..(x.why or '')..').' end)
  elseif sub=='cost' then
    local cost,name=VC.vpCost(rest)
    log(cost and ((name or 'That item')..': '..cost..' Loot Points suggested.') or 'No item level for that: shift-click an item after /vc points cost.',true)
  elseif sub=='rules' then
    local parts={}
    for _,r in ipairs(VC.VP_RULES) do parts[#parts+1]=r.key..' '..VC.vpRule(r.key) end
    local p=VC.vpData()
    log('Village Points rules: '..table.concat(parts,', ')..((p and p.rules.by) and (' (last changed by '..p.rules.by..')') or ' (defaults)')..'. Officers: /vc points set perBoss 20',true)
  elseif sub=='set' then
    local key,value=rest:match('^(%S+)%s+(%S+)$')
    local found
    for _,r in ipairs(VC.VP_RULES) do if key and r.key:lower()==key:lower() then found=r.key end end
    local v,why=VC.vpSetRule(found or key,value)
    if v then log('Village Points rule '..found..' is now '..v..'.',true) else log(why,true) end
  elseif sub=='approve' then
    local pending=VC.vpPending()
    if #pending==0 then log('No raids are waiting for an officer.',true) end
    for _,g in ipairs(pending) do VC.vpApprove(g) end
  else
    local name
    if sub~='me' then name=(arg or ''):gsub('^%s+',''):gsub('%s+$','') end
    local id=name and VC.nameId(name) or VC.myId()
    local s,place,total=VC.vpStanding(id)
    if s then log(string.format('%s: %s Village Points, %s Loot Points, priority %s (#%d of %d).',s.name,VC.fmtPoints(s.vp),VC.fmtPoints(s.lp),VC.fmtPriority(s.pr),place,total),true)
    elseif name and not (id and VC.byId[id]) then log('Nobody called '..name..' in the guild. '..HELP,true)
    else log((name or 'You')..' has no Village Points yet.',true) end
  end
end
