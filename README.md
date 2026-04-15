# Arc Node Setup & Manager

> **One-script installer and management tool for running an [Arc Network](https://arc.network) testnet node.**  
> Arc is Circle's stablecoin-native Layer-1 blockchain — built for USDC and on-chain finance.

[![Shell](https://img.shields.io/badge/shell-bash-89e051?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Testnet](https://img.shields.io/badge/Arc%20Testnet-v0.6.0-blue)](https://github.com/circlefin/arc-node)
[![Platform](https://img.shields.io/badge/platform-Ubuntu%2022.04%2B%20%7C%20Debian%2012%2B-orange)](https://ubuntu.com/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

## Table of Contents

- [Overview](#overview)
- [System Requirements](#system-requirements)
- [Quick Start](#quick-start)
- [All Commands](#all-commands)
- [Setup Options](#setup-options)
- [What the Script Does](#what-the-script-does)
  - [Phase 1 — Welcome & Hardware Check](#phase-1--welcome--hardware-check)
  - [Phase 2 — Install Dependencies](#phase-2--install-dependencies)
  - [Phase 3 — Build Arc Binaries](#phase-3--build-arc-binaries)
  - [Phase 4 — Data Directories & Snapshots](#phase-4--data-directories--snapshots)
  - [Phase 5 — Initialise Consensus Layer](#phase-5--initialise-consensus-layer)
  - [Phase 6 — Install systemd Services](#phase-6--install-systemd-services)
  - [Phase 7 — Verify Node is Syncing](#phase-7--verify-node-is-syncing)
- [Node Endpoints & Ports](#node-endpoints--ports)
- [Post-Install Management](#post-install-management)
  - [Live Monitor Dashboard](#live-monitor-dashboard)
  - [Status Snapshot](#status-snapshot)
  - [Log Tailing](#log-tailing)
  - [Update Node Version](#update-node-version)
  - [Restart / Stop / Start](#restart--stop--start)
  - [Uninstall](#uninstall)
  - [Rollback Sudo](#rollback-sudo)
- [Advanced Options](#advanced-options)
  - [Swap File](#swap-file)
  - [Expose RPC for MetaMask / LAN](#expose-rpc-for-metamask--lan)
  - [Firewall (ufw)](#firewall-ufw)
  - [Skip Snapshots](#skip-snapshots)
  - [Pin a Specific Arc Version](#pin-a-specific-arc-version)
  - [Non-Interactive / CI Mode](#non-interactive--ci-mode)
- [Keypair VPS — Passwordless Sudo](#keypair-vps--passwordless-sudo)
- [Resume After Interruption](#resume-after-interruption)
- [File Layout](#file-layout)
- [Troubleshooting](#troubleshooting)
- [Resources](#resources)
- [Support & Donations](#support--donations)

---

## Overview

`setup.sh` is a single Bash file that handles the entire lifecycle of an Arc testnet node:

| What it does | How |
|---|---|
| Installs system packages, Rust, and Foundry | `apt-get` + `rustup` + `foundryup` |
| Builds 3 Arc binaries from source | `cargo install` from `circlefin/arc-node` |
| Downloads blockchain snapshots (~60 GB) | `arc-snapshots download` |
| Initialises your node's P2P identity key | `arc-node-consensus init` |
| Registers auto-start + crash-restart services | `systemd` unit files |
| Provides live monitoring, logging, and updates | Built-in subcommands |

Setup takes **20–60 minutes** on a fast machine (dominated by Rust compilation).

---

## System Requirements

| Resource | Minimum | Recommended |
|---|---|---|
| **OS** | Ubuntu 22.04 or Debian 12 | Ubuntu 22.04 LTS |
| **CPU** | 8 cores | 16+ cores |
| **RAM** | 64 GB | 128 GB |
| **Disk** | 150 GB free SSD | 500 GB+ NVMe SSD |
| **Network** | Stable broadband | 1 Gbps unmetered |
| **User** | Non-root with `sudo` | — |
| **Init** | systemd | — |

> **RAM note:** The script builds all three crates in parallel, limited to `nproc / 2` jobs to avoid OOM during the Reth link phase. If you have exactly 64 GB of RAM, consider passing `--swap 32G` to add headroom.

---

## Quick Start

```bash
# Download
curl -O https://raw.githubusercontent.com/candyburst/arc-node-setup/main/setup.sh
chmod +x setup.sh

# Run guided interactive setup
./setup.sh

# — or — fully unattended (CI / provisioning)
./setup.sh setup --yes
```

---

## All Commands

```
./setup.sh [COMMAND] [OPTIONS]
```

| Command | Description |
|---|---|
| `setup` | Full interactive node setup **(default)** |
| `monitor` | Live dashboard — refreshes every 5 s (Ctrl+C to exit) |
| `status` | Quick one-shot status snapshot |
| `logs el` | Tail execution-layer logs |
| `logs cl` | Tail consensus-layer logs |
| `logs both` | Tail both layers simultaneously |
| `update` | Auto-detect latest Arc version and rebuild |
| `update v0.7.0` | Upgrade to a specific version |
| `restart` | Restart both services (safe tear-down order) |
| `stop` | Stop both services |
| `start` | Start both services |
| `uninstall` | Guided removal of services, binaries, and data |
| `rollback-sudo` | Remove the passwordless sudo drop-in written during setup |
| `help` | Show usage help |

---

## Setup Options

All options apply to the `setup` command:

| Flag | Description |
|---|---|
| `-y`, `--yes` | Skip all yes/no prompts (non-interactive / CI mode) |
| `--skip-snap` | Skip snapshot download — syncs from genesis (very slow, not recommended) |
| `--expose-rpc` | Bind JSON-RPC on `0.0.0.0` — needed for MetaMask over LAN/WAN |
| `--with-firewall` | Auto-configure `ufw` firewall rules |
| `--swap SIZE` | Create a swap file, e.g. `--swap 16G` |
| `--version VER` | Install a specific Arc version, e.g. `--version v0.7.0` |
| `-h`, `--help` | Show help |

**Examples:**

```bash
./setup.sh                                    # Guided interactive setup
./setup.sh setup --yes                        # Fully unattended / CI
./setup.sh setup --expose-rpc --with-firewall # Open to LAN + configure firewall
./setup.sh setup --swap 32G --yes             # Add 32 GB swap, no prompts
./setup.sh setup --version v0.7.0            # Install a specific version
```

---

## What the Script Does

### Phase 1 — Welcome & Hardware Check

Displays a banner, then checks:

- **RAM** ≥ 64 GB (warns, does not block)
- **Disk** ≥ 150 GB free (warns, does not block)
- **OS** is Ubuntu 22.04+ or Debian 12+
- **User** is not root (root execution is blocked)
- **systemd** is present

If any check fails you are asked whether to continue. All results are written to `~/arc-setup.log`.

### Phase 2 — Install Dependencies

Installs via `apt-get`:

```
git  curl  wget  build-essential  pkg-config  libssl-dev
clang  libclang-dev  cmake  unzip  jq  screen  htop  iotop  net-tools
```

Then installs **Rust** via `rustup` (or updates if already present) and **Foundry** via `foundryup` (provides the `cast` tool for RPC queries).

Both installers are downloaded to a temp file, their SHA-256 is printed for manual verification, and you are prompted before execution (bypassed with `--yes`).

Also configures `journald` log retention: 2 GB max, 4-week history.

### Phase 3 — Build Arc Binaries

Clones [`circlefin/arc-node`](https://github.com/circlefin/arc-node), checks out the target version tag, and compiles three Rust crates:

| Binary | Role |
|---|---|
| `arc-node-execution` | Executes transactions, serves the JSON-RPC endpoint (Reth-based) |
| `arc-node-consensus` | Fetches and verifies blocks (Malachite BFT) |
| `arc-snapshots` | Downloads blockchain snapshots |

All binaries are installed to `/usr/local/bin/`. Build time is **20–60 minutes** depending on hardware. The number of parallel jobs is capped at `nproc / 2` to avoid OOM on machines at the 64 GB RAM minimum.

### Phase 4 — Data Directories & Snapshots

Creates:

```
~/.arc/execution/     ← Execution-layer chain data
~/.arc/consensus/     ← Consensus-layer state
/run/arc/             ← IPC socket directory
```

Then offers to download the **testnet snapshot** (~60 GB download, ~120 GB on disk). This lets your node start near the chain tip in 1–2 hours rather than syncing from genesis (which would take many days).

The free disk space is checked before downloading. Snapshot download is given a 4-hour timeout.

### Phase 5 — Initialise Consensus Layer

Runs `arc-node-consensus init` to generate your node's **P2P identity key** at:

```
~/.arc/consensus/config/node_key.json
```

This is a one-time operation. The key is automatically backed up to `~/.arc-key-backup/` with a timestamp. **Keep this backup — losing it means a new P2P identity.**

### Phase 6 — Install systemd Services

Writes two systemd unit files:

| Service | Binary | Key Behaviour |
|---|---|---|
| `arc-execution` | `arc-node-execution` | Runs Reth EL; exposes JSON-RPC on `localhost:8545` (or `0.0.0.0:8545` with `--expose-rpc`) |
| `arc-consensus` | `arc-node-consensus` | Runs the BFT consensus layer; connects to EL via IPC socket |

Both services:
- Start automatically on boot (`WantedBy=multi-user.target`)
- Restart automatically on crash (`Restart=on-failure`, 10-second delay)
- Log to `journald`
- Have `LimitNOFILE=1048576`

The script waits up to 120 seconds for the execution-layer IPC socket (`/run/arc/reth.ipc`) to appear before starting the consensus layer.

If `--with-firewall` was passed, `ufw` is configured automatically (see [Firewall](#firewall-ufw)).

### Phase 7 — Verify Node is Syncing

Confirms both services are `active`, then uses `cast block-number` to:

1. Query the local node at `http://localhost:8545`
2. Wait up to 30 seconds for the block number to advance

A block advance confirms the node is receiving and processing new blocks.

---

## Node Endpoints & Ports

| Endpoint | Default Address | Flag to change |
|---|---|---|
| JSON-RPC | `http://localhost:8545` | `--expose-rpc` → `0.0.0.0:8545` |
| Consensus RPC | `http://localhost:31000` | — |
| EL Metrics (Prometheus) | `http://localhost:9001/metrics` | — |
| CL Metrics (Prometheus) | `http://localhost:29000/metrics` | — |
| EL P2P TCP | `0.0.0.0:30303` | — |
| EL P2P UDP | `0.0.0.0:30303` | — |
| CL P2P TCP | `0.0.0.0:31001` | — |

---

## Post-Install Management

### Live Monitor Dashboard

```bash
./setup.sh monitor
```

Clears the terminal and refreshes every 5 seconds, showing:

- **Services** — running status with uptime
- **Sync Status** — local block, network head, lag, peer count
- **Resources** — CPU %, RAM (RSS), disk usage
- **Recent Logs** — last 5 lines from execution, last 3 from consensus

Press `Ctrl+C` to exit.

### Status Snapshot

```bash
./setup.sh status
```

One-shot output: service state, installed version, block height, peers, disk usage.

### Log Tailing

```bash
./setup.sh logs el      # Execution layer
./setup.sh logs cl      # Consensus layer
./setup.sh logs both    # Both simultaneously
```

Uses `journalctl -f` under the hood. Press `Ctrl+C` to stop.

### Update Node Version

```bash
./setup.sh update              # Auto-detect latest version from GitHub
./setup.sh update v0.7.0       # Upgrade to a specific version
```

The update process:
1. Stops both services
2. Backs up current binaries to `/usr/local/bin/*.bak`
3. Checks out the new version tag and recompiles
4. If any build step fails, **automatically rolls back** to the backed-up binaries and restarts services
5. Patches `ARC_VERSION_DEFAULT` in the script itself
6. Restarts services

### Restart / Stop / Start

```bash
./setup.sh restart    # Stop consensus → stop execution → start execution → wait for IPC → start consensus
./setup.sh stop       # Stop consensus then execution (safe order)
./setup.sh start      # Start execution → wait for IPC → start consensus
```

The ordering (consensus before execution on stop, execution before consensus on start) ensures the IPC socket is ready and avoids state conflicts.

### Uninstall

```bash
./setup.sh uninstall
```

Guided removal. You are asked separately (with a danger prompt) about:

1. Services and binaries — removed automatically after confirmation
2. Chain data at `~/.arc` (~120+ GB) — separate `yes`-to-confirm prompt
3. Source code at `~/arc-node-src` — optional
4. Passwordless sudo drop-in (if present)

The key backup at `~/.arc-key-backup/` is intentionally kept.

### Rollback Sudo

```bash
./setup.sh rollback-sudo
```

Removes `/etc/sudoers.d/<USER>-nopasswd` if it was written during setup on a keypair-only VPS. Safe to run even if the file does not exist.

---

## Advanced Options

### Swap File

If your server has less than 64 GB of RAM (or exactly 64 GB and you want extra headroom during compilation):

```bash
./setup.sh setup --swap 16G
./setup.sh setup --swap 32G --yes
```

The script:
- Skips creation if swap is already active
- Allocates with `fallocate` (fallback: `dd`)
- Warns on Btrfs/ZFS (`nodatacow` may be required)
- Adds the entry to `/etc/fstab` for persistence across reboots

### Expose RPC for MetaMask / LAN

```bash
./setup.sh setup --expose-rpc
```

Binds the JSON-RPC server on `0.0.0.0:8545` instead of `localhost:8545`. After setup, your public IP is printed as the MetaMask RPC URL. Combine with `--with-firewall` to restrict access by port.

### Firewall (ufw)

```bash
./setup.sh setup --with-firewall
```

Configures `ufw` with these rules:

| Rule | Purpose |
|---|---|
| `allow ssh` | Prevent lockout |
| `allow 30303/tcp` + `30303/udp` | EL P2P — without this, incoming peers are silently dropped |
| `allow 31001/tcp` | CL P2P |
| `allow 8545/tcp` | JSON-RPC (only if `--expose-rpc` is also set) |
| `deny incoming` (default) | Block everything else |

> **Warning:** Always ensure SSH is allowed before enabling ufw. The script does this automatically.

### Skip Snapshots

```bash
./setup.sh setup --skip-snap
```

Skips the snapshot download entirely. The node will sync from genesis block 0, which can take **many days**. Not recommended unless you have a specific reason.

### Pin a Specific Arc Version

```bash
./setup.sh setup --version v0.6.0
./setup.sh setup --version v0.7.0 --yes
```

Version strings must match `v<MAJOR>.<MINOR>.<PATCH>` exactly. The tag must exist in `circlefin/arc-node`.

### Non-Interactive / CI Mode

```bash
./setup.sh setup --yes
```

Skips all yes/no prompts. Danger prompts (uninstall, irreversible data deletion) are **never** bypassed by `--yes` — they always require typing `yes` in full.

---

## Keypair VPS — Passwordless Sudo

Many cloud VPS providers (AWS, GCP, Azure, DigitalOcean) use SSH key authentication with no password set on the account. In this case `sudo` cannot be used non-interactively, which would block automated setup steps.

The script detects this by inspecting the shadow password field. If the account has no password (`!`, `!!`, or `*`), it offers to write:

```
/etc/sudoers.d/<USER>-nopasswd
```

Contents:
```
<USER> ALL=(ALL) NOPASSWD:ALL
Defaults:<USER> !use_pty
Defaults:<USER> !authenticate
```

This is validated with `visudo -c` before installation. **After setup is complete, remove it:**

```bash
./setup.sh rollback-sudo
```

---

## Resume After Interruption

If setup is interrupted (network drop, manual Ctrl+C, OOM kill), simply re-run:

```bash
./setup.sh
```

Completed phases are recorded in `~/.arc-setup-state`. Already-finished phases are skipped automatically, so the script resumes from where it left off. A lock file (`~/.arc-setup.lock`) prevents concurrent runs from racing.

---

## File Layout

After a successful install:

```
~/
├── arc-setup.log           ← Full setup log (all output)
├── arc-node-src/           ← Cloned + compiled source (circlefin/arc-node)
├── .arc/
│   ├── execution/          ← Reth execution-layer data (~120 GB with snapshots)
│   └── consensus/
│       └── config/
│           └── node_key.json   ← Your P2P identity key
└── .arc-key-backup/
    └── node_key_<timestamp>.json  ← Timestamped key backup (keep safe!)

/usr/local/bin/
├── arc-node-execution      ← EL binary
├── arc-node-consensus      ← CL binary
└── arc-snapshots           ← Snapshot tool

/etc/systemd/system/
├── arc-execution.service
└── arc-consensus.service

/run/arc/
└── reth.ipc                ← IPC socket (EL ↔ CL communication)
```

---

## Troubleshooting

**Services not starting after setup**
```bash
sudo journalctl -u arc-execution -n 50
sudo journalctl -u arc-consensus -n 50
./setup.sh logs both
```

**Node not syncing / zero peers**
- Ensure ports `30303` (TCP+UDP) and `31001` (TCP) are open inbound on your firewall/VPC security group.
- Check you have outbound internet access.
- Run `./setup.sh monitor` and watch the peer count.

**RPC not responding**
```bash
cast block-number --rpc-url http://localhost:8545
```
If this returns nothing, check `arc-execution` is active and the IPC socket exists at `/run/arc/reth.ipc`.

**Snapshot download failed or timed out**
The script allows 4 hours. Re-run `./setup.sh` — the script will resume from the data phase.

**Build failed (cargo OOM)**
Add swap before retrying:
```bash
./setup.sh setup --swap 32G
```

**Permission denied on sudo**
If you are not on a keypair VPS and sudo prompts for a password:
```bash
sudo -v   # cache credentials, then re-run setup
```

**Check what phases have completed**
```bash
cat ~/.arc-setup-state
```

**Full log**
```bash
cat ~/arc-setup.log
```

---

## Resources

| Resource | URL |
|---|---|
| Arc Docs | https://docs.arc.network |
| Block Explorer | https://testnet.arcscan.app |
| Testnet Faucet | https://faucet.circle.com |
| Arc Discord | https://discord.com/invite/buildonarc |
| Arc Node Source | https://github.com/circlefin/arc-node |
| This Repo | https://github.com/candyburst/arc-node-setup |

---

## Support & Donations

Built and maintained by **[@cryptoasuran](https://twitter.com/cryptoasuran)**

- **Discord:** [livingbycrypto](https://discord.com/users/livingbycrypto)
- **Telegram:** [@livingbycrypto](https://t.me/livingbycrypto)

If this script saved you hours of work and you'd like to say thanks:

**EVM Donation Wallet:**
```
0xb58b6E9b725D7f865FeaC56641B1dFB57ECfB43f
```

Any chain, any token — every bit is appreciated! ☕

---

> Arc Network is on public testnet. The network may experience instability, resets, or breaking changes. Always back up your `node_key.json`.

---

*MIT License — use freely, fork freely, improve freely.*
