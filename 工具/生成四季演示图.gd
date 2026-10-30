extends SceneTree
## **四季演示图**：给验收/截屏用，不是游戏内容。
##
##   godot --headless --path . --script 工具/生成四季演示图.gd
##   然后：godot --path . -- --map=res://地图/_四季演示.tres --shot=... --cam=0,3,0 --cam-dist=26
##
## 做什么：一张空白平地地图，同一条线上摆 4 棵（春/夏/秋/冬），
## 每棵固定种子、朝向 0、缩放 1.0 —— 只用来比"品种差在哪"，不带随机干扰。
##
## 注意：这里**不能用 MapLoader.new_map()**。那个脚本引用自动加载单例 Game，
## 在 `--script` 上下文里编译不过；所以直接用 MapDef 的公开接口拼一张空图。

const OUT := "res://地图/_四季演示.tres"
const 品种 := ["tree_春", "tree_夏", "tree_秋", "tree_冬"]


func _init() -> void:
	var m := MapDef.new()
	m.size = 128
	m.seed = 20261030
	m.biome = "temperate"
	m.height_resolution = MapDef.DEFAULT_HEIGHT_RES
	m.ensure_arrays()
	m.heightmap.fill(0.0)                       # 全平，方便看树
	m.splatmap.fill(MapDef.SPLAT_BIOME)         # 生态底色
	m.water = {"enabled": false, "spots": []}
	m.objects.clear()
	m.players.clear()
	var colors: Array[Color] = [Color(0.19, 0.40, 0.74), Color(0.74, 0.22, 0.22)]
	for i in 2:
		var slot := PlayerSlot.make(i, "human", colors[i], 0, Vector2(-52.0 + 104.0 * float(i), 44.0))
		m.players.append(slot)

	var 间距 := 5.0
	for i in 品种.size():
		var x: float = -间距 * 1.5 + 间距 * float(i)
		var o := MapObject.make(StringName(品种[i]), MapObject.Category.RESOURCE,
			Vector3(x, m.height_at(x, 0.0), 0.0), 0.0, 1.0, -1)
		# 固定种子（每个品种换一个），保证每次生成的演示图长得一样
		o.properties["seed"] = 100003 + i * 7919
		o.properties["season"] = String(品种[i]).substr(5)
		m.objects.append(o)

	# 各给一座大本营：本作"敌方没有建筑 = 立刻胜利"，
	# 空图跑起来会直接弹胜利结算把画面压黑。放远一点，别进镜头。
	for i in 2:
		var base: Vector2 = m.players[i].start_pos
		var b := MapObject.make(&"townhall", MapObject.Category.BUILDING,
			Vector3(base.x, m.height_at(base.x, base.y), base.y), PI, 1.0, i)
		m.objects.append(b)

	var err: int = ResourceSaver.save(m, OUT)
	print("[四季演示] 写入 %s err=%d，对象 %d 个" % [OUT, err, m.objects.size()])
	quit(0 if err == OK else 1)
