using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>
    /// 单兵模式专属旋钮（`Content/data/squad.json`）的唯一读取点。
    ///
    /// 为什么单独一层：这些值既不是关卡数值（不随关卡变），也不是规划数值（不属于 CP/人口），
    /// 而是"战场这一套玩法"的全局口味。散在各处读 JSON 迟早出现两套默认值。
    /// </summary>
    public sealed class SquadTuning
    {
        /// <summary>
        /// 一名单兵停在敌区里每秒给敌方基地造成的伤害（覆盖 levels.json 的 lane 值）。
        /// 单兵制：0.24 / 人 / 秒 → 10 个人站住 ≈ 2.4 DPS，把 72 血的基地拆完约 30 秒。
        /// </summary>
        public double ZoneDpsPerUnit = 0.24;

        /// <summary>中立据点：占领要多少 CP；enabled=false 表示这张底壳没有据点。</summary>
        public int OutpostCpCost = 5;
        public bool OutpostEnabled = true;

        /// <summary>据点/主堡免费防守兵：防守战开始时白送几名（不占 CP/人口）。</summary>
        public bool FreeDefendEnabled = true;
        public string FreeDefendUnit = "alliance_footman";
        public int FreeDefendStar = 1;
        /// <summary>白送几名 —— 单兵制下的数量，不是"几队"。</summary>
        public int FreeDefendCount = 3;

        public static SquadTuning FromDict(IDictionary<string, object> d)
        {
            var t = new SquadTuning();
            if (d == null) return t;
            t.ZoneDpsPerUnit = JVal.Double(d, "zone_dps_per_unit",
                JVal.Double(d, "zone_dps_per_squad", t.ZoneDpsPerUnit));

            var outpost = JVal.Dict(d, "outpost");
            if (outpost != null)
            {
                t.OutpostEnabled = JVal.Bool(outpost, "enabled", t.OutpostEnabled);
                t.OutpostCpCost = JVal.Int(outpost, "cp_cost", t.OutpostCpCost);
            }

            var free = JVal.Dict(d, "free_defend");
            if (free != null)
            {
                t.FreeDefendEnabled = JVal.Bool(free, "enabled", t.FreeDefendEnabled);
                t.FreeDefendUnit = JVal.Str(free, "unit", t.FreeDefendUnit);
                t.FreeDefendStar = JVal.Int(free, "star", t.FreeDefendStar);
                t.FreeDefendCount = JVal.Int(free, "count", t.FreeDefendCount);
            }
            return t;
        }

        public List<string> Validate(UnitCatalog units)
        {
            var errors = new List<string>();
            if (ZoneDpsPerUnit <= 0.0)
                errors.Add($"squad.json：zone_dps_per_unit={ZoneDpsPerUnit} 必须 > 0");
            if (ZoneDpsPerUnit > 2.0)
                errors.Add($"squad.json：zone_dps_per_unit={ZoneDpsPerUnit} 过大（单兵制下应在 0.1~0.5）");
            if (OutpostCpCost < 0) errors.Add($"squad.json：outpost.cp_cost={OutpostCpCost} 不能为负");
            if (FreeDefendEnabled)
            {
                UnitDef def = units != null ? units.Get(FreeDefendUnit) : null;
                if (def == null) errors.Add($"squad.json：free_defend.unit={FreeDefendUnit} 未定义");
                else if (!def.Enabled) errors.Add($"squad.json：free_defend.unit={FreeDefendUnit} 已禁用");
                if (FreeDefendCount < 1 || FreeDefendCount > 12)
                    errors.Add($"squad.json：free_defend.count={FreeDefendCount} 越界（1..12）");
            }
            if (FreeDefendStar < 1 || FreeDefendStar > 3)
                errors.Add($"squad.json：free_defend.star={FreeDefendStar} 越界（1..3）");
            return errors;
        }
    }
}
