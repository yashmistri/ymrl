extends SceneTree
## One-off character-model builder. Run from the project root:
##
##   godot --headless --path . --script res://tools/build_characters.gd
##
## Takes the paladin FBX in assets/ and writes it into soldier3.tscn and
## zombie3.tscn as the visible body. Gameplay nodes (collision, sensors, AI,
## ray, health bar) are left exactly as they were: this only replaces the
## CapsuleMesh that used to stand in for the character.
##
## Why a build script instead of instancing the FBX scene directly: the FBX
## carries a 315-curve "mixamo.com" take, and an instanced AnimationPlayer would
## rebuild that clip on every zombie spawn. Rebaking the mesh + skeleton without
## animations gives a plain MeshInstance3D/Skeleton3D pair that is cheap to
## duplicate and needs no import-level stripping.
##
## The paladin mesh is saved with its imported material (the extracted embedded
## diffuse/normal/specular maps), except where a character overrides it:
##   - zombie:  a shader that tints neutral steel green but leaves gold and skin
##   - soldier: a second, inverted-hull MeshInstance3D for the white outline

const PALADIN := "res://assets/Paladin J Nordstrom.fbx"

const SOLDIER_TSN := "res://characters/soldier3/soldier3.tscn"
const ZOMBIE_TSN := "res://characters/zombie3/zombie3.tscn"

const OUTLINE_SHADER_PATH := "res://characters/soldier3/outline.gdshader"
const ZOMBIE_TINT_SHADER_PATH := "res://characters/common/zombie_tint.gdshader"

const PALADIN_BODY := "Skeleton3D/Paladin_J_Nordstrom"
const ANIMATOR_SCRIPT := "res://characters/common/character_animator.gd"

# Nodes the scripts look up by path. A missing one is a build failure.
# WallSensor/EntitySensor are soldier-only; the zombie has no perception
# sensors, so requiring them there would be a false failure.
const REQUIRED_NODES := {
	SOLDIER_TSN: ["Mesh", "Outline", "Skeleton3D", "WallSensor", "EntitySensor", "AI", "Col", "ray", "hit"],
	ZOMBIE_TSN: ["Mesh", "Skeleton3D", "Col", "ray", "hit"],
}

const OUTLINE_SHADER := """shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled;

// Inverted-hull outline. A second MeshInstance3D shares the paladin's mesh and
// skeleton, runs the same GPU skinning, and is pushed out along its own normals
// far enough to clear the silhouette in front of the body. Front faces are
// culled, so all that remains visible is the rim poking past the model.
//
// depth_draw_opaque lets the hull write depth so the real body still occludes
// it correctly; shadows_disabled stops the expanded copy casting its own,
// slightly larger shadow.
uniform float outline_width : hint_range(0.0, 0.05, 0.001) = 0.012;
uniform vec4 outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

void vertex() {
	// Expand in world space so a non-uniform node scale cannot skew the width.
	VERTEX += NORMAL * outline_width;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * (MODEL_MATRIX * vec4(VERTEX, 1.0));
}

void fragment() {
	ALBEDO = outline_color.rgb;
	// Unshaded, so ALPHA is used directly rather than as a fade mask.
	ALPHA = outline_color.a;
}
"""

const ZOMBIE_TINT_SHADER := """shader_type spatial;
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
"""

var _failed := false


func _init() -> void:
	_write_if_changed(OUTLINE_SHADER_PATH, OUTLINE_SHADER)
	_write_if_changed(ZOMBIE_TINT_SHADER_PATH, ZOMBIE_TINT_SHADER)

	var paladin: PackedScene = load(PALADIN)
	if paladin == null:
		_fail("could not load " + PALADIN)
	else:
		# Stop at the first failure so a half-applied model is never written
		# over a good scene.
		_rebuild(SOLDIER_TSN, paladin)
		if not _failed:
			_rebuild(ZOMBIE_TSN, paladin)
	quit(1 if _failed else 0)


func _fail(message: String) -> void:
	_failed = true
	printerr("BUILD FAILED: ", message)


func _write_if_changed(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		var current := file.get_as_text()
		file.close()
		if current == text:
			return
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		_fail("cannot write " + path)
		return
	out.store_string(text)
	out.close()
	print("wrote ", path)


func _rebuild(scene_path: String, paladin: PackedScene) -> void:
	# A previous run has already moved the paladin's two skinned meshes onto the
	# character's own Skeleton3D, so there is no capsule left to replace. Rebuild
	# from that state instead of requiring the original capsule scene, which
	# keeps this script re-runnable.
	var packed: PackedScene = load(scene_path)
	if packed == null:
		_fail("could not load " + scene_path)
		return
	var root: Node = packed.instantiate()
	var skeleton: Skeleton3D = root.get_node_or_null("Skeleton3D")
	var has_capsule := root.get_node_or_null("Mesh") != null and skeleton == null
	if has_capsule:
		root.free()
		_rebuild_from_capsule(scene_path, paladin)
	else:
		_rebuild_from_built(root, scene_path)


func _rebuild_from_built(root: Node, scene_path: String) -> void:
	var skeleton: Skeleton3D = root.get_node_or_null("Skeleton3D")
	if skeleton == null:
		_fail(scene_path + ": no Skeleton3D in existing scene")
		root.free()
		return
	# Already-built scenes keep the body either at the root (current layout) or
	# on the skeleton (layout from an earlier run of this script).
	var body: MeshInstance3D = root.get_node_or_null("Mesh")
	if body == null:
		body = skeleton.get_node_or_null("Paladin_J_Nordstrom")
	if body == null:
		body = skeleton.get_node_or_null("Mesh")
	if body == null:
		_fail(scene_path + ": existing scene has no paladin body mesh")
		root.free()
		return
	body.name = "Mesh"
	# Re-apply the +Z -> -Z yaw, since this path rebuilds an already-converted
	# scene rather than adopting a fresh import.
	body.rotation.y = PI
	_finish_build(root, scene_path, skeleton, body)
	_validate_and_save(root, scene_path)



func _rebuild_from_capsule(scene_path: String, paladin: PackedScene) -> void:
	var packed: PackedScene = load(scene_path)
	if packed == null:
		_fail("could not load " + scene_path)
		return
	var root: Node = packed.instantiate()
	# Keep the root detached from the scene tree: attaching it would run the
	# character's _ready() in the editor process (soldier3.gd builds its
	# shield, the HUD resolves nodes), which is not wanted here. Relative paths
	# via get_path_to() still work between nodes that share the same detached
	# subtree, and the packer re-resolves them on save.
	# Returns {"skeleton": Skeleton3D, "body": MeshInstance3D}, or {} on failure.
	var adopted := _adopt_paladin(root, scene_path, paladin)
	if adopted.is_empty():
		root.free()
		return
	_finish_build(root, scene_path, adopted["skeleton"], adopted["body"])
	_validate_and_save(root, scene_path)


func _finish_build(root: Node, scene_path: String, skeleton: Skeleton3D, body: MeshInstance3D) -> void:
	# The paladin is TWO meshes: the body and the helmet. Both must sit at the
	# character root and both must be covered by the outline / tint, otherwise
	# the helmet is the only part that matches (which is exactly the bug this
	# replaced: the outline was a copy of the body mesh only).
	var helmet: MeshInstance3D = root.find_child("Paladin_J_Nordstrom_Helmet", true, false) as MeshInstance3D
	if helmet == null:
		_fail(scene_path + ": paladin helmet mesh not found")
		return
	body.name = "Mesh"
	if body.get_parent() != root:
		body.owner = null
		body.reparent(root, false)
		_own_recursive(body, root)
	body.skeleton = body.get_path_to(skeleton)
	body.rotation.y = PI
	if helmet.get_parent() != root:
		helmet.owner = null
		helmet.reparent(root, false)
		_own_recursive(helmet, root)
	helmet.skeleton = helmet.get_path_to(skeleton)

	# Clear anything a previous build or an unsaved editor session left behind,
	# so a re-run does not stack hulls or shaders.
	for container in [root, skeleton]:
		for child in container.get_children():
			if child.name.begins_with("Outline"):
				child.free()
	body.material_override = null
	helmet.material_override = null

	if scene_path == ZOMBIE_TSN:
		_apply_zombie_tint(body, helmet)
	elif scene_path == SOLDIER_TSN:
		_add_outline(root, skeleton, body)
		_add_outline(root, skeleton, helmet)
	_ensure_animator(root)


# Adds the locomotion animator once. It reads the character's own move vector,
# so it is cosmetic only and cannot affect training.
func _ensure_animator(root: Node) -> void:
	var existing := root.get_node_or_null("Animator")
	if existing != null:
		existing.free()
	var animator := Node.new()
	animator.name = "Animator"
	animator.set_script(load(ANIMATOR_SCRIPT))
	root.add_child(animator)
	animator.owner = root
	print("animator: added to ", root.name)


func _validate_and_save(root: Node, scene_path: String) -> void:
	for required in REQUIRED_NODES.get(scene_path, []):
		if root.find_child(required, true, false) == null:
			_fail(scene_path + ": required node missing: " + required)
			root.free()
			return
	var out := PackedScene.new()
	var err := out.pack(root)
	if err == OK:
		err = ResourceSaver.save(out, scene_path)
	if err != OK:
		_fail(scene_path + ": save failed (%d)" % err)
		root.free()
		return
	print("rebuilt ", scene_path)
	root.free()


# Returns {"skeleton": Skeleton3D, "body": MeshInstance3D} now parented under
# `root`, or {} on failure.
func _adopt_paladin(root: Node, scene_path: String, paladin: PackedScene) -> Dictionary:
	# Drop the capsule stand-in (with its `forward` child). Everything else in
	# the original scene -- collision, sensors, AI, ray, health bar -- stays.
	var old_mesh := root.get_node_or_null("Mesh")
	if old_mesh != null:
		old_mesh.free()

	# Adopt the paladin's skeleton. Meshes are reparented onto it below.
	var paladin_inst: Node = paladin.instantiate()
	# The instantiated root IS the imported model root ("Paladin J Nordstrom"),
	# so its children are Skeleton3D and AnimationPlayer.
	var skeleton: Skeleton3D = paladin_inst.get_node_or_null("Skeleton3D")
	var body: MeshInstance3D = paladin_inst.get_node_or_null(PALADIN_BODY)
	if skeleton == null or body == null:
		_fail(scene_path + ": paladin skeleton/body not found")
		paladin_inst.free()
		return {}
	# Reparented sub-scene nodes keep the paladin root as `owner`, which the
	# packer rejects with "inconsistent owner". Clear ownership before the node
	# joins this scene, then re-own the whole adopted subtree to the character
	# root so it is packed inline rather than as a nested scene instance.
	skeleton.owner = null
	skeleton.reparent(root, false)
	_own_recursive(skeleton, root)
	# Move the two meshes out of the paladin root (leaving behind its
	# AnimationPlayer, which holds the unused Mixamo take) and repoint their
	# skin to the adopted skeleton. soldier3_ai.gd reads $"../Mesh" for yaw
	# and soldier3.gd aligns $Mesh, so the body mesh is renamed "Mesh".
	for child in skeleton.get_children():
		child.reparent(skeleton, false)
		child.skeleton = child.get_path_to(skeleton)
		_own_recursive(child, root)
	paladin_inst.free()
	body.name = "Mesh"
	# soldier3.gd/char3.gd orient the character by rotating $Mesh so its -Z
	# faces the aim. The paladin is authored facing +Z (toes point at +Z), so
	# without this yaw the model would walk backwards.
	body.rotation.y = PI
	return {"skeleton": skeleton, "body": body}


# Re-own a detached subtree so PackedScene.pack() includes it as part of the
# scene rather than treating it as an instance of another scene.
func _own_recursive(node: Node, scene_root: Node) -> void:
	node.owner = scene_root
	for child in node.get_children():
		_own_recursive(child, scene_root)


func _apply_zombie_tint(body: MeshInstance3D, helmet: MeshInstance3D) -> void:
	# The paladin is TWO skinned meshes: the body and the helmet. Tinting only
	# the body left the helmet bare, which is the most eye-catching part of the
	# model, so the shader goes on both.
	for part in [body, helmet]:
		if part == null:
			continue
		var mesh: Mesh = part.mesh
		if mesh == null:
			_fail("zombie: mesh instance " + part.name + " has no mesh")
			return
		var albedo := _find_texture(mesh, ["albedo_texture", "Albedo", "BaseColor"])
		var normal := _find_texture(mesh, ["normal_texture", "NormalMap", "Normal"])
		if albedo == null:
			_fail("zombie: " + part.name + " has no albedo texture to tint")
			return
		var shader: Shader = load(ZOMBIE_TINT_SHADER_PATH)
		if shader == null:
			_fail("could not load shader " + ZOMBIE_TINT_SHADER_PATH)
			return
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("albedo_tex", albedo)
		if normal != null:
			mat.set_shader_parameter("normal_tex", normal)
		else:
			printerr("zombie: no normal map on ", part.name, "; leaving normal_tex unset")
		part.material_override = mat
	print("zombie: tint shader on Mesh + helmet")


func _add_outline(root: Node, skeleton: Skeleton3D, source: MeshInstance3D) -> void:
	var shader: Shader = load(OUTLINE_SHADER_PATH)
	if shader == null:
		_fail("could not load shader " + OUTLINE_SHADER_PATH)
		return
	# One hull per source mesh. A single hull copied the body only, which is why
	# the helmet was the lone outlined part; each part needs its own copy
	# because they are separate skinned meshes with separate skins.
	var outline := MeshInstance3D.new()
	outline.name = "Outline" if source.name == "Mesh" else "OutlineHelmet"
	outline.mesh = source.mesh
	outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Copy the source's transform (notably the +Z -> -Z yaw) so hull and mesh
	# are exactly aligned.
	outline.transform = source.transform
	var mat := ShaderMaterial.new()
	mat.shader = shader
	outline.material_override = mat
	root.add_child(outline)
	outline.skeleton = outline.get_path_to(skeleton)
	outline.owner = root
	root.move_child(outline, source.get_index() + 1)
	print("soldier: outline hull for ", source.name, " -> ", outline.skeleton)


# Returns the first texture found under any of `params` on any surface.
func _find_texture(mesh: Mesh, params: Array) -> Texture2D:
	for i in mesh.get_surface_count():
		var mat: Material = mesh.surface_get_material(i)
		if mat is BaseMaterial3D:
			for p in params:
				var value = mat.get(p)
				if value is Texture2D:
					return value
	return null
