extends SceneTree
## **地形自检**（RIDGE 2026-10-18）
##
## 覆盖任务书 §3.2：
##   1. 高度极差（合成 8m 台地 + 3m 沟壑；真实 200m 图 37m 级）
##   2. 台地面积 / 顶面平整
##   3. 坡道存在（合成图两侧各一条 30°；真实图 MapData.ramps ≥ 2）且可走
##   4. 基地 → 中央台地 → 金矿/树林连通（A* + BFS 双口径）
##   5. 坡道贴地 / 路径采样坡度（height_at 与三角面一致）
##   6. 相机不穿地形（台地顶 / 台地边缘 / 沟壑三个焦点）
##   7. is_buildable 的 footprint 高差 >0.8m 拒绝（台地顶/低地仍可建）
##
## 运行（不要加 --import）：
##   godot --headless --path . --script 代码/测试/地形自检.gd
##
## ★ 为什么全篇用 load()/call() 而不是 Game/Cfg/RtsUnit：
##   --script 指定的脚本在 autoload 注册之前编译；直接写单例名会报
##   "Identifier not found: Game"。而且 HOUND 改 单位.gd 时整条依赖链可能暂时编译不过，
##   本自检用 build_from_data + 镜头 override 夹具，**不依赖 Game 也能跑地形/镜头**；
##   Game 健康时才额外做"单位在坡道上贴地"的动态用例。

const SYNTH_SIZE: float = 128.0
const SYNTH_RES: int = 64
const SYNTH_MESA_R: float = 16.0
const SYNTH_MESA_H: float = 8.0
const SYNTH_RAMP_DEG: float = 30.0
const SYNTH_CLIFF_START: float = 16.0
const SYNTH_CLIFF_END: float = 20.0

var _pass: int = 0
var _fail: int = 0
var _warn: int = 0
var _lines: Array[String] = []
var _summary: Dictionary = {}

var _level_script: Script = null
var _map_script: Script = null
var _terrain_script: Script = null
var _cam_script: Script = null
var _cfg_script: Script = null
var _const_script: Script = null

var _cfg = null
var _synth_cfg = null
var _game: Node = null
var _game_ok: bool = false

var _synth_level: Node3D = null
var _synth_data = null
var _real_level: Node3D = null
var _real_data = null


## 自检需要一个带 selection_system 属性的父节点，避免镜头 _cache_siblings 在 Window 上乱 get
class CameraParent:
	extends Node3D
	var selection_system: Node = null


func _initialize() -> void:
	# 和 战斗自检 一样：_initialize 时 root 还没真正进树，推迟一帧再搭世界
	call_deferred("_run")


func _run() -> void:
	print("========== 地形自检 ==========")
	_load_scripts()
	var can_run: bool = _level_script != null and _level_script.can_instantiate() \
		and _map_script != null and _map_script.can_instantiate() \
		and _terrain_script != null and _terrain_script.can_instantiate() \
		and _cam_script != null and _cam_script.can_instantiate()
	if not can_run:
		_ok("关键脚本可加载/编译", false, "关卡/地图/地形/镜头脚本当前编译失败（有人在改？）")
		_finish()
		return
	_cfg = _cfg_script.new()
	_synth_cfg = _cfg_script.new()
	_synth_cfg.map_size = SYNTH_SIZE
	_synth_cfg.player_base_pos = Vector2(-36.0, 34.0)
	_synth_cfg.enemy_base_pos = Vector2(36.0, -34.0)
	_synth_cfg.has_pond = false

	_game = root.get_node_or_null("Game")
	_game_ok = _game != null and _game.has_method("reset") and _game.has_method("spawn_unit") 		and _game.has_method("setup_factions")
	if not _game_ok:
		_warn += 1
		_lines.append("  · SKIP 单位贴地动态用例：Game/单位脚本当前不可用（HOUND 可能正在改）")

	_test_synthetic()
	await _test_camera_synthetic()
	_cleanup_synthetic()
	_test_real()

	_finish()


func _load_scripts() -> void:
	_level_script = load("res://代码/核心/关卡.gd")
	_map_script = load("res://代码/核心/地图生成.gd")
	_terrain_script = load("res://代码/核心/地形.gd")
	_cam_script = load("res://代码/镜头/魔兽镜头.gd")
	_cfg_script = load("res://代码/配置/游戏配置.gd")
	_const_script = load("res://代码/核心/常量.gd")


# ===========================================================================
# 合成夹具：8m 台地 + 30° 坡道 + 60° 崖壁 + 3m 沟壑
# ===========================================================================

func _build_synthetic() -> void:
	_synth_data = _map_script.call("build", _synth_cfg)
	if _synth_data == null:
		_ok("合成 MapData 生成", false)
		return
	_synth_data.size = SYNTH_SIZE
	_synth_data.resolution = SYNTH_RES
	_synth_data.heights = _make_synth_heights()
	_synth_data.walkable = PackedByteArray()
	_synth_data.walkable.resize(int(SYNTH_SIZE) * int(SYNTH_SIZE))
	_synth_data.walkable.fill(1)
	_synth_data.trees.clear()
	_synth_data.rocks.clear()
	_synth_data.clusters.clear()
	_synth_data.ramps.clear()
	_synth_data.gorges.clear()
	_synth_data.chokes.clear()
	_synth_data.flat_zones.clear()
	_synth_data.spawn_safe.clear()
	_synth_data.mines.clear()
	_synth_data.mines.append(Vector2(0.0, 0.0))
	_synth_data.mines.append(Vector2(-26.0, 0.0))
	_synth_data.mines.append(Vector2(26.0, 0.0))
	# 基地附近各放两棵树（树心不参与可走性，这里只测"树旁可走格可达"）
	_synth_data.trees.append(Vector2(-36.0, 40.0))
	_synth_data.trees.append(Vector2(-40.0, 28.0))
	_synth_data.trees.append(Vector2(36.0, -40.0))
	_synth_data.trees.append(Vector2(40.0, -28.0))
	_synth_data.pond_radius = 0.0
	_synth_data.plateau = {"center": Vector2.ZERO, "radius": SYNTH_MESA_R, "top": SYNTH_MESA_H}
	_synth_data.plateau_area = PI * SYNTH_MESA_R * SYNTH_MESA_R

	_synth_level = _level_script.new()
	_synth_level.name = "合成地形"
	root.add_child(_synth_level)
	_synth_level.call("build_from_data", _synth_data, _synth_cfg)


func _make_synth_heights() -> PackedFloat32Array:
	var res: int = SYNTH_RES
	var row: int = res + 1
	var cell: float = SYNTH_SIZE / float(res)
	var half: float = SYNTH_SIZE * 0.5
	var ramp_len: float = (SYNTH_MESA_H - 0.0) / tan(deg_to_rad(SYNTH_RAMP_DEG))
	var out := PackedFloat32Array()
	out.resize(row * row)
	for gz in range(row):
		for gx in range(row):
			var wx: float = -half + float(gx) * cell
			var wz: float = -half + float(gz) * cell
			var h: float = 0.0
			var d: float = Vector2(wx, wz).length()
			# 台地：顶面平，16→20m 是 63.4° 崖壁
			if d <= SYNTH_CLIFF_START:
				h = SYNTH_MESA_H
			elif d < SYNTH_CLIFF_END:
				h = SYNTH_MESA_H * (SYNTH_CLIFF_END - d) / (SYNTH_CLIFF_END - SYNTH_CLIFF_START)
			# 两条坡道（±x），30°，宽 8m，边缘 1.5m 过渡
			if absf(wz) <= 5.0:
				var r: float = absf(wx)
				if r >= 14.0 and r <= SYNTH_CLIFF_START + ramp_len:
					var rh: float = SYNTH_MESA_H * clampf((SYNTH_CLIFF_START + ramp_len - r) / ramp_len, 0.0, 1.0)
					var lat: float = 1.0 - smoothstep(3.5, 5.0, absf(wz))
					h = lerpf(h, rh, lat)
			# 北侧 20m 压力墙：只给镜头用例制造"相机在墙后/墙内"的真实遮挡
			var wall_dz: float = absf(wz - 24.0)
			if absf(wx) < 18.0 and wall_dz < 2.5:
				var wall_h: float = 20.0 \
					* (1.0 - smoothstep(1.5, 2.5, wall_dz)) \
					* (1.0 - smoothstep(15.0, 18.0, absf(wx)))
				h = maxf(h, wall_h)
			# 南侧干沟：深 3m，谷底平，岸 36.9°
			var dz: float = absf(wz - 30.0)
			if absf(wx) < 16.0 and dz < 7.0:
				h -= 3.0 * (1.0 - smoothstep(3.0, 7.0, dz)) * (1.0 - smoothstep(12.0, 16.0, absf(wx)))
			out[gz * row + gx] = h
	return out


func _test_synthetic() -> void:
	_build_synthetic()
	if _synth_level == null:
		return
	var terrain = _synth_level.get("terrain")
	if terrain == null:
		_ok("合成地形已建立", false)
		return

	var h_range: float = float(terrain.call("height_range"))
	var max_slope: float = float(terrain.call("max_slope_degrees"))
	var subdiv: int = int(terrain.call("subdivided_cell_count"))
	var tris: int = int(terrain.call("triangle_count"))
	# 细分已改为曲率驱动：每格面数 = 2·nu·nv（+边界缝合），不再是固定 2/4。
	# 这里只守两条硬不变量：①不低于每格 2 面；②不超过每格 6×6 的细分上限。
	var cells: int = SYNTH_RES * SYNTH_RES
	var tri_lo: int = cells * 2
	var tri_hi: int = cells * 80
	_ok("合成图：高度极差 ≥ 10m", h_range >= 10.0, "极差 %.2fm（8m 台地 + 3m 沟）" % h_range)
	_ok("合成图：最大坡度 ≥ 60°（真崖壁）", max_slope >= 60.0, "最大坡度 %.2f°" % max_slope)
	_ok("合成图：三角面数落在曲面细分预算内", tris >= tri_lo and tris <= tri_hi,
		"实测 %d / 区间 [%d, %d]（细分 %d 格）" % [tris, tri_lo, tri_hi, subdiv])

	# height_at 与网格顶点 / 四分裂中心一致（崖边不悬空/陷地的前提）
	var res: int = int(terrain.get("resolution"))
	var row: int = res + 1
	var cell: float = float(terrain.get("size")) / float(res)
	var half: float = float(terrain.get("size")) * 0.5
	var heights: PackedFloat32Array = terrain.get("heights")
	var vertex_err: float = 0.0
	for gz in range(row):
		for gx in range(row):
			var wx: float = -half + float(gx) * cell
			var wz: float = -half + float(gz) * cell
			var hv: float = heights[gz * row + gx]
			vertex_err = maxf(vertex_err, absf(float(terrain.call("height_at", wx, wz)) - hv))
	var center_err: float = 0.0
	var checked_centers: int = 0
	for z in range(res):
		for x in range(res):
			if bool(terrain.call("is_subdivided_cell", Vector2i(x, z))):
				var ch: float = float(terrain.call("cell_center_height", Vector2i(x, z)))
				var wx2: float = -half + (float(x) + 0.5) * cell
				var wz2: float = -half + (float(z) + 0.5) * cell
				center_err = maxf(center_err, absf(float(terrain.call("height_at", wx2, wz2)) - ch))
				checked_centers += 1
	_ok("height_at 与网格顶点一致", vertex_err < 0.001, "最大误差 %.6fm" % vertex_err)
	_ok("height_at 与四分裂中心一致", checked_centers == subdiv and center_err < 0.001,
		"核对 %d/%d 格，最大误差 %.6fm" % [checked_centers, subdiv, center_err])

	# 30° 坡道 / 60° 崖壁的坡度校验
	var ramp_slope: float = float(terrain.call("slope_degrees_at", 23.0, 0.0, 0.5))
	var cliff_slope: float = float(terrain.call("slope_degrees_at", 0.0, 18.0, 0.5))
	_ok("合成图：坡道约 30°", ramp_slope >= 26.0 and ramp_slope <= 34.0, "实测 %.2f°" % ramp_slope)
	_ok("合成图：崖壁 ≥ 55°", cliff_slope >= 55.0, "实测 %.2f°" % cliff_slope)

	# 台地面积 & 顶面平整（只统计中央 22m 内，避免把相机压力测试的北墙算进来）
	var plat := _plateau_area(terrain, 22.0, SYNTH_MESA_H)
	var plat_flat: bool = plat["flat"]
	_ok("合成图：台地顶面积 ≥ 400m²", float(plat["area"]) >= 400.0,
		"%.0fm²（顶面高差 %.2fm）" % [float(plat["area"]), float(plat["range"])])
	_ok("合成图：台地顶面平整（高差 ≤ 0.5m）", plat_flat, "顶面高差 %.2fm" % float(plat["range"]))

	# 可走性：40° 通过、未退 fallback、崖壁被砍
	var wi: Dictionary = _synth_level.call("walkability_info")
	_ok("合成图：坡度校验 40° 通过（未退 fallback）",
		float(wi.get("limit_deg", 0.0)) == 40.0 and not bool(wi.get("fallback", true)),
		"limit=%.0f° blocked=%d fallback=%s failed=%s" % [
			float(wi.get("limit_deg", 0.0)), int(wi.get("blocked_by_slope", 0)),
			str(wi.get("fallback", true)), str(wi.get("failed_targets", []))])
	_ok("合成图：崖壁被砍成不可走（blocked>0）", int(wi.get("blocked_by_slope", 0)) > 0,
		"blocked=%d" % int(wi.get("blocked_by_slope", 0)))

	# 连通性 + 坡道 + 贴地
	var base: Vector3 = _synth_level.call("base_center", null)
	var center: Vector3 = _synth_level.call("central_plateau_point")
	var path_c := _path_stats(_synth_level, base, center)
	_ok("合成图：基地 → 中央台地可寻路", int(path_c["n"]) > 0,
		"路点 %d，终点 (%.1f,%.1f,%.1f)" % [int(path_c["n"]), path_c["end"].x, path_c["end"].y, path_c["end"].z])
	_ok("合成图：中央台地真上去了（终点高度 ≥ 6.5m）", float(path_c["end"].y) >= 6.5,
		"终点高度 %.2fm" % float(path_c["end"].y))
	_ok("合成图：坡道可走（路径采样最大坡度 ≤ 42°）", float(path_c["max_slope"]) <= 42.0,
		"最大 %.2f°" % float(path_c["max_slope"]))
	_ok("合成图：坡道贴地（路径中点与地形高差 ≤ 0.6m）", float(path_c["max_dev"]) <= 0.6,
		"最大偏差 %.3fm" % float(path_c["max_dev"]))

	# 两条坡道：从 ±x 两侧各走一次，都能上中央台地
	var pa: Dictionary = _path_stats(_synth_level, Vector3(-31.0, 0.0, 0.0), center)
	var pb: Dictionary = _path_stats(_synth_level, Vector3(31.0, 0.0, 0.0), center)
	var ramps_ok: bool = int(pa["n"]) > 0 and int(pb["n"]) > 0 		and float(pa["end"].y) >= 6.5 and float(pb["end"].y) >= 6.5
	_ok("合成图：至少 2 条坡道（±x 两侧都能上）", ramps_ok,
		"-x 路点 %d 终点高度 %.1f；+x 路点 %d 终点高度 %.1f" % [
			int(pa["n"]), float(pa["end"].y), int(pb["n"]), float(pb["end"].y)])

	# 资源连通：中央矿 + 两侧低地矿 + 基地旁树
	var mine_ok: int = 0
	for m in _synth_data.mines:
		var p: Dictionary = _path_stats(_synth_level, base, Vector3(m.x, 0.0, m.y))
		if int(p["n"]) > 0:
			mine_ok += 1
	_ok("合成图：基地 → 全部金矿连通", mine_ok == _synth_data.mines.size(),
		"%d/%d" % [mine_ok, _synth_data.mines.size()])
	var tree_ok: int = 0
	for t in [_synth_data.trees[0], _synth_data.trees[1]]:
		var p2: Dictionary = _path_stats(_synth_level, base, Vector3(t.x, 0.0, t.y))
		if int(p2["n"]) > 0:
			tree_ok += 1
	_ok("合成图：基地 → 最近树林连通", tree_ok == 2, "%d/2" % tree_ok)

	# is_buildable：台地顶/低地可建，坡道/崖壁不可建
	var b_top: bool = bool(_synth_level.call("is_buildable", Vector3(0.0, 0.0, 0.0), Vector2i(4, 4)))
	var b_ramp: bool = bool(_synth_level.call("is_buildable", Vector3(23.0, 0.0, 0.0), Vector2i(4, 4)))
	var b_cliff: bool = bool(_synth_level.call("is_buildable", Vector3(0.0, 0.0, 18.0), Vector2i(4, 4)))
	var b_low: bool = bool(_synth_level.call("is_buildable", base + Vector3(10.0, 0.0, 0.0), Vector2i(4, 4)))
	_ok("合成图：台地顶可建", b_top)
	_ok("合成图：低地可建", b_low)
	_ok("合成图：4×4 跨坡道被拒（高差 > 0.8m）", not b_ramp,
		"高差 %.2fm" % float(_synth_level.call("footprint_height_range", Vector3(23.0, 0.0, 0.0), Vector2i(4, 4))))
	_ok("合成图：4×4 压崖壁被拒", not b_cliff)

	# 单位在坡道/台地上贴地（只有 Game/单位脚本健康时才跑）
	_test_unit_grounding()

	_summary["合成"] = {
		"height_range": h_range, "max_slope_deg": max_slope,
		"triangles": tris, "subdivided_cells": subdiv,
		"plateau_area_m2": plat["area"], "plateau_flat_range": plat["range"],
		"ramp_slope_deg": ramp_slope, "cliff_slope_deg": cliff_slope,
		"walkability": wi,
		"path_center": {"n": path_c["n"], "end_y": path_c["end"].y,
			"max_slope_deg": path_c["max_slope"], "max_ground_dev": path_c["max_dev"]},
	}


func _test_unit_grounding() -> void:
	if not _game_ok:
		return
	_game.call("reset")
	_game.call("setup_factions")
	_game.set("level", _synth_level)
	var phase: int = 1
	if _const_script != null:
		var phases: Dictionary = _const_script.get_script_constant_map().get("Phase", {})
		phase = int(phases.get("RUNNING", 1))
	_game.set("phase", phase)
	var player = _game.get("player_faction")
	if player == null:
		_ok("单位贴地：玩家阵营可用", false)
		return
	var start := Vector3(-30.0, 0.0, 0.0)
	var u = _game.call("spawn_unit", player, &"footman", _synth_level.call("snap_to_ground", start), _synth_level)
	if u == null:
		_ok("单位贴地：步兵生成", false)
		return
	u.set_process(false)
	var target: Vector3 = _synth_level.call("snap_to_ground", Vector3(-12.0, 0.0, 0.0))
	u.call("order_move", target)
	var max_err: float = 0.0
	var frames: int = 0
	var final_dist: float = 999.0
	for i in range(600):
		u._process(1.0 / 60.0)
		var x: float = u.global_position.x
		var z: float = u.global_position.z
		var h: float = float(_synth_level.call("height_at", x, z))
		if i > 5:
			max_err = maxf(max_err, absf(u.global_position.y - h))
		final_dist = u.global_position.distance_to(target)
		frames = i + 1
		if final_dist < 1.2:
			break
	var climbed: bool = u.global_position.y >= 6.0
	_ok("单位贴地：坡道/台地上最大离地误差 ≤ 0.35m", max_err <= 0.35,
		"最大 %.3fm（%d 帧）" % [max_err, frames])
	_ok("单位贴地：能走上台地（高度 ≥ 6m，终点 ≤ 2m）", climbed and final_dist <= 2.0,
		"高度 %.2fm，距终点 %.2fm" % [u.global_position.y, final_dist])
	_summary["单位贴地"] = {"max_err": max_err, "frames": frames,
		"final_y": u.global_position.y, "final_dist": final_dist}
	_game.call("reset")


# ===========================================================================
# 镜头：台地顶 / 台地边缘 / 沟壑三个焦点
# ===========================================================================

func _test_camera_synthetic() -> void:
	if _synth_level == null or _cam_script == null:
		return
	var parent := CameraParent.new()
	parent.name = "镜头夹具"
	root.add_child(parent)
	var cam = _cam_script.new()
	cam.name = "自检镜头"
	cam.set("level_override", _synth_level)
	cam.set("cfg_override", _synth_cfg)
	parent.add_child(cam)
	await process_frame
	cam.set_process(false)

	var cam3d: Camera3D = cam.get("cam")
	if cam3d == null:
		_ok("镜头：子 Camera3D 已创建", false)
		parent.queue_free()
		return

	var focuses: Array = [
		{"name": "台地顶", "p": Vector3(0.0, 0.0, 0.0), "stress": false},
		{"name": "台地边缘", "p": Vector3(0.0, 0.0, 16.0), "stress": true},
		{"name": "沟壑", "p": Vector3(0.0, 0.0, 30.0), "stress": false},
	]
	var report: Dictionary = {}
	for f in focuses:
		var fp: Vector3 = f["p"]
		fp.y = float(_synth_level.call("height_at", fp.x, fp.z))
		cam.set("_focus", fp)
		cam.set("_focus_target", fp)
		cam.set("_placed", true)
		cam.set("_yaw", 0.0)
		cam.set("_yaw_target", 0.0)
		cam.set("_dist", 28.0)
		cam.set("_dist_target", 28.0)
		var min_clear: float = 999.0
		var min_ring: float = 999.0
		var los_ok: bool = true
		var max_lift: float = 0.0
		for i in range(90):
			cam.call("_process", 1.0 / 60.0)
			var clear: float = float(cam.call("terrain_clearance"))
			min_clear = minf(min_clear, clear)
			var cp: Vector3 = cam3d.global_position
			for k in range(8):
				var ang: float = TAU * float(k) / 8.0
				var px: float = cp.x + cos(ang) * 1.2
				var pz: float = cp.z + sin(ang) * 1.2
				min_ring = minf(min_ring, cp.y - float(_synth_level.call("height_at", px, pz)))
			if not _los_ok(_synth_level, fp, cp, 0.18, 0.05):
				los_ok = false
			max_lift = maxf(max_lift, cp.y - (fp.y + 28.0 * sin(deg_to_rad(50.0))))
		var dist_after: float = float(cam.call("distance"))
		var yaw_after: float = float(cam.call("yaw_degrees"))
		var pitch_ok: bool = is_equal_approx(float(_synth_cfg.camera_pitch_deg), 50.0)
		_ok("镜头[%s]：相机离地 ≥ 1.0m" % f["name"], min_clear >= 1.0,
			"最小净空 %.2fm" % min_clear)
		_ok("镜头[%s]：1.2m 邻域不切崖壁" % f["name"], min_ring >= 0.5,
			"邻域最小净空 %.2fm" % min_ring)
		_ok("镜头[%s]：视线不被地形挡住" % f["name"], los_ok,
			"相机 (%.1f,%.1f,%.1f) 抬高 %.2fm" % [cam3d.global_position.x, cam3d.global_position.y,
				cam3d.global_position.z, max_lift])
		if bool(f.get("stress", false)):
			_ok("镜头[%s]：崖壁遮挡时确实触发了抬高保护" % f["name"], max_lift >= 0.5,
				"抬高 %.2fm（原始视线会被 20m 压力墙挡住）" % max_lift)
		_ok("镜头[%s]：距离/偏航/50°俯角手感参数未变" % f["name"],
			is_equal_approx(dist_after, 28.0) and absf(yaw_after) < 0.01 and pitch_ok,
			"dist=%.2f yaw=%.2f° pitch=%.1f°" % [dist_after, yaw_after, float(_synth_cfg.camera_pitch_deg)])
		report[f["name"]] = {"min_clear": min_clear, "min_ring": min_ring,
			"los": los_ok, "lift": max_lift}
	_summary["镜头"] = report
	cam.queue_free()
	parent.queue_free()
	await process_frame


## 视线是否全程在地形之上（从 min_t 开始采样）
func _los_ok(lv: Node3D, focus: Vector3, cam_pos: Vector3, min_t: float, clearance: float) -> bool:
	for i in range(1, 49):
		var t: float = min_t + (1.0 - min_t) * float(i) / 48.0
		var p: Vector3 = focus.lerp(cam_pos, t)
		if p.y < float(lv.call("height_at", p.x, p.z)) + clearance:
			return false
	return true


# ===========================================================================
# 真实 200m 地图
# ===========================================================================

func _test_real() -> void:
	_real_data = _map_script.call("build", _cfg)
	if _real_data == null:
		_ok("真实 MapData 生成", false)
		return
	_real_level = _level_script.new()
	_real_level.name = "真实地图"
	root.add_child(_real_level)
	_real_level.call("build_from_data", _real_data, _cfg)

	var stats: Dictionary = _real_level.call("terrain_stats")
	var wi: Dictionary = _real_level.call("walkability_info")
	print("  · 真实图生成统计：" + JSON.stringify(_real_data.stats))
	print("  · 真实图地形统计：" + JSON.stringify(stats))
	print("  · 真实图可走性：" + JSON.stringify(wi))

	var world: float = float(_real_level.get("world_size"))
	var h_range: float = float(stats.get("height_range", 0.0))
	var max_slope: float = float(stats.get("max_slope_deg", 0.0))
	var tris: int = int(stats.get("triangle_count", 0))
	var subdiv: int = int(stats.get("subdivided_cells", 0))
	var steep_ratio: float = float(stats.get("steep_face_ratio", 0.0))
	var plat_area: float = float(_real_data.plateau_area)
	var plateau: Dictionary = _real_data.plateau if _real_data.plateau is Dictionary else {}
	var ramps: Array = _real_data.ramps if _real_data.ramps is Array else []
	var top_h: float = float(plateau.get("top", 0.0))

	_ok("真实图：地图已放大到 ≥180m", world >= 180.0, "world_size=%.0fm" % world)
	_ok("真实图：高度极差 ≥ 6m", h_range >= 6.0, "极差 %.2fm（min %.2f / max %.2f）" % [
		h_range, float(stats.get("height_min", 0.0)), float(stats.get("height_max", 0.0))])
	_ok("真实图：最大坡度 ≥ 55°（崖壁）", max_slope >= 55.0, "最大 %.2f°" % max_slope)
	_ok("真实图：陡崖硬面（四分裂格 > 0）", subdiv > 0, "四分裂 %d 格 / 三角面 %d" % [subdiv, tris])
	_ok("真实图：陡面占比 ≥ 5%", steep_ratio >= 0.05, "%.2f%%" % (steep_ratio * 100.0))
	_ok("真实图：台地顶面高度 6~10m", top_h >= 6.0 and top_h <= 10.0, "台地顶 %.2fm" % top_h)
	_ok("真实图：台地可站立面积 ≥ 400m²", plat_area >= 400.0, "%.0fm²" % plat_area)
	_ok("真实图：坡道元数据 ≥ 2 条", ramps.size() >= 2, "%d 条" % ramps.size())
	_ok("真实图：坡度校验 40° 通过（未退 fallback）",
		float(wi.get("limit_deg", 0.0)) == 40.0 and not bool(wi.get("fallback", true)),
		"limit=%.0f° blocked=%d failed=%s" % [float(wi.get("limit_deg", 0.0)),
			int(wi.get("blocked_by_slope", 0)), str(wi.get("failed_targets", []))])

	var base: Vector3 = _real_level.call("base_center", null)
	var center: Vector3 = _real_level.call("central_plateau_point")
	var path_c: Dictionary = _path_stats(_real_level, base, center)
	_ok("真实图：基地 → 中央台地可寻路", int(path_c["n"]) > 0,
		"路点 %d，终点 (%.1f,%.1f,%.1f)" % [int(path_c["n"]), path_c["end"].x, path_c["end"].y, path_c["end"].z])
	_ok("真实图：中央台地终点高度 ≥ 6.5m", float(path_c["end"].y) >= 6.5,
		"%.2fm" % float(path_c["end"].y))
	_ok("真实图：基地 → 中央坡道贴地（偏差 ≤ 1.2m）", float(path_c["max_dev"]) <= 1.2,
		"最大偏差 %.3fm，采样最大坡度 %.2f°" % [float(path_c["max_dev"]), float(path_c["max_slope"])])

	var enemy := Vector3(_cfg.enemy_base_pos.x, 0.0, _cfg.enemy_base_pos.y)
	var path_e: Dictionary = _path_stats(_real_level, base, enemy)
	_ok("真实图：玩家基地 → 敌人基地连通", int(path_e["n"]) > 0,
		"路点 %d" % int(path_e["n"]))

	var mine_ok: int = 0
	for m in _real_data.mines:
		var p: Dictionary = _path_stats(_real_level, base, Vector3(m.x, 0.0, m.y))
		if int(p["n"]) > 0:
			mine_ok += 1
	_ok("真实图：基地 → 全部金矿连通", mine_ok == _real_data.mines.size(),
		"%d/%d" % [mine_ok, _real_data.mines.size()])

	var tree_targets: Array = _nearest_points(_real_data.trees, Vector2(base.x, base.z), 2)
	var tree_ok: int = 0
	for t in tree_targets:
		var p2: Dictionary = _path_stats(_real_level, base, Vector3(t.x, 0.0, t.y))
		if int(p2["n"]) > 0:
			tree_ok += 1
	_ok("真实图：基地 → 最近 2 处树林连通", tree_ok == tree_targets.size(),
		"%d/%d" % [tree_ok, tree_targets.size()])

	var ramp_ok: int = 0
	for rp in ramps:
		if rp is Dictionary and rp.has("top_pos"):
			var tp: Vector2 = rp["top_pos"]
			var pr: Dictionary = _path_stats(_real_level, base, Vector3(tp.x, 0.0, tp.y))
			if int(pr["n"]) > 0:
				ramp_ok += 1
	_ok("真实图：基地 → 每条坡道顶连通", ramp_ok == ramps.size(), "%d/%d" % [ramp_ok, ramps.size()])

	# 中央台地顶的正中心有金矿（地图生成器把矿写进 walkable），所以挪开 8m 测平地
	var top_spot := center + Vector3(8.0, 0.0, 0.0)
	top_spot.y = float(_real_level.call("height_at", top_spot.x, top_spot.z))
	var b_center: bool = bool(_real_level.call("is_buildable", top_spot, Vector2i(4, 4)))
	var b_base: bool = bool(_real_level.call("is_buildable", base + Vector3(10.0, 0.0, 0.0), Vector2i(4, 4)))
	var rim: Vector3 = _find_cliff_point(_real_level, center, float(plateau.get("radius", 20.0)))
	var rim_range: float = float(_real_level.call("footprint_height_range", rim, Vector2i(4, 4)))
	var b_rim: bool = bool(_real_level.call("is_buildable", rim, Vector2i(4, 4)))
	_ok("真实图：台地顶（避开中央金矿）可建（4×4）", b_center,
		"点 (%.1f,%.1f,%.1f)" % [top_spot.x, top_spot.y, top_spot.z])
	_ok("真实图：基地平地可建（4×4）", b_base)
	_ok("真实图：台地崖壁 4×4 被拒（高差 >0.8m）", not b_rim and rim_range > 0.8,
		"崖点 (%.1f,%.1f,%.1f) 高差 %.2fm" % [rim.x, rim.y, rim.z, rim_range])

	_summary["真实"] = {
		"world_size": world, "resolution": _real_data.resolution,
		"height_range": h_range, "height_min": stats.get("height_min"),
		"height_max": stats.get("height_max"), "max_slope_deg": max_slope,
		"triangles": tris, "subdivided_cells": subdiv, "steep_face_ratio": steep_ratio,
		"plateau_top": top_h, "plateau_area_m2": plat_area, "ramps": ramps.size(),
		"walkable_cells": stats.get("walkable_cells"), "walkability": wi,
		"path_center": {"n": path_c["n"], "end_y": path_c["end"].y,
			"max_slope_deg": path_c["max_slope"], "max_ground_dev": path_c["max_dev"]},
		"mines_reachable": mine_ok, "trees_reachable": tree_ok,
		"ramps_reachable": ramp_ok,
		"buildable": {"center": b_center, "base": b_base, "rim": b_rim},
	}
	_cleanup_real()


func _cleanup_real() -> void:
	if _real_level != null and is_instance_valid(_real_level):
		_real_level.queue_free()
	_real_level = null
	_real_data = null


func _cleanup_synthetic() -> void:
	if _game_ok:
		_game.set("level", null)
		_game.call("reset")
	if _synth_level != null and is_instance_valid(_synth_level):
		_synth_level.queue_free()
	_synth_level = null
	_synth_data = null


# ===========================================================================
# 工具
# ===========================================================================

## 台地顶面积与顶面高差：高处（min+75%极差）且坡度 < 10° 的格
func _plateau_area(terrain, center_radius: float = 0.0, top_h: float = 0.0) -> Dictionary:
	var res: int = int(terrain.get("resolution"))
	var size: float = float(terrain.get("size"))
	var cell: float = size / float(res)
	var half: float = size * 0.5
	var cut: float = top_h - 1.0
	if top_h <= 0.0:
		cut = float(terrain.call("height_min")) + float(terrain.call("height_range")) * 0.75
	var area: float = 0.0
	var lo: float = 1e20
	var hi: float = -1e20
	for z in range(res):
		for x in range(res):
			var wx: float = -half + (float(x) + 0.5) * cell
			var wz: float = -half + (float(z) + 0.5) * cell
			if center_radius > 0.0 and Vector2(wx, wz).length() > center_radius:
				continue
			var h: float = float(terrain.call("height_at", wx, wz))
			if h < cut:
				continue
			if float(terrain.call("slope_degrees_at", wx, wz, 0.5)) >= 10.0:
				continue
			area += cell * cell
			lo = minf(lo, h)
			hi = maxf(hi, h)
	if hi < -1e19:
		return {"area": 0.0, "range": 999.0, "flat": false}
	return {"area": area, "range": maxf(0.0, hi - lo), "flat": (hi - lo) <= 0.5}


## 路径统计：路点数、终点、采样最大坡度、段中点与地形最大偏差
func _path_stats(lv: Node3D, from: Vector3, to: Vector3) -> Dictionary:
	var path: PackedVector3Array = lv.call("find_path", from, to)
	var out: Dictionary = {
		"n": path.size(), "end": Vector3.ZERO, "max_slope": 0.0, "max_dev": 0.0,
	}
	if path.is_empty():
		return out
	out["end"] = path[path.size() - 1]
	var prev: Vector3 = from
	prev.y = float(lv.call("height_at", prev.x, prev.z))
	var max_slope: float = 0.0
	var max_dev: float = 0.0
	for pt in path:
		var seg: float = Vector2(pt.x - prev.x, pt.z - prev.z).length()
		var steps: int = maxi(1, int(ceil(seg / 0.5)))
		for i in range(steps + 1):
			var t: float = float(i) / float(steps)
			var p: Vector3 = prev.lerp(pt, t)
			var h: float = float(lv.call("height_at", p.x, p.z))
			var lin: float = lerpf(prev.y, pt.y, t)
			max_dev = maxf(max_dev, absf(h - lin))
			var terrain = lv.get("terrain")
			if terrain != null:
				var slope: float = float(terrain.call("slope_degrees_at", p.x, p.z, 0.4))
				max_slope = maxf(max_slope, slope)
		prev = pt
	out["max_slope"] = max_slope
	out["max_dev"] = max_dev
	return out


## 在台地边缘环上找最陡的点（用于 is_buildable 的崖壁用例）
func _find_cliff_point(lv: Node3D, center: Vector3, radius: float) -> Vector3:
	var terrain = lv.get("terrain")
	var best := Vector3(center.x, 0.0, center.z + radius)
	var best_s: float = -1.0
	for k in range(72):
		var ang: float = TAU * float(k) / 72.0
		for rr in [radius - 2.0, radius - 1.0, radius, radius + 1.0]:
			var p := Vector3(center.x + cos(ang) * rr, 0.0, center.z + sin(ang) * rr)
			var s: float = float(terrain.call("slope_degrees_at", p.x, p.z, 0.5))
			if s > best_s:
				best_s = s
				best = p
	best.y = float(lv.call("height_at", best.x, best.z))
	return best


func _nearest_points(points: Array, from: Vector2, n: int) -> Array:
	var picked: Array = []
	for p in points:
		var d: float = p.distance_to(from)
		var ins: bool = false
		for i in range(picked.size()):
			if d < float(picked[i]["d"]):
				picked.insert(i, {"p": p, "d": d})
				ins = true
				break
		if not ins:
			picked.append({"p": p, "d": d})
		if picked.size() > n:
			picked.pop_back()
	var out: Array = []
	for e in picked:
		out.append(e["p"])
	return out


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		_lines.append("  ✓ %s %s" % [name, detail])
	else:
		_fail += 1
		_lines.append("  ✗ %s %s" % [name, detail])


func _finish() -> void:
	print("-------------------------------")
	for l in _lines:
		print(l)
	if _pass + _fail == 0:
		_ok("自检至少执行了一条用例", false, "0 条用例被执行（脚本编译/夹具失败）")
	_summary["通过"] = _pass
	_summary["失败"] = _fail
	_summary["跳过/警告"] = _warn
	_summary["结果"] = "通过" if _fail == 0 else "有失败"
	print("TERRAINTEST " + JSON.stringify(_summary))
	print("结果：通过 %d / 失败 %d / 警告 %d —— %s" % [
		_pass, _fail, _warn, "全部通过 ✓" if _fail == 0 else "有失败 ✗"])
	quit(0 if _fail == 0 else 1)
