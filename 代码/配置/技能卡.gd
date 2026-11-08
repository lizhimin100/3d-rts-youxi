@tool
class_name SkillCard
extends Resource
## **技能卡（配方卡）—— 三层积木 + 一张配方卡 = 成品技能**
##
## ★ 2026-11-08 玩家定稿的模型（整套技能系统的唯一口径，改之前先读完这段）：
##
## ```
##   ┌ 第 1 层：技能原子（Effect）  代码/配置/原子/*.gd
##   │    只描述"发生什么效果"：属性倍率 / 连发 / 格挡 …
##   │    **不绑触发方式** —— 同一个减伤原子，换张卡就是举盾/光环/格挡
##   ├ 第 2 层：单位姿势（Action）   动画 clip 名（shield_hold / cast …）
##   │    只是 clip 名，模型没有就静默跳过
##   ├ 第 3 层：技能特效（VFX）      代码/系统/技能特效.gd 的 id
##   │    只是 id，没注册就退到占位微光
##   └ 配方卡（本文件 SkillCard）     用哪几个原子 + 播哪个动作 + 挂哪个特效
##                                    + 什么触发 + 对谁 + 冷却多久
## ```
##
## **卡是说明书，不是成品；成品是运行时按卡把三层积木拼起来**（技能表 → 技能运行时）。
##
## 2026-11-07 建立。玩家口径：技能不要和单位绑死，编辑器里能单独拎出来挂到任意单位；
## 技能的动作、特效、效果三者分开，缺什么就用占位。
##
## 于是这张卡被拆成四块，**任何一块都可以留空**：
##
## ```
##   ┌ 身份 ──────────────── id / 名字 / 图标 / 说明
##   ├ 施放 ──────────────── kind（主动·开关·被动·采集）/ target / cast / cooldown / range
##   ├ 效果（纯数值）────── mods[]（开关类挂自身修正）/ burst（连发）+ reload
##   └ 表现（可缺）───────── anim_on / anim_hold / anim_off  +  vfx_on / vfx_off
## ```
##
## 三条规矩：
##   1. **效果不写代码**：新的开关技能只加 mods，不改任何 .gd；
##   2. **表现不做硬依赖**：`anim_*` 为空 → 不播（保持原动作），`vfx_*` 为空 → 不冒特效；
##   3. **单位只认 id**：`UnitCard.skills` 里放 id，单位运行时向 `技能表` 要定义。
##
## 存盘位置：`代码/配置/卡/技能/<id>.tres`（启动时被 `技能表.gd` 全量扫入）。

@export_group("身份")
## 唯一 id（和文件名一致，代码里用它索引）
@export var id: StringName = &""
## 中文名（命令卡按钮 / 提示条）
@export var display_name: String = "技能"
## 图标 id（`界面规格.icon_tex` 的键：shield / bow / clock / fire / sword …）
@export var icon: String = "shield"
## 一句话说明（命令卡副标题 + 气泡）
@export_multiline var note: String = ""

@export_group("施放")
## 技能类型：
##   · 主动 = 点一下放一次（火球术）
##   · 开关 = 点一下开、再点一下关（举盾）
##   · 被动 = 无需操作，自动生效（三连发）
##   · 采集 = 右键资源触发（伐木 / 采矿）
##   · 受击 = 每次挨打时判定一次（格挡）—— **触发方式住在卡上，不住在原子类里**
@export_enum("主动", "开关", "被动", "采集", "受击") var kind: String = "主动"
## 目标类型：无 / 点 / 单位 / 资源
@export_enum("无", "点", "单位", "资源") var target: String = "无"
## 前摇秒数（0 = 瞬发）
@export var cast: float = 0.0
## 冷却秒数（开关类可给 0.4，防止连点抖动）
@export var cooldown: float = 0.0
## 施放距离（米，身位边缘口径；0 = 对自己）
@export var range: float = 0.0
## 采集类：这个资源点能站几个农民（载位）
@export var slots: int = 1
## 快捷键（空 = 自动分配 Q，第二个技能 X）
@export var hotkey: String = ""

@export_group("原子（三层积木第 1 层）")
## 这张卡用哪几个原子。**编辑器不直接暴露原子的原始字段**，
## 而是按"技能模板"生成表单（见 addons/map_editor/技能弹窗.gd）。
## 允许多个原子叠在一张卡上（例如：减伤 + 移速惩罚 + 攻速惩罚 = 举盾）。
@export var atoms: Array[SkillAtom] = []

@export_group("效果（纯数值，不写代码 · 旧字段，保留兼容）")
## 开关类技能**开启时**挂在自身上的修正组件。每项一个 Dictionary：
##   {"stat": "damage_taken", "mul": 0.85}                 # 受到伤害 ×0.85
##   {"stat": "damage_taken", "mul": 0.65, "when": "穿刺"}  # 只在受穿刺时再 ×0.65
##   {"stat": "move_speed", "mul": 0.55}                    # 移速 ×0.55
##   {"stat": "attack_cooldown", "mul": 2.0}                # 攻击间隔 ×2（攻速 -50%）
## 支持的 stat 见 `代码/系统/技能运行时.gd` 顶部注释。
@export var mods: Array = []
## 连发组件：一次攻击打几发（0 = 不连发）。打完后进装填。
@export var burst_shots: int = 0
## 连发间隔（秒）
@export var burst_interval: float = 0.12
## 装填时长（秒）：连发打完后要等这么久才能再攻击
@export var reload: float = 0.0

@export_group("表现 · 动作（可缺）")
## 开启/切换时播的动作（例如 shield_up）。模型没有就自动跳过。
@export var anim_on: StringName = &""
## 持续动作（例如 shield_hold）：开启期间覆盖 idle。
@export var anim_hold: StringName = &""
## 关闭时播的动作（例如 shield_down）。
@export var anim_off: StringName = &""

@export_group("表现 · 特效（可缺）")
## 开启特效 id（注册表见 `代码/系统/技能特效.gd`；例如 weapon_glint = 切换武器特效）
@export var vfx_on: StringName = &""
## 关闭特效 id
@export var vfx_off: StringName = &""


## 旧字段（mods 数组）与原子里的属性倍率**合并**：老的 .tres 不用改就能继续跑。
func _all_mods() -> Array:
	var out: Array = []
	for m in mods:
		if m is Dictionary:
			out.append(m)
	for a in atoms:
		if a != null and a.has_method("to_mods"):
			out.append_array(a.call("to_mods"))
	return out


## 连发：原子优先，没有原子时回落到旧字段
func _all_burst() -> Dictionary:
	for a in atoms:
		if a != null and a.has_method("to_burst"):
			var b: Dictionary = a.call("to_burst")
			if not b.is_empty():
				return b
	if burst_shots > 0:
		return {
			"shots": maxi(burst_shots, 0),
			"interval": maxf(burst_interval, 0.02),
			"reload": maxf(reload, 0.0),
		}
	return {}


## 格挡：所有原子里的格挡取**最高概率**那一份（叠多份没有意义）
func _all_block() -> Dictionary:
	var best: Dictionary = {}
	for a in atoms:
		if a == null or not a.has_method("to_block"):
			continue
		var b: Dictionary = a.call("to_block")
		if b.is_empty():
			continue
		if best.is_empty() or float(b.get("chance", 0.0)) > float(best.get("chance", 0.0)):
			best = b
	return best


## 这张卡的原子摘要（编辑器/日志）
func atom_describe() -> Array:
	var out: Array = []
	for a in atoms:
		if a != null and a.has_method("describe"):
			out.append(String(a.call("describe")))
	return out


## 转成运行期读的 Dictionary（`技能表.get_def` 的返回格式）。
## 为什么要转：全工程的技能读取都是 Dictionary 口径，转一层就不用改几十处调用点。
func to_def() -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"kind": StringName(kind),
		"target": StringName(target),
		"cast": maxf(cast, 0.0),
		"cooldown": maxf(cooldown, 0.0),
		"range": maxf(range, 0.0),
		"icon": icon,
		"note": note,
		"slots": maxi(slots, 1),
		"hotkey": hotkey,
		"effect": {
			"mods": _all_mods(),
			"burst": _all_burst(),
			"block": _all_block(),
		},
		"anim": {
			"on": anim_on,
			"hold": anim_hold,
			"off": anim_off,
		},
		"vfx": {
			"on": vfx_on,
			"off": vfx_off,
		},
	}
