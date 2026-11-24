//! Combines contributors' totals into one snapshot (docs/website-plan.md, "Snapshot build").

use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::format::{Data, Drops, Gather, Gold, Header, ItemInfo, Stack};

/// What the snapshot keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// Mobs (and gathering records) with fewer kills or corpses are left out.
    pub min_kills: u32,
    /// Items kept per mob that aren't grey. The search window shows 10.
    pub top_items: usize,
    /// Grey items kept per mob, listed when Shift is held.
    pub top_grey: usize,
    /// Items kept per gathering record.
    pub top_gather: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Limits { min_kills: 5, top_items: 10, top_grey: 8, top_gather: 10 }
    }
}

impl Limits {
    /// Keeps everything: for one mob's page.
    pub fn all() -> Self {
        Limits { min_kills: 1, top_items: usize::MAX, top_grey: usize::MAX, top_gather: usize::MAX }
    }
}

/// Sums contributors' rows. Feed it rows in any order (stack ranges before
/// stack counts is not required), then call `finish`.
#[derive(Debug, Default)]
pub struct Combiner {
    drops: BTreeMap<u32, Drops>,
    gathers: BTreeMap<(u32, u8), Gather>,
    item_votes: HashMap<u32, HashMap<(u8, String), u32>>,
    mob_votes: HashMap<u32, HashMap<String, u32>>,
}

impl Combiner {
    pub fn mob(&mut self, npc: u32, kills: u32, grey: u32, no_items: u32, gold: Option<Gold>) {
        let d = self.drops.entry(npc).or_default();
        d.kills = d.kills.saturating_add(kills);
        d.grey = d.grey.saturating_add(grey);
        d.no_items = d.no_items.saturating_add(no_items);
        if let Some(g) = gold.filter(|g| g.n > 0) {
            d.gold = Some(match d.gold {
                None => g,
                Some(o) => Gold {
                    n: o.n.saturating_add(g.n),
                    sum: o.sum.saturating_add(g.sum),
                    min: o.min.min(g.min),
                    max: o.max.max(g.max),
                },
            });
        }
    }

    pub fn drop_item(&mut self, npc: u32, item: u32, hits: u32) {
        let h = self.drops.entry(npc).or_default().items.entry(item).or_default();
        *h = h.saturating_add(hits);
    }

    pub fn gather(&mut self, npc: u32, kind: u8, corpses: u32) {
        let g = self.gathers.entry((npc, kind)).or_default();
        g.corpses = g.corpses.saturating_add(corpses);
    }

    pub fn gather_item(&mut self, npc: u32, kind: u8, item: u32, hits: u32) {
        let h = self.gathers.entry((npc, kind)).or_default().items.entry(item).or_default();
        *h = h.saturating_add(hits);
    }

    /// kind 0 is a drop (N record), 1-5 the S record's kind.
    fn stack(&mut self, npc: u32, kind: u8, item: u32, min: u32, max: u32) -> &mut Stack {
        let stacks = if kind == 0 {
            &mut self.drops.entry(npc).or_default().stacks
        } else {
            &mut self.gathers.entry((npc, kind)).or_default().stacks
        };
        let s = stacks.entry(item).or_insert(Stack { min, max, counts: BTreeMap::new() });
        s.min = s.min.min(min);
        s.max = s.max.max(max);
        s
    }

    pub fn stack_range(&mut self, npc: u32, kind: u8, item: u32, min: u32, max: u32) {
        self.stack(npc, kind, item, min, max);
    }

    pub fn stack_count(&mut self, npc: u32, kind: u8, item: u32, size: u32, corpses: u32) {
        let c = self.stack(npc, kind, item, size, size).counts.entry(size).or_default();
        *c = c.saturating_add(corpses);
    }

    pub fn item_name(&mut self, item: u32, quality: u8, name: String) {
        *self.item_votes.entry(item).or_default().entry((quality, name)).or_default() += 1;
    }

    pub fn mob_name(&mut self, npc: u32, name: String) {
        *self.mob_votes.entry(npc).or_default().entry(name).or_default() += 1;
    }

    /// Adds one contributor's whole upload.
    pub fn add(&mut self, data: &Data) {
        for (&npc, d) in &data.drops {
            self.mob(npc, d.kills, d.grey, d.no_items, d.gold);
            for (&item, &hits) in &d.items {
                self.drop_item(npc, item, hits);
            }
            self.add_stacks(npc, 0, &d.stacks);
        }
        for (&(npc, kind), g) in &data.gathers {
            self.gather(npc, kind, g.corpses);
            for (&item, &hits) in &g.items {
                self.gather_item(npc, kind, item, hits);
            }
            self.add_stacks(npc, kind, &g.stacks);
        }
        for (&item, info) in &data.items {
            self.item_name(item, info.quality, info.name.clone());
        }
        for (&npc, name) in &data.mobs {
            self.mob_name(npc, name.clone());
        }
    }

    fn add_stacks(&mut self, npc: u32, kind: u8, stacks: &BTreeMap<u32, Stack>) {
        for (&item, s) in stacks {
            self.stack_range(npc, kind, item, s.min, s.max);
            for (&size, &corpses) in &s.counts {
                self.stack_count(npc, kind, item, size, corpses);
            }
        }
    }

    /// Trims to `limits` and returns the snapshot's data.
    pub fn finish(self, generated: i64, contributors: u32, limits: &Limits) -> Data {
        let names: BTreeMap<u32, ItemInfo> = self
            .item_votes
            .into_iter()
            .filter_map(|(item, votes)| most_votes(votes).map(|(quality, name)| (item, ItemInfo { quality, name })))
            .collect();
        let grey = |item: &u32| names.get(item).is_some_and(|i| i.quality == 0);

        let mut data = Data::new(Header::Snapshot { generated, contributors });
        for (npc, mut d) in self.drops {
            if d.kills < limits.min_kills || d.kills == 0 {
                continue;
            }
            let (greys, others): (Vec<_>, Vec<_>) = d.items.iter().map(|(&i, &h)| (i, h)).partition(|(i, _)| grey(i));
            let keep: BTreeSet<u32> = top(others, limits.top_items).chain(top(greys, limits.top_grey)).collect();
            d.items.retain(|i, _| keep.contains(i));
            d.stacks.retain(|i, _| keep.contains(i));
            data.drops.insert(npc, d);
        }
        for (key, mut g) in self.gathers {
            if g.corpses < limits.min_kills || g.corpses == 0 {
                continue;
            }
            let keep: BTreeSet<u32> = top(g.items.iter().map(|(&i, &h)| (i, h)).collect(), limits.top_gather).collect();
            g.items.retain(|i, _| keep.contains(i));
            g.stacks.retain(|i, _| keep.contains(i));
            data.gathers.insert(key, g);
        }

        let listed: BTreeSet<u32> = data
            .drops
            .values()
            .flat_map(|d| d.items.keys())
            .chain(data.gathers.values().flat_map(|g| g.items.keys()))
            .copied()
            .collect();
        data.items = names.into_iter().filter(|(item, _)| listed.contains(item)).collect();
        let mobs: BTreeSet<u32> = data.drops.keys().copied().chain(data.gathers.keys().map(|&(npc, _)| npc)).collect();
        data.mobs = self
            .mob_votes
            .into_iter()
            .filter(|(npc, _)| mobs.contains(npc))
            .filter_map(|(npc, votes)| most_votes(votes).map(|name| (npc, name)))
            .collect();
        data.sends_counts = data
            .drops
            .values()
            .flat_map(|d| d.stacks.values())
            .chain(data.gathers.values().flat_map(|g| g.stacks.values()))
            .any(|s| !s.counts.is_empty());
        data
    }
}

/// The most-reported value; ties go to the smallest, so the result doesn't depend on order.
fn most_votes<K: Ord>(votes: HashMap<K, u32>) -> Option<K> {
    votes.into_iter().max_by(|a, b| a.1.cmp(&b.1).then_with(|| b.0.cmp(&a.0))).map(|(k, _)| k)
}

/// IDs of the `n` items seen on the most corpses (ties: lower ID first).
fn top(mut items: Vec<(u32, u32)>, n: usize) -> impl Iterator<Item = u32> {
    items.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    items.into_iter().take(n).map(|(i, _)| i)
}

/// Combines whole uploads (used by tests, and handy for offline tools).
pub fn combine(uploads: &[Data], generated: i64, limits: &Limits) -> Data {
    let mut c = Combiner::default();
    for u in uploads {
        c.add(u);
    }
    c.finish(generated, uploads.len() as u32, limits)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::format::{decode, encode, parse_text, write_text};

    const ADDON_EXPORT: &str = include_str!("../tests/fixtures/addon-export.txt");

    fn upload(body: &str) -> Data {
        parse_text(&format!("MD1 U abcdefgh12345678 1795400000 0.1.0 16001\n{body}")).unwrap()
    }

    #[test]
    fn sums_contributors() {
        let a = upload("N 6 10 159:4 755:2 G:3 E:1 $:5:500:50:150 Q:159:1:2 C:159:1:3 C:159:2:1\nS 6 1 4 2318:4 Q:2318:1:2\nI 159 1 Refreshing Spring Water\nI 755 0 Melted Candle\nM 6 Kobold Vermin");
        let b = upload("N 6 20 159:6 4536:1 G:5 $:10:2000:20:400 Q:159:1:3 C:159:1:4 C:159:3:2\nS 6 1 6 2318:5 783:1\nI 159 1 Refreshing Spring Water\nM 6 Kobold Vermin");
        let s = combine(&[a, b], 1800000000, &Limits::default());
        assert_eq!(s.header, Header::Snapshot { generated: 1800000000, contributors: 2 });
        let d = &s.drops[&6];
        assert_eq!((d.kills, d.items[&159], d.items[&755], d.items[&4536], d.grey, d.no_items), (30, 10, 2, 1, 8, 1));
        assert_eq!(d.gold, Some(Gold { n: 15, sum: 2500, min: 20, max: 400 }));
        let q = &d.stacks[&159];
        assert_eq!((q.min, q.max), (1, 3));
        assert_eq!(q.counts, BTreeMap::from([(1, 7), (2, 1), (3, 2)]));
        let g = &s.gathers[&(6, 1)];
        assert_eq!((g.corpses, g.items[&2318], g.items[&783]), (10, 9, 1));
        assert_eq!(s.mobs[&6], "Kobold Vermin");
        // I records only for items that have a name
        assert_eq!(s.items.keys().copied().collect::<Vec<_>>(), vec![159, 755]);
    }

    #[test]
    fn drops_small_samples() {
        let s = combine(&[upload("N 6 4 159:1\nN 7 5 159:1\nS 6 1 4 2318:1\nM 6 Rare\nM 7 Common")], 0, &Limits::default());
        assert_eq!(s.drops.keys().copied().collect::<Vec<_>>(), vec![7]);
        assert!(s.gathers.is_empty());
        assert_eq!(s.mobs.keys().copied().collect::<Vec<_>>(), vec![7], "no M record for a mob that was left out");
    }

    #[test]
    fn keeps_top_items_and_top_greys_separately() {
        let mut body = String::from("N 6 100");
        for i in 1..=15 {
            body += &format!(" {}:{}", 1000 + i, i); // non-grey, hits 1..15
            body += &format!(" {}:{}", 2000 + i, i); // grey
        }
        body += " Q:1001:1:2 Q:1015:1:2";
        for i in 1..=15 {
            body += &format!("\nI {} 0 Grey {i}", 2000 + i);
        }
        let s = combine(&[upload(&body)], 0, &Limits::default());
        let d = &s.drops[&6];
        let kept: Vec<u32> = d.items.keys().copied().collect();
        assert_eq!(kept, (1006..=1015).chain(2008..=2015).collect::<Vec<_>>());
        assert_eq!(d.stacks.keys().copied().collect::<Vec<_>>(), vec![1015], "stack data dropped with its item");
        assert_eq!(s.items.len(), 8, "names only for listed items");
    }

    #[test]
    fn names_go_to_the_majority() {
        let a = upload("N 6 5 159:1\nI 159 1 Water\nM 6 Old Name");
        let b = upload("N 6 5 159:1\nI 159 1 Spring Water\nM 6 New Name");
        let c = upload("N 6 5 159:1\nI 159 1 Spring Water\nM 6 New Name");
        let s = combine(&[a.clone(), b, c], 0, &Limits::default());
        assert_eq!(s.items[&159].name, "Spring Water");
        assert_eq!(s.mobs[&6], "New Name");
        // ties don't depend on upload order
        let d = upload("N 6 5 159:1\nI 159 1 Aqua");
        let one = combine(&[a.clone(), d.clone()], 0, &Limits::default());
        let two = combine(&[d, a], 0, &Limits::default());
        assert_eq!(one.items[&159], two.items[&159]);
    }

    #[test]
    fn snapshot_text_parses_back() {
        let data = decode(ADDON_EXPORT).unwrap();
        let s = combine(&[data.clone()], 1800000000, &Limits::all());
        let text = write_text(&s, true);
        let back = parse_text(&text).unwrap();
        assert_eq!(back, s);
        assert_eq!(back.drops, data.drops);
        assert_eq!(back.gathers, data.gathers);
        assert_eq!(back.items, data.items);
        assert_eq!(back.mobs, data.mobs);
        assert!(back.sends_counts);
        let legacy = parse_text(&write_text(&s, false)).unwrap();
        assert!(!legacy.sends_counts);
        assert_eq!(legacy.drops[&660].stacks[&4338].max, 3, "legacy keeps Q");
    }

    /// Writes tests/fixtures/server-snapshot.txt, which the addon's test harness
    /// imports, so both directions are checked against the other side's code.
    /// Set MD_UPDATE_FIXTURES=1 to rewrite it after a deliberate change.
    #[test]
    fn snapshot_fixture_for_the_addon() {
        let a = decode(ADDON_EXPORT).unwrap();
        let b = upload("N 6 7 159:2 4536:3 G:1 $:4:400:50:200\nN 660 9 4338:6 Q:4338:1:4 C:4338:1:3 C:4338:2:2 C:4338:4:1\nS 6 1 5 2318:4 Q:2318:1:2 C:2318:1:3 C:2318:2:1\nI 4536 1 Shiny Red Apple");
        let s = combine(&[a, b], 1800000000, &Limits { min_kills: 1, ..Limits::default() });
        let body = encode(&write_text(&s, true)) + "\n";
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/server-snapshot.txt");
        let current = std::fs::read_to_string(path).ok();
        if std::env::var_os("MD_UPDATE_FIXTURES").is_some() || current.is_none() {
            std::fs::write(path, &body).unwrap();
        } else {
            assert_eq!(current.unwrap().trim_end(), body.trim_end(), "snapshot output changed; rerun with MD_UPDATE_FIXTURES=1 if that's intended");
        }
    }
}
