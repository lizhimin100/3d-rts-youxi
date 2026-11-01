class_name UnitVisual
extends Node3D
## **单位外观**：模型 / 队伍色 / 程序动画 / 命中闪白 / 受伤抖动。
##
## 为什么从 RtsUnit 里拆出来：单位本体已经有移动、索敌、采集、建造四套状态机，
## 再往里塞材质遍历和闪白计时会变成一坨。外观的"所有"脏活都在这里，
## 单位本体只调 `play("move", 0.8)` / `flash()` 这种高层接口。
##
## 注意：美术资产可能还没到位 —— ArtKit 会自动退化成占位盒，这里不需要判空。

## 组合件外观注册表（见 代码/美术/组合件.gd）。用 load() 取，不写 class_name：
## ① 避免全局类缓存（.godot/global_script_class_cache.cfg）失效导致编译失败；
## ② 组合件不止一种（`combo:dungeon` / `combo:campfire`），key → 脚本的映射只在那一处维护。
var _combo_registry: Script = null

## 命中反馈时长（秒）。建筑比单位更短：整栋楼亮一下太久会显得迟钝。
const FLASH_TIME_UNIT: float = 0.10
const FLASH_TIME_BUILDING: float = 0.07
## 两次受伤动画之间的最小间隔（防止被集火时动画抖成抽搐）
const HURT_ANIM_GAP: float = 0.3
## 命中反馈色：**深暖橙，不是白**。
## 以前用 (1,1,1,0.82) 的 unshaded 白整块盖上去 —— 材质细节、队伍色、金属高光
## 全被洗掉，看起来像"变成石膏像"或"整片泛白"（老板原话）。
## 现在只做两层：① 极短的低强度暖光脉冲（ADD，只抬亮不夺色）
##              ② 0.12s 的方向性受击顿挫（Tween），像"被打得晃了一下"
const FLASH_COLOR: Color = Color(1.0, 0.34, 0.13)
## 叠加峰值（ADD 混合的 alpha）。单位 0.18 已经很克制；建筑**不用整面闪白**，
## 改为墙根尘土 + 裂缝 + 轻微顿挫（见 建筑.gd 的 _damage_fx）。
const FLASH_PEAK_UNIT: float = 0.18
const FLASH_PEAK_BUILDING: float = 0.0
## 受击顿挫距离 / 时长（米 / 秒）
const HIT_NUDGE: float = 0.075
const HIT_NUDGE_TIME: float = 0.12

## 模型根
var _model: Node3D = null
## 建筑抬升量（米）：资产包的"训练场/散水"平面在 z=0，和地形共面会 z-fighting
## （现场图里的橙黑噪点就是它）。抬高 12cm + 下面垫一层石基，平面离开地形，闪烁根除。
const BUILDING_LIFT := 0.06
## 程序动画器（可能为 null：美术没到位时）
var _anim: Node = null
## 收集到的所有网格（闪白要挨个套 overlay）
var _meshes: Array = []
## 本次命中的时长 / 峰值（按单位或建筑分档，见 build）
var _flash_dur: float = FLASH_TIME_UNIT
var _flash_peak: float = FLASH_PEAK_UNIT
## 闪白材质（复用一份，别每次 new）
var _flash_mat: StandardMaterial3D = null
## 被闪白覆盖前的原 overlay，恢复时用
var _prev_overlay: Dictionary = {}
## 暖光脉冲 / 受击顿挫：全部走 Tween，不自己做逐帧动画
var _flash_tween: Tween = null
var _nudge_tween: Tween = null
## 顿挫的基准位置（模型的本地坐标）
var _nudge_base: Vector3 = Vector3.ZERO
## 当前动画状态（去重用）
var _anim_state: String = ""
## 受伤动画剩余时间
var _hurt_t: float = 0.0
## 受伤动画冷却
var _hurt_gap: float = 0.0
## 是否已经构建（避免重复建模型）
var _built: bool = false

# ---------------------------------------------------------------------------
# 无骨骼模型的"整体程序动作"（2026-10-31）
# ---------------------------------------------------------------------------
#
# 新步兵是「方块人」：三块网格（unit_body / unit_team / unit_trim）拼出来的静态模型，
# glb 里既没有 AnimationPlayer 也没有 Body/Torso 关节，ProcAnim 绑不上 —— 不收这个尾，
# 兵在场上就是一根会滑动的柱子。
#
# 这里只做**整体**的三件事（不动网格本体、不新建材质，零 draw call 成本）：
#   · 走路：上下小幅弹跳 + 前后微倾，相位跟地速走；
#   · 待机：极慢的呼吸起伏（1.6cm）；
#   · 攻击：一次 0.16s 的前冲回弹（"撞一下"）。
# 有骨骼动画的资产完全不受影响（_static_anim 为 false 时整段不跑）。
const MOTION_BOB := 0.032
const MOTION_BOB_SPEED := 2.35
const MOTION_IDLE_AMP := 0.010
const MOTION_IDLE_SPEED := 1.15
const MOTION_LEAN := 0.055
const MOTION_LUNGE := 0.16
const MOTION_LUNGE_TIME := 0.16
var _static_anim: bool = false
var _motion_pivot: Node3D = null
var _motion_t: float = 0.0
var _motion_state: String = "idle"
var _lunge_t: float = 0.0

# ---------------------------------------------------------------------------
# 走路步频（2026-11-01 修"蠕动/小碎步"）
# ---------------------------------------------------------------------------
#
# 玩家原话："步兵的移动动作有些怪，移动起来像蠕动、慢慢挪动、小碎步"。
#
# 病根不是动画本身，是**播放速度**：`RtsUnit._update_anim()` 传进来的是
# `_speed / _max_speed()`（0~1 的比例），于是 walk 永远用 1.0 倍速播 ——
# 而这几只兵的实际移速是 4.3~4.6 m/s，动画步幅只够走 1.9 m/s，
# 脚在原地小碎步、身子在滑 —— 看起来就是"蠕动"。
#
# 正确口径：**按真实位移速度换算步频**。`ANIM_WALK_MPS` 是"这套 walk 动画
# 1.0 倍速时对应的地面速度"，实测（1.1s 一个双步循环、步幅约 1.05m）取 1.9。
# 上限 2.6：再快腿会抖成马赛克；4.6m/s 的兵 = 2.42 倍，脚下还剩约 5% 滑步，
# 观感上已经是"跑"而不是"挪"。
const ANIM_WALK_MPS := 1.9
const ANIM_WALK_SCALE_MAX := 2.6
const ANIM_WALK_SCALE_MIN := 0.55
## 当前单位的定义（算步频要用 move_speed）
var _def: UnitDef = null


# ===========================================================================
# 构建
# ===========================================================================

## 建模型 + 套队伍色 + 挂动画器。重复调用安全。
## proc：程序化外观的参数（当前只有树用），空字典 = 走 GLB 老路。
##   {"season": "春/夏/秋/冬"（可空 → 按种子定）, "seed": int, "yaw": float}
func build(def: UnitDef, team_color: Color, proc: Dictionary = {}) -> void:
	if _built or def == null:
		return
	_built = true
	_def = def

	# 占位尺寸：让美术没到位时的盒子比例别太离谱
	var fallback := Vector3(0.8, 1.7, 0.6)
	if def.kind == RtsConst.Kind.BUILDING:
		fallback = Vector3(float(maxi(def.footprint.x, 1)), def.height,
				float(maxi(def.footprint.y, 1)))
	elif def.kind == RtsConst.Kind.HARVESTABLE:
		fallback = Vector3(def.body_radius * 2.0, def.height, def.body_radius * 2.0)
	else:
		fallback = Vector3(def.body_radius * 2.0, def.height, def.body_radius * 2.0)

	# ★ 程序化树：不吃 glb、不套阵营色、不挂骨骼动画。
	#   三档 LOD 直接由 树库 造好（每档一个 MeshInstance3D，靠 visibility_range 切）。
	var 程序化树: bool = def.kind == RtsConst.Kind.HARVESTABLE and TreeLibrary.is_tree(def.id)
	# 组合件（`combo:` 前缀，例如地牢 = 岩石+帐篷+营火拼的巢穴、营火 = 柴堆 + 一盏暖光）：
	# 不走单个 glb，由 `代码/美术/<key>外观.gd` 现场拼，材质全是"自然_"那套。
	var 组合件: bool = String(def.model_path).begins_with("combo:")
	if 组合件:
		_model = _build_combo(def)
	elif 程序化树:
		_model = TreeLibrary.build_visual(def, proc)
	else:
		_model = ArtKit.build_model(def.model_path, def.model_scale, fallback)
	if _model != null:
		add_child(_model)
		if def.is_building():
			# 只抬 6cm：资产包自带 0.55m 石台，6cm 足够离开地形又不显悬空；
			# 不再加"黑色大石台"（实测比建筑还抢眼）。
			_model.position.y = BUILDING_LIFT
		if not 程序化树 and not 组合件:
			ArtKit.apply_team_color(_model, team_color)
			_anim = ArtKit.attach_anim(_model)
		_collect_meshes(_model)
		_add_ground_shadow(def)
		_nudge_base = _model.position
		# 方块人（无骨骼单位）挂一层"动作枢轴"：整体弹跳/前冲走枢轴，
		# 受击顿挫仍然走 _model.position —— 两条 tween/相位互不覆盖。
		if def.kind == RtsConst.Kind.UNIT and _anim_is_static():
			_static_anim = true
			_motion_pivot = Node3D.new()
			_motion_pivot.name = "动作"
			add_child(_motion_pivot)
			remove_child(_model)
			_motion_pivot.add_child(_model)

	_flash_mat = StandardMaterial3D.new()
	_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# ADD 叠加：只是在原色上"加一点暖光"，不是覆盖一层不透明的白。
	# 这是"泛白"和"被打了一下"的分水岭。
	_flash_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash_mat.albedo_color = Color(FLASH_COLOR.r, FLASH_COLOR.g, FLASH_COLOR.b, 0.0)
	_flash_mat.no_depth_test = false
	# 建筑分档：面大、颜色浅，同样的强度会刺眼得多
	if def.kind == RtsConst.Kind.BUILDING:
		_flash_dur = FLASH_TIME_BUILDING
		_flash_peak = FLASH_PEAK_BUILDING
	else:
		_flash_dur = FLASH_TIME_UNIT
		_flash_peak = FLASH_PEAK_UNIT


## 动画器是不是"绑不上"的静态模型（没有骨骼 / 没有 Body/Torso 关节）
func _anim_is_static() -> bool:
	if _anim == null:
		return true
	if _anim.has_method("已绑定"):
		return not bool(_anim.call("已绑定"))
	return false


## 接触阴影（Decal 贴地）。## 为什么必须加：建筑/单位脚下的地形是程序化低模，没有"落地暗角"，
## 模型再精细也像剪下来贴在图上。Decal 沿 -Y 投影，把柔和暗斑压进地面，
## 比在 Blender 里烘一张阴影贴图更吃实时地形高度，也不会随地形起伏悬空。
const SHADOW_TEX := "res://美术/贴图/接触阴影.png"
static var _shadow_texture: Texture2D = null
## ★ 阴影贴片要**按尺寸共享**：以前每个单位 new 一份 PlaneMesh + StandardMaterial3D，
##   单局 150 棵树 = 150 份材质 = 150 次独立批处理，纯浪费。
##   同一类单位尺寸相同（树的 body_radius 都是 0.9），共享之后全场景只有 1~3 份。
static var _shadow_mesh_cache: Dictionary = {}
static var _shadow_mat_cache: Dictionary = {}

func _add_ground_shadow(def: UnitDef) -> void:
	if def == null:
		return
	if _shadow_texture == null and ResourceLoader.exists(SHADOW_TEX):
		_shadow_texture = load(SHADOW_TEX) as Texture2D
	if _shadow_texture == null:
		return
	var w: float = 1.2
	var d: float = 1.2
	var alpha: float = 0.62
	if def.is_building():
		w = float(maxi(def.footprint.x, 2)) * 1.72
		d = float(maxi(def.footprint.y, 2)) * 1.72
		alpha = 0.58
	elif def.is_harvestable():
		w = def.body_radius * 3.1
		d = def.body_radius * 3.1
		alpha = 0.42
	else:
		w = def.body_radius * 2.7
		d = def.body_radius * 2.7
		alpha = 0.52
	# 用"贴地半透明面片"而不是 Decal：
	# 地形是自定义 ShaderMaterial，Decal 投影不吃它的光照/材质路径（实测脚下不出现暗角）。
	# 面片是 unshaded 的软阴影图，压在地面上 6cm，任何着色器都吃得下。
	var quad := MeshInstance3D.new()
	quad.name = "接触阴影"
	var key := "%.2f|%.2f|%.2f" % [w, d, alpha]
	var pm: PlaneMesh = _shadow_mesh_cache.get(key, null) as PlaneMesh
	if pm == null:
		pm = PlaneMesh.new()
		pm.size = Vector2(w, d)
		_shadow_mesh_cache[key] = pm
	quad.mesh = pm
	var mat: StandardMaterial3D = _shadow_mat_cache.get(key, null) as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		mat.albedo_texture = _shadow_texture
		mat.albedo_color = Color(1.0, 1.0, 1.0, alpha)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		mat.disable_receive_shadows = true
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		_shadow_mat_cache[key] = mat
	quad.material_override = mat
	quad.position = Vector3(0.0, 0.012 if def.is_building() else 0.06, 0.0)
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(quad)


## 递归收集网格（闪白用）
func _collect_meshes(n: Node) -> void:
	var mi := n as MeshInstance3D
	if mi != null:
		_meshes.append(mi)
	for c in n.get_children():
		_collect_meshes(c)


## 造组合件外观：`combo:<key>` → 交给 `代码/美术/组合件.gd`（key → 中文外观脚本的映射表）。
## 找不到脚本就返回 null（上层退回占位盒，不报错、不白屏）。
func _build_combo(def: UnitDef) -> Node3D:
	var key: String = String(def.model_path).substr(6)
	if key.is_empty():
		return null
	if _combo_registry == null:
		_combo_registry = load("res://代码/美术/组合件.gd")
	if _combo_registry == null:
		return null
	var n: Variant = _combo_registry.call("build", key, def)
	return n as Node3D


# ===========================================================================
# 动画
# ===========================================================================

## 切动画。state: idle/move/attack/cast/gather/build/death/hurt
## speed_ratio 只对 move 有意义：**传进来的是 0~1 的速度比例**（`_speed / _max_speed()`），
## 这里换算成"动画该放多快"，见 ANIM_WALK_MPS 那段注释。
func play(state: String, speed_ratio: float = 1.0) -> void:
	# 受伤动画优先，播完自动回到逻辑状态（由 _process 清缓存后重新推）
	if _hurt_t > 0.0 and state != "death":
		return
	# 无骨骼模型没有 set_state 可调，但"整体程序动作"仍然需要知道当前状态
	if _static_anim and state != _motion_state:
		if state == "attack":
			_lunge_t = MOTION_LUNGE_TIME
		_motion_state = state
	if _anim == null:
		return
	# idle 之外的状态切换都直接透传；move 要持续更新步频，不能去重
	var loco: bool = state == "move" or state == "run" or state.begins_with("carry_")
	if state == _anim_state and not loco:
		return
	_anim_state = state
	var scale: float = clampf(speed_ratio, 0.15, 3.0)
	if loco:
		# 0~1 的比例 × 实际最高移速 = 此刻真实地速（m/s），再除以动画步速
		var top: float = _def.move_speed if _def != null else ANIM_WALK_MPS
		var mps: float = maxf(top * clampf(speed_ratio, 0.0, 1.6), 0.15)
		scale = clampf(mps / ANIM_WALK_MPS, ANIM_WALK_SCALE_MIN, ANIM_WALK_SCALE_MAX)
	ArtKit.set_anim(_anim, state, scale)


## 命中反馈：暖光脉冲 + 方向性顿挫 + 受伤动作（受伤动作限流，脉冲每次都打）
## from_pos 是攻击来源的世界坐标（可为 Vector3.ZERO：远程/脚本伤害没有方向）。
func flash(from_pos: Vector3 = Vector3.ZERO) -> void:
	_apply_flash()
	_apply_hit_nudge(from_pos)
	if _hurt_gap <= 0.0:
		_hurt_gap = HURT_ANIM_GAP
		_hurt_t = _flash_dur
		if _anim != null and _anim_state != "death":
			ArtKit.set_anim(_anim, "hurt", 1.0)


## 死亡动画
func play_death() -> void:
	_hurt_t = 0.0
	_anim_state = "death"
	ArtKit.set_anim(_anim, "death", 1.0)


## 打一发暖光脉冲（ADD 混合，见 build 里的材质参数）。
## 建筑峰值 = 0：**不做整面墙泛白**，只靠尘土/裂缝/顿挫表达挨打。
func _apply_flash() -> void:
	if _flash_mat == null or _flash_peak <= 0.001:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_set_flash_alpha(_flash_peak)
	for m in _meshes:
		if m == null or not is_instance_valid(m):
			continue
		var mi := m as MeshInstance3D
		if mi == null:
			continue
		if not _prev_overlay.has(mi):
			_prev_overlay[mi] = mi.material_overlay
		mi.material_overlay = _flash_mat
	# Tween 把 ADD 层的 alpha 从峰值收到 0；比逐帧手写曲线更好调、也不会漏状态
	_flash_tween = create_tween()
	_flash_tween.tween_property(_flash_mat, "albedo_color:a", 0.0, _flash_dur) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_flash_tween.tween_callback(_clear_flash)


## 方向性受击顿挫：单位/建筑都只用 7.5cm、0.12s —— 是"晃一下"，不是"整栋跳"
func _apply_hit_nudge(from_pos: Vector3) -> void:
	if _model == null or not is_instance_valid(_model):
		return
	if _nudge_tween != null and _nudge_tween.is_valid():
		_nudge_tween.kill()
	_model.position = _nudge_base
	var dir := Vector3.ZERO
	if from_pos != Vector3.ZERO:
		dir = global_position - from_pos
		dir.y = 0.0
	if dir.length_squared() < 0.0001:
		dir = Vector3(cos(randf() * TAU), 0.0, sin(randf() * TAU))
	dir = dir.normalized()
	var off: Vector3 = dir * HIT_NUDGE
	_nudge_tween = create_tween()
	_nudge_tween.tween_property(_model, "position", _nudge_base + off, HIT_NUDGE_TIME * 0.38) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_nudge_tween.tween_property(_model, "position", _nudge_base, HIT_NUDGE_TIME * 0.62) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _set_flash_alpha(a: float) -> void:
	var c := FLASH_COLOR
	c.a = clampf(a, 0.0, 1.0)
	_flash_mat.albedo_color = c


## 自检：当前命中反馈是否"暖色 + 低强度 + 非白"（不依赖渲染）
func flash_debug() -> Dictionary:
	var c: Color = _flash_mat.albedo_color if _flash_mat != null else Color.WHITE
	return {
		"color": c,
		"peak": _flash_peak,
		"building_no_overlay": _flash_peak <= 0.001,
		"blend_add": _flash_mat.blend_mode == BaseMaterial3D.BLEND_MODE_ADD if _flash_mat != null else false,
		"white": c.r > 0.98 and c.g > 0.90 and c.b > 0.90,
	}


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

	if _static_anim:
		_tick_motion(delta)

	if _hurt_t > 0.0:
		_hurt_t -= delta
		if _hurt_t <= 0.0 and _anim_state != "death":
			# 受伤动作播完：清掉状态缓存，让单位逻辑下一帧重新推一次正确动画
			_anim_state = ""


## 无骨骼模型的整体动作：走路弹跳 + 前后微倾 + 攻击前冲。
## 只改枢轴的 position/rotation，网格与材质一个字节都不碰。
func _tick_motion(dt: float) -> void:
	if _motion_pivot == null or not is_instance_valid(_motion_pivot):
		return
	var moving: bool = _motion_state == "move"
	var speed: float = MOTION_BOB_SPEED if moving else MOTION_IDLE_SPEED
	_motion_t += dt * speed
	var amp: float = MOTION_BOB if moving else MOTION_IDLE_AMP
	var bob: float = absf(sin(_motion_t * PI)) * amp
	var lean: float = MOTION_LEAN if moving else 0.0
	# 攻击前冲：0.16s 内 sin 半周冲出去再回来，不打断行走相位
	var lunge: float = 0.0
	if _lunge_t > 0.0:
		_lunge_t = maxf(_lunge_t - dt, 0.0)
		lunge = sin((1.0 - _lunge_t / MOTION_LUNGE_TIME) * PI) * MOTION_LUNGE
	_motion_pivot.position = Vector3(0.0, bob, -lunge)
	_motion_pivot.rotation.x = -lean
