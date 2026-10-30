// terrain_blend.gdshader —— 双材质硬边过渡 + 扩展图集（Godot 4 · spatial）
//
// 干什么
// ------
// 地面在两张各自平铺的底材（8 m 一格）之间**二选一**，交界是一条硬边，不做任何
// alpha 混合。选哪张由一张 **2048×1024** 的遮罩图集回答，图集分左右两块：
//
//   左 4×4（1024×1024）= 16 个「四角材质」过渡格
//   右 4×4（1024×1024）= 16 个**纯纹理变体**（上两行 A 材质 8 个，下两行 B 材质 8 个）
//
// 为什么要右边那块：过渡格里的「纯 A / 纯 B」只有一个，大片草地铺出去就是一格
// 8 m 反复读，复读感极强。有了变体块，纯色区每格按格号哈希挑一个变体，8 个随机
// 轮换，眼睛就抓不到重复了。
//
// 图集通道（atlas_rgba）：
//   R = 遮罩 0/255（255 = B 材质）   G = 有符号距离，128 = 交界，±24 cm
//   B = 宽度抖动场（接触阴影 / 受光边用）      A = 255
//
// 【必须知道的一件事】idx → 过渡格位置不是 idx%4
// ----------------------------------------------
// 角权重场是四角值的双线性插值。要让相邻格共边像素相等，唯一办法是两格的共边角值
// 来自**同一个格点**。按 (col=idx%4, row=idx//4) 摆，拼起来是 16 条笔直台阶。
// 所以过渡块用 4×4 二进制德布鲁因环摆位，16 个组合一个不少且角点同源。
// 下面 CELL_LUT 就是那张表（生成器从交付参数导出的，不是手抄的）。
//
// 输入约定（mat_map）
// -------------------
// R8，1 texel = 1 个**格点** = 8 m，世界对齐，repeat + nearest。
// texel(i,j) 的值 = 世界坐标 (i*8, j*8) 那个**顶点**是不是 B 材质（>0.5）。
// 一格的四角 = (i,j)(i+1,j)(i+1,j+1)(i,j+1)，顺序 左上→右上→右下→左下。
// 也就是魔兽争霸 3 那种：材质存在共享顶点上，一格渲染时读它四个角。
//
// 导入设置（Godot 4）
// -------------------
//   atlas_<名称>_rgba.png  Compress: Lossless   sRGB: 关（R/G/B 全是数据）
//   mat_map                同上
//   底材 A / B             Compress: VRAM/Lossless   sRGB: 开
//
// 平铺距离：底材与遮罩都必须是 8 m（tile_m），否则交界跟贴图的踩踏节奏对不上。

shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_back;

// ── 输入 ────────────────────────────────────────────────────────────────────
uniform sampler2D mat_map : filter_nearest, repeat_enable, hint_default_black;
uniform sampler2D atlas_rgba : filter_linear, repeat_disable;
uniform sampler2D tex_a : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_b : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D atlas_n : filter_linear, repeat_disable,
                            hint_normal, hint_default_black;

// ── 参数（要与生成时 参数配置.json 一致）────────────────────────────────────
uniform float tile_m : hint_range(2.0, 32.0) = 8.0;
uniform float sd_max_m = 0.24;      // G 通道 0/255 对应的距离（米）
uniform float shadow_amt : hint_range(0.0, 1.0) = 0.30;
uniform float shadow_w = 0.08;
uniform float rim_amt : hint_range(0.0, 0.1) = 0.06;
uniform float rim_w = 0.03;

// 纯色块随机采样：每个 8 m 格按格号哈希挑一个变体。
// 关掉（false）就永远用第 0 个变体 —— 用来 A/B 对比复读感。
uniform bool  variant_random = true;
uniform int   variant_count : hint_range(1, 8) = 8;
uniform int   variant_seed = 0;

// 最大 mip 级别。**必须夹住**：不夹的话远处一个 texel 跨过整格，遮罩糊成灰、边界乱跳。
uniform float max_lod = 5.0;

uniform bool use_normal_map = false;
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;

// ── 图集布局 ────────────────────────────────────────────────────────────────
const ivec2 ATLAS_CELLS = ivec2(8, 4);   // 8 列 × 4 行（2048×1024，一格 256）
const vec2  CELL_UV = vec2(1.0 / 8.0, 1.0 / 4.0);
const int   VAR_COL0 = 4;                // 变体块从第 4 列开始
const int   VAR_PER_ROW = 4;             // 每行 4 个变体
const int   VAR_ROW_A = 0;               // A 材质占上两行（0,1）
const int   VAR_ROW_B = 2;               // B 材质占下两行（2,3）

__CELL_LUT__

// 整数哈希：同一个格号永远得到同一个变体（不会随镜头闪）
uint tile_hash(ivec2 p) {
    uint h = uint(p.x) * 1597334677u ^ uint(p.y) * 3812015801u;
    h ^= h >> 15u;
    h *= 2246822519u;
    h ^= h >> 13u;
    return h;
}

void fragment() {
    // 世界坐标（米）。VERTEX 在片元里是 view space，乘 INV_VIEW_MATRIX 回到世界。
    vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;

    // 以 tile 为单位。g 连续，t 才被 fract 折断。
    vec2 g = wp.xz / tile_m;
    vec2 t = fract(g);
    ivec2 ij = ivec2(floor(g));

    // 四角格点材质 0/1。texelFetch 不插值 —— 正好是「这个顶点是 A 还是 B」。
    int c0 = int(texelFetch(mat_map, ij + ivec2(0, 0), 0).r > 0.5);
    int c1 = int(texelFetch(mat_map, ij + ivec2(1, 0), 0).r > 0.5);
    int c2 = int(texelFetch(mat_map, ij + ivec2(1, 1), 0).r > 0.5);
    int c3 = int(texelFetch(mat_map, ij + ivec2(0, 1), 0).r > 0.5);
    int idx = c0 | (c1 << 1) | (c2 << 2) | (c3 << 3);

    // 纯色块（四角全同）不走过渡格，去右侧变体块挑一个。
    bool pure_a = (idx == 0);
    bool pure_b = (idx == 15);
    ivec2 cell;
    if (pure_a || pure_b) {
        int v = 0;
        if (variant_random) {
            v = int(tile_hash(ij + ivec2(variant_seed)) % uint(max(variant_count, 1)));
        }
        int col = VAR_COL0 + v % VAR_PER_ROW;
        int row = (pure_b ? VAR_ROW_B : VAR_ROW_A) + v / VAR_PER_ROW;
        cell = ivec2(col, row);
    } else {
        cell = CELL_LUT[idx];
    }

    vec2 uv = (vec2(cell) + t) * CELL_UV;

    // 梯度必须在 fract 之前算（用 t 求导会得到 ±1/tile 的假梯度，mip 跳到最粗，
    // 格边出现 1 px 灰线）。x、y 的缩放不同：图集是 8 列 4 行。
    vec2 dgx = dFdx(g) * CELL_UV;
    vec2 dgy = dFdy(g) * CELL_UV;

    // 显式算 LOD 再 textureLod：效果同 textureGrad，但能往下夹 max_lod。
    float lod = clamp(0.5 * log2(max(dot(dgx, dgx), dot(dgy, dgy))), 0.0, max_lod);

    // 纯色格把采样中心夹在格内「半个 texel」处 —— 否则 mip 会把隔壁格子混进来
    // （纯 A 格的左边是过渡块，混进来就是一条 25 cm 的暗边，正好又变成网格）。
    // 变体自己每一格都是无缝平铺的，往里夹半个 texel 看不出来。
    if (pure_a || pure_b) {
        vec2 half_texel = 0.5 * exp2(lod) / vec2(ATLAS_CELLS * 256);
        vec2 cu = vec2(cell) * CELL_UV;
        uv = clamp(uv, cu + half_texel, cu + CELL_UV - half_texel);
    }

    vec4 m = textureLod(atlas_rgba, uv, lod);

    // 底材按 8 m 重复。两张用同一个 uv，交界两侧的踩踏节奏才对得上。
    vec2 tuv = wp.xz / tile_m;
    vec3 col_a = texture(tex_a, tuv).rgb;
    vec3 col_b = texture(tex_b, tuv).rgb;

    // 二选一。没有 mix、没有 smoothstep、没有 alpha。
    vec3 albedo = (m.r > 0.5) ? col_b : col_a;

    // 接触阴影（B 侧 8 cm，压 30%）+ 受光边（A 侧 3 cm，提 6%）。一暗一亮，不对称。
    float sd = (m.g * 2.0 - 1.0) * sd_max_m;
    float w = 1.0 + 0.5 * (m.b - 0.5);
    // 各长各的一侧：阴影只在 B 侧、受光边只在 A 侧，另一侧严格为 0。
    // （写成 exp(-max(sd,0)/w) 的话，sd<0 时 max=0 → 整片 A 材质被压暗 30%。）
    float shadow = (sd > 0.0) ? shadow_amt * exp(-sd / shadow_w * w) : 0.0;
    float rim = (sd < 0.0) ? rim_amt * exp(sd / rim_w * w) : 0.0;

    // 必须在线性空间乘（ALBEDO 是线性的，tex_* 标了 source_color 会自动 sRGB→线性）。
    albedo *= (1.0 - shadow + rim);

    ALBEDO = albedo;
    ROUGHNESS = 0.95;
    SPECULAR = 0.0;

    // ── 可选：图集法线（默认关）──────────────────────────────────────────
    if (use_normal_map) {
        vec3 nt = textureLod(atlas_n, uv, lod).xyz * 2.0 - 1.0;
        vec3 n_world = normalize(vec3(nt.x, nt.z, -nt.y) * normal_strength
                                 + vec3(0.0, 1.0, 0.0));
        NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
    }
}
