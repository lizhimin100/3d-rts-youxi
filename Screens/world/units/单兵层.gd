extends Node3D
## 职责：把 `SquadView`（**一名独立单兵一条快照**）画成工程里的真实 3D 单位 ——
##       错峰空降、行走颠簸与前倾、攻击前冲 / 开火后坐、简易弹道、受击闪白、死亡倒地。
## 属于：Screens/world/units（表现层）
##
## 纪律：
##   · 模型路径只来自 `Content/data/units.json` 的 `model_path`；没有"按兵种 id 现拼方块"的分支；
##   · 位置/朝向/血量全部来自快照（世界米），这里只做插值与动画；
##   · 表现层不判断"谁能打谁"：`engaged` 由 Model 给，这里只决定播什么动作；
##   · **没有任何操控入口**：选中只画一圈选中环 + 血条，不下指令、不改位置；
##   · 单兵制（2026-11-22）：每条视图 = 一个人，没有再按 `members` 铺成员。
##
## 动画口径（为什么"看起来像真在打"）：
##   ① 骨骼层：模型自带 walk / attack / shoot / death 就直接播（ArtKit 会做名字映射与降级）；
##   ② 程序层：无论有没有骨骼，都叠一层**身体**动画 —— 走路上下颠 + 前倾、
##      出手瞬间向前顶一下（远程是后坐）、落地压扁回弹。骨骼只管四肢，程序层管"重心"，
##      两层叠起来才不会有"滑步平移"的塑料感；
##   ③ 手感层：受击闪白、脚下光圈、弹道拖尾 —— 这些是"打中了"的唯一视觉证据。

const UNIT_CAP := 220

## 空降：从多高、多久落地、错峰间隔（0.05~0.08 秒/人，规格写在这里）
const DROP_HEIGHT := 7.2
const DROP_TIME := 0.52
const DROP_STAGGER := 0.065

const ATTACK_HOLD := 0.36
const FLASH_TIME := 0.11

const PLAYER_COLOR := Color(0.36, 0.62, 0.98)
const ENEMY_COLOR := Color(0.92, 0.42, 0.34)
const SELECT_COLOR := Color(0.98, 0.96, 0.84, 0.95)
const SHOT_COLOR := Color(1.0, 0.86, 0.45, 0.9)

var _units_configured: Dictionary = {}
var _units: Dictionary = {}
var _arena: Dictionary = {}
var _view: Dictionary = {}
var _selected: Array = []
var _ground: Callable = Callable()
var _warned: Dictionary = {}

var _mat_flash: StandardMaterial3D = null
var _mat_select: StandardMaterial3D = null
var _ring_mesh: ArrayMesh = null
var _shot_mesh: BoxMesh = null
var _shot_mat: StandardMaterial3D = null
var _fx_root: Node3D = null
var _t := 0.0


func _ready() -> void:
	_mat_flash = StandardMaterial3D.new()
	_mat_flash.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_flash.albedo_color = Color(1.0, 0.74, 0.62, 0.92)
	_mat_flash.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_select = StandardMaterial3D.new()
	_mat_select.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_select.albedo_color = SELECT_COLOR
	_mat_select.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_select.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_mesh = _make_ring_mesh(0.52, 0.62, 0.02)
	_shot_mesh = BoxMesh.new()
	_shot_mesh.size = Vector3(0.16, 0.16, 1.0)
	_shot_mat = StandardMaterial3D.new()
	_shot_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shot_mat.albedo_color = SHOT_COLOR
	_shot_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shot_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fx_root = Node3D.new()
	_fx_root.name = "UnitFx"
	add_child(_fx_root)


func set_ground(fn: Callable) -> void:
	_ground = fn


func configure(units: Dictionary) -> void:
	_units_configured = units


func set_arena(arena: Dictionary) -> void:
	_arena = arena


# ===========================================================================
# 快照 → 实体（只做增删与"最新快照"记录，动画在 _process 里跑）
# ===========================================================================
func update_view(view: Dictionary, selected: Array, _order_point: Vector3, _has_order: bool) -> void:
	_view = view
	_selected = selected
	var live := {}
	var fresh: Array = []
	for s in view.get("squads", []):
		var sq: Dictionary = s
		if not bool(sq.get("active", true)):
			continue
		var sid := int(sq.get("id", 0))
		live[sid] = true
		if _units.has(sid):
			(_units[sid] as Dictionary)["sq"] = sq
		elif _units.size() < UNIT_CAP:
			fresh.append(sq)
	# 空降错峰：同一帧新出现的 N 个人按 0.065 秒依次落地（不是"啪"一下全站好）
	for i in fresh.size():
		_make_unit(fresh[i], float(i) * DROP_STAGGER)
	# 离场：一次少一大片 = 轮末清场（直接淡出）；零散少人 = 战死（播倒地）
	var missing: Array = []
	for sid in _units.keys():
		if not live.has(sid):
			missing.append(sid)
	var mass := missing.size() > 6
	for sid in missing:
		_retire(int(sid), mass)


func model_instance_count() -> int:
	var n := 0
	for sid in _units.keys():
		var rec: Dictionary = _units[sid]
		var node: Node3D = rec.get("model", null)
		if is_instance_valid(node) and (node as Node3D).visible:
			n += 1
	return n


## 探针（截图/自检用）：真的在播什么状态、空降了几个人、有没有骨骼动画
func anim_report() -> String:
	var bone := 0
	var dropping := 0
	var attacking := 0
	for sid in _units.keys():
		var rec: Dictionary = _units[sid]
		if rec.get("anim", null) != null:
			bone += 1
		if not bool(rec.get("landed", true)):
			dropping += 1
		if String(rec.get("state", "")) == "attack":
			attacking += 1
	return "units=%d bone=%d drop=%d atk=%d" % [_units.size(), bone, dropping, attacking]


func _make_unit(sq: Dictionary, delay: float) -> void:
	var sid := int(sq.get("id", 0))
	var unit_id := String(sq.get("unit_id", ""))
	var def: Dictionary = _units_configured.get(unit_id, {})
	var root := Node3D.new()
	root.name = "U_%d" % sid
	add_child(root)
	var rec := {
		"root": root,
		"model": null,
		"anim": null,
		"sq": sq,
		"unit_id": unit_id,
		"def": def,
		"side": int(sq.get("side", 0)),
		"state": "",
		"last_x": float(sq.get("x", 0.0)),
		"last_z": float(sq.get("z", 0.0)),
		"bob": 0.0,
		"atk": 0.0,
		"cd": 0.0,
		"hit": 0.0,
		"hp": float(sq.get("hp", 1.0)),
		"drop_t": -delay,
		"landed": false,
		"squash": 0.0,
		"ring": null,
		"flash_saved": null,
	}
	_units[sid] = rec

	root.position = Vector3(float(sq.get("x", 0.0)), _h(float(sq.get("x", 0.0)), float(sq.get("z", 0.0))) + DROP_HEIGHT,
		float(sq.get("z", 0.0)))
	root.rotation.y = _yaw(float(sq.get("heading", 0.0)))
	root.visible = delay <= 0.0

	var built := _build_model(def, int(sq.get("side", 0)))
	if built.is_empty():
		# 没模型（render=false 或资产缺失）：留一个不可见的占位，别把逻辑单位从场上抹掉
		rec["fallback"] = true
		return
	root.add_child(built["node"])
	rec["model"] = built["node"]
	rec["anim"] = built["anim"]

	var ring := MeshInstance3D.new()
	ring.name = "SelectRing"
	ring.mesh = _ring_mesh
	ring.material_override = _mat_select
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.visible = false
	root.add_child(ring)
	rec["ring"] = ring


## 造模型：真实 GLB + 阵营色 + 骨骼动画器。找不到模型返回 {}（不硬塞方块）。
func _build_model(def: Dictionary, side: int) -> Dictionary:
	if not bool(def.get("render", true)):
		return {}
	var path := String(def.get("model_path", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		if not _warned.has(path):
			_warned[path] = true
			push_warning("[unit] model missing: " + path)
		return {}
	var scale := float(def.get("model_scale", 1.0))
	var model: Node3D = ArtKit.build_model(path, scale, Vector3(0.6, 1.7, 0.5))
	if model == null:
		return {}
	_hide_helper_meshes(model)
	ArtKit.apply_team_color(model, PLAYER_COLOR if side == 0 else ENEMY_COLOR)
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


# ===========================================================================
# 每帧动画
# ===========================================================================
func _process(delta: float) -> void:
	_t += delta
	for sid in _units.keys():
		var rec: Dictionary = _units[sid]
		if is_instance_valid(rec.get("root", null)):
			_animate(rec, delta)


func _animate(rec: Dictionary, delta: float) -> void:
	var root: Node3D = rec["root"]
	var model: Node3D = rec.get("model", null)
	var sq: Dictionary = rec.get("sq", {})

	# ---- ① 空降：等自己的那一拍 → 自由落体 → 压扁回弹 + 光圈 ----
	if not bool(rec["landed"]):
		_drop_tick(rec, delta, root)
		return

	# ---- ② 贴地与插值：逻辑 20Hz，渲染 60Hz，位置必须插值，否则"一顿一顿" ----
	var tx := float(sq.get("x", rec["last_x"]))
	var tz := float(sq.get("z", rec["last_z"]))
	var ty := _h(tx, tz)
	var k := 1.0 - exp(-18.0 * delta)
	root.position.x = lerpf(root.position.x, tx, k)
	root.position.z = lerpf(root.position.z, tz, k)
	var moved := absf(tx - rec["last_x"]) + absf(tz - rec["last_z"]) > 0.012
	rec["last_x"] = tx
	rec["last_z"] = tz

	# ---- ③ 朝向：模型正面 -Z（工程约定）→ yaw = atan2(-dx,-dz) ----
	var want := _yaw(float(sq.get("heading", 0.0)))
	root.rotation.y = lerp_angle(root.rotation.y, want, 1.0 - exp(-12.0 * delta))

	# ---- ④ 状态机：攻击（按攻击冷却重播）> 行走 > 待机 ----
	# 注意：不能"进了攻击就播一次然后一直站着"—— 60 秒对砍里那只读得出第一刀。
	var engaged := bool(sq.get("engaged", false))
	var cd := float(rec["cd"]) - delta
	var state := "idle"
	if engaged:
		if cd <= 0.0:
			cd = maxf(float(sq.get("attack_cooldown", 1.2)), 0.35)
			rec["atk"] = ATTACK_HOLD
			rec["state"] = "attack"
			_play_state(rec, "attack", false)
		state = "attack"
		rec["atk"] = maxf(float(rec["atk"]) - delta, 0.0)
	elif float(rec["atk"]) > 0.0:
		rec["atk"] = maxf(float(rec["atk"]) - delta, 0.0)
		state = "attack"
	elif moved:
		state = "walk"
	else:
		state = "idle"
	rec["cd"] = maxf(cd, 0.0)
	if state != String(rec["state"]):
		rec["state"] = state
		_play_state(rec, state, moved)

	# ---- ⑤ 程序层重心动画（骨骼只管四肢）----
	if model != null:
		var amp := 1.0 if state != "idle" else 0.35
		rec["bob"] = float(rec["bob"]) + delta * (9.0 if state == "walk" else 2.2)
		var bob := sin(float(rec["bob"])) * 0.055 * amp
		var lean := 0.14 if state == "walk" else 0.0
		var lunge := 0.0
		if state == "attack":
			var p := 1.0 - clampf(float(rec["atk"]) / ATTACK_HOLD, 0.0, 1.0)
			# 0→0.35：向前顶；0.35→1：收回来（远程是后坐，符号相反）
			var curve := sin(clampf(p / 0.45, 0.0, 1.0) * PI)
			lunge = curve * (0.30 if _is_ranged(rec) else 0.42)
			if _is_ranged(rec):
				lunge = -lunge * 0.45
		# 压扁回弹（落地那一拍）
		var squash := float(rec["squash"])
		if squash > 0.0:
			rec["squash"] = maxf(squash - delta * 4.2, 0.0)
		var sy := 1.0 - squash * 0.34
		var sxz := 1.0 + squash * 0.26
		model.scale = Vector3(sxz, sy, sxz)
		model.position = Vector3(0.0, bob, lunge)
		model.rotation.x = lean

	# ---- ⑥ 受击闪白 ----
	var hp := float(sq.get("hp", 0.0))
	if hp < float(rec["hp"]) - 0.01:
		_bite(rec, model)
	rec["hp"] = hp
	if float(rec["hit"]) > 0.0:
		rec["hit"] = float(rec["hit"]) - delta
		if float(rec["hit"]) <= 0.0:
			_unflash(model)

	# ---- ⑦ 选中环（只表示"我看的是谁"，没有任何指令入口）----
	var ring: Node3D = rec.get("ring", null)
	if ring != null:
		ring.visible = _selected.has(int(sq.get("id", 0)))
		ring.position.y = 0.02


func _drop_tick(rec: Dictionary, delta: float, root: Node3D) -> void:
	var model: Node3D = rec.get("model", null)
	rec["drop_t"] = float(rec["drop_t"]) + delta
	var t := float(rec["drop_t"])
	if t < 0.0:
		root.visible = false
		return
	root.visible = true
	var p := clampf(t / DROP_TIME, 0.0, 1.0)
	# 自由落体：y = H(1-p²) —— 越落越快，不是匀速下坠
	root.position.y = _h(root.position.x, root.position.z) + DROP_HEIGHT * (1.0 - p * p)
	if model != null:
		# 下落时纵向拉伸，落地后压扁（Squash & Stretch）
		model.scale = Vector3(1.0 - 0.12 * p, 1.0 + 0.22 * p, 1.0 - 0.12 * p)
	if p < 1.0:
		return
	rec["landed"] = true
	root.position.y = _h(root.position.x, root.position.z)
	rec["squash"] = 1.0
	if model != null:
		model.scale = Vector3.ONE
	_land_ring(root.position)
	_play_state(rec, "idle", false)


## 脚下光圈：一圈贴地细环，0.34 秒内扩散淡出
func _land_ring(pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _ring_mesh
	mi.material_override = _mat_select
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(pos.x, pos.y + 0.03, pos.z)
	_fx_root.add_child(mi)
	mi.scale = Vector3(0.5, 1.0, 0.5)
	var mat := (_mat_select as StandardMaterial3D).duplicate() as StandardMaterial3D
	mat.albedo_color = Color(0.98, 0.94, 0.82, 0.7)
	mi.material_override = mat
	var t := create_tween().set_parallel(true)
	t.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(mi, "scale", Vector3(1.7, 1.0, 1.7), 0.34)
	t.tween_property(mat, "albedo_color:a", 0.0, 0.34)
	t.chain().tween_callback(mi.queue_free)


## 倒地位置留下的一圈暗色印子（0.5 秒淡出）—— 自己的实现，不依赖特效库的静态调用
func _death_mark(pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _ring_mesh
	var mat := (_mat_select as StandardMaterial3D).duplicate() as StandardMaterial3D
	mat.albedo_color = Color(0.30, 0.12, 0.10, 0.55)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(pos.x, pos.y + 0.025, pos.z)
	_fx_root.add_child(mi)
	mi.scale = Vector3(0.6, 1.0, 0.6)
	var t := create_tween().set_parallel(true)
	t.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(mi, "scale", Vector3(1.4, 1.0, 1.4), 0.5)
	t.tween_property(mat, "albedo_color:a", 0.0, 0.5)
	t.chain().tween_callback(mi.queue_free)


func _play_state(rec: Dictionary, state: String, moving: bool) -> void:
	var anim: Node = rec.get("anim", null)
	if anim == null:
		return
	var def: Dictionary = rec.get("def", {})
	var ranged := _is_ranged(rec)
	var speed := 1.0
	if state == "walk":
		# 步频跟真实地速走：走得快 → 迈得急（不然脚底打滑）
		speed = clampf(float(rec["sq"].get("move_speed", 4.0)) / 3.2, 0.8, 2.2)
	ArtKit.set_anim(anim, _clip_for(state, ranged, def), speed, state == "attack")
	if state == "attack" and ranged:
		_fire_tracer(rec)


func _clip_for(state: String, ranged: bool, _def: Dictionary) -> String:
	match state:
		"attack":
			return "shoot" if ranged else "attack"
		"walk":
			return "move"
		_:
			return "idle"


func _is_ranged(rec: Dictionary) -> bool:
	return bool((rec.get("def", {}) as Dictionary).get("projectile", false))


# ===========================================================================
# 受击 / 弹道 / 倒地
# ===========================================================================
func _bite(rec: Dictionary, model: Node3D) -> void:
	rec["hit"] = FLASH_TIME
	if model == null:
		return
	if rec.get("flash_saved", null) == null:
		var saved: Array = []
		_collect_meshes(model, saved)
		rec["flash_saved"] = saved
	for m in rec.get("flash_saved", []):
		var mi: MeshInstance3D = m
		if is_instance_valid(mi):
			mi.material_override = _mat_flash
	# 注意：这里**不调 ArtKit.vfx_hit** —— 那套特效是 Script.call 静态函数的旧路径，
	# 在当前引擎版本上会刷 "Nonexistent function 'hit_spark'"，一个人挨打一次一条 ERROR。
	# 受击的反馈就是"整身闪白 + 血条掉一截"，够读，而且零分配。


func _unflash(model: Node3D) -> void:
	if model == null:
		return
	var saved: Array = []
	_collect_meshes(model, saved)
	for mi in saved:
		if is_instance_valid(mi):
			(mi as MeshInstance3D).material_override = null


func _collect_meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_meshes(c, out)


## 简易弹道：从射手胸口朝目标拉一根 0.1 秒的亮条（远程单位开火时触发的唯一视觉）
func _fire_tracer(rec: Dictionary) -> void:
	var sq: Dictionary = rec["sq"]
	var target := int(sq.get("target_squad", -1))
	if target < 0 or not _units.has(target):
		return
	var other: Dictionary = _units[target]
	var to: Vector3 = (other["root"] as Node3D).position + Vector3(0, 1.1, 0)
	var from: Vector3 = (rec["root"] as Node3D).position + Vector3(0, 1.15, 0)
	var d := from.distance_to(to)
	if d < 0.2:
		return
	var mi := MeshInstance3D.new()
	mi.mesh = _shot_mesh
	mi.material_override = _shot_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx_root.add_child(mi)
	# 盒子长度沿本地 Z：把它居中在射手与目标的中点，再 look_at 目标 —— 两头就对上了
	mi.scale = Vector3(1.0, 1.0, maxf(d, 0.5))
	mi.position = (from + to) * 0.5
	mi.look_at(to, Vector3.UP)
	var t := create_tween()
	t.tween_property(mi, "scale:z", 0.2, 0.1)
	t.tween_callback(mi.queue_free)


func _retire(sid: int, mass: bool) -> void:
	var rec: Dictionary = _units.get(sid, {})
	_units.erase(sid)
	if rec.is_empty():
		return
	var root: Node3D = rec.get("root", null)
	if not is_instance_valid(root):
		return
	# 死的时候可能正闪着白 —— 必须先把手感层摘掉，
	# 否则尸体会顶着一身白漆躺在地上（截图里就是一大块白斑）。
	if float(rec.get("hit", 0.0)) > 0.0:
		_unflash(rec.get("model", null))
	var anim: Node = rec.get("anim", null)
	if mass:
		var t := create_tween()
		t.tween_property(root, "scale", Vector3(0.6, 0.6, 0.6), 0.18)
		t.parallel().tween_property(root, "position:y", root.position.y - 0.4, 0.18)
		t.tween_callback(root.queue_free)
		return
	# 战死：有 death 动作就播完再淡出，没有就向前扑倒
	if anim != null and anim.has_method("has_state") and bool(anim.call("has_state", "death")):
		ArtKit.set_anim(anim, "death", 1.0, true)
	var t2 := create_tween()
	t2.tween_property(root, "rotation:x", 1.35, 0.34).set_ease(Tween.EASE_IN)
	t2.parallel().tween_property(root, "position:y", root.position.y - 0.25, 0.34)
	t2.tween_property(root, "scale", Vector3(1.0, 0.2, 1.0), 0.22)
	t2.tween_callback(root.queue_free)
	_death_mark(root.position)


# ===========================================================================
# 小工具
# ===========================================================================
func _h(x: float, z: float) -> float:
	if not _ground.is_valid():
		return 0.0
	var v: Variant = _ground.call(x, z)
	return float(v) if v != null else 0.0


## lane heading（弧度，+X 为 0）→ Godot yaw（模型正面 -Z）
func _yaw(heading: float) -> float:
	return atan2(-cos(heading), -sin(heading))


func _make_ring_mesh(r_in: float, r_out: float, lift: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 24
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var o0 := Vector3(cos(a0) * r_out, lift, sin(a0) * r_out)
		var o1 := Vector3(cos(a1) * r_out, lift, sin(a1) * r_out)
		var i0 := Vector3(cos(a0) * r_in, lift, sin(a0) * r_in)
		var i1 := Vector3(cos(a1) * r_in, lift, sin(a1) * r_in)
		for pair in [[o0, o1, i1], [o0, i1, i0]]:
			for v in pair:
				st.set_color(Color.WHITE)
				st.set_normal(Vector3.UP)
				st.add_vertex(v)
	return st.commit()
