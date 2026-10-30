// 画面の描画（docs/design.md「描画と解像度」）。座標はすべて物理ピクセル
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewport;
};

// 塗りつぶしの四角（背景・罫線・下線・カーソル・選択）
struct RectInstance {
    float4 rect;   // x, y, w, h
    float4 color;  // r, g, b, a
};

// 文字（グリフアトラスの一部を貼る）
struct GlyphInstance {
    float4 rect;   // x, y, w, h
    float4 uv;     // アトラスの x, y, w, h（ピクセル）
    float4 color;
};

struct VOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

static float4 toClip(float2 p, float2 viewport) {
    return float4(p.x / viewport.x * 2.0 - 1.0, 1.0 - p.y / viewport.y * 2.0, 0.0, 1.0);
}

// 4 頂点の三角形ストリップ: (0,0) (1,0) (0,1) (1,1)
vertex VOut rect_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant RectInstance *instances [[buffer(0)]],
                        constant Uniforms &u [[buffer(1)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    RectInstance r = instances[iid];
    VOut o;
    o.position = toClip(r.rect.xy + corner * r.rect.zw, u.viewport);
    o.uv = float2(0.0);
    o.color = r.color;
    return o;
}

fragment float4 rect_fragment(VOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

vertex VOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                         constant GlyphInstance *instances [[buffer(0)]],
                         constant Uniforms &u [[buffer(1)]]) {
    float2 corner = float2(float(vid & 1), float(vid >> 1));
    GlyphInstance g = instances[iid];
    VOut o;
    o.position = toClip(g.rect.xy + corner * g.rect.zw, u.viewport);
    o.uv = g.uv.xy + corner * g.uv.zw;
    o.color = g.color;
    return o;
}

// アトラスは物理ピクセルと 1 対 1 なので、最近傍で読む（滲ませない）
fragment float4 glyph_fragment(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    float a = atlas.sample(s, in.uv).r * in.color.a;
    return float4(in.color.rgb * a, a);
}
