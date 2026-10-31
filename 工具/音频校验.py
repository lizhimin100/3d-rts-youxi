#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""音频验收（v3）：按 代码/音频/音效管理.gd 的 SPEC 反查素材是否齐全、规格是否达标。

检查项
  1. SPEC 里登记的每个 id 都有对应 WAV（缺一个就报错，防止改名后静默无声）
  2. 语音表 4 组 ×（应答1..3 + 死亡）+ 6 条口令/提示 都在
  3. 采样率统一 48 kHz；BGM 必须立体声，其余单声道
  4. BGM 时长 60~90s；循环接缝只**记录**（源文件不要求无缝：播放端
     代码/音频/音效管理.gd 的 _make_seamless_loop 会在载入时做 0.35s 等功率
     交叉淡化，循环点两侧的样本变成原文件里相邻的样本）。只拦明显坏的（> 12×）
  5. 任何文件不得削顶（峰值 > -0.1 dBFS 视为失败）

用法：
    python 工具/音频校验.py
    python 工具/音频校验.py --verbose
"""

import argparse
import re
import sys
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
AUDIO = ROOT / "音频"
SFX_GD = ROOT / "代码" / "音频" / "音效管理.gd"
VOICE_GD = ROOT / "代码" / "音频" / "语音表.gd"

SR_EXPECT = 48000
BGM_MIN, BGM_MAX = 60.0, 90.0
CLIP_DB = -0.1
## 源文件接缝的"明显坏了"阈值。无缝是播放端做的，所以这里只拦严重不连续；
## 正常源文件的 seam 会在 verbose 里打出来（当前 经营 0.6× / 会战 2.5×）。
SEAM_MAX = 12.0


def read(path):
    with wave.open(str(path), "rb") as w:
        ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if sw != 2:
        raise SystemExit("只支持 16bit:%s" % path)
    x = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    if ch > 1:
        x = x.reshape(-1, ch)
    return x, sr, ch


def db(v):
    return 20.0 * np.log10(v) if v > 1e-12 else -140.0


def spec_ids():
    txt = SFX_GD.read_text(encoding="utf-8")
    return re.findall(r'"([^"]+)":\s*\{"bus"', txt)


def voice_groups():
    txt = VOICE_GD.read_text(encoding="utf-8")
    block = txt.split("const GROUPS := {", 1)[1].split("}", 1)[0]
    return re.findall(r'"([^"]+)":\s*"([^"]+)"', block)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    fails = []
    counter = [0]
    ids = spec_ids()
    bgms = ["bgm_经营", "bgm_会战"]
    voices = ["%s_应答%d" % (g, i) for _uid, g in voice_groups() for i in (1, 2, 3)]
    voices += ["%s_死亡" % g for _uid, g in voice_groups()]
    barks = ["指令_前进", "指令_进攻", "指令_撤退",
             "提示_金币不足", "提示_人口已满", "提示_建造完成"]

    print("SPEC 登记 %d 条音效 / %d 首 BGM / %d 条单位语音 / %d 条口令"
          % (len(ids), len(bgms), len(voices), len(barks)))

    def check(name, is_bgm=False, is_voice=False):
        path = (AUDIO / "语音" / (name + ".wav")) if is_voice else (AUDIO / (name + ".wav"))
        if not path.exists():
            fails.append("缺文件：%s" % path.relative_to(ROOT))
            return
        counter[0] += 1
        x, sr, ch = read(path)
        mono = x.mean(axis=1) if ch > 1 else x
        peak = db(float(np.max(np.abs(x))))
        rms = db(float(np.sqrt(np.mean(mono * mono))))
        dur = len(mono) / sr
        tag = "OK "
        if sr != SR_EXPECT:
            fails.append("%s 采样率 %d（应为 %d）" % (name, sr, SR_EXPECT))
            tag = "BAD"
        if is_bgm and ch != 2:
            fails.append("%s 不是立体声" % name)
            tag = "BAD"
        if not is_bgm and ch != 1:
            fails.append("%s 应为单声道" % name)
            tag = "BAD"
        if peak > CLIP_DB:
            fails.append("%s 削顶 %.1f dBFS" % (name, peak))
            tag = "BAD"
        seam = ""
        if is_bgm:
            if not (BGM_MIN <= dur <= BGM_MAX):
                fails.append("%s 时长 %.1fs 不在 %.0f~%.0f" % (name, dur, BGM_MIN, BGM_MAX))
                tag = "BAD"
            d = np.abs(np.diff(mono))
            typ = float(np.median(d))
            ratio = float(abs(mono[0] - mono[-1])) / typ if typ > 1e-12 else 0.0
            seam = "  seam %.1fx" % ratio
            if ratio >= SEAM_MAX:
                fails.append("%s 循环接缝 %.2fx 过大" % (name, ratio))
                tag = "BAD"
        if args.verbose or tag == "BAD":
            print("  [%s] %-22s %5.2fs %2dch %dHz  peak %6.1f  rms %6.1f%s"
                  % (tag, name, dur, ch, sr, peak, rms, seam))

    seen = set()
    for i in ids:
        if i not in seen:
            seen.add(i)
            check(i)
    for b in bgms:
        check(b, is_bgm=True)
    for v in voices:
        if v not in seen:
            seen.add(v)
            check(v, is_voice=True)
    for b in barks:
        if b not in seen:
            seen.add(b)
            check(b)

    print()
    if fails:
        print("结果：失败（%d 项）" % len(fails))
        for f in fails:
            print("  -", f)
        return 1
    print("结果：通过（%d 个文件全部达标）" % counter[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
