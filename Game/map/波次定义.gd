@tool
class_name WaveDef
extends Resource
## **波次定义**：什么时候、从哪个区域、出什么兵、打哪个区域、多难。
##
## 刻意保持"一张表能念完"的复杂度：不做行为树、不做事件脚本、不做条件分支。
## 行为树/触发器是明确非目标，这里只有五个字段。

## 触发时间（秒，从开局算）
@export var time: float = 60.0
## 兵种组成：{ "footman": 4, "archer": 2 }
@export var composition: Dictionary = {}
## 出生区域 id（对应 MapDef.regions）
@export var spawn_region: String = ""
## 目标区域 id（留空 = 直接打玩家基地）
@export var target_region: String = ""
## 难度 0/1/2（简单/普通/困难），只做数值倍率，不做 AI 行为
@export var difficulty: int = 1


static func make(p_time: float, p_comp: Dictionary, p_spawn: String, p_target: String,
		p_diff: int = 1) -> WaveDef:
	var w := WaveDef.new()
	w.time = p_time
	w.composition = p_comp.duplicate(true)
	w.spawn_region = p_spawn
	w.target_region = p_target
	w.difficulty = p_diff
	return w


## 总兵力（编辑器列表显示用）
func total_units() -> int:
	var n: int = 0
	for k in composition:
		n += int(composition[k])
	return n


func composition_text() -> String:
	var parts: PackedStringArray = []
	for k in composition:
		parts.append("%s×%d" % [String(k), int(composition[k])])
	return " ".join(parts) if not parts.is_empty() else "（空）"


func clone_wave() -> WaveDef:
	var w := WaveDef.new()
	w.time = time
	w.composition = composition.duplicate(true)
	w.spawn_region = spawn_region
	w.target_region = target_region
	w.difficulty = difficulty
	return w


func to_dict() -> Dictionary:
	var comp: Dictionary = {}
	for k in composition:
		comp[String(k)] = int(composition[k])
	return {
		"time": time,
		"composition": comp,
		"spawn_region": spawn_region,
		"target_region": target_region,
		"difficulty": difficulty,
	}


static func from_dict(d: Dictionary) -> WaveDef:
	var w := WaveDef.new()
	w.time = float(d.get("time", 60.0))
	var c: Variant = d.get("composition", {})
	if c is Dictionary:
		w.composition = (c as Dictionary).duplicate(true)
	w.spawn_region = String(d.get("spawn_region", ""))
	w.target_region = String(d.get("target_region", ""))
	w.difficulty = int(d.get("difficulty", 1))
	return w
