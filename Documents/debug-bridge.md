# 调试接口（127.0.0.1 HTTP）

> 状态：现行（2026-11-14）。
> 规矩：**禁止用截屏、点窗口、发按键的方式操作游戏**；要什么能力就在接口里补。

## 1. 什么时候开

- 只在**调试构建**（`OS.is_debug_build()`）且**非发行**（`App.release == false`）时可用。
- 有窗口运行时默认启动；无头运行默认**不**启动（避免并行测试抢端口），显式传 `--debug-bridge` 才开。
- 端口默认 `18777`，`--debug-port=NNNN` 可改；**只绑定 `127.0.0.1`**，外部机器连不上。
- 发行构建：`Engine/debug/` 整目录被 `Tools/build/release_exclude.txt` 排除，且 `App.release` 双重门禁。

## 2. 端点

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/health` | pid / boot_id / 版本 / 是否测试 / 运行时长 / 动作列表 |
| GET | `/state` | 游戏状态快照（阶段、时间、阵营资源/兵力、选中数、节点数） |
| GET | `/screenshot?path=…` | 存一张 PNG，返回路径（无头会 409） |
| POST | `/action` | `{"name":"…","args":{…}}` 执行动作 |
| POST | `/quit` | 退出游戏 |
| GET | `/help` | 端点与动作清单 |

### 动作（/action）

| name | args | 说明 |
|---|---|---|
| `select_all` | `{}` | 选中玩家全部单位（走真实选择系统） |
| `click_ui` | `{"name":"指令_建造"}` | 用真实输入事件点一个 Control（不是直接调信号） |
| `camera_focus` | `{"x":0,"z":0}` | 镜头跳到世界坐标 |
| `set_speed` | `{"value":3.0}` | `Engine.time_scale`（0~32） |
| `spawn` | `{"id":"footman","count":2,"x":0,"z":0}` | 走 `Game.spawn_unit` |
| `screenshot` | `{"path":"user://…png"}` | 与 GET 等价 |
| `tune` | `{"file":"res://Content/data/game.json","pointer":"props.start_gold","value":700}` | 只允许写源目录 JSON，写后回读 |
| `quit` | `{}` | 退出 |
| `boot_report` | `{}` | 启动横幅的字典版 |

## 3. 示例（PowerShell）

```powershell
$h = Invoke-RestMethod http://127.0.0.1:18777/health
$s = Invoke-RestMethod http://127.0.0.1:18777/state
Invoke-RestMethod http://127.0.0.1:18777/action -Method Post -ContentType 'application/json' `
  -Body '{"name":"select_all","args":{}}'
Invoke-RestMethod http://127.0.0.1:18777/quit -Method Post -ContentType 'application/json' -Body '{}'
```

## 4. 新进程校验（硬规定）

**重启游戏后先确认连上的是新进程**：

1. 记录重启前的 `pid + boot_id`；
2. 等新进程起来后 `GET /health`；
3. 两者任一相同 → 连的是旧进程，继续等/杀掉旧进程，不要下结论。

`Tools/qa/bridge_probe.ps1` 自动化了这一步（启动 → health/state/action → quit → 再启动对比 boot_id）。

## 5. 排查

- 连不上：先看 `/health` 的端口是否被占用；无头运行需要显式 `--debug-bridge`。
- 请求挂住：确认 `Engine/debug/debug_bridge.gd` 的 `_pump_clients` 没有丢 CONNECTING 状态的连接。
- 截图 409：无头渲染器没有画面，截图必须在有窗口的模式下跑（`run-game --shot` 会自动处理）。
- 端口冲突：`--debug-port=18778` 换一个；并行跑两个游戏实例时不要共用端口。
