import os
import sys

# torch.onnx prints progress markers with a U+2705 check mark. On Windows the
# console defaults to cp1252, which cannot encode it, so the export dies with
# UnicodeEncodeError *after* the graph is built. Forcing UTF-8 on the stdio
# streams fixes it. This must run before torch is imported.
os.environ.setdefault("PYTHONIOENCODING", "utf-8")
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass  # Non-reconfigurable stream (e.g. redirected): not fatal.

import argparse
import pathlib
from typing import Callable

from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import CheckpointCallback
from stable_baselines3.common.vec_env.vec_monitor import VecMonitor

from godot_rl.core.utils import can_import
from godot_rl.wrappers.onnx.stable_baselines_export import export_model_as_onnx
from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv

# To download the env source and binary:
# 1.  gdrl.env_from_hub -r edbeeching/godot_rl_BallChase
# 2.  chmod +x examples/godot_rl_BallChase/bin/BallChase.x86_64
if can_import("ray"):
    print("WARNING, stable baselines and ray[rllib] are not compatible")

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument(
    "--env_path",
    default=None,
    type=str,
    help="The Godot binary to use, do not include for in editor training",
)
parser.add_argument(
    "--experiment_dir",
    default="logs/sb3",
    type=str,
    help="The name of the experiment directory, in which the tensorboard logs and checkpoints (if enabled) are "
    "getting stored.",
)
parser.add_argument(
    "--experiment_name",
    default="experiment",
    type=str,
    help="The name of the experiment, which will be displayed in tensorboard and "
    "for checkpoint directory and name (if enabled).",
)
parser.add_argument("--seed", type=int, default=0, help="seed of the experiment")
parser.add_argument(
    "--resume_model_path",
    default=None,
    type=str,
    help="The path to a model file previously saved using --save_model_path or a checkpoint saved using "
    "--save_checkpoints_frequency. Use this to resume training or infer from a saved model.",
)
parser.add_argument(
    "--save_model_path",
    default=None,
    type=str,
    help="The path to use for saving the trained sb3 model after training is complete. Saved model can be used later "
    "to resume training. Extension will be set to .zip",
)
parser.add_argument(
    "--save_checkpoint_frequency",
    default=None,
    type=int,
    help=(
        "If set, will save checkpoints every 'frequency' environment steps. "
        "Requires a unique --experiment_name or --experiment_dir for each run. "
        "Does not need --save_model_path to be set. "
    ),
)
parser.add_argument(
    "--onnx_export_path",
    default=None,
    type=str,
    help="If included, will export onnx file after training to the path specified.",
)
parser.add_argument(
    "--timesteps",
    default=1_000_000,
    type=int,
    help="The number of environment steps to train for, default is 1_000_000. If resuming from a saved model, "
    "it will continue training for this amount of steps from the saved state without counting previously trained "
    "steps",
)
parser.add_argument(
    "--inference",
    default=False,
    action="store_true",
    help="Instead of training, it will run inference on a loaded model for --timesteps steps. "
    "Requires --resume_model_path to be set.",
)
parser.add_argument(
    "--linear_lr_schedule",
    default=False,
    action="store_true",
    help="Use a linear LR schedule for training. If set, learning rate will decrease until it reaches 0 at "
    "--timesteps"
    "value. Note: On resuming training, the schedule will reset. If disabled, constant LR will be used.",
)
parser.add_argument(
    "--viz",
    action="store_true",
    help="If set, the simulation will be displayed in a window during training. Otherwise "
    "training will run without rendering the simulation. This setting does not apply to in-editor training.",
    default=False,
)
parser.add_argument("--speedup", default=1, type=int, help="Whether to speed up the physics in the env")
parser.add_argument(
    "--action_repeat",
    default=None,
    type=int,
    help="Similar concept to frame skip, sends action/gets obs every n frames only. Uses sync node setting if not set here.",
)
parser.add_argument(
    "--n_parallel",
    default=1,
    type=int,
    help="How many separate environment executables to launch. Requires --env_path "
    "when > 1: each parallel env is its own Godot process, which is what actually "
    "parallelizes rollout collection. With --env_path omitted, training runs "
    "in-editor against a single process and this must stay 1.",
)
parser.add_argument("--learning_rate", default=0.0003, type=float, help="The learning rate (default 0.0003)")
parser.add_argument(
    "--n_steps",
    default=64,
    type=int,
    help="Number of steps to run for each environment per update (default 64).",
)
parser.add_argument(
    "--batch_size",
    default=None,
    type=int,
    help="The minibatch size. Defaults to the full rollout (n_steps × n_envs). "
    "The rollout size = n_steps × n_envs must be divisible by batch_size without remainder.",
)
parser.add_argument(
    "--device",
    default="auto",
    type=str,
    help="Torch device for the policy ('auto', 'cpu', 'cuda', 'cuda:0'). 'auto' picks CUDA when available.",
)
parser.add_argument(
    "--ent_coef",
    # 0.01 was tuned while learning from scratch. For FINE-TUNING an already
    # competent checkpoint it is too strong: the 20k continuation at 0.01 halved
    # its attack rate (5.4 -> 2.4 per episode) and cut kill_rate 42% -> 12%,
    # i.e. entropy pressure pushed the policy away from the behaviour it had
    # found. 0.001 still permits exploration without dismantling a good policy.
    default=0.001,
    type=float,
    help="The entropy coefficient for the loss calculation (default 0.001)",
)
parser.add_argument(
    "--clip_range",
    default=0.2,
    type=float,
    help="The clipping range (default 0.2). This limits the policy changes per update",
)

args, extras = parser.parse_known_args()


def resolve_batch_size(n_steps: int, n_envs: int, requested: int | None) -> int:
    """Pick a batch size that divides the rollout exactly.

    PPO splits each rollout (n_steps x n_envs) into minibatches, so the batch
    size must divide it. The previous hardcoded 256 did not divide the default
    64-step single-env rollout and silently ignored --batch_size.
    """
    rollout_size = n_steps * n_envs
    if requested is None:
        return rollout_size
    if requested <= 0:
        raise parser.error(f"--batch_size must be positive, got {requested}")
    if rollout_size % requested != 0:
        raise parser.error(
            f"--batch_size {requested} does not divide the rollout size "
            f"n_steps x n_envs = {n_steps} x {n_envs} = {rollout_size}. "
            f"Pick a divisor of {rollout_size}, or omit --batch_size to use the full rollout."
        )
    return requested


def handle_onnx_export():
    # Enforce the extension of onnx and zip when saving model to avoid potential conflicts in case of same name
    # and extension used for both
    if args.onnx_export_path is None:
        return True
    try:
        path_onnx = pathlib.Path(args.onnx_export_path).with_suffix(".onnx")
        print("Exporting onnx to: " + os.path.abspath(path_onnx))
        export_model_as_onnx(model, str(path_onnx))
        return True
    except Exception as e:
        # The export is optional; losing it must never cost us the .zip.
        print(f"WARNING: ONNX export failed, continuing: {type(e).__name__}: {e}")
        # Give the hint that matches the failure rather than always blaming a
        # missing package -- the common Windows failure is an encoding error.
        if isinstance(e, UnicodeEncodeError):
            print(
                "         Console encoding cannot print torch.onnx's progress "
                "markers.\n"
                "         Re-run with PYTHONIOENCODING=utf-8 (this script sets it "
                "automatically;\n"
                "         seeing this means an older copy ran, or stdout was "
                "redirected oddly)."
            )
        elif isinstance(e, ModuleNotFoundError) and "onnxscript" in str(e):
            print("         Fix with: uv add onnxscript   (torch >= 2.6 requires it)")
        else:
            print(
                "         The .zip was still written. To retry just the export:\n"
                "         see handle_onnx_export() in this file."
            )
        return False


def handle_model_save():
    if args.save_model_path is None:
        return True
    try:
        zip_save_path = pathlib.Path(args.save_model_path).with_suffix(".zip")
        print("Saving model to: " + os.path.abspath(zip_save_path))
        model.save(zip_save_path)
        return True
    except Exception as e:
        print(f"ERROR: saving model failed: {type(e).__name__}: {e}")
        return False


def close_env():
    try:
        print("closing env")
        env.close()
    except Exception as e:
        print("Exception while closing env: ", e)


def cleanup():
    """Run every teardown step, even if an earlier one fails.

    Each step is independent on purpose: a missing optional dependency used to
    abort the whole sequence, which silently skipped the model save. The .zip
    is the artifact you cannot regenerate; everything else is replaceable.
    """
    results = {
        "onnx_export": handle_onnx_export(),
        "model_save": handle_model_save(),
    }
    close_env()
    if args.save_model_path is not None and not results["model_save"]:
        print("The trained model was NOT saved. Check --save_model_path and disk space.")
    return all(results.values())


path_checkpoint = os.path.join(args.experiment_dir, args.experiment_name + "_checkpoints")
abs_path_checkpoint = os.path.abspath(path_checkpoint)

# Prevent overwriting existing checkpoints when starting a new experiment if checkpoint saving is enabled
if args.save_checkpoint_frequency is not None and os.path.isdir(path_checkpoint):
    raise RuntimeError(
        abs_path_checkpoint + " folder already exists. "
        "Use a different --experiment_dir, or --experiment_name,"
        "or if previous checkpoints are not needed anymore, "
        "remove the folder containing the checkpoints. "
    )

if args.inference and args.resume_model_path is None:
    raise parser.error("Using --inference requires --resume_model_path to be set.")

if args.env_path is None and args.viz:
    print("Info: Using --viz without --env_path set has no effect, in-editor training will always render.")

if args.n_parallel > 1 and args.env_path is None:
    raise parser.error(
        f"--n_parallel {args.n_parallel} requires --env_path. Each parallel env is a "
        "separate Godot process; in-editor training drives the one open editor and "
        "cannot be parallelized this way. Export a build first:\n"
        "    python tools/export_headless.py\n"
        "    python tools/train_sb3.py --env_path build/YMRL.exe --n_parallel "
        f"{args.n_parallel}"
    )

if args.n_parallel < 1:
    raise parser.error(f"--n_parallel must be >= 1, got {args.n_parallel}")

if args.env_path is None and args.n_parallel == 1:
    print(
        "Info: in-editor training uses one Godot process. For real parallelism, "
        "export a build and pass --env_path with --n_parallel > 1."
    )


class SeededGodotEnv(StableBaselinesGodotEnv):
    """StableBaselinesGodotEnv with a working seed().

    The upstream wrapper implements seed() as `raise NotImplementedError()`.
    SB3 >= 2.0 calls env.seed() from _setup_model() whenever PPO(seed=...) is
    given, so training crashed before the first step.

    The seed already reaches Godot at launch: StableBaselinesGodotEnv passes it
    to GodotEnv, which forwards it to the process as --env_seed. Nothing is left
    to do here except satisfy the VecEnv contract, so this records the value and
    reports it back rather than reseeding a running game.
    """

    def seed(self, seed=None):
        self._seed = seed
        return [None if seed is None else seed + i for i in range(self.num_envs)]


env = SeededGodotEnv(
    env_path=args.env_path,
    show_window=args.viz,
    seed=args.seed,
    n_parallel=args.n_parallel,
    speedup=args.speedup,
    action_repeat=args.action_repeat,
)
env = VecMonitor(env)

# -- Env shape check -------------------------------------------------------
# Checkpoints are only resumable if the env produces the same observation and
# action shapes as when the model was trained. soldier3_ai.gd changed both on
# purpose: the 13-ray char sensor (31 obs) was replaced by WallSensor +
# EntitySensor (8 wall + 90 entity + 5 manual = 103 obs), and the 6-head action
# space was collapsed to 5 heads (move 9, turn 3, attack 2, sprint 2, block 2).
# Any model saved BEFORE that change cannot load.
#
# Failing here with an explicit message is much better than letting PPO.load
# die on a tensor-shape mismatch, which reads like a corrupted checkpoint.
EXPECTED_OBS_SIZE = 103
# Alphabetical: this is the order Godot's JSON.stringify emits, which is what
# the trainer builds MultiDiscrete from. soldier3_ai.gd::get_action_space()
# declares its keys in the same order so Godot's slicing order matches.
# attack(2), block(2), move(9), sprint(2), turn(3)
EXPECTED_ACTION_HEADS = (2, 2, 9, 2, 3)
EXPECTED_ACTION_HEAD_COUNTS = tuple(sorted(EXPECTED_ACTION_HEADS))


def _observed_shapes(env) -> tuple:
    """Return (obs_size, action_heads) for the wrapped Godot env."""
    obs_space = env.observation_space
    # Single-agent envs are Dict({"obs": Box(n)}); fall back to Box directly.
    if hasattr(obs_space, "spaces"):
        box = obs_space.spaces.get("obs", obs_space)
    else:
        box = obs_space
    obs_size = int(box.shape[0]) if len(box.shape) else int(box.shape)

    act_space = env.action_space
    if hasattr(act_space, "nvec"):
        heads = tuple(int(n) for n in act_space.nvec)
    else:
        heads = (int(act_space.n),)
    return obs_size, heads


_obs_size, _action_heads = _observed_shapes(env)
# Order matters, not just the set of sizes. Godot slices the action vector by
# its own key order; the trainer builds MultiDiscrete from JSON order. If those
# disagree the total count still matches, so nothing errors -- actions just go
# to the wrong heads. Treat any order difference as a hard failure.
if _obs_size != EXPECTED_OBS_SIZE or tuple(_action_heads) != EXPECTED_ACTION_HEADS:
    raise SystemExit(
        "\nEnv shape does not match what this training setup expects.\n"
        f"  expected: obs={EXPECTED_OBS_SIZE} actions={EXPECTED_ACTION_HEADS}\n"
        f"  actual:   obs={_obs_size} actions={_action_heads}\n\n"
        "If the action heads are the right sizes but in a different order,\n"
        "soldier3_ai.gd::get_action_space() is returning keys in an order that\n"
        "differs from alphabetical. Godot's JSON.stringify alphabetises keys\n"
        "while _extract_action_dict slices by insertion order, so the two must\n"
        "agree -- declare the keys alphabetically.\n\n"
        "If you changed the sensors or action space on purpose, update\n"
        "EXPECTED_OBS_SIZE / EXPECTED_ACTION_HEADS in tools/train_sb3.py.\n"
        "Checkpoints saved under a different shape/order are NOT loadable.\n"
    )

print(f"Env shape OK: obs={_obs_size} actions={_action_heads}")


# LR schedule code snippet from:
# https://stable-baselines3.readthedocs.io/en/master/guide/examples.html#learning-rate-schedule
# Fraction of the initial LR kept at the end of a linear decay. Decaying all
# the way to 0 freezes the policy: the previous run ended at 1.8e-06, six orders
# below the start, and could not recover from a dip (peaked 0.86 at step 41k,
# then fell to 0.64 with essentially no learning happening). A floor keeps the
# late run stable without removing the ability to correct.
LR_FLOOR_FRACTION = 0.1


def linear_schedule(initial_value: float) -> Callable[[float], float]:
    """Linear decay from initial_value down to initial_value * LR_FLOOR_FRACTION.

    :param initial_value: Initial learning rate (used at progress_remaining=1).
    :return: schedule mapping progress_remaining (1 -> 0) to a learning rate.
    """

    def func(progress_remaining: float) -> float:
        return initial_value * (LR_FLOOR_FRACTION + (1.0 - LR_FLOOR_FRACTION) * progress_remaining)

    return func


if args.resume_model_path is None:
    learning_rate = args.learning_rate if not args.linear_lr_schedule else linear_schedule(args.learning_rate)
    batch_size = resolve_batch_size(args.n_steps, env.num_envs, args.batch_size)

    model: PPO = PPO(
        "MultiInputPolicy",
        env,
        device=args.device,
        # 0.0001 was far too low: entropy collapsed from ~5.4 nats (near-uniform
        # over 216 actions) to ~0.9 within 25k steps, locking the policy into a
        # circling local optimum before it found the zombie.
        ent_coef=args.ent_coef,
        verbose=2,
        n_steps=args.n_steps,
        n_epochs=20,
        # Kill reward arrives at the end of a long approach. At gamma=0.99 with
        # action_repeat=8 that signal was discounted into noise.
        gamma=0.995,
        tensorboard_log=args.experiment_dir,
        learning_rate=learning_rate,
        batch_size=batch_size,
        clip_range=args.clip_range,
        policy_kwargs=dict(net_arch=[256, 256]),  # or [512, 512]
        seed=args.seed,
    )
    print(
        f"Training config: n_envs={env.num_envs} n_steps={args.n_steps} "
        f"rollout={args.n_steps * env.num_envs} batch_size={batch_size} "
        f"device={args.device} seed={args.seed}"
    )
else:
    path_zip = pathlib.Path(args.resume_model_path)
    print("Loading model: " + os.path.abspath(path_zip))
    # PPO.load restores saved hyperparameters (including learning_rate as a
    # plain float), so --n_steps etc. do not apply here. But an explicit
    # --linear_lr_schedule SHOULD: without this it was silently ignored on
    # resume, leaving the LR pinned for the whole run and the policy unable to
    # settle -- the 100k run oscillated 0.28-0.62 success instead of converging.
    model = PPO.load(path_zip, env=env, tensorboard_log=args.experiment_dir)
    if args.linear_lr_schedule:
        model.learning_rate = linear_schedule(args.learning_rate)
        model._setup_lr_schedule()
        print(
            f"Applied linear LR schedule on resume: {args.learning_rate} -> "
            f"{args.learning_rate * LR_FLOOR_FRACTION:.3e} floor over {args.timesteps} steps"
        )
    # ent_coef is restored from the zip too, so an explicit --ent_coef would be
    # silently ignored on resume (same trap as --linear_lr_schedule). Apply it.
    if args.ent_coef != model.ent_coef:
        print(f"Overriding resumed ent_coef: {model.ent_coef} -> {args.ent_coef}")
        model.ent_coef = args.ent_coef
    print(
        f"Resumed config (from {path_zip.name}): n_steps={model.n_steps} "
        f"batch_size={model.batch_size} gamma={model.gamma} "
        f"ent_coef={model.ent_coef} lr={model.learning_rate} "
        f"n_epochs={model.n_epochs} device={model.device}"
    )

if args.inference:
    obs = env.reset()
    for i in range(args.timesteps):
        action, _state = model.predict(obs, deterministic=True)
        obs, reward, done, info = env.step(action)
else:
    learn_arguments = dict(total_timesteps=args.timesteps, tb_log_name=args.experiment_name)
    if args.save_checkpoint_frequency:
        print("Checkpoint saving enabled. Checkpoints will be saved to: " + abs_path_checkpoint)
        checkpoint_callback = CheckpointCallback(
            save_freq=(args.save_checkpoint_frequency // env.num_envs),
            save_path=path_checkpoint,
            name_prefix=args.experiment_name,
        )
        learn_arguments["callback"] = checkpoint_callback
    try:
        model.learn(**learn_arguments)
    except (KeyboardInterrupt, ConnectionError, ConnectionResetError):
        print("""Training interrupted by user or a ConnectionError. Will save if --save_model_path was
            used and/or export if --onnx_export_path was used.""")
    finally:
        cleanup()
