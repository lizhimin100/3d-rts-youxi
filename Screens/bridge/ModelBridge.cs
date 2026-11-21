using Godot;
using System;
using System.Collections.Generic;
using WarIsland.Model;

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
        // 2026-11-21 新内核：6 步公式 / units.json / 规划 / 双 90 秒
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
