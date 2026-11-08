class_name RtsLexicon
extends RefCounted
## **词条** —— 界面里"为了好看被省略掉的那些文字"，全部在这里成句。
##
## 玩家口径："本意是把一些省略掉、为了美观而不显示出来的文本，用弹窗说明文本弥补。
## 比如放在攻击图标上要显示这是什么类型的攻击。"
##
## 所以中段那三行只留「图标 + 数字 + 两个字」，剩下的话都在这里：
##   · 攻击 —— 伤害类型（普通/穿刺/魔法/攻城）、间隔、秒伤、克制表
##   · 护甲 —— 护甲类型（轻/重/城/无）、每点减伤、当前减伤比例
##   · 移速 —— 米/秒，折算成"穿过一个屏幕要几秒"
##   · 视野 —— 米，折算成"小地图上多大一圈"
##
## **只读配置与单位状态，不发明任何规则**：倍率一律问 `Cfg.game.damage_multiplier()`，
## 减伤一律问 `RtsCombat.armor_mitigation()` —— 数值表改了，说明文本自动跟上。

const Spec := preload("res://代码/界面/界面规格.gd")
## 射程换算（卡上游戏数值 ↔ 引擎米）。界面只显示游戏数值。
const RANGE_BASE := preload("res://代码/配置/射程基准.gd")


# ===========================================================================
# 枚举 → 中文
# ===========================================================================

static func dmg_name(t: int) -> String:
	match t:
		RtsConst.DamageType.PIERCE:
			return "穿刺"
		RtsConst.DamageType.MAGIC:
			return "魔法"
		RtsConst.DamageType.SIEGE:
			return "攻城"
		_:
			return "普通"


static func dmg_how(t: int) -> String:
	match t:
		RtsConst.DamageType.PIERCE:
			return "箭矢/弩矢造成"
		RtsConst.DamageType.MAGIC:
			return "法术造成"
		RtsConst.DamageType.SIEGE:
			return "攻城器械造成"
		_:
			return "刀剑近身造成"


static func armor_name(t: int) -> String:
	match t:
		RtsConst.ArmorType.HEAVY:
			return "重甲"
		RtsConst.ArmorType.FORTIFIED:
			return "城甲"
		RtsConst.ArmorType.NONE:
			return "无甲"
		_:
			return "轻甲"


static func kind_name(d: UnitDef) -> String:
	if d == null:
		return "单位"
	if d.is_building():
		return "建筑"
	if d.gather_rate > 0.0:
		return "采集"
	if d.attack_damage <= 0.0:
		return "辅助"
	if d.attack_range > 3.0:
		return "远程"
	return "近战"


# ===========================================================================
# 数值口径
# ===========================================================================

static func fmt(v: float) -> String:
	if absf(v - roundf(v)) < 0.05:
		return "%d" % int(roundf(v))
	return "%.1f" % v


## 护甲减伤（%）——走战斗模块的同一个函数，别在这里自己乘
static func mitigation_pct(armor: float) -> int:
	return int(round(RtsCombat.armor_mitigation(armor) * 100.0))


## 克制表：**分成「克制 / 被克」两行**。
## why 不合并成一行：中文在 RichTextLabel 里可以在任意两字之间折行，
## "重甲 ×0.85"会被拆成"重"换行"甲 ×0.85"（看着像错字）。一行只放两项就再也不会断。
static func counter_line(attack_type: int) -> String:
	var cfg: GameConfig = Cfg.game
	if cfg == null:
		return ""
	var names: Array[String] = ["轻甲", "重甲", "城甲", "无甲"]
	var good: Array[String] = []
	var bad: Array[String] = []
	for i in 4:
		var m: float = cfg.damage_multiplier(attack_type, i)
		if m > 1.02:
			good.append("[color=#8fe08a]%s\u00A0×%.2f[/color]" % [names[i], m])
		elif m < 0.98:
			bad.append("[color=#e08a7a]%s\u00A0×%.2f[/color]" % [names[i], m])
	var lines: Array[String] = []
	if not good.is_empty():
		lines.append("克制：" + " · ".join(good))
	if not bad.is_empty():
		lines.append("被克：" + " · ".join(bad))
	if lines.is_empty():
		return "对所有护甲类型都是 ×1.00，不挑对手。"
	return "\n".join(lines)


## 秒伤（不含暴击）：伤害 / 间隔
static func dps(d: UnitDef) -> float:
	if d == null or d.attack_cooldown <= 0.01:
		return 0.0
	return d.attack_damage / d.attack_cooldown


# ===========================================================================
# 单元说明：头像 / 生命 / 法力
# ===========================================================================

## 头像上：这是谁、什么阵营、什么定位、还剩多少血
static func portrait(u: Node3D) -> Dictionary:
	var d: UnitDef = _def(u)
	if d == null:
		return {}
	var fac: RtsFaction = null
	if u != null:
		fac = u.get("faction") as RtsFaction
	var team: String = ""
	if fac != null:
		team = String(fac.display_name) if not String(fac.display_name).is_empty() else "阵营 %d" % (fac.index + 1)
	var tex: Texture2D = _portrait_tex(d)
	var lines: Array[String] = []
	lines.append("[color=#b9b6a8]%s · %s[/color]" % [kind_name(d), team if not team.is_empty() else "中立"])
	if d.max_hp > 0.0:
		var hp: float = float(u.get("hp")) if u.get("hp") != null else d.max_hp
		lines.append("生命 [b]%s / %s[/b]（%d%%）" % [fmt(hp), fmt(d.max_hp),
				int(round(clampf(hp / d.max_hp, 0.0, 1.0) * 100.0))])
	if d.attack_damage > 0.0:
		lines.append("攻击 [b]%s[/b]（%s）" % [fmt(d.attack_damage), dmg_name(d.attack_type)])
	if d.is_building():
		lines.append("占地 %d×%d · 高度 %.1f 米" % [d.footprint.x, d.footprint.y, d.height])
	return {
		"icon": _icon_hint(d),
		"icon_color": _team_color(u, d),
		"tex": tex,
		"title": d.display_name,
		"tag": kind_name(d),
		"body": "\n".join(lines),
		"foot": "左键点选 · 右键下达指令" if not d.is_building() else "左键点选 · 右键设置集结点",
	}


## 队伍清单里的一格：这个兵是谁、还剩多少血、值不值得点开看
static func cell(u: Node3D, idx: int) -> Dictionary:
	var d: UnitDef = _def(u)
	if d == null:
		return {}
	var cur: float = float(u.get("hp")) if u.get("hp") != null else 0.0
	var mx: float = maxf(d.max_hp, 1.0)
	var lines: Array[String] = []
	lines.append("[color=#b9b6a8]%s[/color]" % kind_name(d))
	lines.append("生命 [b]%s / %s[/b]（%d%%）" % [fmt(cur), fmt(mx),
			int(round(clampf(cur / mx, 0.0, 1.0) * 100.0))])
	if d.attack_damage > 0.0:
		lines.append("攻击 %s（%s）· 护甲 %s" % [fmt(d.attack_damage),
				dmg_name(d.attack_type), fmt(d.armor)])
	return {
		"icon": _icon_hint(d),
		"icon_color": _team_color(u, d),
		"tex": _portrait_tex(d),
		"title": d.display_name,
		"tag": "第 %d 个" % (idx + 1),
		"body": "\n".join(lines),
		"foot": "点一下：只选它（看详细数值）",
	}


## 生命那一行
static func hp(u: Node3D) -> Dictionary:
	var d: UnitDef = _def(u)
	if d == null:
		return {}
	var cur: float = float(u.get("hp")) if u.get("hp") != null else 0.0
	var mx: float = maxf(d.max_hp, 1.0)
	var r: float = clampf(cur / mx, 0.0, 1.0)
	var state: String = "满血"
	if r <= 0.0:
		state = "已阵亡"
	elif r <= 0.30:
		state = "[color=#ff8a7a]濒死[/color]"
	elif r <= 0.60:
		state = "[color=#ffd27a]受伤[/color]"
	return {
		"icon": "heart",
		"icon_color": Color(0.52, 0.88, 0.56) if r > 0.6 else (Color(1.0, 0.80, 0.36) if r > 0.3 else Color(1.0, 0.42, 0.34)),
		"title": "生命 %s / %s" % [fmt(cur), fmt(mx)],
		"tag": state,
		"body": "余量 [b]%d%%[/b]。生命归零，单位死亡、建筑被摧毁。\n"
				% int(round(r * 100.0))
				+ "战斗时看单位头顶那条血条，这里只报精确数字。",
		"foot": "",
	}


## 法力那一行
static func mana(u: Node3D) -> Dictionary:
	if u == null or not u.has_method("has_mana") or not bool(u.call("has_mana")):
		return {}
	var mx: float = float(u.call("max_mana"))
	var cur: float = float(u.get("mana"))
	var d: UnitDef = _def(u)
	var regen: float = d.mana_regen if d != null else 0.0
	var body: String = "余量 [b]%d%%[/b]" % int(round(clampf(cur / maxf(mx, 1.0), 0.0, 1.0) * 100.0))
	if regen > 0.0:
		body += " · 每秒回 [b]%s[/b] 点，回满约 %.0f 秒" % [fmt(regen), (mx - cur) / regen]
	if d != null and d.mana_cost > 0.0:
		body += "\n施放一次消耗 [b]%s[/b] 点。" % fmt(d.mana_cost)
	return {
		"icon": "mana",
		"icon_color": Color(0.42, 0.70, 1.0),
		"title": "法力 %s / %s" % [fmt(cur), fmt(mx)],
		"tag": "魔法值",
		"body": body,
		"foot": "",
	}


# ===========================================================================
# 单位 / 建筑的三行数值（中段竖排那三行）
# ===========================================================================

## `key` 见下面各级分支；返回的字典直接喂 RtsTipLayer
static func stat(d: UnitDef, key: String, u: Node3D = null) -> Dictionary:
	if d == null:
		return {}
	match key:
		"attack":
			if d.attack_damage <= 0.0:
				return {"icon": "sword", "icon_color": Color(0.7, 0.7, 0.68),
						"title": "没有攻击能力",
						"tag": "攻击",
						"body": "这个单位不会主动攻击。它能做的只有移动、采集或建造。",
						"foot": ""}
			# 一行一个信息点：中文会在任意两字之间折行，句子写太长就会出现
			# "单次 19 / 点。"这种只剩两个字的孤行。
			var body: String = "每 [b]%s 秒[/b] 一发 · 单次 [b]%s[/b] 点" % [
					fmt(d.attack_cooldown), fmt(d.attack_damage)]
			if d.attack_spread > 0.0:
				body += "（±%s 浮动）" % fmt(d.attack_spread)
			body += "\n秒伤约 [b]%s[/b]（未计暴击）" % fmt(dps(d))
			body += "\n" + counter_line(d.attack_type)
			return {
				"icon": "sword", "icon_color": Color(0.98, 0.62, 0.42),
				"title": "%s攻击 · %s" % [dmg_name(d.attack_type), fmt(d.attack_damage)],
				"tag": "伤害类型",
				"body": "%s\n%s" % [dmg_how(d.attack_type), body],
				"foot": "" if d.attack_range <= 0.0 else "射程 %s（超出就打不到）" % fmt(d.attack_range_value),
			}
		"armor":
			var pct: int = mitigation_pct(d.armor)
			return {
				"icon": "shield", "icon_color": Color(0.62, 0.78, 0.98),
				"title": "%s甲 · %s" % [armor_name(d.armor_type), fmt(d.armor)],
				"tag": "护甲类型",
				"body": "每 1 点护甲按比例削减受到的伤害，当前减免 [b]%d%%[/b]。\n"
						% pct
						+ "护甲类型决定被什么克制：%s。\n" % _armor_counter_hint(d.armor_type)
						+ "铁匠铺的「护甲锻造」每级 +1 点，最多 5 级。",
				"foot": "",
			}
		"speed":
			var sp: float = d.move_speed
			var per_screen: float = 46.0 / maxf(sp, 0.1)
			return {
				"icon": "move", "icon_color": Color(0.72, 0.88, 0.56),
				"title": "移动 · %s 米/秒" % fmt(sp),
				"tag": "移速",
				"body": "从基地走到地图中心（约 46 米）要 [b]%.0f 秒[/b]。\n" % per_screen
						+ "[color=#a8a49a]（不含地形减速与队列拥堵）[/color]",
				"foot": "",
			}
		"range":
			# ★ 2026-11-08 口径：界面显示的是**游戏射程数值**（1 / 1.2 / 1.5 / 10 / 13），
			#   不是米。米只给引擎判定用，换算只有一处：代码/配置/射程基准.gd（定死）。
			if d.attack_range_value < 1.0:
				return {
					"icon": "sword", "icon_color": Color(0.98, 0.62, 0.42),
					"title": "近战 · 贴身",
					"tag": "攻击距离",
					"body": "只要双方身体贴住就一定能打到（射程数值 [b]%s[/b] 是留的余量，不是武器长度）。\n"
							% fmt(d.attack_range_value)
							+ "身体没贴住就打不到，会自己向前贴近。",
					"foot": "",
				}
			return {
				"icon": "bow", "icon_color": Color(0.86, 0.80, 0.52),
				"title": "射程 · %s" % fmt(d.attack_range_value),
				"tag": "攻击距离",
				"body": "从[b]自己的身体边缘[/b]算起，超出这个射程就打不到目标。\n"
						+ "选中时地上的圈 = 射程 + 自身半径，圈边就是真正的够得着边界。\n"
						+ "[color=#a8a49a]（游戏射程 1 = %s 米，换算系数 R1 全游戏统一）[/color]" % fmt(RANGE_BASE.R1),
				"foot": "",
			}
		"sight":
			return {
				"icon": "eye", "icon_color": Color(0.66, 0.86, 0.92),
				"title": "视野 · %s 米" % fmt(d.sight_range),
				"tag": "侦察",
				"body": "能揭开战争迷雾的半径。视野外的敌人看不见、也点不到。",
				"foot": "",
			}
		"detect":
			return {
				"icon": "eye", "icon_color": Color(0.98, 0.78, 0.52),
				"title": "预警 · %s 米" % fmt(d.detect_radius),
				"tag": "哨戒",
				"body": "敌人一进这个圈就在小地图上报警，但它自己**不会攻击**。",
				"foot": "",
			}
		"pop":
			return {
				"icon": "house", "icon_color": Color(0.80, 0.88, 0.66),
				"title": "人口 +%d" % d.food_provided,
				"tag": "人口上限",
				"body": "每座农场 +8 人口上限。人口满了就训练不出新兵。",
				"foot": "",
			}
		"train_time":
			return {
				"icon": "gear", "icon_color": Color(0.80, 0.80, 0.76),
				"title": "建造 · %d 秒" % int(round(d.train_time)),
				"tag": "耗时",
				"body": "从放下地基到完工需要 %d 秒，期间最怕被打断。\n造价 %d 金 / %d 木。"
						% [int(round(d.train_time)), d.gold_cost, d.wood_cost],
				"foot": "",
			}
		"trainable":
			return {
				"icon": "gear", "icon_color": Color(0.86, 0.82, 0.52),
				"title": "可训练 %d 种" % d.trains.size(),
				"tag": "兵营",
				"body": _list_units(d.trains),
				"foot": "训练入口在右下命令卡",
			}
		"researchable":
			return {
				"icon": "upgrade", "icon_color": Color(0.86, 0.78, 1.0),
				"title": "可研究 %d 项" % d.researches.size(),
				"tag": "科技",
				"body": _list_research(d.researches),
				"foot": "研究入口在右下命令卡",
			}
	return {}


static func _armor_counter_hint(armor_type: int) -> String:
	match armor_type:
		RtsConst.ArmorType.HEAVY:
			return "穿刺打它减伤、魔法打它加成"
		RtsConst.ArmorType.FORTIFIED:
			return "攻城打得动，穿刺几乎无效"
		RtsConst.ArmorType.NONE:
			return "什么都不抗，纯靠血量"
		_:
			return "穿刺打它加成，普通攻击略吃亏"


static func _list_units(ids: Array) -> String:
	var out: Array[String] = []
	for id in ids:
		var ud: UnitDef = Cfg.unit(id) if Cfg.game != null else null
		if ud == null:
			out.append(String(id))
			continue
		out.append("[b]%s[/b] %d金 %d木 %.0fs" % [ud.display_name, ud.gold_cost,
				ud.wood_cost, ud.train_time])
	return "\n".join(out) if not out.is_empty() else "（空）"


static func _list_research(ids: Array) -> String:
	var out: Array[String] = []
	for id in ids:
		var rd: ResearchDef = Cfg.research(id) if Cfg.game != null else null
		if rd == null:
			out.append(String(id))
			continue
		out.append("[b]%s[/b] 最高 %d 级 · %d金 %d木" % [rd.display_name, rd.max_level,
				rd.gold_cost, rd.wood_cost])
	return "\n".join(out) if not out.is_empty() else "（空）"


# ===========================================================================
# 队列 / 研究 / 训练
# ===========================================================================

## 训练队列里的一格：这个兵是什么、还要多久
static func queue_item(id: StringName, index: int, progress: float, running: bool) -> Dictionary:
	var d: UnitDef = Cfg.unit(id) if Cfg.game != null else null
	if d == null:
		return {"title": String(id), "body": "", "icon": "shield"}
	var lines: Array[String] = []
	lines.append("[color=#b9b6a8]%s[/color]" % kind_name(d))
	if d.attack_damage > 0.0:
		lines.append("攻击 %s（%s）· 护甲 %s（%s）" % [fmt(d.attack_damage),
				dmg_name(d.attack_type), fmt(d.armor), armor_name(d.armor_type)])
	lines.append("生命 %s · 移速 %s" % [fmt(d.max_hp), fmt(d.move_speed)])
	lines.append("造价 %d 金 / %d 木 · 训练 %d 秒" % [d.gold_cost, d.wood_cost,
			int(round(d.train_time))])
	var tag: String = "第 %d 位" % (index + 1)
	if running:
		tag = "训练中 %d%%" % int(round(progress * 100.0))
		lines.append("剩余 [b]%.1f 秒[/b]" % (maxf(1.0 - progress, 0.0) * d.train_time))
	return {
		"icon": "gear", "icon_color": Color(0.62, 0.84, 1.0),
		"tex": _portrait_tex(d),
		"title": d.display_name, "tag": tag,
		"body": "\n".join(lines),
		"foot": "",
	}


## 研究进度那一行
static func research(rid: StringName, level: int, max_level: int, progress: float) -> Dictionary:
	var rd: ResearchDef = Cfg.research(rid) if Cfg.game != null else null
	var name_: String = rd.display_name if rd != null else String(rid)
	var body: String = ""
	if rd != null and not rd.description.is_empty():
		body = rd.description
	else:
		body = "把这项科技再升一级。"
	body += "\n当前 [b]%d / %d[/b] 级" % [level, max_level]
	if progress > 0.0:
		body += " · 进行中 %d%%" % int(round(progress * 100.0))
	if rd != null:
		body += "\n每级 %d 金 / %d 木 · %d 秒" % [rd.gold_cost, rd.wood_cost,
				int(round(rd.research_time))]
	return {
		"icon": "upgrade", "icon_color": Color(0.80, 0.74, 1.0),
		"title": name_, "tag": "%d / %d 级" % [level, max_level],
		"body": body, "foot": "",
	}


# ===========================================================================
# 小工具
# ===========================================================================

static func _def(u: Node3D) -> UnitDef:
	if u == null or not is_instance_valid(u):
		return null
	return u.get("def") as UnitDef


static func _team_color(u: Node3D, d: UnitDef) -> Color:
	if u != null:
		var f: RtsFaction = u.get("faction") as RtsFaction
		if f != null:
			return f.color
	if d != null and d.is_harvestable():
		return Spec.gold()
	return Color(0.72, 0.76, 0.82)


## 单位/建筑的头像贴图（有就用真头像，没有就 null → 气泡退回线描图标）
static func _portrait_tex(d: UnitDef) -> Texture2D:
	if d == null:
		return null
	return Spec.building_icon(d.id) if d.is_building() else Spec.unit_icon(d.id)


static func _icon_hint(d: UnitDef) -> String:
	if d == null:
		return "shield"
	if d.is_building():
		return "house"
	match String(d.id):
		"peasant", "worker":
			return "hammer"
		"footman", "soldier", "swordsman":
			return "sword"
		"archer", "crossbow", "rifleman":
			return "bow"
		"mage", "priest":
			return "staff"
	return "shield"
