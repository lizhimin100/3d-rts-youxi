using System;
using System.Collections.Generic;
using Vec2 = System.Numerics.Vector2;

namespace WarIsland.Model
{
    /// <summary>
    /// 单场战斗（BattleSession）—— 一轮一个实例，输入 ArmyPlan，输出 RoundResult。
    ///
    /// 与棋盘**不共享坐标/实体**：战场是 levels.json 的 battlefield 矩形，
    /// 双方从各自部署线直接对冲（March → Engage），不读格子、不建建筑。
    ///
    /// 唯一的战斗内核仍然是 <see cref="BattleSim"/>：
    ///   · 这里只做"把 ArmyPlan 摆到部署线 + 排敌方波次 + 45 秒狂暴 + 60 秒结算"；
    ///   · 伤害/克制/分离/朝向全部在内核里，不在这里重写。
    /// </summary>
    public static class BattleSession
    {
        public static RoundResult Run(
            UnitCatalog units,
            CombatRules rules,
            PlanningConfig planning,
            BattleArena arena,
            LevelDef level,
            LevelRound round,
            int roundIndex,
            ArmyPlan plan,
            double playerBaseHp,
            double enemyBaseHp,
            int seed,
            BattleTuning tuning)
        {
            if (units == null) throw new ArgumentNullException(nameof(units));
            if (rules == null) throw new ArgumentNullException(nameof(rules));
            if (planning == null) throw new ArgumentNullException(nameof(planning));
            if (arena == null) throw new ArgumentNullException(nameof(arena));
            if (level == null) throw new ArgumentNullException(nameof(level));
            tuning = tuning ?? new BattleTuning();
            plan = plan ?? new ArmyPlan();

            var battle = new BattleSim(units, rules, arena, planning, seed, tuning);
            battle.SetBaseHp(playerBaseHp, enemyBaseHp);
            battle.SetArmyModifiers(plan.Modifiers);
            SpawnArmy(battle, plan, level, tuning, arena);
            ScheduleEnemyWaves(battle, round, level, arena);

            double seconds = level.RoundSeconds > 0.0 ? level.RoundSeconds : LevelDef.RoundSecondsSpec;
            battle.Run(seconds);
            bool timeUp = battle.Time >= seconds - 0.06;
            battle.Finish(timeUp ? "time" : "wipe");
            return RoundResolver.Settle(roundIndex, round != null ? round.Label : "", battle,
                tuning, playerBaseHp, enemyBaseHp, timeUp);
        }

        /// <summary>
        /// 把 ArmyPlan 摆到玩家部署线：近战在前、远程在后（按 projectile 分类），
        /// 中轴向外对称、超宽折行；棋盘哨塔投射到部署线后方两翼。
        /// 只写位置与指令，不改任何战斗数值。
        /// </summary>
        public static void SpawnArmy(
            BattleSim battle,
            ArmyPlan plan,
            LevelDef level,
            BattleTuning tuning,
            BattleArena arena)
        {
            if (battle == null || plan == null || level == null || arena == null) return;
            tuning = tuning ?? new BattleTuning();
            Battlefield bf = level.Battlefield ?? new Battlefield();
            UnitCatalog units = battle.Units;

            int files = FormationPlan.FilesForWidth(bf.Width, bf.Edge, tuning.FilePitch, tuning.MaxFiles);
            double frontX = bf.DeployPlayer;
            double frontZ = 0.0;
            int dirX = -1; // 玩家排向自家后方（-X）延伸

            int meleeCount = 0;
            foreach (ArmyUnit u in plan.Units)
            {
                UnitDef def = units.Get(u.UnitId);
                if (def == null || !def.Enabled) continue;
                if (FormationPlan.LineOf(def) == UnitLine.Melee) meleeCount += Math.Max(u.Count, 1);
            }
            int meleeRanks = FormationPlan.Ranks(meleeCount, files);
            int slotMelee = 0;
            int slotRanged = 0;
            Vec2 goal = arena.LaneToWorld(bf.DeployEnemy, 0.0);

            foreach (ArmyUnit u in plan.Units)
            {
                UnitDef def = units.Get(u.UnitId);
                if (def == null || !def.Enabled) continue;
                UnitLine line = FormationPlan.LineOf(def);
                int count = Math.Max(u.Count, 1);
                ModifierSet mods = plan.Modifiers.ForSource(u.SourceBuilding, u.SourceTile);
                for (int k = 0; k < count; k++)
                {
                    int slot = line == UnitLine.Melee ? slotMelee++ : slotRanged++;
                    Vec2 lane = FormationPlan.BattleSlot(frontX, frontZ, dirX, line, slot, files, meleeRanks,
                        tuning.FilePitch, tuning.RankPitch, tuning.LineGap);
                    Vec2 world = arena.LaneToWorld(lane.X, lane.Y);
                    int id = battle.AddUnit(0, def.Id, u.Star, world.X, world.Y,
                        u.SourceBuilding, u.SourceTile, mods);
                    if (id > 0) battle.OrderMarch(id, goal.X, goal.Y);
                }
            }

            // 棋盘哨塔：部署线后方两翼（静止、可被摧毁、不贡献基地伤害）
            // 放在敌方阵线宽度之内（files/2 - 1），否则两翼会落在敌人行军带之外、整场零输出。
            double flankZ = Math.Max(files * 0.5 - 1.0, 1.0) * tuning.FilePitch;
            foreach (ArmyUnit t in plan.Towers)
            {
                UnitDef def = units.Get(t.UnitId);
                if (def == null || !def.Enabled || !def.Static) continue;
                int count = Math.Max(t.Count, 1);
                ModifierSet mods = plan.Modifiers.ForSource(t.SourceBuilding, t.SourceTile);
                for (int k = 0; k < count; k++)
                {
                    int sideSign = (k % 2 == 0) ? 1 : -1;
                    int rank = k / 2;
                    double x = frontX - (rank + 1) * tuning.RankPitch;
                    double z = sideSign * (flankZ + rank * tuning.FilePitch);
                    Vec2 world = arena.LaneToWorld(x, z);
                    int id = battle.AddUnit(0, def.Id, t.Star, world.X, world.Y,
                        t.SourceBuilding, t.SourceTile, mods);
                    if (id > 0) battle.OrderHold(id);
                }
            }
        }

        /// <summary>把一轮的敌方波次排到敌方部署线（直线对冲，不走脊线）。</summary>
        public static void ScheduleEnemyWaves(BattleSim battle, LevelRound round, LevelDef level, BattleArena arena)
        {
            if (battle == null || round == null || level == null || arena == null) return;
            Battlefield bf = level.Battlefield ?? new Battlefield();
            Vec2 enemyFront = arena.LaneToWorld(bf.DeployEnemy, 0.0);
            for (int wi = 0; wi < round.Waves.Count; wi++)
                battle.ScheduleWaveAtLine(round.Waves[wi], 1, enemyFront.X, enemyFront.Y, 1, 0.0);
        }
    }
}
