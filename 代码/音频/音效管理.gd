class_name Sfx
extends Node
## **音效 / 语音 / BGM 管理**（音效与 BGM 由 工具/音频/合成音效.py、语音由 合成语音_v2.py 程序化合成，零外部素材）。
##
## 这一版重点解决四件事：
##
## 1. **总线**：Master / Music / SFX / UI / Voice，电平写在 音频/default_bus_layout.tres，
##    启动时用 AudioServer.set_bus_layout() 应用 —— **不改 project.godot**。
##    资源若加载失败，下面的 _ensure_bus() 会按同一套电平把缺失的总线补出来。
##
## 2. **素材加载绕开导入管线**：新增 WAV 直接用 AudioStreamWAV.load_from_file() 读源文件，
##    所以**不需要 --import**（.godot 里没有导入产物也能播）。编辑器下次打开会补 .import，不影响这里。
##
## 3. **反馈预算**（任务书 A）：每个音效 id 有三把闸 —— 节流（最小间隔）/ 每秒上限 / 并发上限。
##    点选 75ms、移动 80ms；一次 selection_changed 哪怕带 12 个单位也只播 1 声。
##
## 4. **语音接线（v3）**：指令_前进/进攻/撤退、提示_金币不足/人口已满/建造完成
##    这 6 条由 工具/音频/合成语音_v2.py（SAPI 中文 TTS + DSP）生成；以前没有任何调用者，
##    现在分别挂在 order_issued / notify / building_completed 上，各带 4~10s 节流。
##
## 电平约定：WAV 峰值已经按任务书做在文件里（点选 -19 / 移动 -15 / 语音 -8 dBFS），
## 播放端不再按声音重复衰减，只做"总线 + UI 补偿"：
##     UI 总线 -16 dB 是整类压低，短促点击会掉到听不见，所以 UI 一声额外补 +6 dB；
##     有效电平 = 文件峰值 + 总线 + 补偿，具体数值见本文件常量与 音频/来源.md。
##
## 用法：
##     Sfx.attach(get_tree())        # 主场景启动时调一次（幂等）
##     Sfx.play("战斗_命中")          # 2D 短音（按 id 自动选总线）
##     Sfx.play_at("战斗_命中", pos)  # 3D 定位音
##     Sfx.set_bgm("bgm_战")          # 循环 BGM（战斗曲；平常曲内部自动轮播）

const DIR := "res://音频/"
const BUS_LAYOUT := "res://音频/default_bus_layout.tres"

## 语音映射表（用 preload 而不是全局类名：新脚本还没进 .godot 的 class 缓存时也能工作）
const VOICE_MAP := preload("res://代码/音频/语音表.gd")

const POOL_2D := 8
const POOL_3D := 8

const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"
const BUS_UI := "UI"
const BUS_VOICE := "Voice"

## UI 总线的可听度补偿（见文件头"电平约定"）
const UI_MAKEUP_DB := 6.0
## 音乐总线电平（dB）。旧值 -14 实测偏吵：BGM 是连续音，SFX 是瞬态，
## 同一峰值下 BGM 听起来明显更响。降到 -19 后 BGM 退到"背景"，不压指令/战斗反馈。
const MUSIC_BUS_DB := -19.0
const BGM_DB := -1.0           # 音乐在总线基础上再压 1 dB（总线见 default_bus_layout.tres）
const VOICE_THROTTLE := 5.0    # 应答语音全局 5s 节流
const DEATH_VOICE_THROTTLE := 8.0
const COMBAT_HOLD := 16.0      # 最后一次交战后 16s 自然退回和平 BGM

## BGM 素材（48kHz 立体声 16bit，全部 音频/ 下）：
##   bgm_和平_和 / bgm_和平_森 —— **平常**用的两首，轮流播放（每首放完一遍交叉淡化到下一首）
##   bgm_战   —— **小规模战斗**用的，打起来自然淡入、打完自然淡回原曲原位置
##   bgm_舒缓 —— 开局序曲（25.8s），放完平滑并入和平轮播
##
## 三件事保证"不生硬"：
##   1. **循环接缝**：载入时把尾 0.35s 与头 0.35s 等功率交叉淡化后截尾，循环点两侧
##      样本在原文件里就是相邻的，不可能有"咔哒"。
##   2. **等功率交叉淡化**：两首同时存在、sin/cos 能量互补 + smoothstep 曲线，
##      不存在"先掉到 -20dB 再涨回来"的断层。
##   3. **响度对齐**：四个素材的 RMS 差 10dB 之多（战比和平低 10.3dB，直接切会像被捂住），
##      所以每首先按实测 RMS 归一化到 -23dBFS 再进播放器（见 BGM_TRIM_DB）。
const BGM_PEACE: Array[String] = ["bgm_和平_和", "bgm_和平_森"]
const BGM_BATTLE := "bgm_战"
const BGM_SOFT := "bgm_舒缓"
## 每首 BGM 的响度补偿（dB）。用整曲 RMS 实测后归一到 0.070（≈ -23.1 dBFS）：
##   和 -19.14dBFS / 森 -19.47 / 战 -29.48 / 舒缓 -21.51。
## 重新导入素材后若音量变了，只改这张表（峰值不会顶到 limiter）。
const BGM_TRIM_DB := {
	"bgm_和平_和": -3.9,
	"bgm_和平_森": -3.6,
	"bgm_战": 6.4,
	"bgm_舒缓": -1.6,
}
## 循环接缝交叉淡化长度（秒）
const BGM_LOOP_FIX := 0.35
## 淡入淡出时长（秒）
const BGM_FADE_IN := 3.0           # 起播
const BGM_FADE_TO_BATTLE := 3.2    # 和平 → 战：慢一点，别"炸"出来
const BGM_FADE_TO_CALM := 4.2      # 战 → 和平：更慢，收尾
const BGM_FADE_ROTATE := 4.5       # 和平两首之间轮播
const BGM_FADE_OUT := 2.2          # 结算
## 提前多少秒开始轮播下一首（= 淡入淡出时长，保证过渡完整落在曲子里）
const BGM_ROTATE_LEAD := 4.5
## 静音深度（dB）：线性增益到 0 时用 -80 代替 -inf，避免 log(0)
const BGM_SILENT_DB := -80.0

## 口令 / 提示语音 id（= 音频/ 下的文件名；由 合成语音_v2.py 生成）
const VOICE_FORWARD := "指令_前进"
const VOICE_ATTACK := "指令_进攻"
const VOICE_FALLBACK := "指令_撤退"
const VOICE_NO_GOLD := "提示_金币不足"
const VOICE_NO_FOOD := "提示_人口已满"
const VOICE_BUILT := "提示_建造完成"

## 低血警报阈值（己方最惨单位低于这个血量比就响；5s 节流在 SPEC 里）
const LOW_HP_RATIO := 0.30

## 每个音效的播放规格：
##   bus        走哪条总线
##   throttle   最小播放间隔（秒）——"60~90ms"这一类
##   per_sec    1 秒窗口内最多播几次（响度预算，超了直接丢）
##   concurrent 同一时刻最多几个（点选限 2）
##   pitch      音高随机抖动幅度（避免机关枪式重复）
const SPEC := {
	"界面_点选": {"bus": BUS_UI, "throttle": 0.075, "per_sec": 4, "concurrent": 2, "pitch": 0.04},
	"界面_框选": {"bus": BUS_UI, "throttle": 0.090, "per_sec": 3, "concurrent": 2, "pitch": 0.05},
	"指令_移动": {"bus": BUS_UI, "throttle": 0.080, "per_sec": 4, "concurrent": 2, "pitch": 0.05},
	"战斗_攻击": {"bus": BUS_SFX, "throttle": 0.120, "per_sec": 5, "concurrent": 3, "pitch": 0.05},
	"战斗_命中": {"bus": BUS_SFX, "throttle": 0.030, "per_sec": 10, "concurrent": 6, "pitch": 0.08},
	"战斗_死亡": {"bus": BUS_SFX, "throttle": 0.080, "per_sec": 4, "concurrent": 3, "pitch": 0.06},
	"建造_完成": {"bus": BUS_SFX, "throttle": 0.150, "per_sec": 3, "concurrent": 2, "pitch": 0.04},
	"采集_资源": {"bus": BUS_SFX, "throttle": 0.120, "per_sec": 3, "concurrent": 2, "pitch": 0.05},
	"法术_施放": {"bus": BUS_SFX, "throttle": 0.150, "per_sec": 3, "concurrent": 2, "pitch": 0.04},
	"结算_胜利": {"bus": BUS_SFX, "throttle": 1.000, "per_sec": 1, "concurrent": 1, "pitch": 0.0},
	"结算_失败": {"bus": BUS_SFX, "throttle": 1.000, "per_sec": 1, "concurrent": 1, "pitch": 0.0},
	# --- v3 新增 ---
	"战斗_箭矢": {"bus": BUS_SFX, "throttle": 0.050, "per_sec": 6, "concurrent": 4, "pitch": 0.08},
	"战斗_塔射": {"bus": BUS_SFX, "throttle": 0.090, "per_sec": 4, "concurrent": 3, "pitch": 0.06},
	"建造_放置": {"bus": BUS_SFX, "throttle": 0.150, "per_sec": 3, "concurrent": 2, "pitch": 0.05},
	"建造_锤击": {"bus": BUS_SFX, "throttle": 0.120, "per_sec": 5, "concurrent": 3, "pitch": 0.07},
	"提示_低血": {"bus": BUS_UI, "throttle": 5.000, "per_sec": 1, "concurrent": 1, "pitch": 0.0},
	"升级_完成": {"bus": BUS_SFX, "throttle": 1.000, "per_sec": 1, "concurrent": 1, "pitch": 0.0},
	# --- 口令语音（走 Voice 总线，节流压住刷屏） ---
	"指令_前进": {"bus": BUS_VOICE, "throttle": 8.000, "per_sec": 1, "concurrent": 1, "pitch": 0.02},
	"指令_进攻": {"bus": BUS_VOICE, "throttle": 8.000, "per_sec": 1, "concurrent": 1, "pitch": 0.02},
	"指令_撤退": {"bus": BUS_VOICE, "throttle": 10.000, "per_sec": 1, "concurrent": 1, "pitch": 0.02},
	"提示_金币不足": {"bus": BUS_VOICE, "throttle": 4.000, "per_sec": 1, "concurrent": 1, "pitch": 0.0},
	"提示_人口已满": {"bus": BUS_VOICE, "throttle": 4.000, "per_sec": 1, "concurrent": 1, "pitch": 0.0},
	"提示_建造完成": {"bus": BUS_VOICE, "throttle": 8.000, "per_sec": 1, "concurrent": 1, "pitch": 0.0},
}

## 没登记的 id（例如语音）走这套：不限流（调用方自己节流）、SFX 总线
const DEFAULT_SPEC := {"bus": BUS_SFX, "throttle": 0.0, "per_sec": 0, "concurrent": 0, "pitch": 0.03}

static var _inst: Sfx = null

var _pool2d: Array[AudioStreamPlayer] = []
var _pool3d: Array[AudioStreamPlayer3D] = []
var _bgm_a: AudioStreamPlayer = null    # 双播放器之一（交叉淡入淡出用）
var _bgm_b: AudioStreamPlayer = null    # 双播放器之二
var _bgm_cur: AudioStreamPlayer = null  # 当前可闻的那个
var _bgm_in: AudioStreamPlayer = null   # 正在淡入的那个（crossfade 期间）
var _bgm_out: AudioStreamPlayer = null  # 正在淡出的那个（crossfade 期间）
var _bgm_fading: bool = false
var _bgm_fade_t: float = 0.0
var _bgm_fade_dur: float = 1.0          # 本次淡化的总时长
var _bgm_stopping: bool = false         # true = 淡出到静音（结算），不再起新曲
var _bgm_out_env: float = 0.0           # 淡出方的起始包络（0~1，中途改指令时不跳变）
var _bgm_cur_env: float = 0.0           # 当前曲的真实包络（战斗回来时按它续接）
var _bgm_in_env: float = 0.0            # 淡入方的最新包络
var _bgm_in_id: String = ""             # 淡入方播的是哪首（响度补偿要用）
var _bgm_out_id: String = ""            # 淡出方播的是哪首
var _bgm_pending: String = ""           # 换曲途中排队的下一首
var _bgm_pending_pos: float = 0.0
var _music_limiter_added: bool = false
var _cache: Dictionary = {}
var _next2d: int = 0
var _next3d: int = 0
var _last_gold: int = -1
var _last_wood: int = -1

# --- 反馈预算状态 ---
var _last_played: Dictionary = {}   # id -> 上次播放时刻（秒）
var _window: Dictionary = {}        # id -> Array[float] 最近 1 秒的播放时刻
var _active: Dictionary = {}        # id -> Array[float] 结束时刻（用于并发上限）

# --- 语音 / BGM 状态 ---
var _last_voice: float = -9999.0
var _last_death_voice: float = -9999.0
var _last_sel_frame: int = -1
var _combat_until: float = 0.0
var _bgm_id: String = ""
## 和平轮播下标（BGM_PEACE）与"本曲已放多久"（用于提前 BGM_ROTATE_LEAD 秒换下一首）
var _peace_idx: int = 0
var _peace_elapsed: float = 0.0
## 进战斗前记下的和平曲（id / 播放位置 / 已放时长），打完原样续上
var _peace_saved_id: String = ""
var _peace_saved_pos: float = 0.0
var _peace_saved_elapsed: float = 0.0
var _in_battle: bool = false
## QA：`--bgm-qa` 脚本化走一遍「序曲 → 和平 → 战斗 → 和平 → 再次战斗」
var _qa_bgm: bool = false
var _qa_t: float = 0.0
var _qa_step: int = 0
var _hp_check_t: float = 0.0


# ===========================================================================
# 静态入口
# ===========================================================================

## 挂载到场景树（幂等）
static func attach(tree: SceneTree) -> void:
	if _inst != null and is_instance_valid(_inst):
		# 重开一局：节点挂在 /root 下不会被 reload 掉，但结算时 BGM 已经 stop 了
		_inst._resume_after_restart.call_deferred()
		return
	if tree == null:
		return
	_inst = Sfx.new()
	_inst.name = "音效"
	# 主场景还在 _ready 里挂子节点，此时 add_child 会因"父节点正在建树"失败，
	# 必须走 call_deferred；初始化（含 BGM）同理。
	tree.root.add_child.call_deferred(_inst)
	_inst._setup.call_deferred()


## 播放 2D 音效（总线/节流/预算由 SPEC 决定）
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
	if _bgm_a != null:
		_bgm_a.stop()
		_bgm_a.stream = null
	if _bgm_b != null:
		_bgm_b.stop()
		_bgm_b.stream = null
	for p in _pool2d:
		if p != null:
			p.stop()
			p.stream = null
	for p3 in _pool3d:
		if p3 != null:
			p3.stop()
			p3.stream = null
	_cache.clear()
	_active.clear()
	_window.clear()


func _setup() -> void:
	_setup_buses()

	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_SFX
		add_child(p)
		_pool2d.append(p)
	for i in POOL_3D:
		var p3 := AudioStreamPlayer3D.new()
		p3.bus = BUS_SFX
		p3.max_distance = 36.0
		p3.unit_size = 7.0
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p3)
		_pool3d.append(p3)
	_bgm_a = AudioStreamPlayer.new()
	_bgm_a.bus = BUS_MUSIC
	_bgm_a.volume_db = BGM_SILENT_DB
	add_child(_bgm_a)
	_bgm_b = AudioStreamPlayer.new()
	_bgm_b.bus = BUS_MUSIC
	_bgm_b.volume_db = BGM_SILENT_DB
	add_child(_bgm_b)
	_bgm_cur = _bgm_a
	_qa_bgm = OS.get_cmdline_user_args().has("--bgm-qa")

	# --- 接线：把全局信号全接上（不碰 单位.gd / 选择系统 / 指令系统）---
	Game.selection_changed.connect(_on_selection)
	Game.combat_hit.connect(_on_hit)
	Game.unit_died.connect(_on_died)
	Game.projectile_impact.connect(_on_impact)
	Game.building_completed.connect(_on_built)
	Game.resources_changed.connect(_on_resources)
	Game.order_issued.connect(_on_order)
	Game.game_over.connect(_on_over)
	Game.notify.connect(_on_notify)
	print("[音效] 已就绪（音频目录：%s）" % DIR)
	# BGM 起（延迟一帧，确保已经在树里）
	_start_bgm.call_deferred()


## 应用总线布局；资源缺失/字段不全时就地补齐
func _setup_buses() -> void:
	var layout: AudioBusLayout = null
	if ResourceLoader.exists(BUS_LAYOUT):
		layout = load(BUS_LAYOUT) as AudioBusLayout
	if layout != null:
		AudioServer.set_bus_layout(layout)
	# 兜底：布局万一没保住 Master（0 号总线），先把它改回来，否则所有播放器都没地方落
	if AudioServer.bus_count > 0 and AudioServer.get_bus_index("Master") < 0:
		AudioServer.set_bus_name(0, "Master")
		AudioServer.set_bus_volume_db(0, 0.0)
	_ensure_bus(BUS_MUSIC, MUSIC_BUS_DB)
	# 电平以代码为准（音频/default_bus_layout.tres 同步改成同一个值）：
	# 用户反馈 BGM"有点吵"，整体从 -14 dB 降到 -19 dB，再叠加 BGM_DB=-1。
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(BUS_MUSIC), MUSIC_BUS_DB)
	_add_music_limiter()
	_ensure_bus(BUS_SFX, -6.0)
	_ensure_bus(BUS_UI, -16.0)
	_ensure_bus(BUS_VOICE, -8.0)
	var parts: PackedStringArray = []
	for i in AudioServer.bus_count:
		parts.append("%s(%.1fdB)" % [AudioServer.get_bus_name(i), AudioServer.get_bus_volume_db(i)])
	print("[音效] 总线：%s" % " ".join(parts))


## 确保某条总线存在（存在则只补 send，不改用户调好的电平）
func _ensure_bus(bus_name: String, db: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_volume_db(idx, db)
		AudioServer.set_bus_send(idx, "Master")
		return
	if String(AudioServer.get_bus_send(idx)).is_empty():
		AudioServer.set_bus_send(idx, "Master")


## 重开一局时复位 BGM（attach 的幂等分支走这里）
##
## 结算时 _on_over() 会 stop 并把 _bgm_id 清空，而 attach() 因为单例还在会直接返回，
## 结果是重开后一直没有 BGM，要等第一次交战才被拉起来。
func _resume_after_restart() -> void:
	if _bgm_cur == null or not is_inside_tree():
		return
	if Game.phase != RtsConst.Phase.RUNNING:
		return
	_last_gold = -1
	_last_wood = -1
	_combat_until = 0.0
	_bgm_stopping = false
	_in_battle = false
	_bgm_id = ""
	_peace_idx = 0
	_peace_elapsed = 0.0
	_peace_saved_id = ""
	_hard_stop_bgm()
	_play_track(BGM_SOFT, BGM_FADE_IN, 0.0)
	print("[音效] 重开：BGM 复位 → %s" % BGM_SOFT)


## 起 BGM（必须在入树之后）
func _start_bgm() -> void:
	if not is_inside_tree():
		return
	# 开局先放舒缓序曲（25.8s），放完自动并入和平轮播
	_peace_idx = 0
	_peace_elapsed = 0.0
	_play_track(BGM_SOFT, BGM_FADE_IN, 0.0)
	# 预解码另外两首（各 75s / 14MB），避免第一次切歌时在主线程卡一下
	for id in BGM_PEACE:
		_stream(id)
	_stream(BGM_BATTLE)


# ===========================================================================
# 播放
# ===========================================================================

## 取（并缓存）音频流
##
## ★ BGM 优先 **OGG**（2026-11-01 优化）：
##   6 首 WAV 合计 74MB，`AudioStreamWAV` 是整段 PCM 常驻内存，启动时还要为
##   "无缝循环"复制一遍 13MB 缓冲 —— 光 BGM 就吃掉 70MB+ 静态内存。
##   现在 OGG 只有 5.6MB，而且**接缝已经在离线阶段接好**（工具/音频/压缩BGM到OGG.py
##   用的是同一套等功率交叉淡化），运行时只要 `loop = true`，解码器流式读盘。
##   WAV 那条路原样保留：素材缺失/没转过的项目照样能跑。
func _stream(id: String) -> AudioStream:
	if _cache.has(id):
		return _cache[id]
	var s: AudioStream = null
	if id.begins_with("bgm"):
		var opath: String = DIR + id + ".ogg"
		if FileAccess.file_exists(opath):
			var ogg := AudioStreamOggVorbis.load_from_file(opath) as AudioStreamOggVorbis
			if ogg != null:
				ogg.loop = true
				s = ogg
				_cache[id] = s
				return s
	var path := DIR + id + ".wav"
	if FileAccess.file_exists(path):
		s = AudioStreamWAV.load_from_file(path)
	if s == null and ResourceLoader.exists(path):
		s = load(path) as AudioStream
	if s == null:
		push_warning("[音效] 缺素材：%s" % path)
	elif id.begins_with("bgm"):
		# ★ BGM 只在载入时做一次"无缝循环"处理；之后全部复用缓存。
		s = _make_seamless_loop(s, id)
	_cache[id] = s
	return s


## 把一首 BGM 改造成**数学上无缝**的循环。
##
## 原理（交叉淡化循环）：
##   原曲长度 L 帧，取 D = 0.35s；新缓冲 = [混合头 D 帧] + [原曲 D..L-D)，
##   总长 L-D；混合头[i] = tail[L-D+i] * cos(t·π/2) + head[i] * sin(t·π/2)。
##   · 新缓冲第 0 帧 = 原曲 L-D 帧 → 它前面正好接原曲 L-D-1（新缓冲的最后一帧）；
##   · 新缓冲第 D-1 帧 = 原曲 D-1 帧 → 后面正好接原曲 D。
##   于是循环点两侧的样本是**原文件里相邻的样本**，不会有跳变/咔哒。
##
## 为什么必须在运行时做：原曲是 48kHz 立体声 72~80s（13~15MB），
## 离线改文件会改素材本身；而"接缝"是播放器行为，在播放器这层修最合适。
## 非 16-bit PCM（将来换 ogg 之类）就退化成普通整段循环，不报错。
func _make_seamless_loop(src: AudioStream, id: String) -> AudioStream:
	var w := src as AudioStreamWAV
	if w == null:
		return src
	if w.format != AudioStreamWAV.FORMAT_16_BITS:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(round(w.get_length() * float(w.mix_rate)))
		return w
	var ch: int = 2 if w.stereo else 1
	var bpf: int = 2 * ch
	# ★ 这句看似多余，其实救命：w.data 是**属性**，每次访问都可能把 13MB 的
	#   PackedByteArray 复制一份；循环里写 w.data.decode_s16() 就是 3 万次 13MB 拷贝
	#   （实测直接把进程卡死）。先取到局部变量（Packed 数组赋值是写时复制，不搬家）。
	var data: PackedByteArray = w.data
	var frames: int = data.size() / bpf
	var d: int = int(BGM_LOOP_FIX * float(w.mix_rate))
	if frames < d * 4 or d < 64:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = frames
		return w
	var head := PackedByteArray()
	head.resize(d * bpf)
	var tail_base: int = (frames - d) * bpf
	for i in range(d):
		var t: float = float(i) / float(d - 1)
		var w_in: float = sin(t * PI * 0.5)
		var w_out: float = cos(t * PI * 0.5)
		var to: int = tail_base + i * bpf
		var ho: int = i * bpf
		var dst: int = i * bpf
		for c in range(ch):
			var a: float = float(data.decode_s16(to + c * 2))
			var b: float = float(data.decode_s16(ho + c * 2))
			head.encode_s16(dst + c * 2,
				clampi(int(round(a * w_out + b * w_in)), -32768, 32767))
	var mid: PackedByteArray = data.slice(d * bpf, (frames - d) * bpf)
	var merged: PackedByteArray = head + mid
	var out := AudioStreamWAV.new()
	out.format = w.format
	out.mix_rate = w.mix_rate
	out.stereo = w.stereo
	out.data = merged
	out.loop_mode = AudioStreamWAV.LOOP_FORWARD
	out.loop_begin = 0
	out.loop_end = frames - d
	print("[音效] BGM %s 无缝循环：原 %.2fs → %.2fs（接缝交叉淡化 %.2fs）" % [
		id, float(frames) / float(w.mix_rate), float(frames - d) / float(w.mix_rate),
		BGM_LOOP_FIX])
	return out


func _spec_of(id: String) -> Dictionary:
	var spec: Dictionary = SPEC.get(id, DEFAULT_SPEC)
	return spec


## 三条闸：节流 → 并发 → 1 秒预算；任意一条不过就丢
func _allow(id: String, spec: Dictionary, now: float, dur: float) -> bool:
	var throttle := float(spec.get("throttle", 0.0))
	if throttle > 0.0 and now - float(_last_played.get(id, -9999.0)) < throttle:
		return false

	var cap := int(spec.get("concurrent", 0))
	var ends: Array = []
	if cap > 0:
		# 只保留"还没播完"的；遍历而不是只砍队首 —— 同一 id 的时长可能不同，队列不保证有序
		var raw: Array = _active.get(id, [])
		for e in raw:
			if float(e) > now:
				ends.append(e)
		if ends.size() >= cap:
			_active[id] = ends
			return false

	var per_sec := int(spec.get("per_sec", 0))
	var times: Array = []
	if per_sec > 0:
		times = _window.get(id, [])
		var cutoff := now - 1.0
		while not times.is_empty() and float(times[0]) < cutoff:
			times.pop_front()
		if times.size() >= per_sec:
			_window[id] = times
			return false

	# 通过：登记时刻
	if cap > 0:
		ends.append(now + maxf(dur, 0.02))
		_active[id] = ends
	if per_sec > 0:
		times.append(now)
		_window[id] = times
	_last_played[id] = now
	return true


func _play2d(id: String, volume_db: float, jitter: float, bus: String = "") -> void:
	var s := _stream(id)
	if s == null or _pool2d.is_empty():
		return
	var spec := _spec_of(id)
	var out_bus := bus
	if out_bus.is_empty():
		out_bus = String(spec.get("bus", BUS_SFX))
	var now := _now()
	if not _allow(id, spec, now, float(s.get_length())):
		return
	var p: AudioStreamPlayer = _pool2d[_next2d]
	_next2d = (_next2d + 1) % _pool2d.size()
	p.stream = s
	p.bus = out_bus
	p.volume_db = volume_db + _bus_makeup(out_bus)
	p.pitch_scale = 1.0 + randf_range(-jitter, jitter)
	p.play()


func _play3d(id: String, pos: Vector3, volume_db: float) -> void:
	var s := _stream(id)
	if s == null or _pool3d.is_empty():
		return
	var spec := _spec_of(id)
	var now := _now()
	if not _allow(id, spec, now, float(s.get_length())):
		return
	var p: AudioStreamPlayer3D = _pool3d[_next3d]
	_next3d = (_next3d + 1) % _pool3d.size()
	p.stream = s
	p.bus = String(spec.get("bus", BUS_SFX))
	p.global_position = pos
	p.volume_db = volume_db
	p.pitch_scale = 1.0 + randf_range(-0.05, 0.05)
	p.play()


## UI 总线的可听度补偿（其余总线不补）
func _bus_makeup(bus: String) -> float:
	return UI_MAKEUP_DB if bus == BUS_UI else 0.0


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


## 对外切歌入口（保留旧 API）。战斗曲走"进战斗"，其余走普通切歌。
func _set_bgm(id: String) -> void:
	if id == BGM_BATTLE:
		_enter_battle()
		return
	_in_battle = false
	_play_track(id, BGM_FADE_TO_CALM, 0.0)


## ★ BGM 切歌的唯一实现：等功率 crossfade，永远在"当前可闻播放器"之外的那一个上起新曲。
##
## 三条不变量（保证"不生硬"）：
##   · 两个播放器交替，**永远只有一路在淡入、一路在淡出**，不存在三路叠在一起；
##   · 换曲途中又来新请求 → **排队**，等这一轮淡化走完再切（硬切第三路必然出咔哒）；
##   · 包络是线性增益的 sin/cos（能量互补）+ smoothstep 时间曲线，不会中途掉到 -20dB。
func _play_track(id: String, fade: float, start_pos: float = 0.0) -> void:
	var s := _stream(id)
	if s == null or _bgm_a == null or _bgm_b == null:
		return
	# 同一首正在放（且没在换）：跳过，避免重复起播造成的"咔哒"
	if _bgm_id == id and _bgm_cur != null and _bgm_cur.playing and not _bgm_fading:
		return
	if _bgm_fading and not _bgm_stopping:
		if _bgm_id != id:
			_bgm_pending = id
			_bgm_pending_pos = start_pos
		return
	_bgm_stopping = false
	_bgm_pending = ""
	var in_p: AudioStreamPlayer = _bgm_b if _bgm_cur == _bgm_a else _bgm_a
	var out_p: AudioStreamPlayer = _bgm_cur
	if out_p == null or not out_p.playing:
		out_p = null
		fade = BGM_FADE_IN
	in_p.stream = s
	_apply_env(in_p, id, 0.0)
	if start_pos > 0.01:
		in_p.play(start_pos)
	else:
		in_p.play()
	_bgm_in = in_p
	_bgm_in_id = id
	_bgm_out = out_p
	_bgm_out_id = _bgm_id
	_bgm_out_env = _bgm_cur_env if out_p != null else 0.0
	_bgm_in_env = 0.0
	_bgm_id = id
	_bgm_fade_t = 0.0
	_bgm_fade_dur = maxf(fade, 0.1)
	_bgm_fading = true
	print("[音效] BGM → %s（%.1fs 等功率交叉淡化，入点 %.1fs）" % [id, _bgm_fade_dur, start_pos])


## 每帧推进 crossfade（等功率）。
func _drive_bgm_fade(delta: float) -> void:
	if not _bgm_fading:
		return
	_bgm_fade_t += delta
	var t: float = clampf(_bgm_fade_t / maxf(_bgm_fade_dur, 0.01), 0.0, 1.0)
	# smoothstep 让两头更缓、中段更匀（线性 t 在耳朵里是"前半快、后半拖"）
	var e: float = t * t * (3.0 - 2.0 * t)
	if _bgm_stopping:
		if _bgm_out != null:
			_apply_env(_bgm_out, _bgm_out_id, _bgm_out_env * cos(e * PI * 0.5))
		if t >= 1.0:
			_hard_stop_bgm()
		return
	var in_env: float = sin(e * PI * 0.5)
	if _bgm_in != null:
		_apply_env(_bgm_in, _bgm_in_id, in_env)
		_bgm_in_env = in_env
	if _bgm_out != null:
		_apply_env(_bgm_out, _bgm_out_id, _bgm_out_env * cos(e * PI * 0.5))
	if t >= 1.0:
		_bgm_fading = false
		if _bgm_out != null:
			_bgm_out.stop()
			_bgm_out.stream = null
			_bgm_out.volume_db = BGM_SILENT_DB
		if _bgm_in != null:
			_bgm_cur = _bgm_in
			_bgm_cur_env = 1.0
			_apply_env(_bgm_cur, _bgm_in_id, 1.0)
		_bgm_in = null
		_bgm_out = null
		_bgm_in_id = ""
		_bgm_out_id = ""
		_bgm_in_env = 0.0
		_bgm_out_env = 0.0
		# 从这一刻起才算"这首开始播"——因为轮播是按这个计时提前 LEAD 秒起淡化的
		if BGM_PEACE.has(_bgm_id):
			_peace_elapsed = 0.0
		# 排队的下一首接着淡入
		if not _bgm_pending.is_empty():
			var nid: String = _bgm_pending
			var npos: float = _bgm_pending_pos
			_bgm_pending = ""
			_bgm_pending_pos = 0.0
			var nfade: float = BGM_FADE_TO_BATTLE if nid == BGM_BATTLE else BGM_FADE_TO_CALM
			_bgm_id = ""
			_play_track(nid, nfade, npos)


## 把某一路播放器设到指定包络（0~1），并叠加该曲的响度补偿
func _apply_env(p: AudioStreamPlayer, id: String, env: float) -> void:
	if p == null:
		return
	p.volume_db = BGM_DB + _trim_db(id) + linear_to_db(maxf(env, 0.00001))


func _trim_db(id: String) -> float:
	return float(BGM_TRIM_DB.get(id, 0.0))


## 处理好的循环流长度（秒）；同一首只算一次
func _bgm_len(id: String) -> float:
	var s := _stream(id)
	return 0.0 if s == null else float(s.get_length())


## 淡出到静音（结算用）；不重建任何播放器，只把当前曲拉到 0 再停。
func _bgm_stop_fade(dur: float) -> void:
	_bgm_pending = ""
	if _bgm_cur == null or not _bgm_cur.playing:
		_hard_stop_bgm()
		return
	_bgm_stopping = true
	_bgm_fading = true
	_bgm_in = null
	_bgm_in_id = ""
	_bgm_out = _bgm_cur
	_bgm_out_id = _bgm_id
	_bgm_out_env = _bgm_cur_env
	_bgm_id = ""
	_bgm_fade_t = 0.0
	_bgm_fade_dur = maxf(dur, 0.1)


## 立刻停掉两路 BGM 并复位状态（淡出结束时调用 / 退出时兜底）
func _hard_stop_bgm() -> void:
	if _bgm_a != null:
		_bgm_a.stop()
		_bgm_a.stream = null
		_bgm_a.volume_db = BGM_SILENT_DB
	if _bgm_b != null:
		_bgm_b.stop()
		_bgm_b.stream = null
		_bgm_b.volume_db = BGM_SILENT_DB
	_bgm_cur = _bgm_a
	_bgm_cur_env = 0.0
	_bgm_in = null
	_bgm_out = null
	_bgm_in_id = ""
	_bgm_out_id = ""
	_bgm_in_env = 0.0
	_bgm_out_env = 0.0
	_bgm_pending = ""
	_bgm_pending_pos = 0.0
	_bgm_fading = false
	_bgm_stopping = false
	_bgm_fade_t = 0.0
	_bgm_fade_dur = 0.0
	_bgm_id = ""
	_peace_elapsed = 0.0


## Music 总线加一个软 Limiter，压住任何偶然峰值（降噪 / 不刺耳）。每会话只加一次。
func _add_music_limiter() -> void:
	if _music_limiter_added:
		return
	var idx := AudioServer.get_bus_index(BUS_MUSIC)
	if idx < 0:
		return
	var lim := AudioEffectLimiter.new()
	lim.threshold_db = -2.0
	lim.ceiling_db = -4.0
	AudioServer.add_bus_effect(idx, lim)
	# 再挂一条很轻的高频衰减：BGM 是程序合成的，镲片/泛音偏亮，
	# 高频收 1.5~7 dB 之后"吵"的那部分（刺耳的沙沙声）明显退后，旋律一点不受影响。
	var eq := AudioEffectEQ10.new()
	eq.set_band_gain_db(7, -1.5)   # 4 kHz
	eq.set_band_gain_db(8, -4.0)   # 8 kHz
	eq.set_band_gain_db(9, -7.0)   # 16 kHz
	AudioServer.add_bus_effect(idx, eq)
	_music_limiter_added = true


# ===========================================================================
# 信号处理
# ===========================================================================

## 选中：一次信号只播一声（点选/框选二选一）+ 至多一句类型应答
func _on_selection(units: Array) -> void:
	if units == null or units.is_empty():
		return
	# 同一帧内可能有多处 emit（选择系统 + HUD 补选），只认第一次
	var frame := Engine.get_process_frames()
	if frame == _last_sel_frame:
		return

	var player: RtsFaction = Game.player_faction
	if player == null:
		return
	var mine: Array = []
	for u in units:
		if u != null and is_instance_valid(u) and u.get("faction") == player:
			mine.append(u)
	if mine.is_empty():
		return
	_last_sel_frame = frame

	# ★ 12 个单位也只播 1 声：框选播"唰"（受 90ms 节流 + 每秒 3 次预算约束）
	var cue := "界面_点选" if mine.size() == 1 else "界面_框选"
	_play2d(cue, 0.0, 0.04, BUS_UI)
	_try_reply_voice(mine)


## 应答语音：按"第一个会说话的单位类型"选组，5s 节流，走 Voice 总线
func _try_reply_voice(mine: Array) -> void:
	var now := _now()
	if now - _last_voice < VOICE_THROTTLE:
		return
	var line := ""
	for u in mine:
		if u is RtsBuilding:
			continue
		var d: UnitDef = u.get("def") as UnitDef
		if d == null:
			continue
		var lines: PackedStringArray = VOICE_MAP.reply_lines(d.id)
		if lines.is_empty():
			continue
		line = lines[randi() % lines.size()]
		break
	if line.is_empty():
		return
	_last_voice = now
	_play2d(line, 0.0, 0.03, BUS_VOICE)


## 命中：按攻击方式选音色
func _on_hit(attacker: Node3D, target: Node3D, _damage: float, _crit: bool) -> void:
	var pos: Vector3 = target.global_position if target != null else Vector3.ZERO
	var is_ranged := false
	var is_tower := attacker is RtsBuilding
	if attacker != null and is_instance_valid(attacker):
		var d: UnitDef = attacker.get("def") as UnitDef
		if d != null:
			is_ranged = d.projectile != RtsConst.Projectile.NONE or d.attack_range > 3.0
	if is_tower:
		# 箭塔/建筑开火：弩机声，而不是普通命中
		_play3d("战斗_塔射", pos, -4.0)
	elif is_ranged:
		_play3d("战斗_命中", pos, -3.0)
	else:
		_play3d("战斗_命中", pos, 0.0)
	_mark_combat()


func _on_died(unit: Node3D) -> void:
	var pos: Vector3 = unit.global_position if unit != null else Vector3.ZERO
	_play3d("战斗_死亡", pos, 0.0)
	_mark_combat()
	if unit == null or not is_instance_valid(unit):
		return
	if unit is RtsBuilding:
		return
	if unit.get("faction") != Game.player_faction:
		return
	_try_death_voice(unit)


func _try_death_voice(unit: Node3D) -> void:
	var now := _now()
	if now - _last_death_voice < DEATH_VOICE_THROTTLE:
		return
	var d: UnitDef = unit.get("def") as UnitDef
	if d == null:
		return
	var line := String(VOICE_MAP.death_line(d.id))
	if line.is_empty():
		return
	_last_death_voice = now
	_play2d(line, 0.0, 0.02, BUS_VOICE)


func _on_impact(pos: Vector3, kind: int) -> void:
	if kind == RtsConst.Projectile.ARROW:
		_play3d("战斗_箭矢", pos, -7.0)
	else:
		_play3d("战斗_命中", pos, -9.0)


func _on_built(building: Node3D) -> void:
	var pos: Vector3 = building.global_position if building != null else Vector3.ZERO
	_play3d("建造_完成", pos, 0.0)
	if building is RtsBuilding and (building as RtsBuilding).faction == Game.player_faction:
		_play2d(VOICE_BUILT, -4.0, 0.0)


## 资源变化：只在自己（玩家）增减时响，且要跟上一帧比
func _on_resources(faction: RtsFaction) -> void:
	if faction == null or faction != Game.player_faction:
		return
	var gained := false
	if _last_gold >= 0 and faction.gold > _last_gold:
		gained = true
	if _last_wood >= 0 and faction.wood > _last_wood:
		gained = true
	if gained:
		_play2d("采集_资源", 0.0, 0.08)
	_last_gold = faction.gold
	_last_wood = faction.wood


## 下令：移动 80ms 节流；攻击/施法走战斗音；其余给一声很轻的点选
func _on_order(_units: Array, order: int, target_pos: Vector3, _target: Node3D) -> void:
	if order == RtsConst.Order.CAST:
		_play3d("法术_施放", target_pos, 0.0)
	elif order == RtsConst.Order.ATTACK or order == RtsConst.Order.ATTACK_MOVE:
		_play2d("战斗_攻击", 0.0, 0.10)
		_play2d(VOICE_ATTACK, -4.0, 0.02)          # 8s 节流在 SPEC 里
	elif order == RtsConst.Order.MOVE:
		_play2d("指令_移动", 0.0, 0.05, BUS_UI)
		_play2d(VOICE_FORWARD, -5.0, 0.02)
	elif order == RtsConst.Order.STOP or order == RtsConst.Order.HOLD:
		_play2d("界面_点选", 0.0, 0.06, BUS_UI)
		_play2d(VOICE_FALLBACK, -5.0, 0.02)
	else:
		_play2d("界面_点选", 0.0, 0.06, BUS_UI)


func _on_over(victory: bool) -> void:
	# 不再硬停：2s 淡出，结算音效盖在上面 —— "一场仗打完"应该是收尾，不是被掐断
	_bgm_stop_fade(BGM_FADE_OUT)
	_play2d("结算_胜利" if victory else "结算_失败", 0.0, 0.0)


## 顶部提示兼做"语音播报"：这 6 条口令以前生成了却没人播，现在按文本前缀接上。
## 用前缀匹配是因为全部失败提示都走 Game.toast()（5 处调用点），
## 在音频层一处收口，比在 单位/建筑/指令系统 里各加一行更不容易漏。
func _on_notify(text: String, _color: Color) -> void:
	if text.begins_with("资源不足"):
		_play2d(VOICE_NO_GOLD, 0.0, 0.0)
	elif text.begins_with("人口不足") or text.begins_with("人口已满"):
		_play2d(VOICE_NO_FOOD, 0.0, 0.0)
	elif text.begins_with("研究完成"):
		_play2d("升级_完成", -2.0, 0.0)


# ===========================================================================
# BGM 状态机：和平轮播 ↔ 小规模战斗
# ===========================================================================

## 交战中：切战 BGM，并把"停战计时"往后推。
##
## 只要有任何一次命中/死亡就算"打起来了"——小规模摩擦同样进战曲，这是任务要求的
## "小规模战斗自然过渡"；退回靠 COMBAT_HOLD 的静默时间，不会因为一支箭就来回抖。
func _mark_combat() -> void:
	_combat_until = _now() + COMBAT_HOLD
	if Game.phase != RtsConst.Phase.RUNNING:
		return
	if _in_battle or _bgm_id == BGM_BATTLE:
		return
	_enter_battle()


## 进战斗：记下和平曲的落点（打完从原地续上，不是重头再来），再淡入战曲
func _enter_battle() -> void:
	if _in_battle:
		return
	_in_battle = true
	# 自己兜住停战计时：_enter_battle 也可能被 set_bgm / QA 直接调，不能只靠 _mark_combat 先设好
	_combat_until = maxf(_combat_until, _now() + COMBAT_HOLD)
	_peace_saved_id = _bgm_id
	_peace_saved_elapsed = _peace_elapsed
	_peace_saved_pos = 0.0
	if _bgm_cur != null and _bgm_cur.playing and _bgm_id != BGM_BATTLE:
		var l := _bgm_len(_bgm_id)
		var p := float(_bgm_cur.get_playback_position())
		# 贴着循环点就别硬续了，不然刚回去就又要换曲
		if l > 1.0:
			p = minf(p, maxf(0.0, l - BGM_ROTATE_LEAD - 1.0))
		_peace_saved_pos = p
	print("[音效] 进入战斗（记下和平曲 %s @%.1fs）" % [_peace_saved_id, _peace_saved_pos])
	_play_track(BGM_BATTLE, BGM_FADE_TO_BATTLE, 0.0)


## 出战斗：淡回原来那首和平曲（同曲同位置）
func _leave_battle() -> void:
	if not _in_battle:
		return
	_in_battle = false
	var rid: String = _peace_saved_id
	if rid.is_empty() or rid == BGM_BATTLE or rid == BGM_SOFT:
		rid = BGM_PEACE[_peace_idx]
	_peace_idx = BGM_PEACE.find(rid)
	if _peace_idx < 0:
		_peace_idx = 0
	_peace_elapsed = _peace_saved_elapsed
	_bgm_pending = ""
	_bgm_id = ""
	print("[音效] 战斗结束，回到 %s @%.1fs" % [rid, _peace_saved_pos])
	_play_track(rid, BGM_FADE_TO_CALM, _peace_saved_pos)


## 和平期推进：序曲 → 两首和平曲轮流（提前 LEAD 秒起淡化，正好落在循环点上）
func _tick_bgm(delta: float) -> void:
	if Game.phase != RtsConst.Phase.RUNNING:
		return
	if _in_battle:
		if _now() >= _combat_until:
			_leave_battle()
		return
	if _bgm_fading or _bgm_id.is_empty() or _bgm_stopping:
		return
	_peace_elapsed += delta
	if _bgm_id == BGM_SOFT:
		if _peace_elapsed >= _bgm_len(BGM_SOFT) - BGM_ROTATE_LEAD:
			_peace_elapsed = 0.0
			_play_track(BGM_PEACE[_peace_idx], BGM_FADE_ROTATE, 0.0)
		return
	if not BGM_PEACE.has(_bgm_id):
		return
	var l := _bgm_len(_bgm_id)
	if l > BGM_ROTATE_LEAD * 2.0 and _peace_elapsed >= l - BGM_ROTATE_LEAD:
		_peace_idx = (_peace_idx + 1) % BGM_PEACE.size()
		_peace_elapsed = 0.0
		_play_track(BGM_PEACE[_peace_idx], BGM_FADE_ROTATE, 0.0)


## 停战 16s 自动回和平 + 低血看门狗
func _process(delta: float) -> void:
	_drive_bgm_fade(delta)
	_tick_bgm(delta)
	if _qa_bgm:
		_qa_tick_bgm(delta)

	# 低血警报：信号里拿不到血量，只能低频轮询（0.5s 一次，几十个单位，开销可忽略）
	_hp_check_t += delta
	if _hp_check_t >= 0.5:
		_hp_check_t = 0.0
		_check_low_hp()


## BGM 过渡自检：`--bgm-qa` 下按脚本推一遍状态机，把每次切换打进日志。
## 配合 `--headless --fixed-fps 60 --quit-after 3600` 跑，约 60s 出结果。
func _qa_tick_bgm(delta: float) -> void:
	if Game.phase != RtsConst.Phase.RUNNING:
		return
	_qa_t += delta
	if _qa_step == 0 and _qa_t >= 4.0:
		_qa_step = 1
		print("[音效 QA] ① 强制进战斗")
		_enter_battle()
	elif _qa_step == 1 and _qa_t >= 12.0:
		_qa_step = 2
		print("[音效 QA] ② 强制出战斗")
		_leave_battle()
	elif _qa_step == 2 and _qa_t >= 20.0:
		_qa_step = 3
		print("[音效 QA] ③ 轮播途中强制进战斗（验证排队）")
		_enter_battle()
	elif _qa_step == 3 and _qa_t >= 30.0:
		_qa_step = 4
		print("[音效 QA] ④ 强制出战斗")
		_leave_battle()
	elif _qa_step == 4 and _qa_t >= 34.0:
		_qa_step = 5
		print("[音效 QA] 完成：当前 %s，包络 %.2f" % [_bgm_id, _bgm_cur_env])


## 己方最惨单位（含已完工建筑）低于 30% 就响一声；5s 节流由 SPEC 负责
func _check_low_hp() -> void:
	var player := Game.player_faction
	if player == null:
		return
	var worst := 1.0
	var probe: Array = []
	probe.append_array(player.units)
	probe.append_array(player.buildings)
	for u in probe:
		if u == null or not is_instance_valid(u):
			continue
		var b := u as RtsBuilding
		if b != null and not b.is_constructed:
			continue                      # 半成品被拆到低血不算警报
		var d: UnitDef = u.get("def") as UnitDef
		if d == null or d.max_hp <= 0.0:
			continue
		var hp := float(u.get("hp"))
		if hp <= 0.0:
			continue
		worst = minf(worst, hp / d.max_hp)
	if worst <= LOW_HP_RATIO:
		_play2d("提示_低血", -2.0, 0.0)