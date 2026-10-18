class_name RtsMoveIndicator
extends Node3D
## **移动指示**：给"走位类指令"画一条贴地的绿色虚线，终点打一个脉动圆环 + 十字准星。
##
## 职责：
##   - 订阅 Game.order_issued，**只**对 MOVE / ATTACK_MOVE / RETURN_RES 画线；
##   - 每帧刷新每条线的起点（单位在走，线就跟着挪），终点钉死在这趟指令的真实落点；
##   - 单位到达 / 死亡 / 被别的指令覆盖 → 0.2s 内淡出，绝不硬切。
##
## 为什么这么拆：
##   - 它是纯**观察者**：不碰指令系统、不碰单位脚本，只读单位的 global_position 与
##     move_target，拿不到就退回信号里的落点；可能还没实现的接口一律 has_method 兜底。
##     指令系统以后怎么改，都不会把它带崩。
##   - 几何只有 **2 个 ImmediateMesh**（线一份、环一份），节点数恒定；每帧只
##     clear + 重填顶点，**绝不新建节点**；顶点数有硬上限（见 MAX_SAMPLES / MAX_TRACKS）。
##   - 换目标时旧线不当场消失，而是降级成 0.2s 的"幽灵旧线"淡出，新线同时接上 ——
##     这就是"被新指令覆盖也要淡出、不许硬切"的做法。
##   - 贴地不是"空中拉一条直线"：沿线按 ~0.5m 采样 关卡.height_at() 逐点取高度，
##     再抬高 0.05m（足够压住坡度带来的边缘误差与 z-fighting）；关卡接口不在就退到
##     0.03 的平地高度，绝不悬空。
##
## 对外接口：
##   has_tracked() -> bool        现在有没有线在画（自检 / 演出判断用）
##   tracked_count() -> int       正在跟踪的单位条数
##   clear_all(instant := false)  立刻清空，或让它们 0.2s 内淡出

# ===========================================================================
# 常量（调手感只改这一块）
# ===========================================================================
## 同时画线的单位上限（一次多选最多 12 条，任务书指定）
const MAX_LINES: int = 12
## 跟踪表硬上限：活跃线 + 换目标后 0.2s 内的"幽灵旧线"都算在内
const MAX_TRACKS: int = 20
## 目的地圆环上限（同屏别糊满；超了顶掉最老的一个）
const MAX_RINGS: int = 6
## 淡出时长（秒）：任务书 0.15~0.25，取中值，够肉又不拖
const FADE_TIME: float = 0.2
## 贴地抬高（米）：盖住横坡上 0.2m 线宽带来的边缘误差 + z-fighting，又不至于看着"浮起来"
const GROUND_LIFT: float = 0.05
## 拿不到地形接口时的地板高度（米）
const FALLBACK_GROUND: float = 0.03
## 判定"已经走到"的水平距离（米）
const ARRIVE_DIST: float = 1.2
## 判定"已经停住"的速度阈值（米/秒）
const STOP_SPEED: float = 0.18
## 虚线带宽度（米）：任务书 0.12~0.22，取上限（亮芯约 0.12m、外圈辉光铺满 0.22m）
const LINE_WIDTH: float = 0.22
## 沿线采样步长（米）：越小越贴地形，顶点越多
const SAMPLE_STEP: float = 0.5
## 一条线最多采样点数（顶点上限就靠它：每段 2 个三角 = 6 个顶点）
const MAX_SAMPLES: int = 34
## 虚线周期自适应：一条线大致切成多少个周期
const DASH_TARGET_COUNT: float = 12.0
## 虚线周期下限（米）：太短会像跑马灯
const DASH_PERIOD_MIN: float = 0.85
## 虚线周期上限（米）：太长会像"断掉的线"
const DASH_PERIOD_MAX: float = 1.85
## 目的地圆环半径（米）
const RING_RADIUS: float = 0.95
## 圆环环带宽度（米）
const RING_BAND: float = 0.13
## 圆环分段数
const RING_SEGS: int = 28
## 圆环上贴多少个"虚线刻度"（喂给着色器的 UV.x）
const RING_TICKS: float = 16.0
## 拥挤判定半径（米）：两条线起点或终点挨这么近，就算叠在一起
const CROWD_RADIUS: float = 2.2
## 单条线的基础不透明度（顶点色 alpha，实际还要乘拥挤系数与淡出系数）
const BASE_ALPHA: float = 0.95
## 颜色：魔兽感亮绿 #3DFF72
const DASH_COLOR: Color = Color(0.239, 1.0, 0.447, 1.0)
## 着色器路径（独立 .gdshader 文件，绝不内联）
const SHADER_PATH: String = "res://美术/着色器/移动指示.gdshader"

# ===========================================================================
# 几何（一次建好，永远复用；每帧只重填顶点）
# ===========================================================================
var _line_mi: MeshInstance3D = null
var _ring_mi: MeshInstance3D = null
var _line_mesh: ImmediateMesh = null
var _ring_mesh: ImmediateMesh = null
var _line_mat: Material = null
var _ring_mat: Material = null
## 线 / 环当前有没有几何（空的时候别白 clear 一遍）
var _has_line_geo: bool = false
var _has_ring_geo: bool = false

# ===========================================================================
# 跟踪表
# ===========================================================================
## 每条虚线：{unit, dest, prev, speed, fade, fading, group, crowd, alpha}
var _lines: Array = []
## 每个目的地标记：{pos, fade, fading, group, phase, age}
var _rings: Array = []
## 指令分组号：一次移动指令 = 一组 = 一个目的地标记
var _next_group: int = 1

# ===========================================================================
# 关卡高度接口缓存（避免每个采样点都 has_method 一次）
# ===========================================================================
var _lv: Node3D = null
var _lv_has_height: bool = false

# ===========================================================================
# 全局淡出（游戏结束时整层收掉，别在胜负遮罩下面留一排绿线）
# ===========================================================================
var _time: float = 0.0
var _master_fade: float = 1.0
var _master_target: float = 1.0


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	name = "移动指示"
	_build_visual()
	# 只订阅全局信号：指令系统 / 单位脚本一行都不用改
	Game.order_issued.connect(_on_order_issued)
	Game.game_over.connect(_on_game_over)


func _exit_tree() -> void:
	# 主动断开网格引用：脚本比渲染服务晚析构，留着会刷
	# "resources still in use at exit"（本项目一直在躲的引擎提示）
	if _line_mi != null and is_instance_valid(_line_mi):
		_line_mi.mesh = null
	if _ring_mi != null and is_instance_valid(_ring_mi):
		_ring_mi.mesh = null
	_line_mesh = null
	_ring_mesh = null
	_line_mat = null
	_ring_mat = null
	_lines.clear()
	_rings.clear()


func _process(delta: float) -> void:
	_time += delta
	_refresh_level()
	_tick_lines(delta)
	_tick_rings(delta)
	_rebuild_lines()
	_rebuild_rings()
	_tick_master_fade(delta)


# ===========================================================================
# 对外接口
# ===========================================================================

## 现在有没有线在画
func has_tracked() -> bool:
	return not _lines.is_empty()


## 正在跟踪的单位条数
func tracked_count() -> int:
	return _lines.size()


## 清空全部指示：instant=false 时走 0.2s 淡出
func clear_all(instant: bool = false) -> void:
	if instant:
		_lines.clear()
		_rings.clear()
		return
	for e in _lines:
		e["fading"] = true
	for r in _rings:
		r["fading"] = true


# ===========================================================================
# 信号：只在这里"收活"，绝不去改指令系统
# ===========================================================================

## 收到一条指令：走位类就画线，别的就把相关单位的线淡出
func _on_order_issued(units: Array, order: int, target_pos: Vector3, target: Node3D) -> void:
	if units.is_empty():
		return
	if not _is_move_order(order):
		_cancel_units(units)
		return

	var group: int = _next_group
	_next_group += 1
	var made: int = 0
	var last_dest: Vector3 = target_pos
	for u in units:
		if made >= MAX_LINES:
			break
		if not _unit_can_track(u):
			continue
		var node := u as Node3D
		var dest: Vector3 = _dest_for(node, target_pos)
		last_dest = _track(node, dest, group)
		made += 1
	if made <= 0:
		return

	# 目的地标记：单单位就钉在线终点上（严丝合缝）；多选就摆在指令落点当"集结区"
	var anchor: Vector3 = last_dest
	if made != 1:
		anchor = target_pos
		if target != null and is_instance_valid(target):
			anchor = (target as Node3D).global_position
	_add_ring(anchor, group)


func _on_game_over(_victory: bool) -> void:
	# 整层淡出，别在胜负遮罩底下还留一排绿线
	_master_target = 0.0
	clear_all(false)


## 这些指令才配画走位线（攻击 / 采集 / 建造 / 施法 / 停止 / 保持都不画）
func _is_move_order(order: int) -> bool:
	return (order == RtsConst.Order.MOVE
		or order == RtsConst.Order.ATTACK_MOVE
		or order == RtsConst.Order.RETURN_RES)


# ===========================================================================
# 跟踪：增 / 改 / 取消
# ===========================================================================

## 登记一条线。
## 同一单位已经有线时：
##   · 目的地没变（点了同一个点）→ 原地刷新 + 改挂到新组，不制造影子线；
##   · 目的地变了 → 旧线降级成"幽灵"淡出，新线立刻接上（0.2s 的心手交替）。
func _track(u: Node3D, dest: Vector3, group: int) -> Vector3:
	var pos: Vector3 = u.global_position
	var active: Dictionary = {}
	for e in _lines:
		var raw: Variant = e["unit"]
		if not is_instance_valid(raw) or raw != u:
			continue
		if bool(e["fading"]):
			continue
		active = e
		break
	if not active.is_empty():
		var old_dest: Vector3 = active["dest"]
		if _flat(old_dest, dest) <= 0.5:
			active["prev"] = pos
			active["speed"] = 0.0
			active["fade"] = 1.0
			active["fading"] = false
			active["group"] = group
			active["alpha"] = BASE_ALPHA
			return dest
		active["fading"] = true
	_prune_tracks()
	_lines.append({
		"unit": u,
		"dest": dest,
		"prev": pos,
		"speed": 0.0,
		"fade": 1.0,
		"fading": false,
		"group": group,
		"crowd": 0.0,
		"alpha": BASE_ALPHA,
	})
	return dest


## 跟踪表到顶了：先踢掉已经在淡出的旧线，实在没有就踢最老的那条
func _prune_tracks() -> void:
	if _lines.size() < MAX_TRACKS:
		return
	for i in _lines.size():
		if bool(_lines[i]["fading"]):
			_lines.remove_at(i)
			return
	_lines.remove_at(0)


## 这些单位被"非走位指令"覆盖了 → 它们的线淡出
func _cancel_units(units: Array) -> void:
	if _lines.is_empty():
		return
	for e in _lines:
		var raw: Variant = e["unit"]
		if not is_instance_valid(raw):
			continue
		for u in units:
			if raw == u:
				e["fading"] = true
				break


## 这个单位这趟到底走去哪：优先 move_target（编队分点），否则退回指令落点
func _dest_for(u: Node3D, fallback: Vector3) -> Vector3:
	var mv: Variant = u.get("move_target")
	if mv is Vector3:
		var p: Vector3 = mv
		var dx: float = p.x - u.global_position.x
		var dz: float = p.z - u.global_position.z
		# 离自己太近 = 没设过（默认 Vector3.ZERO），此时用指令落点更靠谱
		if dx * dx + dz * dz > 0.25:
			return p
	return fallback


# ===========================================================================
# 每帧推进：到达 / 死亡 / 覆盖 → 淡出
# ===========================================================================

func _tick_lines(delta: float) -> void:
	if _lines.is_empty():
		return
	var dt: float = maxf(delta, 0.0001)
	for i in range(_lines.size() - 1, -1, -1):
		var e: Dictionary = _lines[i]
		var raw: Variant = e["unit"]
		if not is_instance_valid(raw) or not (raw is Node3D):
			e["fading"] = true
		else:
			var u: Node3D = raw
			if not _unit_alive(u):
				e["fading"] = true
			elif not bool(e["fading"]):
				var pos: Vector3 = u.global_position
				var prev: Vector3 = e["prev"]
				var dx: float = pos.x - prev.x
				var dz: float = pos.z - prev.z
				# 瞬时速度平滑一下：单位分离/脱困会瞬移几厘米，别让线误判成"停了"
				var spd: float = sqrt(dx * dx + dz * dz) / dt
				e["speed"] = lerpf(float(e["speed"]), spd, 0.35)
				e["prev"] = pos
				var dest: Vector3 = e["dest"]
				var flat: float = Vector2(pos.x - dest.x, pos.z - dest.z).length()
				if flat <= ARRIVE_DIST:
					e["fading"] = true
				elif _unit_idle(u) and float(e["speed"]) < STOP_SPEED:
					e["fading"] = true
		if bool(e["fading"]):
			e["fade"] = float(e["fade"]) - delta / maxf(FADE_TIME, 0.01)
			if float(e["fade"]) <= 0.0:
				_lines.remove_at(i)


func _tick_rings(delta: float) -> void:
	if _rings.is_empty():
		return
	for i in range(_rings.size() - 1, -1, -1):
		var r: Dictionary = _rings[i]
		r["age"] = float(r["age"]) + delta
		if not bool(r["fading"]) and not _group_has_live_line(int(r["group"])):
			r["fading"] = true
		if bool(r["fading"]):
			r["fade"] = float(r["fade"]) - delta / maxf(FADE_TIME, 0.01)
			if float(r["fade"]) <= 0.0:
				_rings.remove_at(i)


## 这一组还有没有"仍在走"的线（全组都开始淡出了，标记才跟着淡出）
func _group_has_live_line(group: int) -> bool:
	for e in _lines:
		if int(e["group"]) == group and not bool(e["fading"]):
			return true
	return false


func _tick_master_fade(delta: float) -> void:
	if is_equal_approx(_master_fade, _master_target):
		return
	_master_fade = move_toward(_master_fade, _master_target, delta / maxf(FADE_TIME, 0.01))
	_push_fade_uniform()
	if _master_fade <= 0.001 and _master_target <= 0.001:
		clear_all(true)


func _push_fade_uniform() -> void:
	if _line_mat is ShaderMaterial:
		(_line_mat as ShaderMaterial).set_shader_parameter("fade", _master_fade)
	if _ring_mat is ShaderMaterial:
		(_ring_mat as ShaderMaterial).set_shader_parameter("fade", _master_fade)


# ===========================================================================
# 拥挤：多条线叠在一起时压暗，绝不许糊成一坨白
# ===========================================================================

func _apply_crowd() -> void:
	var n: int = _lines.size()
	for i in n:
		_lines[i]["crowd"] = 0.0
	for i in n:
		var a: Dictionary = _lines[i]
		for j in range(i + 1, n):
			var b: Dictionary = _lines[j]
			var d_start: float = _flat(a["prev"], b["prev"])
			var d_end: float = _flat(a["dest"], b["dest"])
			var d: float = minf(d_start, d_end)
			if d < CROWD_RADIUS:
				var w: float = 1.0 - d / CROWD_RADIUS
				a["crowd"] = float(a["crowd"]) + w
				b["crowd"] = float(b["crowd"]) + w
	# 挤得越狠越透：最多压到 46%，既看得清每一条，又不刺眼
	for e in _lines:
		var c: float = float(e["crowd"])
		e["alpha"] = BASE_ALPHA * clampf(1.0 - 0.09 * c, 0.46, 1.0) * _ease01(float(e["fade"]))


# ===========================================================================
# 几何：线
# ===========================================================================

func _rebuild_lines() -> void:
	if _line_mesh == null:
		return
	# 先算拥挤度再判断"能不能画"：两者用的必须是同一个 alpha，
	# 否则会出现"判断能画、却一个顶点都没进"的空 surface（引擎会报错）
	_apply_crowd()
	if _lines.is_empty() or not _any_line_drawable():
		if _has_line_geo:
			_line_mesh.clear_surfaces()
			_has_line_geo = false
		if _line_mi != null:
			_line_mi.visible = false
		return
	var inv: Transform3D = global_transform.affine_inverse()
	_line_mesh.clear_surfaces()
	_line_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for e in _lines:
		_emit_line(e, inv)
	_line_mesh.surface_end()
	_has_line_geo = true
	if _line_mi != null:
		_line_mi.visible = true


func _any_line_drawable() -> bool:
	for e in _lines:
		# 门槛和 _emit_line 完全一致（alpha > 0.01 且距离 > 0.10）：
		# 判断"能画"就一定能画出顶点，绝不留下空 surface
		if float(e["alpha"]) <= 0.01:
			continue
		var raw: Variant = e["unit"]
		if not is_instance_valid(raw) or not (raw is Node3D):
			continue
		var u: Node3D = raw
		if _flat(u.global_position, e["dest"]) <= 0.10:
			continue
		return true
	return false


## 把一条线拼成贴地带子（每段 6 个顶点；ImmediateMesh 没有索引缓冲，只能重复顶点）
func _emit_line(e: Dictionary, inv: Transform3D) -> void:
	var raw: Variant = e["unit"]
	if not is_instance_valid(raw) or not (raw is Node3D):
		return
	var alpha: float = float(e["alpha"])
	if alpha <= 0.01:
		return
	var u: Node3D = raw
	var from: Vector3 = u.global_position
	var dest: Vector3 = e["dest"]
	var dx: float = dest.x - from.x
	var dz: float = dest.z - from.z
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist < 0.10:
		return

	# 采样点数与虚线周期都随距离自适应：短线密、长线疏，绝不糊成密条纹
	var count: int = clampi(int(ceil(dist / SAMPLE_STEP)) + 1, 2, MAX_SAMPLES)
	var period: float = clampf(dist / DASH_TARGET_COUNT, DASH_PERIOD_MIN, DASH_PERIOD_MAX)
	# 水平面内的法向：线宽就沿这个方向摊开
	var nx: float = -dz / dist
	var nz: float = dx / dist
	var half: float = LINE_WIDTH * 0.5
	var uv2 := Vector2(0.0, 0.0)
	var prev_a: Vector3 = Vector3.ZERO
	var prev_b: Vector3 = Vector3.ZERO
	var prev_u: float = 0.0
	var prev_c: Color = Color.WHITE
	for i in count:
		var t: float = float(i) / float(count - 1)
		var wx: float = from.x + dx * t
		var wz: float = from.z + dz * t
		var wy: float = _ground_y(wx, wz)
		var arc: float = dist * t
		# 起点收窄 + 淡入：线从脚底"长"出来，不糊在单位身上
		var widen: float = clampf(arc / 0.9, 0.35, 1.0)
		var a_col: Color = Color(1.0, 1.0, 1.0, alpha * clampf(arc / 0.7, 0.0, 1.0))
		var ux: float = arc / period
		var a := Vector3(wx + nx * half * widen, wy, wz + nz * half * widen)
		var b := Vector3(wx - nx * half * widen, wy, wz - nz * half * widen)
		if i > 0:
			_put(_line_mesh, prev_a, Vector2(prev_u, 0.0), uv2, prev_c, inv)
			_put(_line_mesh, prev_b, Vector2(prev_u, 1.0), uv2, prev_c, inv)
			_put(_line_mesh, b, Vector2(ux, 1.0), uv2, a_col, inv)
			_put(_line_mesh, prev_a, Vector2(prev_u, 0.0), uv2, prev_c, inv)
			_put(_line_mesh, b, Vector2(ux, 1.0), uv2, a_col, inv)
			_put(_line_mesh, a, Vector2(ux, 0.0), uv2, a_col, inv)
		prev_a = a
		prev_b = b
		prev_u = ux
		prev_c = a_col


# ===========================================================================
# 几何：目的地圆环 + 十字准星
# ===========================================================================

func _add_ring(pos: Vector3, group: int) -> void:
	# 同一组只留一个标记（重下指令时旧的直接丢，线已经改挂到新组了）
	for i in range(_rings.size() - 1, -1, -1):
		if int(_rings[i]["group"]) == group:
			_rings.remove_at(i)
	if _rings.size() >= MAX_RINGS:
		_rings.pop_front()
	_rings.append({
		"pos": pos,
		"fade": 1.0,
		"fading": false,
		"group": group,
		"phase": float(group) * 0.37,
		"age": 0.0,
	})


func _rebuild_rings() -> void:
	if _ring_mesh == null:
		return
	if _rings.is_empty() or not _any_ring_drawable():
		if _has_ring_geo:
			_ring_mesh.clear_surfaces()
			_has_ring_geo = false
		if _ring_mi != null:
			_ring_mi.visible = false
		return
	var inv: Transform3D = global_transform.affine_inverse()
	_ring_mesh.clear_surfaces()
	_ring_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in _rings:
		_emit_ring(r, inv)
	_ring_mesh.surface_end()
	_has_ring_geo = true
	if _ring_mi != null:
		_ring_mi.visible = true


func _any_ring_drawable() -> bool:
	if _master_fade <= 0.01:
		return false
	for r in _rings:
		# 同 _emit_ring 的门槛：淡到看不见就别 begin 一个空 surface
		if _ease01(float(r["fade"])) * _master_fade > 0.01:
			return true
	return false


## 一个目的地标记：脉动圆环（转动的刻度）+ 4 道十字准星（恒亮，不吃虚线相位）
func _emit_ring(r: Dictionary, inv: Transform3D) -> void:
	var fade: float = _ease01(float(r["fade"])) * _master_fade
	if fade <= 0.01:
		return
	var pos: Vector3 = r["pos"]
	var phase: float = float(r["phase"])
	# 轻微脉动：半径 ±4.5%，和着色器的亮度脉冲错开相位，读起来是"活的"而不是闪烁
	var pulse: float = 1.0 + 0.045 * sin(_time * 2.2 + phase * TAU)
	var outer: float = RING_RADIUS * pulse
	var inner: float = maxf(outer - RING_BAND, 0.05)
	var col := Color(1.0, 1.0, 1.0, fade * 0.95)
	var uv2 := Vector2(0.0, phase)

	for i in RING_SEGS:
		var a0: float = TAU * float(i) / float(RING_SEGS)
		var a1: float = TAU * float(i + 1) / float(RING_SEGS)
		var u0: float = RING_TICKS * float(i) / float(RING_SEGS)
		var u1: float = RING_TICKS * float(i + 1) / float(RING_SEGS)
		var d0 := Vector2(cos(a0), sin(a0))
		var d1 := Vector2(cos(a1), sin(a1))
		var p00: Vector3 = _ring_pt(pos, d0.x, d0.y, inner)
		var p01: Vector3 = _ring_pt(pos, d1.x, d1.y, inner)
		var p10: Vector3 = _ring_pt(pos, d0.x, d0.y, outer)
		var p11: Vector3 = _ring_pt(pos, d1.x, d1.y, outer)
		_put(_ring_mesh, p00, Vector2(u0, 0.0), uv2, col, inv)
		_put(_ring_mesh, p01, Vector2(u1, 0.0), uv2, col, inv)
		_put(_ring_mesh, p11, Vector2(u1, 1.0), uv2, col, inv)
		_put(_ring_mesh, p00, Vector2(u0, 0.0), uv2, col, inv)
		_put(_ring_mesh, p11, Vector2(u1, 1.0), uv2, col, inv)
		_put(_ring_mesh, p10, Vector2(u0, 1.0), uv2, col, inv)

	# 十字准星：4 个正方向各一道短刻度。UV2.x = 1 → 着色器跳过虚线，永远亮着
	var tick_uv2 := Vector2(1.0, phase)
	var t_col := Color(1.0, 1.0, 1.0, fade)
	for k in 4:
		var ang: float = TAU * float(k) / 4.0
		var dir := Vector2(cos(ang), sin(ang))
		var perp := Vector2(-dir.y, dir.x)
		var r0: float = maxf(inner * 0.55, 0.12)
		var r1: float = outer + 0.11
		var w: float = 0.055
		var c0: Vector3 = _ring_pt(pos, dir.x, dir.y, r0)
		var c1: Vector3 = _ring_pt(pos, dir.x, dir.y, r1)
		var o0 := Vector3(perp.x, 0.0, perp.y) * w
		_put(_ring_mesh, c0 - o0, Vector2(0.0, 0.0), tick_uv2, t_col, inv)
		_put(_ring_mesh, c0 + o0, Vector2(0.0, 1.0), tick_uv2, t_col, inv)
		_put(_ring_mesh, c1 + o0, Vector2(1.0, 1.0), tick_uv2, t_col, inv)
		_put(_ring_mesh, c0 - o0, Vector2(0.0, 0.0), tick_uv2, t_col, inv)
		_put(_ring_mesh, c1 + o0, Vector2(1.0, 1.0), tick_uv2, t_col, inv)
		_put(_ring_mesh, c1 - o0, Vector2(1.0, 0.0), tick_uv2, t_col, inv)


## 圆环上的一点（贴地 + 抬高）
func _ring_pt(center: Vector3, dir_x: float, dir_z: float, radius: float) -> Vector3:
	var x: float = center.x + dir_x * radius
	var z: float = center.z + dir_z * radius
	return Vector3(x, _ground_y(x, z), z)


# ===========================================================================
# 底层工具
# ===========================================================================

## 往 ImmediateMesh 里丢一个顶点（颜色/UV 状态是"给后续顶点用"的，所以每次都重设）
func _put(mesh: ImmediateMesh, world: Vector3, uv: Vector2, uv2: Vector2,
		col: Color, inv: Transform3D) -> void:
	mesh.surface_set_color(col)
	mesh.surface_set_uv(uv)
	mesh.surface_set_uv2(uv2)
	mesh.surface_add_vertex(inv * world)


## 地面高度：关卡有 height_at 就用它，没有就退到 0.03 的平地高度（绝不悬空）
func _ground_y(x: float, z: float) -> float:
	if _lv != null and _lv_has_height:
		return float(_lv.call("height_at", x, z)) + GROUND_LIFT
	return FALLBACK_GROUND


## 每帧只查一次关卡引用：接口存在性也跟着缓存，别让每个采样点都 has_method
func _refresh_level() -> void:
	var n: Node3D = Game.level
	if n != null and not is_instance_valid(n):
		n = null
	if n == _lv:
		return
	_lv = n
	_lv_has_height = n != null and n.has_method("height_at")


func _flat(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return sqrt(dx * dx + dz * dz)


## 0→1 平滑（淡出用它，线性淡出会看出"一刀一刀"）
func _ease01(x: float) -> float:
	var t: float = clampf(x, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## 单位还在不在
func _unit_alive(u: Node3D) -> bool:
	if u == null or not is_instance_valid(u):
		return false
	if u.has_method("is_alive"):
		return bool(u.call("is_alive"))
	return true


## 单位是不是"闲下来了"（没有走位指令）
func _unit_idle(u: Node3D) -> bool:
	if u.has_method("is_idle_like"):
		return bool(u.call("is_idle_like"))
	# 兜底：老单位脚本没有 is_idle_like，就读 order 字段
	var o: Variant = u.get("order")
	if o == null:
		return true
	return int(o) == RtsConst.Order.NONE


## 这个单位值不值得画线：活着 + 会走（建筑不许画，老脚本没 is_mobile 就放行）
func _unit_can_track(u: Variant) -> bool:
	if not (u is Node3D) or not is_instance_valid(u):
		return false
	var n: Node3D = u
	if not _unit_alive(n):
		return false
	if n.has_method("is_mobile") and not bool(n.call("is_mobile")):
		return false
	return true


# ===========================================================================
# 建节点 / 建材质（只在这里 new，之后一辈子复用）
# ===========================================================================

## 建两个恒定的绘制层（虚线一份 / 标记一份），之后只重填顶点，不再 new 节点
func _build_visual() -> void:
	_line_mesh = ImmediateMesh.new()
	_ring_mesh = ImmediateMesh.new()
	_line_mat = _make_material(false)
	_ring_mat = _make_material(true)
	_line_mi = _make_layer("移动虚线", _line_mesh, _line_mat)
	_ring_mi = _make_layer("目的地标记", _ring_mesh, _ring_mat)


func _make_layer(node_name: String, mesh: ImmediateMesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	add_child(mi)
	return mi


## 建材质：优先用独立着色器；着色器缺失就退化成"实线绿带"（绝不崩、绝不内联 shader）
func _make_material(is_ring: bool) -> Material:
	var sh: Shader = null
	if ResourceLoader.exists(SHADER_PATH):
		sh = load(SHADER_PATH) as Shader
	if sh == null:
		return _make_fallback_material()
	var m := ShaderMaterial.new()
	m.shader = sh
	m.render_priority = 1
	m.set_shader_parameter("dash_color", DASH_COLOR)
	m.set_shader_parameter("dash_scale", 1.0)
	m.set_shader_parameter("fade", 1.0)
	if is_ring:
		m.set_shader_parameter("scroll_speed", 0.30)
		m.set_shader_parameter("dash_duty", 0.70)
		m.set_shader_parameter("dash_soft", 0.07)
		m.set_shader_parameter("edge_soft", 0.88)
		m.set_shader_parameter("core_power", 1.15)
		m.set_shader_parameter("halo_power", 0.46)
		m.set_shader_parameter("pulse_speed", 2.2)
		m.set_shader_parameter("pulse_amount", 0.20)
		m.set_shader_parameter("base_opacity", 0.92)
	else:
		# 虚线：流得慢、脉动极小 —— 任务书原话"可以流动，但不许闪到刺眼"
		m.set_shader_parameter("scroll_speed", 0.75)
		m.set_shader_parameter("dash_duty", 0.58)
		m.set_shader_parameter("dash_soft", 0.10)
		m.set_shader_parameter("edge_soft", 0.95)
		m.set_shader_parameter("core_power", 1.30)
		m.set_shader_parameter("halo_power", 0.34)
		m.set_shader_parameter("pulse_speed", 2.4)
		m.set_shader_parameter("pulse_amount", 0.06)
		m.set_shader_parameter("base_opacity", 0.95)
	return m


## 着色器文件丢了的降级路径：实线绿带（没有虚线/流动，但指示照样看得见）
func _make_fallback_material() -> Material:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(DASH_COLOR.r, DASH_COLOR.g, DASH_COLOR.b, 1.0)
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return m