@tool
class_name GameConfig
extends Resource
## **全局唯一配置资源**：镜头、经济、战斗、难度、地图、界面、开局。
## 所有可调数值都集中在这里（以及生成它的 代码/配置/单位表.gd），
## 玩法脚本一律通过自动加载单例 `Cfg.game` 读取，禁止硬编码。
##
## 读取方式：
##     Cfg.game.camera_distance_default
##     Cfg.unit(&"footman").max_hp
##     Cfg.difficulty(0).wave_interval

# ---------------------------------------------------------------------------
# 镜头（魔兽争霸3 手感）
# ---------------------------------------------------------------------------
@export_group("镜头")
## 俯角（度）。魔兽3 大约是 50 度
@export var camera_pitch_deg: float = 50.0
## 相机到注视点的距离（米）
@export var camera_distance_default: float = 30.0
## 缩放范围
@export var camera_distance_min: float = 13.0
@export var camera_distance_max: float = 44.0
## 滚轮每格缩放量
@export var camera_zoom_step: float = 2.2
## 缩放阻尼（越大越快到位）
@export var camera_zoom_damping: float = 17.0
## 屏幕边缘触发滚动的像素宽度
@export var camera_edge_margin: float = 22.0
## 最大平移速度（米/秒）
@export var camera_pan_speed: float = 24.0
## 平移加速度（米/秒²）—— 这是"丝滑跟手"的关键
@export var camera_pan_accel: float = 165.0
## 平移阻尼（松手后滑行减速）
@export var camera_pan_damping: float = 20.0
## 键盘平移速度倍率
@export var camera_key_pan_scale: float = 1.0
## 旋转步长（度，按 Q/E 一次转多少）
@export var camera_rotate_step: float = 45.0
## 旋转插值速度
@export var camera_rotate_speed: float = 13.0
## 注视点跟随阻尼（小地图跳转用）
@export var camera_focus_damping: float = 15.0
## 允许镜头到达的地图边界外扩（米）
@export var camera_bounds_margin: float = 4.0
## 镜头抖动衰减速度
@export var camera_shake_decay: float = 7.0

# ---------------------------------------------------------------------------
# 经济
# ---------------------------------------------------------------------------
@export_group("经济")
@export var start_gold: int = 620
@export var start_wood: int = 380
## 开局人口上限（大本营提供的另算）
@export var start_food_cap: int = 0
## 单个农民一次采集携带量（覆盖单位自己的 carry_capacity 为空时用）
@export var harvest_carry: int = 10
## 采集一次所需时间（秒）
@export var harvest_time_gold: float = 3.2
@export var harvest_time_wood: float = 4.0
## 资源产出暴击（不设 0）
@export var gold_mine_amount: int = 3200
@export var tree_amount: int = 260
## 单位重叠时的分离推力
@export var separation_strength: float = 1.8

# ---------------------------------------------------------------------------
# 战斗
# ---------------------------------------------------------------------------
@export_group("战斗")
## 每点护甲减伤比例
@export var armor_reduction: float = 0.06
## 减伤上限
@export var armor_reduction_cap: float = 0.72
## 暴击率 / 暴击倍率
@export var crit_chance: float = 0.12
@export var crit_multiplier: float = 1.65
## 伤害克制表：扁平 4x4，行=伤害类型(普通/穿刺/魔法/攻城)，列=护甲类型(轻/重/城/无)
@export var damage_table: Array[float] = [
	1.00, 0.85, 0.60, 1.00,   # 普通
	1.35, 0.85, 0.45, 1.20,   # 穿刺
	1.10, 1.15, 0.55, 1.00,   # 魔法
	0.60, 0.85, 1.60, 0.70,   # 攻城
]
## 死亡后尸体停留时间（秒）
@export var corpse_linger: float = 2.2
## 受击/命中时的镜头抖动强度基准
@export var shake_on_hit: float = 0.045
@export var shake_on_death: float = 0.09
@export var shake_on_building_destroyed: float = 0.55
## 攻击前摇比例（0~1，决定动画与伤害的配合节奏）
@export var attack_windup: float = 0.35

# ---------------------------------------------------------------------------
# 难度
# ---------------------------------------------------------------------------
@export_group("难度")
## 三档难度（在 单位表.gd 里填充具体数值）
@export var difficulties: Array[DifficultyDef] = []
## 默认难度下标
@export var default_difficulty: int = 0

# ---------------------------------------------------------------------------
# 地图
# ---------------------------------------------------------------------------
@export_group("地图")
## 可行走区域边长（米），地图是以原点为中心的正方形
@export var map_size: float = 116.0
## 随机种子（保证每次地形一致，方便测试）
@export var map_seed: int = 20261017
## 地形起伏幅度（米）
@export var terrain_amplitude: float = 1.6
## 地形细分数（每边的格子数）
@export var terrain_resolution: int = 58
## 玩家基地坐标
@export var player_base_pos: Vector2 = Vector2(-36.0, 34.0)
## 敌人基地坐标
@export var enemy_base_pos: Vector2 = Vector2(36.0, -34.0)
## 每个基地附近的金矿相对偏移
@export var gold_mine_offset: Vector2 = Vector2(-7.0, -9.0)
## 树林簇数量
@export var tree_clusters: int = 9
## 每簇树的半径范围
@export var tree_cluster_radius_min: float = 4.0
@export var tree_cluster_radius_max: float = 9.0
## 单簇树数量范围
@export var tree_cluster_count_min: int = 7
@export var tree_cluster_count_max: int = 16
## 岩石数量
@export var rock_count: int = 26
## 是否生成中央水潭
@export var has_pond: bool = true

# ---------------------------------------------------------------------------
# 开局
# ---------------------------------------------------------------------------
@export_group("开局")
## 玩家开局建筑（id → 相对基地的偏移 Vector2）
@export var player_buildings: Dictionary = {
	&"townhall": Vector2(0.0, 0.0),
	&"barracks": Vector2(9.0, 4.0),
	&"blacksmith": Vector2(-1.5, 10.0),
}
## 玩家开局单位（id → 数量）
@export var player_units: Dictionary = {
	&"peasant": 5,
	&"footman": 4,
	&"archer": 2,
	&"mage": 1,
}
## 敌人开局建筑
@export var enemy_buildings: Dictionary = {
	&"townhall": Vector2(0.0, 0.0),
	&"barracks": Vector2(-9.0, -4.0),
	&"blacksmith": Vector2(1.5, -10.0),
}
## 敌人开局单位
@export var enemy_units: Dictionary = {
	&"peasant": 5,
	&"footman": 2,
}
## 出兵时单位围绕建筑散开的半径
@export var rally_spread: float = 3.2

# ---------------------------------------------------------------------------
# 界面
# ---------------------------------------------------------------------------
@export_group("界面")
## 队伍色（玩家 / 敌人）
@export var player_color: Color = Color(0.30, 0.62, 1.00)
@export var enemy_color: Color = Color(1.00, 0.32, 0.26)
## 中立资源色
@export var gold_color: Color = Color(1.00, 0.82, 0.24)
## 小地图尺寸（正方形）
@export var minimap_size: float = 236.0
## 小地图边距
@export var minimap_margin: float = 14.0
## HUD 主色
@export var hud_accent: Color = Color(0.85, 0.71, 0.36)
@export var hud_bg: Color = Color(0.06, 0.07, 0.09, 0.86)
## 提示消息停留时间
@export var toast_duration: float = 3.0

# ---------------------------------------------------------------------------
# 单位表（运行时由 单位表.gd 填充，不在 .tres 里序列化）
# ---------------------------------------------------------------------------
## id → UnitDef
var units: Dictionary = {}


## 取一个单位定义（找不到返回 null 并警告）
func unit_def(id: StringName) -> UnitDef:
	var d: UnitDef = units.get(id, null)
	if d == null:
		push_warning("[Cfg] 未定义的单位 id: %s" % id)
	return d


## 全部已定义 id
func unit_ids() -> Array:
	return units.keys()


## 按种子生成一档默认难度数组（若 .tres 里没配）
func ensure_default_difficulties() -> void:
	if not difficulties.is_empty():
		return
	difficulties = UnitTable.build_difficulties()


## 伤害克制倍率
func damage_multiplier(attack_type: int, armor_type: int) -> float:
	var idx: int = clampi(attack_type, 0, 3) * 4 + clampi(armor_type, 0, 3)
	if idx < 0 or idx >= damage_table.size():
		return 1.0
	return damage_table[idx]
