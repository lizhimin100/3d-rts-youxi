extends Node
## 职责：小队战场的**队级输入**——玩家能碰到的最小单位是 Squad，永远不是单个成员。
## 属于：Screens/input
##
## 操作：
##   左键拖拽 = 框选整队（只选我方）｜ 左键点 = 点选整队（点成员也算整队）
##   右键点地 = 移动 ｜ 右键点敌人 = 集火
##   H = 驻守 ｜ S = 停止 ｜ A = 攻击移动（再点左键落点）｜ 空格 = 全选 ｜ Esc = 取消选择
##   滚轮 = 缩放 ｜ 方向键 = 平移镜头

const DRAG_MIN := 6.0

var _root: Node = null
var _drag_start := Vector2.ZERO
var _dragging := false
var _attack_move := false


func _ready() -> void:
	_root = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS


func _unhandled_input(event: InputEvent) -> void:
	if _root == null:
		return
	if bool(_root.call("is_ui_blocking")):
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					if _attack_move:
						var w: Vector3 = _root.call("ground_at_screen", mb.position)
						_root.call("order_selected", "attack_move", w, -1)
						_attack_move = false
						_root.call("set_attack_move", false)
						return
					_drag_start = mb.position
					_dragging = true
				elif _dragging:
					_dragging = false
					var delta := mb.position - _drag_start
					if delta.length() < DRAG_MIN:
						_root.call("pick_at_screen", mb.position)
					else:
						_root.call("box_select_screen", Rect2(_drag_start, delta).abs())
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					var w: Vector3 = _root.call("ground_at_screen", mb.position)
					_root.call("context_order_screen", mb.position, w)
					_attack_move = false
					_root.call("set_attack_move", false)
			MOUSE_BUTTON_WHEEL_UP:
				_root.call("zoom_camera", 0.88)
			MOUSE_BUTTON_WHEEL_DOWN:
				_root.call("zoom_camera", 1.14)
		return

	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		match key.keycode:
			KEY_H:
				_root.call("order_selected", "hold", Vector3.ZERO, -1)
			KEY_S:
				_root.call("order_selected", "stop", Vector3.ZERO, -1)
			KEY_A:
				_attack_move = not _attack_move
				_root.call("set_attack_move", _attack_move)
			KEY_SPACE:
				_root.call("select_all_squads")
			KEY_ESCAPE:
				_root.call("clear_selection")
				_attack_move = false
				_root.call("set_attack_move", false)
