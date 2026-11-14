extends Node
## 职责：程序化音效播放器 —— AudioStreamGenerator 运行时合成，不读 wav/ogg
## 属于：Engine/audio（游戏侧只播 key，不自己 new AudioStreamPlayer）
## 对外：play(key, volume_db, pitch_scale) / set_enabled(bool) / is_enabled() /
##       stats() / stop_all() / prewarm()
## 实现：常驻 POOL_SIZE 个 AudioStreamPlayer，每槽配一个 AudioStreamGenerator；
##       play() 时重新 play() 拿到新的 playback，把整段 PCM 推进缓冲，按剩余时长回收。
## 无头：Dummy 驱动下照样能填缓冲（无声）；拿不到 playback 就静默返回 false，不 push_error。

const SynthBank := preload("res://Engine/audio/synth_bank.gd")

const POOL_SIZE := 6
const BUS_SFX := "SFX"
const BUS_FALLBACK := "Master"
const MIN_PITCH := 0.25
const MAX_PITCH := 4.0
const BUFFER_SECONDS := 1.0

var _enabled := true
var _pool: Array[Dictionary] = []
var _serial := 0
var _played := 0
var _dropped := 0
var _stolen := 0
var _warned_no_tree := false


func _ready() -> void:
	set_process(true)
	prewarm()


## 播一个合成音效。未知 key / 未入树 / 被禁用 / 驱动不可用 → false（不报脚本错）。
func play(key: String, volume_db: float = 0.0, pitch_scale: float = 1.0) -> bool:
	if not _enabled:
		_dropped += 1
		return false
	if not is_inside_tree():
		if not _warned_no_tree:
			_warned_no_tree = true
			push_warning("[Synth] 还没进场景树，play() 被忽略（先 add_child 再播）")
		_dropped += 1
		return false
	if not SynthBank.has(key):
		push_warning("[Synth] 没有这个音效 key：%s" % key)
		_dropped += 1
		return false
	if _pool.is_empty():
		prewarm()
	if _pool.is_empty():
		_dropped += 1
		return false
	var samples := SynthBank.render(key)
	if samples.is_empty():
		_dropped += 1
		return false
	var frames := SynthBank.to_frames(samples)
	var slot := _take_slot()
	var audio_player: AudioStreamPlayer = slot["player"]
	var gen: AudioStreamGenerator = slot["gen"]
	audio_player.stream = gen
	audio_player.bus = _bus_name()
	audio_player.volume_db = volume_db
	audio_player.pitch_scale = clampf(pitch_scale, MIN_PITCH, MAX_PITCH)
	audio_player.play()
	slot["frames"] = frames
	slot["offset"] = 0
	slot["active"] = true
	slot["serial"] = _serial
	_serial += 1
	# 播完的回收时刻：采样数 / 采样率 / 变调 + 一点余量
	slot["time_left"] = float(frames.size()) / float(SynthBank.SAMPLE_RATE) / float(audio_player.pitch_scale) + 0.05
	if not _pump(slot):
		audio_player.stop()
		slot["active"] = false
		slot["frames"] = PackedVector2Array()
		slot["offset"] = 0
		_dropped += 1
		return false
	_played += 1
	return true


## 提前建池（可选：进游戏时调一次，避免第一次 play 时才 new 节点）。
func prewarm() -> void:
	if not _pool.is_empty():
		return
	for i in POOL_SIZE:
		var gen := AudioStreamGenerator.new()
		gen.mix_rate = float(SynthBank.SAMPLE_RATE)
		gen.buffer_length = BUFFER_SECONDS
		var audio_player := AudioStreamPlayer.new()
		audio_player.name = "Synth%d" % i
		audio_player.stream = gen
		audio_player.bus = _bus_name()
		add_child(audio_player)
		_pool.append({
			"player": audio_player,
			"gen": gen,
			"frames": PackedVector2Array(),
			"offset": 0,
			"time_left": 0.0,
			"serial": 0,
			"active": false,
		})


func set_enabled(on: bool) -> void:
	_enabled = on
	if not on:
		stop_all()


func is_enabled() -> bool:
	return _enabled


func stop_all() -> void:
	for slot in _pool:
		var audio_player: AudioStreamPlayer = slot["player"]
		if audio_player != null and audio_player.playing:
			audio_player.stop()
		slot["active"] = false
		slot["offset"] = 0
		slot["time_left"] = 0.0
		slot["frames"] = PackedVector2Array()


func stats() -> Dictionary:
	var active := 0
	for slot in _pool:
		if bool(slot["active"]):
			active += 1
	return {
		"enabled": _enabled,
		"pool_size": _pool.size(),
		"active": active,
		"played": _played,
		"dropped": _dropped,
		"stolen": _stolen,
		"headless": DisplayServer.get_name() == "headless",
		"driver": AudioServer.get_driver_name(),
		"sample_rate": SynthBank.SAMPLE_RATE,
		"presets": SynthBank.keys().size(),
		"bus": _bus_name(),
		"buffer_seconds": BUFFER_SECONDS,
	}


func _process(delta: float) -> void:
	if _pool.is_empty():
		return
	for slot in _pool:
		if not bool(slot["active"]):
			continue
		var audio_player: AudioStreamPlayer = slot["player"]
		if audio_player == null or not is_instance_valid(audio_player):
			slot["active"] = false
			continue
		if not audio_player.playing:
			slot["active"] = false
			continue
		var frames: PackedVector2Array = slot["frames"]
		if int(slot["offset"]) < frames.size():
			if not _pump(slot):
				audio_player.stop()
				slot["active"] = false
				continue
		slot["time_left"] = float(slot["time_left"]) - delta
		if float(slot["time_left"]) <= 0.0:
			audio_player.stop()
			slot["active"] = false
			slot["offset"] = 0
			slot["time_left"] = 0.0
			slot["frames"] = PackedVector2Array()


func _pump(slot: Dictionary) -> bool:
	var audio_player: AudioStreamPlayer = slot["player"]
	if audio_player == null or not is_instance_valid(audio_player) or not audio_player.playing:
		return false
	var pb := audio_player.get_stream_playback()
	if pb == null:
		return false
	var playback := pb as AudioStreamGeneratorPlayback
	if playback == null:
		return false
	var frames: PackedVector2Array = slot["frames"]
	var offset: int = int(slot["offset"])
	while offset < frames.size():
		var avail: int = playback.get_frames_available()
		if avail <= 0:
			break
		var n: int = mini(avail, frames.size() - offset)
		playback.push_buffer(frames.slice(offset, offset + n))
		offset += n
	slot["offset"] = offset
	return true


func _take_slot() -> Dictionary:
	for slot in _pool:
		if not bool(slot["active"]):
			return slot
	# 全忙：抢最早的那一个（声音短，最多吞掉一个尾音）
	var oldest: Dictionary = _pool[0]
	for slot in _pool:
		if int(slot["serial"]) < int(oldest["serial"]):
			oldest = slot
	var audio_player: AudioStreamPlayer = oldest["player"]
	if audio_player != null and audio_player.playing:
		audio_player.stop()
	oldest["active"] = false
	oldest["offset"] = 0
	oldest["time_left"] = 0.0
	_stolen += 1
	return oldest


func _bus_name() -> String:
	return BUS_SFX if AudioServer.get_bus_index(BUS_SFX) != -1 else BUS_FALLBACK
