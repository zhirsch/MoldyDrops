//! MoldyDrops website server: collects `/drops export` uploads and serves the
//! combined snapshot for `/drops import`. See docs/website-plan.md.

pub mod api;
pub mod db;
pub mod format;
pub mod snapshot;
