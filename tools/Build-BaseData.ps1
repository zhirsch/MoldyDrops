<#
.SYNOPSIS
  Builds MoldyDrops_112\BaseData.lua from the CMaNGOS classic-db full dump.

.DESCRIPTION
  Download the dump from https://github.com/cmangos/classic-db/tree/master/Full_DB
  (ClassicDB_1_12_1_*.sql.gz), then run:

    .\tools\Build-BaseData.ps1 -Dump path\to\ClassicDB_1_12_1_z2815.sql.gz

  Keeps creatures spawned on the open-world maps (0 = Eastern Kingdoms,
  1 = Kalimdor) and computes each item's chance to drop at least once per kill,
  following CMaNGOS loot rules (grouped loot, equal-chance group members and
  nested reference tables).
#>
param(
  [Parameter(Mandatory)] [string] $Dump,
  [string] $Out = (Join-Path $PSScriptRoot '..\MoldyDrops_112\BaseData.lua'),
  [int] $TopN = 10   # tooltip shows 5; the /drops window shows up to 10
)

$ErrorActionPreference = 'Stop'

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;

public static class LootBuilder
{
    class LootRow { public int Item; public double Chance; public int Group; public int MinOrRef; public int MaxCount; }

    static IEnumerable<List<string>> Tuples(string line)
    {
        int i = line.IndexOf(" VALUES ", StringComparison.Ordinal);
        if (i < 0) yield break;
        i += 8;
        var fields = new List<string>();
        var sb = new StringBuilder();
        bool inStr = false, inTuple = false, quoted = false;
        for (; i < line.Length; i++)
        {
            char c = line[i];
            if (inStr)
            {
                if (c == '\\' && i + 1 < line.Length) { i++; sb.Append(line[i] == 'n' ? '\n' : line[i]); }
                else if (c == '\'') inStr = false;
                else sb.Append(c);
                continue;
            }
            if (!inTuple) { if (c == '(') { inTuple = true; fields = new List<string>(); sb.Clear(); quoted = false; } continue; }
            if (c == '\'') { inStr = true; quoted = true; }
            else if (c == ',') { fields.Add(Field(sb, quoted)); sb.Clear(); quoted = false; }
            else if (c == ')') { fields.Add(Field(sb, quoted)); inTuple = false; yield return fields; }
            else sb.Append(c);
        }
    }

    static string Field(StringBuilder sb, bool quoted)
    {
        var s = sb.ToString();
        return (!quoted && s == "NULL") ? null : s;
    }

    static int I(string s) { return s == null ? 0 : (int)double.Parse(s, CultureInfo.InvariantCulture); }
    static double D(string s) { return s == null ? 0 : double.Parse(s, CultureInfo.InvariantCulture); }

    static Dictionary<int, List<LootRow>> creatureLoot = new Dictionary<int, List<LootRow>>();
    static Dictionary<int, List<LootRow>> refLoot = new Dictionary<int, List<LootRow>>();
    static Dictionary<int, List<LootRow>> itemLoot = new Dictionary<int, List<LootRow>>(); // containers
    static Dictionary<int, List<LootRow>> skinLoot = new Dictionary<int, List<LootRow>>(); // skinning, herbs, mining, engineering
    static Dictionary<int, List<LootRow>> pickLoot = new Dictionary<int, List<LootRow>>(); // pick pocketing

    // Which profession gathers from a corpse, from creature_template.CreatureTypeFlags:
    // 1 = skinning (default), 2 = herbalism (0x100), 3 = mining (0x200), 4 = engineering (0x8000).
    static int GatherKind(int typeFlags)
    {
        if ((typeFlags & 0x100) != 0) return 2;
        if ((typeFlags & 0x200) != 0) return 3;
        if ((typeFlags & 0x8000) != 0) return 4;
        return 1;
    }
    static Dictionary<int, Dictionary<int, double>> refCache = new Dictionary<int, Dictionary<int, double>>();

    // P(at least one) when combining independent sources.
    static void AddProb(Dictionary<int, double> acc, int item, double p)
    {
        if (p <= 0) return;
        double prev;
        acc[item] = acc.TryGetValue(item, out prev) ? 1 - (1 - prev) * (1 - p) : p;
    }

    // Quest-only rows (negative chance: they drop only while you're on the quest)
    // are left out everywhere. Rows with a positive chance drop for everyone, so
    // they stay even when the item's class is Quest (12), e.g. Gorilla Fang.
    static HashSet<int> questClass = new HashSet<int>();
    static bool Keep(LootRow r) { return r.Chance >= 0; }

    static Dictionary<int, double> Expand(List<LootRow> rows, int depth)
    {
        var result = new Dictionary<int, double>();
        if (rows == null || depth > 8) return result;

        foreach (var grp in rows.Where(Keep).GroupBy(r => r.Group))
        {
            var list = grp.ToList();
            if (grp.Key == 0)
            {
                foreach (var r in list) AddSource(result, r, Math.Abs(r.Chance) / 100.0, depth);
            }
            else
            {
                // Exactly one entry of a group drops: explicit chances first,
                // zero-chance entries share whatever probability is left.
                double explicitSum = list.Where(r => r.Chance != 0).Sum(r => Math.Abs(r.Chance));
                int equalCount = list.Count(r => r.Chance == 0);
                double equalP = equalCount > 0 ? Math.Max(0, 100 - explicitSum) / equalCount / 100.0 : 0;
                foreach (var r in list) AddSource(result, r, r.Chance != 0 ? Math.Abs(r.Chance) / 100.0 : equalP, depth);
            }
        }
        return result;
    }

    // Quest drops (negative chance) in a loot table: item -> chance per kill
    // while you need it. Each row rolls on its own; references in group 0 are
    // followed (CMaNGOS rarely puts quest drops anywhere else).
    static Dictionary<int, Dictionary<int, double>> questRefCache = new Dictionary<int, Dictionary<int, double>>();
    static Dictionary<int, double> QuestExpand(List<LootRow> rows, int depth)
    {
        var result = new Dictionary<int, double>();
        if (rows == null || depth > 8) return result;
        foreach (var r in rows)
        {
            if (r.MinOrRef >= 0)
            {
                if (r.Chance < 0) AddProb(result, r.Item, -r.Chance / 100.0);
            }
            else if (r.Group == 0 && r.Chance > 0)
            {
                int refId = -r.MinOrRef;
                Dictionary<int, double> inner;
                if (!questRefCache.TryGetValue(refId, out inner))
                {
                    List<LootRow> rr; refLoot.TryGetValue(refId, out rr);
                    questRefCache[refId] = inner = QuestExpand(rr, depth + 1);
                }
                int times = Math.Max(1, r.MaxCount);
                foreach (var kv in inner) AddProb(result, kv.Key, 1 - Math.Pow(1 - r.Chance / 100.0 * kv.Value, times));
            }
        }
        return result;
    }

    // Count ranges of the quest drops in a loot table (item -> (min, max)).
    static Dictionary<int, Tuple<int, int>> QuestCounts(List<LootRow> rows, int depth)
    {
        var result = new Dictionary<int, Tuple<int, int>>();
        if (rows == null || depth > 8) return result;
        foreach (var r in rows)
        {
            if (r.MinOrRef < 0)
            {
                List<LootRow> rr; refLoot.TryGetValue(-r.MinOrRef, out rr);
                foreach (var kv in QuestCounts(rr, depth + 1)) MergeCount(result, kv.Key, kv.Value.Item1, kv.Value.Item2);
            }
            else if (r.Chance < 0)
            {
                int min = Math.Max(1, r.MinOrRef);
                MergeCount(result, r.Item, min, Math.Max(min, r.MaxCount));
            }
        }
        return result;
    }

    // Chance that a loot table gives no items at all. Quest-only drops
    // (negative chance) are left out, since they need the quest.
    static Dictionary<int, double> refNothingCache = new Dictionary<int, double>();
    static double NothingProb(List<LootRow> rows, int depth)
    {
        if (rows == null || depth > 8) return 1;
        double nothing = 1;
        foreach (var grp in rows.GroupBy(r => r.Group))
        {
            var list = grp.Where(Keep).ToList();
            if (list.Count == 0) continue;
            if (grp.Key == 0)
            {
                foreach (var r in list) nothing *= 1 - SomethingProb(r, r.Chance / 100.0, depth);
            }
            else
            {
                // A group gives one entry; with any equal-chance entries it always gives something.
                double explicitSum = list.Where(r => r.Chance > 0).Sum(r => r.Chance);
                bool hasEqual = list.Any(r => r.Chance == 0);
                double pGroup = hasEqual ? 1 : Math.Min(1, explicitSum / 100.0);
                nothing *= 1 - pGroup;
            }
        }
        return nothing;
    }

    // Chance one row gives at least one item, given its roll chance p.
    static double SomethingProb(LootRow r, double p, int depth)
    {
        if (r.MinOrRef >= 0) return p;
        int refId = -r.MinOrRef;
        double refNothing;
        if (!refNothingCache.TryGetValue(refId, out refNothing))
        {
            List<LootRow> rr; refLoot.TryGetValue(refId, out rr);
            refNothing = NothingProb(rr, depth + 1);
            refNothingCache[refId] = refNothing;
        }
        int times = Math.Max(1, r.MaxCount);
        return 1 - Math.Pow(1 - p * (1 - refNothing), times);
    }

    static void AddSource(Dictionary<int, double> result, LootRow r, double p, int depth)
    {
        if (r.MinOrRef < 0)
        {
            int refId = -r.MinOrRef;
            Dictionary<int, double> inner;
            if (!refCache.TryGetValue(refId, out inner))
            {
                List<LootRow> rr; refLoot.TryGetValue(refId, out rr);
                inner = Expand(rr, depth + 1);
                refCache[refId] = inner;
            }
            int times = Math.Max(1, r.MaxCount);
            foreach (var kv in inner)
                AddProb(result, kv.Key, 1 - Math.Pow(1 - p * kv.Value, times));
        }
        else
        {
            AddProb(result, r.Item, p);
        }
    }

    // How many of each item a loot table can give at once: item -> (min, max).
    // References are followed; their roll count isn't multiplied in.
    static Dictionary<int, Tuple<int, int>> Counts(List<LootRow> rows, int depth)
    {
        var result = new Dictionary<int, Tuple<int, int>>();
        if (rows == null || depth > 8) return result;
        foreach (var r in rows.Where(Keep))
        {
            if (r.MinOrRef < 0)
            {
                List<LootRow> rr; refLoot.TryGetValue(-r.MinOrRef, out rr);
                foreach (var kv in Counts(rr, depth + 1)) MergeCount(result, kv.Key, kv.Value.Item1, kv.Value.Item2);
            }
            else
            {
                int min = Math.Max(1, r.MinOrRef);
                MergeCount(result, r.Item, min, Math.Max(min, r.MaxCount));
            }
        }
        return result;
    }

    static void MergeCount(Dictionary<int, Tuple<int, int>> acc, int item, int min, int max)
    {
        Tuple<int, int> prev;
        acc[item] = acc.TryGetValue(item, out prev)
            ? Tuple.Create(Math.Min(prev.Item1, min), Math.Max(prev.Item2, max))
            : Tuple.Create(min, max);
    }

    // "[key]={itemID,min,max,...}," for the listed items that can come more than one at a time.
    static string QtyLine(int key, IEnumerable<int> items, Dictionary<int, Tuple<int, int>> counts)
    {
        var parts = new List<string>();
        foreach (var id in items.Distinct())
        {
            Tuple<int, int> c;
            if (id != 0 && counts.TryGetValue(id, out c) && c.Item2 > 1)
                parts.Add(id + "," + c.Item1 + "," + c.Item2);
        }
        return parts.Count == 0 ? null : "[" + key + "]={" + string.Join(",", parts) + "},";
    }

    static string LuaStr(string s)
    {
        return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n") + "\"";
    }

    public static string Build(string dumpPath, string outPath, int topN)
    {
        var lootIdOf = new Dictionary<int, int>();
        var openWorld = new HashSet<int>();
        var itemInfo = new Dictionary<int, Tuple<string, int>>();
        var mobInfo = new Dictionary<int, Tuple<string, int, int, int>>(); // name, min level, max level, model (display) ID
        var gatherOf = new Dictionary<int, Tuple<int, int>>(); // npc -> (skinning loot id, gather kind)
        var goldOf = new Dictionary<int, Tuple<int, int>>();   // npc -> (min copper, max copper)
        var pickOf = new Dictionary<int, int>();                // npc -> pickpocketing loot id
        var questsFor = new Dictionary<int, SortedSet<int>>();  // item -> quests that need it

        Stream s = File.OpenRead(dumpPath);
        if (dumpPath.EndsWith(".gz", StringComparison.OrdinalIgnoreCase)) s = new GZipStream(s, CompressionMode.Decompress);
        using (var reader = new StreamReader(s, Encoding.UTF8))
        {
            string line;
            while ((line = reader.ReadLine()) != null)
            {
                if (!line.StartsWith("INSERT INTO `", StringComparison.Ordinal)) continue;
                int e = line.IndexOf('`', 13);
                string table = line.Substring(13, e - 13);
                switch (table)
                {
                    case "creature":
                        foreach (var f in Tuples(line)) { int map = I(f[2]); if (map == 0 || map == 1) openWorld.Add(I(f[1])); }
                        break;
                    case "creature_template":
                        foreach (var f in Tuples(line))
                        {
                            int loot = I(f[56]);
                            if (loot > 0) lootIdOf[I(f[0])] = loot;
                            int minGold = I(f[54]), maxGold = I(f[55]);
                            if (maxGold > 0) goldOf[I(f[0])] = Tuple.Create(minGold, maxGold);
                            int pick = I(f[57]);
                            if (pick > 0) pickOf[I(f[0])] = pick;
                            int skin = I(f[58]);
                            if (skin > 0) gatherOf[I(f[0])] = Tuple.Create(skin, GatherKind(I(f[20])));
                            mobInfo[I(f[0])] = Tuple.Create(f[1] ?? "", I(f[3]), I(f[4]), I(f[5]));
                        }
                        break;
                    case "item_template":
                        foreach (var f in Tuples(line))
                        {
                            itemInfo[I(f[0])] = Tuple.Create(f[3] ?? "", I(f[5]));
                            if (I(f[1]) == 12) questClass.Add(I(f[0])); // class 12 = Quest
                        }
                        break;
                    case "quest_template":
                        // ReqItemId1-4 (items to hand in) and ReqSourceId1-4 (items used along the way)
                        foreach (var f in Tuples(line))
                            foreach (int col in new[] { 40, 41, 42, 43, 48, 49, 50, 51 })
                            {
                                int item = I(f[col]);
                                if (item <= 0) continue;
                                SortedSet<int> qs;
                                if (!questsFor.TryGetValue(item, out qs)) questsFor[item] = qs = new SortedSet<int>();
                                qs.Add(I(f[0]));
                            }
                        break;
                    case "creature_loot_template":
                    case "reference_loot_template":
                    case "item_loot_template":
                    case "skinning_loot_template":
                    case "pickpocketing_loot_template":
                        var target = table == "creature_loot_template" ? creatureLoot
                            : table == "item_loot_template" ? itemLoot
                            : table == "skinning_loot_template" ? skinLoot
                            : table == "pickpocketing_loot_template" ? pickLoot : refLoot;
                        foreach (var f in Tuples(line))
                        {
                            var row = new LootRow { Item = I(f[1]), Chance = D(f[2]), Group = I(f[3]), MinOrRef = I(f[4]), MaxCount = I(f[5]) };
                            List<LootRow> l;
                            if (!target.TryGetValue(I(f[0]), out l)) target[I(f[0])] = l = new List<LootRow>();
                            l.Add(row);
                        }
                        break;
                }
            }
        }

        var npcLines = new List<string>();
        var mobLines = new List<string>();
        var namedMobs = new HashSet<int>();
        var usedItems = new SortedSet<int>();
        var lootCache = new Dictionary<int, List<KeyValuePair<int, double>>>();
        var greyCache = new Dictionary<int, List<KeyValuePair<int, double>>>();
        var greyLines = new List<string>();
        foreach (var npc in openWorld.OrderBy(x => x))
        {
            int lootId;
            if (!lootIdOf.TryGetValue(npc, out lootId)) continue;
            List<KeyValuePair<int, double>> top;
            if (!lootCache.TryGetValue(lootId, out top))
            {
                List<LootRow> rows; creatureLoot.TryGetValue(lootId, out rows);
                var all = Expand(rows, 0).Where(kv => itemInfo.ContainsKey(kv.Key)).ToList();
                // Poor (grey) items collapse into one entry, item ID 0: the chance of
                // at least one grey item, treating the sources as independent.
                double noGrey = 1;
                foreach (var kv in all) if (itemInfo[kv.Key].Item2 == 0) noGrey *= 1 - kv.Value;
                var list = all.Where(kv => itemInfo[kv.Key].Item2 != 0).ToList();
                if (noGrey < 1) list.Add(new KeyValuePair<int, double>(0, 1 - noGrey));
                top = list.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(topN).ToList();
                lootCache[lootId] = top;
                greyCache[lootId] = all.Where(kv => itemInfo[kv.Key].Item2 == 0)
                    .OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(topN).ToList();
            }
            var greys = greyCache[lootId];
            if (greys.Count > 0 && top.Any(kv => kv.Key == 0))
            {
                var gs = new StringBuilder();
                gs.Append('[').Append(npc).Append("]={");
                for (int i = 0; i < greys.Count; i++)
                {
                    if (i > 0) gs.Append(',');
                    double pct = greys[i].Value * 100;
                    gs.Append(greys[i].Key).Append(',').Append(pct.ToString(pct >= 1 ? "0.#" : "0.###", CultureInfo.InvariantCulture));
                    usedItems.Add(greys[i].Key);
                }
                gs.Append("},");
                greyLines.Add(gs.ToString());
            }
            if (top.Count == 0) continue;
            var sb = new StringBuilder();
            sb.Append('[').Append(npc).Append("]={");
            for (int i = 0; i < top.Count; i++)
            {
                if (i > 0) sb.Append(',');
                double pct = top[i].Value * 100;
                sb.Append(top[i].Key).Append(',').Append(pct.ToString(pct >= 1 ? "0.#" : "0.###", CultureInfo.InvariantCulture));
                if (top[i].Key != 0) usedItems.Add(top[i].Key);
            }
            sb.Append("},");
            npcLines.Add(sb.ToString());
            Tuple<string, int, int, int> mi;
            if (mobInfo.TryGetValue(npc, out mi))
            {
                mobLines.Add(string.Format("[{0}]={{{1},{2},{3},{4}}},", npc, LuaStr(mi.Item1), mi.Item2, mi.Item3, mi.Item4));
                namedMobs.Add(npc);
            }
        }

        // Chance of no items, and gold: extra[npc] = { noItemsPercent [, minCopper, maxCopper] }
        var extraLines = new List<string>();
        foreach (var npc in openWorld.OrderBy(x => x))
        {
            int lootId;
            bool hasLoot = lootIdOf.TryGetValue(npc, out lootId) && creatureLoot.ContainsKey(lootId);
            Tuple<int, int> gold;
            bool hasGold = goldOf.TryGetValue(npc, out gold);
            if (!hasLoot && !hasGold) continue;
            double nothing = hasLoot ? NothingProb(creatureLoot[lootId], 0) : 1;
            double pct = nothing * 100;
            var es = new StringBuilder();
            es.Append('[').Append(npc).Append("]={").Append(pct.ToString(pct >= 1 ? "0.#" : "0.###", CultureInfo.InvariantCulture));
            if (hasGold) es.Append(',').Append(gold.Item1).Append(',').Append(gold.Item2);
            es.Append("},");
            extraLines.Add(es.ToString());
            Tuple<string, int, int, int> em;
            if (!namedMobs.Contains(npc) && mobInfo.TryGetValue(npc, out em))
            {
                mobLines.Add(string.Format("[{0}]={{{1},{2},{3},{4}}},", npc, LuaStr(em.Item1), em.Item2, em.Item3, em.Item4));
                namedMobs.Add(npc);
            }
        }

        // What gathering a corpse yields: gather[npc] = { kind, itemID, percent, ... }
        var gatherLines = new List<string>();
        var gatherCache = new Dictionary<int, List<KeyValuePair<int, double>>>();
        var kindCounts = new int[5];
        foreach (var npc in openWorld.OrderBy(x => x))
        {
            Tuple<int, int> g;
            if (!gatherOf.TryGetValue(npc, out g)) continue;
            List<KeyValuePair<int, double>> items;
            if (!gatherCache.TryGetValue(g.Item1, out items))
            {
                List<LootRow> rows; skinLoot.TryGetValue(g.Item1, out rows);
                items = Expand(rows, 0).Where(kv => itemInfo.ContainsKey(kv.Key))
                    .OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(topN).ToList();
                gatherCache[g.Item1] = items;
            }
            if (items.Count == 0) continue;
            var gs = new StringBuilder();
            gs.Append('[').Append(npc).Append("]={").Append(g.Item2);
            foreach (var kv in items)
            {
                double pct = kv.Value * 100;
                gs.Append(',').Append(kv.Key).Append(',').Append(pct.ToString(pct >= 1 ? "0.#" : "0.###", CultureInfo.InvariantCulture));
                usedItems.Add(kv.Key);
            }
            gs.Append("},");
            gatherLines.Add(gs.ToString());
            kindCounts[g.Item2]++;
            Tuple<string, int, int, int> gm;
            if (!namedMobs.Contains(npc) && mobInfo.TryGetValue(npc, out gm))
            {
                mobLines.Add(string.Format("[{0}]={{{1},{2},{3},{4}}},", npc, LuaStr(gm.Item1), gm.Item2, gm.Item3, gm.Item4));
                namedMobs.Add(npc);
            }
        }

        // Pick pocketing: pick[npc] = { 5, itemID, percent per mob pick pocketed, ... }
        var pickLines = new List<string>();
        var pickCache = new Dictionary<int, List<KeyValuePair<int, double>>>();
        foreach (var npc in openWorld.OrderBy(x => x))
        {
            int pickId;
            if (!pickOf.TryGetValue(npc, out pickId)) continue;
            List<KeyValuePair<int, double>> items;
            if (!pickCache.TryGetValue(pickId, out items))
            {
                List<LootRow> rows; pickLoot.TryGetValue(pickId, out rows);
                items = Expand(rows, 0).Where(kv => itemInfo.ContainsKey(kv.Key))
                    .OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(topN).ToList();
                pickCache[pickId] = items;
            }
            if (items.Count == 0) continue;
            var ps = new StringBuilder();
            ps.Append('[').Append(npc).Append("]={5");
            foreach (var kv in items)
            {
                double pct = kv.Value * 100;
                ps.Append(',').Append(kv.Key).Append(',').Append(pct.ToString(pct >= 1 ? "0.#" : "0.###", CultureInfo.InvariantCulture));
                usedItems.Add(kv.Key);
            }
            ps.Append("},");
            pickLines.Add(ps.ToString());
        }

        // Contents of containers (clams, lockboxes, bags of loot) that mobs drop:
        // chance of each item per container opened.
        var contentLines = new List<string>();
        foreach (var containerId in usedItems.ToList())
        {
            List<LootRow> rows;
            if (!itemLoot.TryGetValue(containerId, out rows)) continue;
            var inside = Expand(rows, 0).Where(kv => itemInfo.ContainsKey(kv.Key))
                .OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).Take(topN).ToList();
            if (inside.Count == 0) continue;
            var cs = new StringBuilder();
            cs.Append('[').Append(containerId).Append("]={");
            for (int i = 0; i < inside.Count; i++)
            {
                if (i > 0) cs.Append(',');
                double pct = inside[i].Value * 100;
                cs.Append(inside[i].Key).Append(',').Append(pct.ToString(pct >= 1 ? "0.#" : "0.###", CultureInfo.InvariantCulture));
                usedItems.Add(inside[i].Key);
            }
            cs.Append("},");
            contentLines.Add(cs.ToString());
        }

        // Count ranges for items that can come more than one at a time.
        var qtyDrop = new List<string>(); var qtyGather = new List<string>();
        var qtyPick = new List<string>(); var qtyContent = new List<string>();
        var countCache = new Dictionary<string, Dictionary<int, Tuple<int, int>>>();
        Func<string, List<LootRow>, Dictionary<int, Tuple<int, int>>> cachedCounts = (key, rows) =>
        {
            Dictionary<int, Tuple<int, int>> c;
            if (!countCache.TryGetValue(key, out c)) countCache[key] = c = Counts(rows, 0);
            return c;
        };
        foreach (var npc in openWorld.OrderBy(x => x))
        {
            int lootId;
            if (lootIdOf.TryGetValue(npc, out lootId) && lootCache.ContainsKey(lootId))
            {
                List<LootRow> rows; creatureLoot.TryGetValue(lootId, out rows);
                var ids = lootCache[lootId].Select(kv => kv.Key).Concat(greyCache[lootId].Select(kv => kv.Key));
                var l = QtyLine(npc, ids, cachedCounts("c" + lootId, rows));
                if (l != null) qtyDrop.Add(l);
            }
            Tuple<int, int> g;
            if (gatherOf.TryGetValue(npc, out g) && gatherCache.ContainsKey(g.Item1))
            {
                List<LootRow> rows; skinLoot.TryGetValue(g.Item1, out rows);
                var l = QtyLine(npc, gatherCache[g.Item1].Select(kv => kv.Key), cachedCounts("s" + g.Item1, rows));
                if (l != null) qtyGather.Add(l);
            }
            int pickId;
            if (pickOf.TryGetValue(npc, out pickId) && pickCache.ContainsKey(pickId))
            {
                List<LootRow> rows; pickLoot.TryGetValue(pickId, out rows);
                var l = QtyLine(npc, pickCache[pickId].Select(kv => kv.Key), cachedCounts("p" + pickId, rows));
                if (l != null) qtyPick.Add(l);
            }
        }
        foreach (var containerId in usedItems)
        {
            List<LootRow> rows;
            if (!itemLoot.TryGetValue(containerId, out rows)) continue;
            var counts = Counts(rows, 0);
            var l = QtyLine(containerId, counts.Keys, counts);
            if (l != null) qtyContent.Add(l);
        }

        // Quest drops, shown only while you need them: questDrops[npc] = { itemID,
        // percent per kill, ... }; questFor[itemID] = { questID, ... }.
        var questDropLines = new List<string>(); var qtyQuest = new List<string>();
        var questItemsUsed = new SortedSet<int>();
        var questDropCache = new Dictionary<int, List<KeyValuePair<int, double>>>();
        foreach (var npc in openWorld.OrderBy(x => x))
        {
            int lootId;
            if (!lootIdOf.TryGetValue(npc, out lootId)) continue;
            List<KeyValuePair<int, double>> qd;
            List<LootRow> rows; creatureLoot.TryGetValue(lootId, out rows);
            if (!questDropCache.TryGetValue(lootId, out qd))
            {
                qd = QuestExpand(rows, 0).Where(kv => itemInfo.ContainsKey(kv.Key) && questsFor.ContainsKey(kv.Key))
                    .OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key).ToList();
                questDropCache[lootId] = qd;
            }
            if (qd.Count == 0) continue;
            var qs = new StringBuilder();
            qs.Append('[').Append(npc).Append("]={");
            for (int i = 0; i < qd.Count; i++)
            {
                if (i > 0) qs.Append(',');
                double pct = qd[i].Value * 100;
                qs.Append(qd[i].Key).Append(',').Append(pct.ToString(pct >= 1 ? "0.#" : "0.###", CultureInfo.InvariantCulture));
                usedItems.Add(qd[i].Key); questItemsUsed.Add(qd[i].Key);
            }
            qs.Append("},");
            questDropLines.Add(qs.ToString());
            var ql = QtyLine(npc, qd.Select(kv => kv.Key), QuestCounts(rows, 0));
            if (ql != null) qtyQuest.Add(ql);
            Tuple<string, int, int, int> qm;
            if (!namedMobs.Contains(npc) && mobInfo.TryGetValue(npc, out qm))
            {
                mobLines.Add(string.Format("[{0}]={{{1},{2},{3},{4}}},", npc, LuaStr(qm.Item1), qm.Item2, qm.Item3, qm.Item4));
                namedMobs.Add(npc);
            }
        }

        // Which items are quest drops, for loot recorded in game: questOnly = items
        // that only ever drop while on a quest; questOk = Quest-class items that
        // drop for everyone (so the game's "quest item" flag mustn't hide them).
        var everyone = new HashSet<int>(); var onQuest = new HashSet<int>();
        foreach (var tbl in new[] { creatureLoot, refLoot, itemLoot, skinLoot, pickLoot })
            foreach (var rows in tbl.Values)
                foreach (var r in rows)
                {
                    if (r.MinOrRef < 0) continue; // reference, not an item
                    if (r.Chance < 0) onQuest.Add(r.Item); else everyone.Add(r.Item);
                }
        var questOnly = onQuest.Where(id => !everyone.Contains(id)).OrderBy(x => x).ToList();
        var questOk = everyone.Where(id => questClass.Contains(id)).OrderBy(x => x).ToList();

        var o = new StringBuilder();
        o.AppendLine("-- Generated by tools/Build-BaseData.ps1 from the CMaNGOS classic-db dump (WoW 1.12 data, GPL-3.0).");
        o.AppendLine("-- These are estimates from the original game, not measured on WoW Forever.");
        o.AppendLine("-- itemID 0 in base = any grey (poor quality) item; baseGrey[npcID] lists those grey items.");
        o.AppendLine("-- contents[containerItemID] = { itemID, percent per container opened, ... }");
        o.AppendLine("-- pick[npcID] = { 5, itemID, percent per mob pick pocketed, ... }");
        o.AppendLine("-- extra[npcID] ={ percent chance of no items [, min copper, max copper] } (gold omitted if none)");
        o.AppendLine("-- gather[npcID] = { kind, itemID, percent per corpse gathered, ... }; kind 1 skinning, 2 herbalism, 3 mining, 4 engineering");
        o.AppendLine("-- base[npcID] = { itemID, percent, ... }   items[itemID] = { name, quality }   mobs[npcID] = { name, minLevel, maxLevel, modelDisplayID }");
        o.AppendLine("local _, ns = ...");
        o.AppendLine("ns.items = ns.items or {}");
        o.AppendLine("local items = ns.items");
        foreach (var id in usedItems)
            o.Append("items[").Append(id).Append("]={").Append(LuaStr(itemInfo[id].Item1)).Append(',').Append(itemInfo[id].Item2).AppendLine("}");
        o.AppendLine("ns.base = {");
        foreach (var l in npcLines) o.AppendLine(l);
        o.AppendLine("}");
        o.AppendLine("ns.baseGrey = {");
        foreach (var l in greyLines) o.AppendLine(l);
        o.AppendLine("}");
        o.AppendLine("ns.pick = {");
        foreach (var l in pickLines) o.AppendLine(l);
        o.AppendLine("}");
        o.AppendLine("ns.extra = {");
        foreach (var l in extraLines) o.AppendLine(l);
        o.AppendLine("}");
        o.AppendLine("ns.gather = {");
        foreach (var l in gatherLines) o.AppendLine(l);
        o.AppendLine("}");
        o.AppendLine("ns.contents = {");
        foreach (var l in contentLines) o.AppendLine(l);
        o.AppendLine("}");
        o.AppendLine("-- qty.<section>[npcID or containerID] = { itemID, min, max, ... } for items that can come more than one at a time");
        o.AppendLine("ns.qty = { drop = {");
        foreach (var l in qtyDrop) o.AppendLine(l);
        o.AppendLine("}, gather = {");
        foreach (var l in qtyGather) o.AppendLine(l);
        o.AppendLine("}, pick = {");
        foreach (var l in qtyPick) o.AppendLine(l);
        o.AppendLine("}, content = {");
        foreach (var l in qtyContent) o.AppendLine(l);
        o.AppendLine("}, quest = {");
        foreach (var l in qtyQuest) o.AppendLine(l);
        o.AppendLine("} }");
        o.AppendLine("-- questDrops[npcID] = { itemID, percent per kill while you need it, ... }; questFor[itemID] = { questID, ... }");
        o.AppendLine("ns.questDrops = {");
        foreach (var l in questDropLines) o.AppendLine(l);
        o.AppendLine("}");
        o.Append("ns.questFor = {");
        foreach (var id in questItemsUsed) o.Append('[').Append(id).Append("]={").Append(string.Join(",", questsFor[id])).Append("},");
        o.AppendLine("}");
        o.AppendLine("ns.mobs = {");
        foreach (var l in mobLines) o.AppendLine(l);
        o.AppendLine("}");
        o.AppendLine("-- questOnly: items that only drop while on a quest. questOk: Quest-class items that drop for everyone.");
        o.Append("ns.questOnly = {");
        foreach (var id in questOnly) o.Append('[').Append(id).Append("]=true,");
        o.AppendLine("}");
        o.Append("ns.questOk = {");
        foreach (var id in questOk) o.Append('[').Append(id).Append("]=true,");
        o.AppendLine("}");
        File.WriteAllText(outPath, o.ToString(), new UTF8Encoding(false));
        return string.Format("{0} open-world NPCs with loot, gathering on {3} (skin {4}, herb {5}, mine {6}, engineer {7}), pick pocket on {8}, {9} containers, {1} items, {2:N0} bytes",
            npcLines.Count, usedItems.Count, o.Length, gatherLines.Count, kindCounts[1], kindCounts[2], kindCounts[3], kindCounts[4],
            pickLines.Count, contentLines.Count);
    }
}
'@

$Dump = (Resolve-Path $Dump).Path
$Out = [IO.Path]::GetFullPath($Out)
[LootBuilder]::Build($Dump, $Out, $TopN)
"Wrote $Out"
