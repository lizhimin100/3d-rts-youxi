class_name BuildSite
extends Node3D
## **工地表现**：建筑从"放下"到"完工"这段时间的施工现场（SLEDGE 名下）。
##
## 分工：本节点只负责"看起来在盖房子"，不碰任何玩法数据 ——
##   进度仍然由 RtsBuilding.advance_construction() 推进，本节点只在 set_progress() 里跟。
##
## **两条路径（优先资产、缺档回落程序化）**：
##
## ① 资产路径（9 座建筑）：`美术/模型/建造/<id>_build.glb` 内嵌 `build` 动画，
##    自带脚手架 / 料堆 / 围挡。动画**不自己播**，由 `set_progress()` seek —— 多个农民
##    同时建、停工、被拆，动画都跟真实进度走，不会跑偏。成品模型（`visual`）隐藏。
## ② 程序化路径（营火 / 火堆 / 火把 / 火炬 等没有 `_建造.glb` 的）：
##   下面这四层老结构原样保留，行为与以前一模一样。
##
## 程序化四层结构（自下而上）：
##   ① 地基：比占地略大的石台 + 四角角石（"这里已经放线了"）—— 两条路径都建
##   ② 料堆：石料堆 / 木料堆 / 绳圈（越建越少）
##   ③ 脚手架：8 根立柱随进度长高 + 4 层横杆按高度显隐 + 平台 / 梯子 / 斜撑
##   ④ 主体：给建筑的每个材质副本塞 clip_height，墙从 0 长到层高（着色器逐片元丢弃）
##
## 锤击反馈由 RtsBuilding 在农民抡锤时调 strike()，**按工地**做 0.9s 节流，
## 所以 3 个农民同时干也只是一工地一节奏，不会变成机关枪。两条路径都有。

## 锤击最小间隔（秒）——任务书要求 0.7~1.2s 一次
const STRIKE_INTERVAL: float = 0.9

## 建造资产目录 + 编号 → 文件名（缺档的 id 不出现在表里 → 走程序化脚手架）
const BUILD_MODEL_DIR: String = "res://美术/模型/建造/"
const BUILD_ANIM: StringName = &"build"
const BUILD_MODEL: Dictionary = {
	&"townhall": "townhall_build.glb",
	&"barracks": "barracks_build.glb",
	&"farm": "farm_build.glb",
	&"lumbercamp": "lumbercamp_build.glb",
	&"watchtower": "watchtower_build.glb",
	&"tower": "tower_build.glb",
	&"blacksmith": "blacksmith_build.glb",
	&"sanctum": "sanctum_build.glb",
	&"workshop": "workshop_build.glb",
}
## 表现层随机流（锤击方位 / 脚手架散落方向）。玩法随机仍走全局 randf，见 表现随机.gd
const Fx := preload("res://代码/美术/表现随机.gd")
## 建造显影 shader：把资产的 StandardMaterial3D 换成"世界高度裁剪"版本
## （资产自带的 reveal_height shader 不在仓库里，见 美术/着色器/建造显影.gdshader 的注释）
const CLIP_SHADER := preload("res://美术/着色器/建造显影.gdshader")
## 脚手架横杆层数与高度比例
const RAIL_LEVELS: PackedFloat32Array = [0.26, 0.50, 0.74, 0.96]

## 宿主建筑（故意只按 Node3D 鸭子类型用：避免"建筑 ↔ 工地"两个脚本 preload 成环）
var building: Node3D = null
var _fp: Vector2i = Vector2i(4, 4)
var _height: float = 4.0
var _hx: float = 2.4
var _hz: float = 2.4
var _progress: float = 0.0
var _done: bool = false

## 脚手架零件
var _posts: Array[MeshInstance3D] = []
var _rails: Array[MeshInstance3D] = []
var _rail_levels: Array[float] = []
var _braces: Array[MeshInstance3D] = []
var _platform: Node3D = null
var _ladder: Node3D = null
var _ladder_scale_root: Node3D = null
var _piles: Array[Node3D] = []

## 剖切材质副本：{ "mi": MeshInstance3D, "i": int, "prev": Material, "mat": ShaderMaterial }
var _clip: Array = []
var _clip_ok: bool = false
var _fallback_scale: bool = false

## 资产建造模型（挂 `build` 动画的那个 holder；null = 走程序化脚手架）
var _build_model: Node3D = null
## 建造模型里"随进度长高"的主体网格（墙 + 屋顶；脚手架不动）
var _body: Node3D = null
var _ap: AnimationPlayer = null
var _ap_len: float = 0.0
## 报警只打一次（同一栋楼反复建不该刷屏）
static var _warned: Dictionary = {}

## 锤击节流
var _last_strike_ms: int = -10000
var strike_count: int = 0

## 材质（一份够用，工地不染色）
var _wood: StandardMaterial3D
var _wood_light: StandardMaterial3D
var _rope: StandardMaterial3D
var _stone: StandardMaterial3D
var _stone_light: StandardMaterial3D
var _iron: StandardMaterial3D


# ===========================================================================
# 装配
# ===========================================================================

## 挂到一栋"工地状态"的建筑上。必须在建筑的 visual 建好之后调（setup_construction 里）。
func attach(b: Node3D, team_color: Color = Color.WHITE) -> void:
	building = b
	name = "工地"
	if b == null:
		return
	var d: UnitDef = b.get("def")
	if d == null:
		return
	_fp = d.footprint
	if _fp == Vector2i.ZERO:
		_fp = Vector2i(1, 1)
	_height = maxf(d.height, 1.2)
	_hx = float(_fp.x) * 0.5 + 0.42
	_hz = float(_fp.y) * 0.5 + 0.42

	_make_materials()
	# 夯土台两条路径都建：它负责遮住地形接缝，资产里的"施工场地"也压不住这道缝
	_build_foundation()
	# 优先用资产自带的施工动画；缺档 / 缺动画 / 实例化失败一律回落到程序化四层
	if _try_attach_build_model(d, team_color):
		_collect_clip_from(_build_model)
	else:
		_build_piles()
		_build_scaffold()
		_collect_clip()
	set_progress(0.0)
	# 工地落地的第一声（石料/木架/碎石）。完工音不在这里 —— 由 building_completed
	# 信号统一交给 Sfx._on_built()，否则同一次完工会被播两遍。
	Sfx.play_at("建造_放置", building.global_position, 0.0)


## 资产建造模型：找到 → 挂上并按进度驱动；缺档 / 缺 `build` 动画 → 返回 false（回落旧路径）
##
## 三条硬规矩：
##   ① transform 全盘照抄 `visual`（位置 / 旋转 / 缩放）—— 朝向由 building 的
##      `建筑网格.DEFAULT_YAW` 决定，这里绝不自作主张转一个角度；
##   ② `play("build")` → `speed_scale = 0` → `seek(0)`：动画时轴交给进度，
##      3 个农民同时建 / 停工 / 被拆都不会和真实进度脱节；
##   ③ 隐藏 `visual`，成品模型只在 finish() 里露脸。
func _try_attach_build_model(d: UnitDef, team_color: Color) -> bool:
	var fname: String = String(BUILD_MODEL.get(d.id, ""))
	if fname.is_empty():
		return false
	var path: String = BUILD_MODEL_DIR + fname
	if not ResourceLoader.exists(path):
		_warn_once("缺档:" + fname, "[工地] 缺建造模型 %s，回落程序化脚手架" % path)
		return false
	var vis := building.get("visual") as Node3D
	if vis == null:
		return false
	var model: Node3D = ArtKit.build_model(path, d.model_scale)
	if model == null:
		_warn_once("实例化:" + fname, "[工地] 建造模型实例化失败 %s，回落程序化脚手架" % path)
		return false
	var ap := _find_anim_player(model)
	if ap == null or not ap.has_animation(BUILD_ANIM):
		_warn_once("动画:" + fname, "[工地] %s 里没有 %s 动画，回落程序化脚手架" % [path, BUILD_ANIM])
		model.free()
		return false
	var len: float = ap.get_animation(BUILD_ANIM).length
	if len <= 0.001:
		_warn_once("空动画:" + fname, "[工地] %s 的 %s 动画长度为 0，回落程序化脚手架" % [path, BUILD_ANIM])
		model.free()
		return false

	# 阵营色：资产用 material 名 `team` / `team_trim` 当染色接口（与成品模型同一条路）
	ArtKit.apply_team_color(model, team_color)

	# holder 的 transform 直接抄 visual：这样建造模型和成品模型同原点、同朝向、同缩放
	var holder := Node3D.new()
	holder.name = "建造模型"
	holder.transform = vis.transform
	holder.add_child(model)
	building.add_child(holder)

	# 纵向生长的对象：资产里 `Building` 是静态主体（墙 + 屋顶），`SiteKit` 是脚手架。
	# 只压主体、不压脚手架 —— 整模一起压的话，低进度时脚手架跟着被压成扁片，
	# 现场图会读成"模型坏了"而不是"房子盖到一半"。（找不到主体就退回整模）
	_body = _find_body(model)

	_ap = ap
	_ap_len = len
	_ap.play(BUILD_ANIM)
	_ap.speed_scale = 0.0
	_ap.seek(0.0, true)
	_build_model = holder
	vis.visible = false
	return true


## 深度优先找第一个 AnimationPlayer（glb 里它挂在 BuildRig 同级）
func _find_anim_player(root: Node) -> AnimationPlayer:
	var ap := root as AnimationPlayer
	if ap != null:
		return ap
	for c in root.get_children():
		var found := _find_anim_player(c)
		if found != null:
			return found
	return null


## 资产里非蒙皮的 `Building` 主体（墙 + 屋顶）。找不到返回 null → 退回整模纵向压缩。
## 只认 MeshInstance3D 且没有 skin：脚手架 SiteKit 是蒙皮的，动画在驱动它，绝不能动它。
func _find_body(root: Node) -> Node3D:
	var mi := root as MeshInstance3D
	if mi != null and mi.name == "Building" and mi.skin == null and mi.mesh != null:
		return mi
	for c in root.get_children():
		var found := _find_body(c)
		if found != null:
			return found
	return null


## 同一条告警只打一次（asset 缺档不该每建一次刷一条）
static func _warn_once(key: String, msg: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(msg)


func _make_materials() -> void:
	_wood = _standard(Color(0.40, 0.28, 0.16), 0.9)
	_wood_light = _standard(Color(0.55, 0.41, 0.25), 0.88)
	_rope = _standard(Color(0.62, 0.55, 0.36), 0.95)
	_stone = _standard(Color(0.44, 0.43, 0.40), 0.92)
	_stone_light = _standard(Color(0.57, 0.55, 0.51), 0.9)
	_iron = _standard(Color(0.30, 0.30, 0.33), 0.7)


## 把料堆贴到它所在位置的地面（斜地形上不悬空）
func _snap_to_ground(n: Node3D) -> void:
	if building == null or n == null:
		return
	var wp: Vector3 = building.global_position + n.position
	n.position.y = RtsWorld.height_at(wp.x, wp.z) - building.global_position.y + 0.02


func _standard(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


## ① 地基：3×3 砌块台面 + 一圈立起来的石砌边 + 四角角石
## 为什么不做一整块大板：斜地形上大板会一边翘起来像块飞碟；
## 砌块 + 立边读起来才是"这里已经放线、基础砌了一半"。
func _build_foundation() -> void:
	# 基槽：往地下埋 1.6m 的土台，斜地形上地基边缘不会悬空（比把地基做厚更便宜）
	var earth := _standard(Color(0.30, 0.24, 0.17), 1.0)
	add_child(_box(Vector3(float(_fp.x) + 0.75, 1.6, float(_fp.y) + 0.75),
			Vector3(0.0, -0.72, 0.0), earth))

	var nx: int = 3
	var nz: int = 3
	var tw: float = float(_fp.x) / float(nx)
	var td: float = float(_fp.y) / float(nz)
	for ix in nx:
		for iz in nz:
			var c := Vector3(-float(_fp.x) * 0.5 + tw * (float(ix) + 0.5), 0.055,
					-float(_fp.y) * 0.5 + td * (float(iz) + 0.5))
			add_child(_box(Vector3(tw * 0.93, 0.11, td * 0.93), c,
					_stone_light if (ix + iz) % 2 == 0 else _stone))

	# 立起来的石砌边（四边各一条，像刚砌到勒脚）
	var rim_h: float = 0.24
	add_child(_box(Vector3(float(_fp.x) + 0.16, rim_h, 0.26),
			Vector3(0.0, rim_h * 0.5 + 0.10, -float(_fp.y) * 0.5 - 0.06), _stone_light))
	add_child(_box(Vector3(float(_fp.x) + 0.16, rim_h, 0.26),
			Vector3(0.0, rim_h * 0.5 + 0.10, float(_fp.y) * 0.5 + 0.06), _stone_light))
	add_child(_box(Vector3(0.26, rim_h, float(_fp.y) + 0.16),
			Vector3(-float(_fp.x) * 0.5 - 0.06, rim_h * 0.5 + 0.10, 0.0), _stone))
	add_child(_box(Vector3(0.26, rim_h, float(_fp.y) + 0.16),
			Vector3(float(_fp.x) * 0.5 + 0.06, rim_h * 0.5 + 0.10, 0.0), _stone))

	# 四角角石
	var cx: float = float(_fp.x) * 0.5 + 0.10
	var cz: float = float(_fp.y) * 0.5 + 0.10
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			add_child(_box(Vector3(0.46, 0.42, 0.46), Vector3(sx * cx, 0.21, sz * cz), _stone_light))

	# 施工放线：四边压一圈窄木条（"施工放线"的读感）
	add_child(_box(Vector3(float(_fp.x) + 1.0, 0.03, 0.06), Vector3(0.0, 0.03, -_hz + 0.10), _rope))
	add_child(_box(Vector3(float(_fp.x) + 1.0, 0.03, 0.06), Vector3(0.0, 0.03, _hz - 0.10), _rope))
	add_child(_box(Vector3(0.06, 0.03, float(_fp.y) + 1.0), Vector3(-_hx + 0.10, 0.03, 0.0), _rope))
	add_child(_box(Vector3(0.06, 0.03, float(_fp.y) + 1.0), Vector3(_hx - 0.10, 0.03, 0.0), _rope))


## ② 料堆：石料 / 木料 / 绳圈，进度过半后收走
func _build_piles() -> void:
	var pile_a := Node3D.new()
	pile_a.name = "石料堆"
	pile_a.position = Vector3(-_hx + 0.55, 0.0, -_hz + 0.55)
	add_child(pile_a)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261018
	for i in 7:
		var s: float = rng.randf_range(0.18, 0.34)
		var mi := _box(Vector3(s, s, s * rng.randf_range(0.7, 1.2)),
				Vector3(rng.randf_range(-0.28, 0.28), s * 0.5 + 0.02,
						rng.randf_range(-0.28, 0.28)), _stone_light if i % 2 == 0 else _stone)
		mi.rotation.y = rng.randf() * TAU
		pile_a.add_child(mi)
	_snap_to_ground(pile_a)
	_piles.append(pile_a)

	var pile_b := Node3D.new()
	pile_b.name = "木料堆"
	pile_b.position = Vector3(_hx - 0.55, 0.0, _hz - 0.65)
	add_child(pile_b)
	for i in 6:
		var beam := _box(Vector3(1.5, 0.13, 0.13),
				Vector3(0.0, 0.07 + float(i) * 0.135, 0.0), _wood if i % 2 == 0 else _wood_light)
		beam.rotation.y = (0.0 if i < 3 else PI * 0.5)
		pile_b.add_child(beam)
	_snap_to_ground(pile_b)
	_piles.append(pile_b)

	# 绳圈：一个躺着的圆环
	var coil := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.16
	tm.outer_radius = 0.26
	tm.rings = 14
	tm.ring_segments = 6
	coil.mesh = tm
	coil.material_override = _rope
	coil.position = Vector3(-_hx + 0.5, 0.06, _hz - 0.6)
	coil.rotation.x = PI * 0.5
	add_child(coil)
	_snap_to_ground(coil)
	_piles.append(coil)


## ③ 脚手架：立柱 / 横杆 / 斜撑 / 平台 / 梯子
func _build_scaffold() -> void:
	var root := Node3D.new()
	root.name = "脚手架"
	add_child(root)

	# 立柱：8 根（四角 + 四边中点），单位高度 1，靠 scale.y 长高
	var spots: Array = []
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			spots.append(Vector3(sx * _hx, 0.0, sz * _hz))
	spots.append(Vector3(0.0, 0.0, -_hz))
	spots.append(Vector3(0.0, 0.0, _hz))
	spots.append(Vector3(-_hx, 0.0, 0.0))
	spots.append(Vector3(_hx, 0.0, 0.0))
	for s in spots:
		var post := _box(Vector3(0.06, 1.0, 0.06), Vector3(s.x, 0.5, s.z), _wood)
		root.add_child(post)
		_posts.append(post)

	# 横杆：每层 4 根（前后左右），按进度显隐
	for lv in RAIL_LEVELS:
		var y: float = _height * float(lv)
		var a := _box(Vector3(_hx * 2.0, 0.05, 0.05), Vector3(0.0, y, -_hz), _wood_light)
		var b := _box(Vector3(_hx * 2.0, 0.05, 0.05), Vector3(0.0, y, _hz), _wood_light)
		var c := _box(Vector3(0.05, 0.05, _hz * 2.0), Vector3(-_hx, y, 0.0), _wood_light)
		var d := _box(Vector3(0.05, 0.05, _hz * 2.0), Vector3(_hx, y, 0.0), _wood_light)
		for r in [a, b, c, d]:
			root.add_child(r)
			_rails.append(r)
			_rail_levels.append(float(lv))

	# 斜撑：四个面上各一根 45° 木条（按进度显隐，避免一开工就满身线条）
	var brace_len: float = sqrt(pow(_hx * 2.0, 2.0) + pow(_height * 0.5, 2.0))
	var ba := _box(Vector3(brace_len, 0.05, 0.05), Vector3(0.0, 0.0, -_hz), _wood)
	ba.rotation.z = atan2(_height * 0.5, _hx * 2.0)
	root.add_child(ba)
	_braces.append(ba)
	var bb := _box(Vector3(brace_len, 0.05, 0.05), Vector3(0.0, 0.0, _hz), _wood)
	bb.rotation.z = -atan2(_height * 0.5, _hx * 2.0)
	root.add_child(bb)
	_braces.append(bb)

	# 平台：脚手架顶部两块跳板（一侧沿 X、一侧沿 Z，形成 L 形工作面）
	_platform = Node3D.new()
	_platform.name = "工作平台"
	root.add_child(_platform)
	_platform.add_child(_box(Vector3(_hx * 2.0, 0.05, 0.28), Vector3(0.0, 0.0, -_hz + 0.14), _wood_light))
	_platform.add_child(_box(Vector3(0.28, 0.05, _hz * 2.0), Vector3(_hx - 0.14, 0.0, 0.0), _wood_light))

	# 梯子：正面（-Z）两臂 + 6 根横档，整体随进度长高
	_ladder_scale_root = Node3D.new()
	_ladder_scale_root.name = "梯子"
	_ladder_scale_root.position = Vector3(-_hx + 0.55, 0.0, -_hz - 0.12)
	root.add_child(_ladder_scale_root)
	var lr_a := _box(Vector3(0.045, 1.0, 0.045), Vector3(-0.20, 0.5, 0.0), _wood)
	var lr_b := _box(Vector3(0.045, 1.0, 0.045), Vector3(0.20, 0.5, 0.0), _wood)
	_ladder_scale_root.add_child(lr_a)
	_ladder_scale_root.add_child(lr_b)
	for i in 6:
		var y: float = (float(i) + 0.5) / 6.0
		_ladder_scale_root.add_child(_box(Vector3(0.40, 0.032, 0.032), Vector3(0.0, y, 0.0), _wood_light))
	# 梯子要能"长高"，所以子节点用 0~1 的归一化高度，靠父节点 scale.y 拉伸
	for c in _ladder_scale_root.get_children():
		(c as Node3D).set_meta("unit_y", (c as Node3D).position.y)
	_ladder = _ladder_scale_root


## ④ 剖切：给建筑的每个材质面复制一份带 clip_height 的材质
func _collect_clip() -> void:
	if building == null:
		return
	_collect_clip_from(building.get("visual") as Node3D)


## 通用版：对任意模型子树做剖切（建造模型也走这里）。
## 资产的 StandardMaterial3D 没有 clip_height → 落到 `_fallback_scale`（纵向压缩兜底）。
func _collect_clip_from(root: Node3D) -> void:
	_clip.clear()
	_clip_ok = false
	if root == null:
		_fallback_scale = true
		return
	var meshes := _meshes_of(root)
	for mi in meshes:
		if mi.mesh == null:
			continue
		# material_override 的优先级高于 surface override：有它就必须整体换，
		# 否则我们设了 surface 也看不见（glTF 导入的模型常常是这种）。
		if mi.material_override != null:
			var ov := _clip_material_of(mi.material_override)
			if ov != null:
				_clip.append({"mi": mi, "i": -1, "prev": mi.material_override,
						"mat": ov["mat"], "world": ov["world"]})
				mi.material_override = ov["mat"]
			continue
		for i in mi.mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(i)
			if src == null:
				src = mi.mesh.surface_get_material(i)
			var ov2 := _clip_material_of(src)
			if ov2 == null:
				continue
			_clip.append({"mi": mi, "i": i, "prev": mi.get_surface_override_material(i),
					"mat": ov2["mat"], "world": ov2["world"]})
			mi.set_surface_override_material(i, ov2["mat"])
	_clip_ok = not _clip.is_empty()
	# 一个面都没剖到（没有 clip_height 也不是标准材质）→ 退化成"纵向拉伸"，至少能看出在长
	_fallback_scale = not _clip_ok


## 把一份材质转成"可剖切"的副本。返回 `{mat, world}`；不支持返回 null。
##   · 已经带 clip_height 的卡通 shader → duplicate 后直接用（world=false）
##   · StandardMaterial3D（美术资产）→ 转成 建造显影.gdshader（world=true）
func _clip_material_of(src: Material) -> Dictionary:
	if src == null:
		return {}
	var sm := src as ShaderMaterial
	if sm != null:
		# 注意：不能拿 get_shader_parameter() 判空 —— 没写过的 uniform 返回 null，
		# 但 shader 里其实有默认值。必须查 uniform 列表。
		if not _shader_has(sm, "clip_height"):
			return {}
		var dup := sm.duplicate() as ShaderMaterial
		if dup == null:
			return {}
		dup.set_shader_parameter("clip_height", 0.0)
		return {"mat": dup, "world": false}
	var std := src as StandardMaterial3D
	if std == null:
		return {}
	var conv := _std_to_clip(std)
	if conv == null:
		return {}
	return {"mat": conv, "world": true}


## 工地所在地面的世界 Y（世界裁剪的基准）
func _ground_y() -> float:
	if building == null or not is_instance_valid(building):
		return 0.0
	return building.global_position.y


## 把一份 StandardMaterial3D 转成"世界高度裁剪"的 ShaderMaterial（贴图原样搬过去）。
## 拿不到任何贴图的极端情况（纯色材质）也接 —— albedo_color 本身就够看。
func _std_to_clip(std: StandardMaterial3D) -> ShaderMaterial:
	if std == null or CLIP_SHADER == null:
		return null
	var m := ShaderMaterial.new()
	m.shader = CLIP_SHADER
	m.set_shader_parameter("albedo_color", std.albedo_color)
	m.set_shader_parameter("uv_scale", std.uv1_scale)
	if std.albedo_texture != null:
		m.set_shader_parameter("albedo_tex", std.albedo_texture)
	if std.orm_texture != null:
		m.set_shader_parameter("orm_tex", std.orm_texture)
	m.set_shader_parameter("ao_strength", 1.0 if std.ao_enabled or std.orm_texture != null else 0.0)
	m.set_shader_parameter("emission_color", std.emission)
	m.set_shader_parameter("emission_energy", std.emission_energy_multiplier)
	if std.emission_texture != null:
		m.set_shader_parameter("emission_tex", std.emission_texture)
	# 阵营色那两层（team / team_trim）不在这里改：阵营色由 铁誓建筑/ArtKit 侧注入，
	# 我们只是把颜色搬过来，避免"建造模型是灰的、成品是蓝的"。
	m.set_shader_parameter("clip_world_y", 1.0e9)
	m.set_shader_parameter("edge_glow", 0.0)
	return m


## 当前"该显示的那个模型"：有建造模型就是它，否则是成品 visual。
## 纵向压缩兜底必须作用在**正在显示**的那份上，否则玩家看到的模型不会长。
func _shown_model() -> Node3D:
	if _build_model != null and is_instance_valid(_build_model):
		return _build_model
	if building == null:
		return null
	return building.get("visual") as Node3D


## 纵向压缩兜底真正作用的节点：
##   资产路径 = 建造模型里的 `Building` 主体（脚手架保持原尺寸，工地才立得住）；
##   程序化路径 = 成品 visual（与以前完全一致）。
func _scale_target() -> Node3D:
	if _body != null and is_instance_valid(_body):
		return _body
	return _shown_model()


# ===========================================================================
# 进度驱动
# ===========================================================================

## 每帧由 RtsBuilding 推进（0~1）；本节点只把它翻译成几何 / 动画时轴
func set_progress(p: float) -> void:
	if _done or building == null:
		return
	_progress = clampf(p, 0.0, 1.0)
	var grown: float = _height * _progress

	# 资产建造动画：时轴 = 进度。speed_scale 恒为 0，所以动画永远不会自己往前跑
	if _ap != null and is_instance_valid(_ap) and _ap_len > 0.0:
		_ap.seek(_progress * _ap_len, true)

	# 剖切高度：+0.06 让地面处也有一点厚度，否则进度 0 时连地基都看不见
	if _clip_ok:
		var world_cut: float = _ground_y() + grown + 0.06
		for e in _clip:
			var sm := e["mat"] as ShaderMaterial
			if bool(e.get("world", false)):
				# 资产材质：按**世界 Y** 切（模型自己怎么缩放/旋转都不影响切口水平）
				sm.set_shader_parameter("clip_world_y", world_cut)
				sm.set_shader_parameter("edge_glow", 0.45)
			else:
				sm.set_shader_parameter("clip_height", grown + 0.06)
	elif _fallback_scale:
		var target := _scale_target()
		if target != null:
			target.scale = Vector3(1.0, clampf(_progress, 0.02, 1.0), 1.0)

	# 立柱长高
	var post_h: float = maxf(grown + 0.35, 0.35)
	for post in _posts:
		if not is_instance_valid(post):
			continue
		post.scale.y = post_h
		post.position.y = post_h * 0.5

	# 横杆：过了那个高度才出现
	for i in _rails.size():
		var r: MeshInstance3D = _rails[i]
		if not is_instance_valid(r):
			continue
		r.visible = grown + 0.35 >= _height * _rail_levels[i]

	# 斜撑：盖到 1/3 才开始上
	for b in _braces:
		if is_instance_valid(b):
			b.visible = _progress > 0.32

	# 平台：跟着脚手架顶走
	if _platform != null and is_instance_valid(_platform):
		_platform.visible = _progress > 0.12
		_platform.position.y = grown + 0.42

	# 梯子：归一化子节点靠父节点 scale.y 拉伸
	if _ladder != null and is_instance_valid(_ladder):
		_ladder.scale.y = maxf(post_h, 0.35)
		_ladder.visible = _progress > 0.05

	# 料堆：过半之后陆续"用完"
	for k in _piles.size():
		var pile: Node3D = _piles[k]
		if pile != null and is_instance_valid(pile):
			var thresh: float = 0.55 + 0.12 * float(k)
			pile.visible = _progress < thresh
			var s: float = clampf((thresh - _progress) / 0.25, 0.35, 1.0)
			pile.scale = Vector3(s, s, s)


## 锤击反馈：返回这次是否真的出效果（节流用）
## at 是农民位置（可为空），用来把尘土放在"他正在敲的那一段墙根"
func strike(at: Vector3 = Vector3.ZERO) -> bool:
	if _done or building == null:
		return false
	var now: int = Time.get_ticks_msec()
	if now - _last_strike_ms < int(STRIKE_INTERVAL * 1000.0):
		return false
	_last_strike_ms = now
	strike_count += 1

	var base: Vector3 = building.global_position
	var side := Vector3.ZERO
	if at != Vector3.ZERO and base.distance_squared_to(at) < 400.0:
		side = (at - base)
		side.y = 0.0
		if side.length_squared() > 0.0001:
			side = side.normalized()
	if side == Vector3.ZERO:
		var ang: float = Fx.rand() * TAU
		side = Vector3(cos(ang), 0.0, sin(ang))
	# 墙根位置：占地边缘 + 当前已建高度
	var hit := base + side * Vector3(_hx, 0.0, _hz).length() * 0.62
	hit.y = base.y + clampf(_height * _progress + 0.20, 0.25, _height - 0.25)

	BuildFx.dust(hit, 5, 0.35, Color(0.66, 0.60, 0.48))
	BuildFx.chips(hit, Color(0.60, 0.44, 0.26), 6)
	Sfx.play_at("建造_锤击", hit, -5.0)
	return true


# ===========================================================================
# 完成 / 中途被拆
# ===========================================================================

## 完工：撤掉剖切 → 收起建造模型、露出成品 → 脚手架散落 → 尘土爆发 → 闪一下 → 自毁
func finish() -> void:
	if _done:
		return
	_done = true
	_restore_clip()
	_release_build_model(true)
	if building != null:
		var vis: Node = building.get("visual")
		if vis != null and vis.has_method("flash"):
			vis.call("flash")
		var base: Vector3 = building.global_position
		BuildFx.dust(base + Vector3(0.0, 0.25, 0.0), 16, 1.1, Color(0.70, 0.64, 0.50))
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				BuildFx.dust(base + Vector3(sx * _hx * 0.8, 0.2, sz * _hz * 0.8), 7, 0.7,
						Color(0.64, 0.58, 0.46))
		Game.shake(0.10)
		# 完工音已由 Sfx._on_built()（building_completed 信号）统一播放，这里不再重复
	_collapse_scaffold()
	# 让散落的木头飞完再见
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = 1.5
	add_child(tm)
	tm.timeout.connect(queue_free)
	tm.start()


## 工地还没完工就被拆：建造模型直接丢掉（不留半截资产脚手架），成品 mesh 露出来跟着倒
func abort() -> void:
	if _done:
		return
	_done = true
	_restore_clip()
	_release_build_model(true)
	_collapse_scaffold()
	var base: Vector3 = building.global_position if building != null else global_position
	BuildFx.dust(base + Vector3.UP * 0.4, 14, 1.0, Color(0.66, 0.60, 0.48))
	var tm := Timer.new()
	tm.one_shot = true
	tm.wait_time = 0.9
	add_child(tm)
	tm.timeout.connect(queue_free)
	tm.start()


## 收掉资产建造模型；show_visual 决定要不要把成品模型露出来
## （finish / abort 都要露出 —— abort 时整栋楼要跟着倒塌动画一起倒，藏起来就成了幽灵）
func _release_build_model(show_visual: bool) -> void:
	if _build_model != null:
		if is_instance_valid(_build_model):
			# 先隐藏再 queue_free：释放发生在帧末，否则会和 visual 同帧并存闪一下
			_build_model.visible = false
			_build_model.queue_free()
		_build_model = null
	_body = null
	_ap = null
	_ap_len = 0.0
	if show_visual and building != null:
		var vis := building.get("visual") as Node3D
		if vis != null:
			vis.visible = true


## 撤掉剖切材质（还原成 MatKit 原本那份共享材质）
func _restore_clip() -> void:
	for e in _clip:
		var mi: MeshInstance3D = e["mi"]
		if mi == null or not is_instance_valid(mi):
			continue
		var i: int = int(e["i"])
		# i == -1 表示换的是 material_override（整只网格一份材质）
		if i < 0:
			mi.material_override = e["prev"]
			continue
		if i >= mi.mesh.get_surface_count():
			continue
		mi.set_surface_override_material(i, e["prev"])
	_clip.clear()
	if _fallback_scale:
		var target := _scale_target()
		if target != null:
			target.scale = Vector3.ONE


## 脚手架散落：立柱向外倒、横杆掉地、平台翻下去（0.9s）
func _collapse_scaffold() -> void:
	for n in _posts:
		if is_instance_valid(n):
			_fall(n, Vector3(Fx.rand_range(-0.5, 0.5), 0.0, Fx.rand_range(0.5, 1.3)))
	for n in _rails:
		if is_instance_valid(n):
			_fall(n, Vector3(Fx.rand_range(-0.8, 0.8), 0.0, Fx.rand_range(-0.8, 0.8)), 0.7)
	if _platform != null and is_instance_valid(_platform):
		_fall(_platform, Vector3(Fx.rand_range(-0.5, 0.5), 0.0, Fx.rand_range(-1.0, 1.0)), 1.2)
	if _ladder != null and is_instance_valid(_ladder):
		_fall(_ladder, Vector3(0.0, 0.0, -1.4), 1.1)


func _fall(n: Node3D, dir: Vector3, drop: float = 0.55) -> void:
	var tw := n.create_tween()
	tw.set_parallel(true)
	tw.tween_property(n, "rotation:z", n.rotation.z + dir.x * 1.2, 0.55)
	tw.tween_property(n, "rotation:x", n.rotation.x + dir.z * 1.2, 0.55)
	tw.tween_property(n, "position:y", n.position.y - drop, 0.55)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(n):
			n.visible = false)


# ===========================================================================
# 内部
# ===========================================================================

func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	return mi


## 这个 ShaderMaterial 的 shader 里有没有这个 uniform
func _shader_has(sm: ShaderMaterial, uniform: String) -> bool:
	if sm == null or sm.shader == null:
		return false
	for u in sm.shader.get_shader_uniform_list():
		if String(u.name) == uniform:
			return true
	return false


func _meshes_of(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null:
			out.append(mi)
		for c in n.get_children():
			stack.append(c)
	return out


## 自检用：当前剖切高度（没有剖切材质时返回 -2）
func clip_height() -> float:
	if _clip.is_empty():
		return -2.0
	var sm := _clip[0]["mat"] as ShaderMaterial
	var v: Variant = sm.get_shader_parameter("clip_height")
	return float(v) if v != null else -2.0


## 自检用：当前剖切方式 —— "world"（资产材质，世界 Y 裁剪）/ "local"（卡通 shader）/
## "scale"（都没有，纵向压缩兜底）
func clip_mode() -> String:
	if not _clip.is_empty():
		return "world" if bool(_clip[0].get("world", false)) else "local"
	if _fallback_scale:
		return "scale"
	return "none"


## 自检用：世界裁剪面相对工地地面的高度（非 world 模式返回 -2）
func clip_world_offset() -> float:
	if _clip.is_empty() or not bool(_clip[0].get("world", false)):
		return -2.0
	var sm := _clip[0]["mat"] as ShaderMaterial
	var v: Variant = sm.get_shader_parameter("clip_world_y")
	if v == null:
		return -2.0
	return float(v) - _ground_y()


## 自检用：当前"可见建筑高度"。有 clip_height 着色器走剖切；没有则走纵向压缩兜底。
## 建筑资产是 StandardMaterial3D（硬约束，不能挂自定义 shader），所以后者是常态。
func cut_height() -> float:
	if _done:
		return -2.0
	if _clip_ok:
		# 世界裁剪（资产材质）与本地 clip_height（卡通 shader）语义统一成
		# "相对工地地面已经长到多高"，自检/调试只认这一个数。
		if not _clip.is_empty() and bool(_clip[0].get("world", false)):
			return clip_world_offset()
		return clip_height()
	if _fallback_scale:
		var target := _scale_target()
		if target != null:
			return _height * target.scale.y
	return -2.0


## 自检用：是不是走了资产建造模型（false = 程序化脚手架）
func has_build_model() -> bool:
	return _build_model != null and is_instance_valid(_build_model)


## 自检用：资产建造模型根节点（没有则 null）
func build_model() -> Node3D:
	return _build_model if has_build_model() else null


## 自检用：建造动画当前时轴（没有动画器返回 -1）
func anim_position() -> float:
	if _ap == null or not is_instance_valid(_ap):
		return -1.0
	return _ap.current_animation_position


## 自检用：建造动画总长（没有动画器返回 -1）
func anim_length() -> float:
	return _ap_len if _ap_len > 0.0 else -1.0


## 自检用：脚手架立柱当前高度（第一根）
func post_height() -> float:
	for p in _posts:
		if is_instance_valid(p):
			return p.scale.y
	return 0.0


## 自检用：当前可见的横杆数
func visible_rails() -> int:
	var n: int = 0
	for r in _rails:
		if is_instance_valid(r) and r.visible:
			n += 1
	return n