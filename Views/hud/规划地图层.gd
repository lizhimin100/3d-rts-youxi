extends Control
## **规划地图层**（2026-11-15 第二版）—— 规划阶段盖在 3D 战场上的那一层"作战图"。
##
## 画三样东西（全部在 `_draw` 里画，不建子节点）：
##   ① **部署预览**（随鼠标实时变）：进攻=虚线箭头 / 防守=蓝区 / 占据=据点金圈；
##   ② **已下达的部署标记**：箭头 / 防区环 / 旗子 / 采集点…
##   ③ **明牌意图**：挂在**每个势力区上方**的图标聚合牌 —— 敌我同格式。
##      只许出现：要造的建筑图标、要训的兵种图标、进攻/防守/占据 + 左路/中路/右路；
##      **不许出现**：哪支小队、多少数量、什么时候出兵（玩家 2026-11-15 点名禁止）。
##
## 为什么锚在"势力区"上而不是大本营头顶：
##   玩家草图要求"意图面板在敌方红色区域上方 / 己方蓝色区域上方"，红蓝区是
##   固定矩形（见 `Views/world/规划沙盘.gd`），沿着它的上边中线挂，两边天然对称。
##
## 为什么挂在 CanvasLayer 上、不进 HUD 的 root：
##   它要用**屏幕像素**对齐 3D 投影（`Camera3D.unproject_position` 返回屏幕坐标），
##   而 root 被 `_zoom` 反拉伸过，混在一起每个坐标都要除一次缩放，容易错。

const Spec := preload("res://Views/hud/界面规格.gd")
const 徽记 := preload("res://Views/hud/徽记.gd")
const WAR := preload("res://Game/ai/战区指令.gd")

const COL_ATTACK := Color(1.0, 0.60, 0.30)
const COL_DEFEND := Color(0.44, 0.72, 1.0)
const COL_CAPTURE := Color(1.0, 0.84, 0.36)
const COL_MOVE := Color(0.62, 0.94, 0.56)
const COL_ENEMY := Color(1.0, 0.40, 0.34)
const COL_MINE := Color(0.42, 0.70, 1.0)

## 重绘节流（秒）：预览要跟手，20Hz 足够，别每帧重画整张图
const REDRAW := 0.05
## 明牌意图牌子：格子边长 / 间距 / 内边距 / 高
const CHIP := 34.0
const CHIP_GAP := 6.0
const PAD := 10.0
const BAR_H := 54.0
## 离势力区上边的距离（像素，会乘 zoom）
const LIFT_PX := 18.0

var zoom: float = 1.0
var _t: float = 0.0
var _pending: float = 0.0
var _font: Font = null
var _mono: Font = null
var _hud: Node = null
## "明牌意图"允许摆放的安全区（屏幕像素；HUD 每次摆位时注入）
var _safe: Rect2 = Rect2(250.0, 210.0, 900.0, 400.0)
## 淡入淡出（换阶段时整层淡掉，绝不硬切）
var _alpha: float = 1.0
var _alpha_target: float = 1.0
## 面板底样式缓存（每帧 new StyleBoxFlat 是浪费）
var _box_mine: StyleBoxFlat = null
var _box_foe: StyleBoxFlat = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "规划地图层"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = Spec.cjk_font()
	_mono = Spec.mono_font()
	_box_mine = _bar_style(COL_MINE)
	_box_foe = _bar_style(COL_ENEMY)
	visible = false


func setup(hud: Node) -> void:
	_hud = hud


func set_zoom(z: float) -> void:
	zoom = clampf(z, 0.5, 2.5)


## HUD 注入"明牌意图"的安全区（避开顶部横条、底部操作面板、右下按钮）
func set_safe_rect(r: Rect2) -> void:
	if r.size.x > 120.0 and r.size.y > 80.0:
		_safe = r


## 淡出（HUD 离开规划阶段时调；淡完自己藏，绝不打断"网格淡出"的节奏）
func dismiss() -> void:
	_alpha_target = 0.0


func appear() -> void:
	visible = true
	_alpha = 0.0
	_alpha_target = 1.0


func _process(delta: float) -> void:
	if not visible and _alpha_target <= 0.0:
		visible = false
		return
	if not visible:
		return
	var vp := get_viewport()
	if vp != null:
		var vp_size: Vector2 = vp.get_visible_rect().size
		if absf(size.x - vp_size.x) > 0.5 or absf(size.y - vp_size.y) > 0.5:
			size = vp_size
			position = Vector2.ZERO
	_t += delta
	# 淡入淡出：0.45s 走到位，改变时写 modulate（画面上所有东西一起淡，最省事）
	if not is_equal_approx(_alpha, _alpha_target):
		_alpha = move_toward(_alpha, _alpha_target, delta / 0.45)
		modulate.a = clampf(_alpha, 0.0, 1.0)
		if _alpha <= 0.001:
			visible = false
			return
	_pending -= delta
	if _pending <= 0.0:
		_pending = REDRAW
		queue_redraw()


func _draw() -> void:
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		return
	_draw_preview(cam)
	_draw_planned(cam)
	_draw_intents(cam)


# ===========================================================================
# ① 部署预览
# ===========================================================================

func _draw_preview(cam: Camera3D) -> void:
	var di := _deploy_node()
	if di == null or not di.has_method("preview"):
		return
	var pv: Dictionary = di.call("preview")
	if pv.is_empty():
		return
	var mode: int = int(pv.get("mode", 0))
	var to: Vector3 = pv.get("to", Vector3.INF)
	if to == Vector3.INF:
		return
	var ok: bool = bool(pv.get("ok", false))
	match mode:
		WAR.ATTACK:
			var from: Vector3 = pv.get("from", Vector3.ZERO)
			var a: Vector2 = _project(cam, _lift(from, 0.7))
			var b: Vector2 = _project(cam, _lift(to, 0.3))
			if a == Vector2.INF or b == Vector2.INF:
				return
			_dashed_line(a, b, Color(COL_ATTACK, 0.92 if ok else 0.45), 3.0 * zoom, 9.0 * zoom)
			_arrow_head(b, (b - a).normalized(), 15.0 * zoom,
					Color(COL_ATTACK, 0.98 if ok else 0.5))
			_ring_world(cam, to, 1.1, Color(COL_ATTACK, 0.9), 2.0 * zoom)
		WAR.DEFEND:
			var r: float = float(pv.get("radius", 10.0))
			_zone_world(cam, to, r, COL_DEFEND, ok)
		WAR.CAPTURE:
			var snap: Variant = pv.get("snap", null)
			var radius: float = 8.0 if snap != null else 6.0
			_zone_world(cam, to, radius, COL_CAPTURE, ok)


# ===========================================================================
# ② 已下达的部署标记
# ===========================================================================

func _draw_planned(cam: Camera3D) -> void:
	var cs := _command_node()
	if cs == null or not cs.has_method("planned_records"):
		return
	var recs: Array = cs.call("planned_records")
	var n: int = mini(recs.size(), 8)
	for i in n:
		var r: Dictionary = recs[i]
		var kind: int = int(r.get("kind", 0))
		var p: Vector3 = r.get("point", Vector3.ZERO)
		if kind == RtsConst.Order.STOP:
			continue
		match kind:
			RtsConst.Order.DEFEND:
				_zone_world(cam, p, 10.0, COL_DEFEND, true, 0.55)
				_mark(cam, p, "defend", COL_DEFEND)
			RtsConst.Order.CAPTURE:
				_mark(cam, p, "capture", COL_CAPTURE)
			RtsConst.Order.ATTACK_MOVE, RtsConst.Order.ATTACK:
				_mark(cam, p, "attack", COL_ATTACK)
			RtsConst.Order.MOVE:
				_mark(cam, p, "move", COL_MOVE)
			RtsConst.Order.GATHER:
				_mark(cam, p, "gather", Color(0.98, 0.86, 0.42))
			RtsConst.Order.BUILD:
				_mark(cam, p, "build", Color(0.82, 0.94, 0.72))
			RtsConst.Order.HOLD:
				_mark(cam, p, "hold", COL_DEFEND)
			_:
				_mark(cam, p, "order", Color(0.9, 0.9, 0.86))


## 一枚"徽记圆牌"（比旧版的单字好认：刀/盾/旗/锤）
func _mark(cam: Camera3D, world: Vector3, kind: String, col: Color) -> void:
	var sp: Vector2 = _project(cam, _lift(world, 0.6))
	if sp == Vector2.INF:
		return
	var r: float = 13.0 * zoom
	var pulse: float = 1.0 + 0.05 * sin(_t * 3.4)
	draw_circle(sp, r * pulse + 2.0, Color(0.0, 0.0, 0.0, 0.45))
	draw_circle(sp, r * pulse, Color(col.r * 0.16, col.g * 0.16, col.b * 0.16, 0.92))
	draw_arc(sp, r * pulse, 0.0, TAU, 26, Color(col, 0.95), 1.8 * zoom, true)
	var glyph := "attack"
	match kind:
		"defend", "hold":
			glyph = "defend"
		"capture":
			glyph = "capture"
		"build":
			glyph = "build"
		"gather":
			glyph = "coin"
		"move":
			glyph = "play"
		"order":
			glyph = "flag"
	徽记.draw_glyph(self, glyph, Rect2(sp - Vector2(r, r) * 0.72, Vector2(r, r) * 1.44), col, 1.0)


# ===========================================================================
# ③ 明牌意图（敌我同格式的图标聚合牌）
# ===========================================================================

## 一块牌子 = 一排图标：建筑 / 兵种 / 命令+方向。
## 位置：势力区矩形上边中点的正上方；多块牌子互相避让，绝不叠在一起。
func _draw_intents(cam: Camera3D) -> void:
	var sb := _sandbox()
	if sb == null:
		return
	var zones: Array = sb.call("zone_list")
	if zones.is_empty():
		return
	var items: Array = []
	for z in zones:
		var chips: Array = _chips_for(z)
		if chips.is_empty():
			continue
		var rect: Rect2 = z["rect"]
		var top_mid := Vector3(rect.position.x + rect.size.x * 0.5, 0.0,
				rect.position.y + 1.0)
		var sp: Vector2 = _project(cam, _lift(top_mid, 0.2))
		if sp == Vector2.INF:
			# 区在镜头外：不挂牌子（比"贴到屏幕边缘"更干净，也不会指错地方）
			continue
		items.append({
			"chips": chips,
			"want": sp,
			"mine": bool(z.get("mine", false)),
		})
	if items.is_empty():
		return
	items.sort_custom(func(a, b): return float(a["want"].y) < float(b["want"].y))
	var stack_bottom: float = -99999.0
	for it in items:
		var chips: Array = it["chips"]
		var bw: float = _bar_width(chips)
		var bh: float = BAR_H
		var want: Vector2 = it["want"]
		var bx: float = clampf(want.x - bw * 0.5, _safe.position.x, _safe.position.x + _safe.size.x - bw)
		var by: float = clampf(want.y - LIFT_PX - bh,
				maxf(_safe.position.y, stack_bottom + 8.0),
				_safe.position.y + _safe.size.y - bh)
		stack_bottom = maxf(stack_bottom, by + bh)
		var box := Rect2(Vector2(bx, by), Vector2(bw, bh))
		_draw_intent_bar(box, chips, bool(it["mine"]), want)


func _draw_intent_bar(box: Rect2, chips: Array, mine: bool, want: Vector2) -> void:
	var col: Color = COL_MINE if mine else COL_ENEMY
	# 底：深色 + 势力色描边（我方蓝 / 敌方红），顶边厚一档做出"作战牌"的味道
	draw_style_box(_box_mine if mine else _box_foe, box)
	# 指向势力区的小尖角
	var tip_x: float = clampf(want.x, box.position.x + 16.0, box.end.x - 16.0)
	if want.y > box.end.y:
		draw_colored_polygon(PackedVector2Array([
			Vector2(tip_x - 7.0, box.end.y),
			Vector2(tip_x + 7.0, box.end.y),
			Vector2(tip_x, box.end.y + 8.0),
		]), Color(col.r, col.g, col.b, 0.85))
	# 牌子被夹到屏幕边缘（势力区在画面外）时：在侧面补一个方向三角，
	# 告诉玩家"这块区在那个方向"。没有它，牌子会读成"凭空挂在屏幕角上"。
	var c0: Vector2 = box.get_center()
	if absf(c0.x - want.x) > box.size.x * 0.5 + 6.0:
		var dir: float = signf(want.x - c0.x)
		var base_pt := Vector2(box.position.x if dir < 0.0 else box.end.x, c0.y)
		draw_colored_polygon(PackedVector2Array([
			base_pt + Vector2(9.0 * dir, 0.0),
			base_pt + Vector2(-2.0 * dir, -7.0),
			base_pt + Vector2(-2.0 * dir, 7.0),
		]), Color(col.r, col.g, col.b, 0.90))
	# 图标格（每个格子的宽度可能不同："路"那一格要留出两个字的宽度）
	var x: float = box.position.x + PAD
	for c in chips:
		var cw: float = _chip_w(c)
		var cr := Rect2(x, box.position.y + (BAR_H - CHIP) * 0.5, CHIP, CHIP)
		_draw_chip(cr, c, col)
		x += cw + CHIP_GAP


## 一个牌子上所有格子的总宽
func _bar_width(chips: Array) -> float:
	var w: float = PAD * 2.0
	for c in chips:
		w += _chip_w(c)
	w += CHIP_GAP * float(maxi(chips.size() - 1, 0))
	return w


func _chip_w(chip: Dictionary) -> float:
	if String(chip.get("kind", "")) == "lane":
		# 箭头格 + 后面两个字
		return CHIP + 4.0 + float(_text_w(String(chip.get("text", "")), 13)) + 2.0
	return CHIP


func _text_w(text: String, fs: int) -> float:
	if _font == null or text.is_empty():
		return 0.0
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			maxi(int(round(float(fs) * zoom)), 9)).x


func _draw_chip(r: Rect2, chip: Dictionary, col: Color) -> void:
	var kind: String = String(chip.get("kind", ""))
	if kind == "cmd":
		# 命令徽记：刀 / 盾 / 旗
		draw_circle(r.get_center(), CHIP * 0.5, Color(0.030, 0.036, 0.048, 0.94))
		draw_arc(r.get_center(), CHIP * 0.5, 0.0, TAU, 22,
				Color(col.r, col.g, col.b, 0.55), 1.2, true)
		徽记.draw_glyph(self, String(chip.get("glyph", "attack")),
				Rect2(r.position + Vector2(5.0, 5.0), r.size - Vector2(10.0, 10.0)),
				Color(chip.get("color", col)), 1.0)
	elif kind == "lane":
		# 方向：一个箭头 + 两个字（左路/中路/右路）
		var c := r.get_center()
		draw_circle(c, CHIP * 0.5, Color(0.030, 0.036, 0.048, 0.94))
		var dir: float = float(chip.get("dir", 1.0))
		var pts := PackedVector2Array([
			c + Vector2(6.0 * dir, 0.0),
			c + Vector2(-3.0 * dir, -6.0),
			c + Vector2(-3.0 * dir, 6.0),
		])
		draw_colored_polygon(pts, Color(col.r, col.g, col.b, 0.95))
		var txt: String = String(chip.get("text", ""))
		_label(r.position + Vector2(CHIP + 4.0, CHIP * 0.5 - 8.5), txt, col, 13)
	else:
		var tex: Texture2D = chip.get("tex", null) as Texture2D
		if tex != null:
			draw_texture_rect(tex, r, false, Color(1, 1, 1, 0.98))
			draw_rect(r, Color(col.r, col.g, col.b, 0.22), false, 1.0)
		else:
			徽记.draw_icon(self, "build", r, Color(0.9, 0.88, 0.82), 0.9)


## 一个势力区该挂哪些图标。
##
## 数据全部**真实可查**（不下结论、不预测）：
##   · 在建建筑 → 建筑图标（`is_constructed == false`）；
##   · 训练队列 → 兵种图标（每座建筑 queue 里的 id，去重后最多 3 个）；
##   · 短局敌方 → 下一波编成（回合控制提供的 id 列表，只给种类不给数量）；
##   · 我方 → 已排的部署计划（进攻/防守/占据）+ 目标在左/中/右哪一路。
func _chips_for(z: Dictionary) -> Array:
	var f: RtsFaction = z.get("faction", null) as RtsFaction
	var mine: bool = bool(z.get("mine", false))
	var out: Array = []
	if f == null or not is_instance_valid(f):
		return out

	# --- 在建建筑（最多 2 个；多到 3 个以上玩家也读不过来）---
	var builds: Array = []
	for b in f.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive() or b.def == null:
			continue
		if bool(b.is_constructed):
			continue
		if builds.size() >= 2:
			break
		builds.append(b.def.id)
	for id in builds:
		var tex := Spec.building_icon(id)
		if tex != null:
			out.append({"kind": "icon", "tex": tex})

	# --- 训练队列（去重、最多 3 种）---
	var trains: Array = []
	for b in f.buildings:
		if b == null or not is_instance_valid(b) or not b.is_alive():
			continue
		var q: Variant = b.get("train_queue")
		if not (q is Array):
			continue
		for id in (q as Array):
			if not trains.has(id):
				trains.append(id)
			if trains.size() >= 3:
				break
		if trains.size() >= 3:
			break
	for id in trains:
		var tex2 := Spec.unit_icon(id)
		if tex2 != null:
			out.append({"kind": "icon", "tex": tex2})

	# --- 短局敌方：下一波的兵种（真的会来，所以是真情报）---
	if not mine and Game.short_match:
		var rc: Node = Game.round_control
		if rc != null and rc.has_method("next_wave_ids"):
			var ids: Array = rc.call("next_wave_ids")
			var shown: int = 0
			for id in ids:
				if shown >= 2:
					break
				var tex3 := Spec.unit_icon(id)
				if tex3 != null:
					out.append({"kind": "icon", "tex": tex3})
					shown += 1

	# --- 命令 + 方向 ---
	# ★ 只有"玩家本人"的区才挂玩家的计划：盟友是同队（蓝色），但它不听玩家指挥，
	#   把玩家的进攻计划挂在盟友区上等于撒谎（实测会同时出现两块"右路/左路"牌子）。
	var is_me: bool = f == Game.player_faction
	var cmd_chip: Dictionary = _plan_chip(is_me, mine)
	if not cmd_chip.is_empty():
		if is_me:
			for id in _plan_defs():
				if out.size() >= 4:
					break
				var tex4 := Spec.unit_icon(StringName(id))
				if tex4 != null:
					out.append({"kind": "icon", "tex": tex4})
		out.append(cmd_chip)
		var lane: Dictionary = _lane_chip(f, is_me, int(cmd_chip.get("kind_id", 0)))
		if not lane.is_empty():
			out.append(lane)
	return out


## 这块势力区"要干什么"：玩家本人读计划表，敌方读"冲着玩家基地去"，盟友不挂命令。
func _plan_chip(is_me: bool, mine: bool) -> Dictionary:
	if is_me:
		var cs := _command_node()
		if cs == null or not cs.has_method("planned_records"):
			return {}
		var recs: Array = cs.call("planned_records")
		# 从最后一条往前找：最新的计划最能代表"我现在想干嘛"
		for i in range(recs.size() - 1, -1, -1):
			var kind: int = int((recs[i] as Dictionary).get("kind", -1))
			match kind:
				RtsConst.Order.ATTACK_MOVE, RtsConst.Order.ATTACK:
					return {"kind": "cmd", "glyph": "attack", "color": COL_ATTACK,
						"kind_id": WAR.ATTACK}
				RtsConst.Order.DEFEND:
					return {"kind": "cmd", "glyph": "defend", "color": COL_DEFEND,
						"kind_id": WAR.DEFEND}
				RtsConst.Order.CAPTURE:
					return {"kind": "cmd", "glyph": "capture", "color": COL_CAPTURE,
						"kind_id": WAR.CAPTURE}
		return {}
	if mine:
		return {}
	# 敌方：短局波次就是冲玩家基地来的
	if Game.short_match:
		return {"kind": "cmd", "glyph": "attack", "color": COL_ATTACK,
			"kind_id": WAR.ATTACK}
	return {}


## 我方最后一条计划里出现的兵种 id（最多 2 种）
func _plan_defs() -> Array:
	var cs := _command_node()
	if cs == null or not cs.has_method("planned_records"):
		return []
	var recs: Array = cs.call("planned_records")
	if recs.is_empty():
		return []
	var defs: Array = (recs[recs.size() - 1] as Dictionary).get("defs", [])
	var out: Array = []
	for d in defs:
		if out.size() >= 2:
			break
		out.append(String(d))
	return out


## 方向：按"目标相对自己的左右"给一路（左路/中路/右路），只给方位不给坐标。
func _lane_chip(f: RtsFaction, is_me: bool, kind_id: int) -> Dictionary:
	if kind_id == WAR.DEFEND:
		return {}
	var lv: Node3D = RtsWorld.level()
	if lv == null:
		return {}
	var base: Vector3 = lv.call("base_center", f) if lv.has_method("base_center") else Vector3.ZERO
	var target := Vector3.ZERO
	if is_me:
		var cs := _command_node()
		if cs == null or not cs.has_method("planned_records"):
			return {}
		var recs: Array = cs.call("planned_records")
		if recs.is_empty():
			return {}
		target = (recs[recs.size() - 1] as Dictionary).get("point", Vector3.ZERO)
		if target == Vector3.ZERO:
			return {}
	else:
		if Game.player_faction == null:
			return {}
		target = lv.call("base_center", Game.player_faction) if lv.has_method("base_center") else Vector3.ZERO
	var dx: float = target.x - base.x
	var txt: String = "中路"
	var dir: float = 1.0
	if dx < -12.0:
		txt = "左路"
		dir = -1.0
	elif dx > 12.0:
		txt = "右路"
		dir = 1.0
	else:
		txt = "中路"
		dir = 1.0
	return {"kind": "lane", "text": txt, "dir": dir}


# ===========================================================================
# 牌子样式
# ===========================================================================

func _bar_style(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.030, 0.036, 0.048, 0.90)
	sb.border_color = Color(col.r, col.g, col.b, 0.80)
	sb.set_border_width_all(1)
	sb.border_width_top = 2
	sb.set_corner_radius_all(6)
	sb.corner_detail = 6
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(0.0, 2.0)
	return sb


# ===========================================================================
# 绘图工具
# ===========================================================================

func _project(cam: Camera3D, world: Vector3) -> Vector2:
	if cam.is_position_behind(world):
		return Vector2.INF
	return cam.unproject_position(world)


## 抬到离地一点（贴地画线会被地形吃掉一半）
func _lift(p: Vector3, up: float) -> Vector3:
	return Vector3(p.x, RtsWorld.height_at(p.x, p.z) + up, p.z)


func _dashed_line(a: Vector2, b: Vector2, col: Color, width: float, dash: float) -> void:
	var d: Vector2 = b - a
	var total: float = d.length()
	if total < 0.5:
		return
	var dir: Vector2 = d / total
	var t: float = 0.0
	while t < total:
		var t2: float = minf(t + dash * 0.55, total)
		draw_line(a + dir * t, a + dir * t2, col, width, true)
		t += dash


func _arrow_head(tip: Vector2, dir: Vector2, size: float, col: Color) -> void:
	if dir.length_squared() < 0.0001:
		return
	var n := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array([
		tip,
		tip - dir * size + n * size * 0.55,
		tip - dir * size - n * size * 0.55,
	])
	draw_colored_polygon(pts, col)


## 世界空间的一个圆环（贴地形采样，投到屏幕上画闭合折线）
func _ring_world(cam: Camera3D, center: Vector3, radius: float, col: Color, width: float) -> void:
	var pts := PackedVector2Array()
	for i in 41:
		var a: float = TAU * float(i) / 40.0
		var w := Vector3(center.x + cos(a) * radius, 0.0, center.z + sin(a) * radius)
		var sp: Vector2 = _project(cam, _lift(w, 0.16))
		if sp == Vector2.INF:
			return
		pts.append(sp)
	draw_polyline(pts, col, width, true)


## 防区：半透明色块 + 虚线外圈 + 中心十字
func _zone_world(cam: Camera3D, center: Vector3, radius: float, col: Color,
		ok: bool, alpha: float = 1.0) -> void:
	var fill := PackedVector2Array()
	var edge := PackedVector2Array()
	for i in 49:
		var a: float = TAU * float(i) / 48.0
		var w := Vector3(center.x + cos(a) * radius, 0.0, center.z + sin(a) * radius)
		var sp: Vector2 = _project(cam, _lift(w, 0.18))
		if sp == Vector2.INF:
			return
		if i < 48:
			fill.append(sp)
		edge.append(sp)
	var a_fill: float = (0.20 if ok else 0.09) * alpha
	draw_colored_polygon(fill, Color(col.r, col.g, col.b, a_fill))
	for i in 48:
		if i % 2 == 0:
			draw_line(edge[i], edge[i + 1], Color(col, 0.92 * alpha), 2.2 * zoom, true)
	var c: Vector2 = _project(cam, _lift(center, 0.4))
	if c != Vector2.INF:
		draw_line(c - Vector2(7, 0) * zoom, c + Vector2(7, 0) * zoom,
				Color(col, 0.9 * alpha), 1.6 * zoom, true)
		draw_line(c - Vector2(0, 7) * zoom, c + Vector2(0, 7) * zoom,
				Color(col, 0.9 * alpha), 1.6 * zoom, true)


func _label(pos: Vector2, text: String, col: Color, fs: int) -> void:
	var size_px: int = maxi(int(round(float(fs) * zoom)), 9)
	draw_string_outline(_font, pos + Vector2(0.0, size_px), text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, size_px, 3, Color(0.0, 0.0, 0.0, 0.72))
	draw_string(_font, pos + Vector2(0.0, size_px), text, HORIZONTAL_ALIGNMENT_LEFT,
			-1, size_px, col)


# ===========================================================================
# 外部节点
# ===========================================================================

## 规划沙盘（3D 势力网格）：红蓝区矩形从它那里拿，保证"牌子挂的区和地上的网格"是同一份数据
func _sandbox() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group("planning_sandbox")


func _command_node() -> Node:
	var host := _hud.get_parent() if _hud != null and is_instance_valid(_hud) else null
	if host == null:
		return null
	return host.get_node_or_null("指令系统")


func _deploy_node() -> Node:
	var host := _hud.get_parent() if _hud != null and is_instance_valid(_hud) else null
	if host == null:
		return null
	return host.get_node_or_null("部署输入")
