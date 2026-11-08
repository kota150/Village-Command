# Village Command

**Run your guild from one window.** Village Command is a guild overview and progression suite: see everyone who's online, manage the roster with notes and officer notes, promote and demote one member or fifty at once, and watch the guild grow with progression tracking and fun stats. It also brings your other guild addons, **GuildForge** and **Un-Nina Bank**, into the same window.

Built for **WoW Forever**, and also works on **Classic Era** and **Retail**.

## Features

### Overview
Members, online now, members at the level cap and the average level at a glance, the message of the day, **everyone online** (sorted by rank, with level and zone), the latest guild activity, and the state of your other guild addons.

### Roster
The whole guild in one fast list: class-colored names, level, rank, zone (or how long since they were online), public note and officer note.

- **Search** names, notes, officer notes, zones, classes and ranks.
- **Filter** to online only, one rank, a level range, or members away 14, 30 or 90+ days. Click a column to sort.
- **Click a member** to edit their public note and officer note right there, or to promote or demote them. **Right-click** to whisper, invite, promote, demote or tick them.

### Mass promote, demote and notes
Tick members, shift-click a range, or tick everyone the filters show, then:

- **Promote**, **Demote** or **Set rank** for all of them.
- Set **public notes** or **officer notes**: replace, add to the end, add to the start, or clear. `{date}`, `{level}`, `{rank}`, `{class}` and `{name}` fill in per member, and a preview shows the result.

Village Command asks first and names who's affected. Changes go out one at a time a moment apart (adjustable in Settings) so the server accepts every one, pause during combat, and can be cancelled part way. It follows the game's rules: you can only move members ranked below you, never to your own rank or above, and anyone it can't change is skipped with the reason.

### Progression
Milestones (roster size, members at the level cap, average level, professions covered), this week's levels gained, joins, leaves and promotions, **top climbers** over 7 or 30 days, and an activity feed of joins, leaves, level milestones and rank changes.

### Fun Stats
Peak online, busiest hour, today's hot spot, the rarest class, and superlatives: **Ding champion**, **Night owl**, **Early bird**, **Always around**, **Fresh blood**, **Wanderer**, **Alt army** (from "Alt of ..." notes), **Blank slates** and **Achievement hunter** (Retail). Plus online-by-hour, class, level and rank charts.

History is recorded by your client as it sees the roster, so Progression and Fun Stats fill in over the days you play. It stays on your PC (nothing is sent to guildmates); turn it off or reset it in Settings.

### With GuildForge and Un-Nina Bank
Both are optional. When they're installed:

- **[GuildForge](https://github.com/TheFrosty02/GuildForge)**: a **Professions** page with each profession's members, top skill and online crafters, a list of crafters online now, and professions in every member's tooltip.
- **[Un-Nina Bank](https://github.com/kota150/GuildBankToons)**: a **Guild Bank** page with bank gold and its 14-day history, bank toons and tabs, and open requests, with buttons straight to the bank's Requests, Ledger and Goals. Bank toons are tagged in the roster.

The **GuildForge** and **Un-Nina Bank** buttons at the top of the window open those addons directly.

## Commands

| Command | What it does |
| --- | --- |
| `/vc` | Open or close the window (also `/village`, `/villagecommand`) |
| `/vc roster`, `progress`, `stats`, `forge`, `bank` | Open a page |
| `/vc online` | List who's online in chat |
| `/vc settings` | Open settings |
| `/vc cancel` | Stop a mass change part way |
| `/vc status` | Show what your rank is allowed to do |
| `/vc minimap` | Show or hide the minimap button |
| `/vc quiet` | Only print messages for things you did |

## Installing

Get it from [CurseForge](https://www.curseforge.com/projects/1792191) or the CurseForge app.

### From source

The addon folder must be named `VillageCommand`. Copy or link this repository into `Interface/AddOns/VillageCommand`.

## Tests

`tests/run_tests.py` runs the addon in a stand-in WoW environment with a simulated guild (WoW's Lua 5.1, through lupa): loading, every page, filters, mass promote / demote / set rank, mass notes, progression tracking, the GuildForge and Un-Nina Bank pages, and WoW Forever names.

```bash
python3 -m venv .venv && .venv/bin/pip install lupa && .venv/bin/python tests/run_tests.py
```
