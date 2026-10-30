extends SceneTree
## **把四季演示图存成地图文件**（想在地图编辑器里打开看时用这个）
##
##   godot --headless --path . --script 工具/生成四季演示图.gd
##   → res://地图/_四季演示.tres
##
## 只想在游戏里扫一眼的话，不用这个脚本：
##   godot --path . -- --demo-tree
##
## 建图逻辑在 代码/测试/树品种演示.gd 里，两处共用一份。

const OUT := "res://地图/_四季演示.tres"


func _init() -> void:
	var demo: Script = load("res://代码/测试/树品种演示.gd") as Script
	if demo == null:
		push_error("[四季演示] 读不到 代码/测试/树品种演示.gd")
		quit(1)
		return
	var m: MapDef = demo.call("make_map", 5.0, true, 128) as MapDef
	var err: int = ResourceSaver.save(m, OUT)
	print("[四季演示] 写入 %s err=%d，对象 %d 个" % [OUT, err, m.objects.size()])
	quit(0 if err == OK else 1)
