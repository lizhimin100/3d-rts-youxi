class_name RtsMinimap
extends Control
## **小地图（HAWKEYE）**
##
## 全自定义 _draw（文档 §8）。这一版按任务书 §3.2 补齐"可读性"：
##   · **边框**：内 1px 主色细框 + 外 3px 暗框 + 四角取景角；拖动时整框亮起；
##   · **地形底图**：高度场烘成一张贴图（只烘一次），低绿高灰，配三分战术网格；
##   · **视野框**：屏幕四角打地面得到的梯形，半透明白填充 + 描边；
##   · **图例**：底部一条 12px 图例（我方 / 敌军 / 金矿 / 树林），窄屏自动减项；
##   · **明确的可点区域**：鼠标悬停变手型，按下即飞，拖动持续跟随。
##
## 性能纪律：地形底图只烘一次；每帧只重画几十个点，重绘频率压到 10Hz。

const Spec := preload("res://代码/界面/界面规格.gd")

## 重绘间隔（秒）
const REFRESH_INTERVAL := 0.1
## 边框留白（像素）：0 = 地图铺满控件，圆盘正好是控件的内切圆
const PAD := 0.0
## 图例条高度（现在是**圆内**的一条半透明浮条，不再占圆外高度）
const LEGEND_H := 24.0
## 圆盘遮罩色（= 面板底色）
const MASK_COLOR := Color(0.035, 0.041, 0.052, 0.96)

## 圆形裁剪用的 canvas_item 着色器。
## 为什么不用"画四个角盖住"：底盘和遮罩同色，盖了等于没盖，仍旧是一块方板；
## 只有 discard 才是真的圆 —— 圆外透明，直接透出战场。
const CIRCLE_SHADER := """
shader_type canvas_item;
uniform vec2 size_px = vec2(240.0, 240.0);
uniform vec2 center_px = vec2(120.0, 120.0);
uniform float radius_px = 116.0;
void fragment() {
	vec2 p = UV * size_px - center_px;
	if (length(p) > radius_px) {
		discard;
	}
}
"""
## 视野框淡填充 / 描边色。
## 旧版填充 alpha 0.055 + 1.2px 白线 —— 在花花绿绿的小地图上等于不存在；
## 但如果反过来画成"粗白框 + 12% 白底"，它又会压过营地、金矿、单位，成为最抢眼的东西
## （用户："梯形 UI 太大、太抢眼了"）。所以取中间值：**只有一圈细线 + 很淡的填充**，
## 找得到、但不抢戏。
const VIEW_FILL := Color(0.90, 0.98, 1.0, 0.040)
const VIEW_LINE := Color(0.90, 0.98, 1.0, 0.52)
## 取景框角标长度（像素）：只做"方向提示"，不做相框
const VIEW_TICK := 4.0

## 世界边长（没关卡时从 Cfg 取）
var world_size: float = 116.0

## 地形底图（第一次绘制时烘出来）
var _terrain_tex: ImageTexture = null
var _terrain_built: bool = false
## 本张地图的高度范围（自适应，不再用硬编码的 -0.6~2.4）
var _hmin: float = 0.0
var _hmax: float = 1.0

## 重绘计时
var _clock: float = 0.0

## 圆形裁剪材质 / 圆盘下方的图例条
var _mat: ShaderMaterial = null
var _legend_bg: PanelContainer = null
var _legend: HBoxContainer = null

## 左键拖动中
var _dragging: bool = false
## 鼠标悬停中（只影响边框亮度，不参与逻辑）
var _hover: bool = false
## 边框层：**不带圆形裁剪材质**的子控件。
## 控件自身的 material 会把圆外的一切绘制 discard 掉，所以"圆环边框"必须画在子节点上，
## 否则无论加多粗都看不见（之前的边框就是这么消失的）。
var _frame: RingFrame = null
## 战争迷雾节点（运行时由 RtsFog 加入 "fog_system" 组；没有就退化成无迷雾）
var _fog_node: Node = null


## 圆形外框：外黑边 + 金环 + 内阴影，画在子控件上（不受父级圆形裁剪影响）
class RingFrame extends Control:
	var accent_color: Color = Color(0.86, 0.72, 0.40)
	var emph: float = 0.76

	func _draw() -> void:
		var side: float = minf(size.x, size.y)
		if side < 16.0:
			return
		var ctr := Vector2(size.x, size.y) * 0.5
		var rad: float = side * 0.5 - 2.0
		# 外黑边：让圆盘从草地背景里"跳"出来
		draw_arc(ctr, rad + 1.5, 0.0, TAU, 160, Color(0.0, 0.0, 0.0, 0.92), 7.0, true)
		# 金环：显式边框
		draw_arc(ctr, rad - 2.0, 0.0, TAU, 160,
			Color(accent_color.r, accent_color.g, accent_color.b, emph), 3.5, true)
		# 内阴影：读起来像"嵌进去"
		draw_arc(ctr, rad - 6.5, 0.0, TAU, 160, Color(0.0, 0.0, 0.0, 0.40), 4.0, true)
		# 四向刻度（方向感，不是装饰）
		for i in 4:
			var a: float = TAU * float(i) / 4.0 - PI * 0.5
			var d := Vector2(cos(a), sin(a))
			draw_line(ctr + d * (rad - 11.0), ctr + d * (rad - 3.0),
				Color(accent_color.r, accent_color.g, accent_color.b, minf(1.0, emph + 0.12)), 2.0)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_contents = false
	_build_circle_material()
	_build_frame()
	_build_legend()
	mouse_entered.connect(func() -> void: _hover = true; _sync_frame())
	mouse_exited.connect(func() -> void: _hover = false; _sync_frame())
	resized.connect(_update_material)


## 圆形裁剪材质：把控件自己画的东西裁成圆（子节点图例不受影响）
func _build_circle_material() -> void:
	var sh := Shader.new()
	sh.code = CIRCLE_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	material = _mat
	_update_material()


func _update_material() -> void:
	if _mat == null:
		return
	_layout_legend()
	var mr := _map_rect()
	var ctr: Vector2 = mr.position + mr.size * 0.5
	_mat.set_shader_parameter("size_px", size)
	_mat.set_shader_parameter("center_px", ctr)
	_mat.set_shader_parameter("radius_px", minf(mr.size.x, mr.size.y) * 0.5 - 1.0)


## 图例：圆盘下方一条横排（我方 / 敌军 / 金矿 / 树林）。
## 用节点而不是 _draw —— 它必须"活在圆外面"，否则会被圆形裁剪一起切掉。
func _build_legend() -> void:
	# 图例在圆盘外侧，直接压在草地上读不清 —— 给它一条自己的深色底板
	_legend_bg = PanelContainer.new()
	_legend_bg.name = "图例底"
	_legend_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_legend_bg.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.030, 0.036, 0.046, 0.94), 8,
					Color(Spec.accent().r, Spec.accent().g, Spec.accent().b, 0.30), 10.0, 1.0))
	add_child(_legend_bg)

	_legend = HBoxContainer.new()
	_legend.name = "图例"
	_legend.add_theme_constant_override("separation", 10)
	_legend.alignment = BoxContainer.ALIGNMENT_CENTER
	_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_legend_bg.add_child(_legend)
	var items: Array = [
		[Spec.player_color(), "我方"],
		[Spec.ally_color(), "盟友"],
		[Spec.enemy_color(), "敌军"],
		[Spec.gold(), "金矿"],
		[Color(0.34, 0.56, 0.30), "树林"],
	]
	for it in items:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 5)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_legend.add_child(row)
		var sq := ColorRect.new()
		sq.color = it[0]
		sq.custom_minimum_size = Vector2(8.0, 8.0)
		sq.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		sq.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(sq)
		row.add_child(Spec.label(String(it[1]), Spec.FS_BODY, Color(0.74, 0.75, 0.72)))
	# 图例条彻底隐藏：它要么占圆外（圆盘缩小、偏上），要么在圆内超宽被裁。
	# 小地图上"蓝点=我方 / 红点=敌方 / 黄点=金矿"本来就够读，圆盘保持干净。
	_legend_bg.visible = false
	_layout_legend()


func _process(delta: float) -> void:
	_clock += delta
	if _clock < REFRESH_INTERVAL:
		return
	_clock = 0.0
	_sync_world_size()
	queue_redraw()


## 世界尺寸跟着关卡（关卡没建好就用配置）。
##
## ★ 这里**不能**写 `Game.level as RtsLevel`：Game.level 的静态类型是 Node3D，
##   而关卡脚本是运行时挂上去的；一旦 RtsLevel 的全局类名没进缓存，as 直接返回 null，
##   于是 world_size 永远停在初始值 116 —— 200m 的地图上所有点都被推到圆盘外，
##   小地图只剩一块纯绿。玩家说的"地图 UI 对不上"就是这个。
func _sync_world_size() -> void:
	var lv: Node = Game.level
	if lv != null and lv.get("world_size") != null:
		var w: float = float(lv.get("world_size"))
		if w > 1.0:
			world_size = w
			return
	if Cfg.game != null:
		world_size = Cfg.game.map_size


# ===========================================================================
# 绘制
# ===========================================================================

## 地图绘制区：**铺满控件**（控件本身是正方形）。
## 旧版留 4px 边 + 底部图例占 34px，于是圆盘比控件小一圈、还偏上 ——
## 玩家看到的"小地图没对齐圆圈"就是这两件事叠起来的。
func _map_rect() -> Rect2:
	# 四周留 7px 给边框：地形不再顶到控件边缘，圆形裁剪也就不会把内容切出"毛边"
	var side: float = maxf(16.0, minf(size.x, size.y) - 14.0)
	return Rect2(Vector2(7.0, 7.0), Vector2(side, side))


func _build_frame() -> void:
	_frame = RingFrame.new()
	_frame.name = "边框"
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_frame)
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sync_frame()


func _sync_frame() -> void:
	if _frame == null:
		return
	_frame.accent_color = _accent()
	_frame.emph = 0.98 if _dragging else (0.90 if _hover else 0.78)
	# 尺寸交给 anchors(FULL_RECT) 跟着走 —— 在 `_draw` 里直接改子控件 size 会触发
	# "Control::set_size during draw" 报错。
	_frame.queue_redraw()


## 图例条：**收进圆盘内部**底缘（水平居中，宽 76%，高 24）。
## 放在圆外会让整个小地图看起来是"一个圆 + 一块贴纸"，怎么摆都不齐。
func _layout_legend() -> void:
	if _legend == null:
		return
	var side: float = minf(size.x, size.y)
	var w: float = maxf(side * 0.76, 40.0)
	var h: float = LEGEND_H
	if _legend_bg != null:
		_legend_bg.position = Vector2((side - w) * 0.5, side - h - side * 0.055)
		_legend_bg.size = Vector2(w, h)



func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if r.size.x <= 8.0 or r.size.y <= 8.0:
		return
	var acc := _accent()
	var mr := _map_rect()

	# --- 外底（图例区也吃这个底）---
	draw_rect(r, Color(0.035, 0.041, 0.052, 0.96), true)

	# --- 地形底图 ---
	draw_rect(mr, Color(0.05, 0.06, 0.08, 0.95), true)
	_build_terrain_once()
	if _terrain_tex != null:
		draw_texture_rect(_terrain_tex, mr, false)
	else:
		draw_rect(mr.grow(-1.0), Color(0.16, 0.22, 0.15, 1.0), true)

	# --- 水面（圆形池塘）---
	var lv: Node = Game.level
	var md: Variant = lv.get("map_data") if lv != null else null
	if md != null and float(md.get("pond_radius")) > 0.0:
		var pc2: Vector2 = md.get("pond_center")
		var pc: Vector2 = _world_to_map(Vector3(pc2.x, 0.0, pc2.y))
		var pr: float = float(md.get("pond_radius")) / world_size * mr.size.x
		draw_circle(pc, pr, Color(0.18, 0.34, 0.48, 0.85))

	# --- 土路：真实路网映射上来，玩家才能"看图找路" ---
	if md != null:
		var road_col := Color(0.46, 0.395, 0.272, 0.62)
		for rd in md.get("roads"):
			var pts: PackedVector2Array = rd.get("pts", PackedVector2Array())
			if pts.size() < 2:
				continue
			var poly := PackedVector2Array()
			for p in pts:
				poly.append(_world_to_map(Vector3(p.x, 0.0, p.y)))
			var wpx: float = maxf(1.0, float(rd.get("width", 4.0)) / world_size * mr.size.x)
			draw_polyline(poly, Color(0.0, 0.0, 0.0, 0.20), wpx + 1.4, true)
			draw_polyline(poly, road_col, wpx, true)

	# --- 战术网格：三分线，读起来才像一张"战图"而不是一坨绿 ---
	_draw_grid(mr)

	# --- 资源点 ---
	if md != null:
		var gold := Spec.gold()
		for m in md.get("mines"):
			var mp: Vector2 = _world_to_map(Vector3(m.x, 0.0, m.y))
			draw_rect(Rect2(mp - Vector2(3.4, 3.4), Vector2(6.8, 6.8)), Color(0.0, 0.0, 0.0, 0.66), true)
			draw_rect(Rect2(mp - Vector2(2.3, 2.3), Vector2(4.6, 4.6)), gold, true)
		for t in md.get("trees"):
			var tp: Vector2 = _world_to_map(Vector3(t.x, 0.0, t.y))
			draw_rect(Rect2(tp - Vector2(1.6, 1.6), Vector2(3.2, 3.2)), Color(0.10, 0.24, 0.11, 0.92), true)

	# --- 战争迷雾遮罩（地形 + 资源都吃这层压黑/压暗，雾中敌人由下面的单位循环跳过）---
	if _fog_node == null or not is_instance_valid(_fog_node):
		_fog_node = get_tree().get_first_node_in_group("fog_system")
	if _fog_node != null:
		var ft: Variant = _fog_node.get("fog_texture")
		if ft != null:
			draw_texture_rect(ft, mr, false)

	# --- 单位/建筑 ---
	var pl := Game.player_faction
	if OS.has_environment("MM_DEBUG"):
		var shown: int = 0
		for u in Game.all_units():
			var n3 := u as Node3D
			if n3 == null:
				continue
			if shown >= 4:
				break
			shown += 1
			print("[MM] %s world=%s map=%s ws=%.0f mr=%s" % [String(n3.name),
				str(n3.global_position), str(_world_to_map(n3.global_position)),
				world_size, str(mr)])
	# 迷雾节点可能比小地图晚建（RtsFog 在关卡 _ready 里挂），每帧补找一次
	if _fog_node == null or not is_instance_valid(_fog_node):
		_fog_node = get_tree().get_first_node_in_group("fog_system")
	var dots: Array = []
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var n := u as Node3D
		if n == null:
			continue
		if n is RtsUnit and not (n as RtsUnit).is_alive():
			continue
		var fac: RtsFaction = n.get("faction")
		# 迷雾口径（和 3D 侧一致）：
		#   自己 / 盟友永远画；敌方**单位**只在当前可见时画；
		#   敌方**建筑**只要"探索过"就留一个点 —— 侦察过的房子不该凭空消失。
		if _fog_node != null and fac != null and pl != null and not pl.is_ally_of(fac):
			if n is RtsBuilding:
				if not _fog_explored(n.global_position):
					continue
			elif not _fog_visible(n.global_position):
				continue
		# 点色 = 阵营**显示色**：你蓝 / 盟友青 / 敌人各自队色。
		# 旧版只有"我方蓝 / 其它一律红"，于是整张图一片红、盟友和敌人一个样。
		var col: Color = Color(0.80, 0.82, 0.78)
		if fac != null:
			col = fac.color
		dots.append([n, fac, col])
	# 画序：敌人 → 盟友 → 自己，自己的点永远压在最上面
	dots.sort_custom(func(a: Array, b: Array) -> bool:
		return _dot_rank(a[1]) < _dot_rank(b[1]))
	for e in dots:
		var n: Node3D = e[0]
		var col: Color = e[2]
		var p: Vector2 = _world_to_map(n.global_position)
		var half: float = 2.6 if n is RtsBuilding else 1.7
		# 每个点先铺一圈 1px 黑影：亮底/暗底上都咬得住
		draw_rect(Rect2(p - Vector2(half + 0.9, half + 0.9), Vector2((half + 0.9) * 2.0, (half + 0.9) * 2.0)),
				Color(0.0, 0.0, 0.0, 0.55), true)
		draw_rect(Rect2(p - Vector2(half, half), Vector2(half * 2.0, half * 2.0)), col, true)
		# 选中：外面再套一圈白框（一眼看出"我选的是哪几个点"）
		if n is RtsUnit and (n as RtsUnit).is_selected:
			draw_rect(Rect2(p - Vector2(half + 1.8, half + 1.8),
					Vector2((half + 1.8) * 2.0, (half + 1.8) * 2.0)),
					Color(1.0, 1.0, 1.0, 0.92), false, 1.0)

	# --- 当前视野框（玩家视角的梯形）---
	_draw_view_box();


	# --- 底图内框（把地形和边框分开）---
	draw_rect(mr, Color(acc.r, acc.g, acc.b, 0.34), false, 1.0)

	# 圆形化：圆外由材质 discard 掉（真的透明）。
	# 边框/刻度由子控件 RingFrame 画 —— 父级的 material 会把这里画的圆环一起裁掉。
	_sync_frame()


## 三分网格（只在内部画，别压到边）
func _draw_grid(mr: Rect2) -> void:
	var line := Color(1.0, 1.0, 1.0, 0.065)
	for i in [1, 2, 3]:
		var t: float = float(i) / 4.0
		draw_line(Vector2(mr.position.x + mr.size.x * t, mr.position.y + 1.0),
				Vector2(mr.position.x + mr.size.x * t, mr.position.y + mr.size.y - 1.0), line, 1.0)
		draw_line(Vector2(mr.position.x + 1.0, mr.position.y + mr.size.y * t),
				Vector2(mr.position.x + mr.size.x - 1.0, mr.position.y + mr.size.y * t), line, 1.0)


## 圆形裁剪说明（保留常量，方便后人改色）：
## 真正的圆形是材质 discard 出来的（见 CIRCLE_SHADER）；MASK_COLOR 只在
## "想退回方板 + 盖角"时才有用，别在这里再画一遍。


## 主色
func _accent() -> Color:
	return Spec.accent()


## 地形底图：把 MapData 的高度场烘成一张 (res+1)² 的贴图
func _build_terrain_once() -> void:
	if _terrain_built:
		return
	var lv: Node = Game.level
	var md: Variant = lv.get("map_data") if lv != null else null
	if md == null:
		return  # 关卡还没建好，下一帧再试
	var res: int = maxi(int(md.get("resolution")), 2)
	var row: int = res + 1
	var hs: PackedFloat32Array = md.get("heights")
	if hs.size() < row * row:
		return

	# 自适应高度范围：旧版把 (h+0.6)/3 写死，实际地形 -8~+20m 的图会被压成
	# "一片暗绿 + 中央一块白"，跟战场完全对不上。
	_hmin = 1e20
	# 地块格点表（竞技场图才有；旧的双人图 mat_cells = 0，行为不变）
	var mat_nodes: PackedByteArray = PackedByteArray()
	var mat_cells: int = 0
	if md != null and md.has_method("mat_at"):
		mat_nodes = md.get("mat_nodes")
		mat_cells = int(md.get("mat_cells"))
	_hmax = -1e20
	for i in row * row:
		var hv: float = hs[i]
		_hmin = minf(_hmin, hv)
		_hmax = maxf(_hmax, hv)
	if _hmax - _hmin < 0.6:
		_hmax = _hmin + 0.6

	var bytes := PackedByteArray()
	bytes.resize(row * row * 4)
	# 3×3 均值：高度场逐格有噪声，直接上色会得到一张"花花绿绿的噪点图"。
	# 小地图要的是**区域**（草甸 / 台地 / 岩脊 / 峡谷），不是地形高程图。
	for z in range(row):
		for x in range(row):
			var acc: float = 0.0
			for dz in range(-2, 3):
				var zz: int = clampi(z + dz, 0, row - 1)
				for dx in range(-2, 3):
					var xx: int = clampi(x + dx, 0, row - 1)
					acc += hs[zz * row + xx]
			var h: float = acc / 25.0
			var c := _height_color(h)
			# 地块（魔兽 3 口径的 8m 格点表）：土路 / 营地 / 矿点在图上直接是土色。
			# 这比"按高度上色"有用得多 —— 玩家看小地图是在找"从哪条路能绕过去"。
			if mat_nodes.size() > 0 and mat_cells > 0:
				var n: int = mat_cells + 1
				if mat_nodes.size() == n * n:
					var half: float = world_size * 0.5
					var step: float = world_size / float(mat_cells)
					var gp := Vector2(-half + float(x) / float(maxi(row - 1, 1)) * world_size,
						-half + float(z) / float(maxi(row - 1, 1)) * world_size)
					var mi: int = clampi(int(round((gp.x + half) / step)), 0, n - 1)
					var mj: int = clampi(int(round((gp.y + half) / step)), 0, n - 1)
					if mat_nodes[mj * n + mi] > 128:
						c = c.lerp(Color(0.36, 0.29, 0.20), 0.72)
			var i: int = (z * row + x) * 4
			bytes[i] = int(clampf(c.r, 0.0, 1.0) * 255.0)
			bytes[i + 1] = int(clampf(c.g, 0.0, 1.0) * 255.0)
			bytes[i + 2] = int(clampf(c.b, 0.0, 1.0) * 255.0)
			bytes[i + 3] = 255
	var img := Image.create_from_data(row, row, false, Image.FORMAT_RGBA8, bytes)
	_terrain_tex = ImageTexture.create_from_image(img)
	_terrain_built = true


## 高度 → 小地图片色。色阶直接对齐地表顶点色（草 → 干草 → 土 → 岩 → 亮顶），
## 这样小地图上的一块绿/一块灰，在战场上就是同样的草坡/岩壁。
func _height_color(h: float) -> Color:
	var t: float = clampf((h - _hmin) / maxf(_hmax - _hmin, 0.001), 0.0, 1.0)
	var c_deep := Color(0.086, 0.170, 0.066)
	var c_grass := Color(0.152, 0.292, 0.110)
	var c_dry := Color(0.300, 0.302, 0.156)
	var c_dirt := Color(0.330, 0.278, 0.180)
	var c_rock := Color(0.360, 0.368, 0.382)
	var c_top := Color(0.560, 0.552, 0.522)
	# 低地占画面 70%：**统一成深绿**（留一点起伏），高差明显的台地/岩脊才跳出来。
	# 旧版从头到尾都在渐变，整张图读起来像迷彩。
	if t < 0.40:
		return c_deep.lerp(c_grass, 0.35 + 0.65 * (t / 0.40))
	if t < 0.62:
		return c_grass.lerp(c_dry, (t - 0.40) / 0.22)
	if t < 0.76:
		return c_dry.lerp(c_dirt, (t - 0.62) / 0.14)
	if t < 0.90:
		return c_dirt.lerp(c_rock, (t - 0.76) / 0.14)
	return c_rock.lerp(c_top, (t - 0.90) / 0.10)


## 视野框：把屏幕四角打到地面，再映射到小地图（四点组成的梯形）
func _view_polygon() -> PackedVector2Array:
	var out := PackedVector2Array()
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null:
		return out
	var vsize: Vector2 = vp.get_visible_rect().size
	if vsize.x < 8.0 or vsize.y < 8.0:
		return out
	var corners: Array = [
		Vector2(0.0, 0.0), Vector2(vsize.x, 0.0),
		Vector2(vsize.x, vsize.y), Vector2(0.0, vsize.y),
	]
	var cam_node := cam.get_parent()
	for c in corners:
		var w: Vector3
		if cam_node != null and cam_node.has_method("ray_ground"):
			w = cam_node.call("ray_ground", cam.project_ray_origin(c), cam.project_ray_normal(c))
		else:
			var ro: Vector3 = cam.project_ray_origin(c)
			var rd: Vector3 = cam.project_ray_normal(c)
			if absf(rd.y) < 0.0001:
				return _view_fallback_rect(cam)
			var t: float = (0.0 - ro.y) / rd.y
			if t < 0.0:
				return _view_fallback_rect(cam)
			w = ro + rd * t
		# ★ 用**不裁剪**的映射：镜头看到地图外时，四角本来就该落在圆盘外面。
		#   旧版在这里 clamp 到 [0,1]，梯形会被压成一块贴边的白色大方块 ——
		#   玩家说的"小地图对不上"，一半是它。
		out.append(_world_to_map_raw(w))
	# 退化保护：四个角挤成一团（相机贴地/朝天上）时，用镜头距离估一个框，
	# 也好过"什么都没有"。
	if out.size() == 4:
		var aabb := Rect2(out[0], Vector2.ZERO)
		for i in range(1, 4):
			aabb = aabb.expand(out[i])
		if aabb.size.x < 8.0 or aabb.size.y < 8.0:
			return _view_fallback_rect(cam)
	return out


## 兜底取景框：以镜头注视点为中心、按当前缩放估一块矩形。
## 这不是"假数据"—— 它保证任何相机姿态下玩家都能看到"我现在大概在看哪"。
func _view_fallback_rect(cam: Camera3D) -> PackedVector2Array:
	var node := cam.get_parent()
	var ctr := Vector3.ZERO
	var dist := 26.0
	if node != null:
		if node.has_method("focus_point"):
			var fp: Variant = node.call("focus_point")
			if fp is Vector3:
				ctr = fp
		if node.has_method("distance"):
			dist = maxf(float(node.call("distance")), 8.0)
	var pc := _world_to_map(ctr)
	var mr := _map_rect()
	var hw: float = clampf(dist * 1.35 / maxf(world_size, 1.0) * mr.size.x,
		10.0, mr.size.x * 0.62)
	var hh: float = hw * 0.58
	return PackedVector2Array([
		pc + Vector2(-hw, -hh), pc + Vector2(hw, -hh),
		pc + Vector2(hw, hh), pc + Vector2(-hw, hh),
	])


## 画视野框：填充 + 暗描边 + 亮描边 + 四角角标 + 镜头朝向箭头。
## **小地图上必须能一眼找到"玩家视角"**，所以它不是装饰，是主信息之一。
## ★ 圆盘裁剪 shader 的坑（这次才查出来）：
##   控件挂的 canvas_item 着色器用 UV 算"圆内/圆外"，而 draw_colored_polygon /
##   draw_polyline / draw_line / draw_circle **不带 UV**（顶点 UV = 0），
##   于是这些图元全被判成"圆外"、整批 discard —— 旧版视野梯形就是这么消失的：
##   代码一直在画，只是从来没显示出来（玩家报"小地图看不到玩家视角在哪"）。
##   结论：在这个控件里画任何**非矩形**图元，都必须显式给 UV = 像素/控件尺寸。
func _canvas_uv(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	if size.x < 1.0 or size.y < 1.0:
		return out
	for p in points:
		out.append(p / size)
	return out


## 带 UV 的实心多边形（圆盘裁剪下唯一能活下来的填充图元）
func _fill_poly_uv(points: PackedVector2Array, color: Color) -> void:
	if points.size() < 3:
		return
	draw_colored_polygon(points, color, _canvas_uv(points))


## 带 UV 的粗线（用四边形拼；draw_line 没有 UV，会被 discard）
func _thick_line_uv(a: Vector2, b: Vector2, width: float, color: Color) -> void:
	var d := b - a
	if d.length_squared() < 0.0001:
		return
	var n := d.normalized().orthogonal() * (width * 0.5)
	_fill_poly_uv(PackedVector2Array([a + n, b + n, b - n, a - n]), color)


## 带 UV 的圆点
func _dot_uv(center: Vector2, radius: float, color: Color, segs: int = 12) -> void:
	var pts := PackedVector2Array()
	for i in segs:
		var a: float = TAU * float(i) / float(segs)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	_fill_poly_uv(pts, color)


## 画视野框：填充 + 暗描边 + 亮描边 + 四角角标 + 镜头朝向箭头。
## **小地图上必须能一眼找到"玩家视角"**，所以它不是装饰，是主信息之一。
func _draw_view_box() -> void:
	var poly := _view_polygon()
	if OS.has_environment("MM_DEBUG"):
		print("[MM-VIEW] pts=%d poly=%s" % [poly.size(), str(poly)])
	if poly.size() < 3:
		return
	# 1) 很淡的填充：能看出"镜头盖住了哪一块"，但不会压过单位点
	_fill_poly_uv(poly, VIEW_FILL)
	# 2) 描边：2.6px 暗底（只在亮地面上负责分离）+ 1.2px 亮线
	for i in poly.size():
		var j: int = (i + 1) % poly.size()
		_thick_line_uv(poly[i], poly[j], 2.6, Color(0.02, 0.03, 0.05, 0.30))
	for i2 in poly.size():
		var j2: int = (i2 + 1) % poly.size()
		_thick_line_uv(poly[i2], poly[j2], 1.2, VIEW_LINE)
	# 3) 四角角标：4px 小折角，只当方向提示
	var ctr := Vector2.ZERO
	for c in poly:
		ctr += c
	ctr /= float(poly.size())
	for c2 in poly:
		var d: Vector2 = c2 - ctr
		if d.length() > 0.01:
			d = d.normalized()
		var side := d.orthogonal() * 2.2
		_thick_line_uv(c2 - d * VIEW_TICK + side, c2, 1.2, VIEW_LINE)
		_thick_line_uv(c2 - d * VIEW_TICK - side, c2, 1.2, VIEW_LINE)
	# 4) 镜头位置 + 朝向箭头（"玩家到底在看哪一边"）
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null:
		return
	var node := cam.get_parent()
	if node == null:
		return
	var focus := Vector3.ZERO
	var yaw := 0.0
	if node.has_method("focus_point"):
		var fp: Variant = node.call("focus_point")
		if fp is Vector3:
			focus = fp
	if node.has_method("yaw_degrees"):
		yaw = deg_to_rad(float(node.call("yaw_degrees")))
	var pc := _world_to_map(focus)
	# 镜头看向 -Z 旋转 yaw 后的方向，映射到小地图（+x 右 / +z 下）
	var dir := Vector2(-sin(yaw), -cos(yaw))
	var side2 := dir.orthogonal()
	# 箭头只做"朝向"的极小提示（7px），不再画大三角 + 黑底
	var tip := pc + dir * 7.0
	var a := pc + side2 * 2.8 - dir * 1.0
	var b := pc - side2 * 2.8 - dir * 1.0
	_fill_poly_uv(PackedVector2Array([tip, a, b]), Color(0.90, 0.98, 1.0, 0.62))
	_dot_uv(pc, 1.2, Color(0.02, 0.03, 0.05, 0.45))


## 小地图点画序：敌人 0 / 盟友 1 / 自己 2（自己的点永远压在最上面）
func _dot_rank(f: RtsFaction) -> int:
	var pl := Game.player_faction
	if f == null or pl == null:
		return 0
	if f == pl:
		return 2
	if pl.is_ally_of(f):
		return 1
	return 0


## 迷雾可见（没有迷雾节点时一律可见）
func _fog_visible(p: Vector3) -> bool:
	if _fog_node == null or not is_instance_valid(_fog_node):
		return true
	if _fog_node.has_method("is_world_visible_pos"):
		return bool(_fog_node.call("is_world_visible_pos", p))
	return true


## 迷雾已探索（曾经看见过）
func _fog_explored(p: Vector3) -> bool:
	if _fog_node == null or not is_instance_valid(_fog_node):
		return true
	if _fog_node.has_method("is_world_explored_pos"):
		return bool(_fog_node.call("is_world_explored_pos", p))
	return true


# ===========================================================================
# 坐标 / 交互
# ===========================================================================

## 世界坐标 → 小地图局部坐标（在地图区内，避开边框与图例）
func _world_to_map(p: Vector3) -> Vector2:
	var mr := _map_rect()
	var half: float = world_size * 0.5
	var u: float = clampf((p.x + half) / world_size, 0.0, 1.0)
	var v: float = clampf((p.z + half) / world_size, 0.0, 1.0)
	return Vector2(mr.position.x + u * mr.size.x, mr.position.y + v * mr.size.y)


## 小地图局部坐标 → 世界坐标（地面 y=0 附近，镜头自己会贴地）
func _map_to_world(p: Vector2) -> Vector3:
	var mr := _map_rect()
	if mr.size.x <= 0.0 or mr.size.y <= 0.0:
		return Vector3.ZERO
	var half: float = world_size * 0.5
	var u: float = clampf((p.x - mr.position.x) / mr.size.x, 0.0, 1.0)
	var v: float = clampf((p.y - mr.position.y) / mr.size.y, 0.0, 1.0)
	return Vector3(u * world_size - half, 0.0, v * world_size - half)


## 世界坐标 → 小地图局部坐标（**不裁剪**，超出地图的部分留给圆形遮罩切掉）
func _world_to_map_raw(p: Vector3) -> Vector2:
	var mr := _map_rect()
	var half: float = world_size * 0.5
	var u: float = (p.x + half) / world_size
	var v: float = (p.z + half) / world_size
	return Vector2(mr.position.x + u * mr.size.x, mr.position.y + v * mr.size.y)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.pressed:
				_focus_at(mb.position)
			queue_redraw()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_focus_at(mm.position)
		accept_event()


## 点小地图 → 镜头飞过去
func _focus_at(local_pos: Vector2) -> void:
	var target := _map_to_world(local_pos)
	var vp := get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam == null:
		return
	var cam_node := cam.get_parent()
	if cam_node != null and cam_node.has_method("focus_on"):
		cam_node.call("focus_on", target)
