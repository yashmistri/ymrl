YMRL - Yash Mistri's Reinforcement Learning Tests for Godot Agents

## Layout

```
res://
  project.godot, YMRL.csproj, YMRL.sln, icon.svg   # Godot/C# project root
  characters/          # agents and enemies
    common/            #   shared base classes (Char, Char3) and shared nodes
    agent/             #   2D seek-target agent
    soldier/           #   2D soldier
    soldier3/          #   3D soldier (main trained agent)
    zombie3/           #   3D zombie
    creature/          #   2D creature
  scenes/              # environments
    2d/                #   target_main, swarm_main
    3d/                #   main3 arena
  training/            # RL training wrappers (Sync node + arena instances)
  ui/                  # HUD scripts
  tools/               # train_sb3.py, evaluate.py, export_headless.py, build_characters.gd
  models/              # saved SB3 .zip policies
  build/               # exported Godot binaries (git-ignored)
  docs/                # design notes and todo lists
  assets/              # art (git-ignored, see .gitignore)
  addons/              # godot_ai, godot_rl_agents (third-party, untouched)
```

## Headless export

Training and evaluation can run without the editor by exporting a binary once:

```
python tools/export_headless.py --install-templates   # first time only (~1.2 GB)
python tools/export_headless.py                       # -> build/YMRL.exe
python tools/export_headless.py --check               # verify prerequisites
```

## Training

```
python tools/train_sb3.py --onnx_export_path=model.onnx --save_model_path=models/model.zip
python tools/train_sb3.py --env_path build/YMRL.exe   # headless, no editor
```

## Evaluation

```
python tools/evaluate.py --model models/model.zip --episodes 100
python tools/evaluate.py --model models/model.zip --env_path build/YMRL.exe --json eval.json
```

Reports return, episode length, kills, damage dealt/taken, kill rate, and a
kills-per-episode histogram. Seeds are fixed so runs are comparable.

See `docs/commands.txt` for resume and inference commands.

Note: the training scene only runs with the Python trainer listening on port
11008. To just look at the game (models, HUD, camera), run the plain arena
instead: `godot --path . res://scenes/3d/main3.tscn`. Details in
`docs/commands.txt` under "WHAT CAN BE RUN WITHOUT THE TRAINING SERVER".

## Character models

The soldier and zombie both render the paladin from `assets/`, baked into
`characters/*/*.tscn` by `tools/build_characters.gd`:

```
godot --headless --path . --import          # once, to extract the FBX textures
godot --headless --path . --script res://tools/build_characters.gd
godot --headless --path . --script res://tools/build_animations.gd
```

`build_characters.gd` replaces the capsule stand-in in each character scene,
keeps every gameplay node (collision, sensors, AI, ray, health bar), and is
re-runnable. It also writes the shaders it references:

- `characters/soldier3/outline.gdshader` -- inverted-hull white outline. The
  paladin is TWO skinned meshes (body + helmet), so each gets its own hull
  (`Outline`, `OutlineHelmet`); a single hull only covered the body and left
  the helmet as the lone outlined part. Width is `outline_width` (0.012 m).
- `characters/common/zombie_tint.gdshader` -- palette-split green tint, applied
  to both meshes. Only neutral steel is mixed toward green; gold trim, leather
  and skin keep their hue, and the darkest crevices stay original. Tune with
  `tint` and `tint_strength`.

The body mesh is named `Mesh` and stays a direct child of the character root:
`char3.gd`/`soldier3_ai.gd` look it up as `$Mesh` / `$"../Mesh"`. It carries a
180 degree yaw because the FBX faces +Z while the game's forward is -Z.

## Locomotion animation

`tools/build_animations.gd` bakes four looping, in-place clips from the Mixamo
set in `assets/Animations/` into `animations/*.res`:

```
    clip            source clip                 direction (measured from Hips')
    walk_forward    sword and shield walk.fbx   +Z
    walk_backward   sword and shield walk (2)   -Z
    walk_left       sword and shield strafe     -X    (paladin's left)
    walk_right      sword and shield strafe (2) +X
```

Directions were measured from the Hips translation channel, not guessed: the
(2)/(3)/(4) variants are different directions, not duplicates. The clips import
with `mixamorig_` bone prefixes, so the baker strips the prefix (the character
skeletons use bare `Hips`, `Spine`, ...). **Root translation is dropped** --
`char3.gd` owns position, and baked travel would slide the character across the
arena.

`characters/common/character_animator.gd` (added to both character scenes as an
`Animator` node) picks the clip from the character's own `move` vector and plays
it, so the animation is cosmetic and cannot reach the reward. There is no idle
clip yet: standing still stops the player on the rest pose.

Two traps, both of which failed silently:

- **Track paths resolve from the player's `root_node`, not the scene.** The
  player lives under `Animator`, so the default root `".."` is `Animator` and
  `Skeleton3D:Hips` does not exist there -- every track logged "couldn't
  resolve track" and the model stayed in its rest pose. The animator points
  `root_node` at the character body.
- **Library handling is asymmetric.** A fresh `AnimationPlayer` has NO `""`
  library (`get_animation_library("")` errors), but once one exists,
  `add_animation_library("", ...)` is a silent no-op that discards the clips.
  Guard with `has_animation_library` before adding.

Changing either one makes the model sit motionless with the clips present, so
verify by checking that a bone's pose actually changes -- `player.has_animation`
returning true is NOT sufficient.

## Facing

The model turns to face the character's `aim`, which `char3.gd` sets from the
turn action / target. The body is a skinned mesh driven by `Skeleton3D`, so
rotating the `MeshInstance3D` does nothing visible -- `CharacterAnimator` yaws
the skeleton's root bones instead.

`char3.gd` no longer calls `mesh.look_at(aim)`. Two things used to read that
mesh rotation and now derive from `aim` directly:

- the **facing observation** (`soldier3_ai.gd`, float 5 of 103). Its formula was
  verified against the old `look_at` behaviour for eight directions -- use
  `atan2(-x, -z)`; the naive `atan2(x, -z)` mirrors left/right and would feed
  every trained checkpoint a flipped input.
- `_attack_is_blocked`, the block arc test.

`RIG_FORWARD_FLIP` in the animator is 0: the paladin mesh carries the 180 degree
build-time yaw, but the bones do not, so adding another 180 made the model face
backwards.


