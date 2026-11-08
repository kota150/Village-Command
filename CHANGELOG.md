# Changelog

All notable changes to Village Command are listed here.

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
