// 卡通主体着色器（v5：带手绘贴图 + 法线 + 顶点 AO）
//
// 设计口径：
//   * 用 Godot 内建的 diffuse_toon 光照模型做色阶，不手写 light() —— 阴影/多光源/Forward+ 天然正确；
//   * 队伍色用 tint 参数注入（tint_strength=0 时不染色），调色板改色只改 uniform；
//   * **detail_on = 0 时行为与 v4 完全一致**（老资产/无贴图的 zone 逐像素不变，可回退）；
//   * 贴图是"乘算细节层"（均值 0.9），detail_gain 是显式曝光旋钮，别用 base_color 去凑亮度；
//   * 顶点色 COLOR 是 Blender 里 Cycles 烘的接触阴影（COLOR_0），ao_strength 控制强度；
//   * 法线走 NORMAL_MAP / NORMAL_MAP_DEPTH 内建通道，切线由 glTF 的 TANGENT 提供。
shader_type spatial;
render_mode diffuse_toon, specular_schlick_ggx, cull_back;

uniform vec4 base_color : source_color = vec4(0.6, 0.6, 0.6, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.82;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;

uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.0;

uniform int ramp_steps : hint_range(1, 8) = 4;
uniform float rim_strength : hint_range(0.0, 1.0) = 0.22;
uniform vec4 rim_color : source_color = vec4(0.85, 0.92, 1.0, 1.0);

uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy : hint_range(0.0, 8.0) = 0.0;

uniform float toon_sharpness : hint_range(0.0, 1.0) = 0.35;

// 反照率增益：太阳+天光很亮，浅色石材不压一档会过曝成白片。
uniform float albedo_gain : hint_range(0.4, 1.2) = 0.94;

// --- 贴图细节层（v5） ---
uniform sampler2D detail_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float detail_on : hint_range(0.0, 1.0) = 0.0;
uniform float detail_gain : hint_range(0.5, 1.6) = 1.06;
uniform float normal_on : hint_range(0.0, 1.0) = 0.0;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;

// 施工剖切（可选）：高于 clip_height（模型局部 Y，米）的片元直接丢弃。
uniform float clip_height : hint_range(-1.0, 64.0) = -1.0;

varying vec3 v_world_normal;
varying float v_local_y;

void vertex() {
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_local_y = VERTEX.y;
}

void fragment() {
	if (clip_height >= 0.0 && v_local_y > clip_height) {
		discard;
	}

	vec3 c = mix(base_color.rgb, tint.rgb, tint_strength);

	if (detail_on > 0.001) {
		vec3 tex = texture(detail_albedo, UV).rgb;
		// 均值 0.9 → 乘 detail_gain 拉回中性，细节不会把整体压暗
		c *= mix(vec3(1.0), tex * detail_gain, detail_on);
	}

	// 顶点 AO（Blender 烘的接触阴影）：只压暗，不提亮，避免整体发灰
	if (ao_strength > 0.001) {
		float ao = clamp(COLOR.r, 0.0, 1.0);
		// ao^1.35：把接缝压得更黑一点，模型才有"硬"的体积感（实测 0.35+0.65*ao 太淡）
		float ao_k = pow(clamp(ao, 0.0, 1.0), 1.35);
		// 0.55m 烘出来的 AO 覆盖面比想象大（大部分面都在 0.5 左右），
		// 用 0.12+0.88*ao 会把整个人压成黑块（实测弓箭手变成一团深蓝）。
		// 改成 0.45+0.55*ao：只在真正的接缝处压暗，保留布料/钢甲的固有色。
		float k = mix(1.0, 0.45 + 0.55 * ao_k, ao_strength);
		c *= k;
	}

	c *= albedo_gain;
	ALBEDO = c;
	ROUGHNESS = roughness;
	METALLIC = metallic;

	if (normal_on > 0.001 && normal_strength > 0.001) {
		vec3 n = texture(detail_normal, UV).xyz * 2.0 - 1.0;
		n.xy *= normal_strength * normal_on;
		NORMAL_MAP = normalize(n);
		NORMAL_MAP_DEPTH = 1.0;
	}

	// 边缘光：只吃视角，不吃光照方向 —— 暗面也有轮廓，不糊成一团
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	vec3 emit = emission_color.rgb * emission_energy;
	emit += rim_color.rgb * rim * rim_strength;
	EMISSION = emit;
}
