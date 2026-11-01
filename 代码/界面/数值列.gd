class_name RtsStatColumn
extends VBoxContainer
## **竖排数值列** —— 单位与建筑中段共用的那三行（攻击 / 护甲 / 移速…）。
##
## 玩家的口径："下面的攻击、护甲和移动在铭牌后下方**竖着**排列，把中间的位置空出来，
## 好让两边不要被UI填满。"
##
## 竖排是这一版的核心：横着摆三块大铭牌会把中段一路撑到命令卡；
## 竖排以后整块只有 ~230px 宽，右边全是战场。
##
##   ┌──────────────────────────┐
##   │ ⚔   15   攻击            │  ← 数字 34px，中文小标 16px，左图标 30px
##   ├──────────────────────────┤  ← 1px 暗金分隔（不用整块斑马底）
##   │ 🛡    5   护甲            │
##   ├──────────────────────────┤
##   │ 👟  4.6  移速            │
##   └──────────────────────────┘
##
## 三条纪律：
##   1. **行底色是空的**：以前每行铺一条 0.62 透明度的深底，三行叠起来就是
##      一块"淡黑方块"，正是玩家要求删掉的东西。现在只用一根金线分栏。
##   2. 数字用等宽字体、右对齐、同一宽度 —— 三行的个位对齐，一眼比大小。
##   3. 每行都能挂弹窗说明（`RtsTipLayer.bind`），所以这里的 `mouse_filter` 必须是 PASS。

const Spec := preload("res://代码/界面/界面规格.gd")
const Deco := preload("res://代码/界面/装饰.gd")

## 行高（HUD 会按底栏高度灌进来）
var row_h: float = 50.0
## 数字列宽（右对齐用）
var value_w: float = 74.0
## 数字字号
var value_fs: int = 34
## 图标边长
var icon_px: float = 27.0

var _rows: Array[PanelContainer] = []
var _icons: Array[Control] = []
var _vals: Array[Label] = []
var _caps: Array[Label] = []
## 每行下面那根分隔线（行隐藏时它也要跟着藏，否则会留下一条"孤线"）
var _rules: Array[Control] = []
## 每行的弹窗内容（RtsStatColumn 只负责存，弹出时由气泡层取）
var _tips: Array = []
var _sig: String = ""


func _ready() -> void:
	add_theme_constant_override("separation", 0)
	# 三行在面板里**垂直居中**：底栏比内容高时，让空白均分到上下，
	# 而不是全堆在下面（看上去像"数值没加载完"）。
	alignment = BoxContainer.ALIGNMENT_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	ensure(3)


## 建出 count 行（默认 3；建筑只有两项时也先建 3 行，多余的隐藏）
func ensure(count: int = 3) -> void:
	if _rows.size() >= count:
		return
	for i in range(_rows.size(), count):
		var idx: int = i
		var row := PanelContainer.new()
		row.name = "数值%d" % i
		row.custom_minimum_size = Vector2(0.0, row_h)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_theme_stylebox_override("panel", _row_style(false))
		row.mouse_entered.connect(func() -> void:
			if row.visible:
				row.add_theme_stylebox_override("panel", _row_style(true)))
		row.mouse_exited.connect(func() -> void:
			row.add_theme_stylebox_override("panel", _row_style(false)))
		add_child(row)
		_rows.append(row)
		_tips.append({})

		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 9)
		hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(hb)

		var ic := Spec.icon("sword", icon_px, Color(0.98, 0.62, 0.42))
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(ic)
		_icons.append(ic)

		var v := Spec.label("-", value_fs, Color(0.98, 0.94, 0.82))
		v.add_theme_font_override("font", Spec.mono_font())
		v.custom_minimum_size = Vector2(value_w, 0.0)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		v.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.88))
		v.add_theme_constant_override("outline_size", 5)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(v)
		_vals.append(v)

		var cap := Spec.label("", Spec.FS_SUB, Color(0.74, 0.72, 0.66))
		cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		cap.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.80))
		cap.add_theme_constant_override("outline_size", 3)
		cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(cap)
		_caps.append(cap)

		# 行间分隔线（最后一行的线由外层铭牌那条金线代替，这里照画不影响）
		var rule := Deco.Rule.new()
		rule.name = "分隔"
		rule.alpha = 0.20
		rule.gem = false
		add_child(rule)
		_rules.append(rule)

		# 弹窗：闭包只读 _tips[idx]，弹出时现取 → 数值永远是最新的
		var host: Node = self
		RtsTipLayer.bind(host, row, func() -> Dictionary:
			return _tips[idx] if idx < _tips.size() else {})


func _row_style(hover: bool) -> StyleBoxFlat:
	var a: Color = Spec.accent()
	if not hover:
		var empty := StyleBoxFlat.new()
		empty.bg_color = Color(0, 0, 0, 0)
		empty.set_corner_radius_all(5)
		empty.content_margin_left = 8.0
		empty.content_margin_right = 8.0
		empty.content_margin_top = 0.0
		empty.content_margin_bottom = 0.0
		return empty
	return Spec.inset_style(Color(a.r * 0.5, a.g * 0.5, a.b * 0.5, 0.13), 5,
			Color(a.r, a.g, a.b, 0.30), 8.0, 0.0)


## 行高随底栏高度变
func set_row_height(h: float) -> void:
	if is_equal_approx(h, row_h):
		return
	row_h = h
	for row in _rows:
		row.custom_minimum_size = Vector2(0.0, row_h)


## 喂三条数据。每条：{icon, name, text, color, tip(Dictionary)}
## 少于 3 条就把多余的行藏起来（建筑常常只有 2 项）。
func feed(stats: Array) -> void:
	ensure(3)
	var sig: String = ""
	for s in stats:
		sig += "%s|%s|%s;" % [String(s.get("icon", "")), String(s.get("text", "")),
				String(s.get("name", ""))]
	if sig == _sig:
		return
	_sig = sig
	for i in _rows.size():
		if i >= stats.size():
			_rows[i].visible = false
			if i < _rules.size():
				_rules[i].visible = false
			continue
		var s: Dictionary = stats[i]
		var col: Color = s.get("color", Color(0.9, 0.88, 0.8))
		_rows[i].visible = true
		if i < _rules.size():
			_rules[i].visible = true
		Spec.set_icon(_icons[i], String(s.get("icon", "sword")), col)
		var txt: String = String(s.get("text", "-"))
		_vals[i].text = txt
		# 超过 4 个字就自动降一档字号：宁可小一点，也不许压到右边的小标上
		_vals[i].add_theme_font_size_override("font_size",
				value_fs if txt.length() <= 4 else int(value_fs * 0.72))
		_vals[i].add_theme_color_override("font_color", col.lerp(Color(1, 1, 1), 0.55))
		_caps[i].text = String(s.get("name", ""))
		_tips[i] = s.get("tip", {})


func clear() -> void:
	_sig = ""
	for i in _rows.size():
		_rows[i].visible = false


func visible_rows() -> int:
	var n: int = 0
	for r in _rows:
		if r.visible:
			n += 1
	return n
