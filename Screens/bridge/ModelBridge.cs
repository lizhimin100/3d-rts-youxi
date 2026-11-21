using Godot;
using System;
using System.Collections.Generic;
using WarIsland.Model;

namespace WarIsland.Bridge
{
    /// <summary>
    /// Model ⇄ GDScript 的**唯一桥**（由 Game/adapters/桥.gd 懒建，不用自动加载）。
    ///
    /// 规矩：
    ///   · 这里是唯一允许 `using Godot` 的 Model 调用面；`Model/` 本身零 Godot 引用；
    ///   · 只做三件事：把 Variant 拆成纯 .NET 值、调 Model、把结果装回 Variant；
    ///   · 不写第二份公式 —— 任何"算一下"都必须落到 WarIsland.Model。
    ///
    /// GDScript 侧统一通过 `Game/adapters/*.gd` 调用，不直接摸 Mdl。
    /// </summary>
    [GlobalClass]
    public partial class ModelBridge : RefCounted
    {
        // =================================================================
        // 距离铁律
        // =================================================================
        public double R1() => RtsUnits.R1;

        public double ToMeters(double units) => RtsUnits.ToMeters(units);

        public double ToUnits(double meters) => RtsUnits.ToUnits(meters);

        // =================================================================
        // 伤害
        // =================================================================
        public Godot.Collections.Dictionary DamageCompute(
            double baseDamage, double spread, int attackType,
            double targetArmor, int targetArmorType,
            Godot.Collections.Dictionary rules,
            double rollSpread, double rollCrit, double attackMult)
        {
            var r = Damage.Compute(baseDamage, spread, attackType, targetArmor, targetArmorType,
                ParseRules(rules), rollSpread, rollCrit, attackMult);
            return new Godot.Collections.Dictionary
            {
                { "ok", r.Ok },
                { "damage", r.Damage },
                { "mitigation", r.Mitigation },
                { "multiplier", r.Multiplier },
                { "is_crit", r.IsCrit },
            };
        }

        public double DamageArmorMitigation(double armor, double reduction, double cap) =>
            Damage.ArmorMitigation(armor, reduction, cap);

        public double DamageCounterMultiplier(Godot.Collections.Array table, int attackType, int armorType, int stride) =>
            Damage.CounterMultiplier(ToDoubleArray(table), attackType, armorType, stride);

        // =================================================================
        // 经济 / 人口 / CP
        // =================================================================
        public bool EconomyCanAfford(int gold, int wood, int costGold, int costWood) =>
            Economy.CanAfford(gold, wood, costGold, costWood);

        /// <summary>扣费并写回 state（Dictionary 是引用类型，改了就生效）；不够时一分不扣。</summary>
        public bool EconomyPay(Godot.Collections.Dictionary state, int costGold, int costWood)
        {
            int gold = state.TryGetValue("gold", out Variant g) ? g.AsInt32() : 0;
            int wood = state.TryGetValue("wood", out Variant w) ? w.AsInt32() : 0;
            bool ok = Economy.Pay(ref gold, ref wood, costGold, costWood);
            if (ok)
            {
                state["gold"] = gold;
                state["wood"] = wood;
            }
            return ok;
        }

        public Godot.Collections.Dictionary EconomyAdd(Godot.Collections.Dictionary state, int gold, int wood)
        {
            int g = state.TryGetValue("gold", out Variant vg) ? vg.AsInt32() : 0;
            int w = state.TryGetValue("wood", out Variant vw) ? vw.AsInt32() : 0;
            Economy.Add(ref g, ref w, gold, wood);
            state["gold"] = g;
            state["wood"] = w;
            return state;
        }

        public bool EconomyHasFood(int used, int reserved, int amount, int cap) =>
            Economy.HasFood(used, reserved, amount, cap);

        public bool EconomyCanSpendCp(int cp, int costCp) => Economy.CanSpendCp(cp, costCp);

        public double EconomyIncomePerSecond(int workers, int carry, double tripSeconds) =>
            Economy.IncomePerSecond(workers, carry, tripSeconds);

        public int EconomyWorkersForIncome(double incomePerSec, int carry, double tripSeconds) =>
            Economy.WorkersForIncome(incomePerSec, carry, tripSeconds);

        // =================================================================
        // 可用性（原因码 + 参数）
        // =================================================================
        public Godot.Collections.Dictionary AvailabilityTrain(Godot.Collections.Dictionary ctx)
        {
            var c = new TrainCheck
            {
                PhaseOk = Bool(ctx, "phase_ok", true),
                Constructed = Bool(ctx, "constructed", true),
                Trains = ToStringArray(ctx, "trains"),
                Id = Str(ctx, "id", ""),
                Upgrading = Bool(ctx, "upgrading", false),
                RequireTier = Int(ctx, "require_tier", 0),
                CurrentTier = Int(ctx, "current_tier", 1),
                QueueMax = Int(ctx, "queue_max", Availability.TrainQueueMax),
                QueueSize = Int(ctx, "queue_size", 0),
                FoodCost = Int(ctx, "food_cost", 0),
                FoodFree = Int(ctx, "food_free", 0),
                Short = Bool(ctx, "short", false),
                Cp = Int(ctx, "cp", 0),
                CpCost = Int(ctx, "cp_cost", 0),
                Gold = Int(ctx, "gold", 0),
                GoldCost = Int(ctx, "gold_cost", 0),
                Wood = Int(ctx, "wood", 0),
                WoodCost = Int(ctx, "wood_cost", 0),
            };
            return AvailToDict(Availability.CheckTrain(c));
        }

        public Godot.Collections.Dictionary AvailabilityTrainPermission(
            Godot.Collections.Array trains, string id, int requiredTier, int currentTier)
        {
            var arr = new string[trains.Count];
            for (int i = 0; i < trains.Count; i++) arr[i] = trains[i].ToString();
            return AvailToDict(Availability.CheckTrainPermission(arr, id, requiredTier, currentTier));
        }

        public Godot.Collections.Dictionary AvailabilityResearch(Godot.Collections.Dictionary ctx)
        {
            var c = new ResearchCheck
            {
                Constructed = Bool(ctx, "constructed", true),
                Researchable = Bool(ctx, "researchable", false),
                Upgrading = Bool(ctx, "upgrading", false),
                Busy = Bool(ctx, "busy", false),
                Level = Int(ctx, "level", 0),
                MaxLevel = Int(ctx, "max_level", 1),
                Gold = Int(ctx, "gold", 0),
                GoldCost = Int(ctx, "gold_cost", 0),
                Wood = Int(ctx, "wood", 0),
                WoodCost = Int(ctx, "wood_cost", 0),
            };
            return AvailToDict(Availability.CheckResearch(c));
        }

        public Godot.Collections.Dictionary AvailabilityRefit(Godot.Collections.Dictionary ctx)
        {
            var c = new RefitCheck
            {
                Constructed = Bool(ctx, "constructed", true),
                Busy = Bool(ctx, "busy", false),
                Gold = Int(ctx, "gold", 0),
                GoldCost = Int(ctx, "gold_cost", 0),
                Wood = Int(ctx, "wood", 0),
                WoodCost = Int(ctx, "wood_cost", 0),
            };
            return AvailToDict(Availability.CheckRefit(c));
        }

        public Godot.Collections.Dictionary AvailabilityBuild(Godot.Collections.Dictionary ctx)
        {
            var c = new BuildCheck
            {
                HasWorker = Bool(ctx, "has_worker", true),
                PhaseOk = Bool(ctx, "phase_ok", true),
                RequireTier = Int(ctx, "require_tier", 0),
                CurrentTier = Int(ctx, "current_tier", 1),
                Short = Bool(ctx, "short", false),
                PopCost = Int(ctx, "pop_cost", 0),
                FoodFree = Int(ctx, "food_free", 0),
                Cp = Int(ctx, "cp", 0),
                CpCost = Int(ctx, "cp_cost", 0),
                Gold = Int(ctx, "gold", 0),
                GoldCost = Int(ctx, "gold_cost", 0),
                Wood = Int(ctx, "wood", 0),
                WoodCost = Int(ctx, "wood_cost", 0),
            };
            return AvailToDict(Availability.CheckBuild(c));
        }

        // =================================================================
        // 成长（主城等级 / 铁匠铺 / 升星）
        // =================================================================
        public double ProgressionFlatBonus(int level, double perLevel) =>
            Progression.FlatBonus(level, perLevel);

        public bool ProgressionCanUpgrade(int level, int maxLevel, int gold, int wood, int costGold, int costWood) =>
            Progression.CanUpgrade(level, maxLevel, gold, wood, costGold, costWood);

        public int ProgressionApplyLevel(int level, int maxLevel) => Progression.ApplyLevel(level, maxLevel);

        public bool ProgressionTierAllows(int requireTier, int currentTier) =>
            Progression.TierAllows(requireTier, currentTier);

        public int StarCap() => Progression.StarCap;

        public double StarKillExp() => Progression.KillExp;

        public double StarExpPerStar(int goldCost, int woodCost) => Progression.ExpPerStar(goldCost, woodCost);

        public int StarStarsOf(double expValue, double need) => Progression.StarsOf(expValue, need);

        public string StarName(int star) => Progression.StarName(star);

        public double StarOffenseMult(int star) => Progression.OffenseMult(star);

        public double StarToughMult(int star) => Progression.ToughMult(star);

        // =================================================================
        // 推演（--simulate）
        // =================================================================
        /// <summary>只做校验，返回错误字符串数组（空数组 = 合法）。</summary>
        public Godot.Collections.Array SimValidate(Godot.Collections.Dictionary config)
        {
            var errors = Skirmish.Validate(ToPlainDict(config));
            var arr = new Godot.Collections.Array();
            foreach (var e in errors) arr.Add(e);
            return arr;
        }

        public Godot.Collections.Dictionary Simulate(Godot.Collections.Dictionary config)
        {
            var result = Skirmish.Run(ToPlainDict(config));
            var outDict = new Godot.Collections.Dictionary
            {
                { "ok", result.Ok },
                { "seed", result.Seed },
                { "seconds", result.Seconds },
                { "winner", result.Winner },
            };
            if (!result.Ok)
            {
                var errs = new Godot.Collections.Array();
                foreach (var e in result.Errors) errs.Add(e);
                outDict["errors"] = errs;
                return outDict;
            }
            var sides = new Godot.Collections.Array();
            foreach (var s in result.Sides)
            {
                sides.Add(new Godot.Collections.Dictionary
                {
                    { "name", s.Name },
                    { "alive", s.Alive },
                    { "alive_by_type", ToGodotDict(s.AliveByType) },
                    { "hp_left", s.HpLeft },
                    { "kills", s.Kills },
                    { "losses", s.Losses },
                    { "units_built", s.UnitsBuilt },
                    { "built_by_type", ToGodotDict(s.BuiltByType) },
                    { "gold_mined", s.GoldMined },
                    { "gold_left", s.GoldLeft },
                    { "damage_dealt", s.DamageDealt },
                });
            }
            outDict["sides"] = sides;
            var timeline = new Godot.Collections.Array();
            foreach (var t in result.Timeline)
            {
                timeline.Add(new Godot.Collections.Dictionary
                {
                    { "t", t.T },
                    { "units", new Godot.Collections.Array { t.Units[0], t.Units[1] } },
                    { "gold", new Godot.Collections.Array { t.Gold[0], t.Gold[1] } },
                    { "hp", new Godot.Collections.Array { t.Hp[0], t.Hp[1] } },
                });
            }
            outDict["timeline"] = timeline;
            return outDict;
        }

        // =================================================================
        // Variant → 纯 .NET
        // =================================================================
        private static DamageRules ParseRules(Godot.Collections.Dictionary d)
        {
            var rules = new DamageRules();
            if (d == null) return rules;
            if (d.TryGetValue("damage_table", out Variant table) && table.VariantType == Variant.Type.Array)
                rules.DamageTable = ToDoubleArray(table.AsGodotArray());
            rules.Stride = d.TryGetValue("stride", out Variant st) ? st.AsInt32() : 5;
            rules.ArmorReduction = d.TryGetValue("armor_reduction", out Variant ar) ? ar.AsDouble() : 0.0;
            rules.ArmorReductionCap = d.TryGetValue("armor_reduction_cap", out Variant ac) ? ac.AsDouble() : 0.0;
            rules.CritChance = d.TryGetValue("crit_chance", out Variant cc) ? cc.AsDouble() : 0.0;
            rules.CritMultiplier = d.TryGetValue("crit_multiplier", out Variant cm) ? cm.AsDouble() : 1.0;
            return rules;
        }

        private static double[] ToDoubleArray(Godot.Collections.Array arr)
        {
            var outArr = new double[arr.Count];
            for (int i = 0; i < arr.Count; i++) outArr[i] = arr[i].AsDouble();
            return outArr;
        }

        /// <summary>递归拆成纯 .NET 类型：Dictionary→Dictionary&lt;string,object&gt;、Array→List&lt;object&gt;。</summary>
        private static Dictionary<string, object> ToPlainDict(Godot.Collections.Dictionary d)
        {
            var outDict = new Dictionary<string, object>();
            if (d == null) return outDict;
            foreach (var key in d.Keys)
            {
                outDict[key.ToString()] = ToPlain(d[key]);
            }
            return outDict;
        }

        private static object ToPlain(Variant v)
        {
            switch (v.VariantType)
            {
                case Variant.Type.Dictionary:
                    return ToPlainDict(v.AsGodotDictionary());
                case Variant.Type.Array:
                {
                    var src = v.AsGodotArray();
                    var list = new List<object>(src.Count);
                    for (int i = 0; i < src.Count; i++) list.Add(ToPlain(src[i]));
                    return list;
                }
                case Variant.Type.String:
                case Variant.Type.StringName:
                case Variant.Type.NodePath:
                    return v.ToString();
                case Variant.Type.Int:
                    return v.AsInt64();
                case Variant.Type.Float:
                    return v.AsDouble();
                case Variant.Type.Bool:
                    return v.AsBool();
                case Variant.Type.Nil:
                    return null;
                default:
                    return v.ToString();
            }
        }

        private static Godot.Collections.Dictionary ToGodotDict(Dictionary<string, int> d)
        {
            var outDict = new Godot.Collections.Dictionary();
            foreach (var kv in d) outDict[kv.Key] = kv.Value;
            return outDict;
        }

        // =================================================================
        // 小工具
        // =================================================================
        private static bool Bool(Godot.Collections.Dictionary d, string key, bool fallback)
        {
            return d != null && d.TryGetValue(key, out Variant v) ? v.AsBool() : fallback;
        }

        private static int Int(Godot.Collections.Dictionary d, string key, int fallback)
        {
            return d != null && d.TryGetValue(key, out Variant v) ? v.AsInt32() : fallback;
        }

        private static string Str(Godot.Collections.Dictionary d, string key, string fallback)
        {
            return d != null && d.TryGetValue(key, out Variant v) ? v.ToString() : fallback;
        }

        private static string[] ToStringArray(Godot.Collections.Dictionary d, string key)
        {
            if (d == null || !d.TryGetValue(key, out Variant v) || v.VariantType != Variant.Type.Array)
                return Array.Empty<string>();
            var arr = v.AsGodotArray();
            var outArr = new string[arr.Count];
            for (int i = 0; i < arr.Count; i++) outArr[i] = arr[i].ToString();
            return outArr;
        }

        private static Godot.Collections.Dictionary AvailToDict(AvailResult r)
        {
            var d = new Godot.Collections.Dictionary
            {
                { "ok", r.Ok },
                { "reason", r.Reason },
            };
            var p = new Godot.Collections.Dictionary();
            foreach (var kv in r.Params) p[kv.Key] = kv.Value;
            d["params"] = p;
            return d;
        }
    }
}
