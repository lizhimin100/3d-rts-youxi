using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>单兵指令（原子单位：一名单兵只能有一个指令）。</summary>
    public enum UnitOrder
    {
        None = 0,
        Move = 1,
        AttackMove = 2,
        Hold = 3,
        Attack = 4,
        Stop = 5,
    }

    public static class UnitOrders
    {
        public const string None = "none";
        public const string Move = "move";
        public const string AttackMove = "attack_move";
        public const string Hold = "hold";
        public const string Attack = "attack";
        public const string Stop = "stop";

        public static UnitOrder Parse(string name)
        {
            switch ((name ?? "").Trim().ToLowerInvariant())
            {
                case Move: return UnitOrder.Move;
                case AttackMove: return UnitOrder.AttackMove;
                case Hold: return UnitOrder.Hold;
                case Attack: return UnitOrder.Attack;
                case Stop: return UnitOrder.Stop;
                default: return UnitOrder.None;
            }
        }

        public static string Name(UnitOrder order)
        {
            switch (order)
            {
                case UnitOrder.Move: return Move;
                case UnitOrder.AttackMove: return AttackMove;
                case UnitOrder.Hold: return Hold;
                case UnitOrder.Attack: return Attack;
                case UnitOrder.Stop: return Stop;
                default: return None;
            }
        }
    }

    /// <summary>
    /// 单兵战斗状态（**表现层唯一动画驱动**，2026-11-25 Phase 3 冻结）。
    ///
    /// 口径：
    ///   · `march` —— 正在推进（有路径/追目标，且本 tick 真的挪了位置）；
    ///   · `fight` —— 射程内有活目标（R+4 进 / R+12 出，带滞回）；
    ///   · `hold`  —— 站着不动且没在打（驻守/等下一波）；
    ///   · `dead`  —— 已阵亡，本 tick 起不再参与任何结算。
    ///
    /// 为什么不给表现层留 `Engaged`：那是个布尔，进场/出场各抖一次就让动画闪一帧；
    /// `State + StateAge` 让表现层自己决定"稳定超过 0.15 秒才换动作"。
    /// </summary>
    public static class UnitStates
    {
        public const string March = "march";
        public const string Fight = "fight";
        public const string Hold = "hold";
        public const string Dead = "dead";
    }

    /// <summary>一名独立单兵的快照（世界坐标，米）。</summary>
    public sealed class UnitView
    {
        public int Id;
        public int Side;
        public string UnitId = "";
        public string DisplayName = "";
        public int Star;
        public double X;
        public double Z;
        public double Heading;
        public double Hp;
        public double MaxHp;
        public bool Alive = true;
        /// <summary>none / move / attack_move / hold / attack / stop。</summary>
        public string Order = UnitOrders.None;
        /// <summary>当前锁定的敌方单兵 id（-1 = 没有）。</summary>
        public int TargetUnit = -1;
        public double Radius;
        public double MoveSpeed;
        public int Kills;
        public double DamageDealt;
        public int SpawnTile;
        public string SourceBuilding = "";
        /// <summary>march / fight / hold / dead（见 <see cref="UnitStates"/>）。</summary>
        public string State = UnitStates.Hold;
        /// <summary>当前状态已持续的秒数（表现层用它做换动作防抖）。</summary>
        public double StateAge;
        /// <summary>本 tick 是否真的位移了（<see cref="BattleSim"/> 按 1 cm 阈值判定）。</summary>
        public bool Moving;
        /// <summary>出生到现在的模型时间（秒）。表现层用它排序落地动画。</summary>
        public double Age;
        /// <summary>身位半径（米）—— 血条/落点圈按它算。</summary>
        public double BodyRadius = 0.45;
        /// <summary>攻击间隔（秒）—— 表现层按这个节拍重播攻击动作/弹道。</summary>
        public double AttackCooldown = 1.0;
    }

    /// <summary>单个兵种在本次战斗里的统计（一名单兵 = 一个实体，不再有 Models/Squads 两级）。</summary>
    public sealed class UnitStat
    {
        public string UnitId = "";
        public int Units;
        public int Kills;
        public int Losses;
        public double Damage;
        /// <summary>该兵种所有单兵的存活秒数之和（算 DPS 的分母）。</summary>
        public double AliveSeconds;

        public double DpsPerUnit => AliveSeconds > 1e-6 ? Damage / AliveSeconds : 0.0;
    }

    /// <summary>一场战斗的统计（复盘 / 100 局聚合的唯一读数口）。</summary>
    public sealed class BattleStats
    {
        public double PlayerDamage;
        public double EnemyDamage;
        public int PlayerKills;
        public int EnemyKills;
        public int PlayerUnitsLost;
        public int EnemyUnitsLost;
        public int PlayerUnitsSpawned;
        public int EnemyUnitsSpawned;
        public int StuckEvents;
        public int Repaths;
        public double PlannedPathLength;
        public int PathSamples;
        /// <summary>规划时"起点→终点"的直线距离之和（和路径同一批样本）。</summary>
        public double StraightLengthSum;
        public double ActualTravelled;
        public double FirstContactSecond = -1.0;

        /// <summary>
        /// 同一 tick 内"深度重叠"（d &lt; 0.5×硬核）的对数峰值。
        /// 口径：出生/前压把多人放在同一点时，这个值会跳到几十；
        /// 正常接敌时单位贴身是允许的，但不应出现"半个人叠进去"的深度重叠。
        /// </summary>
        public int OverlapPairsMax;
        /// <summary>同一 tick 内的最大重叠深度（游戏数值，报告时 ×R1 换成米）。</summary>
        public double OverlapDepthMax;
        /// <summary>最大重叠发生的时刻 / 两个单位 id（诊断用）。</summary>
        public double OverlapWorstTime = -1.0;
        public int OverlapWorstA = -1;
        public int OverlapWorstB = -1;
        /// <summary>分离**之后**仍残留的深度重叠对数（这才是玩家真正看到的叠模）。</summary>
        public int OverlapPairsAfterMax;
        /// <summary>分离之后的最大重叠深度（游戏数值）。</summary>
        public double OverlapDepthAfterMax;
        /// <summary>分离之后仍有深度重叠的 tick 数（判断是"一瞬"还是"持续叠模"）。</summary>
        public int OverlapAfterTicks;
        /// <summary>
        /// "已进入攻击态、冷却已好、却因距离不够没打出去"的累计人·秒。
        /// 口径：`Cd &lt;= 0 &amp;&amp; Engaged &amp;&amp; 目标距离 &gt; MaxRange + RangeSlack`。
        /// 正常战斗应接近 0；正死区（1.02R 停火）会让它持续上涨。
        /// </summary>
        public double UnfiredEngagedSeconds;
        /// <summary>朝向左右反转次数（累计先转过 34° 才记一次，过滤微抖）。</summary>
        public int HeadingFlips;

        // ---- 2026-11-24：狂暴与跳字反馈 ----
        /// <summary>本场是否触发 45 秒狂暴。</summary>
        public bool BerserkTriggered;
        public double BerserkSecond = -1.0;
        /// <summary>跳字分级计数（暴击或克制 / 被抵抗 / 普通 / 未命中）。</summary>
        public int FeedbackCritOrCounter;
        public int FeedbackResisted;
        public int FeedbackNormal;
        public int FeedbackMiss;
        public double FeedbackCritDamage;
        public double FeedbackResistedDamage;
        public double FeedbackNormalDamage;

        public readonly Dictionary<string, UnitStat> PlayerByUnit = new Dictionary<string, UnitStat>(StringComparer.Ordinal);
        public readonly Dictionary<string, UnitStat> EnemyByUnit = new Dictionary<string, UnitStat>(StringComparer.Ordinal);

        public double AvgPathLength => PathSamples > 0 ? PlannedPathLength / PathSamples : 0.0;
        /// <summary>同一批路径的直线长度均值；AvgPathLength / 它 = 绕行比（脊线走廊 &gt; 1）。</summary>
        public double AvgStraightLength => PathSamples > 0 ? StraightLengthSum / PathSamples : 0.0;
    }

    /// <summary>整场战斗的快照（给 Screens 渲染）。</summary>
    public sealed class BattleView
    {
        public double Time;
        public bool Finished;
        public string Outcome = "";
        public double PlayerBaseHp;
        public double PlayerBaseHpMax;
        public double EnemyBaseHp;
        public double EnemyBaseHpMax;
        public UnitView[] Units = Array.Empty<UnitView>();
        public BattleStats Stats;
    }

    /// <summary>
    /// 一条伤害跳字事件（2026-11-25 Phase 3 的跨语言契约）。
    ///
    /// 唯一生产点：<see cref="BattleSim"/> 每次真正结算伤害（或未命中）时压入队列；
    /// 唯一消费点：ModelBridge 的 <c>BattleStep</c> 把队列排空成 GDScript 数组。
    /// 表现层只认 `feedback` 四个值 —— 不要自己按克制表重算颜色。
    /// </summary>
    public sealed class HitEvent
    {
        /// <summary>被打的单兵 id。</summary>
        public int TargetId;
        /// <summary>实际伤害（未命中 = 0）。</summary>
        public double Amount;
        /// <summary>crit_or_counter / resisted / normal / miss。</summary>
        public string Feedback = "normal";
        /// <summary>命中位置（世界米）—— 表现层直接在上面飘字，不用再查单位。</summary>
        public double X;
        public double Z;
        /// <summary>这一下是否打死了目标。</summary>
        public bool Lethal;
        /// <summary>模型时间（秒）。</summary>
        public double T;
    }
}
