# -*- coding: utf-8 -*-
r"""合成语音 v3 —— SAPI 说中文 + numpy 粗化（不依赖 pywin32）

v2 用 win32com 直接调 SAPI，本机没装 pywin32 就跑不起来。v3 改成：
    Python 生成一份临时 .ps1（UTF-8 BOM），交给 Windows PowerShell 5.1 的
    System.Speech.Synthesis 合成 48 kHz/16bit 单声道 WAV 到临时目录，
    Python 再读回来做 DSP。

DSP 链路（每条都一样，只是参数不同）：
    1. 裁掉首尾静音（SAPI 尾部常有 0.4~0.8s，会让应答显得迟钝）
    2. 重采样降调（ratio<1：同时变慢变低）—— 女声 → 战场粗嗓
    3. 胸腔共振 +120Hz 一带提升、3.2kHz 轻度下压（去齿音）
    4. tanh 软失真（声带沙哑、加中频谐波）
    5. 短混响（早期反射 + 指数尾）→ "站在营地里"
    6. 12ms 淡入淡出，归一化到 -8 dBFS，统一 48 kHz 输出

输出：
    音频/语音/  农民|步兵|弓箭手|法师 × (应答1..3 + 死亡)   = 16 条
    音频/       指令_前进 / 指令_进攻 / 指令_撤退 /
                提示_金币不足 / 提示_人口已满 / 提示_建造完成 = 6 条

用法：
    python 工具/音频/合成语音_v2.py            # 全部
    python 工具/音频/合成语音_v2.py --only barks
"""

import argparse
import os
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

SR = 48000
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "音频"
VOICE_DIR = OUT / "语音"

LINES = {
    "农民": {"应答1": ("是，大人。", 0), "应答2": ("我这就去。", 1),
             "应答3": ("干活了。", 0), "死亡": ("啊——", -2)},
    "步兵": {"应答1": ("是，长官！", 0), "应答2": ("步兵就位！", 0),
             "应答3": ("为了联盟！", 1), "死亡": ("呃啊——", -2)},
    "弓箭手": {"应答1": ("弓箭手就绪。", 0), "应答2": ("目标锁定。", 0),
               "应答3": ("箭在弦上。", 0), "死亡": ("唔——", -2)},
    "法师": {"应答1": ("魔法听候差遣。", -1), "应答2": ("元素听我号令。", -1),
             "应答3": ("如你所愿。", 0), "死亡": ("我的法力……", -2)},
}

COMMANDS = {
    "指令_前进": ("前进！", 1),
    "指令_进攻": ("进攻！", 1),
    "指令_撤退": ("撤退！", 1),
    "提示_金币不足": ("金币不足。", 0),
    "提示_人口已满": ("人口已满。", 0),
    "提示_建造完成": ("建造完成。", 0),
}

# (降调比, 失真, 胸腔, 混响)
TIMBRE = {
    "农民": (0.88, 1.35, 0.26, 0.09),
    "步兵": (0.80, 1.95, 0.46, 0.12),
    "弓箭手": (0.85, 1.55, 0.30, 0.10),
    "法师": (0.82, 1.75, 0.34, 0.18),
}
CMD_TIMBRE = (0.81, 1.80, 0.42, 0.15)


# ---------------------------------------------------------------------------
# PowerShell TTS
# ---------------------------------------------------------------------------

PS_HEAD = r"""Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
try { $s.SelectVoice('Microsoft Huihui Desktop') } catch { }
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(48000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$items = @(
"""

PS_ITEM = """  @{ f = '__PATH__'; t = '__TEXT__'; r = __RATE__ }"""

PS_TAIL = r""")
foreach ($it in $items) {
  $s.Rate = [int]$it.r
  $s.SetOutputToWaveFile([string]$it.f, $fmt)
  $s.Speak([string]$it.t)
  $s.SetOutputToNull()
  Write-Output ("OK " + [string]$it.f)
}
"""


def synth_all(items, tmpdir):
    """items: [(out_wav_path, text, rate)]；一次性交给 PowerShell 批量合成。"""
    ps1 = Path(tmpdir) / "tts.ps1"
    rows = []
    for path, text, rate in items:
        rows.append(PS_ITEM.replace("__PATH__", str(path).replace("'", "''"))
                    .replace("__TEXT__", text.replace("'", "''"))
                    .replace("__RATE__", str(rate)))
    body = [PS_HEAD, ",\n".join(rows), "\n", PS_TAIL]
    ps1.write_text("".join(body), encoding="utf-8-sig")
    r = subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", str(ps1)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
        raise SystemExit("SAPI 合成失败（返回 %d）" % r.returncode)
    return r


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        n = w.getnframes()
        sr = w.getframerate()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        raw = w.readframes(n)
    if sw == 2:
        x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    elif sw == 4:
        x = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2147483648.0
    else:
        x = (np.frombuffer(raw, dtype=np.uint8).astype(np.float64) - 128.0) / 128.0
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return x, sr


def write_wav(path, x, sr=SR):
    x = np.clip(x, -1.0, 1.0)
    pcm = np.round(x * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


# ---------------------------------------------------------------------------
# DSP
# ---------------------------------------------------------------------------

def resample(x, ratio):
    """ratio<1 = 变慢 + 变低。线性插值（够用，后面还有失真和混响）。"""
    if abs(ratio - 1.0) < 1e-6:
        return x
    n_out = max(2, int(len(x) / ratio))
    t = np.linspace(0.0, len(x) - 1.001, n_out)
    return np.interp(t, np.arange(len(x)), x)


def biquad(x, b, a):
    b0, b1, b2 = b
    a0, a1, a2 = a
    b0, b1, b2 = b0 / a0, b1 / a0, b2 / a0
    a1, a2 = a1 / a0, a2 / a0
    y = np.empty_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(len(x)):
        xi = float(x[i])
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, xi
        y2, y1 = y1, yi
        y[i] = yi
    return y


def _q(kind, f, sr, q):
    f = min(max(f, 10.0), sr * 0.45)
    w0 = 2.0 * np.pi * f / sr
    c = np.cos(w0)
    alpha = np.sin(w0) / (2.0 * q)
    if kind == "hp":
        return ((1 + c) / 2, -(1 + c), (1 + c) / 2), (1 + alpha, -2 * c, 1 - alpha)
    if kind == "lp":
        return ((1 - c) / 2, 1 - c, (1 - c) / 2), (1 + alpha, -2 * c, 1 - alpha)
    return (alpha, 0.0, -alpha), (1 + alpha, -2 * c, 1 - alpha)


def hp(x, f, sr, q=0.707):
    b, a = _q("hp", f, sr, q)
    return biquad(x, b, a)


def lp(x, f, sr, q=0.707):
    b, a = _q("lp", f, sr, q)
    return biquad(x, b, a)


def peak(x, f, sr, gain_db, q=1.0):
    A = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * np.pi * f / sr
    alpha = np.sin(w0) / (2.0 * q)
    c = np.cos(w0)
    b = (1 + alpha * A, -2 * c, 1 - alpha * A)
    a = (1 + alpha / A, -2 * c, 1 - alpha / A)
    return biquad(x, b, a)


def convolve_fft(x, ir):
    n = len(x) + len(ir) - 1
    N = 1 << (n - 1).bit_length()
    y = np.fft.irfft(np.fft.rfft(x, N) * np.fft.rfft(ir, N), N)
    return y[: len(x)]


def reverb(x, sr, wet=0.12, decay=0.34, seed=7):
    n = int(sr * decay * 2.0)
    rng = np.random.default_rng(seed)
    ir = rng.uniform(-1, 1, n) * np.exp(-np.linspace(0, 7.0, n))
    ir = lp(ir, 3800.0, sr) if n < 100000 else ir
    for dly, g in ((0.011, 0.55), (0.019, 0.40), (0.031, 0.28), (0.047, 0.18)):
        i = int(dly * sr)
        if i < n:
            ir[i] += g
    ir /= max(1e-9, np.max(np.abs(ir)))
    y = convolve_fft(x, ir)
    y = y / max(1e-9, np.max(np.abs(y))) * max(1e-9, np.max(np.abs(x)))
    return x * (1.0 - wet) + y * wet


def trim_silence(x, sr, thresh_db=-42.0, keep=0.030):
    th = 10.0 ** (thresh_db / 20.0)
    idx = np.where(np.abs(x) > th)[0]
    if len(idx) == 0:
        return x
    k = int(sr * keep)
    a = max(0, int(idx[0]) - k)
    b = min(len(x), int(idx[-1]) + k)
    return x[a:b]


def thicken(x, ratio=0.5, mix=0.22):
    low = resample(x, ratio)[: len(x)]
    if len(low) < len(x):
        low = np.pad(low, (0, len(x) - len(low)))
    return x + low * mix


def process(x, sr, timbre):
    ratio, drive, chest, wet = timbre
    x = trim_silence(x, sr)
    x = resample(x, ratio)
    sr2 = sr / ratio
    x = thicken(x, 0.5, 0.22)
    x = x - float(np.mean(x))
    x = hp(x, 85.0, sr2)
    x = peak(x, 125.0, sr2, 3.2 * (chest + 0.4), q=0.9)
    x = peak(x, 3200.0, sr2, -2.4, q=1.1)
    x = np.tanh(x * drive) / np.tanh(drive)
    x = reverb(x, sr2, wet=wet, decay=0.34, seed=int(ratio * 1000) % 97 + 1)
    n = int(sr2 * 0.012)
    if len(x) > 2 * n:
        x[:n] *= np.linspace(0.0, 1.0, n)
        x[-n:] *= np.linspace(1.0, 0.0, n)
    m = float(np.max(np.abs(x)))
    if m > 1e-9:
        x = x * (10.0 ** (-8.0 / 20.0) / m)
    if abs(sr2 - SR) > 1.0:
        x = resample(x, sr2 / float(SR))
    return x


def report(path, x):
    m = float(np.max(np.abs(x))) if len(x) else 0.0
    r = float(np.sqrt(np.mean(x * x))) if len(x) else 0.0
    print("[语音] %-22s %5.2fs  peak %5.1f dBFS  rms %5.1f dBFS  %5.0f KB" % (
        Path(path).name, len(x) / float(SR),
        20.0 * np.log10(max(m, 1e-9)), 20.0 * np.log10(max(r, 1e-9)),
        Path(path).stat().st_size / 1024.0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["voices", "barks"], default=None)
    args = ap.parse_args()
    VOICE_DIR.mkdir(parents=True, exist_ok=True)

    jobs = []          # (final_path, timbre, label)
    if args.only in (None, "voices"):
        for group, lines in LINES.items():
            for tag, (text, rate) in lines.items():
                jobs.append((VOICE_DIR / ("%s_%s.wav" % (group, tag)), TIMBRE[group], text, rate))
    if args.only in (None, "barks"):
        for name, (text, rate) in COMMANDS.items():
            jobs.append((OUT / ("%s.wav" % name), CMD_TIMBRE, text, rate))

    with tempfile.TemporaryDirectory() as td:
        items = []
        for i, (dst, _tb, text, rate) in enumerate(jobs):
            items.append((Path(td) / ("raw_%02d.wav" % i), text, rate))
        print("[TTS] 合成 %d 条（SAPI 48kHz）…" % len(items))
        synth_all(items, td)
        for i, (dst, tb, text, _rate) in enumerate(jobs):
            src = Path(td) / ("raw_%02d.wav" % i)
            x, sr = read_wav(src)
            y = process(x, sr, tb)
            write_wav(dst, y, SR)
            report(dst, y)

    print("完成 →", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
