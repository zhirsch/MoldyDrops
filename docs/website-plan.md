# MoldyDrops website: plan

A small site where anyone can contribute loot data recorded in the game, and anyone can download the combined data back into the addon. No accounts.

## What a player does

1. **Contribute:** type `/drops export` in the game, press Ctrl+C, paste the string into the site's upload box and submit. The site replies with what it accepted, e.g. "312 kills across 41 mobs".
2. **Download:** click "Copy latest data" on the site, type `/drops import` in the game, paste, and click Import.
3. **Browse (nice to have):** search for a mob and see its drop table, kill count and number of contributors.

## Architecture

The recommended setup is **Cloudflare Workers + D1 (SQLite) + static pages**.

- The free tier covers a hobby project, there's no server to maintain, and the API and pages deploy as one project.
- Any small host with SQLite works the same way, for example a Node or Python app on a VPS or Fly.io. Nothing below depends on Cloudflare.

```
browser ──► static page (upload box, copy-snapshot button, mob search)
        ──► POST /api/upload      decode, validate, replace this client's rows
        ──► GET  /api/snapshot    latest snapshot string (cached)
        ──► GET  /api/npc/:id     one mob's table, for the browse page
cron    ──► rebuild snapshot every 15 minutes
```

## Data model

```sql
contributors (
  client_hash  TEXT PRIMARY KEY,   -- SHA-256 of clientId + server secret; raw ID never stored
  first_seen   INTEGER,
  last_upload  INTEGER,
  addon_version TEXT,
  build        INTEGER,
  banned       INTEGER DEFAULT 0
)
observations (                     -- latest cumulative totals per contributor
  client_hash TEXT, npc_id INTEGER, kills INTEGER,
  PRIMARY KEY (client_hash, npc_id)
)
observation_extra (                -- per-mob extras from N records
  client_hash TEXT, npc_id INTEGER,
  grey INTEGER,                    -- G: corpses with at least one grey item
  no_items INTEGER,                -- E: corpses with no items
  gold_n INTEGER, gold_sum INTEGER, gold_min INTEGER, gold_max INTEGER,  -- $
  PRIMARY KEY (client_hash, npc_id)
)
gathering (                        -- S records: skinning/herbalism/mining/engineering/pick pocketing
  client_hash TEXT, npc_id INTEGER, kind INTEGER, corpses INTEGER,
  PRIMARY KEY (client_hash, npc_id, kind)
)
gathering_items (
  client_hash TEXT, npc_id INTEGER, kind INTEGER, item_id INTEGER, count INTEGER,
  PRIMARY KEY (client_hash, npc_id, kind, item_id)
)
mobs (npc_id INTEGER PRIMARY KEY, name TEXT, reports INTEGER)
observation_items (
  client_hash TEXT, npc_id INTEGER, item_id INTEGER, count INTEGER,
  PRIMARY KEY (client_hash, npc_id, item_id)
)
items (item_id INTEGER PRIMARY KEY, name TEXT, quality INTEGER, reports INTEGER)
snapshot (id INTEGER PRIMARY KEY CHECK (id = 1), generated INTEGER, body TEXT)
```

**Upload:** in one transaction, delete that contributor's `observations` and `observation_items`, then insert the new ones. Uploads are cumulative, so this replaces old totals rather than adding to them, and uploading twice is harmless.

**Snapshot build:**
- Sum `kills` and `count` per mob across contributors who aren't banned.
- Drop mobs with fewer than 5 total kills.
- Keep each mob's top 10 non-grey items and top 8 grey items, plus the summed `G` grey count. The tooltip shows 5 rows, the search window 10, and Shift lists the grey items.
- Write the `!MD1!` string, as specified in `exchange-format.md`.
- Add an `M` record for each mob not in the bundled 1.12 data, and `I` records for every item listed. Item names come from `items`. When contributors disagree on a name, take the most-reported one.

## Validation and abuse

Bad data is the main risk, since anyone can upload. Planned defenses, simplest first:

- **Format checks:** reject strings over 2 MB and any `count > kills`. Also reject IDs or numbers that are out of range, kills over 100,000 for one mob, and malformed records.
- **Rate limit:** at most 10 uploads per IP per hour, and 1 per contributor per minute.
- **Monotonic totals:** a contributor's kills for a mob shouldn't go down between uploads. If they do (reinstall or `/drops reset`), accept the new data but flag it.
- **Outliers:** for each mob and item, compare one contributor's rate with everyone else's using a binomial z-test. Leave out contributors whose rates are wildly off (|z| > 5 with at least 30 kills) and show them for review.
- **Moderation:** an admin page, behind a single admin token, to list flagged contributors and ban or unban them.
- **Privacy:** store only the hashed client ID. No character names, realms, IPs (beyond short-lived rate-limit counters) or accounts.

## Open issues to resolve while building

- **Paste size in the game:** WoW edit boxes slow down with very large pastes. A full snapshot could reach about 3,000 mobs, roughly 150–250 KB of base64.
  - Option 1: test an import of that size in the game first.
  - Option 2: if it's too slow, add a compressed `!MD2!` format (LibDeflate) or let players download one region at a time.
- **Game versions:** the `build` field lets the site split data if Blizzard changes loot tables in a patch. For v1, accept every build and show which builds a mob's data comes from.
- **Base data license:** the bundled 1.12 estimates come from CMaNGOS (GPL). If the site republishes that data, keep the attribution.

## Milestones

1. API: upload and snapshot endpoints with format checks. Database tables. Tests that round-trip strings made by the addon's `Codec.lua`.
2. Page: upload box, result summary, copy-snapshot button, short how-to.
3. Snapshot cron, rate limits, outlier flagging, admin page.
4. Browse: mob search and mob page.
5. Deploy, then link the site from the addon's `/drops export` help text and the CurseForge description.
