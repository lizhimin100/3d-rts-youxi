using System;
using System.Collections.Generic;
using Vec2 = System.Numerics.Vector2;

namespace WarIsland.Model
{
    internal sealed class SquadMember
    {
        public int Index;
        public double OffsetX;
        public double OffsetZ;
        public double X;
        public double Z;
        public double Hp;
        public double MaxHp;
        public double Cd;
        public double Retarget;
        public int Target = -1;
        public bool Alive = true;
        public double DamageDealt;
        public int Kills;
    }

    internal sealed class BattleSquad
    {
        public int Id;
        public int Side;
        public UnitDef Def;
        public int Star;
        public double X;
        public double Z;
        public double Heading;
        public double Hp;
        public double HpMax;
        public double Speed;
        public double Radius;
        /// <summary>接触半径：阵型实际铺开半径 + 一个身位（比导航半径小，允许近战贴上来）。</summary>
        public double ContactRadius;
        public double MaxRange;
        public double MoveMult = 1.0;
        public double ArmorMult = 1.0;
        public double CritAdd;
        // ---- 2026-11-24：数据修饰器（ArmyPlan.Modifiers）与静止塔 ----
        /// <summary>攻击倍率（光环/遗物），只乘基础伤害。</summary>
        public double AttackMult = 1.0;
        /// <summary>额外护甲（光环），加在装甲值上。</summary>
        public double ArmorAdd;
        /// <summary>承伤倍率（减伤光环），&lt;1 = 更耐打。</summary>
        public double DamageTakenMult = 1.0;
        /// <summary>静止实体（哨塔/箭塔）：不移动、invMass=0。</summary>
        public bool Static;

        public SquadOrder Order = SquadOrder.Hold;
        public double OrderX;
        public double OrderZ;
        public int TargetSquad = -1;

        public readonly List<Vec2> Path = new List<Vec2>();
        public int PathIndex;
        public double PathLength;
        public double Travelled;
        public double StuckTimer;
        public double StuckX;
        public double StuckZ;

        public readonly List<SquadMember> Members = new List<SquadMember>();
        /// <summary>
        /// 攻击态质量锁定（2026-11-24 修正）：
        /// 只要射程内（R+4）有活目标，这名单兵 `invMass=0` —— **推不动，但仍按份额推别人**；
        /// 硬核在所有情况下生效。2026-11-22 的"整对跳过分离"已删除：那会让增援穿过正在对砍的人、
        /// 两个锁定单位叠在同一点，目标死后又一次性弹开。
        /// </summary>
        public bool Locked;
        /// <summary>
        /// 是否"正在打"（R+4 实际开火线，带 0.25 s 滞回）。表现层用它播攻击动作；
        /// 与 <see cref="Locked"/> 的区别：Locked 是"推不动"的质量状态（R+4，无滞回），
        /// Engaged 是"够得着"的稳定表现态（R+4 进、R+12 出）。
        /// </summary>
        public bool Engaged;
        /// <summary>朝向反转计数：上一次转向的方向 / 连续转过多少 / 反转后累计多少。</summary>
        public int LastTurnSign;
        public double TurnAccum;
        public double FlipAccum;
        public int AliveCount;
        public double DamageDealt;
        public int Kills;
        public int ModelsLost;
        public double MemberSeconds;
        public double SquadSeconds;
        public double SlotErrorSum;
        public int SlotErrorSamples;
        public bool WasAlive = true;
        public double Age;

        public int SpawnTile;
        public string SourceBuilding = "";
        /// <summary>attack / defend / ""（不限时空）。</summary>
        public string Role = SquadRoles.Any;
        /// <summary>轮末清场：被抹掉的小队不再参与任何结算，也不再出现在快照里。</summary>
        public bool Purged;
        /// <summary>本 tick 是否"想动"（卡住检测只看它，交战中原地对砍不算卡住）。</summary>
        public bool WantsMove;

        public bool Alive => WasAlive && AliveCount > 0;
    }

    internal sealed class SquadShot
    {
        public int Side;
        public int SourceSquad;
        public int SourceMember;
        public int TargetSquad;
        public int TargetMember;
        public double X;
        public double Z;
        public double Speed;
        public double Damage;
        /// <summary>跳字反馈等级（暴击/克制 = 红，被抵抗 = 白，普通 = 常规）。</summary>
        public DamageFeedback Feedback;
        public bool Alive = true;
    }

    internal sealed class SquadWaveEntry
    {
        public double T;
        public int Side;
        public int Tile;
        public Wave Wave;
        /// <summary>波次出生锚点（世界米）；0/0 表示回退到格子锚点。</summary>
        public double AnchorX;
        public double AnchorZ;
        public int DirX = 1;
        public bool UseLineAnchor;
    }

    /// <summary>
    /// 战斗内核（纯 C#，20Hz 固定步长）。
    ///
    /// 原子性（2026-11-22 起）：
    ///   · **一个实体 = 一名独立单兵**：自己寻路、自己索敌、自己受击、自己死；
    ///     没有小队编制、没有阵型槽位、没有队内分散 AI（`SquadFormation.cs` 已删除）；
    ///   · 成员列表恒定 1 项，且**槽位就是质心**（offset 0,0）——
    ///     保留 Members 是为了跨语言快照契约（GDScript 仍按 members[0] 读血条/位置），
    ///     但成员不再有任何独立位移，所以"槽位误差"这一指标恒为 0。
    ///
    /// 导航：
    ///   · 每名单兵沿 <see cref="SquadRouteGraph"/> 规划的脊线路径推进，局部靠圆-圆分离避障；
    ///   · 进入攻击态（射程内有活目标）→ <see cref="BattleSquad.Locked"/> 置真，
    ///     位置冻结、分离跳过：这是"接敌不被推走"的唯一实现；
    ///   · 建筑不参与寻路（设计口径），所以这里没有任何格子/占格查询。
    ///
    /// 坐标：
    ///   · 内部一律**游戏数值**（lane 坐标：X 沿战场、Y 横向）；
    ///   · 对外的 Add/Order/Pick/View 用**世界米**，由 <see cref="SquadArena"/> 唯一换算。
    /// </summary>
    public sealed class SquadBattle
    {
        private const double Dt = 0.05;
        private const double Eps = 1e-9;
        /// <summary>近战判定容差（游戏数值）：0.06 米。</summary>
        private const double RangeSlack = 4.0;
        /// <summary>
        /// 硬核系数在 `SquadTuning.HardCoreFactor`（默认 0.90），不再有 1.55。
        /// 1.55×身位和 经常大于近战射程（领主 vs 步兵 110.5 &gt; 99），是"够不着"的根因；
        /// 行军间距由 <see cref="FormationPlan.FilePitchDefault"/>（96）保证，碰撞只留一个半径。
        /// </summary>
        /// <summary>攻击态判定的额外容差（游戏数值）：0.12 米，射程边界不抖。</summary>
        private const double LockSlack = 8.0;
        /// <summary>攻击移动的最小索敌半径（游戏数值）= 9 米；远程按自身射程 ×1.6 放宽。</summary>
        private const double DetectRadius = 600.0;
        /// <summary>驻守时的自动索敌半径下限（游戏数值）= 7.5 米。</summary>
        private const double HoldDetectMin = 500.0;
        /// <summary>
        /// 重叠读数的固定标尺（0.90×身位和）。**不跟随配置变化**，
        /// 这样改前/改后的 overlap 指标是同一把尺子；正常贴身（d≈硬核）不算深叠。
        /// </summary>
        private const double MetricHardCoreFactor = 0.90;

        private readonly UnitCatalog _units;
        private readonly CombatRules _rules;
        private readonly SquadArena _arena;
        private readonly PlanningConfig _planning;
        private readonly SquadTuning _tuning;
        private readonly Rng _rng;
        private readonly SquadRouteGraph _route;

        /// <summary>每格已用到的阵位号：同一格连出多批时继续往后排，绝不回到同一组点。</summary>
        private readonly Dictionary<int, int> _tileCursor = new Dictionary<int, int>();

        private readonly List<BattleSquad> _squads = new List<BattleSquad>();
        private readonly List<SquadShot> _shots = new List<SquadShot>();
        private readonly List<SquadWaveEntry> _waves = new List<SquadWaveEntry>();
        private int _nextWave;
        private int _nextSquadId = 1;

        private double _acc;
        private double _time;
        private double _playerBaseHp;
        private double _enemyBaseHp;
        private double _playerBaseHpMax;
        private double _enemyBaseHpMax;
        private double _playerDrainReduction;
        private double _enemyDrainReduction;
        private bool _finished;
        private string _outcome = "";
        private readonly SquadBattleStats _stats = new SquadBattleStats();
        private readonly RoundModifiers _playerMods = new RoundModifiers();
        private readonly RoundModifiers _enemyMods = new RoundModifiers();
        private ArmyModifiers _playerArmyMods = new ArmyModifiers();
        private bool _berserk;
        private double _berserkAt = -1.0;

        public SquadBattle(UnitCatalog units, CombatRules rules, SquadArena arena, PlanningConfig planning, int seed,
            SquadTuning tuning = null)
        {
            _units = units ?? throw new ArgumentNullException(nameof(units));
            _rules = rules ?? throw new ArgumentNullException(nameof(rules));
            _arena = arena ?? throw new ArgumentNullException(nameof(arena));
            _planning = planning;
            _tuning = tuning ?? new SquadTuning();
            _rng = new Rng(seed);
            _route = arena.Route;
            _playerBaseHp = Math.Max(arena.PlayerBaseHp, 0.0);
            _enemyBaseHp = Math.Max(arena.EnemyBaseHp, 0.0);
            _playerBaseHpMax = _playerBaseHp;
            _enemyBaseHpMax = _enemyBaseHp;
        }

        public SquadArena Arena => _arena;
        public UnitCatalog Units => _units;
        public double Time => _time;
        public bool Finished => _finished;
        public string Outcome => _outcome;

        // =================================================================
        // 时间倍率（1x / 2x）
        //
        // 玩家口径（2026-11-21）："战斗控制器预留时间倍率接口（支持 1x / 2x 倍速）"。
        // 实现口径：
        //   · 只改**推进速率**，不改任何数值（伤害 / 射程 / 抽血一律按模型时间算），
        //     所以 2x 与 1x 跑固定模型的最终结果**完全一致**，只是更快看完；
        //   · 固定步长 Dt 不变（20Hz 逻辑），倍率乘在 Step 的输入 delta 上 ——
        //     绝不把 Dt 乘大，否则碰撞/攻击节奏会变，等于换了一套物理。
        // =================================================================
        public const double TimeScaleMin = 1.0;
        public const double TimeScaleMax = 2.0;
        private double _timeScale = TimeScaleMin;

        public double TimeScale
        {
            get => _timeScale;
            set => _timeScale = Math.Max(TimeScaleMin, Math.Min(TimeScaleMax, value));
        }
        public SquadBattleStats Stats => _stats;
        public int SquadCount
        {
            get
            {
                int n = 0;
                for (int i = 0; i < _squads.Count; i++) if (_squads[i].Alive) n++;
                return n;
            }
        }

        /// <summary>
        /// 当前时空角色（attack / defend / "" = 不限）。
        /// 只有 <see cref="SquadRoles.ActiveIn"/> 为真的队伍会被推进、被索敌、被抽血；
        /// 其余队伍"存在但冻结"，Screens 通过 <see cref="SquadView.Active"/> 决定是否画出来。
        /// </summary>
        public string ActiveRole { get; private set; } = SquadRoles.Any;

        public double PlayerBaseHp => Math.Max(_playerBaseHp, 0.0);
        public double EnemyBaseHp => Math.Max(_enemyBaseHp, 0.0);
        public double PlayerBaseHpMax => _playerBaseHpMax;
        public double EnemyBaseHpMax => _enemyBaseHpMax;

        public void SetBaseHp(double playerHp, double enemyHp)
        {
            SetBaseHp(playerHp, enemyHp, playerHp, enemyHp);
        }

        /// <summary>设置当前基地血与**血条上限**（跨轮时上限保持不变，否则血条永远满格）。</summary>
        public void SetBaseHp(double playerHp, double enemyHp, double playerMax, double enemyMax)
        {
            _playerBaseHp = Math.Max(playerHp, 0.0);
            _enemyBaseHp = Math.Max(enemyHp, 0.0);
            _playerBaseHpMax = Math.Max(playerMax, 1e-9);
            _enemyBaseHpMax = Math.Max(enemyMax, 1e-9);
        }

        public void SetDrainReduction(double player, double enemy)
        {
            _playerDrainReduction = Clamp01(player);
            _enemyDrainReduction = Clamp01(enemy);
        }

        public void SetModifiers(RoundModifiers player, RoundModifiers enemy)
        {
            CopyMods(_playerMods, player);
            CopyMods(_enemyMods, enemy);
        }

        /// <summary>
        /// 灌入 ArmyPlan 的数据修饰器（光环/遗物）。战斗内核不认识建筑 id，
        /// 只按来源建筑 key 取一组乘数，落到每个单兵身上。
        /// </summary>
        public void SetArmyModifiers(ArmyModifiers mods)
        {
            _playerArmyMods = mods ?? new ArmyModifiers();
        }

        /// <summary>45 秒狂暴是否已触发（结算/报告用）。</summary>
        public bool Berserk => _berserk;
        public double BerserkAt => _berserkAt;

        /// <summary>
        /// 把当前策略加成重新灌到已经落地的小队上（即时出兵模式下，
        /// 玩家可能先出队再打策略牌；速度/护甲/暴击要立刻生效）。
        /// </summary>
        public void RefreshModifiers()
        {
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.Alive || !IsActive(s)) continue;
                var mods = s.Side == 0 ? _playerMods : _enemyMods;
                s.MoveMult = mods.MoveMult > 0.0 ? mods.MoveMult : 1.0;
                s.ArmorMult = mods.ArmorMult > 0.0 ? mods.ArmorMult : 1.0;
                s.CritAdd = mods.CritAdd;
                s.Speed = s.Static ? 0.0 : RtsUnits.ToUnits(s.Def.MoveSpeed) * s.MoveMult;
            }
        }

        private static void CopyMods(RoundModifiers dst, RoundModifiers src)
        {
            dst.Reset();
            if (src == null) return;
            dst.MoveMult = src.MoveMult > 0.0 ? src.MoveMult : 1.0;
            dst.ArmorMult = src.ArmorMult > 0.0 ? src.ArmorMult : 1.0;
            dst.CritAdd = src.CritAdd;
            dst.Active.AddRange(src.Active);
        }

        // =================================================================
        // 出兵
        // =================================================================
        public int AddSquad(int side, string unitId, int star, double worldX, double worldZ, string sourceBuilding = "", int spawnTile = 0)
        {
            return AddSquadRole(side, unitId, star, worldX, worldZ, sourceBuilding, spawnTile, SquadRoles.Any);
        }

        /// <summary>
        /// 生成**一名独立单兵**（<paramref name="role"/> = attack / defend / ""）。
        /// 角色决定它在哪一场里被推进；<see cref="SquadRoles.Any"/> 两场都在。
        /// </summary>
        public int AddSquadRole(int side, string unitId, int star, double worldX, double worldZ,
            string sourceBuilding, int spawnTile, string role)
        {
            return AddSquadEx(side, unitId, star, worldX, worldZ, sourceBuilding, spawnTile, role, null);
        }

        /// <summary>
        /// 带数据修饰器的单兵生成（BattleSession 的唯一入口）。
        /// <paramref name="mods"/> 为 null 时等价于"无光环"。
        /// </summary>
        public int AddSquadEx(int side, string unitId, int star, double worldX, double worldZ,
            string sourceBuilding, int spawnTile, string role, ModifierSet mods)
        {
            UnitDef def = _units.Get(unitId);
            if (def == null || !def.Enabled) return -1;
            if (!SquadRoles.IsValid(role)) role = SquadRoles.Any;

            var lane = _arena.WorldToLane(worldX, worldZ);
            double radius = def.NavRadius;
            lane = _route.ClampPoint(lane, radius);

            var squad = new BattleSquad
            {
                Id = _nextSquadId++,
                Side = side,
                Def = def,
                Star = Math.Max(star, 1),
                X = lane.X,
                Z = lane.Y,
                Heading = side == 0 ? 0.0 : Math.PI,
                Radius = radius,
                MaxRange = Math.Max(def.AttackRange, 10.0),
                SpawnTile = spawnTile,
                SourceBuilding = sourceBuilding ?? "",
                Role = role,
                Static = def.Static,
            };

            double starHp = _planning != null ? _planning.StarHpMult(squad.Star) : 1.0;
            var roundMods = side == 0 ? _playerMods : _enemyMods;
            squad.MoveMult = roundMods.MoveMult > 0.0 ? roundMods.MoveMult : 1.0;
            squad.ArmorMult = roundMods.ArmorMult > 0.0 ? roundMods.ArmorMult : 1.0;
            squad.CritAdd = roundMods.CritAdd;
            if (mods != null)
            {
                squad.AttackMult = mods.AttackMult > 0.0 ? mods.AttackMult : 1.0;
                squad.ArmorAdd = mods.ArmorAdd;
                squad.DamageTakenMult = mods.DamageTakenMult > 0.0 ? mods.DamageTakenMult : 1.0;
                squad.MoveMult *= mods.MoveMult > 0.0 ? mods.MoveMult : 1.0;
            }
            squad.Speed = squad.Static
                ? 0.0
                : RtsUnits.ToUnits(def.MoveSpeed) * squad.MoveMult;

            // 单兵：唯一成员的槽位就是质心（offset 0,0）。没有阵型、没有槽位弹簧。
            squad.ContactRadius = UnitBody.BodyUnits(def);
            var m = new SquadMember
            {
                Index = 0,
                OffsetX = 0.0,
                OffsetZ = 0.0,
                MaxHp = def.Hp * starHp,
                Cd = _rng.NextFloat() * 0.3,
                Retarget = _rng.NextFloat() * 0.2,
            };
            m.Hp = m.MaxHp;
            m.X = squad.X;
            m.Z = squad.Z;
            squad.Members.Add(m);
            squad.AliveCount = 1;
            squad.HpMax = m.MaxHp;
            squad.Hp = squad.HpMax;
            squad.OrderX = squad.X;
            squad.OrderZ = squad.Z;
            squad.StuckX = squad.X;
            squad.StuckZ = squad.Z;

            _squads.Add(squad);
            if (side == 0) _stats.PlayerSquadsSpawned += 1;
            else _stats.EnemySquadsSpawned += 1;
            StatOf(side, def.Id).Squads += 1;
            StatOf(side, def.Id).Models += 1;
            return squad.Id;
        }

        /// <summary>
        /// 在战术格子的出兵锚点（格子正中心）生成一整批单兵。
        ///
        /// 2026-11-24 起不再用黄金角环（`SpawnRing(6)` 自身最小点距只有 0.744 m，
        /// 小于身位直径，一张牌就会互叠）。改为 <see cref="FormationPlan.TileSlot"/>：
        /// 每格维护一个只增不减的 slot 游标，同格连出多批继续往后排；列距 96 / 排距 144，
        /// 起点在格子右下象限（+60,+60），构造上避开左上建筑占地。
        /// <paramref name="ordinal"/> 仅为兼容旧签名保留，真实批次号由 <see cref="_tileCursor"/> 决定。
        /// </summary>
        public int AddUnitsAtTile(int side, string unitId, int star, int tileIndex,
            string sourceBuilding, int count, int ordinal, string role)
        {
            _ = ordinal;
            Vec2 center = _arena.TileSpawnWorld(tileIndex);
            _tileCursor.TryGetValue(tileIndex, out int slot);
            int made = 0;
            int n = Math.Max(count, 1);
            for (int i = 0; i < n; i++)
            {
                Vec2 off = FormationPlan.TileSlot(slot, _tuning.TileFiles, _tuning.FilePitch, _tuning.RankPitch);
                double x = center.X + off.X * RtsUnits.R1;
                double z = center.Y + off.Y * RtsUnits.R1;
                ModifierSet mods = side == 0 ? _playerArmyMods.ForSource(sourceBuilding, tileIndex) : null;
                int id = AddSquadEx(side, unitId, star, x, z, sourceBuilding, tileIndex, role, mods);
                if (id > 0)
                {
                    made += 1;
                    slot += 1;
                }
            }
            _tileCursor[tileIndex] = slot;
            return made;
        }

        /// <summary>兼容旧签名：一次出一名（count=1 的批次）。</summary>
        public int AddSquadAtTile(int side, string unitId, int star, int tileIndex, string sourceBuilding = "", int ring = 0)
        {
            return AddUnitsAtTile(side, unitId, star, tileIndex, sourceBuilding, 1, ring, SquadRoles.Any);
        }

        /// <summary>兼容旧签名：在格子中心出**一名**指定时空角色的单兵。</summary>
        public int AddSquadAtTileRole(int side, string unitId, int star, int tileIndex,
            string sourceBuilding, int ring, string role)
        {
            return AddUnitsAtTile(side, unitId, star, tileIndex, sourceBuilding, 1, ring, role);
        }

        /// <summary>切换当前时空：attack / defend / ""（切换后立刻生效，冻结的队伍停止一切结算）。</summary>
        public void SetActiveRole(string role)
        {
            if (!SquadRoles.IsValid(role)) role = SquadRoles.Any;
            ActiveRole = role;
        }

        private bool IsActive(BattleSquad s)
        {
            return s != null && !s.Purged && SquadRoles.ActiveIn(s.Role, ActiveRole);
        }

        /// <summary>
        /// 轮末清场：把某一方（或某一方 + 某角色）的队伍整批抹掉。
        /// 与"打死"不同 —— 不计阵亡数、不进复盘统计，等价于"这个时空结束了"。
        /// </summary>
        public int PurgeSide(int side, string role = null)
        {
            int n = 0;
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.WasAlive || s.Purged) continue;
                if (s.Side != side) continue;
                if (!string.IsNullOrEmpty(role) && s.Role != role) continue;
                s.Purged = true;
                s.WasAlive = false;
                s.AliveCount = 0;
                s.TargetSquad = -1;
                s.Order = SquadOrder.Stop;
                s.Locked = false;
                s.Engaged = false;
                s.Path.Clear();
                for (int m = 0; m < s.Members.Count; m++) s.Members[m].Alive = false;
                n += 1;
            }
            if (n > 0)
            {
                for (int i = 0; i < _shots.Count; i++)
                {
                    if (_shots[i].Side == side) _shots[i].Alive = false;
                }
            }
            return n;
        }

        /// <summary>
        /// 前压/后撤：把某一方某角色的单兵整体挪到指定世界点附近。
        /// 2026-11-24 起用 <see cref="FormationPlan.BattleSlot"/>：
        /// 近战在前、远程在后（按 `projectile` 判定），中轴向外对称、超宽折行；
        /// 近战线占 `meleeRanks` 排，远程线整体再后退 `meleeRanks×rank_pitch + line_gap`。
        /// </summary>
        public int StageSide(int side, string role, double worldX, double worldZ)
        {
            var units = new List<BattleSquad>();
            int melee = 0;
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.Alive || s.Purged || s.Side != side) continue;
                if (!string.IsNullOrEmpty(role) && s.Role != role) continue;
                units.Add(s);
                if (FormationPlan.LineOf(s.Def) == UnitLine.Melee) melee += 1;
            }
            if (units.Count == 0) return 0;

            int files = Math.Max(_tuning.MaxFiles, 2);
            int meleeRanks = FormationPlan.Ranks(melee, files);
            Vec2 anchor = _arena.WorldToLane(worldX, worldZ);
            int dirX = side == 0 ? -1 : 1;
            int slotMelee = 0;
            int slotRanged = 0;
            int n = 0;
            for (int i = 0; i < units.Count; i++)
            {
                BattleSquad s = units[i];
                UnitLine line = FormationPlan.LineOf(s.Def);
                int slot = line == UnitLine.Melee ? slotMelee++ : slotRanged++;
                Vec2 lane = FormationPlan.BattleSlot(anchor.X, anchor.Y, dirX, line, slot, files, meleeRanks,
                    _tuning.FilePitch, _tuning.RankPitch, _tuning.LineGap);
                lane = _route.ClampPoint(lane, s.Radius);
                s.X = lane.X;
                s.Z = lane.Y;
                s.OrderX = s.X;
                s.OrderZ = s.Z;
                s.Path.Clear();
                s.PathIndex = 0;
                s.TargetSquad = -1;
                s.Locked = false;
                s.Engaged = false;
                s.LastTurnSign = 0;
                s.TurnAccum = 0.0;
                s.FlipAccum = 0.0;
                s.Heading = side == 0 ? 0.0 : Math.PI;
                s.StuckX = s.X;
                s.StuckZ = s.Z;
                s.StuckTimer = 0.0;
                for (int m = 0; m < s.Members.Count; m++)
                {
                    var mem = s.Members[m];
                    mem.X = s.X;
                    mem.Z = s.Z;
                }
                n += 1;
            }
            return n;
        }

        public void ScheduleWave(Wave wave, int side, int tileIndex)
        {
            ScheduleWaveAt(wave, side, tileIndex, 0.0);
        }

        /// <summary>
        /// 排一波敌人；<paramref name="offsetSeconds"/> 是"这个时空从第几秒开始"。
        /// 防守战排在 60s 之后时，波次时间不必改数据，只需要给一个 60 的偏移。
        /// </summary>
        public void ScheduleWaveAt(Wave wave, int side, int tileIndex, double offsetSeconds)
        {
            if (wave == null) return;
            _waves.Add(new SquadWaveEntry
            {
                T = wave.T + Math.Max(offsetSeconds, 0.0),
                Side = side,
                Tile = tileIndex,
                Wave = wave,
            });
            SortWaves();
        }

        /// <summary>
        /// 按**部署线**（世界米）排一波敌人：不再依赖棋盘格子锚点。
        /// <paramref name="dirX"/> = 排队方向（向自家后方延伸，敌人 = +1）。
        /// </summary>
        public void ScheduleWaveAtLine(Wave wave, int side, double worldX, double worldZ, int dirX, double offsetSeconds)
        {
            if (wave == null) return;
            _waves.Add(new SquadWaveEntry
            {
                T = wave.T + Math.Max(offsetSeconds, 0.0),
                Side = side,
                Wave = wave,
                AnchorX = worldX,
                AnchorZ = worldZ,
                DirX = dirX >= 0 ? 1 : -1,
                UseLineAnchor = true,
            });
            SortWaves();
        }

        private void SortWaves()
        {
            _waves.Sort((a, b) =>
            {
                int c = a.T.CompareTo(b.T);
                if (c != 0) return c;
                return a.Side.CompareTo(b.Side);
            });
        }

        // =================================================================
        // 指令（只接受小队 id）
        // =================================================================
        public bool OrderMove(int squadId, double worldX, double worldZ)
        {
            BattleSquad s = Find(squadId);
            if (s == null || !s.Alive) return false;
            var lane = _arena.WorldToLane(worldX, worldZ);
            s.Order = SquadOrder.Move;
            s.TargetSquad = -1;
            PlanPath(s, _route.ClampPoint(lane, s.Radius));
            return true;
        }

        public bool OrderAttackMove(int squadId, double worldX, double worldZ)
        {
            BattleSquad s = Find(squadId);
            if (s == null || !s.Alive) return false;
            var lane = _arena.WorldToLane(worldX, worldZ);
            s.Order = SquadOrder.AttackMove;
            s.TargetSquad = -1;
            PlanPath(s, _route.ClampPoint(lane, s.Radius));
            return true;
        }

        public bool OrderHold(int squadId)
        {
            BattleSquad s = Find(squadId);
            if (s == null || !s.Alive) return false;
            s.Order = SquadOrder.Hold;
            s.TargetSquad = -1;
            s.Path.Clear();
            s.PathIndex = 0;
            s.PathLength = 0.0;
            s.OrderX = s.X;
            s.OrderZ = s.Z;
            return true;
        }

        public bool OrderStop(int squadId)
        {
            BattleSquad s = Find(squadId);
            if (s == null || !s.Alive) return false;
            s.Order = SquadOrder.Stop;
            s.TargetSquad = -1;
            s.Path.Clear();
            s.PathIndex = 0;
            s.PathLength = 0.0;
            s.OrderX = s.X;
            s.OrderZ = s.Z;
            return true;
        }

        /// <summary>
        /// 直线行军（开阔战场专用）：不走脊线 A*，只在起点与终点之间放两个路点。
        /// 单轮死斗里双方都从部署线直接对冲，A* 的 1.26 m 走廊只会制造单列瓶颈。
        /// </summary>
        public bool OrderMarch(int squadId, double worldX, double worldZ)
        {
            BattleSquad s = Find(squadId);
            if (s == null || !s.Alive) return false;
            if (s.Static) return false;
            var lane = _arena.WorldToLane(worldX, worldZ);
            s.Order = SquadOrder.AttackMove;
            s.TargetSquad = -1;
            s.Path.Clear();
            s.PathIndex = 0;
            s.Path.Add(new Vec2((float)s.X, (float)s.Z));
            s.Path.Add(_route.ClampPoint(lane, s.Radius));
            s.PathLength = Dist(s.X, s.Z, s.Path[1].X, s.Path[1].Y);
            s.OrderX = s.Path[1].X;
            s.OrderZ = s.Path[1].Y;
            return true;
        }

        public bool OrderAttack(int squadId, int targetSquadId)
        {
            BattleSquad s = Find(squadId);
            BattleSquad t = Find(targetSquadId);
            if (s == null || !s.Alive || t == null || !t.Alive || t.Side == s.Side) return false;
            s.Order = SquadOrder.Attack;
            s.TargetSquad = t.Id;
            s.Path.Clear();
            s.PathIndex = 0;
            s.PathLength = 0.0;
            s.OrderX = t.X;
            s.OrderZ = t.Z;
            return true;
        }

        /// <summary>
        /// 玩家侧指令白名单 —— **2026-11-22 起是空的**。
        ///
        /// 玩家口径：「选中己方或敌人单位都不可操作，只显示它们的信息」。
        /// 于是集火也一起下线了：战斗里玩家只观察，推进 / 索敌 / 攻击全部由自动战斗负责。
        /// 其余指令（Move / AttackMove / Hold / Stop / Attack）仍然保留给 AI、波次与推演用，
        /// 只是**玩家拨不动** —— 拒绝发生在这一层，不在界面层假装禁用。
        /// </summary>
        public static bool IsPlayerMicroOrder(string order)
        {
            _ = order;
            return false;
        }

        /// <summary>玩家侧指令唯一入口：只接受 attack（集火），其它一律返回 0。</summary>
        public int OrderPlayerMany(IList<int> squadIds, string order, int targetSquadId)
        {
            if (!IsPlayerMicroOrder(order)) return 0;
            if (squadIds == null || squadIds.Count == 0) return 0;
            int ok = 0;
            for (int i = 0; i < squadIds.Count; i++)
            {
                BattleSquad s = Find(squadIds[i]);
                if (s == null || !s.Alive || s.Side != 0) continue;
                if (OrderAttack(s.Id, targetSquadId)) ok += 1;
            }
            return ok;
        }

        /// <summary>对一组小队下同一条指令（框选后的唯一入口）。</summary>
        public int OrderMany(IList<int> squadIds, string order, double worldX, double worldZ, int targetSquadId)
        {
            if (squadIds == null || squadIds.Count == 0) return 0;
            SquadOrder kind = SquadOrders.Parse(order);
            int ok = 0;
            for (int i = 0; i < squadIds.Count; i++)
            {
                bool r;
                switch (kind)
                {
                    case SquadOrder.Move: r = OrderMove(squadIds[i], worldX, worldZ); break;
                    case SquadOrder.AttackMove: r = OrderAttackMove(squadIds[i], worldX, worldZ); break;
                    case SquadOrder.Hold: r = OrderHold(squadIds[i]); break;
                    case SquadOrder.Stop: r = OrderStop(squadIds[i]); break;
                    case SquadOrder.Attack: r = OrderAttack(squadIds[i], targetSquadId); break;
                    default: r = false; break;
                }
                if (r) ok += 1;
            }
            return ok;
        }

        /// <summary>对一整边下达同一条指令（波次自动推进 / 推演用）。</summary>
        public int OrderSide(int side, string order, double worldX, double worldZ)
        {
            var ids = new List<int>();
            for (int i = 0; i < _squads.Count; i++)
            {
                if (_squads[i].Side == side && _squads[i].Alive && IsActive(_squads[i])) ids.Add(_squads[i].Id);
            }
            return OrderMany(ids, order, worldX, worldZ, -1);
        }

        public List<int> SquadIdsOfSide(int side)
        {
            var ids = new List<int>();
            for (int i = 0; i < _squads.Count; i++)
            {
                if (_squads[i].Side == side && _squads[i].Alive && IsActive(_squads[i])) ids.Add(_squads[i].Id);
            }
            return ids;
        }

        /// <summary>按定位取一方的队伍 id：melee（含长枪）/ ranged（远程）。</summary>
        public List<int> SquadIdsOfSideRole(int side, string role)
        {
            var ids = new List<int>();
            bool wantRanged = string.Equals(role, "ranged", StringComparison.OrdinalIgnoreCase);
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (s.Side != side || !s.Alive || !IsActive(s)) continue;
                bool ranged = s.Def.AttackRange >= UnitDef.MeleeMaxRange;
                if (ranged == wantRanged) ids.Add(s.Id);
            }
            return ids;
        }

        /// <summary>
        /// 按**时空角色**取一方的队伍 id（进攻战只拿 attack 队）。
        /// 预设偏好（Model 内部的自动推进）与自检都走这一条。
        /// </summary>
        public List<int> SquadIdsOfSideAndRole(int side, string role)
        {
            var ids = new List<int>();
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (s.Side != side || !s.Alive || s.Purged) continue;
                if (!string.IsNullOrEmpty(role) && s.Role != role) continue;
                ids.Add(s.Id);
            }
            return ids;
        }

        /// <summary>调试/自检：读取一支队当前的脊线路径（lane 坐标）。</summary>
        public List<Vec2> DebugPath(int squadId)
        {
            BattleSquad s = Find(squadId);
            return s != null ? new List<Vec2>(s.Path) : new List<Vec2>();
        }

        public double DebugPathLength(int squadId)
        {
            BattleSquad s = Find(squadId);
            return s != null ? s.PathLength : 0.0;
        }

        // =================================================================
        // 选择（同样是队级）
        // =================================================================
        /// <summary>点选：命中一名单兵就选中它（side -1 = 不限）。</summary>
        public int PickSquad(double worldX, double worldZ, int side, double slackMeters = 0.4)
        {
            var lane = _arena.WorldToLane(worldX, worldZ);
            double slack = RtsUnits.ToUnits(Math.Max(slackMeters, 0.0));
            int best = -1;
            double bestD = double.MaxValue;
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.Alive || (side >= 0 && s.Side != side)) continue;
                double d = Dist(lane.X, lane.Y, s.X, s.Z);
                if (d > s.Radius + slack) continue;
                if (d < bestD)
                {
                    bestD = d;
                    best = s.Id;
                }
            }
            return best;
        }

        /// <summary>框选：单兵落在矩形内即入选（世界米）；选中只用于看信息，不下任何指令。</summary>
        public List<int> SquadsInRectWorld(double x0, double z0, double x1, double z1, int side)
        {
            double minX = Math.Min(x0, x1);
            double maxX = Math.Max(x0, x1);
            double minZ = Math.Min(z0, z1);
            double maxZ = Math.Max(z0, z1);
            var outIds = new List<int>();
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.Alive || (side >= 0 && s.Side != side)) continue;
                Vec2 w = _arena.LaneToWorld(s.X, s.Z);
                if (w.X < minX || w.X > maxX || w.Y < minZ || w.Y > maxZ) continue;
                outIds.Add(s.Id);
            }
            outIds.Sort();
            return outIds;
        }

        public bool IsAliveSquad(int squadId)
        {
            BattleSquad s = Find(squadId);
            return s != null && s.Alive;
        }

        // =================================================================
        // 推进
        // =================================================================
        public void Step(double dt)
        {
            if (_finished || dt <= 0.0) return;
            // 倍速只乘在"这一帧推进了多少模型时间"上；固定步长 Dt 与所有数值不动。
            _acc += Math.Min(dt * _timeScale, 0.25 * _timeScale);
            int guard = 0;
            while (_acc >= Dt - 1e-9 && !_finished && guard++ < 16)
            {
                _acc -= Dt;
                Tick(Dt);
            }
        }

        /// <summary>无窗口推演：一次跑到 seconds（或基地被拆）。</summary>
        public SquadBattleStats Run(double seconds)
        {
            _playerBaseHpMax = Math.Max(_playerBaseHpMax, _playerBaseHp);
            _enemyBaseHpMax = Math.Max(_enemyBaseHpMax, _enemyBaseHp);
            SpawnDueWaves(0.0);
            while (_time < seconds - Eps && !_finished)
            {
                Tick(Dt);
            }
            return _stats;
        }

        private void Tick(double dt)
        {
            _time += dt;
            UpdateBerserk();
            SpawnDueWaves(_time);

            UpdateOrders(dt);
            ResolveSeparation();
            UpdateMembers(dt);
            UpdateAttacks(dt);
            UpdateShots(dt);
            Cleanup();
            UpdateStats(dt);
            CheckAnnihilation();
            // 2026-11-24：基地血量不再由战场逐 tick 抽取；
            // 60 秒后由 RoundResolver 按幸存者 base_damage 一次性结算。
        }

        /// <summary>
        /// 一方全灭就收场（不必空跑到 60 秒）：
        ///   · 我方全灭 → 立即结束（后面还有没有敌方波次都不影响结果）；
        ///   · 敌方全灭 → 必须等**所有波次都已出场**，否则会把"下一波还没来"误判成胜利。
        /// 只有打满 45 秒才会触发狂暴，所以这个提前收场也让"狂暴触发率"变成真实读数。
        /// </summary>
        private void CheckAnnihilation()
        {
            if (_finished) return;
            if (Survivors(0).Count == 0)
            {
                _outcome = "lose";
                _finished = true;
                return;
            }
            if (_nextWave >= _waves.Count && Survivors(1).Count == 0)
            {
                _outcome = "win";
                _finished = true;
            }
        }

        /// <summary>
        /// 45 秒狂暴：全员攻速 ×N、护甲按 0 结算。
        /// 只改"出手频率/承伤"，不改伤害数值本身 —— 配平仍看 combat.json。
        /// </summary>
        private void UpdateBerserk()
        {
            if (_berserk) return;
            if (_tuning.BerserkStartSeconds <= 0.0) return;
            if (_time + Eps < _tuning.BerserkStartSeconds) return;
            _berserk = true;
            _berserkAt = Round2(_time);
            _stats.BerserkTriggered = true;
            _stats.BerserkSecond = _berserkAt;
        }

        // =================================================================
        // 指令 → 移动
        // =================================================================
        private void UpdateOrders(double dt)
        {
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.Alive || !IsActive(s)) continue;
                s.Age += dt;

                if (s.TargetSquad >= 0)
                {
                    BattleSquad t = Find(s.TargetSquad);
                    if (t == null || !t.Alive)
                    {
                        s.TargetSquad = -1;
                        if (s.Order == SquadOrder.Attack) s.Order = SquadOrder.Hold;
                    }
                }

                // Phase 1：先算"够不够得着"，再决定动不动。
                // hasFire = 实际开火线（R+4）；hasLock = 免推挤的滞回线（R+12）。
                // Locked 只对"正在追打"的 Attack/AttackMove 生效；Hold 靠 invMass=0.15 抗推。
                bool hasFire = HasTargetInRange(s, s.MaxRange + RangeSlack);
                bool hasLock = HasTargetInRange(s, s.MaxRange + RangeSlack + LockSlack);
                bool canLock = s.Order == SquadOrder.Attack || s.Order == SquadOrder.AttackMove;
                s.Engaged = hasFire || (s.Engaged && hasLock);
                // 质量锁定只认"真的够得着"（R+4）；R+12 只用于表现滞回。
                // 否则单位会停在 99~107 的锁定带里：有攻击态、却永远不进开火线。
                s.Locked = canLock && hasFire;
                double standOff = s.MaxRange * _tuning.StandOffRatio;

                // 静止塔：不移动、不追，只靠 UpdateAttacks 自动开火。
                if (s.Static)
                {
                    s.WantsMove = false;
                    continue;
                }

                switch (s.Order)
                {
                    case SquadOrder.Attack:
                    {
                        if (s.TargetSquad < 0) { s.Order = SquadOrder.Hold; s.WantsMove = false; break; }
                        BattleSquad t = Find(s.TargetSquad);
                        if (t == null || !t.Alive) { s.Order = SquadOrder.Hold; s.WantsMove = false; break; }
                        s.WantsMove = !s.Locked;
                        if (!s.Locked) MoveToward(s, t.X, t.Z, dt, standOff);
                        s.OrderX = t.X;
                        s.OrderZ = t.Z;
                        break;
                    }
                    case SquadOrder.AttackMove:
                    {
                        double detect = Math.Max(DetectRadius, s.MaxRange * 1.6);
                        if (s.TargetSquad < 0)
                        {
                            int near = NearestEnemySquad(s, detect);
                            if (near >= 0) s.TargetSquad = near;
                        }
                        if (s.TargetSquad >= 0)
                        {
                            BattleSquad t = Find(s.TargetSquad);
                            if (t != null && t.Alive)
                            {
                                // 牵引绳：追出索敌圈就放弃，回去继续走脊线（否则会被远程风筝到天边）
                                double leash = detect * 1.25;
                                if (Dist(s.X, s.Z, t.X, t.Z) > leash)
                                {
                                    s.TargetSquad = -1;
                                }
                                else
                                {
                                    s.WantsMove = !s.Locked;
                                    if (!s.Locked) MoveToward(s, t.X, t.Z, dt, standOff);
                                    break;
                                }
                            }
                            else s.TargetSquad = -1;
                        }
                        s.WantsMove = !s.Locked;
                        if (!s.Locked) FollowPath(s, dt);
                        break;
                    }
                    case SquadOrder.Move:
                    {
                        s.WantsMove = !s.Locked;
                        if (!s.Locked) FollowPath(s, dt);
                        break;
                    }
                    case SquadOrder.Hold:
                    case SquadOrder.Stop:
                    default:
                    {
                        s.WantsMove = false;
                        // 驻守：不移动；只在射程内自动打（成员自己索敌）
                        if (s.TargetSquad < 0)
                        {
                            double detect = Math.Max(HoldDetectMin, s.MaxRange * 1.25);
                            s.TargetSquad = NearestEnemySquad(s, detect);
                        }
                        break;
                    }
                }

                // 面向目标：射程内优先看敌人，6° 死区与转速在 TurnToward 里。
                if (s.Engaged && s.TargetSquad >= 0)
                {
                    BattleSquad t = Find(s.TargetSquad);
                    if (t != null && t.Alive)
                        TurnToward(s, Math.Atan2(t.Z - s.Z, t.X - s.X), dt);
                }
            }
        }

        /// <summary>给定半径内是否有活着的敌人 —— 开火判定与锁定滞回共用这一个扫描。</summary>
        private bool HasTargetInRange(BattleSquad s, double range)
        {
            double r2 = range * range;
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad o = _squads[i];
                if (!o.Alive || !IsActive(o) || o.Side == s.Side) continue;
                for (int m = 0; m < o.Members.Count; m++)
                {
                    SquadMember tm = o.Members[m];
                    if (!tm.Alive) continue;
                    double dx = tm.X - s.X;
                    double dz = tm.Z - s.Z;
                    if (dx * dx + dz * dz <= r2) return true;
                }
            }
            return false;
        }

        private void FollowPath(BattleSquad s, double dt)
        {
            if (s.Path.Count == 0)
            {
                s.Order = SquadOrder.Hold;
                return;
            }
            if (s.PathIndex < 0) s.PathIndex = 0;
            if (s.PathIndex >= s.Path.Count) s.PathIndex = s.Path.Count - 1;

            double reach = Math.Max(s.Radius * 0.55, 45.0);
            Vec2 wp = s.Path[s.PathIndex];
            double d = Dist(s.X, s.Z, wp.X, wp.Y);
            int guard = 0;
            while (d <= reach && s.PathIndex < s.Path.Count - 1 && guard++ < 64)
            {
                s.PathIndex += 1;
                wp = s.Path[s.PathIndex];
                d = Dist(s.X, s.Z, wp.X, wp.Y);
            }
            if (s.PathIndex >= s.Path.Count - 1 && d <= reach)
            {
                s.Order = SquadOrder.Hold;
                s.WantsMove = false;
                s.OrderX = s.X;
                s.OrderZ = s.Z;
                return;
            }
            MoveToward(s, wp.X, wp.Y, dt);
        }

        /// <summary>
        /// 朝目标点走一步。
        /// <paramref name="stopDistance"/> = 停火线（打单位时传 0.92R；走路/追路径传 0）。
        /// 关键：步长裁到"剩余到停火线的距离"，**永不超过**，所以不会在射程边界上反复进出。
        /// 另外，任何一步都不许跨进别人（敌/友/塔）的硬核；被挡住时只保留切向分量。
        /// </summary>
        private void MoveToward(BattleSquad s, double tx, double tz, double dt, double stopDistance = 0.0)
        {
            double dx = tx - s.X;
            double dz = tz - s.Z;
            double d = Math.Sqrt(dx * dx + dz * dz);
            if (d <= stopDistance + 0.5) return;
            double step = Math.Min(d - stopDistance, s.Speed * dt);
            if (step <= 0.0) return;
            double stepX = dx / d * step;
            double stepZ = dz / d * step;

            // 硬核阻挡：不许一步跨进任何单位的硬核。
            // 注意：这里**不再只挡敌人、也不再只挡 1.65 倍身位** —— 那是"近战够不着"的根因。
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad o = _squads[i];
                if (o == s || !o.Alive || !IsActive(o)) continue;
                // 只挡敌人：友军交给分离去挤。若连友军也挡，后排会被前排堵死在同一条路径点上。
                if (o.Side == s.Side) continue;
                double ex = s.X - o.X;
                double ez = s.Z - o.Z;
                double ed = Math.Sqrt(ex * ex + ez * ez);
                if (ed < 1e-6) continue;
                double hardCore = (s.ContactRadius + o.ContactRadius) * _tuning.HardCoreFactor;
                double afterX = s.X + stepX;
                double afterZ = s.Z + stepZ;
                double ad = Dist(afterX, afterZ, o.X, o.Z);
                if (ad >= hardCore || ad >= ed) continue;
                double nx = ex / ed;
                double nz = ez / ed;
                double dot = stepX * nx + stepZ * nz;
                if (dot < 0.0)
                {
                    stepX -= nx * dot;
                    stepZ -= nz * dot;
                }
            }

            double moved = Math.Sqrt(stepX * stepX + stepZ * stepZ);
            s.X += stepX;
            s.Z += stepZ;
            s.Travelled += moved;
            _stats.ActualTravelled += moved;
            // 微小残余步长（< 2 cm）不驱动朝向，避免"原地抖头"。
            if (moved > 1.5)
            {
                double want = Math.Atan2(stepZ, stepX);
                TurnToward(s, want, dt);
            }
            ClampSquad(s);
        }

        private void TurnToward(BattleSquad s, double want, double dt)
        {
            double diff = NormalizeAngle(want - s.Heading);
            double dead = _tuning.FacingDeadzoneDeg * Math.PI / 180.0;
            // 6° 死区：差值在死区内完全不转。没有它，射程边界/微小残余步长会让模型来回甩头。
            if (Math.Abs(diff) <= dead) return;
            double maxTurn = _tuning.TurnRateDeg * Math.PI / 180.0 * dt;
            if (diff > maxTurn) diff = maxTurn;
            if (diff < -maxTurn) diff = -maxTurn;
            s.Heading = NormalizeAngle(s.Heading + diff);

            // 朝向反转计数（Phase 0 读数）：同向累计，反向时把累计弧长并入 FlipAccum；
            // 累计超过 34° 才记一次，过滤"贴着阈值左右各抖 1°"的微抖。
            if (Math.Abs(diff) > 1e-6)
            {
                int sign = diff > 0.0 ? 1 : -1;
                if (s.LastTurnSign != 0 && sign != s.LastTurnSign)
                {
                    s.FlipAccum += Math.Abs(s.TurnAccum);
                    if (s.FlipAccum > 0.6)
                    {
                        _stats.HeadingFlips += 1;
                        s.FlipAccum = 0.0;
                    }
                    s.TurnAccum = 0.0;
                }
                else
                {
                    s.TurnAccum += Math.Abs(diff);
                }
                s.LastTurnSign = sign;
            }
        }

        private void PlanPath(BattleSquad s, Vec2 target)
        {
            s.Path.Clear();
            s.PathIndex = 0;
            s.PathLength = 0.0;
            if (_route.Valid)
            {
                var path = _route.Plan(new Vec2((float)s.X, (float)s.Z), target);
                s.Path.AddRange(path);
            }
            else
            {
                s.Path.Add(new Vec2((float)s.X, (float)s.Z));
                s.Path.Add(target);
            }
            s.PathLength = _route.PathLength(s.Path);
            if (s.PathLength > 1e-6 && s.TargetSquad < 0)
            {
                _stats.PlannedPathLength += s.PathLength;
                _stats.StraightLengthSum += Dist(s.X, s.Z, target.X, target.Y);
                _stats.PathSamples += 1;
            }
        }

        // =================================================================
        // 避障 / 成员槽位
        // =================================================================
        /// <summary>
        /// Phase 0 读数：每 tick 在分离之前量一次"真实叠模"。
        /// deepPairs = 中心距 &lt; 0.5×0.90×身位和（半个人叠进去）；
        /// maxOverlap = 0.90×身位和 − 中心距（最大重叠深度，游戏数值）。
        /// </summary>
        private void MeasureOverlap(bool after)
        {
            int deepPairs = 0;
            double maxOverlap = 0.0;
            int worstA = -1;
            int worstB = -1;
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad a = _squads[i];
                if (!a.Alive || !IsActive(a)) continue;
                for (int j = i + 1; j < _squads.Count; j++)
                {
                    BattleSquad b = _squads[j];
                    if (!b.Alive || !IsActive(b)) continue;
                    double hardCore = (a.ContactRadius + b.ContactRadius) * MetricHardCoreFactor;
                    double d = Dist(a.X, a.Z, b.X, b.Z);
                    if (d >= hardCore) continue;
                    double overlap = hardCore - d;
                    if (overlap > maxOverlap)
                    {
                        maxOverlap = overlap;
                        worstA = a.Id;
                        worstB = b.Id;
                    }
                    if (d < hardCore * 0.5) deepPairs += 1;
                }
            }
            if (after)
            {
                if (deepPairs > 0) _stats.OverlapAfterTicks += 1;
                if (deepPairs > _stats.OverlapPairsAfterMax) _stats.OverlapPairsAfterMax = deepPairs;
                if (maxOverlap > _stats.OverlapDepthAfterMax) _stats.OverlapDepthAfterMax = maxOverlap;
                return;
            }
            if (deepPairs > _stats.OverlapPairsMax) _stats.OverlapPairsMax = deepPairs;
            if (maxOverlap > _stats.OverlapDepthMax)
            {
                _stats.OverlapDepthMax = maxOverlap;
                _stats.OverlapWorstTime = Round2(_time);
                _stats.OverlapWorstA = worstA;
                _stats.OverlapWorstB = worstB;
            }
        }

        private void ResolveSeparation()
        {
            MeasureOverlap(false);
            var pushX = new double[_squads.Count];
            var pushZ = new double[_squads.Count];
            for (int pass = 0; pass < 8; pass++)
            {
                for (int i = 0; i < pushX.Length; i++)
                {
                    pushX[i] = 0.0;
                    pushZ[i] = 0.0;
                }
                for (int i = 0; i < _squads.Count; i++)
                {
                    BattleSquad a = _squads[i];
                    if (!a.Alive || !IsActive(a)) continue;
                    for (int j = i + 1; j < _squads.Count; j++)
                    {
                        BattleSquad b = _squads[j];
                        if (!b.Alive || !IsActive(b)) continue;
                        double dx = a.X - b.X;
                        double dz = a.Z - b.Z;
                        double min = (a.ContactRadius + b.ContactRadius) * _tuning.HardCoreFactor;
                        double d2 = dx * dx + dz * dz;
                        if (d2 >= min * min) continue;
                        double d = Math.Sqrt(d2);
                        if (d < 1e-6)
                        {
                            double ang = (a.Id * 2.399963229728653 + b.Id * 0.7) % (Math.PI * 2.0);
                            dx = Math.Cos(ang);
                            dz = Math.Sin(ang);
                            d = 1.0;
                        }
                        double overlap = min - d;
                        double nx = dx / d;
                        double nz = dz / d;

                        // 质量分离（2026-11-24 唯一实现）：
                        // 攻击态/塔 invMass=0 → 自己推不动，但仍然按份额推别人；
                        // 两个都不可推时各让一半 —— 所以"锁定"再也不会变成"整对跳过、互相穿模"。
                        double invA = InvMass(a);
                        double invB = InvMass(b);
                        double sum = invA + invB;
                        if (sum <= 1e-9)
                        {
                            invA = 0.5;
                            invB = 0.5;
                            sum = 1.0;
                        }
                        pushX[i] += nx * overlap * (invA / sum);
                        pushZ[i] += nz * overlap * (invA / sum);
                        pushX[j] -= nx * overlap * (invB / sum);
                        pushZ[j] -= nz * overlap * (invB / sum);
                    }
                }
                for (int i = 0; i < _squads.Count; i++)
                {
                    BattleSquad s = _squads[i];
                    if (!s.Alive || !IsActive(s)) continue;
                    // 分离是"挤"，不是"弹射"：每 tick 最多挪 0.9 个身位/秒的速度
                    double maxPush = Math.Max(s.Speed * Dt * 0.9, 6.0);
                    double len = Math.Sqrt(pushX[i] * pushX[i] + pushZ[i] * pushZ[i]);
                    if (len > maxPush && len > 1e-9)
                    {
                        double k = maxPush / len;
                        pushX[i] *= k;
                        pushZ[i] *= k;
                    }
                    s.X += pushX[i];
                    s.Z += pushZ[i];
                    ClampSquad(s);
                }
            }
            // 分离之后仍残留的深度重叠 = 玩家真正看到的叠模。
            MeasureOverlap(true);
        }

        /// <summary>
        /// 分离质量：攻击态 / 静止塔 = 0（推不动），驻守 = 0.15（很难推），行军 = 1。
        /// 注意这里返回的是 **invMass**（越小越难推），不是质量本身。
        /// </summary>
        private static double InvMass(BattleSquad s)
        {
            if (s.Locked) return 0.0;
            if (s.Speed <= 1e-9) return 0.0;
            if (s.Order == SquadOrder.Hold || s.Order == SquadOrder.Stop) return 0.15;
            return 1.0;
        }

        /// <summary>
        /// 成员位置对齐：单兵的唯一成员就站在质心上（偏移恒为 0），
        /// 所以这里没有"弹簧收敛"也没有"牵引绳" —— 那套东西是编制时代的遗留。
        /// 保留这个函数是为了槽位误差指标（恒 0）与快照契约不破。
        /// </summary>
        private void UpdateMembers(double dt)
        {
            _ = dt;
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.Alive || !IsActive(s)) continue;
                for (int m = 0; m < s.Members.Count; m++)
                {
                    SquadMember mem = s.Members[m];
                    if (!mem.Alive) continue;
                    mem.X = s.X;
                    mem.Z = s.Z;
                }
            }
        }

        /// <summary>成员槽位 = 质心（单兵没有阵型偏移）。</summary>
        private static Vec2 SlotPoint(BattleSquad s, SquadMember m)
        {
            _ = m;
            return new Vec2((float)s.X, (float)s.Z);
        }

        // =================================================================
        // 出手 / 投射物
        // =================================================================
        private void UpdateAttacks(double dt)
        {
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.Alive || !IsActive(s)) continue;
                for (int m = 0; m < s.Members.Count; m++)
                {
                    SquadMember mem = s.Members[m];
                    if (!mem.Alive) continue;
                    if (mem.Cd > 0.0) mem.Cd -= dt;
                    if (mem.Retarget > 0.0) mem.Retarget -= dt;
                    else
                    {
                        mem.Target = FindMemberTarget(s, mem);
                        mem.Retarget = 0.18 + (mem.Index % 5) * 0.03;
                    }
                    if (mem.Cd > 0.0) continue;
                    if (mem.Target < 0) continue;
                    if (!TryResolveTarget(mem.Target, s.Side, out BattleSquad ts, out SquadMember tm)) continue;

                    double d = Dist(mem.X, mem.Z, tm.X, tm.Z);
                    // Phase 0 读数：冷却已好、也进了攻击态，却因为距离不够打不出去。
                    // 正常战斗应接近 0；停火线在开火线之外时它会持续上涨。
                    if (s.Engaged && d > s.MaxRange + RangeSlack)
                        _stats.UnfiredEngagedSeconds += dt;
                    if (d > s.MaxRange + RangeSlack) continue;

                    var atk = new CombatAttacker
                    {
                        Damage = s.Def.AttackDamage * (_planning != null ? _planning.StarAttackMult(s.Star) : 1.0) * s.AttackMult,
                        Cooldown = s.Def.AttackCooldown,
                        AttackType = s.Def.AttackType,
                        Hit = s.Def.Hit,
                        CritChance = s.Def.Crit + s.CritAdd,
                        CritMultiplier = 0.0,
                        ArmorPenFlat = s.Def.ArmorPenFlat,
                        ArmorPenPct = s.Def.ArmorPenPct,
                        AttackMult = 1.0,
                    };
                    double armorValue = ts.Def.Armor * ts.ArmorMult + ts.ArmorAdd;
                    if (_berserk && _tuning.BerserkArmorZero) armorValue = 0.0;
                    var def = new CombatDefender
                    {
                        Armor = armorValue,
                        ArmorType = ts.Def.ArmorType,
                        Dodge = ts.Def.Dodge,
                        ArmorMult = 1.0,
                        DamageTakenMult = ts.DamageTakenMult,
                    };

                    double rollHit = _rng.NextFloat();
                    double rollCrit = _rng.NextFloat();
                    var br = CombatCalculator.Compute(atk, def, _rules, rollHit, rollCrit);

                    if (br.Hit)
                    {
                        if (s.Def.Projectile)
                        {
                            _shots.Add(new SquadShot
                            {
                                Side = s.Side,
                                SourceSquad = s.Id,
                                SourceMember = mem.Index,
                                TargetSquad = ts.Id,
                                TargetMember = tm.Index,
                                X = mem.X,
                                Z = mem.Z,
                                Speed = RtsUnits.ToUnits(s.Def.ProjectileSpeed > 0.0 ? s.Def.ProjectileSpeed : 26.0),
                                Damage = br.Damage,
                                Feedback = br.Feedback,
                            });
                        }
                        else
                        {
                            ApplyMemberDamage(s, mem, ts, tm, br.Damage, br.Feedback);
                        }
                    }
                    double cooldown = s.Def.AttackCooldown;
                    if (_berserk && _tuning.BerserkAttackSpeedMult > 0.0)
                        cooldown /= _tuning.BerserkAttackSpeedMult;
                    mem.Cd = Math.Max(cooldown, 0.05);
                    if (!br.Hit) CountFeedback(DamageFeedback.Miss, 0.0);
                }
            }
        }

        private int FindMemberTarget(BattleSquad s, SquadMember mem)
        {
            int best = -1;
            double bestD = double.MaxValue;
            if (s.TargetSquad >= 0)
            {
                BattleSquad t = Find(s.TargetSquad);
                if (t != null && t.Alive)
                {
                    for (int i = 0; i < t.Members.Count; i++)
                    {
                        SquadMember tm = t.Members[i];
                        if (!tm.Alive) continue;
                        double d = Dist(mem.X, mem.Z, tm.X, tm.Z);
                        if (d < bestD)
                        {
                            bestD = d;
                            best = (t.Id << 8) | i;
                        }
                    }
                    // 只在目标确实进入开火线时才死守它；目标太远就继续扫描最近的敌人。
                    // 否则会出现"锁定了一个远处目标，身边明明有人却一直不开火"。
                    if (best >= 0 && bestD <= s.MaxRange + RangeSlack) return best;
                }
            }
            double scan = s.MaxRange * 1.6;
            for (int q = 0; q < _squads.Count; q++)
            {
                BattleSquad t = _squads[q];
                if (!t.Alive || !IsActive(t) || t.Side == s.Side) continue;
                for (int i = 0; i < t.Members.Count; i++)
                {
                    SquadMember tm = t.Members[i];
                    if (!tm.Alive) continue;
                    double d = Dist(mem.X, mem.Z, tm.X, tm.Z);
                    if (d > scan || d >= bestD) continue;
                    bestD = d;
                    best = (t.Id << 8) | i;
                }
            }
            if (best >= 0) s.TargetSquad = best >> 8;
            return best;
        }

        private bool TryResolveTarget(int packed, int mySide, out BattleSquad squad, out SquadMember member)
        {
            squad = null;
            member = null;
            int id = packed >> 8;
            int index = packed & 0xFF;
            BattleSquad s = Find(id);
            if (s == null || !s.Alive || s.Side == mySide) return false;
            if (index < 0 || index >= s.Members.Count) return false;
            SquadMember m = s.Members[index];
            if (!m.Alive) return false;
            squad = s;
            member = m;
            return true;
        }

        private void ApplyMemberDamage(BattleSquad sourceSquad, SquadMember source, BattleSquad targetSquad, SquadMember target, double damage,
            DamageFeedback feedback = DamageFeedback.Normal)
        {
            if (damage <= 0.0 || target == null || !target.Alive) return;
            target.Hp -= damage;
            source.DamageDealt += damage;
            sourceSquad.DamageDealt += damage;
            if (sourceSquad.Side == 0) _stats.PlayerDamage += damage;
            else _stats.EnemyDamage += damage;
            StatOf(sourceSquad.Side, sourceSquad.Def.Id).Damage += damage;
            if (_stats.FirstContactSecond < 0.0) _stats.FirstContactSecond = Round2(_time);
            CountFeedback(feedback, damage);

            if (target.Hp <= 0.0)
            {
                target.Hp = 0.0;
                target.Alive = false;
                source.Kills += 1;
                sourceSquad.Kills += 1;
                StatOf(sourceSquad.Side, sourceSquad.Def.Id).Kills += 1;
                if (sourceSquad.Side == 0) _stats.PlayerKills += 1;
                else _stats.EnemyKills += 1;
            }
        }

        private void UpdateShots(double dt)
        {
            for (int i = 0; i < _shots.Count; i++)
            {
                SquadShot p = _shots[i];
                if (!p.Alive) continue;
                if (!TryResolveTarget((p.TargetSquad << 8) | p.TargetMember, p.Side, out BattleSquad ts, out SquadMember tm))
                {
                    p.Alive = false;
                    continue;
                }
                double dx = tm.X - p.X;
                double dz = tm.Z - p.Z;
                double d = Math.Sqrt(dx * dx + dz * dz);
                double step = p.Speed * dt;
                double body = UnitBody.BodyUnits(ts.Def);
                if (d <= step + body)
                {
                    BattleSquad srcSquad = Find(p.SourceSquad);
                    if (srcSquad != null && srcSquad.Alive && p.SourceMember >= 0 && p.SourceMember < srcSquad.Members.Count)
                    {
                        ApplyMemberDamage(srcSquad, srcSquad.Members[p.SourceMember], ts, tm, p.Damage, p.Feedback);
                    }
                    p.Alive = false;
                }
                else if (d > 1e-6)
                {
                    p.X += dx / d * step;
                    p.Z += dz / d * step;
                }
            }
        }

        // =================================================================
        // 清点 / 基地 / 统计
        // =================================================================
        private void Cleanup()
        {
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.WasAlive) continue;
                int alive = 0;
                double hp = 0.0;
                for (int m = 0; m < s.Members.Count; m++)
                {
                    SquadMember mem = s.Members[m];
                    if (mem.Alive && mem.Hp > 0.0)
                    {
                        alive += 1;
                        hp += mem.Hp;
                    }
                    else if (mem.Alive)
                    {
                        mem.Alive = false;
                        mem.Hp = 0.0;
                    }
                }
                int lostNow = s.AliveCount - alive;
                if (lostNow > 0)
                {
                    s.ModelsLost += lostNow;
                    if (s.Side == 0) _stats.PlayerModelsLost += lostNow;
                    else _stats.EnemyModelsLost += lostNow;
                    StatOf(s.Side, s.Def.Id).Losses += lostNow;
                }
                s.AliveCount = alive;
                s.Hp = hp;
                if (alive == 0)
                {
                    s.WasAlive = false;
                    if (s.Side == 0) _stats.PlayerSquadsLost += 1;
                    else _stats.EnemySquadsLost += 1;
                }
            }
        }

        /// <summary>
        /// 跳字反馈计数（唯一入口）。暴击/克制 = 红，被抵抗 = 白，普通 = 常规，未命中 = 不跳字。
        /// 表现层只读这些计数与 <see cref="SquadShot.Feedback"/>，不自己查表。
        /// </summary>
        private void CountFeedback(DamageFeedback feedback, double damage)
        {
            switch (feedback)
            {
                case DamageFeedback.CritOrCounter:
                    _stats.FeedbackCritOrCounter += 1;
                    _stats.FeedbackCritDamage += damage;
                    break;
                case DamageFeedback.Resisted:
                    _stats.FeedbackResisted += 1;
                    _stats.FeedbackResistedDamage += damage;
                    break;
                case DamageFeedback.Miss:
                    _stats.FeedbackMiss += 1;
                    break;
                default:
                    _stats.FeedbackNormal += 1;
                    _stats.FeedbackNormalDamage += damage;
                    break;
            }
        }

        /// <summary>结算用：某一方还活着的单兵（不含被清场的）。</summary>
        internal List<BattleSquad> Survivors(int side)
        {
            var list = new List<BattleSquad>();
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.Alive || s.Purged || s.Side != side) continue;
                list.Add(s);
            }
            return list;
        }

        /// <summary>
        /// 幸存单位的 base_damage 之和（结算唯一口径；static 单位 base_damage 恒 0）。
        /// <paramref name="cap"/> &lt;= 0 表示不封顶。
        /// </summary>
        public double SurvivorBaseDamage(int side, int cap = 0)
        {
            double sum = 0.0;
            List<BattleSquad> list = Survivors(side);
            for (int i = 0; i < list.Count; i++)
            {
                BattleSquad s = list[i];
                if (s.Static) continue;
                sum += s.Def.BaseDamageOf(s.Star);
            }
            if (cap > 0 && sum > cap) sum = cap;
            return sum;
        }

        /// <summary>主动结束（60 秒到点）：只置完成标记，不改基地血。</summary>
        public void Finish(string outcome = "")
        {
            if (_finished) return;
            _outcome = outcome ?? "";
            _finished = true;
        }

        private void UpdateStats(double dt)
        {
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.Alive || !IsActive(s)) continue;
                s.SquadSeconds += dt;
                s.MemberSeconds += s.AliveCount * dt;
                var stat = StatOf(s.Side, s.Def.Id);
                stat.SquadSeconds += dt;
                stat.MemberSeconds += s.AliveCount * dt;
                _stats.SlotErrorSum += s.SlotErrorSum;
                _stats.SlotErrorSamples += s.SlotErrorSamples;
                s.SlotErrorSum = 0.0;
                s.SlotErrorSamples = 0;
            }
        }

        private SquadUnitStat StatOf(int side, string unitId)
        {
            var map = side == 0 ? _stats.PlayerByUnit : _stats.EnemyByUnit;
            if (!map.TryGetValue(unitId, out SquadUnitStat stat))
            {
                stat = new SquadUnitStat { UnitId = unitId };
                map[unitId] = stat;
            }
            return stat;
        }

        // =================================================================
        // 波次
        // =================================================================
        private void SpawnDueWaves(double t)
        {
            while (_nextWave < _waves.Count && t + Eps >= _waves[_nextWave].T)
            {
                SquadWaveEntry w = _waves[_nextWave];
                _nextWave += 1;
                SpawnWave(w);
            }
        }

        private void SpawnWave(SquadWaveEntry entry)
        {
            if (entry.Wave == null) return;
            Vec2 goal = BaseWorld(entry.Side);

            // 先数这一波有几名近战，远程线整体后退 meleeRanks×rank_pitch + line_gap。
            int melee = 0;
            foreach (WaveSquad ws in entry.Wave.Squads)
            {
                UnitDef def = _units.Get(ws.Unit);
                if (def == null || !def.Enabled) continue;
                if (FormationPlan.LineOf(def) == UnitLine.Melee) melee += Math.Max(ws.Count, 1);
            }
            int files = Math.Max(_tuning.MaxFiles, 2);
            int meleeRanks = FormationPlan.Ranks(melee, files);
            Vec2 anchor;
            int dirX;
            if (entry.UseLineAnchor)
            {
                anchor = _arena.WorldToLane(entry.AnchorX, entry.AnchorZ);
                dirX = entry.DirX;
            }
            else
            {
                Vec2 anchorWorld = _arena.TileSpawnWorld(entry.Tile);
                anchor = _arena.WorldToLane(anchorWorld.X, anchorWorld.Y);
                dirX = entry.Side == 0 ? -1 : 1;
            }
            int slotMelee = 0;
            int slotRanged = 0;

            foreach (WaveSquad ws in entry.Wave.Squads)
            {
                UnitDef def = _units.Get(ws.Unit);
                if (def == null || !def.Enabled) continue;
                int count = Math.Max(ws.Count, 1);
                UnitLine line = FormationPlan.LineOf(def);
                for (int k = 0; k < count; k++)
                {
                    int slot = line == UnitLine.Melee ? slotMelee++ : slotRanged++;
                    Vec2 lane = FormationPlan.BattleSlot(anchor.X, anchor.Y, dirX, line, slot, files, meleeRanks,
                        _tuning.FilePitch, _tuning.RankPitch, _tuning.LineGap);
                    Vec2 world = _arena.LaneToWorld(lane.X, lane.Y);
                    int id = AddSquad(entry.Side, def.Id, Math.Max(ws.Star, 1),
                        world.X, world.Y, "", entry.Tile);
                    if (id >= 0) OrderMarch(id, goal.X, goal.Y);
                }
            }
        }

        /// <summary>某一方要推掉的敌方基地（世界米）。</summary>
        private Vec2 BaseWorld(int side)
        {
            double baseX = side == 0 ? _arena.EnemyBaseX : _arena.PlayerBaseX;
            return _arena.LaneToWorld(baseX, 0.0);
        }

        // =================================================================
        // 快照
        // =================================================================
        public SquadBattleView View(bool includeMembers = true)
        {
            var view = new SquadBattleView
            {
                Time = Round2(_time),
                Finished = _finished,
                Outcome = _outcome,
                PlayerBaseHp = Math.Max(_playerBaseHp, 0.0),
                PlayerBaseHpMax = _playerBaseHpMax,
                EnemyBaseHp = Math.Max(_enemyBaseHp, 0.0),
                EnemyBaseHpMax = _enemyBaseHpMax,
                Stats = _stats,
            };
            var list = new List<SquadView>();
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad s = _squads[i];
                if (!s.WasAlive || s.Purged) continue;
                Vec2 w = _arena.LaneToWorld(s.X, s.Z);
                var sv = new SquadView
                {
                    Id = s.Id,
                    Side = s.Side,
                    UnitId = s.Def.Id,
                    DisplayName = s.Def.DisplayName,
                    Star = s.Star,
                    X = w.X,
                    Z = w.Y,
                    Heading = s.Heading,
                    Hp = Math.Max(s.Hp, 0.0),
                    MaxHp = s.HpMax,
                    AliveCount = s.AliveCount,
                    MemberCount = s.Members.Count,
                    Order = SquadOrders.Name(s.Order),
                    TargetSquad = s.TargetSquad,
                    Radius = s.Radius * RtsUnits.R1,
                    MoveSpeed = s.Speed * RtsUnits.R1,
                    Kills = s.Kills,
                    DamageDealt = s.DamageDealt,
                    SpawnTile = s.SpawnTile,
                    SourceBuilding = s.SourceBuilding,
                    Role = s.Role,
                    Active = IsActive(s),
                    Engaged = s.Engaged,
                    Age = Round2(s.Age),
                    BodyRadius = UnitBody.BodyMeters(s.Def),
                    AttackCooldown = s.Def.AttackCooldown,
                };
                if (includeMembers)
                {
                    var members = new SquadMemberView[s.Members.Count];
                    for (int m = 0; m < s.Members.Count; m++)
                    {
                        SquadMember mem = s.Members[m];
                        Vec2 mw = _arena.LaneToWorld(mem.X, mem.Z);
                        Vec2 slotLane = SlotPoint(s, mem);
                        Vec2 slotWorld = _arena.LaneToWorld(slotLane.X, slotLane.Y);
                        members[m] = new SquadMemberView
                        {
                            Index = m,
                            X = mw.X,
                            Z = mw.Y,
                            Hp = Math.Max(mem.Hp, 0.0),
                            MaxHp = mem.MaxHp,
                            Alive = mem.Alive,
                            SlotX = slotWorld.X,
                            SlotZ = slotWorld.Y,
                            SlotError = Dist(mem.X, mem.Z, slotLane.X, slotLane.Y) * RtsUnits.R1,
                        };
                    }
                    sv.Members = members;
                }
                list.Add(sv);
            }
            view.Squads = list.ToArray();
            return view;
        }

        // =================================================================
        // 小工具
        // =================================================================
        private BattleSquad Find(int id)
        {
            for (int i = 0; i < _squads.Count; i++)
            {
                if (_squads[i].Id == id) return _squads[i];
            }
            return null;
        }

        private bool AnyEnemyWithin(BattleSquad s, double radius)
        {
            double r2 = radius * radius;
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad o = _squads[i];
                if (!o.Alive || !IsActive(o) || o.Side == s.Side) continue;
                double dx = o.X - s.X;
                double dz = o.Z - s.Z;
                if (dx * dx + dz * dz <= r2) return true;
            }
            return false;
        }

        private int NearestEnemySquad(BattleSquad s, double radius)
        {
            int best = -1;
            double bestD = radius * radius;
            for (int i = 0; i < _squads.Count; i++)
            {
                BattleSquad o = _squads[i];
                if (!o.Alive || !IsActive(o) || o.Side == s.Side) continue;
                double dx = o.X - s.X;
                double dz = o.Z - s.Z;
                double d2 = dx * dx + dz * dz;
                if (d2 > bestD) continue;
                if (d2 < bestD - 1e-9 || (Math.Abs(d2 - bestD) <= 1e-9 && o.Id < best))
                {
                    bestD = d2;
                    best = o.Id;
                }
            }
            return best;
        }

        private bool Engaged(BattleSquad a, BattleSquad b)
        {
            double reach = a.MaxRange * 1.02;
            double reach2 = reach * reach;
            for (int i = 0; i < a.Members.Count; i++)
            {
                SquadMember am = a.Members[i];
                if (!am.Alive) continue;
                for (int j = 0; j < b.Members.Count; j++)
                {
                    SquadMember bm = b.Members[j];
                    if (!bm.Alive) continue;
                    double dx = am.X - bm.X;
                    double dz = am.Z - bm.Z;
                    if (dx * dx + dz * dz <= reach2) return true;
                }
            }
            return false;
        }

        private void ClampSquad(BattleSquad s)
        {
            Vec2 p = _route.ClampPoint(new Vec2((float)s.X, (float)s.Z), s.Radius);
            s.X = p.X;
            s.Z = p.Y;
        }

        private static double Dist(double ax, double az, double bx, double bz)
        {
            double dx = bx - ax;
            double dz = bz - az;
            return Math.Sqrt(dx * dx + dz * dz);
        }

        private static double NormalizeAngle(double a)
        {
            while (a > Math.PI) a -= Math.PI * 2.0;
            while (a < -Math.PI) a += Math.PI * 2.0;
            return a;
        }

        private static double Clamp01(double v)
        {
            if (double.IsNaN(v) || v <= 0.0) return 0.0;
            return v >= 1.0 ? 1.0 : v;
        }

        private static double Round2(double v) => Math.Round(v * 100.0) / 100.0;
    }
}
