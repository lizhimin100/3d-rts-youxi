extends Node
## 职责：音频（唯一出口）—— 总线、总线音量、静音、按 key 播放
## 属于：Engine/audio（自动加载 AudioSvc）
## 对外：ensure_buses() / play_sfx(key) / play_music(key) / stop_music() / set_bus_db() /
##       set_muted() / is_silent() / bus_names()
## 数据：Content/keys/assets.json 的 audio 段（key → res:// 路径）
## 禁改：
##   · 测试模式（App.silent / --headless）必须真的不发声，不能只把音量调小；
##   · 游戏代码不许自己 new AudioStreamPlayer 并直接拼路径 —— 走 play_sfx(key)。

const BUSES := ["Master", "Music", "SFX", "UI", "Voice"]
const BUS_DEFAULT_DB := {"Master": 0.0, "Music": -19.0, "SFX": -6.0, "UI": -16.0, "Voice": -8.0}

var _sfx_players: Array[AudioStreamPlayer] = []
var _music: AudioStreamPlayer = null
var _muted := false
var _play_count := 0


func _ready() -> void:
	ensure_buses()
	if App != null and App.silent:
		set_muted(true)


func ensure_buses() -> void:
	for name in BUSES:
		var idx := AudioServer.get_bus_index(name)
		if idx == -1:
			AudioServer.add_bus()
			idx = AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, name)
			AudioServer.set_bus_send(idx, "Master")
		AudioServer.set_bus_volume_db(idx, float(BUS_DEFAULT_DB.get(name, 0.0)))
		AudioServer.set_bus_mute(idx, name == "Master" and _muted)
	_ensure_player_pool()


func _ensure_player_pool() -> void:
	if _music == null:
		_music = AudioStreamPlayer.new()
		_music.name = "Music"
		_music.bus = "Music"
		add_child(_music)
	if _sfx_players.is_empty():
		for i in 8:
			var p := AudioStreamPlayer.new()
			p.name = "SFX%d" % i
			p.bus = "SFX"
			add_child(p)
			_sfx_players.append(p)


func bus_names() -> Array:
	var out: Array = []
	for i in AudioServer.bus_count:
		out.append(AudioServer.get_bus_name(i))
	return out


func set_bus_db(bus: String, db: float) -> bool:
	var idx := AudioServer.get_bus_index(bus)
	if idx == -1:
		push_error("[Audio] 没有总线：" + bus)
		return false
	AudioServer.set_bus_volume_db(idx, db)
	return true


## 全局静音（测试默认开）。真正把总线静音，不是把音量调小。
func set_muted(on: bool) -> void:
	_muted = on
	var idx := AudioServer.get_bus_index("Master")
	if idx != -1:
		AudioServer.set_bus_mute(idx, on)


func is_silent() -> bool:
	if _muted:
		return true
	return App != null and App.silent


func play_sfx(key: String, volume_db: float = 0.0) -> bool:
	if is_silent():
		return false
	var path := Keys.path("audio", key)
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("[Audio] 音效文件不存在：%s → %s" % [key, path])
		return false
	var stream: AudioStream = load(path)
	if stream == null:
		return false
	var player := _free_sfx_player()
	player.stream = stream
	player.volume_db = volume_db
	player.play()
	_play_count += 1
	return true


func play_music(key: String, volume_db: float = 0.0) -> bool:
	_ensure_player_pool()
	if is_silent():
		return false
	var path := Keys.path("audio", key)
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("[Audio] 音乐文件不存在：%s → %s" % [key, path])
		return false
	var stream: AudioStream = load(path)
	if stream == null:
		return false
	if _music.stream == stream and _music.playing:
		return true
	_music.stream = stream
	_music.volume_db = volume_db
	_music.play()
	return true


func stop_music() -> void:
	if _music != null:
		_music.stop()


func _free_sfx_player() -> AudioStreamPlayer:
	for p in _sfx_players:
		if not p.playing:
			return p
	return _sfx_players[0]


func stats() -> Dictionary:
	return {"buses": bus_names(), "muted": is_silent(), "played": _play_count}
