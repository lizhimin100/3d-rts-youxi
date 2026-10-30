extends SceneTree
## **寻路抖动自检**（HOUND）：把"贴建筑抽搐 / 卡死 / 穿墙 / 顶死"量化成可复现的数字。
##
## 运行（★ 不要用 console exe）：
##   Godot_v4.7.2-stable_mono_win64.exe --headless --fixed-fps 60 --path . \
##       --script 代码/测试/寻路抖动自检.gd
##
## 为什么必须 --fixed-fps 60：整个判据建立在"0.5s / 1.5s 窗口"上，
##   帧率一变窗口里的采样数就变，数字就没法前后对比。
##
## 五个阶段（同一个世界、同一条时间线，真地图 / 真关卡 / 真寻路网格 / 真单位脚本）：
##   ① 环穿 + 共点：两栋兵营隔 2m；8 兵各自走到对面（必须绕边缘/穿窄缝）；
##      4 兵冲向建筑中心（目标压在建筑里），并要求每帧重下同一目标不漂移。
##   ② 缝里穿：8 兵从 2m 窄缝**对向**同时穿（4 ↔ 4），不许互相顶死 >1.5s。
##   ③ 贴墙根走：4 栋兵营拼成 28m 长墙，2 兵沿外墙走 20m 直线（一正一反）。
##   ④ 崖边绕：真实地图中央台地崖壁，2 兵沿崖脚绕行 85°，不许进不可走格。
##   ⑤ 人群互挤：12 兵同一个落点，最终两两 ≥0.7m、0 抽搐窗。
##
## 判据（文档/本次改造任务书_地形与寻路.md §3.1，逐条对应）：
##   1. 单位最终到达目标附近（①≤1.2m；②③≤1.5m；④≤3m；⑤目标区 ≤5.5m）
##   2. 同一单位 0.5s 内方向反转 ≥3 次且位移 <0.15m  = 抽搐 → 必须 0 次
##   3. 订单 MOVE 却连续 1.5s 位移 <0.06m            = 卡死 → 必须 0 次
##   4. 单位中心到不可走格 ≥ body_radius              = 不穿墙
##      （双口径：格子中心距 + 到格子矩形边缘的严格距离，后者才是身体）
##   5. 单采样（0.05s）位移 >0.45m                    = 被瞬移/snap 过 → 必须 0 次
##   6. 到点之后不许残留抖动（2s 内单步 >0.25m）
##   7. 目标点压进建筑时，解析出的落点净空 ≥ body_radius + 0.15（48 个来向）
##
## ★ 本文件不写 Game/Cfg 全局标识符：--script 模式下主循环被本脚本接管，
##   autoload 的全局名在本文件解析时还没注册（与 建造自检.gd 同一运行约束），
##   所以一律 root.get_node() + call()/get() 鸭子调用。

const LEVEL_SCRIPT := "res://代码/核心/关卡.gd"

# ===========================================================================
# 判据常量（改这里 = 改验收口径，注释里写了为什么是这个数）
# ===========================================================================
## 采样周期：20Hz（任务书要求）
const SAMPLE_DT := 0.05
## 抽搐窗口 0.5s / 窗口内反转 ≥3 次 / 窗口净位移 <0.15m
const TWITCH_WINDOW := 0.5
const TWITCH_REV := 3
const TWITCH_DISP := 0.15
## 卡死窗口 1.5s / 净位移 <0.06m（0.06m = 4.6m/s 的 1.3%，肉眼就是没动）
const STALL_TIME := 1.5
const STALL_DISP := 0.06
## 到达判定
const ARRIVE_DIST := 1.2
## 瞬移判定：0.05s 内正常位移上限 = 4.6m/s*0.05*1.5(分离/坡道余量) ≈ 0.35m
const TELEPORT_STEP := 0.45
## 到点后的残留抖动窗口
const AFTER_ARRIVE_SEC := 2.0
const AFTER_ARRIVE_STEP := 0.25
## 贴墙根走：中心到阻挡格边缘的下限（body_radius 0.5 × 0.9）
const WALL_MIN_CLEAR := 0.45
## 崖边绕：允许的换路（A* 重算）次数上限。绕 85° 崖壁正常 2~4 次，
## 8 次已经是"反复切路"了（贴墙抖动/RPATH 风暴都会冲上十几次）。
const CLIFF_MAX_REPATH := 8
## 人群互挤：最终两两最小间距
const CROWD_MIN_PAIR := 0.7
const CROWD_MAX_DIST := 5.5

# ===========================================================================
# 场景常量
# ===========================================================================
const BAR := &"barracks"
const FOOT := &"footman"
const ORDER_MOVE := 1
## 环形半径：要能容下"兵营1 + 10m 外的兵营2 + 两侧各 4m 净空"
const RING_R := 16.0
const RING_N := 8
const SLOT_OFFSET := Vector3(10.0, 0.0, 0.0)
const B_COUNT := 4
const SIM_MAX := 45.0
const SETTLE_SEC := 3.0
## B 组"到点后"的持续指令窗口：真实调用方（采集/建造/追击）是**每帧**重下同一个目标的，
## 这里照抄这个模式 4 秒 —— 专测"到了点还被反复叫去同一点"时的重算风暴与原地抖。
const B_SUSTAIN := 4.0
## 允许的重算次数（4 秒内）
const B_SUSTAIN_MAX_REPATH := 4
## 持续段允许的漂移（真站着就不该挪窝）
const B_SUSTAIN_MAX_DRIFT := 1.0
## 新阶段
const GAP_N := 8
const GAP_LANES: Array[float] = [-2.6, -0.9, 0.9, 2.6]
const WALL_BLOCKS := 4
const WALL_LEN := 20.0
const WALL_STAGE_SEC := 16.0
const CLIFF_N := 2
const CLIFF_STAGE_SEC := 30.0
const CROWD_N := 12
const CROWD_R := 8.0
const CROWD_STAGE_SEC := 18.0

# ===========================================================================
# 状态
# ===========================================================================
var _game: Node = null
var _cfg: Node = null
var _level: Node3D = null
var _pf: Object = null
var _faction: Object = null
var _barracks: Array = []
var _anchor := Vector3.ZERO
var _has_slot: bool = false

## 当前阶段的采样对象
var _agents: Array = []
## A 组 / B 组存档（阶段 0 结束时报告）
var _ab_agents: Array = []

var _frames: int = 0
var _sim_t: float = 0.0
var _next_sample: float = 0.0
var _booted: bool = false
var _done: bool = false
var _settle_t: float = -1.0
## B 组阶段：0=还在走 1=到点后持续重下指令 2=静置观察
var _phase_b: int = 0
var _b_sustain_t: float = -1.0
var _b_before: Dictionary = {}

## 阶段机：0=A/B 1=缝 2=墙 3=崖 4=人群 5=收尾
var _stage: int = 0
var _stage_t0: float = 0.0
var _stage_settled_t: float = -1.0
var _stage_sec: float = 0.0

var _pass: int = 0
var _fail: int = 0
var _lines: Array[String] = []
var _rows: Array[String] = []


# ===========================================================================
# 主循环
# ===========================================================================
func _process(delta: float) -> bool:
	if _done:
		return true
	if not _booted:
		_boot_once()
		return false
	_frames += 1
	_sim_t += delta
	if _sim_t >= _next_sample:
		_next_sample += SAMPLE_DT
		_sample_all()
	match _stage:
		0:
			if _tick_ab():
				_end_stage_ab()
		1:
			if _stage_over(20.0):
				_end_stage_gap()
		2:
			if _stage_over(WALL_STAGE_SEC):
				_end_stage_wall()
		3:
			if _stage_over(CLIFF_STAGE_SEC):
				_end_stage_cliff()
		4:
			if _stage_over(CROWD_STAGE_SEC):
				_end_stage_crowd()
		_:
			_finish()
	if _sim_t > 240.0:
		_finish()
	return _done


## 阶段通用收尾条件：全部不再 MOVE 并稳定 2s，或超时
func _stage_over(sec: float) -> bool:
	if _sim_t < _stage_t0 + 1.5:
		return false
	var settled := true
	for a in _agents:
		var u: Node3D = a["node"]
		if u != null and is_instance_valid(u) and int(u.get("order")) == ORDER_MOVE:
			settled = false
			break
	if settled:
		if _stage_settled_t < 0.0:
			_stage_settled_t = _sim_t
		if _sim_t > _stage_settled_t + 2.0:
			return true
	else:
		_stage_settled_t = -1.0
	return _sim_t > _stage_t0 + sec


# ===========================================================================
# 搭世界
# ===========================================================================
func _boot_once() -> void:
	_booted = true
	print("========== 寻路抖动自检 ==========")
	_game = root.get_node_or_null("Game")
	_cfg = root.get_node_or_null("Cfg")
	if _game == null or _cfg == null:
		_ok("autoload（Game/Cfg）可用", false, "拿不到 autoload，无法建关")
		_finish()
		return
	_game.call("reset")
	_game.set("difficulty_index", 0)
	_game.call("setup_factions")

	_level = load(LEVEL_SCRIPT).new()
	root.add_child(_level)
	_level.call("build")
	_level.call("spawn_props")
	_game.set("level", _level)
	_game.set("phase", 1)  # RUNNING
	_faction = _game.get("player_faction")
	_faction.call("add_res", 20000, 20000)
	_pf = _level.get("pathfinder")
	if _pf == null:
		_ok("寻路网格就位", false, "pathfinder 为空")
		_finish()
		return

	_place_arena()
	_spawn_agents()
	print("  · 地图 %.0fm，兵营1 (%.1f, %.1f)，兵营2 %s，窄缝 %s" % [
		float(_level.get("world_size")), _anchor.x, _anchor.z,
		("(%.1f, %.1f)" % [_barracks[1].global_position.x, _barracks[1].global_position.z]) if _barracks.size() > 1 else "无",
		"2 格" if _has_slot else "无（地形放不下）"])
	print("  · ① 环穿 %d + 共点 %d → ② 窄缝对穿 %d → ③ 贴墙走 %.0fm → ④ 崖边绕 → ⑤ 人群 %d（20Hz 采样）" % [
		RING_N, B_COUNT, GAP_N, WALL_LEN, CROWD_N])


## 找一块能放下"两栋兵营 + 半径 16m 环形起终点"的空地（从玩家基地往南螺旋找）
func _place_arena() -> void:
	var base: Vector3 = _level.call("base_center", _faction)
	var center := base + Vector3(0.0, 0.0, 18.0)
	var found := Vector3(INF, INF, INF)
	for r in range(0, 34):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var c := center + Vector3(float(dx) * 2.0, 0.0, float(dz) * 2.0)
				c = _snap(c)
				if _arena_ok(c):
					found = c
					break
			if found.is_finite():
				break
		if found.is_finite():
			break
	if not found.is_finite():
		# 兜底：老地图（116m）边缘可能放不下
		found = center
		_ok("找到能放下环形场景的空地", false, "螺旋搜索失败，退化到基地南侧（环半径仍 16m）")

	_anchor = _snap(found)
	_barracks.append(_spawn_barracks(_anchor))
	var b2pos: Vector3 = _snap(_anchor + SLOT_OFFSET)
	if _buildable(b2pos, Vector2i(6, 6)):
		_barracks.append(_spawn_barracks(b2pos))
		_has_slot = true


## 这块地能不能放下：两栋 6×6 兵营 + 环上 8 个起点 + 8 个终点全部可走
func _arena_ok(c: Vector3) -> bool:
	if not _buildable(c, Vector2i(6, 6)):
		return false
	if not _buildable(c + SLOT_OFFSET, Vector2i(6, 6)):
		return false
	for i in range(RING_N):
		var ang: float = TAU * float(i) / float(RING_N)
		var p := c + Vector3(cos(ang), 0.0, sin(ang)) * RING_R
		if not bool(_pf.call("is_walkable", p)):
			return false
		var g := c - Vector3(cos(ang), 0.0, sin(ang)) * RING_R
		if not bool(_pf.call("is_walkable", g)):
			return false
	return true


## 本地版 is_buildable（不打印 DIAG，批量搜索场地时用）
func _buildable(pos: Vector3, fp: Vector2i) -> bool:
	var c: Vector2i = _pf.call("world_to_cell", pos)
	var hx: int = fp.x / 2
	var hz: int = fp.y / 2
	for dz in range(-hz, hz + fp.y % 2):
		for dx in range(-hx, hx + fp.x % 2):
			if not bool(_pf.call("is_cell_walkable", Vector2i(c.x + dx, c.y + dz))):
				return false
	return float(_level.call("footprint_height_range", pos, fp)) <= 0.8


func _snap(p: Vector3) -> Vector3:
	return _level.call("snap_grid", p)


func _spawn_barracks(pos: Vector3) -> Node3D:
	var b: Node3D = _game.call("spawn_unit", _faction, BAR, pos, _level)
	if b == null:
		return null
	b.rotation = Vector3(0.0, PI, 0.0)
	_level.call("mark_footprint", b)
	if b.has_method("set_constructed"):
		b.call("set_constructed", true)
	return b


func _free_nodes(list: Array, buildings: bool = false) -> void:
	for n in list:
		if n == null or not is_instance_valid(n):
			continue
		if buildings:
			_level.call("clear_footprint", n)
		_game.call("unregister", n)
		var par: Node = n.get_parent()
		if par != null:
			par.remove_child(n)
		n.free()


## 生 12 个步兵：A 组环形 8 个（目标=对面），B 组 4 个（目标=兵营中心）
func _spawn_agents() -> void:
	var dfoe: Object = _cfg.call("unit", FOOT)
	var body_r: float = float(dfoe.get("body_radius")) if dfoe != null else 0.5
	for i in range(RING_N):
		var ang: float = TAU * float(i) / float(RING_N)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var pos := _anchor + dir * RING_R
		var goal := _anchor - dir * RING_R
		var u: Node3D = _game.call("spawn_unit", _faction, FOOT, _level.call("walkable_pos", pos), _level)
		if u == null:
			continue
		_agents.append(_make_agent(u, "A", "A%d" % i, goal, body_r))
		u.call("order_move", goal)
	for i in range(B_COUNT):
		var ang2: float = TAU * float(i) / float(B_COUNT) * 0.5  # 半圆内 4 个方向
		var dir2 := Vector3(cos(ang2), 0.0, sin(ang2))
		var pos2 := _anchor + dir2 * 15.0 + Vector3(0.0, 0.0, -6.0)
		var u2: Node3D = _game.call("spawn_unit", _faction, FOOT, _level.call("walkable_pos", pos2), _level)
		if u2 == null:
			continue
		_agents.append(_make_agent(u2, "B", "B%d" % i, _anchor, body_r))
		u2.call("order_move", _anchor)


func _make_agent(u: Node3D, group: String, label: String, target: Vector3, body_r: float) -> Dictionary:
	return {
		"node": u, "group": group, "label": label, "target": target,
		"br": body_r, "samples": [], "path_sig": "", "path_changes": 0,
		"arrive_t": -1.0, "rep0": int(u.get("dbg_repath_count")),
	}


# ===========================================================================
# ① 环穿 + 共点
# ===========================================================================
func _tick_ab() -> bool:
	if _phase_b == 0 and _sim_t > 6.0 and _a_all_arrived() and _b_all_stopped():
		_phase_b = 1
		_b_sustain_t = _sim_t
		_b_before.clear()
		for a in _agents:
			if String(a["group"]) == "B":
				a["sus0"] = (a["node"] as Node3D).global_position
				a["sus_rep0"] = int(a["path_changes"])
	elif _phase_b == 1:
		_sustain_b()
		if _sim_t > _b_sustain_t + B_SUSTAIN:
			_phase_b = 2
			_settle_t = _sim_t
	if _settle_t > 0.0 and _sim_t > _settle_t + SETTLE_SEC:
		return true
	return _sim_t > SIM_MAX


## A 组全部到点了？（用当前坐标判，不等订单状态）
func _a_all_arrived() -> bool:
	for a in _agents:
		if String(a["group"]) != "A":
			continue
		var u: Node3D = a["node"]
		if u == null or not is_instance_valid(u):
			continue
		var p: Vector3 = u.global_position
		var t: Vector3 = a["target"]
		if sqrt((p.x - t.x) * (p.x - t.x) + (p.z - t.z) * (p.z - t.z)) > ARRIVE_DIST:
			return false
	return true


## B 组都停下来了（订单不再是 MOVE）？
func _b_all_stopped() -> bool:
	for a in _agents:
		if String(a["group"]) != "B":
			continue
		var u: Node3D = a["node"]
		if u == null or not is_instance_valid(u):
			continue
		if int(u.get("order")) == ORDER_MOVE:
			return false
	return true


## 每帧重下同一个目标 —— 与 采集/建造/追击 的调用方式一致（_go_to(pos, false)）。
func _sustain_b() -> void:
	for a in _agents:
		if String(a["group"]) != "B":
			continue
		var u: Node3D = a["node"]
		if u == null or not is_instance_valid(u):
			continue
		u.call("_go_to", a["target"], false)


func _end_stage_ab() -> void:
	_ab_agents = _agents.duplicate()
	var a_tw: int = 0
	var a_st: int = 0
	var a_tp: int = 0
	var a_arrive: int = 0
	var a_min_wc := 99.0
	var a_min_we := 99.0
	var b_tw: int = 0
	var b_st: int = 0
	var b_tp: int = 0
	var b_min_pair := 99.0
	var b_max_center := 0.0
	var b_max_drift := 0.0
	var b_max_rep := 0
	var a_restless: int = 0

	for a in _agents:
		var tw: Array = _twitch_windows(a)
		var st: Array = _stall_windows(a)
		var tp: Array = _teleports(a)
		var mm: Vector2 = _min_wall(a)
		var rest: float = _after_arrive_max_step(a)
		var s: Array = a["samples"]
		var last_p := Vector2.ZERO
		if s.size() > 0:
			last_p = s[s.size() - 1]["p"]
		var d_end := last_p.distance_to(Vector2(a["target"].x, a["target"].z))
		var at: float = float(a["arrive_t"])
		if String(a["group"]) == "A":
			a_tw += tw.size()
			a_st += st.size()
			a_tp += tp.size()
			a_min_wc = minf(a_min_wc, mm.x)
			a_min_we = minf(a_min_we, mm.y)
			if d_end <= ARRIVE_DIST:
				a_arrive += 1
			if rest > AFTER_ARRIVE_STEP:
				a_restless += 1
			_rows.append("  %s 到达 %s 用时 %s | 抽搐窗 %d | 卡死窗 %d | 瞬移 %d | 贴墙心距 %.2f 边距 %.2f | 换路 %d | 到点后最大步 %.2f" % [
				String(a["label"]), ("是" if d_end <= ARRIVE_DIST else "否 %.1fm" % d_end),
				("%.1fs" % at) if at > 0.0 else "-", tw.size(), st.size(), tp.size(), mm.x, mm.y,
				int(a["path_changes"]), rest])
		else:
			b_tw += tw.size()
			b_st += st.size()
			b_tp += tp.size()
			b_max_center = maxf(b_max_center, d_end)
			var drift := 0.0
			var rep := 0
			if a.has("sus0"):
				var p0: Vector3 = a["sus0"]
				drift = last_p.distance_to(Vector2(p0.x, p0.z))
				rep = int(a["path_changes"]) - int(a["sus_rep0"])
				b_max_drift = maxf(b_max_drift, drift)
				b_max_rep = maxi(b_max_rep, rep)
			_rows.append("  %s 距建筑中心 %.2fm | 抽搐窗 %d | 卡死窗 %d | 瞬移 %d | 换路 %d | 到点后最大步 %.2f | 持续段漂移 %.2fm 复算 %d 次" % [
				String(a["label"]), d_end, tw.size(), st.size(), tp.size(),
				int(a["path_changes"]), rest, drift, rep])

	if _agents.size() > 0:
		for i in range(_agents.size()):
			for j in range(i + 1, _agents.size()):
				var ai: Dictionary = _agents[i]
				var aj: Dictionary = _agents[j]
				if String(ai["group"]) != "B" or String(aj["group"]) != "B":
					continue
				var si: Array = ai["samples"]
				var sj: Array = aj["samples"]
				if si.size() > 0 and sj.size() > 0:
					b_min_pair = minf(b_min_pair, (si[si.size() - 1]["p"] as Vector2).distance_to(sj[sj.size() - 1]["p"]))

	_test_formation()
	_test_edge_goals()

	var body_r: float = 0.5
	for a in _agents:
		body_r = maxf(body_r, float(a["br"]))
	_rows.append("  · ① 汇总：A 组到达 %d/%d，抽搐 %d 窗，卡死 %d 窗，瞬移 %d 次，最贴墙(边距) %.2fm（身体半径 %.2f）" % [
		a_arrive, RING_N, a_tw, a_st, a_tp, a_min_we, body_r])
	_rows.append("  · ① 汇总：B 组抽搐 %d 窗，卡死 %d 窗，瞬移 %d 次，最远距中心 %.2fm，两两最近 %.2fm" % [
		b_tw, b_st, b_tp, b_max_center, b_min_pair])
	_rows.append("  · ① 汇总：B 组到点后被每帧重下指令 %.0fs → 最大漂移 %.2fm，最多复算 %d 次" % [
		B_SUSTAIN, b_max_drift, b_max_rep])

	_ok("① A 组 8 兵全部到达目标 ≤%.1fm" % ARRIVE_DIST, a_arrive == RING_N, "%d/%d" % [a_arrive, RING_N])
	_ok("① 无抽搐（0.5s 内反转≥3 且位移<0.15m）", a_tw == 0 and b_tw == 0, "A%d + B%d 窗" % [a_tw, b_tw])
	_ok("① 无卡死（MOVE 下 1.5s 位移<0.06m）", a_st == 0 and b_st == 0, "A%d + B%d 窗" % [a_st, b_st])
	_ok("① 无瞬移/snap（单采样位移 ≤%.2fm）" % TELEPORT_STEP, a_tp == 0 and b_tp == 0, "A%d + B%d 次" % [a_tp, b_tp])
	_ok("① 不穿墙：中心到不可走格中心 ≥ body_radius", a_min_wc >= body_r * 0.999,
		"最近 %.2fm / 半径 %.2f" % [a_min_wc, body_r])
	_ok("① 不贴墙：中心到不可走格**边缘** ≥ body_radius×0.9", a_min_we >= body_r * 0.9,
		"最近 %.2fm / 要求 %.2f" % [a_min_we, body_r * 0.9])
	_ok("① B 组目标点压在建筑里也能站住（≤6.5m）且不抽搐", b_max_center <= 6.5 and b_tw == 0,
		"最远 %.2fm，抽搐 %d" % [b_max_center, b_tw])
	_ok("① B 组多单位不挤成一坨（两两 ≥0.7m）", b_min_pair >= 0.7 or _agents.size() < 2,
		"最近 %.2fm" % b_min_pair)
	_ok("① 到点后不残留抖动（%.1fs 内单步 ≤%.2fm）" % [AFTER_ARRIVE_SEC, AFTER_ARRIVE_STEP],
		a_restless == 0, "%d/%d 单位" % [a_restless, RING_N])
	_ok("① 到点后每帧重下同一目标：不漂移（≤%.1fm）" % B_SUSTAIN_MAX_DRIFT,
		b_max_drift <= B_SUSTAIN_MAX_DRIFT, "最大 %.2fm" % b_max_drift)
	_ok("① 到点后每帧重下同一目标：不复算路径（≤%d 次/%.0fs）" % [B_SUSTAIN_MAX_REPATH, B_SUSTAIN],
		b_max_rep <= B_SUSTAIN_MAX_REPATH, "最多 %d 次" % b_max_rep)

	# 清场：A/B 单位退出；两栋兵营留给 ② 窄缝
	var nodes: Array = []
	for a in _agents:
		nodes.append(a["node"])
	_free_nodes(nodes)
	_agents = []
	_enter_stage(1)


## 编队落点唯一性：同一组 8 个编队格，
##   旧算法（关卡 walkable_pos → 最近可走格中心）会夹到重复点；
##   新算法（指令系统 _formation_points → 可站立点 + 最小间距 1.25m）必须两两错开。
func _test_formation() -> void:
	var cmd: Node = load("res://代码/操作/指令系统.gd").new()
	var n: int = 8
	var spacing := 1.9
	var cols: int = int(ceil(sqrt(float(n))))
	var rows2: int = int(ceil(float(n) / float(cols)))
	var sx: float = -float(cols - 1) * 0.5 * spacing
	var sz: float = -float(rows2 - 1) * 0.5 * spacing
	var slots: Array = []
	for i in range(n):
		slots.append(_anchor + Vector3(sx + float(i % cols) * spacing, 0.0, sz + float(i / cols) * spacing))
	var old_pts: Array = []
	for sl in slots:
		old_pts.append(_level.call("walkable_pos", sl))
	var new_pts: Array = cmd.call("_formation_points", _anchor, n, spacing)
	var old_min := _min_pair(old_pts)
	var new_min := _min_pair(new_pts)
	var old_uniq := _unique_count(old_pts)
	var new_uniq := _unique_count(new_pts)
	var new_ok: int = 0
	for q in new_pts:
		if bool(_pf.call("is_standable", q, 0.49)):
			new_ok += 1
	_rows.append("  · 编队落点：旧算法 唯一 %d/%d、两两最近 %.2fm | 新算法 唯一 %d/%d、两两最近 %.2fm、可站立 %d/%d" % [
		old_uniq, n, old_min, new_uniq, n, new_min, new_ok, n])
	_ok("① 编队落点两两错开（≥1.2m，不再多人抢同一格）", new_min >= 1.2, "最近 %.2fm（旧算法 %.2fm）" % [new_min, old_min])
	_ok("① 编队落点全部可站立（净空 ≥0.49m）", new_ok == n, "%d/%d" % [new_ok, n])
	_ok("① 编队落点个数不丢（8 个点 8 个位置）", new_uniq == n, "%d/%d（旧算法 %d）" % [new_uniq, n, old_uniq])
	cmd.free()


## 目标压在建筑里：48 个来向解析出的落点都必须有 body_radius + GOAL_MARGIN 的净空。
## 这是"贴墙 0.14~0.26m 的停止点"的专项回归 —— 落点净空不够，站上去就会被分离
## 推进阻挡格，然后逐帧推出→兜底吸附，形成抽搐。
func _test_edge_goals() -> void:
	if _barracks.is_empty():
		return
	var br: float = 0.5
	var need: float = br * 0.98 + 0.15
	var bpos: Vector3 = _barracks[0].global_position
	var worst := 99.0
	var okn: int = 0
	var total: int = 48
	for i in range(total):
		var ang: float = TAU * float(i) / float(total)
		var origin: Vector3 = bpos + Vector3(cos(ang), 0.0, sin(ang)) * 9.0
		var g: Vector3 = _pf.call("standable_near", bpos, origin, br * 0.98, 0.15)
		var c: float = _pf.call("clearance_at", g)
		worst = minf(worst, c)
		if c + 0.002 >= need:
			okn += 1
	_rows.append("  · 建筑内目标落点：%d 个来向，净空最差 %.2fm（要求 %.2fm）" % [total, worst, need])
	_ok("① 目标压进建筑的落点净空 ≥ body_radius+0.15（48 个来向）", okn == total,
		"%d/%d，最差 %.2fm" % [okn, total, worst])


# ===========================================================================
# ② 2m 窄缝对穿
# ===========================================================================
func _enter_stage(n: int) -> void:
	_stage = n
	_stage_t0 = _sim_t
	_stage_settled_t = -1.0
	_agents = []
	match n:
		1:
			_setup_gap()
		2:
			_setup_wall()
		3:
			_setup_cliff()
		4:
			_setup_crowd()


func _setup_gap() -> void:
	if _barracks.size() < 2:
		_rows.append("  · ② 跳过硬缝（地形放不下两栋兵营）")
		return
	var a: Vector3 = _barracks[0].global_position
	var b: Vector3 = _barracks[1].global_position
	# 两栋 6×6 兵营的阻挡矩形各向四周扩 1 格：中心距 10m → 中间恰好 2m 缝
	var xw: float = a.x + 4.0
	var xe: float = b.x - 4.0
	var zc: float = a.z
	var body_r: float = 0.5
	var dfoe: Object = _cfg.call("unit", FOOT)
	if dfoe != null:
		body_r = float(dfoe.get("body_radius"))
	for i in range(4):
		var z: float = zc + GAP_LANES[i]
		var pw: Vector3 = Vector3(xw - 6.0 - float(i) * 3.0, 0.0, z)
		var pe: Vector3 = Vector3(xe + 6.0 + float(i) * 3.0, 0.0, z)
		var gw: Vector3 = Vector3(xe + 10.0, 0.0, z)
		var ge: Vector3 = Vector3(xw - 10.0, 0.0, z)
		var uw: Node3D = _game.call("spawn_unit", _faction, FOOT, _level.call("walkable_pos", pw), _level)
		if uw != null:
			_agents.append(_make_agent(uw, "G", "G%da" % i, gw, body_r))
			uw.call("order_move", gw)
		var ue: Node3D = _game.call("spawn_unit", _faction, FOOT, _level.call("walkable_pos", pe), _level)
		if ue != null:
			_agents.append(_make_agent(ue, "G", "G%db" % i, ge, body_r))
			ue.call("order_move", ge)


func _end_stage_gap() -> void:
	if _agents.is_empty():
		_enter_stage(2)
		return
	var tw := 0
	var st := 0
	var tp := 0
	var arrive := 0
	var max_t := 0.0
	for a in _agents:
		var w: Array = _twitch_windows(a)
		var s: Array = _stall_windows(a)
		var p: Array = _teleports(a)
		tw += w.size()
		st += s.size()
		tp += p.size()
		var ss: Array = a["samples"]
		var d := 99.0
		if ss.size() > 0:
			d = (ss[ss.size() - 1]["p"] as Vector2).distance_to(Vector2(a["target"].x, a["target"].z))
		if d <= 1.5:
			arrive += 1
		max_t = maxf(max_t, float(a["arrive_t"]))
		_rows.append("  %s 穿缝 %s（%.2fm）| 抽搐 %d | 卡死 %d | 瞬移 %d | 用时 %s" % [
			String(a["label"]), ("过" if d <= 1.5 else "没过"), d, w.size(), s.size(), p.size(),
			("%.1fs" % float(a["arrive_t"])) if float(a["arrive_t"]) > 0.0 else "-"])
	_rows.append("  · ② 汇总：对穿 %d/%d 过缝，抽搐 %d 窗，卡死 %d 窗，瞬移 %d 次" % [
		arrive, GAP_N, tw, st, tp])
	_ok("② 2m 窄缝 8 兵对向全部穿过（≤1.5m）", arrive == GAP_N, "%d/%d" % [arrive, GAP_N])
	_ok("② 窄缝对穿无互相顶死（MOVE 下 1.5s 无位移 = 0 窗）", st == 0, "%d 窗" % st)
	_ok("② 窄缝对穿无抽搐", tw == 0, "%d 窗" % tw)
	_ok("② 窄缝对穿无瞬移", tp == 0, "%d 次" % tp)
	# 清掉两栋兵营（后面的阶段要自己造墙）
	_free_nodes(_barracks.duplicate(), true)
	_barracks = []
	_agents = []
	_enter_stage(2)


# ===========================================================================
# ③ 贴墙根走 20m 直线
# ===========================================================================
func _setup_wall() -> void:
	var base: Vector3 = _level.call("base_center", _faction)
	var spot := _find_wall_spot(base)
	if not spot.is_finite():
		_rows.append("  · ③ 跳过贴墙走（找不到 28m 直墙的空地）")
		_ok("③ 贴墙根走 20m：找到场地", false, "螺旋搜索失败")
		return
	for i in range(WALL_BLOCKS):
		var bp: Vector3 = spot + Vector3(float(i) * 6.0, 0.0, 0.0)
		_barracks.append(_spawn_barracks(bp))
	# 阻挡矩形 = 中心 ±4m；走线在 z+4.5（0.5m 净空）
	var zline: float = spot.z + 4.5
	var p0: Vector3 = Vector3(spot.x - 2.0, 0.0, zline)
	var p1: Vector3 = Vector3(spot.x + 2.0 + WALL_LEN, 0.0, zline)
	var body_r: float = 0.5
	var dfoe: Object = _cfg.call("unit", FOOT)
	if dfoe != null:
		body_r = float(dfoe.get("body_radius"))
	var u0: Node3D = _game.call("spawn_unit", _faction, FOOT, _level.call("walkable_pos", p0), _level)
	if u0 != null:
		_agents.append(_make_agent(u0, "W", "W0", p1, body_r))
		u0.call("order_move", p1)
	var u1: Node3D = _game.call("spawn_unit", _faction, FOOT, _level.call("walkable_pos", p1 + Vector3(0.0, 0.0, 0.0)), _level)
	if u1 != null:
		_agents.append(_make_agent(u1, "W", "W1", p0, body_r))
		u1.call("order_move", p0)


## 找一排 4 栋兵营（中心间距 6m = 连成 28m 墙）能放下、且南侧 20m 走线全程可站立
func _find_wall_spot(near: Vector3) -> Vector3:
	var offs: Array[Vector2] = [Vector2(0, 24), Vector2(0, -24), Vector2(24, 0), Vector2(-24, 0), Vector2(0, 40)]
	for base_off in offs:
		var c0: Vector3 = _snap(near + Vector3(base_off.x, 0.0, base_off.y))
		for r in range(0, 14):
			for dz in range(-r, r + 1):
				for dx in range(-r, r + 1):
					if maxi(absi(dx), absi(dz)) != r:
						continue
					var c: Vector3 = _snap(c0 + Vector3(float(dx) * 4.0, 0.0, float(dz) * 4.0))
					if _wall_ok(c):
						return c
	return Vector3(INF, INF, INF)


func _wall_ok(c: Vector3) -> bool:
	for i in range(WALL_BLOCKS):
		if not _buildable(c + Vector3(float(i) * 6.0, 0.0, 0.0), Vector2i(6, 6)):
			return false
	var zline: float = c.z + 4.5
	var x: float = c.x - 3.0
	while x <= c.x + WALL_LEN + 3.0:
		var p := Vector3(x, 0.0, zline)
		if not bool(_pf.call("is_walkable", p)):
			return false
		if not bool(_pf.call("is_standable", p, 0.49)):
			return false
		x += 1.0
	# 两端各留 2m 转身空间
	for e in [Vector3(c.x - 5.0, 0.0, zline), Vector3(c.x + WALL_LEN + 5.0, 0.0, zline)]:
		if not bool(_pf.call("is_standable", e, 0.49)):
			return false
	return true


func _end_stage_wall() -> void:
	if _agents.is_empty():
		_enter_stage(3)
		return
	var tw := 0
	var st := 0
	var tp := 0
	var arrive := 0
	var min_we := 99.0
	var max_edge_off := 0.0
	for a in _agents:
		var w: Array = _twitch_windows(a)
		var s: Array = _stall_windows(a)
		var p: Array = _teleports(a)
		var mm: Vector2 = _min_wall(a)
		tw += w.size()
		st += s.size()
		tp += p.size()
		min_we = minf(min_we, mm.y)
		var ss: Array = a["samples"]
		var d := 99.0
		if ss.size() > 0:
			d = (ss[ss.size() - 1]["p"] as Vector2).distance_to(Vector2(a["target"].x, a["target"].z))
		if d <= 1.5:
			arrive += 1
		_rows.append("  %s 贴墙走 %s（%.2fm）| 抽搐 %d | 卡死 %d | 瞬移 %d | 贴墙边距 %.2f | 换路 %d" % [
			String(a["label"]), ("完" if d <= 1.5 else "未完"), d, w.size(), s.size(), p.size(),
			mm.y, int(a["path_changes"])])
	_rows.append("  · ③ 汇总：%d/%d 走完 20m，抽搐 %d 窗，卡死 %d 窗，瞬移 %d 次，最贴墙 %.2fm" % [
		arrive, _agents.size(), tw, st, tp, min_we])
	_ok("③ 沿兵营外墙走 20m 全部走完", arrive == _agents.size(), "%d/%d" % [arrive, _agents.size()])
	_ok("③ 贴墙根走：0 抽搐", tw == 0, "%d 窗" % tw)
	_ok("③ 贴墙根走：0 卡死", st == 0, "%d 窗" % st)
	_ok("③ 贴墙根走：中心到阻挡格边缘 ≥ %.2fm（body_radius×0.9）" % WALL_MIN_CLEAR,
		min_we >= WALL_MIN_CLEAR, "最近 %.2fm" % min_we)
	var nodes: Array = []
	for a in _agents:
		nodes.append(a["node"])
	_free_nodes(nodes)
	_free_nodes(_barracks.duplicate(), true)
	_barracks = []
	_agents = []
	_enter_stage(3)


# ===========================================================================
# ④ 崖边绕（真实地图中央台地）
# ===========================================================================
func _setup_cliff() -> void:
	var pair: Array = _find_cliff_pair()
	if pair.is_empty():
		_rows.append("  · ④ 跳过崖边绕（找不到台地崖壁）")
		_ok("④ 崖边绕：找到中央台地崖壁", false, "扫描失败")
		return
	var p0: Vector3 = pair[0]
	var p1: Vector3 = pair[1]
	var body_r: float = 0.5
	var dfoe: Object = _cfg.call("unit", FOOT)
	if dfoe != null:
		body_r = float(dfoe.get("body_radius"))
	var tangent: Vector3 = (p1 - p0)
	tangent.y = 0.0
	tangent = tangent.normalized()
	for i in range(CLIFF_N):
		var s: Vector3 = p0 + tangent * (float(i) * 2.2)
		var g: Vector3 = p1 + tangent * (float(i) * 2.2)
		var u: Node3D = _game.call("spawn_unit", _faction, FOOT, _level.call("walkable_pos", s), _level)
		if u == null:
			continue
		_agents.append(_make_agent(u, "C", "C%d" % i, g, body_r))
		u.call("order_move", g)
	_rows.append("  · ④ 崖边：起点 (%.1f, %.1f) → 终点 (%.1f, %.1f)，直线 %.1fm（必须绕崖）" % [
		p0.x, p0.z, p1.x, p1.z, Vector2(p1.x - p0.x, p1.z - p0.z).length()])


## 在中央台地外缘找一个"绕 85°"的走位对：两点都在崖脚可站立，
## 但两点之间被崖体挡死（必须绕行）。
func _find_cliff_pair() -> Array:
	var center := Vector3.ZERO
	for i in range(72):
		var a0: float = TAU * float(i) / 72.0
		var p0: Vector3 = _cliff_walk_point(center, a0)
		if not p0.is_finite():
			continue
		var p1: Vector3 = _cliff_walk_point(center, a0 + deg_to_rad(85.0))
		if not p1.is_finite():
			continue
		if bool(_pf.call("line_of_sight", p0, p1, 0.49)):
			continue  # 能直线过去，说明没被崖体挡住
		var path: PackedVector3Array = _pf.call("find_path", p0, p1)
		if path.is_empty():
			continue
		return [p0, p1]
	return []


## 从台地中心沿 ang 往外：先跨过台地顶（可走）→ 崖壁（不可走）→ 崖脚（可走），
## 返回崖脚外 2.5m 的走线点；地形不像台地就返回 INF。
func _cliff_walk_point(center: Vector3, ang: float) -> Vector3:
	var dir := Vector3(cos(ang), 0.0, sin(ang))
	var r: float = 18.0
	var saw_top := false
	var top_r := 0.0
	while r < 30.0:
		var p: Vector3 = center + dir * r
		if bool(_pf.call("is_walkable", p)):
			saw_top = true
			top_r = r
		elif saw_top:
			break
		r += 0.5
	if not saw_top or top_r > 29.0:
		return Vector3(INF, INF, INF)
	# 跨过崖壁/坡（不可走带）
	var cliff_r := r
	while r < 46.0 and not bool(_pf.call("is_walkable", center + dir * r)):
		r += 0.5
	if r >= 46.0 or r - cliff_r < 1.5:
		return Vector3(INF, INF, INF)
	var walk_r: float = r + 2.5
	var wp: Vector3 = center + dir * walk_r
	if not bool(_pf.call("is_walkable", wp)):
		return Vector3(INF, INF, INF)
	if not bool(_pf.call("is_standable", wp, 0.49)):
		return Vector3(INF, INF, INF)
	return wp


func _end_stage_cliff() -> void:
	if _agents.is_empty():
		_enter_stage(4)
		return
	var tw := 0
	var st := 0
	var tp := 0
	var arrive := 0
	var bad_cells := 0
	var max_rep := 0
	var min_edge := 99.0
	for a in _agents:
		var w: Array = _twitch_windows(a)
		var s: Array = _stall_windows(a)
		var p: Array = _teleports(a)
		var mm: Vector2 = _min_wall(a)
		var rep: int = int((a["node"] as Node3D).get("dbg_repath_count")) - int(a["rep0"])
		tw += w.size()
		st += s.size()
		tp += p.size()
		max_rep = maxi(max_rep, rep)
		min_edge = minf(min_edge, mm.y)
		var mine := 0
		for k in a["samples"]:
			if not bool(k["walk"]):
				mine += 1
		bad_cells += mine
		var ss: Array = a["samples"]
		var d := 99.0
		if ss.size() > 0:
			d = (ss[ss.size() - 1]["p"] as Vector2).distance_to(Vector2(a["target"].x, a["target"].z))
		if d <= 3.0:
			arrive += 1
		_rows.append("  %s 绕崖 %s（%.2fm）| 抽搐 %d | 卡死 %d | 瞬移 %d | 重算 %d 次 | 踩不可走格 %d 采样 | 最近边距 %.2f" % [
			String(a["label"]), ("到" if d <= 3.0 else "没到"), d, w.size(), s.size(), p.size(), rep,
			mine, mm.y])
	_rows.append("  · ④ 汇总：绕崖 %d/%d 到达，抽搐 %d 窗，卡死 %d 窗，瞬移 %d 次，最多重算 %d 次，不可走格采样 %d 个" % [
		arrive, _agents.size(), tw, st, tp, max_rep, bad_cells])
	_ok("④ 崖边绕行全部到达（≤3m）", arrive == _agents.size(), "%d/%d" % [arrive, _agents.size()])
	_ok("④ 崖边绕行：不踩不可走格（0 采样）", bad_cells == 0, "%d 个" % bad_cells)
	_ok("④ 崖边绕行：不反复切路（重算 ≤%d 次）" % CLIFF_MAX_REPATH, max_rep <= CLIFF_MAX_REPATH, "最多 %d 次" % max_rep)
	_ok("④ 崖边绕行：0 抽搐", tw == 0, "%d 窗" % tw)
	_ok("④ 崖边绕行：0 卡死", st == 0, "%d 窗" % st)
	_ok("④ 崖边绕行：0 瞬移", tp == 0, "%d 次" % tp)
	var nodes: Array = []
	for a in _agents:
		nodes.append(a["node"])
	_free_nodes(nodes)
	_agents = []
	_enter_stage(4)


# ===========================================================================
# ⑤ 12 人同一落点
# ===========================================================================
func _setup_crowd() -> void:
	var spot := _find_open_disk(_anchor + Vector3(0.0, 0.0, 46.0), int(CROWD_R) + 3)
	if not spot.is_finite():
		spot = _find_open_disk(_anchor, int(CROWD_R) + 3)
	if not spot.is_finite():
		_rows.append("  · ⑤ 跳过人群互挤（找不到半径 11m 的净空场）")
		_ok("⑤ 人群互挤：找到场地", false, "螺旋搜索失败")
		return
	var body_r: float = 0.5
	var dfoe: Object = _cfg.call("unit", FOOT)
	if dfoe != null:
		body_r = float(dfoe.get("body_radius"))
	for i in range(CROWD_N):
		var ang: float = TAU * float(i) / float(CROWD_N)
		var s: Vector3 = spot + Vector3(cos(ang), 0.0, sin(ang)) * CROWD_R
		var u: Node3D = _game.call("spawn_unit", _faction, FOOT, _level.call("walkable_pos", s), _level)
		if u == null:
			continue
		_agents.append(_make_agent(u, "P", "P%d" % i, spot, body_r))
		u.call("order_move", spot)
	_rows.append("  · ⑤ 人群：%d 兵从半径 %.0fm 的环上同时冲向同一点 (%.1f, %.1f)" % [
		_agents.size(), CROWD_R, spot.x, spot.z])


func _find_open_disk(center: Vector3, r: int) -> Vector3:
	var c0: Vector3 = _snap(center)
	for ring in range(0, 16):
		for dz in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) != ring:
					continue
				var c: Vector3 = _snap(c0 + Vector3(float(dx) * 4.0, 0.0, float(dz) * 4.0))
				var ok := true
				for k in range(24):
					var ang: float = TAU * float(k) / 24.0
					var p: Vector3 = c + Vector3(cos(ang), 0.0, sin(ang)) * float(r)
					if not bool(_pf.call("is_walkable", p)) or not bool(_pf.call("is_standable", p, 0.49)):
						ok = false
						break
				if ok and bool(_pf.call("is_standable", c, 0.49)):
					return c
	return Vector3(INF, INF, INF)


func _end_stage_crowd() -> void:
	if _agents.is_empty():
		_enter_stage(5)
		return
	var tw := 0
	var st := 0
	var tp := 0
	var settled := 0
	var max_d := 0.0
	var pts: Array = []
	var min_pair := 99.0
	for a in _agents:
		var w: Array = _twitch_windows(a)
		var s: Array = _stall_windows(a)
		var p: Array = _teleports(a)
		tw += w.size()
		st += s.size()
		tp += p.size()
		var u: Node3D = a["node"]
		if u != null and is_instance_valid(u) and int(u.get("order")) != ORDER_MOVE:
			settled += 1
		var ss: Array = a["samples"]
		if ss.size() > 0:
			var lp: Vector2 = ss[ss.size() - 1]["p"]
			pts.append(lp)
			max_d = maxf(max_d, lp.distance_to(Vector2(a["target"].x, a["target"].z)))
	for i in range(pts.size()):
		for j in range(i + 1, pts.size()):
			min_pair = minf(min_pair, (pts[i] as Vector2).distance_to(pts[j]))
	_rows.append("  · ⑤ 汇总：%d/%d 站定，抽搐 %d 窗，卡死 %d 窗，瞬移 %d 次，两两最近 %.2fm，最远距目标 %.2fm" % [
		settled, _agents.size(), tw, st, tp, min_pair, max_d])
	_ok("⑤ 12 人同一落点全部站定", settled == _agents.size(), "%d/%d" % [settled, _agents.size()])
	_ok("⑤ 12 人同一落点：两两 ≥%.1fm" % CROWD_MIN_PAIR, min_pair >= CROWD_MIN_PAIR or pts.size() < 2, "最近 %.2fm" % min_pair)
	_ok("⑤ 12 人同一落点：0 抽搐窗", tw == 0, "%d 窗" % tw)
	_ok("⑤ 12 人同一落点：0 卡死窗", st == 0, "%d 窗" % st)
	_ok("⑤ 12 人同一落点：0 瞬移", tp == 0, "%d 次" % tp)
	_ok("⑤ 12 人同一落点：不跑飞（最远 ≤%.1fm）" % CROWD_MAX_DIST, max_d <= CROWD_MAX_DIST, "最远 %.2fm" % max_d)
	# 全程兜底吸附计数（静态累加，覆盖 ①~⑤ 所有单位）
	var snaps := 0
	for a in _agents:
		var u2: Node3D = a["node"]
		if u2 != null and is_instance_valid(u2):
			snaps = maxi(snaps, int(u2.call("debug_move_stats").get("snap_fallbacks")))
	_ok("⑤ 全程 0 次兜底吸附（多帧无解的 snap 为 0）", snaps == 0, "%d 次" % snaps)
	var nodes: Array = []
	for a in _agents:
		nodes.append(a["node"])
	_free_nodes(nodes)
	_agents = []
	_enter_stage(5)


# ===========================================================================
# 采样
# ===========================================================================
func _sample_all() -> void:
	for a in _agents:
		var u: Node3D = a["node"]
		if u == null or not is_instance_valid(u):
			continue
		var p: Vector3 = u.global_position
		var path: PackedVector3Array = u.get("_path")
		var sig := "%d/%d" % [path.size(), int(u.get("_path_i"))]
		if path.size() > 0:
			var last: Vector3 = path[path.size() - 1]
			sig += "|%.2f,%.2f" % [last.x, last.z]
		if sig != String(a["path_sig"]):
			a["path_sig"] = sig
			a["path_changes"] = int(a["path_changes"]) + 1
		var wd: Vector2 = _wall_dist(p)
		var samples: Array = a["samples"]
		samples.append({
			"t": _sim_t, "p": Vector2(p.x, p.z), "order": int(u.get("order")),
			"speed": float(u.get("_speed")), "wc": wd.x, "we": wd.y,
			"walk": bool(_pf.call("is_walkable", p)),
		})
		# 首次“订单不再是 MOVE”的时刻 = 到达时刻
		if float(a["arrive_t"]) < 0.0 and int(u.get("order")) != ORDER_MOVE and _sim_t > 0.5:
			a["arrive_t"] = _sim_t


## 到"最近的不可走格"的两个距离：
##   x = 单位中心 → 格子中心（任务书原文口径）
##   y = 单位中心 → 格子矩形边缘（真正的身体净空，矩形 = 格子 ±0.5m）
## 只扫 3×3 邻域：再远的格子对"贴不贴墙"没有意义（≥2m）。
func _wall_dist(p: Vector3) -> Vector2:
	var c: Vector2i = _pf.call("world_to_cell", p)
	var best_c := 99.0
	var best_e := 99.0
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var cc := Vector2i(c.x + dx, c.y + dz)
			if bool(_pf.call("is_cell_walkable", cc)):
				continue
			if not bool(_pf.call("in_bounds", cc)):
				continue
			var w: Vector3 = _pf.call("cell_to_world", cc)
			var ddx: float = absf(p.x - w.x)
			var ddz: float = absf(p.z - w.z)
			best_c = minf(best_c, sqrt(ddx * ddx + ddz * ddz))
			var ex: float = maxf(ddx - 0.5, 0.0)
			var ez: float = maxf(ddz - 0.5, 0.0)
			best_e = minf(best_e, sqrt(ex * ex + ez * ez))
	return Vector2(best_c, best_e)


func _min_wall(a: Dictionary) -> Vector2:
	var wc := 99.0
	var we := 99.0
	for k in a["samples"]:
		wc = minf(wc, float(k["wc"]))
		we = minf(we, float(k["we"]))
	return Vector2(wc, we)


# ===========================================================================
# 统计
# ===========================================================================
## 抽搐窗口：0.5s 内方向反转 ≥3 次 且 窗口净位移 <0.15m
func _twitch_windows(a: Dictionary) -> Array:
	var s: Array = a["samples"]
	var out: Array = []
	var n: int = s.size()
	var win: int = int(round(TWITCH_WINDOW / SAMPLE_DT))
	for i in range(1, n - win):
		var rev: int = 0
		var pv := Vector2.ZERO
		for k in range(i, i + win + 1):
			var p0: Vector2 = s[k - 1]["p"]
			var p1: Vector2 = s[k]["p"]
			var v := p1 - p0
			if v.length() > 0.02 and pv.length() > 0.02 and v.dot(pv) < 0.0:
				rev += 1
			pv = v
		if rev < TWITCH_REV:
			continue
		var disp: float = (s[i + win]["p"] as Vector2).distance_to(s[i]["p"])
		if disp < TWITCH_DISP:
			out.append({"t": float(s[i]["t"]), "rev": rev, "disp": disp})
	return out


## 卡死窗口：1.5s 内订单一直是 MOVE，净位移 <0.06m
func _stall_windows(a: Dictionary) -> Array:
	var s: Array = a["samples"]
	var out: Array = []
	var n: int = s.size()
	var win: int = int(round(STALL_TIME / SAMPLE_DT))
	for i in range(0, n - win):
		var all_move := true
		for k in range(i, i + win + 1):
			if int(s[k]["order"]) != ORDER_MOVE:
				all_move = false
				break
		if not all_move:
			continue
		var disp: float = (s[i + win]["p"] as Vector2).distance_to(s[i]["p"])
		if disp < STALL_DISP:
			out.append({"t": float(s[i]["t"]), "disp": disp})
	return out


## 瞬移：单采样位移超过正常上限（= 被 snap/teleport 过）
func _teleports(a: Dictionary) -> Array:
	var s: Array = a["samples"]
	var out: Array = []
	for i in range(1, s.size()):
		var d: float = (s[i]["p"] as Vector2).distance_to(s[i - 1]["p"])
		if d > TELEPORT_STEP:
			out.append({"t": float(s[i]["t"]), "d": d})
	return out


## 到点后（订单第一次不是 MOVE 之后）还有没有残留抖动
func _after_arrive_max_step(a: Dictionary) -> float:
	var s: Array = a["samples"]
	var idx: int = -1
	for i in range(s.size()):
		if int(s[i]["order"]) != ORDER_MOVE:
			idx = i
			break
	if idx < 0:
		return 0.0
	var win: int = int(round(AFTER_ARRIVE_SEC / SAMPLE_DT))
	var mx := 0.0
	for i in range(idx + 1, mini(s.size(), idx + win)):
		mx = maxf(mx, (s[i]["p"] as Vector2).distance_to(s[i - 1]["p"]))
	return mx


# ===========================================================================
# 汇总
# ===========================================================================
func _finish() -> void:
	if _done:
		return
	_done = true
	print("-------------------------------")
	for r in _rows:
		print(r)
	print("-------------------------------")
	for ln in _lines:
		print(ln)
	print("结果：通过 %d / 失败 %d  —— %s" % [_pass, _fail, "全部通过 ✓" if _fail == 0 else "有失败 ✗"])
	quit(0 if _fail == 0 else 1)


func _min_pair(pts: Array) -> float:
	var best := 99.0
	for i in range(pts.size()):
		for j in range(i + 1, pts.size()):
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[j]
			best = minf(best, sqrt((a.x - b.x) * (a.x - b.x) + (a.z - b.z) * (a.z - b.z)))
	return best


## 量化到 0.05m 去重（旧算法会把多个格夹到同一格心）
func _unique_count(pts: Array) -> int:
	var seen: Dictionary = {}
	for p in pts:
		var q: Vector3 = p
		seen["%d,%d" % [roundi(q.x * 20.0), roundi(q.z * 20.0)]] = true
	return seen.size()


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		_lines.append("  ✓ %s %s" % [name, detail])
	else:
		_fail += 1
		_lines.append("  ✗ %s %s" % [name, detail])
