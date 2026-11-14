# Views/screens —— 全屏画面（新代码）

- 职责：整屏画面的装配（标题 / 大厅 / 结算 / 设置），只读 Model 状态、只做绘制与输入。
- 不属于这里：3D 世界表现（`Views/world/`）、HUD 组件（`Views/hud/`）、玩法规则（`Model/`）。
- 硬约定：**不许写死文案**（走 `I18n.t`），**不许直接改 Model 之外的全局状态**。
- 截图：新画面在 `Content/data/screens.json` 里登记一行，`run-game --shot <名字> <png>` 就能跑。

当前还没有新画面；现有主场景在 `Views/scenes/主场景.tscn`，属于迁移期资产。
