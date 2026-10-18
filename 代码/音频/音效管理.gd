class_name Sfx
extends Node
## **音效与背景音乐管理**（素材全部由 `工具/音频` 的程序化脚本合成，无外部素材）。
##
## 用法：
##     Sfx.attach(get_tree())        # 主场景启动时调一次（幂等）
##     Sfx.play("命中_金属")          # 2D 短音
##     Sfx.play_at("命中_弓", pos)    # 3D 定位音
##     Sfx.set_bgm("bgm_战斗")        # 循环 BGM
##
## 设计要点：
##   - **播放器池**：8 个 2D + 8 个 3D 常驻通道循环复用，不在战斗热路径上 new 节点；
##   - **懒加载 + 缓存**：`res://音频/<name>.wav`，找不到文件静默跳过（不报错、不影响玩法）；
##   - 自动订阅 `Game` 的信号，把"选中/命中/死亡/胜负/采集/建造"全接上。

const DIR := "res://音频/"
const POOL_2D := 8
const POOL_3D := 8
const BGM_DB := -14.0

static var _inst: Sfx = null

var _pool2d: Array = []
var _pool3d: Array = []
var _bgm: AudioStreamPlayer = null
var _cache: Dictionary = {}
var _next2d: int = 0
var _next3d: int = 0
var _last_gold: int = -1
var _last_wood: int = -1


# ===========================================================================
# 静态入口
# ===========================================================================

## 挂载到场景树（幂等）
static func attach(tree: SceneTree) -> void:
	if _inst != null and is_instance_valid(_inst):
		return
	if tree == null:
		return
	_inst = Sfx.new()
	_inst.name = "音效"
	# 主场景还在 _ready 里挂子节点，此时 add_child 会因"父节点正在建树"失败，
	# 必须走 call_deferred；初始化（含 BGM）同理。
	tree.root.add_child.call_deferred(_inst)
	_inst._setup.call_deferred()


## 播放 2D 音效
static func play(id: String, volume_db: float = 0.0, pitch_jitter: float = 0.06) -> void:
	if _inst == null or not is_instance_valid(_inst):
		return
	_inst._play2d(id, volume_db, pitch_jitter)


## 播放 3D 定位音效
static func play_at(id: String, pos: Vector3, volume_db: float = 0.0) -> void:
	if _inst == null or not is_instance_valid(_inst):
		return
	_inst._play3d(id, pos, volume_db)


## 切 BGM
static func set_bgm(id: String) -> void:
	if _inst == null or not is_instance_valid(_inst):
		return
	_inst._set_bgm(id)


# ===========================================================================
# 初始化
# ===========================================================================

## 退出时释放所有音频流（否则引擎会报 "resources still in use at exit"）
func _exit_tree() -> void:
	if _bgm != null:
		_bgm.stop()
		_bgm.stream = null
	for p in _pool2d:
		if p != null:
			p.stop()
			p.stream = null
	for p3 in _pool3d:
		if p3 != null:
			p3.stop()
			p3.stream = null
	_cache.clear()


func _setup() -> void:
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool2d.append(p)
	for i in POOL_3D:
		var p3 := AudioStreamPlayer3D.new()
		p3.max_distance = 36.0
		p3.unit_size = 7.0
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p3)
		_pool3d.append(p3)
	_bgm = AudioStreamPlayer.new()
	_bgm.bus = "Master"
	_bgm.volume_db = BGM_DB
	add_child(_bgm)

	# --- 接线：把全局信号全接上 ---
	Game.selection_changed.connect(_on_selection)
	Game.combat_hit.connect(_on_hit)
	Game.unit_died.connect(_on_died)
	Game.projectile_impact.connect(_on_impact)
	Game.building_completed.connect(_on_built)
	Game.resources_changed.connect(_on_resources)
	Game.order_issued.connect(_on_order)
	Game.game_over.connect(_on_over)
	print("[音效] 已就绪（音频目录：%s）" % DIR)
	# BGM 起（延迟一帧，确保已经在树里）
	_start_bgm.call_deferred()


## 起 BGM（必须在入树之后）
func _start_bgm() -> void:
	if not is_inside_tree():
		return
	_set_bgm("bgm_战斗")


# ===========================================================================
# 播放
# ===========================================================================

## 取（并缓存）音频流
func _stream(id: String) -> AudioStream:
	if _cache.has(id):
		return _cache[id]
	var path := DIR + id + ".wav"
	var s: AudioStream = null
	if ResourceLoader.exists(path):
		s = load(path)
	_cache[id] = s
	return s


func _play2d(id: String, volume_db: float, jitter: float) -> void:
	var s := _stream(id)
	if s == null or _pool2d.is_empty():
		return
	var p: AudioStreamPlayer = _pool2d[_next2d]
	_next2d = (_next2d + 1) % _pool2d.size()
	p.stream = s
	p.volume_db = volume_db
	p.pitch_scale = 1.0 + randf_range(-jitter, jitter)
	p.play()


func _play3d(id: String, pos: Vector3, volume_db: float) -> void:
	var s := _stream(id)
	if s == null or _pool3d.is_empty():
		return
	var p: AudioStreamPlayer3D = _pool3d[_next3d]
	_next3d = (_next3d + 1) % _pool3d.size()
	p.stream = s
	p.global_position = pos
	p.volume_db = volume_db
	p.pitch_scale = 1.0 + randf_range(-0.05, 0.05)
	p.play()


func _set_bgm(id: String) -> void:
	var s := _stream(id)
	if s == null or _bgm == null:
		return
	if _bgm.stream == s and _bgm.playing:
		return
	if s is AudioStreamWAV:
		(s as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
		(s as AudioStreamWAV).loop_begin = 0
		(s as AudioStreamWAV).loop_end = (s as AudioStreamWAV).data.size() / 2
	_bgm.stream = s
	_bgm.volume_db = BGM_DB
	_bgm.play()


# ===========================================================================
# 信号处理
# ===========================================================================

## 选中：己方单位给一声应答
func _on_selection(units: Array) -> void:
	if units == null or units.is_empty():
		return
	var mine: int = 0
	for u in units:
		if u != null and is_instance_valid(u) and u.get("faction") == Game.player_faction:
			mine += 1
	if mine <= 0:
		return
	_play2d("单位_应答" if randf() < 0.5 else "单位_应答2", -6.0, 0.10)


## 命中：按攻击方式选音色
func _on_hit(attacker: Node3D, target: Node3D, _damage: float, _crit: bool) -> void:
	var pos: Vector3 = target.global_position if target != null else Vector3.ZERO
	var is_ranged := false
	if attacker != null and is_instance_valid(attacker):
		var d: UnitDef = attacker.get("def") as UnitDef
		if d != null:
			is_ranged = d.projectile != RtsConst.Projectile.NONE or d.attack_range > 3.0
	if is_ranged:
		_play3d("命中_弓", pos, -8.0)
	else:
		_play3d("命中_金属", pos, -6.0)


func _on_died(unit: Node3D) -> void:
	var pos: Vector3 = unit.global_position if unit != null else Vector3.ZERO
	_play3d("死亡", pos, -5.0)


func _on_impact(pos: Vector3, _kind: int) -> void:
	_play3d("命中_弓", pos, -9.0)


func _on_built(building: Node3D) -> void:
	var pos: Vector3 = building.global_position if building != null else Vector3.ZERO
	_play3d("建造_锤击", pos, -4.0)


## 资源变化：只在自己（玩家）增减时响，且要跟上一帧比
func _on_resources(faction: RtsFaction) -> void:
	if faction == null or faction != Game.player_faction:
		return
	if _last_gold >= 0 and faction.gold > _last_gold:
		_play2d("采集_金币", -11.0, 0.08)
	if _last_wood >= 0 and faction.wood > _last_wood:
		_play2d("采集_木材", -12.0, 0.08)
	_last_gold = faction.gold
	_last_wood = faction.wood


## 下令：法术走火球音，其余给一声点击
func _on_order(_units: Array, order: int, target_pos: Vector3, _target: Node3D) -> void:
	if order == RtsConst.Order.CAST:
		_play3d("法术_火球", target_pos, -5.0)
	elif order == RtsConst.Order.ATTACK or order == RtsConst.Order.ATTACK_MOVE:
		_play2d("攻击_挥砍", -13.0, 0.10)
	else:
		_play2d("界面_点击", -13.0, 0.06)


func _on_over(victory: bool) -> void:
	if _bgm != null:
		_bgm.stop()
	_play2d("胜利" if victory else "失败", -3.0, 0.0)
