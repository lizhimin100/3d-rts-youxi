using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>一批要进战场的单兵（来自一座棋盘建筑）。</summary>
    public sealed class ArmyUnit
    {
        public string UnitId = "";
        public int Star = 1;
        public int Count = 1;
        /// <summary>产它的建筑定义 id（光环按来源建筑生效）。</summary>
        public string SourceBuilding = "";
        /// <summary>产它的棋盘格（表现层落位/调试用）。</summary>
        public int SourceTile;

        public ArmyUnit Clone()
        {
            return new ArmyUnit
            {
                UnitId = UnitId,
                Star = Star,
                Count = Count,
                SourceBuilding = SourceBuilding,
                SourceTile = SourceTile,
            };
        }
    }

    /// <summary>
    /// 一组数据修饰器。战斗里只做乘/加，不再判断"这是哪个建筑给的"。
    /// 约定：AttackMult / MoveMult / DamageTakenMult 乘算，ArmorAdd 加算。
    /// </summary>
    public sealed class ModifierSet
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

        public void Multiply(ModifierSet other)
        {
            if (other == null) return;
            if (other.AttackMult > 0.0) AttackMult *= other.AttackMult;
            if (other.MoveMult > 0.0) MoveMult *= other.MoveMult;
            if (other.DamageTakenMult > 0.0) DamageTakenMult *= other.DamageTakenMult;
            ArmorAdd += other.ArmorAdd;
        }

        public ModifierSet Clone()
        {
            return new ModifierSet
            {
                AttackMult = AttackMult,
                ArmorAdd = ArmorAdd,
                MoveMult = MoveMult,
                DamageTakenMult = DamageTakenMult,
            };
        }
    }

    /// <summary>整支军队的修饰器：全局 + 按来源建筑（空间光环只作用于邻接建筑产出的兵）。</summary>
    public sealed class ArmyModifiers
    {
        public readonly ModifierSet Global = new ModifierSet();
        /// <summary>key = defId@tile —— 同一种建筑在不同格子可以有不同光环。</summary>
        public readonly Dictionary<string, ModifierSet> BySource =
            new Dictionary<string, ModifierSet>(StringComparer.Ordinal);

        public static string SourceKey(string defId, int tile) => $"{defId}@{tile}";

        public ModifierSet ForSource(string defId, int tile = 0)
        {
            var set = Global.Clone();
            if (string.IsNullOrEmpty(defId)) return set;
            if (BySource.TryGetValue(SourceKey(defId, tile), out ModifierSet local))
            {
                set.Multiply(local);
                return set;
            }
            // 兼容只给 defId 的调用：把同种建筑的所有局部光环一起乘上（宁可多给，不漏给）。
            foreach (var kv in BySource)
            {
                if (kv.Key.StartsWith(defId + "@", StringComparison.Ordinal)) set.Multiply(kv.Value);
            }
            return set;
        }

        public void AddSource(string defId, int tile, ModifierSet add)
        {
            if (string.IsNullOrEmpty(defId) || add == null) return;
            string key = SourceKey(defId, tile);
            if (!BySource.TryGetValue(key, out ModifierSet set))
            {
                set = new ModifierSet();
                BySource[key] = set;
            }
            set.Multiply(add);
        }
    }

    /// <summary>
    /// 规划 → 战斗的唯一交换物：**只交换计划与修饰器，不共享坐标/实体**。
    /// </summary>
    public sealed class ArmyPlan
    {
        public readonly List<ArmyUnit> Units = new List<ArmyUnit>();
        /// <summary>棋盘防御建筑投射的实体塔（静止、不贡献基地伤害）。</summary>
        public readonly List<ArmyUnit> Towers = new List<ArmyUnit>();
        public readonly ArmyModifiers Modifiers = new ArmyModifiers();
        public string Label = "";

        public int UnitCount
        {
            get
            {
                int n = 0;
                for (int i = 0; i < Units.Count; i++) n += Math.Max(Units[i].Count, 1);
                return n;
            }
        }

        public ArmyPlan Clone()
        {
            var p = new ArmyPlan { Label = Label };
            foreach (ArmyUnit u in Units) p.Units.Add(u.Clone());
            foreach (ArmyUnit u in Towers) p.Towers.Add(u.Clone());
            p.Modifiers.Global.Multiply(Modifiers.Global);
            foreach (var kv in Modifiers.BySource)
            {
                if (!p.Modifiers.BySource.TryGetValue(kv.Key, out ModifierSet set))
                {
                    set = new ModifierSet();
                    p.Modifiers.BySource[kv.Key] = set;
                }
                set.Multiply(kv.Value);
            }
            return p;
        }
    }
}
