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
## ★ 2026-11-06：`gather` / `build` 改成循环（玩家口径「采集木头变为不停做出采集动作」）。
##   它们以前在 ONE_SHOT 里，播一遍就自动回 idle —— 玩家看到的是"砍一刀就站着发呆"，
##   而采集/建造其实还在推进度。现在这两个状态只要不被切走就一直循环：
##   砍树是连续挥斧、造房子是连续抡锤，和真实进度对得上。
const LOOPING: Array[StringName] = [&"idle", &"walk", &"wave", &"carry_gold", &"carry_wood",
		&"gather", &"build"]

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
	# 搬运动作：方块人_农民独有；别的兵没有就退回走路（背东西的样子不变形）
	&"carry_gold": [&"carry_gold", &"walk"],
	&"carry_wood": [&"carry_wood", &"walk"],
}

## 单次动作（播完自动回 idle）；death 例外：停在最后一帧
## gather / build 不在里面 —— 它们是"持续动作"，见 LOOPING 的注释。
const ONE_SHOT: Array[StringName] = [&"attack", &"shoot", &"cast", &"hurt", &"death"]

## 打完一发接的"装填"动作（弩兵/火枪这类）。纯视觉：不参与伤害时序，
## 只是让玩家看见「射一箭要上一次弦」，而不是凭空连发。
## 资产契约：`shoot` + `reload` 两个动作同时存在才生效，别的兵种完全不受影响。
const RELOAD_AFTER := {&"shoot": &"reload"}

const BLEND := 0.16
## 循环动作（walk）在高速播放时，0.16s 的淡入已经接近半个周期，会糊。
## 实测 2.3x 步频下用 0.09s 既不断帧、也不吃掉落脚。
const BLEND_LOOP := 0.09

var _ap: AnimationPlayer = null
var _current: StringName = &""
var _one_shot: StringName = &""
## 正在补播"装填"动作（shoot 播完 → reload → idle）
var _reloading: bool = false
var _speed: float = 1.0
var _ready_ok: bool = false
## **动作白名单**（空 = 不限制）。见 set_allowed 的注释。
var _allowed: Dictionary = {}
## 已经被白名单裁掉的动作名（审计用）
var _dropped: Array[String] = []
## 全局只打印一次：同一套模型会实例化几百个，逐个 println 会把 3000 兵压测的日志刷爆
static var _dropped_reported: Dictionary = {}


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


## **动作白名单**：只允许播这些 clip 名（`walk` / `attack` / `shoot` …）。
##
## 为什么要有它（2026-11-07 玩家口径「用不到的、和当前表现形式不搭的动作不要播出来」）：
##   模型里常带着做实验时留下的动作（`idle_b` / `idle_scratch` / `idle_stretch` /
##   没技能的兵身上的 `cast`）。只要降级链能落到它，就会在某个状态里突然播出来，
##   看起来就是"这个兵怎么还有第二种攻击/第二种待机"。
##   白名单由 `单位视觉` 按 UnitDef 推导（有没有技能、是不是远程、是不是农民），
##   推导不出来的动作一律不播 —— 宁可不播，也不要播错。
func set_allowed(names: Array) -> void:
	_allowed.clear()
	for n in names:
		_allowed[StringName(n)] = true
	_dropped.clear()
	if _ap == null:
		return
	for a in _ap.get_animation_list():
		if _allowed.has(StringName(a)) or _allowed.has(StringName(NAME_MAP.get(StringName(a), a))):
			continue
		_dropped.append(a)
	if not _dropped.is_empty():
		var sig: String = ",".join(_dropped) + "|" + ",".join(PackedStringArray(_allowed.keys().map(func(k): return String(k))))
		if not _dropped_reported.has(sig):
			_dropped_reported[sig] = true
			print("[动画] 裁掉未使用动作：%s（允许：%s）" % [
				", ".join(_dropped), sig.get_slice("|", 1)])


## 被裁掉的动作（审计用）
func dropped_clips() -> Array[String]:
	return _dropped.duplicate()


func current_state() -> StringName:
	return _current


## 主接口：与旧 程序动画.gd 的 set_state 完全一致
## force=true：无视"单次动作没播完"和"同名去重"，强制从第 0 帧重播。
func set_state(state: String, speed_ratio: float = 1.0, force: bool = false) -> void:
	if not _ready_ok:
		return
	var want := _resolve(StringName(state))
	if want == &"":
		return
	var is_loop := LOOPING.has(want)
	# 单次动作没播完就别被循环动作打断（否则攻击永远只出头两帧）。
	# ★ 但也不能"整段播完才放行"：attack 0.9s 比很多单位的反应窗口还长，
	#   玩家点一下移动，兵要站满 0.9 秒才开始走 —— 手感上是"指令不跟手"。
	#   现在放行阈值 = 55%：出手（伤害结算）在前摇里早完成了，剩下的是收势。
	if not force and _one_shot != &"" and _ap.is_playing() \
			and _ap.current_animation == String(_one_shot) and is_loop:
		var cur_len: float = 0.0
		var cur_anim := _ap.get_animation(String(_one_shot))
		if cur_anim != null:
			cur_len = cur_anim.length
		if cur_len <= 0.001 or _ap.current_animation_position < cur_len * 0.55:
			return
	if want == _current and is_loop and not force:
		# 上限 3.0：walk 按真实地速播放（4.6m/s / 2.0m/s 步幅 ≈ 2.3x）
		_speed = clampf(speed_ratio, 0.2, 3.0)
		_ap.speed_scale = _speed
		return
	_current = want
	_speed = clampf(speed_ratio, 0.2, 3.0)
	_ap.speed_scale = _speed if is_loop else 1.0
	_one_shot = want if ONE_SHOT.has(want) else &""
	_ap.play(String(want), BLEND_LOOP if is_loop else BLEND, 1.0)
	if force:
		# play() 对"正在播同一个动作"会续播而不是重头播 → 显式回到 0
		_ap.seek(0.0, true)


func _resolve(state: StringName) -> StringName:
	if _ap == null:
		return &""
	var mapped: StringName = NAME_MAP.get(state, state)
	if _playable(mapped):
		return mapped
	for alt in FALLBACK.get(mapped, []):
		if _playable(alt):
			return StringName(alt)
	return &""


## 这个 clip 存在、且在白名单里（白名单为空 = 不限制）
func _playable(n: StringName) -> bool:
	if n == &"" or not _ap.has_animation(String(n)):
		return false
	if _allowed.is_empty():
		return true
	return _allowed.has(n)


func _on_finished(anim: StringName) -> void:
	if anim != _current:
		return
	if anim == &"death":
		_one_shot = &""
		return
	# 装填播完 → 回 idle
	if _reloading and anim == &"reload":
		_reloading = false
		_one_shot = &""
		set_state("idle")
		return
	if ONE_SHOT.has(anim):
		# 弩兵：射完接一段上弦（资产里有 reload 才播）
		var nxt: StringName = RELOAD_AFTER.get(anim, &"")
		if nxt != &"" and _playable(nxt):
			_reloading = true
			_current = nxt
			_one_shot = nxt
			_ap.play(String(nxt), BLEND, 1.0)
			_ap.seek(0.0, true)
			return
		_one_shot = &""
		set_state("idle")


## 当前动作的播放进度 0~1（没有动画 / 没在播返回 -1）。
## 采集用它抓"斧头落到最低点"那一下（见 单位._tick_chop_fx）。
func phase() -> float:
	if _ap == null or not _ap.is_playing():
		return -1.0
	var a := _ap.get_animation(_ap.current_animation)
	if a == null or a.length <= 0.001:
		return -1.0
	return clampf(_ap.current_animation_position / a.length, 0.0, 1.0)


## 调试/验收用：某个动作的时长（秒）
func clip_length(state: String) -> float:
	if _ap == null:
		return 0.0
	var n := _resolve(StringName(state))
	if n == &"":
		return 0.0
	var a := _ap.get_animation(String(n))
	return a.length if a != null else 0.0
