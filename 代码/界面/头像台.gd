class_name RtsPortraitStage
extends Control
## **IRIS（头像台）** —— 选中面板左侧的**实时 3D 头像**。
##
## 为什么不用静态贴图：单位有队伍色、有程序动画、有高矮胖瘦，
## 一张预渲染图三天就跟美术资产对不上了。这里用 SubViewport 现渲染：
##
##   · SubViewport 160×160，`render_target_update_mode = UPDATE_ALWAYS`（真·每帧重画）
##   · `own_world_3d = true` —— 头像有**自己的世界**与灯光，不污染主场景，
##     也不会被主场景的主光/补光/雾照成一坨灰（这是"停尸房观感"的根因）
##   · 相机：3/4 机位（偏航 45°）+ 单位 12° 俯角，距离按 `def.height` 解包围盒自适应
##   · 模型进来先"转正"：rotation 归零 → XZ 居中 → 底面贴 y=0（歪脖子斜着站是验收硬伤）
##   · 找不到模型 → 纯色方块 + 名字首字，**不报错、不刷 ERROR**
##
## 生命周期：由 RtsDossierPanel 持有，`show_target(node)` 换人，`clear()` 清空。
## 同一个目标重复 show 不会重建模型（省一次 GLB 实例化）。

# ===========================================================================
# 版面 / 机位常量
# ===========================================================================

## 头像画幅（SubViewport 边长，任务书要求 128 或 160）
const VIEW_SIZE := 160
## 画框厚度（左/上/右/下各留这么多像素给描边，避免边框压住画面）
const FRAME := 4
## 相机视场角
const FOV := 38.0
## 3/4 机位偏航角（度）：正面在 -Z，绕 45° 才能看到脸 + 侧面
const YAW := 45.0
## 单位俯角（度）—— 任务书点名 12°
const PITCH_UNIT := 12.0
## 建筑俯角（度）—— 略抬高；12° 看 9 米高的大本营只剩一面墙
const PITCH_BUILDING := 16.0
## 画面填充率（1.0 = 贴边，0.88 留一圈呼吸位）
const FILL := 0.88
## 头像台外边距
const PAD := 0.0

# ===========================================================================
# 节点
# ===========================================================================

## SubViewport 容器（显示层）
var _host: SubViewportContainer = null
## 子视口
var _vp: SubViewport = null
## 3D 舞台根
var _stage: Node3D = null
## 相机
var _cam: Camera3D = null
## 主光 / 补光 / 轮廓光
var _key: DirectionalLight3D = null
var _fill: DirectionalLight3D = null
var _rim: DirectionalLight3D = null
## 展示底座（只有单位才有；建筑/自然物站在真实地面上更可信）
var _pedestal: MeshInstance3D = null
## 当前模型
var _model: Node3D = null
## 当前程序动画器
var _anim: Node = null
## 退化占位时盖在画面中央的"名字首字"
var _glyph: Label = null
## 多选角标
var _badge: PanelContainer = null
var _badge_label: Label = null

## 当前目标的缓存键（instance_id + def.id），用来跳过重复重建
var _key_id: int = 0
var _key_def: StringName = &""
## 头像背后的队伍色柔光
var _glow: Color = Color(0.30, 0.62, 1.0)


# ===========================================================================
# 构建
# ===========================================================================

func _ready() -> void:
	name = "头像台"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(float(VIEW_SIZE + FRAME * 2), float(VIEW_SIZE + FRAME * 2))
	_build_viewport()
	_build_lights()
	_build_frame()
	_build_badge()
	_build_glyph()


## 子视口：独立世界 + 每帧重绘
func _build_viewport() -> void:
	_host = SubViewportContainer.new()
	_host.name = "画布"
	_host.stretch = false
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host.position = Vector2(float(FRAME), float(FRAME))
	_host.size = Vector2(float(VIEW_SIZE), float(VIEW_SIZE))
	add_child(_host)

	_vp = SubViewport.new()
	_vp.name = "视口"
	_vp.size = Vector2i(VIEW_SIZE, VIEW_SIZE)
	# ★ 任务书硬要求：不是一次性烘图，是每帧重画
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.own_world_3d = true
	# 透明底：3D 只画人，背景由本控件的 _draw 画"影棚渐变 + 队伍色光斑"，
	# 这样头像和面板是长在一起的，不是一个方块贴上去
	_vp.transparent_bg = true
	_vp.gui_disable_input = true
	_vp.msaa_3d = Viewport.MSAA_2X
	_vp.handle_input_locally = false
	_host.add_child(_vp)

	# 独立世界的环境：环境光够亮，暗部才不是死黑（"停尸房"就是只有平行光没环境光的后果）
	var we := WorldEnvironment.new()
	we.name = "头像环境"
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.63, 0.78)
	env.ambient_light_energy = 0.62
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.92
	env.ssao_enabled = true
	env.ssao_radius = 0.6
	env.ssao_intensity = 1.4
	env.glow_enabled = true
	env.glow_intensity = 0.18
	env.glow_hdr_threshold = 1.30
	we.environment = env
	_vp.add_child(we)

	_stage = Node3D.new()
	_stage.name = "舞台"
	_vp.add_child(_stage)

	_cam = Camera3D.new()
	_cam.name = "头像相机"
	_cam.fov = FOV
	_cam.near = 0.03
	_cam.far = 80.0
	_cam.current = true
	_stage.add_child(_cam)

	_build_pedestal()


## 三盏灯：主光（暖、前上）+ 补光（冷、侧）+ 轮廓光（背后勾边）
func _build_lights() -> void:
	_key = DirectionalLight3D.new()
	_key.name = "主光"
	_key.light_color = Color(1.0, 0.94, 0.85)
	_key.light_energy = 2.35
	_key.rotation_degrees = Vector3(-42.0, -38.0, 0.0)
	# 开阴影：头像是"雕塑感"的门面，没有自投影就是一坨贴纸
	_key.shadow_enabled = true
	_key.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	_key.directional_shadow_max_distance = 40.0
	_key.shadow_bias = 0.03
	_stage.add_child(_key)

	_fill = DirectionalLight3D.new()
	_fill.name = "补光"
	_fill.light_color = Color(0.56, 0.72, 1.0)
	_fill.light_energy = 0.85
	_fill.rotation_degrees = Vector3(-10.0, 128.0, 0.0)
	_fill.shadow_enabled = false
	_stage.add_child(_fill)

	_rim = DirectionalLight3D.new()
	_rim.name = "轮廓光"
	_rim.light_color = Color(0.86, 0.92, 1.0)
	_rim.light_energy = 1.15
	_rim.rotation_degrees = Vector3(-16.0, 196.0, 0.0)
	_rim.shadow_enabled = false
	_stage.add_child(_rim)


## 展示底座：一个极扁的圆台，让"人站在上面"有落点
func _build_pedestal() -> void:
	_pedestal = MeshInstance3D.new()
	_pedestal.name = "底座"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 0.02
	cyl.radial_segments = 40
	cyl.rings = 1
	_pedestal.mesh = cyl
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.075, 0.085, 0.105)
	m.roughness = 0.94
	m.metallic = 0.02
	m.emission_enabled = true
	m.emission = Color(0.55, 0.62, 0.78)
	m.emission_energy_multiplier = 0.10
	_pedestal.material_override = m
	_pedestal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pedestal.position = Vector3(0.0, 0.008, 0.0)
	_pedestal.visible = false
	_stage.add_child(_pedestal)


## 画框：四条 1px 边 + 四角加粗的"取景角"（比一圈死边框有设计感）
func _build_frame() -> void:
	var accent: Color = _accent()
	var edge := accent
	edge.a = 0.34
	var w: float = float(VIEW_SIZE + FRAME * 2)
	_rect(Vector2(float(FRAME), 1.0), Vector2(float(VIEW_SIZE), 1.0), edge)
	_rect(Vector2(float(FRAME), w - 2.0), Vector2(float(VIEW_SIZE), 1.0), edge)
	_rect(Vector2(1.0, float(FRAME)), Vector2(1.0, float(VIEW_SIZE)), edge)
	_rect(Vector2(w - 2.0, float(FRAME)), Vector2(1.0, float(VIEW_SIZE)), edge)
	# 四角：2×2 的亮角块，读起来像"取景器"
	var corner := accent
	corner.a = 0.9
	var cl: float = 7.0
	_rect(Vector2(1.0, 1.0), Vector2(cl, 2.0), corner)
	_rect(Vector2(1.0, 1.0), Vector2(2.0, cl), corner)
	_rect(Vector2(w - 1.0 - cl, 1.0), Vector2(cl, 2.0), corner)
	_rect(Vector2(w - 3.0, 1.0), Vector2(2.0, cl), corner)
	_rect(Vector2(1.0, w - 3.0), Vector2(cl, 2.0), corner)
	_rect(Vector2(1.0, w - 1.0 - cl), Vector2(2.0, cl), corner)
	_rect(Vector2(w - 1.0 - cl, w - 3.0), Vector2(cl, 2.0), corner)
	_rect(Vector2(w - 3.0, w - 1.0 - cl), Vector2(2.0, cl), corner)


func _rect(pos: Vector2, size: Vector2, col: Color) -> void:
	var r := ColorRect.new()
	r.color = col
	r.position = pos
	r.size = size
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(r)


## 右下角 ×N 角标
func _build_badge() -> void:
	_badge = PanelContainer.new()
	_badge.name = "多选角标"
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.08, 0.95)
	sb.border_color = _accent()
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 5.0
	sb.content_margin_right = 5.0
	sb.content_margin_top = 0.0
	sb.content_margin_bottom = 0.0
	_badge.add_theme_stylebox_override("panel", sb)
	add_child(_badge)

	_badge_label = Label.new()
	_badge_label.text = "×1"
	_badge_label.add_theme_font_size_override("font_size", 13)
	_badge_label.add_theme_color_override("font_color", _accent())
	_badge_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.add_child(_badge_label)

	var w: float = float(VIEW_SIZE + FRAME * 2)
	_badge.anchor_left = 0.0
	_badge.anchor_top = 0.0
	_badge.anchor_right = 0.0
	_badge.anchor_bottom = 0.0
	_badge.offset_left = w - 44.0
	_badge.offset_top = w - 27.0
	_badge.offset_right = w - 5.0
	_badge.offset_bottom = w - 5.0
	_badge.visible = false


## 退化占位的大字（名字首字）
func _build_glyph() -> void:
	_glyph = Label.new()
	_glyph.name = "占位首字"
	_glyph.text = ""
	_glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_glyph.add_theme_font_size_override("font_size", 58)
	_glyph.add_theme_color_override("font_color", Color(0.97, 0.96, 0.92, 0.94))
	_glyph.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.75))
	_glyph.add_theme_constant_override("outline_size", 6)
	_glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glyph.position = Vector2(float(FRAME), float(FRAME))
	_glyph.size = Vector2(float(VIEW_SIZE), float(VIEW_SIZE))
	_glyph.visible = false
	add_child(_glyph)


## 画在子视口**底下**的底片：纵向冷灰渐变 + 一团队伍色柔光。
## 子视口是透明底，所以这层会从人物后面透出来 —— 头像和面板是一体的，不是贴上去的方块。
func _draw() -> void:
	var w: float = float(VIEW_SIZE)
	var origin := Vector2(float(FRAME), float(FRAME))
	var top := Color(0.098, 0.112, 0.148)
	var bot := Color(0.036, 0.041, 0.054)
	var bands: int = 24
	for i in bands:
		var y0: float = origin.y + w * float(i) / float(bands)
		var bh: float = w / float(bands) + 0.6
		var t: float = float(i) / float(maxi(bands - 1, 1))
		draw_rect(Rect2(origin.x, y0, w, bh), top.lerp(bot, t), true)
	# 队伍色光斑：外圈大而淡、内圈小而叠，自然叠出柔光
	var c := origin + Vector2(w * 0.5, w * 0.44)
	var rings: int = 16
	for i in range(rings, 0, -1):
		var r: float = w * 0.44 * float(i) / float(rings)
		draw_circle(c, r, Color(_glow.r, _glow.g, _glow.b, 0.024))
	# 地平线：一条极淡的横向亮线，让人"站"得住
	draw_rect(Rect2(origin.x, origin.y + w * 0.80, w, 1.0),
			Color(_glow.r, _glow.g, _glow.b, 0.10), true)
	# 空槽：画一个暗准星，读起来是"这里等一个目标"，不是一块坏掉的空白
	if _model == null or not is_instance_valid(_model):
		var ctr := origin + Vector2(w * 0.5, w * 0.46)
		var rc: Color = Color(_accent().r, _accent().g, _accent().b, 0.20)
		draw_arc(ctr, w * 0.22, 0.0, TAU, 40, rc, 1.0, true)
		draw_arc(ctr, w * 0.075, 0.0, TAU, 24, Color(rc.r, rc.g, rc.b, 0.30), 1.0, true)
		for i in 4:
			var a: float = TAU * float(i) / 4.0 + TAU * 0.125
			var d := Vector2(cos(a), sin(a))
			draw_line(ctr + d * w * 0.25, ctr + d * w * 0.32, rc, 1.0)


# ===========================================================================
# 对外接口
# ===========================================================================

## 显示一个目标（单位 / 建筑 / 可采集物都行）。同一个目标重复调用是零成本的。
func show_target(target: Node3D, count: int = 1) -> void:
	set_badge(count)
	if target == null or not is_instance_valid(target):
		clear()
		return
	var def: UnitDef = target.get("def") as UnitDef
	var id: int = target.get_instance_id()
	var did: StringName = def.id if def != null else &""
	# 同一个人 + 同一个定义：不重建（GLB 实例化不便宜，别每 0.12 秒来一次）
	if id == _key_id and did == _key_def and _model != null:
		return
	_key_id = id
	_key_def = did
	_rebuild(target, def)


## 多选角标（1 就隐藏）
func set_badge(count: int) -> void:
	if _badge == null:
		return
	_badge.visible = count > 1
	if count > 1:
		_badge_label.text = "×%d" % count


## 清空（没有选中）
func clear() -> void:
	_key_id = 0
	_key_def = &""
	_drop_model()
	if _glyph != null:
		_glyph.visible = false
	set_badge(1)


## 当前是否有模型在台上
func has_model() -> bool:
	return _model != null and is_instance_valid(_model)


# ===========================================================================
# 重建
# ===========================================================================

func _rebuild(target: Node3D, def: UnitDef) -> void:
	_drop_model()
	if _glyph != null:
		_glyph.visible = false

	var col: Color = _team_color(target, def)
	_glow = col
	queue_redraw()
	var is_building: bool = def != null and def.is_building()
	var is_harvest: bool = def != null and def.is_harvestable()

	var model := _make_model(def)
	var fallback: bool = model == null

	if fallback:
		model = _make_fallback_box(def, col)
		if _glyph != null:
			_glyph.text = _first_char(def)
			_glyph.visible = true
	else:
		ArtKit.apply_team_color(model, col)
		# 挂程序动画器，放 idle —— 让头像是"活的"，不是蜡像
		_anim = ArtKit.attach_anim(model)
		ArtKit.set_anim(_anim, "idle", 1.0)

	_model = model
	_model.name = "头像模型"
	_model.rotation = Vector3.ZERO
	_model.position = Vector3.ZERO
	_stage.add_child(_model)

	# 转正：按包围盒把 XZ 居中、底面压到 y=0
	var box := _aabb_of(_model)
	if box.size.length_squared() > 0.000001:
		_model.position = Vector3(-box.get_center().x, -box.position.y, -box.get_center().z)

	# 重新量一次（位置变了），用于机位解算
	var fit := _aabb_of(_model)
	var h: float = maxf(fit.size.y, 0.2)
	var w: float = maxf(maxf(fit.size.x, fit.size.z), 0.2)
	# 3/4 机位看到的是对角线，方形足迹的建筑要按 1.4 倍宽算，否则塔角会被切掉
	if is_building:
		w *= 1.40
	var pitch: float = PITCH_BUILDING if is_building else PITCH_UNIT
	_frame_camera(h, w, pitch)

	# 底座：只有"人"才站台子
	if _pedestal != null:
		var use_ped: bool = not is_building and not is_harvest
		_pedestal.visible = use_ped
		if use_ped:
			var r: float = maxf(maxf(fit.size.x, fit.size.z) * 0.58, 0.28)
			_pedestal.scale = Vector3(r, 1.0, r)


## 造模型：路径存在且真能实例化才算成功
func _make_model(def: UnitDef) -> Node3D:
	if def == null:
		return null
	var path: String = def.model_path
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var m: Node3D = null
	var scale: float = def.model_scale
	if scale <= 0.0001:
		scale = 1.0
	m = ArtKit.build_model(path, scale)
	if m == null:
		return null
	# 模型工厂缺文件时会吐一个"占位_"色块：这也是退化，交给纯色方块 + 首字
	if _has_placeholder(m):
		m.queue_free()
		return null
	return m


## 模型工厂的占位块名字以「占位_」开头
func _has_placeholder(root: Node) -> bool:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if String(n.name).begins_with("占位_"):
			return true
		for c in n.get_children():
			stack.append(c)
	return false


## 纯色方块退化石（任务书：纯色方块 + 名字首字，不许报错）
func _make_fallback_box(def: UnitDef, col: Color) -> Node3D:
	var root := Node3D.new()
	var size := Vector3(0.7, 1.6, 0.5)
	if def != null:
		if def.is_building():
			size = Vector3(maxf(float(def.footprint.x), 1.0) * 0.8,
				maxf(def.height, 0.5), maxf(float(def.footprint.y), 1.0) * 0.8)
		elif def.is_harvestable():
			size = Vector3(maxf(def.body_radius * 1.7, 0.6), maxf(def.height, 0.5),
				maxf(def.body_radius * 1.7, 0.6))
		elif def.height > 0.1:
			size = Vector3(maxf(size.x, 0.6), def.height, maxf(size.z, 0.45))
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(col.r * 0.72 + 0.10, col.g * 0.72 + 0.10, col.b * 0.72 + 0.10)
	mat.roughness = 0.62
	mat.metallic = 0.08
	mi.material_override = mat
	mi.position = Vector3(0.0, size.y * 0.5, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	return root


## 队伍色 / 资源色
func _team_color(target: Node3D, def: UnitDef) -> Color:
	var fac: RtsFaction = target.get("faction") as RtsFaction
	if fac != null:
		return fac.color
	if def != null and def.is_harvestable():
		if def.harvest_kind == RtsConst.Harvest.GOLD:
			return Cfg.game.gold_color if Cfg.game != null else Color(1.0, 0.82, 0.24)
		return Color(0.42, 0.62, 0.34)
	if Cfg.game != null:
		return Cfg.game.player_color
	return Color(0.30, 0.62, 1.0)


func _first_char(def: UnitDef) -> String:
	var s: String = def.display_name if def != null else "?"
	if s.is_empty():
		return "?"
	return s.substr(0, 1)


# ===========================================================================
# 几何 / 机位
# ===========================================================================

## 累加整棵子树的包围盒（相对 root 的父空间）。
## 这个工程的 GLB 是"网格烘焙在父级空间 + 关节空节点做枢轴"，所以直接乘变换链就准。
func _aabb_of(root: Node3D) -> AABB:
	var boxes: Array[AABB] = []
	_walk_aabb(root, Transform3D.IDENTITY, boxes)
	if boxes.is_empty():
		return AABB(Vector3.ZERO, Vector3.ZERO)
	var out: AABB = boxes[0]
	for i in range(1, boxes.size()):
		out = out.merge(boxes[i])
	return out


func _walk_aabb(n: Node, xf: Transform3D, out: Array[AABB]) -> void:
	var t := xf
	var n3 := n as Node3D
	if n3 != null:
		t = xf * n3.transform
	var mi := n as MeshInstance3D
	if mi != null and mi.mesh != null:
		var local: AABB = mi.mesh.get_aabb()
		if local.size.length_squared() > 0.0000001:
			out.append(t * local)
	for c in n.get_children():
		_walk_aabb(c, t, out)


## 按高/宽解相机距离，再摆 3/4 机位（用 Basis 直算，不依赖节点是否已入树）
func _frame_camera(h: float, w: float, pitch_deg: float) -> void:
	if _cam == null:
		return
	var ext: float = maxf(h, w)
	var half_v: float = tan(deg_to_rad(FOV) * 0.5)
	var d: float = (ext * 0.5) / maxf(half_v * FILL, 0.0001)
	d = clampf(d, 0.55, 90.0)

	var target := Vector3(0.0, h * 0.52, 0.0)
	var yaw := deg_to_rad(YAW)
	var pitch := deg_to_rad(pitch_deg)
	# 正面朝 -Z，所以相机要落在 -X/-Z 象限
	var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
	dir = Vector3(dir.x * cos(pitch), sin(pitch), dir.z * cos(pitch))
	var pos: Vector3 = target + dir * d

	var back: Vector3 = pos - target
	if back.length_squared() < 0.000001:
		back = Vector3(0.0, 0.0, 1.0)
	back = back.normalized()
	var right: Vector3 = Vector3.UP.cross(back)
	if right.length_squared() < 0.000001:
		right = Vector3.RIGHT
	right = right.normalized()
	var up: Vector3 = back.cross(right).normalized()
	_cam.transform = Transform3D(Basis(right, up, back), pos)
	_cam.far = clampf(d * 8.0, 40.0, 400.0)


func _drop_model() -> void:
	_anim = null
	if _model != null and is_instance_valid(_model):
		_model.queue_free()
	_model = null


func _accent() -> Color:
	return Cfg.game.hud_accent if Cfg.game != null else Color(0.85, 0.71, 0.36)
