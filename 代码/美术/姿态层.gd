extends SkeletonModifier3D
## **姿态层**：在动画之后把某几根骨骼**按住不动**（举盾 = 左臂一直举在身前）。
##
## 为什么不用 clip：
##   玩家口径「举盾就不该循环播放举盾动作，要一直保持举着，而且要有举盾状态下的移动/攻击动作」。
##   做成 clip 只有两条路：① 循环播 → 手臂每 0.5 秒抬一次（现在的毛病）；
##   ② 给走/攻/待机各做一套举盾版 → 三段新动作，容易和原动作对不上。
##   姿态层是第三条路：**基础动作照常播**（走路迈腿、攻击挥剑），
##   这里在动画结算之后把左臂几根骨改回"举盾"的姿势 —— 于是"一直举着 + 能走能砍"同时成立。
##
## 姿势从哪来：读 `anim_hold` 那个 clip 的**最后一帧**（美术在 Blender 里摆好的举盾姿势），
## 所以换美术、改动作都不用动这份代码。

## 允许被姿态层按住、并从中取目标姿势的骨骼白名单。
## ★ 只收"上半身左侧 + 盾"：root/hips/腿/脊柱留给基础动作，否则走路会僵住。
const BONES: Array[String] = [
	"shoulder_L", "upperarm_L", "forearm_L", "hand_L", "shield",
]
## 淡入淡出时长（秒）。0.18 是实测手感：再快像抽筋，再慢像没反应。
const BLEND_TIME := 0.18

var _skel: Skeleton3D = null
var _ap: AnimationPlayer = null
var _clip: StringName = &""
## 骨骼名 → { idx, target: Quaternion }
var _targets: Dictionary = {}
var _want: float = 0.0
var _weight: float = 0.0


## 绑定（UnitVisual 建完模型后调一次）。返回是否真的挂上了（模型没有这些骨就返回 false）
func setup(skel: Skeleton3D, ap: AnimationPlayer) -> bool:
	if skel == null or ap == null:
		return false
	_skel = skel
	_ap = ap
	active = true
	return true


## 指定"按住哪一段"：clip 名（技能卡的 anim_hold）。空 = 不按。
func use_clip(clip: StringName) -> void:
	if clip == _clip:
		return
	_clip = clip
	# ★ 关掉（clip 为空）时**不要**立刻清 _targets：
	#   淡出还要靠它把骨骼从"举着"平滑地 slerp 回动画姿势。
	#   清空放到 _process_modification 里权重归零之后做（踩过：清早了权重永远卡在 1）。
	if clip == &"":
		return
	if _ap == null or not _ap.has_animation(String(clip)):
		_targets.clear()
		return
	_targets.clear()
	var anim: Animation = _ap.get_animation(String(clip))
	var t_end: float = maxf(anim.length - 0.001, 0.0)
	for i in anim.get_track_count():
		if anim.track_get_type(i) != Animation.TYPE_ROTATION_3D:
			continue
		var path: NodePath = anim.track_get_path(i)
		var bone: String = String(path.get_concatenated_subnames())
		if not BONES.has(bone):
			continue
		var idx: int = _skel.find_bone(bone)
		if idx < 0:
			continue
		var q: Quaternion = anim.rotation_track_interpolate(i, t_end)
		_targets[bone] = {"idx": idx, "target": q}


## 开/关（带淡入淡出由 _process_modification 做）
func set_hold(on: bool) -> void:
	_want = 1.0 if on else 0.0


func hold_on() -> bool:
	return _want > 0.5


## 动画之后执行：把左臂往目标姿势上按
func _process_modification() -> void:
	if _skel == null:
		return
	var dt: float = get_process_delta_time()
	_weight = move_toward(_weight, _want, dt / BLEND_TIME)
	if _weight <= 0.001:
		# 完全放下之后才丢掉姿势数据（淡出期间还要用它）
		if _clip == &"":
			_targets.clear()
		return
	if _targets.is_empty():
		return
	for bone in _targets:
		var info: Dictionary = _targets[bone]
		var idx: int = int(info["idx"])
		var cur: Quaternion = _skel.get_bone_pose_rotation(idx)
		_skel.set_bone_pose_rotation(idx, cur.slerp(info["target"], _weight))


## 调试：当前按住的是哪几根骨（自检/截图脚本读）
func debug_info() -> Dictionary:
	return {"clip": String(_clip), "weight": snappedf(_weight, 0.01),
		"bones": _targets.keys()}

