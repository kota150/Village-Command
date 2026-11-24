#!/usr/bin/env python3
"""Village Command Discord companion: Village Points standings, raid results and loot on Discord.

Reads the addon's SavedVariables file (VillageCommand.lua, written when you log out or /reload) and,
through webhooks:
  * keeps one Standings message up to date: everyone's Village Points, Loot Points and priority, the
    same numbers the addon shows (decay worked out from the dates, exactly as the addon does), plus the
    top of the Renown board;
  * posts each settled raid once (bosses, who earned what) and edits it if officers re-settle it;
  * posts each loot award ("Mira received Gloves of Prophecy for 50 Loot Points"), struck through if an
    officer undoes it;
  * optionally sends the officers' flags (reports that disagreed with the result) to a separate channel.
Every guildmate running the addon has the whole ledger, so anyone can run this, not just an officer.

Python 3.8+, standard library only.

    python3 villagecommand_discord.py --dry-run            # print what would be posted
    python3 villagecommand_discord.py                      # post or update once
    python3 villagecommand_discord.py --watch              # keep running, update after every logout/reload
    python3 villagecommand_discord.py --export exports     # write standings.csv, points.csv and raids.csv

Settings come from villagecommand.json next to this script (see villagecommand.example.json), overridden
by command-line flags. The webhook URL can also come from the VILLAGECOMMAND_WEBHOOK environment variable.
"""

import argparse
import csv
import datetime
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "villagecommand.json")
STATE_PATH = os.path.join(HERE, ".villagecommand_state.json")
USER_AGENT = "VillageCommand-Companion (https://github.com/kota150, 1.0)"
DEFAULT_WOW_DIRS = [
    "/Applications/World of Warcraft",
    "C:/Program Files (x86)/World of Warcraft",
    "C:/Program Files/World of Warcraft",
]
FLAVORS = ["_forever_", "_classic_era_", "_retail_"]
DESCRIPTION_LIMIT = 4000
DAY, WEEK = 86400, 7 * 86400
# The same numbers as Points.lua: weeks start Tuesday 15:00 UTC, points older than 26 weeks drop off.
EPOCH, WINDOW = 486000, 26
RULE_DEFAULTS = {"onTime": 10, "perBoss": 15, "perHour": 0, "bench": 50, "decay": 10, "base": 50,
                 "quorum": 3, "grace": 15, "scale": 100, "minGuild": 5}
GREEN, ORANGE, GOLD = 0x40FF40, 0xFF9A40, 0xE7C483


# --- SavedVariables (Lua) parser ------------------------------------------------------------------

class LuaParser:
    """Parses the subset of Lua that WoW writes to SavedVariables: `Name = value` assignments of
    tables, strings, numbers, booleans and nil."""

    def __init__(self, text):
        self.s = text
        self.i = 0

    def error(self, msg):
        line = self.s.count("\n", 0, self.i) + 1
        raise ValueError(f"SavedVariables parse error on line {line}: {msg}")

    def skip(self):
        s, n = self.s, len(self.s)
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                end = s.find("\n", self.i)
                self.i = n if end < 0 else end + 1
            else:
                break

    def peek(self):
        self.skip()
        return self.s[self.i] if self.i < len(self.s) else ""

    def expect(self, ch):
        if self.peek() != ch:
            self.error(f"expected {ch!r}")
        self.i += 1

    def name(self):
        self.skip()
        start = self.i
        while self.i < len(self.s) and (self.s[self.i].isalnum() or self.s[self.i] == "_"):
            self.i += 1
        if start == self.i:
            self.error("expected a name")
        return self.s[start:self.i]

    def string(self):
        quote = self.s[self.i]
        self.i += 1
        out = []
        escapes = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}
        while True:
            if self.i >= len(self.s):
                self.error("unterminated string")
            c = self.s[self.i]
            if c == quote:
                self.i += 1
                return "".join(out)
            if c == "\\":
                nxt = self.s[self.i + 1]
                if nxt.isdigit():
                    j = self.i + 1
                    while j < self.i + 4 and j < len(self.s) and self.s[j].isdigit():
                        j += 1
                    out.append(chr(int(self.s[self.i + 1:j])))
                    self.i = j
                    continue
                out.append(escapes.get(nxt, nxt))
                self.i += 2
                continue
            out.append(c)
            self.i += 1

    def number(self):
        start = self.i
        if self.s[self.i] == "-":
            self.i += 1
        while self.i < len(self.s) and (self.s[self.i].isalnum() or self.s[self.i] in ".+-"):
            if self.s[self.i] in "+-" and self.s[self.i - 1] not in "eE":
                break
            self.i += 1
        raw = self.s[start:self.i]
        try:
            return int(raw, 0)
        except ValueError:
            return float(raw)

    def value(self):
        c = self.peek()
        if c == "{":
            return self.table()
        if c in "\"'":
            return self.string()
        if c.isdigit() or c in "-.":
            return self.number()
        word = self.name()
        if word == "true":
            return True
        if word == "false":
            return False
        if word == "nil":
            return None
        self.error(f"unexpected {word!r}")

    def table(self):
        self.expect("{")
        result, index = {}, 1
        while self.peek() != "}":
            if self.peek() == "[":
                self.i += 1
                k = self.value()
                self.expect("]")
                self.expect("=")
                result[k] = self.value()
            else:
                save = self.i
                c = self.peek()
                if c.isalpha() or c == "_":
                    word = self.name()
                    if self.peek() == "=":
                        self.i += 1
                        result[word] = self.value()
                    else:
                        self.i = save
                        result[index] = self.value()
                        index += 1
                else:
                    result[index] = self.value()
                    index += 1
            if self.peek() in ",;":
                self.i += 1
        self.expect("}")
        return result

    def document(self):
        out = {}
        while self.peek():
            name = self.name()
            self.expect("=")
            out[name] = self.value()
        return out


def load_saved_variables(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return LuaParser(f.read()).document()


def find_saved_variables(wow_dir, account=None):
    dirs = [wow_dir] if wow_dir else DEFAULT_WOW_DIRS
    found = []
    for base in dirs:
        for flavor in FLAVORS:
            pattern = os.path.join(base, flavor, "WTF", "Account", account or "*", "SavedVariables", "VillageCommand.lua")
            found.extend(glob.glob(pattern))
    # Most recently written first: that's the copy from the latest logout.
    return sorted(found, key=os.path.getmtime, reverse=True)


def as_list(value):
    """Lua arrays arrive as {1: a, 2: b}; give them back as a list."""
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [value[k] for k in sorted(k for k in value if isinstance(k, int))]
    return []


# --- Village Points, worked out exactly as the addon does -----------------------------------------

def rule(guild, key):
    rules = (guild.get("vp") or {}).get("rules") or {}
    value = rules.get(key)
    return RULE_DEFAULTS[key] if value is None else value


def week(t):
    return (int(t) - EPOCH) // WEEK


def factor(guild, t, now):
    w = max(0, week(now) - week(t))
    if w >= WINDOW:
        return 0.0
    return (1 - rule(guild, "decay") / 100) ** w


def member_name(guild, member_id, fallback=None):
    rec = (guild.get("members") or {}).get(member_id) or {}
    return rec.get("name") or fallback or member_id


def standings(guild, now=None):
    """Everyone with points: dicts with id, name, vp, lp, pr, raids, last; highest priority first."""
    now = now or time.time()
    vp = guild.get("vp") or {}
    raids = vp.get("raids") or {}
    base = rule(guild, "base")
    by = {}
    for e in (vp.get("led") or {}).values():
        if e.get("x"):
            continue
        f = factor(guild, e["t"], now)
        if f <= 0:
            continue
        who = e["who"]
        s = by.setdefault(who, {"id": who, "name": member_name(guild, who, e.get("n")), "vp": 0.0, "lp": float(base),
                                "raids": set(), "last": 0})
        if e.get("k") == "l":
            s["lp"] += e["amt"] * f
        else:
            s["vp"] += e["amt"] * f
        raid = e["id"].split(".", 1)[0] if "." in e["id"] else None
        if raid and raid in raids and e["t"] >= now - 30 * DAY:
            s["raids"].add(raid)
        s["last"] = max(s["last"], e["t"])
    out = []
    for s in by.values():
        s["raids"] = len(s["raids"])
        s["lp"] = max(1.0, s["lp"])
        s["pr"] = max(0.0, s["vp"]) / s["lp"]
        out.append(s)
    out.sort(key=lambda s: (-s["pr"], -s["vp"], s["name"]))
    return out


def renown(guild, now=None):
    """The community score: 3 per event attended (60 days), 5 per bounty earned (90 days), 1 per level (30 days)."""
    now = now or time.time()
    members = guild.get("members") or {}
    by_name = {(rec.get("name") or "").lower(): mid for mid, rec in members.items()}
    scores = {}

    def add(mid, field, n):
        if mid not in members:
            return
        s = scores.setdefault(mid, {"id": mid, "name": member_name(guild, mid), "events": 0, "bounties": 0, "levels": 0})
        s[field] += n

    board = guild.get("board") or {}
    for ev in (board.get("ev") or {}).values():
        if ev.get("att") and not ev.get("x") and ev.get("t", 0) >= now - 60 * DAY:
            for mid in ev["att"]:
                add(mid, "events", 1)
    for bo in (board.get("bo") or {}).values():
        if bo.get("st") == "d" and bo.get("done") and bo.get("u", 0) >= now - 90 * DAY:
            mid = by_name.get(bo["done"].lower())
            if mid:
                add(mid, "bounties", 1)
    cutoff = now - 30 * DAY
    for mid, rec in members.items():
        before, top = None, 0
        for e in as_list(rec.get("levels")):
            e = as_list(e)
            if len(e) < 2:
                continue
            if e[0] < cutoff:
                before = e[1]
            elif e[1] > top:
                top = e[1]
        if before and top > before:
            add(mid, "levels", top - before)
    out = []
    for s in scores.values():
        s["score"] = s["events"] * 3 + s["bounties"] * 5 + s["levels"]
        if s["score"] > 0:
            out.append(s)
    out.sort(key=lambda s: (-s["score"], s["name"]))
    return out


def raid_entries(guild, key):
    """What each guildmate earned from one raid (bench included), most first."""
    out = []
    for e in ((guild.get("vp") or {}).get("led") or {}).values():
        if e["id"].startswith(key + ".") and not e.get("x") and e.get("k") == "v":
            out.append(e)
    out.sort(key=lambda e: (-e["amt"], e.get("n") or ""))
    return out


# --- Building the Discord messages ----------------------------------------------------------------

def day(t):
    return datetime.datetime.fromtimestamp(t).strftime("%a %d %b")


def build_standings_message(guild_name, guild, top, now=None):
    now = now or time.time()
    rows = standings(guild, now)
    lines = [f"{'#':>2}  {'Name':<16} {'VP':>5} {'LP':>5} {'Prio':>5} {'Raids':>5}"]
    for i, s in enumerate(rows[:top], 1):
        lines.append(f"{i:>2}  {s['name'][:16]:<16} {round(s['vp']):>5} {round(s['lp']):>5} {s['pr']:>5.2f} {s['raids']:>5}")
    if not rows:
        lines.append("Nobody has Village Points yet.")
    text = "```\n" + "\n".join(lines) + "\n```"
    if len(rows) > top:
        text += f"\n+{len(rows) - top} more in the addon (/vc points)."
    fields = []
    board = renown(guild, now)
    if board:
        fields.append({"name": "Renown", "inline": False,
                       "value": "\n".join(f"**{s['name']}** {s['score']}" for s in board[:5])})
    footer = (f"Priority = Village Points ÷ Loot Points · base {rule(guild, 'base')} · "
              f"{rule(guild, 'decay')}% decay a week")
    return {"username": "Village Command", "embeds": [{
        "title": f"Village Points: {guild_name.split(' - ')[0]}",
        "description": text[:DESCRIPTION_LIMIT], "color": GOLD, "fields": fields,
        "footer": {"text": footer}, "timestamp": datetime.datetime.utcfromtimestamp(now).isoformat() + "Z"}]}


def build_raid_message(guild, raid):
    bosses = as_list(raid.get("bosses"))
    earned = raid_entries(guild, raid["key"])
    lines = [f"**Bosses ({len(bosses)}):** " + (", ".join(bosses) if bosses else "none")]
    if earned:
        lines.append("")
        lines.append("**Village Points earned:**")
        for e in earned:
            why = e.get("why") or ""
            tag = " (bench)" if why.startswith("Bench") else (" (on time)" if "on time" in why else "")
            lines.append(f"{member_name(guild, e['who'], e.get('n'))}: +{e['amt']}{tag}")
    text = "\n".join(lines)
    if len(text) > DESCRIPTION_LIMIT:
        text = text[:DESCRIPTION_LIMIT - 20] + "\n…and more"
    start = datetime.datetime.fromtimestamp(raid["t"])
    return {"username": "Village Command", "embeds": [{
        "title": f"{raid.get('iname') or 'Raid'}: {start.strftime('%a %d %b, %H:%M')}",
        "description": text, "color": GREEN,
        "footer": {"text": f"Settled from {raid.get('rep') or 0} reports by {raid.get('by') or '?'}"}}]}


def build_flags_message(raid):
    flags = as_list(raid.get("fl"))
    return {"username": "Village Command", "content": (
        f"⚠️ **{raid.get('iname') or 'Raid'}** ({day(raid['t'])}), flagged for officers:\n" + "\n".join(f"• {f}" for f in flags))[:1900]}


def build_loot_message(entry):
    text = (f"🎁 **{entry.get('n')}** received **{entry.get('why') or 'loot'}** for {entry['amt']} Loot Points"
            f" (awarded by {entry.get('by') or '?'})")
    if entry.get("x"):
        text = f"~~{text}~~ (undone)"
    return {"username": "Village Command", "content": text}


def export_csv(data, folder, guild_filter=None):
    os.makedirs(folder, exist_ok=True)
    written = []
    now = time.time()
    for guild_name, guild in (data.get("guilds") or {}).items():
        if guild_filter and guild_filter.lower() not in guild_name.lower():
            continue
        safe = "".join(c if c.isalnum() else "_" for c in guild_name).strip("_")
        path = os.path.join(folder, f"{safe}_standings.csv")
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["place", "name", "village_points", "loot_points", "priority", "raids_30_days"])
            for i, s in enumerate(standings(guild, now), 1):
                w.writerow([i, s["name"], round(s["vp"], 1), round(s["lp"], 1), round(s["pr"], 3), s["raids"]])
        written.append(path)
        path = os.path.join(folder, f"{safe}_points.csv")
        led = sorted(((guild.get("vp") or {}).get("led") or {}).values(), key=lambda e: e["t"])
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["date", "name", "kind", "points", "reason", "by", "undone"])
            for e in led:
                w.writerow([datetime.datetime.fromtimestamp(e["t"]).strftime("%Y-%m-%d %H:%M"), e.get("n"),
                            "loot" if e.get("k") == "l" else "village", e["amt"], e.get("why") or "", e.get("by") or "",
                            "yes" if e.get("x") else ""])
        written.append(path)
        path = os.path.join(folder, f"{safe}_raids.csv")
        raids = sorted(((guild.get("vp") or {}).get("raids") or {}).values(), key=lambda r: r["t"])
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["date", "instance", "bosses", "guildmates", "reports", "settled_by"])
            for r in raids:
                w.writerow([datetime.datetime.fromtimestamp(r["t"]).strftime("%Y-%m-%d %H:%M"), r.get("iname"),
                            "; ".join(as_list(r.get("bosses"))), r.get("att"), r.get("rep"), r.get("by")])
        written.append(path)
    return written


# --- Discord webhook -------------------------------------------------------------------------------

def request(method, url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json", "User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read()
        return json.loads(body) if body else {}


def publish(webhook, message_id, payload):
    """Edits the existing message, or posts a new one if there isn't one (or it was deleted)."""
    base = webhook.split("?")[0].rstrip("/")
    if message_id:
        try:
            request("PATCH", f"{base}/messages/{message_id}", payload)
            return message_id
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
    return request("POST", f"{base}?wait=true", payload)["id"]


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def run_once(args, state, now=None):
    path = args.savedvars or (find_saved_variables(args.wow_dir, args.account) or [None])[0]
    if not path or not os.path.exists(path):
        settings = (f"Settings read from {CONFIG_PATH}." if os.path.exists(CONFIG_PATH)
                    else f"No settings file at {CONFIG_PATH} (copy villagecommand.example.json to that name).")
        if args.savedvars:
            tried = f"There's no file at the savedvars path:\n  {args.savedvars}"
        else:
            dirs = [args.wow_dir] if args.wow_dir else DEFAULT_WOW_DIRS
            tried = "Looked for _forever_/WTF/Account/*/SavedVariables/VillageCommand.lua (or _classic_era_) under:\n  " + "\n  ".join(dirs)
        sys.exit(f"Couldn't find VillageCommand.lua.\n{tried}\n{settings}\nSet \"savedvars\" to the file's full path, or pass --savedvars.")
    data = load_saved_variables(path).get("VillageCommandDB") or {}
    now = now or time.time()
    posted = []

    def post(webhook, message_id, payload, what):
        if args.dry_run:
            print(json.dumps(payload, indent=2, ensure_ascii=False))
            return message_id or "dry-run"
        mid = publish(webhook, message_id, payload)
        posted.append(what)
        print(what)
        time.sleep(1)  # stay well inside the webhook rate limit
        return mid

    for guild_name, guild in (data.get("guilds") or {}).items():
        if args.guild and args.guild.lower() not in guild_name.lower():
            continue
        vp = guild.get("vp") or {}
        if not vp.get("led") and not vp.get("raids"):
            continue
        gstate = state.setdefault(guild_name, {})
        # Standings: one message, edited whenever the numbers change.
        if not args.no_standings:
            payload = build_standings_message(guild_name, guild, args.top, now)
            fingerprint = json.dumps(payload["embeds"][0]["description"]) + json.dumps(payload["embeds"][0]["fields"])
            seen = gstate.setdefault("standings", {})
            if args.force or seen.get("fingerprint") != fingerprint:
                seen["message"] = post(args.webhook, seen.get("message"), payload, f"Updated the standings for {guild_name}.")
                seen["fingerprint"] = fingerprint
        # The first run only takes note of raids and loot already there, so it doesn't flood the channel.
        first_run = "raids" not in gstate and not args.backfill
        raids_seen = gstate.setdefault("raids", {})
        for key, raid in sorted((vp.get("raids") or {}).items(), key=lambda kv: kv[1]["t"]):
            if args.no_raids:
                break
            seen = raids_seen.get(key)
            payload = build_raid_message(guild, raid)
            fingerprint = json.dumps(payload, sort_keys=True)
            if first_run:
                raids_seen[key] = {"fingerprint": fingerprint, "skipped": True}
                continue
            if seen and (seen.get("fingerprint") == fingerprint or seen.get("skipped")):
                continue
            seen = seen or {}
            seen["message"] = post(args.raids_webhook or args.webhook, seen.get("message"), payload,
                                   f"Posted {raid.get('iname') or 'a raid'} ({day(raid['t'])}).")
            seen["fingerprint"] = fingerprint
            raids_seen[key] = seen
            flags = as_list(raid.get("fl"))
            if args.officer_webhook and flags and seen.get("flags") != len(flags):
                seen["flagsMessage"] = post(args.officer_webhook, seen.get("flagsMessage"), build_flags_message(raid),
                                            f"Sent {len(flags)} flags to officers.")
                seen["flags"] = len(flags)
        loot_seen = gstate.setdefault("loot", {})
        for eid, e in sorted((vp.get("led") or {}).items(), key=lambda kv: kv[1]["t"]):
            if args.no_loot or e.get("k") != "l":
                continue
            seen = loot_seen.get(eid)
            undone = bool(e.get("x"))
            if first_run:
                loot_seen[eid] = {"undone": undone, "skipped": True}
                continue
            if seen and (seen.get("undone") == undone or seen.get("skipped")):
                continue
            if not seen and undone:
                loot_seen[eid] = {"undone": True}
                continue
            seen = seen or {}
            seen["message"] = post(args.loot_webhook or args.webhook, seen.get("message"), build_loot_message(e),
                                   f"Posted loot: {e.get('n')}, {e.get('why')}.")
            seen["undone"] = undone
            loot_seen[eid] = seen
        if first_run:
            print(f"First run for {guild_name}: took note of {len(raids_seen)} raids and {len(loot_seen)} loot awards "
                  "already there (use --backfill to post them).")
    if args.export:
        for written in export_csv(data, args.export, args.guild):
            print(f"Wrote {written}")
    if not args.dry_run:
        with open(STATE_PATH, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)
    return path, posted


def main():
    config = load_json(CONFIG_PATH, {})
    p = argparse.ArgumentParser(description="Post Village Points standings, raids and loot to Discord.")
    p.add_argument("--webhook", default=os.environ.get("VILLAGECOMMAND_WEBHOOK") or config.get("webhook"))
    p.add_argument("--savedvars", default=config.get("savedvars"), help="path to SavedVariables/VillageCommand.lua")
    p.add_argument("--wow-dir", default=config.get("wow_dir"), help="World of Warcraft install folder")
    p.add_argument("--account", default=config.get("account"), help="WTF account folder name")
    p.add_argument("--guild", default=config.get("guild"), help="only post guilds whose name contains this")
    p.add_argument("--top", type=int, default=config.get("top", 25), help="how many places the standings show")
    p.add_argument("--raids-webhook", default=config.get("raids_webhook"),
                   help="separate webhook (channel) for raid results; defaults to --webhook")
    p.add_argument("--loot-webhook", default=config.get("loot_webhook"),
                   help="separate webhook (channel) for loot awards; defaults to --webhook")
    p.add_argument("--officer-webhook", default=config.get("officer_webhook"),
                   help="webhook for an officers' channel: flags on raids (reports that disagreed); off when blank")
    p.add_argument("--no-standings", action="store_true", default=config.get("no_standings", False))
    p.add_argument("--no-raids", action="store_true", default=config.get("no_raids", False))
    p.add_argument("--no-loot", action="store_true", default=config.get("no_loot", False))
    p.add_argument("--backfill", action="store_true", help="on the first run, post the raids and loot already there")
    p.add_argument("--export", metavar="FOLDER", default=config.get("export"),
                   help="also write standings, points and raids CSV files to this folder after every update")
    p.add_argument("--watch", action="store_true", help="keep running and update after every save")
    p.add_argument("--interval", type=int, default=config.get("interval", 15), help="seconds between checks")
    p.add_argument("--dry-run", action="store_true", help="print the messages instead of posting")
    p.add_argument("--force", action="store_true", help="post the standings even if nothing changed")
    args = p.parse_args()
    if args.export and not args.webhook and not args.dry_run:
        args.dry_run = True
        args.no_standings = args.no_raids = args.no_loot = True
    if not args.webhook and not args.dry_run:
        sys.exit("No webhook URL. Set it in villagecommand.json, VILLAGECOMMAND_WEBHOOK, or --webhook.")

    state = load_json(STATE_PATH, {})
    path, _ = run_once(args, state)
    if not args.watch:
        return
    print(f"Watching {path} (Ctrl-C to stop).")
    last = os.path.getmtime(path)
    while True:
        time.sleep(args.interval)
        try:
            mtime = os.path.getmtime(path)
            # Decay ticks over at the weekly reset even without a save, so look again every hour too.
            if mtime != last or int(time.time()) % 3600 < args.interval:
                time.sleep(2)  # let WoW finish writing the file
                last = mtime
                run_once(args, state)
        except (OSError, ValueError, urllib.error.URLError) as e:
            print(f"Skipped an update: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
