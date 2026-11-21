using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>可用性判断的结果：ok / 原因码 / 原因参数（界面负责翻译成文案）。</summary>
    public sealed class AvailResult
    {
        public bool Ok;
        public string Reason;
        public Dictionary<string, int> Params = new Dictionary<string, int>();

        public static AvailResult Pass() => new AvailResult { Ok = true, Reason = "ok" };

        public static AvailResult Fail(string reason)
        {
            return new AvailResult { Ok = false, Reason = reason };
        }

        public static AvailResult Fail(string reason, string key, int value)
        {
            var r = new AvailResult { Ok = false, Reason = reason };
            r.Params[key] = value;
            return r;
        }
    }

    /// <summary>训练可用性的输入（缺省值按"最宽松"处理，调用方只传关心的项）。</summary>
    public sealed class TrainCheck
    {
        public bool PhaseOk = true;
        public bool Constructed = true;
        public string[] Trains = System.Array.Empty<string>();
        public string Id = "";
        public bool Upgrading;
        public int RequireTier;
        public int CurrentTier = 1;
        public int QueueMax = 10;
        public int QueueSize;
        public int FoodCost;
        public int FoodFree;
        public bool Short;
        public int Cp;
        public int CpCost;
        public int Gold;
        public int GoldCost;
        public int Wood;
        public int WoodCost;
    }

    public sealed class ResearchCheck
    {
        public bool Constructed = true;
        public bool Researchable = true;
        public bool Upgrading;
        public bool Busy;
        public int Level;
        public int MaxLevel = 1;
        public int Gold;
        public int GoldCost;
        public int Wood;
        public int WoodCost;
    }

    public sealed class RefitCheck
    {
        public bool Constructed = true;
        public bool Busy;
        public int Gold;
        public int GoldCost;
        public int Wood;
        public int WoodCost;
    }

    public sealed class BuildCheck
    {
        public bool HasWorker = true;
        public bool PhaseOk = true;
        public int RequireTier;
        public int CurrentTier = 1;
        public bool Short;
        public int PopCost;
        public int FoodFree;
        public int Cp;
        public int CpCost;
        public int Gold;
        public int GoldCost;
        public int Wood;
        public int WoodCost;
    }

    /// <summary>
    /// 可用性判断（训练 / 研究 / 建造 / 改造）—— **全游戏唯一实现**。
    ///
    /// 铁律：
    ///   · 只收数值与字符串，不读配置、不碰节点；
    ///   · 返回原因码（ASCII），界面负责翻译成文案；
    ///   · 判断顺序 = 玩家看到的第一个原因
    ///     （没盖好 &gt; 没这个选项 &gt; 升级中 &gt; 门槛 &gt; 队列 &gt; 人口 &gt; CP &gt; 金币 &gt; 木材）。
    /// </summary>
    public static class Availability
    {
        /// <summary>训练队列上限（唯一来源）。</summary>
        public const int TrainQueueMax = 10;

        public static AvailResult CheckTrain(TrainCheck c)
        {
            if (!c.PhaseOk) return AvailResult.Fail("not_planning");
            if (!c.Constructed) return AvailResult.Fail("not_constructed");
            if (!Contains(c.Trains, c.Id)) return AvailResult.Fail("not_in_trains");
            if (c.Upgrading) return AvailResult.Fail("upgrading");
            if (c.RequireTier > c.CurrentTier)
            {
                var r = AvailResult.Fail("tier_locked");
                r.Params["required"] = c.RequireTier;
                r.Params["current"] = c.CurrentTier;
                return r;
            }
            if (c.QueueMax > 0 && c.QueueSize >= c.QueueMax)
                return AvailResult.Fail("queue_full", "max", c.QueueMax);
            if (c.FoodCost > c.FoodFree)
            {
                var r = AvailResult.Fail("no_food");
                r.Params["need"] = c.FoodCost;
                r.Params["free"] = c.FoodFree;
                return r;
            }
            if (c.Short)
            {
                if (c.Cp < c.CpCost)
                {
                    var r = AvailResult.Fail("no_cp");
                    r.Params["need"] = c.CpCost;
                    r.Params["have"] = c.Cp;
                    r.Params["short"] = c.CpCost - c.Cp;
                    return r;
                }
                return AvailResult.Pass();
            }
            if (c.Gold < c.GoldCost)
            {
                var r = AvailResult.Fail("no_gold");
                r.Params["need"] = c.GoldCost;
                r.Params["have"] = c.Gold;
                r.Params["short"] = c.GoldCost - c.Gold;
                return r;
            }
            if (c.Wood < c.WoodCost)
            {
                var r = AvailResult.Fail("no_wood");
                r.Params["need"] = c.WoodCost;
                r.Params["have"] = c.Wood;
                r.Params["short"] = c.WoodCost - c.Wood;
                return r;
            }
            return AvailResult.Pass();
        }

        /// <summary>只判"这栋楼有没有资格造它"（trains + 主城等级），不判资源/队列/完工。</summary>
        public static AvailResult CheckTrainPermission(string[] trains, string id, int requiredTier, int currentTier)
        {
            if (!Contains(trains, id)) return AvailResult.Fail("not_in_trains");
            if (requiredTier > currentTier)
            {
                var r = AvailResult.Fail("tier_locked");
                r.Params["required"] = requiredTier;
                r.Params["current"] = currentTier;
                return r;
            }
            return AvailResult.Pass();
        }

        public static AvailResult CheckResearch(ResearchCheck c)
        {
            if (!c.Constructed) return AvailResult.Fail("not_constructed");
            if (!c.Researchable) return AvailResult.Fail("not_researchable");
            if (c.Upgrading) return AvailResult.Fail("upgrading");
            if (c.Busy) return AvailResult.Fail("research_busy");
            if (c.Level >= c.MaxLevel)
            {
                var r = AvailResult.Fail("max_level");
                r.Params["level"] = c.Level;
                r.Params["max"] = c.MaxLevel;
                return r;
            }
            if (c.Gold < c.GoldCost)
            {
                var r = AvailResult.Fail("no_gold");
                r.Params["need"] = c.GoldCost;
                r.Params["have"] = c.Gold;
                r.Params["short"] = c.GoldCost - c.Gold;
                return r;
            }
            if (c.Wood < c.WoodCost)
            {
                var r = AvailResult.Fail("no_wood");
                r.Params["need"] = c.WoodCost;
                r.Params["have"] = c.Wood;
                r.Params["short"] = c.WoodCost - c.Wood;
                return r;
            }
            return AvailResult.Pass();
        }

        public static AvailResult CheckRefit(RefitCheck c)
        {
            if (!c.Constructed) return AvailResult.Fail("not_constructed");
            if (c.Busy) return AvailResult.Fail("upgrading");
            if (c.Gold < c.GoldCost)
            {
                var r = AvailResult.Fail("no_gold");
                r.Params["need"] = c.GoldCost;
                r.Params["have"] = c.Gold;
                r.Params["short"] = c.GoldCost - c.Gold;
                return r;
            }
            if (c.Wood < c.WoodCost)
            {
                var r = AvailResult.Fail("no_wood");
                r.Params["need"] = c.WoodCost;
                r.Params["have"] = c.Wood;
                r.Params["short"] = c.WoodCost - c.Wood;
                return r;
            }
            return AvailResult.Pass();
        }

        public static AvailResult CheckBuild(BuildCheck c)
        {
            if (!c.HasWorker) return AvailResult.Fail("no_worker");
            if (!c.PhaseOk) return AvailResult.Fail("not_planning");
            if (c.RequireTier > c.CurrentTier)
            {
                var r = AvailResult.Fail("tier_locked");
                r.Params["required"] = c.RequireTier;
                r.Params["current"] = c.CurrentTier;
                return r;
            }
            if (c.Short)
            {
                if (c.PopCost > c.FoodFree)
                {
                    var r = AvailResult.Fail("no_food");
                    r.Params["need"] = c.PopCost;
                    r.Params["free"] = c.FoodFree;
                    return r;
                }
                if (c.Cp < c.CpCost)
                {
                    var r = AvailResult.Fail("no_cp");
                    r.Params["need"] = c.CpCost;
                    r.Params["have"] = c.Cp;
                    r.Params["short"] = c.CpCost - c.Cp;
                    return r;
                }
                return AvailResult.Pass();
            }
            if (c.Gold < c.GoldCost)
            {
                var r = AvailResult.Fail("no_gold");
                r.Params["need"] = c.GoldCost;
                r.Params["have"] = c.Gold;
                r.Params["short"] = c.GoldCost - c.Gold;
                return r;
            }
            if (c.Wood < c.WoodCost)
            {
                var r = AvailResult.Fail("no_wood");
                r.Params["need"] = c.WoodCost;
                r.Params["have"] = c.Wood;
                r.Params["short"] = c.WoodCost - c.Wood;
                return r;
            }
            return AvailResult.Pass();
        }

        private static bool Contains(string[] arr, string id)
        {
            if (arr == null) return false;
            for (int i = 0; i < arr.Length; i++)
            {
                if (arr[i] == id) return true;
            }
            return false;
        }
    }
}
