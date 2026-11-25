using Godot;
using System;
using System.Collections.Generic;
using WarIsland.Model;
using Vec2 = System.Numerics.Vector2;

namespace WarIsland.Bridge
{
    /// <summary>
    /// Model ⇄ GDScript 的**唯一桥**（由 Game/adapters/桥.gd 懒建，不用自动加载）。
    ///
    /// 规矩：
    ///   · 这里是唯一允许 `using Godot` 的 Model 调用面；`Model/` 本身零 Godot 引用；
    ///   · 只做三件事：把 Variant 拆成纯 .NET 值、调 Model、把结果装回 Variant；
    ///   · 不写第二份公式 —— 任何"算一下"都必须落到 WarIsland.Model。
    ///
    /// GDScript 侧统一通过 `Game/adapters/*.gd` 调用，不直接摸 Mdl。
    /// </summary>
    [GlobalClass]
    public partial class ModelBridge : RefCounted
    {
        // =================================================================
        // 距离铁律
        // =================================================================
        public double R1() => RtsUnits.R1;

        public double ToMeters(double units) => RtsUnits.ToMeters(units);

        public double ToUnits(double meters) => RtsUnits.ToUnits(meters);

        // =================================================================
        // 数据 / 公式探针（--check 用；调用真实内核，不在检查里重推公式）
        // =================================================================
        /// <summary>四张数据表的校验（units / combat / planning / levels）。</summary>
        public Godot.Collections.Dictionary DataValidate(
            Godot.Collections.Dictionary unitsDict,
            Godot.Collections.Dictionary combatDict,
            Godot.Collections.Dictionary planningDict,
            Godot.Collections.Dictionary levelsDict)
        {
            var notes = new List<string>();
            var rules = CombatRules.FromDict(ToPlainDict(combatDict));
            var units = UnitCatalog.FromDict(ToPlainDict(unitsDict), rules, notes);
            var planning = PlanningConfig.FromDict(ToPlainDict(planningDict), units, notes);
            var levels = LevelSet.FromDict(ToPlainDict(levelsDict), units, notes);
            var errors = new List<string>();
            errors.AddRange(notes);
            errors.AddRange(rules.Validate());
            errors.AddRange(units.Validate());
            errors.AddRange(planning.Validate(units));
            errors.AddRange(levels.Validate(units));
            var ids = new Godot.Collections.Array();
            foreach (LevelDef lv in levels.Levels) ids.Add(lv.Id);
            return new Godot.Collections.Dictionary
            {
                { "ok", errors.Count == 0 },
                { "errors", ToGodotArray(errors) },
                { "levels", ids },
                { "units", units.All.Count },
                { "cards", planning.Cards.Count },
                { "round_seconds", LevelDef.RoundSecondsSpec },
            };
        }

        /// <summary>
        /// 靶子模拟器（数据工作台「单位」页用）：给一组攻/防参数，返回期望伤害 / DPS / 各步中间量。
        /// 中间量全部由 <see cref="CombatCalculator"/> 提供，桥不重算公式。
        /// </summary>
        public Godot.Collections.Dictionary CombatExpect(
            Godot.Collections.Dictionary attacker,
            Godot.Collections.Dictionary defender,
            Godot.Collections.Dictionary rulesDict)
        {
            var rules = CombatRules.FromDict(ToPlainDict(rulesDict));
            CombatAttacker a = ParseAttacker(attacker);
            CombatDefender d = ParseDefender(defender);
            double effArmor = CombatCalculator.EffectiveArmor(
                d.Armor * (d.ArmorMult > 0.0 ? d.ArmorMult : 1.0), a.ArmorPenPct, a.ArmorPenFlat);
            return new Godot.Collections.Dictionary
            {
                { "damage", CombatCalculator.ExpectedDamage(a, d, rules) },
                { "dps", CombatCalculator.ExpectedDps(a, d, rules) },
                { "hit_chance", CombatCalculator.HitChance(a.Hit, d.Dodge) },
                { "effective_armor", effArmor },
                { "armor_taken", CombatCalculator.ArmorDamageTaken(effArmor, rules) },
                { "counter", CombatCalculator.CounterMultiplier(rules, a.AttackType, d.ArmorType) },
            };
        }


        /// <summary>
        /// 六步伤害的唯一实现探针（命中 → 暴击 → 穿透 → 承伤 → 克制 → 取整）。
        /// 检查只喂输入、读输出，绝不在这里重算一遍。
        /// </summary>
        public Godot.Collections.Dictionary CombatProbe(
            double damage, int attackType, double armor, int armorType,
            Godot.Collections.Dictionary rulesDict, double rollHit, double rollCrit,
            double dodge = 0.0)
        {
            var rules = CombatRules.FromDict(ToPlainDict(rulesDict));
            var atk = new CombatAttacker
            {
                Damage = damage,
                Cooldown = 1.0,
                AttackType = attackType,
                Hit = 100.0,
                CritChance = 0.0,
                CritMultiplier = 0.0,
            };
            var def = new CombatDefender
            {
                Armor = armor,
                ArmorType = armorType,
                Dodge = dodge,
                ArmorMult = 1.0,
                DamageTakenMult = 1.0,
            };
            DamageBreakdown r = CombatCalculator.Compute(atk, def, rules, rollHit, rollCrit);
            return new Godot.Collections.Dictionary
            {
                { "ok", true },
                { "hit", r.Hit },
                { "crit", r.Crit },
                { "damage", r.Damage },
            };
        }

        // =================================================================
        // 2026-11-21 真小队：编制 / 脊线寻路 / 队级指令 / 100 局推演
        // =================================================================
        private readonly Dictionary<int, SquadSession> _squadSessions = new Dictionary<int, SquadSession>();
        private int _nextSquadHandle = 1;

        /// <summary>建一个"规划 + 执行"的小队会话；返回 { ok, handle, errors, arena }。</summary>
        public Godot.Collections.Dictionary SquadSessionNew(
            Godot.Collections.Dictionary unitsDict,
            Godot.Collections.Dictionary combatDict,
            Godot.Collections.Dictionary planningDict,
            Godot.Collections.Dictionary levelDict,
            Godot.Collections.Dictionary shellDict,
            Godot.Collections.Dictionary layoutDict,
            Godot.Collections.Dictionary encounterDict,
            Godot.Collections.Dictionary tuningDict,
            int seed,
            bool instantTrain)
        {
            var notes = new List<string>();
            var rules = CombatRules.FromDict(ToPlainDict(combatDict));
            var units = UnitCatalog.FromDict(ToPlainDict(unitsDict), rules, notes);
            var planning = PlanningConfig.FromDict(ToPlainDict(planningDict), units, notes);
            var arena = SquadArena.FromDict(
                ToPlainDict(levelDict), ToPlainDict(shellDict), ToPlainDict(layoutDict),
                ToPlainDict(encounterDict), units, ToPlainDict(tuningDict));

            var errors = new List<string>();
            errors.AddRange(notes);
            errors.AddRange(rules.Validate());
            errors.AddRange(units.Validate());
            errors.AddRange(planning.Validate(units));
            errors.AddRange(arena.Validate(units));
            errors.AddRange(SquadTuning.FromDict(ToPlainDict(tuningDict)).Validate(units));
            if (errors.Count > 0)
            {
                return new Godot.Collections.Dictionary
                {
                    { "ok", false },
                    { "handle", 0 },
                    { "errors", ToGodotArray(errors) },
                };
            }

            var session = new SquadSession(units, rules, planning, arena, seed, instantTrain,
                -1.0, -1.0, ToPlainDict(tuningDict));
            int handle = _nextSquadHandle++;
            _squadSessions[handle] = session;
            return new Godot.Collections.Dictionary
            {
                { "ok", true },
                { "handle", handle },
                { "errors", new Godot.Collections.Array() },
                { "arena", ArenaInfoDict(arena) },
                { "instant_train", instantTrain },
            };
        }

        public void SquadSessionFree(int handle)
        {
            _squadSessions.Remove(handle);
        }

        private SquadSession Session(int handle)
        {
            _squadSessions.TryGetValue(handle, out SquadSession session);
            return session;
        }

        public Godot.Collections.Dictionary SquadSessionBeginPlanning(int handle)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            session.BeginPlanning();
            return OkState(session);
        }

        public Godot.Collections.Dictionary SquadSessionTrain(int handle, string cardId)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            int n = session.PlayTrainCard(cardId);
            var d = OkState(session);
            d["produced"] = n;
            return d;
        }

        /// <summary>打建造牌并落到指定战术格子（tile=0 = 自动挑第一块空格）。</summary>
        public Godot.Collections.Dictionary SquadSessionBuild(int handle, string cardId, int tile)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            bool ok = session.PlayBuildCardAt(cardId, tile);
            var d = OkState(session);
            d["built"] = ok;
            d["tile"] = tile;
            return d;
        }

        /// <summary>规划期还能放建筑的玩家格子（HUD 高亮/自检口径）。</summary>
        public Godot.Collections.Array SquadSessionFreeTiles(int handle)
        {
            var arr = new Godot.Collections.Array();
            var session = Session(handle);
            if (session == null) return arr;
            foreach (int t in session.FreePlayerTiles()) arr.Add(t);
            return arr;
        }

        /// <summary>买下中立据点（规划期动作；只花 CP，不动人口）。</summary>
        public Godot.Collections.Dictionary SquadSessionCaptureOutpost(int handle)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            bool ok = session.CaptureOutpost();
            var d = OkState(session);
            d["captured"] = ok;
            return d;
        }

        public Godot.Collections.Dictionary SquadSessionAttack(int handle)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            session.BeginAttack();
            return OkState(session);
        }

        public Godot.Collections.Dictionary SquadSessionDefend(int handle)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            session.BeginDefend();
            return OkState(session);
        }

        public Godot.Collections.Dictionary SquadSessionEndRound(int handle)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            session.EndRound();
            return OkState(session);
        }

        /// <summary>打一张策略牌（只影响本轮）。</summary>
        public Godot.Collections.Dictionary SquadSessionStrategy(int handle, string cardId)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            bool ok = session.Match.PlayStrategy(cardId);
            var d = OkState(session);
            d["played"] = ok;
            return d;
        }

        public Godot.Collections.Dictionary SquadSessionEndPlanning(int handle)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            session.EndPlanning(true);
            return OkState(session);
        }

        public Godot.Collections.Dictionary SquadSessionBeginExecution(int handle, int roundIndex)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            session.BeginExecution(roundIndex);
            return OkState(session);
        }

        public Godot.Collections.Dictionary SquadSessionState(int handle)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            return OkState(session);
        }

        private static Godot.Collections.Dictionary Err(string msg)
        {
            return new Godot.Collections.Dictionary
            {
                { "ok", false },
                { "error", msg },
            };
        }

        private static Godot.Collections.Dictionary OkState(SquadSession session)
        {
            SquadSessionState st = session.State();
            var cards = new Godot.Collections.Array();
            foreach (SquadTrainEntry c in st.TrainCards)
            {
                cards.Add(new Godot.Collections.Dictionary
                {
                    { "card_id", c.CardId },
                    { "display_name", c.DisplayName },
                    { "unit_id", c.UnitId },
                    { "unit_name", c.UnitName },
                    { "tag", c.Tag },
                    { "role", c.Role },
                    { "cost_cp", c.CostCp },
                    { "units", c.Units },
                    { "buildings", c.Buildings },
                    { "in_hand", c.InHand },
                    { "available", c.Available },
                    { "reason", c.Reason },
                });
            }
            return new Godot.Collections.Dictionary
            {
                { "ok", true },
                { "phase", st.Phase },
                { "round_kind", st.RoundKind },
                { "attack_squads", st.AttackSquads },
                { "defend_squads", st.DefendSquads },
                { "outpost_captured", st.OutpostCaptured },
                { "outpost_available", st.OutpostAvailable },
                { "outpost_cp_cost", st.OutpostCpCost },
                { "planning_index", st.PlanningIndex },
                { "cp", st.Cp },
                { "cp_start", st.CpStart },
                { "cp_cap", st.CpCap },
                { "pop_used", st.PopUsed },
                { "pop_cap", st.PopCap },
                { "pop_blocked", st.PopBlocked },
                { "army_squads", st.ArmySquads },
                { "army_models", st.ArmyModels },
                { "train_count_mult", st.TrainCountMult },
                { "draw_pile", st.DrawPile },
                { "discard_pile", st.DiscardPile },
                { "hand_count", st.HandCount },
                { "hand", ToGodotArray(st.Hand) },
                { "train_cards", cards },
                { "log", ToGodotArray(st.Log) },
                // 2026-11-24：单轮死斗
                { "rounds_played", st.RoundsPlayed },
                { "outcome", st.Outcome },
                { "player_base_hp", st.PlayerBaseHp },
                { "enemy_base_hp", st.EnemyBaseHp },
                { "defeat_record", st.DefeatRecord },
            };
        }

        public Godot.Collections.Dictionary SquadStep(int handle, double dt)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            session.Battle.Step(dt);
            return new Godot.Collections.Dictionary
            {
                { "ok", true },
                { "time", Math.Round(session.Battle.Time * 100.0) / 100.0 },
                { "finished", session.Battle.Finished },
                { "outcome", session.Battle.Outcome },
            };
        }

        /// <summary>小队战场快照（世界坐标，米）。</summary>
        public Godot.Collections.Dictionary SquadView(int handle)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            SquadBattleView view = session.Battle.View(true);
            var squads = new Godot.Collections.Array();
            foreach (SquadView s in view.Squads)
            {
                var members = new Godot.Collections.Array();
                foreach (SquadMemberView m in s.Members)
                {
                    members.Add(new Godot.Collections.Dictionary
                    {
                        { "index", m.Index },
                        { "x", m.X },
                        { "z", m.Z },
                        { "hp", m.Hp },
                        { "max_hp", m.MaxHp },
                        { "alive", m.Alive },
                        { "slot_x", m.SlotX },
                        { "slot_z", m.SlotZ },
                        { "slot_error", Math.Round(m.SlotError, 3) },
                    });
                }
                squads.Add(new Godot.Collections.Dictionary
                {
                    { "id", s.Id },
                    { "side", s.Side },
                    { "unit_id", s.UnitId },
                    { "display_name", s.DisplayName },
                    { "star", s.Star },
                    { "x", s.X },
                    { "z", s.Z },
                    { "heading", s.Heading },
                    { "hp", s.Hp },
                    { "max_hp", s.MaxHp },
                    { "alive_count", s.AliveCount },
                    { "member_count", s.MemberCount },
                    { "order", s.Order },
                    { "target_squad", s.TargetSquad },
                    { "radius", s.Radius },
                    { "move_speed", s.MoveSpeed },
                    { "kills", s.Kills },
                    { "damage_dealt", s.DamageDealt },
                    { "spawn_tile", s.SpawnTile },
                    { "source_building", s.SourceBuilding },
                    { "role", s.Role },
                    { "active", s.Active },
                    { "engaged", s.Engaged },
                    { "age", s.Age },
                    { "body_radius", s.BodyRadius },
                    { "attack_cooldown", s.AttackCooldown },
                    { "members", members },
                });
            }
            return new Godot.Collections.Dictionary
            {
                { "ok", true },
                { "time", view.Time },
                { "finished", view.Finished },
                { "outcome", view.Outcome },
                { "player_hp", view.PlayerBaseHp },
                { "player_hp_max", view.PlayerBaseHpMax },
                { "enemy_hp", view.EnemyBaseHp },
                { "enemy_hp_max", view.EnemyBaseHpMax },
                { "squads", squads },
                { "stats", StatsDict(view.Stats) },
            };
        }

        private static Godot.Collections.Dictionary StatsDict(SquadBattleStats st)
        {
            if (st == null) return new Godot.Collections.Dictionary();
            return new Godot.Collections.Dictionary
            {
                { "player_damage", st.PlayerDamage },
                { "enemy_damage", st.EnemyDamage },
                { "player_kills", st.PlayerKills },
                { "enemy_kills", st.EnemyKills },
                { "player_models_lost", st.PlayerModelsLost },
                { "enemy_models_lost", st.EnemyModelsLost },
                { "player_squads_lost", st.PlayerSquadsLost },
                { "enemy_squads_lost", st.EnemySquadsLost },
                { "player_squads_spawned", st.PlayerSquadsSpawned },
                { "enemy_squads_spawned", st.EnemySquadsSpawned },
                { "player_zone_seconds", st.PlayerZoneSeconds },
                { "enemy_zone_seconds", st.EnemyZoneSeconds },
                { "player_max_zone", st.PlayerMaxZone },
                { "enemy_max_zone", st.EnemyMaxZone },
                { "stuck_events", st.StuckEvents },
                { "repaths", st.Repaths },
                { "slot_error_m", st.AvgSlotErrorMeters },
                { "path_length", st.AvgPathLength },
                { "first_contact", st.FirstContactSecond },
                { "player_by_unit", UnitStatsDict(st.PlayerByUnit) },
                { "enemy_by_unit", UnitStatsDict(st.EnemyByUnit) },
            };
        }

        private static Godot.Collections.Dictionary UnitStatsDict(Dictionary<string, SquadUnitStat> map)
        {
            var d = new Godot.Collections.Dictionary();
            foreach (var kv in map)
            {
                d[kv.Key] = new Godot.Collections.Dictionary
                {
                    { "squads", kv.Value.Squads },
                    { "models", kv.Value.Models },
                    { "kills", kv.Value.Kills },
                    { "losses", kv.Value.Losses },
                    { "damage", kv.Value.Damage },
                    { "dps_member", kv.Value.DpsPerMember },
                    { "dps_squad", kv.Value.DpsPerSquad },
                };
            }
            return d;
        }

        /// <summary>点选整队（世界米）。side -1 = 不限；返回 squad id，-1 = 没点到。</summary>
        public int SquadPickWorld(int handle, double worldX, double worldZ, int side, double slack)
        {
            var session = Session(handle);
            if (session == null) return -1;
            return session.Battle.PickSquad(worldX, worldZ, side, slack);
        }

        /// <summary>框选整队（世界米）→ squad id 数组。</summary>
        public Godot.Collections.Array SquadBoxWorld(int handle, double x0, double z0, double x1, double z1, int side)
        {
            var session = Session(handle);
            var arr = new Godot.Collections.Array();
            if (session == null) return arr;
            foreach (int id in session.Battle.SquadsInRectWorld(x0, z0, x1, z1, side)) arr.Add(id);
            return arr;
        }

        /// <summary>对一组小队下指令：move / attack_move / hold / stop / attack。</summary>
        /// <summary>
        /// 玩家侧小队指令：**只接受 attack（集火）**。
        /// 2026-11-21 微操收敛：移动 / 攻击移动 / 停火 / 驻守从玩家手里移除，
        /// 推进与接敌交给自动战斗与预设偏好；这里返回 0 就是"这条指令玩家拨不动"。
        /// </summary>
        public int SquadOrder(int handle, Godot.Collections.Array ids, string order, double worldX, double worldZ, int targetSquad)
        {
            var session = Session(handle);
            if (session == null) return 0;
            var list = new List<int>();
            foreach (Variant v in ids) list.Add(v.AsInt32());
            return session.Battle.OrderPlayerMany(list, order, targetSquad);
        }

        /// <summary>玩家侧指令是否被白名单接受（界面用它决定回执文案，不猜）。</summary>
        public bool SquadPlayerOrderAllowed(string order) => SquadBattle.IsPlayerMicroOrder(order);

        /// <summary>
        /// **AI / 预设偏好 / 推演**用的队级指令（Move / AttackMove / Hold / Stop 全通）。
        /// 不是玩家入口：玩家只能走 SquadOrder（只有集火）。自检用它对寻路/驻守做真验证。
        /// </summary>
        public int SquadAutoOrder(int handle, Godot.Collections.Array ids, string order, double worldX, double worldZ, int targetSquad)
        {
            var session = Session(handle);
            if (session == null) return 0;
            var list = new List<int>();
            foreach (Variant v in ids) list.Add(v.AsInt32());
            return session.Battle.OrderMany(list, order, worldX, worldZ, targetSquad);
        }

        /// <summary>时间倍率（1x / 2x）：只改推进速率，不改任何数值。</summary>
        public double SquadSetTimeScale(int handle, double scale)
        {
            var session = Session(handle);
            if (session == null) return 0.0;
            session.Battle.TimeScale = scale;
            return session.Battle.TimeScale;
        }

        public double SquadTimeScale(int handle)
        {
            var session = Session(handle);
            return session == null ? 0.0 : session.Battle.TimeScale;
        }

        /// <summary>直接生成一支小队（试玩初始阵容 / 自检用）；世界米。</summary>
        public int SquadSpawn(int handle, int side, string unitId, int star, double worldX, double worldZ)
        {
            var session = Session(handle);
            if (session == null) return -1;
            return session.Battle.AddSquad(side, unitId, star, worldX, worldZ);
        }

        public Godot.Collections.Dictionary SquadDebugPath(int handle, int squadId)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            var points = new Godot.Collections.Array();
            foreach (System.Numerics.Vector2 p in session.Battle.DebugPath(squadId))
            {
                var w = session.Battle.Arena.LaneToWorld(p.X, p.Y);
                points.Add(new Godot.Collections.Dictionary { { "x", w.X }, { "z", w.Y } });
            }
            return new Godot.Collections.Dictionary
            {
                { "ok", true },
                { "length", session.Battle.DebugPathLength(squadId) },
                { "length_m", session.Battle.DebugPathLength(squadId) * RtsUnits.R1 },
                { "points", points },
            };
        }

        /// <summary>战场几何（格子锚点 / 脊线 / 势力区），世界米。</summary>
        public Godot.Collections.Dictionary SquadArenaInfo(int handle)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            return ArenaInfoDict(session.Arena);
        }

        private static Godot.Collections.Dictionary ArenaInfoDict(SquadArena arena)
        {
            var ridge = new Godot.Collections.Array();
            foreach (System.Numerics.Vector2 p in arena.Route.Ridge)
            {
                var w = arena.LaneToWorld(p.X, p.Y);
                ridge.Add(new Godot.Collections.Dictionary { { "x", w.X }, { "z", w.Y } });
            }
            var tiles = new Godot.Collections.Array();
            foreach (TacticalTile t in arena.Tiles)
            {
                var spawn = t.SquadSpawnAnchorWorld();
                var build = t.BuildingAnchorWorld();
                tiles.Add(new Godot.Collections.Dictionary
                {
                    { "index", t.Index },
                    { "side", t.Side },
                    { "role", t.Role },
                    { "x", t.X },
                    { "z", t.Z },
                    { "w", t.Width },
                    { "d", t.Depth },
                    { "yaw", t.YawDeg },
                    { "terrain_y", t.TerrainY },
                    { "spawn_x", spawn.X },
                    { "spawn_z", spawn.Y },
                    { "building_x", build.X },
                    { "building_z", build.Y },
                });
            }
            var playerBuildings = new Godot.Collections.Array();
            foreach (ArenaBuilding b in arena.PlayerBuildings)
            {
                playerBuildings.Add(new Godot.Collections.Dictionary
                {
                    { "tile", b.Tile },
                    { "building", b.DefId },
                    { "star", b.Star },
                });
            }
            var enemyBuildings = new Godot.Collections.Array();
            foreach (ArenaBuilding b in arena.EnemyBuildings)
            {
                enemyBuildings.Add(new Godot.Collections.Dictionary
                {
                    { "tile", b.Tile },
                    { "building", b.DefId },
                    { "star", b.Star },
                });
            }
            var playerBase = arena.LaneToWorld(arena.PlayerBaseX, 0.0);
            var enemyBase = arena.LaneToWorld(arena.EnemyBaseX, 0.0);
            var pZone = arena.LaneToWorld(arena.PlayerZoneEnd, 0.0);
            var eZone = arena.LaneToWorld(arena.EnemyZoneStart, 0.0);
            var outpostStage = arena.OutpostStageWorld();
            var min = arena.LaneToWorld(arena.MinX, arena.MinY);
            var max = arena.LaneToWorld(arena.MaxX, arena.MaxY);
            return new Godot.Collections.Dictionary
            {
                { "id", arena.Id },
                { "display_name", arena.DisplayName },
                { "player_faction", arena.PlayerFaction },
                { "enemy_faction", arena.EnemyFaction },
                { "round_seconds", arena.RoundSeconds },
                { "rounds", RoundsDict(arena) },
                { "min_x", min.X },
                { "min_z", min.Y },
                { "max_x", max.X },
                { "max_z", max.Y },
                { "player_base_x", playerBase.X },
                { "player_base_z", playerBase.Y },
                { "enemy_base_x", enemyBase.X },
                { "enemy_base_z", enemyBase.Y },
                { "player_zone_x", pZone.X },
                { "enemy_zone_x", eZone.X },
                { "neutral_start_x", arena.NeutralStartWorldX },
                { "neutral_end_x", arena.NeutralEndWorldX },
                { "outpost_tile", arena.NeutralOutpostTile },
                { "outpost_x", outpostStage.X },
                { "outpost_z", outpostStage.Y },
                { "player_base_tile", arena.PlayerBaseTile },
                { "enemy_base_tile", arena.EnemyBaseTile },
                { "ridge", ridge },
                { "tiles", tiles },
                { "player_buildings", playerBuildings },
                { "enemy_buildings", enemyBuildings },
                { "zone_dps_per_unit", arena.ZoneDpsPerUnit },
            };
        }

        private static Godot.Collections.Array RoundsDict(SquadArena arena)
        {
            var arr = new Godot.Collections.Array();
            foreach (LevelRound r in arena.Rounds)
            {
                var waves = new Godot.Collections.Array();
                foreach (Wave w in r.Waves)
                {
                    int count = 0;
                    foreach (WaveSquad sq in w.Squads) count += Math.Max(sq.Count, 1);
                    waves.Add(new Godot.Collections.Dictionary { { "t", w.T }, { "count", count } });
                }
                arr.Add(new Godot.Collections.Dictionary
                {
                    { "kind", r.Kind },
                    { "label", r.Label },
                    { "waves", waves },
                });
            }
            return arr;
        }

        /// <summary>只校验小队战场（--check 的入口）。</summary>
        public Godot.Collections.Dictionary SquadArenaValidate(
            Godot.Collections.Dictionary unitsDict,
            Godot.Collections.Dictionary combatDict,
            Godot.Collections.Dictionary levelDict,
            Godot.Collections.Dictionary shellDict,
            Godot.Collections.Dictionary layoutDict,
            Godot.Collections.Dictionary encounterDict,
            Godot.Collections.Dictionary tuningDict)
        {
            var rules = CombatRules.FromDict(ToPlainDict(combatDict));
            var units = UnitCatalog.FromDict(ToPlainDict(unitsDict), rules, new List<string>());
            var arena = SquadArena.FromDict(
                ToPlainDict(levelDict), ToPlainDict(shellDict), ToPlainDict(layoutDict),
                ToPlainDict(encounterDict), units, ToPlainDict(tuningDict));
            var errors = new List<string>();
            errors.AddRange(rules.Validate());
            errors.AddRange(units.Validate());
            errors.AddRange(arena.Validate(units));
            return new Godot.Collections.Dictionary
            {
                { "ok", errors.Count == 0 },
                { "errors", ToGodotArray(errors) },
                { "ridge_points", arena.Route != null ? arena.Route.Ridge.Count : 0 },
                { "tiles", arena.Tiles.Count },
                { "player_buildings", arena.PlayerBuildings.Count },
                { "enemy_buildings", arena.EnemyBuildings.Count },
                { "zone_dps_per_unit", arena.ZoneDpsPerUnit },
                { "outpost_tile", arena.NeutralOutpostTile },
                { "deploy_player", arena.Battlefield.DeployPlayer },
                { "deploy_enemy", arena.Battlefield.DeployEnemy },
                { "battlefield_width", arena.Battlefield.Width },
                { "rounds", arena.Rounds.Count },
                { "size_x", arena.SizeX },
                { "size_z", arena.SizeZ },
            };
        }

        /// <summary>
        /// 逐兵种**单兵身位**探针（原「阵型探针」）。
        /// 小队编制已取消，所以这里不再报槽位，只报身位/导航半径与落点环是否避开左上角建筑位。
        /// </summary>
        public Godot.Collections.Dictionary UnitBodyProbe(
            Godot.Collections.Dictionary unitsDict,
            Godot.Collections.Dictionary combatDict)
        {
            var rules = CombatRules.FromDict(ToPlainDict(combatDict));
            var units = UnitCatalog.FromDict(ToPlainDict(unitsDict), rules, new List<string>());
            var rows = new Godot.Collections.Array();
            var errors = new List<string>();
            foreach (UnitDef u in units.All)
            {
                errors.AddRange(UnitBody.Validate(u));
                double body = UnitBody.BodyMeters(u);
                double nav = u.NavRadius;
                if (nav <= 0.0) errors.Add($"{u.Id}：导航半径必须 > 0");
                // 落点环：9 人时不许有人落在左上象限（建筑位）
                var ring = UnitBody.SpawnRing(9);
                int inBuilding = 0;
                foreach (System.Numerics.Vector2 p in ring)
                {
                    if (p.X < -0.30f && p.Y < -0.30f) inBuilding += 1;
                }
                if (inBuilding > 0) errors.Add($"{u.Id}：落点环有 {inBuilding} 个点落在左上建筑位");
                rows.Add(new Godot.Collections.Dictionary
                {
                    { "id", u.Id },
                    { "body_radius_m", body },
                    { "nav_radius_units", nav },
                    { "single_unit", true },
                    { "ring_points", ring.Count },
                    { "ring_in_building", inBuilding },
                });
            }
            return new Godot.Collections.Dictionary
            {
                { "ok", errors.Count == 0 },
                { "errors", ToGodotArray(errors) },
                { "rows", rows },
            };
        }

        /// <summary>
        /// 自动布阵探针：给 count 个人算棋盘出生位，返回两两最小中心距（游戏数值 / 米）。
        /// `bodyUnits` 是参考身位和（步兵 = 60）；判定用 MinDistance ≥ bodyUnits × hard_core。
        /// </summary>
        public Godot.Collections.Dictionary FormationProbe(
            int count,
            double bodyUnits,
            Godot.Collections.Dictionary squadDict)
        {
            var tuning = SquadTuning.FromDict(ToPlainDict(squadDict));
            int n = Math.Clamp(count, 2, 64);
            var pts = new List<System.Numerics.Vector2>(n);
            for (int i = 0; i < n; i++)
                pts.Add(FormationPlan.TileSlot(i, tuning.TileFiles, tuning.FilePitch, tuning.RankPitch));
            double min = double.MaxValue;
            for (int i = 0; i < n; i++)
            {
                for (int j = i + 1; j < n; j++)
                {
                    double dx = pts[i].X - pts[j].X;
                    double dy = pts[i].Y - pts[j].Y;
                    double d = Math.Sqrt(dx * dx + dy * dy);
                    if (d < min) min = d;
                }
            }
            double need = Math.Max(bodyUnits, 1.0) * tuning.HardCoreFactor;
            return new Godot.Collections.Dictionary
            {
                { "ok", min + 1e-6 >= need },
                { "points", n },
                { "min_distance_units", min },
                { "min_distance_m", min * RtsUnits.R1 },
                { "need_units", need },
                { "file_pitch", tuning.FilePitch },
                { "rank_pitch", tuning.RankPitch },
            };
        }

        /// <summary>100 局纯 Model 小队攻防推演（胜率 + DPS + 阵型/寻路指标）。</summary>
        /// <summary>
        /// Phase 2 规则自检（4×4 / base_damage / 竖列棋盘 / 单轮波次 / 狂暴 / 结算 / 跳字）+ 3 项反向验错。
        /// GDScript 侧只读 ok/checks/errors，不重写任何规则。
        /// </summary>
        public Godot.Collections.Dictionary Phase2SelfCheck(
            Godot.Collections.Dictionary unitsDict,
            Godot.Collections.Dictionary combatDict,
            Godot.Collections.Dictionary planningDict,
            Godot.Collections.Dictionary levelsDict,
            Godot.Collections.Dictionary shellsDict,
            Godot.Collections.Dictionary layoutsDict,
            Godot.Collections.Dictionary encountersDict,
            Godot.Collections.Dictionary tuningDict,
            string levelId)
        {
            var plainLevels = ToPlainDict(levelsDict);
            var levelRow = FindRow(plainLevels, "levels", levelId);
            if (levelRow == null)
            {
                return new Godot.Collections.Dictionary
                {
                    { "ok", false },
                    { "checks", 0 },
                    { "errors", ToGodotArray(new List<string> { "找不到关卡：" + levelId }) },
                    { "lines", new Godot.Collections.Array() },
                };
            }
            var asm = JValDict(levelRow, "assembly");
            var shell = asm != null ? FindRow(ToPlainDict(shellsDict), "shells", StrOf(asm, "shell")) : null;
            var layout = asm != null ? FindRow(ToPlainDict(layoutsDict), "layouts", StrOf(asm, "player_layout")) : null;
            if (shell == null || layout == null)
            {
                return new Godot.Collections.Dictionary
                {
                    { "ok", false },
                    { "checks", 0 },
                    { "errors", ToGodotArray(new List<string> { "关卡 assembly 缺底壳或布局卡" }) },
                    { "lines", new Godot.Collections.Array() },
                };
            }

            CheckReport report = Phase2Checks.Run(
                ToPlainDict(unitsDict), ToPlainDict(combatDict), ToPlainDict(planningDict),
                shell, layout, plainLevels, ToPlainDict(tuningDict), levelId, true);

            var lines = new Godot.Collections.Array();
            foreach (string line in report.Lines) lines.Add(line);
            return new Godot.Collections.Dictionary
            {
                { "ok", report.Ok },
                { "checks", report.Checks },
                { "errors", ToGodotArray(report.Errors) },
                { "lines", lines },
            };
        }

        public Godot.Collections.Dictionary SquadSimulate(
            Godot.Collections.Dictionary unitsDict,
            Godot.Collections.Dictionary combatDict,
            Godot.Collections.Dictionary planningDict,
            Godot.Collections.Dictionary levelsDict,
            Godot.Collections.Dictionary shellsDict,
            Godot.Collections.Dictionary layoutsDict,
            Godot.Collections.Dictionary encountersDict,
            Godot.Collections.Dictionary tuningDict,
            string levelId,
            int games,
            int seedBase)
        {
            var rules = CombatRules.FromDict(ToPlainDict(combatDict));
            var notes = new List<string>();
            var units = UnitCatalog.FromDict(ToPlainDict(unitsDict), rules, notes);
            var planning = PlanningConfig.FromDict(ToPlainDict(planningDict), units, notes);
            var levels = LevelSet.FromDict(ToPlainDict(levelsDict), units, notes);

            var errors = new List<string>();
            errors.AddRange(notes);
            errors.AddRange(rules.Validate());
            errors.AddRange(units.Validate());
            errors.AddRange(planning.Validate(units));
            errors.AddRange(levels.Validate(units));

            LevelDef level = levels.Get(levelId);
            if (level == null)
            {
                errors.Add("找不到关卡：" + levelId);
            }
            string shellId = "";
            string layoutId = "";
            string encounterId = "";
            if (level != null)
            {
                var lvDict = FindRow(ToPlainDict(levelsDict), "levels", levelId);
                var asm = JValDict(lvDict, "assembly");
                if (asm == null)
                {
                    errors.Add($"关卡 {levelId} 缺 assembly（底壳 / 布局卡 / 遭遇卡）");
                }
                else
                {
                    shellId = StrOf(asm, "shell");
                    layoutId = StrOf(asm, "player_layout");
                    encounterId = StrOf(asm, "enemy_encounter");
                }
            }
            var shell = FindRow(ToPlainDict(shellsDict), "shells", shellId);
            var layout = FindRow(ToPlainDict(layoutsDict), "layouts", layoutId);
            var encounter = FindRow(ToPlainDict(encountersDict), "encounters", encounterId);
            if (shell == null) errors.Add("找不到底壳：" + shellId);
            if (layout == null) errors.Add("找不到玩家布局卡：" + layoutId);
            if (encounter == null) errors.Add("找不到敌人遭遇卡：" + encounterId);

            if (errors.Count > 0)
            {
                return new Godot.Collections.Dictionary
                {
                    { "ok", false },
                    { "errors", ToGodotArray(errors) },
                };
            }

            var arena = SquadArena.FromDict(
                FindRow(ToPlainDict(levelsDict), "levels", levelId),
                shell, layout, encounter, units, ToPlainDict(tuningDict));
            errors.AddRange(arena.Validate(units));
            if (errors.Count > 0)
            {
                return new Godot.Collections.Dictionary
                {
                    { "ok", false },
                    { "errors", ToGodotArray(errors) },
                };
            }

            var sim = SquadSimulator.Run(units, rules, planning, arena, games, seedBase, ToPlainDict(tuningDict));
            var outDict = new Godot.Collections.Dictionary
            {
                { "ok", sim.Ok },
                { "errors", ToGodotArray(sim.Errors) },
                { "arena", sim.ArenaId },
                { "arena_name", sim.ArenaName },
                { "level", level.Id },
                { "games", sim.Games },
                { "seed_base", sim.SeedBase },
                { "wins", sim.Wins },
                { "losses", sim.Losses },
                { "draws", sim.Draws },
                { "win_rate", sim.WinRate },
                { "avg_player_hp", sim.AvgPlayerHp },
                { "avg_enemy_hp", sim.AvgEnemyHp },
                { "avg_player_hp_pct", sim.AvgPlayerHpPct },
                { "avg_seconds", sim.AvgSeconds },
                { "avg_player_squads", sim.AvgPlayerSquads },
                { "avg_enemy_squads", sim.AvgEnemySquads },
                { "avg_player_squads_lost", sim.AvgPlayerSquadsLost },
                { "avg_player_models_lost", sim.AvgPlayerModelsLost },
                { "avg_enemy_models_lost", sim.AvgEnemyModelsLost },
                { "avg_player_damage", sim.AvgPlayerDamage },
                { "avg_player_dps", sim.AvgPlayerDps },
                { "avg_player_dps_per_member", sim.AvgPlayerDpsPerMember },
                { "avg_path_length", sim.AvgPathLength },
                { "avg_path_ratio", sim.AvgPathStraightRatio },
                { "avg_stuck_events", sim.AvgStuckEvents },
                { "avg_slot_error", sim.AvgSlotError },
                { "avg_overlap_pairs_max", sim.AvgOverlapPairsMax },
                { "avg_overlap_depth_max_m", sim.AvgOverlapDepthMaxMeters },
                { "avg_overlap_pairs_after_max", sim.AvgOverlapPairsAfterMax },
                { "avg_overlap_depth_after_max_m", sim.AvgOverlapDepthAfterMaxMeters },
                { "avg_overlap_after_ticks", sim.AvgOverlapAfterTicks },
                { "avg_unfired_engaged_seconds", sim.AvgUnfiredEngagedSeconds },
                { "avg_heading_flips_per_sec", sim.AvgHeadingFlipsPerSec },
                // 2026-11-24：单轮死斗读数
                { "avg_rounds", sim.AvgRounds },
                { "total_rounds", sim.TotalRounds },
                { "avg_round_base_damage", sim.AvgRoundBaseDamage },
                { "avg_player_base_damage_dealt", sim.AvgPlayerBaseDamageDealt },
                { "berserk_rounds", sim.TotalBerserkRounds },
                { "berserk_round_rate", sim.BerserkRoundRate },
                { "tie_diff_rounds", sim.TotalTieDiffRounds },
                { "tie_diff_round_rate", sim.TieDiffRoundRate },
                { "round_histogram", RoundHistogramDict(sim.RoundHistogram) },
                { "avg_enemy_max_zone", sim.AvgEnemyMaxZone },
                { "avg_player_zone_seconds", sim.AvgPlayerZoneSeconds },
                { "avg_enemy_zone_seconds", sim.AvgEnemyZoneSeconds },
                { "total_player_kills", sim.TotalPlayerKills },
                { "total_enemy_kills", sim.TotalEnemyKills },
                { "review_counts", ToGodotDict(sim.ReviewCounts) },
                { "player_dps_rows", UnitStatsRows(sim.PlayerByUnit) },
                { "enemy_dps_rows", UnitStatsRows(sim.EnemyByUnit) },
            };

            var rows = new Godot.Collections.Array();
            foreach (SquadSimRow r in sim.Rows)
            {
                rows.Add(new Godot.Collections.Dictionary
                {
                    { "index", r.Index },
                    { "seed", r.Seed },
                    { "outcome", r.Outcome },
                    { "outcome_text", r.OutcomeText },
                    { "player_hp", r.PlayerHp },
                    { "enemy_hp", r.EnemyHp },
                    { "player_hp_pct", r.PlayerHpPct },
                    { "player_squads", r.PlayerSquads },
                    { "enemy_squads", r.EnemySquads },
                    { "player_squads_lost", r.PlayerSquadsLost },
                    { "enemy_squads_lost", r.EnemySquadsLost },
                    { "player_models_lost", r.PlayerModelsLost },
                    { "enemy_models_lost", r.EnemyModelsLost },
                    { "player_damage", r.PlayerDamage },
                    { "enemy_damage", r.EnemyDamage },
                    { "dps_member", r.DpsPerMember },
                    { "seconds", r.Seconds },
                    { "zone_max", r.ZoneMax },
                    { "enemy_zone_max", r.EnemyZoneMax },
                    { "player_zone_seconds", r.PlayerZoneSeconds },
                    { "enemy_zone_seconds", r.EnemyZoneSeconds },
                    { "stuck_events", r.StuckEvents },
                    { "slot_error", r.SlotError },
                    { "overlap_pairs_max", r.OverlapPairsMax },
                    { "overlap_depth_max", r.OverlapDepthMax },
                    { "overlap_pairs_after_max", r.OverlapPairsAfterMax },
                    { "overlap_depth_after_max", r.OverlapDepthAfterMax },
                    { "overlap_after_ticks", r.OverlapAfterTicks },
                    { "unfired_engaged_seconds", r.UnfiredEngagedSeconds },
                    { "heading_flips_per_sec", r.HeadingFlipsPerSec },
                    { "rounds", r.Rounds },
                    { "base_damage_dealt", r.BaseDamageDealt },
                    { "berserk_rounds", r.BerserkRounds },
                    { "tie_diff_rounds", r.TieDiffRounds },
                    { "cp_left", r.CpLeft },
                    { "pop_blocked", r.PopBlocked },
                    { "top_reason", r.TopReason },
                });
            }
            outDict["rows"] = rows;

            var samples = new Godot.Collections.Array();
            foreach (SquadMatchResult s in sim.Samples)
            {
                samples.Add(new Godot.Collections.Dictionary
                {
                    { "seed", s.Seed },
                    { "outcome", s.Outcome },
                    { "outcome_text", s.OutcomeText },
                    { "player_hp", Math.Round(s.PlayerBaseHp) },
                    { "enemy_hp", Math.Round(s.EnemyBaseHp) },
                    { "player_damage", Math.Round(s.PlayerDamage) },
                    { "rounds", s.RoundsPlayed },
                    { "base_damage_dealt", Math.Round(s.PlayerBaseDamageDealt) },
                    { "berserk_rounds", s.BerserkRounds },
                    { "tie_diff_rounds", s.TieDiffRounds },
                    { "defeat_record", s.DefeatRecord },
                    { "army", s.PlayerSquadsProduced },
                    { "defend_squads", 0 },
                    { "reviews", ToGodotArray(s.Reviews) },
                    { "review_codes", ToGodotArray(s.ReviewCodes) },
                    { "dps_rows", UnitStatsRows(s.PlayerByUnit) },
                });
            }
            outDict["samples"] = samples;
            return outDict;
        }

        /// <summary>回合数分布（轮数 → 局数）；键用字符串，GDScript 侧直接读。</summary>
        private static Godot.Collections.Dictionary RoundHistogramDict(Dictionary<int, int> hist)
        {
            var d = new Godot.Collections.Dictionary();
            var keys = new List<int>(hist.Keys);
            keys.Sort();
            foreach (int k in keys) d[k.ToString()] = hist[k];
            return d;
        }

        private static Godot.Collections.Array UnitStatsRows(Dictionary<string, SquadUnitStat> map)        {
            var list = new List<SquadUnitStat>(map.Values);
            list.Sort((a, b) =>
            {
                int c = b.Damage.CompareTo(a.Damage);
                if (c != 0) return c;
                return string.CompareOrdinal(a.UnitId, b.UnitId);
            });
            var rows = new Godot.Collections.Array();
            foreach (SquadUnitStat s in list)
            {
                rows.Add(new Godot.Collections.Dictionary
                {
                    { "unit_id", s.UnitId },
                    { "squads", s.Squads },
                    { "models", s.Models },
                    { "kills", s.Kills },
                    { "losses", s.Losses },
                    { "damage", s.Damage },
                    { "dps_member", s.DpsPerMember },
                    { "dps_squad", s.DpsPerSquad },
                });
            }
            return rows;
        }

        private static IDictionary<string, object> FindRow(IDictionary<string, object> doc, string key, string id)
        {
            var list = JValList(doc, key);
            if (list == null) return null;
            foreach (object o in list)
            {
                var d = o as IDictionary<string, object>;
                if (d == null) continue;
                if (StrOf(d, "id") == id) return d;
            }
            return null;
        }

        private static IDictionary<string, object> JValDict(IDictionary<string, object> d, string key)
        {
            if (d == null || !d.TryGetValue(key, out object v)) return null;
            return v as IDictionary<string, object>;
        }

        private static List<object> JValList(IDictionary<string, object> d, string key)
        {
            if (d == null || !d.TryGetValue(key, out object v)) return null;
            return v as List<object>;
        }

        private static string StrOf(IDictionary<string, object> d, string key)
        {
            if (d == null || !d.TryGetValue(key, out object v) || v == null) return "";
            return v.ToString();
        }

        // =================================================================
        // 2026-11-21 地图底壳：势力区域多边形 / 战术格子
        // =================================================================
        /// <summary>新建底壳的默认三块矩形（player / neutral / enemy，沿长轴切三条）。</summary>
        public Godot.Collections.Dictionary RegionDefaults(double sizeX, double sizeZ)
        {
            var set = RegionSet.Defaults(sizeX, sizeZ);
            var outDict = new Godot.Collections.Dictionary();
            foreach (RegionKind kind in new[] { RegionKind.Player, RegionKind.Neutral, RegionKind.Enemy })
                outDict[RegionKinds.Name(kind)] = PointsToGodot(set.Of(kind).Points);
            return outDict;
        }

        /// <summary>区域校验（顶点不足 3 个 → 返回非空数组，这就是反向验错的靶子）。</summary>
        public Godot.Collections.Array RegionValidate(string kind, Godot.Collections.Array points)
        {
            var poly = new RegionPolygon(RegionKinds.Parse(kind), ToPoints(points));
            return ToGodotArray(poly.Validate());
        }

        public bool RegionContains(Godot.Collections.Array points, double x, double z)
        {
            var poly = new RegionPolygon(RegionKind.Neutral, ToPoints(points));
            return poly.Contains(x, z);
        }

        public double RegionArea(Godot.Collections.Array points)
        {
            var poly = new RegionPolygon(RegionKind.Neutral, ToPoints(points));
            return poly.Area;
        }

        /// <summary>格子校验：唯一索引 / 每边最多一个主堡 / 格间留缝 / 不出图。</summary>
        public Godot.Collections.Array TileValidate(Godot.Collections.Array tiles, double sizeX, double sizeZ, double minGap)
        {
            return ToGodotArray(TacticalTileSet.Validate(ToTiles(tiles), sizeX, sizeZ, minGap));
        }

        /// <summary>单个格子的两个标准锚点（世界坐标，左上角建筑位 / 正中心出兵位）。</summary>
        public Godot.Collections.Dictionary TileAnchors(Godot.Collections.Dictionary tile)
        {
            var t = ToTile(tile);
            var b = t.BuildingAnchorWorld();
            var s = t.SquadSpawnAnchorWorld();
            return new Godot.Collections.Dictionary
            {
                { "index", t.Index },
                { "building_x", b.X },
                { "building_z", b.Y },
                { "spawn_x", s.X },
                { "spawn_z", s.Y },
                { "local_building_x", t.BuildingAnchorLocal.X },
                { "local_building_z", t.BuildingAnchorLocal.Y },
                { "corners", PointsToGodot(new List<Vec2>(t.Corners())) },
            };
        }

        /// <summary>新建底壳的默认格子（两边主堡 + 建造位）。</summary>
        public Godot.Collections.Array TileDefaults(double sizeX, double sizeZ)
        {
            var arr = new Godot.Collections.Array();
            foreach (var t in TacticalTileSet.Defaults(sizeX, sizeZ)) arr.Add(TileToGodot(t));
            return arr;
        }

        // =================================================================
        // 2026-11-21 地图底板：立体厚度 / 画布冗余 / 格子统一倍率
        // =================================================================
        /// <summary>底板参数校验（厚度 / 倒角 / 冗余 / 格子倍率 / 地图尺寸）。</summary>
        public Godot.Collections.Array MapBoardValidate(double sizeX, double sizeZ, double depth,
            double bevel, double margin, double tileScale)
        {
            return ToGodotArray(MapBoard.Validate(sizeX, sizeZ, depth, bevel, margin, tileScale));
        }

        /// <summary>画布尺寸（= 地图尺寸 × (1 + 2 × 冗余)），返回 [w, h]。</summary>
        public Godot.Collections.Array MapCanvasSize(double sizeX, double sizeZ, double margin)
        {
            return new Godot.Collections.Array
            {
                MapBoard.CanvasSizeX(sizeX, margin),
                MapBoard.CanvasSizeZ(sizeZ, margin),
            };
        }

        /// <summary>某个原尺寸格子允许的最大统一倍率（不是写死的 2.0）。</summary>
        public double MapMaxTileScale(double width, double depth) => MapBoard.MaxScaleFor(width, depth);

        /// <summary>
        /// 地图扩容时一个格子怎么走：位置按 X/Z 比例缩放 + 宽深按倍率缩放。
        /// 失败（新尺寸放不下）返回 ok=false + error，调用方必须原地不动。
        /// </summary>
        public Godot.Collections.Dictionary MapResizeTile(double x, double z, double width, double depth,
            double oldSizeX, double oldSizeZ, double newSizeX, double newSizeZ, double tileScale)
        {
            bool ok = MapBoard.TryResizeTile(x, z, width, depth, oldSizeX, oldSizeZ,
                newSizeX, newSizeZ, tileScale, out double nx, out double nz, out double nw,
                out double nd, out string error);
            return new Godot.Collections.Dictionary
            {
                { "ok", ok },
                { "error", error },
                { "x", nx },
                { "z", nz },
                { "w", nw },
                { "d", nd },
            };
        }

        /// <summary>点是否还在画布冗余范围内（编辑器相机/装饰边界用）。</summary>
        public bool MapInsideCanvas(double x, double z, double sizeX, double sizeZ, double margin)
        {
            return MapBoard.InsideCanvas(x, z, sizeX, sizeZ, margin);
        }

        /// <summary>编辑器相机最大距离（随画布放大，扩容后仍能拉远看全图）。</summary>
        public double MapCameraDistMax(double canvasX, double canvasZ) =>
            MapBoard.CameraDistMax(canvasX, canvasZ);

        private static Godot.Collections.Array PointsToGodot(IEnumerable<Vec2> points)
        {
            var arr = new Godot.Collections.Array();
            foreach (var p in points) arr.Add(new Vector2(p.X, p.Y));
            return arr;
        }

        private static List<Vec2> ToPoints(Godot.Collections.Array arr)
        {
            var list = new List<Vec2>();
            if (arr == null) return list;
            foreach (Variant v in arr)
            {
                switch (v.VariantType)
                {
                    case Variant.Type.Vector2:
                        list.Add(new Vec2(v.AsVector2().X, v.AsVector2().Y));
                        break;
                    case Variant.Type.Dictionary:
                    {
                        var d = v.AsGodotDictionary();
                        double x = d.TryGetValue("x", out Variant vx) ? vx.AsDouble() : 0.0;
                        double z = d.TryGetValue("z", out Variant vz) ? vz.AsDouble() : 0.0;
                        list.Add(new Vec2((float)x, (float)z));
                        break;
                    }
                }
            }
            return list;
        }

        private static TacticalTile ToTile(Godot.Collections.Dictionary d)
        {
            var t = new TacticalTile();
            if (d == null) return t;
            t.Index = Int(d, "index", 0);
            t.Side = Str(d, "side", RegionKinds.Player);
            t.Role = Str(d, "role", "build");
            t.X = d.TryGetValue("x", out Variant vx) ? vx.AsDouble() : 0.0;
            t.Z = d.TryGetValue("z", out Variant vz) ? vz.AsDouble() : 0.0;
            t.Width = d.TryGetValue("w", out Variant vw) ? vw.AsDouble() : 6.0;
            t.Depth = d.TryGetValue("d", out Variant vd) ? vd.AsDouble() : 6.0;
            t.YawDeg = d.TryGetValue("yaw", out Variant vy) ? vy.AsDouble() : 0.0;
            t.TerrainY = d.TryGetValue("terrain_y", out Variant vt) ? vt.AsDouble() : 0.0;
            return t;
        }

        private static List<TacticalTile> ToTiles(Godot.Collections.Array arr)
        {
            var list = new List<TacticalTile>();
            if (arr == null) return list;
            foreach (Variant v in arr)
            {
                if (v.VariantType == Variant.Type.Dictionary)
                    list.Add(ToTile(v.AsGodotDictionary()));
            }
            return list;
        }

        private static Godot.Collections.Dictionary TileToGodot(TacticalTile t)
        {
            var b = t.BuildingAnchorWorld();
            var s = t.SquadSpawnAnchorWorld();
            return new Godot.Collections.Dictionary
            {
                { "index", t.Index },
                { "side", t.Side },
                { "role", t.Role },
                { "x", t.X },
                { "z", t.Z },
                { "w", t.Width },
                { "d", t.Depth },
                { "yaw", t.YawDeg },
                { "terrain_y", t.TerrainY },
                { "building_x", b.X },
                { "building_z", b.Y },
                { "spawn_x", s.X },
                { "spawn_z", s.Y },
            };
        }

        private static int CountEnabled(UnitCatalog units)
        {
            int n = 0;
            foreach (var u in units.All)
            {
                if (u.Enabled) n++;
            }
            return n;
        }

        private static int CountCards(PlanningConfig cfg, CardKind kind)
        {
            int n = 0;
            foreach (var c in cfg.Cards.Values)
            {
                if (c.Kind == kind) n++;
            }
            return n;
        }

        private static int CountTrainTagClosure(PlanningConfig cfg, UnitCatalog units)
        {
            int n = 0;
            foreach (var c in cfg.Cards.Values)
            {
                if (c.Kind != CardKind.Train) continue;
                bool matched = false;
                foreach (var b in cfg.Buildings.Values)
                {
                    if (b.Kind != BuildingKinds.Producer) continue;
                    if (b.Tag == c.BuildingTag && b.Trains.Contains(c.Unit)) matched = true;
                }
                if (matched) n++;
            }
            return n;
        }

        private static CombatAttacker ParseAttacker(Godot.Collections.Dictionary d)
        {
            return new CombatAttacker
            {
                Damage = d.TryGetValue("damage", out Variant dmg) ? dmg.AsDouble() : 0.0,
                Cooldown = d.TryGetValue("cooldown", out Variant cd) ? cd.AsDouble() : 1.0,
                AttackType = d.TryGetValue("attack_type", out Variant at) ? at.AsInt32() : 0,
                Hit = d.TryGetValue("hit", out Variant hit) ? hit.AsDouble() : 100.0,
                CritChance = d.TryGetValue("crit", out Variant cr) ? cr.AsDouble() : 0.0,
                CritMultiplier = d.TryGetValue("crit_multiplier", out Variant cm) ? cm.AsDouble() : 0.0,
                ArmorPenFlat = d.TryGetValue("pen_flat", out Variant pf) ? pf.AsDouble() : 0.0,
                ArmorPenPct = d.TryGetValue("pen_pct", out Variant pp) ? pp.AsDouble() : 0.0,
                AttackMult = d.TryGetValue("attack_mult", out Variant am) ? am.AsDouble() : 1.0,
            };
        }

        private static CombatDefender ParseDefender(Godot.Collections.Dictionary d)
        {
            return new CombatDefender
            {
                Armor = d.TryGetValue("armor", out Variant ar) ? ar.AsDouble() : 0.0,
                ArmorType = d.TryGetValue("armor_type", out Variant at) ? at.AsInt32() : 0,
                Dodge = d.TryGetValue("dodge", out Variant dg) ? dg.AsDouble() : 0.0,
                ArmorMult = d.TryGetValue("armor_mult", out Variant am) ? am.AsDouble() : 1.0,
                DamageTakenMult = d.TryGetValue("taken_mult", out Variant tm) ? tm.AsDouble() : 1.0,
            };
        }

        private static Godot.Collections.Array ToGodotArray(string[] arr)
        {
            var outArr = new Godot.Collections.Array();
            if (arr == null) return outArr;
            foreach (var s in arr) outArr.Add(s);
            return outArr;
        }

        private static Godot.Collections.Array ToGodotArray(double[] arr)
        {
            var outArr = new Godot.Collections.Array();
            if (arr == null) return outArr;
            foreach (var v in arr) outArr.Add(v);
            return outArr;
        }

        private static Godot.Collections.Array ToGodotArray(List<string> list)
        {
            var outArr = new Godot.Collections.Array();
            if (list == null) return outArr;
            foreach (var s in list) outArr.Add(s);
            return outArr;
        }

        /// <summary>递归拆成纯 .NET 类型：Dictionary→Dictionary&lt;string,object&gt;、Array→List&lt;object&gt;。</summary>
        private static Dictionary<string, object> ToPlainDict(Godot.Collections.Dictionary d)
        {
            var outDict = new Dictionary<string, object>();
            if (d == null) return outDict;
            foreach (var key in d.Keys)
            {
                outDict[key.ToString()] = ToPlain(d[key]);
            }
            return outDict;
        }

        private static object ToPlain(Variant v)
        {
            switch (v.VariantType)
            {
                case Variant.Type.Dictionary:
                    return ToPlainDict(v.AsGodotDictionary());
                case Variant.Type.Array:
                {
                    var src = v.AsGodotArray();
                    var list = new List<object>(src.Count);
                    for (int i = 0; i < src.Count; i++) list.Add(ToPlain(src[i]));
                    return list;
                }
                case Variant.Type.String:
                case Variant.Type.StringName:
                case Variant.Type.NodePath:
                    return v.ToString();
                case Variant.Type.Int:
                    return v.AsInt64();
                case Variant.Type.Float:
                    return v.AsDouble();
                case Variant.Type.Bool:
                    return v.AsBool();
                case Variant.Type.Nil:
                    return null;
                default:
                    return v.ToString();
            }
        }

        private static Godot.Collections.Dictionary ToGodotDict(Dictionary<string, int> d)
        {
            var outDict = new Godot.Collections.Dictionary();
            foreach (var kv in d) outDict[kv.Key] = kv.Value;
            return outDict;
        }

        // =================================================================
        // 小工具
        // =================================================================
        private static bool Bool(Godot.Collections.Dictionary d, string key, bool fallback)
        {
            return d != null && d.TryGetValue(key, out Variant v) ? v.AsBool() : fallback;
        }

        private static int Int(Godot.Collections.Dictionary d, string key, int fallback)
        {
            return d != null && d.TryGetValue(key, out Variant v) ? v.AsInt32() : fallback;
        }

        private static string Str(Godot.Collections.Dictionary d, string key, string fallback)
        {
            return d != null && d.TryGetValue(key, out Variant v) ? v.ToString() : fallback;
        }

    }
}
