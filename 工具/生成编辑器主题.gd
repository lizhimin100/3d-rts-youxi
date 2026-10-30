extends SceneTree
## **设计令牌 → Godot Theme 资源**（一次性生成，不参与运行）。
##
## 跑法：
##   godot --headless --path . --script 工具/生成编辑器主题.gd
##
## 产物：res://addons/map_editor/编辑器主题.tres
## 产物是正经 Theme 资源（StyleBoxFlat / SystemFont / 类型变体都序列化在里面），
## 编辑器主屏与 Dock 直接 preload 挂载；token 改了重跑这一条即可。
##
## 为什么不让运行时代码 "顺手 new 一个 Theme"：
## 那样每次打开编辑器都要重新构造几十个 StyleBox，而且主题不是可见/可审的资源；
## 这里落成 .tres，改色/对稿都能直接在资源里看，符合"token 生成的是 Godot Theme"。

const SPEC_PATH := "res://代码/界面/界面规格.gd"
const OUT_PATH := "res://addons/map_editor/编辑器主题.tres"


func _init() -> void:
	var spec: Script = load(SPEC_PATH) as Script
	if spec == null:
		push_error("[编辑器主题] 加载设计令牌失败：" + SPEC_PATH)
		quit(1)
		return
	var th: Theme = spec.call("build_editor_theme") as Theme
	if th == null:
		push_error("[编辑器主题] build_editor_theme() 没返回 Theme")
		quit(1)
		return
	var err: int = ResourceSaver.save(th, OUT_PATH)
	if err != OK:
		push_error("[编辑器主题] 保存失败 err=%d → %s" % [err, OUT_PATH])
		quit(1)
		return
	print("[编辑器主题] 已生成 %s（default_font_size=%d）" % [OUT_PATH, th.default_font_size])
	quit(0)