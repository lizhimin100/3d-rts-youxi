using System;
using Vec2 = System.Numerics.Vector2;

namespace WarIsland.Model
{
    /// <summary>阵位类别：唯一判据是**是否使用投射物**，不是射程。</summary>
    public enum UnitLine
    {
        Melee = 0,
        Ranged = 1,
    }

    /// <summary>
    /// 自动布阵 —— 纯数学、确定性、全游戏数值（1 = 1.5 cm）。
    ///
    /// 口径（2026-11-24 冻结）：
    ///   · 只有两排：无投射物 = 近战前排；有投射物 = 远程后排（长枪兵虽然 155 射程，仍在近战排）；
    ///   · 同一排内严格按规划期出牌/生成顺序（slot 0,1,2…）；
    ///   · 中轴（Z=0）向外对称展开：±0.5、±1.5、±2.5… × file_pitch；
    ///   · 超宽自动折行：slot / files 就是排号，排向后延伸 rank_pitch；
    ///   · 0 号位在部署线，排号越大越靠自家；远程线再整体后退 meleeRanks×rank_pitch + line_gap。
    ///
    /// 这里不读任何 Godot API；Screens 只用 R1 把结果换成米。
    /// </summary>
    public static class FormationPlan
    {
        public const double FilePitchDefault = 96.0;   // 1.44 m
        public const double RankPitchDefault = 144.0;  // 2.16 m
        public const double LineGapDefault = 240.0;    // 3.60 m
        public const int MaxFilesDefault = 24;
        public const int TileFilesDefault = 4;

        /// <summary>唯一分类：有投射物 = 远程；没有 = 近战。</summary>
        public static UnitLine LineOf(UnitDef def)
        {
            return def != null && def.Projectile ? UnitLine.Ranged : UnitLine.Melee;
        }

        /// <summary>n 个人按每排 files 个排，需要几排（0 人 = 0 排）。</summary>
        public static int Ranks(int count, int files)
        {
            if (count <= 0) return 0;
            int f = Math.Max(files, 1);
            return (count + f - 1) / f;
        }

        /// <summary>
        /// 棋盘格内的出生位（相对格中心，游戏数值）。
        /// 从格子右下象限起步（+60,+60），排向 +X 延伸，4 列 × N 排；
        /// 左上建筑占地（x&lt;-0.3 且 z&lt;-0.3 格宽）在构造上不会被踩到。
        /// </summary>
        public static Vec2 TileSlot(int slot, int files = TileFilesDefault,
            double filePitch = FilePitchDefault, double rankPitch = RankPitchDefault)
        {
            int f = Math.Max(files, 1);
            int rank = slot / f;
            int k = slot % f;
            int pair = k / 2;
            double sign = (k % 2 == 0) ? 1.0 : -1.0;
            double lateral = (pair + 0.5) * filePitch * sign;
            double x = 60.0 + rank * rankPitch;
            double z = 60.0 + lateral;
            return new Vec2((float)x, (float)z);
        }

        /// <summary>
        /// 战场阵位（lane 坐标 / 游戏数值）。
        /// <paramref name="frontX"/> / <paramref name="frontZ"/> 是己方部署线中点；
        /// <paramref name="dirX"/> = 排向自家延伸的方向：玩家 -1，敌方 +1。
        /// <paramref name="meleeRanks"/> 只影响远程线的整体后退量。
        /// </summary>
        public static Vec2 BattleSlot(double frontX, double frontZ, int dirX, UnitLine line,
            int slot, int files, int meleeRanks,
            double filePitch = FilePitchDefault, double rankPitch = RankPitchDefault,
            double lineGap = LineGapDefault)
        {
            int f = Math.Max(files, 1);
            int rank = slot / f;
            int k = slot % f;
            int pair = k / 2;
            double sign = (k % 2 == 0) ? 1.0 : -1.0;
            double lateral = (pair + 0.5) * filePitch * sign;
            double lineOffset = line == UnitLine.Ranged
                ? (meleeRanks > 0 ? meleeRanks * rankPitch + lineGap : 0.0)
                : 0.0;
            double forward = frontX + dirX * (lineOffset + rank * rankPitch);
            return new Vec2((float)forward, (float)(frontZ + lateral));
        }

        /// <summary>
        /// 按战场宽度算每排人数（偶数，保证中轴对称；至少 2）。
        /// width/edge 都是游戏数值；maxFiles 是数据兜底上限。
        /// </summary>
        public static int FilesForWidth(double widthUnits, double edgeUnits, double filePitch, int maxFiles)
        {
            double half = widthUnits * 0.5 - edgeUnits;
            if (half <= filePitch) return 2;
            int pairs = (int)Math.Floor(half / filePitch);
            if (pairs < 1) pairs = 1;
            int files = pairs * 2;
            int cap = Math.Max(maxFiles, 2);
            return Math.Min(files, cap);
        }
    }
}
