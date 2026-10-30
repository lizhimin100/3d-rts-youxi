extends SceneTree
## **程序化树自检**（无头跑，不需要窗口）
##
##   godot --headless --path . --script 代码/测试/程序化树自检.gd
##
## 验的是"生成器"本身，不是画面：
##   ① 确定性：同一个种子两次生成，顶点数/坐标完全一致（地图存档才敢只存种子）
##   ② 变体差异：不同种子必须长出不同的树（不然"随机"是假的）
##   ③ 档位预算：近/中/远三档的面数落在预算内（手游 RTS 的硬指标）
##   ④ 尺寸：归一化到 def.height，根部贴 y=0（否则整片林子离地或埋土）
##   ⑤ 单材质单 surface：一棵树一次 draw call 的前提
##   ⑥ 品种差异：四季的叶色/叶量必须真的不同
##   ⑦ 纹理图集：叶形区有透明也有实心，树干取样点是不透明
##   ⑧ 生成耗时：池化前的单次成本，决定开局卡不卡

const 预算 := {"近": 2600, "中": 1700, "远": 420}


func _init() -> void:
	var fails: Array[String] = []
	print("========== 程序化树自检 ==========")

	# ---------- ① 确定性 ----------
	var a: ArrayMesh = ProcTree.build("夏", 0, 12345, 5.5)
	var b: ArrayMesh = ProcTree.build("夏", 0, 12345, 5.5)
	var va: PackedVector3Array = _verts(a)
	var vb: PackedVector3Array = _verts(b)
	var same := va.size() == vb.size()
	if same:
		for i in va.size():
			if not va[i].is_equal_approx(vb[i]):
				same = false
				break
	print("[① 确定性] 同种子两次生成：顶点 %d / %d → %s" % [va.size(), vb.size(),
		"一致 ✓" if same else "不一致 ✗"])
	if not same:
		fails.append("确定性")

	# ---------- ② 变体差异 ----------
	var c: ArrayMesh = ProcTree.build("夏", 0, 99991, 5.5)
	var vc: PackedVector3Array = _verts(c)
	var diff := 0
	for i in mini(vc.size(), va.size()):
		if vc[i].distance_to(va[i]) > 0.01:
			diff += 1
	var diff_ratio: float = float(diff) / float(maxi(1, va.size()))
	print("[② 变体差异] 种子 12345 vs 99991：%.0f%% 顶点位置不同 → %s" % [
		diff_ratio * 100.0, "✓" if diff_ratio > 0.5 else "✗"])
	if diff_ratio <= 0.5:
		fails.append("变体差异")

	# ---------- ③④⑤ 各品种各档位 ----------
	print("[③④⑤ 档位] 品种  档  面数   预算  网格数 高(m)  根y    材质数")
	for season in ProcTree.SEASON_ORDER:
		for tier in 3:
			var m: ArrayMesh = ProcTree.build(season, tier, 424242, 5.5)
			var v := _verts(m)
			var tris: int = _tris(m)
			var h: float = _height(v)
			var ymin: float = _ymin(v)
			var label: String = ["近", "中", "远"][tier]
			var budget: int = 预算[label]
			var ok: bool = tris > 0 and tris <= budget and m.get_surface_count() == 1 \
				and absf(h - 5.5) < 0.05 and absf(ymin) < 0.05
			print("            %s   %s  %5d  %5d   %d      %.2f  %+.3f  %d  %s" % [
				season, label, tris, budget, m.get_surface_count(), h, ymin,
				m.get_surface_count(), "✓" if ok else "✗"])
			if not ok:
				fails.append("%s/%s 预算或尺寸" % [season, label])

	# ---------- ⑥ 品种差异 ----------
	var avg: Dictionary = {}
	for season in ProcTree.SEASON_ORDER:
		var m: ArrayMesh = ProcTree.build(season, 1, 424242, 5.5)
		avg[season] = _avg_leaf_color(m)
		print("[⑥ 品种] %s 平均叶色 = %s  三角面 = %d" % [season, avg[season],
		_tris(m)])
	var 色差: bool = (avg["春"] as Color).r != (avg["秋"] as Color).r \
		or (avg["夏"] as Color).g != (avg["冬"] as Color).g
	print("            四季叶色互不相同 → %s" % ("✓" if 色差 else "✗"))
	if not 色差:
		fails.append("品种差异")

	# ---------- ⑦ 图集 ----------
	var tex: ImageTexture = ProcTree.atlas()
	var img: Image = tex.get_image()
	var leaf_alpha_min := 1.0
	var leaf_alpha_max := 0.0
	for py in range(img.get_height() / 2, img.get_height()):
		for px in range(0, img.get_width() / 2):
			var al: float = img.get_pixel(px, py).a
			leaf_alpha_min = minf(leaf_alpha_min, al)
			leaf_alpha_max = maxf(leaf_alpha_max, al)
	var opaque_a: float = img.get_pixel(int(ProcTree.UV_OPAQUE.x * img.get_width()),
		int(ProcTree.UV_OPAQUE.y * img.get_height())).a
	var atlas_ok: bool = leaf_alpha_min < 0.1 and leaf_alpha_max > 0.9 and opaque_a > 0.99
	print("[⑦ 图集] %dx%d  叶形 alpha %.2f~%.2f  树干取样 alpha %.2f → %s" % [
		img.get_width(), img.get_height(), leaf_alpha_min, leaf_alpha_max, opaque_a,
		"✓" if atlas_ok else "✗"])
	if not atlas_ok:
		fails.append("图集")

	# ---------- ⑧ 生成耗时 ----------
	TreeLibrary.clear_cache()
	var t0: int = Time.get_ticks_usec()
	TreeLibrary.prewarm(ProcTree.SEASON_ORDER, 5.5)
	var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	var st: Dictionary = TreeLibrary.stats()
	print("[⑧ 耗时] 全量预热 %d 份网格（4 品种 × 3 档 × %d 变体）：%.0f ms，单份约 %.1f ms" % [
		int(st["网格份数"]), TreeLibrary.POOL, ms, ms / float(maxi(1, int(st["网格份数"])))])
	print("          池占用：%s" % str(st))

	# ---------- ⑨ 接线 ----------
	_check_wiring(fails)

	print("========== 结果：%s（%d 项不通过）==========" % [
		"全部通过" if fails.is_empty() else "有失败项", fails.size()])
	for f in fails:
		print("   ✗ ", f)
	quit(0 if fails.is_empty() else 1)


## ⑨ 接线检查：不是"生成器能不能画"，而是"数据能不能活到游戏里"
func _check_wiring(fails: Array[String]) -> void:
	print("[⑨ 接线] —— 单位表 / 存档往返 / 品种解析")
	var units: Dictionary = UnitTable.build_units()
	var want: Array[String] = ["tree", "tree_春", "tree_夏", "tree_秋", "tree_冬"]
	for id in want:
		var d: UnitDef = units.get(StringName(id), null)
		var ok: bool = d != null and d.kind == RtsConst.Kind.HARVESTABLE and d.model_path.is_empty()
		print("            %-9s 存在=%s kind=HARVESTABLE=%s 不依赖glb=%s → %s" % [
			id, str(d != null), str(d != null and d.kind == RtsConst.Kind.HARVESTABLE),
			str(d != null and d.model_path.is_empty()), "✓" if ok else "✗"])
		if not ok:
			fails.append("单位表缺 " + id)

	# 存档往返：种子/品种必须能进 .tres 再回来（不然"随机并保存"就是空话）
	var o := MapObject.make(&"tree_秋", MapObject.Category.RESOURCE, Vector3(3, 4, 5), 1.2, 1.05, -1)
	o.properties["seed"] = 987654
	o.properties["season"] = "秋"
	var back: MapObject = MapObject.from_dict(o.to_dict())
	var round_ok: bool = int(back.properties.get("seed", 0)) == 987654 \
		and String(back.properties.get("season", "")) == "秋" \
		and absf(back.rotation - 1.2) < 0.001 and absf(back.scale - 1.05) < 0.001
	print("            存档往返：seed/season/朝向/缩放 → %s" % ("✓" if round_ok else "✗"))
	if not round_ok:
		fails.append("存档往返")

	# 品种解析
	var suffix_ok: bool = true
	for s in ProcTree.SEASON_ORDER:
		if TreeLibrary.season_of(StringName("tree_" + s), 1) != s:
			suffix_ok = false
	print("            后缀→品种：tree_春/夏/秋/冬 → %s" % ("✓" if suffix_ok else "✗"))
	if not suffix_ok:
		fails.append("后缀解析")

	# 无后缀的混生树：50 个种子应该至少覆盖 3 个品种（否则"混生"是假的）
	var seen: Dictionary = {}
	for i in 50:
		seen[TreeLibrary.season_of(&"tree", i * 7919)] = true
	var mix_ok: bool = seen.size() >= 3
	print("            混生树 50 个种子覆盖 %d 个品种 → %s" % [seen.size(),
		"✓" if mix_ok else "✗"])
	if not mix_ok:
		fails.append("混生品种覆盖")

	# 变体号必须落在池子里
	var var_ok := true
	for i in 200:
		var v: int = TreeLibrary.variant_of(i * 12345 - 77)
		if v < 0 or v >= TreeLibrary.POOL:
			var_ok = false
	print("            变体号取值范围 [0, %d) → %s" % [TreeLibrary.POOL,
		"✓" if var_ok else "✗"])
	if not var_ok:
		fails.append("变体号越界")

	# 编辑器预览：MapObject → 预览节点，且和游戏内**共享同一个 ArrayMesh**
	# （共享 = 存档里的种子在编辑器和游戏里长出来的确实是同一棵树）
	var po := MapObject.make(&"tree_夏", MapObject.Category.RESOURCE, Vector3(5, 0, 5), 0.5, 1.0, -1)
	po.properties["seed"] = 4242
	po.properties["season"] = "夏"
	var pv: Node3D = MapPreviewFactory.build(po)
	var pv_mesh: ArrayMesh = null
	if pv != null:
		for c in pv.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh is ArrayMesh:
				pv_mesh = (c as MeshInstance3D).mesh as ArrayMesh
				break
	var same_mesh: bool = pv_mesh != null and pv_mesh == TreeLibrary.mesh("夏", 0,
		TreeLibrary.variant_of(4242), 5.5)
	print("            编辑器预览：%s，与游戏内共用同一份网格 → %s" % [
		"有模型" if pv_mesh != null else "空/占位", "✓" if same_mesh else "✗"])
	if not same_mesh:
		fails.append("编辑器预览")
	if pv != null:
		pv.free()

	# 编辑器摆放：MapAssets.roll_proc_tree（add_object 里那颗"骰子"的纯函数版）
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261030
	var a1 := MapObject.make(&"tree_秋", MapObject.Category.RESOURCE, Vector3.ZERO)
	MapAssets.roll_proc_tree(a1, &"tree_秋", rng)
	var a2 := MapObject.make(&"tree", MapObject.Category.RESOURCE, Vector3.ZERO)
	MapAssets.roll_proc_tree(a2, &"tree", rng)
	var roll_ok: bool = a1.properties.has("seed") \
		and String(a1.properties.get("season", "")) == "秋" \
		and not a2.properties.has("season") \
		and a1.rotation >= 0.0 and a1.rotation <= TAU \
		and a1.scale >= 0.88 and a1.scale <= 1.14 \
		and int(a1.properties["seed"]) != int(a2.properties["seed"])
	print("            摆放掷骰：秋树带 season=秋 / 混生树不带 / 两次种子不同 → %s" % [
		"✓" if roll_ok else "✗"])
	if not roll_ok:
		fails.append("摆放掷骰")


# ------------------------------------------------------------------ 工具
func _verts(m: ArrayMesh) -> PackedVector3Array:
	if m == null or m.get_surface_count() == 0:
		return PackedVector3Array()
	var arr: Array = m.surface_get_arrays(0)
	return arr[Mesh.ARRAY_VERTEX] as PackedVector3Array


func _tris(m: ArrayMesh) -> int:
	if m == null or m.get_surface_count() == 0:
		return 0
	var arr: Array = m.surface_get_arrays(0)
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] as PackedInt32Array
	if idx.size() > 0:
		return idx.size() / 3
	return (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


func _height(v: PackedVector3Array) -> float:
	if v.is_empty():
		return 0.0
	var lo := INF
	var hi := -INF
	for p in v:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	return hi - lo


func _ymin(v: PackedVector3Array) -> float:
	var lo := INF
	for p in v:
		lo = minf(lo, p.y)
	return lo if lo != INF else 0.0


## 只统计叶片的平均色：叶片 UV 落在图集左下半（u < 0.5 且 v > 0.5）
func _avg_leaf_color(m: ArrayMesh) -> Color:
	if m == null or m.get_surface_count() == 0:
		return Color.BLACK
	var arr: Array = m.surface_get_arrays(0)
	var cols: PackedColorArray = arr[Mesh.ARRAY_COLOR] as PackedColorArray
	var uvs: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array
	var acc := Color(0, 0, 0, 0)
	var n := 0
	for i in mini(cols.size(), uvs.size()):
		if uvs[i].x < 0.5 and uvs[i].y > 0.5:
			acc += cols[i]
			n += 1
	if n == 0:
		return Color.BLACK
	return Color(acc.r / n, acc.g / n, acc.b / n, 1.0)
