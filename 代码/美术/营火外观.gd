class_name RtsCampfireVisual
extends RefCounted
## **营火外观**：一堆木柴 + 一盏会呼吸的暖光（玩家/AI 的夜间照明点）。
##
## 为什么复用 `美术/模型/营火.glb` 而不是新做模型：
##   野怪营地和玩家营火用的都是这一件，材质走同一套自然材质库（`自然_` 前缀），
##   营火出现在任何地方都长一个样 —— 美术口径统一，也省一次资产导入。
##
## 三条纪律：
##   1. 只拼现成资产（`ArtKit.build_model`，自带缓存 + 自然材质）；
##   2. **不缩放父节点**：部件的 scale 单独给，方便以后微调；
##   3. 灯必须有（`营火光.gd` 控制白天/夜晚）—— 这座建筑的**全部意义**就是夜里照亮。

const CAMPFIRE := "res://美术/模型/营火.glb"
const LIGHT_SCRIPT := preload("res://代码/系统/营火光.gd")


static func build(_def: UnitDef) -> Node3D:
	var root := Node3D.new()
	root.name = "营火模型"
	var fire: Node3D = ArtKit.build_model(CAMPFIRE, 1.0, Vector3(1.6, 1.2, 1.6))
	if fire != null:
		fire.name = "柴堆"
		# 营火.glb 自带一圈石头/木柴，抬 2cm 离开地形（和建筑同一套防 z-fighting 口径）
		fire.position = Vector3(0.0, 0.02, 0.0)
		fire.scale = Vector3.ONE * 1.35
		for c in fire.get_children():
			_set_shadow(c)
		root.add_child(fire)
	# 火苗的光：挂在柴堆中上部，别埋进地面（否则只照亮脚下一小块）
	var lamp := OmniLight3D.new()
	lamp.name = "火光"
	lamp.set_script(LIGHT_SCRIPT)
	lamp.position = Vector3(0.0, 0.85, 0.0)
	root.add_child(lamp)
	return root


static func _set_shadow(n: Node) -> void:
	var mi := n as GeometryInstance3D
	if mi != null:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for c in n.get_children():
		_set_shadow(c)
