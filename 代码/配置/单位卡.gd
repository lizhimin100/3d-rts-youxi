class_name UnitCard
extends EntityCard
## **单位卡**（2C-4 · C2）：5 兵种 + 2 野怪的数值唯一真相源。
##
## 三块内容：
##   · 定位（人填）：unit_class / roles / counters —— 取词只认 定位词表；
##   · 数值（照抄 单位表.gd 原表，**抄不是改**）：attack/defense/range 等战略数值
##     + 引擎数值镜像（UnitDef 全字段，供 单位表.gd 重建 UnitDef 用）；
##   · 派生（不存盘）：attack_range_tier 由 range + 阈值只读派生，索引层预计算。
##
## power 默认 **-1 = 未测**，不得用 0 冒充（任务书 §2.2）。
## skills 只存技能 ID 占位，**本轮不实现逻辑**。

# ---------------------------------------------------------------------------
# 定位（人填，取词只认 定位词表.gd）
# ---------------------------------------------------------------------------
## 词表·兵种（陆军/空军/海军，单选）
@export var unit_class: StringName = &"陆军"
## 词表·职能（多选）。**当前必须含"承伤"或"输出"才参与选兵**；
## 辅助/机动/控制本轮不参与选兵，填着等兵种丰富。农民留空（worker 不是战斗职能）。
@export var roles: Array[StringName] = []
## 词表·克制（多选，**不参与伤害结算**）
@export var counters: Array[StringName] = []

# ---------------------------------------------------------------------------
# 数值（2C-4 从 单位表.gd 逐项抄入；attack/defense/range 是卡口径的主字段）
# ---------------------------------------------------------------------------
## 射程（引擎 attack_range）。
## ★ 2026-11-07 最终口径：**本单位碰撞圆边缘 → 目标碰撞体边缘的间隙（米）**，
##   填多少就是多少 —— **没有档位、没有基准乘法**，直接在卡上调这个数字。
##   · 0 = 两具身体正好贴住（近战别填 0，会打不到）；
##   · 近战标准值是 **1.0**：身体边缘留 1 米，两具 0.5 半径的兵中心距 2.0m 就够得着；
##   · 弩兵 10 / 法师 11 / 箭塔 13 只是"当前填的数"，不是档位，随时可改；
##   · 范围圈画在 `range + 自身半径 + 0.5`（= 一个标准体型敌人的中心距）；
##   · 打建筑时寻路把占地外扩 1 格，近战另有 `BUILDING_REACH=1.60` 的墙面余量。
##   详见 `文档/战斗射程口径.md`；改这里必须同步 `sight_range`（索敌不能超过视野）。
@export var range: float = 0.0
## 攻击力（引擎 attack_damage，取整）
@export var attack: int = 0
## 词表·攻击类型（参与结算；映射 RtsConst.DamageType 在 定位词表）
@export var attack_type: StringName = &"普通"
## 防御力（引擎 armor，取整）
@export var defense: int = 0
## 词表·防御类型（参与结算；映射 RtsConst.ArmorType 在 定位词表）
@export var defense_type: StringName = &"轻甲"
## 战略定位分：**-1 = 未测**，不得用 0 冒充
@export var power: int = -1
## 技能 ID 占位（本轮不实现逻辑；引擎 abilities 照抄这里）
@export var skills: Array[StringName] = []

# ---------------------------------------------------------------------------
# 引擎数值镜像（照抄 UnitDef —— 单位表.gd 用它重建 UnitDef，零差异校验对它做）
# 名字与 UnitDef 一一对应，方便逐项搬与逐项比对。
# ---------------------------------------------------------------------------
@export var max_hp: float = 100.0
@export var attack_spread: float = 0.0
@export var attack_cooldown: float = 1.5
@export var projectile: int = 0            # RtsConst.Projectile
@export var projectile_speed: float = 20.0
@export var acquire_range: float = 0.0
@export var sight_range: float = 10.0
@export var move_speed: float = 4.0
@export var turn_speed: float = 8.0
@export var body_radius: float = 0.45
@export var selection_radius: float = 0.7
@export var food_cost: int = 0
@export var train_time: float = 10.0
@export var height: float = 1.8
@export var gather_rate: float = 0.0
@export var carry_capacity: int = 10
@export var max_mana: float = 0.0
@export var mana_regen: float = 0.0
@export var mana_cost: float = 0.0
@export var ability_cooldown: float = 8.0

# --- 美术引用（静态定义数据，不是实例状态；icon 另有其字段且本轮留空） ---
@export var model_path: String = ""
@export var model_scale: float = 1.0
@export var anim_set: int = 1              # RtsConst.AnimSet

# --- 引擎元数据（2C-3 引入，照抄原表；与上面的"职能 roles"是两套口径） ---
## UnitDef.role：frontline / ranged / caster / siege / worker / defense（引擎侧）
@export var def_role: StringName = &""
## UnitDef.tags：heavy / light / anti_air / support / light(照明) …
@export var def_tags: Array[StringName] = []
## 用户填的战略定位值；AI 决策不读（2C-3 口径不变）
@export var design_power: float = 0.0
