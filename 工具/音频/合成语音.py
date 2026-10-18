# -*- coding: utf-8 -*-
"""
合成语音.py —— 四兵种的应答/死亡语音（程序合成，零版权风险）

为什么自己合成：项目坚持"全程序化生成"的资产口径；网上找的真人语音要么有版权，
要么风格不统一。这里用"共振峰合成"（脉冲源 + 三级带通共振腔）做出能听出区别的短促应答音，
每个兵种 3 条应答 + 1 条死亡。

输出：音频/语音/<组名>_应答1..3.wav、<组名>_死亡.wav
     （与 代码/音频/语音表.gd 的命名逐字对应）

用法：python 工具/音频/合成语音.py
"""

import math
import os
import random
import struct
import wave

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                   "音频", "语音")

# 元音共振峰 (F1, F2, F3) —— 经典男声取值
VOWELS = {
    "a": (730, 1090, 2440),
    "e": (530, 1840, 2480),
    "i": (270, 2290, 3010),
    "o": (570, 840, 2410),
    "u": (300, 870, 2240),
}

# 兵种音色：F0、元音序列、时长、气声量、亮度
VOICES = {
    "农民":   {"f0": 178, "vowels": ["a", "e"], "dur": 0.42, "breath": 0.10, "tilt": 0.55},
    "步兵":   {"f0": 104, "vowels": ["o", "a"], "dur": 0.52, "breath": 0.07, "tilt": 0.42},
    "弓箭手": {"f0": 141, "vowels": ["e", "i"], "dur": 0.40, "breath": 0.12, "tilt": 0.50},
    "法师":   {"f0": 118, "vowels": ["o", "u"], "dur": 0.58, "breath": 0.20, "tilt": 0.60},
}


class Resonator(object):
    """二级带通（共振腔）。"""

    def __init__(self, f, bw):
        r = math.exp(-math.pi * bw / SR)
        th = 2.0 * math.pi * f / SR
        self.a1 = 2.0 * r * math.cos(th)
        self.a2 = -r * r
        self.g = 1.0 - r
        self.y1 = 0.0
        self.y2 = 0.0

    def step(self, x):
        y = self.g * x + self.a1 * self.y1 + self.a2 * self.y2
        self.y2 = self.y1
        self.y1 = y
        return y


def synth_voice(f0, vowels, dur, breath, tilt, rnd, pitch_end=None):
    n = int(SR * dur)
    out = [0.0] * n
    # 三共振腔随元音切换
    stages = max(1, len(vowels))
    res = []
    for v in vowels:
        f1, f2, f3 = VOWELS[v]
        res.append((Resonator(f1, 90), Resonator(f2, 120), Resonator(f3, 180)))
    phase = 0.0
    if pitch_end is None:
        pitch_end = f0
    for i in range(n):
        t = i / float(n)
        # 音高轮廓：起音略高 -> 落下来；死亡音整体下行
        f = f0 * (1.02 - 0.06 * t) + (pitch_end - f0) * t
        f *= 1.0 + 0.012 * math.sin(2 * math.pi * 5.2 * t)   # 轻微颤音
        phase += f / SR
        if phase >= 1.0:
            phase -= 1.0
        # 脉冲源（窄脉冲 = 声带）
        src = 1.0 if phase < 0.22 else -0.06
        src += rnd.uniform(-breath, breath) * 0.9
        # 元音段
        seg = min(stages - 1, int(t * stages))
        r1, r2, r3 = res[seg]
        y = r1.step(src)
        y = r2.step(y)
        y = r3.step(y)
        # 包络：快起 + 平台 + 收尾
        if t < 0.06:
            env = t / 0.06
        elif t > 0.72:
            env = max(0.0, (1.0 - t) / 0.28)
        else:
            env = 1.0
        out[i] = y * env * tilt
    return out


def synth_death(f0, vowels, dur, breath, tilt, rnd):
    sig = synth_voice(f0, vowels, dur, breath * 1.6, tilt, rnd, pitch_end=f0 * 0.55)
    # 死亡音后半段加一点气声衰减
    n = len(sig)
    for i in range(n):
        t = i / float(n)
        if t > 0.55:
            sig[i] *= 1.0 - (t - 0.55) / 0.45
    return sig


def normalize(sig, peak_db=-6.0):
    peak = max(1e-6, max(abs(v) for v in sig))
    target = 10.0 ** (peak_db / 20.0)
    k = target / peak
    return [v * k for v in sig]


def write_wav(path, sig):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767)) for v in sig)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)


def main():
    total = 0
    for group, cfg in VOICES.items():
        for i in range(3):
            rnd = random.Random(hash((group, i)) & 0xFFFF)
            # 每个变体换元音顺序 / 抖音高，避免"同一条播三遍"
            vs = cfg["vowels"][:] if i % 2 == 0 else list(reversed(cfg["vowels"]))
            f0 = cfg["f0"] * (1.0 + 0.03 * (i - 1))
            sig = synth_voice(f0, vs, cfg["dur"] * (1.0 + 0.06 * i), cfg["breath"],
                              cfg["tilt"], rnd)
            write_wav(os.path.join(OUT, "%s_应答%d.wav" % (group, i + 1)), normalize(sig))
            total += 1
        rnd = random.Random(hash((group, "death")) & 0xFFFF)
        sig = synth_death(cfg["f0"], cfg["vowels"], cfg["dur"] * 1.7, cfg["breath"],
                          cfg["tilt"], rnd)
        write_wav(os.path.join(OUT, "%s_死亡.wav" % group), normalize(sig, -7.0))
        total += 1
    print("VOICE_OK 生成 %d 个语音文件 → %s" % (total, OUT))


if __name__ == "__main__":
    main()
