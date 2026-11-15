// =============================================================================
//  沙盘网格.gdshader  —— 规划阶段“作战台”底图（第三版，2026-11-15）
// -----------------------------------------------------------------------------
//  一张贴地网格同时画三样东西（全部程序化，不用贴图）：
//    ① 全图细网格：2m 一格 + 10m 主刻度，抗锯齿、远处自动淡出；
//    ② 势力场：采样 CPU 生成的 territory 贴图（R=我方 / G=敌方），
//       多座建筑的辐射核叠加成不规则领地，边缘由 smoothstep 羽化成光晕；
//    ③ 领地内六边形网格高亮：读成“战术沙盘”的网格，而不是一块纯色贴纸。
//
//  颜色口径（玩家 2026-11-15）：不要高饱和纯红纯蓝 ——
//    我方 = 深邃湖蓝（半透明、发光），敌方 = 暗红紫（半透明、发光）。
//
//  关键参数：
//    territory        势力场贴图（R 我方 / G 敌方；0..1）
//    map_min/map_size 世界 XZ 范围（贴图 uv 与网格都用它对齐）
//    fade             整体淡入淡出（进/出规划阶段由脚本推，绝不硬切）
//    grid_alpha       全图细网格亮度（默认很轻，别盖住地形）
//    territory_alpha  领地亮度
// =============================================================================
shader_type spatial;
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 player_color : source_color = vec4(0.05, 0.24, 0.60, 1.0);
uniform vec4 enemy_color : source_color = vec4(0.72, 0.03, 0.28, 1.0);
uniform sampler2D territory : filter_linear_mipmap, repeat_disable;
uniform vec2 map_min = vec2(-112.0, -112.0);
uniform vec2 map_size = vec2(224.0, 224.0);
uniform float grid_cell = 2.0;
uniform float major_every = 5.0;
uniform float hex_size = 3.4;
uniform float fade = 1.0;
uniform float grid_alpha = 0.20;
uniform float territory_alpha = 0.92;

varying vec3 v_world;

void vertex() {
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// 一格一格的线：返回 0..1 的“离线程度”（1.1 像素宽，远处自然糊掉）
float line_mask(vec2 p, vec2 fw, float width) {
    vec2 g = abs(fract(p + 0.5) - 0.5);
    vec2 m = 1.0 - smoothstep(vec2(0.0), fw * width, g);
    return max(m.x, m.y);
}

// 六边形：经典 hex 距离（0 在边，0.5 在中心）
float hex_dist(vec2 p) {
    p = abs(p);
    float c = dot(p, normalize(vec2(1.0, 1.7320508)));
    return max(c, p.x);
}

vec4 hex_coords(vec2 uv) {
    vec2 r = vec2(1.0, 1.7320508);
    vec2 h = r * 0.5;
    vec2 a = mod(uv, r) - h;
    vec2 b = mod(uv - h, r) - h;
    vec2 gv = dot(a, a) < dot(b, b) ? a : b;
    float x = atan(gv.x, gv.y);
    float y = 0.5 - hex_dist(gv);
    return vec4(x, y, gv);
}

void fragment() {
    vec2 to_edge = min(v_world.xz - map_min, map_min + map_size - v_world.xz);
    float edge_fade = smoothstep(0.0, 9.0, min(to_edge.x, to_edge.y));

    // ---------------------------------------------------------------- 全图细网格
    vec2 gp = v_world.xz / max(grid_cell, 0.25);
    vec2 fw = max(fwidth(gp), vec2(0.0007));
    // 一格不足 1 像素时淡掉细线，只留主刻度，避免远处变成噪点
    float near = 1.0 - smoothstep(0.22, 0.65, max(fw.x, fw.y));
    float fine = line_mask(gp, fw, 1.0) * near;
    vec2 mp = v_world.xz / max(grid_cell * major_every, 0.5);
    vec2 mfw = max(fwidth(mp), vec2(0.0007));
    float major = line_mask(mp, mfw, 1.35);
    float grid = (fine * 0.20 + major * 0.58) * edge_fade;
    // 地图边缘一圈很淡的冷光，把“作战台”框住（也遮住地形与远景底板的硬接缝）
    float border_d = min(to_edge.x, to_edge.y);
    float border = exp(-max(border_d, 0.0) * 0.55) * 0.18;

    // ---------------------------------------------------------------- 势力场
    vec2 uv = (v_world.xz - map_min) / map_size;
    vec4 field = texture(territory, uv);
    float mine_f = field.r;
    float foe_f = field.g;
    float mine = smoothstep(0.030, 0.22, mine_f);
    float foe = smoothstep(0.030, 0.22, foe_f);
    float terr = clamp(mine + foe, 0.0, 1.0);
    vec3 tint = (player_color.rgb * mine + enemy_color.rgb * foe) / max(mine + foe, 0.001);

    // 边缘羽化光晕：只取场值 0.035..0.34 这一条带，外缘自然消失，没有硬直线
    // 羽化光边只取最外的一条窄带（0.02..0.16）；再往上就是“领地内”，
    //   否则铺得开一点的营地整片都会被算成光边，看起来只剩一圈粉红光环。
    float rim_m = smoothstep(0.02, 0.06, mine_f) * (1.0 - smoothstep(0.06, 0.16, mine_f));
    float rim_f = smoothstep(0.02, 0.06, foe_f) * (1.0 - smoothstep(0.06, 0.16, foe_f));
    float rim = clamp(rim_m + rim_f, 0.0, 1.0);

    // ---------------------------------------------------------------- 领地内六边形
    vec4 hc = hex_coords(v_world.xz / max(hex_size, 0.5));
    float hw = max(fwidth(hc.y) * 1.5, 0.035);
    float hex_line = (1.0 - smoothstep(0.0, hw, hc.y));
    float hex = hex_line * smoothstep(0.08, 0.28, mine_f + foe_f);

    // 极慢的扫描带（科技感，但别抢戏）
    float scan = exp(-pow((fract(v_world.z / 46.0 - TIME * 0.035) - 0.5) * 7.0, 2.0));
    float pulse = 0.92 + 0.08 * sin(TIME * 0.9);

    // 领地“内核”→ 越靠近建筑越亮
    float core = pow(clamp(mine_f + foe_f, 0.0, 1.0), 2.4);
    float fill = terr * (0.60 + core * 0.30) * pulse;
    float glow = rim * 0.90 + hex * 0.42 + fill;

    // 领地内部让位给六边形网格：方格只在“中立地表”上做底纹
    float grid_fade = 1.0 - clamp(mine + foe, 0.0, 1.0) * 0.65;
    float ga = (grid * grid_alpha * 0.45 + border) * grid_fade;
    float ta = glow * territory_alpha * 0.72;
    float a = clamp(ga + ta, 0.0, 0.92) * fade;

    vec3 gcol = vec3(0.52, 0.64, 0.76);
    vec3 tcol = tint * (1.15 + core * 0.60) + tint * rim * 0.50;
    vec3 hexcol = mix(tint, vec3(0.95, 0.97, 1.0), 0.35);
    tcol += hexcol * hex * 0.55;
    tcol += tint * scan * terr * 0.45;
    vec3 col = (gcol * ga + tcol * ta) / max(ga + ta, 0.0001);

    ALBEDO = col;
    ALPHA = a;
}
