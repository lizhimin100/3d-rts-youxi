class_name Sfx
extends Node
## **音频（BGM + 唯一 UI 提示音）**
##
## ★ 2026-11-14 玩家口径：「删除所有合成音效（不是下载的 BGM），只在 UI 更新时
##   出现提示音效叮（该音效在执行前面删除所有音效后再重新合成）」。
##   于是这个文件只剩两件事：
##     1. **BGM**（Content/audio/*.ogg，玩家自己的曲子）：和平轮播 / 战斗淡入淡出 /
##        结算淡出，逻辑一行没动（下面 BGM 段全部保留）；
##     2. **UI 提示音**：`ding()` → `AudioSvc.play_synth("ui_ding")`。
##        波形在 `Engine/audio/synth_bank.gd` 里**现合成**（不读任何 wav/ogg），
##        这是全局唯一音效。
##   历史：v1~v3 的战斗/建造/采集/语音/低血全套音效（51 个 wav + 17 条合成 key）
##   已按玩家要求**整批删除**，`Content/audio/` 现在只有 6 首 BGM。
##
## 用法：
##     Sfx.attach(get_tree())        # 主场景启动时调一次（幂等）
##     Sfx.ui()                      # UI 更新提示音（唯一音效，"叮"）
##     Sfx.set_bgm("bgm_战")          # 循环 BGM（战斗曲；平常曲内部自动轮播）

const DIR := "res://Content/audio/"
const BUS_LAYOUT := "res://Content/audio/default_bus_layout.tres"

## 唯一音效的 key（合成库里的名字，见 Engine/audio/synth_bank.gd）
const UI_DING := "ui_ding"
## 提示音最小间隔（秒）：UI 一帧内可能连发几个信号（选中 + 下令 + 播报），只要一声
const UI_DING_THROTTLE := 0.16
## 提示音电平（dB）：比中性的 0 轻一档，是"叮"不是"当"
const UI_DING_DB := -11.0

## 表现层随机流（音高抖动）。**不许**用全局 randf（见 表现随机.gd 文件头）
const Fx := preload("res://Views/world/art/表现随机.gd")

const BUS_MUSIC := "Music"
const BUS_SFX := "SFX"

## 音乐总线电平（dB）。旧值 -14 实测偏吵：BGM 是连续音，SFX 是瞬态，
## 同一峰值下 BGM 听起来明显更响。降到 -19 后 BGM 退到"背景"，不压指令/战斗反馈。
const MUSIC_BUS_DB := -19.0
const BGM_DB := -1.0           # 音乐在总线基础上再压 1 dB（总线见 default_bus_layout.tres）
const COMBAT_HOLD := 16.0      # 最后一次交战后 16s 自然退回和平 BGM

## BGM 素材（48kHz 立体声 16bit，全部 Content/audio/ 下）：
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

static var _inst: Sfx = null

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
## 提示音的上次播放时刻（秒）
var _last_ding: float = -9999.0

# --- BGM 状态 ---
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


## **UI 更新提示音**（全局唯一音效）。
##
## 玩家口径 2026-11-14：删掉所有合成音效，只在 UI 更新时"叮"一声。
## 走 `AudioSvc` 的合成播放器（AudioStreamGenerator），**不读任何音频文件**。
static func ui() -> void:
	if _inst == null or not is_instance_valid(_inst):
		return
	_inst.ding()


## 兼容旧调用名：音效已经全部删除，这里只是空实现，避免漏改的调用点报"方法不存在"。
static func play(_id: String, _volume_db: float = 0.0, _pitch_jitter: float = 0.06) -> void:
	pass


## 兼容旧调用名（3D 定位音）：同上，空实现。
static func play_at(_id: String, _pos: Vector3, _volume_db: float = 0.0) -> void:
	pass


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
	_cache.clear()


func _setup() -> void:
	_setup_buses()

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

	# --- 接线（不碰 单位.gd / 选择系统 / 指令系统）---
	#   * 提示音只认"UI 更新"这几条：选中 / 下令 / 播报 / 建造完成；
	#   * 战斗/死亡只用来驱动 BGM 进战（`_mark_combat`），不出声。
	Game.selection_changed.connect(_on_selection)
	Game.order_issued.connect(_on_order)
	Game.notify.connect(_on_notify)
	Game.building_completed.connect(_on_built)
	Game.combat_hit.connect(_on_hit)
	Game.unit_died.connect(_on_died)
	Game.game_over.connect(_on_over)
	print("[音效] 已就绪（BGM 目录：%s；唯一音效：%s 现合成）" % [DIR, UI_DING])
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
	# 电平以代码为准（Content/audio/default_bus_layout.tres 同步改成同一个值）：
	# 用户反馈 BGM"有点吵"，整体从 -14 dB 降到 -19 dB，再叠加 BGM_DB=-1。
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(BUS_MUSIC), MUSIC_BUS_DB)
	_add_music_limiter()
	# 只保留 Music / SFX 两条总线（SFX 是提示音走的那条；UI / Voice 已随音效一起删除，
	# 旧的 default_bus_layout.tres 里如果还留着它们，AudioServer 照旧加载、不用管）。
	_ensure_bus(BUS_SFX, -6.0)
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
##   现在 OGG 只有 5.6MB，而且**接缝已经在离线阶段接好**（Tools/Content/audio/压缩BGM到OGG.py
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


## 播放那一声"叮"。
##
## 节流 0.16s：一次点选可能同时触发 selection_changed + order_issued + notify，
## 不节流就是三连响。静音（测试模式 `App.silent`）时 AudioSvc 直接吞掉，不发声。
func ding() -> void:
	var now := _now()
	if now - _last_ding < UI_DING_THROTTLE:
		return
	_last_ding = now
	var svc := get_node_or_null("/root/AudioSvc")
	if svc == null:
		return
	# 音高微抖 1.5%：连续点选不会像电子门铃一样死板
	var pitch: float = 1.0 + Fx.rand_range(-0.015, 0.015)
	svc.call("play_synth", UI_DING, UI_DING_DB, pitch)


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

## 选中变化 → 叮（任何选中变化都是 UI 更新；同一帧多处 emit 只算一次）
func _on_selection(units: Array) -> void:
	if units == null or units.is_empty():
		return
	var frame := Engine.get_process_frames()
	if frame == _last_sel_frame:
		return
	_last_sel_frame = frame
	ding()


## 下令 → 叮（UI 更新：指令发出的那一下）
func _on_order(_units: Array, _order: int, _target_pos: Vector3, _target: Node3D) -> void:
	ding()


## 播报（顶部提示条）→ 叮。"资源不足/人口已满"这类失败提示也算 UI 更新。
func _on_notify(_text: String, _color: Color) -> void:
	ding()


## 建造完成 → 叮（自己的建筑才响，敌人的建造不该打扰玩家）
func _on_built(building: Node3D) -> void:
	if building is RtsBuilding and (building as RtsBuilding).faction == Game.player_faction:
		ding()


## 命中：**不出声**，只用来驱动 BGM 进战（小规模摩擦也要自然过渡到战曲）
func _on_hit(_attacker: Node3D, _target: Node3D, _damage: float, _crit: bool) -> void:
	_mark_combat()


## 死亡：同上，只驱动 BGM（一场仗打到有人死，肯定算"打起来了"）
func _on_died(_unit: Node3D) -> void:
	_mark_combat()


## 结算：BGM 2s 淡出（不再被掐断），不播提示音
func _on_over(_victory: bool) -> void:
	_bgm_stop_fade(BGM_FADE_OUT)


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


## 停战 16s 自动回和平
func _process(delta: float) -> void:
	_drive_bgm_fade(delta)
	_tick_bgm(delta)
	if _qa_bgm:
		_qa_tick_bgm(delta)



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
