extends Node3D
## **规划沙盘（固定势力范围网格）** —— 规划阶段盖在战场上的那层"红蓝领地"。
##
## 玩家口径（2026-11-15）：
##   · 势力范围**不动态扩张**，而是按地图设计划成**固定区**：
##     我方基地/布局区 = 蓝色高光网格，敌方初始区 = 红色高光网格，其余是中立地表；
##   · 网格要有轻微"沙盘科技感"：边缘发光 + 扫描线 + 流光，能一眼分出大本营与交战区。
##
## 为什么是 3D 网格 + 着色器，而不是在 HUD 上画 2D 线：
##   ① 2D 画线要逐点把世界坐标投到屏幕（每帧上千次），而且**不贴地**——
##      坡上一看就露馅；3D 面片逐顶点采样地形高度，网格才是"趴在地上"的；
##   ② 扫描线/流光/边缘辉光在着色器里是几行数学，换到 GDScript 就是每帧重画整张图。
##
## 纪律：
##   · **只在规划阶段可见**（执行阶段 `fade → 0` 后整节点隐藏，不占渲染）；
##   · 网格是**纯装饰**：不挡鼠标、不进碰撞、不写任何玩法状态；
##   · 淡入淡出只推 `fade` 这一个 uniform，绝不硬切（玩家口径：过渡要"不突兀"）。
##
## 对外：
##   zone_list()   已建好的势力区快照（规划地图层拿它挂"明牌意图"牌子）
##   set_fade(v)   手动推淡出（过场用；正常由 Game.phase_changed 驱动）

## 势力区单边半径（米）。比基地平台（Cfg.map_base_flat=18m）大一圈，
## 刚好把"大本营 + 一圈建筑位"框进来；不跟着实际建筑数量变（固定区，不扩张）。
const ZONE_HALF := 27.0
## 区域对齐到的格宽（米）：边界必须落在整数格上，否则网格和边界会错半格
const SNAP := 1.0
## 地面网格的几何精度（米）：只决定"贴不贴地形"，和画出来的格宽无关
const MESH_STEP := 1.5
## 边界光墙高度（米）
const CURTAIN_H := 1.4
## 贴着地形抬高多少（米）：压住 z-fighting，又不至于让单位"陷进网格里"
const LIFT := 0.07
## 淡入淡出速度（每秒）
const FADE_SPEED := 2.4

const SHADER_PATH := "res://Content/art/着色器/沙盘网格.gdshader"
const Spec := preload("res://Views/hud/界面规格.gd")

## 已建好的区：{faction, rect: Rect2(x,z,w,h), color, mine}
var _zones: Array = []
## 每区一份材质（淡出时逐个推 fade）
var _mats: Array = []
var _fade: float = 0.0
var _target: float = 0.0
## 地形还没就绪时重试计数（开局时序：关卡可能比本节点晚一帧）
var _retry: int = 0
var _built: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "规划沙盘"
	add_to_group("planning_sandbox")
	visible = false
	if Game != null:
		Game.phase_changed.connect(_on_phase_changed)
		if Game.short_match and Game.is_planning():
			_build.call_deferred()


func _on_phase_changed(_old: int, new_phase: int) -> void:
	if not Game.short_match:
		return
	if new_phase == RtsConst.Phase.PLANNING:
		# 回规划：已建过就不重建（重建会在同一帧里 queue_free + 同名 add_child，
		# 名字会被引擎改名成 "@势力区_x@2"，自检和调试都难认）。
		if not _built or _zones.is_empty():
			_build.call_deferred()
		_target = 1.0
	else:
		_target = 0.0


func set_fade(v: float) -> void:
	_target = clampf(v, 0.0, 1.0)


## 势力区快照（只读；规划地图层用来定位"明牌意图"牌子）
func zone_list() -> Array:
	return _zones


func _process(delta: float) -> void:
	if is_equal_approx(_fade, _target):
		if _target <= 0.001 and visible:
			visible = false
		return
	var step: float = FADE_SPEED * delta
	_fade = move_toward(_fade, _target, step)
	if _fade > 0.001:
		visible = true
	for m in _mats:
		if m != null:
			(m as ShaderMaterial).set_shader_parameter("fade", _fade)
	if _fade <= 0.001:
		visible = false


# ===========================================================================
# 建区
# ===========================================================================

func _build() -> void:
	var lv: Node3D = RtsWorld.level()
	if lv == null or lv.get("terrain") == null:
		# 地形还没挂上：再等一帧（最多 40 帧，超了就按平地建，绝不死循环）
		_retry += 1
		if _retry < 40:
			_build.call_deferred()
		return
	_clear()
	var player := Game.player_faction
	for f in Game.factions:
		if f == null or not is_instance_valid(f):
			continue
		var base: Vector3 = lv.call("base_center", f) if lv.has_method("base_center") \
				else Vector3.ZERO
		if base == Vector3.ZERO:
			continue
		var rect: Rect2 = _zone_rect(base)
		var mine: bool = player != null and player.is_ally_of(f)
		var col: Color = Spec.player_color() if mine else Spec.enemy_color()
		var mat := ShaderMaterial.new()
		mat.shader = load(SHADER_PATH)
		mat.set_shader_parameter("zone_color", col)
		mat.set_shader_parameter("zone_min", rect.position)
		mat.set_shader_parameter("zone_size", rect.size)
		mat.set_shader_parameter("cell", 2.0)
		mat.set_shader_parameter("fade", _fade)
		mat.set_shader_parameter("line_strength", 0.22 if mine else 0.26)
		mat.set_shader_parameter("edge_strength", 1.25 if mine else 1.10)
		var mi := MeshInstance3D.new()
		mi.name = "势力区_%s" % f.display_name
		mi.mesh = _mesh_for(rect)
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(mi)
		_mats.append(mat)
		_zones.append({
			"faction": f,
			"rect": rect,
			"color": col,
			"mine": mine,
		})
	_built = true
	# 开局若已经在规划阶段，第一帧就该看得见（不淡入，免得像"卡了一下"）
	if Game.is_planning():
		_fade = maxf(_fade, 0.0)
		_target = 1.0


func _clear() -> void:
	for c in get_children():
		c.queue_free()
	_zones.clear()
	_mats.clear()


## 基地 → 势力区矩形（XZ 平面；对齐到 SNAP，夹在地图内）
func _zone_rect(base: Vector3) -> Rect2:
	var half: float = ZONE_HALF
	var map: float = 224.0
	if Cfg != null and Cfg.game != null:
		map = maxf(float(Cfg.game.map_size), 60.0)
	var lim: float = map * 0.5 - 2.0
	var x0: float = clampf(round((base.x - half) / SNAP) * SNAP, -lim, lim)
	var z0: float = clampf(round((base.z - half) / SNAP) * SNAP, -lim, lim)
	var x1: float = clampf(round((base.x + half) / SNAP) * SNAP, -lim, lim)
	var z1: float = clampf(round((base.z + half) / SNAP) * SNAP, -lim, lim)
	return Rect2(Vector2(x0, z0), Vector2(maxf(x1 - x0, 8.0), maxf(z1 - z0, 8.0)))


## 一块势力的贴地面片 + 四条边界光墙（一次 SurfaceTool 拼成一个 Mesh）
func _mesh_for(rect: Rect2) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)

	# --- 地面：按 MESH_STEP 切格子，逐顶点采样地形高度 ---
	var nx: int = maxi(int(ceil(rect.size.x / MESH_STEP)), 1)
	var nz: int = maxi(int(ceil(rect.size.y / MESH_STEP)), 1)
	var grid: Array = []
	for iz in nz + 1:
		var row: PackedVector3Array = PackedVector3Array()
		var wz: float = rect.position.y + rect.size.y * float(iz) / float(nz)
		for ix in nx + 1:
			var wx: float = rect.position.x + rect.size.x * float(ix) / float(nx)
			row.append(Vector3(wx, RtsWorld.height_at(wx, wz) + LIFT, wz))
		grid.append(row)
	for iz in nz:
		for ix in nx:
			var a: Vector3 = grid[iz][ix]
			var b: Vector3 = grid[iz][ix + 1]
			var c: Vector3 = grid[iz + 1][ix + 1]
			var d: Vector3 = grid[iz + 1][ix]
			_tri(st, a, b, c, 0.0)
			_tri(st, a, c, d, 0.0)

	# --- 光墙：四条边各一条竖带（uv2.x = 1 告诉着色器"这是幕布"）---
	_wall(st, Vector2(rect.position.x, rect.position.y),
			Vector2(rect.end.x, rect.position.y))
	_wall(st, Vector2(rect.end.x, rect.position.y),
			Vector2(rect.end.x, rect.end.y))
	_wall(st, Vector2(rect.end.x, rect.end.y),
			Vector2(rect.position.x, rect.end.y))
	_wall(st, Vector2(rect.position.x, rect.end.y),
			Vector2(rect.position.x, rect.position.y))

	return st.commit()


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, _h: float) -> void:
	# 地面顶点的 uv2.x = 0（不是幕布）；uv 不用（网格靠世界坐标算）
	for v in [a, b, c]:
		st.set_uv(Vector2.ZERO)
		st.set_uv2(Vector2.ZERO)
		st.add_vertex(v)


## 一段边界光墙（a→b 沿地形起伏，向上拉起 CURTAIN_H）
func _wall(st: SurfaceTool, a: Vector2, b: Vector2) -> void:
	var d: Vector2 = b - a
	var length: float = d.length()
	if length < 0.2:
		return
	var n: int = maxi(int(ceil(length / 2.0)), 1)
	var dir: Vector2 = d / length
	for i in n:
		var t0: float = float(i) / float(n)
		var t1: float = float(i + 1) / float(n)
		var p0 := Vector2(a.x + dir.x * length * t0, a.y + dir.y * length * t0)
		var p1 := Vector2(a.x + dir.x * length * t1, a.y + dir.y * length * t1)
		var h0: float = RtsWorld.height_at(p0.x, p0.y) + LIFT
		var h1: float = RtsWorld.height_at(p1.x, p1.y) + LIFT
		var v00 := Vector3(p0.x, h0, p0.y)
		var v01 := Vector3(p0.x, h0 + CURTAIN_H, p0.y)
		var v10 := Vector3(p1.x, h1, p1.y)
		var v11 := Vector3(p1.x, h1 + CURTAIN_H, p1.y)
		# 四边形 (v00,v01,v11,v10) 拆两个三角；uv.y = 高度比（0 底 1 顶），
		# uv.x = 沿边的进度（着色器拿它做竖向"肋骨"条纹）
		_wall_vert(st, v00, 0.0, t0)
		_wall_vert(st, v01, 1.0, t0)
		_wall_vert(st, v11, 1.0, t1)
		_wall_vert(st, v00, 0.0, t0)
		_wall_vert(st, v11, 1.0, t1)
		_wall_vert(st, v10, 0.0, t1)


func _wall_vert(st: SurfaceTool, v: Vector3, hf: float, u: float) -> void:
	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(u, hf))
	st.set_uv2(Vector2(1.0, 0.0))
	st.add_vertex(v)
