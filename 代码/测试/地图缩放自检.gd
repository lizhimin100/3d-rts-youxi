extends SceneTree
## **地图缩放自检（无头）**：验证"每边加 N 米"把整张图一致地放大。
##
## 跑法：godot --headless --path . --script 代码/测试/地图缩放自检.gd
## 结尾一行 `RESIZETEST {json}`，退出码 0 = 全过。
##
## 判据（玩家 2026-11-08 第 12 条：地图尺寸缩放/扩大）：
##   A 尺寸：size / height_resolution / mat_cells 都跟着变，且格点数是 (res+1)²；
##   B 地形不变形：同一个**世界坐标**的高度扩大前后一致（误差 < 0.05m）；
##   C 内容随中心平移：对象 / 玩家出生点 / 区域 / 镜头边界全部 +N；
##   D 小地图 / 镜头 / 寻路用的是 size 派生值 —— 这里断言 `MapDef.half_size()`
##     与 `camera_bounds` 同步（运行时三样都从 level.world_size 走，不另存分块）；
##   E 越界参数（不是 8 的倍数 / 超范围）必须被拒绝且不改图。

const SCALE := preload("res://代码/地图核心/地图缩放.gd")
const MAP_PATH := "res://地图/主场景地图.tres"

var 报告: Dictionary = {}
var 失败: Array = []


func _initialize() -> void:
	call_deferred("_运行")


func _运行() -> void:
	var src = load(MAP_PATH)
	if src == null:
		push_error("[地图缩放自检] 读不到 %s" % MAP_PATH)
		quit(1)
		return
	# ★ 必须 duplicate：直接改会写脏 .tres（编辑器里下次打开就是放大后的图）
	var m: MapDef = (src as MapDef).duplicate(true)
	var 旧size: int = int(m.size)
	var 旧res: int = int(m.height_resolution)
	var 旧cells: int = int(m.mat_cells)
	var 旧half: float = m.half_size()
	var 旧h0: float = m.height_at(0.0, 0.0)
	var 旧h1: float = m.height_at(旧half * 0.35, -旧half * 0.30)
	var 旧obj: Vector3 = Vector3.ZERO
	if not m.objects.is_empty():
		旧obj = m.objects[0].position
	var 旧spawn: Vector2 = m.players[0].start_pos if not m.players.is_empty() else Vector2.ZERO
	var 加: int = 32
	var ok: bool = SCALE.expand(m, 加)

	# --- A 尺寸 ---
	var 新size: int = int(m.size)
	var 新res: int = int(m.height_resolution)
	var 行: int = 新res + 1
	var a_ok: bool = ok and 新size == 旧size + 加 * 2 \
			and 新res > 旧res \
			and m.heightmap.size() == 行 * 行 \
			and m.splatmap.size() == 新res * 新res \
			and int(m.mat_cells) == int(round(float(新size) / 8.0)) \
			and m.mat_nodes.size() == (int(m.mat_cells) + 1) * (int(m.mat_cells) + 1)
	_记("A_尺寸", {"旧": "%dm / res %d / 地块 %d" % [旧size, 旧res, 旧cells],
		"新": "%dm / res %d / 地块 %d" % [新size, 新res, int(m.mat_cells)],
		"高度点数": m.heightmap.size(), "应": 行 * 行})
	if not a_ok:
		失败.append("A 尺寸：扩图后数组尺寸对不上（%dm res=%d 高度点=%d）"
				% [新size, 新res, m.heightmap.size()])

	# --- B 地形不变形（同世界坐标高度一致）---
	var 差0: float = absf(m.height_at(0.0, 0.0) - 旧h0)
	var 差1: float = absf(m.height_at(旧half * 0.35, -旧half * 0.30) - 旧h1)
	_记("B_地形", {"中心高差": "%.4f" % 差0, "偏一点高差": "%.4f" % 差1})
	if 差0 > 0.05 or 差1 > 0.05:
		失败.append("B 地形：重采样把地形改了（中心 %.3f / 偏移 %.3f）" % [差0, 差1])

	# --- C 内容平移 +N ---
	var c_ok: bool = true
	var 说明: Array = []
	if not m.objects.is_empty():
		var 新obj: Vector3 = m.objects[0].position
		var d: Vector3 = 新obj - 旧obj
		c_ok = c_ok and absf(d.x - float(加)) < 0.01 and absf(d.z - float(加)) < 0.01
		说明.append("对象 +%.1f,%.1f" % [d.x, d.z])
	if not m.players.is_empty():
		var ds: Vector2 = m.players[0].start_pos - 旧spawn
		c_ok = c_ok and absf(ds.x - float(加)) < 0.01
		说明.append("出生点 +%.1f,%.1f" % [ds.x, ds.y])
	_记("C_内容平移", {"明细": str(说明), "对": c_ok, "对象数": m.objects.size()})
	if not c_ok:
		失败.append("C 内容平移：对象/出生点没有整体 +%d 米（原文 %s）" % [加, str(说明)])

	# --- D 镜头边界 / 半边长 ---
	var 期望: float = float(新size) * 0.5
	var d_ok: bool = absf(m.half_size() - 期望) < 0.01 \
			and absf(m.camera_bounds.size.x - (float(新size) - 4.0)) < 0.5
	_记("D_镜头边界", {"半边长": "%.1f（应 %.1f）" % [m.half_size(), 期望],
		"camera_bounds": str(m.camera_bounds)})
	if not d_ok:
		失败.append("D 镜头边界：half_size / camera_bounds 没跟着 size 变")

	# --- E 非法参数拒绝 ---
	var m2: MapDef = (src as MapDef).duplicate(true)
	var 旧: int = int(m2.size)
	var e1: bool = SCALE.expand(m2, 7)      # 不是 8 的倍数 → 会被向下取整成 0
	var e2: bool = SCALE.expand(m2, 400)    # 超上限
	_记("E_拒绝非法", {"+7米": e1, "+400米": e2, "图没变": int(m2.size) == 旧})
	if e1 or e2 or int(m2.size) != 旧:
		失败.append("E 拒绝非法：非法参数没有被拒绝（+7=%s / +400=%s）" % [e1, e2])

	报告["失败项"] = 失败
	报告["结果"] = "通过" if 失败.is_empty() else "失败"
	print("RESIZETEST " + JSON.stringify(报告))
	quit(0 if 失败.is_empty() else 1)


func _记(名: String, 明细: Dictionary) -> void:
	报告[名] = 明细
	print("[地图缩放自检] %s %s" % [名, JSON.stringify(明细)])
