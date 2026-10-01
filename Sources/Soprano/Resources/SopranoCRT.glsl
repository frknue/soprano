// Soprano CRT: scanlines, phosphor bloom and a soft vignette over the
// terminal. Enabled by "crtEffect" in settings.json.
//
// Deliberately static (no iTime) and flat (no barrel curvature): Soprano
// turns Ghostty's shader animation loop off, and curvature would move text
// away from where the mouse selects it.

const float SCANLINE_DEPTH = 0.22;   // how dark the gaps between lines get
const float SCANLINE_PERIOD = 3.0;   // device pixels per scanline
const float BLOOM_STRENGTH = 0.55;   // how much lit glyphs bleed into their surroundings
const float BLOOM_RADIUS = 1.75;     // device pixels between bloom taps
const float VIGNETTE_DEPTH = 0.28;   // edge darkening

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec2 texel = 1.0 / iResolution.xy;
    vec4 source = texture(iChannel0, uv);

    // Phosphor bloom: only what is brighter than the background glows, so the
    // background keeps its color instead of washing out.
    vec3 bloom = vec3(0.0);
    float weight = 0.0;
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            vec2 offset = vec2(float(x), float(y)) * BLOOM_RADIUS * texel;
            float w = 1.0 / (1.0 + float(x * x + y * y));
            vec3 tap = texture(iChannel0, uv + offset).rgb;
            bloom += max(tap - iBackgroundColor, vec3(0.0)) * w;
            weight += w;
        }
    }
    bloom /= weight;

    vec3 color = source.rgb + bloom * BLOOM_STRENGTH;

    // Scanlines, softened where the bloom fills the gaps the way a real
    // phosphor's glow does.
    float gap = 0.5 - 0.5 * cos(fragCoord.y / SCANLINE_PERIOD * 6.28318530718);
    float glowFill = clamp(dot(bloom, vec3(0.333)) * 3.0, 0.0, 1.0);
    color *= 1.0 - SCANLINE_DEPTH * gap * (1.0 - 0.5 * glowFill);

    // Vignette.
    vec2 centered = uv * (1.0 - uv);
    float vignette = pow(clamp(centered.x * centered.y * 16.0, 0.0, 1.0), 0.18);
    color *= mix(1.0 - VIGNETTE_DEPTH, 1.0, vignette);

    fragColor = vec4(clamp(color, 0.0, 1.0), source.a);
}
