//! HTTP API (docs/website-plan.md, "Architecture").
//!
//! - `POST /api/upload`: body is the `!MD1!` string from `/drops export`.
//! - `GET /api/snapshot`: the latest snapshot string. `?legacy=1` leaves out C
//!   tokens, for addon versions from before they existed.
//! - `GET /api/npc/{id}`: one mob's combined table, as JSON.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use sqlx::PgPool;

use crate::db;
use crate::format::{self, Data, Header, Stack};
use crate::snapshot::Limits;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    /// Mixed into client ID hashes, so a leaked database can't be matched to installs.
    pub secret: Arc<str>,
    pub limits: Limits,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/api/upload", post(upload))
        .route("/api/snapshot", get(snapshot))
        .route("/api/npc/{id}", get(npc))
        .route("/api/health", get(|| async { "ok" }))
        .layer(DefaultBodyLimit::max(format::MAX_STRING + 4096))
        .with_state(state)
}

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub fn client_hash(secret: &str, client_id: &str) -> String {
    let digest = Sha256::new()
        .chain_update(secret.as_bytes())
        .chain_update(b":")
        .chain_update(client_id.as_bytes())
        .finalize();
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

fn error(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({ "error": message }))).into_response()
}

fn server_error(what: &str, e: sqlx::Error) -> Response {
    tracing::error!("{what}: {e}");
    error(StatusCode::INTERNAL_SERVER_ERROR, "the server had a problem; please try again later")
}

async fn upload(State(st): State<AppState>, body: String) -> Response {
    let data = match format::decode(&body) {
        Ok(d) => d,
        Err(e) => return error(StatusCode::BAD_REQUEST, &e.to_string()),
    };
    let Header::Upload { client_id, .. } = &data.header else {
        return error(
            StatusCode::BAD_REQUEST,
            "that's a snapshot from this site. Type /drops import in the game and paste it there instead.",
        );
    };
    if data.drops.is_empty() && data.gathers.is_empty() {
        return error(StatusCode::BAD_REQUEST, "that string has no recorded loot yet");
    }
    let hash = client_hash(&st.secret, client_id);
    match db::store_upload(&st.pool, &hash, &data, now()).await {
        Ok(s) => {
            if let Some(flag) = &s.flag {
                tracing::warn!(contributor = %&hash[..12], "flagged: {flag}");
            }
            let message = format!(
                "Thanks! Accepted {} kills across {} mobs{}.",
                s.kills,
                s.mobs,
                if s.gathered > 0 { format!(", plus {} gathering records", s.gathered) } else { String::new() }
            );
            Json(json!({
                "message": message,
                "kills": s.kills,
                "mobs": s.mobs,
                "gathered": s.gathered,
                "new_contributor": s.new_contributor,
            }))
            .into_response()
        }
        Err(e) => server_error("upload", e),
    }
}

#[derive(Deserialize)]
struct SnapshotQuery {
    legacy: Option<String>,
}

async fn snapshot(State(st): State<AppState>, Query(q): Query<SnapshotQuery>) -> Response {
    let snap = match db::get_snapshot(&st.pool).await {
        Ok(Some(s)) => s,
        Ok(None) => match db::build_snapshot(&st.pool, &st.limits, now()).await {
            Ok(s) => s,
            Err(e) => return server_error("snapshot build", e),
        },
        Err(e) => return server_error("snapshot read", e),
    };
    let legacy = q.legacy.as_deref().is_some_and(|v| v != "0" && !v.is_empty());
    let body = if legacy { snap.body_legacy } else { snap.body };
    (
        [
            (header::CONTENT_TYPE, "text/plain; charset=utf-8".to_string()),
            (header::CACHE_CONTROL, "public, max-age=300".to_string()),
            (header::HeaderName::from_static("x-moldydrops-generated"), snap.generated.to_string()),
            (header::HeaderName::from_static("x-moldydrops-contributors"), snap.contributors.to_string()),
        ],
        body,
    )
        .into_response()
}

async fn npc(State(st): State<AppState>, Path(id): Path<u32>) -> Response {
    if id == 0 || id > format::MAX_ID {
        return error(StatusCode::NOT_FOUND, "no such NPC");
    }
    match db::npc_data(&st.pool, id, now()).await {
        Ok((data, contributors)) => Json(npc_json(id, &data, contributors)).into_response(),
        Err(e) => server_error("npc", e),
    }
}

fn item_rows(data: &Data, items: &BTreeMap<u32, u32>, stacks: &BTreeMap<u32, Stack>, total: u32) -> Vec<Value> {
    let mut rows: Vec<(&u32, &u32)> = items.iter().collect();
    rows.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
    rows.into_iter()
        .map(|(id, hits)| {
            let info = data.items.get(id);
            json!({
                "id": id,
                "name": info.map(|i| i.name.as_str()),
                "quality": info.map(|i| i.quality),
                "hits": hits,
                "pct": if total > 0 { 100.0 * *hits as f64 / total as f64 } else { 0.0 },
                "stack": stacks.get(id).map(|s| json!({ "min": s.min, "max": s.max, "counts": s.counts })),
            })
        })
        .collect()
}

/// JSON for the mob page: everything contributors recorded for one NPC.
pub fn npc_json(npc: u32, data: &Data, contributors: u32) -> Value {
    let drops = data.drops.get(&npc);
    let gathering: Vec<Value> = data
        .gathers
        .iter()
        .filter(|((n, _), _)| *n == npc)
        .map(|((_, kind), g)| {
            json!({
                "kind": kind,
                "corpses": g.corpses,
                "items": item_rows(data, &g.items, &g.stacks, g.corpses),
            })
        })
        .collect();
    json!({
        "npc": npc,
        "name": data.mobs.get(&npc),
        "contributors": contributors,
        "kills": drops.map_or(0, |d| d.kills),
        "grey": drops.map_or(0, |d| d.grey),
        "no_items": drops.map_or(0, |d| d.no_items),
        "gold": drops.and_then(|d| d.gold).map(|g| json!({ "n": g.n, "sum": g.sum, "min": g.min, "max": g.max })),
        "items": drops.map(|d| item_rows(data, &d.items, &d.stacks, d.kills)).unwrap_or_default(),
        "gathering": gathering,
    })
}

/// Rebuilds the snapshot every `every`, starting now.
pub async fn snapshot_loop(st: AppState, every: Duration) {
    let mut tick = tokio::time::interval(every);
    loop {
        tick.tick().await;
        match db::build_snapshot(&st.pool, &st.limits, now()).await {
            Ok(s) => tracing::info!(mobs = s.mobs, contributors = s.contributors, "snapshot rebuilt"),
            Err(e) => tracing::error!("snapshot rebuild failed: {e}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashes_depend_on_the_secret() {
        let a = client_hash("one", "abcdefgh12345678");
        assert_eq!(a.len(), 64);
        assert_eq!(a, client_hash("one", "abcdefgh12345678"));
        assert_ne!(a, client_hash("two", "abcdefgh12345678"));
    }

    #[test]
    fn npc_json_shape() {
        let data = format::decode(include_str!("../tests/fixtures/addon-export.txt")).unwrap();
        let v = npc_json(660, &data, 1);
        assert_eq!(v["kills"], 3);
        assert_eq!(v["items"][0]["id"], 4338);
        assert_eq!(v["items"][0]["name"], "Mageweave Cloth");
        assert_eq!(v["items"][0]["pct"], 100.0);
        assert_eq!(v["items"][0]["stack"]["counts"]["3"], 1);
        let v = npc_json(6, &data, 1);
        assert_eq!(v["gathering"].as_array().unwrap().len(), 2);
        assert_eq!(v["gold"]["sum"], 150);
    }
}
