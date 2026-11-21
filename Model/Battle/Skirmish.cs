using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    // =====================================================================
    // 推演数据（纯 C#，不依赖任何引擎类型）
    // =====================================================================
    public sealed class UnitStats
    {
        public double MaxHp;
        public double AttackDamage;
        public double AttackSpread;
        public double AttackCooldown;
        public double AttackRange;
        public int AttackType;
        public double Armor;
        public int ArmorType;
        public double MoveSpeed;
        public int GoldCost;
        public int WoodCost;
        public int FoodCost;
        public double TrainTime;
        public int PopCost;
    }

    public sealed class RosterEntry
    {
        public string Id = "";
        public double Weight = 1.0;
        public UnitStats Stats = new UnitStats();
    }

    public sealed class SimSideConfig
    {
        public string Name = "side";
        public double BaseX;
        public int Workers;
        public int StartGold;
        public int StartWood;
        public int FoodCap;
        public int ArmyTarget = 12;
        public List<RosterEntry> Roster = new List<RosterEntry>();
    }

    public sealed class SimSideResult
    {
        public string Name = "";
        public int Alive;
        public Dictionary<string, int> AliveByType = new Dictionary<string, int>();
        public double HpLeft;
        public int Kills;
        public int Losses;
        public int UnitsBuilt;
        public Dictionary<string, int> BuiltByType = new Dictionary<string, int>();
        public int GoldMined;
        public int GoldLeft;
        public double DamageDealt;
    }

    public sealed class SimSample
    {
        public double T;
        public int[] Units = new int[2];
        public int[] Gold = new int[2];
        public double[] Hp = new double[2];
    }

    public sealed class SimResult
    {
        public bool Ok;
        public List<string> Errors = new List<string>();
        public int Seed = 1;
        public double Seconds;
        public string Winner = "";
        public List<SimSideResult> Sides = new List<SimSideResult>();
        public List<SimSample> Timeline = new List<SimSample>();
    }

    /// <summary>
    /// 确定性小规模推演（run-game --simulate 的引擎）。
    ///
    /// 只说清"数值规则放在一起跑会怎样"：没有地形/寻路/建筑/技能。
    /// 同 seed + 同配置 → 逐字节相同的结果（所以随机数只走 <see cref="Rng"/>）。
    ///
    /// 输入用 <c>IDictionary&lt;string, object&gt;</c>（调用方把 JSON/引擎字典转成纯 .NET 字典），
    /// 这样校验、缺字段、类型错误都留在 Model 里，宿主不做判断。
    /// </summary>
    public static class Skirmish
    {
        private const double Eps = 0.000001;

        private static readonly string[] RequiredStats =
        {
            "max_hp", "attack_damage", "attack_spread", "attack_cooldown", "attack_range",
            "attack_type", "armor", "armor_type", "move_speed", "gold_cost", "wood_cost",
            "food_cost", "train_time",
        };

        // =================================================================
        // 校验
        // =================================================================
        public static List<string> Validate(IDictionary<string, object> config)
        {
            var errors = new List<string>();
            if (config == null)
            {
                errors.Add("配置为空");
                return errors;
            }
            var sides = GetList(config, "sides");
            if (sides == null || sides.Count != 2)
            {
                errors.Add("sides 必须是恰好 2 个阵营");
                return errors;
            }
            for (int si = 0; si < sides.Count; si++)
            {
                var side = sides[si] as IDictionary<string, object>;
                if (side == null)
                {
                    errors.Add($"sides[{si}] 不是对象");
                    continue;
                }
                var roster = GetList(side, "roster");
                if (roster == null || roster.Count == 0)
                {
                    errors.Add($"sides[{si}].roster 不能为空");
                    continue;
                }
                for (int ri = 0; ri < roster.Count; ri++)
                {
                    var entry = roster[ri] as IDictionary<string, object>;
                    if (entry == null)
                    {
                        errors.Add($"sides[{si}].roster[{ri}] 不是对象");
                        continue;
                    }
                    var stats = GetDict(entry, "stats");
                    if (stats == null)
                    {
                        errors.Add($"sides[{si}].roster[{ri}].stats 不是对象");
                        continue;
                    }
                    foreach (var key in RequiredStats)
                    {
                        if (!stats.ContainsKey(key))
                            errors.Add($"sides[{si}].roster[{ri}].stats 缺 {key}");
                    }
                }
            }
            if (GetDict(config, "rules") == null || GetDict(config, "economy") == null)
                errors.Add("rules / economy 必须是对象");
            return errors;
        }

        // =================================================================
        // 推演
        // =================================================================
        public static SimResult Run(IDictionary<string, object> config)
        {
            var errors = Validate(config);
            if (errors.Count > 0)
            {
                return new SimResult { Ok = false, Errors = errors };
            }

            int seed = GetInt(config, "seed", 1);
            double dt = Math.Max(GetDouble(config, "dt", 0.1), 0.001);
            double maxSeconds = Math.Max(GetDouble(config, "max_seconds", 300.0), dt);
            double sampleSeconds = Math.Max(GetDouble(config, "sample_seconds", 10.0), dt);

            var rules = ParseRules(GetDict(config, "rules"));
            var economy = GetDict(config, "economy");
            int carry = Math.Max(GetInt(economy, "harvest_carry_gold", 20), 1);
            double trip = Math.Max(GetDouble(economy, "trip_seconds", 14.0), 0.1);

            var sides = new List<Side>();
            var sideList = GetList(config, "sides");
            for (int i = 0; i < sideList.Count; i++)
            {
                sides.Add(Side.FromConfig(sideList[i] as IDictionary<string, object>, seed, i));
            }

            var timeline = new List<SimSample>();
            double t = 0.0;
            int tick = 0;
            double nextSample = 0.0;

            while (t < maxSeconds - Eps)
            {
                t += dt;
                tick += 1;
                for (int i = 0; i < sides.Count; i++) TickEconomy(sides[i], carry, trip, dt);
                for (int i = 0; i < sides.Count; i++) TickProduction(sides[i], dt);
                TickCombat(sides, rules, dt, tick);
                if (t + Eps >= nextSample)
                {
                    nextSample += sampleSeconds;
                    timeline.Add(new SimSample
                    {
                        T = Round1(t),
                        Units = new[] { sides[0].Units.Count, sides[1].Units.Count },
                        Gold = new[] { sides[0].Gold, sides[1].Gold },
                        Hp = new[] { Round1(TotalHp(sides[0])), Round1(TotalHp(sides[1])) },
                    });
                }
            }

            var result = new SimResult
            {
                Ok = true,
                Seed = seed,
                Seconds = Round1(t),
                Winner = WinnerOf(sides),
                Timeline = timeline,
            };

            foreach (var side in sides)
            {
                var byType = new Dictionary<string, int>();
                foreach (var u in side.Units)
                {
                    byType.TryGetValue(u.Id, out int n);
                    byType[u.Id] = n + 1;
                }
                result.Sides.Add(new SimSideResult
                {
                    Name = side.Name,
                    Alive = side.Units.Count,
                    AliveByType = byType,
                    HpLeft = Round1(TotalHp(side)),
                    Kills = side.Kills,
                    Losses = side.Losses,
                    UnitsBuilt = side.UnitsBuilt,
                    BuiltByType = new Dictionary<string, int>(side.BuiltByType),
                    GoldMined = side.GoldMined,
                    GoldLeft = side.Gold,
                    DamageDealt = Round1(side.DamageDealt),
                });
            }
            return result;
        }

        // =================================================================
        // 内部模型
        // =================================================================
        private sealed class SimUnit
        {
            public string Id = "";
            public double Hp;
            public double MaxHp;
            public double X;
            public double Cd;
            public UnitStats Stats;
        }

        private sealed class Side
        {
            public string Name = "side";
            public double BaseX;
            public int Workers;
            public int Gold;
            public int Wood;
            public int FoodCap;
            public int ArmyTarget = 12;
            public List<RosterEntry> Roster = new List<RosterEntry>();
            public List<SimUnit> Units = new List<SimUnit>();
            public List<QueueItem> Queue = new List<QueueItem>();
            public int Kills;
            public int Losses;
            public int UnitsBuilt;
            public Dictionary<string, int> BuiltByType = new Dictionary<string, int>();
            public int GoldMined;
            public double DamageDealt;
            public double GoldFrac;
            public Rng ProdRng;
            public Rng CombatRng;

            public static Side FromConfig(IDictionary<string, object> raw, int seed, int index)
            {
                var s = new Side
                {
                    Name = GetString(raw, "name", "side"),
                    BaseX = GetDouble(raw, "base_x", 0.0),
                    Workers = Math.Max(GetInt(raw, "workers", 0), 0),
                    Gold = Math.Max(GetInt(raw, "start_gold", 0), 0),
                    Wood = Math.Max(GetInt(raw, "start_wood", 0), 0),
                    FoodCap = Math.Max(GetInt(raw, "food_cap", 0), 0),
                    ArmyTarget = Math.Max(GetInt(raw, "army_target", 12), 1),
                    ProdRng = new Rng(seed),
                    CombatRng = new Rng(seed + 104729 * (index + 1)),
                };
                var roster = GetList(raw, "roster");
                if (roster != null)
                {
                    foreach (var item in roster)
                    {
                        var entry = item as IDictionary<string, object>;
                        if (entry == null) continue;
                        s.Roster.Add(new RosterEntry
                        {
                            Id = GetString(entry, "id", ""),
                            Weight = GetDouble(entry, "weight", 1.0),
                            Stats = ParseStats(GetDict(entry, "stats")),
                        });
                    }
                }
                return s;
            }
        }

        private sealed class QueueItem
        {
            public string Id = "";
            public double Left;
            public int Food;
        }

        private static void TickEconomy(Side side, int carry, double trip, double dt)
        {
            // 抽象补给率（不是游戏内采集；推演只关心"钱进得多快"）
            double rate = Economy.IncomePerSecond(side.Workers, carry, trip);
            double gain = rate * dt;
            int whole = (int)Math.Floor(gain);
            if (whole <= 0)
            {
                side.GoldFrac += gain;
                whole = (int)Math.Floor(side.GoldFrac);
                if (whole > 0) side.GoldFrac -= whole;
            }
            if (whole > 0)
            {
                side.Gold += whole;
                side.GoldMined += whole;
            }
        }

        private static void TickProduction(Side side, double dt)
        {
            // 进队列：队列空 → 选一个买得起、人口够的兵
            if (side.Queue.Count == 0 && side.Units.Count < side.ArmyTarget && side.Roster.Count > 0)
            {
                var weights = new double[side.Roster.Count];
                for (int i = 0; i < side.Roster.Count; i++) weights[i] = side.Roster[i].Weight;
                int start = side.ProdRng.WeightedIndex(weights);
                for (int k = 0; k < side.Roster.Count; k++)
                {
                    var entry = side.Roster[(start + k) % side.Roster.Count];
                    var st = entry.Stats;
                    int used = FoodUsed(side);
                    if (!Economy.HasFood(used, TotalFood(side.Queue), st.FoodCost, side.FoodCap)) continue;
                    int gold = side.Gold;
                    int wood = side.Wood;
                    if (!Economy.Pay(ref gold, ref wood, st.GoldCost, st.WoodCost)) continue;
                    side.Gold = gold;
                    side.Wood = wood;
                    side.Queue.Add(new QueueItem { Id = entry.Id, Left = st.TrainTime, Food = st.FoodCost });
                    break;
                }
            }

            // 推进队列
            var done = new List<QueueItem>();
            foreach (var item in side.Queue)
            {
                item.Left -= dt;
                if (item.Left <= 0.0) done.Add(item);
            }
            foreach (var item in done) side.Queue.Remove(item);
            foreach (var item in done)
            {
                var entry = RosterEntryOf(side, item.Id);
                if (entry == null) continue;
                side.Units.Add(new SimUnit
                {
                    Id = entry.Id,
                    Hp = entry.Stats.MaxHp,
                    MaxHp = entry.Stats.MaxHp,
                    X = side.BaseX,
                    Cd = 0.0,
                    Stats = entry.Stats,
                });
                side.UnitsBuilt += 1;
                side.BuiltByType.TryGetValue(item.Id, out int n);
                side.BuiltByType[item.Id] = n + 1;
            }
        }

        private static void TickCombat(List<Side> sides, DamageRules rules, double dt, int tick)
        {
            // 先手每 tick 交替，避免"编号小的阵营永远先打"这种假优势
            for (int k = 0; k < sides.Count; k++)
            {
                int si = (tick + k) % sides.Count;
                var me = sides[si];
                var foe = sides[(si + 1) % sides.Count];
                foreach (var u in me.Units)
                {
                    u.Cd = Math.Max(u.Cd - dt, 0.0);
                    var target = NearestEnemy(u, foe);
                    if (target == null)
                    {
                        u.X = MoveToward(u, foe.BaseX, dt);
                        continue;
                    }
                    double reach = Math.Max(u.Stats.AttackRange, 0.1);
                    double dist = Math.Abs(u.X - target.X);
                    if (dist > reach)
                    {
                        u.X = MoveToward(u, target.X, dt);
                    }
                    else if (u.Cd <= Eps)
                    {
                        var outRes = Damage.Compute(
                            u.Stats.AttackDamage, u.Stats.AttackSpread, u.Stats.AttackType,
                            target.Stats.Armor, target.Stats.ArmorType, rules,
                            me.CombatRng.NextFloat(), me.CombatRng.NextFloat(), 1.0);
                        double dmg = outRes.Damage;
                        target.Hp -= dmg;
                        me.DamageDealt += dmg;
                        u.Cd = Math.Max(u.Stats.AttackCooldown, 0.05);
                    }
                }
                // 清理阵亡
                var alive = new List<SimUnit>(me.Units.Count);
                foreach (var u in me.Units)
                {
                    if (u.Hp > 0.0) alive.Add(u);
                    else
                    {
                        me.Losses += 1;
                        foe.Kills += 1;
                    }
                }
                me.Units = alive;
            }
        }

        private static SimUnit NearestEnemy(SimUnit u, Side foe)
        {
            SimUnit best = null;
            double bestD = double.MaxValue;
            foreach (var e in foe.Units)
            {
                double d = Math.Abs(u.X - e.X);
                if (d < bestD)
                {
                    bestD = d;
                    best = e;
                }
            }
            return best;
        }

        private static double MoveToward(SimUnit u, double goalX, double dt)
        {
            double speed = Math.Max(u.Stats.MoveSpeed, 0.5);
            double x = u.X;
            double step = speed * dt;
            if (Math.Abs(goalX - x) <= step) return goalX;
            return x + Math.Sign(goalX - x) * step;
        }

        private static double TotalHp(Side side)
        {
            double total = 0.0;
            foreach (var u in side.Units) total += Math.Max(u.Hp, 0.0);
            return total;
        }

        private static string WinnerOf(List<Side> sides)
        {
            var a = sides[0];
            var b = sides[1];
            double aScore = a.Kills * 3.0 + a.Units.Count * 2.0 + TotalHp(a) * 0.01;
            double bScore = b.Kills * 3.0 + b.Units.Count * 2.0 + TotalHp(b) * 0.01;
            if (Math.Abs(aScore - bScore) <= 0.0001) return "draw";
            return aScore > bScore ? a.Name : b.Name;
        }

        private static int FoodUsed(Side side)
        {
            int used = 0;
            foreach (var u in side.Units) used += u.Stats.FoodCost;
            return used;
        }

        private static int TotalFood(List<QueueItem> queue)
        {
            int n = 0;
            foreach (var q in queue) n += q.Food;
            return n;
        }

        private static RosterEntry RosterEntryOf(Side side, string id)
        {
            foreach (var e in side.Roster)
            {
                if (e.Id == id) return e;
            }
            return null;
        }

        // =================================================================
        // 字典读写（只认纯 .NET 类型；缺字段给安全默认）
        // =================================================================
        private static UnitStats ParseStats(IDictionary<string, object> d)
        {
            if (d == null) return new UnitStats();
            return new UnitStats
            {
                MaxHp = GetDouble(d, "max_hp", 0.0),
                AttackDamage = GetDouble(d, "attack_damage", 0.0),
                AttackSpread = GetDouble(d, "attack_spread", 0.0),
                AttackCooldown = GetDouble(d, "attack_cooldown", 1.0),
                AttackRange = GetDouble(d, "attack_range", 0.0),
                AttackType = GetInt(d, "attack_type", 0),
                Armor = GetDouble(d, "armor", 0.0),
                ArmorType = GetInt(d, "armor_type", 0),
                MoveSpeed = GetDouble(d, "move_speed", 1.0),
                GoldCost = GetInt(d, "gold_cost", 0),
                WoodCost = GetInt(d, "wood_cost", 0),
                FoodCost = GetInt(d, "food_cost", 0),
                TrainTime = GetDouble(d, "train_time", 1.0),
                PopCost = GetInt(d, "pop_cost", GetInt(d, "food_cost", 0)),
            };
        }

        private static DamageRules ParseRules(IDictionary<string, object> d)
        {
            var rules = new DamageRules();
            if (d == null) return rules;
            var table = GetList(d, "damage_table");
            if (table != null)
            {
                rules.DamageTable = new double[table.Count];
                for (int i = 0; i < table.Count; i++) rules.DamageTable[i] = ToDouble(table[i]);
            }
            rules.Stride = GetInt(d, "stride", 5);
            rules.ArmorReduction = GetDouble(d, "armor_reduction", 0.0);
            rules.ArmorReductionCap = GetDouble(d, "armor_reduction_cap", 0.0);
            rules.CritChance = GetDouble(d, "crit_chance", 0.0);
            rules.CritMultiplier = GetDouble(d, "crit_multiplier", 1.0);
            return rules;
        }

        private static double Round1(double v) => Math.Round(v * 10.0) / 10.0;

        private static IDictionary<string, object> GetDict(IDictionary<string, object> d, string key)
        {
            if (d == null || !d.TryGetValue(key, out object v)) return null;
            return v as IDictionary<string, object>;
        }

        private static List<object> GetList(IDictionary<string, object> d, string key)
        {
            if (d == null || !d.TryGetValue(key, out object v)) return null;
            if (v is List<object> list) return list;
            if (v is System.Collections.IEnumerable e && !(v is string))
            {
                var outList = new List<object>();
                foreach (var item in e) outList.Add(item);
                return outList;
            }
            return null;
        }

        private static string GetString(IDictionary<string, object> d, string key, string fallback)
        {
            if (d != null && d.TryGetValue(key, out object v) && v != null) return v.ToString();
            return fallback;
        }

        private static int GetInt(IDictionary<string, object> d, string key, int fallback)
        {
            if (d == null || !d.TryGetValue(key, out object v) || v == null) return fallback;
            try { return Convert.ToInt32(v); }
            catch { return fallback; }
        }

        private static double GetDouble(IDictionary<string, object> d, string key, double fallback)
        {
            if (d == null || !d.TryGetValue(key, out object v) || v == null) return fallback;
            return ToDouble(v, fallback);
        }

        private static double ToDouble(object v, double fallback = 0.0)
        {
            if (v == null) return fallback;
            try { return Convert.ToDouble(v); }
            catch { return fallback; }
        }
    }
}
