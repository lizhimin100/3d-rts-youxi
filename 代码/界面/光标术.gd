class_name RtsGlyphCursor
extends Node
## **GLYPH（光标符文）** —— 鼠标指到不同对象上换不同图标。
##
## 为什么不用外部图片：图标是**代码画出来的**（`Image` + 手工光栅化），
## 这样没有资源依赖、没有导入设置、换色只改一行常量，也不会有人往工程里塞盗来的素材。
##
## 六种形态（全部 32×32，带 1px 深色描边，保证在草地/雪地/夜空上都读得出来）：
##   · 默认     白箭头                      —— 地面 / 界面 / 中立空物
##   · 己方单位 绿箭头 + 十字徽标            —— 可以指挥的东西
##   · 盟友单位 **青箭头 + 盾形徽标**         —— 同队 AI：能并肩、不能打
##   · 敌方单位 红剑（斜刃 + 横向护手 + 金柄） —— 右键就是打
##   · 可采集物 黄镐（弯头 + 木柄）           —— 只有**选中的是农民**时才亮
##   · 己方建筑 铁锤（斜置锤头）             —— 只有**选中的是农民**时才亮
##
## ★ 敌我判据只有一条：Game.is_ally_of_player(faction)（同队 = 盟友）。
##   旧版写的是 faction == Game.player_faction，于是**盟友全部落进"敌方"分支** ——
##   鼠标一放到盟友身上就变红剑，玩家以为要打自己人（用户报的"盟友身上显示攻击图标"）。
##
## 性能纪律：
##   · 拾取是纯数学（射线 × 竖直胶囊），**不碰物理引擎**，也不为了光标去开物理层；
##   · 每 5 帧才拾一次，图标切换再叠 60ms 节流 —— 不做"每帧 set_cursor"这种既丑又费的蠢事；
##   · headless 下整个模块直接躺平（没有鼠标，调了也是空转）。

## 每几帧拾取一次
const PICK_EVERY := 5
## 图标切换节流（毫秒）
const SWITCH_MS := 60
## 图标边长
const ICON := 32

## 六种图标索引
enum Shape {
	ARROW = 0,
	ALLY = 1,       ## 自己的
	ENEMY = 2,
	PICK = 3,
	HAMMER = 4,
	TEAMMATE = 5,   ## 同队盟友（青）
}

## 生成的贴图（建一次，全程复用）
var _tex: Array[ImageTexture] = []
## 当前正在用的形态
var _current: int = -1
## 上次切换时刻（毫秒）
var _last_switch_ms: int = -1000
## 帧计数
var _frame: int = 0
## HUD 喂进来的选中（只用来判"是不是农民"）
var _selection: Array = []
var _has_worker: bool = false
## headless / 无鼠标时躺平
var _dormant: bool = false


# ===========================================================================
# 生命周期
# ===========================================================================

func _ready() -> void:
	name = "光标符文"
	_dormant = DisplayServer.get_name() == "headless"
	var dump: bool = "--dump-cursors" in OS.get_cmdline_user_args()
	# headless 下没有鼠标，连图标都不生成（省得在退出时占着 5 张纹理不放）
	if not _dormant or dump:
		_build_icons()
	if not _dormant:
		_apply(Shape.ARROW, true)
	if dump and not _tex.is_empty():
		_dump_icons()
	if "--cursor-probe" in OS.get_cmdline_user_args():
		_probe.call_deferred()


## **自检（只跑在 `--cursor-probe` 下）**：把若干目标投到屏幕上，再用同一套拾取逻辑
## 反查一遍，看它是不是真的分得出"己方 / 敌方 / 资源 / 建筑"。
## 这条不验证操作系统指针（那玩意不进截图），验证的是**判定链路**。
func _probe() -> void:
	for _i in 8:
		await get_tree().process_frame
	await get_tree().create_timer(1.2).timeout
	var vp := get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam == null:
		print("[光标自检] 没有相机，跳过")
		return
	var names := ["默认箭头", "己方绿箭头", "敌方红剑", "黄色镐", "铁锤", "盟友青箭头"]
	print("[光标自检] ---- 开始 ----")
	_has_worker = false
	_probe_group(cam, names, _group_player(), 2, false)
	_probe_group(cam, names, _group_ally(), 2, false)
	_probe_group(cam, names, _group_enemy(), 2, false)
	_probe_group(cam, names, _group_own_buildings(), 1, false)
	_probe_group(cam, names, _group_harvest(), 2, false)
	print("[光标自检] （模拟选中农民后）")
	_has_worker = true
	_probe_group(cam, names, _group_own_buildings(), 1, true)
	_probe_group(cam, names, _group_harvest(), 2, true)
	_has_worker = false
	# 空地：屏幕左下角 → 应该是默认箭头
	var mid := Vector2(vp.get_visible_rect().size.x * 0.22, vp.get_visible_rect().size.y * 0.80)
	var ground := _pick(cam.project_ray_origin(mid), cam.project_ray_normal(mid))
	print("[光标自检] 空地处命中=%s → %s" % [
		"无" if ground == null else String(ground.name), names[_shape_for(ground)]])
	print("[光标自检] ---- 结束 ----")


func _group_player() -> Array:
	var out: Array = []
	var pl := Game.player_faction
	if pl == null:
		return out
	for u in pl.units:
		if u != null and is_instance_valid(u) and not (u is RtsBuilding) and (u as RtsUnit).is_alive():
			out.append(u)
	return out


func _group_own_buildings() -> Array:
	var out: Array = []
	var pl := Game.player_faction
	if pl == null:
		return out
	for b in pl.buildings:
		if b != null and is_instance_valid(b) and (b as RtsUnit).is_alive():
			out.append(b)
	return out


## 全部**敌对**单位（不含盟友 —— 旧版把盟友也塞进来，自检才会"验不出"这个 bug）
func _group_enemy() -> Array:
	var out: Array = []
	var pl := Game.player_faction
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var r := u as RtsUnit
		if r == null or not r.is_alive():
			continue
		if r.faction != null and pl != null and pl.is_enemy_of(r.faction):
			out.append(r)
	return out


## 全部盟友单位（同队、不是自己）
func _group_ally() -> Array:
	var out: Array = []
	var pl := Game.player_faction
	for u in Game.all_units():
		if u == null or not is_instance_valid(u):
			continue
		var r := u as RtsUnit
		if r == null or not r.is_alive():
			continue
		if r.faction != null and r.faction != pl and pl != null and pl.is_ally_of(r.faction):
			out.append(r)
	return out


func _group_harvest() -> Array:
	var out: Array = []
	for h in Game.all_harvestables():
		if h != null and is_instance_valid(h) and not bool(h.call("is_depleted")):
			out.append(h)
	return out


func _probe_group(cam: Camera3D, names: Array, group: Array, limit: int, with_worker: bool) -> void:
	var tested: int = 0
	for u in group:
		if tested >= limit:
			break
		var n := u as Node3D
		if n == null or not is_instance_valid(n):
			continue
		var def: UnitDef = n.get("def") as UnitDef
		var hh: float = (def.height if def != null else 1.6) * 0.5
		var wp: Vector3 = n.global_position + Vector3.UP * hh
		if cam.is_position_behind(wp):
			continue
		var sp: Vector2 = cam.unproject_position(wp)
		var hit := _pick(cam.project_ray_origin(sp), cam.project_ray_normal(sp))
		var shape := _shape_for(hit)
		var dname: String = def.display_name if def != null else "?"
		print("[光标自检] 目标=%-5s 屏幕(%4.0f,%4.0f) 命中=%-5s → %s%s" % [
			dname, sp.x, sp.y,
			"空" if hit == null else String((hit.get("def") as UnitDef).display_name if hit.get("def") != null else hit.name),
			names[shape], "  [农民态]" if with_worker else ""])
		tested += 1


func _process(_delta: float) -> void:
	if _dormant:
		return
	_frame += 1
	if _frame % PICK_EVERY != 0:
		return
	_poll()


## 退出时主动交还鼠标图标并放掉贴图引用。
## 不这么做的话，引擎关停顺序是"渲染服务先走、脚本对象后析构"，
## ImageTexture 析构时会刷 "Parameter RenderingServer::get_singleton() is null" 的 ERROR。
func _exit_tree() -> void:
	if not _dormant:
		Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	_tex.clear()
	_current = -1
	_selection.clear()


## HUD 每次刷新选择时喂进来（只关心有没有农民 + 阵营）
func note_selection(units: Array) -> void:
	_selection = units
	_has_worker = false
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		var d: UnitDef = u.get("def") as UnitDef
		if d != null and RtsWorld.is_worker_def(d):
			_has_worker = true
			break


# ===========================================================================
# 拾取（纯数学，不碰物理）
# ===========================================================================

func _poll() -> void:
	if Game.phase != RtsConst.Phase.RUNNING and Game.phase != RtsConst.Phase.PREPARE:
		_apply(Shape.ARROW)
		return
	var vp := get_viewport()
	if vp == null:
		return
	var pos: Vector2 = vp.get_mouse_position()
	# 压在界面上就别装模作样了，给回普通箭头
	if _ui_blocks(pos):
		_apply(Shape.ARROW)
		return
	var cam := vp.get_camera_3d()
	if cam == null:
		_apply(Shape.ARROW)
		return
	var hit := _pick(cam.project_ray_origin(pos), cam.project_ray_normal(pos))
	_apply(_shape_for(hit))


## 目标 → 形态
func _shape_for(target: Node3D) -> int:
	if target == null or not is_instance_valid(target):
		return Shape.ARROW
	var def: UnitDef = target.get("def") as UnitDef
	if target is RtsHarvestable:
		return Shape.PICK if _has_worker else Shape.ARROW
	var fac: RtsFaction = target.get("faction") as RtsFaction
	var mine: bool = fac != null and fac == Game.player_faction
	# 敌我判据走 Game.is_ally_of_player（同队 = 盟友），不是"和我同一个阵营"
	var mate: bool = fac != null and not mine and Game.is_ally_of_player(fac)
	if target is RtsBuilding:
		if mine:
			return Shape.HAMMER if _has_worker else Shape.ALLY
		if mate:
			return Shape.TEAMMATE
		return Shape.ENEMY
	if mine:
		return Shape.ALLY
	if mate:
		return Shape.TEAMMATE
	if fac != null:
		return Shape.ENEMY
	return Shape.ARROW


## 射线 × 竖直胶囊，返回最近命中（单位优先于建筑，和选择系统一个口径）
func _pick(ro: Vector3, rd: Vector3) -> Node3D:
	var best: Node3D = null
	var best_key: float = INF
	for u in Game.all_units():
		var n := u as Node3D
		if n == null or not is_instance_valid(n):
			continue
		if n is RtsUnit and not (n as RtsUnit).is_alive():
			continue
		if not n.visible:
			continue    # 迷雾里藏起来的敌人：光标不该"凭空变红剑"
		var hit := _test_capsule(n, ro, rd)
		if hit < 0.0:
			continue
		var bias: float = 3.0 if n is RtsBuilding else 0.0
		var key: float = hit + bias
		if key < best_key:
			best_key = key
			best = n
	for h in Game.all_harvestables():
		var hd := h as Node3D
		if hd == null or not is_instance_valid(hd):
			continue
		if bool(h.call("is_depleted")):
			continue
		if not hd.visible:
			continue    # 没探索过的资源不参与拾取
		var hit2 := _test_capsule(hd, ro, rd)
		if hit2 < 0.0:
			continue
		if hit2 + 1.0 < best_key:
			best_key = hit2 + 1.0
			best = hd
	return best


## 命中返回射线参数 t，不命中返回 -1
func _test_capsule(n: Node3D, ro: Vector3, rd: Vector3) -> float:
	var def: UnitDef = n.get("def") as UnitDef
	var r: float = 0.8
	var h: float = 1.6
	if def != null:
		r = def.selection_radius if def.selection_radius > 0.0 else 0.8
		h = maxf(def.height, 0.4)
	if n is RtsBuilding and def != null and def.footprint != Vector2i.ZERO:
		r = clampf(float(maxi(def.footprint.x, def.footprint.y)) * 0.5, 1.0, 3.2)
	var bottom: float = minf(r, 0.45)
	var a: Vector3 = n.global_position + Vector3.UP * bottom
	var b: Vector3 = a + Vector3.UP * maxf(h - bottom, 0.25)
	var res := _ray_vs_segment(ro, rd, a, b)
	if res.y > r:
		return -1.0
	return res.x


## 射线到线段最近距离：Vector2(沿射线参数, 垂距)
func _ray_vs_segment(ro: Vector3, rd: Vector3, a: Vector3, b: Vector3) -> Vector2:
	var ab := b - a
	var ab_len2 := ab.length_squared()
	if ab_len2 < 0.000001:
		var t0 := maxf((a - ro).dot(rd), 0.0)
		return Vector2(t0, ro.distance_to(a))
	var w := a - ro
	var abd := ab.dot(rd)
	var denom := ab_len2 - abd * abd
	var s: float = 0.0
	if absf(denom) > 0.000001:
		s = clampf(((w.dot(rd)) * abd - w.dot(ab)) / denom, 0.0, 1.0)
	var q: Vector3 = a + ab * s
	var t: float = (q - ro).dot(rd)
	if t <= 0.0:
		var s2 := clampf((ro - a).dot(ab) / ab_len2, 0.0, 1.0)
		return Vector2(0.0, ro.distance_to(a + ab * s2))
	var d2: float = (q - ro).length_squared() - t * t
	return Vector2(t, sqrt(maxf(d2, 0.0)))


func _ui_blocks(pos: Vector2) -> bool:
	var parent := get_parent()
	if parent != null and is_instance_valid(parent) and parent.has_method("covers_point"):
		return bool(parent.call("covers_point", pos))
	return false


# ===========================================================================
# 应用 / 节流
# ===========================================================================

func _apply(shape: int, force: bool = false) -> void:
	if shape == _current and not force:
		return
	var now: int = Time.get_ticks_msec()
	if not force and now - _last_switch_ms < SWITCH_MS:
		return
	if shape < 0 or shape >= _tex.size():
		return
	_current = shape
	_last_switch_ms = now
	Input.set_custom_mouse_cursor(_tex[shape], Input.CURSOR_ARROW, _hotspot(shape))


func _hotspot(shape: int) -> Vector2:
	match shape:
		Shape.ENEMY: return Vector2(25.0, 5.0)     # 剑尖
		Shape.PICK: return Vector2(24.0, 6.0)      # 镐尖
		Shape.HAMMER: return Vector2(21.0, 11.0)   # 锤头
		_: return Vector2(5.0, 3.0)                # 箭头尖


# ===========================================================================
# 图标生成
# ===========================================================================

func _build_icons() -> void:
	_tex.clear()
	_tex.append(ImageTexture.create_from_image(_icon_arrow(Color(0.97, 0.97, 0.95))))
	_tex.append(ImageTexture.create_from_image(_icon_ally()))
	_tex.append(ImageTexture.create_from_image(_icon_enemy()))
	_tex.append(ImageTexture.create_from_image(_icon_pick()))
	_tex.append(ImageTexture.create_from_image(_icon_hammer()))
	_tex.append(ImageTexture.create_from_image(_icon_teammate()))


## 调试：把五张图标拼成一张对照表存到工程里，方便人眼看
func _dump_icons() -> void:
	var dir := OS.get_executable_path().get_base_dir()
	var out_dir := OS.get_user_data_dir().path_join("debug")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var sheet := Image.create(ICON * 7, ICON, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.16, 0.17, 0.20, 1.0))
	var names := ["箭头", "己方", "敌方", "采集", "建造", "盟友"]
	for i in _tex.size():
		var img := _tex[i].get_image()
		if img == null:
			continue
		sheet.blit_rect(img, Rect2i(0, 0, ICON, ICON), Vector2i(i * ICON, 0))
		print("[光标] 图标 %d %s" % [i, names[i] if i < names.size() else "?"])
	var path := out_dir + "/cursor_sheet.png"
	var err: int = sheet.save_png(path)
	print("[光标] 对照表 %s err=%d（%s）" % [path, err, dir])


# --- 箭头 ---
func _icon_arrow(body: Color) -> Image:
	var img := _new_img()
	var pts := PackedVector2Array([
		Vector2(5.0, 3.0), Vector2(5.0, 24.0), Vector2(9.5, 19.5),
		Vector2(12.5, 26.5), Vector2(16.5, 24.5), Vector2(13.5, 17.0),
		Vector2(20.5, 17.0),
	])
	_outline_poly(img, pts, body)
	return img


# --- 己方：绿箭头 + 十字 ---
func _icon_ally() -> Image:
	var img := _new_img()
	var body := Color(0.44, 0.94, 0.56)
	var pts := PackedVector2Array([
		Vector2(4.0, 2.0), Vector2(4.0, 22.0), Vector2(8.2, 17.8),
		Vector2(11.0, 24.0), Vector2(14.6, 22.2), Vector2(11.8, 15.6),
		Vector2(18.2, 15.6),
	])
	_outline_poly(img, pts, body)
	# 右下角小十字（"可指挥"的徽标）
	var cross := Color(0.80, 1.0, 0.84)
	var cx: float = 24.5
	var cy: float = 23.5
	_line(img, Vector2(cx - 4.0, cy), Vector2(cx + 4.0, cy), 2.0, Color(0.02, 0.10, 0.04))
	_line(img, Vector2(cx, cy - 4.0), Vector2(cx, cy + 4.0), 2.0, Color(0.02, 0.10, 0.04))
	_line(img, Vector2(cx - 3.0, cy), Vector2(cx + 3.0, cy), 1.2, cross)
	_line(img, Vector2(cx, cy - 3.0), Vector2(cx, cy + 3.0), 1.2, cross)
	return img


# --- 盟友：青箭头 + 盾徽（能并肩、不能打） ---
## 颜色口径和 小地图 / 选中圈 / 头顶血条 完全一致：盟友 = 青。
## 盾形徽标是"友军"语义，十字徽标（己方）才是"可指挥"。
func _icon_teammate() -> Image:
	var img := _new_img()
	var body := Color(0.34, 0.96, 0.94)
	var pts := PackedVector2Array([
		Vector2(4.0, 2.0), Vector2(4.0, 22.0), Vector2(8.2, 17.8),
		Vector2(11.0, 24.0), Vector2(14.6, 22.2), Vector2(11.8, 15.6),
		Vector2(18.2, 15.6),
	])
	_outline_poly(img, pts, body)
	var cx: float = 24.2
	var cy: float = 22.4
	var shield := PackedVector2Array([
		Vector2(cx - 5.0, cy - 5.4), Vector2(cx + 5.0, cy - 5.4),
		Vector2(cx + 5.0, cy + 0.4), Vector2(cx, cy + 5.8),
		Vector2(cx - 5.0, cy + 0.4),
	])
	var dark := PackedVector2Array()
	for p in shield:
		dark.append(p + Vector2(0.9, 0.0))
	_fill_poly(img, dark, Color(0.02, 0.10, 0.12, 0.95))
	_fill_poly(img, shield, Color(0.08, 0.38, 0.42, 0.96))
	var inner := PackedVector2Array()
	for p in shield:
		inner.append((p - Vector2(cx, cy)) * 0.70 + Vector2(cx, cy))
	_fill_poly(img, inner, Color(0.46, 0.98, 0.96, 0.98))
	return img


# --- 敌方：红剑（斜刃 + 护手 + 金柄） ---
func _icon_enemy() -> Image:
	var img := _new_img()
	var tip := Vector2(26.0, 5.0)
	var base := Vector2(12.5, 18.5)
	# 刀锋（暗底 + 亮面，读起来有厚度）
	_line(img, tip, base, 3.0, Color(0.20, 0.03, 0.03))
	_line(img, tip, base, 2.0, Color(1.0, 0.42, 0.34))
	_line(img, tip + Vector2(-0.8, 0.8), base + Vector2(-0.8, 0.8), 0.9, Color(1.0, 0.86, 0.82))
	# 护手（与刃垂直）
	_line(img, Vector2(7.5, 14.5), Vector2(17.0, 23.0), 3.0, Color(0.20, 0.03, 0.03))
	_line(img, Vector2(8.2, 15.2), Vector2(16.3, 22.3), 1.6, Color(0.86, 0.16, 0.12))
	# 柄 + 金坠
	_line(img, base, Vector2(7.0, 24.5), 3.0, Color(0.20, 0.03, 0.03))
	_line(img, base, Vector2(7.4, 24.1), 1.8, Color(0.46, 0.20, 0.14))
	_disc(img, 6.4, 25.2, 2.3, Color(0.16, 0.02, 0.02))
	_disc(img, 6.4, 25.2, 1.5, Color(0.98, 0.82, 0.36))
	return img


# --- 可采集物：黄镐 ---
func _icon_pick() -> Image:
	var img := _new_img()
	# 木柄
	_line(img, Vector2(8.0, 27.0), Vector2(21.0, 13.5), 3.2, Color(0.14, 0.08, 0.04))
	_line(img, Vector2(8.0, 27.0), Vector2(21.0, 13.5), 2.0, Color(0.62, 0.42, 0.20))
	# 镐头（弯钩）
	var head := PackedVector2Array([
		Vector2(9.5, 12.5), Vector2(13.0, 7.0), Vector2(18.5, 4.5), Vector2(25.0, 5.5),
	])
	_line(img, head[0], head[1], 3.4, Color(0.16, 0.10, 0.03))
	_line(img, head[1], head[2], 3.4, Color(0.16, 0.10, 0.03))
	_line(img, head[2], head[3], 3.4, Color(0.16, 0.10, 0.03))
	_line(img, head[0], head[1], 2.2, Color(1.0, 0.82, 0.28))
	_line(img, head[1], head[2], 2.2, Color(1.0, 0.86, 0.36))
	_line(img, head[2], head[3], 2.2, Color(0.98, 0.74, 0.20))
	_line(img, Vector2(13.5, 6.6), Vector2(19.0, 4.6), 1.0, Color(1.0, 0.96, 0.68))
	return img


# --- 己方建筑：铁锤 ---
func _icon_hammer() -> Image:
	var img := _new_img()
	# 柄
	_line(img, Vector2(9.5, 27.0), Vector2(19.0, 16.0), 3.4, Color(0.12, 0.07, 0.03))
	_line(img, Vector2(9.5, 27.0), Vector2(19.0, 16.0), 2.2, Color(0.60, 0.42, 0.22))
	# 锤头：一个斜置矩形
	var c := Vector2(21.0, 11.0)
	var ang := deg_to_rad(-42.0)
	var u := Vector2(cos(ang), sin(ang))
	var v := Vector2(-sin(ang), cos(ang))
	var hw: float = 6.0
	var hh: float = 3.4
	var quad := PackedVector2Array([
		c - u * hw - v * hh, c + u * hw - v * hh,
		c + u * hw + v * hh, c - u * hw + v * hh,
	])
	_fill_poly(img, quad, Color(0.10, 0.12, 0.16))
	var inner := PackedVector2Array([
		c - u * (hw - 1.0) - v * (hh - 1.0), c + u * (hw - 1.0) - v * (hh - 1.0),
		c + u * (hw - 1.0) + v * (hh - 1.0), c - u * (hw - 1.0) + v * (hh - 1.0),
	])
	_fill_poly(img, inner, Color(0.78, 0.83, 0.90))
	# 受光面
	var lit := PackedVector2Array([
		c - u * (hw - 1.0) - v * (hh - 1.0), c + u * (hw - 1.0) - v * (hh - 1.0),
		c + u * (hw - 1.0) - v * 0.2, c - u * (hw - 1.0) - v * 0.2,
	])
	_fill_poly(img, lit, Color(0.95, 0.97, 1.0))
	return img


# ===========================================================================
# 光栅化小工具（全部代码画，不加载任何外部资源）
# ===========================================================================

static func _new_img() -> Image:
	var img := Image.create(ICON, ICON, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	return img


static func _blend(img: Image, x: int, y: int, c: Color) -> void:
	if x < 0 or y < 0 or x >= ICON or y >= ICON or c.a <= 0.004:
		return
	var old := img.get_pixel(x, y)
	var a: float = c.a + old.a * (1.0 - c.a)
	if a <= 0.0001:
		return
	var r: float = (c.r * c.a + old.r * old.a * (1.0 - c.a)) / a
	var g: float = (c.g * c.a + old.g * old.a * (1.0 - c.a)) / a
	var b: float = (c.b * c.a + old.b * old.a * (1.0 - c.a)) / a
	img.set_pixel(x, y, Color(r, g, b, a))


## 实心圆
static func _disc(img: Image, cx: float, cy: float, r: float, c: Color) -> void:
	var r2: float = r * r
	var x0: int = int(floorf(cx - r))
	var x1: int = int(ceilf(cx + r))
	var y0: int = int(floorf(cy - r))
	var y1: int = int(ceilf(cy + r))
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var dx: float = float(x) + 0.5 - cx
			var dy: float = float(y) + 0.5 - cy
			if dx * dx + dy * dy <= r2:
				_blend(img, x, y, c)


## 带圆头的线段
static func _line(img: Image, a: Vector2, b: Vector2, w: float, c: Color) -> void:
	var d := b - a
	var steps: int = int(maxf(d.length(), 1.0) * 3.0)
	for i in range(steps + 1):
		var t: float = float(i) / float(maxi(steps, 1))
		var p := a + d * t
		_disc(img, p.x, p.y, w * 0.5, c)


## 多边形填充（扫描线，奇偶规则；够画这些 32px 小图标了）
static func _fill_poly(img: Image, pts: PackedVector2Array, c: Color) -> void:
	var n := pts.size()
	if n < 3:
		return
	var min_y: float = 1e9
	var max_y: float = -1e9
	for p in pts:
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
	var y0: int = maxi(int(floorf(min_y)), 0)
	var y1: int = mini(int(ceilf(max_y)), ICON - 1)
	for y in range(y0, y1 + 1):
		var sy: float = float(y) + 0.5
		var xs: Array[float] = []
		for i in n:
			var p1 := pts[i]
			var p2 := pts[(i + 1) % n]
			if (p1.y <= sy and p2.y > sy) or (p2.y <= sy and p1.y > sy):
				var t: float = (sy - p1.y) / (p2.y - p1.y)
				xs.append(p1.x + (p2.x - p1.x) * t)
		if xs.size() < 2:
			continue
		xs.sort()
		var k: int = 0
		while k + 1 < xs.size():
			var xa: int = int(floorf(xs[k]))
			var xb: int = int(ceilf(xs[k + 1]))
			for x in range(xa, xb + 1):
				_blend(img, x, y, c)
			k += 2


## 给多边形描 1px 深边（八方向偏移铺底），保证任何底色上都看得清
static func _outline_poly(img: Image, pts: PackedVector2Array, fill: Color) -> void:
	var dark := Color(0.03, 0.03, 0.04, 0.92)
	var offs := [
		Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
		Vector2(1, 1), Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1),
	]
	for o in offs:
		var shifted := PackedVector2Array()
		for p in pts:
			shifted.append(p + (o as Vector2))
		_fill_poly(img, shifted, dark)
	_fill_poly(img, pts, fill)