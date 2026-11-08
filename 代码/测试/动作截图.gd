extends Node
## **动作截图**：把兵的 4 个动作（待机 / 走 / 攻击 / 举盾）逐张拍下来，给人眼看。
##
## 为什么要有它：`--shot` 只拍一张、而且镜头是全图，兵只有 20 像素高，
## 想确认「走路有没有迈腿 / 攻击是不是一刀 / 举盾盾牌举没举起来」根本看不出来。
## 这里把相机架到兵身边 3 米，每个动作拍一张，产物直接落在 res://_qa/动作/。
##
## 用法（要窗口）：
##   godot --path . --resolution 900x700 -- --anim-shots
##   godot --path . --resolution 900x700 -- --anim-shots=archer   （换兵种）
##
## 判据仍然是**人眼**：图里腿在迈、剑在挥、盾在身前，才算过。
## 机器判据在 代码/测试/动画验收.gd（骨骼位移）。

const OUT_DIR := "res://_qa/动作"

var _unit: RtsUnit = null
var _foe: Node3D = null
var _cam: Camera3D = null
var _tag: String = "footman"


func _ready() -> void:
	name = "动作截图"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--anim-shots="):
			_tag = a.substr(String("--anim-shots=").length())
	await get_tree().process_frame
	await get_tree().process_frame
	_spawn()
	if _unit == null:
		print("[动作截图] 造兵失败")
		get_tree().quit(1)
		return
	_setup_camera()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	await _shot("0_待机")
	await _walk()
	# ★ 先拍举盾再拍攻击：攻击会在身前 2m 摆一个敌人，正前方的机位会被敌人挡住
	await _shield()
	await _attack()
	print("[动作截图] 完成 → %s" % ProjectSettings.globalize_path(OUT_DIR))
	get_tree().quit(0)


func _spawn() -> void:
	var pl := Game.player_faction
	if pl == null:
		return
	var base: Vector3 = RtsWorld.base_center(pl)
	var spot: Vector3 = RtsWorld.walkable_pos(base + Vector3(10.0, 0.0, 10.0))
	var n: Node3D = Game.spawn_unit(pl, StringName(_tag), spot, Game.level)
	if n is RtsUnit:
		_unit = n as RtsUnit


func _setup_camera() -> void:
	_cam = Camera3D.new()
	_cam.name = "动作截图相机"
	_cam.fov = 34.0
	_cam.near = 0.03
	_cam.far = 120.0
	add_child(_cam)
	_cam.current = true
	_follow()


## 相机站在单位**右前 40 度**：既看得到剑、也看得到腿（正侧面手会挡住身子）。
## `front=true` 时站到**正前方**（验收举盾：盾是不是挡在身前、手有没有穿模）。
func _follow(front: bool = false) -> void:
	if _unit == null or not is_instance_valid(_unit) or _cam == null:
		return
	var p: Vector3 = _unit.global_position
	var b: Basis = _unit.global_transform.basis
	var fwd: Vector3 = -b.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var right: Vector3 = fwd.cross(Vector3.UP).normalized()
	if front:
		_cam.global_position = p + fwd * 4.2 + Vector3(0.0, 1.35, 0.0)
	else:
		_cam.global_position = p + fwd * 3.9 + right * 2.9 + Vector3(0.0, 1.55, 0.0)
	_cam.look_at(p + Vector3(0.0, 0.92, 0.0), Vector3.UP)


func _shot(tag: String, front: bool = false) -> void:
	_follow(front)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		return
	var path: String = ProjectSettings.globalize_path(OUT_DIR) + "/" + _tag + "_" + tag + ".png"
	img.save_png(path)
	print("[动作截图] %s" % path)


func _walk() -> void:
	if _unit == null:
		return
	var goal: Vector3 = _unit.global_position + (-_unit.global_transform.basis.z) * 9.0
	_unit.order_move(RtsWorld.walkable_pos(goal))
	await get_tree().create_timer(0.75).timeout
	await _shot("1_走_a")
	await get_tree().create_timer(0.16).timeout
	await _shot("1_走_b")
	_unit.order_stop()
	await get_tree().create_timer(0.35).timeout


func _attack() -> void:
	if _unit == null:
		return
	var ef := Game.enemy_faction
	if ef == null:
		return
	var p: Vector3 = _unit.global_position + (-_unit.global_transform.basis.z) * 2.0
	_foe = Game.spawn_unit(ef, StringName(_tag), RtsWorld.walkable_pos(p), Game.level)
	if _foe == null:
		return
	_unit.order_attack(_foe)
	await get_tree().create_timer(0.55).timeout
	for i in 4:
		await _shot("2_攻击_%d" % i)
		await get_tree().create_timer(0.14).timeout
	_unit.order_stop()
	await get_tree().create_timer(0.25).timeout


func _shield() -> void:
	if _unit == null:
		return
	if _unit.has_method("skill_toggle"):
		_unit.call("skill_toggle", &"shield_up")
	await get_tree().create_timer(0.55).timeout
	# 姿态层是不是真的挂上了、权重到 1 了
	var v = _unit.get("visual")
	if v != null and is_instance_valid(v) and v.has_method("hold_pose_debug"):
		print("[动作截图] 姿态层 ", v.call("hold_pose_debug"))
	await _shot("3_举盾_待机")
	await _shot("3_举盾_正面", true)
	# 举盾走路
	var goal: Vector3 = _unit.global_position + (-_unit.global_transform.basis.z) * 7.0
	_unit.order_move(RtsWorld.walkable_pos(goal))
	await get_tree().create_timer(0.7).timeout
	await _shot("3_举盾_走")
	_unit.order_stop()
	await get_tree().create_timer(0.3).timeout
	# 举盾攻击
	if _foe != null and is_instance_valid(_foe) and _foe.call("is_alive"):
		_unit.order_attack(_foe)
		await get_tree().create_timer(0.55).timeout
		await _shot("3_举盾_攻击")
