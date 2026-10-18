#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""铁血战歌 · 程序化音频合成（纯标准库：wave / math / random / struct，零依赖）

生成内容：
  · 10 类交互/战斗音效：点选 / 框选 / 移动 / 攻击 / 命中 / 死亡 / 建造 / 采集 / 法术 / 胜负
  · 4 套单位应答语音（农民 / 步兵 / 弓箭手 / 法师，各 3 变体）+ 4 条死亡语音
  · 2 首循环 BGM：经营（40s / 96BPM）、会战（32s / 120BPM）

电平约定（写进文件，播放端不再补偿）：
  点选 ≈ -19 dBFS 峰值（任务书 -18~-22）
  移动 ≈ -15 dBFS 峰值（任务书 -14~-16）
  语音 ≈ -8  dBFS 峰值（任务书 -8）
  其余音效 -3 ~ -7 dBFS，BGM -4 dBFS

用法：
    python 工具/音频/合成音效.py            # 全部重生成
    python 工具/音频/合成音效.py --only sfx
    python 工具/音频/合成音效.py --only voice
    python 工具/音频/合成音效.py --only bgm
"""

import argparse
import math
import random
import struct
import sys
import wave
from pathlib import Path

TAU = math.tau
SR = 44100          # 音效 / 语音采样率
SR_BGM = 22050      # BGM 采样率（省一半体积，卡通听感足够）

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "音频"
VOICE_DIR = OUT / "语音"


# ===========================================================================
# 基础 DSP（一律 float 列表，最后写 16bit PCM）
# ===========================================================================

def db2amp(db: float) -> float:
    return 10.0 ** (db / 20.0)


def peak_db(buf) -> float:
    m = 0.0
    for x in buf:
        a = -x if x < 0.0 else x
        if a > m:
            m = a
    return 20.0 * math.log10(m) if m > 1e-9 else -120.0


def rms_db(buf) -> float:
    if not buf:
        return -120.0
    s = 0.0
    for x in buf:
        s += x * x
    r = math.sqrt(s / len(buf))
    return 20.0 * math.log10(r) if r > 1e-9 else -120.0


def normalize(buf, target_db: float):
    cur = peak_db(buf)
    g = db2amp(target_db - cur)
    return [x * g for x in buf]


def fade_io(buf, sr, fade_in=0.002, fade_out=0.008):
    n = len(buf)
    a = min(n, max(1, int(fade_in * sr)))
    b = min(n, max(1, int(fade_out * sr)))
    for i in range(a):
        buf[i] *= i / a
    for i in range(b):
        buf[n - 1 - i] *= i / b
    return buf


def noise_buf(n: int, seed: int):
    rng = random.Random(seed)
    return [rng.uniform(-1.0, 1.0) for _ in range(n)]


def _biquad(x, b0, b1, b2, a1, a2):
    """直接 I 型双二阶，系数已归一化。"""
    n = len(x)
    y = [0.0] * n
    x1 = x2 = y1 = y2 = 0.0
    for i in range(n):
        xi = x[i]
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = xi
        y2 = y1
        y1 = yi
        y[i] = yi
    return y


def lowpass(x, f, q=0.707, sr=SR):
    f = min(max(f, 10.0), sr * 0.45)
    w0 = TAU * f / sr
    c = math.cos(w0)
    alpha = math.sin(w0) / (2.0 * q)
    a0 = 1.0 + alpha
    return _biquad(x, (1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0,
                   (-2 * c) / a0, (1 - alpha) / a0)


def highpass(x, f, q=0.707, sr=SR):
    f = min(max(f, 10.0), sr * 0.45)
    w0 = TAU * f / sr
    c = math.cos(w0)
    alpha = math.sin(w0) / (2.0 * q)
    a0 = 1.0 + alpha
    return _biquad(x, (1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0,
                   (-2 * c) / a0, (1 - alpha) / a0)


def bandpass(x, f, q=1.0, sr=SR):
    f = min(max(f, 20.0), sr * 0.45)
    w0 = TAU * f / sr
    c = math.cos(w0)
    alpha = math.sin(w0) / (2.0 * q)
    a0 = 1.0 + alpha
    return _biquad(x, alpha / a0, 0.0, -alpha / a0, (-2 * c) / a0, (1 - alpha) / a0)


def soft_clip(x, drive=1.0):
    d = math.tanh(drive)
    return [math.tanh(v * drive) / d for v in x]


def env_ad(n, sr, attack=0.002, tau=0.05):
    out = [0.0] * n
    a = max(1, int(attack * sr))
    for i in range(n):
        if i < a:
            out[i] = i / a
        else:
            out[i] = math.exp(-((i - a) / sr) / tau)
    return out


def mix(*parts):
    n = max(len(p) for p in parts)
    out = [0.0] * n
    for p in parts:
        for i, v in enumerate(p):
            out[i] += v
    return out


def osc(freq_fn, dur, sr=SR, shape="sine", phase0=0.0):
    n = int(dur * sr)
    out = [0.0] * n
    ph = phase0
    for i in range(n):
        t = i / sr
        f = freq_fn(t)
        ph += f / sr
        if ph >= 1.0:
            ph -= math.floor(ph)
        if shape == "sine":
            out[i] = math.sin(TAU * ph)
        elif shape == "saw":
            out[i] = 2.0 * ph - 1.0
        elif shape == "square":
            out[i] = 1.0 if ph < 0.5 else -1.0
        else:
            out[i] = math.sin(TAU * ph)
    return out


def add_at(buf, start_s, samples, sr, gain=1.0):
    i0 = int(round(start_s * sr))
    n = len(buf)
    for k, v in enumerate(samples):
        j = i0 + k
        if 0 <= j < n:
            buf[j] += v * gain


def write_wav(path: Path, buf, sr: int, target_db=None, fade_in=0.002, fade_out=0.008, dither=True):
    buf = list(buf)
    if fade_in > 0 or fade_out > 0:
        fade_io(buf, sr, fade_in, fade_out)
    if target_db is not None:
        buf = normalize(buf, target_db)
    rng = random.Random(1234)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        frames = bytearray()
        for v in buf:
            if dither:
                v += rng.uniform(-1.0, 1.0) / 32768.0
            if v > 1.0:
                v = 1.0
            elif v < -1.0:
                v = -1.0
            frames += struct.pack("<h", int(round(v * 32767.0)))
        w.writeframes(bytes(frames))
    print("  %-28s %6.3fs  peak %6.1f dBFS  rms %6.1f dBFS  %6.1f KB" % (
        path.name, len(buf) / sr, peak_db(buf), rms_db(buf), path.stat().st_size / 1024.0))


# ===========================================================================
# 音效
# ===========================================================================

def sfx_click():
    """点选：60ms，两粒高频 + 一点木体，轻、短、不刺耳。"""
    n = int(0.060 * SR)
    rng = random.Random(11)
    out = [0.0] * n
    for i in range(n):
        t = i / SR
        e1 = math.exp(-t / 0.010)
        e2 = math.exp(-t / 0.005)
        body = math.sin(TAU * 640.0 * t) * math.exp(-t / 0.016)
        out[i] = 0.52 * math.sin(TAU * 1240.0 * t) * e1 \
            + 0.30 * math.sin(TAU * 1910.0 * t) * e2 \
            + 0.30 * body
    tr = [rng.uniform(-1, 1) * math.exp(-(i / SR) / 0.0035) * 0.35 for i in range(n)]
    out = mix(out, highpass(tr, 2200))
    out = highpass(out, 240)
    return write_wav(OUT / "界面_点选.wav", out, SR, -19.0, 0.0005, 0.012)


def sfx_box():
    """框选：120ms，先低后高的布面"唰"，比点选更有"扫过一片"的意思。"""
    n = int(0.120 * SR)
    nz = noise_buf(n, 21)
    lo = bandpass(nz, 780.0, 0.9)
    hi = bandpass(nz, 2300.0, 0.8)
    env = env_ad(n, SR, 0.006, 0.045)
    out = [0.0] * n
    for i in range(n):
        k = i / n
        w = k * k
        out[i] = ((1.0 - w) * lo[i] + w * hi[i]) * env[i] * 1.6
    tick = osc(lambda t: 1600.0, 0.02, SR, "sine")
    tick = [tick[i] * math.exp(-(i / SR) / 0.004) * 0.25 for i in range(len(tick))]
    out = mix(out, tick)
    return write_wav(OUT / "界面_框选.wav", out, SR, -18.0, 0.001, 0.02)


def sfx_move():
    """右键移动：100ms，低频"咚"+ 一声短木鱼，落点感强但不炸。"""
    n = int(0.100 * SR)
    body = osc(lambda t: 210.0 - 95.0 * (t / 0.10), 0.10, SR, "sine")
    benv = env_ad(n, SR, 0.002, 0.030)
    body = [body[i] * benv[i] * 0.9 for i in range(n)]
    tick = osc(lambda t: 880.0, 0.035, SR, "sine")
    tick = [tick[i] * math.exp(-(i / SR) / 0.006) * 0.35 for i in range(len(tick))]
    out = mix(body, tick)
    out = lowpass(out, 3500)
    return write_wav(OUT / "指令_移动.wav", out, SR, -15.0, 0.001, 0.02)


def sfx_attack():
    """攻击：170ms 挥砍风声（带一点低频推力）。"""
    n = int(0.170 * SR)
    nz = noise_buf(n, 31)
    a = bandpass(nz, 600.0, 0.7)
    b = bandpass(nz, 2400.0, 0.6)
    out = [0.0] * n
    for i in range(n):
        k = i / n
        peak = 1.0 - abs(k - 0.32) * 1.6
        peak = max(peak, 0.0)
        out[i] = (a[i] * (1.0 - k) + b[i] * k) * peak
    body = osc(lambda t: 130.0 - 40.0 * (t / 0.17), 0.17, SR, "sine")
    body = [body[i] * math.exp(-(i / SR) / 0.05) * 0.35 for i in range(len(body))]
    out = mix(out, body)
    out = soft_clip(out, 1.2)
    return write_wav(OUT / "战斗_攻击.wav", out, SR, -5.0, 0.002, 0.03)


def sfx_hit():
    """命中：150ms 金属泛音 + 5ms 噪声瞬态。"""
    n = int(0.150 * SR)
    out = [0.0] * n
    parts = [(523.0, 0.50, 0.030), (1174.0, 0.34, 0.024),
             (1861.0, 0.24, 0.018), (2790.0, 0.14, 0.012), (3710.0, 0.09, 0.009)]
    for f, amp, tau in parts:
        for i in range(n):
            t = i / SR
            out[i] += amp * math.sin(TAU * f * t) * math.exp(-t / tau)
    nz = noise_buf(n, 41)
    tr = highpass(nz, 3000.0)
    for i in range(n):
        out[i] += tr[i] * math.exp(-(i / SR) / 0.004) * 0.45
    out = highpass(out, 120)
    out = soft_clip(out, 1.3)
    return write_wav(OUT / "战斗_命中.wav", out, SR, -4.0, 0.0005, 0.03)


def sfx_death():
    """死亡：550ms 下坠的闷吼。"""
    n = int(0.550 * SR)
    src = osc(lambda t: 250.0 * math.exp(-t / 0.22) + 70.0, 0.55, SR, "saw")
    src = lowpass(src, 1400.0, 0.6)
    out = [0.0] * n
    growl = 0.0
    for i in range(n):
        t = i / SR
        growl = 0.65 + 0.35 * math.sin(TAU * 26.0 * t)
        e = math.exp(-t / 0.18) * min(1.0, t / 0.012)
        out[i] = src[i] * e * growl
    nz = noise_buf(n, 51)
    br = bandpass(nz, 900.0, 0.8)
    for i in range(n):
        out[i] += br[i] * math.exp(-(i / SR) / 0.10) * 0.12
    return write_wav(OUT / "战斗_死亡.wav", out, SR, -5.0, 0.002, 0.06)


def sfx_build():
    """建造：220ms 一记锤子（木体 + 金属余韵）。"""
    n = int(0.220 * SR)
    out = [0.0] * n
    body = osc(lambda t: 240.0 * math.exp(-t / 0.03) + 120.0, 0.10, SR, "sine")
    for i in range(min(n, len(body))):
        out[i] += body[i] * math.exp(-(i / SR) / 0.030) * 0.9
    for f, amp, tau in [(1460.0, 0.28, 0.045), (2630.0, 0.16, 0.028)]:
        for i in range(n):
            t = i / SR
            out[i] += amp * math.sin(TAU * f * t) * math.exp(-t / tau)
    nz = noise_buf(n, 61)
    tr = highpass(nz, 1800.0)
    for i in range(n):
        out[i] += tr[i] * math.exp(-(i / SR) / 0.003) * 0.5
    return write_wav(OUT / "建造_完成.wav", out, SR, -5.0, 0.0005, 0.03)


def sfx_gather():
    """采集：140ms 两粒金币叮（第二粒稍晚、稍轻）。"""
    n = int(0.140 * SR)
    out = [0.0] * n
    for start, amp in [(0.0, 1.0), (0.052, 0.6)]:
        i0 = int(start * SR)
        for i in range(i0, n):
            t = (i - i0) / SR
            e = math.exp(-t / 0.020)
            v = 0.55 * math.sin(TAU * 2360.0 * t) + 0.30 * math.sin(TAU * 3540.0 * t)
            out[i] += v * e * amp
    out = highpass(out, 900)
    return write_wav(OUT / "采集_资源.wav", out, SR, -7.0, 0.001, 0.02)


def sfx_spell():
    """法术：700ms 火球（下坠正弦 + 风噪 + 短回声尾）。"""
    n = int(0.700 * SR)
    out = [0.0] * n
    tone = osc(lambda t: 430.0 * math.exp(-t / 0.16) + 68.0, 0.70, SR, "sine")
    for i in range(n):
        t = i / SR
        out[i] += tone[i] * math.exp(-t / 0.24) * min(1.0, t / 0.01) * 0.8
    nz = noise_buf(n, 71)
    who = bandpass(nz, 900.0, 0.6)
    for i in range(n):
        t = i / SR
        out[i] += who[i] * math.exp(-t / 0.13) * 0.35
    # 简易回声：60ms 后叠一层 0.3
    d = int(0.060 * SR)
    for i in range(d, n):
        out[i] += out[i - d] * 0.28
    out = lowpass(out, 5000)
    return write_wav(OUT / "法术_施放.wav", out, SR, -4.0, 0.002, 0.05)


def _fanfare(notes, dur, sr, wave_shape="sine"):
    n = int(dur * sr)
    out = [0.0] * n
    for start, freq, length, amp in notes:
        m = int(length * sr)
        seg = osc(lambda t, f=freq: f, length, sr, wave_shape)
        for i in range(m):
            t = i / sr
            e = min(1.0, t / 0.015) * math.exp(-t / (length * 0.55))
            j = int(start * sr) + i
            if 0 <= j < n:
                out[j] += seg[i] * e * amp
    return out


def sfx_win():
    """胜利：1.6s 大调号角。"""
    notes = [
        (0.00, 523.25, 0.55, 0.55), (0.00, 261.63, 0.90, 0.30),
        (0.18, 659.25, 0.55, 0.50), (0.36, 783.99, 0.60, 0.50),
        (0.54, 1046.50, 0.95, 0.55), (0.54, 523.25, 0.95, 0.28),
    ]
    out = _fanfare(notes, 1.6, SR, "sine")
    raw = highpass(_fanfare(notes, 1.6, SR, "saw"), 1800.0)
    out = mix(out, [v * 0.18 for v in raw])
    out = soft_clip(out, 1.1)
    return write_wav(OUT / "结算_胜利.wav", out, SR, -4.0, 0.005, 0.10)


def sfx_lose():
    """失败：1.6s 下行小调。"""
    notes = [
        (0.00, 440.00, 0.55, 0.50), (0.00, 220.00, 1.20, 0.26),
        (0.30, 349.23, 0.55, 0.48), (0.60, 293.66, 0.60, 0.48),
        (0.88, 220.00, 1.00, 0.55),
    ]
    out = _fanfare(notes, 1.6, SR, "sine")
    raw = lowpass(_fanfare(notes, 1.6, SR, "saw"), 900.0)
    out = mix(out, [v * 0.30 for v in raw])
    out = soft_clip(out, 1.1)
    return write_wav(OUT / "结算_失败.wav", out, SR, -4.0, 0.005, 0.10)


# ===========================================================================
# 单位语音（共振峰合成：声门脉冲 + 三段共振峰 + 气声/嘶哑）
# ===========================================================================

VOICE_SETS = {
    "农民":   {"f0": 190.0, "formants": [(720.0, 7.0, 1.00), (1200.0, 9.0, 0.62), (2600.0, 10.0, 0.30)], "breath": 0.05, "growl": 0.05},
    "步兵":   {"f0": 112.0, "formants": [(520.0, 7.0, 1.00), (950.0, 9.0, 0.58), (2400.0, 10.0, 0.24)], "breath": 0.03, "growl": 0.16},
    "弓箭手": {"f0": 165.0, "formants": [(640.0, 7.0, 1.00), (1150.0, 9.0, 0.60), (2550.0, 10.0, 0.28)], "breath": 0.05, "growl": 0.08},
    "法师":   {"f0": 205.0, "formants": [(420.0, 8.0, 1.00), (1850.0, 10.0, 0.52), (2700.0, 12.0, 0.30)], "breath": 0.14, "growl": 0.03},
}


def syllable_env(n, spans, sr=SR):
    env = [0.0] * n
    for (t0, t1, amp) in spans:
        i0 = max(0, int(t0 * sr))
        i1 = min(n, int(t1 * sr))
        L = i1 - i0
        if L <= 4:
            continue
        a = max(2, int(0.012 * sr))
        r = max(2, int(0.045 * sr))
        for i in range(i0, i1):
            k = i - i0
            v = 1.0
            if k < a:
                v = k / a
            if L - k < r:
                v = min(v, (L - k) / r)
            if v > env[i]:
                env[i] = v * amp
    return env


def formant_voice(dur, f0_curve, formants, spans, breath=0.04, growl=0.0, seed=1, sr=SR):
    n = int(dur * sr)
    rng = random.Random(seed)
    phase = 0.0
    glot = [0.0] * n
    for i in range(n):
        t = i / sr
        f = f0_curve(t) * (1.0 + 0.004 * rng.uniform(-1.0, 1.0))
        phase += f / sr
        glot[i] = 2.0 * (phase - math.floor(phase)) - 1.0
    src = [0.0] * n
    prev = 0.0
    for i in range(n):
        src[i] = (glot[i] - prev) * 0.5
        prev = glot[i]
    src = lowpass(src, 3600.0, 0.8, sr)
    voiced = [0.0] * n
    for (ff, q, g) in formants:
        b = bandpass(src, ff, q, sr)
        for i in range(n):
            voiced[i] += g * b[i]
    for i in range(n):
        voiced[i] += 0.16 * src[i]
    if breath > 0.0:
        nz = highpass(lowpass(noise_buf(n, seed + 7), 6000.0, 0.7, sr), 1500.0, 0.7, sr)
        for i in range(n):
            voiced[i] += breath * nz[i]
    if growl > 0.0:
        for i in range(n):
            t = i / sr
            voiced[i] *= 1.0 - 0.45 * growl + 0.45 * growl * math.sin(TAU * 27.0 * t)
    env = syllable_env(n, spans, sr)
    out = [voiced[i] * env[i] for i in range(n)]
    return soft_clip(out, 1.4)


def build_voices():
    print("[语音] 4 套 × 3 变体 + 死亡")
    variants = [
        # (变体号, 时长, f0 曲线类型, 音节)
        (1, 0.45, "rise", [(0.02, 0.40, 1.0)]),
        (2, 0.72, "two", [(0.02, 0.26, 1.0), (0.36, 0.66, 0.88)]),
        (3, 0.58, "fall", [(0.02, 0.50, 1.0)]),
    ]
    for name, cfg in VOICE_SETS.items():
        base = cfg["f0"]
        for idx, dur, shape, spans in variants:
            if shape == "rise":
                f0 = lambda t, b=base, d=dur: b * (1.0 + 0.10 * math.sin(math.pi * min(t / d, 1.0)))
            elif shape == "two":
                f0 = lambda t, b=base: b * (1.14 if t < 0.30 else 0.96)
            else:
                f0 = lambda t, b=base, d=dur: b * (1.20 - 0.30 * min(t / d, 1.0))
            buf = formant_voice(dur, f0, cfg["formants"], spans,
                                breath=cfg["breath"], growl=cfg["growl"], seed=100 + idx * 17)
            write_wav(VOICE_DIR / ("%s_应答%d.wav" % (name, idx)), buf, SR, -8.0, 0.006, 0.03)
        # 死亡语音：更长、下坠、更嘶哑
        ddur = 0.95
        df0 = lambda t, b=base: b * (1.02 * math.exp(-t / 0.32) + 0.34)
        dbuf = formant_voice(ddur, df0, cfg["formants"], [(0.02, 0.88, 1.0)],
                             breath=cfg["breath"] * 1.6, growl=0.55, seed=900)
        write_wav(VOICE_DIR / ("%s_死亡.wav" % name), dbuf, SR, -8.0, 0.008, 0.06)


# ===========================================================================
# BGM（循环：整小节数 + 尾巴回卷，接缝无断点）
# ===========================================================================

def midi_hz(m: float) -> float:
    return 440.0 * (2.0 ** ((m - 69.0) / 12.0))


def tone(freq, dur, sr, harm=((1.0, 1.0),), decay=0.4, attack=0.005, detune=0.0):
    n = int(dur * sr)
    out = [0.0] * n
    a = max(1, int(attack * sr))
    for i in range(n):
        t = i / sr
        e = (i / a) if i < a else 1.0
        if decay > 0:
            e *= math.exp(-t / decay)
        v = 0.0
        for h, amp in harm:
            v += amp * math.sin(TAU * freq * h * t + detune)
        out[i] = v * e
    return out


def pad_segment(dur, freqs, sr, attack=0.7, release=1.1, cutoff=1500.0, gain=0.22):
    n = int(dur * sr)
    out = [0.0] * n
    for f in freqs:
        for cents in (-6.0, 0.0, 6.0):
            ff = f * (2.0 ** (cents / 1200.0))
            step = ff / sr
            ph = (int(f) % 97) / 97.0
            for i in range(n):
                ph += step
                if ph >= 1.0:
                    ph -= 1.0
                out[i] += (2.0 * ph - 1.0)
    a = max(1, int(attack * sr))
    r = max(1, int(release * sr))
    for i in range(n):
        e = 1.0
        if i < a:
            e = i / a
        if n - i < r:
            e = min(e, (n - i) / r)
        out[i] *= e * gain
    return lowpass(out, cutoff, 0.8, sr)


def render_bgm(bpm, chords, bars, sr, make_events):
    spb = 60.0 / bpm
    bar_s = spb * 4.0
    total = bar_s * bars
    n = int(round(total * sr))
    tail = int(round(bar_s * sr))
    buf = [0.0] * (n + tail)
    make_events(buf, sr, spb, bar_s, chords)
    buf = highpass(buf, 22.0, 0.6, sr)
    out = [0.0] * n
    for i in range(n + tail):
        out[i % n] += buf[i]
    return out


def bgm_calm():
    """经营：96BPM / 16 小节 = 40s，Am-F-C-G，拨弦 + 铺底 + 轻打击。"""
    bpm = 96.0
    bars = 16
    sr = SR_BGM
    prog = ["Am", "F", "C", "G"]
    chords = {
        "Am": [57, 60, 64], "F": [53, 57, 60], "C": [48, 52, 55], "G": [55, 59, 62],
    }
    seq = []
    for i in range(bars):
        seq.append(prog[(i // 4) % 4])

    def events(buf, sr, spb, bar_s, _chords):
        rng = random.Random(7)
        for b in range(bars):
            name = seq[b]
            chord = chords[name]
            t0 = b * bar_s
            # 铺底：每 4 小节换一次和弦，持续到下一段
            if b % 4 == 0:
                seg = pad_segment(bar_s * 4.0 + 0.6, [midi_hz(m) for m in chord], sr,
                                  attack=0.9, release=1.2, cutoff=1250.0, gain=0.12)
                add_at(buf, t0, seg, sr)
            # 拨弦 8 分音符
            pattern = [0, 1, 2, 1, 0, 2, 1, 2]
            for k, pi in enumerate(pattern):
                m = chord[pi] + (12 if (k % 4 == 2) else 0)
                dur = 0.9
                note = tone(midi_hz(m), dur, sr,
                            harm=((1.0, 1.0), (2.0, 0.34), (3.0, 0.12)),
                            decay=0.30, attack=0.004,
                            detune=rng.uniform(-0.001, 0.001))
                add_at(buf, t0 + k * spb * 0.5, note, sr, 0.10)
            # 低音：每小节 1、3 拍
            root = chord[0] - 12
            for bt in (0.0, 2.0):
                note = tone(midi_hz(root), 1.3, sr,
                            harm=((1.0, 1.0), (2.0, 0.22)), decay=0.55, attack=0.01)
                add_at(buf, t0 + bt * spb, note, sr, 0.20)
            # 沙锤：反拍
            for bt in (0.5, 1.5, 2.5, 3.5):
                nz = noise_buf(int(0.05 * sr), 300 + b * 7 + int(bt * 2))
                sh = highpass(nz, 5200.0, 0.7, sr)
                env = env_ad(len(sh), sr, 0.002, 0.012)
                sh = [sh[i] * env[i] for i in range(len(sh))]
                add_at(buf, t0 + bt * spb, sh, sr, 0.05)
        # 稀疏旋律（后两段）
        melody = [
            (4, 0.0, 69, 2.0), (4, 2.0, 72, 2.0),
            (5, 0.0, 76, 2.0), (5, 2.0, 74, 1.0), (5, 3.0, 72, 1.0),
            (6, 0.0, 69, 3.0),
            (7, 0.0, 67, 2.0), (7, 2.0, 69, 2.0),
            (12, 0.0, 76, 2.0), (12, 2.0, 79, 2.0),
            (13, 0.0, 79, 1.0), (13, 1.0, 76, 1.0), (13, 2.0, 74, 2.0),
            (14, 0.0, 72, 2.0), (14, 2.0, 69, 2.0),
            (15, 0.0, 67, 3.0),
        ]
        for (bar, beat, m, dur_beats) in melody:
            note = tone(midi_hz(m), dur_beats * spb * 0.95, sr,
                        harm=((1.0, 1.0), (2.0, 0.25), (4.0, 0.08)),
                        decay=dur_beats * spb * 0.55, attack=0.03)
            add_at(buf, bar * bar_s + beat * spb, note, sr, 0.085)

    buf = render_bgm(bpm, seq, bars, sr, events)
    return write_wav(OUT / "bgm_经营.wav", buf, sr, -4.5, 0.0, 0.0, dither=True)


def bgm_battle():
    """会战：120BPM / 16 小节 = 32s，Dm-Bb-F-C，鼓 + 八分贝斯 + 弦乐断奏。"""
    bpm = 120.0
    bars = 16
    sr = SR_BGM
    prog = ["Dm", "Bb", "F", "C"]
    chords = {
        "Dm": [62, 65, 69], "Bb": [58, 62, 65], "F": [57, 60, 65], "C": [55, 60, 64],
    }
    seq = [prog[(i // 4) % 4] for i in range(bars)]

    def events(buf, sr, spb, bar_s, _chords):
        rng = random.Random(17)
        for b in range(bars):
            name = seq[b]
            chord = chords[name]
            t0 = b * bar_s
            intense = b >= 8
            # 铺底
            if b % 4 == 0:
                seg = pad_segment(bar_s * 4.0 + 0.4, [midi_hz(m) for m in chord], sr,
                                  attack=0.25, release=0.5, cutoff=1800.0,
                                  gain=0.09 if not intense else 0.12)
                add_at(buf, t0, seg, sr)
            # 鼓：底鼓 1/3 拍，军鼓 2/4 拍
            for bt in (0.0, 2.0):
                kick = osc(lambda t: 150.0 * math.exp(-t / 0.02) + 46.0, 0.18, sr, "sine")
                kick = [kick[i] * math.exp(-(i / sr) / 0.085) for i in range(len(kick))]
                add_at(buf, t0 + bt * spb, kick, sr, 0.5)
            if b >= 4:
                for bt in (1.0, 3.0):
                    nz = noise_buf(int(0.14 * sr), 500 + b * 13 + int(bt))
                    sn = bandpass(nz, 1900.0, 0.8, sr)
                    body = tone(190.0, 0.10, sr, decay=0.05, attack=0.001)
                    sn = [sn[i] * math.exp(-(i / sr) / 0.045) for i in range(len(sn))]
                    add_at(buf, t0 + bt * spb, sn, sr, 0.24)
                    add_at(buf, t0 + bt * spb, body, sr, 0.10)
            # 踩镲：8 分
            for k in range(8):
                nz = noise_buf(int(0.04 * sr), 900 + b * 31 + k)
                hh = highpass(nz, 7000.0, 0.7, sr)
                hh = [hh[i] * math.exp(-(i / sr) / 0.010) for i in range(len(hh))]
                add_at(buf, t0 + k * spb * 0.5, hh, sr, 0.055 if intense else 0.04)
            # 贝斯：8 分，根音 / 根音 / 五度 / 根音
            root = chord[0] - 12
            pattern = [0, 0, 7, 0, 0, 0, 10, 0]
            for k, interval in enumerate(pattern):
                m = root + interval
                note = tone(midi_hz(m), 0.26, sr,
                            harm=((1.0, 1.0), (2.0, 0.30), (3.0, 0.10)),
                            decay=0.10, attack=0.004)
                note = lowpass(note, 650.0, 0.8, sr)
                add_at(buf, t0 + k * spb * 0.5, note, sr, 0.24)
            # 弦乐断奏：反拍
            for bt in (0.5, 1.5, 2.5, 3.5):
                for m in chord:
                    note = tone(midi_hz(m), 0.16, sr,
                                harm=((1.0, 1.0), (2.0, 0.28), (3.0, 0.12)),
                                decay=0.06, attack=0.004)
                    note = lowpass(note, 2200.0, 0.7, sr)
                    add_at(buf, t0 + bt * spb, note, sr, 0.045)
        # 旋律：后 8 小节
        melody = [
            (8, 0.0, 74, 1.0), (8, 1.0, 77, 1.0), (8, 2.0, 81, 2.0),
            (9, 0.0, 79, 1.0), (9, 1.0, 77, 1.0), (9, 2.0, 74, 2.0),
            (10, 0.0, 72, 1.0), (10, 1.0, 77, 1.0), (10, 2.0, 81, 2.0),
            (11, 0.0, 84, 3.0),
            (12, 0.0, 81, 1.0), (12, 1.0, 79, 1.0), (12, 2.0, 77, 2.0),
            (13, 0.0, 74, 2.0), (13, 2.0, 77, 2.0),
            (14, 0.0, 79, 1.0), (14, 1.0, 81, 1.0), (14, 2.0, 84, 2.0),
            (15, 0.0, 86, 4.0),
        ]
        for (bar, beat, m, dur_beats) in melody:
            note = tone(midi_hz(m), dur_beats * spb * 0.9, sr,
                        harm=((1.0, 1.0), (2.0, 0.40), (3.0, 0.18)),
                        decay=dur_beats * spb * 0.6, attack=0.01)
            note = lowpass(note, 3000.0, 0.7, sr)
            add_at(buf, bar * bar_s + beat * spb, note, sr, 0.10)

    buf = render_bgm(bpm, seq, bars, sr, events)
    return write_wav(OUT / "bgm_会战.wav", buf, sr, -3.5, 0.0, 0.0, dither=True)


# ===========================================================================
# 入口
# ===========================================================================

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["sfx", "voice", "bgm"], default=None)
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.only in (None, "sfx"):
        print("[音效] 10 类")
        sfx_click()
        sfx_box()
        sfx_move()
        sfx_attack()
        sfx_hit()
        sfx_death()
        sfx_build()
        sfx_gather()
        sfx_spell()
        sfx_win()
        sfx_lose()
    if args.only in (None, "voice"):
        build_voices()
    if args.only in (None, "bgm"):
        print("[BGM] 经营 40s / 会战 32s")
        bgm_calm()
        bgm_battle()
    print("完成 →", OUT)


if __name__ == "__main__":
    sys.exit(main())
