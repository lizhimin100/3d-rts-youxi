extends Node3D
## 三档 LOD 切换（资产包要求：近 / 中 / 远三档，不用引擎自动 LOD）。
## 用整棵节点切换而不是给每个 MeshInstance 设 visibility_range：
## 建筑 4 个网格的 AABB 中心差 20 多米，逐网格切会出现"屋顶先换、墙后换"的撕裂。

var _lods: Array[Node3D] = []
var _cur: int = -1
var _clock: float = 0.0
var _thresholds: Array[float] = [0.0, 46.0, 96.0]
var _hyst: float = 7.0


func setup(near: Node3D, mid: Node3D, far: Node3D) -> void:
	_lods = [near, mid, far]
	for i in _lods.size():
		if _lods[i] != null:
			_lods[i].visible = i == 0
	_cur = 0
	set_process(true)


func _process(delta: float) -> void:
	_clock += delta
	if _clock < 0.18:
		return
	_clock = 0.0
	if _lods.size() < 2:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var d := cam.global_position.distance_to(global_position)
	var want := _cur
	if _cur <= 0 and d > _thresholds[1] + _hyst:
		want = 1
	elif _cur == 1:
		if d < _thresholds[1] - _hyst:
			want = 0
		elif d > _thresholds[2] + _hyst:
			want = 2
	elif _cur >= 2 and d < _thresholds[2] - _hyst:
		want = 1
	if want == _cur:
		return
	_cur = want
	for i in _lods.size():
		if _lods[i] != null:
			_lods[i].visible = i == _cur
