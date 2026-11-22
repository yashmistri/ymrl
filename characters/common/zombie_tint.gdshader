shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Palette-split green tint, so the model reads as "zombie" without repainting
// the parts that carry its identity.
//
// The paladin diffuse is mostly neutral steel plus gold trim, a brown shield
// backing and a human face. A plain multiply would darken all of it; instead
// warm, saturated pixels (gold, skin, leather) keep their own hue and only the
// neutral steel is mixed toward green.
//
// Colour is mixed in toward the tint rather than multiplied by it: the steel
// is dark (albedo ~0.1), and a multiply of two dark vectors barely moves, which
// is why an earlier version was invisible in the render. Saturation tells gold
// and leather apart (they are saturated); temperature separates the cool steel
// from the warm brown backing and skin.
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(0.33, 0.72, 0.27, 1.0);
// 0 = untouched original, 1 = neutral surfaces fully green.
uniform float tint_strength : hint_range(0.0, 1.0) = 0.85;

void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;
	float max_c = max(max(base.r, base.g), base.b);
	float min_c = min(min(base.r, base.g), base.b);
	float saturation = (max_c > 0.0001) ? (max_c - min_c) / max_c : 0.0;
	// Neutral steel: low saturation. Gold armour trim is strongly saturated.
	float neutral = 1.0 - smoothstep(0.18, 0.55, saturation);
	// Warm: brown leather backing and skin. A strict comparison catches the
	// brown-shadowed steel (steel under brown ambient is still far warmer than
	// clean steel) while leaving the plain grey steel alone.
	float warm = base.r > base.b * 1.45 ? 1.0 : 0.0;
	// Value gate: the darkest texels are grime in crevices and read as dirt
	// once tinted, so they stay original and keep the model's depth cues.
	float lum = dot(base, vec3(0.2126, 0.7152, 0.0722));
	float steel = smoothstep(0.06, 0.16, lum);
	float mask = neutral * (1.0 - warm) * steel;
	// Keep some of the original luminance so armour detail survives the mix.
	vec3 detail = mix(vec3(1.0), base / max(max_c, 0.001), 0.35);
	ALBEDO = mix(base, tint.rgb * detail, tint_strength * mask);
	ROUGHNESS = 0.7;
	SPECULAR = 0.3;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
}
