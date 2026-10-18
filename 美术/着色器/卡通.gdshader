// 卡通主体着色器（v3 骨骼模型专用）
// 设计口径：
//   * 用 Godot 内建的 diffuse_toon 光照模型做色阶，不手写 light() —— 这样阴影/多光源/Forward+ 都天然正确，
//     不会出现"自己写光但漏掉阴影"的经典坑；
//   * 队伍色用 tint 参数注入（tint_strength=0 时完全不染色），调色板改色只改 uniform；
//   * 自发光只为水晶/炉火这类"会亮"的 zone 服务。
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

// 整体反照率增益：场景的太阳+天光很亮，浅色石材不压一档会直接过曝成白片。
// 这是"显式可调"的曝光旋钮，不要偷偷改 base_color（调色板要保持语义直白）。
uniform float albedo_gain : hint_range(0.4, 1.2) = 0.84;

varying vec3 v_world_normal;

void vertex() {
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 c = mix(base_color.rgb, tint.rgb, tint_strength) * albedo_gain;
	ALBEDO = c;
	ROUGHNESS = roughness;
	METALLIC = metallic;

	// 边缘光：只吃视角，不吃光照方向 —— 让模型在暗面也有轮廓，别糊成一团
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	vec3 emit = emission_color.rgb * emission_energy;
	emit += rim_color.rgb * rim * rim_strength;
	EMISSION = emit;
}
