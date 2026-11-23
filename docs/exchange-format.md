# MoldyDrops exchange format, version 1

The addon and the website exchange strings in this format, which both sides implement.

## Wrapper

```
!MD1!<base64>
```

- `!MD1!` marks the string and its version. A later version (for example compressed data) gets a new marker such as `!MD2!`.
- `<base64>` is standard base64 (`A–Z a–z 0–9 + /`, `=` padding) of UTF-8 text. Decoders ignore whitespace, so line-wrapped pastes still work.

## Text

The text is a list of records separated by `\n`. The first record is a header. A reader skips any record type it doesn't recognize, so new record types can be added without breaking older readers.

### Header

| Kind | Header | Direction |
|---|---|---|
| Upload | `MD1 U <clientId> <unixTime> <addonVersion> <build>` | addon → website |
| Snapshot | `MD1 S <generatedUnixTime> <contributors>` | website → addon |

- `clientId` is 16 random characters from `[0-9a-z]`, made once per install. Treat it as a secret: whoever has it can replace that install's contribution. The website must never display it.
- `build` is the game's interface number (`select(4, GetBuildInfo())`), so the website can tell game versions apart.

### Records

```
N <npcID> <kills> <itemID>:<count> <itemID>:<count> ... [G:<greyCount>]
I <itemID> <quality> <item name to end of line>
M <npcID> <mob name to end of line>
```

- `N`: `kills` is the number of corpses observed (looted, or confirmed empty). `count` is the number of those corpses that held at least one of the item. Stack size is ignored, so `count <= kills` always.
  - `G:<greyCount>` is optional: the number of corpses that held at least one grey (poor-quality) item.
  - The addon shows all grey items as one "Grey items" rate. That can't be worked out from per-item counts, because one corpse can hold several grey items.
  - Item ID 0 is never used in `N` records.
- `I`: the item's name and quality (0 = poor … 5 = legendary) as the client saw them. This lets the website name items that are new in WoW Forever.
- `M`: a mob's name as the client saw it. Uploads include it only for mobs the bundled 1.12 data doesn't know (new in WoW Forever). Snapshots should include every mob that isn't in the bundled data, so `/drops search` can find it.

Upload counts are **cumulative totals for that install**, not the change since the last upload. The website keeps only the latest upload per `clientId`, so uploading twice never double-counts.

Snapshots use the same `N`, `I` and `M` records, with counts (including `G`) summed over all accepted contributors.

## Example

The text

```
MD1 U k3j9x0q2m1a8z7c4 1795400000 0.1.0 16001
N 6 42 755:12 159:3 G:14
N 274300 9 99999:2
M 274300 Coldrasp
I 159 1 Refreshing Spring Water
I 755 0 Melted Candle
I 99999 2 Frosted Fang
```

becomes `!MD1!TUQxIFUgazNqOXgwcTJ...` after base64.
