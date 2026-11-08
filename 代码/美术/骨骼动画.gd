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

## 一次性动作：播完自动回 idle（death 例外，停在最后一帧）。
##
## ★ 2026-11-07 玩家口径「不要整什么白名单黑名单」：
##   以前是**白名单**（只允许播推导出来的几个）＋**循环名单**（只有列出来的才循环），
##   两张表都要人工维护，新加一个动作忘了登记就变成"播一下就停"或者"播不出来"。
##   现在反过来：**除了下面这几个一次性动作，其余全部按循环播**。
##   于是 `gather` / `build` / `carry_*` / 技能持续动作（`shield_hold`）自动就是循环，
##   新动作进资产即生效，代码零改动。
const ONE_SHOT: Array[StringName] = [&"attack", &"shoot", &"cast", &"hurt", &"death", &"reload"]

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
## （名单本身见文件顶部的 ONE_SHOT）

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
## 待机动作池：资产里所有以 `idle` 开头的动作（idle / idle_b / idle_scratch / idle_stretch …）。
## 玩家 2026-11-07 口径：**待机可以随机多个不同动画，移动/攻击/举盾只用一个**。
## 所以只有 idle 走随机，其他状态一律按名字取那唯一一个。
var _idle_pool: Array[StringName] = []
## 待机池覆盖（只有"手持盾牌"这类单位用）：
## 默认池是 资产里所有 `idle*`（含 idle_scratch / idle_stretch）；
## 挂着盾的单位随机到"挠头"时，手抬到头顶、盾还挂在手边 —— 玩家实测觉得怪，
## 所以那类单位把池子收成 ["idle"]（见 单位视觉._make_pose_layer）。
var _idle_override: Array[StringName] = []
## 上一次随机到的待机（避免连着两次同一个）
var _last_idle: StringName = &""
## 表现层随机流（不要用全局 randf —— 会让"重放同一场"的战斗结果跟着变）
const Fx := preload("res://代码/美术/表现随机.gd")


## 绑定到模型根节点（ArtKit.attach_anim 调用）
func bind(root: Node3D) -> void:
	_ap = _find_player(root)
	if _ap == null:
		return
	_ready_ok = true
	_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
	if not _ap.animation_finished.is_connected(_on_finished):
		_ap.animation_finished.connect(_on_finished)
	# ★ 除了 ONE_SHOT，全部设成循环。
	#   为什么必须显式设：glTF 导入的动作默认是**一次性**（loop_mode = NONE），
	#   不设的话"待机 4.5 秒后定格""走路走一步就停""举着盾 0.6 秒自己放下"。
	for n in _ap.get_animation_list():
		if ONE_SHOT.has(StringName(n)):
			continue
		var a := _ap.get_animation(n)
		if a != null:
			a.loop_mode = Animation.LOOP_LINEAR
	# 待机动作池（随机用）。只有 1 个 = 不随机，行为和以前完全一样。
	_idle_pool.clear()
	for n in _ap.get_animation_list():
		if String(n).begins_with("idle"):
			_idle_pool.append(StringName(n))
	if _idle_pool.is_empty():
		_idle_pool.append(&"idle")
	# ★ 2026-11-08 玩家口径（第三次）：「步兵的待机悠闲动作不要搞挠头，换成左右看即可，
	#   不然盾牌跟着手臂一起翻滚很怪异。」
	#   盾已经挂在 `hand_L` 下（工具/修盾牌.py），所以**任何把手臂举到头顶的动作**
	#   （idle_scratch 挠头 / idle_stretch 伸展）都会让盾翻到脸上。
	#   判据放在这里（而不是只写在 单位视觉 里）是因为**每个**拿 AnimationPlayer 的地方
	#   都要这条规则：3D 战场、底栏头像台、编辑器预览 —— 头像台原来没设池子，
	#   于是它照样随机到 idle_stretch，玩家看到的就是"头像在挠头"。
	if _has_bone(root, &"shield"):
		var keep: Array[StringName] = []
		for n2 in [&"idle", &"idle_look"]:
			if _ap.has_animation(String(n2)):
				keep.append(n2)
		if not keep.is_empty():
			_idle_override = keep
	# 排查用：`ANIM_POOL_DEBUG=1` 会打出每个模型实际用的待机池。
	# （"头像在挠头""步兵举着盾伸展"这类问题，第一眼看的就是这张表）
	if OS.has_environment("ANIM_POOL_DEBUG"):
		print("[骨骼动画] %s idle_pool=%s override=%s shield=%s" % [
			String(root.name), str(_idle_pool), str(_idle_override),
			str(_has_bone(root, &"shield"))])
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


## 骨架里有没有这根骨（用来判断"这个模型带不带盾"）。
## 只看 Skeleton3D，不看节点名 —— 盾是骨，不是 MeshInstance。
func _has_bone(root: Node, bone: StringName) -> bool:
	if root == null:
		return false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var sk := n as Skeleton3D
		if sk != null and sk.find_bone(String(bone)) >= 0:
			return true
		for c in n.get_children():
			stack.append(c)
	return false


## 有没有这个动作（含降级链）
func has_state(state: String) -> bool:
	return _resolve(StringName(state)) != &""


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
	# 待机：从池子里随机挑一个（不连着重复）。别的状态一律用唯一那个动作。
	if want == &"idle" and _idle_pool.size() > 1:
		want = _pick_idle()
	var is_loop: bool = not ONE_SHOT.has(want)
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
	# ★ 2026-11-08 玩家实测「步兵攻击砍两下」的根因：
	#   攻击是单次动作（is_loop=false），旧判据只挡"循环动作"，于是状态机每帧
	#   重新 play 一次 attack —— 播完一遍后又被从头拉起，看起来就是连砍两刀。
	#   现在：同一个单次动作还在播就**不许重播**（要重播必须 force）。
	if want == _current and not is_loop and not force and _ap.is_playing():
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


## 这个 clip 存在吗（没有白名单，只有"资产里有没有"这一条）
func _playable(n: StringName) -> bool:
	if n == &"":
		return false
	return _ap.has_animation(String(n))


## 待机随机：从 `idle*` 池里挑一个，**不连着重复**。
## 只有 1 个待机时根本不会走到这里（见 set_state 的判据）。
func _pick_idle() -> StringName:
	var pool: Array[StringName] = _idle_override if not _idle_override.is_empty() else _idle_pool
	if pool.is_empty():
		return &"idle"
	if pool.size() == 1:
		return pool[0]
	for _i in 4:
		var pick: StringName = pool[Fx.rand_index(pool.size())]
		if pick != _last_idle:
			_last_idle = pick
			return pick
	_last_idle = pool[Fx.rand_index(pool.size())]
	return _last_idle


## 收窄待机池（手持盾牌的单位用：只要基础 idle，别随机到挠头/伸展）
func set_idle_pool(names: Array) -> void:
	_idle_override.clear()
	for n in names:
		_idle_override.append(StringName(n))


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
