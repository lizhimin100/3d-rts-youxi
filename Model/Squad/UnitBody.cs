using System;
using System.Collections.Generic;
using Vec2 = System.Numerics.Vector2;

namespace WarIsland.Model
{
    /// <summary>
    /// 单兵身位 / 落点环 —— **全项目唯一实现**。
    ///
    /// 2026-11-22 口径变更：**小队编制取消**。每次产出都是若干**独立单兵**：
    ///   · 没有 squad_size / formation / squad_radius 这些编制字段（units.json 里已删除）；
    ///   · 没有阵型槽位、没有队内分散 AI —— 每个兵自己寻路、自己索敌、自己受击、自己死；
    ///   · 只剩两个几何量：一个"身位"（碰撞/接敌距离）和一个"导航半径"（脊线夹取/抵达判定）。
    ///
    /// 历史包袱说明：类型名仍带 Squad（`SquadBattle` / `SquadView` / `SquadSession`），
    /// 那是跨语言契约（GDScript 桥 + 136 条自检 + 截图配方都按这个名字调），
    /// 但语义已经是"一个 Squad 实体 = 一名单兵"。改名字只会制造一次大范围迁移，
    /// 不会让玩法变得更对 —— 所以名字留、编制删。
    /// </summary>
    public static class UnitBody
    {
        /// <summary>身位合法区间（米）：0.15（小动物）~ 1.2（巨兽）。</summary>
        public const double MinBodyMeters = 0.15;
        public const double MaxBodyMeters = 1.2;

        /// <summary>导航半径下限（游戏数值）= 0.39 米，比身位略大，避免贴边抖动。</summary>
        public const double MinNavUnits = 26.0;

        /// <summary>一个身位（米）。缺省 0.45 米 = 一个方块人的肩宽。</summary>
        public static double BodyMeters(UnitDef def)
        {
            double m = def != null && def.BodyRadius > 0.0 ? def.BodyRadius : 0.45;
            if (m < MinBodyMeters) m = MinBodyMeters;
            if (m > MaxBodyMeters) m = MaxBodyMeters;
            return m;
        }

        /// <summary>一个身位（游戏数值）—— 接敌/碰撞用。</summary>
        public static double BodyUnits(UnitDef def) => RtsUnits.ToUnits(BodyMeters(def));

        /// <summary>导航半径（游戏数值）—— 脊线夹取与抵达判定用。</summary>
        public static double NavRadius(UnitDef def) => Math.Max(BodyUnits(def) * 1.35, MinNavUnits);

        /// <summary>
        /// 一格出兵位附近的**紧凑落点环**（米，相对格中心）。
        ///
        /// 目标：n 个单兵落在格子中心附近、自然散开，且**严格避开左上角的建筑占地**。
        /// 做法：黄金角螺旋 + 右下象限偏置；任何落到左上象限（建筑位）的点镜像到右下。
        /// 结果确定性（同 n 同序 = 同坐标），所以"重放同一场"不会因为落点随机而变结果。
        /// </summary>
        public static List<Vec2> SpawnRing(int count)
        {
            int n = Math.Max(count, 1);
            var list = new List<Vec2>(n);
            const double GoldenAngle = 2.399963229728653;
            for (int i = 0; i < n; i++)
            {
                double ang = i * GoldenAngle;
                double r = 0.72 + 0.225 * Math.Sqrt(i);
                // 环心再往右下推一点：左上角的建筑占地是 41% 格宽，
                // 环心太靠中心时人会和房子在透视上叠在一起（截图里像"站在屋顶上"）。
                double x = 0.86 + Math.Cos(ang) * r * 1.12;
                double z = 0.86 + Math.Sin(ang) * r;
                // 左上象限 = 建筑位（planning.json 的 anchor_u/v 是负的）。
                // 落点只要同时落在"左"和"上"，就镜像到右下 —— 保证人不会站在房子里。
                if (x < -0.30 && z < -0.30)
                {
                    x = -x;
                    z = -z;
                }
                list.Add(new Vec2((float)x, (float)z));
            }
            return list;
        }

        /// <summary>校验一个兵种的身位字段（给 UnitCatalog.Validate 用）。</summary>
        public static List<string> Validate(UnitDef def)
        {
            var errors = new List<string>();
            if (def == null) return errors;
            string tag = string.IsNullOrEmpty(def.Id) ? "(空 id)" : def.Id;
            if (def.BodyRadius < MinBodyMeters || def.BodyRadius > MaxBodyMeters)
                errors.Add($"{tag}：body_radius={def.BodyRadius} 越界（{MinBodyMeters}..{MaxBodyMeters} 米）");
            return errors;
        }
    }
}
