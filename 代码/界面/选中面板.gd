class_name RtsDossierPanel
extends PanelContainer
## **选中卡（魔兽式头像段）** —— 底栏最左段：只剩"这张脸 + 这条命"。
##
## 2026-11-01 第五次改版（玩家口径）：
##   "左边的UI变大、向中间靠拢、里面头像可以更大，下方的血条不要用进度条表示
##    （单位上面有进度条），用魔兽争霸那种 x/x 的方式表达血量和蓝量，
##    且血条蓝条不要有可见的淡黑背景。"
##
##   ┌────────────────────┐
##   │ ┌────────────────┐ │
##   │ │                │ │   头像：跟着底栏高度长到 ~150（原来 114）
##   │ │     头像       │ │   金框 + 四角铆钉（自绘，不占贴图）
##   │ │                │ │
##   │ └────────────────┘ │
##   │  ♥  740 / 740      │   24px 等宽 + 5px 黑边；上限数字压暗一档
##   │  ◆  120 / 200      │   没法力整行收起
##   └────────────────────┘
##
## 三条纪律（改这里之前先读）：
##   1. **不许再出现进度条**：单位头顶已经有血条了，界面里那条只是重复。
##      血量/法力一律 "当前 / 上限" 纯文字，靠颜色（绿→黄→红、蓝）表达比例。
##   2. **不许有可见的底板**：整块面板的 stylebox 是空的，头像框 + 文字黑边
##      直接压在底栏的石面上，没有"又一个黑方块"。
##   3. 名字 / 队色圆点 / 数量 / 数值**都不在这里**：名字和数量在中段铭牌上，
##      攻防速也在中段竖排 —— 这块只回答"这是谁、它还活着吗"。
##   4. 这一块**整块可悬停**：鼠标放上来会解释"这些数字是什么"（RtsTipLayer）。

const Spec := preload("res://代码/界面/界面规格.gd")
const Deco := preload("res://代码/界面/装饰.gd")
const Lex := preload("res://代码/界面/词条.gd")

# ===========================================================================
# 版面常量
# ===========================================================================

const PAD := 3.0
const GAP := 5.0
## 一行 x/x 的高度（24px 字 + 上下呼吸位）
const ROW_H := 32.0
## 头像边长上下限
const PORTRAIT_MIN := 104.0
const PORTRAIT_MAX := 186.0
## 头像外圈金边
const FRAME_W := 2.0
## 头像渲染探测延迟（秒）
const PROBE_DELAY := 0.45
## 数字字号：24 = FS_TITLE（魔兽那张卡里血量也是"大号数字"）
const FS_HP := Spec.FS_TITLE
const FS_MP := Spec.FS_TITLE


# ===========================================================================
# 内嵌控件：一行 "♥ 740 / 740"
# ===========================================================================
class ValueRow extends HBoxContainer:
	var pip: Deco.Pip = null
	var cur: Label = null
	var sep: Label = null
	var mx: Label = null

	func _init(kind: int, fs: int, mono: Font) -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		alignment = BoxContainer.ALIGNMENT_CENTER
		add_theme_constant_override("separation", 4)
		pip = Deco.Pip.new()
		pip.kind = kind
		pip.custom_minimum_size = Vector2(22.0, float(fs) + 4.0)
		pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		add_child(pip)
		cur = _mk(fs, mono, Color(1, 1, 1))
		sep = _mk(fs, mono, Color(0.72, 0.72, 0.68))
		sep.text = "/"
		mx = _mk(fs, mono, Color(0.74, 0.74, 0.70))

	func _mk(fs: int, mono: Font, col: Color) -> Label:
		var l := Label.new()
		l.text = ""
		l.add_theme_font_size_override("font_size", fs)
		l.add_theme_color_override("font_color", col)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		if mono != null:
			l.add_theme_font_override("font", mono)
		# ★ 文字直接压在石面上：5px 黑边是唯一保证"任何地表都读得清"的手段，
		#   有了它就不需要再铺一条淡黑底（那条底就是玩家要删的东西）。
		l.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.92))
		l.add_theme_constant_override("outline_size", 5)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(l)
		return l

	func feed(c: String, m: String, txt_col: Color, pip_col: Color) -> void:
		if cur.text != c:
			cur.text = c
		if mx.text != m:
			mx.text = m
		cur.add_theme_color_override("font_color", txt_col)
		pip.feed(pip.kind, pip_col)


# ===========================================================================
# 状态
# ===========================================================================

var _accent: Color = Color(0.85, 0.71, 0.36)
var _mono: Font = null
var _built: bool = false
var _panel_w: float = 216.0
var _h: float = 200.0
var _portrait_px: float = 140.0
var _compact: bool = false

var _portrait: RtsPortraitStage = null
var _portrait_stack: Control = null
var _fallback: Panel = null
var _fallback_icon: TextureRect = null
var _corners: Control = null
var _hp: ValueRow = null
var _mp: ValueRow = null

var _empty_mode: bool = false
var _probe_t: float = -1.0
var _probe_on: bool = false
var _chrome_sig: String = ""
var _root: VBoxContainer = null
## 当前焦点（弹窗内容要现取，不能缓一份）
var _target: Node3D = null


# ===========================================================================
# 构建
# ===========================================================================

func _ready() -> void:
	ensure_built()


func ensure_built() -> void:
	if _built:
		return
	_built = true
	_accent = Spec.accent()
	_mono = Spec.mono_font()
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(_panel_w, _h)
	# ★ **没有底板**：StyleBoxEmpty 只有一个内边距，画面上什么都不画。
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = 0.0
	sb.content_margin_right = 0.0
	sb.content_margin_top = 0.0
	sb.content_margin_bottom = 0.0
	add_theme_stylebox_override("panel", sb)

	_root = VBoxContainer.new()
	_root.name = "头像列"
	_root.add_theme_constant_override("separation", int(GAP))
	_root.alignment = BoxContainer.ALIGNMENT_CENTER
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_portrait(_root)
	_sync_icon_pad()

	# 整块悬停 = "这是谁"（头像、血量、法力都在这一张说明里）
	RtsTipLayer.bind(self, _portrait_stack, func() -> Dictionary:
		return Lex.portrait(_target) if _target != null and is_instance_valid(_target) else {})
	RtsTipLayer.bind(self, _hp, func() -> Dictionary:
		return Lex.hp(_target) if _target != null and is_instance_valid(_target) else {})
	RtsTipLayer.bind(self, _mp, func() -> Dictionary:
		return Lex.mana(_target) if _target != null and is_instance_valid(_target) else {})

	_show_empty()


## 头像（压边金框 + 四角铆钉）+ **正下方的两行 x/x**
func _build_portrait(parent: Node) -> void:
	_portrait_stack = Control.new()
	_portrait_stack.name = "头像位"
	_portrait_stack.custom_minimum_size = Vector2(_portrait_px, _portrait_px)
	_portrait_stack.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_portrait_stack.mouse_filter = Control.MOUSE_FILTER_PASS
	parent.add_child(_portrait_stack)

	# 外框：深底 + 2px 金边 + 下沿阴影（bevel），头像"镶"在里面
	var frame := Panel.new()
	frame.name = "头像框"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fsb := Spec.bevel_style(Color(0.045, 0.050, 0.062, 0.96), Color(0, 0, 0, 0), 10,
			0.0, 0.0, 0.28)
	fsb.border_color = Color(_accent.r, _accent.g, _accent.b, 0.78)
	fsb.set_border_width_all(int(FRAME_W))
	fsb.shadow_color = Color(0.0, 0.0, 0.0, 0.60)
	fsb.shadow_size = 6
	fsb.shadow_offset = Vector2(0.0, 3.0)
	frame.add_theme_stylebox_override("panel", fsb)
	_portrait_stack.add_child(frame)

	# 四角铆钉 + 内嵌一圈淡金线（"这块是镶上去的"，不是画上去的）
	_corners = Deco.Corners.new()
	_corners.set_anchors_preset(Control.PRESET_FULL_RECT)
	_corners.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait_stack.add_child(_corners)

	_portrait = RtsPortraitStage.new()
	_portrait.name = "头像台"
	_portrait.set_display_size(_portrait_px - FRAME_W * 4.0)
	_portrait.set_anchors_preset(Control.PRESET_FULL_RECT)
	_portrait.offset_left = FRAME_W * 2.0
	_portrait.offset_top = FRAME_W * 2.0
	_portrait.offset_right = -FRAME_W * 2.0
	_portrait.offset_bottom = -FRAME_W * 2.0
	_portrait_stack.add_child(_portrait)

	_fallback = Panel.new()
	_fallback.name = "静态头像"
	_fallback.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fallback.offset_left = FRAME_W * 2.0
	_fallback.offset_top = FRAME_W * 2.0
	_fallback.offset_right = -FRAME_W * 2.0
	_fallback.offset_bottom = -FRAME_W * 2.0
	_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback.visible = false
	_fallback.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.055, 0.065, 0.088, 0.96), 7,
					Color(_accent.r, _accent.g, _accent.b, 0.22), 0.0, 0.0))
	_portrait_stack.add_child(_fallback)

	_fallback_icon = TextureRect.new()
	_fallback_icon.name = "兵种图标"
	_fallback_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fallback_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fallback_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fallback_icon.offset_left = 18.0
	_fallback_icon.offset_top = 18.0
	_fallback_icon.offset_right = -18.0
	_fallback_icon.offset_bottom = -18.0
	_fallback_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback.add_child(_fallback_icon)

	# 生命行（心）与法力行（菱形）—— 纯文字 x/x，没有进度条
	_hp = ValueRow.new(Deco.Pip.HEART, FS_HP, _mono)
	_hp.name = "生命值"
	_hp.custom_minimum_size = Vector2(0.0, ROW_H)
	parent.add_child(_hp)

	_mp = ValueRow.new(Deco.Pip.DIAMOND, FS_MP, _mono)
	_mp.name = "法力值"
	_mp.custom_minimum_size = Vector2(0.0, ROW_H)
	parent.add_child(_mp)


# ===========================================================================
# 对外
# ===========================================================================

func set_metrics(w: float, h_single: float, _h_multi: float, compact: bool) -> void:
	ensure_built()
	_panel_w = w
	_h = h_single
	_compact = compact
	# 头像吃掉"总高 - 两行文字 - 内边距"剩下的全部高度 —— 底栏越高，脸越大。
	var px: float = clampf(_h - (PAD * 2.0 + GAP + ROW_H * 2.0), PORTRAIT_MIN, PORTRAIT_MAX)
	_set_portrait_px(px)
	custom_minimum_size = Vector2(_panel_w, _h)


## 换头像边长（构建后随时可调：底栏高度一变就跟着变）
func _set_portrait_px(px: float) -> void:
	var changed: bool = not is_equal_approx(px, _portrait_px)
	_portrait_px = px
	if _portrait_stack == null:
		return
	if changed or not is_equal_approx(_portrait_stack.custom_minimum_size.x, px):
		_portrait_stack.custom_minimum_size = Vector2(px, px)
		if _portrait != null:
			_portrait.set_display_size(maxf(px - FRAME_W * 4.0, 40.0))
	_sync_icon_pad()


## 兜底图标的留白：线描图标留 ~14%，建筑渲图铺满（它自带留白）
func _sync_icon_pad() -> void:
	if _fallback_icon == null:
		return
	var pad: float = 4.0 if bool(_fallback_icon.get_meta("full_bleed", false)) \
			else maxf(_portrait_px * 0.14, 12.0)
	if is_equal_approx(_fallback_icon.offset_left, pad):
		return
	_fallback_icon.offset_left = pad
	_fallback_icon.offset_top = pad
	_fallback_icon.offset_right = -pad
	_fallback_icon.offset_bottom = -pad


## 内容需要的高度（HUD 用它决定底栏该多高）。
## ★ **不能**把头像算进来：头像边长是"底栏高度反推"的，
##   算进来就形成 内容更高 → 底栏更高 → 头像更大 → 内容更高 的自激循环
##   （以前用 custom_minimum_size 也踩过同一个坑，越涨越高回不去）。
##   这里只报一个和头像无关的下限：104 头像 + 两行 x/x + 呼吸位。
func content_height() -> float:
	ensure_built()
	return 184.0


## 内容需要的宽度：头像才是最宽的那个（血条文字不会超过它）
func content_width() -> float:
	ensure_built()
	var w: float = _portrait_px + 40.0
	if _hp != null:
		w = maxf(w, _hp.get_combined_minimum_size().x + 10.0)
	return clampf(w, 176.0, 300.0)


func desired_height() -> float:
	return maxf(content_height(), _h)


func refresh(units: Array) -> void:
	ensure_built()
	var arr: Array = []
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		arr.append(u)

	if arr.is_empty():
		_target = null
		_show_empty()
		return
	var primary := arr[0] as Node3D
	if primary == null:
		_target = null
		_show_empty()
		return
	_target = primary
	_empty_mode = false
	var def: UnitDef = primary.get("def") as UnitDef
	var n: int = arr.size()

	# --- 头像：语义没变就不动（避免每 0.12s 换贴图抖一下）---
	var sig := "%d|%s" % [primary.get_instance_id(), String(def.id) if def != null else "?"]
	if sig != _chrome_sig:
		_chrome_sig = sig
		# ★ 建筑头像用**美术资产里的建筑图标**（Blender 从 <建筑>.glb 渲的 256² PNG），
		#   不在界面里开 SubViewport 实时渲整栋楼：图标一眼能认，还省一次离屏渲染。
		var is_bld: bool = def != null and def.is_building()
		var btex: Texture2D = Spec.building_icon(def.id) if is_bld else null
		if is_bld:
			if btex != null:
				_fallback_icon.texture = btex
				_fallback_icon.modulate = Color(1, 1, 1, 1)
				_fallback_icon.set_meta("full_bleed", true)
				_sync_icon_pad()
			else:
				_fallback_icon.texture = Spec.icon_tex(_icon_for(def))
				_fallback_icon.modulate = _team_color(primary, def)
				_fallback_icon.set_meta("full_bleed", false)
				_sync_icon_pad()
			_show_portrait(false)
			_probe_on = false
		else:
			_fallback_icon.texture = Spec.icon_tex(_icon_for(def))
			_fallback_icon.modulate = _team_color(primary, def)
			_fallback_icon.set_meta("full_bleed", false)
			_sync_icon_pad()
			_portrait.show_target(primary, n)
			_show_portrait(true)
			_probe_on = true
			_probe_t = 0.0

	var max_hp: float = def.max_hp if def != null and def.max_hp > 0.0 else 1.0
	var hp: float = 100.0
	if primary.get("hp") != null:
		hp = float(primary.get("hp"))
	var ratio: float = clampf(hp / max_hp, 0.0, 1.0)
	_hp.feed("%d" % int(round(hp)), "%d" % int(round(max_hp)),
			_hp_text_color(ratio), _hp_color(ratio))
	# 蓝条 = **法力**。没有法力上限的单位**整行收起**（"没蓝条就不显示"）。
	var has_m: bool = bool(primary.call("has_mana")) if primary.has_method("has_mana") else false
	if _mp.visible != has_m:
		_mp.visible = has_m
	if has_m:
		var mmax: float = float(primary.call("max_mana"))
		var mcur: float = float(primary.get("mana"))
		_mp.feed("%d" % int(round(mcur)), "%d" % int(round(mmax)),
				Color(0.82, 0.91, 1.0), Color(0.36, 0.66, 0.98))


func _show_empty() -> void:
	if _empty_mode:
		return
	_empty_mode = true
	_chrome_sig = ""
	_probe_on = false
	_show_portrait(false)
	_fallback.visible = true
	_fallback_icon.texture = Spec.icon_tex("flag")
	_fallback_icon.modulate = Color(1, 1, 1, 0.5)
	_fallback_icon.set_meta("full_bleed", false)
	_sync_icon_pad()
	_hp.feed("—", "", Spec.text_dim(), Color(0.32, 0.42, 0.36))
	_mp.visible = false


func _process(dt: float) -> void:
	if not _built or not visible:
		return
	if _empty_mode:
		return
	if _probe_on:
		_probe_t += dt
		if _probe_t >= PROBE_DELAY:
			_probe_on = false
			if _portrait != null and not _portrait.probe_rendered():
				_show_portrait(false)


# ===========================================================================
# 头像
# ===========================================================================

func _show_portrait(on: bool) -> void:
	if _portrait != null:
		_portrait.visible = on
		if not on:
			_portrait.clear()
	if _fallback != null:
		_fallback.visible = not on


# ===========================================================================
# 取值
# ===========================================================================

## 生命条的语义色：绿 / 黄 / 红（给心用）
func _hp_color(r: float) -> Color:
	if r <= 0.30:
		return Color(0.96, 0.36, 0.30)
	if r <= 0.60:
		return Color(0.96, 0.76, 0.32)
	return Color(0.46, 0.88, 0.52)


## 生命数字的颜色：**只在半血以下才染色**。满血时保持象牙白，
## 一眼就能把"数字"和"警告"分开（满屏绿字反而没人看）。
func _hp_text_color(r: float) -> Color:
	if r <= 0.30:
		return Color(1.0, 0.72, 0.64)
	if r <= 0.60:
		return Color(1.0, 0.90, 0.66)
	return Color(0.98, 0.97, 0.92)


func _team_color(target: Node3D, def: UnitDef) -> Color:
	var fac: RtsFaction = target.get("faction") as RtsFaction
	if fac != null:
		return fac.color
	if def != null and def.is_harvestable():
		return Spec.gold()
	return Color(0.72, 0.76, 0.82)


## 兵种 → 图标名（兜底盾牌，绝不退回文字）
func _icon_for(def: UnitDef) -> String:
	if def == null:
		return "shield"
	match String(def.id):
		"peasant", "worker":
			return "hammer"
		"footman", "soldier", "swordsman":
			return "sword"
		"archer", "crossbow", "rifleman":
			return "bow"
		"mage", "priest":
			return "staff"
		"townhall", "barracks", "blacksmith", "farm", "tower":
			return "house"
		"goldmine":
			return "coin"
		"tree":
			return "flag"
	return "shield"
