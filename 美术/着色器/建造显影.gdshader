// 建造显影：给**美术资产的建造模型**做"从地面往上长"的世界高度裁剪。
//
// 为什么需要它：`<建筑>_建造.glb` 的资产规范里，建筑本体的显影靠材质里的
// 世界高度裁剪（uniform `reveal_height`），而那个 shader 不在资产仓库里。
// 我们这边如果不做裁剪，只剩两条路：
//   ① 整模纵向 scale —— 窗户/门被压扁，近景一眼假；
//   ② 不裁剪 —— 一放下去就是一栋完整的楼，看不见"在建"。
// 所以这里补一份空间着色器：片元世界 Y 超过 `clip_world_y` 直接 discard。
//
// 只对 StandardMaterial3D 生效（在 工地表现.gd 里按材质逐个转换），
// 转换时把 albedo / ORM / 自发光三张贴图搬过来，视觉与资产原材质一致。
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx, depth_draw_opaque;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec2 uv_scale = vec2(1.0, 1.0);

// R=AO / G=粗糙度 / B=金属度（和铁誓资产包同一口径）
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform float roughness_scale : hint_range(0.0, 2.0) = 1.0;
uniform float metallic_add : hint_range(-1.0, 1.0) = 0.0;

uniform sampler2D emission_tex : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 1.0;

// 世界坐标高度上限：片元在它之上就被切掉（对应建造进度）
uniform float clip_world_y = 1.0e9;
// 切口那一薄层加一点自发光，远看能看出"墙在往上长"
uniform float edge_glow : hint_range(0.0, 3.0) = 0.0;
uniform vec4 edge_color : source_color = vec4(0.62, 0.86, 1.0, 1.0);
uniform float edge_width = 0.07;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float cut = clip_world_y - v_world.y;
	if (cut < 0.0) {
		discard;
	}
	vec2 uv = UV * uv_scale;
	vec4 base = texture(albedo_tex, uv) * albedo_color;
	ALBEDO = base.rgb;
	vec3 orm = texture(orm_tex, uv).rgb;
	AO = mix(1.0, orm.r, ao_strength);
	ROUGHNESS = clamp(orm.g * roughness_scale, 0.05, 1.0);
	METALLIC = clamp(orm.b + metallic_add, 0.0, 1.0);
	EMISSION = texture(emission_tex, uv).rgb * emission_color.rgb * emission_energy;
	if (edge_glow > 0.0 && cut < edge_width) {
		EMISSION += edge_color.rgb * edge_glow * (1.0 - cut / edge_width);
	}
}
