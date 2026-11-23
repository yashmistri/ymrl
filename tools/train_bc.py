#!/usr/bin/env python3
"""
Behavioral Cloning (Imitation Learning) for Squad 3v3 / PvE in Godot RL.
Loads demonstrations recorded from heuristic bots (both PvE and PvP),
trains an SB3-compatible policy network using supervised cross-entropy,
and saves the result as both an SB3 .zip checkpoint and an ONNX model.
"""

import os
import sys
import struct
import argparse
import pathlib
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import TensorDataset, DataLoader

# Ensure UTF-8 output on Windows
os.environ.setdefault("PYTHONIOENCODING", "utf-8")
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

import gymnasium as gym
from gymnasium import spaces
from stable_baselines3 import PPO
from godot_rl.wrappers.onnx.stable_baselines_export import export_model_as_onnx

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent

def resolve_path(p: str) -> str:
    path = pathlib.Path(p)
    if not path.is_absolute():
        return str(PROJECT_ROOT / path)
    return str(path)

def load_bin_or_npz(path_base: str):
    path_base = resolve_path(path_base)
    bin_path = path_base + ".bin"
    npz_path = path_base + ".npz"

    if os.path.exists(bin_path):
        print(f"Reading binary demo: {bin_path}")
        with open(bin_path, "rb") as f:
            header = f.read(12)
            if len(header) < 12:
                raise ValueError(f"Corrupt binary file {bin_path}")
            n_samples, obs_dim, act_dim = struct.unpack("<III", header)
            print(f"  Header: {n_samples} samples, {obs_dim} obs_dim, {act_dim} act_dim")
            obs_bytes = f.read(n_samples * obs_dim * 4)
            act_bytes = f.read(n_samples * act_dim)

            obs = np.frombuffer(obs_bytes, dtype=np.float32).reshape((n_samples, obs_dim)).copy()
            actions = np.frombuffer(act_bytes, dtype=np.uint8).reshape((n_samples, act_dim)).astype(np.int64).copy()

        # Save compressed npz for future instant loading
        print(f"Saving compressed archive: {npz_path}")
        np.savez_compressed(npz_path, obs=obs, actions=actions)
        return obs, actions

    elif os.path.exists(npz_path):
        print(f"Loading compressed npz demo: {npz_path}")
        data = np.load(npz_path)
        return data["obs"], data["actions"]
    else:
        raise FileNotFoundError(f"Neither {bin_path} nor {npz_path} exists!")


def main():
    parser = argparse.ArgumentParser(description="Train Behavioral Cloning model on squad demos")
    parser.add_argument("--pve_demo", type=str, default="demos/pve_demos", help="Path prefix for PvE demo file (.bin or .npz)")
    parser.add_argument("--pvp_demo", type=str, default="demos/pvp_demos", help="Path prefix for PvP demo file (.bin or .npz)")
    parser.add_argument("--epochs", type=int, default=25, help="Number of training epochs (default: 25)")
    parser.add_argument("--batch_size", type=int, default=128, help="Batch size (default: 128)")
    parser.add_argument("--lr", type=float, default=1e-3, help="Learning rate (default: 1e-3)")
    parser.add_argument("--save_path", type=str, default="models/bc_squad_pretrained.zip", help="Output path for SB3 .zip model")
    parser.add_argument("--onnx_path", type=str, default="models/bc_squad_pretrained.onnx", help="Output path for ONNX model")
    parser.add_argument("--device", type=str, default="auto", help="Torch device ('auto', 'cuda', 'cpu')")
    args = parser.parse_args()

    # Load PvE and PvP datasets
    all_obs = []
    all_acts = []

    # 1. PvE
    pve_base = args.pve_demo.replace(".bin", "").replace(".npz", "")
    pve_obs, pve_acts = load_bin_or_npz(pve_base)
    print(f"Loaded PvE demos: {len(pve_obs)} samples")
    all_obs.append(pve_obs)
    all_acts.append(pve_acts)

    # 2. PvP
    pvp_base = args.pvp_demo.replace(".bin", "").replace(".npz", "")
    pvp_obs, pvp_acts = load_bin_or_npz(pvp_base)
    print(f"Loaded PvP demos: {len(pvp_obs)} samples")
    all_obs.append(pvp_obs)
    all_acts.append(pvp_acts)

    # Combine datasets
    obs = np.concatenate(all_obs, axis=0)
    acts = np.concatenate(all_acts, axis=0)
    total_samples = len(obs)
    print(f"\nTotal Dataset: {total_samples} samples. Obs shape: {obs.shape}, Acts shape: {acts.shape}")

    # Dataset distribution statistics
    # Obs structure:
    # 0..7: wall rays (8)
    # 8..107: entity slots (100)
    # 108..135: ally slots (28)
    # 136: hp, 137: stam, 138: x, 139: z, 140: yaw
    # 141: is_tank, 142: is_medic, 143: is_striker, 144: level
    tank_count = np.sum(obs[:, 141] > 0.5)
    medic_count = np.sum(obs[:, 142] > 0.5)
    striker_count = np.sum(obs[:, 143] > 0.5)
    print("\nRole Breakdown:")
    print(f"  Tank:    {tank_count:6d} ({tank_count/total_samples*100:5.1f}%)")
    print(f"  Medic:   {medic_count:6d} ({medic_count/total_samples*100:5.1f}%)")
    print(f"  Striker: {striker_count:6d} ({striker_count/total_samples*100:5.1f}%)")

    print("\nAction Breakdown:")
    print(f"  Attack:  {np.sum(acts[:, 0] == 1):6d} attacks ({np.mean(acts[:, 0] == 1)*100:5.1f}%)")
    print(f"  Block:   {np.sum(acts[:, 1] == 1):6d} blocks  ({np.mean(acts[:, 1] == 1)*100:5.1f}%)")
    print(f"  Sprint:  {np.sum(acts[:, 3] == 1):6d} sprints ({np.mean(acts[:, 3] == 1)*100:5.1f}%)")
    print("  Move directions (0=idle, 1=fwd, 2=fwd-r, 3=r, 4=b-r, 5=back, 6=b-l, 7=l, 8=fwd-l):")
    for m in range(9):
        print(f"    dir {m}: {np.sum(acts[:, 2] == m):6d} ({np.mean(acts[:, 2] == m)*100:5.1f}%)")

    # Select Device
    if args.device == "auto":
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    else:
        device = torch.device(args.device)
    print(f"\nTraining on device: {device}")

    # Create dummy gym environment to initialize identical SB3 PPO MultiInputPolicy
    obs_space = spaces.Dict({
        "obs": spaces.Box(low=-np.inf, high=np.inf, shape=(145,), dtype=np.float32)
    })
    act_space = spaces.MultiDiscrete([2, 2, 9, 2, 3])

    class DummyEnv(gym.Env):
        def __init__(self):
            super().__init__()
            self.observation_space = obs_space
            self.action_space = act_space

    dummy_env = DummyEnv()
    model = PPO(
        "MultiInputPolicy",
        dummy_env,
        policy_kwargs=dict(net_arch=[256, 256]),
        device=device,
        learning_rate=args.lr,
    )
    policy = model.policy
    policy.to(device)

    # Train / Validation Split
    indices = np.arange(total_samples)
    np.random.seed(42)
    np.random.shuffle(indices)
    split = int(0.85 * total_samples)
    train_idx, val_idx = indices[:split], indices[split:]

    obs_tensor = torch.from_numpy(obs).float()
    act_tensor = torch.from_numpy(acts).long()

    train_dataset = TensorDataset(obs_tensor[train_idx], act_tensor[train_idx])
    val_dataset = TensorDataset(obs_tensor[val_idx], act_tensor[val_idx])

    train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True)
    val_loader = DataLoader(val_dataset, batch_size=args.batch_size, shuffle=False)

    optimizer = torch.optim.AdamW(policy.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.epochs, eta_min=1e-5)

    print(f"\nStarting Behavioral Cloning Training ({args.epochs} epochs)...")
    print(f"Train samples: {len(train_idx)}, Validation samples: {len(val_idx)}\n")

    best_val_acc = 0.0
    for epoch in range(1, args.epochs + 1):
        policy.train()
        total_loss = 0.0
        n_batches = 0

        for b_obs, b_act in train_loader:
            b_obs = b_obs.to(device)
            b_act = b_act.to(device)

            # Forward pass through SB3 feature extractor and actor network
            features = policy.extract_features({"obs": b_obs})
            latent_pi = policy.mlp_extractor.forward_actor(features)
            logits = policy.action_net(latent_pi) # Shape: (B, 18)

            # MultiDiscrete heads: [2, 2, 9, 2, 3] -> total 18 logits
            # 0:2 -> attack
            # 2:4 -> block
            # 4:13 -> move
            # 13:15 -> sprint
            # 15:18 -> turn
            l_att = F.cross_entropy(logits[:, 0:2], b_act[:, 0])
            l_blk = F.cross_entropy(logits[:, 2:4], b_act[:, 1])
            l_mov = F.cross_entropy(logits[:, 4:13], b_act[:, 2])
            l_spr = F.cross_entropy(logits[:, 13:15], b_act[:, 3])
            l_trn = F.cross_entropy(logits[:, 15:18], b_act[:, 4])

            # Loss weighting
            loss = l_att * 2.0 + l_blk * 2.0 + l_mov * 1.0 + l_spr * 1.0 + l_trn * 1.5

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

            total_loss += loss.item()
            n_batches += 1

        scheduler.step()
        avg_train_loss = total_loss / n_batches

        # Validation
        policy.eval()
        val_loss = 0.0
        correct_att = 0
        correct_blk = 0
        correct_mov = 0
        correct_spr = 0
        correct_trn = 0
        val_total = 0

        with torch.no_grad():
            for b_obs, b_act in val_loader:
                b_obs = b_obs.to(device)
                b_act = b_act.to(device)

                features = policy.extract_features({"obs": b_obs})
                latent_pi = policy.mlp_extractor.forward_actor(features)
                logits = policy.action_net(latent_pi)

                l_att = F.cross_entropy(logits[:, 0:2], b_act[:, 0])
                l_blk = F.cross_entropy(logits[:, 2:4], b_act[:, 1])
                l_mov = F.cross_entropy(logits[:, 4:13], b_act[:, 2])
                l_spr = F.cross_entropy(logits[:, 13:15], b_act[:, 3])
                l_trn = F.cross_entropy(logits[:, 15:18], b_act[:, 4])
                loss = l_att * 2.0 + l_blk * 2.0 + l_mov * 1.0 + l_spr * 1.0 + l_trn * 1.5
                val_loss += loss.item()

                pred_att = torch.argmax(logits[:, 0:2], dim=1)
                pred_blk = torch.argmax(logits[:, 2:4], dim=1)
                pred_mov = torch.argmax(logits[:, 4:13], dim=1)
                pred_spr = torch.argmax(logits[:, 13:15], dim=1)
                pred_trn = torch.argmax(logits[:, 15:18], dim=1)

                correct_att += (pred_att == b_act[:, 0]).sum().item()
                correct_blk += (pred_blk == b_act[:, 1]).sum().item()
                correct_mov += (pred_mov == b_act[:, 2]).sum().item()
                correct_spr += (pred_spr == b_act[:, 3]).sum().item()
                correct_trn += (pred_trn == b_act[:, 4]).sum().item()
                val_total += len(b_obs)

        avg_val_loss = val_loss / len(val_loader)
        acc_att = correct_att / val_total * 100.0
        acc_blk = correct_blk / val_total * 100.0
        acc_mov = correct_mov / val_total * 100.0
        acc_spr = correct_spr / val_total * 100.0
        acc_trn = correct_trn / val_total * 100.0
        mean_acc = (acc_att + acc_blk + acc_mov + acc_spr + acc_trn) / 5.0

        if mean_acc > best_val_acc:
            best_val_acc = mean_acc

        print(
            f"Epoch {epoch:2d}/{args.epochs:2d} | "
            f"Train Loss: {avg_train_loss:.4f} | "
            f"Val Loss: {avg_val_loss:.4f} | "
            f"Acc: [Atk:{acc_att:4.1f}% Blk:{acc_blk:4.1f}% Mov:{acc_mov:4.1f}% Spr:{acc_spr:4.1f}% Trn:{acc_trn:4.1f}%] "
            f"Avg:{mean_acc:4.1f}%"
        )

    # Save SB3 Model
    resolved_save_path = resolve_path(args.save_path)
    os.makedirs(os.path.dirname(os.path.abspath(resolved_save_path)), exist_ok=True)
    save_zip = str(pathlib.Path(resolved_save_path).with_suffix(".zip"))
    print(f"\nSaving pre-trained SB3 model to: {save_zip}")
    model.save(save_zip)
    print("SB3 model saved successfully!")

    # Export to ONNX
    if args.onnx_path:
        resolved_onnx_path = resolve_path(args.onnx_path)
        onnx_file = str(pathlib.Path(resolved_onnx_path).with_suffix(".onnx"))
        print(f"Exporting pre-trained policy to ONNX: {onnx_file}")
        try:
            export_model_as_onnx(model, onnx_file)
            print("ONNX export succeeded!")
        except Exception as e:
            print(f"WARNING: ONNX export failed: {e}")

    print("\n=======================================================")
    print("Behavioral Cloning Pre-training Complete!")
    print(f"Best Overall Accuracy: {best_val_acc:.2f}%")
    print(f"Model saved at: {save_zip}")
    print("=======================================================")


if __name__ == "__main__":
    main()
