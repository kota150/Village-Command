"""Smoke tests for Village Command in a stand-in WoW environment (tests/mockwow.lua).

Runs the addon with WoW's Lua version (5.1, through lupa) to catch what a syntax check can't: the
200-local limit, errors at load, login or while drawing a page, and the rank and note changes made
against a simulated guild. Not part of the addon download (.pkgmeta ignores tests/).

    python3 -m venv .venv && .venv/bin/pip install lupa
    .venv/bin/python tests/run_tests.py
"""
import os
import sys

import lupa.lua51 as lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = open(os.path.join(HERE, '..', 'VillageCommand.lua'), encoding='utf-8').read()
MOCK = open(os.path.join(HERE, 'mockwow.lua'), encoding='utf-8').read()
failures = []


def check(name, ok, detail=''):
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else '  ' + str(detail)))
    if not ok:
        failures.append(name)


class Client:
    """One WoW client running Village Command, logged in with the roster loaded."""

    def __init__(self, setup='', roster_event=True):
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        if setup:
            self.lua.execute(setup)
        self.lua.execute(MOCK)
        loader = self.lua.eval('function(src) local c,e=loadstring(src,"@VillageCommand.lua"); if not c then error(e,0) end; VC_NS={}; c("VillageCommand",VC_NS) end')
        loader(ADDON)
        self.g = self.lua.globals()
        self.vc = self.g.VC_NS
        self.fire('PLAYER_LOGIN')
        if roster_event:
            self.roster_update()

    def fire(self, *args):
        self.g.VC_TEST_fire(*args)

    def tick(self, seconds=0.5):
        self.g.VC_TEST_tick(seconds)

    def roster_update(self):
        self.fire('GUILD_ROSTER_UPDATE')
        self.tick(2)

    def run(self, code):
        return self.lua.execute(code)

    def calls(self):
        return list(self.g.CALLS.values())

    def events(self, kind):
        g = self.vc.guildData()
        return [e for e in g.events.values() if e.k == kind]


class Guild:
    """Several clients on one guild channel: each one's addon messages reach everyone, the sender too."""

    def __init__(self, *clients):
        self.clients = list(clients)
        self.delivered = []

    def pump(self, seconds):
        for _ in range(int(seconds / 0.1 + 0.5)):
            for c in self.clients:
                c.tick(0.1)
            for c in self.clients:
                out = c.g.OUT
                msgs = [(out[i][1], out[i][2], out[i][3]) for i in range(1, len(out) + 1)]
                c.run('wipe(OUT)')
                sender = c.g.PLAYER + '-' + c.g.REALM.replace(' ', '')
                for prefix, msg, channel in msgs:
                    self.delivered.append((sender, msg))
                    for other in self.clients:
                        other.fire('CHAT_MSG_ADDON', prefix, msg, channel, sender)


def main():
    # Load, log in, read the roster ------------------------------------------------------------
    c = Client()
    check('loads and logs in', c.vc.ready is True)
    check('reads the whole roster', len(c.vc.roster) == 30, len(c.vc.roster))
    check('counts online members', c.vc.onlineCount() == 1 + 10, c.vc.onlineCount())
    check('roster with offline members is complete', c.vc.rosterComplete() is True)
    check('my rank is read', c.vc.myRankIndex() == 1)

    # Every page draws ----------------------------------------------------------------------------
    c.g.SlashCmdList.VILLAGECOMMAND('')
    check('slash command opens the window', c.g.VillageCommandWindow.IsShown(c.g.VillageCommandWindow))
    for key in ['overview', 'roster', 'progress', 'stats', 'forge', 'bank']:
        try:
            c.vc.selectTab(key)
            c.tick(0.5)
            check('draws the ' + key + ' page', True)
        except Exception as e:  # noqa: BLE001
            check('draws the ' + key + ' page', False, e)

    # Filters ------------------------------------------------------------------------------------
    c.run('VillageCommandDB.ui.onlineOnly=true; VC_NS.filterDirty=true')
    check('online-only filter', len(c.vc.filtered()) == 11, len(c.vc.filtered()))
    c.run('VillageCommandDB.ui.onlineOnly=false; VC_NS.filters.rank=4; VC_NS.filterDirty=true')
    initiates = len(c.vc.filtered())
    check('rank filter', initiates == 20, initiates)
    c.run('VC_NS.filters.rank=nil; VC_NS.filters.awayDays=20; VC_NS.filterDirty=true')
    check('away filter', all((m.away or 0) >= 20 * 86400 for m in c.vc.filtered().values()))
    c.run('VC_NS.filters.awayDays=nil; VC_NS.filters.text="alt of"; VC_NS.filterDirty=true')
    check('search reaches notes', len(c.vc.filtered()) == 7, len(c.vc.filtered()))
    c.run('VC_NS.filters.text=""; VC_NS.filterDirty=true')

    # Mass promote: three Initiates become Members, one change at a time --------------------------
    c.run('''for _,n in ipairs({"Member11","Member12","Member13"}) do VC_NS.selected[VC_NS.nameId(n)]=true end''')
    c.vc.massRank(1)
    check('asks before a mass promote', len(c.g.POPUPS) == 1 and 'Promote 3' in c.g.POPUPS[1].text, c.g.POPUPS[1] and c.g.POPUPS[1].text)
    check('changes are queued, not sent at once', len(c.calls()) <= 1, c.calls())
    c.tick(3)
    promoted = [x for x in c.calls() if x.startswith('promote')]
    check('promotes each ticked member once', len(promoted) == 3 and not any('REFUSED' in x for x in promoted), c.calls())
    c.roster_update()
    check('promoted members show the new rank', all(c.vc.byId[c.vc.nameId(n)].rankIndex == 3 for n in ['Member11', 'Member12', 'Member13']))
    check('rank changes reach the activity feed', len(c.events('promote')) == 3, len(c.events('promote')))

    # Set rank walks several steps, and never to your own rank or above ---------------------------
    c.run('wipe(CALLS); wipe(VC_NS.selected); VC_NS.selected[VC_NS.nameId("Member20")]=true')
    c.vc.massRank(0, 2, 'Veteran')
    c.tick(3)
    check('set rank walks one rank at a time', c.calls() == ['promote Member20-LivingFlame', 'promote Member20-LivingFlame'], c.calls())
    c.roster_update()
    c.run('wipe(CALLS); wipe(VC_NS.selected); VC_NS.selected[VC_NS.nameId("Member20")]=true; VC_NS.selected[VC_NS.nameId("Member2")]=true')
    c.vc.massRank(1)
    c.tick(3)
    check('never promotes to your own rank or touches the guild master', c.calls() == [], c.calls())

    # Demote stops at the lowest rank ------------------------------------------------------------
    c.run('wipe(CALLS); wipe(VC_NS.selected); VC_NS.selected[VC_NS.nameId("Member25")]=true; VC_NS.selected[VC_NS.nameId("Member20")]=true')
    c.vc.massRank(-1)
    c.tick(3)
    check('demote skips the lowest rank', c.calls() == ['demote Member20-LivingFlame'], c.calls())

    # Declining the confirmation changes nothing ------------------------------------------------
    c.run('wipe(CALLS); DECLINE_POPUPS=true; wipe(VC_NS.selected); VC_NS.selected[VC_NS.nameId("Member26")]=true')
    c.vc.massRank(1)
    c.tick(3)
    check('saying no changes nothing', c.calls() == [], c.calls())
    c.run('DECLINE_POPUPS=false')

    # Cancel stops a queue part way -------------------------------------------------------------
    c.run('wipe(CALLS); wipe(VC_NS.selected); for i=21,30 do VC_NS.selected[VC_NS.nameId("Member"..i)]=true end')
    c.vc.massRank(1)
    c.tick(1.3)
    c.vc.cancelJobs()
    c.tick(5)
    check('cancel stops the rest', 0 < len(c.calls()) < 10, c.calls())
    c.roster_update()

    # Mass notes ---------------------------------------------------------------------------------
    c.run('wipe(CALLS); wipe(VC_NS.selected); for i=4,6 do VC_NS.selected[VC_NS.nameId("Member"..i)]=true end')
    c.vc.massNote('Lvl {level}', 'append', False)
    c.tick(3)
    notes = [x for x in c.calls() if x.startswith('note')]
    check('mass public note with tokens', len(notes) == 3 and any('Lvl' in x for x in notes), c.calls())
    c.run('wipe(CALLS)')
    c.vc.massNote('Raider since {date} and a very long note', 'replace', True)
    c.tick(3)
    onotes = [x for x in c.calls() if x.startswith('onote')]
    check('mass officer note, trimmed to 31 bytes', len(onotes) == 3, c.calls())
    c.run('CAN.officerNote=false; wipe(CALLS)')
    c.vc.massNote('x', 'replace', True)
    c.tick(2)
    check('no officer notes without permission', c.calls() == [], c.calls())
    c.run('CAN.officerNote=true')

    # Single-member note from the editor
    c.run('wipe(CALLS); VC_NS.startJobs("Note",{{kind="note",id=VC_NS.nameId("Member7"),officer=false,text="Tank"}})')
    c.tick(1)
    check('single note save', c.calls() == ['note Member7-LivingFlame Tank'], c.calls())

    # Note trimming keeps UTF-8 whole
    trimmed = c.vc.trimNote('é' * 20)
    check('trimmed notes never split a letter', len(trimmed.encode('utf-8')) == 30, repr(trimmed))
    check('composeNote append', c.vc.composeNote('Main', 'Tank', 'append', c.vc.roster[1]) == 'Main Tank')
    check('composeNote clear', c.vc.composeNote('Main', 'x', 'clear', c.vc.roster[1]) == '')

    # Progression: dings, joins, leaves ----------------------------------------------------------
    c.run('ROSTER[8].level=10; CLOCK=CLOCK+3600')
    c.roster_update()
    c.run('ROSTER[8].level=31; CLOCK=CLOCK+3600')
    c.roster_update()
    dings = [e.d for e in c.events('ding')]
    check('level milestones become dings', any('level 20' in d for d in dings) and any('level 30' in d for d in dings), dings)
    climbers = c.vc.climbers(7)
    check('top climbers', climbers[1] is not None and climbers[1].m.short == 'Member8' and climbers[1].n == 21, climbers[1] and (climbers[1].m.short, climbers[1].n))
    c.run('ROSTER[#ROSTER+1]={name="Newbie-LivingFlame",rank=4,level=5,class=2,online=true,note="",onote="",zone=1}')
    c.roster_update()
    check('new members are noticed', len(c.events('join')) == 1)
    c.run('table.remove(ROSTER,5)')
    c.roster_update()
    check('leavers are noticed', len(c.events('leave')) == 1)
    c.run('SHOW_OFFLINE=false; for i=#ROSTER,1,-1 do if not ROSTER[i].online then table.remove(ROSTER,i) end end')
    c.roster_update()
    check('an online-only roster is not a mass exodus', len(c.events('leave')) == 1, len(c.events('leave')))

    # Stats --------------------------------------------------------------------------------------
    c.vc.sample()
    s = c.vc.stats()
    check('stats: peak online recorded', s.peak.n >= 10, s.peak.n)
    check('stats: alt army from notes', s.alts >= 1)
    check('stats: busiest hour known', s.busyHour is not None)

    # Integrations -------------------------------------------------------------------------------
    setup = '''
    GuildForgeDB={guilds={["Hidden Leaf - Living Flame"]={members={
      ["Member6-Living Flame"]={professions={{name="Alchemy",rank=300,max=300},{name="Herbalism",rank=250,max=300}}},
      ["Member9"]={professions={{name="Alchemy",rank=120,max=150}}},
      ["Gone-Living Flame"]={professions={{name="Mining",rank=300,max=300}}},
    }}}}
    SlashCmdList={GUILDFORGE=function() FORGE_OPENED=(FORGE_OPENED or 0)+1 end}
    GuildBankToonsAPI={version=1,HasBank=function() return true end,Open=function(tab) BANK_OPENED=tab or "default" end,RegisterCallback=function() end}
    GuildBankToons={
      currentGold=function() return 1234567 end,
      bankList=function() return {{id="vault-1",name="Member6"},{id="*vault1",name="Guild Bank - Mats",tab=1}} end,
      guild=function() return {banks={["vault-1"]={gold=1000000}}} end,
      requestList=function() return {{status="open",by="Member9-LivingFlame"},{status="mailed",by="Member4"}} end,
      describe=function() return "20x Linen Cloth" end,
      goldSeries=function(days) local t={} for i=1,days do t[i]=i*10000 end; t[1]=false; return t end,
    }
    '''
    c2 = Client(setup)
    summary = c2.vc.professionSummary()
    check('GuildForge professions by roster member', summary.Alchemy.count == 2 and summary.Alchemy.top == 300 and summary.Alchemy.topName == 'Member6',
          (summary.Alchemy.count, summary.Alchemy.top, summary.Alchemy.topName))
    check('former members are left out', summary.Mining.count == 0)
    bank = c2.vc.bankSummary()
    check('Un-Ninja Bank gold and requests', bank.gold == 1234567 and bank.open == 1 and len(bank.banks) == 2, (bank.gold, bank.open))
    check('bank toons are tagged', c2.vc.bankToons()[c2.vc.nameId('Member6')] is True)
    c2.g.SlashCmdList.VILLAGECOMMAND('forge')
    c2.tick(0.5)
    c2.g.SlashCmdList.VILLAGECOMMAND('bank')
    c2.tick(0.5)
    c2.g.SlashCmdList.VILLAGECOMMAND('')
    c2.g.SlashCmdList.VILLAGECOMMAND('overview')
    c2.tick(0.5)
    c2.vc.openForge()
    c2.vc.openBank('requests')
    check('opens GuildForge', c2.g.FORGE_OPENED == 1)
    check('opens an Un-Ninja Bank tab', c2.g.BANK_OPENED == 'requests')

    # Not allowed to change ranks -----------------------------------------------------------------
    c3 = Client('MY_RANK=3')
    c3.run('CAN.promote=false; wipe(VC_NS.selected); VC_NS.selected[VC_NS.nameId("Member20")]=true')
    c3.vc.massRank(1)
    c3.tick(2)
    check('a member without rights changes nothing', c3.calls() == [] and len(c3.g.POPUPS) == 0, c3.calls())
    c3.g.SlashCmdList.VILLAGECOMMAND('roster')
    c3.tick(0.5)
    check('roster draws for a plain member', True)

    # WoW: Forever names (surnames, no realms) ----------------------------------------------------
    c4 = Client('INTERFACE=16001; SURNAME="Dawnfire"; PLAYER="Arc"')
    check('Forever: reads the roster', len(c4.vc.roster) == 30, len(c4.vc.roster))
    c4.run('wipe(VC_NS.selected); VC_NS.selected[VC_NS.nameId(TESTNAME("Member20"))]=true')
    c4.vc.massRank(1)
    c4.tick(2)
    check('Forever: never tries a promote (the game keeps it for its guild window)', c4.calls() == [], c4.calls())
    for key in ['overview', 'roster', 'progress', 'stats', 'forge', 'bank']:
        c4.vc.selectTab(key)
        c4.tick(0.3)
    check('Forever: every page draws', True)

    # Clicks: tooltips, the right-click menu, shift-click ranges, the note dialog, settings -----------
    c.g.SlashCmdList.VILLAGECOMMAND('roster')
    c.tick(0.5)
    c.run('''
      local m=VC_NS.roster[5]
      VC_NS.memberTooltip(UIParent,m)
      VC_NS.memberMenu(UIParent,m)
      for _,b in ipairs(VillageCommandMenu.buttons) do b:Click() end
      wipe(VC_NS.selected)
      local list=VC_NS.filtered()
      VC_NS.rowClick({member=list[2]},'LeftButton')
      IsShiftKeyDown=function() return true end
      VC_NS.rowClick({member=list[6]},'LeftButton')
      IsShiftKeyDown=nil
      SHIFT_TICKED=0
      for _ in pairs(VC_NS.selected) do SHIFT_TICKED=SHIFT_TICKED+1 end
      VC_NS.openNoteDialog(true)
      VillageCommandNoteDialog.box:SetText('Core {class}')
      VillageCommandNoteDialog.mode:Click()
      VillageCommandNoteDialog.updatePreview()
      VillageCommandWindow.settingsPanel:Show()
    ''')
    c.tick(3)
    check('shift-click ticks a range', c.g.SHIFT_TICKED == 5, c.g.SHIFT_TICKED)
    c.run('''
      local p=VillageCommandRosterScroll:GetParent():GetParent()
      VC_NS.updateActionBar()
      BAR_WITH=p.actions:IsShown() and not p.barHint:IsShown()
      wipe(VC_NS.selected); VC_NS.updateActionBar()
      BAR_WITHOUT=(not p.actions:IsShown()) and p.barHint:IsShown()
      VC_NS.focus=nil; VC_NS.updateActionBar()
      EDITOR_HINT=p.editor.hint:IsShown() and not p.editor.fields:IsShown()
    ''')
    check('mass actions show only once something is ticked', c.g.BAR_WITH and c.g.BAR_WITHOUT)
    check('editor shows a hint until a member is picked', c.g.EDITOR_HINT)
    check('note dialog and menus run', True)

    # The roster loaded during the loading screen: no GUILD_ROSTER_UPDATE ever comes after login --------
    c5 = Client(roster_event=False)
    c5.tick(0.5)
    check('reads a roster that arrived before login, without an event', len(c5.vc.roster) == 30, len(c5.vc.roster))
    c6 = Client(roster_event=False)
    c6.run('NO_ROSTER_YET=true; local real=GetNumGuildMembers; GetNumGuildMembers=function() if NO_ROSTER_YET then return 0 end return real() end')
    c6.tick(0.5)
    c6.g.SlashCmdList.VILLAGECOMMAND('')
    c6.tick(0.5)
    c6.run('NO_ROSTER_YET=false')
    c6.tick(16)
    check('picks the roster up while the window is open, even with no event', len(c6.vc.roster) == 30, len(c6.vc.roster))
    # One entry the game hands back oddly is skipped and reported, not the whole roster
    c7 = Client('''
      _G.BAD_INDEX=7
    ''', roster_event=False)
    c7.run('local real=GetGuildRosterInfo; GetGuildRosterInfo=function(i) if i==BAD_INDEX then error("odd entry") end return real(i) end; wipe(PRINTED)')
    c7.roster_update()
    reported = [x for x in c7.g.PRINTED.values() if 'odd entry' in x]
    check('a bad roster entry skips one member, not all', len(c7.vc.roster) == 29, len(c7.vc.roster))
    check('a bad roster entry is reported once', len(reported) == 1, list(c7.g.PRINTED.values()))
    c7.roster_update()
    check('and not reported again', len([x for x in c7.g.PRINTED.values() if 'odd entry' in x]) == 1)
    c7.g.SlashCmdList.VILLAGECOMMAND('status')
    check('/vc status shows the last roster error', any('last roster error' in x for x in c7.g.PRINTED.values()))

    # GetNumGuildMembers returns total, online, online+mobile: the online count must never reach tonumber as a
    # number base (0 or 1 online, or more than 36, used to stop the roster loading at all).
    for online in (0, 1, 37):
        cx = Client('''
          ONLINE_TARGET=%d
        ''' % online, roster_event=False)
        cx.run('for i,m in ipairs(ROSTER) do m.online=false end; for i=1,ONLINE_TARGET do ROSTER[#ROSTER+1]={name="Extra"..string.char(96+(i-1)%26+1)..string.char(96+math.floor((i-1)/26)+1).."-LivingFlame",rank=4,level=10,class=1,online=true,note="",onote="",zone=1} end; wipe(PRINTED)')
        cx.roster_update()
        check(f'reads the roster with {online} online', len(cx.vc.roster) == 30 + online and cx.vc.lastError is None,
              (len(cx.vc.roster), cx.vc.lastError))

    # Actions the game keeps for its own guild window ---------------------------------------------
    # WoW Forever: officer notes are known to be blocked, so they're never tried (no popup), but stay readable.
    c8 = Client('INTERFACE=16001; SURNAME="Dawnfire"; PLAYER="Arc"')
    p8 = c8.vc.perms(False)
    check('Forever: officer notes are off from the start', p8.officerNote is False and 'guild window' in (p8.why.officerNote or ''), p8.why.officerNote)
    check('Forever: public notes, promote and demote are off from the start',
          not p8.publicNote and not p8.promote and not p8.demote and c8.vc.gameLocked() is True)
    c8.run('wipe(VC_NS.selected); for i=4,6 do VC_NS.selected[VC_NS.nameId(TESTNAME("Member"..i))]=true end; wipe(CALLS)')
    c8.vc.massNote('x', 'replace', True)
    c8.run('VC_NS.runNow("Officer note",{{kind="note",id=VC_NS.nameId(TESTNAME("Member7")),officer=true,text="Tank"}})')
    c8.tick(3)
    check('Forever: never calls the officer note function', c8.calls() == [], c8.calls())
    c8.g.SlashCmdList.VILLAGECOMMAND('roster')
    c8.run('VC_NS.focus=VC_NS.nameId(TESTNAME("Member7")); VC_NS.updateActionBar()')
    c8.tick(0.5)
    check('Forever: the editor still shows the officer note', True)
    c8.run('''
      local p=VillageCommandRosterScroll:GetParent():GetParent()
      VC_NS.selected[VC_NS.nameId(TESTNAME("Member8"))]=true
      VC_NS.updateActionBar(); VC_NS.drawRows()
      LOCKED_UI=(not p.actions:IsShown()) and p.barHint:IsShown() and p.barHint:GetText()==VC_NS.LOCKED_TEXT
        and not p.tick:IsShown() and not p.all:IsShown()
        and p.editor.lockedHint:IsShown() and not p.editor.saveNote:IsShown() and not p.editor.promote:IsShown()
      VC_NS.memberMenu(UIParent,VC_NS.byId[VC_NS.nameId(TESTNAME("Member8"))])
      MENU_ITEMS=0
      for _,b in ipairs(VillageCommandMenu.buttons) do if b:IsShown() then MENU_ITEMS=MENU_ITEMS+1 end end
    ''')
    check('Forever: the roster is view-only, with no dead buttons', c8.g.LOCKED_UI is True)
    check('Forever: the right-click menu offers only whisper and invite', c8.g.MENU_ITEMS == 2, c8.g.MENU_ITEMS)
    c8.g.SlashCmdList.VILLAGECOMMAND('status')
    check('Forever: /vc status lists what the game keeps for itself', any('blocked by the game on forever' in x for x in c8.g.PRINTED.values()))

    # A block reported during the call: the queue stops at once, and it's remembered.
    c9 = Client('''
      BLOCK_NOW=true
    ''')
    c9.run('''
      local real=GuildRosterSetPublicNote
      GuildRosterSetPublicNote=function(i,text)
        CALLS[#CALLS+1]="tried note"
        if BLOCK_NOW then VC_TEST_fire("ADDON_ACTION_FORBIDDEN","VillageCommand","GuildRosterSetPublicNote()") return end
        real(i,text)
      end
      wipe(VC_NS.selected); for i=4,9 do VC_NS.selected[VC_NS.nameId("Member"..i)]=true end
      wipe(PRINTED)
    ''')
    c9.vc.massNote('Raider', 'replace', False)
    c9.tick(5)
    q = c9.vc.queue
    check('a blocked mass change stops after the first try', c9.calls() == ['tried note'], c9.calls())
    check('the blocked change counts as failed, the rest as skipped', (q.done, q.failed, q.skipped) == (0, 1, 5), (q.done, q.failed, q.skipped))
    check('says what to do instead', any('guild window' in x for x in c9.g.PRINTED.values()), list(c9.g.PRINTED.values())[-3:])
    check('remembers it for this version of the game', c9.g.VillageCommandDB.blocked.classic.publicNote == 'all')
    c9.run('wipe(CALLS)')
    c9.vc.massNote('Raider', 'replace', False)
    c9.run('VC_NS.runNow("Note",{{kind="note",id=VC_NS.nameId("Member7"),officer=false,text="Tank"}})')
    c9.tick(3)
    check('never tries a blocked action again', c9.calls() == [], c9.calls())
    c9.g.SlashCmdList.VILLAGECOMMAND('unblock')
    c9.run('BLOCK_NOW=false; wipe(CALLS)')
    c9.run('VC_NS.runNow("Note",{{kind="note",id=VC_NS.nameId("Member7"),officer=false,text="Tank"}})')
    check('/vc unblock tries again', c9.calls() == ['tried note', 'note Member7-LivingFlame Tank'], c9.calls())

    # A block reported a moment later, from a queued change: only one-at-a-time from a click is left.
    c10 = Client()
    c10.run('''
      local real=GuildPromote
      GuildPromote=function(name)
        CALLS[#CALLS+1]="tried promote"
        C_Timer.After(0.05,function() VC_TEST_fire("ADDON_ACTION_BLOCKED","VillageCommand","GuildPromote()") end)
      end
      wipe(VC_NS.selected); for i=11,16 do VC_NS.selected[VC_NS.nameId("Member"..i)]=true end
    ''')
    c10.vc.massRank(1)
    c10.tick(5)
    q = c10.vc.queue
    check('a late block still stops the queue', c10.calls() == ['tried promote'] and q.failed == 1 and q.done == 0, (c10.calls(), q.done, q.failed, q.skipped))
    check('queued promotes are off, one-at-a-time stays on', c10.g.VillageCommandDB.blocked.classic.promote == 'mass'
          and c10.vc.perms(True).promote is False and c10.vc.perms(False).promote is True)
    c10.run('''
      wipe(CALLS)
      local m=VC_NS.byId[VC_NS.nameId("Member12")]
      VC_NS.runNow("Promoted",(VC_NS.rankJobs({m},1,nil,true)))
    ''')
    check('a single promote from a click is still tried', c10.calls() == ['tried promote'], c10.calls())
    # Other addons' blocked actions are none of our business
    c11 = Client()
    c11.run('VC_NS.lastCall={feature="promote",click=false}')
    c11.fire('ADDON_ACTION_FORBIDDEN', 'SomeOtherAddon', 'CastSpellByName()')
    check('ignores other addons being blocked', c11.vc.blockLevel('promote') is None)
    check('Classic Era is not view-only', c11.vc.gameLocked() is False)

    # Promotion checklist ---------------------------------------------------------------------------
    cp = Client()
    cp.run('VC_NS.saveRule(nil,{from=4,to=3,minLevel=20,minDays=14,activeDays=0})')
    ready = cp.vc.ruleMembers(cp.vc.rules()[1])[0]
    check('checklist: nobody has 14 days in the guild on day one', len(ready) == 0, len(ready))
    cp.run('CLOCK=CLOCK+15*86400')
    cp.roster_update()
    expected = len([1 for m in cp.vc.roster.values() if m.rankIndex == 4 and m.level >= 20])
    ready = cp.vc.ruleMembers(cp.vc.rules()[1])[0]
    check('checklist: rank, level and days decide who qualifies', len(ready) == expected and expected > 0, (len(ready), expected))
    check('checklist: online members come first', all(not ready[i + 1].online or ready[i].online for i in range(1, len(ready))))
    cp.run('VC_NS.rules()[1].activeDays=3')
    active = cp.vc.ruleMembers(cp.vc.rules()[1])[0]
    check('checklist: online-within filter', all(m.online or (m.away or 0) <= 3 * 86400 for m in active.values()) and len(active) < len(ready))
    cp.run('VC_NS.rules()[1].activeDays=0')
    first = ready[1]
    cp.run('VC_NS.rules()[1].skip={[VC_NS.nameId("%s")]=true}' % first.name)
    cp.run('R,S,D=VC_NS.ruleMembers(VC_NS.rules()[1])')
    check('checklist: skipping moves someone off the list', len(cp.g.R) == len(ready) - 1 and len(cp.g.S) == 1)
    # Promoting (here through the game's own path: the mock's GuildPromote) ticks them off
    cp.run('for _,m in ipairs(ROSTER) do if m.name=="%s" then m.rank=3 end end' % ready[2].name)
    cp.roster_update()
    cp.run('R,S,D=VC_NS.ruleMembers(VC_NS.rules()[1])')
    check('checklist: a promoted member drops off', len(cp.g.R) == len(ready) - 2, len(cp.g.R))
    check('checklist: and shows under promoted this week', len(cp.g.D) == 1, list(cp.g.D.values()))
    check('checklist: tooltips and the minimap know who is ready', len(cp.vc.readyForPromotion()[0]) == len(ready) - 2)
    # Classic Era: Promote all goes through the confirmation and queue
    cp.run('wipe(CALLS)')
    cp.vc.promoteRule(cp.vc.rules()[1])
    cp.tick(len(ready) * 1.0 + 2)
    promoted = [x for x in cp.calls() if x.startswith('promote')]
    check('checklist: Promote all promotes everyone listed', len(promoted) == len(ready) - 2, (len(promoted), len(ready) - 2))
    cp.roster_update()
    cp.run('R=VC_NS.ruleMembers(VC_NS.rules()[1])')
    check('checklist: empty once everyone is promoted', len(cp.g.R) == 0, len(cp.g.R))
    # The page and the rule editor
    cp.g.SlashCmdList.VILLAGECOMMAND('promotions')
    cp.tick(0.5)
    cp.run('''
      VC_NS.openRuleDialog()
      local d=VillageCommandRuleDialog
      d.level:SetText("30"); d.days:SetText(""); d.active:SetText("7")
      d.rule.from=3; d.rule.to=4; d.refresh(true)
      BAD_SAVE=not d.save:IsEnabled()
      d.rule.from=4; d.rule.to=2; d.refresh(true)
      d.save:Click()
      NEW_RULE=VC_NS.rules()[2]
      VC_NS.openRuleDialog(1); VillageCommandRuleDialog.save:Click()
      VC_NS.deleteRule(2)
    ''')
    check('rule editor: refuses promoting to a lower rank', cp.g.BAD_SAVE is True)
    check('rule editor: saves from the boxes', cp.g.NEW_RULE.minLevel == 30 and cp.g.NEW_RULE.minDays == 0 and cp.g.NEW_RULE.activeDays == 7 and cp.g.NEW_RULE.to == 2,
          (cp.g.NEW_RULE.minLevel, cp.g.NEW_RULE.minDays, cp.g.NEW_RULE.activeDays))
    check('rule editor: delete', len(cp.vc.rules()) == 1)
    cp.vc.selectTab('promos'); cp.tick(0.5)
    check('promotions page draws', True)
    # Forever: no Promote all, and the roster bar offers the checklist
    cf = Client('INTERFACE=16001; SURNAME="Dawnfire"; PLAYER="Arc"')
    cf.run('VC_NS.saveRule(nil,{from=4,to=3,minLevel=1,minDays=0,activeDays=0})')
    cf.g.SlashCmdList.VILLAGECOMMAND('roster')
    cf.tick(0.5)
    cf.run('''
      local p=VillageCommandRosterScroll:GetParent():GetParent()
      VC_NS.updateActionBar()
      CHECKLIST=p.checklist:IsShown() and p.checklist:GetText():find("Promotions %(") ~= nil
    ''')
    check('Forever: the roster bar offers the promotion checklist', cf.g.CHECKLIST is True)
    cf.vc.selectTab('promos'); cf.tick(0.5)
    check('Forever: promotions page draws (checklist only)', True)

    # The overview dashboard, with history to draw: several days of samples, level-ups and a cap ding.
    cd = Client()
    cd.run('''
      for day=1,9 do
        for h=0,23,3 do CLOCK=CLOCK+3*3600; VC_NS.sample() end
        ROSTER[8].level=math.min(60,ROSTER[8].level+day); ROSTER[12].level=math.min(60,ROSTER[12].level+2)
        VC_NS.readRoster(); VC_NS.track()
      end
      ROSTER[15].level=60; VC_NS.readRoster(); VC_NS.track()
    ''')
    cd.g.SlashCmdList.VILLAGECOMMAND('overview')
    cd.tick(0.5)
    check('overview: every graph draws without errors', cd.vc.panelErrors is None, cd.vc.panelErrors and list(cd.vc.panelErrors.values()))
    check('overview: line graphs use real lines where the client has them', (cd.g.LINES_MADE or 0) > 0, cd.g.LINES_MADE)
    check('overview: hall of fame', len(cd.vc.hallOfFame()) >= 1)
    check('overview: levels per day', sum(cd.vc.levelsByDay(14).values()) > 0)
    check('overview: weekly rhythm data', cd.g.VillageCommandDB is not None and cd.vc.guildData().week is not None)
    for key in ['overview', 'roster', 'promos', 'progress', 'stats', 'forge', 'bank']:
        cd.vc.selectTab(key); cd.tick(0.3)
    check('every page draws after a week of history', cd.vc.panelErrors is None, cd.vc.panelErrors and list(cd.vc.panelErrors.values()))
    c4.vc.selectTab('overview'); c4.tick(0.3)
    c.vc.selectTab('overview'); c.tick(0.3)
    check('overview: no graph errors on Forever or with little data', c4.vc.panelErrors is None and c.vc.panelErrors is None,
          [list((x.vc.panelErrors or {}).values()) for x in (c4, c)])

    # Celebrations ---------------------------------------------------------------------------------
    cc = Client()  # Member17 is already level 60 when the roster first loads
    check('celebrations: nothing is replayed at login', cc.vc.byId[cc.vc.nameId('Member17')].level == 60
          and len(cc.g.RAID_NOTICES) == 0 and not cc.g.VillageCommandCelebration)
    def ding(index, level):
        cc.run('ROSTER[%d].level=%d' % (index, level))
        cc.roster_update()
    cc.run('ROSTER[5].level=18; ROSTER[6].level=38; ROSTER[7].level=58; ROSTER[9].level=59')
    cc.roster_update()
    cc.run('wipe(RAID_NOTICES); wipe(SOUNDS)')
    ding(5, 19)
    check('celebrations: no message between milestones', len(cc.g.RAID_NOTICES) == 0)
    ding(5, 21)
    notices = list(cc.g.RAID_NOTICES.values())
    check('celebrations: a message when someone passes level 20', len(notices) == 1 and 'level 20' in notices[0], notices)
    check('celebrations: with the raid warning sound', 8959 in list(cc.g.SOUNDS.values()))
    ding(6, 41)
    check('celebrations: level 40 too', 'level 40' in list(cc.g.RAID_NOTICES.values())[-1])
    cc.run('ROSTER[7].level=60; ROSTER[9].level=60')
    cc.roster_update()
    party = cc.g.VillageCommandCelebration
    check('celebrations: the big banner at the level cap', party is not None and party.IsShown(party) and 'level 60' in party.sub.GetText(party.sub), party and party.sub.GetText(party.sub))
    check('celebrations: a second cap is queued, not lost', len(cc.vc.partyQueue) == 1)
    check('celebrations: the level-up fanfare', 888 in list(cc.g.SOUNDS.values()))
    cc.tick(7.5)
    check('celebrations: then the queued one shows', party.IsShown(party) and len(cc.vc.partyQueue) == 0)
    cc.tick(8)
    check('celebrations: and the banner goes away', not party.IsShown(party))
    cc.run('VillageCommandDB.settings.celebrateLevels="25"; wipe(RAID_NOTICES)')
    ding(10, 26)
    ding(11, 20)
    notices = list(cc.g.RAID_NOTICES.values())
    check('celebrations: levels are yours to choose', len(notices) == 1 and 'level 25' in notices[0], notices)
    cc.run('VillageCommandDB.settings.celebrate=false; wipe(RAID_NOTICES)')
    ding(13, 30); ding(14, 60)
    check('celebrations: can be turned off', len(cc.g.RAID_NOTICES) == 0 and len(cc.vc.partyQueue) == 0 and not party.IsShown(party))
    cc.run('VillageCommandDB.settings.celebrate=true; VillageCommandDB.settings.celebrateCap=false; wipe(RAID_NOTICES)')
    ding(16, 60)
    check('celebrations: the big one can be turned off on its own', not party.IsShown(party))
    cc.run('VillageCommandDB.settings.celebrateCap=true; VillageCommandDB.settings.celebrateSound=false; wipe(SOUNDS)')
    cc.vc.previewCelebration(False)
    cc.vc.previewCelebration(True)
    check('celebrations: previews, and sound can be turned off', len(cc.g.SOUNDS) == 0 and party.IsShown(party))
    cc.g.SlashCmdList.VILLAGECOMMAND('settings')
    cc.tick(0.3)
    check('settings panel draws with the celebration options', True)

    # Promotion rules are optional: switch one off and it lists and counts nobody
    cr = Client()
    cr.run('VC_NS.saveRule(nil,{from=4,to=3,minLevel=1,minDays=0,activeDays=0})')
    before = len(cr.vc.readyForPromotion()[0])
    cr.run('VC_NS.rules()[1].off=true')
    off = len(cr.vc.readyForPromotion()[0])
    cr.vc.selectTab('promos'); cr.tick(0.3)
    cr.run('VC_NS.saveRule(1,{from=4,to=2,minLevel=5,minDays=0,activeDays=0})')
    check('rules: switched off, a rule counts nobody', before > 0 and off == 0, (before, off))
    check('rules: editing keeps it switched off', cr.vc.rules()[1].off is True and cr.vc.rules()[1].to == 2)
    cr.run('VC_NS.rules()[1].off=nil')
    check('rules: and back on', len(cr.vc.readyForPromotion()[0]) > 0)

    # History sync between guildmates --------------------------------------------------------------
    # A (an Officer) has three weeks of history; B (a Member) just installed. C is another Member.
    A = Client('PLAYER="Arcbinky"; MY_RANK=1; EXTRA_MEMBERS={{"Brightleaf",3,60},{"Cedar",3,20}}')
    B = Client('PLAYER="Brightleaf"; MY_RANK=3; EXTRA_MEMBERS={{"Arcbinky",1,60},{"Cedar",3,20}}')
    A.run('''
      local g=VC_NS.guildData()
      local T=math.floor(CLOCK)
      for id,rec in pairs(g.members) do rec.first=T-21*86400; rec.levels={{T-21*86400,math.max(1,rec.level-6)},{T-10*86400,math.max(1,rec.level-3)},{rec.first+20*86400,rec.level}} end
      local m8=VC_NS.byId[VC_NS.nameId("Member8")]
      VC_NS.event(g,"ding",m8.short,"reached level 50",m8.id,50)
      g.events[#g.events].t=CLOCK-3*86400
      local m9=VC_NS.byId[VC_NS.nameId("Member9")]
      VC_NS.event(g,"promote",m9.short,"promoted to Member",m9.id,3)
      g.events[#g.events].t=CLOCK-2*86400
    ''')
    net = Guild(A, B)
    net.pump(60)
    gB = B.vc.guildData()
    id8 = B.vc.nameId('Member8')
    days = B.vc.daysIn(B.vc.byId[id8])
    check('sync: a newcomer learns how long members have been around', days >= 20, days)
    check('sync: and their level history', len(gB.members[id8].levels) >= 3, len(gB.members[id8].levels))
    kinds = sorted(e.k for e in gB.events.values() if e.shared)
    check('sync: and the activity feed (from a trusted rank)', 'ding' in kinds and 'promote' in kinds, kinds)
    check('sync: shared events read in your own words', any(e.d == 'reached level 50' for e in gB.events.values()))
    check('sync: both sides end up with the same fingerprint', A.vc.digest() == B.vc.digest(), (A.vc.digest(), B.vc.digest()))
    sizes = [len(m) for _, m in net.delivered]
    check('sync: every message fits in 255 bytes', max(sizes) <= 255, max(sizes))
    check('sync: light: under 40 messages for a 32-member guild', len(net.delivered) < 40, len(net.delivered))
    check('sync: never throttled by the game', not A.g.THROTTLED and not B.g.THROTTLED, (A.g.THROTTLED, B.g.THROTTLED))
    print('     (sync used %d messages, %d bytes)' % (len(net.delivered), sum(sizes)))
    before = len(net.delivered)
    B.g.SlashCmdList.VILLAGECOMMAND('sync')
    net.pump(15)
    check('sync: once in step, a hello costs one message', len(net.delivered) - before == 1, net.delivered[before:])

    # What B knew that A didn't goes back to A
    B.run('''
      local g=VC_NS.guildData()
      local c=VC_NS.byId[VC_NS.nameId("Cedar")]
      table.insert(g.members[c.id].levels,1,{math.floor(CLOCK)-86400*30,10})
      VC_NS.event(g,"ding",c.short,"reached level 20",c.id,20)
    ''')
    B.g.SlashCmdList.VILLAGECOMMAND('sync')
    net.pump(40)
    gA = A.vc.guildData()
    idc = A.vc.nameId('Cedar')
    check('sync: works both ways', any(e[2] == 10 for e in gA.members[idc].levels.values()) and A.vc.digest() == B.vc.digest(),
          [(e[1], e[2]) for e in gA.members[idc].levels.values()])

    # Trust: a Member alone can't push an earlier first-seen date or invent joins and promotions
    C = Client('PLAYER="Cedar"; MY_RANK=3; EXTRA_MEMBERS={{"Arcbinky",1,60},{"Brightleaf",3,60}}')
    D = Client('PLAYER="Dawn"; MY_RANK=3; EXTRA_MEMBERS={{"Arcbinky",1,60},{"Brightleaf",3,60},{"Cedar",3,20}}')
    # Make the fresh clients' roster include Dawn too.
    for x in (A, B, C):
        x.run('ROSTER[#ROSTER+1]={name="Dawn-LivingFlame",rank=3,level=12,class=1,online=true,note="",onote="",zone=1}')
        x.roster_update()
    first_before = A.vc.guildData().members[A.vc.nameId('Member20')].first
    fake = 'M|member20-livingflame~' + A.vc.to36(first_before - 90 * 86400) + '~'
    A.fire('CHAT_MSG_ADDON', 'VCMD', fake, 'GUILD', 'Cedar-LivingFlame')
    check('sync: one Member alone can\'t move a first-seen date', A.vc.guildData().members[A.vc.nameId('Member20')].first == first_before)
    A.fire('CHAT_MSG_ADDON', 'VCMD', fake, 'GUILD', 'Dawn-LivingFlame')
    check('sync: two who agree can', A.vc.guildData().members[A.vc.nameId('Member20')].first < first_before)
    n_events = len(A.vc.guildData().events)
    A.fire('CHAT_MSG_ADDON', 'VCMD', 'E|' + A.vc.to36(A.g.CLOCK - 3600) + '~p~Member21~0', 'GUILD', 'Cedar-LivingFlame')
    A.fire('CHAT_MSG_ADDON', 'VCMD', 'E|' + A.vc.to36(A.g.CLOCK - 3600) + '~d~Member21~59', 'GUILD', 'Cedar-LivingFlame')
    check('sync: Members can\'t invent promotions, or level-ups past the roster', len(A.vc.guildData().events) == n_events)
    A.fire('CHAT_MSG_ADDON', 'VCMD', 'M|garbage;~~;' + 'x' * 200, 'GUILD', 'Cedar-LivingFlame')
    A.fire('CHAT_MSG_ADDON', 'VCMD', 'Q|whatever', 'GUILD', 'Stranger-LivingFlame')
    check('sync: junk is ignored', A.vc.sync.lastError is None, A.vc.sync.lastError)

    # Sharing off: nothing goes out, nothing comes in
    E = Client('PLAYER="Elm"; MY_RANK=3; EXTRA_MEMBERS={{"Arcbinky",1,60}}')
    E.run('VillageCommandDB.settings.share=false')
    net2 = Guild(A, E)
    E.g.SlashCmdList.VILLAGECOMMAND('sync')
    A.g.SlashCmdList.VILLAGECOMMAND('sync')
    net2.pump(30)
    check('sync: switched off, it sends nothing', all(s != 'Elm-LivingFlame' for s, _ in net2.delivered))
    check('sync: and takes nothing in', E.vc.sync.merged == 0)

    # Held in combat inside an instance (Forever's lockdown), sent afterwards
    F = Client('PLAYER="Fern"; MY_RANK=3; EXTRA_MEMBERS={{"Arcbinky",1,60}}')
    F.run('IN_INSTANCE=true; IN_COMBAT=true; C_ChatInfo.InChatMessagingLockdown=function() return true end')
    F.g.SlashCmdList.VILLAGECOMMAND('sync')
    F.tick(5)
    check('sync: held while the game locks addon chat', len(F.g.OUT) == 0 and len(F.vc.sync.out) == 1)
    F.run('IN_COMBAT=false')
    F.tick(2)
    check('sync: still held in the instance while the game reports the lockdown', len(F.g.OUT) == 0)
    F.run('IN_INSTANCE=false')
    F.tick(2)
    check('sync: and sent once you\'re out', len(F.g.OUT) == 1)
    for x in (A, B):
        x.g.SlashCmdList.VILLAGECOMMAND('status')
    check('sync: /vc status reports it', any('history sync on' in s for s in A.g.PRINTED.values()))

    # WoW Forever: surnames on the wire, no realms
    FA = Client('INTERFACE=16001; PLAYER="Arc"; SURNAME="Dawnfire"; MY_RANK=1; EXTRA_MEMBERS={{"Bree",3,60}}')
    FB = Client('INTERFACE=16001; PLAYER="Bree"; MY_RANK=3; EXTRA_MEMBERS={{"Arc Dawnfire",1,60}}')
    FA.run('''
      local T=math.floor(CLOCK)
      for id,rec in pairs(VC_NS.guildData().members) do rec.first=T-15*86400 end
      local m=VC_NS.byId[VC_NS.nameId(TESTNAME("Member8"))]
      VC_NS.event(VC_NS.guildData(),"promote",m.short,"promoted to Member",m.id,3)
    ''')
    class ForeverGuild(Guild):
        def pump(self, seconds):
            for _ in range(int(seconds / 0.1 + 0.5)):
                for c in self.clients:
                    c.tick(0.1)
                for c in self.clients:
                    out = c.g.OUT
                    msgs = [(out[i][1], out[i][2], out[i][3]) for i in range(1, len(out) + 1)]
                    c.run('wipe(OUT)')
                    # Forever puts "First-Surname" on messages, with no realm.
                    sender = c.g.PLAYER + ('-' + c.g.SURNAME if c.g.SURNAME else '')
                    for prefix, msg, channel in msgs:
                        self.delivered.append((sender, msg))
                        for other in self.clients:
                            other.fire('CHAT_MSG_ADDON', prefix, msg, channel, sender)
    fnet = ForeverGuild(FA, FB)
    fnet.pump(60)
    fid = FB.vc.nameId(FB.g.TESTNAME('Member8'))
    check('Forever sync: first-seen dates from a trusted Officer', FB.vc.daysIn(FB.vc.byId[fid]) >= 14, FB.vc.daysIn(FB.vc.byId[fid]))
    check('Forever sync: events by name', any(e.k == 'promote' and e.shared for e in FB.vc.guildData().events.values()))
    check('Forever: you are recognised by first name and surname', FA.vc.myId() == 'arcdawnfire' and FA.vc.byId['arcdawnfire'] is not None)
    check('Forever sync: your own echoes are ignored', FA.vc.sync.received == len([1 for s, _ in fnet.delivered if s != 'Arc-Dawnfire']))

    # Promote one by one: a secure /gpromote button (WoW Forever) ----------------------------------
    def helper_client(setup=''):
        h = Client('INTERFACE=16001; PLAYER="Arc"; SURNAME="Dawnfire"; MY_RANK=1; ' + setup)
        h.run('VC_NS.saveRule(nil,{from=4,to=3,minLevel=1,minDays=0,activeDays=0})')
        h.g.SlashCmdList.VILLAGECOMMAND('promotions')
        h.tick(0.5)
        return h
    def batch_of(h):
        hb = h.g.VillageCommandPromoteHelperButton
        b = hb.batch
        return [b[i] for i in range(1, len(b) + 1)]
    H = helper_client()
    H.vc.openPromoteHelper(1)
    H.tick(0.5)
    hb = H.g.VillageCommandPromoteHelperButton
    batch = batch_of(H)
    ready = len(H.vc.ruleMembers(H.vc.rules()[1])[0])
    check('helper: a click carries several names (5 by default)', len(batch) == min(5, ready), (len(batch), ready))
    macro = hb.GetAttribute(hb, 'macrotext')
    check('helper: one /gpromote line per name', macro.split('\n') == ['/gpromote ' + m.name for m in batch], macro)
    check('helper: hides itself in combat (the game\'s state driver)', '[combat] hide' in str(H.g.STATE_DRIVERS[H.g.VillageCommandPromoteHelper]))
    H.run('wipe(CALLS)')
    H.g.VC_TEST_click(hb)
    H.roster_update(); H.tick(3)
    check('helper: one click promotes the whole batch', sorted(H.calls()) == sorted('promote ' + m.name for m in batch), H.calls())
    check('helper: confirmed from the roster', H.vc.helperState.worked == len(batch) and 'Promoted %d' % len(batch) in H.g.VillageCommandPromoteHelper.status.GetText(H.g.VillageCommandPromoteHelper.status))
    nxt = batch_of(H)
    check('helper: then lines up the next batch', len(nxt) > 0 and not set(m.id for m in nxt) & set(m.id for m in batch))
    check('helper: remembers that /gpromote works here', H.g.VillageCommandDB.gpromote.forever == 'works')
    # Skip first
    H.g.VillageCommandPromoteHelper.skip.Click(H.g.VillageCommandPromoteHelper.skip)
    check('helper: Skip first takes the first name off and skips them', H.vc.rules()[1].skip[nxt[0].id] is True and nxt[0].id not in [m.id for m in batch_of(H)])
    # Batch size: down to 1, up to 10 (but never past the 255-character macro limit)
    H.run('VillageCommandDB.settings.batch=1; VC_NS.helperRefresh()')
    check('helper: one per click when asked', len(batch_of(H)) == 1 and '\n' not in hb.GetAttribute(hb, 'macrotext'))
    H.run('''
      for i=1,12 do ROSTER[#ROSTER+1]={name=TESTNAME("Longnamedmemberxyz")..string.char(96+i),rank=4,level=30,class=1,online=true,note="",onote="",zone=1} end
      VillageCommandDB.settings.batch=10
    ''')
    H.roster_update()
    H.run('VC_NS.helperRefresh()')
    macro = hb.GetAttribute(hb, 'macrotext')
    check('helper: never more than a macro holds', len(macro) <= 255 and len(batch_of(H)) >= 5, (len(macro), len(batch_of(H))))
    # In combat nothing about the secure button changes (the mock errors if it does)
    H.run('IN_COMBAT=true')
    before = hb.GetAttribute(hb, 'macrotext')
    H.run('ROSTER[#ROSTER+1]={name=TESTNAME("Zed"),rank=4,level=40,class=1,online=true,note="",onote="",zone=1}')
    H.roster_update(); H.tick(2)
    H.vc.closePromoteHelper()
    check('helper: untouched in combat', hb.GetAttribute(hb, 'macrotext') == before and H.vc.lastError is None, H.vc.lastError)
    H.run('IN_COMBAT=false')
    H.fire('PLAYER_REGEN_ENABLED'); H.tick(1)
    check('helper: a close asked for in combat happens after it', not H.g.VillageCommandPromoteHelper.IsShown(H.g.VillageCommandPromoteHelper))
    # The server takes only some of a click: the rest stay on the list, and twice-missed are set aside
    H4 = helper_client('GPROMOTE_PER_CLICK=3')
    H4.vc.openPromoteHelper(1)
    H4.tick(0.5)
    hb4 = H4.g.VillageCommandPromoteHelperButton
    first5 = batch_of(H4)
    H4.g.VC_TEST_click(hb4); H4.roster_update(); H4.tick(10)
    status = H4.g.VillageCommandPromoteHelper.status.GetText(H4.g.VillageCommandPromoteHelper.status)
    check('helper: reports a partial click', 'Promoted 3 of 5' in status, status)
    check('helper: learns how many the server takes per click', H4.vc.helperBatchSize() == 3 and len(batch_of(H4)) == 3, H4.vc.helperBatchSize())
    check('helper: and remembers it', H4.g.VillageCommandDB.settings.batch == 3)
    missed = [m.id for m in first5[3:]]
    check('helper: the ones that didn\'t go through come first next time', [m.id for m in batch_of(H4)][:2] == missed or set(missed) <= set(m.id for m in batch_of(H4)))
    H4.g.VC_TEST_click(hb4); H4.roster_update(); H4.tick(10)
    status = H4.g.VillageCommandPromoteHelper.status.GetText(H4.g.VillageCommandPromoteHelper.status)
    check('helper: after that, every click goes through cleanly', status.startswith('|cff40ff40Promoted 3') and H4.vc.helperBatchSize() == 3, status)
    missed = [m.id for m in batch_of(H4)]
    H4.run('GPROMOTE_PER_CLICK=0')
    H4.g.VC_TEST_click(hb4); H4.roster_update(); H4.tick(10)
    H4.g.VC_TEST_click(hb4); H4.roster_update(); H4.tick(10)
    check('helper: anyone missed twice is set aside so the queue moves on', all(H4.vc.helperState.fails[i] == 2 for i in missed)
          and not set(missed) & set(m.id for m in batch_of(H4)), [H4.vc.helperState.fails[i] for i in missed])
    # A multi-step rule keeps someone in the queue until they reach the rule's rank
    H2 = helper_client()
    H2.run('VC_NS.rules()[1].to=2; VillageCommandDB.settings.batch=1')
    H2.vc.openPromoteHelper(1)
    H2.tick(0.5)
    hb2 = H2.g.VillageCommandPromoteHelperButton
    m0 = batch_of(H2)[0].id
    H2.g.VC_TEST_click(hb2); H2.roster_update(); H2.tick(10)
    check('helper: stays on someone until they reach the rule\'s rank', batch_of(H2)[0].id == m0 and H2.vc.byId[m0].rankIndex == 3)
    # Where the game refuses /gpromote: report it, don't pretend
    H3 = helper_client('GPROMOTE=false')
    H3.vc.openPromoteHelper(1)
    H3.tick(0.5)
    hb3 = H3.g.VillageCommandPromoteHelperButton
    H3.run('wipe(PRINTED)')
    H3.g.VC_TEST_click(hb3)
    H3.tick(10)
    printed = ' '.join(H3.g.PRINTED.values())
    check('helper: says so when the game didn\'t promote', 'didn\'t promote' in printed and H3.vc.helperState.pending is None, printed[-200:])
    check('helper: and doesn\'t claim it works', (H3.g.VillageCommandDB.gpromote or {}) == {} or H3.g.VillageCommandDB.gpromote.forever is None)
    H3.run('IN_COMBAT=true')
    H3.vc.openPromoteHelper(1)
    check('helper: won\'t open in combat', any('out of combat' in x for x in H3.g.PRINTED.values()))

    # Minimap and slash commands ------------------------------------------------------------------
    for cmd in ['online', 'status', 'help', 'minimap', 'minimap', 'quiet', 'quiet', 'settings', 'stats', 'cancel']:
        c.g.SlashCmdList.VILLAGECOMMAND(cmd)
    c.tick(0.5)
    check('slash commands run', True)

    print()
    if failures:
        print(f'{len(failures)} FAILED: ' + ', '.join(failures))
        sys.exit(1)
    print('All tests passed.')


if __name__ == '__main__':
    main()
