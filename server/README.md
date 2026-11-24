# MoldyDrops server

The website from [docs/website-plan.md](../docs/website-plan.md): players paste `/drops export` strings in, and copy the combined snapshot out for `/drops import`. Rust ([axum](https://github.com/tokio-rs/axum) and [sqlx](https://github.com/launchbadge/sqlx)) with Postgres.

## Layout

| Path | What it is |
|---|---|
| `src/format.rs` | The `!MD1!` exchange format ([docs/exchange-format.md](../docs/exchange-format.md)): decode and validate, and write. |
| `src/snapshot.rs` | Combines contributors' totals and trims them into the snapshot. |
| `src/db.rs` | Postgres: replace a contributor's rows on upload, load everything for a snapshot. |
| `src/api.rs` | HTTP endpoints and the 15-minute snapshot rebuild. |
| `migrations/` | Database schema, applied on startup. |
| `static/` | The page: upload box and "Copy latest data" button. |
| `tests/fixtures/` | `addon-export.txt` is made by the addon's `Codec.Export`, and `server-snapshot.txt` by this server. Each side's tests read the other's. |

## API

| Endpoint | |
|---|---|
| `POST /api/upload` | Body: the `!MD1!` string. Replies `{"message": "Thanks! Accepted 312 kills across 41 mobs.", ...}`, or status 400 with `{"error": "line 4: item 159's count is 9, more than the 3 kills"}`. |
| `GET /api/snapshot` | The latest snapshot string. Add `?legacy=1` for addon versions from before `C` tokens. |
| `GET /api/npc/{id}` | One mob's combined table as JSON, for the browse pages. |
| `GET /api/health` | `ok` |

## Running it locally

Install [Rust](https://rustup.rs) and [PostgreSQL](https://www.postgresql.org/download/). Then create a database:

```powershell
psql -U postgres -c "CREATE USER moldydrops PASSWORD 'moldydrops' CREATEDB" -c "CREATE DATABASE moldydrops OWNER moldydrops"
```

Then start the server from this folder:

```powershell
$env:DATABASE_URL = 'postgres://moldydrops:moldydrops@localhost/moldydrops'
$env:CLIENT_SECRET = 'any long random string, kept the same forever'
cargo run
```

It listens on http://127.0.0.1:8080/. Other settings are `BIND`, `STATIC_DIR` and `SNAPSHOT_MINUTES`.

## Tests

```powershell
cargo test
```

The database tests are skipped unless you ask for them. They create a scratch database per test, so `DATABASE_URL` needs a user allowed to create databases:

```powershell
cargo test -- --include-ignored
```

If you change the snapshot output on purpose, rewrite the fixture with `$env:MD_UPDATE_FIXTURES = 1; cargo test`, then rerun the addon's tests (`tests/build.ps1`), which import it.

## Not done yet

These are milestones 3 to 5 of the plan:

- Rate limits.
- Outlier flagging. Kills going down between uploads is already flagged.
- An admin page for flagged and banned contributors.
- Browse pages.
- Deployment.
