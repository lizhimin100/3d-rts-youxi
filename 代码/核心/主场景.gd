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
## 日夜循环（4.98 挂上；HUD 的时间胶囊读它）
##
## ★★ 类型写成 `Node` 而不是 `RtsDayNight` —— **这是刻意的，别改回去**。
##   `var x: RtsDayNight` 这种写法要用到**全局类缓存**（.godot/global_script_class_cache.cfg）。
##   新加一个带 `class_name` 的脚本后，如果没先跑 `godot --headless --path . --import`，
##   或者缓存正好被重建/被旧编辑器读到，这里就会报：
##     Parse Error: Could not find type "RtsDayNight" in the current scope.
##   一旦本脚本编译失败，整个主场景就白屏 —— 这个错已经复发过两次。
##   现在改成"Node + preload 常量取脚本"，编译期只依赖文件路径，缓存坏不坏都能跑。
##   同理见下面的 creeps（RtsCreeps）。
const DAY_NIGHT_SCRIPT := preload("res://代码/系统/日夜.gd")
const CREEPS_SCRIPT := preload("res://代码/系统/野怪.gd")
## 实际类型 = DAY_NIGHT_SCRIPT（日夜.gd）。只在这里挂一次，别处一律用 `.call("…")`。
var day_night: Node = null
## 中立野怪（豺狼人 / 夜袭）。实际类型 = CREEPS_SCRIPT（野怪.gd）。
var creeps: Node = null
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
## QA：选中之后立刻对这个单位放一个技能（截图验收举盾/连发用）。
## 用法：`--select-id=footman --qa-skill=shield_up --shot=...`
var _qa_skill: StringName = &""
## QA：摆一排 0/1/2/3 星的步兵看星级图标（--qa-stars）
var _qa_stars: bool = false
## --qa-stars=N：只选中前 N 个
var _qa_star_pick: int = 0
## --qa-upgrade：造一座哨塔并立刻开始升级（看"施工中"半成品）
var _qa_upgrade: bool = false
## 地图编辑器：--map=<路径> 直接加载 MapDef（地图编辑器 Test Map 用）
var _map_path: String = ""
## 开局提前读到的地图（阵营数量要用它，见 _ready 第 1 步）
var _pending_map: MapDef = null
## --dump-mapdef=<路径>：把当前程序化地图导出成 MapDef（验证"统一口径"用）
var _dump_mapdef: String = ""
## --no-map：无视 bound_map / 默认地图文件，强制程序化竞技场图（QA 对照组）
var _force_no_map: bool = false
## --qa-reveal：关迷雾（验收用）
var _qa_reveal: bool = false
## --qa-night：立刻入夜并放一波野怪（验收用）
var _qa_night: bool = false
## --qa-hour=<0~24>：把时钟拨到指定小时、**不**放夜袭（拍黄昏/破晓用）
var _qa_hour: float = -1.0
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
	# ★ 先读地图：槽位数/队伍都来自 MapDef.players（编辑器支持 2~12 个槽位）。
	#   老流程是"先建 4 家再看地图"，12 人图里 4 号以后的槽位对象会挂不上阵营。
	Game.reset()
	Game.difficulty_index = Cfg.game.default_difficulty
	var early_map: MapDef = _load_map_arg()
	_pending_map = early_map
	var early_slots: int = 0
	var early_teams: Array = []
	var early_colors: Array = []
	if early_map != null:
		early_slots = early_map.players.size()
		# 老地图的队伍是 0 起（[0,1] / [0,1,0,1]），新地图是 1 起（[1,2,1,2]）。
		# 判据：只要出现一个 0 就是老口径 → 全部 +1；否则原样用。
		# 不做这一步的话，老 2 人图的 [0,1] 会被 max(1,·) 压成 [1,1] = 全员盟友。
		var legacy_zero: bool = false
		for p in early_map.players:
			if p != null and int(p.team) == 0:
				legacy_zero = true
				break
		for p in early_map.players:
			if p != null:
				early_teams.append(int(p.team) + (1 if legacy_zero else 0))
				early_colors.append(p.color)
	Game.setup_factions(early_slots, early_teams, early_colors)

	# 2) 环境兜底（.tscn 里已经挂了 Environment 资源；万一丢了就现场造一个）
	if 环境节点 != null and 环境节点.environment == null:
		环境节点.environment = _make_fallback_env()

	# 3) 关卡：地图数据 → 地形 → 寻路 → 道具 → 开局部队
	#    有 --map= 就走 MapDef（编辑器 Test Map）；否则保持原来的程序化流程，一行不变。
	#
	# ★ 野怪中立阵营**必须在地图对象落地之前**建好：地图里 owner = -1 的野怪
	#   要挂到它身上（见 地图加载器.spawn_map_objects）。所以这一步提前到 3) 之前。
	#   仍然用 `.call()` 而不是 `as RtsCreeps`：别碰全局类缓存（见 文档/开发交接.md §1）。
	creeps = _mount_script("res://代码/系统/野怪.gd", "野怪")
	if creeps != null:
		creeps.call("ensure_faction")
	if level != null:
		Game.level = level
		var map_def: MapDef = _pending_map if _pending_map != null else _load_map_arg()
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
		# QA：`-- --qa-map-check` 在**有 autoload（Cfg/Game）的环境**里跑一遍地图校验。
		# 为什么不在 --script 里跑：MapLoader 静态引用了 Cfg/Game，--script 模式下
		# 这两个全局名没注册，整条校验链编译失败（实测报 "Identifier not found: Cfg"）。
		if "--qa-map-check" in OS.get_cmdline_user_args():
			var qa_r: Dictionary = MapValidator.validate(map_def)
			print("[MAPCHECK] 地图=", map_def.resource_path)
			print("[MAPCHECK] 错误=", qa_r.get("errors", []))
			print("[MAPCHECK] 提醒=", qa_r.get("warnings", []))
			print("[MAPCHECK] 统计=", qa_r.get("stats", {}))
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

	# 4.98 **日夜**（只改两盏灯 + 背景能量）。
	#      ★ 野怪已经在 3) 之前建好中立阵营了；这里只做收尾（收编兜底 + 打印数量）。
	#      夜袭/自动刷怪已按玩家要求**整块删除** —— 野怪只由编辑器摆放。
	# ★ 这里**不要**写 `as RtsDayNight` / `as RtsCreeps`：同上，别碰全局类缓存。
	#   变量已经按 Node 接收，实际对象就是那两个脚本的实例，`.call` 一切正常。
	day_night = _mount_script("res://代码/系统/日夜.gd", "日夜")
	if day_night != null:
		day_night.call("setup", 主光节点, 补光节点, 环境节点)
		# 注册到全局（AI / 副官 / 营火读 Game.is_night()）：这是"夜里"的唯一出口
		Game.day_night = day_night
	if creeps != null:
		creeps.call("setup", level, day_night)
	# QA：--qa-night 把时钟直接拨到入夜（只影响亮度/营火，不再放怪）
	if _qa_night and day_night != null:
		day_night.call("debug_set_hour", 20.2)
		print("[QA] 时钟 → 20.2 时（夜里，野怪由编辑器摆放决定数量）")
	# QA：--qa-hour=18.5 只拨表、不放怪（黄昏/破晓的亮度就靠它拍）
	if _qa_hour >= 0.0 and day_night != null:
		day_night.call("debug_set_hour", _qa_hour)
		print("[QA] 时钟 → %.1f 时（白昼程度 %.2f）" % [
			_qa_hour, float(day_night.call("light_level"))])
	# 4.99 **地图据点**（2026-11-08）：地图中心，开局 3 分钟刷资源箱，占 15 秒归占据方，
	#      之后每 2 分钟一次。挂在关卡下（跟着地图走），AI/HUD 通过 Game.strongpoint 读。
	var sp: Node = _mount_script("res://代码/系统/据点.gd", "据点")
	if sp != null and level != null:
		var mid: Vector3 = RtsWorld.walkable_pos(Vector3.ZERO)
		sp.call("setup", mid)
		Game.strongpoint = sp
		# QA：--qa-crate 立刻把资源箱刷出来（不用等 3 分钟），镜头对准据点
		if "--qa-crate" in OS.get_cmdline_user_args():
			sp.call("_spawn_crate")
			if camera != null and camera.has_method("focus_on"):
				camera.call("focus_on", mid)
			print("[QA] 据点资源箱已刷出 @%.0f,%.0f" % [mid.x, mid.z])
	# QA：--qa-spawn=<id>[,<id>…] 在玩家基地旁直接生成（验收新单位/建筑能不能跑起来）
	_qa_spawn_stuff()
	# QA：--qa-arrow 沿 +X 射一箭，10 帧后把箭身朝向打出来（验收"箭是不是歪的"）
	if "--qa-arrow" in OS.get_cmdline_user_args():
		_qa_arrow.call_deferred()

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
	# 阵营与显示色（诊断用：同队盟友必须是青色，敌人各自队色）
	var fc: PackedStringArray = []
	for f in Game.factions:
		if f != null:
			fc.append("%s(槽%d/队%d/%s)" % [f.display_name, f.slot, f.team, f.color.to_html(false)])
	print("[主场景] 阵营：%s" % " ".join(fc))
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
	# 长跑采样（每 N 秒一行 PERF2）：看"内存会不会一路涨"，`--perf` 只看冷启动那一下
	for a in args:
		if a == "--perf-long" or a.begins_with("--perf-long="):
			_mount_script("res://代码/测试/性能探针.gd", "性能探针")
			break
	if "--gather-test" in args:
		_mount_script("res://代码/测试/采集自检.gd", "采集自检")
	# 木材专项：树按次数扣（20 次/棵）+ 砍完必须自己换树（-- --wood-test）
	if "--wood-test" in args:
		_mount_script("res://代码/测试/木材自检.gd", "木材自检")
	if "--feel-test" in args:
		_mount_script("res://代码/测试/手感自检.gd", "手感自检")
	if "--autotest" in args:
		_mount_script("res://代码/测试/自动试玩.gd", "自动试玩")
	if "--research-test" in args:
		_mount_script("res://代码/测试/升级自检.gd", "升级自检")
	# 野怪营地自检（营地依赖中立阵营 / 地图对象 / 寻路，必须在主场景里跑）
	if "--camp-test" in args:
		_mount_script("res://代码/测试/野怪营地自检.gd", "野怪营地自检")
	if "--adjutant-test" in args:
		_mount_script("res://代码/测试/副官自检.gd", "副官自检")
	# AI 基准（固定条件真实对局 + 情况文本 dump）：只读量测，不改 AI 行为
	for a in args:
		if a == "--ai-bench" or a.begins_with("--ai-bench"):
			_mount_script("res://代码/测试/AI基准.gd", "AI基准")
			break
	# 农民测试（2C-4 §4.4）：纯经济单变量——关 AI 脑、直接派工、采金/木/建造桶空转
	if "--peasant-test" in args:
		_mount_script("res://代码/测试/农民测试.gd", "农民测试")
	if "--walk-test" in args:
		_mount_script("res://代码/测试/走姿验收.gd", "走姿验收")
	# 动作截图：待机/走/攻击/举盾 各拍一张近景（人眼验收动画到底有没有播）
	for a in args:
		if a == "--anim-shots" or a.begins_with("--anim-shots="):
			_mount_script("res://代码/测试/动作截图.gd", "动作截图")
			break
	if "--map-editor-test" in args:
		_mount_script("res://代码/测试/地图编辑器自检.gd", "地图编辑器自检")
	if not _qa_select_id.is_empty():
		_qa_select.call_deferred(_qa_select_id)
	if _qa_stars:
		_qa_spawn_stars.call_deferred()
	if _qa_upgrade:
		_qa_upgrade_tower.call_deferred()
	# 压测：--stress-units=8000 在基地附近塞 N 个待命兵（性能排查用，默认不开）
	for a in args:
		if a.begins_with("--stress-units="):
			call_deferred("_qa_stress_units", int(a.get_slice("=", 1)))
			break
	if "--qa-guard" in args:
		_qa_guard.call_deferred()
	# 干活农民/建造进度条截图用：开一块工地，两个农民钻进去，选中工地
	if "--qa-build-ui" in args:
		_qa_build_ui.call_deferred()
	if "--qa-terrain" in args:
		_qa_terrain.call_deferred()
	if "--qa-map" in args:
		_qa_map_fingerprint.call_deferred()
	# 开发日志拍摄导演（--demo-shot=<dawn|dusk|raid|after|bench|list>）：
	# 拨时钟 + 接管镜头 + 按剧本演夜袭，**只服务录视频**，正常开局不会挂。
	for a in args:
		if a.begins_with("--demo-shot="):
			_mount_script("res://代码/测试/演示导演.gd", "演示导演")
			break


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


## QA：--qa-arrow —— 朝 +X 射一箭，等 10 帧打印箭身的朝向基。
## 正确的箭：-Z 轴（forward）≈ (-1,0,0)（箭头朝 +X 飞），歪的箭是 (0,0,-1)。
func _qa_arrow() -> void:
	var from := Vector3(0.0, 1.0, 0.0)
	var to := Vector3(30.0, 1.0, 0.0)
	RtsProjectile.fire(null, RtsConst.Projectile.ARROW, from, to, null, 26.0, {}, null)
	var p: Node3D = null
	for _i in 10:
		await get_tree().process_frame
		if p == null:
			for c in RtsWorld.level().get_children():
				if c is RtsProjectile:
					p = c as Node3D
	var fwd := Vector3.ZERO
	if p != null:
		fwd = -p.global_transform.basis.z
	print("[QA箭] 位置=", p.global_position if p != null else "null", " 前向=", fwd)


## QA：--qa-spawn=<id>[,<id>…]
##
## 在玩家基地外圈直接生成指定单位/建筑（建筑自动完工 + 标占地）。
## 用途：每加一个新兵种/新建筑，截图验收"它在游戏里长什么样、能不能站住"，
## 而不用真的等农民去盖 —— 也顺便验证"新 id 在 Cfg 里有没有登记"。
func _qa_spawn_stuff() -> void:
	var want: String = ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--qa-spawn="):
			want = arg.substr(11)
			break
	if want.is_empty() or level == null:
		return
	var base: Vector3 = RtsWorld.base_center(Game.player_faction)
	var ids: PackedStringArray = want.split(",", false)
	for i in ids.size():
		var id := StringName(ids[i].strip_edges())
		var d: UnitDef = Cfg.unit(id)
		if d == null:
			print("[QA] --qa-spawn：Cfg 里没有这个 id → %s" % String(id))
			continue
		var ang: float = TAU * float(i) / float(maxi(ids.size(), 1)) + 0.4
		var p := base + Vector3(cos(ang) * 11.0, 0.0, sin(ang) * 11.0)
		if d.is_building():
			p = 建筑网格.snap_point(p, d.footprint)
		p = RtsWorld.snap_y(RtsWorld.walkable_pos(p))
		var n: Node3D = Game.spawn_unit(Game.player_faction, id, p, level)
		if n == null:
			continue
		if d.is_building():
			n.rotation.y = 建筑网格.snap_yaw(建筑网格.default_yaw())
			level.mark_footprint(n)
			if n.has_method("set_constructed"):
				n.call("set_constructed", true)
		print("[QA] --qa-spawn：%s @ (%.0f, %.0f)" % [id, p.x, p.z])


## QA 压测：在玩家基地外圈塞 N 个**待命**战斗单位。
##
## 用途（2026-11-07 性能排查）：复现「8000 单位时单位逻辑吃多少 CPU」，
## 配合 `--perf-long` 拿到可复现的 PERF2 数字（改前/改后同一行参数对比）。
## 为什么要塞待命兵：待命兵是**最省**的状态，如果连待命都卡，说明是每帧固定开销
## （计时点 / 分离 / 贴地 / 动画）而不是某段业务逻辑。
func _qa_stress_units(n: int) -> void:
	if n <= 0 or level == null:
		return
	var base: Vector3 = RtsWorld.base_center(Game.player_faction)
	var t0: int = Time.get_ticks_msec()
	var spawned: int = 0
	for i in n:
		# 螺旋铺开：半径按 sqrt 增长，免得全叠在一个点上（分离力会把它们炸开）
		var ang: float = float(i) * 2.39996323
		var r: float = 6.0 + 0.55 * sqrt(float(i))
		var p := base + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		p = RtsWorld.snap_y(RtsWorld.walkable_pos(p))
		if Game.spawn_unit(Game.player_faction, &"footman", p, level) != null:
			spawned += 1
	print("[压测] 生成 %d 个单位（用时 %d ms）" % [spawned, Time.get_ticks_msec() - t0])


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


## QA：地图指纹 —— 证明"提取成地图文件再加载回来"和原程序化地图逐项一致。
## 用法：godot --headless --path . --quit-after 30 -- --qa-map
##      对照组：同一行再加 --no-map（强制程序化竞技场图）
func _qa_map_fingerprint() -> void:
	for _i in 2:
		await get_tree().process_frame
	if level == null or level.map_data == null:
		print("[QA-MAP] 没有关卡")
		return
	var md: MapGenerator.MapData = level.map_data
	var parts: PackedStringArray = []
	parts.append("size=%.1f res=%d tris=%d" % [md.size, md.resolution,
		level.terrain.triangle_count() if level.terrain != null else -1])
	parts.append("heights=%d" % hash(md.heights))
	var dirt: int = 0
	for b in md.mat_nodes:
		if b > 128:
			dirt += 1
	parts.append("mat=%d/%d/dirt%d" % [md.mat_cells, hash(md.mat_nodes), dirt])
	# 可走性：raw = 按 MapDef 现算的掩码（未过坡度），walk = 关卡最终生效的
	var wk: int = 0
	for b in md.walkable:
		if b != 0:
			wk += 1
	var walk_s: String = "walk=%d/%d" % [wk, hash(md.walkable)]
	if level.map_def != null:
		var raw: PackedByteArray = MapLoader.build_walkable_mask(level.map_def, false)
		var wk2: int = 0
		for b in raw:
			if b != 0:
				wk2 += 1
		walk_s += " raw=%d/%d edge=%.0f" % [wk2, hash(raw), level.map_def.edge_keep_out]
	parts.append(walk_s)
	parts.append("trees=%d/%d mines=%d/%d rocks=%d roads=%d grass=%d rubble=%d decor=%d far=%s" % [
		md.trees.size(), hash(md.trees), md.mines.size(), hash(md.mines),
		md.rocks.size(), md.roads.size(), md.grass.size(), md.rubble.size(),
		md.decor_count(), str(md.far_ridges)])
	print("[QA-MAP] %s" % " ".join(parts))
	var bl: PackedStringArray = []
	var ul: PackedStringArray = []
	for fac in Game.factions:
		if fac == null:
			continue
		for b in fac.buildings:
			if b == null or not is_instance_valid(b):
				continue
			var bd: UnitDef = b.get("def") as UnitDef
			var bp: Vector3 = (b as Node3D).global_position
			bl.append("%d:%s@%.1f,%.1f|%.3f" % [fac.slot,
				String(bd.id) if bd != null else "?", bp.x, bp.z, (b as Node3D).rotation.y])
		for u in fac.units:
			if u == null or not is_instance_valid(u):
				continue
			var ud: UnitDef = u.get("def") as UnitDef
			var up: Vector3 = (u as Node3D).global_position
			ul.append("%d:%s@%.1f,%.1f" % [fac.slot,
				String(ud.id) if ud != null else "?", up.x, up.z])
	bl.sort()
	ul.sort()
	print("[QA-MAP] buildings=%d hash=%d | units=%d hash=%d" % [
		bl.size(), hash("|".join(bl)), ul.size(), hash("|".join(ul))])


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


## QA：搭一块「正在施工的兵营 + 里面的农民」，选中工地并把镜头对过去。
##
## 用途（2026-11-07 玩家口径）：验收建筑面板的「建造进度条 + 农民头像 + 取消建造」，
## 以及农民钻进工地后模型隐藏。凭空看截图看不出这块，必须真的跑到施工中状态。
func _qa_build_ui() -> void:
	for i in 8:
		await get_tree().process_frame
	if Game.level == null or Game.player_faction == null:
		return
	var pf: RtsFaction = Game.player_faction
	var d: UnitDef = Cfg.unit(&"barracks")
	if d == null:
		return
	var base: Vector3 = RtsWorld.base_center(pf)
	var pos: Vector3 = base + Vector3(11.0, 0.0, 7.0)
	pos = RtsWorld.snap_y(建筑网格.snap_point(pos, d.footprint))
	var workers: Array = []
	for u in pf.units:
		if u == null or not is_instance_valid(u) or not u.is_alive() or u.def == null:
			continue
		if RtsWorld.is_worker_def(u.def):
			workers.append(u)
		if workers.size() >= 2:
			break
	if workers.is_empty():
		print("[QA] --qa-build-ui：没有农民")
		return
	var site: Node3D = workers[0].call("order_build", d, pos)
	if site == null:
		print("[QA] --qa-build-ui：工地没立起来（钱不够 / 地形不行）")
		return
	for i in range(1, workers.size()):
		workers[i].call("order_build_site", site)
	# 等农民走过去钻进来（每帧都跑，最多 3 秒）
	for i in 600:
		await get_tree().process_frame
		if i % 60 == 0:
			for w in workers:
				if w == null or not is_instance_valid(w):
					continue
				var wp: Vector3 = (w as Node3D).global_position
				var gv: Variant = w.get("_goal")
				var sv: Variant = w.get("_work_spot")
				var g3: Vector3 = gv if gv is Vector3 else Vector3.ZERO
				var s3: Vector3 = sv if sv is Vector3 else Vector3.ZERO
				var pv: Variant = w.get("_path")
				var pl: int = (pv as PackedVector3Array).size() if pv is PackedVector3Array else -1
				var pi: int = int(w.get("_path_i"))
				var p0: Vector3 = (pv as PackedVector3Array)[mini(pi, pl - 1)] if pv is PackedVector3Array and pl > 0 else Vector3.ZERO
				if i == 0 and pv is PackedVector3Array:
					print("[QA-P] %s 路径=%s" % [w.name, str(pv)])
				print("[QA-T] f=%d %s pos=(%.1f,%.1f) d=%.2f mv=%s path=%d pi=%d p0=(%.1f,%.1f) goal=(%.1f,%.1f) spd=%.2f" % [
					i, w.name, wp.x, wp.z,
					float(site.call("distance_to_footprint", wp)),
					str(w.get("_moving")), pl, pi, p0.x, p0.z, g3.x, g3.z, float(w.get("_speed"))])
		if site.has_method("builders_inside_count") and int(site.call("builders_inside_count")) > 0:
			break
	if selection_system != null and selection_system.has_method("select_units"):
		selection_system.call("select_units", [site])
	if camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", (site as Node3D).global_position)
	# --- 端到端验收「点农民头像 → 选中里面的农民」（玩家 2026-11-07 口径）---
	for i in 20:
		await get_tree().process_frame
	var hudn: Node = hud
	var panel = hudn.get("_building_panel") if hudn != null else null
	if panel != null and panel.has_method("_on_crew_icon"):
		panel.call("_on_crew_icon", 0)
		await get_tree().process_frame
		var sel: Array = selection_system.call("selected_units") if selection_system != null else []
		var ok_unit: bool = sel.size() == 1 and sel[0] != null and is_instance_valid(sel[0]) \
				and bool(sel[0].call("is_inside_build"))
		print("[QA] 点农民头像 → 选中 %d 个；是工地里的农民=%s" % [sel.size(), str(ok_unit)])
		# 截图要的是工地面板，重新选回工地
		if selection_system != null:
			selection_system.call("select_units", [site])
	for w in workers:
		if w != null and is_instance_valid(w) and w.has_method("_work_reach"):
			print("[QA] 农民 %s 距墙 %.2fm（阈值 %.2f）order=%d state=%d" % [
				w.name, float(site.call("distance_to_footprint", (w as Node3D).global_position)),
				float(w.call("_work_reach")), int(w.get("order")), int(w.get("state"))])
	print("[QA] 工地位置=(%.1f,%.1f) 朝向=%.0f°" % [
		(site as Node3D).global_position.x, (site as Node3D).global_position.z,
		rad_to_deg((site as Node3D).rotation.y)])
	print("[QA] --qa-build-ui：工地 %s 进度 %.2f 里面 %d 人" % [
		site.name, float(site.get("progress")),
		int(site.call("builders_inside_count")) if site.has_method("builders_inside_count") else -1])


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
	# 显式 --cam 时不要抢镜头（否则 --select-id + --cam 永远是 select 赢，固定机位失效）
	if camera != null and camera.has_method("focus_on") and _qa_cam_pos == Vector3.INF:
		camera.call("focus_on", picked[0].global_position + Vector3(0.0, 0.0, 5.0))
	print("[QA] 已选中 %d 个 %s" % [picked.size(), id])
	# 截图验收：选中后立刻放一个技能（举盾 / 火球 …），用来拍"技能生效中"的样子
	if _qa_skill != &"":
		var cast_n: int = 0
		for u in picked:
			if u != null and is_instance_valid(u) and u.has_method("order_cast"):
				# 先站住：走路状态会播 walk，技能动作看不出来
				if u.has_method("order_stop"):
					u.call("order_stop")
				u.call("order_cast", _qa_skill, (u as Node3D).global_position, null)
				cast_n += 1
		print("[QA] 释放技能 %s ×%d" % [_qa_skill, cast_n])
	# 截图定位用：把每个被选中对象的真实坐标打出来（省得靠猜镜头）
	for u in picked:
		if u != null and is_instance_valid(u):
			print("[QA]   %s @ %.1f,%.1f" % [String(u.name), u.global_position.x, u.global_position.z])


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


## QA：在基地前面摆四个步兵（0/1/2/3 星），并选中，用来拍"星级图标"。
func _qa_spawn_stars() -> void:
	var pl: RtsFaction = Game.player_faction
	if pl == null:
		return
	var base: Vector3 = RtsWorld.base_center(pl)
	var made: Array = []
	for i in 4:
		var pos: Vector3 = RtsWorld.walkable_pos(base + Vector3(-6.0 + float(i) * 3.4, 0.0, 9.0))
		var n: Node3D = Game.spawn_unit(pl, &"footman", pos, level)
		if n == null:
			continue
		n.set("star_level", i)
		n.set("exp_value", float(i) * 1000.0)
		made.append(n)
	if not made.is_empty():
		var sel: Node = get("selection_system")
		if sel != null and sel.has_method("select_units"):
			var pick: Array = made
			if _qa_star_pick > 0:
				pick = made.slice(0, mini(_qa_star_pick, made.size()))
			sel.call("select_units", pick)
		# 镜头对准这一排（否则基地大本营会挡住它们）
		var mid: Vector3 = (made[0] as Node3D).global_position
		if made.size() > 1:
			mid = ((made[0] as Node3D).global_position + (made[-1] as Node3D).global_position) * 0.5
		var cam: Node = camera
		if cam != null and cam.has_method("focus_on"):
			cam.call("focus_on", mid)
		if cam != null:
			cam.set("distance_want", 16.0)
	print("[QA] 星级演示：%d 个（0~3 星）" % made.size())


## QA：造一座哨塔 → 立刻开始升级 → 镜头对准（拍"施工中"半成品）
func _qa_upgrade_tower() -> void:
	var pl: RtsFaction = Game.player_faction
	if pl == null:
		return
	pl.gold = 2000
	pl.wood = 2000
	var pos: Vector3 = RtsWorld.walkable_pos(RtsWorld.base_center(pl) + Vector3(7.0, 0.0, 11.0))
	var n: Node3D = Game.spawn_unit(pl, &"watchtower", pos, level)
	if n == null:
		return
	if n.has_method("set_constructed"):
		n.call("set_constructed", true)
	var REFIT: Script = load("res://代码/系统/建筑改造.gd")
	REFIT.call("start", n)
	if camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", pos)
	print("[QA] 哨塔升级中（施工中模型已切）")


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
		elif arg == "--qa-upgrade":
			_qa_upgrade = true
		elif arg == "--qa-stars":
			_qa_stars = true
		elif arg.begins_with("--qa-stars="):
			# --qa-stars=N：只选中前 N 个（拍"单选双圈"用，N=1）
			_qa_stars = true
			_qa_star_pick = int(arg.get_slice("=", 1))
		elif arg.begins_with("--qa-skill="):
			_qa_skill = StringName(arg.substr(11))
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
		elif arg.begins_with("--speed="):
			# ★ 时间的唯一入口：在**任何节点 _process 之前**（主场景 _ready 里）定死。
			#   以前由 AI基准 在它自己的 _ready 里设，等于"开局第 1 帧之后才生效"，
			#   首帧时序一差就会让 Game.elapsed 的推进起点差一帧 —— 确定性事故的候选之一。
			Engine.time_scale = maxf(float(arg.substr(8)), 0.1)
		elif arg.begins_with("--dump-mapdef="):
			_dump_mapdef = arg.substr(14)
		elif arg == "--demo-tree":
			_demo_tree = true
		elif arg == "--qa-night":
			# 验收：立刻入夜 + 放一波野怪
			_qa_night = true
		elif arg.begins_with("--qa-hour="):
			# 验收：把时钟拨到指定小时（**不**放夜袭）。黄昏/破晓的过渡就靠它拍，
			# 例：--qa-hour=18.5（黄昏中段） / --qa-hour=23（深夜）
			_qa_hour = float(arg.substr(10))
		elif arg == "--qa-reveal":
			# 验收：关掉战争迷雾（否则"野怪在哪"永远拍不到）
			_qa_reveal = true
		elif arg == "--no-map":
			# 强制走程序化竞技场（验收"地图文件 = 原图"的对照组）
			_force_no_map = true


## 解析本局要用的地图（优先级从高到低）：
##   1. --demo-tree：现场拼一张"四季并排"演示图，不需要任何地图文件。
##   2. --map=<路径>：编辑器 Test Map 指定的地图。
##   3. bound_map（Inspector 绑定的 MapDef）—— 用户想"通过编辑器改图、实时落到主场景"的入口。
##   4. 兜底：默认地图文件 res://地图/主场景地图.tres（生成工具产出）。
##   5. 都没有 → 返回 null，走原来的程序化随机地图。
func _load_map_arg() -> MapDef:
	if _force_no_map:
		print("[主场景] --no-map：强制程序化竞技场图")
		return null
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
		# 绑定的是"地图文件"，不是"这一份内存对象"：强制重读文件，
		# 否则编辑器存盘后热重载拿到的还是 ResourceLoader 缓存里的旧 MapDef。
		var rp: String = String(bound_map.resource_path)
		if not rp.is_empty() and ResourceLoader.exists(rp):
			var fresh: MapDef = ResourceLoader.load(rp, "",
				ResourceLoader.CACHE_MODE_IGNORE) as MapDef
			if fresh != null:
				return fresh
		return bound_map
	# 兜底：默认地图文件（工具/导出主场景地图.gd 产出）
	var fallback := "res://地图/主场景地图.tres"
	if ResourceLoader.exists(fallback):
		var def: MapDef = ResourceLoader.load(fallback, "",
			ResourceLoader.CACHE_MODE_IGNORE) as MapDef
		if def == null:
			def = MapStore.load_any(fallback)
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
	# 索敌/开火的可见性过滤读这里（见 游戏状态.is_visible_to）
	Game.fog_node = fog
	# QA：--qa-reveal 关迷雾（验收截图/野怪体检时看全图用，正常游玩不要开）
	if _qa_reveal and fog.has_method("set_enabled"):
		fog.call("set_enabled", false)


## 把 MapDef 里的初始资源写进**每一个**阵营（多队图：4 个槽位各吃自己那份）。
## 旧版只处理 players[0] 和 enemy_slot()：4 队图里盟友和第三家会退回 cfg 的默认值，
## 编辑器里改它们的钱等于白改。
##
## 难度的 bonus_gold 在运行时叠加、不烘进地图文件 —— 同一张图换个难度还能再打。
func _apply_map_resources(def: MapDef) -> void:
	if def == null:
		return
	var diff: DifficultyDef = Cfg.difficulty(Game.difficulty_index)
	for p in def.players:
		if p == null:
			continue
		if p.id < 0 or p.id >= Game.factions.size():
			continue
		var f: RtsFaction = Game.factions[p.id]
		if f == null:
			continue
		var bonus: int = 0 if f.is_player else diff.bonus_gold
		f.gold = p.gold() + bonus
		f.wood = p.wood()
		Game.resources_changed.emit(f)


## 把**当前这一局真实摆在世界里的地图**导出成 MapDef。
##
## 分工：
##   · MapDef.from_map_data 负责地形高度场 / 地块格点表 / 资源（树、金矿）/
##     地表叙事（土路、草、碎石、营地道具）/ 玩家槽位；
##   · 这里再补上"运行期才存在"的东西：每个阵营的开局建筑与单位（多队图 4 家全要）。
## 导出后主场景绑定的就是这份数据：编辑器改它 → 存档 → 运行中的游戏热重载 =
## 用户要的"通过编辑器改主场景地图，改动实时落实"。
func _dump_map_def(path: String) -> void:
	if level == null or level.map_data == null:
		return
	var def: MapDef = MapDef.from_map_data(level.map_data, Cfg.game)
	# 1) 玩家槽位：以运行中的阵营为准（队号 / 显示色 / 出生点都是权威值）
	def.players.clear()
	for f in Game.factions:
		if f == null:
			continue
		var c: Vector3 = level.base_center(f)
		var slot := PlayerSlot.make(f.slot, "player" if f.is_player else "enemy", f.color,
			f.team, Vector2(c.x, c.z), Cfg.game.start_gold, Cfg.game.start_wood)
		slot.start_yaw = PI
		def.players.append(slot)
	# 2) 对象：保留 from_map_data 里的资源（树/金矿），追加建筑与单位
	var objs: Array = []
	for o in def.objects:
		if o != null:
			objs.append(o)
	var nb: int = 0
	var nu: int = 0
	for f in Game.factions:
		if f == null:
			continue
		for b in f.buildings:
			if b == null or not is_instance_valid(b):
				continue
			var bd: UnitDef = b.get("def") as UnitDef
			if bd == null:
				continue
			if b.has_method("is_alive") and not bool(b.call("is_alive")):
				continue
			var bp: Vector3 = (b as Node3D).global_position
			objs.append(MapObject.make(bd.id, MapObject.Category.BUILDING,
				Vector3(bp.x, level.height_at(bp.x, bp.z), bp.z),
				(b as Node3D).rotation.y, 1.0, f.slot))
			nb += 1
		for u in f.units:
			if u == null or not is_instance_valid(u):
				continue
			var ud: UnitDef = u.get("def") as UnitDef
			if ud == null:
				continue
			if u.has_method("is_alive") and not bool(u.call("is_alive")):
				continue
			var up: Vector3 = (u as Node3D).global_position
			objs.append(MapObject.make(ud.id, MapObject.Category.UNIT,
				Vector3(up.x, level.height_at(up.x, up.z), up.z),
				(u as Node3D).rotation.y, 1.0, f.slot))
			nu += 1
	def.objects.clear()
	for o in objs:
		def.objects.append(o)
	var err: int = MapStore.save_any(def, path)
	var nr: int = 0
	for o in def.objects:
		if o != null and int(o.category) == MapObject.Category.RESOURCE:
			nr += 1
	print("[主场景] 导出 MapDef → %s err=%d（槽位 %d / 建筑 %d / 单位 %d / 资源 %d / 地块 %d² / 地面细节 %s）" % [
		path, err, def.players.size(), nb, nu, nr, def.mat_cells,
		"有" if not def.ground.is_empty() else "无"])


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
