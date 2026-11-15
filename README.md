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
  tools/               # train_sb3.py, evaluate.py, export_headless.py
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
