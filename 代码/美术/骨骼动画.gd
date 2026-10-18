class_name SkeletonAnim
extends Node
## **骨骼动画播放器**：给带 AnimationPlayer 的 v3 模型提供和程序动画一致的 set_state 接口。
##
## 为什么要有它：单位/建筑侧只认 set_state("attack") 这一种调用（UnitVisual 就是这么写的），
## 而模型从"空物体关节 + 程序摆姿态"换成了"真骨骼 + 烘焙 Action"，中间必须有一层翻译：
##   * 名字映射：UnitVisual 传 "move"，glTF 里的动作叫 "walk"；
##   * 缺动作降级：步兵没有 gather/cast，就退到 attack/idle，绝不报错、绝不僵住；
##   * 循环 / 单次：idle/walk/wave 循环，attack/hurt/death 单次，death 停在最后一帧；
##   * 交叉淡入：切换 0.12~0.2s，硬切会"抽帧"。
##
## 资产契约（工具/建模/v3 产出的 GLB）：
##   Armature/Skeleton3D + AnimationPlayer，动作名全小写：idle walk attack shoot cast gather build hurt death

## 名字映射：引擎侧状态名 → GLB 里的动作名
const NAME_MAP := {
	&"move": &"walk",
	&"run": &"walk",
}

## 循环播放的动作
const LOOPING: Array[StringName] = [&"idle", &"walk", &"wave"]

## 缺动作时的降级链（第一个存在的就用）
const FALLBACK := {
	&"walk": [&"walk", &"idle"],
	&"shoot": [&"shoot", &"attack", &"cast", &"idle"],
	&"attack": [&"attack", &"shoot", &"cast", &"walk"],
	&"cast": [&"cast", &"shoot", &"attack", &"idle"],
	&"gather": [&"gather", &"attack", &"build", &"walk"],
	&"build": [&"build", &"gather", &"attack", &"walk"],
	&"hurt": [&"hurt", &"idle"],
	&"death": [&"death", &"hurt", &"idle"],
	&"idle": [&"idle", &"walk"],
}

## 单次动作（播完自动回 idle）；death 例外：停在最后一帧
const ONE_SHOT: Array[StringName] = [&"attack", &"shoot", &"cast", &"gather", &"build", &"hurt", &"death"]

const BLEND := 0.16

var _ap: AnimationPlayer = null
var _current: StringName = &""
var _one_shot: StringName = &""
var _speed: float = 1.0
var _ready_ok: bool = false


## 绑定到模型根节点（ArtKit.attach_anim 调用）
func bind(root: Node3D) -> void:
	_ap = _find_player(root)
	if _ap == null:
		return
	_ready_ok = true
	_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	if not _ap.animation_finished.is_connected(_on_finished):
		_ap.animation_finished.connect(_on_finished)
	# 循环动作强制设循环（glTF 导入默认是一次性，旗子会"飘一下就停"）
	for n in LOOPING:
		if _ap.has_animation(String(n)):
			var a := _ap.get_animation(String(n))
			if a != null:
				a.loop_mode = Animation.LOOP_LINEAR
	set_state("idle")


func _find_player(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is AnimationPlayer:
			return n as AnimationPlayer
		for c in n.get_children():
			stack.append(c)
	return null


## 有没有这个动作（含降级链）
func has_state(state: String) -> bool:
	return _resolve(StringName(state)) != &""


func current_state() -> StringName:
	return _current


## 主接口：与旧 程序动画.gd 的 set_state 完全一致
func set_state(state: String, speed_ratio: float = 1.0) -> void:
	if not _ready_ok:
		return
	var want := _resolve(StringName(state))
	if want == &"":
		return
	var is_loop := LOOPING.has(want)
	# 单次动作没播完就别被循环动作打断（否则攻击永远只出头两帧）
	if _one_shot != &"" and _ap.is_playing() and _ap.current_animation == String(_one_shot) and is_loop:
		return
	if want == _current and is_loop:
		_speed = clampf(speed_ratio, 0.35, 1.8)
		_ap.speed_scale = _speed
		return
	_current = want
	_speed = clampf(speed_ratio, 0.35, 1.8)
	_ap.speed_scale = _speed if is_loop else 1.0
	_one_shot = want if ONE_SHOT.has(want) else &""
	_ap.play(String(want), BLEND, 1.0)


func _resolve(state: StringName) -> StringName:
	if _ap == null:
		return &""
	var mapped: StringName = NAME_MAP.get(state, state)
	if _ap.has_animation(String(mapped)):
		return mapped
	for alt in FALLBACK.get(mapped, []):
		if _ap.has_animation(String(alt)):
			return StringName(alt)
	return &""


func _on_finished(anim: StringName) -> void:
	if anim != _current:
		return
	if anim == &"death":
		_one_shot = &""
		return
	if ONE_SHOT.has(anim):
		_one_shot = &""
		set_state("idle")


## 调试/验收用：某个动作的时长（秒）
func clip_length(state: String) -> float:
	if _ap == null:
		return 0.0
	var n := _resolve(StringName(state))
	if n == &"":
		return 0.0
	var a := _ap.get_animation(String(n))
	return a.length if a != null else 0.0
