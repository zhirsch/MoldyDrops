<#
.SYNOPSIS
  Builds MoldyDrops\BaseData.lua from the CMaNGOS classic-db full dump.

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
  [string] $Out = (Join-Path $PSScriptRoot '..\MoldyDrops\BaseData.lua'),
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

    static Dictionary<int, double> Expand(List<LootRow> rows, int depth)
    {
        var result = new Dictionary<int, double>();
        if (rows == null || depth > 8) return result;

        foreach (var grp in rows.GroupBy(r => r.Group))
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

    static string LuaStr(string s)
    {
        return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n") + "\"";
    }

    public static string Build(string dumpPath, string outPath, int topN)
    {
        var lootIdOf = new Dictionary<int, int>();
        var openWorld = new HashSet<int>();
        var itemInfo = new Dictionary<int, Tuple<string, int>>();
        var mobInfo = new Dictionary<int, Tuple<string, int, int>>();
        var gatherOf = new Dictionary<int, Tuple<int, int>>(); // npc -> (skinning loot id, gather kind)

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
                            int skin = I(f[58]);
                            if (skin > 0) gatherOf[I(f[0])] = Tuple.Create(skin, GatherKind(I(f[20])));
                            mobInfo[I(f[0])] = Tuple.Create(f[1] ?? "", I(f[3]), I(f[4]));
                        }
                        break;
                    case "item_template":
                        foreach (var f in Tuples(line)) itemInfo[I(f[0])] = Tuple.Create(f[3] ?? "", I(f[5]));
                        break;
                    case "creature_loot_template":
                    case "reference_loot_template":
                    case "item_loot_template":
                    case "skinning_loot_template":
                        var target = table == "creature_loot_template" ? creatureLoot
                            : table == "item_loot_template" ? itemLoot
                            : table == "skinning_loot_template" ? skinLoot : refLoot;
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
            Tuple<string, int, int> mi;
            if (mobInfo.TryGetValue(npc, out mi))
            {
                mobLines.Add(string.Format("[{0}]={{{1},{2},{3}}},", npc, LuaStr(mi.Item1), mi.Item2, mi.Item3));
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
            Tuple<string, int, int> gm;
            if (!namedMobs.Contains(npc) && mobInfo.TryGetValue(npc, out gm))
            {
                mobLines.Add(string.Format("[{0}]={{{1},{2},{3}}},", npc, LuaStr(gm.Item1), gm.Item2, gm.Item3));
                namedMobs.Add(npc);
            }
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

        var o = new StringBuilder();
        o.AppendLine("-- Generated by tools/Build-BaseData.ps1 from the CMaNGOS classic-db dump (WoW 1.12 data, GPL-3.0).");
        o.AppendLine("-- These are estimates from the original game, not measured on WoW Forever.");
        o.AppendLine("-- itemID 0 in base = any grey (poor quality) item; baseGrey[npcID] lists those grey items.");
        o.AppendLine("-- contents[containerItemID] = { itemID, percent per container opened, ... }");
        o.AppendLine("-- gather[npcID] = { kind, itemID, percent per corpse gathered, ... }; kind 1 skinning, 2 herbalism, 3 mining, 4 engineering");
        o.AppendLine("-- base[npcID] = { itemID, percent, ... }   items[itemID] = { name, quality }   mobs[npcID] = { name, minLevel, maxLevel }");
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
        o.AppendLine("ns.gather = {");
        foreach (var l in gatherLines) o.AppendLine(l);
        o.AppendLine("}");
        o.AppendLine("ns.contents = {");
        foreach (var l in contentLines) o.AppendLine(l);
        o.AppendLine("}");
        o.AppendLine("ns.mobs = {");
        foreach (var l in mobLines) o.AppendLine(l);
        o.AppendLine("}");
        File.WriteAllText(outPath, o.ToString(), new UTF8Encoding(false));
        return string.Format("{0} open-world NPCs with loot, gathering on {3} (skin {4}, herb {5}, mine {6}, engineer {7}), {1} items, {2:N0} bytes",
            npcLines.Count, usedItems.Count, o.Length, gatherLines.Count, kindCounts[1], kindCounts[2], kindCounts[3], kindCounts[4]);
    }
}
'@

$Dump = (Resolve-Path $Dump).Path
$Out = [IO.Path]::GetFullPath($Out)
[LootBuilder]::Build($Dump, $Out, $TopN)
"Wrote $Out"
