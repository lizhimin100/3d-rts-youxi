extends SceneTree
## 配置导出工具：把代码里的默认配置（含三档难度）落成 **编辑器可改的 .tres 资源**。
##
## 用法：
##   & 'E:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.cmd' `
##       --headless --path . --script 工具/导出配置.gd
##
## 产物：res://配置/游戏配置.tres
## 之后在 Godot 编辑器里双击它，就能像普通资源一样改镜头/经济/战斗/难度/地图参数。
## 注意：**单位数值表不写进 .tres**（永远以 代码/配置/单位表.gd 为准），
##      因为单位表里有 Vector2i/Dictionary 等结构性数据，代码维护比资源序列化更可靠。


func _initialize() -> void:
	var dir_path := "res://配置"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)

	var cfg := GameConfig.new()
	# 单位表由代码生成（不序列化）
	cfg.units = UnitTable.build_units()
	# 难度表序列化成子资源
	cfg.difficulties = UnitTable.build_difficulties()

	var target := "res://配置/游戏配置.tres"
	var err := ResourceSaver.save(cfg, target)
	print("[导出配置] %s → err=%d" % [target, err])

	# 回读验证，确保真的能用
	if err == OK and ResourceLoader.exists(target):
		var back := load(target) as GameConfig
		if back == null:
			print("[导出配置] ✗ 回读失败：不是 GameConfig")
			quit(1)
			return
		print("[导出配置] ✓ 回读成功：难度档 %d 个，镜头俯角 %.1f 度，地图 %.0fm" % [
			back.difficulties.size(), back.camera_pitch_deg, back.map_size
		])
		for d in back.difficulties:
			print("    - %s：思考 %.1fs / 首波 %.0fs / 军队上限 %d / 农民目标 %d" % [
				d.display_name, d.think_interval, d.first_wave_delay, d.max_army, d.target_peasants
			])
		quit(0)
	else:
		print("[导出配置] ✗ 导出失败")
		quit(1)
