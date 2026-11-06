extends SceneTree
## **建造动画自检**：资产 `_建造.glb` 驱动工地表现的专项验证。
##
## 运行：
##   godot --headless --path . --script 代码/测试/建造动画自检.gd
##
## 覆盖（两头都要对）：
##   ① 有 `_建造.glb` 的建筑（兵营）：工地挂上建造模型、`build` 动画由进度 seek、
##      成品 visual 隐藏、程序化脚手架 / 料堆不出现、基础动作仍由进度驱动；
##   ② 缺档建筑（营火）：必须回落程序化脚手架，且不报错；
##   ③ 完工：visual 重新露脸、建造模型释放。
##
## ★ 为什么满篇 call()/get() + load()：`--script` 模式下 autoload 的全局标识符在本文件
##   解析时还没注册（见 建造自检.gd 开头）——`preload` 建筑.gd 会连带编译引用 Game 的
##   依赖链而整个失败，只能在运行时 load() 出来鸭子调用。

const BUILDING_PATH := "res://代码/单位/建筑.gd"
const GRID_PATH := "res://代码/单位/建筑网格.gd"
const CAMPFIRE := &"campfire"

var _pass: int = 0
var _fail: int = 0
var _frames: int = 0

var _b: Node3D = null
var _site: Node3D = null
var _bm: Node3D = null
var _vis: Node3D = null
var _def: Object = null
var _campfire_site: Node3D = null
var _building_script: Script = null
var _grid_yaw: float = -PI


func _initialize() -> void:
	print("========== 建造动画自检 ==========")


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_boot()
		_test_build_model()
		_test_fallback()
		_test_all_ids()
		return false
	if _frames < 3:
		return false
	if _frames == 3:
		_test_finish()
		return false
	if _frames < 5:
		return false
	_test_release()
	_report()
	return true


func _boot() -> void:
	var cfg := root.get_node_or_null("Cfg")
	var game := root.get_node_or_null("Game")
	if cfg == null or game == null:
		_ok("autoload 可用", false, "Cfg / Game 没挂上")
		return
	game.call("reset")
	game.call("setup_factions")
	var grid: Script = load(GRID_PATH)
	if grid != null:
		_grid_yaw = float(grid.call("default_yaw"))
	_building_script = load(BUILDING_PATH)
	if _building_script == null:
		_ok("建筑脚本可载入", false, BUILDING_PATH)
		return
	_def = cfg.call("unit", &"barracks")
	var faction = game.get("player_faction")
	_b = _building_script.new()
	_b.name = "兵营工地"
	_b.position = Vector3(0.0, 0.0, 0.0)
	_b.rotation.y = _grid_yaw
	root.add_child(_b)
	_b.call("setup_construction", faction, _def)
	_site = _b.get("_site_fx")
	_vis = _b.get("visual")
	_ok("工地已立起", _site != null, "site=%s" % str(_site))


# ===========================================================================
# ① 有 _建造.glb 的建筑
# ===========================================================================

func _test_build_model() -> void:
	if _site == null:
		return
	_ok("兵营走资产建造模型（不是程序化脚手架）", bool(_site.call("has_build_model")),
		"has_build_model=%s" % str(_site.call("has_build_model")))
	_bm = _site.call("build_model") as Node3D
	_ok("建造模型节点存在且是 building 的子节点", _bm != null and _bm.get_parent() == _b,
		"parent=%s" % (String(_bm.get_parent().name) if _bm != null else "-"))
	_ok("建造模型和 visual 同级", _bm != null and _bm.name == "建造模型", String(_bm.name) if _bm != null else "-")

	# transform 必须和 visual 严格一致（位置 / 旋转 / 缩放）
	if _bm != null and _vis != null:
		var same := _bm.position.is_equal_approx(_vis.position) \
			and absf(_bm.rotation.y - _vis.rotation.y) < 0.001 \
			and _bm.scale.is_equal_approx(_vis.scale)
		_ok("建造模型 transform = visual transform", same,
			"bm pos=%s rot=%.3f scale=%s | vis pos=%s rot=%.3f scale=%s" % [str(_bm.position),
				_bm.rotation.y, str(_bm.scale), str(_vis.position), _vis.rotation.y, str(_vis.scale)])
		_ok("建造模型朝向 = DEFAULT_YAW（没有额外旋转）",
			absf(angle_difference(_b.global_rotation.y, _grid_yaw)) < 0.001,
			"yaw=%.3f" % _b.global_rotation.y)

	var ap := _find_ap(_bm)
	_ok("建造模型里有 AnimationPlayer", ap != null, "-")
	if ap == null:
		return
	_ok("当前动画 = build", String(ap.current_animation) == "build", String(ap.current_animation))
	_ok("动画速度归零（由进度驱动）", absf(ap.speed_scale) < 0.001, "speed=%.2f" % ap.speed_scale)

	# 成品模型必须藏起来，只显示建造模型
	_ok("成品 visual 已隐藏", _vis != null and not _vis.visible,
		"visible=%s" % str(_vis.visible if _vis != null else "-"))

	# 程序化脚手架 / 料堆不能出现（否则两套脚手架打架）
	var scaffold := _site.get_node_or_null("脚手架")
	_ok("没有程序化脚手架", scaffold == null, "脚手架=%s" % str(scaffold))
	var piles: int = 0
	for c in _site.get_children():
		if String(c.name).ends_with("料堆") or String(c.name) == "石料堆" or String(c.name) == "木料堆":
			piles += 1
	_ok("没有程序化料堆", piles == 0, "料堆 %d 个" % piles)

	# 进度 0 → 0.5：动画时轴真的动了
	var len: float = float(_site.call("anim_length"))
	_site.call("set_progress", 0.0)
	var t0: float = float(_site.call("anim_position"))
	_site.call("set_progress", 0.5)
	var t1: float = float(_site.call("anim_position"))
	_ok("动画被进度 seek 到中点", len > 1.0 and absf(t1 - len * 0.5) < 0.05,
		"len=%.2f t0=%.2f t1=%.2f" % [len, t0, t1])
	_ok("进度回退时动画也能回退（不是自播）", t0 < t1, "%.2f → %.2f" % [t0, t1])

	# 资产材质是 StandardMaterial3D → 转成 建造显影.gdshader 做**世界 Y 裁剪**
	# （纵向压缩会把窗户/门压扁，近景一眼假；见 美术/着色器/建造显影.gdshader 注释）
	var mode: String = String(_site.call("clip_mode"))
	var cut: float = float(_site.call("clip_world_offset"))
	var h: float = float(_def.get("height"))
	_ok("剖切方式 = 世界裁剪（world）", mode == "world", "mode=%s" % mode)
	_ok("世界裁剪面 ≈ 半个层高", cut > h * 0.4 and cut < h * 0.6,
		"cut=%.2f（层高 %.1f）" % [cut, h])
	# 世界裁剪下**不做**任何缩放：模型保持原尺寸，脚手架也保持原尺寸
	var body := _find_body(_bm)
	_ok("世界裁剪时模型不缩放（不压扁窗户）",
		body != null and body.scale.y > 0.99 and _bm.scale.is_equal_approx(Vector3.ONE),
		"body.scale.y=%.2f bm.scale=%s" % [body.scale.y if body != null else -1.0,
			str(_bm.scale) if _bm != null else "-"])
	_ok("成品 visual 的缩放没被动", _vis.scale.is_equal_approx(Vector3.ONE),
		"vis.scale=%s" % str(_vis.scale))

	# 锤击反馈还在（农民抡锤的尘土/石屑是手感的一部分）
	var hit: bool = bool(_site.call("strike", Vector3.ZERO))
	_ok("锤击反馈仍然出效果", hit, "strike=%s" % str(hit))


# ===========================================================================
# ② 缺档建筑必须回落
# ===========================================================================

func _test_fallback() -> void:
	var def2 = root.get_node("Cfg").call("unit", CAMPFIRE)
	if def2 == null:
		_ok("营火定义可取", false, "Cfg.unit(campfire) = null")
		return
	var b2: Node3D = _building_script.new()
	b2.position = Vector3(30.0, 0.0, 0.0)
	root.add_child(b2)
	b2.call("setup_construction", root.get_node("Game").get("player_faction"), def2)
	_campfire_site = b2.get("_site_fx")
	_ok("缺档建筑（营火）回落程序化脚手架",
		_campfire_site != null and not bool(_campfire_site.call("has_build_model")),
		"site=%s" % str(_campfire_site))
	_ok("回落路径建出了脚手架",
		_campfire_site != null and _campfire_site.get_node_or_null("脚手架") != null, "-")


# ===========================================================================
# ②b 九座建筑的表映射（id → 文件名）不能有错漏
# ===========================================================================

const ALL_IDS: Array = ["townhall", "barracks", "farm", "lumbercamp", "watchtower",
	"tower", "blacksmith", "sanctum", "workshop"]


func _test_all_ids() -> void:
	if _building_script == null:
		return
	var cfg := root.get_node("Cfg")
	var faction = root.get_node("Game").get("player_faction")
	var hung: Array[String] = []
	var bad: Array[String] = []
	for i in ALL_IDS.size():
		var d = cfg.call("unit", StringName(ALL_IDS[i]))
		if d == null:
			bad.append(String(ALL_IDS[i]) + "(无卡)")
			continue
		var b: Node3D = _building_script.new()
		b.position = Vector3(-200.0 + float(i) * 12.0, 0.0, -200.0)
		root.add_child(b)
		b.call("setup_construction", faction, d)
		var site = b.get("_site_fx")
		if site != null and bool(site.call("has_build_model")):
			hung.append(String(ALL_IDS[i]))
		else:
			bad.append(String(ALL_IDS[i]))
		b.queue_free()
	_ok("9 座建筑都挂上了资产建造模型（id 表无错漏）", bad.is_empty() and hung.size() == 9,
		"成功 %d 座；失败 %s" % [hung.size(), str(bad)])


# ===========================================================================
# ③ 完工收尾
# ===========================================================================

func _test_finish() -> void:
	if _b == null:
		return
	_b.call("advance_construction", 100.0, null)
	_ok("进度推满 → 建筑已完工", bool(_b.get("is_constructed")), "progress=%s" % str(_b.get("progress")))
	_ok("完工后成品 visual 重新显示", _vis != null and _vis.visible,
		"visible=%s" % str(_vis.visible if _vis != null else "-"))
	_ok("完工后工地不再持有建造模型", not bool(_site.call("has_build_model")),
		"has=%s" % str(_site.call("has_build_model")))
	_ok("完工后建造模型已隐藏（不等帧末释放）", _bm != null and not _bm.visible,
		"visible=%s" % str(_bm.visible if _bm != null else "-"))


## finish() 里是 queue_free（帧末才真删），所以有效性要下一帧再验
func _test_release() -> void:
	_ok("完工后建造模型已释放", _bm == null or not is_instance_valid(_bm),
		"valid=%s" % str(_bm != null and is_instance_valid(_bm)))
	_ok("完工后成品模型缩放归位", _vis != null and _vis.scale.is_equal_approx(Vector3.ONE),
		"scale=%s" % str(_vis.scale if _vis != null else "-"))


# ===========================================================================
# 工具
# ===========================================================================

## 建造模型里非蒙皮的 `Building` 主体
func _find_body(n: Node) -> Node3D:
	var mi := n as MeshInstance3D
	if mi != null and mi.name == "Building" and mi.skin == null:
		return mi
	if n == null:
		return null
	for c in n.get_children():
		var f := _find_body(c)
		if f != null:
			return f
	return null


func _find_ap(n: Node) -> AnimationPlayer:
	var ap := n as AnimationPlayer
	if ap != null:
		return ap
	if n == null:
		return null
	for c in n.get_children():
		var f := _find_ap(c)
		if f != null:
			return f
	return null


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ✓ %s %s" % [what, detail])
	else:
		_fail += 1
		print("  ✗ %s %s" % [what, detail])


func _report() -> void:
	print("-------------------------------")
	print("结果：通过 %d / 失败 %d  —— %s" % [_pass, _fail,
		"全部通过 ✓" if _fail == 0 else "有失败 ✗"])
