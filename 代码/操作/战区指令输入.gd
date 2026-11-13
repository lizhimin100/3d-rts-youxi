extends Node
## **战区指令输入** —— F5/F6/F7/F8 四种战役级指令，左键点地面或拖拽画圈。
##
## 为什么不做成 HUD 面板：`文档/界面说明.md` 第一条就是「没被点名的界面地方一律不要动」。
## 底栏/顶栏/选中面板都有既定尺寸，塞四个按钮进去必然要动布局。
## 用功能键 + 鼠标手势，零布局改动，且**指令语义本身**（区域 vs 目标）用"点击/拖拽"
## 就表达完了：
##   · **单击** = 对一个目标下指令（半径 6m，覆盖目标本身）；
##   · **按住拖拽** = 对一个区域下指令（半径 = 拖拽距离，4–40m）。
##
## 反馈：进入待发模式时鼠标变十字；指令下达后控制台打一行（[战区] ...）。
## 顶部播报条留给据点倒计时，不去抢它的位置。

const WAR := preload("res://代码/ai/战区指令.gd")

## 功能键 → 指令种类
const KEYS: Dictionary = {
	KEY_F5: WAR.ATTACK,
	KEY_F6: WAR.DEFEND,
	KEY_F7: WAR.CAPTURE,
	KEY_F8: WAR.PRODUCE,
}
## 单击时的默认半径（覆盖一个目标）
const TAP_RADIUS: float = 6.0
## 拖拽的最小像素距离（小于它算单击）
const DRAG_MIN_PX: float = 8.0
## 区域半径上下限（米）
const RADIUS_MIN: float = 4.0
const RADIUS_MAX: float = 40.0

var _pending: int = 0
var _pressing: bool = false
var _press_pos: Vector2 = Vector2.ZERO


func _ready() -> void:
	print("[战区] 指令输入就绪：F5 进攻 / F6 防守 / F7 占据 / F8 生产；左键点地或拖拽画圈，ESC 取消")


func _input(event: InputEvent) -> void:
	if Game == null or Game.player_faction == null:
		return

	if event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.keycode
		if KEYS.has(k):
			_enter(int(KEYS[k]))
			get_viewport().set_input_as_handled()
			return
		if k == KEY_ESCAPE and _pending != 0:
			_cancel()
			get_viewport().set_input_as_handled()
			return

	if _pending == 0:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressing = true
			_press_pos = event.position
		elif _pressing:
			_pressing = false
			_commit(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _pressing:
		# 拖拽时保持十字，别让手一抖变回箭头
		Input.set_default_cursor_shape(Input.CURSOR_CROSS)


func _enter(kind: int) -> void:
	_pending = kind
	_pressing = false
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)
	print("[战区] 已选「%s」：单击地面 = 对一个目标；按住拖拽 = 对一片区域；ESC 取消"
		% String(WAR.NAMES[kind]))


func _cancel() -> void:
	_pending = 0
	_pressing = false
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	print("[战区] 已取消")


func _commit(screen_pos: Vector2) -> void:
	var center: Vector3 = _ground_point(screen_pos)
	if center == Vector3.INF:
		_cancel()
		return
	var radius: float = TAP_RADIUS
	if _press_pos.distance_to(screen_pos) > DRAG_MIN_PX:
		var a: Vector3 = _ground_point(_press_pos)
		if a != Vector3.INF:
			radius = clampf(Vector2(a.x - center.x, a.z - center.z).length(), RADIUS_MIN, RADIUS_MAX)
	# 「生产」的作用域是"新兵往哪集结"，半径没有意义，统一给个小的
	if _pending == WAR.PRODUCE:
		radius = TAP_RADIUS
	WAR.issue(_pending, center, radius, null, "玩家")
	_pending = 0
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)


## 屏幕点 → 地面（y=0 平面）。返回 Vector3.INF 表示射线与地面平行/在身后。
func _ground_point(screen: Vector2) -> Vector3:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return Vector3.INF
	var from: Vector3 = cam.project_ray_origin(screen)
	var dir: Vector3 = cam.project_ray_normal(screen)
	if absf(dir.y) < 1e-5:
		return Vector3.INF
	var t: float = -from.y / dir.y
	if t <= 0.0:
		return Vector3.INF
	return from + dir * t
