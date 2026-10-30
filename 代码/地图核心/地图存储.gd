@tool
class_name MapStore
extends RefCounted
## **地图存储**：.tres 主格式 + JSON 导入导出 + 版本迁移 + 最近地图。
##
## 为什么主格式用 .tres：ResourceSaver 直接吃 MapDef，字段/类型/子资源全都保住，
## 编辑器 Project 面板里双击就能看。JSON 是给外部工具/版本对比用的旁路。

## 最近地图配置文件（跟地图一起放项目里的「地图」文件夹，别塞 C 盘）
const RECENT_CFG := "res://地图/_最近地图.cfg"
const RECENT_KEY := "recent"
const RECENT_MAX := 8
## Test Map 用的临时地图（项目内「地图」文件夹，游戏通过 --map=res://... 读）
const TEST_MAP_PATH := "res://地图/_测试地图.tres"


# ===========================================================================
# 保存
# ===========================================================================

## 把绝对路径换算成 res:// / user://（游戏进程和编辑器拿到的路径写法可能不同）
static func normalize_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	var p: String = path.replace("\\", "/")
	var proj: String = ProjectSettings.globalize_path("res://").replace("\\", "/")
	if p.begins_with(proj):
		return "res://" + p.substr(proj.length())
	var user: String = ProjectSettings.globalize_path("user://").replace("\\", "/")
	if p.begins_with(user):
		return "user://" + p.substr(user.length())
	return path


## 保存 .tres（ResourceSaver）。返回 Error。
static func save_tres(def: MapDef, path: String) -> Error:
	if def == null:
		return ERR_INVALID_PARAMETER
	path = normalize_path(path)
	if not path.begins_with("res://") and not path.begins_with("user://"):
		path = "res://" + path
	var dir: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	def.version = MapDef.CURRENT_VERSION
	def.ensure_arrays()
	return ResourceSaver.save(def, path)


## 保存 JSON（人可读；向量都转成数组）
static func save_json(def: MapDef, path: String) -> Error:
	if def == null:
		return ERR_INVALID_PARAMETER
	path = normalize_path(path)
	if not path.begins_with("res://") and not path.begins_with("user://"):
		path = "res://" + path
	var dir: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(def.to_dict(), "\t"))
	f.close()
	return OK


# ===========================================================================
# 读取
# ===========================================================================

## 读 .tres 并迁移
static func load_tres(path: String) -> MapDef:
	path = normalize_path(path)
	if not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	var def := res as MapDef
	if def == null:
		push_warning("[地图存储] %s 不是 MapDef" % path)
		return null
	return migrate(def)


## 读 JSON 并迁移
static func load_json(path: String) -> MapDef:
	path = normalize_path(path)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("[地图存储] %s 不是合法 JSON 对象" % path)
		return null
	var def := MapDef.from_dict(parsed)
	return migrate(def)


## 按扩展名自动选格式（.json → JSON，其它 → .tres）
static func load_any(path: String) -> MapDef:
	if path.is_empty():
		return null
	if path.get_extension().to_lower() == "json":
		return load_json(path)
	return load_tres(path)


## 保存：按扩展名自动选格式
static func save_any(def: MapDef, path: String) -> Error:
	if path.get_extension().to_lower() == "json":
		return save_json(def, path)
	return save_tres(def, path)


# ===========================================================================
# 版本迁移
# ===========================================================================

## 老版本地图书到当前字段。**只补不删**：缺失字段一律取默认值，
## 高度场分辨率变了按比例重采样（见 MapDef.ensure_arrays）。
static func migrate(def: MapDef) -> MapDef:
	if def == null:
		return null
	if def.version > MapDef.CURRENT_VERSION:
		push_warning("[地图存储] 地图版本 %d 高于当前 %d，按当前版本尽力读取"
			% [def.version, MapDef.CURRENT_VERSION])
	# v1：只有 size/heightmap/objects，没有 splat/water/players/waves/camera_bounds
	if def.version < 2:
		if def.splatmap.is_empty():
			def.splatmap = PackedByteArray()
		if def.water == null or not (def.water is Dictionary):
			def.water = {"enabled": false, "spots": []}
		if def.players.is_empty():
			def.players = [
				PlayerSlot.make(0, "player", Color(0.30, 0.62, 1.00), 0,
					Vector2(-def.half_size() * 0.62, def.half_size() * 0.58)),
				PlayerSlot.make(1, "enemy", Color(1.00, 0.32, 0.26), 1,
					Vector2(def.half_size() * 0.62, -def.half_size() * 0.58)),
			]
		if def.victory.is_empty():
			def.victory = {"mode": "destroy_townhall", "time_limit": 0.0}
	def.version = MapDef.CURRENT_VERSION
	def.ensure_arrays()
	if def.camera_bounds.size == Vector2.ZERO:
		def.camera_bounds = Rect2(Vector2(-def.half_size(), -def.half_size()),
			Vector2(def.size, def.size))
	if def.victory.is_empty():
		def.victory = {"mode": "destroy_townhall", "time_limit": 0.0}
	return def


# ===========================================================================
# 最近地图
# ===========================================================================

static func recent_list() -> PackedStringArray:
	var cfg := ConfigFile.new()
	if cfg.load(RECENT_CFG) != OK:
		return PackedStringArray()
	var raw: Variant = cfg.get_value(RECENT_KEY, "paths", PackedStringArray())
	var out := PackedStringArray()
	if raw is PackedStringArray:
		out = raw
	elif raw is Array:
		for p in raw:
			out.append(String(p))
	return out


## 记一条最近地图（去重、最新的排最前、最多 RECENT_MAX 条）
static func recent_add(path: String) -> void:
	if path.is_empty():
		return
	var list := recent_list()
	var out := PackedStringArray([path])
	for p in list:
		if p != path and out.size() < RECENT_MAX:
			out.append(p)
	var cfg := ConfigFile.new()
	cfg.load(RECENT_CFG)
	cfg.set_value(RECENT_KEY, "paths", out)
	cfg.save(RECENT_CFG)


static func recent_clear() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(RECENT_KEY, "paths", PackedStringArray())
	cfg.save(RECENT_CFG)


# ===========================================================================
# 路径工具
# ===========================================================================

## 地图目录（默认保存位置）
static func default_dir() -> String:
	return "res://地图"


## 生成一个不重名的地图路径
static func suggest_path(base_name: String = "新地图") -> String:
	var dir: String = default_dir()
	if not DirAccess.dir_exists_absolute(dir):
		return dir + "/" + base_name + ".tres"
	var path: String = dir + "/" + base_name + ".tres"
	var i: int = 1
	while FileAccess.file_exists(path):
		path = dir + "/%s_%d.tres" % [base_name, i]
		i += 1
	return path
