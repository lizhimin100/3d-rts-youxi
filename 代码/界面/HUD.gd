class_name RtsHud
extends CanvasLayer
## **HUD（HAWKEYE）**：全部用代码构建（文档 §8 明确不写 .tscn，避免布局脆弱）
##
## 版面（四角对齐 + 8px 栅格，任务书 §3.2）：
##   左上     资源条：金币 / 木材 / 人口（三枚等宽胶囊 + 人口微条）
##   顶部中   提示消息（最多 3 条、淡出；窄屏自动让到资源条下方，不压顶栏）
## 左下     小地图（RtsMinimap：地形底图 + 视野框 + 图例 + 取景角）
## 底部一整条   **魔兽式行动带**（2026-10-31 重排）：
##             ┌──────────────────────────────────────────────────────┐
##             │ [ 选中卡：头像 / 名字 / 数值 / 血条 ] [ 命令卡 4 列 ] │
##             └──────────────────────────────────────────────────────┘
##             两段**同高、同顶、同底**，坐在一块连续底板上 —— 不许一高一低。
##   选中面板上方  等待落点提示（"左键选择建造位置…"）
##   全屏     结束遮罩：胜/败 + 用时 + 击杀 + 「重新开始」
##
## 三条纪律：
##   1. **尺寸只从 界面规格.gd 的 metrics() 来**：窗口变化时统一重算、重摆一遍，
##      所以 1024×768 ~ 1920×1080 都不会出现面板互压；
##   2. 字号只有 12/14/16/18/24/28 六级，层级靠"字号 + 颜色明度"两级表达；
##   3. 中文字体：优先美术主题（ArtKit.load_theme），没有就 SystemFont 兜底 ——
##      **必须保证中文能显示**，否则一屏方块，验收直接不过。
##
## 显隐：`F9` 一键收起/放出整层 HUD（录视频、看战场用），菜单里也有同一条；
##       `--ui-hidden` 开局就收起界面（**保留鼠标光标**：拍视频还要靠它拖镜头）；
##       `--all-hidden` 界面 + 鼠标光标全隐藏（成片/干净截图用）。

const Spec := preload("res://代码/界面/界面规格.gd")
## 词条（悬停说明）：经验条/资源条的气泡文案都从这里取
const Lex := preload("res://代码/界面/词条.gd")

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
## 顶部「据点资源箱 N 秒后刷新」提示（2026-11-08 玩家要求：刷新前 30s 要有 UI）
var _crate_banner: PanelContainer = null
var _crate_label: Label = null
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
## 游戏速度（直接写 Engine.time_scale；见 _open_settings 里的说明）
var _speed_slider: HSlider = null
var _speed_label: Label = null
var _adj_check: CheckButton = null
## 战争迷雾开关（设置面板），以及缓存的迷雾节点
var _fog_check: CheckButton = null
var _fog_node: Node = null
## 战斗计时（资源条末段）
var _time_label: Label = null

## 选中信息
var _sel_panel: PanelContainer = null
## **BASALT 档案板**：3D 头像 + 名称 + 生命 + 数值 + 多选格子（见 选中面板.gd）
var _dossier: RtsDossierPanel = null
## **建筑面板**：选中单个建筑时的专属版式（训练 / 集结点 / 研究，见 建筑面板.gd）
var _building_panel: PanelContainer = null

## 选中单位网格（参考图第 2 块：头像 + 短血条 + 蓝条，最多 24 个一页）
var _grid_panel: PanelContainer = null
var _sel_grid: RtsSelectionGrid = null
## 头顶界面（选中单位血条 + 驻守/观察/路径状态图标）
var _overhead: RtsOverheadUi = null
## 底座面板脚本（preload：第一次进工程时 .godot 的 class 缓存可能还没扫到）
const SELECTION_GRID_SCRIPT := preload("res://代码/界面/选择网格.gd")
const OVERHEAD_SCRIPT := preload("res://代码/界面/头顶界面.gd")
## 当前选中面板高度（单位单选 / 多选 / 建筑三种版式各不相同）
var _sel_h: float = 216.0
## 选中面板当前的左边界（响应式时会被夹在小地图和命令卡之间）
var _sel_left: float = 0.0
## 选中卡实际宽度（贴左下、吃满到命令卡左缘）
var _sel_w: float = 0.0
## 建筑面板实际宽度（比单位选中卡更宽：要装训练队列 + 研究）
var _sel_w_bld: float = 0.0
## **ECHO 触感回声**：点选圆环 / 右键涟漪（见 触感回声.gd）
var _echo: RtsEchoFx = null
## **GLYPH 光标符文**：按悬停对象换图标（见 光标术.gd）
var _glyph: RtsGlyphCursor = null

## 底栏底板（一整条奇幻石金板，见 浮雕底板.gd）
var _band_plate: RtsOrnatePlate = null
## 底栏左缘的竖版经验条（单选一个兵时出现；2026-11-08）
var _exp_bar: RtsExpBar = null
## 可弹出式说明文本层（见 说明气泡.gd）
var _tips: RtsTipLayer = null
## 上一次用的底栏高度（内容变化时用来发现"该重摆了"）
var _band_applied: float = 0.0
## 上一次中段的实际宽度（用来发现"内容变宽/变窄了，该重摆"）
var _mid_w_applied: float = 0.0
## 中段左缘（切换形态时用来判断"要不要重摆"）
var _mid_left_applied: float = 0.0
## 上一次是不是"单选紧凑"形态（只有它翻转时才播滑动动画）
var _compact_mode: bool = false
## 首帧还没摆完之前不要播动画（否则开局三块会从 (0,0) 滑进来）
var _booted: bool = false
## 补间表：控件 → Tween
var _slide_tw: Dictionary = {}
## 底栏补间时长（秒）：0.22 够丝滑又不拖沓
const SLIDE_DUR := 0.22
## 整层 HUD 是否显示（F9 切换；录视频时收起）
var _hud_on: bool = true
## 鼠标光标是否要一直藏着（`--all-hidden` 置位；每帧兜一次，防窗口失焦被系统放出来）
var _cursor_hidden: bool = false
## 隐藏 HUD 后那条 2 秒淡出的提示（挂在 CanvasLayer 上，不在 root 里，
## 否则它会跟着一起被藏掉，玩家不知道按什么恢复）
var _hide_hint: Label = null

## 命令卡（_card_h_applied 记录"上一次用于摆位的高度"，用来发现行数变化）
var _card_h_applied: float = 0.0
## 上一次显示的"是否夜晚"（只在翻转时改一次颜色）
var _night_shown: bool = false
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

	_build_band_plate()
	# 经验条：贴在底栏最左缘，两种形态（紧凑/展开）都跟着底板走
	_exp_bar = RtsExpBar.new()
	_exp_bar.visible = false
	root.add_child(_exp_bar)
	RtsTipLayer.bind(self, _exp_bar, func() -> Dictionary:
		var arr: Array = _valid_selection()
		if arr.size() != 1:
			return {}
		return Lex.exp(arr[0] as Node3D))
	_build_tip_layer()
	_build_stats()
	_build_toasts()
	_build_minimap()
	_build_selection_panel()
	_build_selection_grid()
	_build_card()
	_build_overhead()
	_build_pending_label()
	_build_overlay()
	_build_hide_hint()
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
	# --- 录演示视频的两种"干净画面"口径（2026-11-07 玩家要求）---
	#   --ui-hidden  ：只收界面，**保留鼠标光标**。拍摄时还要靠鼠标拖镜头 / 滚轮缩放，
	#                  光标藏了就不知道自己指在哪 —— 这是拍摄的默认档。
	#   --all-hidden ：界面 + 光标全隐藏。成片 / 干净截图用，画面里一个杂质都不留。
	#   两个参数可以同时写（等价于 --all-hidden）；单独写 --all-hidden 也是全隐藏。
	_apply_film_flags()
	if OS.has_environment("UI_AUDIT"):
		_ui_audit()


## 录视频用的显隐开关。**光标口径只在这里定**，别处不要再碰 Input.set_mouse_mode
## （否则 F9 一按、窗口一失焦就会被改回去，现场表现为"录着录着鼠标又冒出来"）。
func _apply_film_flags() -> void:
	var args := OS.get_cmdline_user_args()
	var hide_ui: bool = "--ui-hidden" in args or "--all-hidden" in args
	var hide_cursor: bool = "--all-hidden" in args
	if hide_ui:
		set_hud_visible(false, false)
	_cursor_hidden = hide_cursor
	Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN if hide_cursor
		else Input.MOUSE_MODE_VISIBLE)
	if hide_ui:
		# 读回来再报：日志里写的是**实际生效**的光标状态，不是我们"希望"的状态。
		var m: int = Input.get_mouse_mode()
		print("[HUD] 拍摄模式：界面已收起，鼠标光标%s" % (
			"已隐藏" if m == Input.MOUSE_MODE_HIDDEN else "可见（保留，可拖镜头）"))


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


## 性能计时（探针读它）
static var dbg_usec: int = 0

func _process(delta: float) -> void:
	var _t0: int = Time.get_ticks_usec()
	# 光标兜底：`--all-hidden` 下窗口失焦/切回来会被系统重新放出光标，
	# 只在这里纠一次（正常帧是一次整数比较，量不出开销）。
	if _cursor_hidden and Input.get_mouse_mode() != Input.MOUSE_MODE_HIDDEN:
		Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
	_process_inner(delta)
	RtsHud.dbg_usec += Time.get_ticks_usec() - _t0


func _process_inner(delta: float) -> void:
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
	_poll_hotkeys()
	_clock += delta
	if _clock < REFRESH_INTERVAL:
		return
	_clock = 0.0
	_refresh_stats()
	_refresh_selection()
	_refresh_pending()
	_refresh_card(false)
	# 底栏高度要等控件重排后才算准（命令卡行数变了尤其明显）。
	# 每 0.12s 比对一次"该多高 vs 现在多高"，差 1px 就重摆 ——
	# 否则右下角会裁掉半行字，或者选中卡比命令卡矮一截（就是"一边低一边高"）。
	if _compact_bottom() != _compact_mode:
		# 单选 ⇄ 多选 / 建筑开训：形态变了要重摆（这一步会播 0.22s 的滑动动画）
		_apply_layout()
	elif absf(_band_h() - _band_applied) > 1.0:
		_apply_layout()
	# 中段宽度也会变（队伍数量 / 建筑开始训练），同样按"差多少就重摆"处理。
	# 不比对的话：选中 4 个兵时中段 285 宽，框选 8 个后仍然 285，格子被挤成一团。
	elif absf(_mid_want() - _mid_w_applied) > 8.0:
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
	# 头顶界面**不缩放**：它要用屏幕像素对齐 3D 投影，所以自己铺满视口
	if _overhead != null and is_instance_valid(_overhead):
		var vp_size: Vector2 = vp.get_visible_rect().size
		if absf(_overhead.size.x - vp_size.x) > 1.0 or absf(_overhead.size.y - vp_size.y) > 1.0:
			_overhead.set_anchors_preset(Control.PRESET_FULL_RECT)
			_overhead.size = vp_size
			_overhead.position = Vector2.ZERO
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


## **底部行动带（魔兽式）**：选中卡 + 命令卡 = **同一条带子的两段**。
##
## 2026-10-31 重排（玩家原话"不要一边低一边高"）：
##   旧版两块各自按内容长高、各自贴底，于是选中卡 136 高、命令卡 74 高，
##   上沿相差 60 多像素，读起来像两个随手摆的盒子。
##   现在：一条底板 + 两段等高的段底，同顶同底，中间只留一条缝。
const BAR_GAP := 10.0
## 底板比段底外扩的厚度（上下左右各 6px）
const BAND_PAD := 6.0
## 底栏内容距底板左右边缘的呼吸位（"三块向中间靠拢"就是靠这个值）
const BAND_EDGE := 42.0


## 中段此刻"想要多宽"。
## **只有紧凑形态才跟内容走**：展开形态下中段是"一路贴到命令卡"的，
## 拿内容宽去比会永远不等 → 每 0.12s 重摆一次（抖动）。
func _mid_want() -> float:
	if not _compact_mode:
		return -1.0
	if _building_panel != null and is_instance_valid(_building_panel) \
			and _building_panel.visible and _building_panel.has_method("content_width"):
		return float(_building_panel.call("content_width"))
	if _grid_panel != null and _grid_panel.visible and _sel_grid != null:
		return float(_sel_grid.call("content_width"))
	return 0.0


## 底栏当前该有多高：取三块内容里最高的那个，夹在 [band_h, band_max_h]
func _band_h() -> float:
	if _mets == null:
		return 156.0
	var want: float = _mets.band_h
	# ★ 面板拿到的实高是 band - BAND_PAD*2（_place 里的上下留白），
	#   所以内容高要**先补回这条缝**再比，否则"内容 166 / 实高 154"，
	#   队列小牌会被裁掉下沿（训练视图踩过）。
	var pad2: float = BAND_PAD * 2.0
	if _sel_panel != null and is_instance_valid(_sel_panel) and _sel_panel.visible:
		want = maxf(want, _sel_content_h() + pad2)
	# 建筑面板现在在中段（不再是左段的替身），它的内容高度也要算进来
	if _building_panel != null and is_instance_valid(_building_panel) and _building_panel.visible:
		if _building_panel.has_method("content_height"):
			want = maxf(want, float(_building_panel.call("content_height")) + pad2)
	if _card_panel != null and _card_panel.visible:
		want = maxf(want, _card_height())
	if _sel_grid != null and _grid_panel != null and _grid_panel.visible:
		want = maxf(want, float(_sel_grid.call("content_height")) + pad2)
	return clampf(want, _mets.band_h, _mets.band_max_h)


## 选中卡"内容需要多高"：优先问面板自己的 content_height()，
## 不能用 desired_height()——那个会把 HUD 上一帧灌进去的高度当成最小高度读回来，
## 于是越涨越高、永远回不去。
func _sel_content_h() -> float:
	if _sel_panel == null or not is_instance_valid(_sel_panel):
		return _mets.band_h if _mets != null else 156.0
	if _sel_panel.has_method("content_height"):
		return float(_sel_panel.call("content_height"))
	return float(_sel_panel.call("desired_height"))


## 中段（队伍网格）该不该出现：有单位、且没有选中建筑（建筑有自己的面板）。
## 宽度够不够由 `_apply_layout` 兜底（不够就不显），这里只回答"内容上该不该有"。
func _grid_should_show() -> bool:
	if _sel_grid == null or _grid_panel == null:
		return false
	if bool(_sel_grid.call("is_empty")):
		return false
	if _building_panel != null and is_instance_valid(_building_panel) and _building_panel.visible:
		return false
	return true


## 底栏此刻该不该出现：两段都空（没选中）时整条收起，屏幕干干净净
func _band_visible() -> bool:
	var sel_on: bool = _sel_panel != null and is_instance_valid(_sel_panel) and _sel_panel.visible
	var card_on: bool = _card_panel != null and _card_panel.visible
	var grid_on: bool = _grid_panel != null and _grid_panel.visible
	return sel_on or card_on or grid_on


## 把底栏的所有部件收起来（唯一出口，别在各处零散地写 visible = false）。
##
## 覆盖：左卡（档案板）/ 中段（队伍网格）/ 中段（建筑面板）/ 命令卡 / 石金底板。
## 注意 `_sel_panel` 只是"当前算作左卡"的引用（单位是档案板、建筑是建筑面板），
## 所以这里按**具体控件**收，而不是按 `_sel_panel` 收 —— 否则会漏掉另一半。
func _hide_band_parts() -> void:
	if _dossier != null and is_instance_valid(_dossier):
		_dossier.visible = false
	if _grid_panel != null:
		_grid_panel.visible = false
	if _building_panel != null and is_instance_valid(_building_panel):
		_building_panel.visible = false
	if _card_panel != null:
		_card_panel.visible = false
	if _band_plate != null:
		_band_plate.visible = false
	_sel_panel = null


## 把四块 HUD 钉到四角（窗口变化 / 面板高度变化时都要重摆）
func _apply_layout() -> void:
	if _mets == null or root == null:
		return
	# ★★ **没选中就整条底栏收起**（玩家口径，2026-11-01 再次确认）。
	#
	# 为什么要在这里再挡一道：`_refresh_selection` / `_refresh_card` 各自都会按需
	# 隐藏自己那块面板，但它们是**分两次、在不同时机**跑的（信号一次、8Hz 轮询一次）。
	# 中间任何一步被打断（选中对象死亡、面板重建、命令卡换页），就会留下
	# "某一块还 visible、底板已经没了/或反过来"的中间态 —— 玩家看到的就是
	# "没选中，屏幕下面还挂着一条 UI"。
	# 这里把"空选中"当成唯一判据做硬短路：不管上面谁留了尾巴，一律收干净。
	# ★ 只收底栏这一条带的三块 + 底板，**不要动**资源条/小地图/提示（它们永远在）。
	if _valid_selection().is_empty():
		_hide_band_parts()
	var m: float = _mets.margin

	# 资源条：顶部**居中**（左上让给圆形小地图）
	if _stats_panel != null:
		_place(_stats_panel, 0.5, 0.0, 0.5, 0.0,
				-_mets.stats_w * 0.5, m, _mets.stats_w * 0.5, m + _mets.stats_h)
	# 小地图：左上（圆盘 + 下方图例条）
	# 据点提示：资源条正下方居中（宽度固定 300，和资源条同一条竖轴）
	if _crate_banner != null and _crate_banner.visible:
		_place(_crate_banner, 0.5, 0.0, 0.5, 0.0,
				-150.0, m + _mets.stats_h + 6.0, 150.0, m + _mets.stats_h + 6.0 + 26.0)
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

	# --- 底栏：一条带子，三块内容 ---
	var bh: float = _band_h()
	_band_applied = bh
	if _card != null and _card.has_method("set_tile"):
		_card.call("set_tile", _mets.tile, _mets.card_btn_h)
	if _card != null and _card.has_method("set_compact"):
		_card.call("set_compact", _mets.compact)

	var inner_h: float = bh - BAND_PAD * 2.0
	var cw: float = _mets.card_w
	# 段底 stylebox 的内边距 8 → 面板最小高度 = 内容 + 16，
	# 命令卡自己要**先减掉**这 16，否则整条会高出底板。
	const CARD_PAD := 16.0
	if _card_panel != null:
		if _card != null:
			_card.custom_minimum_size = Vector2(0.0, inner_h - CARD_PAD)
		if absf(_card_panel.custom_minimum_size.x - cw) > 0.5 \
				or absf(_card_panel.custom_minimum_size.y - inner_h) > 0.5:
			_card_panel.custom_minimum_size = Vector2(cw, inner_h)
		_place(_card_panel, 1.0, 1.0, 1.0, 1.0,
				-(m + BAND_PAD + BAND_EDGE + cw), -(m + BAND_PAD + inner_h),
				-(m + BAND_PAD + BAND_EDGE), -(m + BAND_PAD))
	_card_h_applied = inner_h

	# ---------------------------------------------------------------------
	# 三块内容的目标矩形（2026-11-01 第六版，玩家口径）
	#
	#   ① 单选、且没有展开内容：
	#        [信息面板][头像 + 生命/法力][命令卡]      ← 三块**贴着命令卡**，左边全空出来
	#   ② 多选 / 建筑在训练·研究中：
	#        [头像 + 生命/法力][信息面板 → 一路贴到命令卡][命令卡]
	#      头像从右边**丝滑地**滑回最左，信息面板同时展开到命令卡左缘（不留背景缝）
	#
	# 所有坐标都是"设计像素"（root 的尺寸就是设计尺寸），所以可以直接写绝对矩形，
	# 再交给 `_place_smooth` 补间 —— 锚点那套 offset 反算没法做动画。
	# ---------------------------------------------------------------------
	var compact: bool = _compact_bottom()
	var animate: bool = _booted and compact != _compact_mode
	_compact_mode = compact

	var plate_x0: float = m + BAND_PAD
	var content_x0: float = plate_x0 + BAND_EDGE
	var card_left: float = _mets.vw - m - BAND_PAD - BAND_EDGE - cw
	var top_y: float = _mets.vh - m - BAND_PAD - inner_h
	var dw: float = clampf(float(_dossier.call("content_width")) if _dossier != null else 216.0,
			196.0, 320.0)
	var bld_on: bool = _building_panel != null and is_instance_valid(_building_panel) \
			and _building_panel.visible

	# 中段"内容自己想多宽"（只决定紧凑形态下的宽度；展开形态一律铺到命令卡）
	var mid_content: float = 268.0
	if bld_on:
		mid_content = float(_building_panel.call("content_width"))
	elif _sel_grid != null:
		mid_content = float(_sel_grid.call("content_width"))

	var rect_dos: Rect2
	var rect_mid: Rect2
	if compact:
		var room: float = maxf(card_left - BAR_GAP * 2.0 - dw - content_x0, 200.0)
		var mid_w: float = clampf(mid_content, 232.0, room)
		rect_dos = Rect2(card_left - BAR_GAP - dw, top_y, dw, inner_h)
		rect_mid = Rect2(rect_dos.position.x - BAR_GAP - mid_w, top_y, mid_w, inner_h)
	else:
		rect_dos = Rect2(content_x0, top_y, dw, inner_h)
		var mx: float = rect_dos.end.x + BAR_GAP
		rect_mid = Rect2(mx, top_y, maxf(card_left - BAR_GAP - mx, 200.0), inner_h)

	_sel_left = rect_dos.position.x
	_sel_w = rect_dos.size.x
	_sel_w_bld = rect_mid.size.x
	_mid_w_applied = rect_mid.size.x if compact else 0.0
	_mid_left_applied = rect_mid.position.x

	# 中段：建筑选中 → 建筑面板（队列/研究/属性）；否则 → 队伍网格
	if _grid_panel != null:
		var show_grid: bool = (not bld_on) and rect_mid.size.x >= 200.0 \
				and not bool(_sel_grid.call("is_empty"))
		_grid_panel.visible = show_grid and root.visible
		if show_grid:
			_sel_grid.call("set_metrics", rect_mid.size.x - 12.0, inner_h - 12.0, _mets.compact)
	if _dossier != null and is_instance_valid(_dossier):
		_dossier.call("set_metrics", rect_dos.size.x, inner_h, inner_h, _mets.compact)
	if _building_panel != null and is_instance_valid(_building_panel):
		_building_panel.call("set_metrics", rect_mid.size.x, inner_h, inner_h, _mets.compact)

	# 摆位：三块都走补间（切换形态时只有这里会真的动起来）
	_place_smooth(_dossier, rect_dos, animate)
	_place_smooth(_grid_panel, rect_mid, animate)
	_place_smooth(_building_panel, rect_mid, animate)

	# 底板：2026-11-01 第五版 —— **整条底栏长出一块奇幻石金板**。
	#   三块内容全部坐在这块板上：左卡 stylebox 仍是空的（大头像浮在石面上），
	#   信息面板与命令卡只留一圈很淡的凹槽。
	# ★ 2026-11-01 第七版（玩家口径）：**紧凑形态下底板从信息面板左缘起**。
	#   以前底板永远铺满整屏宽，紧凑形态时中段被推到右边，于是左边留下
	#   一大块"什么都没有的石板 + 一枚纹章"——玩家原话："左边就不要再有多余的空白面板"。
	#   现在底板跟着内容走：紧凑 = 只包住 [信息面板][头像][命令卡]；展开 = 铺满。
	#   （plate_left 提到 if 外面：底栏左缘的经验条也要按它定位）
	var plate_left: float = m + BAND_PAD
	if compact:
		plate_left = clampf(rect_mid.position.x - BAND_EDGE, m + BAND_PAD,
				_mets.vw - m - BAND_PAD - 240.0)
	if _band_plate != null:
		_band_plate.visible = _band_visible() and root.visible
		# 走 `_place_smooth`：形态切换时底板要和三块内容一起滑过去，
		# 直接给矩形会出现"面板在滑、底板已经跳到位"的割裂感。
		_place_smooth(_band_plate, Rect2(plate_left, top_y,
				_mets.vw - m - BAND_PAD - plate_left, inner_h), animate)
		# 纹章只画在**真正空出来的那段**；紧凑形态没有空段，整枚收掉。
		var gap_x0: float = plate_left + BAND_EDGE * 0.5
		var gap_x1: float = rect_mid.position.x
		var gap_w: float = gap_x1 - gap_x0
		_band_plate.show_medallion = (not compact) and gap_w >= 260.0
		if _band_plate.show_medallion:
			_band_plate.medallion_x = (gap_x0 + gap_x1) * 0.5 - plate_left

	# 经验条：贴底板左缘外侧（比底板矮 16px，读起来像"挂在板子边上的标尺"）
	if _exp_bar != null:
		var eb_left: float = plate_left - 15.0
		var eb_top: float = top_y + 8.0
		_place_smooth(_exp_bar, Rect2(eb_left, eb_top, RtsExpBar.W, maxf(inner_h - 16.0, 24.0)), animate)

	_place_toasts()
	# 气泡层铺满整个 root：**必须显式摆**，光靠 full-rect 锚点在这套
	# "root 尺寸由 offset 反算"的结构里量到的是 (0,0)，气泡会挤在左上角。
	if _tips != null:
		_place(_tips, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0)
	_place_pending_label()
	_apply_theme_scale()
	_booted = true
	if OS.has_environment("UI_DEBUG"):
		print("[BAND] vw=%.0f band=%.0f compact=%s dos=(%.0f..%.0f) mid=(%.0f..%.0f) card=(%.0f..%.0f)" % [
			_mets.vw, bh, str(compact), rect_dos.position.x, rect_dos.end.x,
			rect_mid.position.x, rect_mid.end.x, card_left, card_left + cw])


## 底栏是否处于"单选紧凑"形态：单选 + 没有展开内容（建筑训练/研究时不算）。
## 玩家口径：单选时头像贴命令卡、信息面板贴头像左边；一多选就把头像滑回最左边。
func _compact_bottom() -> bool:
	var arr: Array = _valid_selection()
	if arr.size() != 1:
		return false
	if _building_panel != null and is_instance_valid(_building_panel) and _building_panel.visible:
		if _building_panel.has_method("is_expanded"):
			return not bool(_building_panel.call("is_expanded"))
	return true


## 绝对摆放（锚点全 0 → position/size 就是设计坐标），可选补间。
## **只给底栏三块用**：其他控件（小地图/资源条/提示）不需要动画。
##
## 这里有两件事必须一起做对：
##   1. 目标变了 → 补间（0.22s）；
##   2. 目标没变但**实际几何被改过**（容器/最小尺寸会偷偷把 size 撑大）→ 直接拉回目标。
##      少了第 2 条，面板会一直停在"上一次更大的那一帧"，下沿直接掉出屏幕。
func _place_smooth(c: Control, r: Rect2, animate: bool) -> void:
	if c == null or not is_instance_valid(c):
		return
	# 锚点转成左上角绝对定位（只在第一次真正改变，之后是零成本判断）
	if not (is_zero_approx(c.anchor_left) and is_zero_approx(c.anchor_top) \
			and is_zero_approx(c.anchor_right) and is_zero_approx(c.anchor_bottom)):
		c.anchor_left = 0.0
		c.anchor_top = 0.0
		c.anchor_right = 0.0
		c.anchor_bottom = 0.0
	# ★ 默认值**不能传 null**：Godot 只在默认值非 null 时才吞掉"没有这个 meta"，
	#   传 null 会直接打一条 ERROR（每帧一条，日志瞬间被刷满）。
	var prev: Variant = c.get_meta("rect_target", Rect2(-99999.0, -99999.0, 0.0, 0.0))
	var same_target: bool = prev is Rect2 and (prev as Rect2).is_equal_approx(r)
	var tw: Variant = _slide_tw.get(c, null)
	var running: bool = tw is Tween and (tw as Tween).is_valid() and (tw as Tween).is_running()
	if same_target and running:
		return
	c.set_meta("rect_target", r)
	var geo_ok: bool = c.position.is_equal_approx(r.position) \
			and c.size.is_equal_approx(r.size)
	if same_target and geo_ok and not animate:
		return
	if running:
		(tw as Tween).kill()
	_slide_tw[c] = null
	if not animate or not c.is_inside_tree() or not c.visible:
		c.position = r.position.round()
		c.size = r.size.round()
		return
	var t := create_tween()
	t.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	t.tween_property(c, "position", r.position, SLIDE_DUR)
	t.parallel().tween_property(c, "size", r.size, SLIDE_DUR)
	_slide_tw[c] = t


## 命令卡当前实际高度（行数自适应：1 行 / 2 行 / 3 行）。
## 取 PanelContainer 的**实测最小尺寸**（含底座内边距），不再自己拿公式对 ——
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

	# 据点资源箱提示条：贴在资源条正下方（居中），平时隐藏
	_crate_banner = PanelContainer.new()
	_crate_banner.name = "据点提示"
	_crate_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb2 := Spec.panel_style(5, 0.92, 0.40, 10.0)
	sb2.border_width_top = 1
	sb2.border_color = Color(0.98, 0.78, 0.36, 0.75)
	_crate_banner.add_theme_stylebox_override("panel", sb2)
	_crate_banner.visible = false
	root.add_child(_crate_banner)
	_crate_label = Spec.label("", Spec.FS_BODY, Color(1.0, 0.88, 0.56))
	_crate_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crate_banner.add_child(_crate_label)

	_gold_label = _stat_pill(hb, "金币", Spec.gold(), false, "coin")
	_wood_label = _stat_pill(hb, "木材", Spec.wood(), false, "wood")
	_food_label = _stat_pill(hb, "人口", Spec.food(), true, "pop")
	# 战斗计时：常驻在资源条末尾，一眼知道打了多久
	_time_label = _stat_pill(hb, "时间", Color(0.80, 0.86, 0.96), false, "clock")


## 资源条上一枚胶囊的说明（金币 / 木材 / 人口 / 时间）
func _resource_tip(title: String) -> Dictionary:
	var pl := Game.player_faction
	match title:
		"金币":
			var g: int = pl.gold if pl != null else 0
			return {"icon": "coin", "icon_color": Spec.gold(), "title": "金币 %d" % g,
				"tag": "主资源", "body": "训练、建造、研究都要花金币。\n由农民在金矿上采集，送回大本营或伐木场结算。",
				"foot": ""}
		"木材":
			var w: int = pl.wood if pl != null else 0
			return {"icon": "wood", "icon_color": Spec.wood(), "title": "木材 %d" % w,
				"tag": "主资源", "body": "造农场 / 兵营 / 箭塔和大部分科技都要木材。\n伐木场是木材专用交汇点，背木头的农民优先去那里。",
				"foot": ""}
		"人口":
			var used: int = pl.food_used() if pl != null else 0
			var cap: int = pl.food_cap() if pl != null else 0
			return {"icon": "pop", "icon_color": Spec.food(), "title": "人口 %d / %d" % [used, cap],
				"tag": "上限", "body": "每个单位都占人口，每座农场 +8 上限。\n人口满了就训练不出新兵（按钮会变灰）。",
				"foot": "空闲 %d" % maxi(cap - used, 0)}
		"时间":
			var secs: int = maxi(0, int(Game.elapsed)) if Game != null else 0
			var dn := _day_night()
			if dn != null:
				var night: bool = bool(dn.call("is_night"))
				var left: float = float(dn.call("seconds_to_turn"))
				return {"icon": "clock",
					"icon_color": Color(0.60, 0.70, 1.0) if night else Color(1.0, 0.86, 0.50),
					"title": "第 %d 天 %s" % [1 + int(Game.elapsed / 210.0), String(dn.call("clock_text"))],
					"tag": "夜晚" if night else "白天",
					"body": "昼夜循环 3.5 分钟一轮。%s\n夜里视野变差，营火与哨塔的照明更有价值。" % (
						"距离天亮还有 %.0f 秒。" % left if night else "距离天黑还有 %.0f 秒。" % left),
					"foot": "本局 %02d:%02d" % [secs / 60, secs % 60]}
			return {"icon": "clock", "icon_color": Color(0.80, 0.86, 0.96),
				"title": "本局 %02d:%02d" % [secs / 60, secs % 60], "tag": "计时",
				"body": "从开局算起的真实时间（暂停也会走）。", "foot": ""}
	return {}


## 一枚资源胶囊：[图标][小字标题][大数字][可选微条]，等宽伸展
##
## 图标替掉了原来的 8×8 色点：色点只能表达"这是另一种资源"，
## 表达不了"这是金币/木头/人口"；玩家点名"没有合适的图标"，指的就是这个位置。
func _stat_pill(parent: Node, title: String, color: Color, with_bar: bool,
		icon_name: String = "") -> Label:
	var pill := PanelContainer.new()
	# PASS（不是 IGNORE）：IGNORE 收不到 mouse_entered，说明气泡永远弹不出来
	pill.mouse_filter = Control.MOUSE_FILTER_PASS
	pill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	RtsTipLayer.bind(self, pill, func() -> Dictionary: return _resource_tip(title))
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
	_menu.add_icon_item(Spec.icon_tex("eye"), "隐藏界面（F9）", 3)
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
		3:
			toggle_hud()


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
		# ---- 游戏速度（玩家口径 2026-11-06：「设置按钮添加：速度设置，可提高或减慢速度」）----
		# 直接写 Engine.time_scale：它只缩放时间步长，不动任何玩法数值口径
		# （射程/伤害/建造时长全是按游戏内秒算的），所以调速度不会让平衡变形。
		vb.add_child(Spec.icon_label_row("gear", "游戏速度", 22.0, Spec.text_main(), Spec.FS_BODY))
		var speed_row := HBoxContainer.new()
		speed_row.add_theme_constant_override("separation", 10)
		_speed_slider = HSlider.new()
		_speed_slider.name = "游戏速度"
		_speed_slider.min_value = 0.5
		_speed_slider.max_value = 3.0
		_speed_slider.step = 0.25
		_speed_slider.custom_minimum_size = Vector2(210.0, 26.0)
		_speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_speed_slider.value = clampf(Engine.time_scale, 0.5, 3.0)
		_speed_label = Spec.label("×%.2f" % _speed_slider.value, Spec.FS_BODY, Spec.text_main())
		_speed_label.name = "速度数值"
		_speed_label.custom_minimum_size = Vector2(58.0, 0.0)
		_speed_slider.value_changed.connect(func(v: float) -> void:
			Engine.time_scale = v
			if _speed_label != null:
				_speed_label.text = "×%.2f" % v)
		speed_row.add_child(_speed_slider)
		speed_row.add_child(_speed_label)
		vb.add_child(speed_row)
		# 复位按钮：玩家很容易把速度调乱后不知道怎么回去（滑块本身看不出"1.0 在哪"）
		var speed_reset := Button.new()
		speed_reset.name = "恢复正常速度"
		speed_reset.text = "恢复正常速度（×1.00）"
		speed_reset.focus_mode = Control.FOCUS_NONE
		speed_reset.add_theme_font_size_override("font_size", Spec.FS_CAPTION)
		speed_reset.pressed.connect(func() -> void:
			Engine.time_scale = 1.0
			if _speed_slider != null:
				_speed_slider.set_value_no_signal(1.0)
			if _speed_label != null:
				_speed_label.text = "×1.00")
		vb.add_child(speed_reset)
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
		_fog_check = CheckButton.new()
		_fog_check.text = "战争迷雾"
		_fog_check.add_theme_font_size_override("font_size", Spec.FS_BODY)
		_fog_check.add_theme_color_override("font_color", Spec.text_main())
		_fog_check.toggled.connect(func(on: bool) -> void:
			var fog := _get_fog()
			if fog != null and fog.has_method("set_enabled"):
				fog.call("set_enabled", on))
		vb.add_child(_fog_check)
	# 每次打开都同步一次真实状态（迷雾/副官节点都可能比面板晚建）
	var fog_now := _get_fog()
	if _adj_check != null:
		_adj_check.set_pressed_no_signal(_adjutant_on())
	if _fog_check != null:
		_fog_check.set_pressed_no_signal(fog_now == null or bool(fog_now.call("is_enabled")))
	_dlg_settings.popup_centered(Vector2i(340, 0))


## 副官当前是否接管（设置面板 / 自检共用；找不到人先补找一次）
func _adjutant_on() -> bool:
	_sync_adjutant()
	if _adjutant == null or not is_instance_valid(_adjutant):
		return false
	return _adjutant.get("enabled") == true


## 迷雾节点（运行时由 RtsFog 加入 fog_system 组）
func _get_fog() -> Node:
	if _fog_node != null and is_instance_valid(_fog_node):
		return _fog_node
	var tree := get_tree()
	if tree != null:
		_fog_node = tree.get_first_node_in_group("fog_system")
	return _fog_node


func _open_team() -> void:
	if _dlg_team == null:
		_dlg_team = AcceptDialog.new()
		_dlg_team.title = "队伍"
		_dlg_team.ok_button_text = "关闭"
		root.add_child(_dlg_team)
	_dlg_team.dialog_text = _team_text()
	_dlg_team.popup_centered(Vector2i(360, 0))


## 队伍面板：本局每个阵营属于哪一队、是敌是友、显示成什么颜色。
## 多队图下"你 / 盟友 / 敌人"必须一眼分清 —— 这里把**显示色**也写出来，
## 和模型染色区、小地图点、选中圈是同一份口径（你蓝 / 盟友青 / 敌人红绿）。
func _team_text() -> String:
	var lines := PackedStringArray()
	var pl := Game.player_faction
	if pl == null:
		return "本局还没有阵营。"
	lines.append("你：%s —— 第 %d 队（%s）" % [pl.display_name, pl.team, _color_name(pl.color)])
	for f in Game.factions:
		if f == null or f == pl:
			continue
		var tag: String = "盟友" if pl.is_ally_of(f) else "敌人"
		lines.append("%s：%s —— 第 %d 队（%s）" % [tag, f.display_name, f.team, _color_name(f.color)])
	lines.append("")
	lines.append("同队 = 盟友：不能互相攻击，队色同源；盟友显示为青色，和你的蓝分开。")
	return "\n".join(lines)


## 显示色的中文名（队伍面板 / 提示语用）。按色相粗分，够读懂就行。
func _color_name(c: Color) -> String:
	var h: float = c.h * 360.0
	if c.s < 0.18:
		return "灰白"
	if h >= 160.0 and h <= 200.0:
		return "青"
	if h >= 190.0 and h < 260.0:
		return "蓝"
	if h >= 260.0 and h < 330.0:
		return "紫"
	if h >= 330.0 or h < 20.0:
		return "红"
	if h >= 20.0 and h < 70.0:
		return "橙黄"
	return "绿"


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
	# 说明走自己的气泡层（和底栏一致）；引擎 tooltip 只留空串免得两套同时弹
	_adj_btn.tooltip_text = ""
	if not bool(_adj_btn.get_meta("tip_on", false)):
		_adj_btn.set_meta("tip_on", true)
		RtsTipLayer.bind(self, _adj_btn, func() -> Dictionary:
			var is_on: bool = _adjutant != null and _adjutant.get("enabled") == true
			return {
				"icon": "flag",
				"icon_color": Color(0.66, 0.90, 0.58) if is_on else Color(0.72, 0.70, 0.66),
				"title": "副官 · " + ("开" if is_on else "关"),
				"tag": "AI 托管",
				"body": ("副官正在替你：补农民、派采集、盖房、带兵推进。\n它不会花光你的钱 —— 总留 480 金 / 140 木给你自己指挥。"
						if is_on else "副官已关闭，全部单位归你手动操作。\n点一下重新开启。"),
				"foot": "点一下" + ("关掉" if is_on else "开启"),
			})


## 底栏的**选中段**：左边紧贴屏幕左缘（不再被小地图挤开），
## 高度由 _apply_layout 统一给，这里只负责"内容多高"，不碰位置。
func _build_selection_panel() -> void:
	_dossier = RtsDossierPanel.new()
	_dossier.name = "选中信息"
	root.add_child(_dossier)

	_building_panel = BUILDING_PANEL_SCRIPT.new() as PanelContainer
	_building_panel.name = "建筑信息"
	_building_panel.visible = false
	_building_panel.custom_minimum_size = Vector2(0.0, 150.0)
	root.add_child(_building_panel)

	_sel_panel = _dossier
	_sel_h = _dossier.desired_height()


## 选中单位网格：底栏中段（左 = 焦点头像，中 = 队伍清单，右 = 命令格）
func _build_selection_grid() -> void:
	_grid_panel = PanelContainer.new()
	_grid_panel.name = "队伍网格底座"
	_grid_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	# 中段只是石板上的一道**浅凹槽**：底色几乎透明（石板自己会透出来），
	# 只留一圈极淡的金线把"这一块是单位信息"框住。
	_grid_panel.add_theme_stylebox_override("panel", Spec.recess_style(0.34))
	_grid_panel.visible = false
	root.add_child(_grid_panel)

	_sel_grid = SELECTION_GRID_SCRIPT.new() as RtsSelectionGrid
	_sel_grid.name = "队伍网格"
	_grid_panel.add_child(_sel_grid)


## 头顶界面：挂在 CanvasLayer 上（**不在 root 里** —— root 带反拉伸缩放，
## 而头顶界面要用屏幕像素对齐 3D 投影），并排到最前面绘制 = 在 HUD 面板之下。
func _build_overhead() -> void:
	_overhead = OVERHEAD_SCRIPT.new() as RtsOverheadUi
	_overhead.name = "头顶界面"
	_overhead.zoom = _zoom
	add_child(_overhead)
	move_child(_overhead, 0)


## 底栏底板：一整条**奇幻石金板**（RtsOrnatePlate 自绘：石面 + 金色内嵌线 +
## 四角铆钉 + 顶心徽记），必须**最早**加入 root —— 兄弟节点按顺序绘制，
## 晚加就会盖住两块面板。
func _build_band_plate() -> void:
	_band_plate = RtsOrnatePlate.new()
	_band_plate.name = "底栏底板"
	_band_plate.kind = RtsOrnatePlate.Kind.BAND
	_band_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_band_plate.visible = false
	root.add_child(_band_plate)


## 说明气泡层：挂在 root 上（跟着 1/zoom 反拉伸走，字号才和面板正文一致），
## z_index 200 → 永远压在所有面板之上。必须在**建面板之前**建好：
## 面板 `_ready` 里就要 `RtsTipLayer.bind()`，找不到层就只能退回引擎 tooltip。
func _build_tip_layer() -> void:
	_tips = RtsTipLayer.new()
	_tips.name = "说明气泡"
	root.add_child(_tips)


## 右下命令卡
func _build_card() -> void:
	_card_panel = PanelContainer.new()
	_card_panel.name = "命令卡底座"
	_card_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 和中段同一套凹槽：石板上的另一块"挖进去的区域"
	_card_panel.add_theme_stylebox_override("panel", Spec.recess_style(0.42))
	root.add_child(_card_panel)

	_card = RtsCommandCard.new()
	_card.name = "命令卡"
	_card_panel.add_child(_card)


## 等待落点的提示（底栏正上方，一个可读的胶囊）
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


## 落点提示：底栏正上方居中
func _place_pending_label() -> void:
	if _pending_box == null or _mets == null:
		return
	var pw: float = minf(_mets.panel_w, 420.0)
	var y: float = _mets.margin + _band_applied + 10.0
	_place(_pending_box, 0.5, 1.0, 0.5, 1.0,
			-pw * 0.5, -y - 26.0, pw * 0.5, -y)


# ===========================================================================
# 界面显隐（F9 / 菜单「隐藏界面」 / --ui-hidden）
# ===========================================================================

## 建一条"界面已隐藏"的提示：它**必须挂在 CanvasLayer 上而不是 root 里**，
## 否则 root.visible=false 会把它一起藏掉，玩家就不知道按什么恢复。
func _build_hide_hint() -> void:
	_hide_hint = Spec.label("", Spec.FS_SUB, Color(0.90, 0.91, 0.88),
			HORIZONTAL_ALIGNMENT_CENTER)
	_hide_hint.name = "隐藏提示"
	_hide_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hide_hint.visible = false
	add_child(_hide_hint)
	_hide_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hide_hint.offset_left = -320.0
	_hide_hint.offset_right = 320.0
	_hide_hint.offset_top = -84.0
	_hide_hint.offset_bottom = -44.0


## 切换整层界面（录演示视频用：战场全屏、零遮挡）
func toggle_hud() -> void:
	set_hud_visible(not _hud_on)


## announce=true 时给一条 2 秒淡出的提示（切换成功后立刻看得见"发生了什么"）
func set_hud_visible(on: bool, announce: bool = true) -> void:
	_hud_on = on
	if root != null:
		root.visible = on
	if not on and _tips != null:
		_tips.dismiss()
	if _overhead != null and is_instance_valid(_overhead):
		_overhead.visible = on
	# 收起界面时，等待落点的胶囊和结算遮罩也跟着走（它们是 root 的子节点，
	# 但 root.visible=false 只是不画，这里额外清一下状态，避免"看不见却吃点击"）
	if not on and _pending_box != null:
		_pending_box.visible = false
	if _glyph != null:
		_glyph.set_process(on)
	if announce:
		_show_hide_hint("界面已隐藏 · F9 恢复" if not on else "界面已显示")
	print("[HUD] 界面%s" % ("隐藏" if not on else "显示"))


func _show_hide_hint(text: String) -> void:
	if _hide_hint == null:
		return
	_hide_hint.text = text
	_hide_hint.modulate.a = 1.0
	_hide_hint.visible = true
	var tw := create_tween()
	tw.tween_interval(1.4)
	tw.tween_property(_hide_hint, "modulate:a", 0.0, 0.5)
	tw.tween_callback(func() -> void: _hide_hint.visible = false)


## 键盘：F9 显隐；Ctrl+A 全选己方；Esc（没有等待落点时）取消选择。
## 走轮询而不是 _unhandled_input：选择系统/指令系统都会吃掉鼠标键盘事件，
## 这里抢事件容易和它们打架（表现就是"按了没反应"或"按一下触发两次"）。
func _poll_hotkeys() -> void:
	if Input.is_action_just_pressed(InputSetup.UI_TOGGLE_HUD):
		toggle_hud()
	if Input.is_action_just_pressed(InputSetup.SEL_ALL):
		_on_select_all()
	if Input.is_action_just_pressed(InputSetup.SEL_CLEAR):
		var cmd := _command_system()
		var pending: bool = cmd != null and cmd.has_method("has_pending") \
			and bool(cmd.call("has_pending"))
		if not pending:
			_on_clear_selection()


## **右侧竖排「框选 / 圈选 / 全选 / 取消」已整块删除**（2026-10-31）。
##
## 为什么删：那四条是"触屏没法拖框"时期的补丁，钉在屏幕右下角、压在战场最热的
## 区域上，和魔兽式的底部行动带互相打架；而桌面上拖框本来就一直在工作
## （选择系统 `set_circle_mode(false)` 是默认档）。功能不丢，入口换成键盘：
##   · Ctrl+A 全选己方部队 / Esc 取消选择（`_poll_hotkeys`）
##   · 框选：直接拖鼠标（默认就是矩形）；圈选是手游手势，桌面用不到。

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
## 2C-5：archer 的 display_name 改为「弩兵」（用户口径），旧名「弓箭手」保留为别名——
## 旧验收脚本/截图命令仍在用中文名，删掉别名会让它们静默失效。
const QA_NAME_MAP := {
	"农民": "peasant", "步兵": "footman", "弓箭手": "archer", "弩兵": "archer",
	"法师": "mage",
	"大本营": "townhall", "兵营": "barracks", "铁匠铺": "blacksmith",
	"农场": "farm", "箭塔": "tower", "金矿": "goldmine", "树": "tree",
}


## `--qa-band-check`：底栏显隐的**回归测试**（无头也能跑，看数字不看截图）。
##
## 验两件事（玩家口径"没选中单位就不显示下面的UI"）：
##   ① 选中己方部队 → 底栏必须出现（底板 + 至少一块内容）；
##   ② 清空选择 → 底栏必须**整条消失**（底板、左卡、中段、命令卡全不可见）。
## 输出一行 `[QA-BAND] 结果：PASS/FAIL`，方便脚本 grep。
func _qa_band_check() -> void:
	await get_tree().create_timer(1.0).timeout
	var sel := get_parent().get_node_or_null("选择系统")
	if sel == null or not sel.has_method("select_units"):
		print("[QA-BAND] 结果：SKIP（找不到选择系统）")
		return
	var picked: Array = []
	for u in Game.all_units():
		var r := u as RtsUnit
		if r == null or not r.is_alive() or r.faction != Game.player_faction:
			continue
		if r.def != null and not r.def.is_building():
			picked.append(r)
		if picked.size() >= 3:
			break
	sel.call("select_units", picked)
	for _i in 3:
		await get_tree().process_frame
	var on_ok: bool = _band_plate != null and _band_plate.visible \
			and _sel_panel != null and _sel_panel.visible
	print("[QA-BAND] 选中 %d 个 → 底栏可见=%s 底板=%s 左卡=%s 命令卡=%s" % [
		picked.size(), str(_band_visible()), str(_band_plate != null and _band_plate.visible),
		str(_sel_panel != null and _sel_panel.visible), str(_card_panel != null and _card_panel.visible)])
	sel.call("select_units", [])
	for _i in 3:
		await get_tree().process_frame
	var off_ok: bool = (_band_plate == null or not _band_plate.visible) \
			and (_dossier == null or not _dossier.visible) \
			and (_grid_panel == null or not _grid_panel.visible) \
			and (_building_panel == null or not _building_panel.visible) \
			and (_card_panel == null or not _card_panel.visible)
	print("[QA-BAND] 清空后 → 底栏可见=%s 底板=%s 左卡=%s 中段=%s 建筑面板=%s 命令卡=%s" % [
		str(_band_visible()),
		str(_band_plate != null and _band_plate.visible),
		str(_dossier != null and _dossier.visible),
		str(_grid_panel != null and _grid_panel.visible),
		str(_building_panel != null and _building_panel.visible),
		str(_card_panel != null and _card_panel.visible)])
	print("[QA-BAND] 结果：%s" % ("PASS" if on_ok and off_ok else "FAIL"))

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
##   --qa-train=<id>[,<id>…]    给选中的第一座建筑排训练（截"训练队列 + 进度条"用）
func _qa_extra_hooks() -> void:
	var over: String = ""
	var want_page: bool = false
	var train: String = ""
	var queue: String = ""
	var hover: String = ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ui-over="):
			over = arg.substr(10)
		elif arg == "--ui-build-page":
			want_page = true
		elif arg.begins_with("--qa-train="):
			train = arg.substr(11)
		elif arg.begins_with("--qa-queue="):
			queue = arg.substr(11)
		elif arg.begins_with("--qa-hover="):
			hover = arg.substr(11)
		elif arg == "--qa-band-check":
			# 底栏显隐回归测试（见 _qa_band_check）
			_qa_band_check()
	if over != "":
		_qa_force_over(over)
	if want_page:
		_qa_open_build_page()
	if not train.is_empty():
		_qa_queue_training(train)
	if not queue.is_empty():
		_qa_fill_queue(queue)
	if not hover.is_empty():
		_qa_hover(hover)


## --qa-queue=<id,id,…>：**不走花钱流程**，直接往训练队列里塞（截 L 型队列 / 翻页用）
func _qa_fill_queue(csv: String) -> void:
	for _i in 30:
		await get_tree().process_frame
	var b: RtsBuilding = null
	for u in _valid_selection():
		var bb := u as RtsBuilding
		if bb != null and bb.is_alive():
			b = bb
			break
	if b == null:
		print("[QA补] --qa-queue 失败：当前没有选中建筑")
		return
	b.train_queue.clear()
	for id in csv.split(",", false):
		b.train_queue.append(StringName(id.strip_edges()))
	print("[QA补] 队列塞入 %d 个（%s）" % [b.train_queue.size(), csv])
	_apply_layout()


## --qa-hover=<节点名>：把说明气泡强制弹在某个控件上（截"可弹出式文本"用）。
## 真人用鼠标悬停，截图脚本没有鼠标 —— 只能直接叫醒气泡层。
func _qa_hover(node_name: String) -> void:
	# 等 48 帧：比 --qa-queue / --qa-train 的 30 帧更晚，
	# 否则队列格还没显示，按名字根本找不到（隐藏节点会被跳过）。
	for _i in 48:
		await get_tree().process_frame
	var c := _find_named(root, node_name)
	if c == null:
		print("[QA补] --qa-hover 没找到控件：%s" % node_name)
		return
	if _tips == null:
		print("[QA补] --qa-hover 失败：没有气泡层")
		return
	var ctl := c as Control
	_tips._enter(ctl)
	_tips._delay = 0.0
	print("[QA补] 说明气泡弹出：%s" % node_name)


## 按名字找控件：**只找可见的**。
## 单位面板和建筑面板都有叫「数值0」的行，按树的顺序会先撞上隐藏的那一份，
## 于是"悬停弹窗"看起来永远不出现（其实是弹在了一个不可见的节点上）。
func _find_named(n: Node, want: String) -> Node:
	var ctl := n as Control
	if ctl != null and not ctl.visible:
		return null
	if String(n.name) == want:
		return n
	for c in n.get_children():
		var hit := _find_named(c, want)
		if hit != null:
			return hit
	return null


## 给当前选中的建筑排训练（验收用）：等选择落定后逐个 queue_train。
## 会打印真实结果，方便判"队列真的排进去了没有"，而不是只看截图猜。
func _qa_queue_training(csv: String) -> void:
	for _i in 30:
		await get_tree().process_frame
	var arr := _valid_selection()
	var b: RtsBuilding = null
	for u in arr:
		var bb := u as RtsBuilding
		if bb != null and bb.is_alive():
			b = bb
			break
	if b == null:
		print("[QA补] --qa-train 失败：当前没有选中建筑")
		return
	for id in csv.split(",", false):
		var ok: bool = bool(b.call("queue_train", StringName(id.strip_edges())))
		print("[QA补] 排训练 %s → %s（队列 %d）" % [id, "成功" if ok else "失败", b.train_queue.size()])
	_apply_layout()


func _qa_force_over(kind: String) -> void:
	for _i in 20:
		await get_tree().process_frame
	_on_game_over(kind != "defeat")
	print("[QA补] 强制结算遮罩：%s" % kind)


func _qa_open_build_page() -> void:
	for _i in 12:
		await get_tree().process_frame
	# 自己选一批农民再开建造页：单靠 --select-id 会和主场景那份 QA 抢选择，
	# 截图经常拍成"步兵 + 常用页"（建造页要求选中里真的有农民）。
	if _valid_selection().is_empty():
		await _qa_select_later("peasant")
		for _i in 3:
			await get_tree().process_frame
	if _card == null:
		return
	_card.enter_build_page()
	_refresh_card(true)
	print("[QA补] 命令卡切到建造页（选择 %d 个）" % _valid_selection().size())


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
	# --qa-single：只选第一个（验收"单选时的数值行"用；多选会按设计隐藏那行）
	# --qa-all   ：把己方**所有**活着的单位都选上（验收多选清单 / 翻页 / 格子宽度）
	for arg in OS.get_cmdline_user_args():
		if arg == "--qa-single":
			picked = [picked[0]]
			break
		if arg == "--qa-all":
			picked.clear()
			for u in Game.all_units():
				var r2 := u as RtsUnit
				if r2 != null and r2.is_alive() and r2.faction == pl and not r2.def.is_building():
					picked.append(r2)
			break
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
		# 有时日系统就显示"游戏内时刻 + ☀/☾"（玩家要知道还有多久天黑），
		# 没有就退回原来的"本局计时"。
		var dn2 := _day_night()
		if dn2 != null:
			_set_label(_time_label, String(dn2.call("clock_text")))
			var night2: bool = bool(dn2.call("is_night"))
			if night2 != _night_shown:
				_night_shown = night2
				_time_label.add_theme_color_override("font_color",
						Color(0.66, 0.76, 1.0) if night2 else Spec.text_main())
		else:
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
	_sync_crate_banner()
	_sync_exp_bar()


## 据点资源箱的顶部倒计时（刷新前 30 秒出现）。
##
## 玩家 2026-11-08：「据点刷新前 30S 要在上面有 UI 提示」。
## 口径：只在**没箱子且剩余 ≤30 秒**时显示；箱子在场就收起来（那时看头顶那块牌）。
func _sync_crate_banner() -> void:
	if _crate_banner == null:
		return
	var sp: Node = Game.strongpoint
	var show_it: bool = false
	var txt: String = ""
	if sp != null and is_instance_valid(sp):
		if not bool(sp.get("crate_active")):
			var left: float = float(sp.call("countdown"))
			if left > 0.0 and left <= 30.0:
				show_it = true
				txt = "据点资源箱 %d 秒后刷新" % int(ceil(left))
	if _crate_banner.visible != show_it:
		_crate_banner.visible = show_it
		_apply_layout()
	if show_it:
		_set_label(_crate_label, txt)


## 经验条：**只在单选一个兵**时出现（多选没有"这个单位多少经验"这回事）。
##
## 玩家 2026-11-08：「选中单个单位后，在下面左侧的信息面板的左边做竖版的经验条 UI，
## 鼠标悬停会显示当前单位有多少经验值、还需多少经验值升级。」
func _sync_exp_bar() -> void:
	if _exp_bar == null:
		return
	var arr: Array = _valid_selection()
	var show_it: bool = arr.size() == 1
	var u: Node3D = arr[0] as Node3D if show_it else null
	if show_it and u != null:
		var d: UnitDef = u.get("def") as UnitDef
		if d == null or d.kind != RtsConst.Kind.UNIT:
			show_it = false
	if _exp_bar.visible != show_it:
		_exp_bar.visible = show_it
		_apply_layout()
	if not show_it:
		return
	var star: int = int(u.get("star_level")) if u.get("star_level") != null else 0
	var cur: float = float(u.get("exp_value")) if u.get("exp_value") != null else 0.0
	var need: float = float(u.call("exp_need")) if u.has_method("exp_need") else 60.0
	var r: float = 1.0 if star >= 3 else clampf((cur - float(star) * need) / maxf(need, 1.0), 0.0, 1.0)
	_exp_bar.set_state(r, star, Spec.accent())


## 幂等写 Label：文本没变就一个字节都不写（避免 8Hz 重排）
func _set_label(lb: Label, txt: String) -> void:
	if lb != null and lb.text != txt:
		lb.text = txt


## 选中信息：**左段永远是选中卡**（单位 / 建筑同一张：头像 + 血条 + 法力条），
## **中段按类型换**：单位 → 数值/队伍清单，建筑 → 训练队列与属性。
## 三段同高，靠 visible 切换；高度变了才重摆，避免每 0.12s 抖一下。
func _refresh_selection() -> void:
	var arr := _valid_selection()
	# 队伍网格 + 头顶界面：**先喂数据再判显隐**（网格的显隐取决于它有没有内容）
	var grid_was: bool = _grid_panel != null and _grid_panel.visible
	var grid_rebuilt: bool = false
	if _sel_grid != null:
		grid_rebuilt = bool(_sel_grid.call("refresh", arr))
	if _overhead != null:
		_overhead.zoom = _zoom
		_overhead.call("set_selection", arr)
	if _grid_panel != null and (_grid_should_show() != grid_was or grid_rebuilt):
		_apply_layout()
	var sole_building: RtsBuilding = null
	if arr.size() == 1:
		var b := arr[0] as RtsBuilding
		if b != null and b.is_alive():
			sole_building = b

	if sole_building != null:
		# 建筑也用同一张选中卡（头像换成本建筑的渲图），中段换建筑面板
		if _dossier != null:
			_dossier.visible = true
			_dossier.refresh(arr)
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
		# 内容高度（不含 HUD 灌进去的最小高度）——底栏靠它决定该多高。
		var h: float = _sel_content_h()
		if OS.has_environment("UI_DEBUG"):
			print("[UI] sel=%s content=%.0f selh=%.0f min=%.0f size=%.0f band=%.0f" % [
				_sel_panel.name, h, _sel_h,
				_sel_panel.get_combined_minimum_size().y, _sel_panel.size.y, _band_h()])
		_sel_h = h
	if _glyph != null:
		_glyph.note_selection(arr)
	# 显隐变了（选中 ↔ 未选中 / 单位 ↔ 建筑）整条底栏都要重摆：
	# 底板要不要出现、两段谁占位，全看这个。
	if _band_visible() != (_band_plate != null and _band_plate.visible):
		_apply_layout()
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
	# 收起时整条底栏要重摆（底板可能只剩选中卡那一半，甚至整条消失）。
	var show: bool = _should_show_card()
	if _card_panel != null and _card_panel.visible != show:
		_card_panel.visible = show
		_apply_layout()
	if not show:
		return
	var sig := _card_signature()
	if force or sig != _card_sig:
		_card_sig = sig
		_card.command_system = _command_system()
		if _building_panel != null and is_instance_valid(_building_panel):
			_building_panel.set("command_system", _command_system())
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
			# 研究状态也进签名：研究开始/结束/满级时命令卡必须重建。
			# ★ **不要把进度塞进签名**：以前写 `id:进度0~10`，研究一次就把整张卡
			#   重建十次（按钮全销毁重建），悬停状态和气泡跟着闪 —— 进度交给
			#   `sync_states` 的 state 回调每 0.12s 就地刷就够了。
			r = String(b.current_research())
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


## 日夜系统（主场景在 4.98 挂上；拿不到就返回 null，界面退回"本局计时"）
func _day_night() -> Node:
	var parent := get_parent()
	if parent == null:
		return null
	var n: Variant = parent.get("day_night")
	if n is Node and is_instance_valid(n as Node):
		return n as Node
	return null


# ===========================================================================
# 信号处理
# ===========================================================================

func _on_resources_changed(_faction: RtsFaction) -> void:
	_refresh_stats()


func _on_selection_changed(units: Array) -> void:
	_selection = units.duplicate()
	# 选择一变就把气泡收掉：否则屏幕上会挂着"上一支部队"的说明
	if _tips != null:
		_tips.dismiss()
	_refresh_selection()
	_refresh_card(true)
	# 形态翻转（单选 ⇄ 多选）要**当帧**就开始滑，不能等 8Hz 那一跳 ——
	# 等的话头像会先僵 0.12s 再动，看起来像卡了一下。
	if _compact_bottom() != _compact_mode:
		_apply_layout()


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

	# 提示条字号 24（≥22）：战场上晃一眼就能读到。
	# ★ 必须开自动折行：长句（"资源不足：神秘圣地需要 180 金"）会让 Label 的
	#   最小宽度顶到 1200+，整条提示冲出屏幕（UI_AUDIT 抓到的越界就是这个）。
	var lb := Spec.label(text, Spec.FS_TITLE, color, HORIZONTAL_ALIGNMENT_CENTER)
	# 短句就让它按内容宽（一条紧凑的胶囊）；长句才给固定宽度 + 折行，
	# 否则"神秘圣地需要 180 金 90 木"这种会把整条提示顶出屏幕。
	if text.length() > 22:
		lb.custom_minimum_size = Vector2(540.0, 0.0)
		lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	# 界面整个收起时，屏幕上没有任何东西吃鼠标 —— 不然还能点中"看不见的按钮"
	if not _hud_on or root == null or not root.visible:
		return false
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
	if _adj_btn != null and _adj_btn.visible and _adj_btn.get_global_rect().has_point(p):
		return true
	if _menu_btn != null and _menu_btn.get_global_rect().has_point(p):
		return true
	return false