# 战斗公式与距离换算（combat_formula）

> 唯一实现：`Model/Core/Damage.cs`、`Model/Core/Progression.cs`、`Model/Core/RtsUnits.cs`。
> 本文件解释**为什么这样算**；数值本身在 `Content/data/game.json` 与卡 JSON 里。
> 改公式 = 改 C# + 改本文 + 改 `--check` 的对照断言，一处都不能漏。

## 0. 距离铁律：R1

```
米 = 游戏数值 × R1        R1 = 0.015
```

- 卡面所有"距离类"数值都是**游戏数值**：射程 `125` / `650` / `870`，判定圈 `36`。
- `Model/` 全层只认游戏数值；**只有 `Screens/` 把它落到世界坐标时才乘 R1**。
- 真值只有一处：`Model/Core/RtsUnits.cs` 的 `R1`。GDScript 侧 `Game/config/射程基准.gd`
  只是门面（`r1()/米()/值()`），自己不再写字面量；`--check` 会断言"规则层零 0.015"。

常用换算：

| 卡面数值 | 米 | 用途 |
|---:|---:|---|
| 95 | 1.425 | 短兵器 |
| 125 | 1.875 | 步兵近战 |
| 650 | 9.75 | 弩兵/弓箭 |
| 870 | 13.05 | 箭塔 |

> 近战"能打到"的实测地板是 **0.30 米**，125（1.875 米）高出 6 倍，所以近战不会
> 出现"贴着楼却砍不到"。见 `Tests/suites/射程标定.gd`。

## 1. 一次伤害（`Damage.Compute`）

```
伤害 = (基础伤害 ± 浮动) × 克制倍率 × (1 - 护甲减免) × 暴击倍率 × 攻击倍率
```

逐项：

1. **基础伤害 ± 浮动**：`base + spread × (2 × rollSpread - 1)`，`rollSpread ∈ [0,1)`。
   掷值由调用方从确定性 RNG 取，C# 侧是纯函数。
2. **克制倍率**：`damage_table[attackType][armorType]`，扁平数组、`stride` 列一行。
   越界夹紧到合法行列；表为空返回 1.0。
3. **护甲减免**：`min(max(armor,0) × armor_reduction, armor_reduction_cap)`。
   当前 `0.06 / 0.72` —— 10 点护甲 = 60% 减免，封顶 72%。
4. **暴击**：`rollCrit < crit_chance` 时乘 `crit_multiplier`（当前 0.12 / 1.65）。
5. **攻击倍率**：技能/连发修正（弩兵三连发每发 0.75）。负数按 0 处理。

返回 `{ok, damage, mitigation, multiplier, is_crit}`；结果不小于 0。

## 2. 护甲与克制

- 护甲类型：`LIGHT / MEDIUM / HEAVY / FORTIFIED / NORMAL`（`RtsConst.ArmorType`）。
- 伤害类型：`NORMAL / PIERCE / SIEGE / MAGIC / …`（`RtsConst.DamageType`）。
- 克制表是**唯一**的攻防关系来源；不在别处写 if/else。
- 中甲（`ArmorType.MEDIUM = 4`）是 2026-11 新增列，追加在表尾，旧列不重排。

## 3. 升星（`Progression`）

| 星级 | 名称 | 攻击/移速/攻速 | 血量/防御 |
|---:|---|---:|---:|
| 0 | 新兵 | 1.00 | 1.00 |
| 1 | 老兵 | 1.15 | 1.20 |
| 2 | 精英 | 1.30 | 1.40 |
| 3 | 王牌 | 1.80 | 2.00 |

- 每次击杀 **15 经验**，击杀者独得，不分享。
- 升一星所需经验 = `金 × 2 + 木 × 3`，**三星同价**；下限 30（0 成本单位不会一杀就三星）。
- 经验不跨星累计：`stars = clamp(floor(exp / need), 0, 3)`。
- 升星是"变强"不是"回满"：按比例抬当前血量。

## 4. 人口 / CP / 付款

- **短局**（唯一模式）：`CP` 只在规划阶段扣；人口 = 存活 + 在训，下单即占。
- 付款纪律：**不够就一分不扣**（不做部分扣款）。
- 人口判断：`已用 + 已排队 + 本单 <= 上限`。
- 金币/木材只服务局外长线（升星/改造），不参与局内采集。

## 5. 确定性

- 推演（`--simulate`）完全由 `Model/Battle/Skirmish.cs` 跑，随机数只走内核 xorshift32。
- **同 seed + 同配置 → 逐字节相同的结果**；`--check` 有一条"两跑结果一致"的断言。
- 不要在推演里读引擎时间/帧率/节点顺序。

## 6. 反着验

改公式后必须做一次反向验证（改坏 → 看红灯 → 改回）：

```powershell
# 把 R1 改成 0.02 → --check 应报"内核 R1 = 0.015"与"R1 换算"两条红
# 把 armor_reduction_cap 改成 0.5 → Model 自测"护甲减免封顶 0.72"应红
./Tools/run-game.ps1 --check
```
