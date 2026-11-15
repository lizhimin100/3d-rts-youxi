extends Control
## **敌方意图条（执行阶段）** —— 规划阶段那张"明牌意图"牌子的**常驻版**。
##
## 玩家口径（2026-11-15 第四条）："敌方意图UI在上方，进入实时战斗视角"。
## 也就是说：进执行阶段以后，这张牌子不许消失，要挪到屏幕上方继续挂着 ——
## 否则玩家打完一回合就不知道下一波是什么，规划阶段给的"情报优势"白给。
##
## 显示粒度与规划阶段**完全一致**（同一条纪律）：
##   · 只有：兵种图标 + 进攻徽记 + 左路/中路/右路；
##   · 没有：数量、具体时刻、哪支小队。
##
## 数据来源：回合控制.next_wave_ids()（短局脚本波次）。
## 长局 / 非短局一律隐藏（长局没有"波次"这回事）。

const Spec := preload("res://Views/hud/界面规格.gd")
const 徽记 := preload("res://Views/hud/徽记.gd")

const CHIP := 26.0
const GAP := 5.0
const PAD := 8.0
const H := 38.0
const COL := Color(1.0, 0.42, 0.34)

var _chips: Array = []
var _sig: String = ""
var _t: float = 0.0


func _ready() -> void:
	name = "敌方意图条"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	custom_minimum_size = Vector2(150.0, H)


## 该不该出现：短局 + 不在规划阶段 + 对局没结束
func should_show() -> bool:
	if Game == null or not Game.short_match:
		return false
	if Game.has_method("is_over") and bool(Game.call("is_over")):
		return false
	if Game.is_planning():
		return false
	var rc: Node = Game.round_control
	if rc == null or not rc.has_method("next_wave_ids"):
		return false
	return not (rc.call("next_wave_ids") as Array).is_empty()


func _process(delta: float) -> void:
	_t += delta
	var on: bool = should_show()
	if on != visible:
		visible = on
		if on:
			_sig = ""
			queue_redraw()
	if not on:
		return
	if fmod(_t, 0.35) < delta:
		_rebuild()


func _rebuild() -> void:
	var rc: Node = Game.round_control
	var ids: Array = rc.call("next_wave_ids") if rc != null else []
	var chips: Array = []
	for id in ids:
		var tex := Spec.unit_icon(id)
		if tex != null:
			chips.append({"kind": "icon", "tex": tex})
	chips.append({"kind": "cmd", "glyph": "attack"})
	var lane: String = _lane_text()
	if lane != "":
		chips.append({"kind": "lane", "text": lane})
	var sig := ""
	for c in chips:
		sig += String(c.get("kind", "")) + String(c.get("text", "")) + "\u0001"
	if sig == _sig:
		return
	_sig = sig
	_chips = chips
	var w: float = PAD * 2.0 + float(chips.size()) * CHIP + GAP * float(maxi(chips.size() - 1, 0))
	for c in chips:
		if String(c.get("kind", "")) == "lane":
			w += 4.0 + 34.0
	custom_minimum_size = Vector2(w, H)
	size = Vector2(w, H)
	queue_redraw()


## 方向：从敌方基地指向玩家基地，只给"左/中/右"
func _lane_text() -> String:
	var lv: Node3D = RtsWorld.level()
	if lv == null or Game.player_faction == null:
		return ""
	var me: Vector3 = lv.call("base_center", Game.player_faction)
	var foe: RtsFaction = null
	for f in Game.factions:
		if f != null and Game.player_faction.is_enemy_of(f):
			foe = f
			break
	if foe == null:
		return ""
	var base: Vector3 = lv.call("base_center", foe)
	var dx: float = me.x - base.x
	if dx < -12.0:
		return "左路"
	if dx > 12.0:
		return "右路"
	return "中路"


func _draw() -> void:
	if _chips.is_empty():
		return
	var box := Rect2(Vector2.ZERO, size)
	if box.size.x < 40.0:
		return
	# 底：暗色 + 敌方红描边（和规划阶段的牌子同一套观感，只做小一号）
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.038, 0.030, 0.032, 0.86)
	sb.border_color = Color(COL.r, COL.g, COL.b, 0.62)
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.set_corner_radius_all(6)
	sb.corner_detail = 6
	draw_style_box(sb, box)
	var x: float = box.position.x + PAD
	for c in _chips:
		var kind: String = String(c.get("kind", ""))
		if kind == "lane":
			var dir: float = 1.0
			var c0 := Vector2(x + CHIP * 0.5, box.position.y + H * 0.5)
			draw_circle(c0, CHIP * 0.5, Color(0.030, 0.036, 0.048, 0.92))
			draw_colored_polygon(PackedVector2Array([
				c0 + Vector2(5.0 * dir, 0.0),
				c0 + Vector2(-3.0 * dir, -5.0),
				c0 + Vector2(-3.0 * dir, 5.0),
			]), Color(COL.r, COL.g, COL.b, 0.95))
			var f: Font = Spec.cjk_font()
			draw_string(f, Vector2(x + CHIP + 6.0, box.position.y + H * 0.5 + 4.5),
					String(c.get("text", "")), HORIZONTAL_ALIGNMENT_LEFT, -1,
					Spec.FS_CAPTION, Color(1.0, 0.86, 0.80))
			x += CHIP + 4.0 + 34.0 + GAP
		elif kind == "cmd":
			var cc := Vector2(x + CHIP * 0.5, box.position.y + H * 0.5)
			draw_circle(cc, CHIP * 0.5, Color(0.030, 0.036, 0.048, 0.92))
			draw_arc(cc, CHIP * 0.5, 0.0, TAU, 20, Color(COL.r, COL.g, COL.b, 0.55), 1.2, true)
			徽记.draw_glyph(self, String(c.get("glyph", "attack")),
					Rect2(x + 4.0, box.position.y + (H - CHIP) * 0.5 + 4.0,
						CHIP - 8.0, CHIP - 8.0), Color(1.0, 0.72, 0.52), 1.0)
			x += CHIP + GAP
		else:
			var tex: Texture2D = c.get("tex", null) as Texture2D
			if tex != null:
				var r := Rect2(x, box.position.y + (H - CHIP) * 0.5, CHIP, CHIP)
				draw_texture_rect(tex, r, false, Color(1, 1, 1, 0.98))
				draw_rect(r, Color(COL.r, COL.g, COL.b, 0.22), false, 1.0)
			x += CHIP + GAP
