#!/usr/bin/env python3
"""Evaluate a trained policy on the Godot RL environment.

Runs N deterministic episodes and reports combat metrics, so reward changes and
model versions can be compared with numbers instead of eyeballing TensorBoard.

Usage:
    python tools/evaluate.py --model models/model.zip --episodes 100
    python tools/evaluate.py --model models/model.zip --env_path build/YMRL.exe
    python tools/evaluate.py --model models/model.zip --json out.json

Episode boundaries are detected from info["episode"], which soldier3_ai.gd
supplies via get_info(). Without that key the wrapper never reports a finished
episode, so this script fails loudly rather than silently reporting zeros.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import statistics
import sys
from dataclasses import dataclass, field

# Same Windows console guard as train_sb3.py: torch/onnx write UTF-8 progress
# markers that cp1252 cannot encode. Must run before torch is imported.
os.environ.setdefault("PYTHONIOENCODING", "utf-8")
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

from stable_baselines3 import PPO

from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv

# Metrics reported per episode. "return_" and "length" come from the standard
# info["episode"] dict; the rest are per-episode counters supplied by
# soldier3_ai.gd::get_info(). Anything listed here that the env does not send
# is reported as 0.0 rather than blowing up, so adding a counter on the Godot
# side is safe before this list catches up -- and vice versa.
METRIC_KEYS = (
    # outcome
    "return_",
    "length",
    "kills",
    "deaths",
    "damage_dealt",
    "damage_taken",
    # effectiveness
    "attacks_started",
    "attacks_hit",
    "attack_hit_rate",
    "attacks_stamina_blocked",
    "blocks_started",
    "blocks_successful",
    "blocks_per_engagement",
    "damage_blocked",
    "steps_to_first_hit",
    # squad & abilities
    "stuns",
    "heals",
    "executions",
    "team_kills",
    "team_deaths",
    # behaviour distribution
    "idle_fraction",
    "full_stamina_fraction",
    "sprint_fraction",
    "block_fraction",
    "attack_fraction",
)


@dataclass
class Episode:
    return_: float = 0.0
    length: int = 0
    # Kept for the JSON payload; get() reads everything from `extra`.
    extra: dict = field(default_factory=dict)

    def get(self, name: str) -> float:
        # Only return_ and length are real dataclass fields. Everything else --
        # including kills / damage_dealt / damage_taken -- arrives through
        # info and lands in `extra`. Reading the (always-zero) dataclass
        # fields here shadowed the real values, which is why the report showed
        # damage_taken 0.00 while the raw info said 21.4.
        if name == "return_":
            return self.return_
        if name == "length":
            return float(self.length)
        return float(self.extra.get(name, 0.0))


@dataclass
class Summary:
    episodes: list[Episode] = field(default_factory=list)

    def _values(self, name: str) -> list[float]:
        return [e.get(name) for e in self.episodes]

    def stats(self) -> dict:
        if not self.episodes:
            return {}
        out = {}
        for name in METRIC_KEYS:
            values = self._values(name)
            out[name] = {
                "mean": statistics.fmean(values),
                "median": statistics.median(values),
                "std": statistics.pstdev(values) if len(values) > 1 else 0.0,
                "min": min(values),
                "max": max(values),
            }
        # Fraction of episodes with at least one kill. A bimodal policy (either
        # 0 or many kills) shows up here but is hidden by the mean.
        out["kill_rate"] = sum(1 for e in self.episodes if e.get("kills") > 0) / len(self.episodes)
        out["episode_count"] = len(self.episodes)
        out["kill_histogram"] = self._kill_histogram()
        return out

    def _kill_histogram(self) -> dict[str, int]:
        histogram: dict[str, int] = {}
        for episode in self.episodes:
            key = str(int(episode.get("kills")))
            histogram[key] = histogram.get(key, 0) + 1
        return dict(sorted(histogram.items(), key=lambda kv: int(kv[0])))


class SeededGodotEnv(StableBaselinesGodotEnv):
    """StableBaselinesGodotEnv with a working seed().

    The upstream wrapper implements seed() as `raise NotImplementedError()`.
    SB3 calls env.seed() from _setup_model() whenever a model with a seed is
    loaded, so PPO.load() crashed here before the first step.

    The seed already reaches Godot at launch: StableBaselinesGodotEnv passes it
    to GodotEnv, which forwards it to the process as --env_seed. Nothing is left
    to do here except satisfy the VecEnv contract. Kept in sync with the
    identical subclass in tools/train_sb3.py.
    """

    def seed(self, seed=None):
        self._seed = seed
        return [None if seed is None else seed + i for i in range(self.num_envs)]


def build_env(args) -> StableBaselinesGodotEnv:
    return SeededGodotEnv(
        env_path=args.env_path,
        show_window=args.viz,
        seed=args.seed,
        n_parallel=1,
        speedup=args.speedup,
        action_repeat=args.action_repeat,
    )


def run_episodes(
    model: PPO,
    env,
    episodes: int,
    max_steps: int,
    deterministic: bool,
    verbose_info: bool = False,
    quiet: bool = False,
) -> Summary:
    summary = Summary()
    obs = env.reset()
    # The wrapper may host several arenas in one process; track each separately
    # so one arena's episode boundary does not bleed into another's counters.
    num_arenas = env.num_envs
    current = [Episode() for _ in range(num_arenas)]
    steps = 0
    # Per-step counters that get_info() reports as running totals. Keep the
    # last value seen for the current episode; they reset on the Godot side.
    EXTRA_KEYS = [k for k in METRIC_KEYS if k not in ("return_", "length")]

    while len(summary.episodes) < episodes and steps < max_steps * episodes:
        actions, _ = model.predict(obs, deterministic=deterministic)
        obs, rewards, dones, infos = env.step(actions)
        steps += 1

        for index, info in enumerate(infos):
            reward = float(rewards[index])
            current[index].return_ += reward
            current[index].length += 1
            for key in EXTRA_KEYS:
                if key in info:
                    current[index].extra[key] = info[key]

            if dones[index]:
                episode_info = info.get("episode")
                if episode_info is None:
                    raise SystemExit(
                        "Episode ended but info['episode'] is missing. "
                        "soldier3_ai.gd get_info() must supply {'r': ..., 'l': ...} "
                        "for VecMonitor and this script to see episode boundaries."
                    )
                current[index].return_ = float(episode_info["r"])
                # NOTE: info["episode"]["l"] is n_steps from AIController3D, which
                # counts PHYSICS FRAMES (600/s), not decision steps (75/s at
                # action_repeat=8). Keep our own decision-step count instead so
                # lengths are comparable with training ep_len_mean... except
                # training has the same bug, so record both for diagnosis.
                reported_l = int(episode_info["l"])
                counted = current[index].length
                current[index].length = counted
                if not quiet:
                    print(
                        f"    [episode {len(summary.episodes) + 1}] "
                        f"decision_steps={counted} reported_l={reported_l} "
                        f"ratio={reported_l / max(counted, 1):.2f} "
                        f"r={current[index].return_:.2f}"
                    )
                # Re-read counters after the final info so the closing step's
                # values are included.
                for key in EXTRA_KEYS:
                    if key in info:
                        current[index].extra[key] = info[key]
                if verbose_info:
                    print(f"    [episode {len(summary.episodes) + 1} raw info] {info}")
                summary.episodes.append(current[index])
                current[index] = Episode()
                if len(summary.episodes) >= episodes:
                    break

    if len(summary.episodes) < episodes:
        print(
            f"Warning: only {len(summary.episodes)} of {episodes} episodes completed "
            f"within the {max_steps * episodes}-step cap. Episodes may not be ending; "
            f"raise --max_steps or check the arena's EpisodeTimer.",
            file=sys.stderr,
        )
    return summary


def print_report(stats: dict, model_path: str) -> None:
    if not stats:
        print("No episodes completed.", file=sys.stderr)
        return
    print(f"\nModel:    {model_path}")
    print(f"Episodes: {stats['episode_count']} completed")
    print()
    header = f"{'metric':<22}{'mean':>10}{'median':>10}{'std':>10}{'min':>10}{'max':>10}"
    print(header)
    print("-" * len(header))
    for name in METRIC_KEYS:
        s = stats[name]
        print(
            f"{name:<22}{s['mean']:>10.2f}{s['median']:>10.2f}"
            f"{s['std']:>10.2f}{s['min']:>10.2f}{s['max']:>10.2f}"
        )
    print()
    print(f"kill_rate:  {stats['kill_rate']:.2%}  (episodes with >= 1 kill)")
    print(f"kills per episode: {stats['kill_histogram']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True, type=str, help="Path to a saved SB3 .zip policy.")
    parser.add_argument("--episodes", default=100, type=int, help="Number of episodes to evaluate (default 100).")
    parser.add_argument("--env_path", default=None, type=str, help="Godot binary. Omit for in-editor evaluation.")
    parser.add_argument("--seed", default=0, type=int, help="Base env seed. Fixed so runs are comparable.")
    # Defaults are None so the value comes from the Sync node in the scene
    # (speed_up = 10, action_repeat = 8). Hardcoding speedup=1 here made
    # evaluation run at a different rate from training, so the EpisodeTimer
    # behaved differently and episodes hit the step cap (3604 steps) instead of
    # ending at ~450. Keep these aligned with training unless testing otherwise.
    parser.add_argument(
        "--speedup",
        default=None,
        type=int,
        help="Physics speedup. Omit to use the scene's Sync.speed_up (recommended).",
    )
    parser.add_argument(
        "--action_repeat",
        default=None,
        type=int,
        help="Action repeat. Omit to use the scene's Sync.action_repeat (recommended).",
    )
    parser.add_argument("--max_steps", default=5000, type=int, help="Step cap per episode guard (default 5000).")
    parser.add_argument("--stochastic", action="store_true", help="Sample actions instead of taking the argmax.")
    parser.add_argument("--viz", action="store_true", help="Show the Godot window (requires --env_path).")
    parser.add_argument("--json", default=None, type=str, help="Write the full report to this JSON path.")
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress per-episode progress messages and print only the final summary report.",
    )
    parser.add_argument(
        "--verbose-info",
        action="store_true",
        help="Print the raw info dict at each episode boundary (diagnostics).",
    )
    args = parser.parse_args()

    model_path = pathlib.Path(args.model)
    if not model_path.exists():
        print(f"Model not found: {model_path}", file=sys.stderr)
        return 1

    env = build_env(args)
    try:
        model = PPO.load(model_path, env=env, device="auto")
        summary = run_episodes(
            model, env, args.episodes, args.max_steps, not args.stochastic,
            verbose_info=args.verbose_info,
            quiet=args.quiet,
        )
        stats = summary.stats()
        print_report(stats, str(model_path))

        if args.json:
            payload = {
                "model": str(model_path),
                "episodes_requested": args.episodes,
                "episodes_completed": len(summary.episodes),
                "seed": args.seed,
                "deterministic": not args.stochastic,
                "stats": stats,
                "episodes": [
                    {**{"return_": e.return_, "length": e.length}, **e.extra}
                    for e in summary.episodes
                ],
            }
            pathlib.Path(args.json).write_text(json.dumps(payload, indent=2), encoding="utf-8")
            print(f"\nWrote {args.json}")
    finally:
        env.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
