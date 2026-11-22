extends Node3D
## 职责：把 `SquadView` 画成**工程里真实的 3D 单位模型**——每支小队按编制人数实例化对应 GLB，
##       成员跟随 Model 给的槽位坐标，整队朝向按质心朝向，脚下用红/蓝徽记区分攻/防时空。
## 属于：Screens/world/battle（表现层）
##
## 这是 2026-11-22 替换"纯色胶囊"的实现。纪律：
##   · 模型路径只来自 `Content/data/units.json` 的 `model_path`；没有任何"按兵种 id 现场拼方块"的分支；
##   · 成员位置/朝向/血量全部来自快照（世界米），这里只做插值；
##   · 表现层不判断"谁能打谁"——集火线只画 Model 给的 target_squad；
##   · 玩家能操作的最小单位是**小队**：这里没有任何单成员的选择/指令入口。

const MEMBER_CAP := 160
const ATTACK_MARK := Color(0.86, 0.26, 0.20)
const DEFEND_MARK := Color(0.24, 0.52, 0.95)
const SELECT_COLOR := Color(0.98, 0.96, 0.84, 0.95)
const FOCUS_COLOR := Color(0.95, 0.30, 0.25, 0.95)
const ORDER_COLOR := Color(0.98, 0.82, 0.34, 0.95)

signal ground_ready

var _units: Dictionary = {}
var _arena: Dictionary = {}
var _view: Dictionary = {}
var _selected: Array = []
var _order_point := Vector3.ZERO
var _has_order := false

var _ground: Callable = Callable()
var _squad_roots: Dictionary = {}        # squad_id -> {root, members:[], anims:[], mark, ring}
var _mm_count := 0
var _lines: ImmediateMesh = null
var _ring_mesh: ArrayMesh = null
var _mark_mesh: ArrayMesh = null
var _mat_attack: StandardMaterial3D = null
var _mat_defend: StandardMaterial3D = null
var _mat_select: StandardMaterial3D = null
var _warned: Dictionary = {}


func _ready() -> void:
	_build_lines()
	_ring_mesh = _make_ring_mesh(0.72, 0.98, 0.010)
	# 攻/防徽记要绕在整队脚下（不是一小圈），否则被模型挡住看不见
	_mark_mesh = _make_ring_mesh(1.25, 1.70, 0.0)
	_mat_attack = _flat_mat(ATTACK_MARK)
	_mat_defend = _flat_mat(DEFEND_MARK)
	_mat_select = _flat_mat(Color(1, 1, 1, 0.9))


## 地面高度查询（由 战役战场 注入：`func(x, z) -> float`）。
func set_ground(fn: Callable) -> void:
	_ground = fn


func configure(units: Dictionary) -> void:
	_units = units


func set_arena(arena: Dictionary) -> void:
	_arena = arena


func _build_lines() -> void:
	_lines = ImmediateMesh.new()
	var mi := MeshInstance3D.new()
	mi.name = "SquadLines"
	mi.mesh = _lines
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	add_child(mi)


func _flat_mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# ===========================================================================
# 每帧
# ===========================================================================
func update_view(view: Dictionary, selected: Array, order_point: Vector3, has_order: bool) -> void:
	_view = view
	_selected = selected
	_order_point = order_point
	_has_order = has_order

	var live := {}
	var total := 0
	for s in view.get("squads", []):
		var sq: Dictionary = s
		if not bool(sq.get("active", true)):
			continue
		var sid := int(sq.get("id", 0))
		var shown := _sync_squad(sq, selected.has(sid))
		if shown < 0:
			# render=false 的兵种：场上没有模型，但小队仍然存在（占阵地/吃伤害/给基地抽血）。
			# 保留它脚下的攻防徽记与选中环，否则玩家会以为这支部队"凭空消失"了。
			live[sid] = true
			continue
		if shown <= 0:
			continue
		total += shown
		live[sid] = true
		if total >= MEMBER_CAP:
			break

	# 回收不再出现的队（死亡 / 轮末清场 / 时空切换被冻结）
	for sid in _squad_roots.keys():
		if live.has(sid):
			continue
		_free_squad(int(sid))

	_draw_lines(live)


## 同步一支小队的实例；返回画出来的成员数。
func _sync_squad(sq: Dictionary, is_selected: bool) -> int:
	var sid := int(sq.get("id", 0))
	var role := String(sq.get("role", ""))
	var rec: Dictionary = _squad_roots.get(sid, {})
	var members: Array = sq.get("members", [])
	if rec.is_empty():
		var root := Node3D.new()
		root.name = "S_%d" % sid
		add_child(root)
		rec = {"root": root, "members": [], "anims": [], "mark": null, "ring": null, "state": ""}
		_squad_roots[sid] = rec
		# 脚下攻/防徽记：红 = 待命进攻，蓝 = 待命防守
		if role == "attack" or role == "defend":
			var mk := MeshInstance3D.new()
			mk.name = "RoleMark"
			mk.mesh = _mark_mesh
			mk.material_override = _mat_attack if role == "attack" else _mat_defend
			mk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			(rec["root"] as Node3D).add_child(mk)
			rec["mark"] = mk
		var ring := MeshInstance3D.new()
		ring.name = "SelectRing"
		ring.mesh = _ring_mesh
		ring.material_override = _mat_select
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ring.visible = false
		(rec["root"] as Node3D).add_child(ring)
		rec["ring"] = ring

	var root: Node3D = rec["root"]
	var list: Array = rec["members"]
	var anims: Array = rec["anims"]
	var unit_id := String(sq.get("unit_id", ""))

	# 编制人数对齐（阵型槽位数 = squad_size；Model 决定，这里只照做）
	while list.size() < members.size():
		var inst := _make_member(unit_id)
		if inst == null:
			break
		root.add_child(inst["node"])
		list.append(inst["node"])
		anims.append(inst["anim"])

	var heading := float(sq.get("heading", 0.0))
	var yaw := atan2(-cos(heading), -sin(heading))
	var cx := float(sq.get("x", 0.0))
	var cz := float(sq.get("z", 0.0))
	var cy := _h(cx, cz)
	root.position = Vector3(cx, cy, cz)
	root.rotation.y = yaw

	var shown := 0
	var moving := false
	for i in members.size():
		if i >= list.size():
			break
		var mem: Dictionary = members[i]
		var node: Node3D = list[i]
		if not bool(mem.get("alive", true)):
			node.visible = false
			continue
		node.visible = true
		var mx := float(mem.get("x", 0.0))
		var mz := float(mem.get("z", 0.0))
		# 成员在 root 的局部空间里（root 已经贴地并转向）。
		# 逆变换口径与 TacticalTile.ToWorld 同一套：
		#   world = (lx*c + lz*s, -lx*s + lz*c)  →  local = (dx*c - dz*s, dx*s + dz*c)
		var dx := mx - cx
		var dz := mz - cz
		var cc := cos(yaw)
		var ss := sin(yaw)
		node.position = Vector3(
			dx * cc - dz * ss,
			_h(mx, mz) - cy,
			dx * ss + dz * cc)
		shown += 1
		var sx := float(mem.get("slot_x", mx))
		var sz := float(mem.get("slot_z", mz))
		if absf(mx - sx) + absf(mz - sz) > 0.06:
			moving = true

	# 动画：移动播 walk，站定播 idle（模型没有这两条状态时静默跳过）
	var want_state := "walk" if moving else "idle"
	if String(rec.get("state", "")) != want_state:
		rec["state"] = want_state
		for a in anims:
			ArtKit.set_anim(a, want_state, 1.0, false)

	var mark: Node3D = rec.get("mark", null)
	if mark != null:
		mark.visible = true
		mark.position = Vector3(0.0, 0.02, 0.0)
		mark.rotation.y = -yaw
	var ring: Node3D = rec.get("ring", null)
	if ring != null:
		ring.visible = is_selected
		ring.position = Vector3(0.0, 0.03, 0.0)
		var r := maxf(float(sq.get("radius", 1.4)), 0.9) * 1.05
		ring.scale = Vector3(r / 0.85, 1.0, r / 0.85)
	return -1 if not _renders(unit_id) else shown


## 这个兵种有没有上场模型（`units.json` 的 render 开关）。
func _renders(unit_id: String) -> bool:
	var def: Dictionary = _units.get(unit_id, {})
	return bool(def.get("render", true))


## 造一个成员视觉：真实 GLB + 阵营色 + 动画器。找不到模型返回 null（不硬塞方块）。
##
## `render=false` 的兵种（长枪兵 / 弓箭手 / 鱼人阵营）**只实现逻辑、不上场**：
## 它们的编制、伤害、占位全部照常跑（Model 说了算），只是不实例化任何模型 ——
## 于是场上"看不到人"，但小队本身仍然占阵地、吃伤害、给敌方基地抽血。
## 这条分支必须早返回：不能滑到下面的 build_model，否则会去加载一个已经被删掉的资产。
func _make_member(unit_id: String) -> Dictionary:
	var def: Dictionary = _units.get(unit_id, {})
	if not bool(def.get("render", true)):
		return {}
	var path := String(def.get("model_path", ""))
	if path.is_empty():
		if not _warned.has(unit_id):
			_warned[unit_id] = true
			push_warning("[squad] no model_path for " + unit_id)
		return {}
	var scale := float(def.get("model_scale", 1.0))
	var model: Node3D = ArtKit.build_model(path, scale, Vector3(0.6, 1.7, 0.5))
	if model == null:
		return {}
	_hide_helper_meshes(model)
	var side_color := Color(0.30, 0.62, 1.0)
	ArtKit.apply_team_color(model, side_color)
	var anim := ArtKit.attach_anim(model)
	if anim != null:
		ArtKit.set_anim(anim, "idle", 1.0, true)
	return {"node": model, "anim": anim}


## 个别资产自带"脚下参考平面"（方块人_步兵.glb 有一块 8×8 的 ground_ref）——
## 那是建模辅助面，进画面会变成一大块灰地板，这里统一收掉。
func _hide_helper_meshes(root: Node) -> void:
	for c in root.get_children():
		if String(c.name).begins_with("ground_ref"):
			if c is Node3D:
				(c as Node3D).visible = false
			continue
		_hide_helper_meshes(c)


func _free_squad(sid: int) -> void:
	var rec: Dictionary = _squad_roots.get(sid, {})
	if rec.is_empty():
		return
	var root: Node3D = rec.get("root", null)
	if is_instance_valid(root):
		root.queue_free()
	_squad_roots.erase(sid)


func _h(x: float, z: float) -> float:
	if not _ground.is_valid():
		return 0.0
	var v: Variant = _ground.call(x, z)
	return float(v) if v != null else 0.0


# ===========================================================================
# 集火线 / 指令标记
# ===========================================================================
func _draw_lines(live: Dictionary) -> void:
	if _lines == null:
		return
	# 规划期没有任何集火线与指令点时，别开 surface —— 空 surface 每帧刷一条
	# "No vertices were added, surface can't be created" 的引擎 ERROR（白占日志与性能）。
	var has_focus := false
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		if not _selected.has(int(sq.get("id", 0))):
			continue
		if int(sq.get("target_squad", -1)) > 0:
			has_focus = true
			break
	if not has_focus and not _has_order:
		if _lines.get_surface_count() > 0:
			_lines.clear_surfaces()
		return
	_lines.clear_surfaces()
	_lines.surface_begin(Mesh.PRIMITIVE_LINES)
	var by_id := {}
	for s in _view.get("squads", []):
		var sq: Dictionary = s
		by_id[int(sq.get("id", 0))] = sq
	for id in _selected:
		var sq: Dictionary = by_id.get(int(id), {})
		if sq.is_empty() or not bool(sq.get("active", true)):
			continue
		var target := int(sq.get("target_squad", -1))
		if target <= 0 or not by_id.has(target):
			continue
		var t: Dictionary = by_id[target]
		var a := Vector3(float(sq.get("x", 0.0)), _h(float(sq.get("x", 0.0)), float(sq.get("z", 0.0))) + 1.2,
			float(sq.get("z", 0.0)))
		var b := Vector3(float(t.get("x", 0.0)), _h(float(t.get("x", 0.0)), float(t.get("z", 0.0))) + 1.2,
			float(t.get("z", 0.0)))
		_line(a, b, FOCUS_COLOR)
	if _has_order:
		var p := _order_point
		p.y = _h(p.x, p.z) + 0.08
		_cross(p, 0.9, ORDER_COLOR)
	_lines.surface_end()


func _line(a: Vector3, b: Vector3, c: Color) -> void:
	_lines.surface_set_color(c)
	_lines.surface_add_vertex(a)
	_lines.surface_add_vertex(b)


func _cross(c: Vector3, s: float, col: Color) -> void:
	_line(c + Vector3(-s, 0, 0), c + Vector3(s, 0, 0), col)
	_line(c + Vector3(0, 0, -s), c + Vector3(0, 0, s), col)


func _make_ring_mesh(r_in: float, r_out: float, lift: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 28
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var o0 := Vector3(cos(a0) * r_out, lift, sin(a0) * r_out)
		var o1 := Vector3(cos(a1) * r_out, lift, sin(a1) * r_out)
		var i0 := Vector3(cos(a0) * r_in, lift, sin(a0) * r_in)
		var i1 := Vector3(cos(a1) * r_in, lift, sin(a1) * r_in)
		st.set_color(Color.WHITE)
		st.add_vertex(o0)
		st.set_color(Color.WHITE)
		st.add_vertex(o1)
		st.set_color(Color.WHITE)
		st.add_vertex(i1)
		st.set_color(Color.WHITE)
		st.add_vertex(o0)
		st.set_color(Color.WHITE)
		st.add_vertex(i1)
		st.set_color(Color.WHITE)
		st.add_vertex(i0)
	return st.commit()


## 自检用：当前真实模型实例数（0 = 退回纯色/没模型，验收会红）
func model_instance_count() -> int:
	var n := 0
	for sid in _squad_roots.keys():
		var rec: Dictionary = _squad_roots[sid]
		for m in rec.get("members", []):
			var node: Node3D = m
			if is_instance_valid(node) and node.visible:
				n += 1
	return n
