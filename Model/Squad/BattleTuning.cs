using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>
    /// 战斗场景全局旋钮（`Content/data/squad.json`，Phase 3 再改名 battle.json）的唯一读取点。
    ///
    /// 2026-11-24 冻结后只剩三块：
    ///   · formation：自动布阵间距（全游戏数值）；
    ///   · combat：硬核/停火线/转向；
    ///   · berserk / settle：45 秒狂暴与 60 秒结算。
    /// 旧的 outpost / free_defend / zone_dps 已物理删除（占区抽血不再存在）。
    /// </summary>
    public sealed class BattleTuning
    {
        // ---- 布阵（游戏数值） ----
        public double FilePitch = FormationPlan.FilePitchDefault;
        public double RankPitch = FormationPlan.RankPitchDefault;
        public double LineGap = FormationPlan.LineGapDefault;
        public int MaxFiles = FormationPlan.MaxFilesDefault;
        public int TileFiles = FormationPlan.TileFilesDefault;

        // ---- 战斗几何 ----
        public double HardCoreFactor = 0.90;
        public double StandOffRatio = 0.92;
        public double TurnRateDeg = 540.0;
        public double FacingDeadzoneDeg = 6.0;

        // ---- 45 秒狂暴（防纯肉盾互刮拖满 60 秒） ----
        public double BerserkStartSeconds = 45.0;
        public double BerserkAttackSpeedMult = 2.0;
        public bool BerserkArmorZero = true;

        // ---- 结算 ----
        public int BaseDamageCap = 48;

        public static BattleTuning FromDict(IDictionary<string, object> d)
        {
            var t = new BattleTuning();
            if (d == null) return t;

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

            var berserk = JVal.Dict(d, "berserk");
            if (berserk != null)
            {
                t.BerserkStartSeconds = JVal.Double(berserk, "start_seconds", t.BerserkStartSeconds);
                t.BerserkAttackSpeedMult = JVal.Double(berserk, "attack_speed_mult", t.BerserkAttackSpeedMult);
                t.BerserkArmorZero = JVal.Bool(berserk, "armor_zero", t.BerserkArmorZero);
            }

            var settle = JVal.Dict(d, "settle");
            if (settle != null)
            {
                t.BaseDamageCap = JVal.Int(settle, "base_damage_cap", t.BaseDamageCap);
            }
            return t;
        }

        public List<string> Validate(UnitCatalog units)
        {
            var errors = new List<string>();
            if (FilePitch < 48.0 || FilePitch > 240.0)
                errors.Add($"battle.json：formation.file_pitch={FilePitch} 越界（48..240）");
            if (RankPitch < 72.0 || RankPitch > 360.0)
                errors.Add($"battle.json：formation.rank_pitch={RankPitch} 越界（72..360）");
            if (LineGap < 0.0 || LineGap > 960.0)
                errors.Add($"battle.json：formation.line_gap={LineGap} 越界（0..960）");
            if (MaxFiles < 2 || MaxFiles > 64)
                errors.Add($"battle.json：formation.max_files={MaxFiles} 越界（2..64）");
            if (TileFiles < 2 || TileFiles > 12)
                errors.Add($"battle.json：formation.tile_files={TileFiles} 越界（2..12）");
            if (HardCoreFactor < 0.80 || HardCoreFactor >= 1.0)
                errors.Add($"battle.json：combat.hard_core_factor={HardCoreFactor} 越界（0.80..0.99）");
            if (StandOffRatio < 0.80 || StandOffRatio >= 1.0)
                errors.Add($"battle.json：combat.stand_off_ratio={StandOffRatio} 越界（0.80..0.99）");
            if (TurnRateDeg < 90.0 || TurnRateDeg > 1440.0)
                errors.Add($"battle.json：combat.turn_rate_deg={TurnRateDeg} 越界（90..1440）");
            if (FacingDeadzoneDeg < 0.0 || FacingDeadzoneDeg > 45.0)
                errors.Add($"battle.json：combat.facing_deadzone_deg={FacingDeadzoneDeg} 越界（0..45）");
            if (FilePitch < RankPitch * 0.5)
                errors.Add($"battle.json：file_pitch={FilePitch} 小于 rank_pitch 的一半，排内会挤成一列");

            if (BerserkStartSeconds < 30.0 || BerserkStartSeconds > LevelDef.RoundSecondsSpec - 5.0)
                errors.Add($"battle.json：berserk.start_seconds={BerserkStartSeconds} 越界（30..{LevelDef.RoundSecondsSpec - 5:0}）");
            if (BerserkAttackSpeedMult < 1.0 || BerserkAttackSpeedMult > 4.0)
                errors.Add($"battle.json：berserk.attack_speed_mult={BerserkAttackSpeedMult} 越界（1..4）");
            if (BaseDamageCap < 1 || BaseDamageCap > 200)
                errors.Add($"battle.json：settle.base_damage_cap={BaseDamageCap} 越界（1..200）");

            // 近战可达性：逐个近战检查"它 vs 场上最大身位"的硬核必须小于自己的射程。
            // 不能用 2×最大身位（两个最大单位互撞的极端）——那会把小鱼人奴隶误判成够不着。
            if (units != null)
            {
                double maxRadius = 0.0;
                foreach (UnitDef u in units.All)
                {
                    if (!u.Enabled) continue;
                    double r = UnitBody.BodyUnits(u);
                    if (r > maxRadius) maxRadius = r;
                }
                foreach (UnitDef a in units.All)
                {
                    if (!a.Enabled || a.Projectile || a.AttackRange <= 0.0) continue;
                    double need = (UnitBody.BodyUnits(a) + maxRadius) * HardCoreFactor;
                    if (need >= a.AttackRange)
                    {
                        errors.Add($"battle.json：{a.Id} 的硬核 {need:0.0} ≥ 射程 {a.AttackRange:0}（近战会够不着）");
                        break;
                    }
                }
            }
            return errors;
        }
    }
}
