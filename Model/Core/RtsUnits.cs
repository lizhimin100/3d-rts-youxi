namespace WarIsland.Model
{
    /// <summary>
    /// 距离换算铁律（全项目唯一来源）。
    ///
    /// 设计真相里所有"距离类"数值都是**游戏数值**（三位数/四位数：射程 125 / 650 / 870），
    /// Godot 3D 空间用**米**。两者之间只允许通过这一个系数换算：
    ///
    ///     米 = 游戏数值 × R1
    ///     R1 = 0.015 米 / 单位
    ///
    /// 规矩：
    ///   · Model 层只认游戏数值，**不许**出现米（也不许出现 0.015）；
    ///   · 只有 Screens/（3D 表现层）在真正落到世界坐标时才乘 R1；
    ///   · 想让某个单位更远，改它的卡面数值（125 → 150），不要动 R1。
    /// </summary>
    public static class RtsUnits
    {
        /// <summary>基准系数：每 1 点游戏数值 = 0.015 米。</summary>
        public const double R1 = 0.015;

        /// <summary>游戏数值 → 米（表现层唯一入口）。</summary>
        public static double ToMeters(double units) => units * R1;

        /// <summary>米 → 游戏数值（界面按米反算时用）。</summary>
        public static double ToUnits(double meters) => meters / R1;
    }
}
