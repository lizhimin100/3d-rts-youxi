extends RefCounted
## **战略计划表**（纯数据）。改这里 = 改 AI 的"性格"，不需要碰一行逻辑。
##
## 每条计划是一条"条件 → 姿态"规则：
##   id        唯一名字（日志与自检断言用）
##   priority  越大越优先；>= 90 无视滞回立即切换（紧急防守就是 100）
##   stance    姿态标签（日志/调试用）
##   when      {"all": [{metric, op, value}, …]}；空字典 = 恒成立（兜底）
##   params    产出给经济/军事模块的旋钮
##
## 可用 metric（全由 代码/ai/战略导演.gd 每次思考算出来）：
##   time  gold  wood  workers  idle_workers  army_count  army_food  army_ratio
##   food_used  food_cap  food_headroom  base_threat  under_attack  buildings
##   enemy_static_defense  gold_float  my_army_value
##
## 为什么用"声明式数据"而不是在代码里写 if/else 树：
##   1. 策划能直接调阈值，不用读代码；
##   2. 新流派（速攻 / 龟缩 / 双矿）只是加一条，不动既有逻辑；
##   3. 条件可以被自检直接断言（"这一帧应该选 press 而不是 open_economy"）。
##
## 注意：**"能不能主动出击"不在这里配**。那是 战略导演 按战力比 + 静态防御 +
## 是否有敌人压家算出来的（见 `_compute_allow_attack`）。把"出击许可"写进
## 计划表会变成"某个流派永远不打/永远送"，两头都错。

static func build() -> Array:
	return [
		{
			"id": "emergency_defense",
			"priority": 100,
			"stance": "defend",
			"desc": "基地在挨打：全军回防，停止巡逻与贪经济",
			# ★ 2026-11-08 玩家口径「防守死锁」：触发条件从"任何压家敌人（含野怪）≥1"
			#   收紧为「战争对手 ≥1」或「压家敌人 ≥2」。
			#   旧条件只要一只豺狼人溜进基地圈，这个 priority=100 的计划就永久占位，
			#   aggression 被钉在 0.10 → `_compute_allow_attack` 的「侵略性 <0.30」一路否决，
			#   AI 整局不出门。单只野怪该由防守/清野解决，不该劫持战略层。
			#   （战略导演另有"30 秒无敌人 → 强制恢复出击许可"的兜底，见 `CALM_RELEASE_SEC`。）
			"when": {"any": [
				{"metric": "war_threat", "op": ">=", "value": 1.0},
				{"metric": "base_threat", "op": ">=", "value": 2.0},
			]},
			"params": {"aggression": 0.10, "worker_bonus": -2,
				"allow_patrol": false, "research": false},
		},
		{
			"id": "all_in",
			"priority": 85,
			"stance": "allin",
			"desc": "兵力大幅领先：全力一波，别再贪经济",
			"when": {"all": [
				{"metric": "army_ratio", "op": ">=", "value": 1.55},
				{"metric": "army_food", "op": ">=", "value": 20.0},
			]},
			"params": {"aggression": 1.0, "worker_bonus": -2,
				"allow_patrol": false, "research": false},
		},
		{
			"id": "press_advantage",
			"priority": 60,
			"stance": "pressure",
			"desc": "兵力领先：压上去，边打边补",
			"when": {"all": [
				{"metric": "army_ratio", "op": ">=", "value": 1.2},
				{"metric": "army_food", "op": ">=", "value": 12.0},
			]},
			"params": {"aggression": 0.8, "worker_bonus": 0,
				"allow_patrol": true, "research": false},
		},
		{
			"id": "expand_econ",
			"priority": 40,
			"stance": "economy",
			"desc": "安全且有钱：贪一波农民与经济",
			"when": {"all": [
				{"metric": "workers", "op": ">=", "value": 10.0},
				{"metric": "base_threat", "op": "<", "value": 1.0},
				{"metric": "gold", "op": ">", "value": 320.0},
			]},
			"params": {"aggression": 0.35, "worker_bonus": 3,
				"allow_patrol": true, "research": false},
		},
		{
			"id": "tech_up",
			"priority": 30,
			"stance": "tech",
			"desc": "中期：把钱砸进铁匠铺升级，用质量换数量",
			"when": {"all": [
				{"metric": "time", "op": ">", "value": 150.0},
				{"metric": "workers", "op": ">=", "value": 8.0},
				{"metric": "base_threat", "op": "<", "value": 1.0},
			]},
			"params": {"aggression": 0.5, "worker_bonus": 0,
				"allow_patrol": true, "research": true},
		},
		{
			"id": "open_economy",
			"priority": 20,
			"stance": "economy",
			"desc": "开局：先运营，别送",
			"when": {"all": [{"metric": "time", "op": "<", "value": 150.0}]},
			"params": {"aggression": 0.30, "worker_bonus": 2,
				"allow_patrol": true, "research": false},
		},
		{
			"id": "default_mid",
			"priority": 0,
			"stance": "balanced",
			"desc": "兜底：均衡发展",
			"when": {},
			"params": {"aggression": 0.5, "worker_bonus": 0,
				"allow_patrol": true, "research": true},
		},
	]
