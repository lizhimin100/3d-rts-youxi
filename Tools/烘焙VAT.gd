extends SceneTree
## **VAT 烘焙（顶点动画纹理）** —— 把骨骼动画烘成"每帧每顶点的位置/法线"。
##
## 为什么要它：人群层是 MultiMesh（零节点、一次 draw call），**不支持蒙皮**。
## 想让一万个兵播真正的走路/待机动作，只有两条路：骨骼矩阵 VAT（每顶点 4 骨 × 2 帧 × 3 texel）
## 或**顶点位置 VAT**（每顶点 2 帧 × 1 texel）。这里做后者：
##   · 不需要 JOINTS/WEIGHTS 在 MultiMesh 里还能被读到（引擎不保证）；
##   · 每顶点每帧只取 1 个 texel，GPU 侧最省；
##   · 代价是每个 clip 一张 (顶点数 × 帧数) 的浮点纹理，步兵只有 ~2000 顶点，完全可接受。
##
## 跑法（headless 即可，不需要窗口）：
##   godot --headless --path . --script Tools/烘焙VAT.gd -- \
##     --vat=res://Content/art/模型/方块人/方块人_联盟步兵.glb --vat-name=footman \
##     --vat-clips=idle,walk --vat-fps=30
##
## 产物（默认落 `Content/art/VAT/`）：
##   <name>_<clip>.res         ImageTexture（RGBAH）：上半 = 位置 xyz，下半 = 法线 xyz
##   <name>_mesh.res           ArrayMesh：所有 surface 合并成 1 个（一次 draw call）
##                              UV2.x = 顶点序号（0~1）、UV2.y = 区域（0 主体 / 1 队色 / 2 镶边）
##                              COLOR = 材质基色 × 贴图采样（= 美术看到的那一版）
##   <name>.json               元数据：每个 clip 的帧数 / fps / 顶点数 / 包围盒 / 区域计数
##
## 约定：帧 i 的采样时刻 = length × i / frames（**不含末帧**，循环首尾天然接上）。

const DEF_OUT_DIR := "res://Content/art/VAT"

var _root: Node3D = null


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var glb := ""
	var name := ""
	var clips: PackedStringArray = PackedStringArray(["idle", "walk"])
	var fps := 30.0
	var out_dir := DEF_OUT_DIR
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--vat="):
			glb = s.substr(6)
		elif s.begins_with("--vat-name="):
			name = s.substr(11)
		elif s.begins_with("--vat-clips="):
			clips = s.substr(12).split(",", false)
		elif s.begins_with("--vat-fps="):
			fps = maxf(1.0, float(s.substr(10)))
		elif s.begins_with("--vat-out="):
			out_dir = s.substr(10)
	if glb.is_empty():
		print("VATERR 缺少 --vat=<glb 路径>")
		quit(1)
		return
	if name.is_empty():
		name = glb.get_file().get_basename()
	if not DirAccess.dir_exists_absolute(out_dir):
		DirAccess.make_dir_recursive_absolute(out_dir)

	var ps := load(glb) as PackedScene
	if ps == null:
		print("VATERR 载入失败：", glb)
		quit(1)
		return
	_root = Node3D.new()
	_root.name = "VAT根"
	get_root().add_child(_root)
	var inst := ps.instantiate() as Node3D
	_root.add_child(inst)

	var skel := _find_skel(inst)
	var ap := _find_ap(inst)
	var meshes := _collect_meshes(inst)
	if skel == null or ap == null or meshes.is_empty():
		print("VATERR 缺 Skeleton3D / AnimationPlayer / MeshInstance3D")
		quit(1)
		return

	# --- 1. 合并网格（所有 surface → 1 个，带 UV2 顶点序号 + COLOR 基色）---
	var merged := _merge_meshes(meshes, inst)
	var mv: PackedVector3Array = merged["verts"]
	var total := mv.size()
	if total <= 1:
		print("VATERR 顶点数异常：", total)
		quit(1)
		return
	var mesh := ArrayMesh.new()
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = mv
	arr[Mesh.ARRAY_NORMAL] = merged["normals"]
	arr[Mesh.ARRAY_TEX_UV2] = merged["uv2"]
	arr[Mesh.ARRAY_COLOR] = merged["colors"]
	arr[Mesh.ARRAY_INDEX] = merged["indices"]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mesh_path := out_dir + "/" + name + "_mesh.res"
	ResourceSaver.save(mesh, mesh_path)

	# --- 2. 逐 clip 烘位置/法线 ---
	var skel_rest: Array[Transform3D] = []
	for b in skel.get_bone_count():
		skel_rest.append(skel.get_bone_global_rest(b))
	var root_inv := _root.global_transform.affine_inverse()
	var meta := {
		"source": glb,
		"fps": fps,
		"verts": total,
		"tris": (merged["indices"] as PackedInt32Array).size() / 3,
		"mesh": mesh_path,
		"bbox": _bbox(mv),
		"clips": {},
	}
	var bones := merged["bones"] as PackedInt32Array
	var weights := merged["weights"] as PackedFloat32Array

	for clip in clips:
		var cn := String(clip)
		if not ap.has_animation(cn):
			print("[VAT] 跳过不存在的动作：", cn)
			continue
		var anim := ap.get_animation(cn)
		var dur := anim.length
		var frames: int = maxi(2, int(round(dur * fps)))
		var img := Image.create(total, frames * 2, false, Image.FORMAT_RGBAH)
		for f in frames:
			ap.play(cn)
			ap.seek(dur * float(f) / float(frames), true)
			ap.pause()
			skel.force_update_all_bone_transforms()
			var mats: Array[Transform3D] = []
			for b in skel.get_bone_count():
				mats.append(skel.get_bone_global_pose(b) * skel_rest[b].affine_inverse())
			var skel_xf := skel.global_transform
			for i in total:
				var v: Vector3 = mv[i]
				var n: Vector3 = (merged["normals"] as PackedVector3Array)[i]
				var p := Vector3.ZERO
				var nn := Vector3.ZERO
				var o: int = i * 4
				for k in 4:
					var w := weights[o + k]
					if w <= 0.00001:
						continue
					var bi := bones[o + k]
					var m: Transform3D = mats[bi]
					p += (m * v) * w
					nn += (m.basis * n) * w
				p = root_inv * (skel_xf * p)
				img.set_pixel(i, f, Color(p.x, p.y, p.z, 1.0))
				img.set_pixel(i, frames + f, Color(nn.x, nn.y, nn.z, 1.0))
		var tex := ImageTexture.create_from_image(img)
		var tex_path := out_dir + "/" + name + "_" + cn + ".res"
		ResourceSaver.save(tex, tex_path)
		meta["clips"][cn] = {
			"frames": frames, "seconds": snappedf(dur, 0.001),
			"texture": tex_path, "size": [total, frames * 2],
		}
		print("[VAT] %s / %s：%d 帧 × %d 顶点 → %s" % [name, cn, frames, total, tex_path])

	# --- 3. 元数据 ---
	var f := FileAccess.open(out_dir + "/" + name + ".json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(meta, "  ", false))
		f.close()
	print("VATOK ", JSON.stringify({
		"name": name, "verts": total, "tris": meta["tris"],
		"clips": (meta["clips"] as Dictionary).keys(),
		"bbox": meta["bbox"],
	}))
	quit(0)


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		var r := _find_skel(c)
		if r != null:
			return r
	return null


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n as AnimationPlayer
	for c in n.get_children():
		var r := _find_ap(c)
		if r != null:
			return r
	return null


func _collect_meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		# 跳过"特效壳"（破法者的 fx_cast 之类挂在骨上的小件仍然要，但 0 面积的跳过）
		out.append(n as MeshInstance3D)
	for c in n.get_children():
		out.append_array(_collect_meshes(c))
	return out


## 合并所有 surface。顶点做 MeshInstance 的局部变换（相对 VAT 根），
## 这样合并后的坐标系 = 单位根（脚底 y=0、-Z 正面），和主线单位一致。
func _merge_meshes(meshes: Array[MeshInstance3D], inst: Node3D) -> Dictionary:
	var all_v := PackedVector3Array()
	var all_n := PackedVector3Array()
	var all_uv := PackedVector2Array()
	var all_c := PackedColorArray()
	var all_i := PackedInt32Array()
	var all_b := PackedInt32Array()
	var all_w := PackedFloat32Array()
	var zone_counts := [0, 0, 0]
	var total := 0
	for mi in meshes:
		var rel := inst.global_transform.affine_inverse() * mi.global_transform
		var nb := rel.basis.inverse().transposed()
		for s in mi.mesh.get_surface_count():
			var a: Array = mi.mesh.surface_get_arrays(s)
			var vs: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			if vs == null or vs.size() == 0:
				continue
			var ns: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
			var uvs: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
			var bs: PackedInt32Array = a[Mesh.ARRAY_BONES]
			var ws: PackedFloat32Array = a[Mesh.ARRAY_WEIGHTS]
			var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
			var mat: Material = mi.get_active_material(s)
			var base := Color(0.7, 0.7, 0.7, 1.0)
			var tex_img: Image = null
			var zone := _zone_of(mi, s, mat)
			if mat is BaseMaterial3D:
				var bm := mat as BaseMaterial3D
				base = bm.albedo_color
				if bm.albedo_texture != null:
					tex_img = bm.albedo_texture.get_image()
					# 导入的贴图是 VRAM 压缩格式，get_pixel() 会直接报错 → 先解压
					if tex_img != null and tex_img.is_compressed():
						tex_img.decompress()
			zone_counts[zone] += vs.size()
			var off := total
			for i in vs.size():
				var v: Vector3 = rel * vs[i]
				all_v.append(v)
				all_n.append((nb * (ns[i] if i < ns.size() else Vector3.UP)).normalized())
				var col := base
				if tex_img != null and uvs != null and i < uvs.size():
					var uv: Vector2 = uvs[i]
					var px := Vector2i(
						clampi(int(uv.x * float(tex_img.get_width())) % tex_img.get_width(), 0, tex_img.get_width() - 1),
						clampi(int(uv.y * float(tex_img.get_height())) % tex_img.get_height(), 0, tex_img.get_height() - 1))
					col = base * tex_img.get_pixelv(px)
				col.a = 1.0
				all_c.append(col)
				all_uv.append(Vector2(float(off + i) / float(1), float(zone)))  # x 稍后归一
				if bs != null and bs.size() >= (i + 1) * 4:
					for k in 4:
						all_b.append(bs[i * 4 + k])
						all_w.append(ws[i * 4 + k])
				else:
					for k in 4:
						all_b.append(0)
						all_w.append(1.0 if k == 0 else 0.0)
			if idx != null and idx.size() > 0:
				for i2 in idx:
					all_i.append(off + i2)
			else:
				for i2 in vs.size():
					all_i.append(off + i2)
			total += vs.size()
	# UV2.x 归一化（着色器里当列号用，0~1 便于跨分辨率）
	for i in all_uv.size():
		var u := all_uv[i]
		u.x = (u.x + 0.5) / float(maxi(total, 1))
		all_uv[i] = u
	return {
		"verts": all_v, "normals": all_n, "uv2": all_uv, "colors": all_c,
		"indices": all_i, "bones": all_b, "weights": all_w,
		"zones": zone_counts,
	}


## 区域（决定队伍色怎么上）：优先看材质名（引擎 MatKit 的命名契约），退回 surface 序号。
func _zone_of(mi: MeshInstance3D, s: int, mat: Material) -> int:
	var nm := ""
	if mat != null:
		nm = String(mat.resource_name)
		if nm.is_empty() and not mat.resource_path.is_empty():
			nm = mat.resource_path.get_file().get_basename()
	var low := nm.to_lower()
	if low.contains("trim"):
		return 2
	if low.contains("team"):
		return 1
	if low.contains("主体") or low.contains("body"):
		return 0
	return clampi(s, 0, 2)


func _bbox(v: PackedVector3Array) -> Array:
	if v.is_empty():
		return [0, 0, 0, 0, 0, 0]
	var mn := v[0]
	var mx := v[0]
	for p in v:
		mn = mn.min(p)
		mx = mx.max(p)
	return [snappedf(mn.x, 0.001), snappedf(mn.y, 0.001), snappedf(mn.z, 0.001),
		snappedf(mx.x, 0.001), snappedf(mx.y, 0.001), snappedf(mx.z, 0.001)]
