class_name SelectionSystem
extends Node
## **选择系统（HAWKEYE）**
##
## 职责（对齐 文档/作战条令.md §7）：
##   - 左键单选：**射线 × 竖直胶囊**相交（纯数学，不用物理引擎，避免不确定性）
##   - 左键拖框多选：把每个单位的锚点投影到屏幕，做矩形包含判断
##   - Shift 加选/减选、双击同类全选
##   - 维护 `selected`，并同步 `RtsUnit.is_selected` 与"选中圈"
##   - 每次变化广播 `Game.selection_changed`
##
## 三个容易漏的细节：
##   1. 点和拖框都要判"鼠标是不是压在界面上"（否则点 HUD 会顺手选中背后的单位）；
##   2. 指令系统处于"等待落点"状态（攻击移动/建造/施法）时，左键归它用，这里要跳过；
##   3. 单位会死，选中集合必须及时剔除无效/死亡引用，否则界面和小地图会崩。

## 拖框阈值（像素）：小于它的拖动算点击，不算框选
const BOX_MIN_PIXELS := 6.0
## 双击判定窗口（秒）
const DOUBLE_CLICK_WINDOW := 0.35
## 自动清理死亡引用的间隔（秒）
const PRUNE_INTERVAL := 0.25

## 当前选中（Array[Node3D]，玩家自己的单位/建筑）
var selected: Array = []

## 鼠标按下中 / 正在拖框
var _pressing: bool = false
var _boxing: bool = false
var _press_pos: Vector2 = Vector2.ZERO
## 圈选模式（参照图右列"圈选"）：拖出圆形范围，按屏幕距离选己方单位
var circle_mode: bool = false

## 拖框覆盖层（只画、不吃事件）
var _overlay: Control = null

## 选中圈：unit → Node3D
var _rings: Dictionary = {}

## 双击判定
var _last_click_time: float = -10.0
var _last_click_id: StringName = &""

## 清理计时
var _prune_clock: float = 0.0

## 缓存的兄弟节点（指令系统）
var _command_system: Node = null
## 缓存的兄弟节点（界面，用来判"点在不在 UI 上"）
var _hud: Node = null


# ===========================================================================
# 拖框覆盖层（内部类：一个只负责画矩形的 Control）
# ===========================================================================
class BoxOverlay extends Control:
	## 当前框（屏幕坐标）
	var box: Rect2 = Rect2()
	## 是否显示
	var showing: bool = false
	## 圈选预览
	var circle: bool = false
	var center: Vector2 = Vector2.ZERO
	var radius: float = 0.0

	func _draw() -> void:
		if not showing:
			return
		if circle:
			draw_circle(center, radius, Color(0.55, 0.80, 1.0, 0.13))
			draw_arc(center, radius, 0.0, TAU, 72, Color(0.70, 0.90, 1.0, 0.90), 1.5)
		else:
			draw_rect(box, Color(0.55, 0.80, 1.0, 0.13), true)
			draw_rect(box, Color(0.70, 0.90, 1.0, 0.90), false, 1.5)


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	# 建筑升级（哨塔→箭塔）会把旧节点换掉：建筑侧靠这个组找到选择系统，
	# 把选中跟着搬到新节点上（否则玩家面板会突然变空）。
	add_to_group("selection_system")
	_overlay = BoxOverlay.new()
	_overlay.name = "拖框层"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_TOP_LEFT)
	add_child(_overlay)
	_sync_overlay_size()

	Game.unit_died.connect(_on_unit_died)


func _process(delta: float) -> void:
	_sync_overlay_size()
	_prune_clock += delta
	if _prune_clock >= PRUNE_INTERVAL:
		_prune_clock = 0.0
		_prune_dead()


## 覆盖层尺寸跟着视口（不靠锚点，避免父节点不是 CanvasItem 时行为不确定）
func _sync_overlay_size() -> void:
	if _overlay == null:
		return
	var vp := get_viewport()
	if vp == null:
		return
	var size := vp.get_visible_rect().size
	if _overlay.size != size:
		_overlay.size = size
		_overlay.position = Vector2.ZERO


# ===========================================================================
# 对外接口
# ===========================================================================

## 清空选择
func clear() -> void:
	_set_selection([])


## 清空选择（别名：别的模块/测试可能按这个名字找）
func clear_selection() -> void:
	clear()


## 当前选中的存活单位/建筑（过滤掉已失效的）
func selected_units() -> Array:
	var out: Array = []
	for u in selected:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_alive") and not u.is_alive():
			continue
		out.append(u)
	return out


## 当前选中的第一个（界面主显示用；没有返回 null）
func primary() -> Node3D:
	var arr := selected_units()
	return arr[0] as Node3D if not arr.is_empty() else null


# ===========================================================================
# 输入
# ===========================================================================

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		_on_left_button(mb)
	elif event is InputEventMouseMotion and _pressing:
		var mm := event as InputEventMouseMotion
		_update_box(mm.position)


## 左键按下/抬起
func _on_left_button(mb: InputEventMouseButton) -> void:
	if mb.pressed:
		if _ui_blocks_world(mb.position) or _command_pending():
			return
		_pressing = true
		_boxing = false
		_press_pos = mb.position
		get_viewport().set_input_as_handled()
		return

	# --- 抬起 ---
	if not _pressing:
		return
	_pressing = false
	if _boxing:
		var additive := Input.is_key_pressed(KEY_SHIFT)
		if circle_mode:
			var radius: float = _press_pos.distance_to(mb.position)
			_hide_box()
			_select_circle(_press_pos, radius, additive)
		else:
			var rect := _box_rect(mb.position)
			_hide_box()
			_select_box(rect, additive)
	else:
		_click_select(mb.position, Input.is_key_pressed(KEY_SHIFT))
	get_viewport().set_input_as_handled()


## 拖动中：超过阈值才进入"框选"
func _update_box(pos: Vector2) -> void:
	if not _boxing and pos.distance_to(_press_pos) > BOX_MIN_PIXELS:
		_boxing = true
	if not _boxing:
		return
	if _overlay is BoxOverlay:
		var bo := _overlay as BoxOverlay
		if circle_mode:
			bo.circle = true
			bo.center = _press_pos
			bo.radius = _press_pos.distance_to(pos)
		else:
			bo.circle = false
			bo.box = _box_rect(pos)
		bo.showing = true
		bo.queue_redraw()


## 隐藏拖框
func _hide_box() -> void:
	if _overlay is BoxOverlay:
		var bo := _overlay as BoxOverlay
		bo.showing = false
		bo.queue_redraw()


## 两点 → 规范化矩形
func _box_rect(pos: Vector2) -> Rect2:
	return Rect2(_press_pos, pos - _press_pos).abs()


## 圈选：屏幕距离圆心 ≤ 半径的己方单位；过滤规则与框选完全一致
func _select_circle(center: Vector2, radius: float, additive: bool) -> void:
	var cam := _camera()
	if cam == null or radius < 1.0:
		return
	var player := Game.player_faction
	var out: Array = []
	if additive:
		for u in selected:
			if is_box_unit(u, player):
				out.append(u)
	var saw_building := false
	for n in _selectable_units():
		var anchor := _anchor_point(n)
		if cam.is_position_behind(anchor):
			continue
		if cam.unproject_position(anchor).distance_to(center) > radius:
			continue
		if n is RtsBuilding:
			saw_building = true
			continue
		if not is_box_unit(n, player):
			continue
		if not out.has(n):
			out.append(n)
	_set_selection(out)
	if out.is_empty() and saw_building and not additive:
		Game.toast("圈选只选单位 · 建筑请单击选择", _accent_color())


# ===========================================================================
# 单选
# ===========================================================================

## 点选：射线拾取（点到敌方/资源上面不改变选择，符合魔兽手感）
func _click_select(screen_pos: Vector2, additive: bool) -> void:
	var cam := _camera()
	var hit: Node3D = null
	if cam != null:
		hit = _pick(cam.project_ray_origin(screen_pos), cam.project_ray_normal(screen_pos))

	if hit == null:
		_last_click_time = -10.0
		_last_click_id = &""
		if not additive:
			_set_selection([])
		return

	var id: StringName = _def_id(hit)
	var hit_faction := hit.get("faction") as RtsFaction
	var now: float = Time.get_ticks_msec() * 0.001
	var is_double: bool = (now - _last_click_time) <= DOUBLE_CLICK_WINDOW and id == _last_click_id and id != &""
	_last_click_time = now
	_last_click_id = id

	# 双击同类：选中屏幕上所有同 id 的**己方单位**。
	# 建筑/敌方/可采集物不参与：双击它们只是普通单选（不会清空已有选择，
	# 也不会把敌人的同型兵一起框进来 —— 框选/双击都只服务"指挥自己的兵"这件事）。
	if is_double and not (hit is RtsBuilding) and hit_faction == Game.player_faction:
		_select_all_of_type(id)
		return

	if additive:
		if selected.has(hit):
			selected.erase(hit)
		else:
			selected.append(hit)
		_commit()
	else:
		_set_selection([hit])


## 双击：选中视野内所有同类型**己方单位**（阵营/建筑/资源一律过滤，见 is_box_unit）
func _select_all_of_type(id: StringName) -> void:
	if id == &"":
		return
	var cam := _camera()
	if cam == null:
		return
	var player := Game.player_faction
	var vp_rect := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var out: Array = []
	for n in _selectable_units():
		if not is_box_unit(n, player):
			continue
		if _def_id(n) != id:
			continue
		var anchor := _anchor_point(n)
		if cam.is_position_behind(anchor):
			continue
		if vp_rect.has_point(cam.unproject_position(anchor)):
			out.append(n)
	_set_selection(out)


# ===========================================================================
# 框选
# ===========================================================================

## 框选：**只框玩家自己的移动单位**（不含建筑、不含可采集物、不含敌方 —— 魔兽3 的惯例）。
##
## 历史坑：这里原先把 _selectable_units() 全量塞进来，于是"点选能选敌人/资源"的能力
## 被顺带搬到了框选上：框一次会框进敌方小兵和树/矿，玩家自己的 12 个兵变成 16 个。
## 现在统一走 is_box_unit()：己方 + 活着 + 非建筑 + 非可采集物。
func _select_box(rect: Rect2, additive: bool) -> void:
	var cam := _camera()
	if cam == null:
		return
	if rect.size.x < 1.0 and rect.size.y < 1.0:
		# 兜底：双击被当成框了
		return
	var player := Game.player_faction
	var out: Array = []
	# Shift 加选：保留原有选择，但同样把建筑/资源/敌方摘掉（框选结果永远只有己方单位）
	if additive:
		for u in selected:
			if is_box_unit(u, player):
				out.append(u)
	var saw_building := false
	for n in _selectable_units():
		var anchor := _anchor_point(n)
		if cam.is_position_behind(anchor):
			continue
		if not rect.has_point(cam.unproject_position(anchor)):
			continue
		if n is RtsBuilding:
			saw_building = true
			continue
		if not is_box_unit(n, player):
			continue
		if not out.has(n):
			out.append(n)
	_set_selection(out)
	# 框里只有建筑（常见：想把基地拖进来）→ 明说一句，别让人以为框选坏了
	if out.is_empty() and saw_building and not additive:
		Game.toast("框选只选单位 · 建筑请单击选择", _accent_color())


# ===========================================================================
# 拾取数学：射线 × 竖直胶囊
# ===========================================================================

## 从自己的单位/建筑里点一个（最近命中优先）
## 屏幕上**至少保留**这么多像素的点击半径。
## 玩家 2026-11-08：「缩小视角时，单位建筑的选中碰撞不变，影响手感。」
## 原因：拾取用的是世界空间胶囊半径（def.selection_radius），镜头拉远后它在屏幕上
## 只有几个像素，鼠标点在兵身上也点不中。这里给一个**屏幕像素下限**，
## 按当前镜头距离把世界半径补足（封顶 MAX_PICK_SCALE 倍，免得拉极远时满屏都算点中）。
const MIN_PICK_PX: float = 16.0
const MAX_PICK_SCALE: float = 3.0


func _pick(ray_o: Vector3, ray_d: Vector3) -> Node3D:
	var best: Node3D = null
	var best_t: float = INF
	# 屏幕像素 → 世界米 的换算（每个候选按自己的深度算，越远补得越多）
	var cam := _camera()
	var vp_h: float = float(get_viewport().get_visible_rect().size.y) if is_inside_tree() else 900.0
	var tan_half: float = tan(deg_to_rad(cam.fov) * 0.5) if cam != null else 0.0
	for n in _selectable_units():
		# 迷雾里被藏起来的敌人不许点选（否则"看不见也能选中"，等于免费开图）
		if not n.visible:
			continue
		var r: float = _select_radius(n)
		# ★ 屏幕空间下限：拉远镜头时选中碰撞不要跟着缩成几个像素
		if cam != null and vp_h > 1.0 and tan_half > 0.0001:
			var depth: float = maxf((n.global_position - cam.global_position).dot(-cam.global_transform.basis.z), 1.0)
			var px_per_m: float = vp_h * 0.5 / (depth * tan_half)
			if px_per_m > 0.0001:
				var want: float = MIN_PICK_PX / px_per_m
				r = clampf(maxf(r, want), r, r * MAX_PICK_SCALE)
		var bottom: float = minf(r, 0.45)
		var a: Vector3 = n.global_position + Vector3.UP * bottom
		var b: Vector3 = a + Vector3.UP * maxf(_def_height(n) - bottom, 0.25)
		var hit := _ray_vs_segment(ray_o, ray_d, a, b)
		if hit.y > r:
			continue
		# ★ 点击优先级：单位优先于建筑。
		#   原来只比"射线命中距离"，而建筑的拾取胶囊又高又粗（大本营半径 5.4），
		#   站在建筑旁边的兵永远抢不过建筑 —— 就是"点单位结果选中建筑"的原因。
		#   现在给建筑加 3m 惩罚距离，并把它作为平手时的劣后项。
		# 单位永远优先：建筑 3m、可采集物 3.5m 的惩罚距离
		var bias: float = 0.0
		if n is RtsBuilding:
			bias = 3.0
		elif n is RtsHarvestable:
			bias = 3.5
		var key: float = hit.x + bias
		if key < best_t:
			best_t = key
			best = n
	return best


## 射线到线段的最近距离。
## 返回 Vector2(t, dist)：t = 沿射线的参数（负值已夹成 0），dist = 射线与线段的最近垂距。
func _ray_vs_segment(ro: Vector3, rd: Vector3, a: Vector3, b: Vector3) -> Vector2:
	var ab := b - a
	var ab_len2 := ab.length_squared()
	if ab_len2 < 0.000001:
		var t0 := (a - ro).dot(rd)
		if t0 < 0.0:
			return Vector2(0.0, ro.distance_to(a))
		return Vector2(t0, ro.distance_to(a))
	# 线段上离射线最近的点：s = ((w·rd)(ab·rd) - w·ab) / (|ab|² - (ab·rd)²)
	var w := a - ro
	var abd := ab.dot(rd)
	var denom := ab_len2 - abd * abd
	var s: float = 0.0
	if absf(denom) > 0.000001:
		s = clampf(((w.dot(rd)) * abd - w.dot(ab)) / denom, 0.0, 1.0)
	var q: Vector3 = a + ab * s
	var t: float = (q - ro).dot(rd)
	if t <= 0.0:
		# 在射线背后：退化成"射线起点到线段"的距离
		var s2 := clampf((ro - a).dot(ab) / ab_len2, 0.0, 1.0)
		return Vector2(0.0, ro.distance_to(a + ab * s2))
	var d2: float = (q - ro).length_squared() - t * t
	return Vector2(t, sqrt(maxf(d2, 0.0)))


# ===========================================================================
# 选择集合维护
# ===========================================================================

## 直接指定选择集合（HUD / 主场景的 QA 钩子用；签名与调用方一致）。
##
## 为什么必须有这层：调用方一直用 has_method("select_units") 探测，但本类原先没有这个方法，
## 于是 QA 截图全走了"set(selected) + 手动 emit"的旁路 —— 选中圈不生成、_commit 不走，
## 选中状态只同步了一半。这里统一走 _set_selection，保证圈/信号/is_selected 一致。
func select_units(list: Array) -> void:
	var arr: Array = []
	for u in list:
		if u == null or not is_instance_valid(u):
			continue
		arr.append(u)
	_set_selection(arr)


## 设置选择（唯一的入口，保证 is_selected / 选中圈 / 信号同步）
func _set_selection(list: Array) -> void:
	for u in selected:
		if u != null and is_instance_valid(u) and "is_selected" in u:
			u.set("is_selected", false)
	selected.clear()
	for u in list:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_alive") and not u.is_alive():
			continue
		if not selected.has(u):
			selected.append(u)
	_commit()


## 把当前 selected 广播出去并同步选中圈
func _commit() -> void:
	for u in selected:
		if u != null and is_instance_valid(u) and "is_selected" in u:
			u.set("is_selected", true)
	_sync_rings()
	Game.selection_changed.emit(selected)


## 同步选中圈（多退少补）
func _sync_rings() -> void:
	# 移除不再需要的
	for key in _rings.keys():
		if key == null or not is_instance_valid(key) or not selected.has(key):
			var old: Node = _rings.get(key, null)
			if old != null and is_instance_valid(old):
				old.queue_free()
			_rings.erase(key)
	# 补上新的
	for u in selected:
		if u == null or not is_instance_valid(u):
			continue
		if _rings.has(u):
			continue
		var ring := _make_ring(u)
		if ring != null:
			_rings[u] = ring
			# 只在这一刻（从"没圈"变成"有圈"）放一次收束反馈：
			# 取消选中、保持选中都不放，否则每次刷新都在闪，反而吵。
			Vfx.selection_burst(u.global_position, _unit_radius(u), _ring_color(u))
	_sync_range_rings()


# ===========================================================================
# 攻击范围圈
# ===========================================================================
## 攻击范围圈：unit → Node3D（挂在单位身上的贴地圆环，跟随移动，无需每帧更新）
var _range_rings: Dictionary = {}
## 攻击范围圈的线宽（米）。0.22 在 44m 的默认视距下正好"看得见又不吵"
const RANGE_RING_WIDTH := 0.14
## 贴在离地多高（米）：0.12 能压住地形又不和选中圈（0.06）打架
const RANGE_RING_LIFT := 0.12
## 攻击圈的固定颜色（暖金）：和"选中圈/判定圈"（阵营色）明确区分。
## 玩家 2026-11-08：「两个圈不同颜色。」
const ATTACK_RING_COLOR := Color(0.98, 0.74, 0.32)


## **该给谁画攻击圈**（唯一判据）。
##
## 玩家口径（2026-11-01）：
##   · 单个单位/建筑选中 → 画；
##   · 同一种（同一个 UnitDef）多选 → 每个都画；
##   · **混合选中不画** —— 步兵 1.4m + 弓手 8m + 箭塔 13m 叠在一起，
##     只会糊成一坨光圈，反而看不清任何一个的真实射程。
##   · 不能攻击的（农民/农场/哨塔）不画。
func _range_targets() -> Array:
	var out: Array = []
	if selected.is_empty():
		return out
	# ★ 2026-11-06 玩家口径「似乎有两个圆圈」：多选同类时每个单位各画一个射程圈，
	#   3 个弩兵 = 3 个 12m 大圈叠在一起，屏幕上只剩一堆圆圈。
	#   射程是**单个单位**的属性，多选时它不构成信息量 → 只在单选时画。
	if selected.size() > 1:
		return out
	var first_id: StringName = &""
	for u in selected:
		var n := u as RtsUnit
		# 选到资源/装饰也算"混合"：它们没有攻击范围，混进来就整组不画。
		if n == null or n.def == null:
			return []
		if not n.def.can_attack():
			return []
		if first_id == &"":
			first_id = n.def.id
		elif n.def.id != first_id:
			return []
		out.append(n)
	return out


## 攻击范围圈的多退少补。圈挂在单位节点下，单位一动圈跟着动（零每帧开销）。
func _sync_range_rings() -> void:
	var want: Array = _range_targets()
	var keep: Dictionary = {}
	for u in want:
		keep[u] = true
	for key in _range_rings.keys():
		if key == null or not is_instance_valid(key) or not keep.has(key):
			var old: Node = _range_rings.get(key, null)
			if old != null and is_instance_valid(old):
				old.queue_free()
			_range_rings.erase(key)
	for u in want:
		if _range_rings.has(u):
			continue
		var ring := _make_range_ring(u)
		if ring != null:
			_range_rings[u] = ring


## 造一个贴地的攻击范围圆环。
##
## 只画"圈"不画"盘"：盘会盖住地表明暗（RTS 里选区高亮是另一种信息，别混）。
## ★ 2026-11-08 最终口径（玩家）：
##   · **攻击圈 = 射程 × R1，固定**；不随场上最大单位体型修正，也不加自身/目标半径；
##   · 命中是"两圈相交"（攻击圈 + 目标判定圈），所以**圈外还够得着目标的身体**是对的 ——
##     圈代表"我能打到多远"，不是"敌人中心能站到哪"；
##   · 单选画攻击圈 + 选中圈（判定圈），两圈**不同颜色**（攻击=暖金，选中=阵营色）。
func _range_ring_radius(u: RtsUnit) -> float:
	return range_ring_radius_of(u)


## 攻击圈画多大（**唯一公式**，自检直接调这个，不用建场景）。
## = 单位自己的攻击圈半径；建筑塔也一样（圈中心在建筑原点）。
static func range_ring_radius_of(u: RtsUnit) -> float:
	if u == null or not is_instance_valid(u):
		return 0.0
	return maxf(u.attack_circle_radius(), 0.0)


func _make_range_ring(u: RtsUnit) -> Node3D:
	if u == null or not is_instance_valid(u) or u.def == null:
		return null
	var r: float = _range_ring_radius(u)
	if r <= 0.0:
		return null
	var color: Color = ATTACK_RING_COLOR

	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var segs: int = 72
	for i in range(segs + 1):
		var ang: float = TAU * float(i) / float(segs)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		im.surface_set_color(Color(color.r, color.g, color.b, 0.34))
		im.surface_add_vertex(dir * r)
		im.surface_set_color(Color(color.r, color.g, color.b, 0.16))
		im.surface_add_vertex(dir * (r - RANGE_RING_WIDTH))
	im.surface_end()

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# 不写深度：塔/树/山坡挡住的那段范围也看得见 —— 玩家要的是"打得到多远"，
	# 不是一个被地形裁掉一半的弧。
	mat.no_depth_test = true
	mat.render_priority = 2
	mat.albedo_color = Color.WHITE

	var mi := MeshInstance3D.new()
	mi.name = "攻击范围"
	mi.mesh = im
	mi.material_override = mat
	mi.position = Vector3(0.0, RANGE_RING_LIFT, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# 建筑很高：圆环挂在**脚底**（本地原点就是建筑基座中心）
	u.add_child(mi)
	return mi


## 生成一个选中圈：三级兜底
##   1. ArtKit.vfx_ring（走 ANVIL 的 代码/美术/特效生成.gd）
##   2. 美术侧给好的 美术/特效/选中圈.tscn（文档 §7 点名的资源）
##   3. 自己画一段贴地环形三角带（保证美术没到位也能看出选中了谁）
func _make_ring(u: Node3D) -> Node3D:
	# ★ 2026-11-08 玩家口径：选中圈就是**判定圈** —— 半径从体积派生（`judge_radius`）。
	#   旧版画的是"拾取半径 × 1.02"，比身体大一圈，和命中判定没有关系。
	#   建筑照旧按占地半对角线罩住（建筑没有判定圈，它的身体是占地矩形）。
	var radius: float = maxf(_select_radius(u), 0.55)
	var ru := u as RtsUnit
	if ru != null:
		radius = maxf(ru.judge_radius(), 0.35)
	var b := u as RtsBuilding
	if b != null and b.def != null and b.def.footprint != Vector2i.ZERO:
		var hx: float = float(maxi(b.def.footprint.x, 1)) * 0.5
		var hz: float = float(maxi(b.def.footprint.y, 1)) * 0.5
		radius = maxf(radius, sqrt(hx * hx + hz * hz) * 1.03)
	# 选中圈颜色跟着**阵营显示色**走：自己的蓝、盟友的青、敌人的红/绿。
	# 以前整圈一律用玩家蓝 —— 选中盟友时圈子和自己一模一样，"选中了谁"读不出来。
	var color: Color = _ring_color(u)
	var ring: Node3D = ArtKit.vfx_ring(u, radius, color)
	if ring == null:
		ring = _ring_from_scene(radius, color)
	if ring == null:
		ring = _fallback_ring(u, radius, color)
	if ring == null:
		return null
	ring.name = "选中圈"
	if ring.get_parent() == null:
		u.add_child(ring)
	return ring


## 选中圈/选中爆发的配色：跟**阵营显示色**走（自己蓝、盟友青、敌人红/绿）
func _ring_color(u: Node) -> Color:
	var fac := u.get("faction") as RtsFaction
	if fac != null:
		return fac.color
	if Cfg.game != null:
		return Cfg.game.player_color
	return Color(0.3, 0.62, 1.0)


## 选中爆发用的半径：单位用自己的碰撞半径；建筑等没有 get_radius 的退回拾取半径
func _unit_radius(u: Node) -> float:
	if u.has_method("get_radius"):
		var r: float = float(u.call("get_radius"))
		if r > 0.05:
			return r
	return maxf(_select_radius(u) * 0.75, 0.5)


## 美术侧给好的选中圈场景（有就用；缩放按半径调，颜色给 shader/material 尽量套）
func _ring_from_scene(radius: float, color: Color) -> Node3D:
	const RING_SCENE := "res://美术/特效/选中圈.tscn"
	if not ResourceLoader.exists(RING_SCENE):
		return null
	var ps: PackedScene = load(RING_SCENE) as PackedScene
	if ps == null:
		return null
	var node := ps.instantiate() as Node3D
	if node == null:
		return null
	# 场景一般按半径 1 建，这里按选中半径缩放（尺子不同的美术自己改）
	node.scale = Vector3(radius, 1.0, radius)
	ArtKit.apply_team_color(node, color)
	return node


## 兜底选中圈：一段贴地的环形三角带
func _fallback_ring(parent: Node3D, radius: float, color: Color) -> Node3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var segs: int = 32
	for i in range(segs + 1):
		var ang: float = TAU * float(i) / float(segs)
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		im.surface_set_color(Color(color.r, color.g, color.b, 0.95))
		im.surface_add_vertex(dir * radius)
		im.surface_set_color(Color(color.r, color.g, color.b, 0.55))
		im.surface_add_vertex(dir * (radius * 0.74))
	im.surface_end()

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	mat.albedo_color = Color.WHITE

	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = mat
	mi.position = Vector3(0.0, 0.06, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 建筑很高，圈子挂在脚下就够；直接加在单位上，跟随移动
	if parent == null:
		return null
	return mi


# ===========================================================================
# 工具
# ===========================================================================


## **可被选中的一切**：自己的、敌人的、友军的、中立的（资源点）。
## 用户要求"不光自己单位能选中，敌人/友军/中立全都要能选中"。
## 注意：能"选中/查看"不等于能"指挥"——下令那一侧会按阵营过滤（见 指令系统._selected_units）。
func _selectable_units() -> Array:
	var out: Array = []
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var n := u as Node3D
		if n == null or not (n is RtsUnit):
			continue
		if not (n as RtsUnit).is_alive():
			continue
		# ★ 钻在工地里的农民不参与世界点选（玩家口径 2026-11-07）：
		#   模型是隐藏的，用鼠标点它等于在点空气；只能点建筑面板上的农民图标选中。
		if (n as RtsUnit).is_inside_build():
			continue
		out.append(n)
	for h in Game.all_harvestables():
		if h == null or not is_instance_valid(h):
			continue
		if bool(h.call("is_depleted")):
			continue
		out.append(h)
	return out

## 玩家自己的单位/建筑（units_only=true 时排除建筑）
func _own_units(units_only: bool) -> Array:
	var out: Array = []
	var pl := Game.player_faction
	if pl == null:
		return out
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var n := u as Node3D
		if n == null:
			continue
		if n.get("faction") != pl:
			continue
		if not (n is RtsUnit):
			continue  # 可采集物不属于任何阵营，也不该被选
		if not (n as RtsUnit).is_alive():
			continue
		if units_only and n is RtsBuilding:
			continue
		out.append(n)
	return out


## 这个节点能不能被**框选 / 双击**收进来：活着的、玩家自己的、非建筑、非可采集物的单位。
## 抽成 static 是为了让无头自检（--headless --script）不建场景也能直接验这条规则。
static func is_box_unit(n: Node, player: RtsFaction) -> bool:
	if player == null or n == null or not is_instance_valid(n):
		return false
	var u := n as RtsUnit
	if u == null or u.def == null:
		return false
	if u is RtsBuilding:
		return false
	if u.def.kind != RtsConst.Kind.UNIT:
		return false
	if not u.is_alive():
		return false
	# 工地里的农民不能框选：他在房子里，框到他会让玩家以为「选中了一队农民」却在原地不动
	if u.is_inside_build():
		return false
	return u.faction == player


## 界面主色（提示文字用；配置没起来时有兜底）
func _accent_color() -> Color:
	return Cfg.game.hud_accent if Cfg.game != null else Color(0.85, 0.71, 0.36)


## 单位定义
func _def_of(n: Node) -> UnitDef:
	if n == null:
		return null
	return n.get("def") as UnitDef


func _def_id(n: Node) -> StringName:
	var d := _def_of(n)
	return d.id if d != null else &""


func _def_height(n: Node) -> float:
	var d := _def_of(n)
	return maxf(d.height, 0.4) if d != null else 1.6


## 鼠标拾取半径（选择半径，比身体略大；手感更宽容）
func _select_radius(n: Node) -> float:
	# 建筑按"足迹"给半径；可采集物收紧（矿/树体量大，别抢单位的点击）
	if n is RtsBuilding:
		var bd: UnitDef = n.get("def") as UnitDef
		if bd != null and bd.footprint != Vector2i.ZERO:
			return clampf(float(maxi(bd.footprint.x, bd.footprint.y)) * 0.5, 1.0, 3.2)
	if n is RtsHarvestable:
		return 1.6
	var d := _def_of(n)
	if d != null and d.selection_radius > 0.0:
		return d.selection_radius
	return 0.8


## 锚点（血条/选中圈/框选判定都指向这里：脚底往上 40% 高度处，屏幕上更稳）
func _anchor_point(n: Node3D) -> Vector3:
	return n.global_position + Vector3.UP * (_def_height(n) * 0.4)


## 当前视口相机
func _camera() -> Camera3D:
	var vp := get_viewport()
	if vp == null:
		return null
	return vp.get_camera_3d()


## 鼠标是不是压在界面控件上（按事件坐标判，模拟输入也准；判不了再退回真实鼠标）
func _ui_blocks_world(p: Vector2 = Vector2(-1.0, -1.0)) -> bool:
	if p.x >= 0.0 and p.y >= 0.0:
		var hud := _hud_ref()
		if hud != null and hud.has_method("covers_point"):
			return bool(hud.call("covers_point", p))
	var vp := get_viewport()
	if vp == null or not vp.has_method("gui_get_hovered_control"):
		return false
	return vp.call("gui_get_hovered_control") != null


## 界面节点（主场景的 hud 字段；还没建好时返回 null）
func _hud_ref() -> Node:
	if _hud != null and is_instance_valid(_hud):
		return _hud
	var parent := get_parent()
	if parent == null:
		return null
	_hud = parent.get("hud") as Node
	return _hud


## 指令系统是否在等落点（等的时候左键归它）
func _command_pending() -> bool:
	if _command_system == null or not is_instance_valid(_command_system):
		var parent := get_parent()
		if parent == null:
			return false
		_command_system = parent.get("command_system") as Node
	if _command_system == null or not is_instance_valid(_command_system):
		return false
	if _command_system.has_method("has_pending"):
		return bool(_command_system.call("has_pending"))
	return false


## 单位死亡：从选择集合里摘掉
func _on_unit_died(unit: Node3D) -> void:
	if unit == null:
		return
	if selected.has(unit):
		selected.erase(unit)
		_commit()


## 定时清理失效引用（比信号更兜底）
func _prune_dead() -> void:
	var dirty: bool = false
	for u in selected.duplicate():
		if u == null or not is_instance_valid(u):
			selected.erase(u)
			dirty = true
			continue
		if u.has_method("is_alive") and not u.is_alive():
			selected.erase(u)
			dirty = true
	if dirty:
		_commit()