// =============================================================================
//  地形.gdshader —— 魔兽争霸 3 式「双材质硬边地块」地形
// -----------------------------------------------------------------------------
//  这一版是重写，不是打补丁。旧版把 5 套程序化噪声 + 顶点色 + 3 张底材 + 2 套
//  细节法线 + 面片哈希 + 1m 格线全乘在一起 —— 每一层单看都对，叠起来就是
//  「很杂很乱」：10~20m 的亮黄/深绿大斑 + 1.75m 的菱形碎块 + 8m 的重复母题。
//
//  现在的口径只有一条主线：
//     地面材质由 **8m 地块** 决定，交界是一条 **硬边**（二选一，不做 alpha 混合），
//     材质存在共享格点上 → 和魔兽争霸 3 的地形编辑器完全一致。
//     · mat_map：R8，(N+1)×(N+1)，1 texel = 1 个格点 = 8m，0=草 255=泥
//     · atlas_草泥_rgba：2048×1024，左 4×4 过渡格（四角组合，德布鲁因环摆位）+
//                       右 4×4 纯纹理变体（上两行草 8 个，下两行泥 8 个）
//     R=遮罩0/255  G=有符号距离(128=交界, ±0.24m)  B=宽度抖动场
//     底材：草地.png / 泥土.png / 裂纹泥地.png（512² 无缝，8m 一铺）
//
//  顶点色退化成「染色 + 干湿」，不再承担配色：
//     rgb = 乘法染色（1.0 附近，营地压暗 / 岩壁偏冷灰 / 湿度偏移）
//     a   = 干度 0..1（0 = 泥土，1 = 裂纹泥地；两个泥种之间是软的）
//
//  陡面（崖壁）不走地块：三平面取 rock_albedo 当细节噪声 × 岩石色。
//  UV 用世界 XZ 参数化，所以换分辨率贴图不会跳。
// =============================================================================
shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_back;

// ── 地块（魔兽 3 口径）──────────────────────────────────────────────────────
uniform sampler2D mat_map : filter_nearest, repeat_disable, hint_default_black;
uniform sampler2D atlas_rgba : filter_linear_mipmap, repeat_disable;
uniform sampler2D tex_grass : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_dirt : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_cracked : source_color, filter_linear_mipmap, repeat_enable;

/// 一格多少米（必须与底材平铺距离一致；美术给的规格是 8m）
uniform float tile_m : hint_range(2.0, 32.0) = 8.0;
/// 世界 XZ 的地图半边长（米）：g = (world + map_half) / tile_m
uniform float map_half = 112.0;
/// 地块数（= 格点数 - 1）。越界时按它取模，避免 texelFetch 越界（边界裙边会踩到）。
uniform int mat_cells = 28;
uniform float sd_max_m = 0.24;
uniform float shadow_amt : hint_range(0.0, 1.0) = 0.34;
uniform float shadow_w = 0.075;
uniform float rim_amt : hint_range(0.0, 0.1) = 0.05;
uniform float rim_w = 0.028;
uniform bool variant_random = true;
uniform int variant_count : hint_range(1, 8) = 8;
/// 必须夹住：不夹的话远处一个 texel 跨过整格，16 个格子被平均成灰。
uniform float max_lod : hint_range(0.0, 8.0) = 5.0;

// ── 岩壁 ───────────────────────────────────────────────────────────────────
uniform sampler2D rock_detail : filter_linear_mipmap, repeat_enable;
uniform vec4 rock_tint : source_color = vec4(0.335, 0.325, 0.310, 1.0);
uniform float rock_scale = 4.2;
uniform float rock_detail_gain : hint_range(0.5, 4.0) = 1.85;

// ── 顶点色 ─────────────────────────────────────────────────────────────────
uniform float tint_strength : hint_range(0.0, 1.0) = 0.85;
uniform float dry_strength : hint_range(0.0, 1.0) = 0.85;
/// 两种地块的**调色**：底材是美术画的中性图，直接上会偏亮偏黄（草地几乎是荧光绿）。
/// 按魔兽 3 的 tileset 思路给两套色偏 —— 改观感不用重出贴图。
uniform vec4 mat_a_tint : source_color = vec4(0.62, 0.80, 0.50, 1.0);
uniform vec4 mat_b_tint : source_color = vec4(0.86, 0.74, 0.62, 1.0);
uniform float albedo_gain : hint_range(0.3, 1.6) = 0.96;
/// 生态换色：**只动地块，不动崖壁**。
/// 乘一个色偏没法把"绿草"变"黄沙"（乘只会变暗不变色相），所以走"亮度保留 + 色相替换"：
/// 取地块颜色的亮度当细节噪声，乘生态基色，再按 biome_mix 混回去。
/// 默认 mix=0（温带）→ 完全不影响现有观感。
uniform vec4 biome_color : source_color = vec4(0.55, 0.72, 0.46, 1.0);
uniform float biome_mix : hint_range(0.0, 1.0) = 0.0;
/// 图集法线（Sobel 自遮罩）：给出地块交界的 8mm 台阶与地面碎点的微起伏。
/// 只用很小一档（0.35）—— 这是"补质感"，不是"加噪声"。
uniform sampler2D atlas_n : filter_linear_mipmap, repeat_disable, hint_default_black;
uniform float atlas_n_strength : hint_range(0.0, 1.0) = 0.35;

// ── 三渲二光照（低多边形要的是"两阶"，不是连续渐变）────────────────────────
uniform float band_edge : hint_range(0.0, 1.0) = 0.50;
uniform float band_soft : hint_range(0.001, 0.4) = 0.14;
uniform vec3 shadow_color : source_color = vec3(0.36, 0.42, 0.56);
uniform float shadow_strength : hint_range(0.0, 1.0) = 0.55;
uniform float ambient_flat : hint_range(0.0, 0.5) = 0.10;

varying vec4 v_col;
varying vec3 v_world;
varying vec3 v_wn;

// 图集布局：8 列 × 4 行（2048×1024，一格 256）
const ivec2 ATLAS_CELLS = ivec2(8, 4);
const vec2  CELL_UV = vec2(1.0 / 8.0, 1.0 / 4.0);
const int   VAR_COL0 = 4;
const int   VAR_PER_ROW = 4;
const int   VAR_ROW_A = 0;
const int   VAR_ROW_B = 2;

// idx → (col,row)。4×4 二进制德布鲁因环落位（16 个组合一个不少，角点同源）。
// 用 idx%4 摆会拼出 16 条笔直台阶 —— 那是"网格感"的来源之一。
// 两个 2bit/位 的打包常量：col = (COL_PACK >> (idx*2)) & 3
const int COL_PACK = 1484392335;
const int ROW_PACK = 860756838;

uint tile_hash(ivec2 p) {
    uint h = uint(p.x) * 1597334677u ^ uint(p.y) * 3812015801u;
    h ^= h >> 15u;
    h *= 2246822519u;
    h ^= h >> 13u;
    return h;
}

void vertex() {
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
    v_col = COLOR;
}

void fragment() {
    vec3 wn = normalize(v_wn);
    float upness = clamp(wn.y, 0.0, 1.0);

    // ── 地块：世界 XZ → 格坐标 ───────────────────────────────────────────
    vec2 g = (v_world.xz + vec2(map_half)) / tile_m;
    vec2 t = fract(g);
    ivec2 ij = ivec2(floor(g));
    // 边界裙边 / 远景会踩到格点表外面：按格数取模（正数），保证 texelFetch 不越界。
    int nc = max(mat_cells, 1);
    ij = ((ij % nc) + nc) % nc;

    // 四角格点材质 0/1（texelFetch 不插值 = "这个顶点是 A 还是 B"）
    int c0 = int(texelFetch(mat_map, ij + ivec2(0, 0), 0).r > 0.5);
    int c1 = int(texelFetch(mat_map, ij + ivec2(1, 0), 0).r > 0.5);
    int c2 = int(texelFetch(mat_map, ij + ivec2(1, 1), 0).r > 0.5);
    int c3 = int(texelFetch(mat_map, ij + ivec2(0, 1), 0).r > 0.5);
    int idx = c0 | (c1 << 1) | (c2 << 2) | (c3 << 3);

    bool pure_a = (idx == 0);
    bool pure_b = (idx == 15);
    ivec2 cell;
    if (pure_a || pure_b) {
        // 纯色区不走过渡格：按格号哈希挑一个变体（8 个轮换，治"8m 复读"）
        int v = 0;
        if (variant_random) {
            v = int(tile_hash(ij) % uint(max(variant_count, 1)));
        }
        int col = VAR_COL0 + v % VAR_PER_ROW;
        int row = (pure_b ? VAR_ROW_B : VAR_ROW_A) + v / VAR_PER_ROW;
        cell = ivec2(col, row);
    } else {
        int sh = idx * 2;
        cell = ivec2((COL_PACK >> sh) & 3, (ROW_PACK >> sh) & 3);
    }

    vec2 uv = (vec2(cell) + t) * CELL_UV;

    // 梯度必须在 fract 之前算（对 t 求导会得到假梯度 → 格边 1px 灰线）
    vec2 dgx = dFdx(g) * CELL_UV;
    vec2 dgy = dFdy(g) * CELL_UV;
    float lod = clamp(0.5 * log2(max(dot(dgx, dgx), dot(dgy, dgy))), 0.0, max_lod);

    // 纯色格把采样中心夹在格内半个 texel（否则 mip 混进邻格 → 每 8m 一道暗边）
    if (pure_a || pure_b) {
        vec2 half_texel = 0.5 * exp2(lod) / vec2(ATLAS_CELLS * 256);
        vec2 cu = vec2(cell) * CELL_UV;
        uv = clamp(uv, cu + half_texel, cu + CELL_UV - half_texel);
    }

    vec4 m = textureLod(atlas_rgba, uv, lod);

    // 底材：同一个 8m 平铺节奏，交界两侧的踩踏才对得上
    vec2 tuv = v_world.xz / tile_m;
    vec3 col_a = texture(tex_grass, tuv).rgb * mat_a_tint.rgb;
    vec3 col_b = texture(tex_dirt, tuv).rgb * mat_b_tint.rgb;
    vec3 col_c = texture(tex_cracked, tuv).rgb * mix(mat_b_tint.rgb, mat_a_tint.rgb, 0.16);

    // 干度：两个泥种之间是软的（它们只在 B 侧出现，交界形状由同一张图集决定）
    float dry = clamp((v_col.a - 0.5) / max(dry_strength, 0.001) + 0.5, 0.0, 1.0);
    vec3 dirt_col = mix(col_b, col_c, dry);

    // 二选一：没有 mix、没有 smoothstep、没有 alpha
    vec3 tile_col = (m.r > 0.5) ? dirt_col : col_a;

    // 接触阴影（B 侧 7.5cm，压 34%）+ 受光边（A 侧 3cm，提 5%）：一暗一亮，不对称
    float sd = (m.g * 2.0 - 1.0) * sd_max_m;
    float w = 1.0 + 0.5 * (m.b - 0.5);
    float shadow = (sd > 0.0) ? shadow_amt * exp(-sd / shadow_w * w) : 0.0;
    float rim     = (sd < 0.0) ? rim_amt * exp(sd / rim_w * w) : 0.0;
    tile_col *= (1.0 - shadow + rim);

    // 顶点色只做乘法染色（1.0 附近），不承担配色
    vec3 tint = mix(vec3(1.0), v_col.rgb, tint_strength);
    vec3 albedo = tile_col * tint * albedo_gain;

    // ── 生态换色（雪原/荒原/火山/沼泽）：只换色相，保留地块自身的明暗细节 ──
    if (biome_mix > 0.002) {
        float lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
        vec3 bio = biome_color.rgb * (0.35 + lum * 1.55);
        albedo = mix(albedo, bio, biome_mix);
    }

    // ── 崖壁：不走地块，三平面取岩石细节 ─────────────────────────────────
    float cliff = smoothstep(0.82, 0.46, upness);
    if (cliff > 0.002) {
        vec3 tw = abs(wn);
        tw /= (tw.x + tw.y + tw.z + 1e-4);
        vec3 q = v_world / rock_scale;
        vec3 rk = texture(rock_detail, q.zy).rgb * tw.x
                + texture(rock_detail, q.xz).rgb * tw.y
                + texture(rock_detail, q.xy).rgb * tw.z;
        vec3 rock_col = rock_tint.rgb * (0.35 + rk.g * rock_detail_gain);
        // 崖脚压暗、层理靠世界高度做一条极淡的横向色阶（不做硬条纹）
        float strata = 0.94 + 0.06 * sin(v_world.y * 1.35);
        rock_col *= strata * mix(0.72, 1.0, smoothstep(-1.0, 6.0, v_world.y));
        albedo = mix(albedo, rock_col, cliff);
    }

    // 法线：只在地块面上补微起伏（崖壁交给岩石细节，别两套打架）
    if (atlas_n_strength > 0.001 && cliff < 0.5) {
        vec3 nt = textureLod(atlas_n, uv, lod).xyz * 2.0 - 1.0;
        vec3 n_world = normalize(vec3(nt.x, nt.z, -nt.y) * atlas_n_strength
                                 * (1.0 - cliff) + normalize(wn));
        NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
    }

    ALBEDO = clamp(albedo, vec3(0.0), vec3(1.0));
    ROUGHNESS = 0.96;
    SPECULAR = 0.0;
}

void light() {
    // 两阶三渲二：暗部有一点点环境补偿，亮部给一个稳定的"上色"。
    vec3 n = normalize(NORMAL);
    vec3 l = normalize(LIGHT);
    float lam = dot(n, l) * 0.5 + 0.5;
    float band = smoothstep(band_edge - band_soft, band_edge + band_soft, lam);
    vec3 shade = mix(shadow_color * shadow_strength + vec3(ambient_flat), vec3(1.06), band);
    DIFFUSE_LIGHT += shade * ATTENUATION * LIGHT_COLOR / PI;
}
