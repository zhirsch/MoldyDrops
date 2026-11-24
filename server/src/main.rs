use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use moldydrops_server::{api, db, snapshot::Limits};
use sqlx::postgres::PgPoolOptions;
use tower_http::services::ServeDir;
use tower_http::trace::TraceLayer;
use tracing_subscriber::EnvFilter;

/// Configuration comes from the environment:
/// - `DATABASE_URL` (required), e.g. `postgres://moldydrops:secret@localhost/moldydrops`
/// - `CLIENT_SECRET` (required): a long random string, mixed into client ID hashes. Never change it,
///   or every contributor's next upload counts as a new contributor.
/// - `BIND`: address to listen on, default `127.0.0.1:8080`
/// - `STATIC_DIR`: the pages to serve, default `static`
/// - `SNAPSHOT_MINUTES`: how often to rebuild the snapshot, default 15
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();

    let url = std::env::var("DATABASE_URL").context("set DATABASE_URL, e.g. postgres://user:password@localhost/moldydrops")?;
    let secret = std::env::var("CLIENT_SECRET").context("set CLIENT_SECRET to a long random string")?;
    if secret.len() < 16 {
        anyhow::bail!("CLIENT_SECRET should be at least 16 characters");
    }
    let bind = std::env::var("BIND").unwrap_or_else(|_| "127.0.0.1:8080".into());
    let static_dir = std::env::var("STATIC_DIR").unwrap_or_else(|_| "static".into());
    let minutes: u64 = match std::env::var("SNAPSHOT_MINUTES") {
        Ok(v) => v.parse().context("SNAPSHOT_MINUTES should be a whole number")?,
        Err(_) => 15,
    };

    let pool = PgPoolOptions::new().max_connections(8).connect(&url).await.context("connecting to the database")?;
    db::MIGRATOR.run(&pool).await.context("running migrations")?;

    let state = api::AppState { pool, secret: Arc::from(secret), limits: Limits::default() };
    tokio::spawn(api::snapshot_loop(state.clone(), Duration::from_secs(minutes.max(1) * 60)));

    let app = api::router(state).fallback_service(ServeDir::new(&static_dir)).layer(TraceLayer::new_for_http());
    let listener = tokio::net::TcpListener::bind(&bind).await.with_context(|| format!("listening on {bind}"))?;
    tracing::info!("serving on http://{bind}/ (pages from {static_dir})");
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
