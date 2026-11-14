# 程序化音效（AudioStreamGenerator）

> 2026-11-14 已拍板：**音效全部改为运行时合成，不再依赖 wav/ogg 文件**（音乐仍用玩家的 ogg）。
> **同日第二次拍板（当前状态）**：删掉全部合成音效，只留一声 `ui_ding`（UI 更新时间"叮"）。
> 于是合成库只剩 **1 个预设**；`Content/audio/` 下 0 个 wav。
> 接入点：`Game/audio/音效管理.gd` 的 `ding()`（选中 / 下令 / 播报 / 建造完成）→
> `AudioSvc.play_synth("ui_ding")` → `Engine/audio/synth_player.gd`。

## 1. 文件

| 文件 | 作用 |
|---|---|
| `Engine/audio/synth_bank.gd` | 合成库（RefCounted，全静态函数）：**1 个预设** `ui_ding` → 44.1kHz / 16-bit / 单声道样本 |
| `Engine/audio/synth_player.gd` | 播放器（Node）：`AudioStreamGenerator` + 6 个 `AudioStreamPlayer` 池 |
| `Tests/checks/synth_probe.gd` | 无窗口自检（`extends SceneTree`） |
| `Documents/audio-synth.md` | 本文 |

## 2. API

### SynthBank（`preload("res://Engine/audio/synth_bank.gd")`）

```gdscript
const SynthBank := preload("res://Engine/audio/synth_bank.gd")

SynthBank.SAMPLE_RATE                 # 44100
SynthBank.keys()                      # Array[String]，当前只有 ["ui_ding"]
SynthBank.has(key)                    # bool
SynthBank.spec(key)                   # Dictionary（参数副本，改它不影响内置表）
SynthBank.duration(key)               # float，秒
SynthBank.render(key)                 # PackedFloat32Array，单声道 [-1, 1]；未知 key → 空数组 + 警告
SynthBank.to_pcm16(samples)           # PackedByteArray，16-bit 小端单声道
SynthBank.to_frames(samples)          # PackedVector2Array，给 AudioStreamGenerator 的立体声帧
SynthBank.describe()                  # key -> {duration, peak, wave, attack, decay, noise, samples, layers}
```

约定：**纯函数**（不进树、不读文件、不碰自动加载）；噪声用固定 seed，同一 key 每次结果逐样本一致；
整段做 3ms 淡入 + 12ms 淡出，再按目标峰值归一化 —— 首尾样本恒为 0，不会爆音/削波。

### SynthPlayer（`preload("res://Engine/audio/synth_player.gd")`，Node）

```gdscript
const SynthPlayer := preload("res://Engine/audio/synth_player.gd")
var synth := SynthPlayer.new()
add_child(synth)

synth.play("ui_click")                 # bool；volume_db 默认 0，pitch_scale 默认 1
synth.play("hit_metal", -6.0, 1.2)     # 变调会连带改变实际时长
synth.set_enabled(false)               # 关掉并停掉所有正在播的
synth.is_enabled()                     # bool（是否允许播放）
synth.stats()                          # Dictionary，见下
synth.stop_all()
synth.prewarm()                        # 可选：提前建池
```

`stats()` 字段：`enabled / pool_size(6) / active / played / dropped / stolen /
headless / driver / sample_rate / presets / bus / buffer_seconds`。

行为要点：

- 池 6 个槽，每槽一个 `AudioStreamGenerator`（`mix_rate=44100`，`buffer_length=1.0s`）；
- `play()` 时重新 `play()` 拿到新的 playback（旧缓冲自然丢弃），把整段 PCM 推进去；
  缓冲没一次性放下时由 `_process` 续推；
- 播完（`samples / 44100 / pitch_scale + 50ms`）自动 `stop()` 并回收槽位；
- 池满时抢最早的槽（`stolen` 计数），不新开节点；
- **无头**：Dummy 驱动下也能拿到 playback 并填缓冲（实测 `avail=65535`），只是听不见；
  拿不到 playback 时 `play()` 静默返回 `false`（`push_error` 一次都不会有）；
- 总线：有 `SFX` 走 `SFX`，没有就退回 `Master`。

## 3. 音效清单

| key | 时长 | 峰值 | 波形 | 频率滑动 | attack/decay | 噪声 | 层 | 用途 |
|---|---|---|---|---|---|---|---|---|
| `ui_click` | 0.070s | 0.65 | 正弦 | 1700→820 | 1ms / 20ms | 0.06 | 1 | 按钮点击 |
| `ui_open` | 0.220s | 0.75 | 正弦 | 380→880 | 6ms / 110ms | 0.02 | 1 | 面板/菜单打开 |
| `ui_error` | 0.300s | 0.70 | 方波 | 190→150 | 2ms / 90ms | 0.05 | 2 | 操作失败（双声） |
| `notify` | 0.400s | 0.80 | 正弦 | 880→872 | 3ms / 220ms | 0.01 | 2 | 提示（A5 + E6） |
| `build_start` | 0.420s | 0.80 | 锯齿 | 140→320 | 10ms / 350ms | 0.18 | 1 | 开始建造 |
| `build_done` | 0.600s | 0.80 | 正弦 | 523→526 | 4ms / 180ms | 0.02 | 4 | 建造完成（C5-E5-G5 + 低频） |
| `hit_flesh` | 0.180s | 0.80 | 正弦 | 130→55 | 1ms / 55ms | 0.55 | 1 | 命中肉体 |
| `hit_metal` | 0.260s | 0.75 | 方波 | 1450→1180 | 1ms / 75ms | 0.22 | 1 | 命中金属 |
| `arrow_shot` | 0.160s | 0.70 | 锯齿 | 1100→260 | 2ms / 45ms | 0.45 | 1 | 射箭 |
| `death` | 0.750s | 0.80 | 锯齿 | 190→45 | 5ms / 500ms | 0.20 | 2 | 单位死亡 |
| `level_up` | 0.780s | 0.80 | 正弦 | 523→530 | 4ms / 200ms | 0.01 | 5 | 升级（C5-E5-G5-C6 + 泛音） |
| `coin` | 0.340s | 0.75 | 正弦 | 988→1000 | 2ms / 90ms | 0.02 | 2 | 金币（B5 → E6） |

（峰值 = `describe()` 实测值，同时也是归一化目标。层数 >1 表示叠加了额外音层。）

## 4. 已接入游戏（2026-11-14）

- `AudioSvc` 的 `_ready` 建一个 `SynthPlayer`；`play_sfx(key)` **合成优先**，合成库没有的 key 才回落文件；新增 `play_synth(key, db, pitch)` 与 `synth_stats()`。
- `Game/audio/音效管理.gd` 的 `SYNTH_KEYS` 把 16 个游戏音效 id 映射到 12 个预设；`_play2d/_play3d` 在节流判定之后先试合成。
- 静音/测试模式：`AudioSvc.play_synth` 返回 **true**（"已接受"）但不真的发声，游戏侧节流/回落行为不变。
- 回落顺序：**合成 → 文件 → false**；音乐/语音仍走文件。

下面是最初的"3 行接入建议"，保留作历史参考（实际实现已包含它）：

```gdscript
var SynthPlayer := preload("res://Engine/audio/synth_player.gd")
_synth = SynthPlayer.new(); add_child(_synth)            # _ready()：建一次
if _synth != null and _synth.play(key, volume_db): return true   # play_sfx() 开头：合成优先
```

之后的回落顺序建议：**合成 → 文件 → false**。这样老 key 还能用 `Content/keys/assets.json` 里的文件，
新 key 直接走合成；`App.silent`/`--headless` 时 AudioSvc 已把 Master 静音，合成器照常推进、只是听不见。

## 5. 自检

```powershell
godot --headless --path . --script Tests/checks/synth_probe.gd
```

判据：末尾 `SYNTH PASS n/N` 且退出码 0；失败打印 `SYNTH FAIL ...` 并退出码 1。
覆盖 175 条断言：12 个 key 齐全 / 非空 / 时长 ∈ [0.05, 0.8] / 采样数与时长一致 /
无 NaN/Inf / 峰值 ≤ 1.0 且非静音 / 首尾单样本 = 0 + 首尾 8 样本已淡出 / `describe()` 自洽 /
16-bit PCM 长度与回读误差 / `AudioStreamGenerator` 真填一次缓冲 /
`play` 返回 true、未知 key 返回 false、池压测不超池且会抢占、`set_enabled` 生效、
播完自动回收（0.75s 的音效等 0.9s 后 `active == 0`）。

## 6. 限制

- **音色是"纯波形 + 包络"**：没有采样、混响、滤波（只有一阶低通给噪声），风格偏 8-bit/街机；
  要更"厚"需要加图层或换 `harmonics`/`noise` 参数，不改代码结构。
- **方波/锯齿没做 polyBLEP 抗混叠**：高频（如 `hit_metal` 1450Hz）会有混叠，当复古音色可接受。
- **单声道**：`to_frames()` 把单声道复制到左右；没有 3D 衰减/声像，需要空间感就用 `AudioStreamPlayer3D` 或自己做声像。
- **每次 play 现场合成**（最长 0.78s ≈ 34k 样本）：短音效开销可忽略，同一帧几十次触发建议自行加缓存
  （`render()` 结果可缓存，`PackedFloat32Array` 是值类型，取用时注意拷贝语义）。
- **buffer_length = 1.0s**：单个预设超过 1s 时分帧续推仍能播，但本模块的预设都 < 0.8s；
  要 loop 需要自己重填（本模块不做循环）。
- **注册表未更新**：按任务约束只新增了本模块 4 个文件；`Engine/pin.json` 与 `Content/manifest.json`
  还是旧的，`--check` 会报"未登记 audio/synth_bank.gd、audio/synth_player.gd、Tests/checks/synth_probe.gd"。
  维护者需要跑 `python Tools/gen/gen_engine_pin.py` 和 `python Tools/gen/gen_manifest.py`（会改生成文件，本次未动）。
- **未知 key**：`SynthBank.render()` 与 `SynthPlayer.play()` 都是 `push_warning` + 返回空/false，不报 error。
- 采样率固定 44100；改 `SAMPLE_RATE` 会连带改所有预设的样本数（时长不变）。
