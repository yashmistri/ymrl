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
import pathlib
import statistics
import sys
from dataclasses import dataclass, field, asdict

from stable_baselines3 import PPO

from godot_rl.wrappers.stable_baselines_wrapper import StableBaselinesGodotEnv

# Metrics reported per episode. "kills" and "damage_*" come from get_info();
# "return" and "length" come from the standard info["episode"] dict.
METRIC_KEYS = ("return_", "length", "kills", "damage_dealt", "damage_taken")


@dataclass
class Episode:
    return_: float
    length: int
    kills: int
    damage_dealt: float
    damage_taken: float


@dataclass
class Summary:
    episodes: list[Episode] = field(default_factory=list)

    def _values(self, name: str) -> list[float]:
        return [getattr(e, name) for e in self.episodes]

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
        out["kill_rate"] = sum(1 for e in self.episodes if e.kills > 0) / len(self.episodes)
        out["episode_count"] = len(self.episodes)
        out["kill_histogram"] = self._kill_histogram()
        return out

    def _kill_histogram(self) -> dict[str, int]:
        histogram: dict[str, int] = {}
        for episode in self.episodes:
            key = str(episode.kills)
            histogram[key] = histogram.get(key, 0) + 1
        return dict(sorted(histogram.items(), key=lambda kv: int(kv[0])))


def build_env(args) -> StableBaselinesGodotEnv:
    return StableBaselinesGodotEnv(
        env_path=args.env_path,
        show_window=args.viz,
        seed=args.seed,
        n_parallel=1,
        speedup=args.speedup,
        action_repeat=args.action_repeat,
    )


def run_episodes(model: PPO, env, episodes: int, max_steps: int, deterministic: bool) -> Summary:
    summary = Summary()
    obs = env.reset()
    # The wrapper may host several arenas in one process; track each separately
    # so one arena's episode boundary does not bleed into another's counters.
    num_arenas = env.num_envs
    current = [Episode(0.0, 0, 0, 0.0, 0.0) for _ in range(num_arenas)]
    steps = 0

    while len(summary.episodes) < episodes and steps < max_steps * episodes:
        actions, _ = model.predict(obs, deterministic=deterministic)
        obs, rewards, dones, infos = env.step(actions)
        steps += 1

        for index, info in enumerate(infos):
            reward = float(rewards[index])
            current[index].return_ += reward
            current[index].length += 1
            current[index].kills = int(info.get("kills", current[index].kills))
            current[index].damage_dealt = float(info.get("damage_dealt", current[index].damage_dealt))
            current[index].damage_taken = float(info.get("damage_taken", current[index].damage_taken))

            if dones[index]:
                episode_info = info.get("episode")
                if episode_info is None:
                    raise SystemExit(
                        "Episode ended but info['episode'] is missing. "
                        "soldier3_ai.gd get_info() must supply {'r': ..., 'l': ...} "
                        "for VecMonitor and this script to see episode boundaries."
                    )
                current[index].return_ = float(episode_info["r"])
                current[index].length = int(episode_info["l"])
                # get_info() sets is_success when the agent scored a kill, so an
                # episode that ended without one is a death or a timeout. The env
                # does not distinguish them, so record it as "no kill".
                summary.episodes.append(current[index])
                current[index] = Episode(0.0, 0, 0, 0.0, 0.0)
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
    header = f"{'metric':<16}{'mean':>10}{'median':>10}{'std':>10}{'min':>10}{'max':>10}"
    print(header)
    print("-" * len(header))
    for name in METRIC_KEYS:
        s = stats[name]
        print(
            f"{name:<16}{s['mean']:>10.2f}{s['median']:>10.2f}"
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
    parser.add_argument("--speedup", default=1, type=int, help="Physics speedup factor.")
    parser.add_argument("--action_repeat", default=None, type=int, help="Override the sync node's action repeat.")
    parser.add_argument("--max_steps", default=5000, type=int, help="Step cap per episode guard (default 5000).")
    parser.add_argument("--stochastic", action="store_true", help="Sample actions instead of taking the argmax.")
    parser.add_argument("--viz", action="store_true", help="Show the Godot window (requires --env_path).")
    parser.add_argument("--json", default=None, type=str, help="Write the full report to this JSON path.")
    args = parser.parse_args()

    model_path = pathlib.Path(args.model)
    if not model_path.exists():
        print(f"Model not found: {model_path}", file=sys.stderr)
        return 1

    env = build_env(args)
    try:
        model = PPO.load(model_path, env=env, device="auto")
        summary = run_episodes(model, env, args.episodes, args.max_steps, not args.stochastic)
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
                "episodes": [asdict(e) for e in summary.episodes],
            }
            pathlib.Path(args.json).write_text(json.dumps(payload, indent=2), encoding="utf-8")
            print(f"\nWrote {args.json}")
    finally:
        env.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
