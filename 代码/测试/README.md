# 代码/测试

> 状态：现行 · 完整清单见 `文档/索引/测试索引.md`（自动生成）

- **职责**：验收脚本与基准。**不是玩法代码**，不参与正式运行。
- **两种入口**（跑之前先分清，这是最常见的翻车点）：
  * `--script 代码/测试/xxx.gd`：**读不到 `Game` / `Cfg`**（autoload 还没注册）；
  * `--headless --path . -- --xxx-test`：主场景 `_mount_tests` 挂载，能读单例。
- **禁改**：不要把断言改成"恒真"来让它变绿；常红项要登记在 `文档/开发交接.md`。

## 常用命令

```text
godot --headless --path . --script 代码/测试/界面自检.gd          # UI 8 项
godot --headless --path . --script 代码/测试/建造自检.gd          # 建造 98 项
godot --headless --path . --script 代码/测试/寻路抖动自检.gd      # 28/3（常红）
godot --headless --fixed-fps 60 --path . -- --adjutant-test       # 副官 31/1
godot --headless --fixed-fps 60 --path . -- --war-test            # 战区指令 10/0
godot --headless --path . --quit-after 2000 -- --autotest         # 全流程
```

## 新增自检的规矩

1. 文件头必须写 `启用：` 一行（`工具/生成测试索引.py` 靠它提取命令）。
2. 结果打一行 `XXX {"结果":"通过/失败","通过":N,"检查":[...]}`，方便机器读。
3. 断言用 `_ok(name, cond, detail)`，detail 里放**数字**（"0.66m" 而不是"有点近"）。
4. 需要 `Game` 的，走主场景挂载 + `--xxx-test`，别用 `--script`。
