using System;

namespace WarIsland.Model
{
    /// <summary>
    /// 成长规则 —— 唯一实现：主城等级门槛、铁匠铺平铺加成、**升星**。
    ///
    /// 升星口径（2026-11-08 定稿，2026-11-20 保留）：
    ///   · 击杀经验：每次击杀 15 点，击杀者独得；
    ///   · 升一星所需经验 = 该兵种价值换算「金 × 2 + 木 × 3」，**三星同价**；
    ///   · 命名：新兵 / 老兵 / 精英 / 王牌；
    ///   · 加成：一星 +15%/+20%，二星累计 +30%/+40%，三星累计 +80%/+100%。
    /// 状态（exp_value / star_level）存在单位身上，这里只提供数字。
    /// </summary>
    public static class Progression
    {
        public const int StarCap = 3;
        public const double KillExp = 15.0;
        public const double MinExpPerStar = 30.0;

        private static readonly string[] StarNames = { "新兵", "老兵", "精英", "王牌" };
        private static readonly double[] OffenseMults = { 1.0, 1.15, 1.30, 1.80 };
        private static readonly double[] ToughMults = { 1.0, 1.20, 1.40, 2.00 };

        /// <summary>铁匠铺：每级平铺 +1（不是百分比）。level 从 0 起。</summary>
        public static double FlatBonus(int level, double perLevel = 1.0) => Math.Max(level, 0) * perLevel;

        public static bool CanUpgrade(int level, int maxLevel, int gold, int wood, int costGold, int costWood)
        {
            if (level >= maxLevel) return false;
            return gold >= costGold && wood >= costWood;
        }

        /// <summary>升级成功返回新等级；到顶返回 -1（调用方据此扣费，避免扣了钱没升级）。</summary>
        public static int ApplyLevel(int level, int maxLevel)
        {
            if (level >= maxLevel) return -1;
            return level + 1;
        }

        /// <summary>主城等级门槛：建筑的 require_tier 必须 &lt;= 当前主城等级。</summary>
        public static bool TierAllows(int requireTier, int currentTier) =>
            Math.Max(requireTier, 0) <= Math.Max(currentTier, 1);

        /// <summary>升一星需要多少经验 = 金 × 2 + 木 × 3（每次升星都是这个数）。</summary>
        public static double ExpPerStar(int goldCost, int woodCost)
        {
            double v = goldCost * 2.0 + woodCost * 3.0;
            return Math.Max(v, MinExpPerStar);
        }

        /// <summary>经验 → 该有多少星（封顶 3）。</summary>
        public static int StarsOf(double expValue, double need)
        {
            if (need <= 0.0) return 0;
            int s = (int)Math.Floor(Math.Max(expValue, 0.0) / need);
            if (s < 0) s = 0;
            if (s > StarCap) s = StarCap;
            return s;
        }

        public static string StarName(int star) => StarNames[ClampStar(star)];

        /// <summary>攻击 / 移速 / 攻速 的累计倍率。</summary>
        public static double OffenseMult(int star) => OffenseMults[ClampStar(star)];

        /// <summary>血量 / 防御 的累计倍率。</summary>
        public static double ToughMult(int star) => ToughMults[ClampStar(star)];

        private static int ClampStar(int star)
        {
            if (star < 0) return 0;
            if (star > StarCap) return StarCap;
            return star;
        }
    }
}
