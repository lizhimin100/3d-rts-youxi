using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>
    /// 机制触发时机（唯一枚举）。新增卡牌/遗物只加数据，不加 if 分支。
    /// </summary>
    public static class MechanicTriggers
    {
        public const string OnBuild = "on_build";
        public const string PlanningEnd = "planning_end";
        public const string BattleStart = "battle_start";
        public const string OnUnitSpawn = "on_unit_spawn";
        public const string OnKill = "on_kill";
        public const string RoundEnd = "round_end";

        public static bool IsValid(string t)
        {
            return t == OnBuild || t == PlanningEnd || t == BattleStart ||
                   t == OnUnitSpawn || t == OnKill || t == RoundEnd;
        }
    }

    /// <summary>
    /// 一个原子效果：只有"乘/加"两种运算，没有行为代码。
    /// 将来加遗物/策略牌，只需要在数据里组合这些原子。
    /// </summary>
    public sealed class MechanicEffect
    {
        public double AttackMult = 1.0;
        public double ArmorAdd;
        public double MoveMult = 1.0;
        public double DamageTakenMult = 1.0;

        public bool IsIdentity =>
            Math.Abs(AttackMult - 1.0) < 1e-9 &&
            Math.Abs(ArmorAdd) < 1e-9 &&
            Math.Abs(MoveMult - 1.0) < 1e-9 &&
            Math.Abs(DamageTakenMult - 1.0) < 1e-9;

        public ModifierSet ToModifierSet()
        {
            return new ModifierSet
            {
                AttackMult = AttackMult > 0.0 ? AttackMult : 1.0,
                ArmorAdd = ArmorAdd,
                MoveMult = MoveMult > 0.0 ? MoveMult : 1.0,
                DamageTakenMult = DamageTakenMult > 0.0 ? DamageTakenMult : 1.0,
            };
        }
    }

    /// <summary>
    /// 机制定义：触发时机 + 来源（kind/tag）+ 作用域 + 原子效果。
    /// 来源只写大类（support/economy/defense），**不许写具体建筑 id**。
    /// </summary>
    public sealed class MechanicDef
    {
        public string Id = "";
        public string Trigger = MechanicTriggers.PlanningEnd;
        /// <summary>来源建筑大类（留空 = 不限制）。</summary>
        public string SourceKind = "";
        /// <summary>来源建筑 Tag（留空 = 不限制）。</summary>
        public string SourceTag = "";
        /// <summary>army / adjacent / column / self。</summary>
        public string Scope = "army";
        public int Radius = 1;
        public MechanicEffect Effect = new MechanicEffect();
        public string Note = "";
    }

    /// <summary>
    /// 机制总线 —— 把"数据修饰器"按触发时机灌进 ArmyModifiers。
    ///
    /// 为什么要有这一层：建筑光环、经济、被动将来会越来越多；
    /// 如果写成 `if (buildingId == "blacksmith")`，每加一张卡就要改一次战斗/规划代码。
    /// 现在只有一条链路：
    ///   数据（planning.json 的 aura/economy/defense/mechanics）
    ///     → MechanicDef（触发时机 + 来源大类 + 作用域 + 原子效果）
    ///     → BoardSession 在 planning_end 求值
    ///     → ArmyPlan.Modifiers 进战斗。
    /// 战斗内核只认乘数，不认识任何建筑 id。
    /// </summary>
    public static class MechanicBus
    {
        public static MechanicDef ParseDef(IDictionary<string, object> d, List<string> notes)
        {
            var def = new MechanicDef();
            if (d == null) return def;
            def.Id = JVal.Str(d, "id", "");
            def.Trigger = JVal.Str(d, "trigger", MechanicTriggers.PlanningEnd);
            def.SourceKind = JVal.Str(d, "source_kind", "");
            def.SourceTag = JVal.Str(d, "source_tag", "");
            def.Scope = JVal.Str(d, "scope", "army");
            def.Radius = JVal.Int(d, "radius", 1);
            def.Note = JVal.Str(d, "note", "");
            var eff = JVal.Dict(d, "effect");
            if (eff != null)
            {
                def.Effect.AttackMult = JVal.Double(eff, "attack_mult", 1.0);
                def.Effect.ArmorAdd = JVal.Double(eff, "armor_add", 0.0);
                def.Effect.MoveMult = JVal.Double(eff, "move_mult", 1.0);
                def.Effect.DamageTakenMult = JVal.Double(eff, "damage_taken_mult", 1.0);
            }
            if (notes != null && !MechanicTriggers.IsValid(def.Trigger))
                notes.Add($"机制 {def.Id} 的 trigger={def.Trigger} 非法");
            return def;
        }

        public static List<string> Validate(List<MechanicDef> defs)
        {
            var errors = new List<string>();
            if (defs == null) return errors;
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (MechanicDef d in defs)
            {
                if (string.IsNullOrEmpty(d.Id)) errors.Add("机制缺 id");
                else if (!seen.Add(d.Id)) errors.Add($"机制 id 重复：{d.Id}");
                if (!MechanicTriggers.IsValid(d.Trigger))
                    errors.Add($"机制 {d.Id} 的 trigger={d.Trigger} 非法");
                if (d.Scope != "army" && d.Scope != "adjacent" && d.Scope != "column" && d.Scope != "self")
                    errors.Add($"机制 {d.Id} 的 scope={d.Scope} 非法（army/adjacent/column/self）");
                if (d.Radius < 0 || d.Radius > 3)
                    errors.Add($"机制 {d.Id} 的 radius={d.Radius} 越界（0..3）");
                if (d.Effect == null) errors.Add($"机制 {d.Id} 缺 effect");
                else if (d.Effect.AttackMult <= 0.0 || d.Effect.MoveMult <= 0.0 || d.Effect.DamageTakenMult <= 0.0)
                    errors.Add($"机制 {d.Id} 的倍率必须 > 0");
            }
            return errors;
        }

        /// <summary>
        /// 从建筑数据生成机制定义（唯一来源 = planning.json 的 aura/economy/defense）。
        /// 星级在这里传入，因为数值是数组（1/2/3 星）。
        /// </summary>
        public static List<MechanicDef> FromBuildings(PlanningConfig cfg, IReadOnlyList<BoardBuilding> buildings)
        {
            var defs = new List<MechanicDef>();
            if (cfg == null || buildings == null) return defs;
            foreach (BoardBuilding b in buildings)
            {
                if (!cfg.Buildings.TryGetValue(b.DefId, out BuildingDef def)) continue;
                if (def.Aura != null)
                {
                    defs.Add(new MechanicDef
                    {
                        Id = $"aura:{def.Id}@{b.Tile}",
                        Trigger = MechanicTriggers.PlanningEnd,
                        SourceKind = def.Kind,
                        SourceTag = def.Tag,
                        Scope = def.Aura.Scope,
                        Radius = def.Aura.Radius,
                        Effect = new MechanicEffect
                        {
                            AttackMult = def.Aura.AttackOf(b.Star),
                            ArmorAdd = def.Aura.ArmorOf(b.Star),
                        },
                    });
                }
            }
            if (cfg.Mechanics != null) defs.AddRange(cfg.Mechanics);
            return defs;
        }

        /// <summary>
        /// 规划结束：把所有 planning_end 机制灌进 ArmyModifiers。
        /// 空间作用域按棋盘格距判定，不认建筑 id：
        ///   · 先找**来源建筑**（kind/tag 匹配的、带 aura 的那几座）；
        ///   · 再找落在它们作用域里的**受益建筑**；
        ///   · 按受益建筑的 defId@tile 记账，同种建筑不同格子可以吃不同光环。
        /// </summary>
        public static void ApplyPlanningEnd(
            PlanningConfig cfg,
            BoardArena arena,
            IReadOnlyList<BoardBuilding> buildings,
            ArmyModifiers into)
        {
            if (into == null || cfg == null || buildings == null) return;
            List<MechanicDef> defs = FromBuildings(cfg, buildings);

            // 全局机制（来自 planning.json 的 mechanics[]）
            foreach (MechanicDef m in defs)
            {
                if (m.Trigger != MechanicTriggers.PlanningEnd) continue;
                if (m.Effect == null || m.Effect.IsIdentity) continue;
                if (m.Scope == "army")
                    into.Global.Multiply(m.Effect.ToModifierSet());
            }

            // 建筑光环（scope = adjacent/column/self）：来源只认 kind/tag
            foreach (BoardBuilding src in buildings)
            {
                if (!cfg.Buildings.TryGetValue(src.DefId, out BuildingDef sdef)) continue;
                if (sdef.Aura == null) continue;
                var mod = new ModifierSet
                {
                    AttackMult = Math.Max(sdef.Aura.AttackOf(src.Star), 0.01),
                    ArmorAdd = sdef.Aura.ArmorOf(src.Star),
                };
                if (Math.Abs(mod.AttackMult - 1.0) < 1e-9 && Math.Abs(mod.ArmorAdd) < 1e-9) continue;

                string scope = sdef.Aura.Scope;
                int radius = Math.Max(sdef.Aura.Radius, 1);
                foreach (BoardBuilding target in buildings)
                {
                    if (!InScope(arena, src, target, scope, radius)) continue;
                    into.AddSource(target.DefId, target.Tile, mod);
                }
            }
        }

        /// <summary>经济建筑每轮产出的 CP（规划期唯一入口）。</summary>
        public static int CollectCp(PlanningConfig cfg, IReadOnlyList<BoardBuilding> buildings)
        {
            int cp = 0;
            if (cfg == null || buildings == null) return cp;
            foreach (BoardBuilding b in buildings)
            {
                if (!cfg.Buildings.TryGetValue(b.DefId, out BuildingDef def)) continue;
                if (def.Kind != BuildingKinds.Economy || def.Economy == null) continue;
                cp += def.Economy.CpOf(b.Star);
            }
            return cp;
        }

        /// <summary>来源建筑 src 的光环是否覆盖 target。</summary>
        private static bool InScope(
            BoardArena arena,
            BoardBuilding src,
            BoardBuilding target,
            string scope,
            int radius)
        {
            if (target.Tile == src.Tile) return true;          // 本格永远吃自己的光环
            if (arena == null) return false;
            if (scope == "self") return false;                  // 只作用自己产出的兵

            int dist = arena.Manhattan(src.Tile, target.Tile);
            if (dist == int.MaxValue) return false;

            if (scope == "adjacent") return dist <= radius;
            if (scope == "column") return arena.ColumnOf(src.Tile) == arena.ColumnOf(target.Tile);
            return false;
        }
    }
}
