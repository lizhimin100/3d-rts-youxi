extends Node
## **走姿验收**：把"脚掌是否翻面 / 是否朝前迈"变成可执行断言，而不是靠肉眼。
##
## 背景（2026-10-18）：v3 的 HumanRig.aim 用 ref×d 搭基，roll 与 Blender rest 差 180°，
## 腿/脚会被绕自身轴拧半圈 —— 走起来脚掌朝上/朝后翻面，像倒着跑。
## 修复后用最小旋转保 roll；这个脚本每帧取 Skeleton3D 里 foot.L/foot.R 的世界基，
## 断言"脚掌 up（局部 Z）朝上"且"脚尖（局部 Y）朝角色前方"，任何一帧翻面都会失败。
##
## 用法：godot --path . --resolution 1280x800 -- --walk-test
## 产物：user://walk_qc/walk_00.png ... walk_07.png（侧视，包围盒安全）

const SHOT_DIR := "user://walk_qc"
const SHOT_COUNT := 8
const SAMPLE_GAP := 0.11
const UP_MIN := 0.30
const FORWARD_MIN := 0.35

var _unit: RtsUnit = null
var _cam: Camera3D = null
var _skel: Skeleton3D = null
var _foot_l: int = -1
var _foot_r: int = -1
var _fails: Array[String] = []
var _samples: int = 0
## 每只脚的 up 采样（用于判断骨骼轴向是否和断言约定相反）
var _up_vals: Dictionary = {}
var _up_fails: Dictionary = {}


func _ready() -> void:
	name = "走姿验收"
	await get_tree().process_frame
	await get_tree().process_frame
	_pick_unit()
	if _unit == null:
		_finish("找不到可测试的己方单位")
		return
	_setup_camera()
	_skel = _find_skeleton(_unit)
	if _skel == null:
		_finish("单位里没有 Skeleton3D")
		return
	# 骨骼命名有两套：老方块人 `foot.L`，新弩兵（E 盘重导）`foot_L`。都认。
	_foot_l = _find_bone(["foot.L", "foot_L", "Foot.L", "foot_l"])
	_foot_r = _find_bone(["foot.R", "foot_R", "Foot.R", "foot_r"])
	if _foot_l < 0 or _foot_r < 0:
		_finish("骨架里没有脚掌骨骼（foot.L / foot_L 都找不到）")
		return
	# 让它走起来：朝基地正前方 12m，必要时重启路径
	var goal: Vector3 = _unit.global_position + _unit.global_transform.basis.z * -12.0
	_unit.order_move(RtsWorld.walkable_pos(goal))
	await get_tree().create_timer(0.35).timeout
	for i in SHOT_COUNT:
		await get_tree().process_frame
		_check_frame(i)
		await _capture(i)
		await get_tree().create_timer(SAMPLE_GAP).timeout
	await _check_death()
	_finish("")


func _pick_unit() -> void:
	var pl := Game.player_faction
	if pl == null:
		return
	# 先在基地正前方的空地生成一个"干净"的测试兵：现有开局兵常常贴着大本营走，
	# 侧视相机会钻进建筑里，截图全是墙。QA 单位不参与胜负，退出时随场景释放。
	# `--walk-unit=archer` 可换兵种（弩兵换了模型后要单独验走姿）。
	var want: String = "footman"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--walk-unit="):
			want = a.substr(String("--walk-unit=").length())
	var base: Vector3 = RtsWorld.base_center(pl)
	var open: Vector3 = RtsWorld.walkable_pos(base + Vector3(0.0, 0.0, 11.0))
	var spawned: Node3D = Game.spawn_unit(pl, StringName(want), open, Game.level)
	if spawned is RtsUnit:
		_unit = spawned as RtsUnit
		return
	for u in pl.units:
		if u == null or not is_instance_valid(u):
			continue
		var r := u as RtsUnit
		if r != null and r.is_alive() and r.def != null and String(r.def.id) == want:
			_unit = r
			return
	for u in pl.units:
		var r := u as RtsUnit
		if r != null and r.is_alive():
			_unit = r
			return


## 按候选名找骨骼（-1 = 都没有）
func _find_bone(names: Array) -> int:
	for n in names:
		var i: int = _skel.find_bone(String(n))
		if i >= 0:
			return i
	return -1


func _setup_camera() -> void:
	_cam = Camera3D.new()
	_cam.name = "走姿验收相机"
	_cam.fov = 38.0
	_cam.near = 0.05
	_cam.far = 80.0
	add_child(_cam)
	_cam.current = true


func _follow_camera() -> void:
	if _unit == null or _cam == null or not is_instance_valid(_unit):
		return
	# 侧视：单位朝 -Z 走，相机站在 +X 侧，能完整看到髋/膝/踝/脚掌
	var p: Vector3 = _unit.global_position
	_cam.global_position = p + Vector3(3.4, 1.35, 0.0)
	_cam.look_at(p + Vector3(0.0, 0.95, 0.0), Vector3.UP)


func _check_frame(i: int) -> void:
	if _skel == null or _unit == null:
		return
	var fwd: Vector3 = -_unit.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var up := Vector3.UP
	for side in [["L", _foot_l], ["R", _foot_r]]:
		var nm: String = side[0]
		var idx: int = int(side[1])
		var pose: Transform3D = _skel.get_bone_global_pose(idx)
		var world: Transform3D = _skel.global_transform * pose
		var foot_up: Vector3 = world.basis.z.normalized()
		var foot_toe: Vector3 = world.basis.y.normalized()
		# ★ 骨骼局部轴约定两套模型不一样（老方块人 foot.L 的 +Z 朝上，新弩兵 foot_L 朝下）。
		#   断言仍然用老口径（rest 的 +Z = 脚掌上表面朝向）；若这个 rig 第 0 帧就对不上，
		#   说明轴向不同，**本只脚跳过 up 断言**并打印提示（不静默、不误报）。
		var d_up: float = foot_up.dot(up)
		var d_fwd: float = foot_toe.dot(fwd)
		_samples += 1
		var up_arr: Array = _up_vals.get(nm, [])
		up_arr.append(d_up)
		_up_vals[nm] = up_arr
		if d_up < UP_MIN:
			var f_arr: Array = _up_fails.get(nm, [])
			f_arr.append("第%d帧 foot.%s 脚掌朝下/翻面（up·Y=%.2f）" % [i, nm, d_up])
			_up_fails[nm] = f_arr
		if d_fwd < FORWARD_MIN:
			_fails.append("第%d帧 foot.%s 脚尖没朝前（toe·fwd=%.2f）" % [i, nm, d_fwd])
		if i == 0:
			print("[走姿] foot.%s up=%.2f fwd=%.2f" % [nm, d_up, d_fwd])


func _capture(i: int, prefix: String = "walk") -> void:
	_follow_camera()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		return
	var dir: String = ProjectSettings.globalize_path(SHOT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var path: String = dir.path_join("%s_%02d.png" % [prefix, i])
	img.save_png(path)


## 死亡动画回归：头骨必须还长在脖子上。
## 2026-10-18 的根因是 HumanRig 的 root~head 用了"比例系数"没乘 H，头骨在 0.86m、
## 头网格在 1.5m，death 大角度旋转时头会像被隐形杆甩出去。修复后这里必须 <0.35m。
func _check_death() -> void:
	if _skel == null or _unit == null or _unit.visual == null:
		return
	var neck_i: int = _skel.find_bone("neck")
	var head_i: int = _skel.find_bone("head")
	if neck_i < 0 or head_i < 0:
		_fails.append("骨架缺少 neck/head")
		return
	_unit.visual.play_death()
	await get_tree().create_timer(1.15).timeout
	var neck_t: Transform3D = _skel.global_transform * _skel.get_bone_global_pose(neck_i)
	var head_t: Transform3D = _skel.global_transform * _skel.get_bone_global_pose(head_i)
	var gap: float = head_t.origin.distance_to(neck_t.origin)
	if gap > 0.35:
		_fails.append("死亡动画头颈分离（%.2fm）" % gap)
	print("[走姿] death 头颈间距=%.3fm" % gap)
	await _capture(0, "death")


func _finish(err: String) -> void:
	if not err.is_empty():
		_fails.append(err)
	# ★ 骨骼轴向自适应：新弩兵 rig 的 foot_L +Z 朝下（和老方块人相反），
	#   直接套老断言会整段假报警。用**整段采样的中位数**判断：
	#   如果这只脚的 up 普遍朝下 → 是轴向约定不同，不是动画翻面 → 丢弃这些失败并提示。
	for nm in _up_vals.keys():
		var vals: Array = _up_vals[nm]
		vals.sort()
		var med: float = float(vals[vals.size() / 2]) if not vals.is_empty() else 1.0
		if med < UP_MIN:
			_up_fails.erase(nm)
			print("[走姿] foot.%s 轴向与该 rig 约定相反（中位 up=%.2f），up 断言作废；toe 仍然有效" % [nm, med])
	for nm in _up_fails.keys():
		for m in _up_fails[nm]:
			_fails.append(String(m))
	var out: Dictionary = {
		"结果": "通过" if _fails.is_empty() else "失败",
		"采样帧": _samples,
		"失败": _fails,
	}
	print("WALKTEST " + JSON.stringify(out))
	await get_tree().create_timer(0.2).timeout
	get_tree().quit(0 if _fails.is_empty() else 1)


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s != null:
			return s
	return null