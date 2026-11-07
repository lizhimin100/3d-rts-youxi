extends RefCounted
## **技能表（唯一读取入口）**：id → 定义 Dictionary。
##
## 2026-11-07 组件化重写。数据和执行彻底分开：
##
## ```
##   代码/配置/卡/技能/<id>.tres   ← SkillCard 资源（编辑器可改、可新增、可挂到任意单位）
##              ↓ 本文件（启动时全量扫入，转 Dictionary）
##   代码/系统/技能.gd             ← 主动技能的施放/结算
##   代码/系统/技能运行时.gd       ← 开关/被动：修正倍率、连发、装填、动作与特效
## ```
##
## 为什么还留一层 Dictionary：`单位.gd` / `命令卡.gd` / 自检 都是按 Dictionary 读的，
## 转换只发生一次（启动），调用点零改动。
##
## 加一个技能 = **只加一个 .tres**：
##   · 开关类：填 `mods`（不用写代码）；
##   · 连发类：填 `burst_shots / interval / reload`；
##   · 主动伤害类：还需要在 `技能.gd::release()` 里加一个 case（这是"效果"，
##     它必须落到真实伤害/召唤/位移，纯数值表达不了）。
##
## 字段（一个都不许省，配置回归会按这个列表校验）：
##   id / name / kind / target / cast / cooldown / range / icon / note / slots / hotkey
##   effect = { mods[], burst{shots,interval,reload} }
##   anim    = { on, hold, off }
##   vfx     = { on, off }

const DIR := "res://代码/配置/卡/技能/"

const K_ACTIVE: StringName = &"主动"
const K_TOGGLE: StringName = &"开关"
const K_PASSIVE: StringName = &"被动"
const K_GATHER: StringName = &"采集"

const T_NONE: StringName = &"无"
const T_POINT: StringName = &"点"
const T_UNIT: StringName = &"单位"
const T_RESOURCE: StringName = &"资源"

## 启动时填充：id → Dictionary
static var _defs: Dictionary = {}
static var _loaded: bool = false
## 加载失败/重名的 id（自检读）
static var load_errors: Array[String] = []


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_defs.clear()
	load_errors.clear()
	var da := DirAccess.open(DIR)
	if da == null:
		push_warning("[技能表] 打不开目录：" + DIR)
		return
	var files: PackedStringArray = da.get_files()
	files.sort()
	for f in files:
		if not f.ends_with(".tres"):
			continue
		var res: Resource = ResourceLoader.load(DIR + f)
		if res == null:
			load_errors.append("%s：加载失败" % f)
			continue
		if not res.has_method("to_def"):
			load_errors.append("%s：不是 SkillCard" % f)
			continue
		var d: Dictionary = res.call("to_def")
		var sid: StringName = StringName(d.get("id", &""))
		if sid == &"":
			load_errors.append("%s：id 为空" % f)
			continue
		if _defs.has(sid):
			load_errors.append("%s：id 重名（%s）" % [f, sid])
			continue
		d["file"] = f
		_defs[sid] = d


static func has(id: StringName) -> bool:
	_ensure()
	return _defs.has(id)


static func get_def(id: StringName) -> Dictionary:
	_ensure()
	return _defs.get(id, {})


static func ids() -> Array:
	_ensure()
	return _defs.keys()


## 全部定义（自检/编辑器用；返回内部引用，别改）
static func all() -> Dictionary:
	_ensure()
	return _defs


static func kind_of(id: StringName) -> StringName:
	var d: Dictionary = get_def(id)
	return StringName(d.get("kind", &""))


static func is_gather(id: StringName) -> bool:
	return kind_of(id) == K_GATHER


static func is_toggle(id: StringName) -> bool:
	return kind_of(id) == K_TOGGLE


static func is_passive(id: StringName) -> bool:
	return kind_of(id) == K_PASSIVE


## 采集技能同时能容纳几个农民（载位）。没有这个字段 = 1。
static func slots_of(id: StringName) -> int:
	var d: Dictionary = get_def(id)
	if d.is_empty():
		return 1
	return maxi(1, int(d.get("slots", 1)))


## 按资源种类挑采集技能（金矿 → 采矿，树 → 伐木）
static func gather_skill_for(kind: int) -> StringName:
	return &"chop_wood" if kind == 1 else &"mine_gold"


## 技能的效果组件（不含表现）。没有返回空字典。
static func effect_of(id: StringName) -> Dictionary:
	var d: Dictionary = get_def(id)
	return d.get("effect", {})


## 技能的连发组件（没有连发返回空字典）
static func burst_of(id: StringName) -> Dictionary:
	var eff: Dictionary = effect_of(id)
	return eff.get("burst", {})


## 技能的表现组件：anim / vfx
static func anim_of(id: StringName) -> Dictionary:
	var d: Dictionary = get_def(id)
	return d.get("anim", {})


static func vfx_of(id: StringName) -> Dictionary:
	var d: Dictionary = get_def(id)
	return d.get("vfx", {})


# ===========================================================================
# 编辑器接口（后续"技能编辑器"直接读这个生成表单）
# ===========================================================================

## 字段清单：名字 → {type, hint, default}
## 技能编辑器、配置回归都读这一份，保证"能加的字段"和"能存的字段"是同一套。
static func schema() -> Dictionary:
	return {
		"id": {"type": "StringName", "hint": "唯一 id（= 文件名）", "default": &""},
		"display_name": {"type": "String", "hint": "中文名", "default": "技能"},
		"icon": {"type": "String", "hint": "图标 id（界面规格.icon_tex 的键）", "default": "shield"},
		"note": {"type": "String", "hint": "一句话说明", "default": ""},
		"kind": {"type": "String", "hint": "主动 / 开关 / 被动 / 采集", "default": "主动"},
		"target": {"type": "String", "hint": "无 / 点 / 单位 / 资源", "default": "无"},
		"cast": {"type": "float", "hint": "前摇秒数", "default": 0.0},
		"cooldown": {"type": "float", "hint": "冷却秒数", "default": 0.0},
		"range": {"type": "float", "hint": "施放距离（米）", "default": 0.0},
		"slots": {"type": "int", "hint": "采集载位", "default": 1},
		"hotkey": {"type": "String", "hint": "快捷键（空 = 自动）", "default": ""},
		"mods": {"type": "Array", "hint": "开关类：自身修正 [{stat,mul,when?}]", "default": []},
		"burst_shots": {"type": "int", "hint": "连发发数（0 = 不连发）", "default": 0},
		"burst_interval": {"type": "float", "hint": "连发间隔（秒）", "default": 0.12},
		"reload": {"type": "float", "hint": "装填时长（秒）", "default": 0.0},
		"anim_on": {"type": "StringName", "hint": "开启动画（可空）", "default": &""},
		"anim_hold": {"type": "StringName", "hint": "持续动画（可空）", "default": &""},
		"anim_off": {"type": "StringName", "hint": "关闭动画（可空）", "default": &""},
		"vfx_on": {"type": "StringName", "hint": "开启特效（可空）", "default": &""},
		"vfx_off": {"type": "StringName", "hint": "关闭特效（可空）", "default": &""},
	}


## 支持的修正 stat（技能运行时按这些名字查倍率）
static func stat_list() -> Array[String]:
	return [
		"damage_taken",      # 受到伤害倍率（可带 when=伤害类型）
		"damage_dealt",      # 造成伤害倍率
		"move_speed",        # 移速倍率
		"attack_cooldown",   # 攻击间隔倍率（2.0 = 攻速 -50%）
		"attack_range",      # 射程倍率
		"armor",             # 护甲加法（mul 当 add 用）
	]
