class_name RtsSkillRt
extends RefCounted
## **技能运行时（技能系统入口）** —— 把配方卡拼成成品技能的那台机器
##
## ★ 整套技能系统的模型（玩家 2026-11-08 定稿，**改任何技能相关代码前先读**）：
##
## ```
##   第 1 层  技能原子（代码/配置/原子/*.gd）   只描述效果，不绑触发
##   第 2 层  单位姿势（动画 clip 名）          只描述动作
##   第 3 层  技能特效（代码/系统/技能特效.gd） 只描述光效
##   配方卡   SkillCard（代码/配置/技能卡.gd）  用哪几个原子/哪个动作/哪个特效/什么触发
##            ↓ 技能表（启动时全量扫 .tres → Dictionary）
##            ↓ 本文件（运行时把卡拼起来：修正倍率 / 连发 / 装填 / 动作 / 特效 / 格挡）
## ```
##
## 三条铁律：
##   ① **原子不绑触发**：本文件只认 stat 名与 kind，不认识任何具体技能 id；
##   ② **表现可缺**：clip 名不存在 → 静默跳过；vfx id 未注册 → 占位微光；
##   ③ 加一个技能 = **加一张 .tres**（编辑器里点"技能卡"），本文件一行不改；
##      只有"主动伤害类"（火球）需要 技能.gd 里一个 case —— 那落的是真实伤害，
##      纯数值表达不了。
##
## **技能运行时**：一个单位身上"技能正在发生什么"。
##
## 2026-11-07 建立，组件化三件套的中间层：
##
## ```
##   技能卡（数据）──→ 运行时（本文件）──→ 效果：修正倍率 / 连发 / 装填
##                                    ├─→ 动作：anim_on / anim_hold / anim_off
##                                    └─→ 特效：vfx_on / vfx_off（技能特效.gd）
## ```
##
## 设计原则（玩家口径"不要和单位绑死"）：
##   · 本文件**不认识任何具体技能 id**，只认 `mods` 里的 stat 名；
##   · 单位只问 `mod("move_speed")` / `damage_taken_mult(type)` / `burst_spec()`；
##   · 加一个开关技能 = 加一张 .tres，本文件一行不改。
##
## 支持的 stat（和 `技能表.stat_list()` 同一份）：
##   damage_taken        受到伤害倍率（`when` 可限定伤害类型，如 "穿刺"）
##   damage_dealt        造成伤害倍率
##   move_speed          移速倍率
##   attack_cooldown     攻击间隔倍率（2.0 = 攻速 -50%）
##   attack_range        射程倍率
##   armor               护甲（乘 0 无效；用 `add` 字段做加法）
##
## 修正的合成规则：**同名 stat 连乘**。两个 -15% 叠起来是 ×0.7225，不是 ×0.70。
## 这是刻意的：连乘不会出现"减到负数"，也不会因为顺序不同而结果不同。

const TABLE := preload("res://代码/配置/技能表.gd")
const LEX := preload("res://代码/配置/定位词表.gd")
const FX := preload("res://代码/系统/技能特效.gd")

## 技能卡按"开关"方式生效的集合：id → true
var _active: Dictionary = {}
## 汇总后的修正：`"stat|when"` → 倍率
var _mods: Dictionary = {}
## 每个技能的剩余冷却（只对主动/开关有意义）：id → 秒
var _cd: Dictionary = {}
## 挂载的单位
var _unit: Node3D = null
## 连发的剩余发数与计时（由单位驱动）
var burst_left: int = 0
var burst_t: float = 0.0
## 装填剩余时间（秒）；> 0 时不许开下一轮攻击
var reload_t: float = 0.0
## 当前连发规格缓存（没有连发为空）
var _burst: Dictionary = {}

## 动作覆盖：开启中的持续动作（为空 = 不覆盖 idle）
var _hold_anim: StringName = &""


func _init(unit: Node3D) -> void:
	_unit = unit


# ===========================================================================
# 查询
# ===========================================================================

## 单位是否有某个技能（读 UnitDef.abilities / skills）
static func has_skill(unit: Node3D, id: StringName) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var d: UnitDef = unit.get("def") as UnitDef
	if d == null:
		return false
	return d.abilities.has(id)


## 这个单位身上**不是采集类**的技能（命令卡/快捷键用）
static func active_skills(unit: Node3D) -> Array[StringName]:
	var out: Array[StringName] = []
	if unit == null or not is_instance_valid(unit):
		return out
	var d: UnitDef = unit.get("def") as UnitDef
	if d == null:
		return out
	for a in d.abilities:
		if not TABLE.has(a) or TABLE.is_gather(a):
			continue
		out.append(a)
	return out


func is_on(id: StringName) -> bool:
	return _active.has(id)


func active_ids() -> Array:
	return _active.keys()


## 某条修正的倍率（没有 = 1.0）。`when` 用于"只在某种伤害类型下生效"。
func mod(stat: StringName, when: StringName = &"") -> float:
	if _mods.is_empty():
		return 1.0
	return float(_mods.get("%s|%s" % [stat, when], 1.0))


## 受到某种伤害类型的总倍率（全局 × 该类型专属）
func damage_taken_mult(type: int) -> float:
	if _mods.is_empty():
		return 1.0
	var m: float = mod(&"damage_taken")
	var tn: StringName = _type_name(type)
	if tn != &"":
		m *= mod(&"damage_taken", tn)
	return m


## 造成伤害的倍率
func damage_dealt_mult() -> float:
	return mod(&"damage_dealt")


## 移速倍率
func move_speed_mult() -> float:
	return mod(&"move_speed")


## 攻击间隔倍率（2.0 = 攻速减半）
func attack_cooldown_mult() -> float:
	return mod(&"attack_cooldown")


## 开启中的持续动作（`shield_hold`）；没有返回空
func hold_anim() -> StringName:
	return _hold_anim


## 连发规格：{shots, interval, reload}；没有连发返回空字典
func burst_spec() -> Dictionary:
	if _burst.is_empty():
		for id in _active_ids_all():
			var b: Dictionary = TABLE.burst_of(id)
			if not b.is_empty() and int(b.get("shots", 0)) > 1:
				_burst = b
				break
	return _burst


## **格挡倍率**：这一击被挡掉多少（1.0 = 没挡）。
##
## 只有 kind = 受击 的卡参与（触发方式在卡上，原子只管 chance/mul）。
## 在 RtsCombat 结算完护甲/克制之后、真正扣血之前判一次；每一下独立掷骰。
func block_mult() -> float:
	if _unit == null or not is_instance_valid(_unit):
		return 1.0
	for id in _active_ids_all():
		if not TABLE.is_onhit(StringName(id)):
			continue
		var b: Dictionary = TABLE.block_of(StringName(id))
		if b.is_empty():
			continue
		if randf() <= float(b.get("chance", 0.0)):
			return float(b.get("mul", 1.0))
	return 1.0


## 这个单位是否有被动连发（不看开关状态：被动类一律生效）
func has_burst() -> bool:
	return not burst_spec().is_empty()


## 现在能不能开下一轮攻击（装填完了、上一轮连发打完了）
func can_fire() -> bool:
	return reload_t <= 0.0 and burst_left <= 0


# ===========================================================================
# 开关（主动技能里的"开关"型）
# ===========================================================================

## 切换一个开关技能，返回切换后的状态（true = 现在是开着的）
func toggle(id: StringName) -> bool:
	if not TABLE.is_toggle(id):
		return false
	var on: bool = not _active.has(id)
	if on:
		_active[id] = true
	else:
		_active.erase(id)
	_rebuild()
	_pull_burst()
	_play_anim(id, on)
	_play_vfx(id, on)
	_refresh_hold()
	return on


## 强制关闭（死亡/装填重置时用）
func clear_all() -> void:
	for id in _active.keys():
		_play_anim(StringName(id), false)
		_play_vfx(StringName(id), false)
	_active.clear()
	_rebuild()
	_refresh_hold()


# ===========================================================================
# 每帧
# ===========================================================================

## 由单位每帧驱动。只做三件事：冷却、连发计时、装填计时。
func tick(dt: float) -> void:
	if not _cd.is_empty():
		for id in _cd.keys():
			var v: float = float(_cd[id]) - dt
			if v <= 0.0:
				_cd.erase(id)
			else:
				_cd[id] = v
	reload_t = maxf(reload_t - dt, 0.0)
	if burst_left > 0:
		burst_t -= dt


## 这个技能冷却好了吗
func ready(id: StringName) -> bool:
	return not _cd.has(id)


## 起冷却
func start_cooldown(id: StringName, sec: float) -> void:
	if sec > 0.0:
		_cd[id] = sec


## 冷却剩余（UI 用）
func cooldown_left(id: StringName) -> float:
	return float(_cd.get(id, 0.0))


# ===========================================================================
# 连发（弩兵三连发）
# ===========================================================================

## 开始一轮连发。返回 true = 这一下由连发接管（本次不再单独发一发）。
func begin_burst() -> bool:
	var b: Dictionary = burst_spec()
	if b.is_empty():
		return false
	if not can_fire():
		return false
	burst_left = maxi(int(b.get("shots", 1)), 1)
	burst_t = 0.0
	return true


## 连发节拍：到点了就返回 true（调用方发一发），并发数减一
func tick_burst() -> bool:
	if burst_left <= 0:
		return false
	if burst_t > 0.0:
		return false
	burst_left -= 1
	var b: Dictionary = burst_spec()
	burst_t = maxf(float(b.get("interval", 0.12)), 0.02)
	if burst_left <= 0:
		reload_t = maxf(float(b.get("reload", 0.0)), 0.0)
	return true


# ===========================================================================
# 内部
# ===========================================================================

## 单位身上**全部**技能 id（含被动/采集），用于找连发组件
func _active_ids_all() -> Array:
	var out: Array = []
	if _unit == null or not is_instance_valid(_unit):
		return out
	var d: UnitDef = _unit.get("def") as UnitDef
	if d == null:
		return out
	for a in d.abilities:
		if TABLE.has(a):
			out.append(a)
	return out


## 把当前开启的技能修正汇总成一张表（只在开关变化时重建，查询 O(1)）。
##
## ★ 2026-11-08：**被动 / 受击**类卡的 mods 永远生效（不看 _active）——
##   格挡是"受击时判定"，不是"开着才有效"；被动铁甲光环同理。
func _rebuild() -> void:
	_mods.clear()
	var ids: Array = _active.keys()
	for id in _active_ids_all():
		if TABLE.is_passive(StringName(id)) or TABLE.is_onhit(StringName(id)):
			if not ids.has(id):
				ids.append(id)
	for id in ids:
		var eff: Dictionary = TABLE.effect_of(StringName(id))
		for md in eff.get("mods", []):
			if not (md is Dictionary):
				continue
			var stat: StringName = StringName(md.get("stat", &""))
			if stat == &"":
				continue
			var when: StringName = StringName(md.get("when", &""))
			var key: String = "%s|%s" % [stat, when]
			var cur: float = float(_mods.get(key, 1.0))
			cur *= float(md.get("mul", 1.0))
			if md.has("add"):
				cur += float(md["add"])
			_mods[key] = cur


## 被动连发在开局就能用，这里顺手把 _burst 填上（避免第一次攻击时再查表）
func _pull_burst() -> void:
	_burst.clear()
	for id in _active_ids_all():
		var b: Dictionary = TABLE.burst_of(id)
		if not b.is_empty() and int(b.get("shots", 0)) > 1:
			_burst = b
			return


## 持续动作：所有开启技能里第一个填了 anim.hold 的
func _refresh_hold() -> void:
	_hold_anim = &""
	for id in _active.keys():
		var anim: Dictionary = TABLE.anim_of(StringName(id))
		var h: StringName = StringName(anim.get("hold", &""))
		if h != &"":
			_hold_anim = h
			return


## 播一次技能动作（模型没有这个 clip 时 SkeletonAnim 会静默跳过）
func _play_anim(id: StringName, on: bool) -> void:
	if _unit == null or not is_instance_valid(_unit):
		return
	var v: Variant = _unit.get("visual")
	if v == null or not is_instance_valid(v):
		return
	var anim: Dictionary = TABLE.anim_of(id)
	var clip: StringName = StringName(anim.get("on" if on else "off", &""))
	if clip == &"" or not v.has_method("play"):
		return
	v.call("play", String(clip), 1.0, true)


## 播一次技能特效（未注册的特效 id 会退到占位微光，并只警告一次）
func _play_vfx(id: StringName, on: bool) -> void:
	if _unit == null or not is_instance_valid(_unit):
		return
	var fx: Dictionary = TABLE.vfx_of(id)
	var clip: StringName = StringName(fx.get("on" if on else "off", &""))
	if clip == &"":
		return
	FX.play(_unit, clip)


## 伤害类型 → 词表中文名（"穿刺" / "普通" …）
func _type_name(type: int) -> StringName:
	var arr: Array = LEX.ATTACK_TYPES
	if type < 0 or type >= arr.size():
		return &""
	return arr[type]
