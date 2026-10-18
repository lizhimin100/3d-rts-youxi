@tool
class_name UnitDef
extends Resource
## 单位 / 建筑 / 可采集物的**静态定义**（数据驱动）。
## 一个 UnitDef 描述"这东西是什么样、多少血、打多少、花多少钱"，
## 运行时的实例状态（当前血量、目标、路径）在 RtsUnit 里。
## 全部字段都可在编辑器里调，也可以在 代码/配置/单位表.gd 里用代码批量生成。

@export_group("身份")
## 唯一 id，形如 "footman"，代码里用它索引
@export var id: StringName = &""
## 中文显示名
@export var display_name: String = "单位"
## 大类：单位 / 建筑 / 可采集物
@export var kind: int = RtsConst.Kind.UNIT
## 模型路径（res://美术/模型/xxx.glb）
@export var model_path: String = ""
## 模型缩放（模型本身按米建，一般 1.0）
@export var model_scale: float = 1.0
## 动画套件类型（RtsConst.AnimSet）
@export var anim_set: int = RtsConst.AnimSet.MELEE

@export_group("生命与防护")
@export var max_hp: float = 100.0
## 护甲值，按公式减伤
@export var armor: float = 0.0
## 护甲类型（RtsConst.ArmorType）
@export var armor_type: int = RtsConst.ArmorType.LIGHT

@export_group("攻击")
@export var attack_damage: float = 0.0
## 伤害浮动（±spread 内随机）
@export var attack_spread: float = 0.0
## 攻击间隔（秒）
@export var attack_cooldown: float = 1.5
## 攻击距离（米，近战约 1.2）
@export var attack_range: float = 0.0
## 伤害类型（RtsConst.DamageType）
@export var attack_type: int = RtsConst.DamageType.NORMAL
## 投射物（RtsConst.Projectile）
@export var projectile: int = RtsConst.Projectile.NONE
## 投射物飞行速度（米/秒）
@export var projectile_speed: float = 20.0
## 自动索敌半径
@export var acquire_range: float = 0.0
## 视野半径（小地图迷雾/索敌共用）
@export var sight_range: float = 10.0

@export_group("移动")
@export var move_speed: float = 4.0
## 转向速度（弧度/秒）
@export var turn_speed: float = 8.0
## 碰撞半径（占位，避免单位重叠）
@export var body_radius: float = 0.45
## 点击拾取半径（比 body 略大，手感更好）
@export var selection_radius: float = 0.7

@export_group("建筑")
## 占地格数（1 格 = 1 米）
@export var footprint: Vector2i = Vector2i(1, 1)
## 高度（血条 / 标签定位用）
@export var height: float = 1.8
## 是否资源交汇点（农民往回送资源的地方）
@export var is_dropoff: bool = false
## 提供的人口上限
@export var food_provided: int = 0

@export_group("经济")
@export var gold_cost: int = 0
@export var wood_cost: int = 0
@export var food_cost: int = 0
## 训练 / 建造耗时（秒）
@export var train_time: float = 10.0
## 该建筑可训练的单位 id 列表
@export var trains: Array[StringName] = []
## 该建筑可研究的升级 id 列表
@export var researches: Array[StringName] = []
## 农民采集速率（资源/秒）。**默认必须是 0**：
## 曾经写成 3.0，结果所有战斗单位都被 is_worker() 误判成农民（步兵被派去采矿）。
@export var gather_rate: float = 0.0
## 单次携带上限
@export var carry_capacity: int = 10
## 采集类型（RtsConst.Harvest），可采集物用
@export var harvest_kind: int = RtsConst.Harvest.GOLD
## 可采集物总量
@export var resource_amount: int = 0

@export_group("技能")
## 技能 id 列表（目前支持 "fireball"）
@export var abilities: Array[StringName] = []
## 技能冷却（秒）
@export var ability_cooldown: float = 8.0


## 是不是建筑
func is_building() -> bool:
	return kind == RtsConst.Kind.BUILDING


## 是不是可采集物
func is_harvestable() -> bool:
	return kind == RtsConst.Kind.HARVESTABLE


## 能不能打人
func can_attack() -> bool:
	return attack_damage > 0.0 and attack_range > 0.0


## 是不是农民（能采集 / 建造）
func is_worker() -> bool:
	return gather_rate > 0.0 and not is_building()


## 复制一份（给"按难度加成"这类需要改数值的场合用）
func duplicate_def() -> UnitDef:
	return duplicate(true) as UnitDef
