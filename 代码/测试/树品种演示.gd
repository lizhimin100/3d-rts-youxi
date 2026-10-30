extends RefCounted
## **树品种演示图**：一张平地小地图，四种树并排站——只用来"一眼看清品种差在哪"。
##
## 两个入口：
##   · 游戏里直接看：`godot --path . -- --demo-tree`
##   · 存成地图文件再看：`godot --headless --path . --script 工具/生成四季演示图.gd`
##     （存到 res://地图/_四季演示.tres，之后也能在编辑器里打开）
##
## 为什么单独一个文件：主场景和工具脚本都要用它，逻辑放一份，别两处各写一遍。
## 注意：这里刻意**不引用 MapLoader** —— 那个脚本依赖自动加载单例 Game，
## 在 `--script` 上下文里编译不过，会连带把调用者也带崩。

## 品种 id（后缀即品种）
const 品种 := ["tree_春", "tree_夏", "tree_秋", "tree_冬"]


## 造演示图。p_间距 越大越松散；p_with_base 为真时给双方各摆一座大本营，
## 否则"敌方无建筑"会让游戏开局立刻判胜利、弹结算把画面压黑。
static func make_map(p_间距: float = 5.0, p_with_base: bool = true, p_size: int = 128) -> MapDef:
	var m := MapDef.new()
	m.size = clampi(p_size, 96, 512)
	m.seed = 20261030
	m.biome = "temperate"
	m.height_resolution = MapDef.DEFAULT_HEIGHT_RES
	m.ensure_arrays()
	m.heightmap.fill(0.0)                       # 全平，纯粹为了看树
	m.splatmap.fill(MapDef.SPLAT_BIOME)         # 生态底色
	m.water = {"enabled": false, "spots": []}
	m.objects.clear()
	m.players.clear()
	var colors: Array[Color] = [Color(0.19, 0.40, 0.74), Color(0.74, 0.22, 0.22)]
	for i in 2:
		m.players.append(PlayerSlot.make(i, "human", colors[i], 0,
			Vector2(-52.0 + 104.0 * float(i), 44.0)))

	for i in 品种.size():
		var x: float = -p_间距 * 1.5 + p_间距 * float(i)
		var o := MapObject.make(StringName(品种[i]), MapObject.Category.RESOURCE,
			Vector3(x, m.height_at(x, 0.0), 0.0), 0.0, 1.0, -1)
		# 固定种子（每个品种换一个）：每次打开都是同一棵，方便对比
		o.properties["seed"] = 100003 + i * 7919
		o.properties["season"] = String(品种[i]).substr(5)
		m.objects.append(o)

	# 后排再摆 4 块程序化岩石（0.9 缩放），用来对照"岩石也有算法了"
	for i in 4:
		var rx: float = -p_间距 * 0.9 + p_间距 * 0.6 * float(i)
		m.objects.append(MapObject.make(&"岩石", MapObject.Category.DOODAD,
			Vector3(rx, m.height_at(rx, 7.0), 7.0), float(i) * 0.9, 1.0, -1))

	if p_with_base:
		for i in 2:
			var base: Vector2 = m.players[i].start_pos
			m.objects.append(MapObject.make(&"townhall", MapObject.Category.BUILDING,
				Vector3(base.x, m.height_at(base.x, base.y), base.y), PI, 1.0, i))
	return m
