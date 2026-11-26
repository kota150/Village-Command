# Changelog

All notable changes to Village Command are listed here.

## [1.4.0] - 2026-11-26

### Added
- **Top recruiters** on the Progression page: who brought in the guildmates who are still here.
  - Read from the game's guild event log, the server's own record of who invited whom, so it can't be faked.
  - A recruit counts while they're in the guild. Leaving takes them off the board, and someone who comes back counts for whoever invited them back. Invites that were never accepted don't count.
  - The log only holds the last 100 or so events, so Village Command reads it every few minutes and shares what it finds with guildmates. A trusted rank's list is taken on its word; anyone else's needs a second guildmate's to agree.
  - Hover a recruiter to see who they brought in. Member tooltips say who invited them.
  - Also `/vc recruits`, or `/vc recruits Name`. `/vc status` and `/vc sync` cover recruits too.

## [1.3.0] - 2026-11-23

### Added
- **Village Points tab: raid points and loot priority.**
  - Raiding earns Village Points: on time, each boss kill, and optionally each hour.
  - Loot costs Loot Points, which officers award with a cost suggested from the item's level and slot.
  - Priority is Village Points ÷ Loot Points, with a base so newcomers don't jump the queue.
  - Both fade by a set share each week, worked out from the dates so every copy agrees.
  - Standings show everyone's points, priority and raids, and each person's history on hover.
  - Officers can award loot, adjust points with a reason, bench, undo, and change the rules. Everyone's standings follow a rule change.
  - Also `/vc points`.
- **Raids are counted from everyone's notes.** Nothing is sent inside an instance. Each Village Command keeps a report of who was in the raid (online, same zone) and for how long, and every boss kill with who was there. Once you're out, it goes to the officers.
  - An officer's Village Command settles the raid. Yes/no questions go by majority vote, numbers use the median, and the raid needs 3 reports or an officer's.
  - Late reports within half an hour are counted in.
  - Reports that disagree, such as kills nobody else saw, are flagged for officers.
  - Unsettled reports are sent again when an officer comes out of the instance.
  - Guildmates without the addon earn points from the others' reports.
- **Renown**: a community score from events attended, bounties earned and levels gained. It's never used for loot.
- **Discord companion** (`companion/villagecommand_discord.py`, in the GitHub repository only):
  - keeps a standings message up to date, with the same numbers as the addon;
  - posts each raid and each loot award;
  - sends flags to an officers' channel;
  - exports CSV files.
- Member tooltips show Village Points, Loot Points and priority. `/vc status` and `/vc sync` cover Village Points too.

### Fixed
- Long explanations at the top of a page wrap onto as many lines as they need instead of being cut off with "...".
- The page no longer shows through the event, bounty and Village Points dialogs.
- Attendance passed on by a guildmate who isn't the leader or an officer is no longer refused. It keeps the name of whoever took it. Before, a guildmate logging in later could miss an event's attendance.

## [1.2.1] - 2026-11-19

### Fixed
- Drop-down menus (like the event date picker) draw above dialog buttons instead of having them show through, and long lists wrap into columns so they stay on screen.
- Settings descriptions wrap inside their own column and each setting makes room for its description, so nothing overlaps.

## [1.2.0] - 2026-11-19

### Added
- **Events tab: signups and attendance.** Plan a raid, dungeon run, PvP night or get-together with a day, time, size and note, and guildmates sign up as tank, healer or damage, or say maybe or can't. Each event shows who's coming by role and class. A reminder comes 15 minutes before and at the start. The leader or an officer can take attendance from their group or raid, and Village Command takes it on its own 15 minutes after the start if the leader is in a group, even inside the raid. **Regulars** lists who came to the most events in the last 60 days. **Announce in guild** posts one line in guild chat. Also `/vc events`.
- **Bounties tab: a guild bounty board.** Post what you need (type it, or shift-click an item), how many, a reward and how long it stays up. Guildmates say they're on it, their bag count shows for item bounties, and they mark it sent. The poster marks it done and names who earned it: it goes in the activity feed and on the **Bounty hunters** leaderboard. The reward is paid in the game; addons can't hold gold. Also `/vc bounties`.
- Events and bounties are shared with guildmates running Village Command as they change, and caught up at login like shared history. Only the leader or poster, or the trusted ranks, can change an event or bounty; signups and hunts only change their own person; and a different copy of one of your own records is answered with yours. `/vc sync` compares them too, and `/vc status` shows their counters.
- **Overview: Coming up** lists the next three events with your answer, and how many bounties are open. Member tooltips say what event they've signed up for and how many they've attended; the minimap tooltip shows the next event.
- Settings > Events and bounties: turn off the reminders, or the chat line when a guildmate posts an event or bounty.

## [1.1.4] - 2026-11-16

### Added
- **Hall of fame badges.** Whoever reached the level cap first wears a crown next to their name in the roster and the Hall of fame, and every member's tooltip says where they placed: "First in the guild to reach level 60", "3rd in the guild to reach level 60" and so on, with the date.
- **Welcome back.** When someone who's been away 30 days or more comes back online, it's in the activity feed and a line in chat says so. Click their name to whisper them. Turn the chat line off under Settings > Celebrations.

### Changed
- **The Hall of fame lists who reached the level cap first at the top**, instead of the most recent. It's kept as its own list, so first place stays first however long ago it was, and someone only comes off it by leaving the guild. Members already on it keep their dates.

## [1.1.3] - 2026-11-11

### Fixed
- **No more false demotions in the activity feed.** When the guild's ranks are reorganised (a rank added, removed or moved), everyone below it gets a new rank number without changing rank. Village Command read that as a demotion for each of them. It now compares rank names too, and treats five or more rank changes in one roster read as a reorganisation. False entries already recorded are removed at login, and history sharing won't bring them back from guildmates still on an older version.

## [1.1.2] - 2026-11-09

### Fixed
- **Logging out and the game menu (Esc) no longer say an action was blocked.** Village Command no longer adds its windows to the game's list of windows that Escape closes, and no longer uses Blizzard's shared popups for its questions. The game walks both when you open the menu or log out, and an addon's entries there make it block its own buttons. Escape still closes Village Command's windows, newest first, and its questions use a box of its own.

### Changed
- Village Command sits still in **instances** (dungeons, raids, battlegrounds) as well as in combat: no roster requests, history messages, samples or celebrations. It catches up when you leave. The window still opens and shows what it last saw.

## [1.1.1] - 2026-11-08

### Added
- `/vc blocked` lists every action the game blocked and blamed on Village Command this session: the function it named, how often, whether you were in combat, and which page was open. The first time the game blocks something Village Command didn't try itself, it says so once in chat.

### Fixed
- **No more "Interface actions failed" in combat.** Village Command now sits still while you're in combat: no roster requests or reads, redraws, history messages or samples. It catches up as soon as combat ends.
- Level 20/40/50 congratulations show in Village Command's own frame instead of Blizzard's raid warning frame, so the game's own boss and raid warnings aren't blocked and blamed on Village Command.
- Un-Ninja Bank is spelled correctly in the AddOns list and on the buttons.

## [1.1.0] - 2026-11-08

### Added
- **The Overview is a dashboard of graphs**, each in its own style: a beaded ring of the class mix, dot gauges for who's online and the level-cap club, a **Climbers of the week** podium, a **Race to the cap** leaderboard, a line graph of a typical day, a **weekly rhythm** heat map (day by hour), a **Hall of fame** of everyone who hit the cap, bars of levels gained per day and of the level spread, and who's online as a compact grid. Hover for details; click a name to open them in the roster.
- **Level-up celebrations.** When a guildmate passes one of your chosen levels (20, 40 and 50 to start), a raid-warning style message congratulates them on your screen; at the level cap, a banner with fireworks and the level-up fanfare. Choose the levels, or turn the message, the banner or the sound off, under Settings > Celebrations, with previews. Only level-ups seen while you're online count.
- **Promote helper (WoW Forever).** From a rule on the Promotions tab, a small window lines up the next few people on the list; each click of Promote has the game run a `/gpromote Name` line for each of them, as if you'd typed them. That works on Forever even though addons can't promote directly. Up to 5 per click by default (1 to 10, and as many as fit in a 255-character macro). Village Command checks the roster after each click: anyone who didn't go through stays at the front, the number per click drops to what the server actually took (and is remembered), anyone missed twice is set aside, and it says plainly if the game didn't promote anyone. It hides in combat and never changes during it. There's no chat command for notes.
- **Shared history.** Guildmates running Village Command compare notes at login: first-seen dates ("days in the guild"), level history and the activity feed now cover everyone's playtime, not just yours. It's light: a short hello at login, and only when someone's history differs, a few dozen small messages (about 50 bytes per member) at the game's pace. Joins, leaves, rank changes and earlier first-seen dates are only taken from trusted ranks (Settings > Trust shared history from), or for first-seen dates, two guildmates who agree. Turn it off under Settings. `/vc sync` compares now; `/vc status` shows the counters.
- **Promotions tab: a promotion checklist.** Officers set rules (from rank, to rank, minimum level, days in the guild, online within so many days) and Village Command lists everyone who qualifies, online first. On WoW Forever, work through it in the game's guild window; on Classic Era, **Promote all** does it in one go. Members drop off as the roster shows their new rank, and the week's promotions are listed under each rule. Right-click to skip someone, or switch a whole rule off and on again, keeping its settings. Ready members are flagged in tooltips, counted in the minimap tooltip, and on Forever the roster's bottom bar links straight to the checklist. Also `/vc promotions`.

### Changed
- The window is larger (900 by 680), with wider roster columns.
- **Minimap button:** now a guild tabard icon instead of "VC" text, laid out like other addons' minimap buttons. The AddOns list uses the same icon.
- **Roster, bottom of the page:** the member editor is always in its own panel (with a hint until you click someone), and the mass-action bar shows what's ticked on the left with Promote, Demote, Set rank, Public notes and Officer notes on the right. The actions appear once something is ticked, and make way for the progress and Cancel while changes go out.

### Fixed
- On WoW Forever, Village Command now recognises you by first name and surname, as the roster does.
- **"VillageCommand has been blocked from an action only available to the Blizzard UI"** on WoW Forever. Forever only lets its own guild window change ranks, public notes and officer notes, so Village Command no longer tries there: the roster is view-only on Forever (notes and ranks shown, searched and tracked, with a pointer to the guild window, J), without tick boxes, mass actions or dead buttons. Mass changes still work on Classic Era. If the game blocks any action anywhere else, Village Command stops the queue at once, says so in chat, and greys that action out with the reason, remembered per version of the game (`/vc unblock` tries again after a patch). `/vc status` lists what's blocked.
- Promote, demote and note changes for one member now happen straight from your click instead of a moment later.
- **Empty roster with 0 or 1 guildmates online, or more than 36** ("bad argument #2 to 'tonumber'"). The online count was being read as a number base. The roster now loads whatever the count.
- **Empty roster after logging in** ("0 members", "the roster hasn't loaded yet"), most often after switching characters. The game can deliver the roster during the loading screen, and the server ignores another roster request for a few seconds after GuildForge or Un-Ninja Bank asks, so Village Command never heard about it. It now reads the roster the game already has at login, when the window opens, on Refresh, and every so often while the window is open.
- One roster entry the game hands back oddly is skipped and reported once in chat (and in `/vc status`), instead of stopping the whole roster from loading.
- Pages no longer run under the scroll bar: rows, stat tiles and charts fit the visible width.
- **Professions page:** each row shows the member count by the name, the best crafter and their skill in the bar, and who's online on the right, without being cut off.

## [1.0.0] - 2026-11-08

First release. Built for **WoW Forever**; also runs on Classic Era and Retail.

### Overview
- Members, online now, members at the level cap and the average level at a glance, plus the message of the day.
- **Everyone online**, sorted by rank, with level and zone. Click anyone to open them in the roster.
- The latest guild activity, and the state of GuildForge and Un-Ninja Bank with buttons to open them.

### Roster
- The whole guild in one fast list (only the rows on screen are drawn, so big guilds scroll smoothly): name in class colors, level, rank, zone or time since last online, note and officer note.
- Search names, notes, officer notes, zones, classes and ranks. Filter by online only, rank, level (at the cap, half way, under 10) and time away (14, 30, 90+ days). Click a column to sort.
- Click a member to edit their **public note** and **officer note** in place, or promote / demote them. Right-click to whisper, invite, promote, demote or tick them.

### Mass actions
- Tick members (or shift-click a range, or tick everyone the filters show) and **Promote**, **Demote** or **Set rank** for all of them at once.
- **Public notes** and **officer notes** for everyone ticked: replace, add to the end, add to the start, or clear. `{date}`, `{level}`, `{rank}`, `{class}` and `{name}` fill in for each member, with a preview.
- Asks first, naming who's affected. Changes go out one at a time with a short pause (adjustable) so the server takes every one, wait out combat, and can be cancelled part way. Anyone your rank can't change is skipped with the reason.

### Progression
- Milestones: roster size, members at the level cap, average level, and (with GuildForge) professions covered and skills at 300.
- This week: levels gained, new members and leavers, promotions and demotions, most online at once.
- Top climbers over 7 or 30 days, and an activity feed of joins, leaves, level milestones and rank changes.

### Fun Stats
- Peak online, busiest hour, today's hot spot and the rarest class.
- Superlatives: Ding champion, Night owl, Early bird, Always around, Fresh blood, Wanderer, Alt army (from "Alt of ..." notes), Blank slates and Achievement hunter (Retail).
- Online by hour of day, and the guild by class, level and rank.

### Works with your other guild addons
- **GuildForge**: a Professions page with members, top skill and online crafters per profession, crafters online now, and professions in member tooltips.
- **Un-Ninja Bank**: a Guild Bank page with bank gold and its 14-day history, bank toons and tabs, and open requests, with buttons straight to the bank's tabs. Bank toons are tagged in the roster.
- Both are optional; their pages say how to get them when they're missing.

### Also
- "VC" minimap button with a green badge counting guildmates online; its tooltip lists who. It lines up with other addons' buttons and follows square minimaps.
- Opens from the minimap, the AddOns menu, Options → AddOns, or `/vc`.
