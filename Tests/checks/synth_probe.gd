extends SceneTree
## 职责：程序化音效模块的无窗口自检（synth_bank.gd + synth_player.gd）
## 属于：Tests/checks
## 用法：godot --headless --path . --script Tests/checks/synth_probe.gd
## 判据：全部通过打印 "SYNTH PASS n/N" 且退出码 0；否则打印 "SYNTH FAIL ..." 且退出码 1。
## 覆盖：12 个预设齐全 / 非空 / 时长区间 / 峰值 / NaN/Inf / 首尾静音（防爆音）/
##       describe() 自洽 / 16-bit PCM 转换 / AudioStreamGenerator 真填一次缓冲 /
##       SynthPlayer 的 play / set_enabled / 池抢占 / stop_all。

const SynthBank := preload("res://Engine/audio/synth_bank.gd")
const SynthPlayerScript := preload("res://Engine/audio/synth_player.gd")

const REQUIRED_KEYS := [
	"ui_click", "ui_open", "ui_error", "notify", "build_start", "build_done",
	"hit_flesh", "hit_metal", "arrow_shot", "death", "level_up", "coin",
]
const MIN_DURATION := 0.05
const MAX_DURATION := 0.80
const PEAK_LIMIT := 1.0
const MIN_PEAK := 0.10
const EDGE_ABS := 0.0001          # 首尾单样本必须≈0
const EDGE_WINDOW := 8            # 首尾 8 样本的淡入淡出窗口
const EDGE_WINDOW_ABS := 0.05

var _pass := 0
var _fail := 0
var _fail_lines: Array[String] = []
var _samples: Dictionary = {}
var _peaks: Dictionary = {}
var _generator_ok := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("========== 程序化音效自检（synth_probe） ==========")
	_cache_samples()
	_check_keys()
	_check_samples()
	_check_describe()
	_check_pcm16()
	_check_generator()
	await _check_player()
	_finish()


# ---------------------------------------------------------------------------
# 1. 预设清单
# ---------------------------------------------------------------------------
func _cache_samples() -> void:
	for key in SynthBank.keys():
		_samples[key] = SynthBank.render(key)


func _check_keys() -> void:
	var keys := SynthBank.keys()
	_ok("预设数量 >= 12", keys.size() >= 12, "实际 %d" % keys.size())
	var missing: Array[String] = []
	for key in REQUIRED_KEYS:
		if not SynthBank.has(key):
			missing.append(key)
	_ok("12 个约定 key 齐全", missing.is_empty(), "缺：" + ", ".join(missing))
	var seen := {}
	for key in keys:
		seen[key] = true
	_ok("key 无重复", seen.size() == keys.size(), "%d 个 key / %d 个唯一" % [keys.size(), seen.size()])


# ---------------------------------------------------------------------------
# 2. 样本质量：非空 / 时长 / 峰值 / NaN / 首尾
# ---------------------------------------------------------------------------
func _check_samples() -> void:
	print("-- 预设清单 --")
	for key in SynthBank.keys():
		var spec := SynthBank.spec(key)
		var samples: PackedFloat32Array = _samples[key]
		var want := float(spec.get("duration", 0.0))
		var dur := float(samples.size()) / float(SynthBank.SAMPLE_RATE)
		var peak := 0.0
		var bad := 0
		for v in samples:
			if is_nan(v) or is_inf(v):
				bad += 1
			else:
				peak = maxf(peak, absf(v))
		_peaks[key] = peak
		var head := absf(samples[0]) if samples.size() > 0 else 999.0
		var tail := absf(samples[samples.size() - 1]) if samples.size() > 0 else 999.0
		var win := 0.0
		var n: int = samples.size()
		for i in mini(EDGE_WINDOW, n):
			win = maxf(win, absf(samples[i]))
			win = maxf(win, absf(samples[n - 1 - i]))
		_ok("%s 非空" % key, samples.size() > 0, "0 样本")
		_ok("%s 时长 %.3fs ∈ [%.2f, %.2f]" % [key, want, MIN_DURATION, MAX_DURATION],
			want >= MIN_DURATION and want <= MAX_DURATION, "越界：%.4f" % want)
		_ok("%s 采样数与时长一致" % key, absf(dur - want) <= 1.0 / float(SynthBank.SAMPLE_RATE),
			"%.4fs vs %.4fs" % [dur, want])
		_ok("%s 无 NaN/Inf" % key, bad == 0, "%d 个坏样本" % bad)
		_ok("%s 峰值 %.3f <= %.1f" % [key, peak, PEAK_LIMIT], peak <= PEAK_LIMIT, "削波")
		_ok("%s 不是静音（峰值 >= %.2f）" % [key, MIN_PEAK], peak >= MIN_PEAK, "峰值 %.4f" % peak)
		_ok("%s 首尾单样本≈0（防爆音）" % key, head <= EDGE_ABS and tail <= EDGE_ABS,
			"head=%.6f tail=%.6f" % [head, tail])
		_ok("%s 首尾 %d 样本已淡入淡出" % [key, EDGE_WINDOW], win <= EDGE_WINDOW_ABS, "%.4f" % win)
		print("  %-11s %5.3fs  peak %.3f  %5d 样本  %d 层  head %.5f tail %.5f" % [
			key, want, peak, samples.size(), int(spec.get("layers", []).size()) + 1, head, tail])


# ---------------------------------------------------------------------------
# 3. describe() 与合成结果自洽
# ---------------------------------------------------------------------------
func _check_describe() -> void:
	var desc := SynthBank.describe()
	_ok("describe() 覆盖全部 key", desc.size() == SynthBank.keys().size(),
		"%d / %d" % [desc.size(), SynthBank.keys().size()])
	for key in SynthBank.keys():
		var d: Dictionary = desc.get(key, {})
		var fields_ok := d.has("duration") and d.has("peak")
		_ok("%s describe 含 duration/peak" % key, fields_ok, "缺字段")
		if not fields_ok:
			continue
		var want := float(SynthBank.spec(key).get("duration", -1.0))
		_ok("%s describe 时长与实际一致" % key, absf(float(d["duration"]) - want) <= 0.0002,
			"%.4f vs %.4f" % [float(d["duration"]), want])
		_ok("%s describe 峰值与实际一致" % key, absf(float(d["peak"]) - float(_peaks[key])) <= 0.001,
			"%.4f vs %.4f" % [float(d["peak"]), float(_peaks[key])])


# ---------------------------------------------------------------------------
# 4. 16-bit PCM 转换
# ---------------------------------------------------------------------------
func _check_pcm16() -> void:
	for key in SynthBank.keys():
		var samples: PackedFloat32Array = _samples[key]
		var bytes := SynthBank.to_pcm16(samples)
		_ok("%s PCM16 长度 = 样本×2" % key, bytes.size() == samples.size() * 2,
			"%d vs %d" % [bytes.size(), samples.size() * 2])
		var probes := [0, int(samples.size() / 2), samples.size() - 1]
		var max_err := 0.0
		for i in probes:
			var v: int = int(bytes[i * 2]) | (int(bytes[i * 2 + 1]) << 8)
			if v >= 32768:
				v -= 65536
			max_err = maxf(max_err, absf(float(v) / 32767.0 - samples[i]))
		_ok("%s PCM16 回读误差 < 1e-4" % key, max_err < 0.0001, "err=%.6f" % max_err)


# ---------------------------------------------------------------------------
# 5. AudioStreamGenerator 实际填充（无头 Dummy 驱动也应能填；无声不算失败）
# ---------------------------------------------------------------------------
func _check_generator() -> void:
	var audio_player := AudioStreamPlayer.new()
	audio_player.name = "SynthProbeGenerator"
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = float(SynthBank.SAMPLE_RATE)
	gen.buffer_length = 1.0
	audio_player.stream = gen
	audio_player.bus = "Master"
	audio_player.volume_db = -80.0
	root.add_child(audio_player)
	_ok("AudioStreamPlayer 已进场景树", audio_player.is_inside_tree(), "不在树里")
	audio_player.play()
	var pb := audio_player.get_stream_playback()
	var gp := pb as AudioStreamGeneratorPlayback
	if gp == null:
		print("[synth] 当前驱动没有 generator playback，跳过实际填充（不算失败）")
		_generator_ok = false
	else:
		var frames := SynthBank.to_frames(_samples["ui_click"])
		var avail := gp.get_frames_available()
		var pushed: int = mini(avail, frames.size())
		var push_ok := false
		if pushed > 0:
			push_ok = gp.push_buffer(frames.slice(0, pushed))
		_generator_ok = push_ok and pushed == frames.size()
		_ok("生成器实际填充缓冲（%d/%d 帧）" % [pushed, frames.size()], _generator_ok,
			"avail=%d push=%s" % [avail, str(push_ok)])
		print("[synth] generator: mix_rate=%d buffer=1.0s avail=%d pushed=%d" % [
			int(gen.mix_rate), avail, pushed])
	audio_player.stop()
	root.remove_child(audio_player)
	audio_player.free()


# ---------------------------------------------------------------------------
# 6. SynthPlayer 接口
# ---------------------------------------------------------------------------
func _check_player() -> void:
	var synth := SynthPlayerScript.new()
	synth.name = "SynthProbePlayer"
	root.add_child(synth)
	var st0: Dictionary = synth.stats()
	_ok("SynthPlayer 池 >= 4", int(st0.get("pool_size", 0)) >= 4, "pool=%s" % str(st0.get("pool_size")))
	_ok("stats() 字段齐全",
		st0.has("played") and st0.has("dropped") and st0.has("active") and st0.has("headless") and st0.has("driver"),
		"缺字段")
	var played: bool = synth.play("ui_click", -6.0)
	if _generator_ok:
		_ok("play(ui_click) 返回 true", played, "生成器可用却播放失败")
	else:
		print("[synth] 生成器不可用，play() 返回 %s（允许静默）" % str(played))
	var st1: Dictionary = synth.stats()
	_ok("播放计数 +1", (not played) or int(st1["played"]) == 1, "played=%d" % int(st1["played"]))
	_ok("未知 key 返回 false", synth.play("no_such_synth_key") == false, "居然返回 true")
	_ok("pitch_scale 变调不崩", synth.play("coin", -12.0, 1.5) == played or not _generator_ok, "")
	var keys_to_spam := ["ui_click", "ui_open", "ui_error", "notify", "build_start",
		"build_done", "coin", "level_up"]
	for key in keys_to_spam:
		synth.play(key, -18.0, 1.0)
	var st2: Dictionary = synth.stats()
	_ok("池压测后不超池", int(st2["active"]) <= int(st2["pool_size"]),
		"active=%d pool=%d" % [int(st2["active"]), int(st2["pool_size"])])
	if _generator_ok:
		_ok("池满会抢占", int(st2["stolen"]) >= 1, "stolen=%d" % int(st2["stolen"]))
	synth.set_enabled(false)
	_ok("set_enabled(false) 生效", synth.is_enabled() == false, "仍为 true")
	_ok("禁用后 play() 返回 false", synth.play("coin") == false, "禁用还能播")
	synth.set_enabled(true)
	_ok("set_enabled(true) 恢复", synth.is_enabled() == true, "仍为 false")
	# 播完回收：时长 0.75s，等 0.9s 后槽位必须自己空出来
	var recycled: bool = synth.play("death", -12.0)
	if recycled:
		await create_timer(0.9).timeout
		_ok("播完自动回收（active → 0）", int(synth.stats()["active"]) == 0,
			"active=%d" % int(synth.stats()["active"]))
	synth.stop_all()
	_ok("stop_all() 后 active == 0", int(synth.stats()["active"]) == 0,
		"active=%d" % int(synth.stats()["active"]))
	root.remove_child(synth)
	synth.free()
	# 给音频线程一帧时间释放 playback，退出时不留 ObjectDB 泄漏告警
	await process_frame
	await process_frame


# ---------------------------------------------------------------------------
func _ok(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		return
	_fail += 1
	var line := label
	if not detail.is_empty():
		line += " —— " + detail
	_fail_lines.append(line)
	print("  ✗ " + line)


func _finish() -> void:
	var total := _pass + _fail
	if _fail == 0:
		print("SYNTH PASS %d/%d" % [_pass, total])
		quit(0)
		return
	print("SYNTH FAIL %d/%d（失败 %d 条）" % [_pass, total, _fail])
	for line in _fail_lines:
		print("  - " + line)
	quit(1)
