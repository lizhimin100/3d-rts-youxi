extends SceneTree
const T := preload("res://Tests/model/model_tests.gd")
func _initialize() -> void:
	call_deferred("_go")
func _go() -> void:
	var r = T.run_all()
	for l in r["lines"]:
		print(l)
	print("MODEL 通过 %d / 失败 %d" % [r["pass"], r["fail"]])
	quit(0 if int(r["fail"]) == 0 else 1)
