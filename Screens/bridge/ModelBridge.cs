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
        // 伤害
        // =================================================================
        public Godot.Collections.Dictionary DamageCompute(
            double baseDamage, double spread, int attackType,
            double targetArmor, int targetArmorType,
            Godot.Collections.Dictionary rules,
            double rollSpread, double rollCrit, double attackMult)
        {
            var r = Damage.Compute(baseDamage, spread, attackType, targetArmor, targetArmorType,
                ParseRules(rules), rollSpread, rollCrit, attackMult);
            return new Godot.Collections.Dictionary
            {
                { "ok", r.Ok },
                { "damage", r.Damage },
                { "mitigation", r.Mitigation },
                { "multiplier", r.Multiplier },
                { "is_crit", r.IsCrit },
            };
        }

        public double DamageArmorMitigation(double armor, double reduction, double cap) =>
            Damage.ArmorMitigation(armor, reduction, cap);

        public double DamageCounterMultiplier(Godot.Collections.Array table, int attackType, int armorType, int stride) =>
            Damage.CounterMultiplier(ToDoubleArray(table), attackType, armorType, stride);

        // =================================================================
        // 经济 / 人口 / CP
        // =================================================================
        public bool EconomyCanAfford(int gold, int wood, int costGold, int costWood) =>
            Economy.CanAfford(gold, wood, costGold, costWood);

        /// <summary>扣费并写回 state（Dictionary 是引用类型，改了就生效）；不够时一分不扣。</summary>
        public bool EconomyPay(Godot.Collections.Dictionary state, int costGold, int costWood)
        {
            int gold = state.TryGetValue("gold", out Variant g) ? g.AsInt32() : 0;
            int wood = state.TryGetValue("wood", out Variant w) ? w.AsInt32() : 0;
            bool ok = Economy.Pay(ref gold, ref wood, costGold, costWood);
            if (ok)
            {
                state["gold"] = gold;
                state["wood"] = wood;
            }
            return ok;
        }

        public Godot.Collections.Dictionary EconomyAdd(Godot.Collections.Dictionary state, int gold, int wood)
        {
            int g = state.TryGetValue("gold", out Variant vg) ? vg.AsInt32() : 0;
            int w = state.TryGetValue("wood", out Variant vw) ? vw.AsInt32() : 0;
            Economy.Add(ref g, ref w, gold, wood);
            state["gold"] = g;
            state["wood"] = w;
            return state;
        }

        public bool EconomyHasFood(int used, int reserved, int amount, int cap) =>
            Economy.HasFood(used, reserved, amount, cap);

        public bool EconomyCanSpendCp(int cp, int costCp) => Economy.CanSpendCp(cp, costCp);

        public double EconomyIncomePerSecond(int workers, int carry, double tripSeconds) =>
            Economy.IncomePerSecond(workers, carry, tripSeconds);

        public int EconomyWorkersForIncome(double incomePerSec, int carry, double tripSeconds) =>
            Economy.WorkersForIncome(incomePerSec, carry, tripSeconds);

        // =================================================================
        // 可用性（原因码 + 参数）
        // =================================================================
        public Godot.Collections.Dictionary AvailabilityTrain(Godot.Collections.Dictionary ctx)
        {
            var c = new TrainCheck
            {
                PhaseOk = Bool(ctx, "phase_ok", true),
                Constructed = Bool(ctx, "constructed", true),
                Trains = ToStringArray(ctx, "trains"),
                Id = Str(ctx, "id", ""),
                Upgrading = Bool(ctx, "upgrading", false),
                RequireTier = Int(ctx, "require_tier", 0),
                CurrentTier = Int(ctx, "current_tier", 1),
                QueueMax = Int(ctx, "queue_max", Availability.TrainQueueMax),
                QueueSize = Int(ctx, "queue_size", 0),
                FoodCost = Int(ctx, "food_cost", 0),
                FoodFree = Int(ctx, "food_free", 0),
                Short = Bool(ctx, "short", false),
                Cp = Int(ctx, "cp", 0),
                CpCost = Int(ctx, "cp_cost", 0),
                Gold = Int(ctx, "gold", 0),
                GoldCost = Int(ctx, "gold_cost", 0),
                Wood = Int(ctx, "wood", 0),
                WoodCost = Int(ctx, "wood_cost", 0),
            };
            return AvailToDict(Availability.CheckTrain(c));
        }

        public Godot.Collections.Dictionary AvailabilityTrainPermission(
            Godot.Collections.Array trains, string id, int requiredTier, int currentTier)
        {
            var arr = new string[trains.Count];
            for (int i = 0; i < trains.Count; i++) arr[i] = trains[i].ToString();
            return AvailToDict(Availability.CheckTrainPermission(arr, id, requiredTier, currentTier));
        }

        public Godot.Collections.Dictionary AvailabilityResearch(Godot.Collections.Dictionary ctx)
        {
            var c = new ResearchCheck
            {
                Constructed = Bool(ctx, "constructed", true),
                Researchable = Bool(ctx, "researchable", false),
                Upgrading = Bool(ctx, "upgrading", false),
                Busy = Bool(ctx, "busy", false),
                Level = Int(ctx, "level", 0),
                MaxLevel = Int(ctx, "max_level", 1),
                Gold = Int(ctx, "gold", 0),
                GoldCost = Int(ctx, "gold_cost", 0),
                Wood = Int(ctx, "wood", 0),
                WoodCost = Int(ctx, "wood_cost", 0),
            };
            return AvailToDict(Availability.CheckResearch(c));
        }

        public Godot.Collections.Dictionary AvailabilityRefit(Godot.Collections.Dictionary ctx)
        {
            var c = new RefitCheck
            {
                Constructed = Bool(ctx, "constructed", true),
                Busy = Bool(ctx, "busy", false),
                Gold = Int(ctx, "gold", 0),
                GoldCost = Int(ctx, "gold_cost", 0),
                Wood = Int(ctx, "wood", 0),
                WoodCost = Int(ctx, "wood_cost", 0),
            };
            return AvailToDict(Availability.CheckRefit(c));
        }

        public Godot.Collections.Dictionary AvailabilityBuild(Godot.Collections.Dictionary ctx)
        {
            var c = new BuildCheck
            {
                HasWorker = Bool(ctx, "has_worker", true),
                PhaseOk = Bool(ctx, "phase_ok", true),
                RequireTier = Int(ctx, "require_tier", 0),
                CurrentTier = Int(ctx, "current_tier", 1),
                Short = Bool(ctx, "short", false),
                PopCost = Int(ctx, "pop_cost", 0),
                FoodFree = Int(ctx, "food_free", 0),
                Cp = Int(ctx, "cp", 0),
                CpCost = Int(ctx, "cp_cost", 0),
                Gold = Int(ctx, "gold", 0),
                GoldCost = Int(ctx, "gold_cost", 0),
                Wood = Int(ctx, "wood", 0),
                WoodCost = Int(ctx, "wood_cost", 0),
            };
            return AvailToDict(Availability.CheckBuild(c));
        }

        // =================================================================
        // 成长（主城等级 / 铁匠铺 / 升星）
        // =================================================================
        public double ProgressionFlatBonus(int level, double perLevel) =>
            Progression.FlatBonus(level, perLevel);

        public bool ProgressionCanUpgrade(int level, int maxLevel, int gold, int wood, int costGold, int costWood) =>
            Progression.CanUpgrade(level, maxLevel, gold, wood, costGold, costWood);

        public int ProgressionApplyLevel(int level, int maxLevel) => Progression.ApplyLevel(level, maxLevel);

        public bool ProgressionTierAllows(int requireTier, int currentTier) =>
            Progression.TierAllows(requireTier, currentTier);

        public int StarCap() => Progression.StarCap;

        public double StarKillExp() => Progression.KillExp;

        public double StarExpPerStar(int goldCost, int woodCost) => Progression.ExpPerStar(goldCost, woodCost);

        public int StarStarsOf(double expValue, double need) => Progression.StarsOf(expValue, need);

        public string StarName(int star) => Progression.StarName(star);

        public double StarOffenseMult(int star) => Progression.OffenseMult(star);

        public double StarToughMult(int star) => Progression.ToughMult(star);

        // =================================================================
        // 推演（--simulate）
        // =================================================================
        /// <summary>只做校验，返回错误字符串数组（空数组 = 合法）。</summary>
        public Godot.Collections.Array SimValidate(Godot.Collections.Dictionary config)
        {
            var errors = Skirmish.Validate(ToPlainDict(config));
            var arr = new Godot.Collections.Array();
            foreach (var e in errors) arr.Add(e);
            return arr;
        }

        public Godot.Collections.Dictionary Simulate(Godot.Collections.Dictionary config)
        {
            var result = Skirmish.Run(ToPlainDict(config));
            var outDict = new Godot.Collections.Dictionary
            {
                { "ok", result.Ok },
                { "seed", result.Seed },
                { "seconds", result.Seconds },
                { "winner", result.Winner },
            };
            if (!result.Ok)
            {
                var errs = new Godot.Collections.Array();
                foreach (var e in result.Errors) errs.Add(e);
                outDict["errors"] = errs;
                return outDict;
            }
            var sides = new Godot.Collections.Array();
            foreach (var s in result.Sides)
            {
                sides.Add(new Godot.Collections.Dictionary
                {
                    { "name", s.Name },
                    { "alive", s.Alive },
                    { "alive_by_type", ToGodotDict(s.AliveByType) },
                    { "hp_left", s.HpLeft },
                    { "kills", s.Kills },
                    { "losses", s.Losses },
                    { "units_built", s.UnitsBuilt },
                    { "built_by_type", ToGodotDict(s.BuiltByType) },
                    { "gold_mined", s.GoldMined },
                    { "gold_left", s.GoldLeft },
                    { "damage_dealt", s.DamageDealt },
                });
            }
            outDict["sides"] = sides;
            var timeline = new Godot.Collections.Array();
            foreach (var t in result.Timeline)
            {
                timeline.Add(new Godot.Collections.Dictionary
                {
                    { "t", t.T },
                    { "units", new Godot.Collections.Array { t.Units[0], t.Units[1] } },
                    { "gold", new Godot.Collections.Array { t.Gold[0], t.Gold[1] } },
                    { "hp", new Godot.Collections.Array { t.Hp[0], t.Hp[1] } },
                });
            }
            outDict["timeline"] = timeline;
            return outDict;
        }

        // =================================================================
        // 2026-11-21 新内核：6 步公式 / units.json / 规划 / 双 60 秒
        // =================================================================
        /// <summary>一次把四张数据表全验一遍（--check 的唯一入口）。</summary>
        public Godot.Collections.Dictionary ContentValidate(
            Godot.Collections.Dictionary unitsDict,
            Godot.Collections.Dictionary combatDict,
            Godot.Collections.Dictionary planningDict,
            Godot.Collections.Dictionary levelsDict)
        {
            var notes = new List<string>();
            var rules = CombatRules.FromDict(ToPlainDict(combatDict));
            var combatErrors = rules.Validate();

            notes.Clear();
            var units = UnitCatalog.FromDict(ToPlainDict(unitsDict), rules, notes);
            var unitErrors = units.Validate();
            unitErrors.InsertRange(0, notes);

            notes.Clear();
            var planning = PlanningConfig.FromDict(ToPlainDict(planningDict), units, notes);
            var planningErrors = planning.Validate(units);
            planningErrors.InsertRange(0, notes);

            notes.Clear();
            var levels = LevelSet.FromDict(ToPlainDict(levelsDict), units, notes);
            var levelErrors = levels.Validate(units);
            levelErrors.InsertRange(0, notes);

            var outDict = new Godot.Collections.Dictionary
            {
                { "r1", rules.R1 },
                { "armor_scale", rules.ArmorScale },
                { "negative_armor_cap", rules.NegativeArmorCap },
                { "crit_multiplier", rules.CritMultiplier },
                { "attack_types", ToGodotArray(rules.AttackNames) },
                { "armor_types", ToGodotArray(rules.ArmorNames) },
                { "counter_table", ToGodotArray(rules.CounterTable) },
                { "combat_errors", ToGodotArray(combatErrors) },
                { "unit_errors", ToGodotArray(unitErrors) },
                { "planning_errors", ToGodotArray(planningErrors) },
                { "level_errors", ToGodotArray(levelErrors) },
                { "unit_count", units.All.Count },
                { "enabled_unit_count", CountEnabled(units) },
                { "faction_count", units.Factions.Count },
                { "building_count", planning.Buildings.Count },
                { "card_count", planning.Cards.Count },
                { "level_count", levels.Levels.Count },
                { "start_building_count", planning.StartBuildings.Count },
                { "train_tag_closure", CountTrainTagClosure(planning, units) },
                { "train_card_count", CountCards(planning, CardKind.Train) },
            };

            var unitRows = new Godot.Collections.Array();
            foreach (var u in units.All)
            {
                unitRows.Add(new Godot.Collections.Dictionary
                {
                    { "id", u.Id },
                    { "faction", u.Faction },
                    { "squad_size", u.SquadSize },
                    { "hp", u.Hp },
                    { "attack_damage", u.AttackDamage },
                    { "attack_cooldown", u.AttackCooldown },
                    { "range", u.AttackRange },
                    { "attack_type", CombatTypes.AttackName(u.AttackType) },
                    { "armor", u.Armor },
                    { "armor_type", CombatTypes.ArmorName(u.ArmorType) },
                    { "hit", u.Hit },
                    { "dodge", u.Dodge },
                    { "crit", u.Crit },
                    { "pen_flat", u.ArmorPenFlat },
                    { "pen_pct", u.ArmorPenPct },
                    { "body_radius", u.BodyRadius },
                    { "move_speed", u.MoveSpeed },
                    { "projectile", u.Projectile },
                    { "pop_cost", u.PopCost },
                    { "enabled", u.Enabled },
                    { "placeholder", u.UsePlaceholderMesh },
                });
            }
            outDict["unit_rows"] = unitRows;

            var factionRows = new Godot.Collections.Array();
            foreach (var kv in units.Factions)
            {
                factionRows.Add(new Godot.Collections.Dictionary
                {
                    { "id", kv.Key },
                    { "display_name", kv.Value.DisplayName },
                    { "placeholder", kv.Value.UsePlaceholderMesh },
                    { "unit_count", units.OfFaction(kv.Key, true).Count },
                });
            }
            outDict["faction_rows"] = factionRows;
            return outDict;
        }

        /// <summary>一次结算（6 步），roll 由 GDScript 传，方便做确定性对照。</summary>
        public Godot.Collections.Dictionary CombatComputeProbe(
            Godot.Collections.Dictionary attacker,
            Godot.Collections.Dictionary defender,
            Godot.Collections.Dictionary rulesDict,
            double rollHit,
            double rollCrit)
        {
            var rules = CombatRules.FromDict(ToPlainDict(rulesDict));
            var a = ParseAttacker(attacker);
            var d = ParseDefender(defender);
            var br = CombatCalculator.Compute(a, d, rules, rollHit, rollCrit);
            return new Godot.Collections.Dictionary
            {
                { "hit", br.Hit },
                { "hit_chance", br.HitChance },
                { "crit", br.Crit },
                { "effective_armor", br.EffectiveArmor },
                { "armor_taken", br.ArmorTaken },
                { "counter", br.Counter },
                { "damage", br.Damage },
            };
        }

        /// <summary>纯数学期望（乘命中率、负甲 3 倍封顶）。</summary>
        public Godot.Collections.Dictionary CombatExpect(
            Godot.Collections.Dictionary attacker,
            Godot.Collections.Dictionary defender,
            Godot.Collections.Dictionary rulesDict)
        {
            var rules = CombatRules.FromDict(ToPlainDict(rulesDict));
            var a = ParseAttacker(attacker);
            var d = ParseDefender(defender);
            double damage = CombatCalculator.ExpectedDamage(a, d, rules);
            double dps = CombatCalculator.ExpectedDps(a, d, rules);
            return new Godot.Collections.Dictionary
            {
                { "damage", damage },
                { "dps", dps },
                { "hit_chance", CombatCalculator.HitChance(a.Hit, d.Dodge) },
                { "effective_armor", CombatCalculator.EffectiveArmor(d.Armor * (d.ArmorMult > 0 ? d.ArmorMult : 1.0), a.ArmorPenPct, a.ArmorPenFlat) },
                { "armor_taken", CombatCalculator.ArmorDamageTaken(CombatCalculator.EffectiveArmor(d.Armor * (d.ArmorMult > 0 ? d.ArmorMult : 1.0), a.ArmorPenPct, a.ArmorPenFlat), rules) },
                { "counter", CombatCalculator.CounterMultiplier(rules, a.AttackType, d.ArmorType) },
            };
        }

        public double CombatArmorTaken(double armor, Godot.Collections.Dictionary rulesDict) =>
            CombatCalculator.ArmorDamageTaken(armor, CombatRules.FromDict(ToPlainDict(rulesDict)));

        public double CombatHitChance(double hit, double dodge) => CombatCalculator.HitChance(hit, dodge);

        public double CombatEffectiveArmor(double armor, double penPct, double penFlat) =>
            CombatCalculator.EffectiveArmor(armor, penPct, penFlat);

        public double CombatCounter(int attackType, int armorType, Godot.Collections.Dictionary rulesDict) =>
            CombatCalculator.CounterMultiplier(CombatRules.FromDict(ToPlainDict(rulesDict)), attackType, armorType);

        /// <summary>规划规则自测：建造 / 3 合 1 / 训练 Tag / 星级传递 / 人口。</summary>
        public Godot.Collections.Dictionary PlanningSelfTest(
            Godot.Collections.Dictionary planningDict,
            Godot.Collections.Dictionary unitsDict,
            Godot.Collections.Dictionary combatDict)
        {
            var rules = CombatRules.FromDict(ToPlainDict(combatDict));
            var units = UnitCatalog.FromDict(ToPlainDict(unitsDict), rules, new List<string>());
            var planning = PlanningConfig.FromDict(ToPlainDict(planningDict), units, new List<string>());
            var m = new PlanningMatch(planning, units, 7);
            m.BeginPlanning();

            int startBuildings = m.Buildings.Count;
            bool hasBase = false;
            foreach (var b in m.Buildings)
            {
                var def = m.DefOf(b);
                if (def != null && def.Tag == "base") hasBase = true;
            }
            int popCap0 = m.PopCap();
            int cp0 = m.Cp;

            // 1) 打一张建造牌
            string buildCard = "";
            foreach (var id in m.Hand)
            {
                if (planning.Cards.TryGetValue(id, out CardDef c) && c.Kind == CardKind.Build)
                {
                    buildCard = id;
                    break;
                }
            }
            int buildPlot = m.FirstFreePlot();
            bool buildOk = !string.IsNullOrEmpty(buildCard) && m.PlayBuild(buildCard, buildPlot);
            int cpAfterBuild = m.Cp;
            int buildingsAfterBuild = m.Buildings.Count;
            var newBuilding = buildOk ? m.BuildingAt(buildPlot) : null;
            int newBuildingStar = newBuilding != null ? newBuilding.Star : 0;

            // 2) 手摆 3 座同名兵营，两两合并 → 3 星
            var plots = new List<int>();
            for (int i = 0; i < 3; i++)
            {
                int p = m.FirstFreePlot();
                if (p < 0) break;
                m.Buildings.Add(new PlanBuilding { Plot = p, DefId = "barracks", MergedBuildings = 1 });
                plots.Add(p);
            }
            bool merge1 = plots.Count >= 2 && m.Merge(plots[0], plots[1]);
            bool merge2 = plots.Count >= 3 && m.Merge(plots[0], plots[2]);
            int mergedStar = 0;
            int barracksCount = 0;
            foreach (var b in m.Buildings)
            {
                if (b.DefId != "barracks") continue;
                barracksCount += 1;
                if (b.Plot == plots[0]) mergedStar = b.Star;
            }

            // 3) 打一张训练牌：全场同类建筑各产 1 队，3 星兵营产 3 星兵
            string trainCard = "";
            foreach (var id in m.Hand)
            {
                if (planning.Cards.TryGetValue(id, out CardDef c) && c.Kind == CardKind.Train)
                {
                    trainCard = id;
                    break;
                }
            }
            int trainProduced = string.IsNullOrEmpty(trainCard) ? -1 : m.PlayTrain(trainCard);
            int star3 = 0;
            foreach (var sq in m.Army)
            {
                if (sq.Star == 3) star3 += 1;
            }

            return new Godot.Collections.Dictionary
            {
                { "start_buildings", startBuildings },
                { "has_base", hasBase },
                { "pop_cap", popCap0 },
                { "cp_start", cp0 },
                { "build_card", buildCard },
                { "build_ok", buildOk },
                { "cp_after_build", cpAfterBuild },
                { "buildings_after_build", buildingsAfterBuild },
                { "new_building_star", newBuildingStar },
                { "merge_1", merge1 },
                { "merge_2", merge2 },
                { "merged_star", mergedStar },
                { "barracks_count", barracksCount },
                { "train_card", trainCard },
                { "train_produced", trainProduced },
                { "train_expected", barracksCount },
                { "army_squads", m.Army.Count },
                { "star3_squads", star3 },
                { "pop_used", m.PopUsed() },
                { "pop_cap_after", m.PopCap() },
                { "cp_left", m.Cp },
            };
        }

        /// <summary>第 1 关 100 局（默认）推演；返回汇总 + 每局行 + 3 个复盘样本。</summary>
        public Godot.Collections.Dictionary LevelSimulate(
            Godot.Collections.Dictionary unitsDict,
            Godot.Collections.Dictionary combatDict,
            Godot.Collections.Dictionary planningDict,
            Godot.Collections.Dictionary levelsDict,
            string levelId,
            int games,
            int seedBase)
        {
            var rules = CombatRules.FromDict(ToPlainDict(combatDict));
            var units = UnitCatalog.FromDict(ToPlainDict(unitsDict), rules, new List<string>());
            var planning = PlanningConfig.FromDict(ToPlainDict(planningDict), units, new List<string>());
            var levels = LevelSet.FromDict(ToPlainDict(levelsDict), units, new List<string>());

            var errors = new List<string>();
            errors.AddRange(rules.Validate());
            errors.AddRange(units.Validate());
            errors.AddRange(planning.Validate(units));
            errors.AddRange(levels.Validate(units));
            if (errors.Count > 0)
            {
                return new Godot.Collections.Dictionary
                {
                    { "ok", false },
                    { "errors", ToGodotArray(errors) },
                };
            }

            var sim = LevelSimulator.Run(units, rules, planning, levels, levelId, games, seedBase);
            var outDict = new Godot.Collections.Dictionary
            {
                { "ok", sim.Ok },
                { "level", sim.LevelId },
                { "level_name", sim.LevelName },
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
                { "avg_pike_behind_rate", sim.AvgPikeBehindRate },
                { "avg_pike_gap_cm", sim.AvgPikeGapCm },
                { "review_counts", ToGodotDict(sim.ReviewCounts) },
                { "errors", ToGodotArray(sim.Errors) },
            };

            var rows = new Godot.Collections.Array();
            foreach (var r in sim.Rows)
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
                    { "player_losses", r.PlayerLosses },
                    { "enemy_losses", r.EnemyLosses },
                    { "base_damage", r.BaseDamage },
                    { "zone_max", r.ZoneMax },
                    { "pike_behind", r.PikeBehind },
                    { "pike_attacks", r.PikeAttacks },
                    { "pike_formation_rate", r.PikeFormationRate },
                    { "cp_left", r.CpLeft },
                    { "pop_blocked", r.PopBlocked },
                    { "top_reason", r.TopReason },
                });
            }
            outDict["rows"] = rows;

            var samples = new Godot.Collections.Array();
            foreach (var s in sim.Samples)
            {
                var sample = new Godot.Collections.Dictionary
                {
                    { "seed", s.Seed },
                    { "outcome", s.Outcome },
                    { "outcome_text", s.OutcomeText },
                    { "player_hp", Math.Round(s.PlayerBaseHp) },
                    { "enemy_hp", Math.Round(s.EnemyBaseHp) },
                    { "attack_squads", s.AttackPlan != null ? s.AttackPlan.ArmySquads : 0 },
                    { "defend_squads", s.DefendPlan != null ? s.DefendPlan.ArmySquads : 0 },
                    { "attack_actions", ToGodotArray(s.AttackPlan != null ? s.AttackPlan.Actions : new List<string>()) },
                    { "defend_actions", ToGodotArray(s.DefendPlan != null ? s.DefendPlan.Actions : new List<string>()) },
                    { "reviews", ToGodotArray(s.Reviews) },
                    { "review_codes", ToGodotArray(s.ReviewCodes) },
                };
                samples.Add(sample);
            }
            outDict["samples"] = samples;
            return outDict;
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
            if (errors.Count > 0)
            {
                return new Godot.Collections.Dictionary
                {
                    { "ok", false },
                    { "handle", 0 },
                    { "errors", ToGodotArray(errors) },
                };
            }

            var session = new SquadSession(units, rules, planning, arena, seed, instantTrain);
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

        public Godot.Collections.Dictionary SquadSessionBuild(int handle, string cardId)
        {
            var session = Session(handle);
            if (session == null) return Err("会话已失效");
            bool ok = session.PlayBuildCard(cardId);
            var d = OkState(session);
            d["built"] = ok;
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
                    { "cost_cp", c.CostCp },
                    { "squad_size", c.SquadSize },
                    { "formation", c.Formation },
                    { "squad_radius", c.SquadRadius },
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
                { "planning_index", st.PlanningIndex },
                { "cp", st.Cp },
                { "cp_start", st.CpStart },
                { "pop_used", st.PopUsed },
                { "pop_cap", st.PopCap },
                { "pop_blocked", st.PopBlocked },
                { "army_squads", st.ArmySquads },
                { "hand", ToGodotArray(st.Hand) },
                { "train_cards", cards },
                { "log", ToGodotArray(st.Log) },
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
            var min = arena.LaneToWorld(arena.MinX, arena.MinY);
            var max = arena.LaneToWorld(arena.MaxX, arena.MaxY);
            return new Godot.Collections.Dictionary
            {
                { "id", arena.Id },
                { "display_name", arena.DisplayName },
                { "player_faction", arena.PlayerFaction },
                { "enemy_faction", arena.EnemyFaction },
                { "round_seconds", arena.RoundSeconds },
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
                { "ridge", ridge },
                { "tiles", tiles },
                { "player_buildings", playerBuildings },
                { "enemy_buildings", enemyBuildings },
                { "zone_dps_per_squad", arena.ZoneDpsPerSquad },
            };
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
                { "zone_dps_per_squad", arena.ZoneDpsPerSquad },
            };
        }

        /// <summary>逐兵种阵型探针：槽位数 / 槽位最远半径 / 是否贴合小队半径。</summary>
        public Godot.Collections.Dictionary SquadFormationProbe(
            Godot.Collections.Dictionary unitsDict,
            Godot.Collections.Dictionary combatDict)
        {
            var rules = CombatRules.FromDict(ToPlainDict(combatDict));
            var units = UnitCatalog.FromDict(ToPlainDict(unitsDict), rules, new List<string>());
            var rows = new Godot.Collections.Array();
            var errors = new List<string>();
            foreach (UnitDef u in units.All)
            {
                errors.AddRange(SquadFormations.Validate(u));
                var slots = SquadFormations.Slots(u);
                double max = SquadFormations.MaxSlotRadius(u);
                bool fits = u.SquadRadius > 0.0 && max <= u.SquadRadius * SquadFormations.FitRatio + 1e-6;
                if (!fits) errors.Add($"{u.Id}：槽位 {max:0.#} 超出半径 {u.SquadRadius:0} 的 92%");
                if (slots.Count != Math.Max(u.SquadSize, 1))
                    errors.Add($"{u.Id}：槽位 {slots.Count} ≠ squad_size {u.SquadSize}");
                var pts = new Godot.Collections.Array();
                foreach (System.Numerics.Vector2 p in slots)
                    pts.Add(new Godot.Collections.Dictionary { { "x", p.X }, { "z", p.Y } });
                rows.Add(new Godot.Collections.Dictionary
                {
                    { "id", u.Id },
                    { "formation", u.Formation },
                    { "squad_size", u.SquadSize },
                    { "squad_radius", u.SquadRadius },
                    { "slot_count", slots.Count },
                    { "max_slot_radius", max },
                    { "fits", fits },
                    { "slots", pts },
                });
            }
            return new Godot.Collections.Dictionary
            {
                { "ok", errors.Count == 0 },
                { "errors", ToGodotArray(errors) },
                { "rows", rows },
            };
        }

        /// <summary>100 局纯 Model 小队攻防推演（胜率 + DPS + 阵型/寻路指标）。</summary>
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

            var sim = SquadSimulator.Run(units, rules, planning, arena, games, seedBase);
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
                    { "stuck_events", r.StuckEvents },
                    { "slot_error", r.SlotError },
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
                    { "attack_squads", s.AttackPlan != null ? s.AttackPlan.ArmySquads : 0 },
                    { "defend_squads", s.DefendPlan != null ? s.DefendPlan.ArmySquads : 0 },
                    { "reviews", ToGodotArray(s.Reviews) },
                    { "review_codes", ToGodotArray(s.ReviewCodes) },
                    { "dps_rows", UnitStatsRows(s.PlayerByUnit) },
                });
            }
            outDict["samples"] = samples;
            return outDict;
        }

        private static Godot.Collections.Array UnitStatsRows(Dictionary<string, SquadUnitStat> map)
        {
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
                    if (b.Tag == c.Tag && b.Trains.Contains(c.Unit)) matched = true;
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

        // =================================================================
        // Variant → 纯 .NET
        // =================================================================
        private static DamageRules ParseRules(Godot.Collections.Dictionary d)
        {
            var rules = new DamageRules();
            if (d == null) return rules;
            if (d.TryGetValue("damage_table", out Variant table) && table.VariantType == Variant.Type.Array)
                rules.DamageTable = ToDoubleArray(table.AsGodotArray());
            rules.Stride = d.TryGetValue("stride", out Variant st) ? st.AsInt32() : 5;
            rules.ArmorReduction = d.TryGetValue("armor_reduction", out Variant ar) ? ar.AsDouble() : 0.0;
            rules.ArmorReductionCap = d.TryGetValue("armor_reduction_cap", out Variant ac) ? ac.AsDouble() : 0.0;
            rules.CritChance = d.TryGetValue("crit_chance", out Variant cc) ? cc.AsDouble() : 0.0;
            rules.CritMultiplier = d.TryGetValue("crit_multiplier", out Variant cm) ? cm.AsDouble() : 1.0;
            return rules;
        }

        private static double[] ToDoubleArray(Godot.Collections.Array arr)
        {
            var outArr = new double[arr.Count];
            for (int i = 0; i < arr.Count; i++) outArr[i] = arr[i].AsDouble();
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

        private static string[] ToStringArray(Godot.Collections.Dictionary d, string key)
        {
            if (d == null || !d.TryGetValue(key, out Variant v) || v.VariantType != Variant.Type.Array)
                return Array.Empty<string>();
            var arr = v.AsGodotArray();
            var outArr = new string[arr.Count];
            for (int i = 0; i < arr.Count; i++) outArr[i] = arr[i].ToString();
            return outArr;
        }

        private static Godot.Collections.Dictionary AvailToDict(AvailResult r)
        {
            var d = new Godot.Collections.Dictionary
            {
                { "ok", r.Ok },
                { "reason", r.Reason },
            };
            var p = new Godot.Collections.Dictionary();
            foreach (var kv in r.Params) p[kv.Key] = kv.Value;
            d["params"] = p;
            return d;
        }
    }
}
