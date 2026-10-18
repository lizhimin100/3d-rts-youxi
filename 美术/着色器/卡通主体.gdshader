// =============================================================================
//  卡通主体.gdshader  —— 三渲二主材质（角色 / 建筑 / 道具通用）
// -----------------------------------------------------------------------------
//  用途：硬阶梯光照的卡通渲染。所有角色/建筑材质都由它派生，队伍色只改 tint。
//  关键参数：
//     base_color     基础色（各材质 .tres 里覆盖，模型本身无贴图）
//     tint           队伍色（红/蓝阵营），由 tint_strength 控制混合强度
//     band_edge_a/b  两段色阶分界（0..1，作用在 wrap 后的 N·L 上）→ 共 3 段
//     shadow_color   阴影色，**偏蓝紫**（死黑会让模型在暗处糊掉）
//     rim_*          边缘光（Fresnel 阶梯，写 EMISSION，所以不受光照影响）
//  设计取舍：故意不写 SPECULAR_LIGHT —— 卡通材质要的是"硬色块 + 一圈亮边"，
//  高光点交给泛光（环境 bloom 阈值 1.35）来处理，避免塑料感。
//  顶点色：COLOR 直接乘进基础色，地形/程序化网格可直接用顶点色分区。
// =============================================================================
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform vec4  base_color : source_color = vec4(0.76, 0.64, 0.46, 1.0);
uniform vec4  tint : source_color = vec4(0.30, 0.55, 0.95, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.0;

uniform float roughness_v : hint_range(0.0, 1.0) = 0.88;
uniform float metallic_v : hint_range(0.0, 1.0) = 0.0;

uniform float band_edge_a : hint_range(0.0, 1.0) = 0.34;
uniform float band_edge_b : hint_range(0.0, 1.0) = 0.66;
uniform float band_soft : hint_range(0.001, 0.20) = 0.012;
uniform vec3  shadow_color : source_color = vec3(0.33, 0.39, 0.62);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.70;
uniform float lit_gain : hint_range(0.0, 2.0) = 1.08;

uniform float rim_strength : hint_range(0.0, 3.0) = 0.50;
uniform float rim_width : hint_range(0.01, 1.0) = 0.38;
uniform vec3  rim_color : source_color = vec3(0.72, 0.84, 1.0);

varying vec3 v_col;

void vertex() {
    v_col = COLOR.rgb;
}

void fragment() {
    vec3 base = base_color.rgb * v_col;
    base = mix(base, tint.rgb * (0.40 + 0.60 * base), tint_strength);
    ALBEDO = base;
    ROUGHNESS = roughness_v;
    METALLIC = metallic_v;

    // 边缘光：Fresnel 阶梯（不做平滑，卡通要硬边）
    float f = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
    float rim = smoothstep(1.0 - rim_width, 1.0 - rim_width * 0.42, f);
    EMISSION = rim_color * rim * rim_strength;
}

void light() {
    vec3 n = normalize(NORMAL);
    vec3 l = normalize(LIGHT);
    // wrap 光照：背面不是全黑，而是落到最深一级色阶
    float lam = dot(n, l) * 0.5 + 0.5;
    float ba = smoothstep(band_edge_a - band_soft, band_edge_a + band_soft, lam);
    float bb = smoothstep(band_edge_b - band_soft, band_edge_b + band_soft, lam);
    float band = clamp(ba * 0.52 + bb * 0.48, 0.0, 1.0);   // 三档：0 / 0.52 / 1
    vec3 shade = mix(shadow_color * shadow_strength, vec3(lit_gain), band);
    DIFFUSE_LIGHT += shade * ATTENUATION * LIGHT_COLOR / PI;
}
