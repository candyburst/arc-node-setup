# Changelog

All notable changes to this project will be documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [1.0.0] — 2026-04-15

Initial public release.

### Features

- **7-phase guided setup** — hardware check, dependency install, Rust/Foundry bootstrap, binary build, snapshot download, consensus init, and systemd service install
- **Resume support** — completed phases are checkpointed; re-running the script resumes from the last completed phase
- **Concurrent-run protection** — lock file prevents two setup instances from racing on state files and service units
- **Swap file creation** — `--swap SIZE` creates and activates a swap file for machines at the 64 GB RAM minimum; warns correctly on Btrfs/ZFS (CoW) filesystems
- **Passwordless sudo bootstrap** — detects keypair-only VPS accounts (AWS/GCP/Azure/DigitalOcean), writes a validated `sudoers.d` drop-in, and provides `rollback-sudo` to remove it after setup
- **Non-interactive / CI mode** — `--yes` skips all confirmations; danger prompts (uninstall, data deletion) always require typing `yes` in full regardless
- **Live monitor dashboard** — `monitor` command refreshes every 5 s with service status, sync lag, peer count, resource usage, and recent log lines
- **Auto-detect update** — `update` queries the GitHub Releases API (falls back to tags) to find the latest `circlefin/arc-node` version; supports pinning with `update vX.Y.Z`
- **Atomic update with rollback** — backs up current binaries before recompiling; automatically restores them and restarts services if any build step fails
- **Guided uninstall** — removes services, binaries, and optionally chain data (~120 GB) and source; each destructive step requires separate confirmation
- **Firewall configuration** — `--with-firewall` auto-configures `ufw` with SSH, EL P2P (30303 TCP+UDP), CL P2P (31001 TCP), and optionally JSON-RPC (8545 TCP)
- **MetaMask / LAN RPC** — `--expose-rpc` binds JSON-RPC on `0.0.0.0:8545` and prints the server's public IP at setup completion
- **Colour-safe output** — ANSI colour codes are stripped automatically when stdout is not a TTY (piped / CI logs)
- **journald retention** — configures 2 GB max / 4-week history to prevent log runaway on long-running nodes

### Supports

- Ubuntu 22.04 LTS and later
- Debian 12 and later
- Arc Testnet **v0.6.0** (`circlefin/arc-node`)
