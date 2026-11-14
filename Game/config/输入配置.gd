@tool
class_name InputSetup
extends RefCounted
## **输入映射注册**：把所有操作键集中在这里，代码里用 Input.is_action_* 读。
## 不写进 project.godot 的原因：那里的 InputEvent 序列化文本极其难维护，
## 而这里一行一个键，改起来直观，也方便写进自动化测试。

## 所有动作名（外部脚本引用这些常量，避免打错字）
const CAM_LEFT := &"cam_left"
const CAM_RIGHT := &"cam_right"
const CAM_UP := &"cam_up"
const CAM_DOWN := &"cam_down"
const CAM_ROTATE_L := &"cam_rotate_l"
const CAM_ROTATE_R := &"cam_rotate_r"
const CAM_ZOOM_IN := &"cam_zoom_in"
const CAM_ZOOM_OUT := &"cam_zoom_out"
const CAM_HOME := &"cam_home"
const CMD_ATTACK_MOVE := &"cmd_attack_move"
const CMD_STOP := &"cmd_stop"
const CMD_HOLD := &"cmd_hold"
const UI_BUILD := &"ui_build"
## 界面显隐（录演示视频用；只藏 HUD，不暂停、不改任何玩法）
const UI_TOGGLE_HUD := &"ui_toggle_hud"
## 全选己方部队 / 取消选择（Ctrl+A / Esc）。
## 这两条替代了原来钉在屏幕右侧的「全选」「取消」按钮。
const SEL_ALL := &"sel_all"
const SEL_CLEAR := &"sel_clear"
const ABILITY_1 := &"ability_1"
const ABILITY_2 := &"ability_2"
const ABILITY_3 := &"ability_3"


## 注册全部输入动作（已存在则跳过，避免重复注册报错）
static func register_all() -> void:
	# --- 镜头平移：方向键 + WASD（WASD 只在没有选中单位时拦截，逻辑在镜头脚本）
	_add_keys(CAM_LEFT, [KEY_LEFT, KEY_A])
	_add_keys(CAM_RIGHT, [KEY_RIGHT, KEY_D])
	_add_keys(CAM_UP, [KEY_UP, KEY_W])
	_add_keys(CAM_DOWN, [KEY_DOWN, KEY_S])
	# --- 镜头旋转
	_add_keys(CAM_ROTATE_L, [KEY_Q])
	_add_keys(CAM_ROTATE_R, [KEY_E])
	# --- 缩放（滚轮也由镜头脚本直接读鼠标事件，这里给键盘兜底）
	_add_keys(CAM_ZOOM_IN, [KEY_EQUAL, KEY_KP_ADD])
	_add_keys(CAM_ZOOM_OUT, [KEY_MINUS, KEY_KP_SUBTRACT])
	# --- 回中（空格）
	_add_keys(CAM_HOME, [KEY_SPACE])
	# --- 指令
	_add_keys(CMD_ATTACK_MOVE, [KEY_F])
	_add_keys(CMD_STOP, [KEY_X])
	_add_keys(CMD_HOLD, [KEY_H])
	# --- 建造菜单
	_add_keys(UI_BUILD, [KEY_B])
	# --- 界面显隐（F9；F10 兜底，笔记本上 F9 偶尔被系统占用）
	_add_keys(UI_TOGGLE_HUD, [KEY_F9, KEY_F10])
	# --- 选择：Ctrl+A 全选、Esc 取消（Esc 在有等待落点的指令时由指令系统优先接管）
	_add_keys(SEL_ALL, [KEY_A], true)
	_add_keys(SEL_CLEAR, [KEY_ESCAPE])
	# --- 技能
	_add_keys(ABILITY_1, [KEY_1, KEY_KP_1])
	_add_keys(ABILITY_2, [KEY_2, KEY_KP_2])
	_add_keys(ABILITY_3, [KEY_3, KEY_KP_3])


## 注册一组按键到某个动作。
## ctrl=true 时给事件带上 Ctrl 修饰键 —— 不带修饰的 A 是镜头左移，直接复用会打架。
static func _add_keys(action: StringName, keys: Array, ctrl: bool = false) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = int(k)
		ev.ctrl_pressed = ctrl
		if InputMap.action_has_event(action, ev):
			continue
		InputMap.action_add_event(action, ev)
