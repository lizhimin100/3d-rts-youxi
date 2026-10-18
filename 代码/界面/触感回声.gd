class_name RtsEchoFx
extends Node3D
## **ECHO（触感回声）** —— 点击 / 下令的"手感反馈"。
##
## 三条规则，全部是为了"点下去有肉感，但绝不廉价"：
##   1. **左键点中单位** → 脚下打一圈快速扩散的圆环（0.35s，缩放到 3 倍并淡出）；
##   2. **右键下指令** → 目标地面打 2 道错开的队伍色涟漪（0.55s，外圈更慢更淡）；
##   3. **点空地 / 空选** → **什么都不放**。乱放特效比没特效还掉价。
##
## 怎么挂到的：只订阅全局信号（`Game.selection_changed` / `Game.order_issued`），
## **不碰选择系统 / 指令系统**；两个信号天然区分了"选中了谁"和"往哪儿下令"，
## 比自己去 `_unhandled_input` 里抢事件稳得多（那两家会 `set_input_as_handled`）。
##
## 生命周期：全部由 Tween 回调 `queue_free`，不靠外部回收；同时在飞的数量封顶，
## 快连点也不会一口气生出几百个 MeshInstance。

## 同时在飞的特效上限
const MAX_ACTIVE := 24
## 点选圆环时长（秒）—— 任务书 0.35s
const PICK_TIME := 0.35
## 右键涟漪时长
const RIPPLE_TIME := 0.55
## 圆环贴地抬高（避免与地形 z-fighting）
const GROUND_LIFT := 0.055

## 环形网格（一次生成，本站点内所有实例复用）
## 注意：**不要**写成 `static var` —— 静态变量活在脚本对象里，
## 脚本比渲染服务晚析构，退出时会刷 "resources still in use / ObjectDB leaked"。
var _ring_mesh: ArrayMesh = null

## 当前在飞的个数
var _active: int = 0
## HUD 引用（由 HUD 在装配时注入；没有也能跑，只是拿不到"当前选中"）
var hud: Node = null
## 上一帧的选中（instance_id 集合），用来找"这次新点中了谁"
var _prev_ids: Dictionary = {}
## 验收用：`--fx-demo` 时周期放特效，好让截图能拍到（不影响正常玩法）
var _demo: bool = false
var _demo_t: float = 0.0


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	name = "触感回声"
	_ensure_mesh()
	Game.selection_changed.connect(_on_selection_changed)
	Game.order_issued.connect(_on_order_issued)
	# 初始化时把当前选中记下来，免得开局第一帧补放一排圆环
	for u in _snapshot_selection():
		_prev_ids[u] = true
	_demo = "--fx-demo" in OS.get_cmdline_user_args()


## 只在验收参数下跑：每 0.3 秒放一组"点选圆环 + 右键涟漪"，保证截图里一定拍得到
func _process(delta: float) -> void:
	if not _demo:
		return
	_demo_t += delta
	if _demo_t < 0.30:
		return
	_demo_t = 0.0
	var host := _hud()
	if host == null:
		return
	var sel = host.get("_selection")
	if not (sel is Array) or (sel as Array).is_empty():
		return
	var u := (sel as Array)[0] as Node3D
	if u == null or not is_instance_valid(u):
		return
	_spawn_pick_ring(u)
	var p: Vector3 = u.global_position + Vector3(2.6, 0.0, 2.6)
	var col: Color = _team_color_of(u)
	var gy: float = _ground_y(p)
	var mi := _make_ring(Vector3(p.x, gy, p.z), Color(col.r, col.g, col.b, 0.72))
	if mi != null:
		mi.scale = Vector3(0.55, 1.0, 0.55)
		_animate(mi, RIPPLE_TIME, 3.9)


## 退出时主动放掉网格（同样是为了避开"资源比渲染服务后死"的关停顺序）
func _exit_tree() -> void:
	_ring_mesh = null
	_prev_ids.clear()


# ===========================================================================
# 左键：点中单位
# ===========================================================================

func _on_selection_changed(units: Array) -> void:
	var now: Dictionary = {}
	var fresh: Array = []
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		var id: int = (u as Node).get_instance_id()
		now[id] = true
		if not _prev_ids.has(id):
			fresh.append(u)
	_prev_ids = now
	if fresh.is_empty():
		return
	# 一次点中很多（双击同类 / 框选）时别刷满屏，取前 12 个
	var limit: int = mini(fresh.size(), 12)
	for i in limit:
		var n := fresh[i] as Node3D
		if n == null:
			continue
		_spawn_pick_ring(n)


func _spawn_pick_ring(u: Node3D) -> void:
	if _active >= MAX_ACTIVE:
		return
	var def: UnitDef = u.get("def") as UnitDef
	var r: float = 0.75
	if def != null:
		r = maxf(def.selection_radius, 0.5)
		if u is RtsBuilding and def.footprint != Vector2i.ZERO:
			r = clampf(float(maxi(def.footprint.x, def.footprint.y)) * 0.5, 1.0, 4.0)
	var col: Color = _team_color_of(u)
	col.a = 0.95
	var pos: Vector3 = u.global_position + Vector3.UP * GROUND_LIFT
	var mi := _make_ring(pos, col)
	if mi == null:
		return
	var dur: float = PICK_TIME
	var from_scale: float = maxf(r * 0.50, 0.20)
	var to_scale: float = maxf(r * 3.4, 1.5)
	mi.scale = Vector3(from_scale, 1.0, from_scale)
	_animate(mi, dur, to_scale)


# ===========================================================================
# 右键：下指令
# ===========================================================================

func _on_order_issued(units: Array, order: int, target_pos: Vector3, target: Node3D) -> void:
	if units.is_empty():
		return
	# 停止 / 保持这种"没有落点"的指令不放涟漪
	if order == RtsConst.Order.STOP or order == RtsConst.Order.HOLD:
		return
	var pos := target_pos
	if target != null and is_instance_valid(target):
		pos = (target as Node3D).global_position
	elif pos.length_squared() < 0.0001:
		return
	var first := units[0] as Node3D if units[0] is Node3D else null
	var col: Color = _team_color_of(first)
	var gy: float = _ground_y(pos)
	# 两道错开的涟漪：内圈快、外圈慢，看起来像水波一圈套一圈
	var mi := _make_ring(Vector3(pos.x, gy, pos.z), Color(col.r, col.g, col.b, 0.72))
	if mi != null:
		mi.scale = Vector3(0.55, 1.0, 0.55)
		_animate(mi, RIPPLE_TIME, 3.9)
	var delay: float = 0.11
	var mi2 := _make_ring(Vector3(pos.x, gy + 0.004, pos.z), Color(col.r, col.g, col.b, 0.55))
	if mi2 != null:
		mi2.visible = false
		var tw := create_tween()
		tw.tween_interval(delay)
		tw.tween_callback(func() -> void:
			if is_instance_valid(mi2):
				mi2.visible = true)
		mi2.scale = Vector3(0.9, 1.0, 0.9)
		_animate(mi2, RIPPLE_TIME * 1.08, 5.2, delay)


# ===========================================================================
# 生成 / 动画
# ===========================================================================

func _make_ring(pos: Vector3, col: Color) -> MeshInstance3D:
	if _active >= MAX_ACTIVE:
		return null
	var mesh := _ensure_mesh()
	if mesh == null:
		return null
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = col
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	var mi := MeshInstance3D.new()
	mi.name = "回声"
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	mi.rotation = Vector3.ZERO
	add_child(mi)
	_active += 1
	return mi


## 扩散 + 淡出；到点自动 queue_free（不靠外部回收）
func _animate(mi: MeshInstance3D, dur: float, to_scale: float, delay: float = 0.0) -> void:
	var mat := mi.material_override as StandardMaterial3D
	var tw := create_tween()
	if delay > 0.0:
		tw.tween_interval(delay)
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3(to_scale, 1.0, to_scale), dur) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if mat != null:
		tw.tween_property(mat, "albedo_color:a", 0.0, dur) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.set_parallel(false)
	tw.tween_callback(func() -> void:
		_active = maxi(_active - 1, 0)
		if is_instance_valid(mi):
			mi.queue_free())


## 环带网格：外沿到内沿四圈，顶点色 alpha 走 0→1→1→0（软边圆环，比硬边圆环贵气）
## 注意：必须用 **TRIANGLE** 而不是 TRIANGLE_STRIP —— SurfaceTool.generate_normals()
## 只吃三角面，用 strip 会当场报 "primitive != Mesh::PRIMITIVE_TRIANGLES"。
func _ensure_mesh() -> ArrayMesh:
	if _ring_mesh != null:
		return _ring_mesh
	var segs: int = 44
	var rings: Array[Dictionary] = [
		{"r": 1.000, "a": 0.0},
		{"r": 0.958, "a": 1.0},
		{"r": 0.876, "a": 1.0},
		{"r": 0.838, "a": 0.0},
	]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in range(rings.size() - 1):
		var r0: float = float(rings[b]["r"])
		var a0: float = float(rings[b]["a"])
		var r1: float = float(rings[b + 1]["r"])
		var a1: float = float(rings[b + 1]["a"])
		var c0 := Color(1.0, 1.0, 1.0, a0)
		var c1 := Color(1.0, 1.0, 1.0, a1)
		for i in segs:
			var g0: float = TAU * float(i) / float(segs)
			var g1: float = TAU * float(i + 1) / float(segs)
			var d0 := Vector3(cos(g0), 0.0, sin(g0))
			var d1 := Vector3(cos(g1), 0.0, sin(g1))
			var p00: Vector3 = d0 * r0
			var p01: Vector3 = d1 * r0
			var p10: Vector3 = d0 * r1
			var p11: Vector3 = d1 * r1
			st.set_color(c0)
			st.add_vertex(p00)
			st.set_color(c0)
			st.add_vertex(p01)
			st.set_color(c1)
			st.add_vertex(p11)
			st.set_color(c0)
			st.add_vertex(p00)
			st.set_color(c1)
			st.add_vertex(p11)
			st.set_color(c1)
			st.add_vertex(p10)
	st.generate_normals()
	_ring_mesh = st.commit() as ArrayMesh
	return _ring_mesh


# ===========================================================================
# 工具
# ===========================================================================

func _team_color_of(u: Node3D) -> Color:
	if u != null and is_instance_valid(u):
		var fac: RtsFaction = u.get("faction") as RtsFaction
		if fac != null:
			return fac.color
	if Cfg.game != null:
		return Cfg.game.player_color
	return Color(0.30, 0.62, 1.0)


## 贴地高度（地形有起伏，不贴地会出现"悬空圆环"这种一眼假的画面）
func _ground_y(p: Vector3) -> float:
	var lv := Game.level
	if lv != null and is_instance_valid(lv) and lv.has_method("height_at"):
		return float(lv.call("height_at", p.x, p.z)) + GROUND_LIFT
	return p.y + GROUND_LIFT


func _snapshot_selection() -> Array:
	var out: Array = []
	var h := _hud()
	if h == null:
		return out
	var sel = h.get("_selection")
	if sel is Array:
		for u in (sel as Array):
			if u != null and is_instance_valid(u):
				out.append((u as Node).get_instance_id())
	return out


## HUD 节点：优先用注入的引用，没有就从主场景的 hud 字段找
func _hud() -> Node:
	if hud != null and is_instance_valid(hud):
		return hud
	var parent := get_parent()
	if parent == null:
		return null
	return parent.get("hud") as Node
