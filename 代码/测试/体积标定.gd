extends SceneTree
## **体积标定（无头 · 只看数，不打架）**：把"体积 → 判定圈半径"的几种候选并排打出来，
## 让玩家实测后拍板选一个。**本工具不改任何东西**（只读卡 + 只算表）。
##
## 跑法：godot --headless --path . --script 代码/测试/体积标定.gd
## 结尾一行 `VOLCAL {json}`。
##
## 为什么要它（玩家 2026-11-08）：
##   「体积 → 判定圈半径的公式先做测试工具 + 几组候选（值=半径 / 值=直径÷2 /
##     值只缩放模型、判定圈另填），我实测后拍，不要现在定死。」
##   所以公式住在 `代码/配置/体积派生.gd` 的 `MODE` 常量里，这里只做**对照表**。
##
## 表里三列都印出来，看的是"同一个体积在三种口径下圈多大"：
##   模式1 半径=体积      —— 体积写"半径米数"（0.5 = 半径 0.5m）
##   模式2 半径=体积÷2    —— 体积写"直径米数"（0.5 = 半径 0.25m）★ 当前生效
##   模式3 只缩放模型     —— 判定圈读卡上另填的半径（体积只影响模型大小）

const VOL := preload("res://代码/配置/体积派生.gd")
const TABLE := preload("res://代码/配置/单位表.gd")


func _initialize() -> void:
	call_deferred("_运行")


func _运行() -> void:
	print("[体积标定] 当前生效：%s" % VOL.mode_name())
	print("")
	print("候选表（体积 = 标准体型的倍数，1.0 = 步兵）")
	print("  体积  模型缩放   模式1半径   模式2半径   模式3(另填)")
	for row in VOL.table():
		print("  %5.2f    %5.2f      %6.2f      %6.2f      %6.2f" % [
			float(row["体积"]), float(row["模型缩放"]),
			float(row["模式1半径=体积"]), float(row["模式2半径=体积÷2"]),
			float(row["模式3=另填"])])
	print("")

	# 现存卡的实测对照：卡上体积 → 派生出来的三个半径（模式 1/2/3 各算一遍）
	var all: Dictionary = TABLE.build_units()
	var rows: Array = []
	print("现存单位（卡上 volume → 派生）")
	print("  %-14s %6s  %5s  %5s  %5s  %5s" % ["单位", "体积", "模式1", "模式2", "模式3", "旧body"])
	for id in all.keys():
		var d: UnitDef = all[id]
		if d == null or d.is_building() or d.is_harvestable():
			continue
		if d.volume <= 0.0:
			continue
		var r1: float = VOL.judge_radius(d.volume, d.selection_radius)
		# 三种口径都走 体积派生.radius_for_mode（**同一个公式**，这里不另抄一份）
		var m1: float = VOL.radius_for_mode(d.volume, VOL.MODE_RADIUS_EQUALS_VOLUME, d.selection_radius)
		var m2: float = VOL.radius_for_mode(d.volume, VOL.MODE_RADIUS_IS_HALF, d.selection_radius)
		var m3: float = VOL.radius_for_mode(d.volume, VOL.MODE_SEPARATE, d.selection_radius)
		if absf(r1 - VOL.radius_for_mode(d.volume, VOL.MODE, d.selection_radius)) > 0.0001:
			print("  [!] %s 的 judge_radius 和公式对不上" % String(d.display_name))
		print("  %-14s %6.2f  %5.2f  %5.2f  %5.2f  %5.2f" % [
			String(d.display_name), d.volume, m1, m2, m3, d.body_radius])
		rows.append({
			"id": String(id), "体积": d.volume,
			"模式1": m1, "模式2": m2, "模式3": m3,
			"旧body半径": d.body_radius, "旧拾取半径": d.selection_radius,
			"攻击圈=射程(米)": d.attack_range,
		})
	# 建筑不走体积：确认 judge_radius 是 0（打楼量墙面，不加圈）
	var 建筑判定圈非零: Array = []
	for id in all.keys():
		var d2: UnitDef = all[id]
		if d2 != null and d2.is_building() and absf(d2.judge_radius) > 0.0001:
			建筑判定圈非零.append(String(id))
	print("")
	print("[体积标定] 建筑判定圈非零的：%s（应为空）" % str(建筑判定圈非零))
	print("VOLCAL " + JSON.stringify({
		"当前模式": VOL.mode_name(),
		"候选": VOL.table(),
		"单位": rows,
		"建筑判定圈非零": 建筑判定圈非零,
	}))
	quit(0 if 建筑判定圈非零.is_empty() else 1)
