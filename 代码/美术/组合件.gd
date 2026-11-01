extends RefCounted
## **组合件注册表** —— `UnitDef.model_path = "combo:<key>"` 时，key 对应哪个外观脚本。
##
## 为什么要这张表（而不是拿 key 直接拼路径）：
##   key 是**英文 id**（`dungeon` / `campfire`，和 UnitDef.id / 地图对象 type_id 一致），
##   而外观脚本是**中文文件名**（`地牢外观.gd` / `营火外观.gd`）。两者对不上，
##   于是"combo:dungeon" 会去找 `dungeon外观.gd` —— 找不到，退回占位方块。
##
## 唯一入口：`script_for(key)`。游戏（单位视觉.gd）和地图编辑器（预览工厂.gd）
## 都走这里，保证"编辑器所见 = 进图所见"。
##
## ★ 写新组合件时**只改这张表**：
##   ① 美术/模型 里拼好部件；
##   ② 写 `代码/美术/<中文>外观.gd`，提供 `static func build(def: UnitDef) -> Node3D`；
##   ③ 在这里加一行 key → 中文名。

## key → 外观脚本目录下的中文名前缀
const ALIAS: Dictionary = {
	&"dungeon": "地牢",
	&"campfire": "营火",
}

## 脚本缓存（key → Script；找不到记 null，避免每次都撞一次 load）
static var _cache: Dictionary = {}


## key → 脚本绝对路径
static func path_for(key: String) -> String:
	var cn: String = String(ALIAS.get(StringName(key), ""))
	if cn.is_empty():
		cn = key    # 没登记就按同名试一次（给临时脚本留条活路）
	return "res://代码/美术/%s外观.gd" % cn


## key → 外观脚本（找不到返回 null，调用方负责退回占位盒）
static func script_for(key: String) -> Script:
	if _cache.has(key):
		return _cache.get(key, null) as Script
	var p: String = path_for(key)
	var s: Script = load(p) as Script if ResourceLoader.exists(p) else null
	if s == null:
		push_warning("[组合件] 缺少外观脚本：%s（key=%s）" % [p, key])
	_cache[key] = s
	return s


## 造外观节点（找不到脚本返回 null）
static func build(key: String, def: UnitDef) -> Node3D:
	var s: Script = script_for(key)
	if s == null:
		return null
	var n: Variant = s.call("build", def)
	return n as Node3D
