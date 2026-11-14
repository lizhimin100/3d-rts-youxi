extends RefCounted
## 职责：JSON 读写（UTF-8 / 容忍 BOM / 原子写 / 失败有明确错误）
## 属于：Engine/util（通用，不含任何游戏规则）
## 对外：read / read_dict / write_atomic / stringify
## 禁改：不要往这里加游戏路径或业务校验（那是调用方的事）

const BOM := "\uFEFF"


## 读 JSON；文件不存在或解析失败返回 fallback（并且 push_error，不静默）
static func read(path: String, fallback: Variant = null) -> Variant:
	if not FileAccess.file_exists(path):
		return fallback
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[json] 打不开：%s（错误 %d）" % [path, FileAccess.get_open_error()])
		return fallback
	var text := f.get_as_text()
	f.close()
	if text.begins_with(BOM):
		text = text.substr(1)
	var parser := JSON.new()
	var err := parser.parse(text)
	if err != OK:
		push_error("[json] 解析失败 %s 第 %d 行：%s" % [path, parser.get_error_line(), parser.get_error_message()])
		return fallback
	return parser.data


## 读 JSON 并保证返回 Dictionary（类型不对也报错）
static func read_dict(path: String, fallback: Dictionary = {}) -> Dictionary:
	var v: Variant = read(path, null)
	if v is Dictionary:
		return v
	if v != null:
		push_error("[json] %s 顶层不是对象（实际 %s）" % [path, type_string(typeof(v))])
	return fallback


## 原子写：先写 .tmp 再替换。Windows 上 rename 覆盖已存在文件会失败，所以先删后改名。
static func write_atomic(path: String, data: Variant, pretty: bool = true) -> Error:
	var text := stringify(data, pretty)
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		var mk := DirAccess.make_dir_recursive_absolute(dir)
		if mk != OK:
			push_error("[json] 建目录失败 %s" % dir)
			return mk
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("[json] 写不了临时文件：%s" % tmp)
		return FileAccess.get_open_error()
	f.store_string(text)
	f.flush()
	f.close()
	var abs_path := ProjectSettings.globalize_path(path)
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(abs_path)
	var err := DirAccess.rename_absolute(abs_tmp, abs_path)
	if err != OK:
		push_error("[json] 替换失败 %s（%d）" % [path, err])
	return err


static func stringify(data: Variant, pretty: bool = true) -> String:
	return JSON.stringify(data, "\t" if pretty else "", false)
