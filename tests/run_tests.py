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

    def __init__(self, setup=''):
        self.lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        if setup:
            self.lua.execute(setup)
        self.lua.execute(MOCK)
        loader = self.lua.eval('function(src) local c,e=loadstring(src,"@VillageCommand.lua"); if not c then error(e,0) end; VC_NS={}; c("VillageCommand",VC_NS) end')
        loader(ADDON)
        self.g = self.lua.globals()
        self.vc = self.g.VC_NS
        self.fire('PLAYER_LOGIN')
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
    check('Un-Nina Bank gold and requests', bank.gold == 1234567 and bank.open == 1 and len(bank.banks) == 2, (bank.gold, bank.open))
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
    check('opens an Un-Nina Bank tab', c2.g.BANK_OPENED == 'requests')

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
    check('Forever: promotes by name', c4.calls() == ['promote Memberca'], c4.calls())
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
    check('note dialog and menus run', True)

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
