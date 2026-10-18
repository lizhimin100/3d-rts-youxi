#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""音频校验：逐个 WAV 输出 时长 / 峰值 dBFS / RMS dBFS，并做规格核对 + 改前改后对比。

用法：
    python 工具/音频校验.py
    python 工具/音频校验.py --only 界面        # 只看名字里带"界面"的
    python 工具/音频校验.py --compare          # 只打关键对比段

判据来自任务书：
    点选  -22 ~ -18 dBFS     移动  -16 ~ -14 dBFS
    语音  -8 dBFS（±1）       应答  0.4 ~ 0.9s
    BGM   30 ~ 60s
"""

import argparse
import array
import math
import re
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUDIO = ROOT / "音频"
BUS_LAYOUT = AUDIO / "default_bus_layout.tres"

# 播放端参数（与 代码/音频/音效管理.gd 保持一致）
UI_MAKEUP_DB = 6.0
OLD_UI_CUE_DB = -13.0        # 改前：界面_点击 在 _on_order 里的 volume_db
OLD_MASTER_DB = 0.0


def read_wav(path: Path):
    with wave.open(str(path), "rb") as w:
        ch = w.getnchannels()
        sw = w.getsampwidth()
        sr = w.getframerate()
        n = w.getnframes()
        raw = w.readframes(n)
    if sw != 2:
        raise ValueError("只支持 16bit PCM：%s（%d bit）" % (path.name, sw * 8))
    data = array.array("h")
    data.frombytes(raw)
    if sys.byteorder == "big":
        data.byteswap()
    peak = 0
    s = 0
    for v in data:
        a = -v if v < 0 else v
        if a > peak:
            peak = a
        s += v * v
    frames = n
    peak_db = 20.0 * math.log10(peak / 32768.0) if peak > 0 else -120.0
    rms = math.sqrt(s / max(1, len(data))) / 32768.0
    rms_db = 20.0 * math.log10(rms) if rms > 1e-9 else -120.0
    return {
        "path": path,
        "ch": ch,
        "sr": sr,
        "frames": frames,
        "dur": frames / float(sr) if sr else 0.0,
        "peak_db": peak_db,
        "rms_db": rms_db,
        "kb": path.stat().st_size / 1024.0,
    }


def bus_levels():
    """从 default_bus_layout.tres 里读总线电平（按名字）。"""
    out = {"Master": 0.0}
    if not BUS_LAYOUT.exists():
        return out
    txt = BUS_LAYOUT.read_text(encoding="utf-8")
    names = dict(re.findall(r'bus/(\d+)/name = &"([^"]+)"', txt))
    vols = dict(re.findall(r"bus/(\d+)/volume_db = ([-0-9.]+)", txt))
    for idx, name in names.items():
        out[name] = float(vols.get(idx, 0.0))
    return out


def fmt(x: float, w: int = 6) -> str:
    return ("%*.1f" % (w, x))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--compare", action="store_true")
    args = ap.parse_args()

    if not AUDIO.exists():
        print("找不到音频目录：", AUDIO)
        return 1

    files = sorted(AUDIO.rglob("*.wav"), key=lambda p: (str(p.parent), p.name))
    if args.only:
        files = [p for p in files if args.only in str(p.relative_to(AUDIO))]
    if not files:
        print("没有匹配的 wav")
        return 1

    buses = bus_levels()
    print("总线（来自 default_bus_layout.tres）：", "  ".join(
        "%s %+.1f dB" % (k, v) for k, v in buses.items()))
    print("")
    print("%-26s %7s %8s %9s %9s %6s %5s" % ("文件", "时长s", "峰值dBFS", "RMS dBFS", "采样率", "声道", "KB"))
    print("-" * 78)
    infos = []
    for p in files:
        try:
            info = read_wav(p)
        except Exception as e:  # noqa: BLE001
            print("%-26s 读取失败：%s" % (p.name, e))
            continue
        infos.append(info)
        print("%-26s %7.3f %8.1f %9.1f %9d %6d %5.1f" % (
            p.relative_to(AUDIO).as_posix(), info["dur"], info["peak_db"],
            info["rms_db"], info["sr"], info["ch"], info["kb"]))

    # ---- 规格核对 ----
    def find(name):
        for i in infos:
            if i["path"].name == name:
                return i
        return None

    checks = []
    click = find("界面_点选.wav")
    if click:
        checks.append(("点选峰值 -22~-18", -22.0 <= click["peak_db"] <= -18.0,
                       "%.1f dBFS" % click["peak_db"]))
    move = find("指令_移动.wav")
    if move:
        checks.append(("移动峰值 -16~-14", -16.0 <= move["peak_db"] <= -14.0,
                       "%.1f dBFS" % move["peak_db"]))
    voice_files = [i for i in infos if i["path"].parent.name == "语音"]
    voice_bad = [i["path"].name for i in voice_files if abs(i["peak_db"] + 8.0) > 1.0]
    checks.append(("语音峰值 -8±1", not voice_bad, "全部通过" if not voice_bad else ",".join(voice_bad)))
    resp_bad = [i["path"].name for i in voice_files
                if "_应答" in i["path"].name and not (0.4 <= i["dur"] <= 0.9)]
    checks.append(("应答时长 0.4~0.9s", not resp_bad, "全部通过" if not resp_bad else ",".join(resp_bad)))
    bgm_bad = [i["path"].name for i in infos
               if i["path"].name.startswith("bgm_") and not (30.0 <= i["dur"] <= 60.0)]
    checks.append(("BGM 时长 30~60s", not bgm_bad, "全部通过" if not bgm_bad else ",".join(bgm_bad)))

    print("")
    print("规格核对")
    print("-" * 78)
    for name, ok, detail in checks:
        print("  %s %-20s %s" % ("✓" if ok else "✗", name, detail))

    # ---- 改前 vs 改后 ----
    old = find("界面_点击.wav")
    print("")
    print("关键对比：点选 / 移动（有效电平 = 文件峰值 + 播放增益 + 总线）")
    print("-" * 78)
    print("%-10s %-14s %7s %9s %10s %11s" % ("", "文件", "时长s", "峰值dBFS", "播放增益", "有效峰值"))
    muted = 0.0
    if old:
        eff = old["peak_db"] + OLD_UI_CUE_DB + muted
        print("%-10s %-14s %7.3f %9.1f %10s %11.1f" % (
            "改前 点选", old["path"].name, old["dur"], old["peak_db"], "%+.0f dB" % OLD_UI_CUE_DB, eff))
        print("%-10s %-14s %7.3f %9.1f %10s %11.1f" % (
            "改前 移动", old["path"].name + "*", old["dur"], old["peak_db"], "%+.0f dB" % OLD_UI_CUE_DB, eff))
    ui_db = buses.get("UI", -16.0)
    if click:
        eff = click["peak_db"] + ui_db + UI_MAKEUP_DB
        print("%-10s %-14s %7.3f %9.1f %10s %11.1f" % (
            "改后 点选", click["path"].name, click["dur"], click["peak_db"],
            "%+.0f%+.0f" % (ui_db, UI_MAKEUP_DB), eff))
    if move:
        eff = move["peak_db"] + ui_db + UI_MAKEUP_DB
        print("%-10s %-14s %7.3f %9.1f %10s %11.1f" % (
            "改后 移动", move["path"].name, move["dur"], move["peak_db"],
            "%+.0f%+.0f" % (ui_db, UI_MAKEUP_DB), eff))
    print("")
    print("* 改前没有独立的移动音，右键移动复用 界面_点击。")
    print("")
    print("共 %d 个 wav。" % len(infos))
    return 0


if __name__ == "__main__":
    sys.exit(main())
