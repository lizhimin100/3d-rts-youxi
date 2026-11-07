extends RefCounted
## **编辑器按钮表（唯一的工具栏定义）**
##
## 2026-11-07 建立。起因：玩家要求「地图编辑器的图标按钮按统一逻辑重排，
## 并且**留下接口**，方便后续 Agent 继续打磨」。
##
## 于是工具栏不再一串散文式的 `_qbtn(...)` 调用，而是这张表：
##
## ```
##   GROUPS = [ { name: 分组名, items: [ {id, text, icon, tip, kind?}, … ] }, … ]
## ```
##
## 加/改一个工具栏按钮 = **只改这张表**：
##   · `id`   —— 必须和 `主屏.gd::_on_menu(id)` 的 case 对上；
##   · `icon` —— `美术/图标/<icon>.svg`（找不到会静默退回纯文字）；
##   · `kind` —— `normal` / `primary` / `danger`（删除这类不可逆操作）；
##   · `text` —— **两个字**。长了就把说明挪进 `tip`。
##
## 表是**数据**，主屏只负责摆：改顺序、改分组、加分隔线都不用碰 `_build_quick_bar`。

const GROUPS: Array = [
	{"name": "文件", "items": [
		{"id": 1, "text": "新建", "icon": "file_new", "tip": "新建地图（先选尺寸 / 人数 / 种子）"},
		{"id": 2, "text": "打开", "icon": "file_open", "tip": "打开 .tres / .json（Ctrl+O）"},
		# 保存是这条工具带上唯一的"主操作"：整条带子里只有一个按钮是金底，
		# 玩家（和 Agent）一眼就知道"这个和别的不是一回事"。
		{"id": 3, "text": "保存", "icon": "file_save", "tip": "保存到当前文件（Ctrl+S）", "kind": "primary"},
		{"id": 4, "text": "另存", "icon": "file_save_as", "tip": "另存为…（换个路径/名字）"},
	]},
	{"name": "编辑", "items": [
		{"id": 11, "text": "撤销", "icon": "undo", "tip": "撤销上一步（Ctrl+Z）"},
		{"id": 12, "text": "重做", "icon": "redo", "tip": "重做（Ctrl+Y）"},
		{"id": 17, "text": "历史", "icon": "history", "tip": "打开编辑历史：点一条直接跳回那一步"},
	]},
	{"name": "检查", "items": [
		{"id": 31, "text": "校验", "icon": "check", "tip": "跑 MapValidator：出生点高差 / 占格 / 边界"},
		{"id": 5, "text": "试玩", "icon": "play", "tip": "保存临时地图并启动游戏（不阻塞编辑器）"},
	]},
	{"name": "数值", "items": [
		{"id": 41, "text": "单位卡", "icon": "card", "tip": "编辑 代码/配置/卡/单位/ 下的数值卡（保存即生效，进图前不用重启）"},
		{"id": 42, "text": "建筑卡", "icon": "card", "tip": "编辑 代码/配置/卡/建筑/ 下的数值卡"},
		{"id": 43, "text": "帮助", "icon": "help", "tip": "功能索引：每个按钮做什么、在哪个文件实现"},
	]},
	{"name": "视角", "items": [
		{"id": 21, "text": "俯视", "icon": "view_top", "tip": "俯视（看布局）"},
		{"id": 22, "text": "斜视", "icon": "view_iso", "tip": "等轴斜视（默认工作视角）"},
		{"id": 23, "text": "复位", "icon": "view_reset", "tip": "镜头回到地图中心（F 对准选中对象）"},
	]},
]

## 左侧「层」栏的按钮（顺序即从上到下）。
## `layer` 是**逻辑键**（不是显示名）：主屏用它映射到 MODE_*/MapObject.Category，
## 这样改文案/换图标不影响行为，改行为也只需要动主屏的 match。
const LAYERS: Array = [
	{"layer": "terrain", "text": "地形", "icon": "terrain", "tip": "切到「地形」层：刷地表、抬降高度"},
	{"layer": "unit", "text": "单位", "icon": "sword", "tip": "切到「对象·单位」：摆兵、野怪"},
	{"layer": "building", "text": "建筑", "icon": "house", "tip": "切到「对象·建筑」：摆房子"},
	{"layer": "doodad", "text": "装饰", "icon": "doodad", "tip": "切到「对象·装饰」：树、石头、杂物"},
	{"layer": "resource", "text": "资源", "icon": "mine", "tip": "切到「对象·资源」：金矿、树林"},
	{"layer": "region", "text": "区域", "icon": "region", "tip": "切到「区域」层：画出生/进攻/镜头区域"},
]


## 按 id 找一条（工具栏/菜单共用；找不到返回空）
static func find(id: int) -> Dictionary:
	for g in GROUPS:
		for it in (g["items"] as Array):
			if int(it["id"]) == id:
				return it
	return {}


## 拍平成一个数组（给 `_on_menu` 校验 id、给帮助窗列清单用）
static func flat() -> Array:
	var out: Array = []
	for g in GROUPS:
		for it in (g["items"] as Array):
			var d: Dictionary = (it as Dictionary).duplicate()
			d["group"] = String(g["name"])
			out.append(d)
	return out
