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

# --- QA / 自动化试玩参数 ---
var _shot_path: String = ""
var _shot_delay: float = 0.0
var _shot_done: bool = false
var _quit_after_shot: bool = false
var _shot_clock: float = 0.0
var _qa_select_id: String = ""


func _ready() -> void:
	_parse_cmdline()

	# 1) 全局状态与阵营
	Game.reset()
	Game.difficulty_index = Cfg.game.default_difficulty
	Game.setup_factions()

	# 2) 环境兜底（.tscn 里已经挂了 Environment 资源；万一丢了就现场造一个）
	if 环境节点 != null and 环境节点.environment == null:
		环境节点.environment = _make_fallback_env()

	# 3) 关卡：地图数据 → 地形 → 寻路 → 道具 → 开局部队
	if level != null:
		level.build()
		level.spawn_props()
		level.spawn_starting_forces()
		Game.level = level
	else:
		push_error("[主场景] 场景里缺少「关卡」节点")

	# 4) 相机初始对准玩家基地（必须在入树之后）
	_place_camera()

	# 4.9 音效与 BGM（素材是程序化合成的 WAV，缺失时静默跳过）
	if ResourceLoader.exists("res://代码/音频/音效管理.gd"):
		var sfx_script := load("res://代码/音频/音效管理.gd") as Script
		if sfx_script != null:
			sfx_script.call("attach", get_tree())

	# 4.95 移动指示（绿色虚线 + 目的地标记）：一层只订阅 Game.order_issued 的观察者，
	#       和 选择系统 / 指令系统 挂在同一层；脚本缺失时静默跳过，不影响开局。
	_mount_script("res://代码/操作/移动指示.gd", "移动指示")

	# 5) 起跑
	Game.phase = RtsConst.Phase.RUNNING
	Game.game_over.connect(_on_game_over)
	Game.notify.emit("战斗开始！摧毁敌人大本营即可获胜。", Cfg.game.hud_accent)

	# 6) 测试挂载（只有命令行显式要求时才挂）
	_mount_tests()

	print("[主场景] 镜头=%s fov=%.0f 类=%s" % [
		camera.name if camera != null else "无",
		(camera.get_node_or_null("相机") as Camera3D).fov if camera != null and camera.get_node_or_null("相机") != null else -1.0,
		camera.get_script().resource_path if camera != null and camera.get_script() != null else "内置",
	])
	print("[主场景] 就绪：地形 %d 面，地图 %.0fm，玩家单位 %d，敌人单位 %d（节点总数 %d）" % [
		level.terrain.triangle_count() if level != null and level.terrain != null else 0,
		Cfg.game.map_size,
		Game.player_faction.count_units(),
		Game.enemy_faction.count_units(),
		_count_nodes(self),
	])


func _exit_tree() -> void:
	# 释放静态缓存里的 Resource，否则退出时报 "resources still in use at exit"
	ArtKit.clear_cache()


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
	_update_shot(delta)
	if Game.phase != RtsConst.Phase.RUNNING:
		return
	_check_timer += delta
	if _check_timer < 0.5:
		return
	_check_timer = 0.0
	if _over_emitted:
		return
	if Game.enemy_faction == null or Game.player_faction == null:
		return
	if not Game.enemy_faction.has_townhall():
		Game.trigger_victory()
	elif not Game.player_faction.has_townhall():
		Game.trigger_defeat()


## 游戏结束：停掉 AI，交给界面出遮罩
func _on_game_over(victory: bool) -> void:
	_over_emitted = true
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
	if not _qa_select_id.is_empty():
		_qa_select.call_deferred(_qa_select_id)


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


## QA：选中指定 id 的全部己方单位（截图验收命令卡用）
func _qa_select(id: String) -> void:
	for i in 3:
		await get_tree().process_frame
	var picked: Array = []
	for u in Game.player_faction.units:
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
