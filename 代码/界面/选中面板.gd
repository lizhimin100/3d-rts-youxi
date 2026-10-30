class_name RtsDossierPanel
extends PanelContainer
## **选中卡（手游横条）** —— 坐在命令条正上方的一条"作战信息带"。
##
## 2026-10-23 重做（按玩家给的参照图，手游思路）：
##   ┌────────┬──────────────────────────────────────┐
##   │        │  农民                        ×5      │
##   │ 头像   │  ⚔ 6    🛡 0    👟 4.3               │
##   │ 88×88  │  ▓▓▓▓▓▓▓▓▓▓▓▓ 血条                  │
##   │        │  ▓▓▓▓▓▓       技能条                │
##   └────────┴──────────────────────────────────────┘
##
## 三个"手游化"决定（和端游那套挤在一起的小字块正好相反）：
##   1. **只留四样**：头像 / 三项数值 / 血条 / 技能条。名字一行、数量一个角标。
##      队列、集结点、研究等级这些"翻菜单才看"的东西一律不进这张卡；
##   2. **数字要大、间距要宽**：数值 20 号等宽、组间距 20px，一眼扫得完；
##   3. 面板高度压到 116，宽度随屏幕，绝不顶到画面中部。
##
## 头像台若在实机里渲染不出东西（SubViewport 空），0.45s 后换成
## "阵营色 + 兵种图标"的静态头像 —— 宁可静，不可空。

const Spec := preload("res://代码/界面/界面规格.gd")

# ===========================================================================
# 版面常量
# ===========================================================================

const PAD := 8.0
## 头像边长（手游：够大但不占地方）
const PORTRAIT_PX := 100.0
## 条高
const BAR_HP := 14.0
const BAR_AB := 9.0
## 头像渲染探测延迟（秒）
const PROBE_DELAY := 0.45


# ===========================================================================
# 内嵌控件：一条极简进度条（血条 / 技能就绪度）
# ===========================================================================

class MiniBar extends Control:
	var ratio: float = 0.0
	var fill: Color = Color(0.42, 0.86, 0.48)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## 相同数值不重绘（HUD 每 0.12s 会调一次 refresh）
	func feed(r: float, col: Color) -> void:
		var v: float = clampf(r, 0.0, 1.0)
		if is_equal_approx(v, ratio) and col == fill:
			return
		ratio = v
		fill = col
		queue_redraw()

	func _draw() -> void:
		var rr := Rect2(Vector2.ZERO, size)
		if rr.size.x < 3.0 or rr.size.y < 3.0:
			return
		draw_rect(rr, Color(0.02, 0.025, 0.032, 0.96), true)
		var w: float = maxf((rr.size.x - 2.0) * ratio, 0.0)
		if w > 0.5:
			draw_rect(Rect2(1.0, 1.0, w, rr.size.y - 2.0), fill, true)
			draw_rect(Rect2(1.0, 1.0, w, maxf((rr.size.y - 2.0) * 0.40, 1.0)),
					Color(1.0, 1.0, 1.0, 0.18), true)
		draw_rect(rr, Color(1.0, 1.0, 1.0, 0.12), false, 1.0)


# ===========================================================================
# 状态
# ===========================================================================

var _accent: Color = Color(0.85, 0.71, 0.36)
var _mono: Font = null
var _built: bool = false
var _compact: bool = false
var _panel_w: float = 560.0
var _h: float = 116.0

## 三项数值：图标 + 数字
var _val: Array[Label] = []
var _val_chip: Array[Panel] = []
## 头像
var _portrait: RtsPortraitStage = null
var _fallback: Panel = null
var _fallback_icon: TextureRect = null
## 血条 / 技能条
var _hp: MiniBar = null
var _ab: MiniBar = null
## 名字 / 数量 / 阵营
var _name: Label = null
var _count_chip: PanelContainer = null
var _count: Label = null
var _fac_dot: Panel = null
var _fac_label: Label = null
var _sub: Label = null

## 空态
var _empty_mode: bool = false
var _empty_tick: float = 0.0
## 头像渲染探测
var _probe_t: float = -1.0
var _probe_on: bool = false
## 镀铬件签名
var _chrome_sig: String = ""
var _root: HBoxContainer = null


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
	add_theme_stylebox_override("panel", Spec.panel_style(10, 0.95, 0.50, PAD))

	_root = HBoxContainer.new()
	_root.name = "横排"
	_root.add_theme_constant_override("separation", 10)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_portrait(_root)
	_build_info(_root)
	_show_empty()


## 左：头像（圆角方框）+ 静态兜底
func _build_portrait(parent: Node) -> void:
	var stack := Control.new()
	stack.name = "头像位"
	stack.custom_minimum_size = Vector2(PORTRAIT_PX, PORTRAIT_PX)
	stack.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(stack)

	_portrait = RtsPortraitStage.new()
	_portrait.name = "头像台"
	_portrait.set_display_size(PORTRAIT_PX)
	stack.add_child(_portrait)

	_fallback = Panel.new()
	_fallback.name = "静态头像"
	_fallback.size = Vector2(PORTRAIT_PX, PORTRAIT_PX)
	_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback.visible = false
	_fallback.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.055, 0.065, 0.088, 0.98), 8,
					Color(_accent.r, _accent.g, _accent.b, 0.30), 0.0, 0.0))
	stack.add_child(_fallback)

	_fallback_icon = TextureRect.new()
	_fallback_icon.name = "兵种图标"
	_fallback_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fallback_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_fallback_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fallback_icon.offset_left = 20.0
	_fallback_icon.offset_top = 20.0
	_fallback_icon.offset_right = -20.0
	_fallback_icon.offset_bottom = -20.0
	_fallback_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback.add_child(_fallback_icon)


## 右：名字行 → 数值行 → 血条 → 技能条（四行，间距宽）
func _build_info(parent: Node) -> void:
	var col := VBoxContainer.new()
	col.name = "信息列"
	col.add_theme_constant_override("separation", 5)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(col)

	# --- 行1：名字 + 阵营点 + 数量 ---
	var title := HBoxContainer.new()
	title.add_theme_constant_override("separation", 8)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title)

	_name = Spec.label("未选中", Spec.FS_VALUE, Spec.text_main())
	_name.name = "名称"
	_name.clip_text = true
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# clip_text 会把最小宽压成 0，HBox 里会被后面的 grow 挤没；给名字留 88px
	_name.custom_minimum_size = Vector2(88.0, 0.0)
	title.add_child(_name)

	_fac_dot = Panel.new()
	_fac_dot.custom_minimum_size = Vector2(9.0, 9.0)
	_fac_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_fac_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_child(_fac_dot)

	_fac_label = Spec.label("", Spec.FS_CAPTION, Spec.text_sub())
	title.add_child(_fac_label)

	_sub = Spec.label("", Spec.FS_CAPTION, Spec.text_dim())
	_sub.clip_text = true
	title.add_child(_sub)

	var grow := Control.new()
	grow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_child(grow)

	_count_chip = PanelContainer.new()
	_count_chip.name = "数量角标"
	_count_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count_chip.visible = false
	_count_chip.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(_accent.r, _accent.g, _accent.b, 0.16), 10,
					Color(_accent.r, _accent.g, _accent.b, 0.55), 8.0, 0.0))
	title.add_child(_count_chip)

	_count = Spec.label("×1", Spec.FS_CAPTION, Color(_accent.r + 0.10, _accent.g + 0.10, _accent.b + 0.10))
	_count_chip.add_child(_count)

	# --- 行2：⚔攻 / 🛡防 / 👟速（横排，间距 20）---
	var stats := HBoxContainer.new()
	stats.name = "数值行"
	stats.add_theme_constant_override("separation", 8)
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(stats)

	for i in 3:
		var chip := Panel.new()
		chip.name = "数值%d" % i
		# 三个数值块**铺满整行**（EXPAND），不再挤在左上角留一大片空白
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.custom_minimum_size = Vector2(0.0, 32.0)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_theme_stylebox_override("panel",
				Spec.inset_style(Color(0.10, 0.115, 0.145, 0.92), 6,
						Color(1, 1, 1, 0.07), 6.0, 0.0))
		stats.add_child(chip)
		_val_chip.append(chip)

		var row := HBoxContainer.new()
		row.set_anchors_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 8.0
		row.offset_right = -8.0
		row.add_theme_constant_override("separation", 6)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(row)

		var ic := Spec.icon(_stat_icon(i), 22.0, _stat_color(i))
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(ic)

		var v := Spec.label("-", Spec.FS_VALUE, Color(0.95, 0.91, 0.77))
		v.add_theme_font_override("font", _mono)
		row.add_child(v)
		_val.append(v)

	# --- 行3/4：血条 + 技能条 ---
	_hp = MiniBar.new()
	_hp.name = "血条"
	_hp.custom_minimum_size = Vector2(0.0, BAR_HP)
	_hp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_hp)

	_ab = MiniBar.new()
	_ab.name = "技能条"
	_ab.custom_minimum_size = Vector2(0.0, BAR_AB)
	_ab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ab.fill = Color(0.36, 0.66, 0.98)
	col.add_child(_ab)


func _stat_icon(i: int) -> String:
	match i:
		0:
			return "sword"
		1:
			return "shield"
		_:
			return "move"


func _stat_color(i: int) -> Color:
	match i:
		0:
			return Color(0.98, 0.62, 0.42)
		1:
			return Color(0.62, 0.78, 0.98)
		_:
			return Color(0.72, 0.88, 0.56)


# ===========================================================================
# 对外
# ===========================================================================

func set_metrics(w: float, h_single: float, _h_multi: float, compact: bool) -> void:
	ensure_built()
	_panel_w = w
	_h = h_single
	_compact = compact
	# 不 reset_size：位置和高度由 HUD 统一摆（reset_size 会把 HUD 的 offset 覆盖掉）
	custom_minimum_size = Vector2(_panel_w, _h)


func desired_height() -> float:
	ensure_built()
	var need: float = _h
	if _root != null:
		need = maxf(need, _root.get_combined_minimum_size().y + PAD * 2.0)
	return maxf(need, get_combined_minimum_size().y)


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

	# --- 镀铬件（名称/阵营/数量）：语义没变就一个字节都不写 ---
	var sig := "%d|%s|%d" % [primary.get_instance_id(),
			String(def.id) if def != null else "?", n]
	if sig != _chrome_sig:
		_chrome_sig = sig
		_name.text = def.display_name if def != null else "未知目标"
		_count_chip.visible = n > 1
		_count.text = "×%d" % n
		_fill_faction(primary)
		_fallback_icon.texture = Spec.icon_tex(_icon_for(def))
		_fallback_icon.modulate = _team_color(primary, def)
		_portrait.show_target(primary, n)
		_show_portrait(true)
		_probe_on = true
		_probe_t = 0.0

	_set_text(_val[0], _fmt(def.attack_damage if def != null else 0.0))
	_set_text(_val[1], _fmt(def.armor if def != null else 0.0))
	_set_text(_val[2], _fmt(def.move_speed if def != null else 0.0))

	var max_hp: float = def.max_hp if def != null and def.max_hp > 0.0 else 1.0
	var hp: float = 100.0
	if primary.get("hp") != null:
		hp = float(primary.get("hp"))
	var ratio: float = clampf(hp / max_hp, 0.0, 1.0)
	_hp.feed(ratio, _hp_color(ratio))
	_ab.feed(_ability_ratio(primary, def), Color(0.36, 0.66, 0.98))

	# 建造进度只在这里露一句（建筑选中时）
	var sub: String = ""
	if def != null and def.is_building():
		var prog: Variant = primary.get("progress")
		if prog != null and float(prog) < 0.999:
			sub = "建造 %d%%" % int(round(float(prog) * 100.0))
	_set_text(_sub, sub)


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
	_refresh_empty()


func _refresh_empty() -> void:
	var pl: RtsFaction = null
	var foe: RtsFaction = null
	if Game != null:
		pl = Game.player_faction
		foe = Game.enemy_faction
	_set_text(_name, "战场")
	_set_text(_val[0], str(pl.units.size() if pl != null else 0))
	_set_text(_val[1], str(foe.units.size() if foe != null else 0))
	_set_text(_val[2], str(pl.buildings.size() if pl != null else 0))
	_hp.feed(0.0, Color(0.42, 0.86, 0.48))
	_ab.feed(0.0, Color(0.36, 0.66, 0.98))


func _process(dt: float) -> void:
	if not _built or not visible:
		return
	if _empty_mode:
		_empty_tick += dt
		if _empty_tick >= 1.0:
			_empty_tick = 0.0
			_refresh_empty()
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

func _ability_ratio(u: Node3D, def: UnitDef) -> float:
	if def == null:
		return 0.0
	if def.abilities.is_empty():
		return 1.0
	var total: float = maxf(def.ability_cooldown, 0.1)
	var cd: Variant = u.get("_ability_cd")
	if cd == null:
		return 0.0
	return clampf(1.0 - float(cd) / total, 0.0, 1.0)


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


func _fill_faction(target: Node3D) -> void:
	var fac: RtsFaction = target.get("faction") as RtsFaction
	var col: Color = _team_color(target, target.get("def") as UnitDef)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(5)
	sb.border_color = Color(0.0, 0.0, 0.0, 0.45)
	sb.set_border_width_all(1)
	_fac_dot.add_theme_stylebox_override("panel", sb)
	_fac_dot.visible = true
	_fac_label.text = fac.display_name if fac != null else "中立"
	_fac_label.add_theme_color_override("font_color", col.lerp(Color(1, 1, 1), 0.25))


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


func _fmt(v: float) -> String:
	if absf(v - roundf(v)) < 0.05:
		return "%d" % int(roundf(v))
	return "%.1f" % v


func _set_text(lb: Label, txt: String) -> void:
	if lb != null and lb.text != txt:
		lb.text = txt