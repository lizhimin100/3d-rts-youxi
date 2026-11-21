using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>横道上的一个模型（一队里的一个人）。</summary>
    internal sealed class LaneModel
    {
        public int Side;
        public int Squad;
        public UnitDef Def;
        public int Star;

        public double X;
        public double Y;
        public double Hp;
        public double MaxHp;

        public double Cd;
        public double Retarget;
        public int Target = -1;

        public double Range;
        public double Damage;
        public double Armor;
        public double Hit;
        public double Dodge;
        public double Crit;
        public double PenFlat;
        public double PenPct;
        public double MoveSpeed;
        public double Radius;
        public double ProjectileSpeed;
        public bool Projectile;
        public int AttackType;
        public int ArmorType;

        public double ArmorMult = 1.0;
        public double DamageTakenMult = 1.0;

        public bool Alive = true;
        public bool DeathCounted;
        public int Kills;
        public double DamageDealt;

        public bool IsFrontMelee => !Projectile && Range <= 120.0;
        public bool IsPike => !Projectile && Range > 120.0 && Range < 300.0;
    }

    internal sealed class LaneSquad
    {
        public int Id;
        public int Side;
        public string UnitId = "";
        public int Star = 1;
        public readonly List<int> Models = new List<int>();
        public double CentroidX;
        public double CentroidY;
        public bool WasAlive = true;
        public double ZoneSeconds;
    }

    internal sealed class LaneProjectile
    {
        public int Side;
        public int Source;
        public double X;
        public double Y;
        public int Target;
        public double Speed;
        public double Damage;
        public bool Crit;
        public bool Alive = true;
    }

    internal sealed class ScheduledWave
    {
        public double T;
        public int Side;
        public Wave Wave;
    }

    /// <summary>一轮 90 秒的完整结果（给复盘/推演）。</summary>
    public sealed class RoundResult
    {
        public string Kind = "";
        public string Label = "";
        public double Seconds;
        public double PlayerBaseHpStart;
        public double EnemyBaseHpStart;
        public double PlayerBaseHp;
        public double EnemyBaseHp;
        public bool PlayerBaseDestroyed;
        public bool EnemyBaseDestroyed;

        public int PlayerSquadsSpawned;
        public int EnemySquadsSpawned;
        public int PlayerSquadsLost;
        public int EnemySquadsLost;
        public int PlayerModelsLost;
        public int EnemyModelsLost;
        public int PlayerMaxModelsAlive;
        public int EnemyMaxModelsAlive;

        public double PlayerDamageDealt;
        public double EnemyDamageDealt;
        public double PlayerBaseDamage;
        public double EnemyBaseDamage;

        public int PlayerMaxSquadsInZone;
        public int EnemyMaxSquadsInZone;
        public double PlayerZoneSeconds;
        public double EnemyZoneSeconds;

        public int PikeAttacks;
        public int PikeBehindAttacks;
        public int PikeFormationSamples;
        public int PikeFormationBehind;
        public double AvgPikeGapMeters;

        public int PlayerShots;
        public int PlayerHits;
        public int EnemyShots;
        public int EnemyHits;

        public double FirstContactSecond = -1.0;
        public double FirstPlayerSquadLostSecond = -1.0;
    }

    /// <summary>
    /// 单通道横道战斗（90 秒）。
    ///
    /// 关键口径：
    ///   · 所有坐标/射程/速度都是**游戏数值**（R1 = 0.015 米），Model 层不出现米；
    ///     只有 move_speed / body_radius 这两个内容字段用米，进场时乘 1/R1 换成游戏数值；
    ///   · 射程按**中心到中心**判定；95 步兵 = 1.425 米，155 长枪 = 2.325 米，
    ///     两个 0.45 米身位 = 0.9 米，所以长枪刚好能站在步兵身后隔排刺击；
    ///   · 轻量圆形排斥是**位置约束**（不施加力），保证队形稳定；
    ///   · 全歼敌方后幸存小队继续越线；停在敌区且身边无敌人时按小队数抽基地血；
    ///   · 轮末由调用方清场（本类只负责一轮）。
    /// </summary>
    public sealed class LaneBattle
    {
        private const double Dt = 0.05;
        private const double RangeSlack = 4.0;
        private const double Eps = 1e-9;

        private readonly UnitCatalog _units;
        private readonly CombatRules _rules;
        private readonly LaneConfig _lane;
        private readonly PlanningConfig _planning;
        private readonly Rng _rng;

        private readonly List<LaneModel> _models = new List<LaneModel>();
        private readonly List<LaneSquad> _squads = new List<LaneSquad>();
        private readonly List<LaneProjectile> _shots = new List<LaneProjectile>();
        private readonly List<ScheduledWave> _waves = new List<ScheduledWave>();
        private int _nextWave;

        // 空间哈希（排斥用）
        private readonly double _cell;
        private readonly int _cols;
        private readonly int _rows;
        private readonly List<int>[] _buckets;

        private double _playerBaseHp;
        private double _enemyBaseHp;
        private double _playerDrainReduction;
        private double _enemyDrainReduction;
        private double _t;

        private readonly RoundResult _result = new RoundResult();
        private double _pikeGapSum;
        private int _pikeGapSamples;
        private int _sampleTick;

        public LaneBattle(UnitCatalog units, CombatRules rules, LaneConfig lane, PlanningConfig planning, int seed)
        {
            _units = units ?? throw new ArgumentNullException(nameof(units));
            _rules = rules ?? throw new ArgumentNullException(nameof(rules));
            _lane = lane ?? throw new ArgumentNullException(nameof(lane));
            _planning = planning;
            _rng = new Rng(seed);

            _cell = 70.0;
            _cols = (int)Math.Ceiling(_lane.Length / _cell) + 2;
            _rows = (int)Math.Ceiling(_lane.Width / _cell) + 2;
            _buckets = new List<int>[_cols * _rows];
            for (int i = 0; i < _buckets.Length; i++) _buckets[i] = new List<int>(8);
        }

        // =================================================================
        // 编成
        // =================================================================
        public void AddArmy(IEnumerable<PlannedSquad> army, RoundModifiers mods)
        {
            var byRole = new Dictionary<string, List<PlannedSquad>>(StringComparer.Ordinal);
            foreach (var sq in army)
            {
                UnitDef def = _units.Get(sq.UnitId);
                if (def == null || !def.Enabled) continue;
                string role = RoleOf(def);
                if (!byRole.TryGetValue(role, out var list))
                {
                    list = new List<PlannedSquad>();
                    byRole[role] = list;
                }
                list.Add(sq);
            }

            foreach (var kv in byRole)
            {
                var list = kv.Value;
                list.Sort((a, b) =>
                {
                    int c = b.Star.CompareTo(a.Star); // 高星先上，站中间
                    if (c != 0) return c;
                    return string.CompareOrdinal(a.UnitId, b.UnitId);
                });
                for (int i = 0; i < list.Count; i++)
                {
                    SpawnPlayerSquad(list[i], RoleBand(i, list.Count), mods);
                }
            }
        }

        public void ScheduleWave(Wave wave, int side)
        {
            if (wave == null) return;
            _waves.Add(new ScheduledWave { T = wave.T, Side = side, Wave = wave });
            _waves.Sort((a, b) => a.T.CompareTo(b.T));
        }

        private static string RoleOf(UnitDef def)
        {
            if (def.AttackRange <= 120.0) return "front";
            if (def.AttackRange < 300.0) return "pike";
            return "ranged";
        }

        private double RoleX(int side, string role)
        {
            // 玩家在左（向 +x 推进），敌人在右（向 -x 推进）
            if (side == 0)
            {
                if (role == "front") return _lane.PlayerSpawnX + 90.0;
                if (role == "pike") return _lane.PlayerSpawnX;
                return Math.Max(_lane.PlayerSpawnX - 360.0, 80.0);
            }
            if (role == "front") return _lane.EnemySpawnX - 90.0;
            if (role == "pike") return _lane.EnemySpawnX;
            return Math.Min(_lane.EnemySpawnX + 360.0, _lane.Length - 80.0);
        }

        private double RoleBand(int index, int count)
        {
            if (count <= 1) return 0.0;
            double usable = _lane.Width * 0.68;
            return -usable * 0.5 + (index + 0.5) * usable / count;
        }

        private void SpawnPlayerSquad(PlannedSquad sq, double band, RoundModifiers mods)
        {
            UnitDef def = _units.Get(sq.UnitId);
            if (def == null) return;
            string role = RoleOf(def);
            SpawnSquad(0, def, sq.Star, RoleX(0, role), band, mods);
        }

        private void SpawnSquad(int side, UnitDef def, int star, double frontX, double band, RoundModifiers mods)
        {
            var squad = new LaneSquad
            {
                Id = _squads.Count,
                Side = side,
                UnitId = def.Id,
                Star = star,
            };
            _squads.Add(squad);

            double radius = UnitsOf(def.BodyRadius);
            double spacing = radius * 2.05;
            int n = Math.Max(def.SquadSize, 1);
            bool ranged = def.Projectile;
            int cols = ranged && n > 2 ? (int)Math.Ceiling(n / 2.0) : n;
            if (cols < 1) cols = 1;
            int rows = (int)Math.Ceiling(n / (double)cols);

            double starAtk = _planning != null ? _planning.StarAttackMult(star) : 1.0;
            double starHp = _planning != null ? _planning.StarHpMult(star) : 1.0;
            double armorMult = mods != null && mods.ArmorMult > 0.0 ? mods.ArmorMult : 1.0;
            double moveMult = mods != null && mods.MoveMult > 0.0 ? mods.MoveMult : 1.0;
            double critAdd = mods != null ? mods.CritAdd : 0.0;

            for (int i = 0; i < n; i++)
            {
                int col = i % cols;
                int row = i / cols;
                double y = band + (col - (cols - 1) * 0.5) * spacing;
                double x;
                if (side == 0)
                    x = frontX - row * spacing;
                else
                    x = frontX + row * spacing;

                x = Clamp(x, radius, _lane.Length - radius);
                y = Clamp(y, -_lane.HalfWidth + radius, _lane.HalfWidth - radius);

                var m = new LaneModel
                {
                    Side = side,
                    Squad = squad.Id,
                    Def = def,
                    Star = star,
                    X = x,
                    Y = y,
                    MaxHp = def.Hp * starHp,
                    Hp = def.Hp * starHp,
                    Cd = _rng.NextFloat() * 0.3,
                    Retarget = _rng.NextFloat() * 0.2,
                    Range = def.AttackRange,
                    Damage = def.AttackDamage * starAtk,
                    Armor = def.Armor,
                    Hit = def.Hit,
                    Dodge = def.Dodge,
                    Crit = def.Crit + critAdd,
                    PenFlat = def.ArmorPenFlat,
                    PenPct = def.ArmorPenPct,
                    MoveSpeed = UnitsOf(def.MoveSpeed) * moveMult,
                    Radius = radius,
                    Projectile = def.Projectile,
                    ProjectileSpeed = UnitsOf(def.ProjectileSpeed),
                    AttackType = def.AttackType,
                    ArmorType = def.ArmorType,
                    ArmorMult = armorMult,
                };
                _models.Add(m);
                squad.Models.Add(_models.Count - 1);
            }

            if (side == 0) _result.PlayerSquadsSpawned += 1;
            else _result.EnemySquadsSpawned += 1;
        }

        private static double UnitsOf(double meters) => RtsUnits.ToUnits(meters);

        // =================================================================
        // 跑一轮
        // =================================================================
        public RoundResult Run(double seconds, double playerBaseHp, double enemyBaseHp,
            double playerDrainReduction = 0.0, double enemyDrainReduction = 0.0,
            string kind = "", string label = "")
        {
            _result.Kind = kind;
            _result.Label = label;
            _playerBaseHp = Math.Max(playerBaseHp, 0.0);
            _enemyBaseHp = Math.Max(enemyBaseHp, 0.0);
            _result.PlayerBaseHpStart = _playerBaseHp;
            _result.EnemyBaseHpStart = _enemyBaseHp;
            _playerDrainReduction = Clamp(playerDrainReduction, 0.0, 0.9);
            _enemyDrainReduction = Clamp(enemyDrainReduction, 0.0, 0.9);
            _t = 0.0;

            SpawnDueWaves(0.0);

            while (_t < seconds - Eps)
            {
                double step = Math.Min(Dt, seconds - _t);
                _t += step;
                SpawnDueWaves(_t);
                Tick(step);
                if (_playerBaseHp <= 0.0 || _enemyBaseHp <= 0.0) break;
            }

            _result.Seconds = Round2(_t);
            _result.PlayerBaseHp = Math.Max(_playerBaseHp, 0.0);
            _result.EnemyBaseHp = Math.Max(_enemyBaseHp, 0.0);
            _result.PlayerBaseDestroyed = _playerBaseHp <= 0.0;
            _result.EnemyBaseDestroyed = _enemyBaseHp <= 0.0;
            _result.AvgPikeGapMeters = _pikeGapSamples > 0
                ? Round3(_pikeGapSum / _pikeGapSamples * RtsUnits.R1)
                : 0.0;
            return _result;
        }

        private void SpawnDueWaves(double t)
        {
            while (_nextWave < _waves.Count && t + Eps >= _waves[_nextWave].T)
            {
                var sw = _waves[_nextWave];
                _nextWave += 1;
                SpawnWave(sw);
            }
        }

        private void SpawnWave(ScheduledWave sw)
        {
            var all = sw.Wave.Squads;
            int total = 0;
            foreach (var s in all) total += Math.Max(s.Count, 1);
            int index = 0;
            foreach (var entry in all)
            {
                UnitDef def = _units.Get(entry.Unit);
                if (def == null || !def.Enabled) continue;
                string role = RoleOf(def);
                int count = Math.Max(entry.Count, 1);
                for (int k = 0; k < count; k++)
                {
                    double band = RoleBand(index, total);
                    SpawnSquad(sw.Side, def, entry.Star, RoleX(sw.Side, role), band, null);
                    index += 1;
                }
            }
        }

        // =================================================================
        // 每步
        // =================================================================
        private void Tick(double dt)
        {
            _sampleTick += 1;

            // 1) 冷却与索敌
            for (int i = 0; i < _models.Count; i++)
            {
                var m = _models[i];
                if (!m.Alive) continue;
                if (m.Cd > 0.0) m.Cd = Math.Max(m.Cd - dt, 0.0);
                if (m.Retarget > 0.0) m.Retarget -= dt;

                if (m.Target < 0 || !IsValidTarget(m.Target, m.Side))
                {
                    m.Target = FindNearestEnemy(m);
                    m.Retarget = 0.2 + _rng.NextFloat() * 0.12;
                }
                else if (m.Retarget <= 0.0)
                {
                    m.Target = FindNearestEnemy(m);
                    m.Retarget = 0.2 + _rng.NextFloat() * 0.12;
                }
            }

            // 2) 推进
            for (int i = 0; i < _models.Count; i++)
            {
                var m = _models[i];
                if (!m.Alive) continue;
                StepMove(m, dt);
            }

            // 3) 圆形轻量排斥（位置约束，两遍）
            ResolveOverlaps();
            ResolveOverlaps();

            // 4) 出手
            for (int i = 0; i < _models.Count; i++)
            {
                if (!_models[i].Alive) continue;
                TryAttack(i);
            }

            // 5) 投射物
            UpdateProjectiles(dt);

            // 6) 清点阵亡
            CleanupDead();
            TrackMaxAlive();

            // 7) 更新小队质心 + 基地抽血
            UpdateSquadsAndBases(dt);

            // 8) 队形采样（每 0.5 秒）
            if (_sampleTick % 10 == 0) SamplePikeGap();
        }

        private void StepMove(LaneModel m, double dt)
        {
            LaneModel target = m.Target >= 0 && IsValidTarget(m.Target, m.Side) ? _models[m.Target] : null;
            double dist = double.MaxValue;
            double reach = m.Range + RangeSlack;
            bool inRange = false;
            if (target != null)
            {
                double dx = target.X - m.X;
                double dy = target.Y - m.Y;
                dist = Math.Sqrt(dx * dx + dy * dy);
                inRange = dist <= reach;
            }

            // 长枪的站位纪律：没打到人时先回到“步兵身后 0.9 米”的槽位。
            // 这是 155 = 95 + 2×0.45/R1 的几何保证：不靠它，长枪会自己冲到前排。
            if (m.IsPike && !inRange)
            {
                LaneModel anchor = FindFrontAnchor(m);
                if (anchor != null)
                {
                    double dir = m.Side == 0 ? 1.0 : -1.0;
                    double slotX = anchor.X - dir * UnitsOf(0.9);
                    MoveToward(m, slotX, anchor.Y, dt);
                    ClampModel(m);
                    return;
                }
            }

            if (target != null)
            {
                if (inRange || dist < 1e-6)
                {
                    ClampModel(m);
                    return;
                }

                // 只走到射程边界，避免 20Hz 步长冲过头
                double want = Math.Min(dist - m.Range, m.MoveSpeed * dt);
                if (want <= 0.0)
                {
                    ClampModel(m);
                    return;
                }
                double k = want / dist;
                m.X += (target.X - m.X) * k;
                m.Y += (target.Y - m.Y) * k;
            }
            else
            {
                // 全歼后继续越线：走向敌方基地（停在 base_stop）
                double goalX = m.Side == 0 ? _lane.Length - _lane.BaseStop : _lane.BaseStop;
                double dx = goalX - m.X;
                double step = Math.Min(Math.Abs(dx), m.MoveSpeed * dt);
                if (step > 0.0) m.X += Math.Sign(dx) * step;
                // 向中线靠拢，避免贴墙
                m.Y += (0.0 - m.Y) * Math.Min(1.0, dt * 2.0);
            }

            ClampModel(m);
        }

        private void MoveToward(LaneModel m, double tx, double ty, double dt)
        {
            double dx = tx - m.X;
            double dy = ty - m.Y;
            double d = Math.Sqrt(dx * dx + dy * dy);
            if (d < 0.5) return;
            double step = Math.Min(d, m.MoveSpeed * dt);
            m.X += dx / d * step;
            m.Y += dy / d * step;
        }

        private void ClampModel(LaneModel m)
        {
            m.X = Clamp(m.X, m.Radius, _lane.Length - m.Radius);
            m.Y = Clamp(m.Y, -_lane.HalfWidth + m.Radius, _lane.HalfWidth - m.Radius);
        }

        /// <summary>找同一侧、同一横向走廊里最合适的“前排步兵”当锚点。</summary>
        private LaneModel FindFrontAnchor(LaneModel pike)
        {
            double dir = pike.Side == 0 ? 1.0 : -1.0;
            double maxDy = UnitsOf(1.6);
            double ideal = UnitsOf(0.9);
            LaneModel best = null;
            double bestScore = double.MaxValue;
            for (int i = 0; i < _models.Count; i++)
            {
                var f = _models[i];
                if (!f.Alive || f.Side != pike.Side || f.Squad == pike.Squad) continue;
                if (!f.IsFrontMelee) continue;
                double dy = Math.Abs(f.Y - pike.Y);
                if (dy > maxDy) continue;
                double ahead = (f.X - pike.X) * dir;
                if (Math.Abs(ahead) > UnitsOf(8.0)) continue;
                double score = dy * 1.6 + Math.Abs(ahead - ideal);
                if (ahead < 0.0) score += UnitsOf(0.6);
                if (score < bestScore)
                {
                    bestScore = score;
                    best = f;
                }
            }
            return best;
        }

        private void TryAttack(int index)
        {
            var m = _models[index];
            if (m.Cd > 0.0) return;
            if (m.Target < 0 || !IsValidTarget(m.Target, m.Side)) return;
            var target = _models[m.Target];
            double dx = target.X - m.X;
            double dy = target.Y - m.Y;
            double dist = Math.Sqrt(dx * dx + dy * dy);
            if (dist > m.Range + RangeSlack) return;

            {
                var atk = new CombatAttacker
                {
                    Damage = m.Damage,
                    Cooldown = m.Def.AttackCooldown,
                    AttackType = m.AttackType,
                    Hit = m.Hit,
                    CritChance = m.Crit,
                    CritMultiplier = 0.0,
                    ArmorPenFlat = m.PenFlat,
                    ArmorPenPct = m.PenPct,
                    AttackMult = 1.0,
                };
                var def = new CombatDefender
                {
                    Armor = target.Armor,
                    ArmorType = target.ArmorType,
                    Dodge = target.Dodge,
                    ArmorMult = target.ArmorMult,
                    DamageTakenMult = target.DamageTakenMult,
                };

                double rollHit = _rng.NextFloat();
                double rollCrit = _rng.NextFloat();
                var br = CombatCalculator.Compute(atk, def, _rules, rollHit, rollCrit);

                if (m.Side == 0)
                {
                    if (m.Def.Projectile) _result.PlayerShots += 1;
                    if (br.Hit && m.Def.Projectile) _result.PlayerHits += 1;
                    if (m.IsPike)
                    {
                        _result.PikeAttacks += 1;
                        if (IsBehindFriendlyFront(m, target)) _result.PikeBehindAttacks += 1;
                    }
                }
                else
                {
                    if (m.Def.Projectile) _result.EnemyShots += 1;
                    if (br.Hit && m.Def.Projectile) _result.EnemyHits += 1;
                }

                if (br.Hit)
                {
                    if (m.Def.Projectile)
                    {
                        _shots.Add(new LaneProjectile
                        {
                            Side = m.Side,
                            Source = index,
                            X = m.X,
                            Y = m.Y,
                            Target = m.Target,
                            Speed = m.ProjectileSpeed > 0.0 ? m.ProjectileSpeed : UnitsOf(24.0),
                            Damage = br.Damage,
                            Crit = br.Crit,
                        });
                    }
                    else
                    {
                        ApplyDamage(m, target, br.Damage);
                    }
                }
                m.Cd = Math.Max(m.Def.AttackCooldown, 0.05);
            }
        }

        private void ApplyDamage(LaneModel source, LaneModel target, double damage)
        {
            if (target == null || !target.Alive || damage <= 0.0) return;
            target.Hp -= damage;
            source.DamageDealt += damage;
            if (_result.FirstContactSecond < 0.0) _result.FirstContactSecond = Round2(_t);
            if (target.Hp <= 0.0)
            {
                target.Hp = 0.0;
                target.Alive = false;
                source.Kills += 1;
            }
        }

        private bool IsBehindFriendlyFront(LaneModel pike, LaneModel target)
        {
            double dir = pike.Side == 0 ? 1.0 : -1.0;
            double targetX = target.X;
            for (int i = 0; i < _models.Count; i++)
            {
                var f = _models[i];
                if (!f.Alive || f.Side != pike.Side || f.Squad == pike.Squad) continue;
                if (!f.IsFrontMelee) continue;
                double ahead = (f.X - pike.X) * dir;
                double toTarget = (targetX - pike.X) * dir;
                if (ahead <= 0.0 || ahead >= toTarget) continue;
                if (Math.Abs(f.Y - pike.Y) <= UnitsOf(1.35)) return true;
            }
            return false;
        }

        private void SamplePikeGap()
        {
            double dir = 1.0;
            for (int i = 0; i < _models.Count; i++)
            {
                var p = _models[i];
                if (!p.Alive || p.Side != 0 || !p.IsPike) continue;

                // 只统计已经接敌的长枪；没接敌的“间距”没有意义
                bool engaged = false;
                for (int j = 0; j < _models.Count; j++)
                {
                    var e = _models[j];
                    if (!e.Alive || e.Side == p.Side) continue;
                    double dx = e.X - p.X;
                    double dy = e.Y - p.Y;
                    if (dx * dx + dy * dy <= UnitsOf(4.5) * UnitsOf(4.5))
                    {
                        engaged = true;
                        break;
                    }
                }
                if (!engaged) continue;

                _result.PikeFormationSamples += 1;

                double best = double.MaxValue;
                for (int j = 0; j < _models.Count; j++)
                {
                    var f = _models[j];
                    if (!f.Alive || f.Side != p.Side || !f.IsFrontMelee) continue;
                    double ahead = (f.X - p.X) * dir;
                    if (ahead <= 0.0) continue;
                    if (Math.Abs(f.Y - p.Y) > UnitsOf(1.35)) continue;
                    if (ahead >= UnitsOf(2.4)) continue;
                    if (ahead < best) best = ahead;
                }
                if (best < double.MaxValue)
                {
                    _result.PikeFormationBehind += 1;
                    // 间距只取“正前方”的步兵（横向 0.6 米内），避免斜后方把均值拉小
                    double gapBest = double.MaxValue;
                    for (int j = 0; j < _models.Count; j++)
                    {
                        var f = _models[j];
                        if (!f.Alive || f.Side != p.Side || !f.IsFrontMelee) continue;
                        if (Math.Abs(f.Y - p.Y) > UnitsOf(0.6)) continue;
                        double ahead = (f.X - p.X) * dir;
                        if (ahead <= 0.0) continue;
                        if (ahead < gapBest) gapBest = ahead;
                    }
                    if (gapBest < double.MaxValue)
                    {
                        _pikeGapSum += gapBest;
                        _pikeGapSamples += 1;
                    }
                }
            }
        }

        private void UpdateProjectiles(double dt)
        {
            for (int i = 0; i < _shots.Count; i++)
            {
                var p = _shots[i];
                if (!p.Alive) continue;
                if (p.Target < 0 || !IsValidTarget(p.Target, p.Side))
                {
                    p.Alive = false;
                    continue;
                }
                var target = _models[p.Target];
                double dx = target.X - p.X;
                double dy = target.Y - p.Y;
                double dist = Math.Sqrt(dx * dx + dy * dy);
                double step = p.Speed * dt;
                if (dist <= step + target.Radius)
                {
                    LaneModel source = p.Source >= 0 && p.Source < _models.Count ? _models[p.Source] : null;
                    if (source != null) ApplyDamage(source, target, p.Damage);
                    p.Alive = false;
                }
                else if (dist > 1e-6)
                {
                    p.X += dx / dist * step;
                    p.Y += dy / dist * step;
                }
            }
        }

        private void CleanupDead()
        {
            for (int i = 0; i < _models.Count; i++)
            {
                var m = _models[i];
                if (!m.Alive)
                {
                    if (!m.DeathCounted)
                    {
                        m.DeathCounted = true;
                        if (m.Side == 0) _result.PlayerModelsLost += 1;
                        else _result.EnemyModelsLost += 1;
                    }
                    continue;
                }
                if (m.Hp > 0.0) continue;
                m.Hp = 0.0;
                m.Alive = false;
                m.DeathCounted = true;
                if (m.Side == 0) _result.PlayerModelsLost += 1;
                else _result.EnemyModelsLost += 1;
            }

            for (int s = 0; s < _squads.Count; s++)
            {
                var squad = _squads[s];
                if (!squad.WasAlive) continue;
                bool alive = false;
                for (int k = 0; k < squad.Models.Count; k++)
                {
                    if (_models[squad.Models[k]].Alive)
                    {
                        alive = true;
                        break;
                    }
                }
                if (!alive)
                {
                    squad.WasAlive = false;
                    if (squad.Side == 0)
                    {
                        _result.PlayerSquadsLost += 1;
                        if (_result.FirstPlayerSquadLostSecond < 0.0)
                            _result.FirstPlayerSquadLostSecond = Round2(_t);
                    }
                    else
                    {
                        _result.EnemySquadsLost += 1;
                    }
                }
            }
        }

        private void TrackMaxAlive()
        {
            int p = 0, e = 0;
            for (int i = 0; i < _models.Count; i++)
            {
                var m = _models[i];
                if (!m.Alive) continue;
                if (m.Side == 0) p++;
                else e++;
            }
            if (p > _result.PlayerMaxModelsAlive) _result.PlayerMaxModelsAlive = p;
            if (e > _result.EnemyMaxModelsAlive) _result.EnemyMaxModelsAlive = e;
        }

        private void UpdateSquadsAndBases(double dt)
        {
            int playerInZone = 0;
            int enemyInZone = 0;
            double playerDps = 0.0;
            double enemyDps = 0.0;

            for (int s = 0; s < _squads.Count; s++)
            {
                var squad = _squads[s];
                if (!squad.WasAlive) continue;

                double sumX = 0.0, sumY = 0.0;
                int n = 0;
                for (int k = 0; k < squad.Models.Count; k++)
                {
                    var m = _models[squad.Models[k]];
                    if (!m.Alive) continue;
                    sumX += m.X;
                    sumY += m.Y;
                    n += 1;
                }
                if (n == 0) continue;
                squad.CentroidX = sumX / n;
                squad.CentroidY = sumY / n;

                bool inZone = squad.Side == 0
                    ? squad.CentroidX >= _lane.EnemyZoneStart
                    : squad.CentroidX <= _lane.PlayerZoneEnd;
                if (!inZone) continue;

                squad.ZoneSeconds += dt;
                if (squad.Side == 0)
                {
                    playerInZone += 1;
                    _result.PlayerZoneSeconds += dt;
                    if (!HasEnemyNear(squad.CentroidX, squad.CentroidY, 0))
                        playerDps += 1.0;
                }
                else
                {
                    enemyInZone += 1;
                    _result.EnemyZoneSeconds += dt;
                    if (!HasEnemyNear(squad.CentroidX, squad.CentroidY, 1))
                        enemyDps += 1.0;
                }
            }

            if (playerInZone > _result.PlayerMaxSquadsInZone) _result.PlayerMaxSquadsInZone = playerInZone;
            if (enemyInZone > _result.EnemyMaxSquadsInZone) _result.EnemyMaxSquadsInZone = enemyInZone;

            if (playerDps > 0.0 && _enemyBaseHp > 0.0)
            {
                double dmg = playerDps * _lane.ZoneDpsPerSquad * (1.0 - _enemyDrainReduction) * dt;
                _enemyBaseHp -= dmg;
                _result.PlayerBaseDamage += dmg;
                if (_result.FirstContactSecond < 0.0) _result.FirstContactSecond = Round2(_t);
            }
            if (enemyDps > 0.0 && _playerBaseHp > 0.0)
            {
                double dmg = enemyDps * _lane.ZoneDpsPerSquad * (1.0 - _playerDrainReduction) * dt;
                _playerBaseHp -= dmg;
                _result.EnemyBaseDamage += dmg;
                if (_result.FirstContactSecond < 0.0) _result.FirstContactSecond = Round2(_t);
            }

            _result.PlayerDamageDealt = 0.0;
            _result.EnemyDamageDealt = 0.0;
            for (int i = 0; i < _models.Count; i++)
            {
                var m = _models[i];
                if (m.Side == 0) _result.PlayerDamageDealt += m.DamageDealt;
                else _result.EnemyDamageDealt += m.DamageDealt;
            }
        }

        private bool HasEnemyNear(double x, double y, int mySide)
        {
            double r = UnitsOf(9.0); // 9 米内有敌人 = 交战中，不抽血
            double r2 = r * r;
            for (int i = 0; i < _models.Count; i++)
            {
                var m = _models[i];
                if (!m.Alive || m.Side == mySide) continue;
                double dx = m.X - x;
                double dy = m.Y - y;
                if (dx * dx + dy * dy <= r2) return true;
            }
            return false;
        }

        // =================================================================
        // 索敌 / 排斥
        // =================================================================
        private bool IsValidTarget(int index, int mySide)
        {
            if (index < 0 || index >= _models.Count) return false;
            var t = _models[index];
            return t.Alive && t.Side != mySide;
        }

        private int FindNearestEnemy(LaneModel m)
        {
            int best = -1;
            double bestD = double.MaxValue;
            for (int i = 0; i < _models.Count; i++)
            {
                var e = _models[i];
                if (!e.Alive || e.Side == m.Side) continue;
                double dx = e.X - m.X;
                double dy = e.Y - m.Y;
                double d = dx * dx + dy * dy;
                if (d < bestD)
                {
                    bestD = d;
                    best = i;
                }
            }
            return best;
        }

        private void ResolveOverlaps()
        {
            for (int i = 0; i < _buckets.Length; i++) _buckets[i].Clear();

            for (int i = 0; i < _models.Count; i++)
            {
                var m = _models[i];
                if (!m.Alive) continue;
                int cx = ClampInt((int)(m.X / _cell), 0, _cols - 1);
                int cy = ClampInt((int)((m.Y + _lane.HalfWidth) / _cell), 0, _rows - 1);
                _buckets[cy * _cols + cx].Add(i);
            }

            for (int i = 0; i < _models.Count; i++)
            {
                var a = _models[i];
                if (!a.Alive) continue;
                int cx = ClampInt((int)(a.X / _cell), 0, _cols - 1);
                int cy = ClampInt((int)((a.Y + _lane.HalfWidth) / _cell), 0, _rows - 1);
                for (int oy = -1; oy <= 1; oy++)
                {
                    int ry = cy + oy;
                    if (ry < 0 || ry >= _rows) continue;
                    for (int ox = -1; ox <= 1; ox++)
                    {
                        int rx = cx + ox;
                        if (rx < 0 || rx >= _cols) continue;
                        var bucket = _buckets[ry * _cols + rx];
                        for (int k = 0; k < bucket.Count; k++)
                        {
                            int j = bucket[k];
                            if (j <= i) continue;
                            var b = _models[j];
                            if (!b.Alive) continue;

                            double dx = a.X - b.X;
                            double dy = a.Y - b.Y;
                            double min = a.Radius + b.Radius;
                            double d2 = dx * dx + dy * dy;
                            if (d2 >= min * min) continue;

                            double d = Math.Sqrt(d2);
                            if (d < 1e-9)
                            {
                                // 完全重合：用稳定的伪角度分开，不用随机（确定性）
                                double ang = (i * 2.399963 + j * 0.7) % (Math.PI * 2.0);
                                dx = Math.Cos(ang);
                                dy = Math.Sin(ang);
                                d = 1.0;
                            }
                            double overlap = min - d;
                            double nx = dx / d;
                            double ny = dy / d;
                            a.X += nx * overlap * 0.5;
                            a.Y += ny * overlap * 0.5;
                            b.X -= nx * overlap * 0.5;
                            b.Y -= ny * overlap * 0.5;
                        }
                    }
                }
            }

            for (int i = 0; i < _models.Count; i++)
            {
                var m = _models[i];
                if (!m.Alive) continue;
                m.X = Clamp(m.X, m.Radius, _lane.Length - m.Radius);
                m.Y = Clamp(m.Y, -_lane.HalfWidth + m.Radius, _lane.HalfWidth - m.Radius);
            }
        }

        // =================================================================
        // 小工具
        // =================================================================
        private static double Clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);
        private static int ClampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
        private static double Round2(double v) => Math.Round(v * 100.0) / 100.0;
        private static double Round3(double v) => Math.Round(v * 1000.0) / 1000.0;
    }
}
