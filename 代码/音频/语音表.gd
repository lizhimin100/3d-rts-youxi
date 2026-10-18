class_name VoiceTable
extends RefCounted
## **单位类型 → 语音组** 的唯一映射表（点选应答 / 死亡语音都从这里查）。
##
## 只做"查表"这一件事：不持有播放器、不连信号、不认识 Sfx。
## 新增一个会说话的单位 = 在这里加一行 + 在 工具/音频/合成音效.py 的 VOICE_SETS 里加一组，
## 其余代码（选中/死亡）不用动。

## 语音文件目录（相对 res://）
const DIR := "res://音频/语音/"

## 兵种 id → 语音组名（组名同时是文件名前缀）
const GROUPS := {
	"peasant": "农民",
	"footman": "步兵",
	"archer": "弓箭手",
	"mage": "法师",
}

## 每个组有几条应答变体（文件名 ..._应答1..N.wav）
const VARIANTS := 3


## 取语音组名；不认识的类型返回空串（建筑/资源/召唤物都会走到这里）
static func group_of(unit_id: Variant) -> String:
	if unit_id == null:
		return ""
	var key := String(unit_id)
	if GROUPS.has(key):
		return String(GROUPS[key])
	return ""


## 这个单位类型有没有语音
static func has_voice(unit_id: Variant) -> bool:
	return not group_of(unit_id).is_empty()


## 该类型全部应答语音的 id（不含扩展名；相对 res://音频/）
static func reply_lines(unit_id: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	var group := group_of(unit_id)
	if group.is_empty():
		return out
	for i in VARIANTS:
		out.append("语音/%s_应答%d" % [group, i + 1])
	return out


## 死亡语音 id；没有就返回空串
static func death_line(unit_id: Variant) -> String:
	var group := group_of(unit_id)
	if group.is_empty():
		return ""
	return "语音/%s_死亡" % group


## 组名反查兵种 id（调试/文档用，例如 "农民" → "peasant"）
static func unit_id_of_group(group: String) -> String:
	for key in GROUPS.keys():
		if String(GROUPS[key]) == group:
			return String(key)
	return ""
