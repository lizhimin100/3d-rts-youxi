extends Node
## 职责：小队战场的**队级输入**——玩家能碰到的最小单位是 Squad，永远不是单个成员。
## 属于：Screens/input
##
## **2026-11-21 微操收敛（玩家口径）**：战斗阶段只允许
##   「选中我方小队 → 指定攻击 / 集火某支敌方小队」。
## 手动移动 / 停火 / 驻守 / 攻击移动全部移除 —— 推进与接敌交给自动战斗与预设偏好。
## 所以这个文件里**没有** move / hold / stop / attack_move 的按键与分支；
## 想加回来先回去改 Model（`SquadBattle.IsPlayerMicroOrder` 里只有 attack 一个白名单）。
##
## 操作：
##   左键拖拽 = 框选整队（只选我方）｜ 左键点 = 点选整队（点成员也算整队）
##   右键点敌方小队 = 集火（点地板无效，只给一行提示）
##   空格 = 全选 ｜ Esc = 取消选择 ｜ 滚轮 = 缩放 ｜ 方向键 = 平移镜头
##   1 / 2 = 战斗倍速 1x / 2x（Model 层 SquadBattle.TimeScale，只改推进速率不改数值）

const DRAG_MIN := 6.0

var _root: Node = null
var _drag_start := Vector2.ZERO
var _dragging := false


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
					# 只认"点在敌方小队身上"；点地板不再下令（旧版会走 Move）。
					_root.call("context_order_screen", mb.position, w)
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
			KEY_SPACE:
				_root.call("select_all_squads")
			KEY_ESCAPE:
				_root.call("clear_selection")
			KEY_1:
				_root.call("set_time_scale", 1.0)
			KEY_2:
				_root.call("set_time_scale", 2.0)
