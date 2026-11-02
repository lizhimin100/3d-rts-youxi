# 单位数据 Schema 与覆盖度审计（第一段交付 · 6.2/6.3/6.4）

> 权威来源不变：**`代码/配置/单位表.gd` 是唯一数值权威**。
> 本文件只定义"AI/文档/未来单位卡应该用什么口径读它"，不新增数值、不改数值。
> ⚠ 禁止在任何 AI 代码、难度配置、界面脚本中出现第二份战斗数值（6.1 纪律）。

---

## 一、标准字段 Schema（6.2）

| # | Schema 字段 | 单位表.gd 中的来源 | 说明 |
|---|---|---|---|
| 1 | 稳定单位ID | `UnitDef.id: StringName` | 如 `&"footman"`；跨存档/地图/AI 稳定 |
| 2 | 名称 | `display_name: String` | 中文显示名 |
| 3 | 类别 | `kind: int` | 0=单位 1=建筑 2=可采集（RtsConst.Kind） |
| 4 | 战略定位 | **缺字段** | 前排/输出/远程/攻城/反制/支援/侦察/经济——见第三节缺口 G1 |
| 5 | 基础生命 | `max_hp: float` | |
| 6 | 攻击 | `attack_damage: float` | |
| 7 | 攻击间隔 | `attack_cooldown: float`（秒） | |
| 8 | 攻击类型 | `attack_type: int` | 0普通 1穿刺 2魔法 3攻城（RtsConst.DamageType） |
| 9 | 防御 | `armor: float` | 每点减伤 6%，上限 72%（在 GameConfig，不在单位表） |
| 10 | 护甲类型 | `armor_type: int` | 0轻 1重 2城 3无（RtsConst.ArmorType） |
| 11 | 射程 | `attack_range: float`（米） | 近战≈身位；建筑塔 13 |
| 12 | 移动速度 | `move_speed: float`（米/秒） | 建筑=0 |
| 13 | 视野 | `sight_range: float`（米） | 哨塔另有 `detect_radius`（预警半径，超出视野） |
| 14 | 资源消耗 | `gold_cost / wood_cost / food_cost: int` | 农民 food_cost=0（不占人口） |
| 15 | 生产时间 | `train_time: float`（秒） | 建筑名下是建造时长 |
| 16 | 技能参数 | `abilities: Array[StringName]` + `ability_cooldown / max_mana / mana_regen / mana_cost` | 目前仅法师 `fireball`；效果实现在 `系统/技能.gd` |
| 17 | 标签 | **缺字段** | 克制应对/寻路代价/加成目标等扩展读取用——见 G2 |
| 18 | 生产来源 | `trains`（**定义在建筑侧**） | 反向索引"我能被谁生产"不存在——见 G3 |
| 19 | 前置条件 | **缺字段**（依赖建筑依赖关系未建模） | 如"法师 ← 神秘圣地已建成"目前由建筑 trains 隐含——见 G4 |
| 20 | 单位介绍 | **缺字段** | UI/单位卡展示文案——见 G5 |

补充字段（Schema 之外、单位表已有，AI/文档可用）：`footprint`(占地格)、`is_dropoff`(资源交汇)、
`dropoff_kinds`、`gather_rate/carry_capacity/harvest_kind`(经济)、`food_provided`(人口)、
`researches`(可研究项)、`model_path/model_scale/anim_set`(美术)、`acquire_range`(索敌)、
`body_radius/selection_radius`(碰撞/拾取)、`aura_radius/aura_mana_regen`(光环)。

## 二、当前全套单位清单（按 schema 抽取，数值以 单位表.gd 为准）

| ID | 名称 | 类别 | 定位(人工标注) | 攻击类型 | 射程 | 造价(金/木/口) | 生产来源 |
|---|---|---|---|---|---|---|---|
| peasant | 农民 | 单位 | 经济/建造 | 普通 | 1.1 | 75/0/0 | 大本营 |
| footman | 步兵 | 单位 | 前排 | 普通 | 1.35 | 135/0/2 | 兵营 |
| archer | 弓箭手(弩兵) | 单位 | 远程输出 | 穿刺 | 11 | 130/15/2 | 兵营 |
| mage | 法师 | 单位 | 法术输出(火球) | 魔法 | 10 | 155/45/3 | 神秘圣地 |
| steam_guard | 蒸汽重步兵 | 单位 | 前排/攻城 | 攻城 | 1.6 | 190/45/3 | 蒸汽车坊 |
| gnoll_warrior | 豺狼人战士 | 单位(中立) | 野怪 | 普通 | 1.4 | — | 编辑器摆放 |
| gnoll_scout | 豺狼人斥候 | 单位(中立) | 野怪远程 | 穿刺 | 8 | — | 编辑器摆放 |
| townhall | 大本营 | 建筑 | 核心/交汇/人口 | 无 | — | — | 开局/编辑器 |
| barracks | 兵营 | 建筑 | 产能 | 无 | — | 180/60 | 农民建造 |
| blacksmith | 铁匠铺 | 建筑 | 科技(攻防5级) | 无 | — | 140/50 | 农民建造 |
| farm | 农场 | 建筑 | 人口+8 | 无 | — | 80/20 | 农民建造 |
| tower | 箭塔 | 建筑 | 防御火力 | 穿刺 | 13 | 130/70 | 农民建造/哨塔改造 |
| watchtower | 哨塔 | 建筑 | 视野20/预警26 | 无(数据层禁攻) | — | 90/55 | 农民建造 |
| sanctum | 神秘圣地 | 建筑 | 法师产能+回蓝光环 | 无 | — | 150/90 | 农民建造 |
| workshop | 蒸汽车坊 | 建筑 | 重步产能+人口10 | 无 | — | 170/130 | 农民建造 |
| lumbercamp | 伐木场 | 建筑 | 木材交汇+木材科技 | 无 | — | 90/0 | 农民建造 |
| campfire | 营火 | 建筑 | 夜间照明 | 无 | — | 0/20 | 农民建造 |
| goldmine / tree(×4季) | 金矿/树 | 可采集 | 资源 | — | — | — | 地图摆放(3200金/260木) |

克制表（4×4，攻→防，GameConfig.damage_table）：普通[1.00,0.85,0.60,1.00] 穿刺[1.35,0.85,0.45,1.20]
魔法[1.10,1.15,0.55,1.00] 攻城[0.60,0.85,1.60,0.70]（列序：轻/重/城/无）。

## 三、覆盖度缺口（6.3：本轮只记录，不改数值、不加字段）

| 缺口 | 内容 | 影响 | 建议(下轮) |
|---|---|---|---|
| G1 战略定位 | 无字段；本文档"定位"列为人工标注 | AI 选兵/编组只能靠 attack_type 猜角色 | 加 `role: StringName`（frontline/ranged/siege/support/econ） |
| G2 标签 | 无字段 | 无法表达"反制轻甲""脆皮""可修理"等 | 加 `tags: Array[StringName]` |
| G3 生产来源反向索引 | `trains` 在建筑侧 | AI 想"补一个法师"要反查全部建筑 | 生成 `produced_by` 派生表（运行时可算，不必存两份） |
| G4 前置条件 | 无建筑依赖建模 | "先圣地后法师"是隐含事实 | 加 `requires_building: StringName`（空=无） |
| G5 单位介绍 | 无文案字段 | 单位卡/说明气泡无数据可用 | 加 `description: String` |
| G6 采集数值口径 | harvest 语义在 `可采集物.gd` + GameConfig(harvest_time/carry) | 分散两处 | 文档聚合即可，不必搬数值 |

## 四、单位卡定位（6.4：本轮不实现任何 UI）

- 单位卡 = **只读视图**：渲染时从 `Cfg.unit(id)` 现取数值，**不得**把数值复制进卡片/界面脚本。
- 实例状态——当前生命/坐标/冷却/临时效果/当前任务/队形状态/控制权——**只存在于 RtsUnit 实例
  （及 Game.control 控制权表），永远不写入单位卡**。
- 本轮交付物仅本 schema 文档；任何 card 文件/UI 变更留待后续轮次。

## 五、AI 侧硬编码审计（6.5 预审计，第二段执行，此处只登记）

| 位置 | 硬编码 | 性质 |
|---|---|---|
| `代码/ai/简单AI.gd` | `&"peasant"/&"townhall"/&"barracks"/&"farm"/&"tower"/&"watchtower"/&"sanctum"/&"workshop"/&"campfire"/&"blacksmith"/&"lumbercamp"/&"footman"` 等 id 字符串 | 建筑语义 id，可接受；兵种 id 出现在 `_cheapest_army_gold` 的 fallback（`&"footman"`）——待改 |
| `代码/配置/难度定义.gd` | composition 兵种配比（步5/弓3/法1 等） | 属于配置层（允许），但 keyed by 兵种 id 而非类别/角色——待 G1 落地后改角色权重 |
| `代码/ai/简单AI.gd` | `MAX_QUEUE_PEASANT=2 / VILLAGER_ARMY_GAP=2 / UNITS_PER_BARRACKS=8` 等常数 | 固定数量判断——标注待改（改法：按类别/当前数据推导） |
| `代码/ai/战斗模型.gd` | worth_per_cost 的 cost_gold/wood/supply/time 折算常数 | 经济常数非单位数值——可移配置，低优先 |
