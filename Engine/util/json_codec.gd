extends RefCounted
## 职责：Resource ↔ JSON 的通用编解码（数据与脚本解耦的唯一出口）
## 属于：Engine/util
## 对外：encode(v) / encode_resource(res) / apply(obj, props) / restore(script, data) / decode_value(v, type, hint)
## 为什么需要：内容数据必须是**纯 JSON**（agent 可读可改、C# 内核也能读），
##   而 Godot 编辑器与运行时用的是 Resource。两边靠这一层转，转换规则只有一份。
## 约定：
##   · 只编码 @export（PROPERTY_USAGE_STORAGE）字段，跳过 resource_*；
##   · StringName → 字符串（读回时按属性类型转回 StringName）；
##   · 资源引用嵌套成 {"$script":"res://…", "props":{…}}；
##   · Vector2/Vector2i/Vector3/Color 用 {"$t":"Vector2","x":…} 这种标记；
##   · **遇到不认识的字段就报错**（apply 返回错误列表），绝不静默忽略。

const MARKER_TYPE := "$t"
const MARKER_SCRIPT := "$script"
const MARKER_PROPS := "props"


# ===========================================================================
# 编码
# ===========================================================================
static func encode(value: Variant) -> Variant:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return value
		TYPE_FLOAT:
			# 整数值的 float 写成整数：JSON 可读性 + 读写往返稳定。
			# 读回时按属性类型（float）转回，不会丢精度（只处理 |x| < 2^53 的整数）。
			var f: float = value
			if is_finite(f) and f == floor(f) and absf(f) < 9007199254740992.0:
				return int(f)
			return f
		TYPE_STRING_NAME:
			return String(value)
		TYPE_VECTOR2:
			var v2: Vector2 = value
			return {MARKER_TYPE: "Vector2", "x": v2.x, "y": v2.y}
		TYPE_VECTOR2I:
			var v2i: Vector2i = value
			return {MARKER_TYPE: "Vector2i", "x": v2i.x, "y": v2i.y}
		TYPE_VECTOR3:
			var v3: Vector3 = value
			return {MARKER_TYPE: "Vector3", "x": v3.x, "y": v3.y, "z": v3.z}
		TYPE_VECTOR3I:
			var v3i: Vector3i = value
			return {MARKER_TYPE: "Vector3i", "x": v3i.x, "y": v3i.y, "z": v3i.z}
		TYPE_COLOR:
			var c: Color = value
			return {MARKER_TYPE: "Color", "r": c.r, "g": c.g, "b": c.b, "a": c.a}
		TYPE_ARRAY:
			var arr: Array = []
			for v in value:
				arr.append(encode(v))
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k in value:
				d[str(k)] = encode(value[k])
			return d
		TYPE_OBJECT:
			if value == null:
				return null
			if value is Resource:
				return encode_resource(value)
			return null
	return null


static func encode_resource(res: Resource) -> Dictionary:
	var script: Script = res.get_script()
	if script == null:
		push_error("[JsonCodec] 资源没有脚本：" + str(res))
		return {}
	var out := {MARKER_SCRIPT: script.resource_path, MARKER_PROPS: {}}
	var props: Dictionary = out[MARKER_PROPS]
	for p in res.get_property_list():
		var usage := int(p.get("usage", 0))
		if not (usage & PROPERTY_USAGE_STORAGE):
			continue
		var name := String(p.name)
		if name.begins_with("resource_") or name == "script":
			continue
		props[name] = encode(res.get(name))
	return out


## class_name → 脚本路径（Godot 的全局类表；自定义类的类型数组需要它）
static func script_for_class(cls: String) -> Script:
	for e in ProjectSettings.get_global_class_list():
		if String(e.get("class", "")) == cls:
			var path := String(e.get("path", ""))
			if not path.is_empty():
				return load(path) as Script
	return null


# ===========================================================================
# 解码
# ===========================================================================
## 把 props 写回一个**已经实例化**的对象。返回错误列表（空 = 通过）。
static func apply(obj: Object, props: Dictionary) -> Array[String]:
	var errs: Array[String] = []
	var infos: Dictionary = {}
	for p in obj.get_property_list():
		infos[String(p.name)] = p
	for key in props.keys():
		if not infos.has(key):
			errs.append("未知字段：%s" % key)
			continue
		var info: Dictionary = infos[key]
		var v: Variant = decode_value(props[key], int(info.type), String(info.hint_string))
		# ★ 类型化数组（Array[SkillAtom] / Array[DifficultyDef]）不能用 set() 赋值：
		#   Godot 4.7 动态构造类型数组时会按"原生类"校验自定义 class_name，必然失败。
		#   拿对象上**已经带类型**的那个数组，用 assign() 就地填充 —— 实测可行。
		if int(info.type) == TYPE_ARRAY:
			var current: Variant = obj.get(key)
			if current is Array:
				(current as Array).assign(v if v is Array else [])
				continue
		obj.set(key, v)
	return errs


static func restore(script_path: String, data: Dictionary) -> Resource:
	var script: Script = load(script_path)
	if script == null:
		push_error("[JsonCodec] 脚本不存在：" + script_path)
		return null
	var obj: Variant = script.new()
	if not (obj is Resource):
		push_error("[JsonCodec] 这个脚本不是 Resource：" + script_path)
		return null
	var errs := apply(obj, data.get(MARKER_PROPS, {}))
	for e in errs:
		push_error("[JsonCodec] %s：%s" % [script_path, e])
	return obj


## 按属性类型把 JSON 值转回 Variant
static func decode_value(value: Variant, type: int, hint_string: String = "") -> Variant:
	if value == null:
		return null
	# 自描述标记优先：字典值 / 无类型数组元素没有属性类型可依，靠 $t / $script 还原
	if value is Dictionary and value.has(MARKER_SCRIPT):
		return restore(String(value[MARKER_SCRIPT]), value)
	if value is Dictionary and value.has(MARKER_TYPE):
		match String(value[MARKER_TYPE]):
			"Vector2":
				return Vector2(float(value.get("x", 0)), float(value.get("y", 0)))
			"Vector2i":
				return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))
			"Vector3":
				return Vector3(float(value.get("x", 0)), float(value.get("y", 0)), float(value.get("z", 0)))
			"Vector3i":
				return Vector3i(int(value.get("x", 0)), int(value.get("y", 0)), int(value.get("z", 0)))
			"Color":
				return Color(float(value.get("r", 0)), float(value.get("g", 0)), float(value.get("b", 0)), float(value.get("a", 1)))
	match type:
		TYPE_BOOL:
			return bool(value)
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			return float(value)
		TYPE_STRING:
			return String(value)
		TYPE_STRING_NAME:
			return StringName(String(value))
		TYPE_ARRAY:
			var elem_type := -1
			var elem_class := ""
			var colon := hint_string.find(":")
			var left := hint_string if colon < 0 else hint_string.substr(0, colon)
			if not left.is_empty():
				var slash := left.find("/")
				elem_type = int(left.substr(0, slash)) if slash >= 0 else int(left)
			if colon >= 0:
				elem_class = hint_string.substr(colon + 1)
			var arr: Array = []
			for item in value:
				arr.append(decode_value(item, elem_type, elem_class))
			return arr
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k in value.keys():
				d[k] = decode_value(value[k], -1, "")
			return d
		TYPE_OBJECT:
			if value is Dictionary and value.has(MARKER_SCRIPT):
				return restore(String(value[MARKER_SCRIPT]), value)
			return null
		TYPE_VECTOR2:
			return Vector2(float(value.get("x", 0)), float(value.get("y", 0)))
		TYPE_VECTOR2I:
			return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))
		TYPE_VECTOR3:
			return Vector3(float(value.get("x", 0)), float(value.get("y", 0)), float(value.get("z", 0)))
		TYPE_VECTOR3I:
			return Vector3i(int(value.get("x", 0)), int(value.get("y", 0)), int(value.get("z", 0)))
		TYPE_COLOR:
			return Color(float(value.get("r", 0)), float(value.get("g", 0)), float(value.get("b", 0)), float(value.get("a", 1)))
	# 未知类型（-1）：无类型容器里的数字。JSON 解析一律给 float，
	# 整数值转回 int —— 否则 player_units 这类 {"peasant": 5} 会变成 5.0，
	# 下游 range()/下标/取整都会静默出错。
	if typeof(value) == TYPE_FLOAT:
		var f: float = value
		if is_finite(f) and f == floor(f) and absf(f) < 9007199254740992.0:
			return int(f)
	return value