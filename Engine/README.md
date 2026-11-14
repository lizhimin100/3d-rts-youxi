# Engine/ —— 我们自己的引擎层（共享库）

> 这里的代码**不属于任何玩法**。游戏只调用它，不复制它。
> 与 Godot 的 `Engine` 单例无关，目录名只是沿用「引擎层」的叫法。

## 规矩（AGENTS.md 里也有，这里是给第一次进目录的人）

1. **不许出现玩法名词**：单位/建筑/技能/金币/木材/AI/副官都不能出现在这里。
2. **不许读游戏存档结构**：只认 `{schema_version, payload}` 外壳，具体 schema 由调用方注册。
3. **平台差异只在这里**：Steam / 手机 / 主机 / 无头，游戏代码里不许写平台判断。
4. **调试能力只在这里**：HTTP 接口、截图、调参写回，全部在 `Engine/debug/`。
5. 改这里的文件必须更新 `Engine/pin.json`（`python Tools/checks/gen_engine_pin.py` 或 `Tools/gen/gen_engine_pin.ps1`），
   否则 `run-game --check` 会报「引擎层被就地修改」。这是刻意的：共享库要能单独发版。

## 模块

| 目录 | 用途 | 自动加载 |
|---|---|---|
| `boot/` | 启动引导、测试模式默认值（静音/无焦点/隔离存档） | `App` |
| `i18n/` | 多语言（CSV → key 字典，缺 key 显式报错） | `I18n` |
| `save/` | 存档（槽位、原子写、版本迁移、测试隔离） | `SaveSvc` |
| `audio/` | 音频（总线、静音、按 key 播放） | `AudioSvc` |
| `dialogue/` | 对话运行时（数据驱动，不含 UI） | — |
| `platform/` | 平台接口（成就 / 云存档 / Steam / 手机 / 无头） | `Platform` |
| `debug/` | 调试接口（127.0.0.1 HTTP、截图、调参写回、调试面板） | `DbgBridge` |
| `util/` | JSON 文件、资源 key 表、日志 | `Keys` |

## 版本

见 `VERSION` 与 `pin.json`。**pin.json 记录每个文件的 sha256**，改动后必须重新生成；
`--check` 会发现「改了却没登记版本」。游戏仓库里不顺手改共享库 —— 改这里等于发一次共享库版本。
