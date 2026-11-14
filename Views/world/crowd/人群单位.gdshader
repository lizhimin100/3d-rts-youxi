// 人群单位着色器 —— 动画全部在顶点阶段算，CPU 一帧都不花。
//
// 输入（MultiMesh 的 INSTANCE_CUSTOM，每实例 4 个 float）：
//   x = 动画相位（spawn 时用黄金比散列错开，整队不会齐步走）
//   y = 移动强度 0..1.4（由当前速度 / 最大速度得到）
//   z = 状态（0 空闲 / 1 行军 / 2 驻守 / 3 空中 / 4 攻击）
//   w = 队伍（0 中立 / 1..N）
//
// "补帧"分两层：
//   1. 位置：CPU 每帧对 20Hz 的两个逻辑位置做线性插值（人群渲染.draw_frame）；
//   2. 姿态：这里用 TIME（渲染帧时间）连续推进，不受 20Hz 限制——
//      腿、躯干、呼吸都是 sin 的连续函数，所以 60fps 下是平滑的。
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled, shadows_disabled;

uniform vec4 team_color_1 : source_color = vec4(0.34, 0.52, 0.78, 1.0);
uniform vec4 team_color_2 : source_color = vec4(0.78, 0.34, 0.28, 1.0);
uniform vec4 team_color_3 : source_color = vec4(0.36, 0.68, 0.40, 1.0);
uniform vec4 team_color_4 : source_color = vec4(0.72, 0.62, 0.26, 1.0);
// 模型中心到脚底的距离（米）。BoxMesh 中心在原点，1.7m 高 → 0.85
uniform float y_base = 0.85;
// 腿的顶端高度（米，从脚底算）。模型 1.7m 高，0.72 = 下 42% 算腿
uniform float leg_split = 0.72;
// 摆腿幅度（米，模型空间）
uniform float stride_amp = 0.06;
// 空中单位悬停高度
uniform float hover_amp = 0.07;

varying vec3 v_col;

void vertex() {
	float phase = INSTANCE_CUSTOM.x;
	float moving = clamp(INSTANCE_CUSTOM.y, 0.0, 1.4);
	float st = INSTANCE_CUSTOM.z;
	float tm = INSTANCE_CUSTOM.w;

	// 队伍颜色（逐实例，走 varying 传给片元）
	if (tm < 1.5) {
		v_col = team_color_1.rgb;
	} else if (tm < 2.5) {
		v_col = team_color_2.rgb;
	} else if (tm < 3.5) {
		v_col = team_color_3.rgb;
	} else {
		v_col = team_color_4.rgb;
	}

	float h = VERTEX.y + y_base;
	float leg = clamp(1.0 - h / max(leg_split, 0.01), 0.0, 1.0);
	// 左右腿用 x 的符号区分；x=0 的中线不摆（避免撕裂）
	float side = sign(VERTEX.x + 0.0001);
	// 步频随速度提高：站立 ~0，全速 ~9 rad/s
	float sw = sin(TIME * (4.6 + moving * 5.2) + phase * 6.2831853);

	// 摆腿：前后位移 + 抬脚（抬脚用 abs 保证总有一只脚着地）
	float stride = sw * side * stride_amp * moving * leg;
	VERTEX.z += stride;
	VERTEX.y -= abs(stride) * 0.32;

	// 躯干：反相轻摆 + 呼吸（站立时也有细微起伏，人群才不像塑料）
	float breath = sin(TIME * 1.7 + phase * 6.2831853) * 0.007;
	VERTEX.y += breath * (1.0 - leg);
	VERTEX.z -= sw * 0.016 * moving * (1.0 - leg);

	// 空中层：整体悬停 + 轻微俯仰
	if (st > 2.5 && st < 3.5) {
		VERTEX.y += sin(TIME * 2.1 + phase * 6.2831853) * hover_amp;
		VERTEX.x += sin(TIME * 2.1 + phase * 6.2831853 + 1.2) * hover_amp * 0.35;
	}
}

void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = 0.86;
	SPECULAR = 0.08;
}
