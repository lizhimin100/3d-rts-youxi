# -*- coding: utf-8 -*-
r"""压缩BGM到OGG.py —— 把 6 首 BGM 的 WAV（77MB）换成 OGG（约 7MB），并**在离线阶段**把接缝接好。

## 为什么值得做

| | 现状（WAV） | 改后（OGG） |
|---|---|---|
| 仓库体积 | 77 MB | ≈ 7 MB |
| 运行时内存 | 每首 13~15MB PCM **常驻**，启动时还要复制一份做交叉淡化 | 流式读取，几乎不占静态内存 |
| 加载耗时 | 启动时对 13MB 数组做 3 万次采样混合 | 0（循环交给解码器） |

`_make_seamless_loop()` 那套"尾/头 0.35s 等功率交叉淡化"是**播放器在运行时**做的，
本质上是在弥补素材本身首尾不连续。改成离线做一次，运行时就不用再算了。

## 怎么做的（和运行时那套数学完全一致）

设原曲 L 帧、淡化 D = 0.35s：
```
新缓冲 = [混合头 D 帧] + [原曲 D..L-D)
混合头[i] = tail[L-D+i] * cos(t·π/2) + head[i] * sin(t·π/2)   t = i/(D-1)
```
于是新缓冲首帧 = 原曲 L-D 帧，末帧 = 原曲 L-D-1 帧 —— 循环点两侧是原文件里相邻的样本，
数学上无跳变。之后交给 OGG 的 `loop = true`。

## 用法

```powershell
pip install soundfile numpy        # 一次性（libsndfile 已打包在 wheel 里）
python 工具/音频/压缩BGM到OGG.py            # 全部转换
python 工具/音频/压缩BGM到OGG.py --keep-wav # 先留着 wav 对照听
```

输出：`音频/bgm_*.ogg`。转完由 `代码/音频/音效管理.gd` 优先读 ogg（读不到再退回 wav）。
"""

import argparse
import os
import sys

try:
    import numpy as np
    import soundfile as sf
except ImportError:
    print("需要 numpy + soundfile：pip install soundfile numpy")
    sys.exit(1)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AUDIO = os.path.join(ROOT, "音频")
FADE_SEC = 0.35


def seamless(x, sr):
    """等功率交叉淡化循环（和 音效管理._make_seamless_loop 同一套数学）。"""
    n = len(x)
    d = int(FADE_SEC * sr)
    if d < 64 or n < d * 4:
        return x
    head = x[:d].copy()
    tail = x[n - d:]
    t = np.linspace(0.0, 1.0, d, dtype=np.float32)[:, None]
    w_in = np.sin(t * np.pi * 0.5)
    w_out = np.cos(t * np.pi * 0.5)
    blend = tail * w_out + head * w_in
    return np.concatenate([blend, x[d:n - d]], axis=0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-wav", action="store_true", help="保留源 wav（默认转换成功后删除）")
    ap.add_argument("--quality", type=float, default=0.45, help="（保留参数，Vorbis 质量由编码器默认档决定）")
    args = ap.parse_args()

    total_in = total_out = 0
    targets = sorted(f for f in os.listdir(AUDIO)
                     if f.startswith("bgm") and f.lower().endswith(".wav"))
    if not targets:
        print("音频/ 下没有 bgm_*.wav（已经转过了？）")
        return
    for f in targets:
        src = os.path.join(AUDIO, f)
        dst = os.path.join(AUDIO, os.path.splitext(f)[0] + ".ogg")
        data, sr = sf.read(src, dtype="float32", always_2d=True)
        fixed = seamless(data, sr)
        # ★ 必须**分块写**：这个 libsndfile 的 Vorbis 编码器一次性喂 120 万帧
        #   （30 秒以上）会让进程直接消失（exit 127、无 traceback）。40k 帧一块稳定。
        with sf.SoundFile(dst, mode="w", samplerate=sr, channels=fixed.shape[1],
                          format="OGG", subtype="VORBIS") as out:
            for i in range(0, len(fixed), 40000):
                out.write(fixed[i:i + 40000])
        a, b = os.path.getsize(src), os.path.getsize(dst)
        total_in += a
        total_out += b
        print("  %-18s %6.2f MB → %5.2f MB  (%.1fs, %d Hz, %d ch)" % (
            f, a / 1048576, b / 1048576, len(fixed) / sr, sr, data.shape[1]))
        if not args.keep_wav:
            os.remove(src)
            imp = src + ".import"
            if os.path.exists(imp):
                os.remove(imp)
    print("合计 %.1f MB → %.1f MB（省 %.1f MB）" % (
        total_in / 1048576, total_out / 1048576, (total_in - total_out) / 1048576))


if __name__ == "__main__":
    main()
