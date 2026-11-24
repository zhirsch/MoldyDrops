//! Database tests. They need a Postgres server: set DATABASE_URL to a user that
//! may create databases (each test gets a fresh one), then run
//! `cargo test -- --include-ignored`.

use moldydrops_server::format::{self, Header};
use moldydrops_server::{db, snapshot::Limits};
use sqlx::PgPool;

const ADDON_EXPORT: &str = include_str!("fixtures/addon-export.txt");

fn upload(client: &str, body: &str) -> format::Data {
    format::parse_text(&format!("MD1 U {client} 1795400000 0.1.0 16001\n{body}")).unwrap()
}

#[sqlx::test]
#[ignore = "needs DATABASE_URL"]
async fn upload_round_trips_through_the_snapshot(pool: PgPool) -> sqlx::Result<()> {
    let data = format::decode(ADDON_EXPORT).unwrap();
    let s = db::store_upload(&pool, "hash-a", &data, 100).await?;
    assert_eq!((s.mobs, s.kills, s.gathered, s.new_contributor), (3, 10, 3, true));
    assert!(s.flag.is_none());

    let snap = db::build_snapshot(&pool, &Limits::all(), 300).await?;
    let back = format::decode(&snap.body).unwrap();
    assert_eq!(back.header, Header::Snapshot { generated: 300, contributors: 1 });
    assert_eq!(back.drops, data.drops);
    assert_eq!(back.gathers, data.gathers);
    assert_eq!(back.items, data.items);
    assert_eq!(back.mobs, data.mobs);
    assert!(!format::decode(&snap.body_legacy).unwrap().sends_counts);

    let stored = db::get_snapshot(&pool).await?.unwrap();
    assert_eq!((stored.generated, stored.body), (300, snap.body));
    Ok(())
}

#[sqlx::test]
#[ignore = "needs DATABASE_URL"]
async fn uploads_replace_instead_of_adding(pool: PgPool) -> sqlx::Result<()> {
    let first = upload("aaaaaaaaaaaaaaaa", "N 6 10 159:4\nI 159 1 Water");
    db::store_upload(&pool, "hash-a", &first, 100).await?;
    let again = db::store_upload(&pool, "hash-a", &first, 200).await?;
    assert!(!again.new_contributor);
    let more = upload("aaaaaaaaaaaaaaaa", "N 6 12 159:5\nI 159 1 Water");
    db::store_upload(&pool, "hash-a", &more, 300).await?;
    db::store_upload(&pool, "hash-b", &upload("bbbbbbbbbbbbbbbb", "N 6 8 159:1 2589:3"), 300).await?;

    let snap = format::decode(&db::build_snapshot(&pool, &Limits::default(), 400).await?.body).unwrap();
    assert_eq!(snap.header, Header::Snapshot { generated: 400, contributors: 2 });
    let d = &snap.drops[&6];
    assert_eq!((d.kills, d.items[&159], d.items[&2589]), (20, 6, 3));
    let uploads: i32 = sqlx::query_scalar("SELECT uploads FROM contributors WHERE client_hash = 'hash-a'")
        .fetch_one(&pool)
        .await?;
    assert_eq!(uploads, 3);
    Ok(())
}

#[sqlx::test]
#[ignore = "needs DATABASE_URL"]
async fn banned_contributors_are_left_out(pool: PgPool) -> sqlx::Result<()> {
    db::store_upload(&pool, "hash-a", &upload("aaaaaaaaaaaaaaaa", "N 6 10 159:4"), 100).await?;
    db::store_upload(&pool, "hash-b", &upload("bbbbbbbbbbbbbbbb", "N 6 10 159:10\nS 6 1 9 2318:9"), 100).await?;
    sqlx::query("UPDATE contributors SET banned = TRUE WHERE client_hash = 'hash-b'").execute(&pool).await?;
    let snap = format::decode(&db::build_snapshot(&pool, &Limits::default(), 200).await?.body).unwrap();
    assert_eq!(snap.header, Header::Snapshot { generated: 200, contributors: 1 });
    assert_eq!((snap.drops[&6].kills, snap.drops[&6].items[&159]), (10, 4));
    let (one, contributors) = db::npc_data(&pool, 6, 200).await?;
    assert_eq!((one.drops[&6].kills, contributors), (10, 1));
    Ok(())
}

#[sqlx::test]
#[ignore = "needs DATABASE_URL"]
async fn kills_going_down_flags_the_contributor(pool: PgPool) -> sqlx::Result<()> {
    db::store_upload(&pool, "hash-a", &upload("aaaaaaaaaaaaaaaa", "N 6 10 159:4\nN 7 5"), 100).await?;
    let s = db::store_upload(&pool, "hash-a", &upload("aaaaaaaaaaaaaaaa", "N 6 3 159:1"), 200).await?;
    assert_eq!(s.flag.as_deref(), Some("kills went down for 2 of 2 mobs since the previous upload"));
    // the new totals are still accepted
    let (one, _) = db::npc_data(&pool, 6, 200).await?;
    assert_eq!(one.drops[&6].kills, 3);
    // and the flag stays after a normal upload
    db::store_upload(&pool, "hash-a", &upload("aaaaaaaaaaaaaaaa", "N 6 4 159:1"), 300).await?;
    let flag: Option<String> = sqlx::query_scalar("SELECT flag FROM contributors WHERE client_hash = 'hash-a'")
        .fetch_one(&pool)
        .await?;
    assert!(flag.is_some());
    Ok(())
}
