extends Control
## **规划地图层（第三版，2026-11-15）** —— 规划阶段盖在 3D 战场上的"作战图"。
##
## 画四样东西（全部在 _draw 里画，不建子节点）：
##   ① 部署预览（进攻虚线箭头 / 防守防区 / 占据据点圈）；
##   ② 已下达的部署标记；
##   ③ **兵牌**：每座建筑一枚缩略图 + 阵营色边框，每个单位小队一枚兵种图标 + "×N"；
##      未建成的建筑 = 半透明 + 虚线框 + 进度条；
##   ④ **明牌意图 / 我方部署**：像战术图钉一样，用一条引线钉在对应**大本营图标**上，
##      而不是旧版"挂在势力方块上边"——挪了基地以后旧口径会挂到空地上。
##
## 为什么兵牌画在 2D 层、不建 Billboard：
##   · 规划阶段模型已经 visible=false，图标必须是屏幕像素尺寸（缩放时不变形）；
##   · 图标要带文字（×N）与虚线框，2D 的 _draw 比 3D Sprite3D 便宜也更清晰；
##   · 投影只做一次（20Hz 重绘），不用给每座建筑挂一个 Label3D/Sprite3D。
##
## 纪律：本层 mouse_filter=IGNORE，绝不拦 3D 点击；只在短局 + 规划阶段出现。

const Spec := preload("res://Views/hud/界面规格.gd")
const 徽记 := preload("res://Views/hud/徽记.gd")
const WAR := preload("res://Game/ai/战区指令.gd")

const COL_ATTACK := Color(1.0, 0.60, 0.30)
const COL_DEFEND := Color(0.40, 0.72, 1.0)
const COL_CAPTURE := Color(1.0, 0.84, 0.36)
const COL_MOVE := Color(0.62, 0.94, 0.56)
const COL_ENEMY := Color(0.92, 0.32, 0.36)
const COL_MINE := Color(0.36, 0.70, 0.98)
const COL_ALLY := Color(0.30, 0.80, 0.82)

## 重绘节流（秒）：预览要跟手，20Hz 足够
const REDRAW := 0.05
## 明牌意图牌子：格子边长 / 间距 / 内边距 / 高
const CHIP := 32.0
const CHIP_GAP := 5.0
const PAD := 10.0
const BAR_H := 52.0
## 兵牌尺寸（屏幕像素，会乘 zoom）
const B_ICON := 46.0
const U_ICON := 36.0
## 图钉引线长度
const PIN_GAP := 14.0

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
var _box_cache: Dictionary = {}
var _plate_cache: Dictionary = {}
## 本帧画出的兵牌矩形（单位图标避让 / 意图牌找锚点）
var _placed_rects: Array = []
var _base_icons: Dictionary = {}
var _panel_rects: Array = []
## 每个阵营的兵牌包围盒（用于把意图牌摆在“整个基地”头顶，而不是单座建筑头顶）
var _faction_bounds: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "规划地图层"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = Spec.cjk_font()
	_mono = Spec.mono_font()
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
	_placed_rects.clear()
	_base_icons.clear()
	_panel_rects.clear()
	_faction_bounds.clear()
	_draw_preview(cam)
	_draw_planned(cam)
	_draw_entities(cam)
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
			_dashed_line(a, b, Color(COL_ATTACK, 0.92 if ok else 0.45), 2.6 * zoom, 9.0 * zoom)
			_arrow_head(b, (b - a).normalized(), 14.0 * zoom,
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
	var r: float = 12.0 * zoom
	var pulse: float = 1.0 + 0.05 * sin(_t * 3.4)
	draw_circle(sp, r * pulse + 2.0, Color(0.0, 0.0, 0.0, 0.42))
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
# ③ 兵牌：建筑缩略图 / 小队兵种图标
# ===========================================================================

func _draw_entities(cam: Camera3D) -> void:
	var sb := _sandbox()
	if sb == null:
		return
	var items: Array = []
	for rec in sb.call("building_items"):
		var node: Variant = rec.get("node", null)
		if node == null or not is_instance_valid(node):
			continue
		var d: UnitDef = rec.get("def", null)
		var pos: Vector3 = rec.get("pos", Vector3.ZERO)
		var constructed: bool = bool(rec.get("constructed", true))
		var h: float = maxf(3.2, float(d.height) if d != null else 4.0)
		if not constructed:
			h = maxf(2.2, h * 0.45)
		var sp: Vector2 = _project(cam, pos + Vector3(0.0, h + 2.2, 0.0))
		if sp == Vector2.INF:
			continue
		var gp: Vector2 = _project(cam, pos)
		items.append({
			"kind": "building", "rec": rec, "d": d, "sp": sp, "gp": gp,
			"size": B_ICON * zoom, "constructed": constructed,
		})
	for rec in sb.call("cluster_items"):
		var d2: UnitDef = rec.get("def", null)
		if d2 == null:
			continue
		var c: Vector3 = rec.get("center", Vector3.ZERO)
		var sp2: Vector2 = _project(cam, c + Vector3(0.0, 3.2, 0.0))
		if sp2 == Vector2.INF:
			continue
		var gp2: Vector2 = _project(cam, c)
		items.append({
			"kind": "unit", "rec": rec, "d": d2, "sp": sp2, "gp": gp2,
			"size": U_ICON * zoom,
		})
	# 远的先画、近的后画（屏幕 y 越小越远）
	items.sort_custom(func(a, b): return float(a["sp"].y) < float(b["sp"].y))
	for it in items:
		if String(it["kind"]) == "building":
			_draw_building_token(it)
		else:
			_draw_unit_token(it)


func _draw_building_token(it: Dictionary) -> void:
	var rec: Dictionary = it["rec"]
	var d: UnitDef = it["d"]
	var sp: Vector2 = it["sp"]
	var gp: Vector2 = it["gp"]
	var s: float = float(it["size"])
	var constructed: bool = bool(it["constructed"])
	var col: Color = rec.get("color", COL_MINE)
	# ★ 建筑兵牌**绝不做图标避让**：它是“这座建筑在战场上的位置”，一旦被推开，
	#   意图牌的图钉就钉到别的建筑/空地上了（2026-11-15 实测：农场把大本营挤下去 200px）。
	var rect := Rect2(sp - Vector2(s, s) * 0.5, Vector2(s, s))
	# ---- 地面锚点 + 引线（“悬浮在实体正上方”的读法） ----
	if gp != Vector2.INF and gp.y > rect.end.y - 2.0:
		draw_circle(gp, 5.0 * zoom, Color(col.r, col.g, col.b, 0.10))
		draw_circle(gp, 2.2 * zoom, Color(col.r, col.g, col.b, 0.80))
		var stem_top := Vector2(rect.get_center().x, rect.end.y)
		draw_line(gp, stem_top, Color(col.r, col.g, col.b, 0.30),
				1.2 * zoom, true)
		draw_circle(stem_top, 2.0 * zoom, Color(col.r, col.g, col.b, 0.55))
	# ---- 铁牌底 ----
	var plate := _plate_style(col, 0.94 if constructed else 0.58, 2 if constructed else 1)
	draw_style_box(plate, rect)
	# 顶边阵营色压条（一眼分敌我）
	draw_rect(Rect2(rect.position + Vector2(2.0, 2.0),
			Vector2(rect.size.x - 4.0, maxf(2.0, 2.4 * zoom))),
			Color(col.r, col.g, col.b, 0.92 if constructed else 0.5), true)
	# ---- 建筑缩略图 ----
	var tex: Texture2D = Spec.building_icon(d.id) if d != null else null
	var inner := rect.grow(-5.0 * zoom)
	if tex != null:
		draw_texture_rect(tex, inner, false,
				Color(1.0, 1.0, 1.0, 0.98 if constructed else 0.46))
	else:
		徽记.draw_icon(self, "build", inner, col, 0.9)
	# ---- 未建成：虚线框 + 进度条（玩家点名：半透明虚线框） ----
	if not constructed:
		_dashed_rect(rect.grow(1.0), Color(col.r, col.g, col.b, 0.90),
				maxf(1.2, 1.4 * zoom), 5.0 * zoom, 4.0 * zoom)
		var prog: float = clampf(float(rec.get("progress", 0.0)), 0.0, 1.0)
		var bx: float = rect.position.x + 5.0 * zoom
		var bw: float = (rect.size.x - 10.0 * zoom) * prog
		var by: float = rect.end.y - 4.0 * zoom
		draw_rect(Rect2(bx, by, rect.size.x - 10.0 * zoom, 2.2 * zoom),
				Color(0.0, 0.0, 0.0, 0.45), true)
		draw_rect(Rect2(bx, by, bw, 2.2 * zoom), Color(col.r, col.g, col.b, 0.95), true)
	# ---- 记录锚点 / 营地包围盒 ----
	var fid: int = rec["faction"].get_instance_id()
	var bb: Dictionary = _faction_bounds.get(fid, {"top": INF, "bottom": -INF})
	bb["top"] = minf(float(bb["top"]), rect.position.y)
	bb["bottom"] = maxf(float(bb["bottom"]), rect.end.y)
	_faction_bounds[fid] = bb
	_placed_rects.append(rect)
	if d != null and _is_townhall(d):
		_base_icons[rec["faction"].get_instance_id()] = {
			"rect": rect, "rec": rec, "sp": sp, "gp": gp,
		}


func _draw_unit_token(it: Dictionary) -> void:
	var rec: Dictionary = it["rec"]
	var d: UnitDef = it["d"]
	var sp: Vector2 = it["sp"]
	var gp: Vector2 = it["gp"]
	var s: float = float(it["size"])
	var col: Color = rec.get("color", COL_MINE)
	var rect := Rect2(sp - Vector2(s, s) * 0.5, Vector2(s, s))
	rect = _avoid(rect, s)
	var c := rect.get_center()
	# ---- 短引线 + 地面点 ----
	if gp != Vector2.INF and gp.y > rect.end.y - 1.0:
		draw_circle(gp, 3.2 * zoom, Color(col.r, col.g, col.b, 0.10))
		draw_circle(gp, 1.8 * zoom, Color(col.r, col.g, col.b, 0.78))
		draw_line(Vector2(c.x, rect.end.y), gp,
				Color(col.r, col.g, col.b, 0.26), 1.0 * zoom, true)
	# ---- 圆形兵牌（比建筑轻一档，读成“小队”） ----
	draw_circle(c + Vector2(0.0, 1.0), s * 0.52, Color(0.0, 0.0, 0.0, 0.45))
	draw_circle(c, s * 0.50, Color(0.040, 0.048, 0.060, 0.94))
	draw_arc(c, s * 0.50, 0.0, TAU, 28, Color(col.r, col.g, col.b, 0.86),
			maxf(1.2, 1.7 * zoom), true)
	var tex: Texture2D = Spec.unit_icon(d.id)
	var inner := rect.grow(-s * 0.16)
	if tex != null:
		draw_texture_rect(tex, inner, false, Color(1.0, 1.0, 1.0, 0.98))
	else:
		徽记.draw_icon(self, "attack", inner, col, 0.9)
	# ---- 数量：×3 ----
	var n: int = int(rec.get("count", 1))
	if n > 1:
		var txt := "×%d" % n
		var fs: int = 12
		var tw: float = _text_w(txt, 12)
		var pw: float = tw + 10.0 * zoom
		var ph: float = 16.0 * zoom
		var pill := Rect2(rect.end.x - pw + 3.0 * zoom, rect.end.y - ph + 3.0 * zoom,
				pw, ph)
		draw_style_box(_pill_style(col), pill)
		_label(Vector2(pill.position.x + 5.0 * zoom,
				pill.position.y + (ph - float(fs) * zoom * 0.82) * 0.5),
				txt, Color(1.0, 0.99, 0.94), fs)
	# 小队兵牌也计入营地包围盒：意图牌不能盖住“×N”兵牌
	var ufid: int = (rec["faction"] as Object).get_instance_id()
	var ubb: Dictionary = _faction_bounds.get(ufid, {"top": INF, "bottom": -INF})
	ubb["top"] = minf(float(ubb["top"]), rect.position.y)
	ubb["bottom"] = maxf(float(ubb["bottom"]), rect.end.y)
	_faction_bounds[ufid] = ubb
	_placed_rects.append(rect)


## 图标避让：只躲“已经画出来的兵牌”，不改变它和实体的归属（引线仍然指回原地）
func _avoid(rect: Rect2, s: float) -> Rect2:
	var out := rect
	for i in 6:
		var hit := false
		for r in _placed_rects:
			if out.intersects(r.grow(3.0 * zoom)):
				hit = true
				break
		if not hit:
			break
		out.position.y += s + 7.0 * zoom
	return out


# ===========================================================================
# ④ 明牌意图 / 我方部署（图钉式，钉在大本营兵牌上）
# ===========================================================================

func _draw_intents(cam: Camera3D) -> void:
	var sb := _sandbox()
	if sb == null:
		return
	var entries: Array = []
	for it in sb.call("faction_items"):
		var f: RtsFaction = it.get("faction", null)
		if f == null or not is_instance_valid(f):
			continue
		var anchor: Dictionary = _base_icons.get(f.get_instance_id(), {})
		if anchor.is_empty():
			continue
		var chips: Array = _chips_for(it)
		var is_me: bool = f == Game.player_faction
		var title: String = "我方部署" if is_me else ("盟军部署" if bool(it.get("mine", false)) else "敌方意图")
		if bool(it.get("mine", false)):
			entries.append({"it": it, "f": f, "anchor": anchor, "chips": chips,
				"title": title, "col": COL_MINE if is_me else COL_ALLY, "is_me": is_me})
		else:
			entries.append({"it": it, "f": f, "anchor": anchor, "chips": chips,
				"title": title, "col": COL_ENEMY, "is_me": false})
	if entries.is_empty():
		return
	# 上方基地先摆，避免下面的牌子把它顶出去
	entries.sort_custom(func(a, b):
		return float((a["anchor"] as Dictionary)["rect"].position.y) < float((b["anchor"] as Dictionary)["rect"].position.y))
	for e in entries:
		_draw_intent_panel(e)


func _draw_intent_panel(e: Dictionary) -> void:
	var anchor: Dictionary = e["anchor"]
	var icon_rect: Rect2 = anchor["rect"]
	var chips: Array = e["chips"]
	var title: String = e["title"]
	var col: Color = e["col"]
	var title_w: float = _text_w(title, 13)
	var chips_w: float = 0.0
	if not chips.is_empty():
		chips_w = _chips_total_w(chips) + 10.0 * zoom
	var bw: float = PAD * 2.0 + title_w + chips_w
	bw = maxf(bw, 128.0 * zoom)
	var bh: float = BAR_H * zoom
	var tx: float = icon_rect.get_center().x - bw * 0.5
	var fid2: int = (e["f"] as Object).get_instance_id()
	var bnd: Dictionary = _faction_bounds.get(fid2, {})
	var cluster_top: float = float(bnd.get("top", icon_rect.position.y))
	var cluster_bottom: float = float(bnd.get("bottom", icon_rect.end.y))
	# ★ 牌子挂在**整个营地**的头顶（营地里还有兵营/农场/塔，挂在单座建筑上必然压住别的兵牌），
	#   图钉再落到大本营兵牌上 —— 这样既“钉住基地”，又不会盖住任何一座建筑。
	var ty: float = cluster_top - PIN_GAP * zoom - bh
	var flipped: bool = false
	# 顶部横条是硬障碍：整块营地已经贴到屏幕顶时，牌子翻到营地下面
	if ty < 96.0 * zoom:
		ty = cluster_bottom + PIN_GAP * zoom
		flipped = true
	var box := Rect2(tx, ty, bw, bh)
	var vp2: Vector2 = get_viewport().get_visible_rect().size
	box.position.x = clampf(box.position.x, _safe.position.x, maxf(_safe.position.x, _safe.end.x - bw))
	box.position.y = clampf(box.position.y, 8.0 * zoom, vp2.y - bh - 8.0 * zoom)
	# 和已摆的牌子避让（同阵营多基地时）
	for pr in _panel_rects:
		if box.intersects((pr as Rect2).grow(6.0 * zoom)):
			box.position.y = (pr as Rect2).position.y - bh - 8.0 * zoom
			flipped = false
			if box.position.y < _safe.position.y:
				box.position.y = (pr as Rect2).end.y + 8.0 * zoom
				flipped = true
	# ---- 图钉引线（先画线，再压牌子） ----
	var pin_x: float = clampf(icon_rect.get_center().x, box.position.x + 14.0 * zoom,
			box.end.x - 14.0 * zoom)
	var panel_pt := Vector2(pin_x, box.end.y if not flipped else box.position.y)
	var icon_pt := Vector2(icon_rect.get_center().x,
			icon_rect.position.y if not flipped else icon_rect.end.y)
	draw_line(panel_pt, icon_pt, Color(col.r, col.g, col.b, 0.48),
			1.3 * zoom, true)
	draw_circle(icon_pt, 3.6 * zoom, Color(0.02, 0.03, 0.04, 0.9))
	draw_arc(icon_pt, 3.6 * zoom, 0.0, TAU, 14, Color(col.r, col.g, col.b, 0.95),
			1.2 * zoom, true)
	draw_circle(panel_pt, 2.2 * zoom, Color(col.r, col.g, col.b, 0.9))
	# ---- 牌子底 ----
	draw_style_box(_bar_style(col), box)
	# ---- 标题 ----
	var fs: int = 13
	var ty2: float = box.position.y + box.size.y * 0.5 - float(fs) * zoom * 0.55
	_label(Vector2(box.position.x + PAD, ty2), title, Color(col.r, col.g, col.b, 0.98), fs)
	# ---- 图标格 ----
	if not chips.is_empty():
		var x: float = box.position.x + PAD + title_w + 10.0 * zoom
		var sep_x: float = x - 7.0 * zoom
		draw_line(Vector2(sep_x, box.position.y + 9.0 * zoom),
				Vector2(sep_x, box.end.y - 9.0 * zoom),
				Color(col.r, col.g, col.b, 0.22), 1.0, true)
		for c in chips:
			var cw: float = _chip_w(c)
			var cr := Rect2(x, box.position.y + (box.size.y - CHIP * zoom) * 0.5,
					cw, CHIP * zoom)
			_draw_chip(cr, c, col)
			x += cw + CHIP_GAP * zoom
	_panel_rects.append(box)


## 这块阵营该挂哪些图标（数据全部真实可查，不预测）
func _chips_for(it: Dictionary) -> Array:
	var f: RtsFaction = it.get("faction", null)
	var mine: bool = bool(it.get("mine", false))
	var out: Array = []
	if f == null or not is_instance_valid(f):
		return out
	var is_me: bool = (Game.player_faction != null and f == Game.player_faction)

	# --- 在建建筑（最多 2 个）---
	var builds: Array = []
	for rec in it.get("buildings", []):
		if bool(rec.get("constructed", true)):
			continue
		if builds.size() >= 2:
			break
		var d: UnitDef = rec.get("def", null)
		if d != null:
			builds.append(d.id)
	for id in builds:
		var tex := Spec.building_icon(id)
		if tex != null:
			out.append({"kind": "icon", "tex": tex, "color": it.get("color", COL_MINE)})

	# --- 训练队列（去重、最多 3 种）---
	var trains: Array = []
	for rec in it.get("buildings", []):
		var node: Variant = rec.get("node", null)
		if node == null or not is_instance_valid(node):
			continue
		var q: Variant = (node as Node).get("train_queue")
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
			out.append({"kind": "icon", "tex": tex2, "color": it.get("color", COL_MINE)})

	# --- 短局敌方：下一波兵种（明牌情报，只给种类不给数量）---
	if not mine and Game.short_match:
		var rc: Node = Game.round_control
		if rc != null and rc.has_method("next_wave_ids"):
			var ids: Array = rc.call("next_wave_ids")
			var shown: int = 0
			for id in ids:
				if shown >= 3:
					break
				var tex3 := Spec.unit_icon(id)
				if tex3 != null:
					out.append({"kind": "icon", "tex": tex3, "color": it.get("color", COL_ENEMY)})
					shown += 1

	# --- 命令 + 方向（只挂玩家本人；盟友不听玩家指挥，挂上去等于撒谎）---
	var cmd_chip: Dictionary = _plan_chip(is_me, mine)
	if not cmd_chip.is_empty():
		if is_me:
			for id in _plan_defs():
				if out.size() >= 5:
					break
				var tex4 := Spec.unit_icon(StringName(id))
				if tex4 != null:
					out.append({"kind": "icon", "tex": tex4, "color": COL_MINE})
		out.append(cmd_chip)
		var lane: Dictionary = _lane_chip(f, is_me, int(cmd_chip.get("kind_id", 0)))
		if not lane.is_empty():
			out.append(lane)
	# --- 空牌子：给一句“现在没东西”的提示，不要留一块空黑条 ---
	if out.is_empty():
		var hint := "未下达部署" if mine else "未发现意图"
		out.append({"kind": "text", "text": hint,
			"color": it.get("color", COL_MINE)})
	return out


## 这块阵营“要干什么”：玩家本人读计划表，敌方读“冲着玩家基地去”，盟友不挂命令。
func _plan_chip(is_me: bool, mine: bool) -> Dictionary:
	if is_me:
		var cs := _command_node()
		if cs == null or not cs.has_method("planned_records"):
			return {}
		var recs: Array = cs.call("planned_records")
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
	if Game.short_match:
		return {"kind": "cmd", "glyph": "attack", "color": COL_ATTACK,
			"kind_id": WAR.ATTACK}
	return {}


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
	return {"kind": "lane", "text": txt, "dir": dir}


# ===========================================================================
# 图标 / 牌子样式
# ===========================================================================

func _chips_total_w(chips: Array) -> float:
	var w: float = 0.0
	for c in chips:
		w += _chip_w(c)
	w += CHIP_GAP * zoom * float(maxi(chips.size() - 1, 0))
	return w


func _chip_w(chip: Dictionary) -> float:
	var kind := String(chip.get("kind", ""))
	if kind == "lane":
		return (CHIP + 4.0 + _text_w(String(chip.get("text", "")), 12) + 2.0) * zoom
	if kind == "text":
		return (_text_w(String(chip.get("text", "")), 12) + 10.0) * zoom
	return CHIP * zoom


func _text_w(text: String, fs: int) -> float:
	if _font == null or text.is_empty():
		return 0.0
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			maxi(int(round(float(fs) * zoom)), 9)).x


func _draw_chip(r: Rect2, chip: Dictionary, col: Color) -> void:
	var kind: String = String(chip.get("kind", ""))
	if kind == "cmd":
		draw_circle(r.get_center(), r.size.y * 0.5, Color(0.030, 0.036, 0.048, 0.94))
		draw_arc(r.get_center(), r.size.y * 0.5, 0.0, TAU, 22,
				Color(col.r, col.g, col.b, 0.55), 1.2, true)
		徽记.draw_glyph(self, String(chip.get("glyph", "attack")),
				Rect2(r.position + Vector2(5.0, 5.0) * zoom,
					r.size - Vector2(10.0, 10.0) * zoom),
				Color(chip.get("color", col)), 1.0)
	elif kind == "lane":
		var c := r.get_center()
		draw_circle(c, r.size.y * 0.5, Color(0.030, 0.036, 0.048, 0.94))
		var dir: float = float(chip.get("dir", 1.0))
		var pts := PackedVector2Array([
			c + Vector2(6.0 * zoom * dir, 0.0),
			c + Vector2(-3.0 * zoom * dir, -6.0 * zoom),
			c + Vector2(-3.0 * zoom * dir, 6.0 * zoom),
		])
		draw_colored_polygon(pts, Color(col.r, col.g, col.b, 0.95))
		var txt: String = String(chip.get("text", ""))
		_label(Vector2(r.position.x + CHIP * zoom + 4.0 * zoom,
				r.position.y + r.size.y * 0.5 - 7.0 * zoom), txt, col, 12)
	elif kind == "text":
		var t: String = String(chip.get("text", ""))
		_label(Vector2(r.position.x + 2.0 * zoom, r.position.y + r.size.y * 0.5 - 7.0 * zoom),
				t, Color(col.r, col.g, col.b, 0.85), 12)
	else:
		var tex: Texture2D = chip.get("tex", null) as Texture2D
		var ir := r.grow(-2.0 * zoom)
		draw_style_box(_chip_style(col), ir)
		if tex != null:
			draw_texture_rect(tex, ir.grow(-2.0 * zoom), false, Color(1, 1, 1, 0.98))
		else:
			徽记.draw_icon(self, "build", ir, Color(0.9, 0.88, 0.82), 0.9)


func _plate_style(col: Color, alpha: float, border: int) -> StyleBoxFlat:
	var key: String = "p:%s:%.2f:%d" % [col.to_html(false), alpha, border]
	if _plate_cache.has(key):
		return _plate_cache[key] as StyleBoxFlat
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.034, 0.041, 0.054, alpha)
	sb.border_color = Color(col.r, col.g, col.b, 0.78 if border > 1 else 0.5)
	sb.set_border_width_all(border)
	sb.set_corner_radius_all(6)
	sb.corner_detail = 6
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	sb.shadow_size = 5
	sb.shadow_offset = Vector2(0.0, 2.0)
	_plate_cache[key] = sb
	return sb


func _bar_style(col: Color) -> StyleBoxFlat:
	var key: String = "b:%s" % col.to_html(false)
	if _box_cache.has(key):
		return _box_cache[key] as StyleBoxFlat
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.028, 0.034, 0.046, 0.93)
	sb.border_color = Color(col.r, col.g, col.b, 0.78)
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.set_corner_radius_all(6)
	sb.corner_detail = 6
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.46)
	sb.shadow_size = 8
	sb.shadow_offset = Vector2(0.0, 3.0)
	_box_cache[key] = sb
	return sb


func _chip_style(col: Color) -> StyleBoxFlat:
	var key: String = "c:%s" % col.to_html(false)
	if _box_cache.has(key):
		return _box_cache[key] as StyleBoxFlat
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.055, 0.062, 0.078, 0.92)
	sb.border_color = Color(col.r, col.g, col.b, 0.42)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.corner_detail = 6
	_box_cache[key] = sb
	return sb


func _pill_style(col: Color) -> StyleBoxFlat:
	var key: String = "l:%s" % col.to_html(false)
	if _box_cache.has(key):
		return _box_cache[key] as StyleBoxFlat
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.020, 0.026, 0.036, 0.94)
	sb.border_color = Color(col.r, col.g, col.b, 0.70)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.corner_detail = 6
	_box_cache[key] = sb
	return sb


# ===========================================================================
# 绘图工具
# ===========================================================================

func _project(cam: Camera3D, world: Vector3) -> Vector2:
	if cam.is_position_behind(world):
		return Vector2.INF
	var sp: Vector2 = cam.unproject_position(world)
	var vs: Vector2 = get_viewport().get_visible_rect().size
	if sp.x < -90.0 or sp.y < -90.0 or sp.x > vs.x + 90.0 or sp.y > vs.y + 90.0:
		return Vector2.INF
	return sp


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


## 虚线矩形（未建成建筑兵牌用）：沿四条边逐段画，不依赖任何贴图
func _dashed_rect(rect: Rect2, col: Color, width: float, dash: float, gap: float) -> void:
	var pts: Array = [
		rect.position, Vector2(rect.end.x, rect.position.y),
		rect.end, Vector2(rect.position.x, rect.end.y),
	]
	for i in 4:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % 4]
		var d: Vector2 = b - a
		var total: float = d.length()
		if total < 0.5:
			continue
		var dir: Vector2 = d / total
		var t: float = 0.0
		while t < total:
			var t2: float = minf(t + dash, total)
			draw_line(a + dir * t, a + dir * t2, col, width, true)
			t += dash + gap


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
	var a_fill: float = (0.30 if ok else 0.12) * alpha
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


func _is_townhall(d: UnitDef) -> bool:
	if d == null:
		return false
	if not d.is_dropoff or not d.dropoff_kinds.is_empty():
		return false
	return d.food_provided > 0


# ===========================================================================
# 外部节点
# ===========================================================================

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
