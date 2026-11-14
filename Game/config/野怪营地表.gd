extends RefCounted
## **野怪营地表**：把 `Game/config/卡/野怪营地/` 下的 .tres 读成一张"锚点建筑 → 营地定义"的表。
##
## 为什么单独一层：`野怪营地.gd` 每帧只关心"这座楼对应哪份配置"，
## 不该自己开目录、拼路径、处理重复锚点。把 IO 收在这里，系统层就是纯逻辑。
##
## 缓存策略：静态缓存（整个进程只扫一次目录）。
##   营地配置是**编辑期数据**，运行时不会变；每次 setup 都扫一遍 30 个文件纯属浪费。
##   改了 .tres 想立刻看到效果 → 重启游戏（和建筑卡同一个口径）。
##
## ⚠ 本文件**不写 class_name**（同上：别碰全局类缓存），调用方用 preload 常量 + `.call()`。

const CardStore := preload("res://Game/config/card_store.gd")
## 营地卡目录（JSON）
const CARD_DIR := CardStore.DIR_CAMPS + "/"

## 全部营地定义（按文件名排序，保证同图每次刷新顺序一致）
static var _all: Array = []
## 锚点建筑 id（String）→ 营地定义（**默认**那份，逐实例可用 camp_id 覆盖）
static var _by_den: Dictionary = {}
## 营地 id（String）→ 营地定义（逐实例指定用）
static var _by_id: Dictionary = {}
static var _loaded: bool = false


## 全部营地定义（数组元素是 Resource，字段见 野怪营地定义.gd）
static func all() -> Array:
	if not _loaded:
		_reload()
	return _all


## 让缓存失效（编辑器保存营地卡之后调用；运行时不用管）。
## 没有这个的话，玩家在编辑器里新建一张营地卡必须重启 Godot 才看得到 ——
## 而营地配置本来就是"编辑期数据"，重启一次等于把刚写的配置藏起来。
static func reload() -> void:
	_loaded = false
	_all.clear()
	_by_den.clear()
	_by_id.clear()


## 按锚点建筑 id 反查营地定义；查不到返回 null
static func for_den(den_id: StringName) -> Resource:
	if not _loaded:
		_reload()
	return _by_den.get(String(den_id), null) as Resource


## 按营地 id 取定义（地图对象 properties.camp_id 逐实例指定用）
static func by_id(camp_id: String) -> Resource:
	if not _loaded:
		_reload()
	return _by_id.get(camp_id, null) as Resource


static func _reload() -> void:
	_loaded = true
	_all.clear()
	_by_den.clear()
	_by_id.clear()
	# 锚点 → 该锚点的全部候选（选默认要看 `default_for_anchor`，见下面的注释）
	var by_anchor: Dictionary = {}
	for entry in CardStore.list(CardStore.DIR_CAMPS):
		var f: String = entry["file"]
		var res: Resource = entry["card"]
		if res == null:
			push_warning("[野怪营地表] 加载失败：%s" % f)
			continue
		var den: String = String(res.get("den_building"))
		if den.is_empty():
			push_warning("[野怪营地表] %s 没有 den_building，已跳过" % f)
			continue
		_all.append(res)
		_by_id[String(res.get("id"))] = res
		if not by_anchor.has(den):
			by_anchor[den] = []
		(by_anchor[den] as Array).append(res)
	# 同类锚点允许多份配置（逐实例 camp_id 指定）。**默认那份**必须显式标
	# `default_for_anchor = true`，不再按文件名排序猜 —— 否则 `camp_creep_den_1.json`
	# 会排在 `camp_den.json` 前面抢走 creep_den，还每次启动刷一条"锚点重复"警告。
	for den in by_anchor:
		var list: Array = by_anchor[den]
		var pick: Resource = null
		var flagged: int = 0
		for r in list:
			if bool(r.get("default_for_anchor")):
				flagged += 1
				if pick == null:
					pick = r
		if pick == null:
			# 一份都没标：退回"文件名排序第一"，并且只在真的有多份时提醒一次
			pick = list[0]
			if list.size() > 1:
				push_warning("[CampTable] anchor %s: %d files, none marked default -> %s"
						% [den, list.size(), String(pick.get("id"))])
		elif flagged > 1:
			push_warning("[CampTable] anchor %s: %d defaults -> %s"
					% [den, flagged, String(pick.get("id"))])
		_by_den[den] = pick
