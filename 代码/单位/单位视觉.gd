class_name UnitVisual
extends Node3D
## **单位外观**：模型 / 队伍色 / 程序动画 / 命中闪白 / 受伤抖动。
##
## 为什么从 RtsUnit 里拆出来：单位本体已经有移动、索敌、采集、建造四套状态机，
## 再往里塞材质遍历和闪白计时会变成一坨。外观的"所有"脏活都在这里，
## 单位本体只调 `play("move", 0.8)` / `flash()` 这种高层接口。
##
## 注意：美术资产可能还没到位 —— ArtKit 会自动退化成占位盒，这里不需要判空。

## 命中闪白持续（秒）——任务书冻结 0.12s
const FLASH_TIME: float = 0.12
## 两次受伤动画之间的最小间隔（防止被集火时动画抖成抽搐）
const HURT_ANIM_GAP: float = 0.3
## 闪白颜色（纯白略透，叠在模型上"啪"一下）
const FLASH_COLOR: Color = Color(1.0, 1.0, 1.0, 0.82)

## 模型根
var _model: Node3D = null
## 程序动画器（可能为 null：美术没到位时）
var _anim: Node = null
## 收集到的所有网格（闪白要挨个套 overlay）
var _meshes: Array = []
## 闪白计时
var _flash_t: float = 0.0
## 闪白材质（复用一份，别每次 new）
var _flash_mat: StandardMaterial3D = null
## 被闪白覆盖前的原 overlay，恢复时用
var _prev_overlay: Dictionary = {}
## 当前动画状态（去重用）
var _anim_state: String = ""
## 受伤动画剩余时间
var _hurt_t: float = 0.0
## 受伤动画冷却
var _hurt_gap: float = 0.0
## 是否已经构建（避免重复建模型）
var _built: bool = false


# ===========================================================================
# 构建
# ===========================================================================

## 建模型 + 套队伍色 + 挂动画器。重复调用安全。
func build(def: UnitDef, team_color: Color) -> void:
	if _built or def == null:
		return
	_built = true

	# 占位尺寸：让美术没到位时的盒子比例别太离谱
	var fallback := Vector3(0.8, 1.7, 0.6)
	if def.kind == RtsConst.Kind.BUILDING:
		fallback = Vector3(float(maxi(def.footprint.x, 1)), def.height,
				float(maxi(def.footprint.y, 1)))
	elif def.kind == RtsConst.Kind.HARVESTABLE:
		fallback = Vector3(def.body_radius * 2.0, def.height, def.body_radius * 2.0)
	else:
		fallback = Vector3(def.body_radius * 2.0, def.height, def.body_radius * 2.0)

	_model = ArtKit.build_model(def.model_path, def.model_scale, fallback)
	if _model != null:
		add_child(_model)
		ArtKit.apply_team_color(_model, team_color)
		_anim = ArtKit.attach_anim(_model)
		_collect_meshes(_model)

	_flash_mat = StandardMaterial3D.new()
	_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_mat.albedo_color = FLASH_COLOR
	_flash_mat.no_depth_test = false


## 递归收集网格（闪白用）
func _collect_meshes(n: Node) -> void:
	var mi := n as MeshInstance3D
	if mi != null:
		_meshes.append(mi)
	for c in n.get_children():
		_collect_meshes(c)


# ===========================================================================
# 动画
# ===========================================================================

## 切动画。state: idle/move/attack/cast/gather/build/death/hurt
## speed_ratio 只对 move 有意义（步频跟速度走）。
func play(state: String, speed_ratio: float = 1.0) -> void:
	if _anim == null:
		return
	# 受伤动画优先，播完自动回到逻辑状态（由 _process 清缓存后重新推）
	if _hurt_t > 0.0 and state != "death":
		return
	# idle 之外的状态切换都直接透传；move 要持续更新步频，不能去重
	if state == _anim_state and state != "move":
		return
	_anim_state = state
	ArtKit.set_anim(_anim, state, clampf(speed_ratio, 0.15, 2.0))


## 命中反馈：闪白 + 受伤动作（受伤动作限流，闪白每次都闪）
func flash() -> void:
	_apply_flash()
	if _hurt_gap <= 0.0:
		_hurt_gap = HURT_ANIM_GAP
		_hurt_t = FLASH_TIME
		if _anim != null and _anim_state != "death":
			ArtKit.set_anim(_anim, "hurt", 1.0)


## 死亡动画
func play_death() -> void:
	_hurt_t = 0.0
	_anim_state = "death"
	ArtKit.set_anim(_anim, "death", 1.0)


## 套白
func _apply_flash() -> void:
	if _flash_mat == null:
		return
	_flash_t = FLASH_TIME
	for m in _meshes:
		if m == null or not is_instance_valid(m):
			continue
		var mi := m as MeshInstance3D
		if mi == null:
			continue
		if not _prev_overlay.has(mi):
			_prev_overlay[mi] = mi.material_overlay
		mi.material_overlay = _flash_mat


## 撤白
func _clear_flash() -> void:
	for m in _prev_overlay.keys():
		if m == null or not is_instance_valid(m):
			continue
		var mi := m as MeshInstance3D
		if mi == null:
			continue
		mi.material_overlay = _prev_overlay[m]
	_prev_overlay.clear()


# ===========================================================================
# 每帧
# ===========================================================================

func _process(delta: float) -> void:
	if _hurt_gap > 0.0:
		_hurt_gap -= delta

	if _hurt_t > 0.0:
		_hurt_t -= delta
		if _hurt_t <= 0.0 and _anim_state != "death":
			# 受伤动作播完：清掉状态缓存，让单位逻辑下一帧重新推一次正确动画
			_anim_state = ""

	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			_clear_flash()
