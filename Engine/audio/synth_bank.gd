extends RefCounted
## 职责：程序化音效合成库（纯函数：给 key 返回样本；不碰节点、不读文件、不进场景树）
## 现状（2026-11-14）：只有一条 `ui_ding`（UI 更新时的"叮"），其余音效已全部删除。
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

## **唯一预设：UI 提示音"叮"**（2026-11-14）。
##
## 玩家口径：「删除所有合成音效，只在 UI 更新时出现提示音效叮（该音效在删除所有
## 音效后再重新合成）」。所以这个库里现在只有一条 key；以前的 12 条
## （点选/命中/死亡/建造/升级/金币…）连同 51 个 wav 一起删了。
##
## 音色设计（为什么是这三个音）：
##   · 根音 E6(1318.5) + 上方五度 B6(1975.5) → 明亮但不刺耳，是"叮"不是"当"；
##   · 底下垫一个低八度 E5(659.25) 只给 0.22 振幅 → 有厚度，小喇叭也听得见；
##   · 起音 2ms（干脆）、指数衰减 120ms（余韵 0.4s）→ 短、干净、不拖泥带水；
##   · 峰值 0.72 + 首尾淡入淡出 → 连续点选叠起来也不会削波。
##
## 字段：duration 总时长(s)；wave 波形；f0→f1 频率滑动；attack 起音(s)；
##       decay 指数衰减时间常数(s)；noise 噪声混合 0~1；harmonics 泛音 0~1.5；
##       peak 归一化目标峰值；seed 随机种子（噪声可复现）。
const PRESETS := {
	"ui_ding": {
		"duration": 0.46, "wave": "sine", "f0": 1318.51, "f1": 1300.0,
		"attack": 0.002, "decay": 0.120, "noise": 0.01, "harmonics": 0.55,
		"peak": 0.72, "seed": 4242,
		"layers": [
			{"start": 0.055, "length": 0.36, "f0": 1975.53, "f1": 1960.0,
				"amp": 0.42, "decay": 0.120},
			{"start": 0.0, "length": 0.46, "f0": 659.25, "f1": 659.25,
				"amp": 0.22, "decay": 0.180},
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
