extends SceneTree
## 一次性工具：生成一张可直接编辑的地图 .tres，放进 res://地图/ 并准备绑定主场景。
## 用法（在简易rts 项目根目录）：
##   godot.cmd --headless --path . --script 工具/gen_bound_map.gd
##
## MapLoader.new_map 内部引用了 Game / Cfg 这两个 autoload 全局名（在 apply_to_level 等函数里），
## 但 --script 独立运行不会加载 autoload。这里先手动把这两个全局名注册成 Engine 单例，
## 再 *动态* load MapLoader（必须在注册之后，否则 MapLoader.gd 在脚本加载期就因找不到 Game 编译失败）。
##
## 生成的图走 MapLoader.new_map（编辑器「新建地图」同一套底图逻辑）：
## 起伏地形 + 压平出生营地 + 八座标配建筑 + 固定距离金矿 + 12~17 棵树 + 全图生态色块 + 波次。
## 之后用户在编辑器里打开这张图修改、保存，主场景（绑定后）即可加载它。

func _register_singleton(name: String, script_path: String) -> bool:
	if Engine.has_singleton(name):
		return true
	var s := load(script_path) as Script
	if s == null:
		printerr("[gen_bound_map] 读不到 %s (%s)" % [name, script_path])
		return false
	var inst: Object = s.new()
	if inst == null:
		printerr("[gen_bound_map] 实例化 %s 失败" % name)
		return false
	Engine.register_singleton(name, inst)
	return true


func _initialize() -> void:
	# 让 autoload 全局名可见（只在独立脚本模式下需要；必须在 load MapLoader 之前）
	if not _register_singleton("Game", "res://代码/核心/游戏状态.gd"):
		quit(1)
		return
	if not _register_singleton("Cfg", "res://代码/配置/配置入口.gd"):
		quit(1)
		return

	# 动态加载 MapLoader（静态引用会在脚本加载期就触发 MapLoader.gd 编译，那时 Game 还没注册）
	var loader_script := load("res://代码/地图核心/地图加载器.gd") as Script
	if loader_script == null:
		printerr("[gen_bound_map] 读不到 MapLoader")
		quit(1)
		return

	var size: int = 224
	var players: int = 4
	var seed: int = 20261024
	var biome: String = "temperate"
	var def: MapDef = loader_script.call("new_map", size, players, seed, false, {"biome": biome})
	if def == null:
		printerr("[gen_bound_map] MapLoader.new_map 返回空")
		quit(1)
		return
	def.ensure_arrays()
	var path: String = "res://地图/主场景地图.tres"
	var err: int = MapStore.save_tres(def, path)
	if err != OK:
		printerr("[gen_bound_map] 保存失败 err=%d -> %s" % [err, path])
		quit(1)
		return
	var tree_count: int = 0
	var mine_count: int = 0
	var building_count: int = 0
	for o in def.objects:
		if o == null:
			continue
		if o.type_id == &"tree":
			tree_count += 1
		elif o.type_id == &"goldmine":
			mine_count += 1
		elif int(o.category) == 1:  # BUILDING
			building_count += 1
	print("[gen_bound_map] OK -> %s" % path)
	print("[gen_bound_map] 尺寸=%dm 玩家=%d 生态=%s 对象=%d(建筑%d/树%d/矿%d) 波次=%d" % [
		def.size, def.players.size(), def.biome, def.objects.size(),
		building_count, tree_count, mine_count, def.waves.size()])
	quit()
