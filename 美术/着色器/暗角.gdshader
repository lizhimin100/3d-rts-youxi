// =============================================================================
//  暗角.gdshader  —— 轻微暗角 / 电影边框（CanvasLayer 上的全屏 ColorRect 用）
// -----------------------------------------------------------------------------
//  为什么要单独一个文件：Godot 4.7 的 Environment **没有** vignette 属性
//  （我用 ClassDB 把 Environment 的属性全列过：background/sky/ambient/tonemap/
//   ssr/ssao/ssil/sdfgi/glow/fog/volumetric/adjustment —— 确实没有 vignette）。
//  所以暗角只能做在全屏后处理层。`美术/特效/暗角.tscn` 已经把它挂好了，
//  主场景里实例化一次即可（它自己是 CanvasLayer，不会挡 UI 输入：mouse_filter 已关）。
//  关键参数：strength 强度 / softness 过渡 / tint 暗角色（偏冷，别用纯黑）。
// =============================================================================
shader_type canvas_item;

uniform float strength : hint_range(0.0, 1.5) = 0.55;
uniform float softness : hint_range(0.05, 1.5) = 0.62;
uniform vec4  tint : source_color = vec4(0.03, 0.04, 0.07, 1.0);
uniform float aspect_correct = 1.0;

void fragment() {
    vec2 uv = UV;   // ColorRect 铺满全屏，UV 与 SCREEN_UV 等价，且不依赖屏幕纹理
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= mix(1.0, 1.78, aspect_correct);
    float d = length(p) * 0.72;
    float v = smoothstep(1.0 - softness, 1.0 + softness * 0.35, d);
    COLOR = vec4(tint.rgb, v * strength);
}
