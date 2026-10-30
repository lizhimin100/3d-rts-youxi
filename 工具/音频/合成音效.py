#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""铁血战歌 · 程序化音频合成 v3（numpy 版，48 kHz 统一采样率）

与 v2（纯标准库 / 44.1k / 单声道）的区别：
  · 全部 48 kHz；BGM 立体声 60~90s 无缝循环
  · SFX 全部**重新合成**（不是旧文件的叠加），并新增 5 条：
        战斗_箭矢 / 战斗_塔射 / 建造_放置 / 提示_低血 / 升级_完成
  · BGM 采用"事件按模长回卷"渲染：音符尾巴绕回 0 点，接缝天然连续
  · 电平仍写进文件（播放端不再逐声衰减），与 音频/来源.md 的约定一致

运行解释器：需要 numpy（系统 Python 未装 numpy 时用 DSH 自带运行时）
    python 工具/音频/合成音效.py      # 需要 numpy；系统 Python 没装时用 DSH 运行时

分项：
    python 工具/音频/合成音效.py --only sfx
    python 工具/音频/合成音效.py --only bgm
"""

import argparse
import math
import sys
import wave
from pathlib import Path

import numpy as np

SR = 48000
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "音频"
VOICE_DIR = OUT / "语音"

TAU = 2.0 * math.pi


# ===========================================================================
# 基础 DSP（numpy / float64）
# ===========================================================================

def db2amp(db):
    return 10.0 ** (db / 20.0)


def peak_db(x):
    m = float(np.max(np.abs(x))) if len(x) else 0.0
    return 20.0 * math.log10(m) if m > 1e-12 else -120.0


def rms_db(x):
    if not len(x):
        return -120.0
    r = float(np.sqrt(np.mean(x * x)))
    return 20.0 * math.log10(r) if r > 1e-12 else -120.0


def centroid_hz(x, sr=SR):
    if not len(x):
        return 0.0
    X = np.abs(np.fft.rfft(x))
    if X.sum() <= 0:
        return 0.0
    f = np.fft.rfftfreq(len(x), 1.0 / sr)
    return float((X * f).sum() / X.sum())


def normalize(x, target_db):
    cur = peak_db(x)
    if cur < -100.0:
        return x
    return x * db2amp(target_db - cur)


def fade_io(x, sr=SR, fi=0.002, fo=0.008):
    n = len(x)
    a = min(n // 2, max(1, int(fi * sr)))
    b = min(n // 2, max(1, int(fo * sr)))
    if a > 0:
        x[:a] *= np.linspace(0.0, 1.0, a)
    if b > 0:
        x[-b:] *= np.linspace(1.0, 0.0, b)
    return x


def noise(n, seed):
    return np.random.default_rng(seed).uniform(-1.0, 1.0, n)


def t_axis(n, sr=SR):
    return np.arange(n, dtype=np.float64) / sr


def env_exp(n, tau, sr=SR):
    return np.exp(-t_axis(n, sr) / max(tau, 1e-6))


def env_ar(n, sr=SR, attack=0.002, release=0.05):
    """线性起振 + 指数衰减。"""
    t = t_axis(n, sr)
    a = np.clip(t / max(attack, 1e-6), 0.0, 1.0)
    return a * np.exp(-np.maximum(t - attack, 0.0) / max(release, 1e-6))


def osc(freq, n, sr=SR, shape="sine", phase0=0.0):
    """freq 可以是标量或长度 n 的数组。"""
    f = np.full(n, float(freq)) if np.isscalar(freq) else np.asarray(freq, dtype=np.float64)
    ph = phase0 + np.cumsum(f) / sr
    frac = ph - np.floor(ph)
    if shape == "sine":
        return np.sin(TAU * frac)
    if shape == "saw":
        return 2.0 * frac - 1.0
    if shape == "square":
        return np.where(frac < 0.5, 1.0, -1.0)
    if shape == "tri":
        return 4.0 * np.abs(frac - 0.5) - 1.0
    return np.sin(TAU * frac)


def biquad(x, b, a):
    """直接 I 型；只用于 <= 200k 样本的短音（BGM 长缓冲走 FFT）。"""
    b0, b1, b2 = b
    a0, a1, a2 = a
    if a0 != 1.0:
        b0, b1, b2 = b0 / a0, b1 / a0, b2 / a0
        a1, a2 = a1 / a0, a2 / a0
    y = np.empty_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(len(x)):
        xi = float(x[i])
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = xi
        y2 = y1
        y1 = yi
        y[i] = yi
    return y


def _coeffs(kind, f, q, sr):
    f = min(max(f, 10.0), sr * 0.45)
    w0 = TAU * f / sr
    c = math.cos(w0)
    alpha = math.sin(w0) / (2.0 * q)
    if kind == "lp":
        b = ((1 - c) / 2, 1 - c, (1 - c) / 2)
        a = (1 + alpha, -2 * c, 1 - alpha)
    elif kind == "hp":
        b = ((1 + c) / 2, -(1 + c), (1 + c) / 2)
        a = (1 + alpha, -2 * c, 1 - alpha)
    else:
        b = (alpha, 0.0, -alpha)
        a = (1 + alpha, -2 * c, 1 - alpha)
    return b, a


def lp(x, f, q=0.707, sr=SR):
    b, a = _coeffs("lp", f, q, sr)
    return biquad(x, b, a)


def hp(x, f, q=0.707, sr=SR):
    b, a = _coeffs("hp", f, q, sr)
    return biquad(x, b, a)


def bp(x, f, q=1.0, sr=SR):
    b, a = _coeffs("bp", f, q, sr)
    return biquad(x, b, a)


def fft_eq(x, sr, fn):
    """零相位 EQ（用于 BGM 长缓冲；循环素材用循环卷积正好保持接缝）。"""
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / sr)
    return np.fft.irfft(X * fn(f), n)


def butter_lp(fc, order=2):
    def fn(f):
        return 1.0 / np.sqrt(1.0 + (f / max(fc, 1.0)) ** (2 * order))
    return fn


def butter_hp(fc, order=2):
    def fn(f):
        r = np.maximum(f, 1e-6) / max(fc, 1.0)
        return 1.0 / np.sqrt(1.0 + (1.0 / r) ** (2 * order))
    return fn


def eq_chain(*fns):
    def fn(f):
        g = np.ones_like(f)
        for k in fns:
            g = g * k(f)
        return g
    return fn


def soft_clip(x, drive=1.2):
    return np.tanh(x * drive) / math.tanh(drive)


def convolve_fft(x, ir):
    n = len(x) + len(ir) - 1
    N = 1 << (n - 1).bit_length()
    y = np.fft.irfft(np.fft.rfft(x, N) * np.fft.rfft(ir, N), N)
    return y[: n]


def make_ir(sr, decay=0.35, wet_early=((0.011, 0.55), (0.019, 0.40), (0.031, 0.28),
                                        (0.047, 0.18)), lp_hz=4200.0, seed=7, length=None):
    """短混响 IR：指数尾噪声 + 早期反射抽头。"""
    n = int(sr * (length if length else decay * 2.2))
    rng = np.random.default_rng(seed)
    ir = rng.uniform(-1, 1, n) * np.exp(-np.linspace(0, 7.0, n))
    ir = lp(ir, lp_hz, 0.7, sr) if n < 200000 else fft_eq(ir, sr, butter_lp(lp_hz))
    for dly, g in wet_early:
        idx = int(dly * sr)
        if idx < n:
            ir[idx] += g
    ir /= max(1e-9, np.max(np.abs(ir)))
    return ir


def reverb(x, sr, wet=0.18, decay=0.30, lp_hz=4200.0, seed=7):
    ir = make_ir(sr, decay=decay, lp_hz=lp_hz, seed=seed)
    y = convolve_fft(x, ir)[: len(x)]
    m = max(1e-9, np.max(np.abs(y)))
    y = y / m * max(1e-9, np.max(np.abs(x)))
    return x * (1.0 - wet) + y * wet


def write_wav(path, data, sr=SR, target_db=None, fi=0.0, fo=0.0, dither=True):
    """data: (n,) 单声道 或 (n,2) 立体声。"""
    x = np.asarray(data, dtype=np.float64)
    stereo = x.ndim == 2
    if stereo and x.shape[1] != 2:
        raise ValueError("只支持 1 或 2 声道")
    if fi > 0 or fo > 0:
        if stereo:
            fade_io(x[:, 0], sr, fi, fo)
            fade_io(x[:, 1], sr, fi, fo)
        else:
            fade_io(x, sr, fi, fo)
    if target_db is not None:
        m = float(np.max(np.abs(x))) if x.size else 0.0
        if m > 1e-9:
            x = x * (db2amp(target_db) / m)
    x = np.clip(x, -1.0, 1.0)
    if dither:
        rng = np.random.default_rng(1234)
        shape = x.shape
        x = x + (rng.uniform(-0.5, 0.5, shape) + rng.uniform(-0.5, 0.5, shape)) / 32768.0
        x = np.clip(x, -1.0, 1.0)
    pcm = np.round(x * 32767.0).astype("<i2")
    path.parent.mkdir(parents=True, exist_ok=True)
    ch = 2 if stereo else 1
    with wave.open(str(path), "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())
    mono = x.mean(axis=1) if stereo else x
    print("  %-24s %6.2fs  %s %5.1fk  peak %6.1f  rms %6.1f  cen %5.0fHz" % (
        path.name, len(mono) / sr, "st" if stereo else "mo",
        path.stat().st_size / 1024.0, peak_db(mono), rms_db(mono), centroid_hz(mono, sr)))


# ===========================================================================
# SFX（全部重写；新增 5 条在最下方）
# ===========================================================================

def sfx_click():
    """界面_点选 65ms：两块木片轻碰，短、闷、连点不炸。"""
    n = int(0.065 * SR)
    t = t_axis(n)
    x = (0.62 * np.sin(TAU * 1180.0 * t) * np.exp(-t / 0.011)
         + 0.38 * np.sin(TAU * 1870.0 * t) * np.exp(-t / 0.006)
         + 0.30 * np.sin(TAU * 470.0 * t) * np.exp(-t / 0.022))
    x += 0.35 * hp(noise(n, 11), 2400.0) * np.exp(-t / 0.0028)
    x = hp(x, 260.0)
    x = soft_clip(x * 1.1)
    return write_wav(OUT / "界面_点选.wav", x, SR, -19.0, 0.0005, 0.012)


def sfx_box():
    """界面_框选 160ms：布面"唰"，低→高的带通扫过。"""
    n = int(0.160 * SR)
    t = t_axis(n)
    nz = noise(n, 21)
    lo = bp(nz, 760.0, 0.9)
    mid = bp(nz, 1500.0, 0.8)
    hi = bp(nz, 2900.0, 0.8)
    k = t / 0.160
    mixn = (1 - k) ** 2 * lo + 2 * k * (1 - k) * mid + k ** 2 * hi
    env = np.minimum(t / 0.008, 1.0) * np.exp(-np.maximum(t - 0.008, 0.0) / 0.055)
    x = mixn * env * 2.2
    tick = np.sin(TAU * 1720.0 * t) * np.exp(-t / 0.004) * 0.22
    return write_wav(OUT / "界面_框选.wav", x + tick, SR, -18.0, 0.001, 0.02)


def sfx_move():
    """指令_移动 110ms：低频落点 + 木鱼尾。"""
    n = int(0.110 * SR)
    t = t_axis(n)
    f = 240.0 * np.exp(-t / 0.020) + 88.0
    body = osc(f, n, SR, "sine") * np.exp(-t / 0.030) * 0.95
    tick = np.sin(TAU * 860.0 * t) * np.exp(-t / 0.006) * 0.30
    x = lp(body + tick, 3600.0)
    return write_wav(OUT / "指令_移动.wav", x, SR, -15.0, 0.001, 0.02)


def sfx_attack():
    """战斗_攻击 200ms：挥砍风声（带通中心上移）+ 低频推力。"""
    n = int(0.200 * SR)
    t = t_axis(n)
    nz = noise(n, 31)
    lo = bp(nz, 520.0, 0.7)
    hi = bp(nz, 2600.0, 0.6)
    k = np.clip(t / 0.200, 0, 1)
    swoosh = (lo * (1 - k) + hi * k) * np.sin(math.pi * np.clip(k / 0.62, 0, 1)) ** 1.2
    body = osc(120.0 * np.exp(-t / 0.18) + 55.0, n, SR, "sine") * np.exp(-t / 0.045) * 0.30
    x = soft_clip(swoosh * 1.15 + body, 1.15)
    return write_wav(OUT / "战斗_攻击.wav", x, SR, -5.0, 0.002, 0.03)


def sfx_hit():
    """战斗_命中 170ms：金属泛音簇 + 瞬态 + 一点房间。"""
    n = int(0.170 * SR)
    t = t_axis(n)
    x = np.zeros(n)
    for f, a, tau in ((571.0, 0.50, 0.085), (1174.0, 0.36, 0.060),
                      (1861.0, 0.26, 0.042), (2790.0, 0.16, 0.028), (3710.0, 0.10, 0.018)):
        x += a * np.sin(TAU * f * t + 0.7) * np.exp(-t / tau)
    x += hp(noise(n, 41), 3200.0) * np.exp(-t / 0.0035) * 0.55
    x = hp(x, 130.0)
    x = soft_clip(x, 1.25)
    x = reverb(x, SR, wet=0.13, decay=0.16, lp_hz=5200.0, seed=41)
    return write_wav(OUT / "战斗_命中.wav", x, SR, -4.0, 0.0005, 0.03)


def sfx_death():
    """战斗_死亡 620ms：下坠闷吼 + 尾段碎石。"""
    n = int(0.620 * SR)
    t = t_axis(n)
    f = 250.0 * np.exp(-t / 0.22) + 66.0
    src = lp(osc(f, n, SR, "saw"), 1500.0, 0.65)
    growl = 0.62 + 0.38 * np.sin(TAU * 24.0 * t)
    env = np.minimum(t / 0.012, 1.0) * np.exp(-t / 0.20)
    x = src * env * growl
    deb = bp(noise(n, 51), 820.0, 0.7) * np.exp(-np.maximum(t - 0.28, 0.0) / 0.09) * (t > 0.28) * 0.22
    x = lp(x + deb, 5200.0)
    return write_wav(OUT / "战斗_死亡.wav", x, SR, -5.0, 0.002, 0.06)


def sfx_build():
    """建造_完成 340ms：锤击 + 金属余韵 + 一点上扬。"""
    n = int(0.340 * SR)
    t = t_axis(n)
    thud = osc(240.0 * np.exp(-t / 0.030) + 96.0, n, SR, "sine") * np.exp(-t / 0.060) * 0.95
    ring = (0.26 * np.sin(TAU * 1460.0 * t) + 0.14 * np.sin(TAU * 2630.0 * t)) * np.exp(-t / 0.090)
    tick = hp(noise(n, 61), 1800.0) * np.exp(-t / 0.0025) * 0.45
    lift = np.sin(TAU * (520.0 + 240.0 * t / 0.34) * t) * np.exp(-t / 0.12) * 0.10
    x = thud + ring + tick + lift
    x = reverb(x, SR, wet=0.12, decay=0.20, seed=61)
    return write_wav(OUT / "建造_完成.wav", x, SR, -5.0, 0.0005, 0.04)


def sfx_hammer():
    """建造_锤击 150ms：锤头打在石头/木料上的短促一击（工地用）。"""
    n = int(0.150 * SR)
    t = t_axis(n)
    strike = osc(300.0 * np.exp(-t / 0.014) + 110.0, n, SR, "sine") * np.exp(-t / 0.028) * 0.9
    wood = bp(noise(n, 77), 1300.0, 1.2) * np.exp(-t / 0.010) * 0.55
    grit = hp(noise(n, 78), 3800.0) * np.exp(-t / 0.004) * 0.30
    x = soft_clip(strike + wood + grit, 1.15)
    return write_wav(OUT / "建造_锤击.wav", x, SR, -8.0, 0.0005, 0.02)


def sfx_gather():
    """采集_资源 170ms：两粒金币，第二粒稍晚稍轻。"""
    n = int(0.170 * SR)
    t = t_axis(n)
    x = np.zeros(n)
    for start, amp in ((0.0, 1.0), (0.055, 0.62)):
        i0 = int(start * SR)
        tt = t[: n - i0]
        seg = (0.55 * np.sin(TAU * 2360.0 * tt) + 0.30 * np.sin(TAU * 3540.0 * tt)
               + 0.12 * np.sin(TAU * 5210.0 * tt)) * np.exp(-tt / 0.022) * amp
        x[i0:] += seg
    x = hp(x, 900.0)
    return write_wav(OUT / "采集_资源.wav", x, SR, -7.0, 0.001, 0.02)


def sfx_spell():
    """法术_施放 820ms：上冲气流 + 中段爆点 + 尾音闪烁。"""
    n = int(0.820 * SR)
    t = t_axis(n)
    nz = noise(n, 71)
    k = np.clip(t / 0.82, 0, 1)
    who = (bp(nz, 700.0, 0.6) * (1 - k) + bp(nz, 2200.0, 0.7) * k) * np.sin(np.pi * np.clip(k / 0.55, 0, 1)) ** 1.5
    tone = osc(180.0 * np.exp(-t / 0.18) + 62.0, n, SR, "sine") * np.exp(-t / 0.30) * 0.75
    boom = np.exp(-np.maximum(t - 0.26, 0.0) / 0.10) * (t > 0.26) * bp(noise(n, 72), 260.0, 0.8) * 0.9
    shimmer = sum(np.sin(TAU * f * t) for f in (1568.0, 2349.0, 3136.0)) / 3.0
    shimmer *= np.exp(-np.maximum(t - 0.40, 0.0) / 0.16) * (t > 0.40) * 0.12
    x = who * 0.9 + tone + boom + shimmer
    x = reverb(x, SR, wet=0.22, decay=0.34, seed=71)
    return write_wav(OUT / "法术_施放.wav", x, SR, -4.0, 0.002, 0.06)


def _fanfare(notes, dur, sr, shape="sine", harm=((1.0, 1.0), (2.0, 0.3), (3.0, 0.15))):
    n = int(dur * sr)
    t = t_axis(n, sr)
    out = np.zeros(n)
    for start, freq, length, amp in notes:
        i0 = int(start * sr)
        m = min(int(length * sr), n - i0)
        if m <= 1:
            continue
        tt = t[:m]
        env = np.minimum(tt / 0.012, 1.0) * np.exp(-tt / (length * 0.62))
        v = np.zeros(m)
        for h, ha in harm:
            v += ha * np.sin(TAU * freq * h * tt)
        out[i0:i0 + m] += v * env * amp
    return out


def sfx_win():
    """结算_胜利 1.9s：大调号角 + 定音鼓。"""
    notes = [(0.00, 523.25, 0.60, 0.50), (0.00, 261.63, 0.95, 0.28),
             (0.16, 659.25, 0.60, 0.46), (0.32, 783.99, 0.65, 0.46),
             (0.48, 1046.50, 1.05, 0.52), (0.48, 523.25, 1.05, 0.26)]
    out = _fanfare(notes, 1.9, SR)
    raw = _fanfare(notes, 1.9, SR, "saw")
    out = out + hp(raw, 1700.0) * 0.16
    n = len(out)
    t = t_axis(n)
    timp = np.sin(TAU * (98.0 * np.exp(-t / 0.5) + 48.0) * t) * np.exp(-t / 0.35) * 0.30
    out = soft_clip(out + timp, 1.1)
    out = reverb(out, SR, wet=0.20, decay=0.55, seed=81)
    return write_wav(OUT / "结算_胜利.wav", out, SR, -4.0, 0.005, 0.12)


def sfx_lose():
    """结算_失败 1.9s：下行小调 + 低音持续。"""
    notes = [(0.00, 440.00, 0.60, 0.46), (0.00, 220.00, 1.30, 0.24),
             (0.28, 349.23, 0.60, 0.44), (0.56, 293.66, 0.65, 0.44),
             (0.84, 220.00, 1.05, 0.50)]
    out = _fanfare(notes, 1.9, SR)
    low = lp(_fanfare(notes, 1.9, SR, "saw"), 900.0) * 0.26
    out = soft_clip(out + low, 1.1)
    out = reverb(out, SR, wet=0.26, decay=0.70, seed=82)
    return write_wav(OUT / "结算_失败.wav", out, SR, -4.0, 0.005, 0.14)


# ---------------------------- 新增 5 条 ----------------------------

def sfx_arrow():
    """战斗_箭矢 180ms：箭杆破空（细带通下扫）+ 末端轻扑。"""
    n = int(0.180 * SR)
    t = t_axis(n)
    nz = noise(n, 91)
    k = np.clip(t / 0.150, 0, 1)
    whiz = (bp(nz, 6200.0, 2.2) * (1 - k) + bp(nz, 2600.0, 1.6) * k)
    whiz *= np.sin(math.pi * np.clip(k, 0, 1)) ** 1.3
    thud = np.exp(-np.maximum(t - 0.130, 0.0) / 0.012) * (t > 0.130) * bp(noise(n, 92), 420.0, 1.4) * 0.5
    x = hp(whiz * 1.3, 1200.0) + thud
    return write_wav(OUT / "战斗_箭矢.wav", x, SR, -6.0, 0.001, 0.02)


def sfx_tower():
    """战斗_塔射 260ms：弩机释放（弦振 + 机括）+ 箭矢出膛。"""
    n = int(0.260 * SR)
    t = t_axis(n)
    string = osc(210.0 * np.exp(-t / 0.045) + 74.0, n, SR, "tri") * np.exp(-t / 0.050) * 0.85
    clack = bp(noise(n, 93), 1900.0, 1.5) * np.exp(-t / 0.006) * 0.75
    creak = bp(noise(n, 94), 640.0, 2.0) * np.exp(-np.maximum(t - 0.03, 0.0) / 0.05) * (t > 0.03) * 0.35
    out = np.exp(-np.maximum(t - 0.10, 0.0) / 0.09) * (t > 0.10) * bp(noise(n, 95), 3200.0, 1.2) * 0.22
    x = soft_clip(string + clack + creak + out, 1.2)
    x = reverb(x, SR, wet=0.12, decay=0.14, seed=95)
    return write_wav(OUT / "战斗_塔射.wav", x, SR, -6.0, 0.0005, 0.03)


def sfx_place():
    """建造_放置 460ms：石料落地 + 木架吱呀 + 碎石散落（放下工地的第一声）。"""
    n = int(0.460 * SR)
    t = t_axis(n)
    thud = osc(150.0 * np.exp(-t / 0.055) + 58.0, n, SR, "sine") * np.exp(-t / 0.075) * 1.0
    stone = bp(noise(n, 96), 900.0, 0.9) * np.exp(-t / 0.045) * 0.65
    rubble = bp(noise(n, 97), 2400.0, 0.8) * np.exp(-np.maximum(t - 0.06, 0.0) / 0.13) * (t > 0.06) * 0.30
    creak = np.sin(TAU * (150.0 + 40.0 * np.sin(TAU * 9.0 * t)) * t) * np.exp(-np.maximum(t - 0.05, 0.0) / 0.10) * (t > 0.05) * 0.16
    x = soft_clip(thud + stone + rubble + creak, 1.1)
    x = lowpass_safe(x)
    x = reverb(x, SR, wet=0.14, decay=0.25, seed=97)
    return write_wav(OUT / "建造_放置.wav", x, SR, -6.0, 0.001, 0.05)


def lowpass_safe(x, hz=6000.0):
    return fft_eq(x, SR, butter_lp(hz, 2))


def sfx_lowhp():
    """提示_低血 700ms：两声短促警戒（带一点失真，紧张但不刺耳）。"""
    n = int(0.700 * SR)
    t = t_axis(n)
    x = np.zeros(n)
    for start, freq, dur in ((0.00, 880.0, 0.13), (0.18, 660.0, 0.16)):
        i0 = int(start * SR)
        m = int(dur * SR)
        tt = t[:m]
        env = np.minimum(tt / 0.004, 1.0) * np.exp(-tt / 0.050)
        seg = (np.sin(TAU * freq * tt) + 0.35 * np.sin(TAU * freq * 2.0 * tt)
               + 0.18 * np.sin(TAU * freq * 3.0 * tt)) * env
        seg = soft_clip(seg, 1.4) * 0.8
        if i0 + m <= n:
            x[i0:i0 + m] += seg
    # 低频心跳垫底
    pulse = np.sin(TAU * 58.0 * t) * np.exp(-np.maximum(t - 0.02, 0.0) / 0.09) * (t > 0.02) * 0.25
    x = hp(x, 180.0) + pulse
    return write_wav(OUT / "提示_低血.wav", x, SR, -8.0, 0.002, 0.06)


def sfx_upgrade():
    """升级_完成 2.1s：四音上行钟 + 泛音闪光（研究/升级完成的确认音）。"""
    n = int(2.10 * SR)
    t = t_axis(n)
    x = np.zeros(n)
    seq = ((0.00, 523.25, 0.36), (0.13, 659.25, 0.36), (0.26, 783.99, 0.40), (0.39, 1046.50, 1.30))
    for start, freq, tau in seq:
        i0 = int(start * SR)
        m = n - i0
        tt = t[:m]
        env = np.minimum(tt / 0.006, 1.0) * np.exp(-tt / tau)
        v = (np.sin(TAU * freq * tt) + 0.42 * np.sin(TAU * freq * 2.0 * tt)
             + 0.20 * np.sin(TAU * freq * 3.01 * tt) + 0.10 * np.sin(TAU * freq * 4.2 * tt))
        x[i0:] += v * env * 0.55
    shimmer = sum(np.sin(TAU * f * t) for f in (2093.0, 2637.0, 3136.0, 4186.0)) / 4.0
    shimmer *= np.exp(-np.maximum(t - 0.42, 0.0) / 0.45) * (t > 0.42) * 0.10
    x = soft_clip(x + shimmer, 1.05)
    x = reverb(x, SR, wet=0.24, decay=0.60, seed=98)
    return write_wav(OUT / "升级_完成.wav", x, SR, -4.0, 0.004, 0.12)


# ===========================================================================
# BGM：立体声 48k，事件按模长回卷 → 接缝连续
# ===========================================================================

def midi_hz(m):
    return 440.0 * (2.0 ** ((m - 69.0) / 12.0))


def add_wrap(L, R, sig, start, gain=1.0, pan=0.0):
    """把 sig 从 start 起叠加到循环缓冲，超出末尾的部分绕回开头。"""
    n = len(L)
    if len(sig) == 0:
        return
    start = int(start) % n
    ang = (pan * 0.5 + 0.5) * (math.pi / 2.0)   # constant power
    gl = math.cos(ang) * gain * math.sqrt(2.0)
    gr = math.sin(ang) * gain * math.sqrt(2.0)
    end = start + len(sig)
    if end <= n:
        L[start:end] += sig * gl
        R[start:end] += sig * gr
    else:
        k = n - start
        L[start:] += sig[:k] * gl
        R[start:] += sig[:k] * gr
        L[: end - n] += sig[k:] * gl
        R[: end - n] += sig[k:] * gr


def pluck(freq, dur, sr, harm=((1, 1.0), (2, 0.34), (3, 0.12)), decay=0.32, detune=0.0):
    n = int(dur * sr)
    t = t_axis(n, sr)
    v = np.zeros(n)
    for h, a in harm:
        v += a * np.sin(TAU * freq * h * (1.0 + detune) * t)
    env = np.minimum(t / 0.004, 1.0) * np.exp(-t / decay)
    return v * env


def pad(freqs, dur, sr, attack=0.8, release=1.4, seed=3, bright=1.0):
    n = int(dur * sr)
    t = t_axis(n, sr)
    rng = np.random.default_rng(seed)
    v = np.zeros(n)
    for f in freqs:
        for det in (-0.004, 0.0, 0.004):
            ff = f * (1.0 + det + rng.uniform(-0.0008, 0.0008))
            for h, a in ((1, 1.0), (2, 0.45 * bright), (3, 0.22 * bright), (4, 0.10 * bright)):
                v += a * np.sin(TAU * ff * h * t + rng.uniform(0, TAU))
    v /= (len(freqs) * 3.0)
    env = np.minimum(t / max(attack, 1e-4), 1.0)
    rel = np.minimum((n - np.arange(n)) / max(release, 1e-4), 1.0)
    return v * env * rel


def bass_note(freq, dur, sr, decay=0.55):
    n = int(dur * sr)
    t = t_axis(n, sr)
    v = np.sin(TAU * freq * t) + 0.24 * np.sin(TAU * freq * 2.0 * t) + 0.07 * np.sin(TAU * freq * 3.0 * t)
    env = np.minimum(t / 0.010, 1.0) * np.exp(-t / decay)
    return v * env


def shaker(sr, seed, dur=0.055):
    n = int(dur * sr)
    t = t_axis(n, sr)
    nz = noise(n, seed)
    v = fft_eq(nz, sr, butter_hp(5200.0, 2))
    return v * np.exp(-t / 0.014)


def kick(sr, dur=0.22):
    n = int(dur * sr)
    t = t_axis(n, sr)
    f = 150.0 * np.exp(-t / 0.024) + 46.0
    return np.sin(TAU * np.cumsum(f) / sr) * np.exp(-t / 0.095)


def snare(sr, seed, dur=0.16):
    n = int(dur * sr)
    t = t_axis(n, sr)
    nz = noise(n, seed)
    body = bp(nz, 1900.0, 0.8) * np.exp(-t / 0.045)
    tone = np.sin(TAU * 190.0 * t) * np.exp(-t / 0.030) * 0.45
    return body + tone


def hat(sr, seed, dur=0.05):
    n = int(dur * sr)
    t = t_axis(n, sr)
    return fft_eq(noise(n, seed), sr, butter_hp(7600.0, 2)) * np.exp(-t / 0.012)


def horn_note(freq, dur, sr, decay=0.9):
    n = int(dur * sr)
    t = t_axis(n, sr)
    vib = 1.0 + 0.0035 * np.sin(TAU * 5.2 * t)
    v = np.zeros(n)
    for h, a in ((1, 1.0), (2, 0.55), (3, 0.34), (4, 0.18), (5, 0.09)):
        v += a * np.sin(TAU * freq * h * vib * t)
    env = np.minimum(t / 0.035, 1.0) * np.exp(-t / decay)
    return v * env


def render_loop(bpm, bars, sr, build_events):
    """返回 (L, R, 总秒数)。事件直接写进长度恰为总长的缓冲，尾巴回卷。"""
    spb = 60.0 / bpm
    bar_s = spb * 4.0
    total = bar_s * bars
    n = int(round(total * sr))
    L = np.zeros(n)
    R = np.zeros(n)
    build_events(L, R, sr, spb, bar_s)
    return L, R, total


CHORDS_CALM = {"Am": [57, 60, 64], "F": [53, 57, 60], "C": [48, 52, 55], "G": [55, 59, 62]}
CHORDS_BATTLE = {"Dm": [62, 65, 69], "Bb": [58, 62, 65], "F": [57, 60, 65], "C": [55, 60, 64]}


def bgm_calm():
    """经营：96 BPM / 32 小节 = 80s / Am-F-C-G / 拨弦 + 铺底 + 沙锤。"""
    bpm, bars = 96.0, 32
    prog = ["Am", "F", "C", "G"]
    seq = [prog[(b // 4) % 4] for b in range(bars)]

    def build(L, R, sr, spb, bar_s):
        rng = np.random.default_rng(7)
        for b in range(bars):
            name = seq[b]
            chord = CHORDS_CALM[name]
            t0 = b * bar_s * sr
            if b % 4 == 0:
                dur = bar_s * 4.0 + 1.2
                p = pad([midi_hz(m) for m in chord], dur, sr, attack=1.0, release=1.6, seed=10 + b, bright=0.8)
                add_wrap(L, R, p, t0, 0.135, 0.0)
                p2 = pad([midi_hz(m) for m in chord], dur, sr, attack=1.2, release=1.8, seed=200 + b, bright=0.9)
                add_wrap(L, R, p2, t0, 0.10, -0.35)
                p3 = pad([midi_hz(m) for m in chord], dur, sr, attack=0.9, release=1.5, seed=400 + b, bright=0.7)
                add_wrap(L, R, p3, t0, 0.10, 0.35)
            pattern = [0, 1, 2, 1, 0, 2, 1, 2]
            for k, pi in enumerate(pattern):
                m = chord[pi] + (12 if k % 4 == 2 else 0)
                note = pluck(midi_hz(m), 0.95, sr,
                             harm=((1, 1.0), (2, 0.30), (3, 0.10), (4, 0.04)),
                             decay=0.34, detune=rng.uniform(-0.0012, 0.0012))
                pan = -0.30 if k % 2 else 0.30
                add_wrap(L, R, note, t0 + k * spb * 0.5 * sr, 0.105, pan)
            root = chord[0] - 12
            for bt in (0.0, 2.0):
                note = bass_note(midi_hz(root), 1.5, sr, decay=0.60)
                add_wrap(L, R, note, t0 + bt * spb * sr, 0.22, 0.0)
            for bt in (0.5, 1.5, 2.5, 3.5):
                sh = shaker(sr, 300 + b * 7 + int(bt * 2))
                add_wrap(L, R, sh, t0 + bt * spb * sr, 0.045, 0.45 if bt % 2 else -0.45)
        melody = [(4, 0.0, 69, 2.0), (4, 2.0, 72, 2.0), (5, 0.0, 76, 2.0),
                  (5, 2.0, 74, 1.0), (5, 3.0, 72, 1.0), (6, 0.0, 69, 3.0),
                  (7, 0.0, 67, 2.0), (7, 2.0, 69, 2.0),
                  (12, 0.0, 76, 2.0), (12, 2.0, 79, 2.0),
                  (13, 0.0, 79, 1.0), (13, 1.0, 76, 1.0), (13, 2.0, 74, 2.0),
                  (14, 0.0, 72, 2.0), (14, 2.0, 69, 2.0), (15, 0.0, 67, 3.0)]
        for (bar, beat, m, beats) in melody:
            note = horn_note(midi_hz(m), beats * spb * 0.95, sr, decay=beats * spb * 0.55)
            start = (bar * bar_s + beat * spb) * sr
            add_wrap(L, R, note, start, 0.082, -0.18)
            add_wrap(L, R, note, start + 0.013 * sr, 0.036, 0.50)

    L, R, total = render_loop(bpm, bars, SR, build)
    L = fft_eq(L, SR, eq_chain(butter_hp(28.0, 2), butter_lp(9000.0, 1)))
    R = fft_eq(R, SR, eq_chain(butter_hp(28.0, 2), butter_lp(9000.0, 1)))
    st = np.stack([L, R], axis=1)
    return write_wav(OUT / "bgm_经营.wav", st, SR, -4.5, 0.0, 0.0)


def bgm_battle():
    """会战：120 BPM / 36 小节 = 72s / Dm-Bb-F-C / 鼓 + 八分贝斯 + 弦乐断奏。"""
    bpm, bars = 120.0, 36
    prog = ["Dm", "Bb", "F", "C"]
    seq = [prog[(b // 4) % 4] for b in range(bars)]

    def build(L, R, sr, spb, bar_s):
        rng = np.random.default_rng(17)
        for b in range(bars):
            chord = CHORDS_BATTLE[seq[b]]
            t0 = b * bar_s * sr
            intense = b >= 16
            if b % 4 == 0:
                dur = bar_s * 4.0 + 0.8
                p = pad([midi_hz(m) for m in chord], dur, sr, attack=0.30, release=0.7,
                        seed=20 + b, bright=1.0)
                add_wrap(L, R, p, t0, 0.10 if not intense else 0.13, 0.0)
                p2 = pad([midi_hz(m + 12) for m in chord], dur, sr, attack=0.5, release=0.9,
                         seed=500 + b, bright=1.2)
                add_wrap(L, R, p2, t0, 0.062, -0.78)
                p3 = pad([midi_hz(m + 12) for m in chord], dur, sr, attack=0.6, release=1.0,
                         seed=700 + b, bright=1.1)
                add_wrap(L, R, p3, t0, 0.062, 0.78)
            for bt in (0.0, 2.0):
                add_wrap(L, R, kick(sr), t0 + bt * spb * sr, 0.50, 0.0)
            if b >= 4:
                for bt in (1.0, 3.0):
                    add_wrap(L, R, snare(sr, 500 + b * 13 + int(bt)), t0 + bt * spb * sr, 0.26, 0.05)
            for k in range(8):
                add_wrap(L, R, hat(sr, 900 + b * 31 + k),
                         t0 + k * spb * 0.5 * sr, 0.055 if intense else 0.042,
                         0.5 if k % 2 else -0.5)
            root = chord[0] - 12
            for k, interval in enumerate([0, 0, 7, 0, 0, 0, 10, 0]):
                m = root + interval
                note = lp(bass_note(midi_hz(m), 0.30, sr, decay=0.11), 700.0, 0.8)
                add_wrap(L, R, note, t0 + k * spb * 0.5 * sr, 0.25, 0.0)
            for bt in (0.5, 1.5, 2.5, 3.5):
                stab_pan = -0.62 if bt in (0.5, 2.5) else 0.62
                for m in chord:
                    note = pluck(midi_hz(m), 0.20, sr,
                                 harm=((1, 1.0), (2, 0.35), (3, 0.16), (4, 0.07)),
                                 decay=0.075)
                    add_wrap(L, R, note, t0 + bt * spb * sr, 0.046, stab_pan)
                    note2 = pluck(midi_hz(m + 12), 0.18, sr,
                                  harm=((1, 1.0), (2, 0.30), (3, 0.12)), decay=0.06)
                    add_wrap(L, R, note2, t0 + bt * spb * sr, 0.028, -stab_pan * 0.8)
        melody = [(16, 0.0, 74, 1.0), (16, 1.0, 77, 1.0), (16, 2.0, 81, 2.0),
                  (17, 0.0, 79, 1.0), (17, 1.0, 77, 1.0), (17, 2.0, 74, 2.0),
                  (18, 0.0, 72, 1.0), (18, 1.0, 77, 1.0), (18, 2.0, 81, 2.0),
                  (19, 0.0, 84, 3.0),
                  (28, 0.0, 81, 1.0), (28, 1.0, 79, 1.0), (28, 2.0, 77, 2.0),
                  (29, 0.0, 74, 2.0), (29, 2.0, 77, 2.0),
                  (30, 0.0, 79, 1.0), (30, 1.0, 81, 1.0), (30, 2.0, 84, 2.0),
                  (31, 0.0, 86, 4.0)]
        for (bar, beat, m, beats) in melody:
            note = horn_note(midi_hz(m), beats * spb * 0.9, sr, decay=beats * spb * 0.6)
            start = (bar * bar_s + beat * spb) * sr
            add_wrap(L, R, note, start, 0.112, -0.22)
            # Haas 延迟（10ms）到另一侧：单声道不糊、立体声有宽度
            add_wrap(L, R, note, start + 0.010 * sr, 0.050, 0.55)

    L, R, total = render_loop(bpm, bars, SR, build)
    L = fft_eq(L, SR, eq_chain(butter_hp(30.0, 2), butter_lp(11000.0, 1)))
    R = fft_eq(R, SR, eq_chain(butter_hp(30.0, 2), butter_lp(11000.0, 1)))
    st = np.stack([L, R], axis=1)
    return write_wav(OUT / "bgm_会战.wav", st, SR, -3.5, 0.0, 0.0)


# ===========================================================================
# 入口
# ===========================================================================

SFX_LIST = [
    ("界面_点选", sfx_click), ("界面_框选", sfx_box), ("指令_移动", sfx_move),
    ("战斗_攻击", sfx_attack), ("战斗_命中", sfx_hit), ("战斗_死亡", sfx_death),
    ("建造_完成", sfx_build), ("建造_锤击", sfx_hammer), ("采集_资源", sfx_gather),
    ("法术_施放", sfx_spell), ("结算_胜利", sfx_win), ("结算_失败", sfx_lose),
    ("战斗_箭矢", sfx_arrow), ("战斗_塔射", sfx_tower), ("建造_放置", sfx_place),
    ("提示_低血", sfx_lowhp), ("升级_完成", sfx_upgrade),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["sfx", "bgm"], default=None)
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.only in (None, "sfx"):
        print("[音效] %d 条（12 重做 + 5 新增）" % len(SFX_LIST))
        for _, fn in SFX_LIST:
            fn()
    if args.only in (None, "bgm"):
        print("[BGM] 立体声 48k 无缝循环")
        bgm_calm()
        bgm_battle()
    print("完成 →", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
