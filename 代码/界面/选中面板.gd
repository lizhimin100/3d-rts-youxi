class_name RtsDossierPanel
extends PanelContainer
## **选中卡（魔兽式信息段）** —— 底栏左段，和右边的命令卡**等高同底**。
##
## 2026-10-31 重做（对齐魔兽争霸三的单位信息面板）：
##   ┌───────┬────────────────────────────────────────┬─────────────────┐
##   │       │ 步兵   ●玩家   ×4                      │ ▣ ▣ ▣ ▣ ▣ ▣     │
##   │ 3D头像│ ⚔15   🛡5   👟4.6                      │ ▣ ▣ ▣           │
##   │  92²  │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 740/740                │（同队单位小头像）│
##   │       │ ▓▓▓▓▓▓ 技能就绪                         │                 │
##   └───────┴────────────────────────────────────────┴─────────────────┘
##
## 四个决定：
##   1. **只留四样**：头像 / 三项数值 / 血条 / 技能条。名字一行、数量一个角标。
##   2. **多选不再只剩一个 ×N**：右边铺一排小头像（最多 12 个），
##      魔兽的多选面板就是这么干的 —— 一眼看出"我框到了谁"。
##   3. **血条带数字与分段刻线**：单色长条在战场上一片糊，加了刻线才有"血量在掉"的
##      体感；数字用等宽字体，避免宽度跳动。
##   4. 高度由 HUD 统一灌入（= 底栏内高），面板自己只报 content_height()。

const Spec := preload("res://代码/界面/界面规格.gd")

# ===========================================================================
# 版面常量
# ===========================================================================

const PAD := 8.0
## 头像边长（魔兽式：够大，一眼认脸）
const PORTRAIT_PX := 88.0
## 条高
const BAR_HP := 18.0
const BAR_AB := 8.0
## 同队小头像边长 / 最多几个
const SQUAD_PX := 40.0
const SQUAD_MAX := 12
## 2026-10-31：底栏中段新增了「队伍网格」（最多 24 个 + 翻页），
## 这里的同队小头像就成了重复信息 —— 关掉它，把宽度让给"名字 + 血条 + 蓝条"。
const SHOW_SQUAD := false
## 头像渲染探测延迟（秒）
const PROBE_DELAY := 0.45
## 信息列的宽度：**固定档**，不跟着面板拉伸。
## 底栏拉到 1000 宽以后，血条跟着铺满会变成一条"机场跑道"——
## 魔兽的血条永远只有两三百像素。多出来的宽度让给同队小头像。
const INFO_W := 380.0


# ===========================================================================
# 内嵌控件：血条 / 技能条
# ===========================================================================
#
# 魔兽的血条是"深槽 + 硬边填充 + 分段刻线"，不是渐变胶囊。
# 分段刻线（每 10% 一条 1px 暗线）是关键：血条从满掉到 30% 的过程里，
# 刻度提供的是**离散的节奏感**，玩家余光就能读出"还剩几格"。

class MiniBar extends Control:
	var ratio: float = 0.0
	var fill: Color = Color(0.42, 0.86, 0.48)
	## 分段数（0 = 不画刻线；血条 10 / 技能条 0）
	var ticks: int = 10
	## 条内文字（血条显示 "740 / 740"）
	var caption: String = ""
	var _font_size: int = 12

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
				var pos := Vector2((rr.size.x - tw) * 0.5, rr.size.y * 0.5 + fs * 0.36)
				draw_string_outline(f, pos, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, 3,
						Color(0.0, 0.0, 0.0, 0.85))
				draw_string(f, pos, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size,
						Color(0.98, 0.97, 0.93))


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
## 信息列（限宽用）
var _info: VBoxContainer = null
## 同队小头像
var _squad: GridContainer = null
var _squad_order: Array[int] = []

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
	# 段底：和命令卡**同一种**皮肤（读起来是一整条带子的两段，不是两种面板）
	add_theme_stylebox_override("panel", Spec.segment_style(
			Color(0.088, 0.096, 0.114, 0.92), 8, 8.0, 0.14))

	_root = HBoxContainer.new()
	_root.name = "横排"
	_root.add_theme_constant_override("separation", 10)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_portrait(_root)
	_build_info(_root)
	# 弹性留白：把"同队小头像"推到段的最右侧（紧挨命令卡）。
	# 这样底栏拉宽时，宽出来的部分是**头像列在往右撑**，而不是中间空一块。
	var spacer := Control.new()
	spacer.name = "留白"
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(spacer)
	_build_squad(_root)
	_show_empty()


## 左：头像（压边金框）+ 静态兜底
func _build_portrait(parent: Node) -> void:
	var stack := Control.new()
	stack.name = "头像位"
	stack.custom_minimum_size = Vector2(PORTRAIT_PX, PORTRAIT_PX)
	stack.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(stack)

	# 外框：深底 + 1px 亮边 + 下沿阴影（bevel），头像"镶"在里面
	var frame := Panel.new()
	frame.name = "头像框"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fsb := Spec.bevel_style(Color(0.045, 0.050, 0.062, 0.98), Color(0, 0, 0, 0), 7, 0.0, 0.0, 0.26)
	fsb.border_color = Color(_accent.r, _accent.g, _accent.b, 0.55)
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
	_fallback_icon.offset_left = 18.0
	_fallback_icon.offset_top = 18.0
	_fallback_icon.offset_right = -18.0
	_fallback_icon.offset_bottom = -18.0
	_fallback_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback.add_child(_fallback_icon)


## 中：名字行 → 数值行 → 血条 → 技能条
func _build_info(parent: Node) -> void:
	var col := VBoxContainer.new()
	col.name = "信息列"
	col.add_theme_constant_override("separation", 3)
	col.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.custom_minimum_size = Vector2(INFO_W, 0.0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(col)
	_info = col

	# --- 行1：名字 + 阵营点 + 数量 ---
	var title := HBoxContainer.new()
	title.add_theme_constant_override("separation", 7)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title)

	_name = Spec.label("未选中", Spec.FS_TITLE, Spec.text_main())
	_name.name = "名称"
	_name.clip_text = true
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# clip_text 会把最小宽压成 0，HBox 里会被后面的 grow 挤没；给名字留 88px
	_name.custom_minimum_size = Vector2(88.0, 0.0)
	title.add_child(_name)

	# 数量角标紧贴名字（"步兵 ×4" 是一个整体词）；以前放在行尾、中间隔一条
	# 大空白，读起来像两个不相干的东西。
	_count_chip = PanelContainer.new()
	_count_chip.name = "数量角标"
	_count_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_count_chip.visible = false
	_count_chip.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(_accent.r, _accent.g, _accent.b, 0.18), 9,
					Color(_accent.r, _accent.g, _accent.b, 0.62), 8.0, 0.0))
	title.add_child(_count_chip)

	_count = Spec.label("×1", Spec.FS_CAPTION,
			Color(minf(_accent.r + 0.12, 1.0), minf(_accent.g + 0.12, 1.0), minf(_accent.b + 0.12, 1.0)))
	_count.add_theme_font_override("font", _mono)
	_count_chip.add_child(_count)

	_fac_dot = Panel.new()
	_fac_dot.custom_minimum_size = Vector2(9.0, 9.0)
	_fac_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_fac_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_child(_fac_dot)

	_fac_label = Spec.label("", Spec.FS_CAPTION, Spec.text_sub())
	_fac_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title.add_child(_fac_label)

	_sub = Spec.label("", Spec.FS_CAPTION, Spec.text_dim())
	_sub.clip_text = true
	_sub.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title.add_child(_sub)

	var grow := Control.new()
	grow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_child(grow)

	# --- 行2：⚔攻 / 🛡防 / 👟速（三块等宽铭牌）---
	var stats := HBoxContainer.new()
	stats.name = "数值行"
	stats.add_theme_constant_override("separation", 6)
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(stats)

	for i in 3:
		var chip := Panel.new()
		chip.name = "数值%d" % i
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		chip.custom_minimum_size = Vector2(0.0, 26.0)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 铭牌：比面板再深一档 + 顶亮底暗的压边
		chip.add_theme_stylebox_override("panel",
				Spec.bevel_style(Color(0.062, 0.070, 0.086, 0.95), Color(0, 0, 0, 0), 4,
						6.0, 0.0, 0.08))
		stats.add_child(chip)
		_val_chip.append(chip)

		var row := HBoxContainer.new()
		row.set_anchors_preset(Control.PRESET_FULL_RECT)
		row.offset_left = 7.0
		row.offset_right = -6.0
		row.add_theme_constant_override("separation", 5)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.add_child(row)

		var ic := Spec.icon(_stat_icon(i), 18.0, _stat_color(i))
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(ic)

		var v := Spec.label("-", Spec.FS_VALUE, Color(0.96, 0.92, 0.79))
		v.add_theme_font_override("font", _mono)
		v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(v)
		_val.append(v)

	# --- 行3/4：血条（带数字与刻线）+ 技能条 ---
	_hp = MiniBar.new()
	_hp.name = "血条"
	_hp.ticks = 10
	_hp._font_size = Spec.FS_CAPTION
	_hp.custom_minimum_size = Vector2(0.0, BAR_HP)
	_hp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_hp)

	_ab = MiniBar.new()
	_ab.name = "技能条"
	_ab.ticks = 0
	_ab.custom_minimum_size = Vector2(0.0, BAR_AB)
	_ab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ab.fill = Color(0.36, 0.66, 0.98)
	col.add_child(_ab)


## 右：同队单位小头像（多选时铺开；单选时整块收起）
func _build_squad(parent: Node) -> void:
	_squad = GridContainer.new()
	_squad.name = "同队"
	_squad.columns = 6
	_squad.add_theme_constant_override("h_separation", 3)
	_squad.add_theme_constant_override("v_separation", 3)
	_squad.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_squad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_squad.visible = false
	parent.add_child(_squad)


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
	_apply_width_policy()


## 内容需要的高度（HUD 用它决定底栏该多高）。
## 注意**不能**用 custom_minimum_size：那是 HUD 自己灌进来的，会自我循环越涨越高。
func content_height() -> float:
	ensure_built()
	var need: float = _root.get_combined_minimum_size().y + 8.0 * 2.0 + 8.0
	return clampf(need, 104.0, 150.0)


func desired_height() -> float:
	return maxf(content_height(), _h)


## 窄面板（1024 档）藏掉小头像列，把宽度全留给血条
func _apply_width_policy() -> void:
	if _squad == null or _info == null:
		return
	var narrow: bool = _panel_w < 700.0
	_squad.set_meta("blocked", narrow)
	_squad.visible = _squad.visible and not narrow
	# 信息列宽：宽屏吃 INFO_W，窄屏按面板 55% 收（别再挤出面板）
	var w: float = INFO_W if not narrow else clampf(_panel_w * 0.52, 150.0, INFO_W)
	_info.custom_minimum_size = Vector2(w, 0.0)


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
		_sync_squad(arr)

	_set_text(_val[0], _fmt(def.attack_damage if def != null else 0.0))
	_set_text(_val[1], _fmt(def.armor if def != null else 0.0))
	_set_text(_val[2], _fmt(def.move_speed if def != null else 0.0))

	var max_hp: float = def.max_hp if def != null and def.max_hp > 0.0 else 1.0
	var hp: float = 100.0
	if primary.get("hp") != null:
		hp = float(primary.get("hp"))
	var ratio: float = clampf(hp / max_hp, 0.0, 1.0)
	_hp.feed(ratio, _hp_color(ratio), "%d / %d" % [int(round(hp)), int(round(max_hp))])
	# 蓝条 = **法力**（参考图上的第二条）。没有法力上限的单位**整条收起** ——
	# 这正是"没蓝条就不显示"。有法力的单位再在上面叠一层技能冷却的暗条。
	var has_m: bool = bool(primary.call("has_mana")) if primary.has_method("has_mana") else false
	if _ab.visible != has_m:
		_ab.visible = has_m
	if has_m:
		var mmax: float = float(primary.call("max_mana"))
		var mcur: float = float(primary.get("mana"))
		var mr: float = clampf(mcur / maxf(mmax, 1.0), 0.0, 1.0)
		_ab.feed(mr, Color(0.36, 0.66, 0.98), "%d / %d 法力" % [int(round(mcur)), int(round(mmax))])

	# 建造进度只在这里露一句（建筑选中时）
	var sub: String = ""
	if def != null and def.is_building():
		var prog: Variant = primary.get("progress")
		if prog != null and float(prog) < 0.999:
			sub = "建造 %d%%" % int(round(float(prog) * 100.0))
	_set_text(_sub, sub)


## 多选小头像：按选中顺序铺，最多 SQUAD_MAX 个；同兵种共用同一张图标
func _sync_squad(arr: Array) -> void:
	if _squad == null:
		return
	if not SHOW_SQUAD:
		_squad.visible = false
		return
	var ids: Array[int] = []
	for i in mini(arr.size(), SQUAD_MAX):
		ids.append(arr[i].get_instance_id())
	if ids == _squad_order:
		return
	_squad_order = ids
	for c in _squad.get_children():
		_squad.remove_child(c)
		c.queue_free()
	var blocked: bool = bool(_squad.get_meta("blocked", false))
	_squad.visible = arr.size() > 1 and not blocked
	if not _squad.visible:
		return
	for i in mini(arr.size(), SQUAD_MAX):
		var u := arr[i] as Node3D
		if u == null:
			continue
		var d: UnitDef = u.get("def") as UnitDef
		var team: Color = _team_color(u, d)
		var cell := Panel.new()
		cell.custom_minimum_size = Vector2(SQUAD_PX, SQUAD_PX)
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sb := Spec.bevel_style(Color(0.058, 0.066, 0.082, 0.96), Color(0, 0, 0, 0), 4,
				0.0, 0.0, 0.07)
		sb.border_color = Color(team.r, team.g, team.b, 0.32)
		cell.add_theme_stylebox_override("panel", sb)
		_squad.add_child(cell)

		# 底边一条**血条**（不是纯色条）：多选时 12 个小格里谁残血一眼看得出
		var bar_bg := ColorRect.new()
		bar_bg.color = Color(0.02, 0.024, 0.03, 0.92)
		bar_bg.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		bar_bg.offset_top = -5.0
		bar_bg.offset_left = 4.0
		bar_bg.offset_right = -4.0
		bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(bar_bg)

		var hp: float = 1.0
		var hp_max: float = d.max_hp if d != null else 1.0
		if u.get("hp") != null:
			hp = clampf(float(u.get("hp")) / maxf(hp_max, 0.001), 0.0, 1.0)
		var bar := ColorRect.new()
		bar.color = _hp_color(hp)
		bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		bar.offset_top = -4.0
		bar.offset_left = 4.0
		bar.offset_right = -(4.0 + (1.0 - hp) * (SQUAD_PX - 8.0))
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(bar)

		var icon := TextureRect.new()
		icon.texture = Spec.icon_tex(_icon_for(d))
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 7.0
		icon.offset_top = 5.0
		icon.offset_right = -7.0
		icon.offset_bottom = -9.0
		icon.modulate = team.lerp(Color(1.0, 0.99, 0.95), 0.62)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(icon)


func _show_empty() -> void:
	if _empty_mode:
		_refresh_empty()
		return
	_empty_mode = true
	_chrome_sig = ""
	_probe_on = false
	if _squad != null:
		_squad.visible = false
		_squad_order.clear()
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
	_hp.feed(0.0, Color(0.42, 0.86, 0.48), "")
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
