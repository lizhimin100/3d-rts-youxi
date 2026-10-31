extends Node3D
## **主场景 / 总装**：整个游戏的入口。
##
## ★ 结构说明（给要改这个工程的人）：
##   场景**节点树是实打实搭在 `场景/主场景.tscn` 里的**，不是代码里现攒的：
##
##     主场景 (Node3D)
##     ├── 环境      WorldEnvironment   ← 战斗环境.tres（天空/雾/泛光/SSAO/调色）
##     ├── 主光      DirectionalLight3D ← 暖色主光，开阴影
##     ├── 补光      DirectionalLight3D ← 冷色补光，无阴影
##     ├── 关卡      RtsLevel           ← 地形网格 / 寻路网格 / 树·金矿·岩石 / 开局双方部队
##     ├── 镜头      RtsCamera          ← 魔兽式 RTS 镜头（运行时建一个 Camera3D 子节点）
##     ├── 选择系统  SelectionSystem    ← 点选 / 拖框 / 选中圈
##     ├── 指令系统  CommandSystem      ← 右键上下文指令 / 快捷键
##     ├── 界面      RtsHud (CanvasLayer)← 资源条 / 小地图 / 选中面板 / 命令卡 / 结束遮罩
##     └── AI        SimpleAI           ← 敌方电脑
##
##   本脚本只做三件事：**接线**（把节点互相认识）、**驱动**（胜负判定）、**测试挂载**。
##   玩法逻辑都在各节点自己的脚本里，这块保持薄。
##
## 自动截图（验收用）：
##   godot --path . -- --shot=<绝对路径.png> --shot-delay=3 --quit-after-shot

# --- 节点引用（全部来自 .tscn，不在这里 new）---
@onready var 环境节点: WorldEnvironment = get_node_or_null("环境") as WorldEnvironment
@onready var 主光节点: DirectionalLight3D = get_node_or_null("主光") as DirectionalLight3D
@onready var 补光节点: DirectionalLight3D = get_node_or_null("补光") as DirectionalLight3D
@onready var level: RtsLevel = get_node_or_null("关卡") as RtsLevel
@onready var camera: Node3D = get_node_or_null("镜头") as Node3D
@onready var selection_system: Node = get_node_or_null("选择系统")
@onready var command_system: Node = get_node_or_null("指令系统")
@onready var hud: Node = get_node_or_null("界面")
@onready var ai: Node = get_node_or_null("AI")

# --- 胜负判定计时 ---
var _check_timer: float = 0.0
var _over_emitted: bool = false
## 绑定地图热重载：监视地图文件 mtime，变化时 reload_current_scene()
var _bound_watch_path: String = ""
var _bound_watch_mtime: int = -1
var _reload_lock: float = 0.0

# --- QA / 自动化试玩参数 ---
var _shot_path: String = ""
var _shot_delay: float = 0.0
var _shot_done: bool = false
var _quit_after_shot: bool = false
var _shot_clock: float = 0.0
## QA 相机：--cam=x,y,z + --cam-dist=N（只用于验收截图，不影响正常开局）
var _qa_cam_pos: Vector3 = Vector3.INF
var _qa_cam_dist: float = -1.0
## QA：从命令行强制镜头朝向（度）。用于"同一场景多角度"截图验收。
var _qa_cam_yaw: float = NAN
var _qa_select_id: String = ""
## 地图编辑器：--map=<路径> 直接加载 MapDef（地图编辑器 Test Map 用）
var _map_path: String = ""
## --dump-mapdef=<路径>：把当前程序化地图导出成 MapDef（验证"统一口径"用）
var _dump_mapdef: String = ""
## --demo-tree：直接进"树品种演示"小地图（春夏秋冬并排），用来肉眼看树的生成效果
var _demo_tree: bool = false
## 同一件事的**编辑器入口**：在编辑器里勾上这个勾，按 F6/F5 就进演示图。
## 之所以要这个开关：命令行参数在编辑器里不好填，而"测试/四季演示.tscn"就是
## 一个实例化了本场景、把这个勾打上的壳场景 —— 双击就能跑。
@export var demo_tree_mode: bool = false
## 绑定地图：在 Inspector 里指定一张 MapDef（.tres），主场景就会加载它而不是随机程序化地图。
## 默认值由 场景/主场景.tscn 设置成 res://地图/主场景地图.tres（生成工具 工具/gen_bound_map.gd 产出）。
## 编辑器里改这张图并存盘，运行中的游戏会自动热重载（见 _tick_map_watch）。
@export var bound_map: MapDef = null


func _ready() -> void:
	_parse_cmdline()
	if demo_tree_mode:
		_demo_tree = true
	_qa_apply_yaw.call_deferred()

	# 1) 全局状态与阵营
	Game.reset()
	Game.difficulty_index = Cfg.game.default_difficulty
	Game.setup_factions()

	# 2) 环境兜底（.tscn 里已经挂了 Environment 资源；万一丢了就现场造一个）
	if 环境节点 != null and 环境节点.environment == null:
		环境节点.environment = _make_fallback_env()

	# 3) 关卡：地图数据 → 地形 → 寻路 → 道具 → 开局部队
	#    有 --map= 就走 MapDef（编辑器 Test Map）；否则保持原来的程序化流程，一行不变。
	if level != null:
		Game.level = level
		var map_def: MapDef = _load_map_arg()
		if map_def != null:
			if not MapLoader.apply_to_level(map_def, level):
				push_error("[主场景] MapDef 建关失败，回退到默认地图")
				level.build()
				level.spawn_props()
				level.spawn_starting_forces()
			else:
				print("[主场景] 已加载地图 %s（%d×%d，对象 %d 个）"
					% [map_def.resource_path, map_def.size, map_def.size, map_def.objects.size()])
				_apply_map_resources(map_def)
		else:
			level.build()
			level.spawn_props()
			level.spawn_starting_forces()
		_setup_map_watch(map_def)
		_setup_fog()
		if not _dump_mapdef.is_empty():
			_dump_map_def(_dump_mapdef)
	else:
		push_error("[主场景] 场景里缺少「关卡」节点")

	# 4) 相机初始对准玩家基地（必须在入树之后）
	_place_camera()
	_apply_qa_camera.call_deferred()

	# 4.9 音效与 BGM（素材是程序化合成的 WAV，缺失时静默跳过）
	if ResourceLoader.exists("res://代码/音频/音效管理.gd"):
		var sfx_script := load("res://代码/音频/音效管理.gd") as Script
		if sfx_script != null:
			sfx_script.call("attach", get_tree())

	# 4.97 每支 AI 阵营一个大脑（多队图：敌人可能有 2~3 个）
	_mount_ai_brains()

	# 4.96 副官（玩家侧脚本 AI）：替玩家补农民/派采集/盖农场兵营，玩家下令即接管。
	#      只碰农民，不碰任何战斗单位；`--no-adjutant` 可关。
	_mount_script("res://代码/ai/副官.gd", "副官")

	# 4.95 移动指示（绿色虚线 + 目的地标记）：一层只订阅 Game.order_issued 的观察者，
	#       和 选择系统 / 指令系统 挂在同一层；脚本缺失时静默跳过，不影响开局。
	_mount_script("res://代码/操作/移动指示.gd", "移动指示")

	# 5) 起跑
	Game.phase = RtsConst.Phase.RUNNING
	Game.game_over.connect(_on_game_over)
	Game.notify.emit(_opening_message(), Cfg.game.hud_accent)
	# 副官不再弹提示：状态改由小地图下方的「副官 · 开/关」按钮表达（常驻、可点）。

	# 6) 测试挂载（只有命令行显式要求时才挂）
	_mount_tests()

	print("[主场景] 镜头=%s fov=%.0f 类=%s" % [
		camera.name if camera != null else "无",
		(camera.get_node_or_null("相机") as Camera3D).fov if camera != null and camera.get_node_or_null("相机") != null else -1.0,
		camera.get_script().resource_path if camera != null and camera.get_script() != null else "内置",
	])
	var 我方单位: int = Game.player_faction.count_units() if Game.player_faction != null else 0
	var 敌方单位: int = 0
	if Game.player_faction != null:
		for f in Game.enemies_of(Game.player_faction):
			敌方单位 += f.count_units()
	print("[主场景] 就绪：地形 %d 面，地图 %.0fm，%d 个阵营 / %d 个队，我方单位 %d，敌方单位 %d（节点总数 %d）" % [
		level.terrain.triangle_count() if level != null and level.terrain != null else 0,
		Cfg.game.map_size,
		Game.factions.size(),
		_team_count(),
		我方单位,
		敌方单位,
		_count_nodes(self),
	])


func _exit_tree() -> void:
	# 释放静态缓存里的 Resource，否则退出时报 "resources still in use at exit"
	ArtKit.clear_cache()


## QA 相机落位：--cam=x,y,z --cam-dist=N 只用于验收截图。
## 必须 deferred：关卡/单位都在同一帧里建完，focus_on 才有地面高度可查询。
func _apply_qa_camera() -> void:
	if camera == null:
		return
	if _qa_cam_pos != Vector3.INF and camera.has_method("focus_on"):
		camera.call("focus_on", _qa_cam_pos)
		if _qa_cam_dist < 0.0:
			_qa_cam_dist = 18.0
	if _qa_cam_dist > 0.0 and camera.has_method("set_distance"):
		camera.call("set_distance", _qa_cam_dist)


## 相机落位（有 focus_on 就用它，没有就直接 look_at 兜底）
func _place_camera() -> void:
	if camera == null or level == null:
		return
	var base: Vector3 = level.base_center(Game.player_faction)
	if camera.has_method("focus_on"):
		camera.call("focus_on", base)
	else:
		camera.look_at(base, Vector3.UP)


# ===========================================================================
# 环境兜底
# ===========================================================================

## 代码兜底环境（.tres 丢了也能看）
func _make_fallback_env() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.15, 0.26, 0.42)
	sky_mat.sky_horizon_color = Color(0.66, 0.70, 0.74)
	sky_mat.ground_horizon_color = Color(0.52, 0.48, 0.42)
	sky_mat.ground_bottom_color = Color(0.18, 0.17, 0.16)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.46
	env.ssao_enabled = true
	env.glow_enabled = true
	env.glow_intensity = 0.34
	env.glow_hdr_threshold = 1.35
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.95
	env.fog_enabled = true
	env.fog_light_color = Color(0.42, 0.48, 0.58)
	env.fog_density = 0.0026
	return env


# ===========================================================================
# 胜负
# ===========================================================================

func _process(delta: float) -> void:
	_tick_map_watch(delta)
	_update_shot(delta)
	if Game.phase != RtsConst.Phase.RUNNING:
		return
	_check_timer += delta
	if _check_timer < 0.5:
		return
	_check_timer = 0.0
	if _over_emitted:
		return
	if Game.player_faction == null:
		return
	# 多队图：**所有敌对阵营的大本营都没了**才算赢（盟友的大本营不算数）
	if Game.all_enemies_defeated():
		Game.trigger_victory()
	elif not Game.player_faction.has_townhall():
		Game.trigger_defeat()


## 游戏结束：停掉 AI，交给界面出遮罩
func _on_game_over(victory: bool) -> void:
	_over_emitted = true
	for n in get_tree().get_nodes_in_group("ai_brain"):
		if n != null and is_instance_valid(n):
			n.set_process(false)
			n.set_physics_process(false)
	if ai != null and is_instance_valid(ai):
		ai.set_process(false)
		ai.set_physics_process(false)
	Game.notify.emit("胜利！" if victory else "战败……",
		Cfg.game.hud_accent if victory else Cfg.game.enemy_color)


# ===========================================================================
# 测试与 QA 挂载
# ===========================================================================

func _mount_tests() -> void:
	var args := OS.get_cmdline_user_args()
	if "--interact-test" in args:
		_mount_script("res://代码/测试/交互自检.gd", "交互自检")
	if "--edge-test" in args:
		_mount_script("res://代码/测试/边缘滚动自检.gd", "边缘滚动自检")
	if "--perf" in args:
		_perf_probe.call_deferred()
	if "--gather-test" in args:
		_mount_script("res://代码/测试/采集自检.gd", "采集自检")
	if "--feel-test" in args:
		_mount_script("res://代码/测试/手感自检.gd", "手感自检")
	if "--autotest" in args:
		_mount_script("res://代码/测试/自动试玩.gd", "自动试玩")
	if "--research-test" in args:
		_mount_script("res://代码/测试/升级自检.gd", "升级自检")
	if "--adjutant-test" in args:
		_mount_script("res://代码/测试/副官自检.gd", "副官自检")
	if "--walk-test" in args:
		_mount_script("res://代码/测试/走姿验收.gd", "走姿验收")
	if "--map-editor-test" in args:
		_mount_script("res://代码/测试/地图编辑器自检.gd", "地图编辑器自检")
	if not _qa_select_id.is_empty():
		_qa_select.call_deferred(_qa_select_id)
	if "--qa-guard" in args:
		_qa_guard.call_deferred()
	if "--qa-terrain" in args:
		_qa_terrain.call_deferred()


## 每支 AI 阵营一个大脑。
##
## 场景里现有的 `AI` 节点接管"玩家最近的敌人"，其余敌人 / 盟友全部现场新建 ——
## 这样 `主场景.tscn` 的节点树不用改，`命令`/`副官` 那条老链路也不受影响。
func _mount_ai_brains() -> void:
	if Game.player_faction == null:
		return
	var script: Script = load("res://代码/ai/简单AI.gd") as Script
	if script == null:
		return
	var ais: Array = []
	for f in Game.factions:
		if f == null or f.is_player:
			continue
		ais.append(f)
	if ais.is_empty():
		return
	# 0 号：场景里那个 AI
	if ai != null and is_instance_valid(ai):
		ai.set("command_faction", ais[0])
		ai.add_to_group("ai_brain")
	ais.remove_at(0)
	# 其余：现场 new（名字带队伍号，场景树里一眼能分清）
	for f in ais:
		var n: Node = script.call("new") as Node
		if n == null:
			continue
		n.name = "AI_%d队" % f.team
		n.set("command_faction", f)
		n.add_to_group("ai_brain")
		add_child(n)


## 本局一共几个队
func _team_count() -> int:
	var seen: Dictionary = {}
	for f in Game.factions:
		if f != null:
			seen[f.team] = true
	return seen.size()


## 开局提示：说清楚"你是几号队、队里有谁、有几个敌人"
func _opening_message() -> String:
	var me: RtsFaction = Game.player_faction
	if me == null:
		return "战斗开始！"
	var mates: Array = []
	var foes: Array = []
	for f in Game.factions:
		if f == null or f == me:
			continue
		if me.is_ally_of(f):
			mates.append(f.display_name)
		else:
			foes.append(f.display_name)
	var s: String = "战斗开始！你是 %d 号队。" % me.team
	if not mates.is_empty():
		s += " 队友：%s。" % "、".join(mates)
	s += " 敌人：%s（共 %d 队）。摧毁全部敌方大本营即可获胜。" % ["、".join(foes), _team_count()]
	return s


## 按路径挂一个测试节点（文件不存在就跳过，不报错）
func _mount_script(path: String, node_name: String) -> Node:
	if not ResourceLoader.exists(path):
		return null
	var s := load(path) as Script
	if s == null:
		return null
	var n: Node = s.call("new") as Node
	if n == null:
		return null
	n.name = node_name
	add_child(n)
	return n


## QA：地形体检 —— 出生点是否严格水平、建筑占地高差是否为 0、可走性如何。
## 这三条正是玩家报的"莫名凸起 / 单位建筑穿模"的判据，用数字回答，不靠截图猜。
func _qa_terrain() -> void:
	for i in 4:
		await get_tree().process_frame
	if level == null or level.terrain == null:
		print("[QA-地形] 没有关卡")
		return
	var st: Dictionary = level.terrain_stats()
	print("[QA-地形] 网格 %d 面 / 高差 %.2f m / 最大坡度 %.1f° / 可走 %d 格(%.1f%%)" % [
		int(st.get("triangle_count", 0)), float(st.get("height_range", 0.0)),
		float(st.get("max_slope_deg", 0.0)),
		int(st.get("walkable_cells", 0)), float(st.get("walkable_ratio", 0.0)) * 100.0])
	var worst: float = 0.0
	for f in Game.factions:
		if f == null:
			continue
		var c: Vector3 = level.base_center(f)
		# 每个出生点按最大建筑占地（9×5）与 8×8 各量一次
		var r1: float = level.footprint_height_range(c, Vector2i(9, 5))
		var r2: float = level.footprint_height_range(c, Vector2i(8, 8))
		var buildable: bool = level.is_buildable(c + Vector3(9.0, 0.0, 9.0), Vector2i(4, 4))
		worst = maxf(worst, maxf(r1, r2))
		print("[QA-地形] 槽位%d(%s) 基地(%.1f,%.1f) 高差 9×5=%.4f 8×8=%.4f 可建=%s" % [
			f.slot, f.display_name, c.x, c.z, r1, r2, str(buildable)])
	print("[QA-地形] 出生平台最大占地高差 = %.4f m（要求 < 0.05；>0.08 就会出现穿模）" % worst)


## QA：给前几个战斗单位分别下 驻守 / 观察 / 路径，并把它们全选中
## （用来验收"头顶状态图标"和"选中血条"两条需求）
func _qa_guard() -> void:
	for i in 6:
		await get_tree().process_frame
	var pool: Array = []
	if Game.player_faction != null:
		for u in Game.player_faction.units:
			if u != null and is_instance_valid(u) and u.is_alive() and u.def != null 					and u.def.kind == RtsConst.Kind.UNIT and not RtsWorld.is_worker_def(u.def):
				pool.append(u)
	if pool.size() < 3:
		return
	pool[0].call("order_hold")
	pool[1].call("order_observe")
	pool[2].call("order_patrol", pool[2].global_position + Vector3(6.0, 0.0, 6.0))
	var picked: Array = []
	for i in mini(pool.size(), 26):
		picked.append(pool[i])
	if selection_system != null and selection_system.has_method("select_units"):
		selection_system.call("select_units", picked)
	if camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", pool[0].global_position)
	print("[QA] 驻守/观察/路径 已下达，选中 %d 个" % picked.size())


## QA：选中指定 id 的全部己方单位（截图验收命令卡用）
func _qa_select(id: String) -> void:
	for i in 3:
		await get_tree().process_frame
	var picked: Array = []
	# 建筑登记在 faction.buildings（不在 units），只扫 units 会漏掉整类目标 ——
	# 于是 --select-id=barracks 只选中、镜头不跟，验收截图永远拍在基地中心。
	var pool: Array = []
	if Game.player_faction != null:
		pool.append_array(Game.player_faction.units)
		pool.append_array(Game.player_faction.buildings)
	for u in pool:
		if u != null and is_instance_valid(u) and u.is_alive() and u.def != null and String(u.def.id) == id:
			picked.append(u)
	if picked.is_empty():
		print("[QA] 没找到 id=%s 的单位" % id)
		return
	if selection_system != null and selection_system.has_method("select_units"):
		selection_system.call("select_units", picked)
	elif selection_system != null:
		selection_system.set("selected", picked)
		for u in picked:
			u.set("is_selected", true)
		Game.selection_changed.emit(picked)
	if camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", picked[0].global_position + Vector3(0.0, 0.0, 5.0))
	print("[QA] 已选中 %d 个 %s" % [picked.size(), id])


# ===========================================================================
# 自动截图
# ===========================================================================

## QA：把镜头转到指定朝向（度）。只是给截图用，不参与玩法。
func _qa_apply_yaw() -> void:
	if is_nan(_qa_cam_yaw):
		return
	for _i in 10:
		await get_tree().process_frame
	var cam := get_node_or_null("镜头")
	if cam == null:
		return
	cam.set("_yaw", deg_to_rad(_qa_cam_yaw))
	cam.set("_yaw_target", deg_to_rad(_qa_cam_yaw))
	print("[QA] 镜头朝向 %.0f°" % _qa_cam_yaw)


func _parse_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_path = arg.substr(7)
		elif arg.begins_with("--shot-delay="):
			_shot_delay = float(arg.substr(13))
		elif arg == "--quit-after-shot":
			_quit_after_shot = true
		elif arg.begins_with("--select-id="):
			_qa_select_id = arg.substr(12)
		elif arg.begins_with("--cam="):
			var parts := arg.substr(6).split(",")
			if parts.size() == 3:
				_qa_cam_pos = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
		elif arg.begins_with("--cam-dist="):
			_qa_cam_dist = float(arg.substr(11))
		elif arg.begins_with("--max-dist="):
			# QA：把镜头最远距离放开（看全图用；正常游玩仍按 Cfg 的 44m 上限）
			Cfg.game.camera_distance_max = float(arg.substr(11))
		elif arg.begins_with("--cam-yaw="):
			_qa_cam_yaw = float(arg.substr(10))
		elif arg.begins_with("--map="):
			_map_path = arg.substr(6)
		elif arg.begins_with("--dump-mapdef="):
			_dump_mapdef = arg.substr(14)
		elif arg == "--demo-tree":
			_demo_tree = true


## 解析本局要用的地图（优先级从高到低）：
##   1. --demo-tree：现场拼一张"四季并排"演示图，不需要任何地图文件。
##   2. --map=<路径>：编辑器 Test Map 指定的地图。
##   3. bound_map（Inspector 绑定的 MapDef）—— 用户想"通过编辑器改图、实时落到主场景"的入口。
##   4. 兜底：默认地图文件 res://地图/主场景地图.tres（生成工具产出）。
##   5. 都没有 → 返回 null，走原来的程序化随机地图。
func _load_map_arg() -> MapDef:
	if _demo_tree:
		var demo: Script = load("res://代码/测试/树品种演示.gd") as Script
		if demo != null:
			print("[主场景] 树品种演示模式（春夏秋冬并排）")
			return demo.call("make_map", 5.0, true, 128) as MapDef
		push_warning("[主场景] 读不到 代码/测试/树品种演示.gd，回退默认地图")
	if not _map_path.is_empty():
		var def: MapDef = MapStore.load_any(_map_path)
		if def == null:
			push_warning("[主场景] 读不到地图：%s（回退到默认地图）" % _map_path)
		return def
	if bound_map != null:
		return bound_map
	# 兜底：默认地图文件（生成工具 工具/gen_bound_map.gd 产出）
	var fallback := "res://地图/主场景地图.tres"
	if ResourceLoader.exists(fallback):
		var def: MapDef = MapStore.load_any(fallback)
		if def != null:
			print("[主场景] 未指定 --map / 未绑定，使用默认地图文件 %s" % fallback)
			return def
	return null


## 记录绑定地图文件，供 _tick_map_watch 监视。仅在"真正从文件加载"时生效（演示图/程序化图不监视）。
func _setup_map_watch(def: MapDef) -> void:
	_bound_watch_path = ""
	_bound_watch_mtime = -1
	if def == null or Engine.is_editor_hint():
		return
	var rp: String = def.resource_path
	if rp.is_empty() or not rp.begins_with("res://地图/"):
		return
	var phys: String = ProjectSettings.globalize_path(rp)
	if phys.is_empty() or not FileAccess.file_exists(phys):
		return
	_bound_watch_path = rp
	_bound_watch_mtime = FileAccess.get_modified_time(phys)
	print("[主场景] 地图热重载已就绪：监视 %s" % rp)


## 每秒轮询一次地图文件 mtime；编辑器存盘后，运行中的游戏自动 reload_current_scene() 把改动落实。
## 只在非编辑器、且确实绑定了地图文件时生效；reload 后 _ready 会重新 setup 监视，不会死循环。
func _tick_map_watch(delta: float) -> void:
	if Engine.is_editor_hint() or _bound_watch_path.is_empty():
		return
	_reload_lock -= delta
	if _reload_lock > 0.0:
		return
	_reload_lock = 1.0
	var phys: String = ProjectSettings.globalize_path(_bound_watch_path)
	if phys.is_empty():
		return
	var mt: int = FileAccess.get_modified_time(phys)
	if mt > 0 and mt != _bound_watch_mtime:
		print("[主场景] 检测到地图文件改动（%s），热重载场景" % _bound_watch_path)
		get_tree().reload_current_scene()


## 战争迷雾：地形 visibility 网格 + 雾区暗化 + 雾中敌方单位隐藏 + 小地图遮罩。
## 以玩家阵营（含其盟友）为观察方，按各单位 sight_range 点亮可见格。
func _setup_fog() -> void:
	if level == null or level.terrain == null or Game.player_faction == null:
		return
	if not ResourceLoader.exists("res://代码/战争迷雾.gd"):
		return
	var fog_script := load("res://代码/战争迷雾.gd") as Script
	if fog_script == null:
		return
	var fog: Node = fog_script.new()
	if fog == null:
		return
	level.add_child(fog)
	fog.setup(level.terrain, Game.player_faction, level.world_size)


## 把 MapDef 里的初始资源写进阵营（MapDef 图不跑 cfg 的开局流程）
func _apply_map_resources(def: MapDef) -> void:
	if def == null:
		return
	if def.players.size() >= 1 and def.players[0] != null and Game.player_faction != null:
		Game.player_faction.gold = def.players[0].gold()
		Game.player_faction.wood = def.players[0].wood()
	var enemy: PlayerSlot = def.enemy_slot()
	if enemy != null and Game.enemy_faction != null:
		Game.enemy_faction.gold = enemy.gold()
		Game.enemy_faction.wood = enemy.wood()


## 把当前地图导出成 MapDef（只在地图编辑器/命令行需要时执行）
func _dump_map_def(path: String) -> void:
	if level == null or level.map_data == null:
		return
	var def: MapDef = MapDef.from_map_data(level.map_data, Cfg.game)
	var err: int = MapStore.save_any(def, path)
	print("[主场景] 导出 MapDef → %s err=%d（%d 个对象）" % [path, err, def.objects.size()])


func _update_shot(delta: float) -> void:
	if _shot_path.is_empty() or _shot_done:
		return
	_shot_clock += delta
	if _shot_clock < _shot_delay:
		return
	_shot_done = true
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		print("[截图] 取不到视口图像")
		return
	var err: int = img.save_png(_shot_path)
	print("[截图] %s err=%d size=%s" % [_shot_path, err, str(img.get_size())])
	if _quit_after_shot:
		await get_tree().create_timer(0.15).timeout
		get_tree().quit()


## 性能探针：真实窗口下量 fps / draw call / 图元数，用来正面回答"代码生成节点吃不吃性能"
func _perf_probe() -> void:
	await get_tree().create_timer(2.5).timeout
	var fps: float = Performance.get_monitor(Performance.TIME_FPS)
	var dc: float = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var objs: float = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var prim: float = Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var nodes: float = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var mem: float = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	print("PERF " + JSON.stringify({
		"fps": "%.1f" % fps,
		"draw_calls": int(dc),
		"render_objects": int(objs),
		"primitives": int(prim),
		"nodes": int(nodes),
		"static_mem_mb": "%.1f" % mem,
		"units": Game.player_faction.count_units() + Game.enemy_faction.count_units(),
		"harvestables": Game.all_harvestables().size(),
	}))
	get_tree().quit()


## 统计节点数（验证"节点树是真的"）
func _count_nodes(n: Node) -> int:
	var c: int = 1
	for ch in n.get_children():
		c += _count_nodes(ch)
	return c
