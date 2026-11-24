//! The MD1 exchange format, as specified in docs/exchange-format.md and
//! implemented on the addon side by MoldyDrops/Codec.lua.
//!
//! `decode` turns a pasted `!MD1!` string into [`Data`] and rejects anything
//! malformed or impossible. `write_text` and `encode` go the other way; for an
//! upload they produce exactly the text the addon's `Codec.Export` writes.

use std::collections::BTreeMap;
use std::fmt::{self, Write as _};

pub const MAGIC: &str = "!MD1!";
/// Longest pasted string accepted.
pub const MAX_STRING: usize = 2 * 1024 * 1024;
/// Most kills (or corpses gathered) one install may report for one mob.
pub const MAX_KILLS: u32 = 100_000;
/// Largest NPC or item ID accepted. Fits in a Postgres INTEGER.
pub const MAX_ID: u32 = 100_000_000;
/// Largest stack size accepted on one corpse.
pub const MAX_STACK: u32 = 1_000;
/// Most copper accepted on one corpse (10,000 gold).
pub const MAX_COPPER: u32 = 100_000_000;
/// Longest item or mob name, in characters.
pub const MAX_NAME: usize = 120;
/// Most records in one string.
pub const MAX_RECORDS: usize = 200_000;
/// Gathering kinds on S records: 1 skinning, 2 herbalism, 3 mining, 4 engineering, 5 pick pocketing.
pub const PICK_POCKET: u8 = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Header {
    Upload { client_id: String, time: i64, addon_version: String, build: u32 },
    Snapshot { generated: i64, contributors: u32 },
}

/// Q and C tokens for one item: smallest and largest stack seen on one corpse,
/// and how many corpses gave each exact stack size.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Stack {
    pub min: u32,
    pub max: u32,
    pub counts: BTreeMap<u32, u32>,
}

/// The `$` token: corpses with gold, their total, and the smallest and largest amounts, in copper.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Gold {
    pub n: u32,
    pub sum: u64,
    pub min: u32,
    pub max: u32,
}

/// One N record.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Drops {
    pub kills: u32,
    /// item ID -> corpses that held at least one
    pub items: BTreeMap<u32, u32>,
    /// G: corpses with at least one grey item (0 when absent)
    pub grey: u32,
    /// E: corpses with no items (0 when absent)
    pub no_items: u32,
    pub gold: Option<Gold>,
    pub stacks: BTreeMap<u32, Stack>,
}

/// One S record.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Gather {
    pub corpses: u32,
    pub items: BTreeMap<u32, u32>,
    pub stacks: BTreeMap<u32, Stack>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemInfo {
    pub quality: u8,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Data {
    pub header: Header,
    /// N records by NPC ID
    pub drops: BTreeMap<u32, Drops>,
    /// S records by (NPC ID, kind)
    pub gathers: BTreeMap<(u32, u8), Gather>,
    /// I records
    pub items: BTreeMap<u32, ItemInfo>,
    /// M records
    pub mobs: BTreeMap<u32, String>,
    /// Whether any C token was present (the addon is new enough to read them back).
    pub sends_counts: bool,
}

impl Data {
    pub fn new(header: Header) -> Self {
        Data {
            header,
            drops: BTreeMap::new(),
            gathers: BTreeMap::new(),
            items: BTreeMap::new(),
            mobs: BTreeMap::new(),
            sends_counts: false,
        }
    }

    pub fn total_kills(&self) -> u64 {
        self.drops.values().map(|d| d.kills as u64).sum()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FormatError {
    /// 1-based line of the decoded text, or 0 for the string as a whole
    pub line: usize,
    pub message: String,
}

impl fmt::Display for FormatError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.line == 0 {
            f.write_str(&self.message)
        } else {
            write!(f, "line {}: {}", self.line, self.message)
        }
    }
}

impl std::error::Error for FormatError {}

fn err(line: usize, message: impl Into<String>) -> FormatError {
    FormatError { line, message: message.into() }
}

// ---------------------------------------------------------------- base64

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for c in bytes.chunks(3) {
        let b1 = c.get(1).copied().unwrap_or(0) as u32;
        let b2 = c.get(2).copied().unwrap_or(0) as u32;
        let v = (c[0] as u32) << 16 | b1 << 8 | b2;
        out.push(ALPHABET[(v >> 18 & 63) as usize] as char);
        out.push(ALPHABET[(v >> 12 & 63) as usize] as char);
        out.push(if c.len() > 1 { ALPHABET[(v >> 6 & 63) as usize] as char } else { '=' });
        out.push(if c.len() > 2 { ALPHABET[(v & 63) as usize] as char } else { '=' });
    }
    out
}

fn base64_value(c: u8) -> Option<u32> {
    match c {
        b'A'..=b'Z' => Some((c - b'A') as u32),
        b'a'..=b'z' => Some((c - b'a') as u32 + 26),
        b'0'..=b'9' => Some((c - b'0') as u32 + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

/// Lenient like the addon's decoder: anything outside the alphabet (whitespace,
/// padding) is skipped, and a trailing partial group is decoded as far as it goes.
pub fn base64_decode(s: &str) -> Vec<u8> {
    let vals: Vec<u32> = s.bytes().filter_map(base64_value).collect();
    let mut out = Vec::with_capacity(vals.len() / 4 * 3 + 2);
    for g in vals.chunks(4) {
        if g.len() < 2 {
            break;
        }
        let v = g[0] << 18 | g[1] << 12 | g.get(2).copied().unwrap_or(0) << 6 | g.get(3).copied().unwrap_or(0);
        out.push((v >> 16) as u8);
        if g.len() > 2 {
            out.push((v >> 8) as u8);
        }
        if g.len() > 3 {
            out.push(v as u8);
        }
    }
    out
}

// ---------------------------------------------------------------- reading

/// Decodes and validates a pasted `!MD1!` string.
pub fn decode(input: &str) -> Result<Data, FormatError> {
    if input.len() > MAX_STRING {
        return Err(err(0, format!("the string is too long (over {} MB)", MAX_STRING / (1024 * 1024))));
    }
    let input = input.trim_start();
    let Some(body) = input.strip_prefix(MAGIC) else {
        return Err(err(0, format!("that doesn't look like a MoldyDrops string (it should start with {MAGIC})")));
    };
    let text = String::from_utf8(base64_decode(body)).map_err(|_| err(0, "the string is damaged (not valid text)"))?;
    parse_text(&text)
}

/// Parses decoded MD1 text (either kind of header).
pub fn parse_text(text: &str) -> Result<Data, FormatError> {
    let mut lines = text.split('\n');
    let first = lines.next().unwrap_or("").trim_end_matches('\r');
    let mut data = Data::new(parse_header(first)?);
    let mut records = 0usize;
    for (i, raw) in lines.enumerate() {
        let line_no = i + 2;
        let line = raw.trim_end_matches('\r');
        if line.is_empty() {
            continue;
        }
        records += 1;
        if records > MAX_RECORDS {
            return Err(err(line_no, format!("too many records (max {MAX_RECORDS})")));
        }
        let (tag, rest) = line.split_once(' ').unwrap_or((line, ""));
        match tag {
            "N" => parse_drops(rest, line_no, &mut data)?,
            "S" => parse_gather(rest, line_no, &mut data)?,
            "I" => {
                let mut f = rest.splitn(3, ' ');
                let id = id_field(f.next(), "item ID", line_no)?;
                let quality = number(f.next().unwrap_or(""), "quality", 9, line_no)? as u8;
                let name = name_field(f.next(), line_no)?;
                data.items.insert(id, ItemInfo { quality, name });
            }
            "M" => {
                let mut f = rest.splitn(2, ' ');
                let id = id_field(f.next(), "NPC ID", line_no)?;
                let name = name_field(f.next(), line_no)?;
                data.mobs.insert(id, name);
            }
            _ => {} // unknown record types are skipped, so the format can grow
        }
    }
    Ok(data)
}

fn parse_header(line: &str) -> Result<Header, FormatError> {
    let f: Vec<&str> = line.split(' ').collect();
    match f.as_slice() {
        ["MD1", "U", client_id, time, version, build, ..] => {
            if client_id.len() != 16 || !client_id.bytes().all(|b| b.is_ascii_digit() || b.is_ascii_lowercase()) {
                return Err(err(1, "the client ID should be 16 characters of 0-9 and a-z"));
            }
            if version.is_empty() || version.len() > 32 || !version.bytes().all(|b| b.is_ascii_graphic()) {
                return Err(err(1, "bad addon version"));
            }
            Ok(Header::Upload {
                client_id: client_id.to_string(),
                time: number(time, "time", u32::MAX as u64, 1)? as i64,
                addon_version: version.to_string(),
                build: number(build, "build", 100_000_000, 1)? as u32,
            })
        }
        ["MD1", "S", generated, contributors, ..] => Ok(Header::Snapshot {
            generated: number(generated, "time", u32::MAX as u64, 1)? as i64,
            contributors: number(contributors, "contributors", u32::MAX as u64, 1)? as u32,
        }),
        _ => Err(err(0, "the string is damaged or from an incompatible version")),
    }
}

fn number(s: &str, what: &str, max: u64, line: usize) -> Result<u64, FormatError> {
    if s.is_empty() || s.len() > 15 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return Err(err(line, format!("{what} isn't a number: {s:?}")));
    }
    let v: u64 = s.parse().map_err(|_| err(line, format!("{what} isn't a number: {s:?}")))?;
    if v > max {
        return Err(err(line, format!("{what} {v} is too large (max {max})")));
    }
    Ok(v)
}

fn id_field(s: Option<&str>, what: &str, line: usize) -> Result<u32, FormatError> {
    let v = number(s.unwrap_or(""), what, MAX_ID as u64, line)? as u32;
    if v == 0 {
        return Err(err(line, format!("{what} 0 isn't allowed")));
    }
    Ok(v)
}

fn name_field(s: Option<&str>, line: usize) -> Result<String, FormatError> {
    let name: String = s.unwrap_or("").chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    let name = name.trim();
    if name.is_empty() {
        return Err(err(line, "missing name"));
    }
    if name.chars().count() > MAX_NAME {
        return Err(err(line, format!("name is longer than {MAX_NAME} characters")));
    }
    Ok(name.to_string())
}

/// What the tokens after the fixed fields of an N or S record hold.
#[derive(Default)]
struct Tokens {
    items: BTreeMap<u32, u32>,
    grey: Option<u32>,
    no_items: Option<u32>,
    gold: Option<Gold>,
    stacks: BTreeMap<u32, Stack>,
    counts: BTreeMap<u32, BTreeMap<u32, u32>>,
}

/// `total` is the record's kills or corpses, which no count may exceed.
fn read_tokens<'a>(tokens: impl Iterator<Item = &'a str>, total: u32, what: &str, line: usize) -> Result<Tokens, FormatError> {
    let mut t = Tokens::default();
    let at_most = |v: u64, label: &str| -> Result<u32, FormatError> {
        if v > total as u64 {
            Err(err(line, format!("{label} is {v}, more than the {total} {what}")))
        } else {
            Ok(v as u32)
        }
    };
    for token in tokens {
        if token.is_empty() {
            continue;
        }
        let p: Vec<&str> = token.split(':').collect();
        match (p[0], p.len()) {
            ("G", 2) => {
                let v = at_most(number(p[1], "G", u64::MAX, line)?, "G (corpses with grey items)")?;
                if t.grey.replace(v).is_some() {
                    return Err(err(line, "G appears twice"));
                }
            }
            ("E", 2) => {
                let v = at_most(number(p[1], "E", u64::MAX, line)?, "E (corpses with no items)")?;
                if t.no_items.replace(v).is_some() {
                    return Err(err(line, "E appears twice"));
                }
            }
            ("$", 5) => {
                let n = at_most(number(p[1], "gold count", u64::MAX, line)?, "gold count")?;
                let sum = number(p[2], "gold total", u64::MAX / 2, line)?;
                let min = number(p[3], "gold min", MAX_COPPER as u64, line)? as u32;
                let max = number(p[4], "gold max", MAX_COPPER as u64, line)? as u32;
                if n > 0 {
                    if min > max || sum < n as u64 * min as u64 || sum > n as u64 * max as u64 {
                        return Err(err(line, "gold total doesn't fit between the min and max"));
                    }
                    if t.gold.replace(Gold { n, sum, min, max }).is_some() {
                        return Err(err(line, "$ appears twice"));
                    }
                }
            }
            ("Q", 4) => {
                let item = id_field(Some(p[1]), "item ID", line)?;
                let min = number(p[2], "stack min", MAX_STACK as u64, line)? as u32;
                let max = number(p[3], "stack max", MAX_STACK as u64, line)? as u32;
                if min == 0 || min > max {
                    return Err(err(line, format!("item {item}: bad stack range {min}-{max}")));
                }
                let stack = Stack { min, max, counts: BTreeMap::new() };
                if t.stacks.insert(item, stack).is_some() {
                    return Err(err(line, format!("Q for item {item} appears twice")));
                }
            }
            ("C", 4) => {
                let item = id_field(Some(p[1]), "item ID", line)?;
                let stack = number(p[2], "stack size", MAX_STACK as u64, line)? as u32;
                let corpses = at_most(number(p[3], "C corpses", u64::MAX, line)?, &format!("C for item {item} x{stack}"))?;
                if stack == 0 {
                    return Err(err(line, format!("item {item}: stack size 0")));
                }
                if t.counts.entry(item).or_default().insert(stack, corpses).is_some() {
                    return Err(err(line, format!("C for item {item} x{stack} appears twice")));
                }
            }
            (id, 2) if id.bytes().all(|b| b.is_ascii_digit()) => {
                let item = id_field(Some(id), "item ID", line)?;
                let hits = at_most(number(p[1], "item count", u64::MAX, line)?, &format!("item {item}'s count"))?;
                if t.items.insert(item, hits).is_some() {
                    return Err(err(line, format!("item {item} appears twice")));
                }
            }
            _ => {} // unknown tokens are skipped, so records can grow
        }
    }
    // Stack data only means something for items the record lists.
    t.stacks.retain(|item, _| t.items.contains_key(item));
    for (item, counts) in std::mem::take(&mut t.counts) {
        let Some(stack) = t.stacks.get_mut(&item) else { continue };
        if let Some(size) = counts.keys().copied().find(|&size| size < stack.min || size > stack.max) {
            return Err(err(line, format!("item {item}: C stack size {size} is outside its Q range {}-{}", stack.min, stack.max)));
        }
        stack.counts = counts;
    }
    Ok(t)
}

fn parse_drops(rest: &str, line: usize, data: &mut Data) -> Result<(), FormatError> {
    let mut f = rest.split(' ');
    let npc = id_field(f.next(), "NPC ID", line)?;
    let kills = number(f.next().unwrap_or(""), "kills", MAX_KILLS as u64, line)? as u32;
    if kills == 0 {
        return Ok(()); // nothing observed; the addon never writes these
    }
    let t = read_tokens(f, kills, "kills", line)?;
    if t.items.contains_key(&0) {
        return Err(err(line, "item ID 0 isn't allowed"));
    }
    let drops = Drops {
        kills,
        items: t.items,
        grey: t.grey.unwrap_or(0),
        no_items: t.no_items.unwrap_or(0),
        gold: t.gold,
        stacks: t.stacks,
    };
    if drops.stacks.values().any(|s| !s.counts.is_empty()) {
        data.sends_counts = true;
    }
    if data.drops.insert(npc, drops).is_some() {
        return Err(err(line, format!("NPC {npc} has two N records")));
    }
    Ok(())
}

fn parse_gather(rest: &str, line: usize, data: &mut Data) -> Result<(), FormatError> {
    let mut f = rest.split(' ');
    let npc = id_field(f.next(), "NPC ID", line)?;
    let kind = number(f.next().unwrap_or(""), "gathering kind", 9, line)? as u8;
    let corpses = number(f.next().unwrap_or(""), "corpses", MAX_KILLS as u64, line)? as u32;
    if !(1..=PICK_POCKET).contains(&kind) || corpses == 0 {
        return Ok(()); // a kind this version doesn't know, or nothing gathered
    }
    let t = read_tokens(f, corpses, "corpses", line)?;
    let gather = Gather { corpses, items: t.items, stacks: t.stacks };
    if gather.stacks.values().any(|s| !s.counts.is_empty()) {
        data.sends_counts = true;
    }
    if data.gathers.insert((npc, kind), gather).is_some() {
        return Err(err(line, format!("NPC {npc} has two S records of kind {kind}")));
    }
    Ok(())
}

// ---------------------------------------------------------------- writing

/// Writes the Q and C tokens for items stacked more than one at a time.
fn write_stacks(out: &mut String, stacks: &BTreeMap<u32, Stack>, with_counts: bool) {
    for (item, s) in stacks {
        if s.max <= 1 {
            continue;
        }
        let _ = write!(out, " Q:{item}:{}:{}", s.min, s.max);
        if with_counts {
            for (size, corpses) in &s.counts {
                let _ = write!(out, " C:{item}:{size}:{corpses}");
            }
        }
    }
}

/// Writes MD1 text in the addon's record order: N, then S (gathering, then pick
/// pocketing), then M, then I. `with_counts` false leaves out C tokens, for
/// addons from before they existed.
pub fn write_text(data: &Data, with_counts: bool) -> String {
    let mut out = String::new();
    match &data.header {
        Header::Upload { client_id, time, addon_version, build } => {
            let _ = write!(out, "MD1 U {client_id} {time} {addon_version} {build}");
        }
        Header::Snapshot { generated, contributors } => {
            let _ = write!(out, "MD1 S {generated} {contributors}");
        }
    }
    for (npc, d) in &data.drops {
        let _ = write!(out, "\nN {npc} {}", d.kills);
        for (item, hits) in &d.items {
            let _ = write!(out, " {item}:{hits}");
        }
        if d.grey > 0 {
            let _ = write!(out, " G:{}", d.grey);
        }
        if d.no_items > 0 {
            let _ = write!(out, " E:{}", d.no_items);
        }
        if let Some(g) = d.gold {
            let _ = write!(out, " $:{}:{}:{}:{}", g.n, g.sum, g.min, g.max);
        }
        write_stacks(&mut out, &d.stacks, with_counts);
    }
    let mut gathers: Vec<_> = data.gathers.iter().collect();
    gathers.sort_by_key(|((npc, kind), _)| (*kind == PICK_POCKET, *npc, *kind));
    for ((npc, kind), g) in gathers {
        let _ = write!(out, "\nS {npc} {kind} {}", g.corpses);
        for (item, hits) in &g.items {
            let _ = write!(out, " {item}:{hits}");
        }
        write_stacks(&mut out, &g.stacks, with_counts);
    }
    for (npc, name) in &data.mobs {
        let _ = write!(out, "\nM {npc} {name}");
    }
    for (item, info) in &data.items {
        let _ = write!(out, "\nI {item} {} {}", info.quality, info.name);
    }
    out
}

/// Wraps MD1 text as a `!MD1!` string.
pub fn encode(text: &str) -> String {
    format!("{MAGIC}{}", base64_encode(text.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const ADDON_EXPORT: &str = include_str!("../tests/fixtures/addon-export.txt");

    fn upload_text(body: &str) -> String {
        format!("MD1 U abcdefgh12345678 1795400000 0.1.0 16001\n{body}")
    }

    fn parse_err(body: &str) -> String {
        parse_text(&upload_text(body)).unwrap_err().to_string()
    }

    #[test]
    fn base64_matches_standard() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"M"), "TQ==");
        assert_eq!(base64_encode(b"Mo"), "TW8=");
        assert_eq!(base64_encode(b"Mol"), "TW9s");
        assert_eq!(base64_encode(b"MoldyDrops!?"), "TW9sZHlEcm9wcyE/");
        let all: Vec<u8> = (0..=255).collect();
        assert_eq!(base64_decode(&base64_encode(&all)), all);
        // whitespace and missing padding are fine, as in the addon
        assert_eq!(base64_decode("TW9s\r\nZHk"), b"Moldy");
    }

    #[test]
    fn reads_the_addon_export() {
        let data = decode(ADDON_EXPORT).unwrap();
        assert_eq!(
            data.header,
            Header::Upload {
                client_id: "5j7fwbs1obleezex".into(),
                time: 1795400000,
                addon_version: "0.1.0".into(),
                build: 16001
            }
        );
        let d6 = &data.drops[&6];
        assert_eq!((d6.kills, d6.items[&159], d6.items[&755], d6.grey, d6.no_items), (3, 1, 2, 2, 1));
        assert_eq!(d6.gold, Some(Gold { n: 1, sum: 150, min: 150, max: 150 }));
        let s660 = &data.drops[&660].stacks[&4338];
        assert_eq!((s660.min, s660.max), (1, 3));
        assert_eq!(s660.counts, BTreeMap::from([(1, 2), (3, 1)]));
        assert_eq!(data.drops[&660].items.len(), 1, "Q and C numbers aren't read as items");
        assert_eq!(data.gathers[&(6, 1)].items[&2318], 1);
        assert_eq!(data.gathers[&(6, 5)].items[&159], 1);
        assert_eq!(data.gathers[&(274400, 2)].corpses, 1);
        assert_eq!(data.mobs[&274300], "Coldrasp");
        assert_eq!(data.items[&755], ItemInfo { quality: 0, name: "Melted Candle".into() });
        assert!(data.sends_counts);
        assert_eq!(data.total_kills(), 10);
    }

    #[test]
    fn writes_exactly_what_the_addon_writes() {
        let data = decode(ADDON_EXPORT).unwrap();
        assert_eq!(encode(&write_text(&data, true)), ADDON_EXPORT.trim());
    }

    #[test]
    fn legacy_text_leaves_out_counts() {
        let data = decode(ADDON_EXPORT).unwrap();
        let text = write_text(&data, false);
        assert!(text.contains("N 660 3 4338:3 Q:4338:1:3\n"));
        assert!(!text.contains("C:"));
    }

    #[test]
    fn snapshot_round_trip() {
        let text = "MD1 S 1795400000 7\nN 6 120 159:8 755:36 G:40 E:30 $:100:5000:10:90\nS 113 1 25 783:5 2318:20 Q:2318:1:3 C:2318:1:15 C:2318:3:5\nM 274301 Gale Wisp\nI 99999 3 Skyborne Trinket";
        let data = parse_text(text).unwrap();
        assert_eq!(data.header, Header::Snapshot { generated: 1795400000, contributors: 7 });
        assert_eq!(write_text(&data, true), text);
    }

    #[test]
    fn skips_unknown_records_and_tokens() {
        let data = parse_text(&upload_text("Z future record\nN 6 10 159:2 X:9 W:1:2:3:4:5\nS 5 9 10 1:1\n\n")).unwrap();
        assert_eq!(data.drops[&6].items, BTreeMap::from([(159, 2)]));
        assert!(data.gathers.is_empty());
    }

    #[test]
    fn rejects_bad_strings() {
        assert!(decode("hello").unwrap_err().message.contains("!MD1!"));
        assert!(decode("!MD1!@@@@").is_err());
        assert!(decode(&encode("MD1 X 1")).is_err());
        assert!(decode(&"A".repeat(MAX_STRING + 1)).unwrap_err().message.contains("too long"));
        assert!(parse_text("MD1 U short 1 0.1.0 1").unwrap_err().message.contains("client ID"));
        assert!(parse_text("MD1 U ABCDEFGH12345678 1 0.1.0 1").is_err(), "upper case isn't a valid client ID");
    }

    #[test]
    fn rejects_impossible_counts() {
        assert_eq!(parse_err("N 6 3 159:4"), "line 2: item 159's count is 4, more than the 3 kills");
        assert!(parse_err("N 6 3 G:4").contains("G (corpses with grey items)"));
        assert!(parse_err("N 6 3 E:9").contains("E (corpses"));
        assert!(parse_err("N 6 200000").contains("kills 200000 is too large"));
        assert!(parse_err("N 6 3 0:1").contains("item ID 0"));
        assert!(parse_err("N 0 3").contains("NPC ID 0"));
        assert!(parse_err("N 6 3 159:1 159:1").contains("appears twice"));
        assert!(parse_err("N 6 3\nN 6 4").contains("two N records"));
        assert!(parse_err("N 6 3 $:1:500:10:90").contains("gold total"));
        assert!(parse_err("N 6 3 159:1 Q:159:3:2").contains("stack range"));
        assert!(parse_err("N 6 3 159:1 Q:159:1:2 C:159:5:1").contains("outside its Q range"));
        assert!(parse_err("N 6 3 159:1 Q:159:1:2 C:159:2:4").contains("more than the 3 kills"));
        assert!(parse_err("N 6 x").contains("isn't a number"));
        assert!(parse_err("S 6 1 5 2318:6").contains("more than the 5 corpses"));
        assert!(parse_err("I 159 1 ").contains("missing name"));
        assert!(parse_err(&format!("M 6 {}", "x".repeat(MAX_NAME + 1))).contains("longer than"));
    }

    #[test]
    fn drops_stack_data_for_unlisted_items() {
        let data = parse_text(&upload_text("N 6 3 159:1 Q:755:1:3 C:755:1:1")).unwrap();
        assert!(data.drops[&6].stacks.is_empty());
        assert!(!data.sends_counts);
    }

    #[test]
    fn names_lose_control_characters() {
        let data = parse_text(&upload_text("I 159 1 Spring\tWater \r\nM 6 Kobold  ")).unwrap();
        assert_eq!(data.items[&159].name, "Spring Water");
        assert_eq!(data.mobs[&6], "Kobold");
    }
}
