using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>
    /// 脚本化规划器（--simulate 与自动对局用）。
    ///
    /// 它不是"聪明 AI"，只是一套**可复现的决策顺序**，用来证明规划规则能跑通：
    ///   兵营 → 加快训练 → 征召 → 经济/光环 → 3 合 1 → 哨塔。
    /// 所有选择只依赖当前 BoardSession 状态与牌面，不读引擎时间/帧率。
    ///
    /// 2026-11-24 起只规划**一场**（单轮死斗），不再区分进攻/防守角色。
    /// </summary>
    public static class ScriptedPlanner
    {
        private sealed class Candidate
        {
            public double Score;
            public string Key = "";
            public Func<bool> Run;
        }

        public static void Plan(BoardSession board)
        {
            if (board == null) return;
            var blocked = new HashSet<string>(StringComparer.Ordinal);
            for (int guard = 0; guard < 64; guard++)
            {
                var list = BuildCandidates(board, blocked);
                if (list.Count == 0) return;
                list.Sort((a, b) =>
                {
                    int c = b.Score.CompareTo(a.Score);
                    if (c != 0) return c;
                    return string.CompareOrdinal(a.Key, b.Key);
                });

                bool acted = false;
                foreach (Candidate cand in list)
                {
                    if (cand.Run())
                    {
                        acted = true;
                        break;
                    }
                    blocked.Add(cand.Key);
                }
                if (!acted) return;
            }
        }

        private static List<Candidate> BuildCandidates(BoardSession board, HashSet<string> blocked)
        {
            var list = new List<Candidate>();
            PlanningMatch m = board.Match;
            PlanningConfig cfg = board.Cfg;

            int producers = m.CountKind(BuildingKinds.Producer);
            int rangedProducers = CountProducersOfTag(m, "ranged");
            int economy = m.CountKind(BuildingKinds.Economy);
            int supports = m.CountKind(BuildingKinds.Support);
            int defenses = m.CountKind(BuildingKinds.Defense);

            // ---- 3 合 1：同名建筑 ≥3 且人口吃紧时，把产线升星（少占格、保人口） ----
            if (m.PopFree() < 6)
            {
                var groups = new Dictionary<string, List<BoardBuilding>>(StringComparer.Ordinal);
                foreach (BoardBuilding b in board.Buildings)
                {
                    if (string.Equals(b.DefId, "keep", StringComparison.Ordinal)) continue;
                    if (!groups.TryGetValue(b.DefId, out List<BoardBuilding> g))
                    {
                        g = new List<BoardBuilding>();
                        groups[b.DefId] = g;
                    }
                    g.Add(b);
                }
                foreach (var kv in groups)
                {
                    if (kv.Value.Count < 3) continue;
                    kv.Value.Sort((a, b) => board.Arena.OrderOf(a.Tile).CompareTo(board.Arena.OrderOf(b.Tile)));
                    int target = kv.Value[0].Tile;
                    int source = kv.Value[1].Tile;
                    int second = kv.Value[2].Tile;
                    string key = $"merge:{target}+{source}+{second}";
                    if (blocked.Contains(key)) continue;
                    list.Add(new Candidate
                    {
                        Score = 86,
                        Key = key,
                        Run = () => board.Merge(target, source) > 0 && board.Merge(target, second) > 0,
                    });
                }
            }

            foreach (string id in new List<string>(m.Hand))
            {
                if (!cfg.Cards.TryGetValue(id, out CardDef card)) continue;
                if (blocked.Contains("card:" + id)) continue;

                switch (card.Kind)
                {
                    case CardKind.Build:
                    {
                        if (m.Cp < card.CostCp) break;
                        double score = 10;
                        if (card.Building == "barracks")
                            score = producers < 1 ? 120 : (producers < 2 ? 108 : (m.Cp >= card.CostCp + 4 ? 58 : 18));
                        else if (card.Building == "archery_range")
                            score = rangedProducers < 1 && HasTrainCard(m, "ranged") ? 112 : (m.Cp >= card.CostCp + 4 ? 44 : 12);
                        else if (card.Building == "lumbermill")
                            score = economy < 1 ? 74 : (m.Cp >= card.CostCp + 6 ? 52 : 16);
                        else if (card.Building == "blacksmith")
                            score = supports < 1 && producers > 0 ? 70 : (m.Cp >= card.CostCp + 6 ? 40 : 8);
                        else if (card.Building == "watchtower")
                            score = defenses < 2 && m.Cp >= card.CostCp + 5 ? 48 : 12;
                        else if (card.Building == "farm")
                            score = m.PopFree() < 8 ? 95 : 20;

                        string cid = id;
                        list.Add(new Candidate
                        {
                            Score = score,
                            Key = "card:" + id,
                            Run = () => board.PlaceBuild(cid) > 0,
                        });
                        break;
                    }

                    case CardKind.Train:
                    {
                        if (!m.CanPlayTrain(id)) break;
                        UnitDef unit = m.Units.Get(card.Unit);
                        if (unit == null) break;
                        int owned = 0;
                        foreach (PlannedSquad s in m.Army)
                        {
                            if (s.UnitId == unit.Id) owned += Math.Max(s.Units, 1);
                        }
                        double score;
                        if (unit.Id == "alliance_footman") score = owned == 0 ? 96 : 90;
                        else if (unit.Id == "alliance_archer") score = 82;
                        else if (unit.Id == "alliance_pikeman") score = 80;
                        else score = 76;
                        if (owned >= 18) score -= 14;
                        string cid = id;
                        list.Add(new Candidate
                        {
                            Score = score,
                            Key = "card:" + id,
                            Run = () => board.PlayTrain(cid) > 0,
                        });
                        break;
                    }

                    case CardKind.Strategy:
                    {
                        if (!m.CanPlayStrategy(id)) break;
                        double score;
                        if (card.Effect == "train_boost")
                            score = HasTrainCard(m, null) ? 130 : 0;
                        else
                            score = m.Army.Count > 0 ? 62 : 0;
                        string cid = id;
                        list.Add(new Candidate
                        {
                            Score = score,
                            Key = "card:" + id,
                            Run = () => board.PlayStrategy(cid),
                        });
                        break;
                    }
                }
            }
            return list;
        }

        private static bool HasTrainCard(PlanningMatch m, string buildingTag)
        {
            foreach (string hid in m.Hand)
            {
                if (!m.Cfg.Cards.TryGetValue(hid, out CardDef hc)) continue;
                if (hc.Kind != CardKind.Train) continue;
                if (string.IsNullOrEmpty(buildingTag) || hc.BuildingTag == buildingTag) return true;
            }
            return false;
        }

        private static int CountProducersOfTag(PlanningMatch m, string tag)
        {
            int n = 0;
            foreach (PlanBuilding b in m.Buildings)
            {
                BuildingDef def = m.DefOf(b);
                if (def != null && def.Kind == BuildingKinds.Producer && def.Tag == tag) n++;
            }
            return n;
        }
    }
}
