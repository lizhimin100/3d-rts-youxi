using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>
    /// 脚本化规划器（--simulate 与自动对局用）。
    ///
    /// 它不是“聪明 AI”，只是一套**可复现的决策顺序**，用来证明规划规则能跑通：
    ///   兵营 → 训练 → 人口不够补农场 → 防守补哨塔 → 策略 → 3 合 1。
    /// 所有选择只依赖当前 PlanningMatch 状态与牌面，不读引擎时间/帧率。
    /// </summary>
    public static class ScriptedPlanner
    {
        private sealed class Candidate
        {
            public double Score;
            public string Key = "";
            public Func<bool> Run;
        }

        public static void Plan(PlanningMatch m, bool defending)
        {
            Plan(m, defending, defending ? SquadRoles.Defend : SquadRoles.Attack);
        }

        /// <summary>
        /// 带时空角色的规划：本轮只需要"这一场"的兵。
        /// 角色不符的训练牌会被打 0 分（仍然可打，只是排在最后），
        /// 这样 CP 会优先落在本轮的队伍上，不会一半钱买了另一场。
        /// </summary>
        public static void Plan(PlanningMatch m, bool defending, string role)
        {
            var blocked = new HashSet<string>(StringComparer.Ordinal);
            for (int guard = 0; guard < 48; guard++)
            {
                var list = BuildCandidates(m, defending, role, blocked);
                if (list.Count == 0) return;
                list.Sort((a, b) =>
                {
                    int c = b.Score.CompareTo(a.Score);
                    if (c != 0) return c;
                    return string.CompareOrdinal(a.Key, b.Key);
                });

                bool acted = false;
                foreach (var cand in list)
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

        private static List<Candidate> BuildCandidates(PlanningMatch m, bool defending, string role, HashSet<string> blocked)
        {
            var list = new List<Candidate>();
            var cfg = m.Cfg;

            // ---- 3 合 1（只在人口被卡死、额外产线用不上时做） ----
            if (m.CountTag("barracks") >= 3 && m.PopFree() < 6)
            {
                var barracks = BuildingsOfTag(m, "barracks");
                for (int i = 0; i < barracks.Count; i++)
                {
                    for (int j = i + 1; j < barracks.Count; j++)
                    {
                        int a = barracks[i].Plot;
                        int b = barracks[j].Plot;
                        if (!m.CanMerge(a, b)) continue;
                        string key = $"merge:{a}+{b}";
                        if (blocked.Contains(key)) continue;
                        int ta = a, tb = b;
                        list.Add(new Candidate
                        {
                            Score = 86,
                            Key = key,
                            Run = () => m.Merge(ta, tb),
                        });
                    }
                }
            }

            foreach (var id in new List<string>(m.Hand))
            {
                if (!cfg.Cards.TryGetValue(id, out CardDef card)) continue;
                if (blocked.Contains("card:" + id)) continue;

                switch (card.Kind)
                {
                    case CardKind.Build:
                    {
                        if (!m.CanPlayBuild(id)) break;
                        double score = 10;
                        if (card.Building == "barracks")
                        {
                            int n = m.CountTag("barracks");
                            score = n < 2 ? 110 : (n < 3 && m.Cp >= card.CostCp + 4 ? 72 : 20);
                        }
                        else if (card.Building == "farm")
                        {
                            score = m.PopFree() < 8 ? 95 : (m.Cp >= card.CostCp + 4 ? 45 : 10);
                        }
                        else if (card.Building == "watchtower")
                        {
                            int n = m.CountTag("tower");
                            score = defending ? (n < 2 ? 78 : 30) : 22;
                        }
                        string cid = id;
                        list.Add(new Candidate
                        {
                            Score = score,
                            Key = "card:" + id,
                            Run = () => m.PlayBuild(cid),
                        });
                        break;
                    }

                    case CardKind.Train:
                    {
                        if (!m.CanPlayTrain(id)) break;
                        // 时空角色硬过滤：单场推演里"另一场"的兵是纯负担（既占人口又不参战）。
                        // 演练双场时（SquadSession 一次规划供两场）不传 role，这里就不生效。
                        if (!string.IsNullOrEmpty(role) && !string.IsNullOrEmpty(card.Role) && card.Role != role)
                            break;
                        var unit = m.Units.Get(card.Unit);
                        if (unit == null) break;
                        int owned = 0;
                        foreach (var s in m.Army)
                        {
                            if (s.UnitId == unit.Id) owned++;
                        }
                        double score;
                        if (unit.Id == "alliance_footman") score = owned == 0 ? 92 : 84;
                        else if (unit.Id == "alliance_pikeman") score = 82;
                        else if (unit.Id == "alliance_archer") score = 80;
                        else score = 76;
                        if (unit.IsMelee && defending) score += 2;
                        if (owned >= 2) score -= 12; // 别把鸡蛋全放一个兵种
                        string cid = id;
                        list.Add(new Candidate
                        {
                            Score = score,
                            Key = "card:" + id,
                            Run = () => m.PlayTrain(cid) > 0,
                        });
                        break;
                    }

                    case CardKind.Strategy:
                    {
                        if (!m.CanPlayStrategy(id)) break;
                        // 「加快训练」是**前置**牌：它只放大"之后打出的征召牌"，
                        // 所以必须在任何训练牌之前出手 —— 给它最高分，
                        // 否则脚本化规划器会先把手牌征召完、最后才打加速（等于白打）。
                        double score;
                        if (card.Effect == "train_boost")
                        {
                            bool haveTrain = false;
                            foreach (var hid in m.Hand)
                            {
                                if (m.Cfg.Cards.TryGetValue(hid, out CardDef hc) && hc.Kind == CardKind.Train)
                                {
                                    haveTrain = true;
                                    break;
                                }
                            }
                            score = haveTrain ? 130 : 0;
                        }
                        else if (card.Effect == "focus") score = m.Army.Count > 0 ? 64 : 0;
                        else score = m.Army.Count > 0 ? 62 : 0;
                        string cid = id;
                        list.Add(new Candidate
                        {
                            Score = score,
                            Key = "card:" + id,
                            Run = () => m.PlayStrategy(cid),
                        });
                        break;
                    }
                }
            }
            return list;
        }

        private static List<PlanBuilding> BuildingsOfTag(PlanningMatch m, string tag)
        {
            var list = new List<PlanBuilding>();
            foreach (var b in m.Buildings)
            {
                var def = m.DefOf(b);
                if (def != null && def.Tag == tag) list.Add(b);
            }
            list.Sort((a, b) => a.Plot.CompareTo(b.Plot));
            return list;
        }
    }
}
