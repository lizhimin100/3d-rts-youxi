@tool
class_name SkillAtom
extends Resource
## **技能原子（三层积木的第 1 层：效果）**
##
## 三层积木 + 一张配方卡 = 成品技能（玩家 2026-11-08 口径）：
##
## ```
##   ① 技能原子（本文件 + 代码/配置/原子/*.gd）    —— 只管"发生什么效果"
##   ② 单位姿势（动画 clip 名：shield_hold / cast …）—— 只管"摆什么动作"
##   ③ 技能特效（代码/系统/技能特效.gd 的 id）      —— 只管"冒什么光"
##
##   配方卡（SkillCard）= 写清楚：
##        用哪几个原子 + 播哪个动作 + 挂哪个特效 + 什么触发 + 对谁 + 冷却多久
## ```
##
## ★ **原子不绑触发方式**（这是整套设计的地基）：
##   同一个"减伤"原子，换一张卡就能变成
##     · 举盾（主动开关，打开时生效）
##     · 铁甲光环（被动常驻）
##     · 格挡（受击时按概率生效）
##   所以**原子类里不许出现 kind / cooldown / target 这些词** —— 它们属于卡。
##
## 原子只负责把自己的参数翻译成 `技能运行时` 认识的三种结构之一：
##   · `to_mods()`   → [{stat, mul, when}]（属性倍率，和旧 mods 完全同构）
##   · `to_burst()`  → {shots, interval, reload}
##   · `to_block()`  → {chance, mul}
##
## 加一种新原子：
##   1. 在 `代码/配置/原子/` 下新建一个 extends SkillAtom 的 .gd；
##   2. 覆写上面三个方法里用得着的那个；
##   3. 技能编辑器（addons/map_editor/技能弹窗.gd）的模板表里加一行。
##   **不要**在 技能运行时 / 单位.gd 里加 if。

@export_group("身份")
## 原子 id（只做标识/排错用，不参与判定）
@export var atom_id: StringName = &""
## 一句话说明（编辑器里显示给人看）
@export_multiline var note: String = ""


## 属性倍率（没有就返回空数组）
func to_mods() -> Array:
	return []


## 连发规格（没有就返回空字典）
func to_burst() -> Dictionary:
	return {}


## 格挡/受击规格（没有就返回空字典）
func to_block() -> Dictionary:
	return {}


## 编辑器/日志用的一句话摘要
func describe() -> String:
	return String(atom_id)
