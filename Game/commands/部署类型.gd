extends RefCounted
## **部署类型**（规划阶段给自己部队的战役级意图）—— 只有三种。
##
## 2026-11-20：旧的「战区指令」系统（给盟友 AI 发意图、F5–F8 四键、带 TTL 与
## 重新下发节流）随旧自由 AI 一起删除；这里只留**玩家部署**用的三个类型。
## 数值是历史值，`命令记录` 里按这些类型写 Order。

const ATTACK: int = 1
const DEFEND: int = 2
const CAPTURE: int = 3

## 类型 → ASCII 代码（界面文案走 Content/i18n/ui.csv 的 deploy.* 条目）
const NAMES: Dictionary = {
	ATTACK: "attack",
	DEFEND: "defend",
	CAPTURE: "capture",
}
