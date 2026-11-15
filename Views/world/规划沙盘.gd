extends Node3D
## **规划沙盘（第三版，2026-11-15）** —— 规划阶段盖在战场上的"作战台"。
##
## 玩家口径（2026-11-15 晚）：
##   ① 全图铺一层**细密、柔和的细线方格**（不是只有两块红蓝区）；
##   ② 规划阶段**不显示 3D 建筑/士兵模型**（模型 visible=false），改用头顶的兵牌图标；
##   ③ 势力范围**以建筑为锚点**向外辐射（基地 34m / 哨塔 16m / 其他 ~13m），
##      多座建筑重叠时自然融合成不规则领地，边缘羽化发光（深湖蓝 / 暗红紫）；
##   ④ 废弃固定大方块（旧版 ZONE_HALF=27 的矩形红蓝块）。
##
## 为什么用"势力场贴图 + 一张贴地网格"而不是 Decal / 逐个矩形：
##   · 建筑可以在编辑器里随时挪动，矩形必然再次对不上（玩家这次就是挪了基地）；
##   · 场值在 CPU 端按建筑距离叠加，重叠处自然相加、边缘由着色器做羽化，
##     天然是"多座建筑融合出的不规则领地"，不需要手工拼多边形；
##   · 网格与领地在同一张 mesh / 同一个 shader 里，网格线不会和领地边缘错位。
##
## 纪律：
##   · **只在规划阶段可见**；淡入淡出只推 fade 一个 uniform（不硬切）；
##   · 纯装饰：不挡鼠标、不进碰撞、不写玩法状态；
##   · 模型隐藏按"节点实例 id → 原 visible"记账，退出时逐一还原，绝不留隐藏的兵。
##
## 对外（规划地图层 / 主场景镜头读）：
##   faction_items()   每个有建筑的阵营：{faction, mine, color, anchor, buildings}
##   building_items()  每座建筑：{node, faction, mine, color, def, pos, constructed, progress}
##   cluster_items()   单位聚合：{faction, mine, color, def, center, count}
##   camera_points()   取景用的世界点（基地 ±24m + 每座建筑）
##   focus_hint()      玩家基地锚点（镜头注视点往近端偏）
##   zone_list()       兼容旧接口：等价于 faction_items()

const SHADER_PATH := "res://Content/art/着色器/沙盘网格.gdshader"
const RING_SHADER := "res://Content/art/着色器/沙盘光环.gdshader"

## 地面网格的几何精度（米）：只决定"贴不贴地形"，和画出来的格宽无关
const MESH_STEP := 2.0
## 贴着地形抬高多少（米）：压住 z-fighting，又不至于让图标"陷进网格里"
const LIFT := 0.075
const RING_LIFT := 0.10
## 淡入淡出速度（每秒）
const FADE_SPEED := 2.4
## 势力场贴图分辨率（224m 图 → 1m/px；换图按 map_size 自动换算）
const MASK_RES := 224
## 单位聚合成"小队图标"的最大间距（米）
const CLUSTER_RADIUS := 15.0

## 势力色：深邃湖蓝 / 副官盟友青 / 暗红紫（都不用高饱和纯红纯蓝）
const TINT_PLAYER := Color(0.16, 0.47, 0.70)
const TINT_ALLY := Color(0.18, 0.59, 0.63)
const TINT_ENEMY := Color(0.55, 0.15, 0.28)

var _factions: Array = []
var _buildings: Array = []
var _clusters: Array = []
var _fade: float = 0.0
var _target: float = 0.0
var _built: bool = false
var _retry: int = 0
var _mask_tex: ImageTexture = null
var _grid_mat: ShaderMaterial = null
var _ring_mats: Array = []
## 被我们藏起来的模型：instance_id -> 隐藏前的 visible
var _hidden: Dictionary = {}
var _hide_tick: float = 0.0
## 规划阶段会临时生成“工地”（玩家点建造）：建筑集合变了要重建一次势力场/兵牌数据
var _dirty: bool = false
var _dirty_t: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "规划沙盘"
	add_to_group("planning_sandbox")
	visible = false
	if Game != null:
		Game.phase_changed.connect(_on_phase_changed)
		# 规划阶段点“建造”→ 工地立刻进世界；兵牌/势力场要跟着出现（玩家点名要虚线框）
		Game.unit_spawned.connect(_on_world_changed)
		Game.unit_died.connect(_on_world_changed)
		Game.building_completed.connect(_on_world_changed)
	if Game != null and Game.short_match and Game.is_planning():
		# ★ 同步建：主场景 _ready 紧接着就要按锚点取景（等 deferred 会取到空锚点）。
		_build()


func _on_phase_changed(_old: int, new_phase: int) -> void:
	if Game == null or not Game.short_match:
		return
	if new_phase == RtsConst.Phase.PLANNING:
		# 回规划：重建一次（这一回合可能新盖了建筑/死了建筑），同步建好给镜头取景用。
		_build()
		_target = 1.0
	else:
		_target = 0.0
		_restore_models()


## 世界实体增删（规划里点建造 / 拆建筑 / 兵死）→ 下一拍重建数据
func _on_world_changed(_unit: Variant = null) -> void:
	_dirty = true
	_dirty_t = 0.0


func set_fade(v: float) -> void:
	_target = clampf(v, 0.0, 1.0)


func zone_list() -> Array:
	return _factions


func faction_items() -> Array:
	return _factions


func building_items() -> Array:
	return _buildings


func cluster_items() -> Array:
	return _clusters


func is_built() -> bool:
	return _built


## 取景点：有建筑的阵营 → 基地 ±24m 四个角 + 每座建筑；没有 → 整张地图四角。
func camera_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	var size: float = _map_size()
	var half: float = size * 0.5
	if _factions.is_empty():
		out.append(Vector3(-half, 0.0, -half))
		out.append(Vector3(half, 0.0, -half))
		out.append(Vector3(half, 0.0, half))
		out.append(Vector3(-half, 0.0, half))
		return out
	# ★ 只框“基地 + 一圈营地”，不逐座建筑取点：
	#   最外圈的伐木场常常就在底栏后面，把它当取景点会把整张图推到 400m 外、
	#   反而让主基地和意图牌缩成一小团。基地 ±18m 已覆盖营地主体。
	for it in _factions:
		var a: Vector3 = it["anchor"]
		var r: float = 18.0
		out.append(a + Vector3(-r, 0.0, -r))
		out.append(a + Vector3(r, 0.0, -r))
		out.append(a + Vector3(r, 0.0, r))
		out.append(a + Vector3(-r, 0.0, r))
	return out


func focus_hint() -> Vector3:
	if Game != null and Game.player_faction != null:
		for it in _factions:
			if it["faction"] == Game.player_faction:
				return it["anchor"]
	if not _factions.is_empty():
		return _factions[0]["anchor"]
	return Vector3.ZERO


# ===========================================================================
# 生命周期 / 淡入淡出
# ===========================================================================

func _process(delta: float) -> void:
	if _built and Game != null and Game.short_match and Game.is_planning():
		_hide_tick += delta
		if _dirty:
			_dirty_t += delta
			if _dirty_t >= 0.22:
				_dirty = false
				_dirty_t = 0.0
				_build()
		if _hide_tick >= 0.3:
			_hide_tick = 0.0
			_hide_models()

	if is_equal_approx(_fade, _target):
		if _target <= 0.001 and visible:
			visible = false
		return
	var step: float = FADE_SPEED * delta
	_fade = move_toward(_fade, _target, step)
	if _fade > 0.001:
		visible = true
	if _grid_mat != null:
		_grid_mat.set_shader_parameter("fade", _fade)
	for m in _ring_mats:
		if m != null:
			(m as ShaderMaterial).set_shader_parameter("fade", _fade)
	if _fade <= 0.001:
		visible = false


# ===========================================================================
# 建局：阵营 / 建筑 / 单位聚合 / 势力场 / 网格 / 光环
# ===========================================================================

func _build() -> void:
	var lv: Node3D = RtsWorld.level()
	if lv == null or lv.get("terrain") == null:
		_retry += 1
		if _retry < 40:
			_build.call_deferred()
		return
	_clear()
	var player: RtsFaction = Game.player_faction if Game != null else null
	for f in Game.factions:
		if f == null or not is_instance_valid(f):
			continue
		var recs: Array = []
		for b in f.buildings:
			if b == null or not is_instance_valid(b) or not (b is RtsBuilding):
				continue
			var bb := b as RtsBuilding
			if not bb.is_alive() or bb.def == null:
				continue
			var rec := {
				"node": bb,
				"faction": f,
				"mine": player != null and player.is_ally_of(f),
				"color": Color.WHITE,
				"def": bb.def,
				"pos": bb.global_position,
				"constructed": bool(bb.is_constructed),
				"progress": clampf(float(bb.progress), 0.0, 1.0),
			}
			rec["color"] = _tint_for(f, rec["mine"])
			recs.append(rec)
		if recs.is_empty():
			continue
		var mine: bool = player != null and player.is_ally_of(f)
		var col: Color = _tint_for(f, mine)
		for rec in recs:
			rec["color"] = col
			_buildings.append(rec)
		_factions.append({
			"faction": f,
			"mine": mine,
			"color": col,
			"anchor": lv.base_center(f),
			"buildings": recs,
		})
	_rebuild_clusters()
	_build_mask()
	_build_grid(lv)
	_build_rings()
	_built = true
	_dirty = false
	if Game.is_planning():
		_target = 1.0
		_hide_models()


func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_factions.clear()
	_buildings.clear()
	_clusters.clear()
	_ring_mats.clear()
	_mask_tex = null
	_grid_mat = null
	_built = false


func _tint_for(f: RtsFaction, mine: bool) -> Color:
	if mine:
		return TINT_PLAYER if (Game != null and f == Game.player_faction) else TINT_ALLY
	return TINT_ENEMY


func _map_size() -> float:
	var size: float = 224.0
	var lv: Node3D = RtsWorld.level()
	if lv != null and float(lv.get("world_size")) > 1.0:
		size = float(lv.get("world_size"))
	elif Cfg != null and Cfg.game != null:
		size = maxf(float(Cfg.game.map_size), 60.0)
	return size


# ===========================================================================
# 单位聚合（兵牌上的 ×N）
# ===========================================================================

func _rebuild_clusters() -> void:
	_clusters.clear()
	for it in _factions:
		var f: RtsFaction = it["faction"]
		var by_id: Dictionary = {}
		for u in f.units:
			if u == null or not is_instance_valid(u) or not (u is RtsUnit):
				continue
			var ru := u as RtsUnit
			if not ru.is_alive() or ru.def == null:
				continue
			var key := String(ru.def.id)
			if not by_id.has(key):
				by_id[key] = []
			(by_id[key] as Array).append(ru)
		for key in by_id.keys():
			var groups: Array = []
			for u in by_id[key]:
				var p: Vector3 = (u as Node3D).global_position
				var found: Dictionary = {}
				for g in groups:
					if Vector2(g["center"].x - p.x, g["center"].z - p.z).length() \
							<= CLUSTER_RADIUS:
						found = g
						break
				if found.is_empty():
					groups.append({"center": p, "units": [u], "n": 1})
				else:
					var n: int = int(found["n"]) + 1
					found["center"] = (found["center"] * float(n - 1) + p) / float(n)
					found["n"] = n
					(found["units"] as Array).append(u)
			for g in groups:
				var lead: RtsUnit = (g["units"] as Array)[0] as RtsUnit
				_clusters.append({
					"faction": f,
					"mine": bool(it["mine"]),
					"color": it["color"],
					"def": lead.def,
					"center": g["center"],
					"count": int(g["n"]),
					# 兵牌点击要能选回**这面牌上的真实单位**（不是另挑一个最近的）：
					# 规划地图层只读这个数组，不自己再扫世界。
					"units": (g["units"] as Array).duplicate(),
				})


# ===========================================================================
# 势力场贴图：每座建筑一个柔和辐射核，叠加成不规则领地
# ===========================================================================

func _build_mask() -> void:
	var res: int = MASK_RES
	var size: float = _map_size()
	var cell: float = size / float(res)
	var half: float = size * 0.5
	var mine_f := PackedFloat32Array()
	var foe_f := PackedFloat32Array()
	mine_f.resize(res * res)
	foe_f.resize(res * res)
	mine_f.fill(0.0)
	foe_f.fill(0.0)

	for rec in _buildings:
		# ★ PackedFloat32Array 是值类型：不能 var target = mine_f 再写 target（写的是副本）。
		var is_mine: bool = bool(rec["mine"])
		var pos: Vector3 = rec["pos"]
		var radius: float = _territory_radius(rec)
		var strength: float = _territory_strength(rec)
		var x0: int = clampi(floori((pos.x - radius + half) / cell), 0, res - 1)
		var x1: int = clampi(ceili((pos.x + radius + half) / cell), 0, res - 1)
		var z0: int = clampi(floori((pos.z - radius + half) / cell), 0, res - 1)
		var z1: int = clampi(ceili((pos.z + radius + half) / cell), 0, res - 1)
		for pz in range(z0, z1 + 1):
			var wz: float = -half + (float(pz) + 0.5) * cell
			var dz: float = wz - pos.z
			for px in range(x0, x1 + 1):
				var wx: float = -half + (float(px) + 0.5) * cell
				var d: float = sqrt((wx - pos.x) * (wx - pos.x) + dz * dz)
				var t: float = clampf(1.0 - d / maxf(radius, 0.5), 0.0, 1.0)
				if t <= 0.0:
					continue
				var w: float = pow(t, 1.65) * strength
				var i: int = pz * res + px
				if is_mine:
					mine_f[i] = minf(mine_f[i] + w, 1.0)
				else:
					foe_f[i] = minf(foe_f[i] + w, 1.0)

	var data := PackedByteArray()
	data.resize(res * res * 4)
	for pz in range(res):
		var wz2: float = -half + (float(pz) + 0.5) * cell
		var edge_z: float = half - absf(wz2)
		for px in range(res):
			var wx2: float = -half + (float(px) + 0.5) * cell
			var edge: float = minf(half - absf(wx2), edge_z)
			# 地图边缘 4m 内淡出：网格/领地不许在地图边界切出一条硬边
			var ef: float = clampf(edge / 4.0, 0.0, 1.0)
			ef = ef * ef * (3.0 - 2.0 * ef)
			var i: int = pz * res + px
			var j: int = i * 4
			data[j] = int(clampf(mine_f[i] * ef, 0.0, 1.0) * 255.0)
			# 敌方营地铺得更开（基地+哨塔+三座生产建筑），同样场值下看起来会比
			# 玩家紧凑营地“空”一档；给 G 通道 15% 的偏置，让暗红领地也读成一片。
			data[j + 1] = int(clampf(foe_f[i] * ef * 1.15, 0.0, 1.0) * 255.0)
			data[j + 2] = 0
			data[j + 3] = 255
	var img := Image.create_from_data(res, res, false, Image.FORMAT_RGBA8, data)
	img.generate_mipmaps()
	_mask_tex = ImageTexture.create_from_image(img)


## 建筑辐射半径（米）：基地最大，哨塔次之，其余一圈；工地只有一小圈。
func _territory_radius(rec: Dictionary) -> float:
	if not bool(rec["constructed"]):
		return 9.0
	var d: UnitDef = rec["def"]
	if d == null:
		return 10.0
	var id := String(d.id)
	if d.is_dropoff and d.dropoff_kinds.is_empty():
		return 34.0
	if id.contains("tower"):
		return 16.0
	if id.contains("barracks") or id.contains("blacksmith") or id.contains("workshop") \
			or id.contains("sanctum"):
		return 14.0
	return 12.0


## 辐射强度：基地最亮，塔/兵营略低；工地很淡（读得出“还没建成”）。
func _territory_strength(rec: Dictionary) -> float:
	if not bool(rec["constructed"]):
		return 0.42
	var d: UnitDef = rec["def"]
	if d == null:
		return 0.7
	var id := String(d.id)
	if d.is_dropoff and d.dropoff_kinds.is_empty():
		return 1.0
	if id.contains("tower"):
		return 0.85
	return 0.72


# ===========================================================================
# 全图网格 mesh（与领地共用同一个 shader）
# ===========================================================================

func _build_grid(lv: Node3D) -> void:
	var size: float = _map_size()
	var half: float = size * 0.5
	var n: int = maxi(int(ceil(size / MESH_STEP)), 1)
	var rows: Array = []
	for iz in n + 1:
		var row := PackedVector3Array()
		var z: float = minf(-half + float(iz) * MESH_STEP, half)
		for ix in n + 1:
			var x: float = minf(-half + float(ix) * MESH_STEP, half)
			row.append(Vector3(x, RtsWorld.height_at(x, z) + LIFT, z))
		rows.append(row)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in n:
		for ix in n:
			var a: Vector3 = rows[iz][ix]
			var b: Vector3 = rows[iz][ix + 1]
			var c: Vector3 = rows[iz + 1][ix + 1]
			var d: Vector3 = rows[iz + 1][ix]
			_grid_tri(st, a, b, c, half, size)
			_grid_tri(st, a, c, d, half, size)
	var mi := MeshInstance3D.new()
	mi.name = "sandbox_grid"
	mi.mesh = st.commit()
	_grid_mat = ShaderMaterial.new()
	_grid_mat.shader = load(SHADER_PATH)
	_grid_mat.set_shader_parameter("map_min", Vector2(-half, -half))
	_grid_mat.set_shader_parameter("map_size", Vector2(size, size))
	_grid_mat.set_shader_parameter("territory", _mask_tex)
	_grid_mat.set_shader_parameter("player_color", TINT_PLAYER)
	_grid_mat.set_shader_parameter("enemy_color", TINT_ENEMY)
	_grid_mat.set_shader_parameter("fade", _fade)
	mi.material_override = _grid_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)


func _grid_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		half: float, size: float) -> void:
	for v in [a, b, c]:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2((v.x + half) / size, (v.z + half) / size))
		st.add_vertex(v)


# ===========================================================================
# 建筑辐射光环（每座建筑一圈柔和脉冲，锚点读得出来）
# ===========================================================================

func _build_rings() -> void:
	var buckets: Dictionary = {}
	for rec in _buildings:
		# 只给“真正的锚点”画脉冲圈：基地与哨塔。每座农场/兵营都套一圈会变成
		# 一地同心圆，既吵又像选中圈；领地本身已经以所有建筑为圆心辐射了。
		var dd: UnitDef = rec.get("def", null)
		if dd == null or not (dd.is_dropoff or String(dd.id).contains("tower")):
			continue
		var col: Color = rec["color"]
		var key := col.to_html(false)
		if not buckets.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			buckets[key] = {"st": st, "color": col}
		_add_ring(buckets[key]["st"], rec)
	for key in buckets.keys():
		var entry: Dictionary = buckets[key]
		var st: SurfaceTool = entry["st"]
		var mi := MeshInstance3D.new()
		mi.name = "sandbox_ring_" + String(key)
		mi.mesh = st.commit()
		var mat := ShaderMaterial.new()
		mat.shader = load(RING_SHADER)
		mat.set_shader_parameter("ring_color", entry["color"])
		mat.set_shader_parameter("fade", _fade)
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(mi)
		_ring_mats.append(mat)


func _add_ring(st: SurfaceTool, rec: Dictionary) -> void:
	var d: UnitDef = rec["def"]
	if d == null:
		return
	var pos: Vector3 = rec["pos"]
	var fp: Vector2i = d.footprint
	var r0: float = maxf(2.2, float(maxi(fp.x, fp.y)) * 0.55 + 1.0)
	var r1: float = r0 + (1.6 if bool(rec["constructed"]) else 1.0)
	var seg: int = 40
	for i in seg:
		var a0: float = TAU * float(i) / float(seg)
		var a1: float = TAU * float(i + 1) / float(seg)
		var p00 := Vector3(pos.x + cos(a0) * r0, 0.0, pos.z + sin(a0) * r0)
		var p01 := Vector3(pos.x + cos(a0) * r1, 0.0, pos.z + sin(a0) * r1)
		var p10 := Vector3(pos.x + cos(a1) * r0, 0.0, pos.z + sin(a1) * r0)
		var p11 := Vector3(pos.x + cos(a1) * r1, 0.0, pos.z + sin(a1) * r1)
		p00.y = RtsWorld.height_at(p00.x, p00.z) + RING_LIFT
		p01.y = RtsWorld.height_at(p01.x, p01.z) + RING_LIFT
		p10.y = RtsWorld.height_at(p10.x, p10.z) + RING_LIFT
		p11.y = RtsWorld.height_at(p11.x, p11.z) + RING_LIFT
		# uv.x：0 = 内圈，1 = 外圈（光环 shader 用径向做脉冲）
		_ring_tri(st, p00, p01, p11, 0.0, 1.0, 1.0)
		_ring_tri(st, p00, p11, p10, 0.0, 1.0, 0.0)


func _ring_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		ua: float, ub: float, uc: float) -> void:
	for pr in [[a, ua], [b, ub], [c, uc]]:
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(float(pr[1]), 0.0))
		st.add_vertex(pr[0] as Vector3)


# ===========================================================================
# 模型隐藏 / 还原（规划阶段只留兵牌）
# ===========================================================================

func _hide_models() -> void:
	if Game == null:
		return
	for f in Game.factions:
		if f == null or not is_instance_valid(f):
			continue
		for n in f.units:
			_hide_one(n)
		for n in f.buildings:
			_hide_one(n)


func _hide_one(n: Variant) -> void:
	if n == null or not is_instance_valid(n) or not (n is Node3D):
		return
	var node := n as Node3D
	var id: int = node.get_instance_id()
	if _hidden.has(id):
		return
	_hidden[id] = node.visible
	node.visible = false


func _restore_models() -> void:
	for id in _hidden.keys():
		var raw: Variant = instance_from_id(int(id))
		if raw is Node3D and is_instance_valid(raw):
			(raw as Node3D).visible = bool(_hidden[id])
	_hidden.clear()
