// =============================================================================
//  地形.gdshader  —— 低多边形地形
// -----------------------------------------------------------------------------
//  用途：草 / 土 / 岩三色阶按**高度 + 坡度**分层，叠一点三平面噪声打破平整感，
//        光照同样硬阶梯、阴影偏冷，和角色材质是同一套世界观。
//  ★ 顶点色：`代码/核心/地形.gd` 用 vertex_color_is_srgb=true 喂顶点色，
//    所以这里 **COLOR 就是基色**（再乘 height_tint 做高度冷暖）。color_pow
//    留成 uniform：实测如果顶点色被引擎转过一次线性，把它调成 1.0 即可，
//    不用改代码（这是唯一能在运行时对齐 sRGB 口径的旋钮）。
//  关键参数：grass_h / dirt_h 分层高度；noise_scale/amt 噪声；band_* 色阶分界。
// =============================================================================
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert;

uniform vec4  grass_color : source_color = vec4(0.44, 0.52, 0.29, 1.0);
uniform vec4  dirt_color : source_color = vec4(0.56, 0.43, 0.27, 1.0);
uniform vec4  rock_color : source_color = vec4(0.58, 0.57, 0.53, 1.0);
uniform float grass_h : hint_range(-4.0, 12.0) = 1.10;
uniform float dirt_h : hint_range(-4.0, 20.0) = 6.0;
uniform float blend_soft : hint_range(0.01, 2.0) = 0.30;
uniform float slope_rock : hint_range(0.0, 1.0) = 0.62;

uniform float color_pow : hint_range(0.4, 3.0) = 1.0;
uniform float use_vertex_color : hint_range(0.0, 1.0) = 1.0;
uniform float noise_scale = 0.32;
uniform float noise_amt : hint_range(0.0, 0.6) = 0.07;
uniform float grid_strength : hint_range(0.0, 0.4) = 0.03;
uniform float grid_size = 1.0;
// ★ 色阶对基色的影响强度。顶点色本身已经是"草/土/岩按高度坡度混好的基色"，
//   这里再整层相乘就会叠出脏斑（曾经在基地左侧叠出一大片橙色污渍）。
//   所以它只作为**轻度染色**存在，默认 0.22。
uniform float layer_strength : hint_range(0.0, 1.0) = 0.80;
// 高度噪声扰动幅度（米）。太大就会出现整片整片的土色斑块
uniform float height_noise : hint_range(0.0, 4.0) = 0.55;

uniform float band_edge_a : hint_range(0.0, 1.0) = 0.36;
uniform float band_edge_b : hint_range(0.0, 1.0) = 0.68;
uniform float band_soft : hint_range(0.001, 0.2) = 0.02;
uniform vec3  shadow_color : source_color = vec3(0.32, 0.40, 0.60);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.66;

varying vec3 v_world;
varying vec3 v_wn;
varying vec3 v_col;
varying float v_upness;

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
    v_col = pow(max(COLOR.rgb, vec3(0.0)), vec3(color_pow));
    v_upness = clamp(v_wn.y, 0.0, 1.0);
}

void fragment() {
    // 噪声（两个尺度叠加 + 三平面取 XZ / XY 折中）
    float n1 = vnoise(v_world.xz * noise_scale);
    float n2 = vnoise(v_world.xz * noise_scale * 3.7 + 11.3);
    float n = (n1 * 0.7 + n2 * 0.3) - 0.5;

    // 高度分层：草 → 土 → 岩
    float h = v_world.y + n * height_noise;
    float a = smoothstep(grass_h - blend_soft, grass_h + blend_soft, h);
    float b = smoothstep(dirt_h - blend_soft, dirt_h + blend_soft, h);
    vec3 layer = mix(grass_color.rgb, dirt_color.rgb, a);
    layer = mix(layer, rock_color.rgb, b);
    // 陡坡露岩（低多边形地形靠这条把"断崖"表达出来）
    float steep = smoothstep(slope_rock, slope_rock + 0.22, 1.0 - v_upness);
    layer = mix(layer, rock_color.rgb, steep);

    // 顶点色是主色，色阶只做轻度染色（相乘会叠出脏斑，见 layer_strength 注释）
    vec3 base = v_col * mix(vec3(1.0), layer, layer_strength);
    base = mix(base, v_col * layer, 1.0 - use_vertex_color);
    base *= 1.0 + n * noise_amt;

    // 网格感：极淡的格子线（RTS 建格子/寻路格的可读性）
    vec2 g = abs(fract(v_world.xz / grid_size - 0.5) - 0.5) * grid_size;
    float line = 1.0 - smoothstep(0.0, 0.035, min(g.x, g.y));
    base *= 1.0 - line * grid_strength;

    ALBEDO = base;
    ROUGHNESS = 0.94;
    METALLIC = 0.0;
}

void light() {
    vec3 n = normalize(NORMAL);
    vec3 l = normalize(LIGHT);
    float lam = dot(n, l) * 0.5 + 0.5;
    float ba = smoothstep(band_edge_a - band_soft, band_edge_a + band_soft, lam);
    float bb = smoothstep(band_edge_b - band_soft, band_edge_b + band_soft, lam);
    float band = clamp(ba * 0.5 + bb * 0.5, 0.0, 1.0);
    vec3 shade = mix(shadow_color * shadow_strength, vec3(1.04), band);
    DIFFUSE_LIGHT += shade * ATTENUATION * LIGHT_COLOR / PI;
}
