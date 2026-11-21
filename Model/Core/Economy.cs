using System;

namespace WarIsland.Model
{
    /// <summary>
    /// 资源账本 —— **付款与人口判断的唯一实现**。
    ///
    /// 两套资源互不相通（长短局隔离）：
    ///   · 短局（主线）：**CP + 人口**，执行阶段不出兵，CP 只在规划阶段消耗；
    ///   · 金币/木材：只给"局外成长 / 升星 / 建筑改造"这类长线账本用。
    /// 本类不读任何配置，调用方把数值喂进来。
    /// </summary>
    public static class Economy
    {
        public static bool CanAfford(int gold, int wood, int costGold, int costWood)
        {
            return gold >= Math.Max(costGold, 0) && wood >= Math.Max(costWood, 0);
        }

        /// <summary>扣费；不够就**一分不扣**并返回 false（不做部分扣款）。</summary>
        public static bool Pay(ref int gold, ref int wood, int costGold, int costWood)
        {
            if (!CanAfford(gold, wood, costGold, costWood)) return false;
            gold -= Math.Max(costGold, 0);
            wood -= Math.Max(costWood, 0);
            return true;
        }

        public static void Add(ref int gold, ref int wood, int addGold, int addWood)
        {
            gold = Math.Max(0, gold + addGold);
            wood = Math.Max(0, wood + addWood);
        }

        /// <summary>人口：已占用 + 已排队 + 这一单 &lt;= 上限。</summary>
        public static bool HasFood(int used, int reserved, int amount, int cap)
        {
            return Math.Max(used, 0) + Math.Max(reserved, 0) + Math.Max(amount, 0) <= Math.Max(cap, 0);
        }

        /// <summary>CP：指挥点是否够下单。</summary>
        public static bool CanSpendCp(int cp, int costCp) => cp >= Math.Max(costCp, 0);

        /// <summary>扣 CP；不够返回 false 且不扣。</summary>
        public static bool SpendCp(ref int cp, int costCp)
        {
            if (!CanSpendCp(cp, costCp)) return false;
            cp -= Math.Max(costCp, 0);
            return true;
        }

        /// <summary>每秒金币收入（抽象补给率：人数 × 每趟携带 ÷ 每趟秒数）。</summary>
        public static double IncomePerSecond(int workers, int carry, double tripSeconds)
        {
            if (workers <= 0 || carry <= 0 || tripSeconds <= 0.0) return 0.0;
            return workers * (double)carry / tripSeconds;
        }

        public static int WorkersForIncome(double incomePerSec, int carry, double tripSeconds)
        {
            double per = IncomePerSecond(1, carry, tripSeconds);
            if (per <= 0.0) return 0;
            return (int)Math.Ceiling(Math.Max(incomePerSec, 0.0) / per);
        }
    }
}
