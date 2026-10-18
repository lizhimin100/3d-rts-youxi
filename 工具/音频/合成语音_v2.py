# -*- coding: utf-8 -*-
"""
合成语音_v2.py —— 用 Windows 中文 TTS + DSP 粗化，替换原来"听不懂"的共振峰假语音

为什么要换：
    原来 工具/音频/合成语音.py 是纯数学共振峰合成（声门脉冲 + 三段带通），
    本质上只是"有音节起伏的嗡嗡声"，没有任何语义 —— 玩家原话"听不懂是什么"。
    这里改成：**系统中文 TTS 先说出真实台词**（语义 100% 可懂），
    再用 DSP 把它变成"战场上的粗嗓门"：

      1. 重采样降调 0.82x（-3.4 半音）+ 时长拉长 → 低沉、语速慢（吼而不是说）
      2. tanh 软失真（drive 1.9）→ 声带沙哑、增加中频谐波
      3. 120Hz 胸腔共鸣提升 + 90Hz 高通（去隆隆）+ 3.2kHz 轻微下压（去齿音）
      4. 短混响（早期反射 4 抽头 + 指数尾）→ 有"站在营地里"的空间感
      5. 峰值 -8 dBFS（Voice 总线再 -8 dB）

输出文件名与 代码/音频/语音表.gd + 音效管理.gd 的 id 完全对应。
"""

import os
import sys
import wave
import struct
import numpy as np
import win32com.client as win32

SR_OUT = 44100
VOICE_DIR = r"E:\自定义游戏\简易rts\音频\语音"
SFX_DIR = r"E:\自定义游戏\简易rts\音频"

# 兵种 → 台词（应答 3 条 + 死亡 1 条）
LINES = {
    "农民": {
        "应答1": "是，大人。",
        "应答2": "我这就去。",
        "应答3": "干活了。",
        "死亡": "啊——",
    },
    "步兵": {
        "应答1": "是，长官！",
        "应答2": "步兵就位！",
        "应答3": "为了联盟！",
        "死亡": "呃啊——",
    },
    "弓箭手": {
        "应答1": "弓箭手就绪。",
        "应答2": "目标锁定。",
        "应答3": "箭在弦上。",
        "死亡": "唔——",
    },
    "法师": {
        "应答1": "魔法听候差遣。",
        "应答2": "元素听我号令。",
        "应答3": "如你所愿。",
        "死亡": "我的法力……",
    },
}

# 全局口令 / 系统提示（放在 音频/ 根，供 HUD 调用）
COMMANDS = {
    "指令_前进": "前进！",
    "指令_进攻": "进攻！",
    "指令_撤退": "撤退！",
    "提示_金币不足": "金币不足。",
    "提示_人口已满": "人口已满。",
    "提示_建造完成": "建造完成。",
}

# 每个兵种的音色参数：(降调比, 失真, 胸腔增益, 混响)
TIMBRE = {
    "农民": (0.86, 1.45, 0.28, 0.10),
    "步兵": (0.79, 2.05, 0.46, 0.13),
    "弓箭手": (0.84, 1.60, 0.30, 0.11),
    "法师": (0.81, 1.85, 0.34, 0.20),
}
CMD_TIMBRE = (0.80, 1.9, 0.42, 0.16)


# ---------------------------------------------------------------------------
# 1. SAPI 合成
# ---------------------------------------------------------------------------

def tts_wav(text, path, rate=-2, volume=100):
    sp = win32.Dispatch("SAPI.SpVoice")
    voices = sp.GetVoices()
    picked = None
    for i in range(voices.Count):
        d = voices.Item(i).GetDescription()
        if "Chinese" in d or "中文" in d or "Huihui" in d:
            picked = voices.Item(i)
            break
    if picked is not None:
        sp.Voice = picked
    sp.Rate = rate
    sp.Volume = volume
    fs = win32.Dispatch("SAPI.SpFileStream")
    # 22 = SAFT22kHz16BitMono；SAPI 输出 22k，后面我们自己升采样
    fs.Format.Type = 22
    fs.Open(path, 3, False)
    old = sp.AudioOutputStream
    sp.AudioOutputStream = fs
    sp.Speak(text)
    fs.Close()
    sp.AudioOutputStream = old


def read_wav(path):
    with wave.open(path, "rb") as w:
        n = w.getnframes()
        sr = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        raw = w.readframes(n)
    if sw == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    elif sw == 4:
        x = np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2147483648.0
    else:
        x = np.frombuffer(raw, dtype=np.uint8).astype(np.float32) / 128.0 - 1.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def write_wav(path, x, sr):
    x = np.clip(x, -1.0, 1.0)
    pcm = (x * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


# ---------------------------------------------------------------------------
# 2. DSP
# ---------------------------------------------------------------------------

def resample(x, ratio):
    """线性插值重采样。ratio < 1 = 降调 + 变慢。"""
    n_out = max(2, int(len(x) / ratio))
    t = np.linspace(0.0, len(x) - 1.001, n_out)
    return np.interp(t, np.arange(len(x)), x).astype(np.float32)


def biquad(x, b0, b1, b2, a1, a2):
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(len(x)):
        v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, x[i]
        y2, y1 = y1, v
        y[i] = v
    return y


def highpass(x, f, sr, q=0.707):
    w0 = 2.0 * np.pi * f / sr
    alpha = np.sin(w0) / (2.0 * q)
    c = np.cos(w0)
    b0 = (1 + c) * 0.5
    b1 = -(1 + c)
    b2 = (1 + c) * 0.5
    a0 = 1 + alpha
    return biquad(x, b0 / a0, b1 / a0, b2 / a0, (-2 * c) / a0, (1 - alpha) / a0)


def peak(x, f, sr, gain_db, q=1.0):
    A = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * np.pi * f / sr
    alpha = np.sin(w0) / (2.0 * q)
    c = np.cos(w0)
    b0 = 1 + alpha * A
    b1 = -2 * c
    b2 = 1 - alpha * A
    a0 = 1 + alpha / A
    a1 = -2 * c
    a2 = 1 - alpha / A
    return biquad(x, b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def lowpass(x, f, sr, q=0.707):
    w0 = 2.0 * np.pi * f / sr
    alpha = np.sin(w0) / (2.0 * q)
    c = np.cos(w0)
    b0 = (1 - c) * 0.5
    b1 = 1 - c
    b2 = (1 - c) * 0.5
    a0 = 1 + alpha
    return biquad(x, b0 / a0, b1 / a0, b2 / a0, (-2 * c) / a0, (1 - alpha) / a0)


def reverb(x, sr, wet=0.12, decay=0.42):
    """早期反射 4 抽头 + 指数尾噪声卷积（够用且便宜）。"""
    n_ir = int(sr * decay)
    rng = np.random.RandomState(7)
    ir = rng.randn(n_ir).astype(np.float32) * np.exp(-np.linspace(0, 7.0, n_ir))
    ir = lowpass(ir, 3800, sr)
    # 早期反射（盔甲/石墙）
    for k, (dly, g) in enumerate(((0.011, 0.55), (0.019, 0.40), (0.031, 0.28),
                                  (0.047, 0.18))):
        idx = int(dly * sr)
        if idx < n_ir:
            ir[idx] += g
    ir /= max(1e-6, np.abs(ir).max())
    y = np.convolve(x, ir, mode="full")[:len(x)]
    y /= max(1e-6, np.abs(y).max())
    return x * (1.0 - wet) + y * wet * 1.6


def thicken(x, sr, ratio=0.5):
    """叠一层低八度（胸腔），让声音有体重。"""
    low = resample(x, 0.5)
    low = low[:len(x)]
    if len(low) < len(x):
        low = np.pad(low, (0, len(x) - len(low)))
    return x + low * ratio


def trim_silence(x, sr, thresh_db=-42.0, keep=0.035):
    """裁掉 TTS 自带的首尾静音（SAPI 尾部常有 0.5s，会让应答显得迟钝）。"""
    th = 10.0 ** (thresh_db / 20.0)
    idx = np.where(np.abs(x) > th)[0]
    if len(idx) == 0:
        return x
    k = int(sr * keep)
    a = max(0, int(idx[0]) - k)
    b = min(len(x), int(idx[-1]) + k)
    return x[a:b]


def process(x, sr, timbre):
    ratio, drive, chest, wet = timbre
    x = trim_silence(x, sr)
    x = resample(x, ratio)
    sr2 = int(sr / ratio)
    x = thicken(x, sr2, 0.22)
    # 去直流 + 高通
    x = x - float(np.mean(x))
    x = highpass(x, 85, sr2)
    # 胸腔 + 去齿音
    x = peak(x, 125, sr2, 3.2 * (chest + 0.4), q=0.9)
    x = peak(x, 3200, sr2, -2.4, q=1.1)
    # 软失真
    x = np.tanh(x * drive) / np.tanh(drive)
    # 混响
    x = reverb(x, sr2, wet=wet, decay=0.38)
    # 首尾淡入淡出（12ms），避免咔哒
    n = int(sr2 * 0.012)
    if len(x) > 2 * n:
        x[:n] *= np.linspace(0.0, 1.0, n)
        x[-n:] *= np.linspace(1.0, 0.0, n)
    # 归一化到 -8 dBFS
    peak_v = float(np.abs(x).max())
    if peak_v > 1e-6:
        x = x * (10.0 ** (-8.0 / 20.0) / peak_v)
    # 统一 44.1k 输出（引擎侧解码无所谓，但保持全项目一致）
    if sr2 != SR_OUT:
        x = resample(x, sr2 / float(SR_OUT))
    return x


def main():
    os.makedirs(VOICE_DIR, exist_ok=True)
    tmp = os.path.join(VOICE_DIR, "_tts_tmp.wav")
    made = 0

    for group, lines in LINES.items():
        timbre = TIMBRE[group]
        for tag, text in lines.items():
            tts_wav(text, tmp, rate=(-2 if tag == "死亡" else 0))
            x, sr = read_wav(tmp)
            y = process(x, sr, timbre)
            out = os.path.join(VOICE_DIR, "%s_%s.wav" % (group, tag))
            write_wav(out, y, SR_OUT)
            made += 1
            print("[语音] %-22s %.2fs  %.1f dBFS" % (
                os.path.basename(out), len(y) / float(SR_OUT),
                20.0 * np.log10(max(1e-6, float(np.abs(y).max())))))

    for name, text in COMMANDS.items():
        tts_wav(text, tmp, rate=1)
        x, sr = read_wav(tmp)
        y = process(x, sr, CMD_TIMBRE)
        out = os.path.join(SFX_DIR, "%s.wav" % name)
        write_wav(out, y, SR_OUT)
        made += 1
        print("[口令] %-22s %.2fs" % (os.path.basename(out), len(y) / float(SR_OUT)))

    try:
        os.remove(tmp)
    except OSError:
        pass
    print("DONE", made)


if __name__ == "__main__":
    main()
