//! Postgres storage: one set of rows per contributor, replaced on each upload.

use serde::Serialize;
use sqlx::PgPool;

use crate::format::{encode, write_text, Data, Gold, Header};
use crate::snapshot::{Combiner, Limits};

pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

/// Tables holding a contributor's data, cleared before each upload is inserted.
const CONTRIBUTOR_TABLES: [&str; 8] = [
    "observations",
    "observation_items",
    "gathering",
    "gathering_items",
    "stack_ranges",
    "stack_counts",
    "item_names",
    "mob_names",
];

#[derive(Debug, Clone, Serialize)]
pub struct UploadSummary {
    pub mobs: usize,
    pub kills: u64,
    pub gathered: usize,
    pub new_contributor: bool,
    /// Why this contributor was flagged for review (not shown to them).
    #[serde(skip)]
    pub flag: Option<String>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct Snapshot {
    pub generated: i64,
    pub contributors: i32,
    pub mobs: i32,
    pub body: String,
    pub body_legacy: String,
}

/// Replaces `client_hash`'s rows with `data` (an upload's cumulative totals).
pub async fn store_upload(pool: &PgPool, client_hash: &str, data: &Data, now: i64) -> Result<UploadSummary, sqlx::Error> {
    let (addon_version, build) = match &data.header {
        Header::Upload { addon_version, build, .. } => (addon_version.clone(), *build as i32),
        Header::Snapshot { .. } => (String::new(), 0),
    };
    let mut tx = pool.begin().await?;
    // Two uploads from one install at once would otherwise interleave their deletes and inserts.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))").bind(client_hash).execute(&mut *tx).await?;

    let exists: bool = sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM contributors WHERE client_hash = $1)")
        .bind(client_hash)
        .fetch_one(&mut *tx)
        .await?;
    // Totals are cumulative, so kills going down means a reinstall or /drops reset (or tampering).
    let old: Vec<(i32, i32)> = sqlx::query_as("SELECT npc_id, kills FROM observations WHERE client_hash = $1")
        .bind(client_hash)
        .fetch_all(&mut *tx)
        .await?;
    let went_down = old
        .iter()
        .filter(|(npc, kills)| data.drops.get(&(*npc as u32)).map_or(true, |d| (d.kills as i32) < *kills))
        .count();
    let flag = (went_down > 0)
        .then(|| format!("kills went down for {went_down} of {} mobs since the previous upload", old.len()));

    sqlx::query(
        "INSERT INTO contributors (client_hash, first_seen, last_upload, addon_version, build, sends_counts, flag)
         VALUES ($1, $2, $2, $3, $4, $5, $6)
         ON CONFLICT (client_hash) DO UPDATE SET
           last_upload = EXCLUDED.last_upload,
           addon_version = EXCLUDED.addon_version,
           build = EXCLUDED.build,
           sends_counts = EXCLUDED.sends_counts,
           uploads = contributors.uploads + 1,
           flag = COALESCE(EXCLUDED.flag, contributors.flag)",
    )
    .bind(client_hash)
    .bind(now)
    .bind(&addon_version)
    .bind(build)
    .bind(data.sends_counts)
    .bind(&flag)
    .execute(&mut *tx)
    .await?;

    for table in CONTRIBUTOR_TABLES {
        sqlx::query(&format!("DELETE FROM {table} WHERE client_hash = $1")).bind(client_hash).execute(&mut *tx).await?;
    }

    // N records
    let (mut npc, mut kills, mut grey, mut empty) = (vec![], vec![], vec![], vec![]);
    let (mut gold_n, mut gold_sum, mut gold_min, mut gold_max) = (vec![], vec![], vec![], vec![]);
    let (mut item_npc, mut item_id, mut item_hits) = (vec![], vec![], vec![]);
    // Q and C tokens from both record types
    let (mut q_npc, mut q_kind, mut q_item, mut q_min, mut q_max) = (vec![], vec![], vec![], vec![], vec![]);
    let (mut c_npc, mut c_kind, mut c_item, mut c_size, mut c_corpses) = (vec![], vec![], vec![], vec![], vec![]);
    let mut add_stacks = |n: u32, kind: i16, stacks: &std::collections::BTreeMap<u32, crate::format::Stack>| {
        for (&item, s) in stacks {
            q_npc.push(n as i32);
            q_kind.push(kind);
            q_item.push(item as i32);
            q_min.push(s.min as i32);
            q_max.push(s.max as i32);
            for (&size, &corpses) in &s.counts {
                c_npc.push(n as i32);
                c_kind.push(kind);
                c_item.push(item as i32);
                c_size.push(size as i32);
                c_corpses.push(corpses as i32);
            }
        }
    };
    for (&n, d) in &data.drops {
        npc.push(n as i32);
        kills.push(d.kills as i32);
        grey.push(d.grey as i32);
        empty.push(d.no_items as i32);
        let g = d.gold.unwrap_or_default();
        gold_n.push(g.n as i32);
        gold_sum.push(g.sum.min(i64::MAX as u64) as i64);
        gold_min.push(g.min as i32);
        gold_max.push(g.max as i32);
        for (&item, &hits) in &d.items {
            item_npc.push(n as i32);
            item_id.push(item as i32);
            item_hits.push(hits as i32);
        }
        add_stacks(n, 0, &d.stacks);
    }
    // S records
    let (mut g_npc, mut g_kind, mut g_corpses) = (vec![], vec![], vec![]);
    let (mut gi_npc, mut gi_kind, mut gi_item, mut gi_hits) = (vec![], vec![], vec![], vec![]);
    for (&(n, kind), g) in &data.gathers {
        g_npc.push(n as i32);
        g_kind.push(kind as i16);
        g_corpses.push(g.corpses as i32);
        for (&item, &hits) in &g.items {
            gi_npc.push(n as i32);
            gi_kind.push(kind as i16);
            gi_item.push(item as i32);
            gi_hits.push(hits as i32);
        }
        add_stacks(n, kind as i16, &g.stacks);
    }

    sqlx::query(
        "INSERT INTO observations (client_hash, npc_id, kills, grey, no_items, gold_n, gold_sum, gold_min, gold_max)
         SELECT $1, * FROM UNNEST($2::int4[], $3::int4[], $4::int4[], $5::int4[], $6::int4[], $7::int8[], $8::int4[], $9::int4[])",
    )
    .bind(client_hash)
    .bind(npc)
    .bind(kills)
    .bind(grey)
    .bind(empty)
    .bind(gold_n)
    .bind(gold_sum)
    .bind(gold_min)
    .bind(gold_max)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO observation_items (client_hash, npc_id, item_id, hits)
         SELECT $1, * FROM UNNEST($2::int4[], $3::int4[], $4::int4[])",
    )
    .bind(client_hash)
    .bind(item_npc)
    .bind(item_id)
    .bind(item_hits)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO gathering (client_hash, npc_id, kind, corpses)
         SELECT $1, * FROM UNNEST($2::int4[], $3::int2[], $4::int4[])",
    )
    .bind(client_hash)
    .bind(g_npc)
    .bind(g_kind)
    .bind(g_corpses)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO gathering_items (client_hash, npc_id, kind, item_id, hits)
         SELECT $1, * FROM UNNEST($2::int4[], $3::int2[], $4::int4[], $5::int4[])",
    )
    .bind(client_hash)
    .bind(gi_npc)
    .bind(gi_kind)
    .bind(gi_item)
    .bind(gi_hits)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO stack_ranges (client_hash, npc_id, kind, item_id, min_count, max_count)
         SELECT $1, * FROM UNNEST($2::int4[], $3::int2[], $4::int4[], $5::int4[], $6::int4[])",
    )
    .bind(client_hash)
    .bind(q_npc)
    .bind(q_kind)
    .bind(q_item)
    .bind(q_min)
    .bind(q_max)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO stack_counts (client_hash, npc_id, kind, item_id, stack, corpses)
         SELECT $1, * FROM UNNEST($2::int4[], $3::int2[], $4::int4[], $5::int4[], $6::int4[])",
    )
    .bind(client_hash)
    .bind(c_npc)
    .bind(c_kind)
    .bind(c_item)
    .bind(c_size)
    .bind(c_corpses)
    .execute(&mut *tx)
    .await?;

    let (item_ids, qualities, item_names): (Vec<i32>, Vec<i16>, Vec<String>) = {
        let mut v = (vec![], vec![], vec![]);
        for (&id, info) in &data.items {
            v.0.push(id as i32);
            v.1.push(info.quality as i16);
            v.2.push(info.name.clone());
        }
        v
    };
    sqlx::query(
        "INSERT INTO item_names (client_hash, item_id, quality, name)
         SELECT $1, * FROM UNNEST($2::int4[], $3::int2[], $4::text[])",
    )
    .bind(client_hash)
    .bind(item_ids)
    .bind(qualities)
    .bind(item_names)
    .execute(&mut *tx)
    .await?;
    let mob_ids: Vec<i32> = data.mobs.keys().map(|&n| n as i32).collect();
    let mob_names: Vec<String> = data.mobs.values().cloned().collect();
    sqlx::query(
        "INSERT INTO mob_names (client_hash, npc_id, name)
         SELECT $1, * FROM UNNEST($2::int4[], $3::text[])",
    )
    .bind(client_hash)
    .bind(mob_ids)
    .bind(mob_names)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(UploadSummary {
        mobs: data.drops.len(),
        kills: data.total_kills(),
        gathered: data.gathers.len(),
        new_contributor: !exists,
        flag,
    })
}

/// Loads every contributor who isn't banned (all mobs, or just `npc`) into a Combiner.
/// Also returns how many contributors that covers.
pub async fn load(pool: &PgPool, npc: Option<i32>) -> Result<(Combiner, u32), sqlx::Error> {
    const ACTIVE: &str = "JOIN contributors c USING (client_hash) WHERE NOT c.banned AND ($1::int4 IS NULL OR t.npc_id = $1)";
    let mut comb = Combiner::default();

    let rows: Vec<(i32, i32, i32, i32, i32, i64, i32, i32)> = sqlx::query_as(&format!(
        "SELECT t.npc_id, t.kills, t.grey, t.no_items, t.gold_n, t.gold_sum, t.gold_min, t.gold_max FROM observations t {ACTIVE}"
    ))
    .bind(npc)
    .fetch_all(pool)
    .await?;
    for (n, kills, grey, empty, gn, gsum, gmin, gmax) in rows {
        let gold = Gold { n: gn as u32, sum: gsum as u64, min: gmin as u32, max: gmax as u32 };
        comb.mob(n as u32, kills as u32, grey as u32, empty as u32, Some(gold));
    }

    let rows: Vec<(i32, i32, i32)> =
        sqlx::query_as(&format!("SELECT t.npc_id, t.item_id, t.hits FROM observation_items t {ACTIVE}"))
            .bind(npc)
            .fetch_all(pool)
            .await?;
    for (n, item, hits) in rows {
        comb.drop_item(n as u32, item as u32, hits as u32);
    }

    let rows: Vec<(i32, i16, i32)> = sqlx::query_as(&format!("SELECT t.npc_id, t.kind, t.corpses FROM gathering t {ACTIVE}"))
        .bind(npc)
        .fetch_all(pool)
        .await?;
    for (n, kind, corpses) in rows {
        comb.gather(n as u32, kind as u8, corpses as u32);
    }

    let rows: Vec<(i32, i16, i32, i32)> =
        sqlx::query_as(&format!("SELECT t.npc_id, t.kind, t.item_id, t.hits FROM gathering_items t {ACTIVE}"))
            .bind(npc)
            .fetch_all(pool)
            .await?;
    for (n, kind, item, hits) in rows {
        comb.gather_item(n as u32, kind as u8, item as u32, hits as u32);
    }

    let rows: Vec<(i32, i16, i32, i32, i32)> = sqlx::query_as(&format!(
        "SELECT t.npc_id, t.kind, t.item_id, t.min_count, t.max_count FROM stack_ranges t {ACTIVE}"
    ))
    .bind(npc)
    .fetch_all(pool)
    .await?;
    for (n, kind, item, min, max) in rows {
        comb.stack_range(n as u32, kind as u8, item as u32, min as u32, max as u32);
    }

    let rows: Vec<(i32, i16, i32, i32, i32)> = sqlx::query_as(&format!(
        "SELECT t.npc_id, t.kind, t.item_id, t.stack, t.corpses FROM stack_counts t {ACTIVE}"
    ))
    .bind(npc)
    .fetch_all(pool)
    .await?;
    for (n, kind, item, size, corpses) in rows {
        comb.stack_count(n as u32, kind as u8, item as u32, size as u32, corpses as u32);
    }

    let rows: Vec<(i32, String)> = sqlx::query_as(&format!("SELECT t.npc_id, t.name FROM mob_names t {ACTIVE}"))
        .bind(npc)
        .fetch_all(pool)
        .await?;
    for (n, name) in rows {
        comb.mob_name(n as u32, name);
    }

    // Item names: all of them for a snapshot, or the ones this mob lists.
    let rows: Vec<(i32, i16, String)> = sqlx::query_as(
        "SELECT t.item_id, t.quality, t.name FROM item_names t
         JOIN contributors c USING (client_hash)
         WHERE NOT c.banned AND ($1::int4 IS NULL OR t.item_id IN (
           SELECT item_id FROM observation_items WHERE npc_id = $1
           UNION SELECT item_id FROM gathering_items WHERE npc_id = $1))",
    )
    .bind(npc)
    .fetch_all(pool)
    .await?;
    for (item, quality, name) in rows {
        comb.item_name(item as u32, quality as u8, name);
    }

    let contributors: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM contributors c WHERE NOT c.banned AND (
           EXISTS (SELECT 1 FROM observations o WHERE o.client_hash = c.client_hash AND ($1::int4 IS NULL OR o.npc_id = $1))
           OR EXISTS (SELECT 1 FROM gathering g WHERE g.client_hash = c.client_hash AND ($1::int4 IS NULL OR g.npc_id = $1)))",
    )
    .bind(npc)
    .fetch_one(pool)
    .await?;

    Ok((comb, contributors as u32))
}

/// Rebuilds the snapshot from everyone's data and stores it.
pub async fn build_snapshot(pool: &PgPool, limits: &Limits, now: i64) -> Result<Snapshot, sqlx::Error> {
    let (comb, contributors) = load(pool, None).await?;
    let data = comb.finish(now, contributors, limits);
    let snap = Snapshot {
        generated: now,
        contributors: contributors as i32,
        mobs: data.drops.len() as i32,
        body: encode(&write_text(&data, true)),
        body_legacy: encode(&write_text(&data, false)),
    };
    sqlx::query(
        "INSERT INTO snapshot (id, generated, contributors, mobs, body, body_legacy) VALUES (1, $1, $2, $3, $4, $5)
         ON CONFLICT (id) DO UPDATE SET generated = EXCLUDED.generated, contributors = EXCLUDED.contributors,
           mobs = EXCLUDED.mobs, body = EXCLUDED.body, body_legacy = EXCLUDED.body_legacy",
    )
    .bind(snap.generated)
    .bind(snap.contributors)
    .bind(snap.mobs)
    .bind(&snap.body)
    .bind(&snap.body_legacy)
    .execute(pool)
    .await?;
    Ok(snap)
}

pub async fn get_snapshot(pool: &PgPool) -> Result<Option<Snapshot>, sqlx::Error> {
    sqlx::query_as("SELECT generated, contributors, mobs, body, body_legacy FROM snapshot WHERE id = 1")
        .fetch_optional(pool)
        .await
}

/// One mob's combined data, untrimmed, and how many contributors it comes from.
pub async fn npc_data(pool: &PgPool, npc: u32, now: i64) -> Result<(Data, u32), sqlx::Error> {
    let (comb, contributors) = load(pool, Some(npc as i32)).await?;
    Ok((comb.finish(now, contributors, &Limits::all()), contributors))
}
