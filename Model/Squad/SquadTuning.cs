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

        // =================================================================
        // 2026-11-24 运动学（Phase 1）：布阵 + 分离几何 + 朝向
        // =================================================================
        /// <summary>同排相邻两人的中心距（游戏数值，默认 96 = 1.44 m）。</summary>
        public double FilePitch = FormationPlan.FilePitchDefault;
        /// <summary>相邻两排的中心距（游戏数值，默认 144 = 2.16 m）。</summary>
        public double RankPitch = FormationPlan.RankPitchDefault;
        /// <summary>近战线最后一排 → 远程线第一排的额外间距（游戏数值，默认 240 = 3.60 m）。</summary>
        public double LineGap = FormationPlan.LineGapDefault;
        /// <summary>战场单排人数上限（偶数，默认 24）。</summary>
        public int MaxFiles = FormationPlan.MaxFilesDefault;
        /// <summary>棋盘格内出生位的单排人数（默认 4，保证 7 m 格内放得下）。</summary>
        public int TileFiles = FormationPlan.TileFilesDefault;
        /// <summary>硬核 = 身位和 × 该系数；0.90 表示允许 10% 贴身重叠。</summary>
        public double HardCoreFactor = 0.90;
        /// <summary>停火线 = 射程 × 该系数；必须 &lt; 1.0（开火线是射程 + 4）。</summary>
        public double StandOffRatio = 0.92;
        /// <summary>转向速度（度/秒，默认 540）。</summary>
        public double TurnRateDeg = 540.0;
        /// <summary>朝向死区（度，默认 6）：差值小于它就不转，防止微抖。</summary>
        public double FacingDeadzoneDeg = 6.0;

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

            var formation = JVal.Dict(d, "formation");
            if (formation != null)
            {
                t.FilePitch = JVal.Double(formation, "file_pitch", t.FilePitch);
                t.RankPitch = JVal.Double(formation, "rank_pitch", t.RankPitch);
                t.LineGap = JVal.Double(formation, "line_gap", t.LineGap);
                t.MaxFiles = JVal.Int(formation, "max_files", t.MaxFiles);
                t.TileFiles = JVal.Int(formation, "tile_files", t.TileFiles);
            }

            var combat = JVal.Dict(d, "combat");
            if (combat != null)
            {
                t.HardCoreFactor = JVal.Double(combat, "hard_core_factor", t.HardCoreFactor);
                t.StandOffRatio = JVal.Double(combat, "stand_off_ratio", t.StandOffRatio);
                t.TurnRateDeg = JVal.Double(combat, "turn_rate_deg", t.TurnRateDeg);
                t.FacingDeadzoneDeg = JVal.Double(combat, "facing_deadzone_deg", t.FacingDeadzoneDeg);
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

            if (FilePitch < 48.0 || FilePitch > 240.0)
                errors.Add($"squad.json：formation.file_pitch={FilePitch} 越界（48..240）");
            if (RankPitch < 72.0 || RankPitch > 360.0)
                errors.Add($"squad.json：formation.rank_pitch={RankPitch} 越界（72..360）");
            if (LineGap < 0.0 || LineGap > 960.0)
                errors.Add($"squad.json：formation.line_gap={LineGap} 越界（0..960）");
            if (MaxFiles < 2 || MaxFiles > 64)
                errors.Add($"squad.json：formation.max_files={MaxFiles} 越界（2..64）");
            if (TileFiles < 2 || TileFiles > 12)
                errors.Add($"squad.json：formation.tile_files={TileFiles} 越界（2..12）");
            if (HardCoreFactor < 0.80 || HardCoreFactor >= 1.0)
                errors.Add($"squad.json：combat.hard_core_factor={HardCoreFactor} 越界（0.80..0.99）");
            if (StandOffRatio < 0.80 || StandOffRatio >= 1.0)
                errors.Add($"squad.json：combat.stand_off_ratio={StandOffRatio} 越界（0.80..0.99）");
            if (TurnRateDeg < 90.0 || TurnRateDeg > 1440.0)
                errors.Add($"squad.json：combat.turn_rate_deg={TurnRateDeg} 越界（90..1440）");
            if (FacingDeadzoneDeg < 0.0 || FacingDeadzoneDeg > 45.0)
                errors.Add($"squad.json：combat.facing_deadzone_deg={FacingDeadzoneDeg} 越界（0..45）");
            if (FilePitch < RankPitch * 0.5)
                errors.Add($"squad.json：file_pitch={FilePitch} 小于 rank_pitch 的一半，排内会挤成一列");
            return errors;
        }
    }
}
