class_name BuildingCard
extends EntityCard
## **建筑卡**（2C-4 · C3）：10 座建筑的数值唯一真相源。
##
## functions 取词只认 定位词表.建筑功能；其余数值**对照 单位表.gd 现有建筑字段逐项搬**
## （占地 / 建造时间 / 耐久 / 交汇点 / 人口 / 训练 / 研究 / 塔攻击 / 光环 / 预警…）。
## 卡不存任何实例状态（工地进度、队列、当前血量都在运行时对象上）。

# ---------------------------------------------------------------------------
# 定位（人填，取词只认 定位词表.gd）
# ---------------------------------------------------------------------------
## 词表·建筑功能（多选：产兵/防御/资源/科技/人口/治疗/侦察）
@export var functions: Array[StringName] = []

## **主城等级**（升本机制，2026-11-08）。只有大本营有意义：
##   1 = 一本（默认）/ 2 = 二本（联盟要塞）。
## 兵种卡上的 `require_tier` 比这个大门槛时不能训练。
@export var tier: int = 1

# ---------------------------------------------------------------------------
# 数值（照抄 UnitDef 建筑字段 —— 逐项搬，供 单位表.gd 重建 UnitDef）
# ---------------------------------------------------------------------------
## 耐久（引擎 max_hp）
@export var max_hp: float = 100.0
## 防御力（引擎 armor，取整）
@export var defense: int = 0
## 词表·防御类型（参与结算；全部建筑当前是"堡垒"）
@export var defense_type: StringName = &"堡垒"
## 占地格数（1 格 = 1 米）
@export var footprint: Vector2i = Vector2i(1, 1)
## 高度（血条/标签定位用）
@export var height: float = 1.8
## 建造耗时（秒）
@export var train_time: float = 10.0
## 是否资源交汇点（农民往回送资源的地方）
@export var is_dropoff: bool = false
## 交汇点接收的资源种类（RtsConst.Harvest）；空 = 金木全收
@export var dropoff_kinds: Array[int] = []
## 提供的人口上限
@export var food_provided: int = 0
## 该建筑可训练的单位 id 列表
@export var trains: Array[StringName] = []
## 该建筑可研究的升级 id 列表
@export var researches: Array[StringName] = []
## 视野半径
@export var sight_range: float = 10.0
## 碰撞半径 / 点击拾取半径
@export var body_radius: float = 2.0
@export var selection_radius: float = 3.0
## 预警半径（哨塔；0 = 不预警）
@export var detect_radius: float = 0.0
## 光环（神秘圣地法力之泉；0 = 无光环）
@export var aura_radius: float = 0.0
@export var aura_mana_regen: float = 0.0

# --- 有攻击的建筑（箭塔）也带攻击字段；无攻击的保持 0 ---
## 攻击力（引擎 attack_damage；箭塔 22，哨塔/其余 0）
@export var attack: int = 0
## 射程（引擎 attack_range）
@export var range: float = 0.0
## 词表·攻击类型（参与结算）
@export var attack_type: StringName = &"普通"
@export var attack_spread: float = 0.0
@export var attack_cooldown: float = 1.5
@export var projectile: int = 0            # RtsConst.Projectile
@export var projectile_speed: float = 20.0
@export var acquire_range: float = 0.0

# --- 美术引用（静态定义数据；icon 另有其字段且本轮留空） ---
@export var model_path: String = ""
@export var model_scale: float = 1.0
@export var anim_set: int = 4              # RtsConst.AnimSet

# --- 引擎元数据（照抄原表） ---
@export var def_role: StringName = &""
@export var def_tags: Array[StringName] = []
@export var design_power: float = 0.0
