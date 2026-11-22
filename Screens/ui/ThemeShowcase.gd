extends Control
## 职责：主题陈列室的**交互演示**（只切可见性/禁用态，不建节点、不写样式）
## 属于：Screens/ui
## 为什么这么薄：界面全部由 ThemeShowcase.tscn 的静态节点 + main_theme.tres 决定，
## 脚本只负责让「集火 / 防守 / 切换 / 重置」真的产生**可断言**的状态变化。
## last_action 供 run-game --shot 的 expect_state 读取 —— 截图必须配真交互，不能只证明画出来。

var last_action: String = ""

@onready var _focus_tip: Control = %FocusTip
@onready var _defend_tip: Control = %DefendTip
@onready var _toggle_on: Control = %ToggleTipOn
@onready var _toggle_off: Control = %ToggleTipOff
@onready var _reset_tip: Control = %ResetTip
@onready var _demo_button: Button = %DemoButton


func _ready() -> void:
	_focus_tip.visible = false
	_defend_tip.visible = false
	_toggle_on.visible = false
	_toggle_off.visible = false
	_reset_tip.visible = false
	last_action = "idle"


func _on_focus_pressed() -> void:
	last_action = "focus_fire"
	_focus_tip.visible = true
	_reset_tip.visible = false


func _on_defend_pressed() -> void:
	last_action = "defend"
	_defend_tip.visible = true
	_reset_tip.visible = false


func _on_toggle_pressed() -> void:
	last_action = "toggle"
	_demo_button.disabled = not _demo_button.disabled
	_toggle_on.visible = not _demo_button.disabled
	_toggle_off.visible = _demo_button.disabled
	_reset_tip.visible = false


func _on_reset_pressed() -> void:
	last_action = "reset"
	_focus_tip.visible = false
	_defend_tip.visible = false
	_toggle_on.visible = false
	_toggle_off.visible = false
	_demo_button.disabled = true
	_reset_tip.visible = true
