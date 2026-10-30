class_name RtsHud
extends CanvasLayer
## **HUD（HAWKEYE）**：全部用代码构建（文档 §8 明确不写 .tscn，避免布局脆弱）
##
## 版面（四角对齐 + 8px 栅格，任务书 §3.2）：
##   左上     资源条：金币 / 木材 / 人口（三枚等宽胶囊 + 人口微条）
##   顶部中   提示消息（最多 3 条、淡出；窄屏自动让到资源条下方，不压顶栏）
##   左下     小地图（RtsMinimap：地形底图 + 视野框 + 图例 + 取景角）
##   中下     选中面板：单个建筑 → 建筑面板；其余 → 档案板（两套版式按可见性切换）
##   右下     命令卡（RtsCommandCard：4×3 指令格，未选中时是操作引导）
##   选中面板上方  等待落点提示（"左键选择建造位置…"）
##   全屏     结束遮罩：胜/败 + 用时 + 击杀 + 「重新开始」
##
## 三条纪律：
##   1. **尺寸只从 界面规格.gd 的 metrics() 来**：窗口变化时统一重算、重摆一遍，
##      所以 1024×768 ~ 1920×1080 都不会出现面板互压；
##   2. 字号只有 12/14/16/18/24/28 六级，层级靠"字号 + 颜色明度"两级表达；
##   3. 中文字体：优先美术主题（ArtKit.load_theme），没有就 SystemFont 兜底 ——
##      **必须保证中文能显示**，否则一屏方块，验收直接不过。

const Spec := preload("res://代码/界面/界面规格.gd")

## 界面刷新间隔（秒）：不跟渲染帧空转
const REFRESH_INTERVAL := 0.12
## 提示消息最多同时留几条
const TOAST_MAX := 3
## 提示消息淡出时长（秒）
const TOAST_FADE := 0.55

## 建筑面板脚本（用 preload 而不是直接写 class_name：新类还没进全局 class 缓存时也能跑）
const BUILDING_PANEL_SCRIPT := preload("res://代码/界面/建筑面板.gd")

## 界面根节点（承载 theme，铺满视口）
var root: Control = null

## 当前版面尺寸（窗口变化时重算）
var _mets = null
var _last_vp: Vector2 = Vector2.ZERO
## 反拉伸系数：工程用 canvas_items 拉伸（1920×1080 基准），小窗口下 2D 会被整体缩小。
## 这里按 1/缩放 把界面根放大回去，使 UI 在 1024×768 与 1920×1080 上都是同一套"物理像素"尺寸。
var _zoom: float = 1.0

## 顶部资源
var _stats_panel: PanelContainer = null
var _gold_label: Label = null
var _wood_label: Label = null
var _food_label: Label = null
var _pop_bar: MiniBar = null
## 人口条是否已满（只在翻转时改颜色，见 _refresh_stats）
var _food_full: bool = false

## 提示消息容器
var _toast_box: VBoxContainer = null

## 小地图
var _minimap: RtsMinimap = null
## 副官开关（小地图正下方一条）
var _adj_btn: Button = null
var _adjutant: Node = null
## 主菜单（小地图下方）：设置 / 队伍 / 投降
var _menu_btn: Button = null
var _menu: PopupMenu = null
var _dlg_settings: AcceptDialog = null
var _dlg_team: AcceptDialog = null
var _dlg_surrender: ConfirmationDialog = null
var _vol_slider: HSlider = null
var _adj_check: CheckButton = null
## 战斗计时（资源条末段）
var _time_label: Label = null

## 选中信息
var _sel_panel: PanelContainer = null
## **BASALT 档案板**：3D 头像 + 名称 + 生命 + 数值 + 多选格子（见 选中面板.gd）
var _dossier: RtsDossierPanel = null
## **建筑面板**：选中单个建筑时的专属版式（训练 / 集结点 / 研究，见 建筑面板.gd）
var _building_panel: PanelContainer = null
## 当前选中面板高度（单位单选 / 多选 / 建筑三种版式各不相同）
var _sel_h: float = 216.0
## 选中面板当前的左边界（响应式时会被夹在小地图和命令卡之间）
var _sel_left: float = 0.0
## 选中卡实际宽度（贴左下、吃满到命令卡左缘）
var _sel_w: float = 0.0
## **ECHO 触感回声**：点选圆环 / 右键涟漪（见 触感回声.gd）
var _echo: RtsEchoFx = null
## **GLYPH 光标符文**：按悬停对象换图标（见 光标术.gd）
var _glyph: RtsGlyphCursor = null

## 右侧竖排快捷选择（全选 / 取消）
var _side_box: VBoxContainer = null
## 命令卡（_card_h_applied 记录"上一次用于摆位的高度"，用来发现行数变化）
var _card_h_applied: float = 0.0
var _card: RtsCommandCard = null
var _card_panel: PanelContainer = null
var _card_sig: String = ""

## 等待落点提示
var _pending_box: PanelContainer = null
var _pending_label: Label = null

## 结束遮罩
var _overlay: ColorRect = null
var _over_title: Label = null
var _over_sub: Label = null
var _over_kills: Label = null

## 当前选中（指向真实节点，刷新时判空）
var _selection: Array = []

## 刷新计时 / 缓存签名
var _clock: float = 0.0
var _sel_sig: String = ""


# ===========================================================================
# 内嵌小控件
# ===========================================================================

## 一条 48×6 的微缩进度条（人口用）
class MiniBar extends Control:
	var ratio: float = 0.0
	var color: Color = Color(0.72, 0.86, 0.95)
	var warn: bool = false

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_ratio(r: float, is_warn: bool = false) -> void:
		var v: float = clampf(r, 0.0, 1.0)
		if absf(v - ratio) < 0.004 and is_warn == warn:
			return
		ratio = v
		warn = is_warn
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		if r.size.x < 3.0 or r.size.y < 4.0:
			return
		draw_rect(r, Color(0.0, 0.0, 0.0, 0.66), true)
		var col: Color = Color(0.96, 0.42, 0.34) if warn else color
		var w: float = maxf((r.size.x - 2.0) * ratio, 0.0)
		if w > 0.5:
			draw_rect(Rect2(1.0, 1.0, w, r.size.y - 2.0), col, true)
		draw_rect(r, Color(1.0, 1.0, 1.0, 0.10), false, 1.0)


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	layer = 1
	root = Control.new()
	root.name = "界面根"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = _build_theme()
	add_child(root)
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 实测踩坑：直接挂在 CanvasLayer 下的 Control，光靠 full-rect 锚点**未必拿到尺寸**
	# （开局量到 size=(0,0)，于是小地图被算到屏幕外、提示贴左边缘被裁）。
	# 所以下面所有子控件都按 root 的锚点排布，而 root 的尺寸**显式同步**，不赌引擎时序。
	_recompute_metrics()
	_sync_root_size()

	_build_stats()
	_build_toasts()
	_build_minimap()
	_build_selection_panel()
	_build_card()
	_build_pending_label()
	_build_side_actions()
	_build_overlay()
	_install_fx()
	_apply_layout()

	# --- 信号 ---
	Game.resources_changed.connect(_on_resources_changed)
	Game.selection_changed.connect(_on_selection_changed)
	Game.notify.connect(_on_notify)
	Game.game_over.connect(_on_game_over)

	_refresh_stats()
	_refresh_selection()
	_refresh_card(true)
	_qa_select_hook()
	_qa_extra_hooks()
	if OS.has_environment("UI_AUDIT"):
		_ui_audit()


## 临时版面审计（本机 QA 用，UI_AUDIT=1 才跑）：越界 / 溢出父容器 / 文字被裁，全打出来
func _ui_audit() -> void:
	await get_tree().create_timer(2.5).timeout
	var out := PackedStringArray()
	_audit_node(root, out, Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size))
	for s in out:
		print("[AUDIT] ", s)
	print("[AUDIT] done issues=", out.size())


func _audit_node(n: Node, out: PackedStringArray, screen: Rect2) -> void:
	for c in n.get_children():
		var cc := c as Control
		if cc == null:
			_audit_node(c, out, screen)
			continue
		if not cc.is_visible_in_tree():
			continue
		var r := cc.get_global_rect()
		if not screen.grow(1.0).encloses(r):
			out.append("OUT-OF-SCREEN %s rect=%s" % [str(cc.get_path()), str(r)])
		var pc := n as Control
		if pc != null and n is Container and not pc.get_global_rect().grow(1.5).encloses(r):
			out.append("OVERFLOW-PARENT %s parent=%s rect=%s prect=%s" % [str(cc.get_path()), str(n.name), str(r), str(pc.get_global_rect())])
		if cc is Label:
			var lb := cc as Label
			if not lb.clip_text and lb.text_overrun_behavior == TextServer.OVERRUN_NO_TRIMMING:
				var need: float = lb.get_minimum_size().x
				if need > lb.size.x + 2.0:
					out.append("TEXT-WIDE %s need=%.0f have=%.0f text=%s" % [str(lb.get_path()), need, lb.size.x, lb.text.substr(0, 14)])
		_audit_node(cc, out, screen)


func _process(delta: float) -> void:
	var vp := get_viewport()
	var vp_size: Vector2 = vp.get_visible_rect().size if vp != null else Vector2(1600.0, 900.0)
	var z: float = 1.0
	if vp != null:
		# 反拉伸上限 1.35：旧值 2.2 是"物理像素等大"的思路，在 960×540 的手机会把
		# 整块 HUD 放到占屏一半高。小屏要的是**相对更小**，不是等大。
		z = clampf(1.0 / maxf(vp.get_screen_transform().get_scale().x, 0.2), 1.0, 1.35)
	if vp_size != _last_vp or absf(z - _zoom) > 0.001:
		_recompute_metrics()
		_apply_layout()
	_sync_root_size()
	_clock += delta
	if _clock < REFRESH_INTERVAL:
		return
	_clock = 0.0
	_refresh_stats()
	_refresh_selection()
	_refresh_pending()
	_refresh_card(false)
	# 容器的最小尺寸要等控件重排后才算准（命令卡行数变了尤其明显）。
	# 每 0.12s 比对一次"实际高度 vs 最小高度"，差 1px 就重摆 —— 右下角不会被裁半行。
	if _card_panel != null and _card_panel.visible:
		if OS.has_environment("UI_DEBUG"):
			print("[CARD] h=%.1f applied=%.1f panelmin=%.1f panelsize=%s cardsize=%s cardmin=%s rows=%d" % [
				_card_height(), _card_h_applied,
				_card_panel.get_combined_minimum_size().y, str(_card_panel.size), str(_card.size),
				str(_card.custom_minimum_size), int(_card.call("_row_count"))])
		if absf(_card_height() - _card_h_applied) > 1.0:
			_apply_layout()


## 把界面根节点铺满视口。
## 注意：这里**改 offset，不改 size**——根节点挂的是 full-rect 锚点（左右/上下锚点不相等），
## 直接给 size 会被引擎在 _ready 之后按锚点重算，还会打一条 "size overridden" 警告。
## 按 offset = 期望尺寸 - 父区域尺寸 来算，就和锚点公式自洽了。
func _sync_root_size() -> void:
	if root == null:
		return
	var vp := get_viewport()
	if vp == null:
		return
	var want: Vector2 = vp.get_visible_rect().size
	if want.x < 1.0 or want.y < 1.0:
		return
	want /= _zoom
	root.scale = Vector2(_zoom, _zoom)
	var area: Vector2 = root.get_parent_area_size()
	var orr: float = want.x - area.x
	var ob: float = want.y - area.y
	if root.offset_left != 0.0 or root.offset_top != 0.0 \
			or absf(root.offset_right - orr) > 0.5 or absf(root.offset_bottom - ob) > 0.5:
		root.offset_left = 0.0
		root.offset_top = 0.0
		root.offset_right = orr
		root.offset_bottom = ob


# ===========================================================================
# 版面：一组尺寸 + 一次摆位
# ===========================================================================

## 按当前视口重算版面尺寸。
## 关键：Godot 的 canvas_items 拉伸会把整套 2D 按窗口/基准等比缩放，
## 于是 1024 窗口下 14 号字只剩 7.5 物理像素。这里反算 _zoom = 1/缩放，
## 让 HUD 用"设计像素"排版，再整体放大 —— 四个分辨率下字号/边距的物理尺寸一致。
func _recompute_metrics() -> void:
	var vp := get_viewport()
	var vp_size: Vector2 = vp.get_visible_rect().size if vp != null else Vector2(1600.0, 900.0)
	_last_vp = vp_size
	var s: float = 1.0
	if vp != null:
		s = maxf(vp.get_screen_transform().get_scale().x, 0.2)
	_zoom = clampf(1.0 / s, 1.0, 1.35)
	_mets = Spec.metrics(vp_size / _zoom)


## 底部行动条：选中卡 + 命令条**左右并排**成一条，不再上下堆。
## 参照图是"头像/数值/选择工具/指令"在同一条横向区域里，堆两层就会挡视野。
const BAR_GAP := 8.0

func _bar_total() -> float:
	if _mets == null:
		return 760.0
	return minf(maxf(_mets.panel_w + _mets.card_w + BAR_GAP, 720.0), _sel_avail_w())


func _sel_width() -> float:
	return _sel_w if _sel_w > 1.0 else 560.0


func _card_width() -> float:
	return _bar_total()


## 把四块 HUD 钉到四角（窗口变化 / 面板高度变化时都要重摆）
func _apply_layout() -> void:
	if _mets == null or root == null:
		return
	var m: float = _mets.margin

	# 资源条：顶部**居中**（左上让给圆形小地图）
	if _stats_panel != null:
		_place(_stats_panel, 0.5, 0.0, 0.5, 0.0,
				-_mets.stats_w * 0.5, m, _mets.stats_w * 0.5, m + _mets.stats_h)
	# 小地图：左上（圆盘 + 下方图例条）
	if _minimap != null:
		# 正方形：圆盘 = 控件内切圆，图例浮在圆内底部（不再额外占高度）
		_place(_minimap, 0.0, 0.0, 0.0, 0.0,
				m, m, m + _mets.minimap, m + _mets.minimap)
	if _adj_btn != null:
		_sync_adjutant()
		if _adj_btn.visible:
			_place(_adj_btn, 0.0, 0.0, 0.0, 0.0,
					m, m + _mets.minimap + 6.0,
					m + _mets.minimap, m + _mets.minimap + 40.0)
	if _menu_btn != null:
		_place(_menu_btn, 0.0, 0.0, 0.0, 0.0,
				m, m + _mets.minimap + 48.0,
				m + _mets.minimap, m + _mets.minimap + 82.0)
	# 命令条：**贴右下角**；选中卡贴左下（小地图右侧）。两块并排成一条、
	# 中间彻底让开视野 —— 以前是"选中卡坐在命令卡正上方"，330px 高的墙直接
	# 糊在屏幕正中偏下，谁玩都嫌挡。
	var cw: float = _card_w()
	if _card_panel != null:
		# 命令条：宽时一行放下所有指令 → 高度 66；窄时自动折行，绝不裁掉指令
		if _card != null:
			_card.custom_minimum_size = Vector2(cw - 20.0, 44.0)
		var ch: float = 64.0
		if _card != null and _card.has_method("desired_height"):
			ch = maxf(64.0, float(_card.call("desired_height")) + 20.0)
		_card_h_applied = ch
		if absf(_card_panel.custom_minimum_size.x - cw) > 0.5 or absf(_card_panel.custom_minimum_size.y - ch) > 0.5:
			_card_panel.custom_minimum_size = Vector2(cw, ch)
		_place(_card_panel, 1.0, 1.0, 1.0, 1.0,
				-(m + cw), -(m + ch), -m, -m)
	if _card != null and _card.has_method("set_tile"):
		_card.call("set_tile", _mets.tile)
	if _card != null and _card.has_method("set_compact"):
		_card.call("set_compact", _mets.compact)
	_place_toasts()
	_place_side_actions()
	# **先**把尺寸灌进两块面板，**再**摆位置。
	# 反过来会被 set_metrics 里的 reset_size 覆盖，面板缩回最小高度、位置也乱。
	_apply_panel_metrics()
	_place_selection_panel()
	_place_pending_label()
	_apply_theme_scale()


## 命令卡当前实际高度（行数自适应：1 行 / 2 行 / 3 行）
## 取 PanelContainer 的**实测最小尺寸**（含底座内边距），不再自己拿公式对——
## 公式少算 2px 就会在右下角裁掉半行字。
func _card_height() -> float:
	if _card_panel != null:
		var h: float = _card_panel.get_combined_minimum_size().y
		if h > 40.0:
			return h
	if _card != null and _card.has_method("desired_height"):
		return float(_card.call("desired_height"))
	return _mets.card_h



## 主题字号跟着反拉伸一起放大：tooltip 由引擎在独立层绘制，不吃 root.scale，
## 所以按 _zoom 预先乘一遍，物理字号才和面板正文一致。
func _apply_theme_scale() -> void:
	if OS.has_environment("UI_NOTHEMESCALE"):
		return
	if root == null or root.theme == null:
		return
	var th: Theme = root.theme
	th.default_font_size = maxi(18, int(round(float(Spec.FS_VALUE) * _zoom)))
	th.set_font_size("font_size", "TooltipLabel", maxi(16, int(round(float(Spec.FS_SUB) * _zoom))))
	th.set_font_size("font_size", "Button", maxi(18, int(round(float(Spec.FS_VALUE) * _zoom))))


## 把响应式尺寸同步给两块选中面板（宽度 / 高度档位 / 小屏标记）
func _apply_panel_metrics() -> void:
	if _mets == null:
		return
	var sw: float = _sel_width() if _mets != null else 432.0
	if _dossier != null and _dossier.has_method("set_metrics"):
		_dossier.call("set_metrics", sw, 136.0, 136.0, _mets.compact)
	if _building_panel != null and _building_panel.has_method("set_metrics"):
		# 建筑面板有训练/研究/集结点三块，必须给它足够高度，不能压成单位卡
		_building_panel.call("set_metrics", sw, 300.0, 300.0, _mets.compact)


## 版面工具：直接设 anchor + offset，避免 set_anchors_preset 的隐式行为
func _place(c: Control, al: float, at: float, ar: float, ab: float,
		ol: float, ot: float, orr: float, ob: float) -> void:
	c.anchor_left = al
	c.anchor_top = at
	c.anchor_right = ar
	c.anchor_bottom = ab
	c.offset_left = ol
	c.offset_top = ot
	c.offset_right = orr
	c.offset_bottom = ob


# ===========================================================================
# 主题（含中文字体兜底）
# ===========================================================================

func _build_theme() -> Theme:
	# 全 UI 共用的一份主题（字体兜底 / 面板 / 按钮四态 / tooltip / 血条 / 文字色）
	return Spec.build_theme(_zoom)


# ===========================================================================
# 构建各块
# ===========================================================================

## 一个彩色小方块（资源图标）
func _dot(color: Color) -> ColorRect:
	var d := ColorRect.new()
	d.color = color
	d.custom_minimum_size = Vector2(8.0, 8.0)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return d


## 顶部资源条：三枚等宽胶囊，右端人口带微条
func _build_stats() -> void:
	_stats_panel = PanelContainer.new()
	_stats_panel.name = "资源条"
	_stats_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 2026-10-18 重做左上角资源条：
	#   · 底：更深的墨色 + 顶部一条金色细线（魔兽式的"铜牌"感），不是纯圆角灰块；
	#   · 每格：[圆形底盘图标][大号等宽数字]，数字带 1px 描边保证在草地/雪地上都读得清；
	#   · 格与格之间一条 1px 冷色竖线分隔，三段结构一眼分明。
	var sb := Spec.panel_style(6, 0.96, 0.55, 12.0)
	sb.border_width_top = 2
	sb.border_color = Color(0.86, 0.70, 0.36, 0.85)
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(0, 2)
	_stats_panel.add_theme_stylebox_override("panel", sb)
	root.add_child(_stats_panel)

	var hb := HBoxContainer.new()
	hb.name = "资源行"
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 12)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	_stats_panel.add_child(hb)

	_gold_label = _stat_pill(hb, "金币", Spec.gold(), false, "coin")
	_wood_label = _stat_pill(hb, "木材", Spec.wood(), false, "wood")
	_food_label = _stat_pill(hb, "人口", Spec.food(), true, "pop")
	# 战斗计时：常驻在资源条末尾，一眼知道打了多久
	_time_label = _stat_pill(hb, "时间", Color(0.80, 0.86, 0.96), false, "clock")


## 一枚资源胶囊：[图标][小字标题][大数字][可选微条]，等宽伸展
##
## 图标替掉了原来的 8×8 色点：色点只能表达"这是另一种资源"，
## 表达不了"这是金币/木头/人口"；玩家点名"没有合适的图标"，指的就是这个位置。
func _stat_pill(parent: Node, title: String, color: Color, with_bar: bool,
		icon_name: String = "") -> Label:
	var pill := PanelContainer.new()
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pill.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.078, 0.088, 0.110, 0.94), 6,
					Color(color.r, color.g, color.b, 0.30), 12.0, 5.0))
	parent.add_child(pill)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 5)
	pill.add_child(row)

	# 图标装进深色圆盘：浅色草地/雪地上也不会"飘"
	var chip := Panel.new()
	chip.custom_minimum_size = Vector2(30.0, 30.0)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.03, 0.04, 0.055, 0.92), 10,
					Color(color.r, color.g, color.b, 0.38), 10.0, 0.0))
	row.add_child(chip)
	if icon_name.is_empty():
		chip.add_child(_dot(color))
	else:
		var holder := Spec.icon(icon_name, 20.0, color)
		# `PRESET_CENTER` **只改 anchors、不改 offset**，holder 会从圆盘中心点
		# 向右下长出一个 20×20 —— 图标就落在圆盘右下角，看着像"跑出框"。
		# 这里显式给四边 offset，才是真正的"居中在圆盘里"。
		holder.set_anchors_preset(Control.PRESET_CENTER)
		holder.offset_left = -10.0
		holder.offset_top = -10.0
		holder.offset_right = 10.0
		holder.offset_bottom = 10.0
		chip.add_child(holder)

	var tag := Spec.label(title, Spec.FS_BODY,
			Color(color.r * 0.5 + 0.32, color.g * 0.5 + 0.32, color.b * 0.5 + 0.32))
	row.add_child(tag)

	# 数字 24 号（任务书要求 ≥22）：战场上一眼就能读出剩多少
	var lb := Spec.label("0", Spec.FS_TITLE, Spec.text_main())
	lb.add_theme_font_override("font", Spec.mono_font())
	lb.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lb.add_theme_constant_override("outline_size", 4)
	if with_bar:
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lb)

	if with_bar:
		var mb := MiniBar.new()
		mb.color = color
		mb.custom_minimum_size = Vector2(56.0, 8.0)
		mb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(mb)
		_pop_bar = mb
	return lb


## 顶部中间的提示消息区
func _build_toasts() -> void:
	_toast_box = VBoxContainer.new()
	_toast_box.name = "提示"
	_toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	_toast_box.add_theme_constant_override("separation", 4)
	root.add_child(_toast_box)
	_place_toasts()


## 提示区摆位：默认顶部居中；若会和资源条打架（窄屏）就挪到资源条下面
func _place_toasts() -> void:
	if _toast_box == null or _mets == null:
		return
	var w: float = minf(680.0, _mets.vw * 0.62)
	# 资源条现在占着顶部正中，提示条统一让到它下面（永不互压）
	var top: float = _mets.margin + _mets.stats_h + _mets.gap
	_place(_toast_box, 0.5, 0.0, 0.5, 0.0, -w * 0.5, top, w * 0.5, top + 260.0)


## 左下小地图
func _build_minimap() -> void:
	_minimap = RtsMinimap.new()
	_minimap.name = "小地图"
	root.add_child(_minimap)
	_build_adjutant_toggle()


## 副官开关：**用一个小控件说清楚"副官开没开"**，比开局弹一条三秒就消失的
## 长提示有用得多（那条提示已经删了）。
func _build_adjutant_toggle() -> void:
	_adj_btn = Button.new()
	_adj_btn.name = "副官开关"
	_adj_btn.focus_mode = Control.FOCUS_NONE
	_adj_btn.add_theme_font_size_override("font_size", Spec.FS_BODY)
	_adj_btn.add_theme_stylebox_override("normal",
		Spec.button_style(Color(0.09, 0.10, 0.12, 0.94), Color(0.86, 0.72, 0.40, 0.55),
			null, 6, 8.0, 4.0))
	_adj_btn.add_theme_stylebox_override("hover",
		Spec.button_style(Color(0.16, 0.18, 0.21, 0.96), Color(0.92, 0.78, 0.45, 0.95),
			null, 6, 8.0, 4.0))
	_adj_btn.add_theme_stylebox_override("pressed",
		Spec.button_style(Color(0.20, 0.17, 0.10, 0.96), Color(0.95, 0.80, 0.42, 1.0),
			Color(0.95, 0.80, 0.42, 1.0), 6, 8.0, 4.0))
	_adj_btn.pressed.connect(_toggle_adjutant)
	root.add_child(_adj_btn)
	_sync_adjutant()
	_build_menu()


## 主菜单：设置 / 队伍 / 投降。图标复用资源条那套 SVG，风格统一。
func _build_menu() -> void:
	_menu_btn = Button.new()
	_menu_btn.name = "菜单"
	_menu_btn.text = "菜单"
	_menu_btn.focus_mode = Control.FOCUS_NONE
	_menu_btn.add_theme_font_size_override("font_size", Spec.FS_BODY)
	_menu_btn.add_theme_color_override("font_color", Spec.text_main())
	_menu_btn.add_theme_stylebox_override("normal",
		Spec.button_style(Color(0.09, 0.10, 0.12, 0.94), Color(0.86, 0.72, 0.40, 0.55),
			null, 6, 8.0, 4.0))
	_menu_btn.add_theme_stylebox_override("hover",
		Spec.button_style(Color(0.16, 0.18, 0.21, 0.96), Color(0.92, 0.78, 0.45, 0.95),
			null, 6, 8.0, 4.0))
	_menu_btn.add_theme_stylebox_override("pressed",
		Spec.button_style(Color(0.20, 0.17, 0.10, 0.96), Color(0.95, 0.80, 0.42, 1.0),
			Color(0.95, 0.80, 0.42, 1.0), 6, 8.0, 4.0))
	_menu_btn.pressed.connect(_open_menu)
	root.add_child(_menu_btn)

	_menu = PopupMenu.new()
	_menu.name = "主菜单列表"
	root.add_child(_menu)
	_menu.add_icon_item(Spec.icon_tex("gear"), "设置", 0)
	_menu.add_icon_item(Spec.icon_tex("team"), "队伍", 1)
	_menu.add_separator()
	_menu.add_icon_item(Spec.icon_tex("surrender"), "投降", 2)
	_menu.id_pressed.connect(_on_menu_id)


func _open_menu() -> void:
	if _menu == null or _menu_btn == null:
		return
	_menu.reset_size()
	var gp: Vector2 = _menu_btn.get_global_rect().position
	_menu.popup(Rect2i(
		Vector2i(int(gp.x + _menu_btn.size.x + 6.0), int(gp.y)), Vector2i(170, 0)))


func _on_menu_id(id: int) -> void:
	match id:
		0:
			_open_settings()
		1:
			_open_team()
		2:
			_open_surrender()


func _open_settings() -> void:
	if _dlg_settings == null:
		_dlg_settings = AcceptDialog.new()
		_dlg_settings.title = "设置"
		_dlg_settings.ok_button_text = "关闭"
		root.add_child(_dlg_settings)
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 8)
		_dlg_settings.add_child(vb)
		vb.add_child(Spec.icon_label_row("gear", "主音量", 22.0, Spec.text_main(), Spec.FS_BODY))
		_vol_slider = HSlider.new()
		_vol_slider.min_value = 0.0
		_vol_slider.max_value = 1.0
		_vol_slider.step = 0.05
		_vol_slider.custom_minimum_size = Vector2(280.0, 26.0)
		_vol_slider.value = clampf(db_to_linear(AudioServer.get_bus_volume_db(0)), 0.0, 1.0)
		_vol_slider.value_changed.connect(func(v: float) -> void:
			AudioServer.set_bus_volume_db(0, linear_to_db(maxf(v, 0.0001))))
		vb.add_child(_vol_slider)
		_adj_check = CheckButton.new()
		_adj_check.text = "副官接管"
		_adj_check.add_theme_font_size_override("font_size", Spec.FS_BODY)
		_adj_check.add_theme_color_override("font_color", Spec.text_main())
		_adj_check.toggled.connect(func(on: bool) -> void:
			if _adjutant != null and is_instance_valid(_adjutant):
				if _adjutant.has_method("set_enabled"):
					_adjutant.call("set_enabled", on)
				else:
					_adjutant.set("enabled", on)
				_sync_adjutant())
		vb.add_child(_adj_check)
	_dlg_settings.popup_centered(Vector2i(340, 0))


func _open_team() -> void:
	if _dlg_team == null:
		_dlg_team = AcceptDialog.new()
		_dlg_team.title = "队伍"
		_dlg_team.ok_button_text = "关闭"
		root.add_child(_dlg_team)
	_dlg_team.dialog_text = _team_text()
	_dlg_team.popup_centered(Vector2i(360, 0))


func _team_text() -> String:
	var lines := PackedStringArray()
	var pl := Game.player_faction
	var en := Game.enemy_faction
	if pl != null:
		lines.append("你：%s —— 队伍 0" % pl.display_name)
	if en != null:
		lines.append("敌方：%s —— 队伍 1（人机）" % en.display_name)
	var md: Variant = null
	if Game.level != null:
		md = Game.level.get("map_def")
	if md != null:
		var pls: Variant = md.get("players")
		if pls is Array and (pls as Array).size() > 2:
			lines.append("")
			lines.append("本图共 %d 个玩家槽位：" % (pls as Array).size())
			for p in (pls as Array):
				if p != null:
					lines.append("  玩家 %d —— 队伍 %d" % [int(p.get("id")) + 1, int(p.get("team"))])
	return "\n".join(lines)


func _open_surrender() -> void:
	if _dlg_surrender == null:
		_dlg_surrender = ConfirmationDialog.new()
		_dlg_surrender.title = "投降"
		_dlg_surrender.dialog_text = "确定投降吗？本局将判定为战败。"
		_dlg_surrender.ok_button_text = "投降"
		_dlg_surrender.cancel_button_text = "继续战斗"
		_dlg_surrender.confirmed.connect(func() -> void:
			Game.game_over.emit(false))
		root.add_child(_dlg_surrender)
	_dlg_surrender.popup_centered(Vector2i(360, 0))


func _toggle_adjutant() -> void:
	if _adjutant == null or not is_instance_valid(_adjutant):
		return
	var want: bool = _adjutant.get("enabled") != true
	if _adjutant.has_method("set_enabled"):
		_adjutant.call("set_enabled", want)
	else:
		_adjutant.set("enabled", want)
	_sync_adjutant()


func _sync_adjutant() -> void:
	if _adj_btn == null:
		return
	if _adjutant == null or not is_instance_valid(_adjutant):
		# 用组名找人：HUD 可能挂在 CanvasLayer 下、副官是主场景的子节点，
		# 靠父子路径找会出现"有时找得到有时找不到"。副官 `_ready` 里 add_to_group。
		var tree := get_tree()
		if tree != null:
			_adjutant = tree.get_first_node_in_group("adjutant")
			if _adjutant == null and tree.current_scene != null:
				_adjutant = tree.current_scene.get_node_or_null("副官")
	if _adjutant == null:
		_adj_btn.visible = false
		return
	_adj_btn.visible = true
	var on: bool = _adjutant.get("enabled") == true
	_adj_btn.text = "副官 · 开" if on else "副官 · 关"
	_adj_btn.add_theme_color_override("font_color",
		Color(0.66, 0.90, 0.58) if on else Color(0.72, 0.70, 0.66))
	_adj_btn.tooltip_text = ("副官正在替你补农民、派采集、盖房、带兵推进。\n点一下关掉。"
		if on else "副官已关闭，全部单位归你手动操作。\n点一下重新开启。")


## 中下：选中信息（**门面**）。两种版式按选中内容切换：
##   · 单个建筑 → RtsBuildingPanel（训练队列 / 建造进度 / 集结点 / 研究）
##   · 其余情况 → RtsDossierPanel（3D 头像 / 属性 / 多选格子）
## 两块面板同时存在、按可见性切换：这样高度重新自适应时不会重建控件，也不会丢悬停状态。
func _build_selection_panel() -> void:
	_dossier = RtsDossierPanel.new()
	_dossier.name = "选中信息"
	root.add_child(_dossier)

	_building_panel = BUILDING_PANEL_SCRIPT.new() as PanelContainer
	_building_panel.name = "建筑信息"
	_building_panel.visible = false
	# 建筑面板有训练/队列/集结点/研究四块，**不能被压成单位卡那个高度**
	_building_panel.custom_minimum_size = Vector2(0.0, 190.0)
	root.add_child(_building_panel)

	_sel_panel = _dossier
	_sel_h = _dossier.desired_height()
	_place_selection_panel()


## 左右并排后，选中卡不再需要抬到命令卡上方（保留给待落点提示用）
func _lift_above_card() -> float:
	return _sel_h + BAR_GAP


## 命令卡宽度：占屏宽的 44%（最小 420 / 最大 900）。
## 加宽的目的是**变矮**：命令条按钮一排 96px，宽了就能一行放下 6 条指令，
## 行数从 3 降到 1，底部整条高度从 330+ 掉到 140 上下，中央视野才真的让开。
func _card_w() -> float:
	if _mets == null:
		return 560.0
	return clampf(_mets.vw * 0.48, 460.0, 980.0)


## 面板宽度上限：不能压到小地图（左右各留一条安全边）
func _sel_avail_w() -> float:
	if _mets == null:
		return 360.0
	return maxf(_mets.vw - _mets.margin * 2.0, 320.0)


## 选中面板与命令条共用的宽度（两者必须一样宽，视觉上才是一条）
func _panel_width() -> float:
	if _mets == null:
		return 560.0
	return minf(maxf(_mets.panel_w, 520.0), _sel_avail_w())


## **选中卡贴左下**（小地图右侧），和右下角的命令卡并排成同一条带。
## 宽度吃满"小地图右缘 → 命令卡左缘"之间的全部空间：又宽又矮，不挡中间。
func _place_selection_panel() -> void:
	if _mets == null:
		return
	var m: float = _mets.margin
	var left: float = m + _mets.minimap + BAR_GAP
	var right: float = _mets.vw - m - _card_w() - BAR_GAP
	var w: float = maxf(340.0, right - left)
	_sel_left = left
	_sel_w = w
	# **两块面板都摆到同一个位置**：谁可见谁占位。
	# 只摆 `_sel_panel` 会出现"切到建筑面板时它是第一次显示、从没被摆过"，
	# 结果面板停在默认尺寸，训练条和集结点叠成一坨。
	var show_h: float = _sel_h
	if _building_panel != null and _building_panel.visible:
		show_h = maxf(_sel_h, 186.0)
	for pnl in [_dossier, _building_panel]:
		if pnl == null or not is_instance_valid(pnl):
			continue
		_place(pnl, 0.0, 1.0, 0.0, 1.0, left, -(m + show_h), left + w, -m)
	# 自校正：引擎把面板顶高了说明 desired_height 少算，把真实高度吃回去
	if _sel_panel != null and is_instance_valid(_sel_panel) \
			and _sel_panel.visible and _sel_panel.size.y > show_h + 0.5:
		_sel_h = _sel_panel.size.y
		_place(_sel_panel, 0.0, 1.0, 0.0, 1.0, left, -(m + _sel_h), left + w, -m)



## 右下命令卡
func _build_card() -> void:
	_card_panel = PanelContainer.new()
	_card_panel.name = "命令卡底座"
	_card_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card_panel.add_theme_stylebox_override("panel", Spec.panel_style(8, 0.95, 0.50, 10.0))
	root.add_child(_card_panel)

	_card = RtsCommandCard.new()
	_card.name = "命令卡"
	_card_panel.add_child(_card)


## 等待落点的提示（选中面板上方，一个可读的胶囊）
func _build_pending_label() -> void:
	_pending_box = PanelContainer.new()
	_pending_box.name = "落点提示"
	_pending_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pending_box.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.06, 0.05, 0.02, 0.92), 12,
					Color(0.98, 0.80, 0.40, 0.65), 16.0, 3.0))
	root.add_child(_pending_box)

	_pending_label = Spec.label("", Spec.FS_SUB, Color(0.99, 0.87, 0.52),
			HORIZONTAL_ALIGNMENT_CENTER)
	_pending_box.add_child(_pending_label)
	_place_pending_label()
	_pending_box.visible = false


## 落点提示：选中面板正上方（原版位置），宽度收窄
func _place_pending_label() -> void:
	if _pending_box == null or _mets == null:
		return
	var pw: float = minf(_mets.panel_w, 420.0)
	var y: float = _mets.margin + _sel_h + 10.0
	_place(_pending_box, 0.5, 1.0, 0.5, 1.0,
			-pw * 0.5, -y - 26.0, pw * 0.5, -y)


## 右侧竖排快捷选择（参照图右列：只剩下真正实现了的两件事 —— 全选 / 取消）
func _build_side_actions() -> void:
	_side_box = VBoxContainer.new()
	_side_box.name = "快捷选择"
	_side_box.add_theme_constant_override("separation", 6)
	_side_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_side_box)
	_side_box.add_child(_side_button("框选", "拖拽矩形选择己方单位", _on_box_mode))
	_side_box.add_child(_side_button("圈选", "拖拽圆形选择己方单位", _on_circle_mode))
	_side_box.add_child(_side_button("全选", "选中所有己方单位", _on_select_all))
	_side_box.add_child(_side_button("取消", "取消当前选择", _on_clear_selection))


func _side_button(text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(92.0, 50.0)
	b.add_theme_font_size_override("font_size", Spec.FS_SUB)
	var a: Color = Spec.accent()
	b.add_theme_stylebox_override("normal",
			Spec.button_style(Color(0.095, 0.105, 0.130, 0.88), Color(a.r, a.g, a.b, 0.45), a, 10, 10.0, 6.0))
	b.add_theme_stylebox_override("hover",
			Spec.button_style(Color(0.170, 0.185, 0.225, 0.96), Color(a.r, a.g, a.b, 0.95), a, 10, 10.0, 6.0))
	b.add_theme_stylebox_override("pressed",
			Spec.button_style(Color(0.270, 0.230, 0.140, 0.98), a, a, 10, 10.0, 6.0))
	b.add_theme_color_override("font_color", Color(0.90, 0.89, 0.84))
	b.pressed.connect(cb)
	return b


## 右侧竖排摆位：贴右边缘、垂直居中偏下（拇指够得着，又不挡战场中央）
func _place_side_actions() -> void:
	if _side_box == null or _mets == null:
		return
	_place(_side_box, 1.0, 1.0, 1.0, 1.0,
			-(_mets.margin + 92.0), -(m_side_bottom() + 110.0), -_mets.margin, -(m_side_bottom() - 110.0))


func m_side_bottom() -> float:
	if _mets == null:
		return 120.0
	return maxf(_mets.vh * 0.34, 120.0)


func _on_box_mode() -> void:
	var sel := get_parent().get_node_or_null("选择系统")
	if sel != null and sel.has_method("set_circle_mode"):
		sel.call("set_circle_mode", false)
	Game.toast("框选：拖拽矩形选择己方单位", Spec.accent())


func _on_circle_mode() -> void:
	var sel := get_parent().get_node_or_null("选择系统")
	if sel != null and sel.has_method("set_circle_mode"):
		sel.call("set_circle_mode", true)
	Game.toast("圈选：拖拽圆形选择己方单位", Spec.accent())


func _on_select_all() -> void:
	var pl := Game.player_faction
	if pl == null:
		return
	var picked: Array = []
	for u in pl.units:
		if u != null and is_instance_valid(u) and u.has_method("is_alive") and u.is_alive():
			picked.append(u)
	var sel := get_parent().get_node_or_null("选择系统")
	if sel == null or picked.is_empty():
		return
	if sel.has_method("select_units"):
		sel.call("select_units", picked)


func _on_clear_selection() -> void:
	var sel := get_parent().get_node_or_null("选择系统")
	if sel != null and sel.has_method("clear_selection"):
		sel.call("clear_selection")


## 结束遮罩
func _build_overlay() -> void:
	_overlay = ColorRect.new()
	_overlay.name = "结束遮罩"
	_overlay.color = Color(0.02, 0.03, 0.04, 0.74)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	root.add_child(_overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(center)

	var card := PanelContainer.new()
	card.name = "结算卡"
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_theme_stylebox_override("panel", Spec.panel_style(10, 0.97, 0.55, 28.0))
	center.add_child(card)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_child(vb)

	var cap := Spec.label("战 役 结 束", Spec.FS_CAPTION, Spec.text_dim(),
			HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(cap)

	_over_title = Spec.label("胜 利", Spec.FS_HERO, Color(0.98, 0.86, 0.42),
			HORIZONTAL_ALIGNMENT_CENTER)
	_over_title.add_theme_constant_override("outline_size", 6)
	_over_title.add_theme_color_override("font_outline_color", Color(0.25, 0.16, 0.02, 0.9))
	vb.add_child(_over_title)

	var rule := Spec.rule(0.55)
	rule.custom_minimum_size = Vector2(280.0, 1.0)
	vb.add_child(rule)

	_over_sub = Spec.label("", Spec.FS_SUB, Spec.text_sub(), HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_over_sub)

	_over_kills = Spec.label("", Spec.FS_VALUE, Color(0.96, 0.80, 0.46),
			HORIZONTAL_ALIGNMENT_CENTER)
	vb.add_child(_over_kills)

	var btn := Button.new()
	btn.text = "重新开始"
	btn.custom_minimum_size = Vector2(220.0, 48.0)
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", Spec.FS_SUB)
	btn.add_theme_color_override("font_color", Color(0.98, 0.90, 0.62))
	btn.add_theme_stylebox_override("normal",
			Spec.button_style(Color(0.16, 0.14, 0.09, 0.98), Color(0.88, 0.72, 0.36, 0.75), Spec.accent(), 6, 18.0, 10.0))
	btn.add_theme_stylebox_override("hover",
			Spec.button_style(Color(0.26, 0.21, 0.11, 0.99), Color(1.0, 0.86, 0.46, 1.0), Spec.accent(), 6, 18.0, 10.0))
	btn.add_theme_stylebox_override("pressed",
			Spec.button_style(Color(0.36, 0.28, 0.12, 0.99), Spec.accent(), Spec.accent(), 6, 18.0, 10.0))
	btn.pressed.connect(_on_restart_pressed)
	vb.add_child(btn)


# ===========================================================================
# 外挂模块（ECHO 触感回声 / GLYPH 光标符文）
# ===========================================================================

## 装两件"手感"外挂：
##   · ECHO 必须挂在 3D 世界里（圆环/涟漪是 MeshInstance3D），
##     所以往**主场景根**（本 HUD 的父节点，主场景.tscn 的 Node3D）上挂 —— 不碰别人的节点树；
##   · GLYPH 只吃输入、不画东西，挂在 HUD 自己名下。
func _install_fx() -> void:
	var host := get_parent()
	if host is Node3D and _echo == null:
		_echo = RtsEchoFx.new()
		_echo.hud = self
		# 这里本来可以直接 add_child，但 HUD 是在主场景 **还在装配子节点时** 就 _ready 的，
		# 直接挂会被引擎拒绝（"Parent node is busy setting up children"），所以推到下一帧。
		(host as Node3D).add_child.call_deferred(_echo)
	if _glyph == null:
		_glyph = RtsGlyphCursor.new()
		add_child(_glyph)


# ===========================================================================
# QA 截图钩子（只在带命令行参数时生效，不碰正常玩法）
# ===========================================================================

## 中文名 → 单位 id（验收命令行允许写中文）
const QA_NAME_MAP := {
	"农民": "peasant", "步兵": "footman", "弓箭手": "archer", "法师": "mage",
	"大本营": "townhall", "兵营": "barracks", "铁匠铺": "blacksmith",
	"农场": "farm", "箭塔": "tower", "金矿": "goldmine", "树": "tree",
}

## --select-id=<英文 id 或 中文名>：自动选中该类型的全部己方对象（**含建筑**）。
##
## 为什么要在这里补一条：主场景自带的 _qa_select 只遍历 faction.units，
## 而建筑登记在 faction.buildings 里（不在 units 数组），中文名也匹配不上 ——
## 于是"截建筑面板"这条路原本是断的。这里补一条更宽的通道，纯为验收。
func _qa_select_hook() -> void:
	var want: String = ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--select-id="):
			want = arg.substr(12)
			break
	if want.is_empty():
		return
	_qa_select_later(want)


## 额外的验收钩子（只在命令行带参数时生效）：
##   --ui-over=victory|defeat  直接弹结算遮罩（截"胜利/失败"版式用）
##   --ui-build-page           选中农民后自动打开建造页（截建造页用）
func _qa_extra_hooks() -> void:
	var over: String = ""
	var want_page: bool = false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ui-over="):
			over = arg.substr(10)
		elif arg == "--ui-build-page":
			want_page = true
	if over != "":
		_qa_force_over(over)
	if want_page:
		_qa_open_build_page()


func _qa_force_over(kind: String) -> void:
	for _i in 20:
		await get_tree().process_frame
	_on_game_over(kind != "defeat")
	print("[QA补] 强制结算遮罩：%s" % kind)


func _qa_open_build_page() -> void:
	for _i in 12:
		await get_tree().process_frame
	if _card == null:
		return
	_card.enter_build_page()
	_refresh_card(true)
	print("[QA补] 命令卡切到建造页")


func _qa_select_later(want: String) -> void:
	for _i in 5:
		await get_tree().process_frame
	var id: String = String(QA_NAME_MAP.get(want, want))
	var picked: Array = []
	var pl := Game.player_faction
	if pl == null:
		return
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var r := u as RtsUnit
		if r == null or not r.is_alive() or r.faction != pl or r.def == null:
			continue
		if String(r.def.id) == id:
			picked.append(r)
	if picked.is_empty():
		return
	var sel := get_parent().get_node_or_null("选择系统")
	if sel == null:
		return
	if sel.has_method("select_units"):
		sel.call("select_units", picked)
	else:
		sel.set("selected", picked)
		for u in picked:
			u.set("is_selected", true)
		Game.selection_changed.emit(picked)
	print("[QA补] 选中 %d 个 %s（建筑也在内）" % [picked.size(), id])


# ===========================================================================
# 关停
# ===========================================================================

## 退出时把音效模块的播放器**提前**收掉。
##
## 为什么界面层要管这事：代码/音频/音效管理.gd 自己已经有 _exit_tree()（stop + stream=null），
## 但 AudioServer 是独立线程，stop 命令要排队处理；引擎关停时音频服务先走一步，
## 播放对象（AudioStreamPlaybackWAV / AudioStreamWAV）就变成"退出时仍被引用"，
## 于是 --quit-after 200 会**间歇性**刷一条
##   ERROR: 1 resources still in use at exit
## 这里在界面层把它的节点直接 free()（立刻释放播放器），只是抢在关停前把手放开，
## **不改音频模块的任何行为** —— 它不在本文件的改动范围里，也轮不到界面去改它的地基。
func _exit_tree() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var sfx := tree.root.get_node_or_null("音效")
	if sfx == null or not is_instance_valid(sfx):
		return
	# 只"放手"，不 free 节点（关停阶段动父子关系会触发引擎的 busy 断言）
	for c in sfx.get_children():
		var p := c as AudioStreamPlayer
		if p != null:
			p.stop()
			p.stream = null
			continue
		var p3 := c as AudioStreamPlayer3D
		if p3 != null:
			p3.stop()
			p3.stream = null


# ===========================================================================
# 刷新
# ===========================================================================

## 资源/人口
##
## ★ 全部写操作都走 "变了才写"：
##   Label.text 赋值会标脏重排，add_theme_color_override 更狠 —— 它会广播
##   NOTIFICATION_THEME_CHANGED，让整个控件重新解析主题并重绘。
##   这里每 0.12s 被调一次，不加守卫就是 8Hz 的闪烁（尤其是人口满/不满切换那一下）。
func _refresh_stats() -> void:
	var pl := Game.player_faction
	if pl == null:
		_set_label(_gold_label, "-")
		_set_label(_wood_label, "-")
		_set_label(_food_label, "-")
		if _time_label != null:
			_set_label(_time_label, "--:--")
		if _pop_bar != null:
			_pop_bar.set_ratio(0.0, false)
		return
	# 副官节点可能比 HUD 晚建好：这里的定时刷新负责"补挂"，
	# 一旦从"找不到"变成"找到了"，立刻重摆一次版面（不然按钮永远不出现）。
	if _adj_btn != null:
		var was_vis: bool = _adj_btn.visible
		_sync_adjutant()
		if _adj_btn.visible != was_vis:
			_apply_layout()
	_set_label(_gold_label, "%d" % pl.gold)
	_set_label(_wood_label, "%d" % pl.wood)
	if _time_label != null:
		var secs: int = maxi(0, int(Game.elapsed))
		_set_label(_time_label, "%02d:%02d" % [secs / 60, secs % 60])
	var used: int = pl.food_used()
	var cap: int = pl.food_cap()
	_set_label(_food_label, "%d/%d" % [used, cap])
	var full: bool = cap > 0 and used >= cap
	# 只在"满/不满"真的翻转时改一次颜色
	if full != _food_full:
		_food_full = full
		_food_label.add_theme_color_override("font_color",
				Color(0.98, 0.52, 0.42) if full else Spec.text_main())
	if _pop_bar != null:
		_pop_bar.set_ratio(float(used) / maxf(float(cap), 1.0), full)


## 幂等写 Label：文本没变就一个字节都不写（避免 8Hz 重排）
func _set_label(lb: Label, txt: String) -> void:
	if lb != null and lb.text != txt:
		lb.text = txt


## 选中信息：**单个建筑**走建筑面板，其余（单位 / 多选 / 空）交给 BASALT 档案板。
## 两块面板共用贴底位置，靠 visible 切换；高度变了才重摆，避免每 0.12s 抖一下。
func _refresh_selection() -> void:
	var arr := _valid_selection()
	var sole_building: RtsBuilding = null
	if arr.size() == 1:
		var b := arr[0] as RtsBuilding
		if b != null and b.is_alive():
			sole_building = b

	if sole_building != null:
		if _dossier != null:
			_dossier.visible = false
		if _building_panel != null:
			_building_panel.visible = true
			_building_panel.call("refresh", sole_building)
		_sel_panel = _building_panel
	else:
		if _building_panel != null:
			_building_panel.visible = false
		# 空选中不显示"战场概览"大板：用户要的是"中间那坨信息砍掉"。
		# 没选中时屏幕只留资源条/小地图/提示，视野干净；选中单位才弹紧凑卡。
		var show_dossier := not arr.is_empty()
		if _dossier != null:
			_dossier.visible = show_dossier
			if show_dossier:
				_dossier.refresh(arr)
		_sel_panel = _dossier if show_dossier else null

	if _sel_panel != null:
		# 两块面板都实现了 desired_height()；这里按调用取，避免依赖具体面板类型
		var h: float = float(_sel_panel.call("desired_height"))
		# 建筑面板高度写死下限，单位卡给上下限：两块面板的内容密度差三倍，
		# 用同一个 desired 值会出现"建筑面板压成一坨 / 单位卡空半屏"。
		if _sel_panel == _building_panel:
			h = maxf(h, 186.0)
		elif _sel_panel == _dossier:
			h = clampf(h, 108.0, 168.0)
		if OS.has_environment("UI_DEBUG"):
			var vbm: float = 0.0
			var vbn: Node = _sel_panel.get("_vb")
			if vbn is Control:
				vbm = (vbn as Control).get_combined_minimum_size().y
			print("[UI] sel=%s desired=%.0f selh=%.0f vbmin=%.0f min=%.0f size=%.0f" % [
				_sel_panel.name, h, _sel_h, vbm,
				_sel_panel.get_combined_minimum_size().y, _sel_panel.size.y])
		if absf(h - _sel_h) > 0.5:
			_sel_h = h
			_place_selection_panel()
			_place_pending_label()
		if _sel_panel.visible and absf(_sel_panel.offset_left - _sel_left) > 0.5:
			_place_selection_panel()
	if _glyph != null:
		_glyph.note_selection(arr)


## 等待落点提示
func _refresh_pending() -> void:
	var cmd := _command_system()
	var show: bool = false
	if cmd != null and is_instance_valid(cmd) and cmd.has_method("has_pending"):
		if bool(cmd.call("has_pending")) and cmd.has_method("pending_prompt"):
			var txt: String = String(cmd.call("pending_prompt"))
			if txt != "":
				_pending_label.text = txt
				show = true
	_pending_box.visible = show


## 命令卡（签名没变就不重建，避免悬停时闪烁；可用性仍每拍就地刷新）
func _refresh_card(force: bool) -> void:
	if _card == null:
		return
	# 【显隐】没有选中 / 选中的不是己方（敌方、中立金矿）→ 整块命令卡收起，不占位。
	# 收起时要顺手重摆选中卡：它本来坐在命令卡上方，卡没了就该落回屏幕底边。
	var show: bool = _should_show_card()
	if _card_panel != null and _card_panel.visible != show:
		_card_panel.visible = show
		_place_selection_panel()
		_place_pending_label()
	if not show:
		return
	var sig := _card_signature()
	if force or sig != _card_sig:
		_card_sig = sig
		_card.command_system = _command_system()
		_card.refresh(_valid_selection())
		# 命令卡行数随内容变（兵营 4 条 = 1 行 / 农民建造页 9 条 = 3 行），
		# 卡高变了就得重摆 —— 否则右下角会留一条黑边或顶出屏幕。
		_apply_layout()
	else:
		_card.sync_states()


## 该不该显示命令卡：必须有选中，且都是自己的（敌方/中立给"档案"就够了）
func _should_show_card() -> bool:
	var arr := _valid_selection()
	if arr.is_empty():
		return false
	var pl := Game.player_faction
	if pl == null:
		return false
	for u in arr:
		var fac: Variant = u.get("faction")
		if fac != null and fac != pl:
			return false
	return true


## 命令卡的内容签名
func _card_signature() -> String:
	var parts := PackedStringArray()
	for u in _valid_selection():
		var id := ""
		var d: UnitDef = u.get("def") as UnitDef
		if d != null:
			id = String(d.id)
		var q: int = 0
		var r: String = "-"
		var b := u as RtsBuilding
		if b != null:
			q = b.train_queue.size()
			# 研究状态也进签名：研究完成/满级时命令卡必须重建，否则按钮一直停在旧等级
			r = "%s:%d" % [String(b.current_research()), int(clampf(b.research_progress(), 0.0, 1.0) * 10.0)]
		parts.append("%s:%d:%s" % [id, q, r])
	parts.append("page:%s" % (str(_card.is_build_page()) if _card != null else "0"))
	parts.append("cmd:%s" % str(_command_system() != null))
	return "|".join(parts)


## 过滤出有效选中（节点还在、还活着）
func _valid_selection() -> Array:
	var out: Array = []
	for u in _selection:
		if u == null or not is_instance_valid(u):
			continue
		# **金矿 / 树木 / 岩石不弹操作面板**：它们没有可执行指令，
		# 弹一块面板只会挡视野。选中反馈交给视口里的高亮环就够了。
		if not (u is RtsUnit):
			continue
		if u.has_method("is_alive") and not u.is_alive():
			continue
		out.append(u)
	return out


func _command_system() -> Node:
	var parent := get_parent()
	if parent == null:
		return null
	return parent.get("command_system") as Node


# ===========================================================================
# 信号处理
# ===========================================================================

func _on_resources_changed(_faction: RtsFaction) -> void:
	_refresh_stats()


func _on_selection_changed(units: Array) -> void:
	_selection = units.duplicate()
	_refresh_selection()
	_refresh_card(true)


## 顶部提示：3 秒后淡出，最多留 3 条；一条一枚深底胶囊（读得清，不糊在战场上）
func _on_notify(text: String, color: Color) -> void:
	if text.is_empty() or _toast_box == null:
		return

	var pill := PanelContainer.new()
	pill.name = "提示条"
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pill.add_theme_stylebox_override("panel",
			Spec.inset_style(Color(0.045, 0.050, 0.062, 0.90), 10,
					Color(color.r, color.g, color.b, 0.42), 14.0, 3.0))
	_toast_box.add_child(pill)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	pill.add_child(row)

	var stripe := ColorRect.new()
	stripe.color = color
	stripe.custom_minimum_size = Vector2(3.0, 14.0)
	stripe.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stripe)

	# 提示条字号 24（≥22）：战场上晃一眼就能读到
	var lb := Spec.label(text, Spec.FS_TITLE, color, HORIZONTAL_ALIGNMENT_CENTER)
	row.add_child(lb)

	while _toast_box.get_child_count() > TOAST_MAX:
		var oldest := _toast_box.get_child(0)
		_toast_box.remove_child(oldest)
		oldest.queue_free()

	var hold: float = Cfg.game.toast_duration if Cfg.game != null else 3.0
	var tw := create_tween()
	tw.tween_interval(hold)
	tw.tween_property(pill, "modulate:a", 0.0, TOAST_FADE)
	tw.tween_callback(pill.queue_free)


func _on_game_over(victory: bool) -> void:
	if _overlay == null:
		return
	_overlay.visible = true
	if victory:
		_over_title.text = "胜  利"
		_over_title.add_theme_color_override("font_color", Color(0.98, 0.86, 0.42))
		_over_title.add_theme_color_override("font_outline_color", Color(0.25, 0.16, 0.02, 0.9))
	else:
		_over_title.text = "战  败"
		_over_title.add_theme_color_override("font_color", Color(0.95, 0.42, 0.36))
		_over_title.add_theme_color_override("font_outline_color", Color(0.22, 0.04, 0.03, 0.9))
	var t: float = Game.elapsed
	_over_sub.text = "用时 %02d:%02d" % [floori(t / 60.0), int(t) % 60]
	_over_kills.text = "击杀 %d" % _player_kills()
	_pending_box.visible = false


## 玩家击杀数（敌方已死亡、还没被清理的单位数；纯展示用）
func _player_kills() -> int:
	var n: int = 0
	var en := Game.enemy_faction
	if en == null:
		return 0
	for u in en.units:
		if u != null and is_instance_valid(u) and u.has_method("is_alive") and not u.is_alive():
			n += 1
	return n


func _on_restart_pressed() -> void:
	Game.restart()


# ===========================================================================
# 对外（供指令系统 B 键调用）
# ===========================================================================

## 切换命令卡的"建造页"
func toggle_build_menu() -> void:
	if _card == null:
		return
	_card.toggle_build_page()
	_refresh_card(true)


## 这个屏幕点是不是压在会吃鼠标的界面块上。
## 为什么不用 viewport.gui_get_hovered_control()：它看的是**真实鼠标位置**，
## 自动化测试用 Input.parse_input_event 灌事件时两者对不上，会误判"点在界面上"。
## 所以这里按控件矩形自己判，真实点击与模拟点击都一致。
func covers_point(p: Vector2) -> bool:
	if _overlay != null and _overlay.visible:
		return true
	if _minimap != null and _minimap.get_global_rect().has_point(p):
		return true
	if _sel_panel != null and _sel_panel.visible and _sel_panel.get_global_rect().has_point(p):
		return true
	if _card_panel != null and _card_panel.visible and _card_panel.get_global_rect().has_point(p):
		return true
	if _stats_panel != null and _stats_panel.get_global_rect().has_point(p):
		return true
	return false