// =============================================================================
//  地形.gdshader  —— 低多边形地形（RIDGE 2026-10-18 视觉重做）
// -----------------------------------------------------------------------------
//  这版专治三处"廉价感"：
//    1) 台地顶一块米白圆盘 → 用 plateau 地标做"草皮 + 土斑 + 碎石 + 磨损边"，
//       接缝不再靠一刀切的顶点色；
//    2) 崖壁竖向拉伸条纹 → 三平面噪声（XY/YZ 投影，不被竖面拉长）+ 水平岩层硬分层
//       + 竖向裂隙 + 崖脚冷影；同时按噪声梯度扰动 NORMAL，让平面着色的崖面有起伏；
//    3) 草地大色块 → 两级世界噪声 + 1.75m 面片哈希，低多边形块面有明暗层次。
//
//  ★ 顶点色：地形.gd 仍把"草/土/岩"写进 COLOR，这里以顶点色为底，
//    只用 layer 色阶/噪声做细化。COLOR 的口径是线性原值（不额外 pow）。
//  ★ 全部程序化，无纹理/无联网依赖。
// =============================================================================
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert;

uniform vec4  grass_color : source_color = vec4(0.27, 0.40, 0.19, 1.0);
uniform vec4  dirt_color : source_color = vec4(0.40, 0.30, 0.17, 1.0);
uniform vec4  rock_color : source_color = vec4(0.34, 0.34, 0.35, 1.0);
uniform vec4  scree_color : source_color = vec4(0.34, 0.32, 0.28, 1.0);

// 台地地标（RtsTerrain 在 build 前写入；0 半径 = 没有台地，效果自动关闭）
uniform vec2  plateau_center = vec2(0.0, 0.0);
uniform float plateau_radius = 0.0;
uniform float plateau_top = 0.0;
uniform float top_grass_strength : hint_range(0.0, 1.0) = 0.68;
uniform float cliff_strength : hint_range(0.0, 1.0) = 0.80;

uniform float noise_amt : hint_range(0.0, 0.6) = 0.16;
uniform float strata_scale : hint_range(0.4, 4.0) = 1.95;
uniform float bump_strength : hint_range(0.0, 1.0) = 0.34;
uniform float facet_strength : hint_range(0.0, 0.4) = 0.09;
uniform float grid_strength : hint_range(0.0, 0.2) = 0.025;
uniform float grid_size = 1.0;

uniform float band_edge_a : hint_range(0.0, 1.0) = 0.36;
uniform float band_edge_b : hint_range(0.0, 1.0) = 0.70;
uniform float band_soft : hint_range(0.001, 0.25) = 0.06;
uniform vec3  shadow_color : source_color = vec3(0.28, 0.34, 0.48);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.62;

// ---------------------------------------------------------------------------
// v5 地表细节层（"地图的每一格都要有东西"）
// ---------------------------------------------------------------------------
// 程序化噪声最多给到 0.8m 级（再高频就得在片元里多采样几次，代价划不来），
// 而"一眼看得出是草地/土路"的信息全在 1~20cm 级：草叶、砂粒、小石子。
// 这两组可平铺贴图（512²）就是补这一段的，三平面投影，竖崖上也不会被拉伸。
uniform sampler2D detail_grass : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_dirt : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_grass_col : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_dirt_col : source_color, filter_linear_mipmap, repeat_enable;
uniform float detail_on : hint_range(0.0, 1.0) = 1.0;
uniform float detail_tile = 1.65;
uniform float detail_normal_strength : hint_range(0.0, 1.5) = 0.62;
uniform float detail_albedo_strength : hint_range(0.0, 1.0) = 0.26;

varying vec3 v_world;
varying vec3 v_wn;
varying vec3 v_col;

float hash21(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// 三平面取色 / 取法线（法线按各平面的切/副切基拼回世界空间）
vec3 tri_col(sampler2D s, vec3 p, vec3 w) {
    return texture(s, p.zy).rgb * w.x
         + texture(s, p.xz).rgb * w.y
         + texture(s, p.xy).rgb * w.z;
}

vec3 tri_nrm(sampler2D s, vec3 p, vec3 w) {
    vec3 a = texture(s, p.zy).rgb * 2.0 - 1.0;
    vec3 b = texture(s, p.xz).rgb * 2.0 - 1.0;
    vec3 c = texture(s, p.xy).rgb * 2.0 - 1.0;
    return vec3(0.0, a.y, a.x) * w.x
         + vec3(b.x, 0.0, b.y) * w.y
         + vec3(c.x, c.y, 0.0) * w.z;
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

// 三平面噪声：竖崖上取 XY/YZ，不会被 UV 拉伸成竖条
float tri_noise(vec3 p, vec3 w) {
    return vnoise(p.xz) * w.y + vnoise(p.xy) * w.z + vnoise(p.zy) * w.x;
}

void vertex() {
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
    v_col = COLOR.rgb;
}

void fragment() {
    vec3 wn = normalize(v_wn);
    vec3 tw = abs(wn);
    tw /= (tw.x + tw.y + tw.z + 0.0001);
    float upness = clamp(wn.y, 0.0, 1.0);

    // 三级世界噪声（尺寸从 12m 到 1m）
    float n_big = tri_noise(v_world * 0.085, tw);
    float n_mid = tri_noise(v_world * 0.31 + vec3(7.1, 3.3, 11.7), tw);
    float n_fine = tri_noise(v_world * 1.25 + vec3(19.3, 5.7, 2.1), tw);

    // 顶点色是主色；整体压到 0.58，避免线性色在暖阳下泛成粉绿
    vec3 base = v_col * 0.44;
    base *= 0.94 + n_big * noise_amt + (n_mid - 0.5) * noise_amt * 0.55;

    // -------------------------------------------------------------------
    // 12m 级草甸斑块：深色三叶草 / 枯草 / 被踩出的土斑。
    // 这一层专治"整片地一个颜色"：低多边形每一格都长一样，
    // 只有把低频斑块压到 10m 尺度，RTS 俯视才有"地块"而不是"色块"。
    // -------------------------------------------------------------------
    float flat_mask = smoothstep(0.66, 0.88, upness);
    float patch_dark = smoothstep(0.46, 0.70, 1.0 - n_big * 0.72 - n_mid * 0.28);
    float patch_dry  = smoothstep(0.56, 0.78, n_big * 0.80 + n_mid * 0.20);
    base = mix(base, vec3(0.055, 0.115, 0.038), patch_dark * 0.42 * flat_mask);
    base = mix(base, vec3(0.300, 0.275, 0.105), patch_dry * 0.30 * flat_mask);
    // 极稀疏的土斑（不是整片沙地）：12m 网格里只挑最亮的 8%
    float bare = smoothstep(0.74, 0.86, n_big * 0.65 + n_fine * 0.35);
    base = mix(base, vec3(0.300, 0.225, 0.125), bare * 0.35 * flat_mask);

    // -------------------------------------------------------------------
    // 台地顶：草/土过渡 + 边缘磨损 + 零星碎石
    // -------------------------------------------------------------------
    float rad = distance(v_world.xz, plateau_center);
    float top_mask = smoothstep(plateau_top - 1.8, plateau_top - 0.5, v_world.y)
                   * (1.0 - smoothstep(plateau_radius - 7.5, plateau_radius - 3.4, rad))
                   * smoothstep(0.64, 0.84, upness);
    if (top_mask > 0.001) {
        vec3 grass_top = mix(grass_color.rgb * 0.72, grass_color.rgb * 1.05, n_mid);
        vec3 dirt_top = mix(dirt_color.rgb * 0.72, dirt_color.rgb * 1.02, n_fine);
        float patch = smoothstep(0.48, 0.62, n_big * 0.60 + n_mid * 0.40 + (n_fine - 0.5) * 0.22);
        vec3 top_col = mix(grass_top, dirt_top, patch * 0.62);
        // 顶面外圈：草皮被踩秃，露出土和碎石
        float rim = smoothstep(plateau_radius - 8.5, plateau_radius - 3.8, rad);
        top_col = mix(top_col, mix(dirt_color.rgb * 0.80, scree_color.rgb * 0.80, 0.35), rim * 0.55);
        // 细碎石子
        float pebble = smoothstep(0.80, 0.92, n_fine) * (0.35 + patch);
        top_col = mix(top_col, rock_color.rgb * 0.72, clamp(pebble, 0.0, 0.55));
        base = mix(base, top_col * 0.82, top_mask * top_grass_strength);
    }

    // -------------------------------------------------------------------
    // 陡崖：水平岩层 + 竖向裂隙 + 崖脚冷影/碎石
    // -------------------------------------------------------------------
    // 55° 左右的围栏内壁也要吃岩层色（upness≈0.57），不能只认 >60°
    float cliff = smoothstep(0.70, 0.30, upness);
    if (cliff > 0.001) {
        float phase = v_world.y * strata_scale + n_mid * 2.4 + n_big * 3.0;
        // 3 档硬岩层（低多边形要的是"层理"，不是柔和渐变）
        float band = floor(fract(phase) * 3.0) / 3.0;
        float seam = smoothstep(0.0, 0.045, fract(phase)) * (1.0 - smoothstep(0.955, 1.0, fract(phase)));
        vec3 cliff_col = mix(rock_color.rgb * 0.30, rock_color.rgb * 1.06, band);
        // 层间缝：一条更暗的细线，读得出沉积层
        cliff_col *= 0.82 + 0.18 * seam;
        // 裂隙：竖向噪声（XY/YZ），不是沿 y 的一条直线
        float crack = smoothstep(0.70, 0.90, tri_noise(vec3(v_world.x * 0.95, v_world.y * 0.32, v_world.z * 0.95), tw));
        cliff_col *= 1.0 - crack * 0.42;
        // 崖脚越低压得越暗、越冷
        float low = smoothstep(3.6, -1.6, v_world.y);
        cliff_col = mix(cliff_col, vec3(0.115, 0.145, 0.195), low * 0.45);
        cliff_col *= mix(0.60, 1.0, smoothstep(-0.5, 5.5, v_world.y));
        base = mix(base, cliff_col, cliff * cliff_strength);

        // 崖脚碎石带：颜色先铺一层，几何碎石由 RtsLevel 的 MultiMesh 补
        float foot = smoothstep(2.9, 0.1, v_world.y) * smoothstep(0.30, 0.62, n_fine);
        base = mix(base, scree_color.rgb * 0.72, foot * 0.42);
    }

    // 1.75m 面片哈希：低多边形的块面明暗（不是逐像素脏斑）
    float facet = hash21(floor(v_world.xz / 1.75) + vec2(v_world.y * 0.37, 3.7));
    base *= 1.0 + (facet - 0.5) * facet_strength;

    // 极淡的 1m 格线（建格子/寻路格可读性）
    vec2 g = abs(fract(v_world.xz / grid_size - 0.5) - 0.5) * grid_size;
    float line = 1.0 - smoothstep(0.0, 0.035, min(g.x, g.y));
    base *= 1.0 - line * grid_strength;

    // -------------------------------------------------------------------
    // v5：贴图细节层（草 / 土 两套，按地表类型混合）
    // -------------------------------------------------------------------
    vec3 dn = vec3(0.0);
    if (detail_on > 0.001) {
        vec3 q = v_world / max(detail_tile, 0.2);
        // 草地还是土：跟"台地顶草皮/土斑"同一套判据（低频噪声 + 坡度）
        float grassy = smoothstep(0.34, 0.66, n_big * 0.55 + n_mid * 0.45 + upness * 0.25);
        vec3 dn_g = tri_nrm(detail_grass, q, tw);
        vec3 dn_d = tri_nrm(detail_dirt, q, tw);
        dn = mix(dn_d, dn_g, grassy);
        vec3 dc = mix(tri_col(detail_dirt_col, q, tw), tri_col(detail_grass_col, q, tw), grassy);
        // 细节色乘算（均值 0.9 → ×1.11 拉回中性）；只在平缓面全量，崖面减半，
        // 否则崖壁会被草纹糊掉岩层
        // 0.26 是实测值：再高就把顶点色的大色块（草地/土路/岩层的分区）洗淡，
        // 地表会变成一层均匀的浅黄绿——细节是补质感，不是盖掉配色。
        float k = detail_albedo_strength * mix(0.35, 1.0, upness);
        base *= mix(vec3(1.0), dc * 1.11, k);
    }

    // 法线扰动：程序化噪声明暗只作用在崖面，贴图法线补足近景（草叶/砂粒/卵石）
    float e = 0.32;
    float h0 = tri_noise(v_world * 1.45, tw);
    float hx = tri_noise((v_world + vec3(e, 0.0, 0.0)) * 1.45, tw);
    float hz = tri_noise((v_world + vec3(0.0, 0.0, e)) * 1.45, tw);
    vec3 grad = vec3(hx - h0, 0.0, hz - h0) / e;
    vec3 world_n = normalize(wn - grad * (bump_strength * cliff)
                             + dn * (detail_normal_strength * detail_on));
    NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);

    ALBEDO = clamp(base, vec3(0.0), vec3(1.0));
    ROUGHNESS = 0.94;
    METALLIC = 0.0;
    SPECULAR = 0.0;
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