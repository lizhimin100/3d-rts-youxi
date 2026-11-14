extends RefCounted
## 职责：程序化音效合成库（纯函数：给 key 返回样本；不碰节点、不读文件、不进场景树）
## 属于：Engine/audio
## 对外：
##   keys() / has(key) / spec(key) / duration(key)
##   render(key) -> PackedFloat32Array          单声道 float32，[-1, 1]
##   to_pcm16(samples) -> PackedByteArray       16-bit 小端单声道 PCM
##   to_frames(samples) -> PackedVector2Array   给 AudioStreamGenerator 的立体声帧
##   describe() -> Dictionary                   key -> {duration, peak, ...}
## 约定：44100Hz；每个预设自带首尾淡入淡出 + 峰值归一化（无爆音、不削波）；
##       随机数用固定 seed，同一 key 每次合成逐样本一致（可回归）。
## 禁改：不要引入文件读取 / 节点 / 自动加载依赖；这个文件要能在纯 --script 下跑。

const SAMPLE_RATE := 44100
const DEFAULT_PEAK := 0.8
const FADE_IN := 0.003
const FADE_OUT := 0.012

## 12 个预设。基础层字段直接写在顶层；需要多音（和弦/连击/低频垫底）时用 layers 叠加。
## 字段：duration 总时长(s)；wave 波形；f0→f1 频率滑动；attack 起音(s)；
##       decay 指数衰减时间常数(s)；noise 噪声混合 0~1；harmonics 泛音 0~1.5；
##       peak 归一化目标峰值；seed 随机种子（噪声可复现）。
const PRESETS := {
	"ui_click": {
		"duration": 0.07, "wave": "sine", "f0": 1700.0, "f1": 820.0,
		"attack": 0.001, "decay": 0.020, "noise": 0.06, "harmonics": 0.20,
		"peak": 0.65, "seed": 1101,
	},
	"ui_open": {
		"duration": 0.22, "wave": "sine", "f0": 380.0, "f1": 880.0,
		"attack": 0.006, "decay": 0.110, "noise": 0.02, "harmonics": 0.35,
		"peak": 0.75, "seed": 1102,
	},
	"ui_error": {
		"duration": 0.30, "wave": "square", "f0": 190.0, "f1": 150.0,
		"attack": 0.002, "decay": 0.090, "noise": 0.05, "harmonics": 0.00,
		"peak": 0.70, "seed": 1103,
		"layers": [
			{"start": 0.15, "length": 0.13, "wave": "square", "f0": 165.0, "f1": 130.0,
				"attack": 0.002, "decay": 0.060, "amp": 0.80, "noise": 0.04},
		],
	},
	"notify": {
		"duration": 0.40, "wave": "sine", "f0": 880.0, "f1": 872.0,
		"attack": 0.003, "decay": 0.220, "noise": 0.01, "harmonics": 0.40,
		"peak": 0.80, "seed": 1104,
		"layers": [
			{"start": 0.09, "length": 0.30, "f0": 1318.5, "f1": 1300.0, "amp": 0.55, "decay": 0.160},
		],
	},
	"build_start": {
		"duration": 0.42, "wave": "saw", "f0": 140.0, "f1": 320.0,
		"attack": 0.010, "decay": 0.350, "noise": 0.18, "harmonics": 0.30,
		"peak": 0.80, "seed": 1105,
	},
	"build_done": {
		"duration": 0.60, "wave": "sine", "f0": 523.25, "f1": 526.0,
		"attack": 0.004, "decay": 0.180, "noise": 0.02, "harmonics": 0.50,
		"peak": 0.80, "seed": 1106,
		"layers": [
			{"start": 0.10, "length": 0.22, "f0": 659.25, "f1": 663.0, "amp": 0.80},
			{"start": 0.20, "length": 0.40, "f0": 783.99, "f1": 790.0, "amp": 0.90, "decay": 0.250},
			{"start": 0.00, "length": 0.18, "f0": 130.80, "f1": 98.00, "amp": 0.50, "decay": 0.120},
		],
	},
	"hit_flesh": {
		"duration": 0.18, "wave": "sine", "f0": 130.0, "f1": 55.0,
		"attack": 0.001, "decay": 0.055, "noise": 0.55, "harmonics": 0.00,
		"peak": 0.80, "seed": 1107,
	},
	"hit_metal": {
		"duration": 0.26, "wave": "square", "f0": 1450.0, "f1": 1180.0,
		"attack": 0.001, "decay": 0.075, "noise": 0.22, "harmonics": 0.60,
		"peak": 0.75, "seed": 1108,
	},
	"arrow_shot": {
		"duration": 0.16, "wave": "saw", "f0": 1100.0, "f1": 260.0,
		"attack": 0.002, "decay": 0.045, "noise": 0.45, "harmonics": 0.15,
		"peak": 0.70, "seed": 1109,
	},
	"death": {
		"duration": 0.75, "wave": "saw", "f0": 190.0, "f1": 45.0,
		"attack": 0.005, "decay": 0.500, "noise": 0.20, "harmonics": 0.25,
		"peak": 0.80, "seed": 1110,
		"layers": [
			{"start": 0.00, "length": 0.70, "wave": "sine", "f0": 70.0, "f1": 38.0,
				"amp": 0.60, "decay": 0.400},
		],
	},
	"level_up": {
		"duration": 0.78, "wave": "sine", "f0": 523.25, "f1": 530.0,
		"attack": 0.004, "decay": 0.200, "noise": 0.01, "harmonics": 0.45,
		"peak": 0.80, "seed": 1111,
		"layers": [
			{"start": 0.08, "length": 0.25, "f0": 659.25, "f1": 666.0, "amp": 0.75},
			{"start": 0.16, "length": 0.30, "f0": 783.99, "f1": 792.0, "amp": 0.80},
			{"start": 0.24, "length": 0.52, "f0": 1046.50, "f1": 1058.0, "amp": 0.90, "decay": 0.350},
			{"start": 0.30, "length": 0.45, "wave": "sine", "f0": 2093.0, "f1": 2637.0,
				"amp": 0.25, "decay": 0.250, "noise": 0.05},
		],
	},
	"coin": {
		"duration": 0.34, "wave": "sine", "f0": 987.77, "f1": 1000.0,
		"attack": 0.002, "decay": 0.090, "noise": 0.02, "harmonics": 0.30,
		"peak": 0.75, "seed": 1112,
		"layers": [
			{"start": 0.07, "length": 0.26, "f0": 1318.51, "f1": 1330.0,
				"amp": 0.90, "decay": 0.160},
		],
	},
}

static var _describe_cache: Dictionary = {}


## 全部预设 key（按定义顺序）。
static func keys() -> Array[String]:
	var out: Array[String] = []
	for key in PRESETS:
		out.append(key)
	return out


static func has(key: String) -> bool:
	return PRESETS.has(key)


## 预设参数副本（外部改它不会污染内置表）。
static func spec(key: String) -> Dictionary:
	var p: Dictionary = PRESETS.get(key, {})
	return p.duplicate(true)


static func duration(key: String) -> float:
	return float(PRESETS.get(key, {}).get("duration", 0.0))


## 合成一个 key（未知 key 返回空数组并告警，不崩）。
static func render(key: String) -> PackedFloat32Array:
	var spec: Dictionary = PRESETS.get(key, {})
	if spec.is_empty():
		push_warning("[Synth] 未知音效 key：%s" % key)
		return PackedFloat32Array()
	var n: int = maxi(1, int(round(float(spec["duration"]) * float(SAMPLE_RATE))))
	# 注意：Packed*Array 是值类型，在辅助函数里 append 不会回传 —— 这里用 Array 累加。
	var acc: Array[float] = []
	acc.resize(n)
	var seed_base: int = int(spec.get("seed", 1))
	var layers := _layers_of(spec)
	for i in layers.size():
		_add_layer(acc, layers[i], seed_base + i * 7919)
	return _finish(acc, float(spec.get("fade_in", FADE_IN)), float(spec.get("fade_out", FADE_OUT)), float(spec.get("peak", DEFAULT_PEAK)))


## 16-bit 小端、单声道 PCM。峰值限制在 [-1, 1]，负数用补码。
static func to_pcm16(samples: PackedFloat32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(samples.size() * 2)
	for i in samples.size():
		var v: int = int(round(clampf(samples[i], -1.0, 1.0) * 32767.0))
		if v < 0:
			v += 65536
		out[i * 2] = v & 0xFF
		out[i * 2 + 1] = (v >> 8) & 0xFF
	return out


## 转成 AudioStreamGenerator 要的立体声帧（单声道复制到左右）。
static func to_frames(samples: PackedFloat32Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(samples.size())
	for i in samples.size():
		var v := clampf(samples[i], -1.0, 1.0)
		out[i] = Vector2(v, v)
	return out


## key -> {duration, peak, wave, attack, decay, noise, samples, layers}
static func describe() -> Dictionary:
	if not _describe_cache.is_empty():
		return _describe_cache.duplicate(true)
	var out := {}
	for key in PRESETS:
		var spec: Dictionary = PRESETS[key]
		var samples := render(key)
		var peak := 0.0
		for v in samples:
			peak = maxf(peak, absf(v))
		var extras: Array = spec.get("layers", [])
		out[key] = {
			"duration": snappedf(float(spec["duration"]), 0.0001),
			"peak": snappedf(peak, 0.0001),
			"wave": String(spec.get("wave", "sine")),
			"attack": float(spec.get("attack", 0.005)),
			"decay": float(spec.get("decay", 0.1)),
			"noise": float(spec.get("noise", 0.0)),
			"samples": samples.size(),
			"layers": 1 + extras.size(),
		}
	_describe_cache = out
	return out.duplicate(true)


# ===========================================================================
# 内部：层 / 波形 / 包络 / 收尾
# ===========================================================================
static func _layers_of(spec: Dictionary) -> Array:
	var base := {}
	for k in ["wave", "f0", "f1", "attack", "decay", "noise", "harmonics", "amp", "curve"]:
		if spec.has(k):
			base[k] = spec[k]
	base["start"] = 0.0
	base["length"] = float(spec["duration"])
	var out: Array = [base]
	var extras: Array = spec.get("layers", [])
	for extra in extras:
		var layer: Dictionary = base.duplicate(true)
		for k in extra:
			layer[k] = extra[k]
		out.append(layer)
	return out


static func _add_layer(buf: Array[float], layer: Dictionary, seed: int) -> void:
	var sr := float(SAMPLE_RATE)
	var start: int = clampi(int(round(float(layer.get("start", 0.0)) * sr)), 0, buf.size())
	var length_s: float = maxf(0.005, float(layer.get("length", 0.1)))
	var total: int = mini(int(round(length_s * sr)), buf.size() - start)
	if total <= 0:
		return
	var wave := String(layer.get("wave", "sine"))
	var f0: float = maxf(20.0, float(layer.get("f0", 440.0)))
	var f1: float = maxf(20.0, float(layer.get("f1", f0)))
	var attack: float = maxf(0.0005, float(layer.get("attack", 0.005)))
	var decay: float = maxf(0.005, float(layer.get("decay", 0.1)))
	var noise_amt: float = clampf(float(layer.get("noise", 0.0)), 0.0, 1.0)
	var harm: float = clampf(float(layer.get("harmonics", 0.0)), 0.0, 1.5)
	var amp: float = float(layer.get("amp", 1.0))
	var exp_curve: bool = String(layer.get("curve", "exp")) == "exp"
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var phase := 0.0
	var noise_lp := 0.0
	var inv_sr := 1.0 / sr
	var layer_seconds: float = float(total) * inv_sr
	for i in total:
		var t: float = float(i) * inv_sr
		var u: float = float(i) / float(maxi(1, total - 1))
		var f: float = f0 * pow(f1 / f0, u) if exp_curve else lerpf(f0, f1, u)
		var s := 0.0
		if wave == "noise":
			s = rng.randf_range(-1.0, 1.0)
		else:
			phase += TAU * f * inv_sr
			s = _wave(wave, phase)
			if harm > 0.0:
				s += _wave(wave, phase * 2.0) * harm * 0.50
				s += _wave(wave, phase * 3.0) * harm * 0.25
		if noise_amt > 0.0:
			# 一阶低通的白噪声：比裸噪柔和，不会刺耳。
			noise_lp = lerpf(noise_lp, rng.randf_range(-1.0, 1.0), 0.45)
			s = s * (1.0 - noise_amt * 0.6) + noise_lp * noise_amt * 1.6
		buf[start + i] += s * amp * _env(t, attack, decay, layer_seconds)


static func _wave(kind: String, phase: float) -> float:
	var p := fposmod(phase, TAU) / TAU
	match kind:
		"square":
			return 1.0 if p < 0.5 else -1.0
		"saw":
			return 2.0 * p - 1.0
		"triangle":
			return 1.0 - 4.0 * absf(p - 0.5)
		_:
			return sin(phase)


static func _env(t: float, attack: float, decay: float, length: float) -> float:
	var a: float = clampf(t / attack, 0.0, 1.0)
	a = a * a * (3.0 - 2.0 * a)            # smoothstep 起音，避免起始台阶
	var d: float = exp(-t / decay)          # 指数衰减
	var tail: float = clampf((length - t) / 0.006, 0.0, 1.0)  # 末尾 6ms 收尾
	return a * d * tail


static func _finish(acc: Array[float], fade_in: float, fade_out: float, target_peak: float) -> PackedFloat32Array:
	var n := acc.size()
	var fi: int = clampi(int(round(fade_in * float(SAMPLE_RATE))), 1, maxi(1, n / 2))
	var fo: int = clampi(int(round(fade_out * float(SAMPLE_RATE))), 1, maxi(1, n / 2))
	for i in fi:
		acc[i] *= float(i) / float(fi)
	for i in fo:
		acc[n - 1 - i] *= float(i) / float(fo)
	var peak := 0.0
	for v in acc:
		peak = maxf(peak, absf(v))
	var gain := 0.0
	if peak > 0.000001:
		gain = minf(clampf(target_peak, 0.0, 1.0) / peak, 64.0)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = acc[i] * gain
	return out
