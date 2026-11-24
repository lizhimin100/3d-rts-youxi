using System;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>小队指令（原子单位：一支队只能有一个指令）。</summary>
    public enum SquadOrder
    {
        None = 0,
        Move = 1,
        AttackMove = 2,
        Hold = 3,
        Attack = 4,
        Stop = 5,
    }

    /// <summary>
    /// 小队编制角色 —— 决定这支队在**哪一个时空**里活着。
    ///
    /// 口径（2026-11-22 攻防时空流转）：
    ///   · 规划期打"进攻训练牌"产出的队伍只参加**进攻战**；"防守训练牌"产出的只参加**防守战**；
    ///   · <see cref="Any"/> = 不受时空限制（旧横道口径 / 据点免费防守队 / 自检用）；
    ///   · 角色是**规则**，不是表现：哪支队被推进、哪支队被隐藏，一律由 Model 判定，
    ///     Screens 只读 <see cref="SquadView.Active"/>，不许自己算"现在该不该显示"。
    /// </summary>
    public static class SquadRoles
    {
        /// <summary>不限时空（两场都在）。</summary>
        public const string Any = "";
        /// <summary>进攻小队：只参加进攻战。</summary>
        public const string Attack = "attack";
        /// <summary>防守小队：只参加防守战。</summary>
        public const string Defend = "defend";

        public static bool IsValid(string role)
        {
            return role == Any || role == Attack || role == Defend;
        }

        /// <summary>角色是否在当前时空里激活；phase 为空 = 不限时空的场次。</summary>
        public static bool ActiveIn(string role, string phase)
        {
            if (string.IsNullOrEmpty(role) || string.IsNullOrEmpty(phase)) return true;
            return role == phase;
        }

        public static string DisplayName(string role)
        {
            switch (role)
            {
                case Attack: return "待命进攻";
                case Defend: return "待命防守";
                default: return "待命";
            }
        }
    }

    public static class SquadOrders
    {
        public const string None = "none";
        public const string Move = "move";
        public const string AttackMove = "attack_move";
        public const string Hold = "hold";
        public const string Attack = "attack";
        public const string Stop = "stop";

        public static SquadOrder Parse(string name)
        {
            switch ((name ?? "").Trim().ToLowerInvariant())
            {
                case Move: return SquadOrder.Move;
                case AttackMove: return SquadOrder.AttackMove;
                case Hold: return SquadOrder.Hold;
                case Attack: return SquadOrder.Attack;
                case Stop: return SquadOrder.Stop;
                default: return SquadOrder.None;
            }
        }

        public static string Name(SquadOrder order)
        {
            switch (order)
            {
                case SquadOrder.Move: return Move;
                case SquadOrder.AttackMove: return AttackMove;
                case SquadOrder.Hold: return Hold;
                case SquadOrder.Attack: return Attack;
                case SquadOrder.Stop: return Stop;
                default: return None;
            }
        }
    }

    /// <summary>一名成员的快照（世界坐标，米）。</summary>
    public sealed class SquadMemberView
    {
        public int Index;
        public double X;
        public double Z;
        public double Hp;
        public double MaxHp;
        public bool Alive;
        /// <summary>槽位锚（世界坐标，米）—— 调试"弹性槽位"用。</summary>
        public double SlotX;
        public double SlotZ;
        /// <summary>当前离槽位的距离（米）。</summary>
        public double SlotError;
    }

    /// <summary>一个独立单兵的快照（世界坐标，米）。</summary>
    public sealed class SquadView
    {
        public int Id;
        public int Side;
        public string UnitId = "";
        public string DisplayName = "";
        public int Star;
        public double X;
        public double Z;
        public double Heading;
        /// <summary>血量：单兵制下就是这名士兵自己的血（不再聚合）。</summary>
        public double Hp;
        public double MaxHp;
        public int AliveCount;
        public int MemberCount;
        public string Order = SquadOrders.None;
        public int TargetSquad = -1;
        public double Radius;
        public double MoveSpeed;
        public int Kills;
        public double DamageDealt;
        public int SpawnTile;
        public string SourceBuilding = "";
        /// <summary>attack / defend / ""（不限时空）。</summary>
        public string Role = SquadRoles.Any;
        /// <summary>当前时空里是否激活（false = 已生成但被冻结，Screens 不画）。</summary>
        public bool Active = true;
        /// <summary>是否处于攻击态（R+4 实际开火线，带滞回）。表现层用它播攻击动画。</summary>
        public bool Engaged;
        /// <summary>出生到现在的模型时间（秒）。表现层用它排序落地动画。</summary>
        public double Age;
        /// <summary>身位半径（米）—— 血条/落点圈按它算。</summary>
        public double BodyRadius = 0.45;
        /// <summary>攻击间隔（秒）—— 表现层按这个节拍重播攻击动作/弹道。</summary>
        public double AttackCooldown = 1.0;
        public SquadMemberView[] Members = Array.Empty<SquadMemberView>();
    }

    /// <summary>单个兵种在本次战斗里的 DPS 统计。</summary>
    public sealed class SquadUnitStat
    {
        public string UnitId = "";
        public int Squads;
        public int Models;
        public int Kills;
        public int Losses;
        public double Damage;
        public double MemberSeconds;
        public double SquadSeconds;

        public double DpsPerMember => MemberSeconds > 1e-6 ? Damage / MemberSeconds : 0.0;
        public double DpsPerSquad => SquadSeconds > 1e-6 ? Damage / SquadSeconds : 0.0;
    }

    /// <summary>一场小队战斗的统计（复盘 / 100 局聚合的唯一读数口）。</summary>
    public sealed class SquadBattleStats
    {
        public double PlayerDamage;
        public double EnemyDamage;
        public int PlayerKills;
        public int EnemyKills;
        public int PlayerModelsLost;
        public int EnemyModelsLost;
        public int PlayerSquadsLost;
        public int EnemySquadsLost;
        public int PlayerSquadsSpawned;
        public int EnemySquadsSpawned;
        public double PlayerZoneSeconds;
        public double EnemyZoneSeconds;
        public int PlayerMaxZone;
        public int EnemyMaxZone;
        public int StuckEvents;
        public int Repaths;
        public double SlotErrorSum;
        public int SlotErrorSamples;
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
        /// 口径：`mem.Cd &lt;= 0 && s.Engaged && 目标距离 &gt; MaxRange + RangeSlack`。
        /// 正常战斗应接近 0；正死区（1.02R 停火）会让它持续上涨。
        /// </summary>
        public double UnfiredEngagedSeconds;
        /// <summary>朝向左右反转次数（累计先转过 34° 才记一次，过滤微抖）。</summary>
        public int HeadingFlips;

        public readonly Dictionary<string, SquadUnitStat> PlayerByUnit = new Dictionary<string, SquadUnitStat>(StringComparer.Ordinal);
        public readonly Dictionary<string, SquadUnitStat> EnemyByUnit = new Dictionary<string, SquadUnitStat>(StringComparer.Ordinal);

        public double AvgSlotErrorMeters => SlotErrorSamples > 0 ? SlotErrorSum / SlotErrorSamples * RtsUnits.R1 : 0.0;
        public double AvgPathLength => PathSamples > 0 ? PlannedPathLength / PathSamples : 0.0;
        /// <summary>同一批路径的直线长度均值；AvgPathLength / 它 = 绕行比（脊线走廊 > 1）。</summary>
        public double AvgStraightLength => PathSamples > 0 ? StraightLengthSum / PathSamples : 0.0;
    }

    /// <summary>整场战斗的快照（给 Screens 渲染）。</summary>
    public sealed class SquadBattleView
    {
        public double Time;
        public bool Finished;
        public string Outcome = "";
        public double PlayerBaseHp;
        public double PlayerBaseHpMax;
        public double EnemyBaseHp;
        public double EnemyBaseHpMax;
        public SquadView[] Squads = Array.Empty<SquadView>();
        public SquadBattleStats Stats;
    }
}
