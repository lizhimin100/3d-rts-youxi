extends SceneTree
## 探针：真·RtsUnit 走一遍 idle→move→attack，看 AnimationPlayer 到底有没有在播
var _u: Node3D = null
var _ap: AnimationPlayer = null
var _frame: int = 0

func _initialize() -> void:
	call_deferred("_start")

func _start() -> void:
	var cfg: Node = root.get_node_or_null("Cfg")
	print("Cfg=", cfg)
	var lvl: Node = root.get_node_or_null("关卡")
	print("关卡=", lvl)
	if cfg == null:
		quit()
		return
	var d: UnitDef = cfg.call("unit", &"archer")
	print("def=", d.display_name, " model=", d.model_path)
	var vis: Node = load("res://代码/单位/单位视觉.gd").new()
	root.add_child(vis)
	vis.call("build", d, Color(0.3, 0.62, 1.0))
	_ap = _find(vis)
	print("AnimationPlayer=", _ap)
	if _ap != null:
		print("  动作=", _ap.get_animation_list())
	vis.call("play", "idle", 1.0, true)
	_frame = 0

func _find(n: Node) -> AnimationPlayer:
	var stack: Array = [n]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is AnimationPlayer:
			return c as AnimationPlayer
		for ch in c.get_children():
			stack.append(ch)
	return null

func _process(_dt: float) -> bool:
	if _ap == null:
		return false
	_frame += 1
	if _frame == 20:
		_ap.get_parent().get_parent()  # noop
		var vis := _ap.get_parent()
		while vis != null and not vis.has_method("play"):
			vis = vis.get_parent()
		if vis != null:
			vis.call("play", "move", 0.9)
			print("[20f] move → ", _ap.current_animation, " playing=", _ap.is_playing())
	if _frame == 40:
		var vis := _ap.get_parent()
		while vis != null and not vis.has_method("play"):
			vis = vis.get_parent()
		if vis != null:
			vis.call("play", "attack", 1.0, true)
			print("[40f] attack → ", _ap.current_animation, " playing=", _ap.is_playing(),
					" pos=", _ap.current_animation_position)
	if _frame == 70:
		print("[70f] 仍在播=", _ap.is_playing(), " 当前=", _ap.current_animation,
				" pos=", _ap.current_animation_position)
		quit()
	return false
