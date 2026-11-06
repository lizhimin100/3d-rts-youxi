extends RefCounted
## **野怪营地表**：把 `代码/配置/卡/野怪营地/` 下的 .tres 读成一张"锚点建筑 → 营地定义"的表。
##
## 为什么单独一层：`野怪营地.gd` 每帧只关心"这座楼对应哪份配置"，
## 不该自己开目录、拼路径、处理重复锚点。把 IO 收在这里，系统层就是纯逻辑。
##
## 缓存策略：静态缓存（整个进程只扫一次目录）。
##   营地配置是**编辑期数据**，运行时不会变；每次 setup 都扫一遍 30 个文件纯属浪费。
##   改了 .tres 想立刻看到效果 → 重启游戏（和建筑卡同一个口径）。
##
## ⚠ 本文件**不写 class_name**（同上：别碰全局类缓存），调用方用 preload 常量 + `.call()`。

## 营地卡目录
const CARD_DIR := "res://代码/配置/卡/野怪营地/"

## 全部营地定义（按文件名排序，保证同图每次刷新顺序一致）
static var _all: Array = []
## 锚点建筑 id（String）→ 营地定义
static var _by_den: Dictionary = {}
static var _loaded: bool = false


## 全部营地定义（数组元素是 Resource，字段见 野怪营地定义.gd）
static func all() -> Array:
	if not _loaded:
		_reload()
	return _all


## 按锚点建筑 id 反查营地定义；查不到返回 null
static func for_den(den_id: StringName) -> Resource:
	if not _loaded:
		_reload()
	return _by_den.get(String(den_id), null) as Resource


static func _reload() -> void:
	_loaded = true
	_all.clear()
	_by_den.clear()
	var dir := DirAccess.open(CARD_DIR)
	if dir == null:
		push_warning("[野怪营地表] 目录打不开：%s（营地系统将不会刷任何怪）" % CARD_DIR)
		return
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for f in names:
		if not f.ends_with(".tres"):
			continue
		var res: Resource = load(CARD_DIR + f) as Resource
		if res == null:
			push_warning("[野怪营地表] 加载失败：%s" % f)
			continue
		var den: String = String(res.get("den_building"))
		if den.is_empty():
			push_warning("[野怪营地表] %s 没有 den_building，已跳过" % f)
			continue
		# 同一个锚点只能有一份配置：否则"摆一座巢穴刷两套怪"，玩家根本对不出原因。
		# 先到先得（文件名排序），后来的打警告但不覆盖。
		if _by_den.has(den):
			push_warning("[野怪营地表] 锚点「%s」重复配置（%s 被忽略）" % [den, f])
			continue
		_all.append(res)
		_by_den[den] = res
