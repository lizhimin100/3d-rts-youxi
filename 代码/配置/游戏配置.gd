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
## 兼容字段：非农民单位 / 未知资源种类时的兜底携带量。
## ★ 2026-11-08 起农民**不再走这个数**，见下面 harvest_carry_gold / harvest_carry_wood。
@export var harvest_carry: int = 10
## **农民一次采金携带量**（1 趟 = 搬这么多金）。
## 2026-11-08 玩家拍板：10 → **15**（金是唯一瓶颈，木长期溢出，见
## 文档/AI经济与等级排查报告.md §2.4）。
@export var harvest_carry_gold: int = 15
## **农民一次采木携带量**（1 趟 = 搬这么多木）。保持 10 不变。
@export var harvest_carry_wood: int = 10
## 采集一次所需时间（秒）
@export var harvest_time_gold: float = 3.2
@export var harvest_time_wood: float = 4.0
## 资源产出暴击（不设 0）
@export var gold_mine_amount: int = 3200
@export var tree_amount: int = 260
## 单位重叠时的分离推力
@export var separation_strength: float = 1.8

## --- AI / 副官的"保留资金"（任何一笔开销之后，余额不得低于它）---
## 敌方 AI：留一点"能补农民/能插箭塔"的机动钱就够（它是对手，不是管家）。
@export var ai_reserve_gold: int = 150
@export var ai_reserve_wood: int = 40
## **副官**：它花的是**玩家的金币**，必须给人类留出一份"我自己造点什么"的预算。
## 兵营 180 金 + 60 木、农场 80 金 + 20 木、箭塔 110 金 + 60 木 ——
## 480 金 / 140 木 = 开局哪怕副官已经动过手，玩家仍能自己起一座兵营 + 一座农场。
## 旧值 150 的实测后果：开局 5 秒金币就从 620 掉到 155，玩家连兵营都点不出来
## （用户原话"余钱留的有点少了，我想建个建筑都不能做到"）。
@export var adjutant_reserve_gold: int = 480
@export var adjutant_reserve_wood: int = 140

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
## 前摇占冷却的比例（0.35 → 0.20，2026-11-01）。
## 玩家原话："单位、建筑的受击效果有些延迟了。"
## 伤害是在前摇结束那一帧结算的：1.3s 冷却的步兵，0.35 意味着挥刀后 0.46 秒
## 对方才闪 —— 画面上"刀已经砍过去了，人还没反应"。
## 0.20 把这段压到 0.26 秒，正好落在"挥到位"的那一拍上。
@export var attack_windup: float = 0.20

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
## 可行走区域边长（米），地图是以原点为中心的正方形。
## 2026-10-31：主场景换成 4 队竞技场图 → 224m（4 个角各一个出生点，边长太小时
## 转身就撞到对面的基地）。
@export var map_size: float = 224.0
## 随机种子（保证每次地形一致，方便测试）
@export var map_seed: int = 20261017
## 地形起伏幅度（米）
@export var terrain_amplitude: float = 2.8
## 地形细分数（每边的格子数）
@export var terrain_resolution: int = 128
## 玩家基地坐标
@export var player_base_pos: Vector2 = Vector2(-62.0, 58.0)
## 敌人基地坐标
@export var enemy_base_pos: Vector2 = Vector2(62.0, -58.0)
## 每个基地附近的金矿相对偏移（敌人侧取反，保证点对称）
@export var gold_mine_offset: Vector2 = Vector2(-13.0, -17.0)
## 树林簇数量（**成对**生成：每簇同时镜像一份，保证双方资源对等）
@export var tree_clusters: int = 7
## 每簇树的半径范围
@export var tree_cluster_radius_min: float = 5.0
@export var tree_cluster_radius_max: float = 10.0
## 单簇树数量范围
@export var tree_cluster_count_min: int = 8
@export var tree_cluster_count_max: int = 14
## 岩石数量
@export var rock_count: int = 40
## 是否生成中央水潭（本轮水潭放在峡谷底部）
@export var has_pond: bool = true

## --- 地形大特征（台地 / 峡谷 / 外圈山脊 / 压平） ---
## 中央台地顶面高度（米）
@export var map_mesa_height: float = 7.4
## 中央台地半径（米）
@export var map_mesa_radius: float = 24.0
## 峡谷深度（米，负高差）
@export var map_gorge_depth: float = 6.5
## 峡谷宽度（米）
@export var map_gorge_width: float = 12.0
## 地图外圈山脊高度（米）
@export var map_edge_height: float = 16.0
## 基地压平半径（米，这个范围内完全平）
@export var map_base_flat: float = 18.0
## 地表草丛数量（MultiMesh 合批）
@export var map_decor_grass: int = 0
## 地表碎石数量（MultiMesh 合批，含路边碎石带）
@export var map_decor_rubble: int = 0

## --- 地表叙事（土路 / 边角装饰；纯视觉，不写寻路格） ---
## 主路宽度（米，双方基地 → 关口 → 台地 → 对方基地）
@export var map_road_width: float = 4.6
## 采矿支路宽度（米，基地 → 门口金矿）
@export var map_road_branch_width: float = 2.9
## 峡谷绕行小径宽度（米）
@export var map_road_trail_width: float = 2.2
## 沿路撒碎石带的间距（米）
@export var map_roadside_step: float = 3.2
## 蘑菇/小花簇数量（林缘 + 沟底）
@export var map_decor_mushroom: int = 0
## 枯木数量（树林边缘）
@export var map_decor_deadtree: int = 0
## 每方营地道具数量（木箱/木桶/栅栏/篝火/柴堆）
@export var map_decor_camp: int = 14
## 断墙遗迹组数（每组 6 段，成对镜像）
@export var map_decor_ruin_groups: int = 1
## 每道岩脊上的碎石墙数量（关口两侧，纯视觉）
@export var map_decor_gate_rocks: int = 22

# ---------------------------------------------------------------------------
# 开局
# ---------------------------------------------------------------------------
@export_group("开局")
## 玩家开局建筑（id → 相对基地的偏移 Vector2）
## 偏移按**营地本地坐标**解释：x = 右手边，y = 朝地图中心的方向（见 关卡._spawn_faction_start）
@export var player_buildings: Dictionary = {
	&"townhall": Vector2(0.0, 0.0),
	# 三座新建筑体量比旧版大（大本营 9.4m 宽 / 13m 高），旧偏移 (9,4)/(-1.5,10)
	# 会让兵营贴脸、铁匠铺挡在镜头与大门之间。左右各拉开 12m，三座都进画面。
	&"barracks": Vector2(13.0, 3.0),
	&"blacksmith": Vector2(-13.0, 3.0),
	# 4 队图每个基地给一座农场（人口）+ 一座哨塔（开局视野与自卫），
	# 免得开局就被人一波推平、也让"哨塔"新建筑一进游戏就能看见。
	&"farm": Vector2(-1.0, 13.5),
	&"watchtower": Vector2(15.5, 14.5),
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
	&"barracks": Vector2(-13.0, 3.0),
	&"blacksmith": Vector2(13.0, 3.0),
	&"farm": Vector2(1.0, 13.5),
	&"watchtower": Vector2(-15.5, 14.5),
}
## 敌人开局单位
@export var enemy_units: Dictionary = {
	&"peasant": 5,
	&"footman": 2,
}
## 出兵时单位围绕建筑散开的半径
@export var rally_spread: float = 4.2

# ---------------------------------------------------------------------------
# 对局（多队）
# ---------------------------------------------------------------------------
@export_group("对局")
## 出生点数量（= 阵营数量）。4 = 四角各一个。
@export var match_slots: int = 4
## 人类玩家所在的槽位
@export var match_human_slot: int = 0
## **每个槽位属于哪个队**。同号 = 盟友（同队同色、不许互相攻击）。
## 默认 [1,1,2,3]：你和槽位 1 是队友，槽位 2、3 各成一军 —— 三队混战。
## 想打 2v2 就改成 [1,1,2,2]；想四家乱战就 [1,2,3,4]。
@export var match_team_of_slot: Array[int] = [1, 1, 2, 3]
## 队色表（第 1 队 = 下标 0 …）。队色落到模型自带的染色区上
## （建筑的 team / team_trim，单位的 M_<zone>_team），不是整模型刷一遍色。
@export var match_team_colors: Array[Color] = [
	Color(0.30, 0.62, 1.00),   # 1 蓝
	Color(1.00, 0.32, 0.26),   # 2 红
	Color(0.38, 0.84, 0.36),   # 3 绿
	Color(0.74, 0.45, 0.96),   # 4 紫
	Color(0.98, 0.78, 0.24),   # 5 金
	Color(0.24, 0.82, 0.80),   # 6 青
]
## **盟友色（青）**：和你同队、但不是你本人的阵营（副官 AI）一律用这个颜色。
##
## 为什么队色不能再"同队同色"：队色是队伍属性，同队同色在纸面上很干净，
## 但进了游戏就是"一圈蓝点里分不出哪个是我的兵、哪个是盟友的兵" ——
## 玩家原话"同一队的显示很模糊、地图上一片红，看不出哪个是盟友"。
## 所以显示层拆成三档：**你 = 队色（蓝）/ 盟友 = 青 / 敌人 = 各自队色（红、绿…）**。
## 队（team）仍然是逻辑上的唯一判据（is_ally_of / is_enemy_of），这里只改"长什么样"。
@export var ally_color: Color = Color(0.18, 0.90, 0.90)


## 某槽位属于哪个队（越界按 1 队算）
func team_of_slot(slot: int) -> int:
	if match_team_of_slot.is_empty():
		return 1
	return maxi(1, match_team_of_slot[clampi(slot, 0, match_team_of_slot.size() - 1)])


## 某个队的队色（表里没有就按取模轮转）
func team_color(team: int) -> Color:
	if match_team_colors.is_empty():
		return Color(0.30, 0.62, 1.00)
	return match_team_colors[posmod(team - 1, match_team_colors.size())]


## **某个槽位的显示色**（不是队色）：你 = 队色 / 盟友 = 青 / 敌人 = 各自队色。
## 全项目只从这里取"这个阵营长得什么颜色"（模型染色区 / 小地图点 / 选中圈 / 血条）。
func display_color_for_slot(slot: int) -> Color:
	var team: int = team_of_slot(slot)
	if slot == match_human_slot:
		return team_color(team)
	if team == team_of_slot(match_human_slot):
		return ally_color
	return team_color(team)


## 槽位显示名（"玩家" / "AI·2队"）
func slot_name(slot: int, team: int) -> String:
	if slot == match_human_slot:
		return "玩家"
	return "AI·%d队" % team


# ---------------------------------------------------------------------------
# 界面
# ---------------------------------------------------------------------------
@export_group("界面")
## 队伍色（玩家 / 敌人）—— 旧接口保留；新代码用 match_team_colors / team_color()
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
## id → ResearchDef（铁匠铺升级，运行时由 单位表.gd 填充）
var researches: Dictionary = {}


## 取一个单位定义（找不到返回 null 并警告）
func unit_def(id: StringName) -> UnitDef:
	var d: UnitDef = units.get(id, null)
	if d == null:
		push_warning("[Cfg] 未定义的单位 id: %s" % id)
	return d


## 全部已定义 id
func unit_ids() -> Array:
	return units.keys()


## 取一项研究定义（找不到返回 null 并警告）
func research_def(id: StringName) -> ResearchDef:
	var r: ResearchDef = researches.get(id, null)
	if r == null:
		push_warning("[Cfg] 未定义的研究 id: %s" % id)
	return r


## 按种子生成一档默认难度数组（若 .tres 里没配）
func ensure_default_difficulties() -> void:
	if not difficulties.is_empty():
		return
	difficulties = UnitTable.build_difficulties()


## **农民一次采集的携带量**（按资源种类）。
## 2026-11-08 玩家拍板：采金 10 → **15**，采木维持 10。
## 只给"采集类单位"（农民）用；其它单位仍读自己的 carry_capacity。
func harvest_carry_of(kind: int) -> int:
	if kind == RtsConst.Harvest.WOOD:
		return maxi(harvest_carry_wood, 1)
	if kind == RtsConst.Harvest.GOLD:
		return maxi(harvest_carry_gold, 1)
	return maxi(harvest_carry, 1)


## 伤害克制倍率
func damage_multiplier(attack_type: int, armor_type: int) -> float:
	var idx: int = clampi(attack_type, 0, 3) * 4 + clampi(armor_type, 0, 3)
	if idx < 0 or idx >= damage_table.size():
		return 1.0
	return damage_table[idx]