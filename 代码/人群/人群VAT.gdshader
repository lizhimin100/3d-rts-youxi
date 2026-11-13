// **人群 VAT 单位着色器** —— 真模型 + 真骨骼动作，一万人一次 draw call。
//
// 数据从哪来：`工具/烘焙VAT.gd` 把一个 GLB 的 idle / walk 两套 clip 逐帧烘成两张纹理。
//   纹理布局：宽 = 顶点序号（列），高 = 2 × 帧数；
//            上半 [0, F) 是**位置** xyz，下半 [F, 2F) 是**法线** xyz；
//            用 FORMAT_RGBAH（half float）—— 8bit 存不下负坐标与 0.001 级的位移。
//   顶点序号写在网格的 UV2.x（0~1 归一化），区域写在 UV2.y（0 主体 / 1 队色 / 2 镶边）。
//
// 为什么不用骨骼矩阵 VAT：每顶点要 4 骨 × 2 帧 × 3 texel = 24 次采样，而且要求
// MultiMesh 的网格还能读到 JOINTS/WEIGHTS（引擎不保证）。顶点位置 VAT 只要 4 次采样。
//
// 错开节拍：`INSTANCE_CUSTOM.x` 是每实例的 0~1 相位（人群模拟 spawn 时按黄金比散列），
// 直接加在**帧号**上 —— 于是队列里每个人的起步帧都不同，不会"整队齐步走"。
// 注意相位必须乘 clip 帧数再取模，否则 108 帧的 idle 和 26 帧的 walk 会错出不同节奏。
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled, shadows_disabled;

uniform sampler2D vat_idle : filter_nearest, repeat_disable;
uniform sampler2D vat_walk : filter_nearest, repeat_disable;
uniform float idle_frames = 108.0;
uniform float idle_seconds = 3.6;
uniform float walk_frames = 26.0;
uniform float walk_seconds = 0.867;
// 走路播放速度区间：慢走 → 快跑（对齐主线 `单位视觉.ANIM_WALK_MPS` 的口径）
uniform float walk_speed_min = 0.75;
uniform float walk_speed_max = 1.45;
// 队伍色（4 队，和人群单位.gdshader 同一套）
uniform vec4 team_color_1 : source_color = vec4(0.34, 0.52, 0.78, 1.0);
uniform vec4 team_color_2 : source_color = vec4(0.78, 0.34, 0.28, 1.0);
uniform vec4 team_color_3 : source_color = vec4(0.36, 0.68, 0.40, 1.0);
uniform vec4 team_color_4 : source_color = vec4(0.72, 0.62, 0.26, 1.0);
uniform vec3 trim_color : source_color = vec3(0.86, 0.72, 0.42);

varying vec3 v_col;

// 取一帧的位置/法线（帧间做一次 mix —— 这就是"顶点插值补帧"）
void vat_lookup(sampler2D tex, float frames, float loop_t, float phase, float u,
		out vec3 p, out vec3 n) {
	float fpos = loop_t * frames + phase * frames;
	float f0 = floor(fpos);
	float k = fract(fpos);
	float a0 = mod(f0, frames);
	float a1 = mod(f0 + 1.0, frames);
	float inv = 1.0 / (frames * 2.0);
	vec3 p0 = texture(tex, vec2(u, (a0 + 0.5) * inv)).xyz;
	vec3 p1 = texture(tex, vec2(u, (a1 + 0.5) * inv)).xyz;
	vec3 n0 = texture(tex, vec2(u, (a0 + frames + 0.5) * inv)).xyz;
	vec3 n1 = texture(tex, vec2(u, (a1 + frames + 0.5) * inv)).xyz;
	p = mix(p0, p1, k);
	n = normalize(mix(n0, n1, k));
}

void vertex() {
	float phase = INSTANCE_CUSTOM.x;
	float moving = clamp(INSTANCE_CUSTOM.y, 0.0, 1.4);
	float tm = INSTANCE_CUSTOM.w;
	float u = UV2.x;

	vec3 p = VERTEX;
	vec3 n = NORMAL;
	if (moving > 0.12) {
		float sp = mix(walk_speed_min, walk_speed_max, clamp(moving, 0.0, 1.0));
		vat_lookup(vat_walk, walk_frames, fract(TIME * sp / max(walk_seconds, 0.001)), phase, u, p, n);
	} else {
		vat_lookup(vat_idle, idle_frames, fract(TIME / max(idle_seconds, 0.001)), phase, u, p, n);
	}
	VERTEX = p;
	NORMAL = n;

	// 队伍色：只染"队色区域"，镶边用暖金压一道
	vec3 tc = team_color_1.rgb;
	if (tm > 1.5 && tm < 2.5) {
		tc = team_color_2.rgb;
	} else if (tm > 2.5 && tm < 3.5) {
		tc = team_color_3.rgb;
	} else if (tm > 3.5) {
		tc = team_color_4.rgb;
	}
	float zone = UV2.y;
	v_col = COLOR.rgb;
	if (zone > 1.5) {
		v_col = mix(v_col, trim_color, 0.55);
	} else if (zone > 0.5) {
		v_col = mix(v_col, tc, 0.72);
	}
}

void fragment() {
	ALBEDO = v_col;
	ROUGHNESS = 0.82;
	SPECULAR = 0.06;
}
