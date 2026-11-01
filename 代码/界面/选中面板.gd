class_name RtsDossierPanel
extends PanelContainer
## **选中卡（魔兽式信息段）** —— 底栏最左段，只剩"这张脸 + 这条命"。
##
## 2026-10-31 三次重做（玩家口径："不仅删玩家文字，队色圆点、步兵这些也要删掉，
## 把血条蓝条和头像放大、更显眼"）：
##   ┌──────────────┐
##   │              │
##   │   3D 头像    │   104²
##   │              │
##   ├──────────────┤
##   │ ▓▓▓ 740/740  │   22 高，带数字与分段刻线
##   │ ▓▓▓▓ 法力    │   10 高（没法力整条收起）
##   └──────────────┘
##
## 于是这块的职责只剩一句话：**这是谁、它还活着吗**。
##   · 名字 / 队色圆点 / 数量角标全部不在这里 —— 名字去中段标题行（单选时），
##     数量去中段标题行（多选时显示"队伍 N"），队色看头像本身；
##   · 数值（攻/防/速）在中段放大了显示，这里不再重复；
##   · 条宽 = 头像宽，一眼就是"这个人的血量"，也不会在宽屏下拉成跑道。
##
## 高度由 HUD 统一灌入（= 底栏内高），面板自己只报 content_height()。

const Spec := preload("res://代码/界面/界面规格.gd")

# ===========================================================================
# 版面常量
# ===========================================================================

const PAD := 8.0
## 头像边长：2026-10-31 从 88 放大到 104（底栏被撑高到 ~166，有地方放）
const PORTRAIT_PX := 104.0
## 血条 / 法力条高度（血条带数字，字号 FS_BODY-2）
const BAR_HP := 22.0
const BAR_AB := 10.0
## 头像渲染探测延迟（秒）
const PROBE_DELAY := 0.45


# ===========================================================================
# 内嵌控件：血条 / 法力条
# ===========================================================================
#
# 魔兽的血条是"深槽 + 硬边填充 + 分段刻线"，不是渐变胶囊。
# 分段刻线（每 10% 一条 1px 暗线）是关键：血条从满掉到 30% 的过程里，
# 刻度提供的是**离散的节奏感**，玩家余光就能读出"还剩几格"。

class MiniBar extends Control:
	var ratio: float = 0.0
	var fill: Color = Color(0.42, 0.86, 0.48)
	## 分段数（0 = 不画刻线；血条 10 / 法力条 0）
	var ticks: int = 10
	## 条内文字（血条显示 "740 / 740"）
	var caption: String = ""
	var _font_size: int = 14

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## 相同数值不重绘（HUD 每 0.12s 会调一次 refresh）
	func feed(r: float, col: Color, cap: String = "") -> void:
		var v: float = clampf(r, 0.0, 1.0)
		if is_equal_approx(v, ratio) and col == fill and cap == caption:
			return
		ratio = v
		fill = col
		caption = cap
		queue_redraw()

	func _draw() -> void:
		var rr := Rect2(Vector2.ZERO, size)
		if rr.size.x < 3.0 or rr.size.y < 3.0:
			return
		# 槽：近黑 + 1px 内描边
		draw_rect(rr, Color(0.015, 0.018, 0.024, 0.98), true)
		var w: float = maxf((rr.size.x - 2.0) * ratio, 0.0)
		if w > 0.5:
			draw_rect(Rect2(1.0, 1.0, w, rr.size.y - 2.0), fill, true)
			# 顶部高光带（上 38% 提亮）：让填充有"金属条"的厚度
			draw_rect(Rect2(1.0, 1.0, w, maxf((rr.size.y - 2.0) * 0.38, 1.0)),
					Color(1.0, 1.0, 1.0, 0.20), true)
			# 右端一条亮边（血量正在掉时这条线在移动，最抓眼）
			draw_rect(Rect2(1.0 + w - 1.5, 1.0, 1.5, rr.size.y - 2.0),
					Color(1.0, 1.0, 1.0, 0.55), true)
		# 分段刻线
		if ticks > 1:
			for i in range(1, ticks):
				var x: float = rr.size.x * float(i) / float(ticks)
				draw_rect(Rect2(x, 1.0, 1.0, rr.size.y - 2.0), Color(0.0, 0.0, 0.0, 0.42), true)
		draw_rect(rr, Color(1.0, 0.96, 0.86, 0.20), false, 1.0)
		if not caption.is_empty():
			var f: Font = get_theme_default_font()
			if f != null:
				var fs: float = float(_font_size)
				var tw: float = f.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x
				# ★ 亮绿/亮红的条身上，白字 + 3px 黑边会糊成一团（黑边把笔画吃掉了）。
				#   现在先铺一条半透明暗底带，再用 2px 黑边 —— 满血绿底上也清清楚楚。
				var pad_x: float = 6.0
				draw_rect(Rect2((rr.size.x - tw) * 0.5 - pad_x, 2.0, tw + pad_x * 2.0,
						rr.size.y - 4.0), Color(0.0, 0.0, 0.0, 0.42), true)
				var pos := Vector2((rr.size.x - tw) * 0.5, rr.size.y * 0.5 + fs * 0.36)
				draw_string_outline(f, pos, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, 2,
						Color(0.0, 0.0, 0.0, 0.90))
				draw_string(f, pos, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size,
						Color(1.0, 1.0, 1.0))


# ===========================================================================
# 状态
# ===========================================================================

var _accent: Color = Color(0.85, 0.71, 0.36)
var _mono: Font = null
var _built: bool = false
var _panel_w: float = 136.0
var _h: float = 158.0

## 头像
var _portrait: RtsPortraitStage = null
var _fallback: Panel = null
var _fallback_icon: TextureRect = null
## 血条 / 法力条
var _hp: MiniBar = null
var _ab: MiniBar = null

## 空态
var _empty_mode: bool = false
var _empty_tick: float = 0.0
## 头像渲染探测
var _probe_t: float = -1.0
var _probe_on: bool = false
## 镀铬件签名
var _chrome_sig: String = ""
var _root: VBoxContainer = null


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
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(_panel_w, _h)
	# 段底：和命令卡**同一种**皮肤（读起来是一整条带子的两段，不是两种面板）
	add_theme_stylebox_override("panel", Spec.segment_style(
			Color(0.088, 0.096, 0.114, 0.92), 8, 8.0, 0.14))

	_root = VBoxContainer.new()
	_root.name = "头像列"
	_root.add_theme_constant_override("separation", 3)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_portrait(_root)
	_show_empty()


## 头像（压边金框）+ **正下方的血条 / 法力条**
func _build_portrait(parent: Node) -> void:
	var stack := Control.new()
	stack.name = "头像位"
	stack.custom_minimum_size = Vector2(PORTRAIT_PX, PORTRAIT_PX)
	stack.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(stack)

	# 外框：深底 + 2px 亮边 + 下沿阴影（bevel），头像"镶"在里面
	var frame := Panel.new()
	frame.name = "头像框"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fsb := Spec.bevel_style(Color(0.045, 0.050, 0.062, 0.98), Color(0, 0, 0, 0), 7, 0.0, 0.0, 0.26)
	fsb.border_color = Color(_accent.r, _accent.g, _accent.b, 0.62)
	fsb.set_border_width_all(2)
	frame.add_theme_stylebox_override("panel", fsb)
	stack.add_child(frame)

	_portrait = RtsPortraitStage.new()
	_portrait.name = "头像台"
	_portrait.set_display_size(PORTRAIT_PX - 8.0)
	_portrait.set_anchors_preset(Control.PRESET_FULL_RECT)
	_portrait.offset_left = 4.0
	_portrait.offset_top = 4.0
	_portrait.offset_right = -4.0
	_portrait.offset_bottom = -4.0
	stack.add_child(_portrait)

	_fallback = Panel.new()
	_fallback.name = "静态头像"
	_fallback.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fallback.offset_left = 4.0
	_fallback.offset_top = 4.0
	_fallback.offset_right = -4.0
	_fallback.offset_bottom = -4.0
	_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback.visible = false
	_fallback.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.055, 0.065, 0.088, 0.98), 5,
					Color(_accent.r, _accent.g, _accent.b, 0.22), 0.0, 0.0))
	stack.add_child(_fallback)

	_fallback_icon = TextureRect.new()
	_fallback_icon.name = "兵种图标"
	_fallback_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fallback_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fallback_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fallback_icon.offset_left = 14.0
	_fallback_icon.offset_top = 14.0
	_fallback_icon.offset_right = -14.0
	_fallback_icon.offset_bottom = -14.0
	_fallback_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback.add_child(_fallback_icon)

	# 血条（带头像同宽 + 数字 + 刻线）与法力条
	_hp = MiniBar.new()
	_hp.name = "血条"
	_hp.ticks = 10
	_hp._font_size = Spec.FS_BODY - 2
	_hp.custom_minimum_size = Vector2(PORTRAIT_PX, BAR_HP)
	_hp.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	parent.add_child(_hp)

	_ab = MiniBar.new()
	_ab.name = "技能条"
	_ab.ticks = 0
	_ab._font_size = Spec.FS_CAPTION - 2
	_ab.custom_minimum_size = Vector2(PORTRAIT_PX, BAR_AB)
	_ab.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_ab.fill = Color(0.36, 0.66, 0.98)
	parent.add_child(_ab)


# ===========================================================================
# 对外
# ===========================================================================

func set_metrics(w: float, h_single: float, _h_multi: float, _compact: bool) -> void:
	ensure_built()
	_panel_w = w
	_h = h_single
	# 不 reset_size：位置和高度由 HUD 统一摆（reset_size 会把 HUD 的 offset 覆盖掉）
	custom_minimum_size = Vector2(_panel_w, _h)


## 内容需要的高度（HUD 用它决定底栏该多高）。
## 注意**不能**用 custom_minimum_size：那是 HUD 自己灌进来的，会自我循环越涨越高。
func content_height() -> float:
	ensure_built()
	var need: float = _root.get_combined_minimum_size().y + PAD * 2.0 + 8.0
	return clampf(need, 120.0, 190.0)


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
		_show_empty()
		return
	var primary := arr[0] as Node3D
	if primary == null:
		_show_empty()
		return
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
				_set_fallback_pad(4.0)
			else:
				_fallback_icon.texture = Spec.icon_tex(_icon_for(def))
				_fallback_icon.modulate = _team_color(primary, def)
				_set_fallback_pad(18.0)
			_show_portrait(false)
			_probe_on = false
		else:
			_fallback_icon.texture = Spec.icon_tex(_icon_for(def))
			_fallback_icon.modulate = _team_color(primary, def)
			_set_fallback_pad(18.0)
			_portrait.show_target(primary, n)
			_show_portrait(true)
			_probe_on = true
			_probe_t = 0.0

	var max_hp: float = def.max_hp if def != null and def.max_hp > 0.0 else 1.0
	var hp: float = 100.0
	if primary.get("hp") != null:
		hp = float(primary.get("hp"))
	var ratio: float = clampf(hp / max_hp, 0.0, 1.0)
	_hp.feed(ratio, _hp_color(ratio), "%d / %d" % [int(round(hp)), int(round(max_hp))])
	# 蓝条 = **法力**。没有法力上限的单位**整条收起**（"没蓝条就不显示"）。
	var has_m: bool = bool(primary.call("has_mana")) if primary.has_method("has_mana") else false
	if _ab.visible != has_m:
		_ab.visible = has_m
	if has_m:
		var mmax: float = float(primary.call("max_mana"))
		var mcur: float = float(primary.get("mana"))
		var mr: float = clampf(mcur / maxf(mmax, 1.0), 0.0, 1.0)
		_ab.feed(mr, Color(0.36, 0.66, 0.98), "%d / %d" % [int(round(mcur)), int(round(mmax))])


func _show_empty() -> void:
	if _empty_mode:
		_refresh_empty()
		return
	_empty_mode = true
	_chrome_sig = ""
	_probe_on = false
	_show_portrait(false)
	_fallback.visible = true
	_fallback_icon.texture = Spec.icon_tex("flag")
	_fallback_icon.modulate = Color(1, 1, 1, 0.55)
	_set_fallback_pad(18.0)
	_refresh_empty()


func _refresh_empty() -> void:
	_hp.feed(0.0, Color(0.32, 0.42, 0.36), "")
	_ab.feed(0.0, Color(0.36, 0.66, 0.98))


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

## 头像兜底层的内边距：建筑渲图自带留白，铺满更好看；线条图标要留 18px 才不顶框
func _set_fallback_pad(pad: float) -> void:
	if _fallback_icon == null:
		return
	_fallback_icon.offset_left = pad
	_fallback_icon.offset_top = pad
	_fallback_icon.offset_right = -pad
	_fallback_icon.offset_bottom = -pad


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

func _hp_color(r: float) -> Color:
	if r <= 0.30:
		return Color(0.94, 0.34, 0.28)
	if r <= 0.60:
		return Color(0.94, 0.74, 0.30)
	return Color(0.42, 0.86, 0.48)


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
