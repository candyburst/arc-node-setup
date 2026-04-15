#!/usr/bin/env bash
# ============================================================
#  Arc Node Setup & Management Script
#  Supports : Ubuntu 22.04+ · Debian 12+
#  Arc Testnet v0.6.0
#  https://github.com/candyburst/arc-node-setup
# ============================================================
#
#  USAGE:
#    ./setup.sh [COMMAND] [OPTIONS]
#
#  COMMANDS:
#    setup            Full interactive node setup (default)
#    monitor          Live dashboard — refreshes every 5s  (Ctrl+C to exit)
#    status           Quick one-shot status snapshot
#    logs             Tail live logs:  logs el | logs cl | logs both
#    update           Upgrade to a new version:  update v0.7.0
#    restart          Restart both services
#    stop             Stop both services
#    start            Start both services
#    uninstall        Guided removal of services, binaries, and data
#    rollback-sudo    Remove the passwordless sudo drop-in written during setup
#    help             Show this help
#
#  SETUP OPTIONS:
#    -y, --yes           Skip all yes/no prompts (non-interactive / CI)
#    --skip-snap         Skip snapshot download (sync from genesis — very slow)
#    --expose-rpc        Bind JSON-RPC on 0.0.0.0 (needed for MetaMask over LAN)
#    --with-firewall     Auto-configure ufw firewall rules
#    --swap SIZE         Create swap file, e.g. --swap 16G
#    --version VER       Arc version to install  (default: v0.6.0)
#    -h, --help          Show this message
#
#  EXAMPLES:
#    ./setup.sh                          Guided interactive setup
#    ./setup.sh setup --yes              Fully unattended (CI / provisioning)
#    ./setup.sh setup --expose-rpc --with-firewall
#    ./setup.sh setup --swap 32G --yes
#    ./setup.sh monitor                  Open live monitoring dashboard
#    ./setup.sh logs el                  Tail execution-layer logs
#    ./setup.sh update                   Auto-detect latest version
#    ./setup.sh update v0.7.0            Upgrade to specific version
#    ./setup.sh uninstall                Guided removal
# ============================================================

set -euo pipefail

# ════════════════════════════════════════════════════════════
#  CONSTANTS
# ════════════════════════════════════════════════════════════

GITHUB_USER="candyburst"
GITHUB_REPO="arc-node-setup"

ARC_VERSION_DEFAULT="v0.6.0"
ARC_REPO="https://github.com/circlefin/arc-node.git"
ARC_DATA_DIR="${HOME}/.arc"
ARC_EXECUTION_DIR="${ARC_DATA_DIR}/execution"
ARC_CONSENSUS_DIR="${ARC_DATA_DIR}/consensus"
IPC_DIR="/run/arc"
BUILD_DIR="${HOME}/arc-node-src"
LOG_FILE="${HOME}/arc-setup.log"
STATE_FILE="${HOME}/.arc-setup-state"
BACKUP_DIR="${HOME}/.arc-key-backup"

MIN_RAM_GB=64
MIN_DISK_GB=150
MONITOR_INTERVAL=5

NET_RPC_ENDPOINTS=(
  "https://rpc.quicknode.testnet.arc.network/"
  "https://rpc.drpc.testnet.arc.network"
  "https://rpc.blockdaemon.testnet.arc.network"
)

# ════════════════════════════════════════════════════════════
#  COLOURS
# ════════════════════════════════════════════════════════════

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'
BOLD='\033[1m';    DIM='\033[2m';        NC='\033[0m'

# Strip colour codes when stdout is not a TTY (piped / redirected output).
if [[ ! -t 1 ]]; then
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''
  BOLD=''; DIM=''; NC=''
fi

# ════════════════════════════════════════════════════════════
#  RUNTIME FLAGS  (populated by parse_setup_flags)
# ════════════════════════════════════════════════════════════

FLAG_YES=false
FLAG_SKIP_SNAP=false
FLAG_EXPOSE_RPC=false
FLAG_WITH_FIREWALL=false
FLAG_SWAP=""
ARC_VERSION="$ARC_VERSION_DEFAULT"

# ════════════════════════════════════════════════════════════
#  LOGGING
# ════════════════════════════════════════════════════════════

log()     { echo -e "${DIM}[$(date '+%H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"; }
info()    { echo -e "${BLUE}ℹ${NC}  $*"  | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}✔${NC}  $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}✖${NC}  $*"   | tee -a "$LOG_FILE"; }
fatal()   { tput cnorm 2>/dev/null || true
            error "$*"
            echo -e "\n${RED}Operation failed. See ${LOG_FILE} for details.${NC}"
            exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ${NC}"; log "STEP: $*"; }
ask()     { echo -e "${YELLOW}?${NC}  $*"; }

trap 'fatal "Unexpected error near line ${BASH_LINENO[0]} while running: ${BASH_COMMAND}"' ERR

# ════════════════════════════════════════════════════════════
#  RETRY HELPER
#  _retry N CMD [ARGS...]  — retries CMD up to N times with 5-second back-off.
#  Logs each failure; returns the last exit code if all attempts fail.
# ════════════════════════════════════════════════════════════

_retry() {
  local attempts="$1"; shift
  local attempt=1
  until "$@"; do
    local rc=$?
    if [[ $attempt -ge $attempts ]]; then
      error "Command failed after ${attempts} attempt(s): $*"
      return $rc
    fi
    warn "Attempt ${attempt}/${attempts} failed for: $* — retrying in 5s..."
    sleep 5
    attempt=$(( attempt + 1 ))
  done
}

# ════════════════════════════════════════════════════════════
#  UI HELPERS
# ════════════════════════════════════════════════════════════

banner() {
  echo -e "${CYAN}"
  echo "  ╔════════════════════════════════════════════════════════╗"
  printf "  ║  Arc Node Setup & Manager  ·  %-25s║\n" "${GITHUB_USER}/${GITHUB_REPO}"
  printf "  ║   Circle's Stablecoin-Native L1  ·  Testnet %-11s║\n" "${ARC_VERSION}"
  echo "  ╚════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

usage() {
  banner
  cat <<EOF
${BOLD}USAGE${NC}
  ./setup.sh [COMMAND] [OPTIONS]

${BOLD}COMMANDS${NC}
  ${CYAN}setup${NC}            Full interactive node setup (default)
  ${CYAN}monitor${NC}          Live dashboard  —  refreshes every ${MONITOR_INTERVAL}s  (Ctrl+C to exit)
  ${CYAN}status${NC}           Quick one-shot status snapshot
  ${CYAN}logs${NC}             Tail live logs:  logs el | logs cl | logs both
  ${CYAN}update${NC}           Rebuild node — auto-detects latest version from GitHub
                   or pass a specific tag:  update v0.7.0
  ${CYAN}restart${NC}          Restart both services
  ${CYAN}stop${NC}             Stop both services
  ${CYAN}start${NC}            Start both services
  ${CYAN}uninstall${NC}        Guided removal of node
  ${CYAN}rollback-sudo${NC}    Remove the passwordless sudo drop-in written during setup
  ${CYAN}help${NC}             Show this message

${BOLD}SETUP OPTIONS${NC}
  ${YELLOW}-y, --yes${NC}           Skip all yes/no prompts (non-interactive)
  ${YELLOW}--skip-snap${NC}         Skip snapshot download (sync from genesis — very slow)
  ${YELLOW}--expose-rpc${NC}        Bind JSON-RPC on 0.0.0.0 (needed for MetaMask over LAN/WAN)
  ${YELLOW}--with-firewall${NC}     Auto-configure ufw firewall rules
  ${YELLOW}--swap SIZE${NC}         Create swap file, e.g. --swap 16G  (use if RAM < ${MIN_RAM_GB} GB)
  ${YELLOW}--version VER${NC}       Arc version to install  (default: ${ARC_VERSION_DEFAULT})
  ${YELLOW}-h, --help${NC}          Show this message

${BOLD}EXAMPLES${NC}
  ./setup.sh                        Guided interactive setup
  ./setup.sh setup --yes            Fully unattended / CI
  ./setup.sh setup --expose-rpc --with-firewall
  ./setup.sh setup --swap 32G --yes
  ./setup.sh monitor                Live monitoring dashboard
  ./setup.sh logs el                Tail execution-layer logs
  ./setup.sh update                 Auto-detect latest version from GitHub releases API
  ./setup.sh update v0.7.0          Upgrade to a specific version
  ./setup.sh uninstall              Guided removal
  ./setup.sh rollback-sudo          Remove the passwordless sudo drop-in

${BOLD}RESOURCES${NC}
  Docs      https://docs.arc.network
  Explorer  https://testnet.arcscan.app
  Faucet    https://faucet.circle.com
  Discord   https://discord.com/invite/buildonarc
  GitHub    https://github.com/${GITHUB_USER}/${GITHUB_REPO}

${BOLD}${YELLOW}☕  SUPPORT THIS SCRIPT${NC}
  If this script helped you, consider a tip (EVM):
  ${CYAN}0xb58b6E9b725D7f865FeaC56641B1dFB57ECfB43f${NC}
EOF
  exit 0
}

# ════════════════════════════════════════════════════════════
#  PROMPTS
# ════════════════════════════════════════════════════════════

# Standard yes/no prompt; auto-confirms when --yes is set.
confirm() {
  local prompt="${1:-Continue?}" default="${2:-y}"
  if $FLAG_YES; then info "(--yes) auto-confirming: ${prompt}"; return 0; fi
  [[ ! -t 0 ]] && fatal "stdin is not a tty and --yes was not given. Use --yes / -y for non-interactive mode."
  if [[ "$default" == "y" ]]; then ask "${prompt} [Y/n] "; else ask "${prompt} [y/N] "; fi
  read -r reply || fatal "Unexpected EOF on stdin during prompt — use Ctrl+C to cancel."
  reply="${reply:-$default}"
  [[ "${reply,,}" =~ ^(y|yes)$ ]]
}

# Danger prompt — never bypassed by --yes; requires typing "yes" in full.
confirm_danger() {
  local prompt="${1:-Are you sure?}"
  [[ ! -t 0 ]] && fatal "stdin is not a tty. Destructive operations require direct terminal input."
  ask "${RED}${BOLD}${prompt}${NC} — type ${BOLD}yes${NC} to confirm: "
  read -r reply
  [[ "${reply,,}" == "yes" ]]
}

# ════════════════════════════════════════════════════════════
#  SELF-HEALING SUDO BOOTSTRAP
#  Detects keypair-based VPS (no password set) and auto-
#  configures passwordless sudo so the script never prompts.
# ════════════════════════════════════════════════════════════
_bootstrap_sudo() {
  # Already works non-interactively — nothing to do.
  if sudo -n true 2>/dev/null; then return 0; fi

  local drop_in="/etc/sudoers.d/${USER}-nopasswd"

  # Idempotency: drop-in already written from a previous partial run.
  # /etc/sudoers.d/ is root-owned so we can't stat it without sudo.
  # The || true is required — with set -euo pipefail a failed sudo -n would
  # otherwise abort the script here before we've even tried to write the file.
  local already_written=false
  sudo -n test -f "$drop_in" 2>/dev/null && already_written=true || true

  # Read the shadow password field without relying on sudo -n (which we know
  # has already failed at this point). Try getent shadow directly first (works
  # when the user belongs to the shadow group, e.g. on some Ubuntu images),
  # then fall back to `passwd -S` which is always available unprivileged.
  local shadow_entry
  shadow_entry=$(getent shadow "${USER}" 2>/dev/null | cut -d: -f2) || true
  if [[ -z "$shadow_entry" ]]; then
    # passwd -S output: "username L|NP|P ..." — second field is the status.
    # L = locked, NP = no password, P = password set.
    local passwd_status
    passwd_status=$(passwd -S "${USER}" 2>/dev/null | awk '{print $2}') || true
    [[ "$passwd_status" == "L" || "$passwd_status" == "NP" ]] && shadow_entry="!"
  fi

  # On keypair-based VPS (AWS/GCP/Azure/DigitalOcean) the password field is
  # '!' / '!!' / '*' — account has no password; SSH key is the only login path.
  # Only treat an explicit locked-password marker as "keypair VPS".
  # An empty result (sudo -n unavailable) falls through to the normal prompt.
  if [[ "$shadow_entry" == "!" || "$shadow_entry" == "!!" || "$shadow_entry" == "*" ]]; then
    echo -e "${YELLOW}⚡${NC}  Keypair-only VPS detected — no account password is set."
    echo ""
    echo -e "  ${BOLD}${YELLOW}SUDO CONFIGURATION REQUIRED${NC}"
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Setup needs passwordless sudo for the duration of the install."
    echo -e "  It will write the following drop-in file:"
    echo ""
    echo -e "    ${CYAN}/etc/sudoers.d/${USER}-nopasswd${NC}"
    echo ""
    echo -e "  Contents:"
    echo -e "    ${DIM}${USER} ALL=(ALL) NOPASSWD:ALL${NC}"
    echo -e "    ${DIM}Defaults:${USER} !use_pty${NC}"
    echo -e "    ${DIM}Defaults:${USER} !authenticate${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠  This grants full passwordless sudo to your user account.${NC}"
    echo -e "  ${YELLOW}   Run  ./setup.sh rollback-sudo  afterwards to remove it.${NC}"
    echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # In non-interactive / CI mode this is auto-accepted (user passed --yes or stdin is
    # not a tty). In that case we still show the block above so the decision is auditable
    # in any CI log.
    if [[ -t 0 ]]; then
      ask "Allow setup.sh to write this drop-in and continue? [Y/n] "
      read -r _sudo_reply || true
      _sudo_reply="${_sudo_reply:-y}"
      if [[ ! "${_sudo_reply,,}" =~ ^(y|yes)$ ]]; then
        echo -e "${RED}✖${NC}  Aborted — not writing sudoers drop-in."
        echo -e "    Configure sudo yourself, then re-run setup.sh."
        exit 1
      fi
    else
      echo -e "${YELLOW}⚠${NC}  Non-interactive session — auto-accepting sudo drop-in (stdin is not a TTY)."
    fi

    if ! $already_written; then
      # Write a validated sudoers drop-in. Keep ALL Defaults overrides inside
      # the drop-in (never append directly to /etc/sudoers — no visudo check).
      if sudo -n bash -c "
          printf '%s\n' \
            '${USER} ALL=(ALL) NOPASSWD:ALL' \
            'Defaults:${USER} !use_pty' \
            'Defaults:${USER} !authenticate' \
            > '${drop_in}.tmp' \
          && visudo -cf '${drop_in}.tmp' \
          && mv '${drop_in}.tmp' '${drop_in}' \
          && chmod 440 '${drop_in}'
        " 2>/dev/null; then
        echo -e "${GREEN}✔${NC}  Passwordless sudo drop-in written. Continuing setup..."
        echo -e "${DIM}    Remember to run: ./setup.sh rollback-sudo   when setup is done.${NC}"
        echo ""
      else
        sudo -n rm -f "${drop_in}.tmp" 2>/dev/null || true
        echo -e "${RED}✖${NC}  Could not auto-configure sudo."
        echo -e "    Run this once manually, then re-run setup.sh:"
        echo -e "    ${BOLD}printf '%s\\n' '${USER} ALL=(ALL) NOPASSWD:ALL' 'Defaults:${USER} !use_pty' 'Defaults:${USER} !authenticate' | sudo tee /etc/sudoers.d/${USER}-nopasswd && sudo chmod 440 /etc/sudoers.d/${USER}-nopasswd${NC}"
        exit 1
      fi
    fi
  else
    # Password exists or shadow unreadable — standard VPS.
    # Fall through: sudo -v below will prompt once for the password.
    echo -e "${YELLOW}⚠${NC}  sudo requires your password for this session. Enter it when prompted."
  fi
}

require_sudo() {
  [[ $EUID -eq 0 ]] && fatal "Do not run as root. Run as a regular user with sudo access."
  _bootstrap_sudo
  sudo -n true 2>/dev/null || sudo -v || fatal "sudo access is required. Configure sudo for user '${USER}'."
}

# ════════════════════════════════════════════════════════════
#  FLAG PARSING
# ════════════════════════════════════════════════════════════

_validate_version() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fatal "Invalid version '${1}' — expected format: v<MAJOR>.<MINOR>.<PATCH>  (e.g. v0.7.0)"
}

_validate_swap_size() {
  [[ "$1" =~ ^[1-9][0-9]*[Gg]$ ]] \
    || fatal "Invalid swap size '${1}' — expected format: <N>G where N >= 1  (e.g. 16G or 16g)"
}

parse_setup_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)           FLAG_YES=true ;;
      --skip-snap)        FLAG_SKIP_SNAP=true ;;
      --expose-rpc)       FLAG_EXPOSE_RPC=true ;;
      --with-firewall)    FLAG_WITH_FIREWALL=true ;;
      --swap)             [[ -z "${2:-}" ]] && fatal "--swap requires a size argument (e.g. --swap 16G)"
                          _validate_swap_size "$2"
                          FLAG_SWAP="${2^^}"; shift ;;   # normalise to uppercase: 16g → 16G
      --version)          [[ -z "${2:-}" ]] && fatal "--version requires a value (e.g. --version v0.7.0)"
                          _validate_version "$2"
                          ARC_VERSION="$2"; shift ;;
      -h|--help)          usage ;;
      *)  error "Unknown option: '$1'"; echo -e "Run ${CYAN}./setup.sh help${NC} for usage."; exit 1 ;;
    esac
    shift
  done
}

# ════════════════════════════════════════════════════════════
#  PHASE STATE  (resume support)
# ════════════════════════════════════════════════════════════

PHASES_DONE=()
mark_done() { PHASES_DONE+=("$1"); }
is_done()   { [[ " ${PHASES_DONE[*]} " == *" $1 "* ]]; }

save_state() {
  local tmp; tmp=$(mktemp "${STATE_FILE}.XXXXXX")
  printf '%s\n' "${PHASES_DONE[@]}" > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

load_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  while IFS= read -r line; do PHASES_DONE+=("$line"); done < "$STATE_FILE"
}

# ════════════════════════════════════════════════════════════
#  PHASE 0 — WELCOME
# ════════════════════════════════════════════════════════════

phase_welcome() {
  banner

  echo -e "${BOLD}What this script does (7 phases):${NC}"
  echo "  1. Validates your hardware against Arc's requirements"
  echo "  2. Installs Rust, Foundry, and all build dependencies"
  echo "  3. Compiles three Arc binaries from source  (~20–60 min)"
  echo "  4. Creates data directories and downloads blockchain snapshots  (~1–2 h)"
  echo "  5. Generates your node's Consensus Layer P2P identity key"
  echo "  6. Installs both layers as auto-restarting systemd services"
  echo "  7. Verifies your node is live and advancing blocks"
  echo ""
  echo -e "${YELLOW}⚠  Requirements at a glance:${NC}"
  echo "   OS       :  Ubuntu 22.04+ or Debian 12+"
  echo "   RAM      :  64 GB+  (Reth spikes during initial sync)"
  echo "   Storage  :  1 TB+ NVMe SSD  (150 GB free minimum)"
  echo "   Network  :  Stable 24 Mbps+  (snapshots ≈ 60 GB)"
  echo "   Time     :  1–3 hours total (compile + snapshot download)"
  echo ""
  [[ -n "$FLAG_SWAP"      ]] && info "--swap ${FLAG_SWAP}: will create a swap file."
  $FLAG_EXPOSE_RPC         && warn "--expose-rpc: RPC will bind on 0.0.0.0 — protect with a firewall!"
  $FLAG_WITH_FIREWALL      && info "--with-firewall: ufw will be configured automatically."
  echo -e "${DIM}  Log: ${LOG_FILE}${NC}"
  echo ""

  if [[ -f "$STATE_FILE" ]] && [[ ${#PHASES_DONE[@]} -gt 0 ]]; then
    warn "Detected a previous partial run."
    info "Completed phases: ${PHASES_DONE[*]}"
    if confirm "Resume from where you left off?"; then
      info "Resuming..."
    else
      rm -f "$STATE_FILE"; PHASES_DONE=(); info "Starting fresh."
    fi
    echo ""
  fi

  confirm "Ready to begin setup?" || { echo "Setup cancelled."; exit 0; }
}

# ════════════════════════════════════════════════════════════
#  PHASE 1 — SYSTEM REQUIREMENTS
# ════════════════════════════════════════════════════════════

phase_check_requirements() {
  is_done "requirements" && { info "Requirements already passed. Skipping."; return; }
  step "Phase 1/7 — System Requirements Check"
  local ok=true

  # OS check
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    info "OS: ${PRETTY_NAME:-unknown}"
    local maj
    case "${ID:-}" in
      ubuntu)
        maj=$(echo "${VERSION_ID:-0}" | cut -d. -f1)
        if [[ "$maj" -lt 22 ]]; then error "Ubuntu 22.04+ required (have ${VERSION_ID})"; ok=false
        else success "Ubuntu ${VERSION_ID} ✔"; fi ;;
      debian)
        maj=$(echo "${VERSION_ID:-0}" | cut -d. -f1)
        if [[ "$maj" -lt 12 ]]; then error "Debian 12+ required (have ${VERSION_ID})"; ok=false
        else success "Debian ${VERSION_ID} ✔"; fi ;;
      *) warn "Unrecognised distro '${ID:-?}'. Proceeding anyway." ;;
    esac
  else
    warn "Cannot detect OS. Proceeding anyway."
  fi

  # Architecture
  local arch; arch=$(uname -m)
  if [[ "$arch" != "x86_64" ]]; then warn "Architecture ${arch} — tested on x86_64 only."
  else success "Architecture: x86_64 ✔"; fi

  # CPU
  local cores; cores=$(nproc)
  info "CPU: ${cores} logical core(s)"
  [[ "$cores" -lt 4 ]] && warn "4+ cores recommended. You have ${cores}." \
    || success "CPU cores: ${cores} ✔"

  # RAM (evaluated together with optional swap)
  local ram_gb ram_ok=true
  ram_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
  if [[ -z "$ram_gb" ]]; then
    warn "Could not parse MemTotal from /proc/meminfo — assuming 0 GB RAM."
    ram_gb=0
  fi
  if [[ "$ram_gb" -lt "$MIN_RAM_GB" ]]; then
    error "RAM: ${ram_gb} GB — Arc requires ${MIN_RAM_GB} GB+"
    [[ -z "$FLAG_SWAP" ]] && warn "Tip: re-run with --swap 16G to create a swap file."
    ram_ok=false
  else
    success "RAM: ${ram_gb} GB ✔"
  fi

  if [[ -n "$FLAG_SWAP" ]]; then
    if $ram_ok; then
      info "RAM already meets requirements — skipping swap creation."
    else
      _create_swap "$FLAG_SWAP"
      local total_swap_kb; total_swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
      local total_swap_gb; total_swap_gb=$(( total_swap_kb / 1024 / 1024 ))
      if (( ram_gb + total_swap_gb >= MIN_RAM_GB )); then
        ram_ok=true
        success "RAM requirement met via swap (${ram_gb} GB + ${total_swap_gb} GB swap ≥ ${MIN_RAM_GB} GB)."
      else
        error "RAM + swap still insufficient: ${ram_gb} GB + ${total_swap_gb} GB < ${MIN_RAM_GB} GB."
        warn "Increase --swap size or add physical RAM."
      fi
    fi
  fi
  $ram_ok || ok=false

  # Disk
  local free_gb; free_gb=$(df -BG "$HOME" | awk 'NR==2{gsub("G",""); print $4}')
  free_gb=${free_gb:-0}
  if [[ "$free_gb" -lt "$MIN_DISK_GB" ]]; then
    error "Free disk: ${free_gb} GB — need ${MIN_DISK_GB} GB+"; ok=false
  else
    success "Free disk: ${free_gb} GB ✔"
  fi

  # systemd
  if ! command -v systemctl &>/dev/null; then
    error "systemd not found — required for service management."; ok=false
  else
    success "systemd ✔"
  fi

  if [[ "$ok" == "false" ]]; then
    echo ""
    warn "Some requirements are not met (see above)."
    confirm "Continue anyway? (not recommended)" "n" \
      || fatal "Requirements not met. Exiting."
  else
    success "All system requirements passed!"
  fi

  mark_done "requirements"; save_state
}

_create_swap() {
  local size="$1"
  local total_swap_kb; total_swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
  if [[ "$total_swap_kb" -gt 0 ]]; then
    local gb; gb=$(( total_swap_kb / 1024 / 1024 ))
    info "Swap already active (${gb} GB total) — skipping creation."
    return 0
  fi

  info "Creating ${size} swap file at /swapfile..."

  # Guard against a leftover /swapfile from a previous failed run that was never
  # activated: fallocate would silently overwrite it at the potentially wrong size.
  if [[ -f /swapfile ]]; then
    fatal "/swapfile already exists but is not active — remove it first and re-run: sudo rm /swapfile"
  fi

  local mb; mb=$(echo "$size" | tr -d 'Gg' | awk '{printf "%d", $1 * 1024}')
  sudo fallocate -l "$size" /swapfile 2>>"$LOG_FILE" \
    || sudo dd if=/dev/zero of=/swapfile bs=1M count="$mb" 2>>"$LOG_FILE" \
    || fatal "Failed to allocate swap file. Check ${LOG_FILE}"

  # Warn specifically on Copy-on-Write filesystems (Btrfs/ZFS): it is swapon that
  # fails on CoW, not mkswap. Multiple extents is normal for any fragmented file
  # and is unrelated — checking extent count was both the wrong condition and the
  # wrong tool for this warning.
  local fstype; fstype=$(stat -f -c '%T' /swapfile 2>/dev/null || true)
  if [[ "$fstype" == "btrfs" || "$fstype" == "zfs" ]]; then
    warn "Btrfs/ZFS detected (fstype=${fstype}) — swapon may fail without 'chattr +C /swapfile' (nodatacow). See: man swapon"
  fi

  sudo chmod 600 /swapfile
  sudo mkswap  /swapfile 2>>"$LOG_FILE" || fatal "mkswap failed. Check ${LOG_FILE}"
  sudo swapon  /swapfile 2>>"$LOG_FILE" || fatal "swapon failed. Check ${LOG_FILE}"
  grep -qE '^[[:space:]]*/swapfile' /etc/fstab \
    || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null

  local total; total=$(free -h | awk '/Swap:/{print $2}')
  success "Swap created and activated: ${size}  (total swap: ${total})"
}

# ════════════════════════════════════════════════════════════
#  PHASE 2 — INSTALL DEPENDENCIES
# ════════════════════════════════════════════════════════════

phase_install_deps() {
  is_done "deps" && { info "Dependencies already installed. Skipping."; return; }
  step "Phase 2/7 — Install Dependencies"

  info "Updating package index..."
  sudo apt-get update -qq 2>>"$LOG_FILE" \
    || fatal "apt-get update failed. Check network access and ${LOG_FILE}"

  info "Installing build tools and utilities..."
  sudo apt-get install -y -qq \
    git curl wget build-essential pkg-config libssl-dev \
    clang libclang-dev cmake unzip jq screen htop iotop net-tools \
    2>>"$LOG_FILE" \
    || fatal "Failed to install required packages. Check ${LOG_FILE}"
  success "System packages installed"

  # Rust
  if command -v rustc &>/dev/null; then
    success "Rust already installed: $(rustc --version)"
    info "Updating to latest stable..."
    rustup update stable 2>>"$LOG_FILE" \
      || warn "rustup update failed — proceeding with existing Rust. See ${LOG_FILE}"
  else
    info "Installing Rust via rustup..."
    echo -e "${DIM}  (Arc node is written in Rust — this installs the compiler to ~/.cargo)${NC}"

    # Download the installer to a temp file so users can verify its SHA-256
    # before it runs — safer than piping curl directly into a shell.
    local rustup_sh; rustup_sh=$(mktemp /tmp/rustup-init-XXXXXX.sh)
    # shellcheck disable=SC2064  # intentional: capture $rustup_sh now
    trap "rm -f '${rustup_sh}'" RETURN
    _retry 3 bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        -o '${rustup_sh}' 2>>\"$LOG_FILE\"" \
      || fatal "Failed to download rustup installer after 3 attempts. Check network and ${LOG_FILE}"
    local rustup_sha; rustup_sha=$(sha256sum "$rustup_sh" | awk '{print $1}')
    info  "rustup installer downloaded."
    warn  "SHA-256: ${rustup_sha}"
    echo -e "  ${DIM}Compare at: https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init${NC}"
    echo ""
    if ! $FLAG_YES; then
      confirm "Execute rustup installer? (verify SHA-256 above before proceeding)" \
        || fatal "Aborted by user — rustup installer not executed."
    fi
    bash "$rustup_sh" -y 2>>"$LOG_FILE" \
      || fatal "rustup installer failed. Check ${LOG_FILE}"
    trap - RETURN; rm -f "$rustup_sh"
    # shellcheck source=/dev/null
    source "${HOME}/.cargo/env"
    success "Rust installed: $(rustc --version)"
  fi
  # shellcheck source=/dev/null
  [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env"

  # Foundry (provides `cast` for RPC queries)
  if command -v cast &>/dev/null; then
    success "Foundry already installed: $(cast --version | head -1)"
  else
    info "Installing Foundry..."

    # Same download-verify-execute pattern as rustup above.
    local foundry_sh; foundry_sh=$(mktemp /tmp/foundryup-XXXXXX.sh)
    # shellcheck disable=SC2064
    trap "rm -f '${foundry_sh}'" RETURN
    _retry 3 bash -c "curl --proto '=https' --tlsv1.2 -sSfL https://foundry.paradigm.xyz \
        -o '${foundry_sh}' 2>>\"$LOG_FILE\"" \
      || fatal "Failed to download Foundry installer after 3 attempts. Check network and ${LOG_FILE}"
    local foundry_sha; foundry_sha=$(sha256sum "$foundry_sh" | awk '{print $1}')
    info  "Foundry installer downloaded."
    warn  "SHA-256: ${foundry_sha}"
    echo -e "  ${DIM}Compare at: https://github.com/foundry-rs/foundry/releases${NC}"
    echo ""
    if ! $FLAG_YES; then
      confirm "Execute Foundry installer? (verify SHA-256 above before proceeding)" \
        || fatal "Aborted by user — Foundry installer not executed."
    fi
    bash "$foundry_sh" 2>>"$LOG_FILE" \
      || fatal "Foundry installer failed. Check ${LOG_FILE}"
    trap - RETURN; rm -f "$foundry_sh"
    # shellcheck source=/dev/null
    [[ -f "${HOME}/.foundry/env" ]] && source "${HOME}/.foundry/env"
    export PATH="${HOME}/.foundry/bin:${PATH}"
    _retry 3 foundryup 2>>"$LOG_FILE" || fatal "foundryup failed after 3 attempts. Check ${LOG_FILE}"
    success "Foundry installed: $(cast --version | head -1)"
  fi

  _setup_journal_retention
  mark_done "deps"; save_state
}

_setup_journal_retention() {
  info "Configuring journald log retention..."
  sudo mkdir -p /etc/systemd/journald.conf.d
  sudo tee /etc/systemd/journald.conf.d/arc-node.conf > /dev/null <<'EOF'
# Arc Node — journal retention
[Journal]
SystemMaxUse=2G
SystemMaxFileSize=200M
MaxRetentionSec=4week
EOF
  sudo systemctl kill --kill-who=main --signal=SIGUSR2 systemd-journald 2>/dev/null || true
  success "journald retention configured (2 GB max, 4 weeks)"
}

# ════════════════════════════════════════════════════════════
#  PHASE 3 — BUILD BINARIES
# ════════════════════════════════════════════════════════════

phase_build_binaries() {
  is_done "binaries" && { info "Binaries already built. Skipping."; return; }
  step "Phase 3/7 — Build Arc Node Binaries (${ARC_VERSION})"
  # shellcheck source=/dev/null
  [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env"

  echo -e "${DIM}  Compiling three binaries from source:${NC}"
  echo -e "${DIM}    arc-node-execution   — executes txs, serves JSON-RPC  (Reth-based)${NC}"
  echo -e "${DIM}    arc-node-consensus   — fetches and verifies blocks  (Malachite BFT)${NC}"
  echo -e "${DIM}    arc-snapshots        — downloads blockchain snapshots${NC}"
  echo ""
  warn "This step takes 20–60 minutes on a fast machine. Grab a coffee ☕"
  echo ""

  if [[ -d "$BUILD_DIR" ]]; then
    info "Existing source directory found at ${BUILD_DIR}"
    if confirm "Re-clone from scratch? (No = use existing clone)" "n"; then
      rm -rf "$BUILD_DIR"; info "Removed old source."
    fi
  fi

  if [[ ! -d "$BUILD_DIR" ]]; then
    info "Cloning arc-node (${ARC_VERSION})..."
    git -c http.connectTimeout=30 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
      clone "$ARC_REPO" "$BUILD_DIR" 2>>"$LOG_FILE" \
      || fatal "Failed to clone ${ARC_REPO}. Check network access and ${LOG_FILE}"
  fi

  local orig_dir="$PWD"
  cd "$BUILD_DIR" || fatal "Failed to enter source directory: ${BUILD_DIR}"
  info "Checking out ${ARC_VERSION}..."
  _retry 3 git -c http.connectTimeout=30 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
    fetch --tags 2>>"$LOG_FILE" \
    || fatal "Failed to fetch tags after 3 attempts. Check network access and ${LOG_FILE}"
  git reset --hard HEAD 2>>"$LOG_FILE" || true
  _retry 3 git checkout -f "$ARC_VERSION" 2>>"$LOG_FILE" \
    || fatal "Tag '${ARC_VERSION}' not found after retries. Run: git -C ${BUILD_DIR} fetch --tags"
  info "Updating submodules..."
  git submodule update --init --recursive --force 2>>"$LOG_FILE" \
    || fatal "Submodule checkout failed. Check network access and ${LOG_FILE}"
  success "Repository ready"

  _cargo_install "crates/node"           "/usr/local" \
    || fatal "Build failed for crates/node. See ${LOG_FILE}"
  _cargo_install "crates/malachite-app"  "/usr/local" \
    || fatal "Build failed for crates/malachite-app. See ${LOG_FILE}"
  _cargo_install "crates/snapshots"      "/usr/local" \
    || fatal "Build failed for crates/snapshots. See ${LOG_FILE}"

  cd "$orig_dir"
  _verify_binaries

  # Record the installed version so cmd_status doesn't fall back to
  # ARC_VERSION_DEFAULT on a fresh install (cmd_update already writes this;
  # phase_build_binaries must too).
  printf '%s\n' "$ARC_VERSION" > "${HOME}/.arc-version" \
    || warn "Could not write to ${HOME}/.arc-version — status may show stale version."

  mark_done "binaries"; save_state
}

_cargo_install() {
  local crate="$1" root="$2"
  info "Building ${crate} — this can take 20–60 minutes. Tail ${LOG_FILE} to watch progress."
  # Build as the current user into a temp dir, then install to system path with sudo.
  local build_tmp; build_tmp="$(mktemp -d "${HOME}/.cargo-build-tmp.XXXXXX")"
  # Cap parallel jobs to half the available cores on machines at or near the 64 GB
  # RAM minimum — full-core Reth compilation can OOM during initial link phases.
  local jobs; jobs=$(( $(nproc) > 4 ? $(nproc) / 2 : $(nproc) ))
  # shellcheck disable=SC2064  # double-quote is intentional: capture $build_tmp now (local var)
  trap "rm -rf '${build_tmp}'" RETURN
  cargo install --jobs "$jobs" --path "$crate" --root "$build_tmp" 2>>"$LOG_FILE" \
    || { trap - RETURN; rm -rf "$build_tmp"; error "Build failed for ${crate}. See ${LOG_FILE}"; return 1; }
  local installed=0
  while IFS= read -r bin; do
    sudo install -m 755 "$bin" "${root}/bin/" \
      || { trap - RETURN; rm -rf "$build_tmp"; error "Failed to install $(basename "$bin") to ${root}/bin/"; return 1; }
    success "Installed $(basename "$bin") → ${root}/bin/"
    installed=$(( installed + 1 ))
  done < <(find "${build_tmp}/bin" -maxdepth 1 -type f -executable)
  [[ "$installed" -gt 0 ]] \
    || { trap - RETURN; rm -rf "$build_tmp"; error "No binaries produced for ${crate}. Check ${LOG_FILE}"; return 1; }
  trap - RETURN
  rm -rf "$build_tmp"
}

_verify_binaries() {
  info "Verifying installations..."
  export PATH="${HOME}/.foundry/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"
  local all_ok=true
  for b in arc-node-execution arc-node-consensus arc-snapshots; do
    if command -v "$b" &>/dev/null; then
      success "${b}: $($b --version 2>&1 | head -1)"
    else
      error "${b}: NOT FOUND in PATH"; all_ok=false
    fi
  done
  $all_ok || fatal "One or more binaries missing. Check ${LOG_FILE}"
}

# ════════════════════════════════════════════════════════════
#  PHASE 4 — DATA DIRECTORIES & SNAPSHOTS
# ════════════════════════════════════════════════════════════

phase_setup_data() {
  is_done "data" && { info "Data setup already done. Skipping."; return; }
  step "Phase 4/7 — Create Directories & Download Snapshots"
  export PATH="${HOME}/.foundry/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"

  info "Creating data directories..."
  mkdir -p "$ARC_EXECUTION_DIR" "$ARC_CONSENSUS_DIR"
  sudo install -d -m 755 -o "$USER" -g "$USER" "$IPC_DIR"
  success "Directories created:"
  echo "    Execution  :  ${ARC_EXECUTION_DIR}"
  echo "    Consensus  :  ${ARC_CONSENSUS_DIR}"
  echo "    IPC        :  ${IPC_DIR}"
  echo ""

  if $FLAG_SKIP_SNAP; then
    warn "--skip-snap: Skipping snapshots. Node will sync from genesis (very slow)."
  else
    echo -e "${DIM}  Snapshots let you start near the chain tip instead of syncing${NC}"
    echo -e "${DIM}  from block 0 (genesis), which would take many days.${NC}"
    echo ""
    warn "~60 GB download → ~120 GB on disk. Typically 1–2 hours."
    echo ""
    if confirm "Download blockchain snapshots? (strongly recommended)"; then
      local required_gb=130
      local free_gb; free_gb=$(df -BG "$ARC_DATA_DIR" | awk 'NR==2{gsub("G",""); print $4}')
      if [[ -z "$free_gb" ]]; then
        warn "Could not parse free disk space for ${ARC_DATA_DIR} — assuming 0 GB."
        free_gb=0
      fi
      if [[ "$free_gb" -lt "$required_gb" ]]; then
        fatal "Insufficient disk space for snapshots: ${free_gb} GB free, ${required_gb} GB needed."
      fi
      info "Downloading Arc Testnet snapshots..."
      info "Tail ${LOG_FILE} to watch progress."
      echo -e "${DIM}  Terminal may go quiet during extraction — this is normal.${NC}"
      timeout 14400 arc-snapshots download --chain=arc-testnet 2>>"$LOG_FILE" \
        || fatal "Snapshot download failed or timed out after 4 hours. Check ${LOG_FILE}"
      success "Snapshots downloaded and extracted!"
    else
      warn "Skipped — node will sync from genesis (very slow)."
    fi
  fi

  mark_done "data"; save_state
}

# ════════════════════════════════════════════════════════════
#  PHASE 5 — INITIALISE CONSENSUS LAYER
# ════════════════════════════════════════════════════════════

phase_init_consensus() {
  is_done "init_cl" && { info "Consensus Layer already initialised. Skipping."; return; }
  step "Phase 5/7 — Initialise Consensus Layer"
  export PATH="${HOME}/.foundry/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"
  echo -e "${DIM}  Generates a P2P identity key for your node (one-time operation).${NC}"
  echo ""

  if [[ -f "${ARC_CONSENSUS_DIR}/config/node_key.json" ]]; then
    info "Identity key already exists — skipping init."
  else
    arc-node-consensus init --home "$ARC_CONSENSUS_DIR" 2>>"$LOG_FILE" \
      || fatal "Consensus Layer init failed. Check ${LOG_FILE}"
    success "P2P identity key generated"
  fi

  _backup_consensus_key
  mark_done "init_cl"; save_state
}

_backup_consensus_key() {
  local key_file="${ARC_CONSENSUS_DIR}/config/node_key.json"
  [[ -f "$key_file" ]] || return 0
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

  # Skip if a backup with the same checksum already exists.
  local key_cksum; key_cksum=$(sha256sum "$key_file" | awk '{print $1}')
  while IFS= read -r existing; do
    local ex_cksum; ex_cksum=$(sha256sum "$existing" | awk '{print $1}')
    if [[ "$key_cksum" == "$ex_cksum" ]]; then
      info "Matching key backup already exists (${existing}) — skipping."
      return 0
    fi
  done < <(find "$BACKUP_DIR" -maxdepth 1 -name 'node_key_*.json' -type f 2>/dev/null || true)

  local dest
  dest="${BACKUP_DIR}/node_key_$(date +%Y%m%d_%H%M%S).json"
  cp "$key_file" "$dest" || fatal "Failed to back up consensus key to ${dest}. Check disk space."
  chmod 600 "$dest"
  success "Consensus key backed up → ${dest}"
  warn "Keep this backup safe — losing it means a new P2P identity for your node."
}

# ════════════════════════════════════════════════════════════
#  PHASE 6 — INSTALL SYSTEMD SERVICES
# ════════════════════════════════════════════════════════════

phase_install_services() {
  is_done "services" && { info "Services already installed. Skipping."; return; }
  step "Phase 6/7 — Install systemd Services"
  echo -e "${DIM}  Services auto-start on boot and restart on crash.${NC}"
  echo ""

  export PATH="${HOME}/.foundry/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"
  local bin_path="/usr/local/bin"
  command -v arc-node-execution &>/dev/null \
    && bin_path=$(dirname "$(command -v arc-node-execution)")
  info "Binary path: ${bin_path}"

  local rpc_addr="127.0.0.1"
  if $FLAG_EXPOSE_RPC; then
    rpc_addr="0.0.0.0"
    warn "RPC exposed on 0.0.0.0:8545 — firewall recommended!"
  fi

  # Pick the first reachable public RPC endpoint; fall back to the first entry.
  # NOTE: this endpoint is baked into the service file at install time. If it
  # goes down permanently, edit /etc/systemd/system/arc-execution.service and
  # run: sudo systemctl daemon-reload && sudo systemctl restart arc-execution
  # Candidate endpoints: ${NET_RPC_ENDPOINTS[*]}
  local rpc_forwarder="${NET_RPC_ENDPOINTS[0]}" rpc_found=false
  for _ep in "${NET_RPC_ENDPOINTS[@]}"; do
    if curl -sf --max-time 5 -X POST "$_ep" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        &>/dev/null; then
      rpc_forwarder="$_ep"; rpc_found=true
      info "RPC forwarder: ${rpc_forwarder}"
      break
    fi
  done
  $rpc_found || warn "No public RPC responded — using ${rpc_forwarder} as forwarder."

  local user_group; user_group=$(id -gn "$USER")

  # ── Execution Layer ──────────────────────────────────────
  info "Writing arc-execution.service..."
  sudo tee /etc/systemd/system/arc-execution.service > /dev/null <<EOF
[Unit]
Description=Arc Node — Execution Layer (Reth)
Documentation=https://docs.arc.network
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
Group=${user_group}
RuntimeDirectory=arc
Environment=RUST_LOG=info
WorkingDirectory=${ARC_DATA_DIR}
ExecStart=${bin_path}/arc-node-execution node \\
  --chain arc-testnet \\
  --datadir ${ARC_EXECUTION_DIR} \\
  --disable-discovery \\
  --ipcpath /run/arc/reth.ipc \\
  --auth-ipc \\
  --auth-ipc.path /run/arc/auth.ipc \\
  --http \\
  --http.addr ${rpc_addr} \\
  --http.port 8545 \\
  --http.api eth,net,web3,txpool,trace,debug \\
  --metrics 127.0.0.1:9001 \\
  --enable-arc-rpc \\
  --rpc.forwarder ${rpc_forwarder}

Restart=on-failure
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=300
StandardOutput=journal
StandardError=journal
SyslogIdentifier=arc-execution
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  success "arc-execution.service written"

  # ── Consensus Layer ──────────────────────────────────────
  info "Writing arc-consensus.service..."
  sudo tee /etc/systemd/system/arc-consensus.service > /dev/null <<EOF
[Unit]
Description=Arc Node — Consensus Layer (Malachite)
Documentation=https://docs.arc.network
After=arc-execution.service
Requires=arc-execution.service

[Service]
Type=simple
User=${USER}
Group=${user_group}
Environment=RUST_LOG=info
WorkingDirectory=${ARC_DATA_DIR}
ExecStart=${bin_path}/arc-node-consensus start \\
  --home ${ARC_CONSENSUS_DIR} \\
  --eth-socket /run/arc/reth.ipc \\
  --execution-socket /run/arc/auth.ipc \\
  --rpc.addr 127.0.0.1:31000 \\
  --follow \\
  --follow.endpoint https://rpc.drpc.testnet.arc.network,wss://rpc.drpc.testnet.arc.network \\
  --follow.endpoint https://rpc.quicknode.testnet.arc.network,wss://rpc.quicknode.testnet.arc.network \\
  --follow.endpoint https://rpc.blockdaemon.testnet.arc.network,wss://rpc.blockdaemon.testnet.arc.network \\
  --metrics 127.0.0.1:29000

Restart=on-failure
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=300
StandardOutput=journal
StandardError=journal
SyslogIdentifier=arc-consensus
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  success "arc-consensus.service written"

  info "Enabling and starting services..."
  sudo systemctl daemon-reload
  sudo systemctl enable arc-execution arc-consensus
  sudo systemctl start arc-execution
  _wait_for_ipc
  sudo systemctl start arc-consensus
  success "Both services started!"

  $FLAG_WITH_FIREWALL && _configure_ufw
  mark_done "services"; save_state
}

# Wait up to 120 s for the execution-layer IPC socket to appear.
# Always call this between starting arc-execution and arc-consensus.
_wait_for_ipc() {
  info "Waiting for execution layer IPC socket..."
  local deadline; deadline=$(( $(date +%s) + 120 ))
  until [[ -S "${IPC_DIR}/reth.ipc" ]] || [[ $(date +%s) -ge $deadline ]]; do
    sleep 1
  done
  [[ -S "${IPC_DIR}/reth.ipc" ]] \
    || fatal "IPC socket not ready after 120s — execution layer failed to start. Check: sudo journalctl -u arc-execution -n 50"
}

_configure_ufw() {
  step "Optional — Configure ufw Firewall"
  command -v ufw &>/dev/null \
    || sudo apt-get install -y -qq ufw 2>>"$LOG_FILE"

  info "Current ufw state before changes:"
  sudo ufw status numbered 2>/dev/null || true
  echo ""

  info "Configuring ufw rules..."
  # Set defaults and allow SSH before enabling to avoid locking yourself out.
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow ssh comment 'SSH access'
  $FLAG_EXPOSE_RPC && sudo ufw allow 8545/tcp comment 'Arc JSON-RPC'
  # P2P ports — without these, incoming peer connections are silently blocked
  # and the node will run with zero peers behind the firewall.
  sudo ufw allow 30303/tcp comment 'Arc EL P2P TCP'
  sudo ufw allow 30303/udp comment 'Arc EL P2P UDP'
  sudo ufw allow 31001/tcp comment 'Arc CL P2P TCP'
  sudo ufw --force enable
  success "ufw configured"
  sudo ufw status numbered
}

# ════════════════════════════════════════════════════════════
#  PHASE 7 — VERIFY
# ════════════════════════════════════════════════════════════

phase_verify() {
  step "Phase 7/7 — Verify Node is Syncing"
  export PATH="${HOME}/.foundry/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"

  local el_status cl_status services_ok=true
  el_status=$(sudo systemctl is-active arc-execution 2>/dev/null || echo "unknown")
  cl_status=$(sudo systemctl is-active arc-consensus  2>/dev/null || echo "unknown")

  if [[ "$el_status" == "active" ]]; then success "arc-execution : RUNNING"
  else error "arc-execution : ${el_status}"; warn "sudo journalctl -u arc-execution -n 50"; services_ok=false; fi

  if [[ "$cl_status" == "active" ]]; then success "arc-consensus : RUNNING"
  else error "arc-consensus : ${cl_status}"; warn "sudo journalctl -u arc-consensus -n 50"; services_ok=false; fi

  $services_ok || fatal "One or more services failed to start. Fix the errors above, then run: ./setup.sh start"

  if command -v cast &>/dev/null; then
    info "Waiting for RPC to become available..."
    local rpc_deadline; rpc_deadline=$(( $(date +%s) + 30 ))
    until cast block-number --rpc-url http://localhost:8545 &>/dev/null \
        || [[ $(date +%s) -ge $rpc_deadline ]]; do
      sleep 1
    done

    local b1 b2
    b1=$(cast block-number --rpc-url http://localhost:8545 2>/dev/null | tr -dc '0-9')
    b1=${b1:-0}
    info "Waiting for block to advance (up to 30s)..."
    local adv_deadline; adv_deadline=$(( $(date +%s) + 30 ))
    while true; do
      b2=$(cast block-number --rpc-url http://localhost:8545 2>/dev/null | tr -dc '0-9')
      b2=${b2:-0}
      [[ "$b2" -gt "$b1" ]] && break
      [[ $(date +%s) -ge $adv_deadline ]] && break
      sleep 2
    done

    if [[ "$b1" -eq 0 ]] && [[ "$b2" -eq 0 ]]; then
      warn "Node not yet responding to RPC — may still be initialising."
      warn "Check again: cast block-number --rpc-url http://localhost:8545"
    elif [[ "$b2" -gt "$b1" ]]; then
      success "Node is syncing! Block advanced: ${b1} → ${b2}"
    else
      info "Local block: ${b2}  (may need more time to start advancing)"
    fi
  else
    warn "cast not found — add ~/.foundry/bin to PATH, then run:"
    warn "  cast block-number --rpc-url http://localhost:8545"
  fi
}

# ════════════════════════════════════════════════════════════
#  SETUP SUMMARY
# ════════════════════════════════════════════════════════════

print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║          🎉  Arc Node Setup Complete!                ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "${BOLD}Endpoints:${NC}"
  local rpc_host="localhost"
  if $FLAG_EXPOSE_RPC; then
    rpc_host=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null \
              || curl -sf --max-time 5 https://api4.my-ip.io/ip 2>/dev/null \
              || echo "<your-server-ip>")
  fi
  echo "  JSON-RPC    :  http://${rpc_host}:8545"
  echo "  CL RPC      :  http://localhost:31000"
  echo "  EL Metrics  :  http://localhost:9001/metrics"
  echo "  CL Metrics  :  http://localhost:29000/metrics"
  echo ""

  echo -e "${BOLD}Quick commands:${NC}"
  echo "  Live dashboard  :  ./setup.sh monitor"
  echo "  Status snapshot :  ./setup.sh status"
  echo "  Tail EL logs    :  ./setup.sh logs el"
  echo "  Tail CL logs    :  ./setup.sh logs cl"
  echo "  Restart node    :  ./setup.sh restart"
  echo "  Stop node       :  ./setup.sh stop"
  echo "  Update node     :  ./setup.sh update v0.X.X"
  echo ""

  echo -e "${BOLD}Resources:${NC}"
  echo "  Docs       :  https://docs.arc.network"
  echo "  Explorer   :  https://testnet.arcscan.app"
  echo "  Faucet     :  https://faucet.circle.com"
  echo "  Discord    :  https://discord.com/invite/buildonarc"
  echo "  GitHub     :  https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
  echo "  Key backup :  ${BACKUP_DIR}/"
  echo "  Setup log  :  ${LOG_FILE}"
  echo ""
  echo -e "${DIM}Arc is on public testnet. Network may experience instability.${NC}"
  echo ""
  echo -e "${BOLD}${YELLOW}☕  Support this script:${NC}"
  echo "  If this setup saved you time, consider a tip (EVM wallet):"
  echo -e "  ${CYAN}  0xb58b6E9b725D7f865FeaC56641B1dFB57ECfB43f${NC}"
  echo ""
}

# ════════════════════════════════════════════════════════════
#  MONITOR HELPERS
# ════════════════════════════════════════════════════════════

# Fetch network head block from public RPCs; returns decimal or "N/A".
_net_head() {
  local use_jq=true
  command -v jq &>/dev/null || use_jq=false

  for ep in "${NET_RPC_ENDPOINTS[@]}"; do
    local response
    response="$(curl -sf --max-time 3 -X POST "$ep" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || true)"
    [[ -z "$response" ]] && continue

    local raw
    if $use_jq; then
      raw=$(printf '%s' "$response" | jq -r '.result // empty' 2>/dev/null) || true
    else
      # grep handles multi-line JSON; extract hex value after "result":
      raw=$(printf '%s' "$response" \
        | grep -o '"result"[[:space:]]*:[[:space:]]*"0x[0-9a-fA-F]*"' \
        | grep -o '0x[0-9a-fA-F]*' | head -1 || true)
    fi

    if [[ "$raw" =~ ^0x[0-9a-fA-F]+$ ]]; then
      local dec; dec=$(printf '%d' "$raw" 2>/dev/null) || continue
      printf '%d\n' "$dec" && return
    fi
  done
  echo "N/A"
}

# Local block height via cast; returns decimal or "N/A".
_local_block() {
  command -v cast &>/dev/null || { echo "N/A"; return; }
  local raw; raw=$(cast block-number --rpc-url http://localhost:8545 2>/dev/null | tr -dc '0-9')
  [[ -n "$raw" ]] && echo "$raw" || echo "N/A"
}

# One-line service status with uptime.
_svc_line() {
  local svc="$1"
  local active; active=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
  if [[ "$active" == "active" ]]; then
    local ts; ts=$(systemctl show "$svc" --property=ActiveEnterTimestamp \
      | cut -d= -f2 2>/dev/null || echo "")
    local upstr=""
    if [[ -n "$ts" ]]; then
      local start now elapsed d h m
      start=$(date -d "$ts" +%s 2>/dev/null || echo "0")
      now=$(date +%s)
      if [[ "$start" -gt 0 ]] && [[ "$now" -gt "$start" ]]; then
        elapsed=$(( now - start ))
        d=$(( elapsed / 86400 )); h=$(( (elapsed % 86400) / 3600 )); m=$(( (elapsed % 3600) / 60 ))
        [[ "$d" -gt 0 ]] && upstr="  up ${d}d ${h}h ${m}m" || upstr="  up ${h}h ${m}m"
      fi
    fi
    echo -e "${GREEN}● RUNNING${NC}${DIM}${upstr}${NC}"
  else
    echo -e "${RED}● ${active^^}${NC}"
  fi
}

# CPU % and RSS for the named binary; uses /proc/<pid>/exe to avoid false matches.
_proc_stats() {
  local pattern="$1" pid=""
  # pgrep -x matches against the kernel COMM field (max 15 chars). Arc binary
  # names are 18 chars ("arc-node-execution", "arc-node-consensus") so -x would
  # never match. Use -f with /proc/<pid>/exe verification to avoid false matches
  # from in-flight cargo builds or grep processes containing the pattern.
  while IFS= read -r candidate; do
    local exe; exe=$(readlink -f "/proc/${candidate}/exe" 2>/dev/null || true)
    if [[ "$exe" == *"${pattern}"* ]]; then pid="$candidate"; break; fi
  done < <(pgrep -f "$pattern" 2>/dev/null || true)

  if [[ -z "$pid" ]]; then echo -e "${DIM}not running${NC}"; return; fi
  local cpu mem_kb mem_mb
  cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | xargs || echo "0.0")
  mem_kb=$(ps -p "$pid" -o rss= 2>/dev/null | xargs || echo "0")
  mem_mb=$(( mem_kb / 1024 ))
  echo -e "CPU ${CYAN}${cpu}%${NC}   MEM ${CYAN}${mem_mb} MB${NC}   PID ${DIM}${pid}${NC}"
}

# Disk usage for the Arc data directory.
_disk_info() {
  if [[ -d "$ARC_DATA_DIR" ]]; then
    local used free
    used=$(du -sh "$ARC_DATA_DIR" 2>/dev/null | cut -f1 || echo "?")
    free=$(df -h "$ARC_DATA_DIR" | awk 'NR==2{print $4}' || echo "?")
    echo -e "Used ${CYAN}${used}${NC}   Free ${CYAN}${free}${NC}"
  else
    echo -e "${DIM}data dir not found${NC}"
  fi
}

# Connected peer count via net_peerCount RPC.
_peers() {
  command -v cast &>/dev/null || { echo "N/A"; return; }
  local raw; raw=$(cast rpc net_peerCount --rpc-url http://localhost:8545 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | tr -d '"' | tr -d '[:space:]' || echo "")
  if [[ "$raw" =~ ^0x[0-9a-fA-F]+$ ]]; then
    printf '%d' "$(( 16#${raw#0x} ))"
  else
    echo "N/A"
  fi
}

# Recent journal lines for a service, truncated to 110 chars each.
_recent_logs() {
  local svc="$1" n="${2:-5}"
  sudo journalctl -u "$svc" -n "$n" --no-pager --output short 2>/dev/null \
    | tail -n "$n" \
    | while IFS= read -r line; do echo "  ${line:0:110}"; done
}

# ════════════════════════════════════════════════════════════
#  COMMAND: monitor
# ════════════════════════════════════════════════════════════

cmd_monitor() {
  require_sudo
  export PATH="${HOME}/.foundry/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"

  trap 'tput cnorm 2>/dev/null; echo -e "\n${NC}Monitor stopped."' EXIT
  trap 'tput cnorm 2>/dev/null; echo -e "\n${NC}Monitor stopped."; exit 0' INT TERM
  tput civis 2>/dev/null || true   # hide cursor while dashboard is running

  local now el_line cl_line lb nb lag lag_line lb_fmt nb_fmt
  local el_stats cl_stats disk_info peers

  while true; do
    now=$(date '+%Y-%m-%d  %H:%M:%S')

    el_line=$(_svc_line "arc-execution")
    cl_line=$(_svc_line "arc-consensus")

    lb=$(_local_block)
    nb=$(_net_head)
    if [[ "$lb" =~ ^[0-9]+$ ]] && [[ "$nb" =~ ^[0-9]+$ ]]; then
      lag=$(( nb - lb ))
      [[ "$lag" -lt 0 ]] && lag=0   # clamp: brief negative values are possible due to RPC skew
      lb_fmt=$(printf "%'d" "$lb")
      nb_fmt=$(printf "%'d" "$nb")
      if   [[ $lag -le 5   ]]; then lag_line="${GREEN}${lag} blocks behind  ✔ synced${NC}"
      elif [[ $lag -le 100 ]]; then lag_line="${YELLOW}${lag} blocks behind  catching up${NC}"
      else                          lag_line="${RED}${lag} blocks behind  syncing...${NC}"
      fi
    else
      lb_fmt="$lb"; nb_fmt="$nb"; lag_line="${DIM}N/A${NC}"
    fi

    el_stats=$(_proc_stats "arc-node-execution")
    cl_stats=$(_proc_stats "arc-node-consensus")
    disk_info=$(_disk_info)
    peers=$(_peers)

    printf '\033[H\033[2J'   # clear screen

    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    printf "  ║   Arc Node Monitor  %-47s║\n" "  github.com/${GITHUB_USER}/${GITHUB_REPO}"
    echo   "  ║   Press Ctrl+C to exit                                         ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}${DIM}  Updated: ${now}   (refreshing every ${MONITOR_INTERVAL}s)${NC}"
    echo ""

    echo -e "  ${BOLD}SERVICES${NC}"
    echo     "  ──────────────────────────────────────────────────────────────────"
    printf   "  %-38s" "Execution Layer  (arc-execution)"; echo -e "$el_line"
    printf   "  %-38s" "Consensus Layer  (arc-consensus)"; echo -e "$cl_line"
    echo ""

    echo -e "  ${BOLD}SYNC STATUS${NC}"
    echo     "  ──────────────────────────────────────────────────────────────────"
    printf   "  %-22s${CYAN}%s${NC}\n" "Local block"   "${lb_fmt}"
    printf   "  %-22s${CYAN}%s${NC}\n" "Network head"  "${nb_fmt}"
    printf   "  %-22s" "Lag"; echo -e "$lag_line"
    printf   "  %-22s${CYAN}%s${NC}\n" "Peers"         "${peers}"
    echo ""

    echo -e "  ${BOLD}RESOURCES${NC}"
    echo     "  ──────────────────────────────────────────────────────────────────"
    printf   "  %-22s" "Execution"; echo -e "$el_stats"
    printf   "  %-22s" "Consensus"; echo -e "$cl_stats"
    printf   "  %-22s" "Disk"; echo -e "$disk_info"
    echo ""

    echo -e "  ${BOLD}RECENT EXECUTION LOGS${NC}"
    echo     "  ──────────────────────────────────────────────────────────────────"
    _recent_logs "arc-execution" 5
    echo ""
    echo -e "  ${BOLD}RECENT CONSENSUS LOGS${NC}"
    echo     "  ──────────────────────────────────────────────────────────────────"
    _recent_logs "arc-consensus" 3
    echo ""
    echo -e "${DIM}  Commands: [./setup.sh status]  [./setup.sh logs el|cl]  [./setup.sh restart]${NC}"
    echo ""
    echo -e "  ${BOLD}${YELLOW}☕  SUPPORT THIS SCRIPT${NC}"
    echo     "  ──────────────────────────────────────────────────────────────────"
    echo -e "  ${DIM}If this script helped you, consider sending a tip (EVM):${NC}"
    echo -e "  ${CYAN}  0xb58b6E9b725D7f865FeaC56641B1dFB57ECfB43f${NC}"

    sleep "$MONITOR_INTERVAL"
  done
}

# ════════════════════════════════════════════════════════════
#  COMMAND: status
# ════════════════════════════════════════════════════════════

cmd_status() {
  export PATH="${HOME}/.foundry/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"
  echo ""
  echo -e "${BOLD}${CYAN}Arc Node Status  ·  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
  echo "══════════════════════════════════════════════════"

  local arc_ver_file="${HOME}/.arc-version" installed_ver
  if [[ -f "$arc_ver_file" ]]; then
    installed_ver=$(tr -d '[:space:]' < "$arc_ver_file")
  else
    installed_ver="${ARC_VERSION_DEFAULT}  ${DIM}(default — run 'update' to record exact version)${NC}"
  fi
  printf "  %-36s${CYAN}%s${NC}\n" "Installed version" "$installed_ver"
  echo ""

  for svc in "arc-execution" "arc-consensus"; do
    local active; active=$(systemctl is-active "$svc" 2>/dev/null || echo "not-installed")
    printf "  %-36s" "$svc"
    case "$active" in
      active)        echo -e "${GREEN}● RUNNING${NC}" ;;
      not-installed) echo -e "${DIM}not installed${NC}" ;;
      *)             echo -e "${RED}● ${active^^}${NC}" ;;
    esac
  done
  echo ""

  if command -v cast &>/dev/null; then
    local lb; lb=$(cast block-number --rpc-url http://localhost:8545 2>/dev/null | tr -dc '0-9')
    printf "  %-36s${CYAN}%s${NC}\n" "Local block height" "${lb:-N/A}"
  fi

  if [[ -d "$ARC_DATA_DIR" ]]; then
    local used; used=$(du -sh "$ARC_DATA_DIR" 2>/dev/null | cut -f1 || echo "?")
    printf "  %-36s${CYAN}%s${NC}\n" "Data directory size" "$used"
  fi

  local free_disk; free_disk=$(df -h "$HOME" | awk 'NR==2{print $4}')
  printf "  %-36s${CYAN}%s${NC}\n" "Free disk (home partition)" "$free_disk"
  echo ""
  echo -e "  ${DIM}RPC      :  http://localhost:8545        CL RPC  :  http://localhost:31000${NC}"
  echo -e "  ${DIM}Metrics  :  http://localhost:9001/metrics         http://localhost:29000/metrics${NC}"
  echo ""
}

# ════════════════════════════════════════════════════════════
#  COMMAND: logs
# ════════════════════════════════════════════════════════════

cmd_logs() {
  local target="${1:-both}"
  require_sudo
  case "$target" in
    el|execution)
      echo -e "${CYAN}Tailing arc-execution logs (Ctrl+C to stop)...${NC}"
      sudo journalctl -u arc-execution -f ;;
    cl|consensus)
      echo -e "${CYAN}Tailing arc-consensus logs (Ctrl+C to stop)...${NC}"
      sudo journalctl -u arc-consensus -f ;;
    both)
      echo -e "${CYAN}Tailing both layers (Ctrl+C to stop)...${NC}"
      sudo journalctl -u arc-execution -u arc-consensus -f ;;
    *)
      error "Unknown log target '${target}'. Valid options: el, cl, both"
      exit 1 ;;
  esac
}

# ════════════════════════════════════════════════════════════
#  COMMAND: start / stop / restart
# ════════════════════════════════════════════════════════════

cmd_service() {
  local action="$1"
  require_sudo
  echo -e "${CYAN}${action^}ing Arc services...${NC}"
  case "$action" in
    stop)
      # Always stop consensus before execution — safe tear-down order.
      sudo systemctl stop arc-consensus arc-execution 2>/dev/null || true
      success "Services stopped." ;;
    start)
      sudo systemctl start arc-execution
      _wait_for_ipc
      sudo systemctl start arc-consensus
      success "Services started." ;;
    restart)
      sudo systemctl stop arc-consensus arc-execution 2>/dev/null || true
      sudo systemctl is-active --quiet arc-consensus 2>/dev/null \
        && warn "arc-consensus still active after stop — watch for state conflicts."
      sudo systemctl is-active --quiet arc-execution 2>/dev/null \
        && warn "arc-execution still active after stop — watch for IPC conflicts."
      sudo systemctl start arc-execution
      _wait_for_ipc
      sudo systemctl start arc-consensus
      success "Services restarted." ;;
  esac
  echo ""
  cmd_status
}

# ════════════════════════════════════════════════════════════
#  COMMAND: update
# ════════════════════════════════════════════════════════════

cmd_update() {
  local new_ver="" flags=()
  for arg in "$@"; do
    if [[ -z "$new_ver" && "$arg" =~ ^v[0-9] ]]; then new_ver="$arg"
    else flags+=("$arg"); fi
  done
  # "${flags[@]+...}" tests whether the variable is set, not whether it is non-empty.
  # For an empty array the behaviour is undefined across bash versions and nounset
  # settings. Use the correctly quoted form instead.
  [[ ${#flags[@]} -gt 0 ]] && parse_setup_flags "${flags[@]}"
  require_sudo

  if [[ -z "$new_ver" ]]; then
    info "No version specified — querying GitHub for the latest arc-node release..."
    local gh_api_base="https://api.github.com/repos/circlefin/arc-node"
    local gh_headers=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
    local detected=""

    if command -v curl &>/dev/null; then
      # Try /releases/latest first; fall back to /tags.
      local release_json
      release_json=$(curl -fsSL --max-time 15 "${gh_headers[@]}" \
        "${gh_api_base}/releases/latest" 2>/dev/null || true)
      if [[ -n "$release_json" ]]; then
        detected=$(printf '%s' "$release_json" \
          | jq -r '.tag_name // empty' 2>/dev/null \
          | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
      fi

      if [[ -z "$detected" ]]; then
        info "No formal GitHub release found — falling back to latest tag..."
        local tags_json
        tags_json=$(curl -fsSL --max-time 15 "${gh_headers[@]}" \
          "${gh_api_base}/tags?per_page=20" 2>/dev/null || true)
        if [[ -n "$tags_json" ]]; then
          detected=$(printf '%s' "$tags_json" \
            | jq -r '.[].name // empty' 2>/dev/null \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -V | tail -1 || true)
        fi
      fi
    fi

    if [[ -n "$detected" ]]; then
      success "Latest arc-node version from GitHub: ${detected}"
      new_ver="$detected"
    else
      warn "Could not reach GitHub API. Check your network."
      ask "Which Arc version to update to? (e.g. v0.7.0): "
      read -r new_ver || fatal "Unexpected EOF on stdin — pass the version explicitly: ./setup.sh update v0.7.0"
    fi
  fi

  [[ -z "$new_ver" ]] && fatal "No version provided."
  _validate_version "$new_ver"

  echo ""
  echo -e "${BOLD}${CYAN}Arc Node Update  →  ${new_ver}  (source: github.com/circlefin/arc-node)${NC}"
  echo "═══════════════════════════════════════════"
  echo "  1. Stop both services"
  echo "  2. Checkout ${new_ver} in ${BUILD_DIR}"
  echo "  3. Recompile all three binaries (~20–60 min)"
  echo "  4. Restart services"
  echo ""
  confirm "Proceed with update to ${new_ver}?" || { echo "Cancelled."; exit 0; }

  info "Stopping services..."
  sudo systemctl stop arc-consensus arc-execution 2>/dev/null || true
  # Refuse to overwrite binaries if either service is still active.
  sudo systemctl is-active --quiet arc-consensus 2>/dev/null \
    && fatal "arc-consensus is still active — refusing to overwrite binaries. Check: sudo journalctl -u arc-consensus -n 20"
  sudo systemctl is-active --quiet arc-execution 2>/dev/null \
    && fatal "arc-execution is still active — refusing to overwrite binaries. Check: sudo journalctl -u arc-execution -n 20"

  # shellcheck source=/dev/null
  [[ -f "${HOME}/.cargo/env" ]] && source "${HOME}/.cargo/env"
  export PATH="${HOME}/.foundry/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"

  if [[ ! -d "$BUILD_DIR" ]]; then
    info "Source not found — cloning..."
    git -c http.connectTimeout=30 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
      clone "$ARC_REPO" "$BUILD_DIR" 2>>"$LOG_FILE" \
      || fatal "Failed to clone ${ARC_REPO}. Check network access and ${LOG_FILE}"
  fi

  local orig_dir="$PWD"
  cd "$BUILD_DIR" || fatal "Failed to enter source directory: ${BUILD_DIR}"
  info "Fetching and checking out ${new_ver}..."
  _retry 3 git -c http.connectTimeout=30 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
    fetch --tags 2>>"$LOG_FILE" \
    || fatal "Failed to fetch tags after 3 attempts. Check network access and ${LOG_FILE}"
  git reset --hard HEAD 2>>"$LOG_FILE" || true
  _retry 3 git checkout -f "$new_ver" 2>>"$LOG_FILE" \
    || fatal "Tag '${new_ver}' not found after retries. Run: git -C ${BUILD_DIR} fetch --tags"
  git submodule update --init --recursive --force 2>>"$LOG_FILE" \
    || fatal "Submodule checkout failed. Check network access and ${LOG_FILE}"
  success "Checked out ${new_ver}"

  # Back up current binaries before overwriting. If any crate fails mid-build
  # the partially-installed set would leave the node unrunnable with no path back.
  info "Backing up current binaries before overwrite..."
  local _bak_ok=true
  for b in arc-node-execution arc-node-consensus arc-snapshots; do
    if [[ -f "/usr/local/bin/${b}" ]]; then
      sudo cp "/usr/local/bin/${b}" "/usr/local/bin/${b}.bak" \
        || { warn "Could not back up /usr/local/bin/${b} — proceeding without backup."; _bak_ok=false; }
    fi
  done
  $_bak_ok && info "Binaries backed up to /usr/local/bin/*.bak"

  _restore_bak_binaries() {
    trap 'fatal "Unexpected error near line ${BASH_LINENO[0]} while running: ${BASH_COMMAND}"' ERR
    warn "Build failed — attempting rollback to backed-up binaries..."
    for b in arc-node-execution arc-node-consensus arc-snapshots; do
      if [[ -f "/usr/local/bin/${b}.bak" ]]; then
        sudo mv "/usr/local/bin/${b}.bak" "/usr/local/bin/${b}" \
          && info "Restored /usr/local/bin/${b}" || true
      fi
    done
    sudo systemctl start arc-execution || true
    # Best-effort wait for IPC — don't abort rollback on timeout.
    # _wait_for_ipc calls fatal internally, so || true would never suppress it.
    local _t=0
    while [[ $_t -lt 60 ]] && [[ ! -S "${IPC_DIR}/reth.ipc" ]]; do sleep 1; _t=$(( _t + 1 )); done
    [[ -S "${IPC_DIR}/reth.ipc" ]] \
      && info "IPC socket ready" \
      || warn "IPC socket not ready after 60s — consensus may fail to connect."
    sudo systemctl start arc-consensus || true
    fatal "Rolled back to previous binaries after failed build. Check ${LOG_FILE}"
  }

  # Override ERR trap so unexpected failures in cmd_update's own code between the
  # _cargo_install calls (e.g. a failed git or install command) also trigger rollback.
  # Note: ERR traps are NOT inherited by called functions without `set -E`, so
  # failures *inside* _cargo_install are handled by its own return-1 paths caught below.
  trap '_restore_bak_binaries' ERR
  _cargo_install "crates/node"           "/usr/local" || _restore_bak_binaries
  _cargo_install "crates/malachite-app"  "/usr/local" || _restore_bak_binaries
  _cargo_install "crates/snapshots"      "/usr/local" || _restore_bak_binaries
  trap 'fatal "Unexpected error near line ${BASH_LINENO[0]} while running: ${BASH_COMMAND}"' ERR

  # Remove backups now that all three crates installed successfully.
  for b in arc-node-execution arc-node-consensus arc-snapshots; do
    sudo rm -f "/usr/local/bin/${b}.bak" 2>/dev/null || true
  done

  cd "$orig_dir"
  _verify_binaries

  # Patch ARC_VERSION_DEFAULT in this script file (best-effort).
  local self; self=$(realpath "$0")
  if [[ -w "$self" ]]; then
    sed -i "s/^ARC_VERSION_DEFAULT=.*/ARC_VERSION_DEFAULT=\"${new_ver}\"/" "$self" \
      || warn "Could not patch ARC_VERSION_DEFAULT in ${self} — version string not updated."
    info "Updated ARC_VERSION_DEFAULT to ${new_ver} in ${self}"
  fi

  # Record installed version for cmd_status.
  printf '%s\n' "$new_ver" > "${HOME}/.arc-version" \
    || warn "Could not write to ${HOME}/.arc-version — status may show stale version."

  info "Starting services..."
  sudo systemctl start arc-execution
  _wait_for_ipc
  sudo systemctl start arc-consensus
  success "Update complete — now running ${new_ver}."
  echo ""
  cmd_status
}

# ════════════════════════════════════════════════════════════
#  SUDO ROLLBACK
#  Removes the passwordless sudo drop-in written by _bootstrap_sudo
#  during setup on keypair-only VPS instances.  Safe to call even
#  when the file does not exist (no-op with an info message).
#  Called by both cmd_uninstall and cmd_rollback_sudo.
# ════════════════════════════════════════════════════════════

_rollback_sudo_dropin() {
  local drop_in="/etc/sudoers.d/${USER}-nopasswd"

  if ! sudo -n test -f "$drop_in" 2>/dev/null; then
    info "No sudoers drop-in found at ${drop_in} — nothing to remove."
    return 0
  fi

  echo ""
  info "Sudoers drop-in found: ${drop_in}"
  echo -e "  ${DIM}This file was written by setup.sh to allow passwordless sudo on a keypair VPS.${NC}"
  echo -e "  ${DIM}Removing it restores your original sudo configuration.${NC}"
  echo ""

  if confirm "Remove ${drop_in} and restore original sudo behaviour?"; then
    sudo rm -f "$drop_in" \
      && success "Sudoers drop-in removed — sudo restored to its original state." \
      || warn "Could not remove ${drop_in} — remove it manually: sudo rm ${drop_in}"
  else
    info "Keeping ${drop_in} — sudo configuration unchanged."
  fi
}

cmd_rollback_sudo() {
  require_sudo
  echo ""
  echo -e "${BOLD}${CYAN}Rollback Passwordless Sudo${NC}"
  echo "════════════════════════════════════════════════════"
  echo ""
  echo -e "  This removes the sudoers drop-in written by setup.sh if your server"
  echo -e "  was detected as a keypair-only VPS during the initial install:"
  echo ""
  echo -e "    ${DIM}/etc/sudoers.d/${USER}-nopasswd${NC}"
  echo ""
  echo -e "  Removing it restores your original sudo configuration. If you rely"
  echo -e "  on passwordless sudo for other reasons, do not proceed."
  echo ""
  _rollback_sudo_dropin
  echo ""
}

# ════════════════════════════════════════════════════════════
#  COMMAND: uninstall
# ════════════════════════════════════════════════════════════

cmd_uninstall() {
  require_sudo
  local drop_in="/etc/sudoers.d/${USER}-nopasswd"
  local has_dropin=false
  sudo -n test -f "$drop_in" 2>/dev/null && has_dropin=true || true

  echo ""
  echo -e "${RED}${BOLD}Arc Node Uninstall${NC}"
  echo "════════════════════════════════════════════════════"
  echo ""
  echo "This will remove:"
  echo "  • systemd services  (arc-execution, arc-consensus)"
  echo "  • Installed binaries  (arc-node-execution, arc-node-consensus, arc-snapshots)"
  $has_dropin && \
  echo "  • Passwordless sudo drop-in  (/etc/sudoers.d/${USER}-nopasswd)"
  echo ""
  echo "Optionally (asked separately):"
  echo "  • Chain data at ${ARC_DATA_DIR}  (~120+ GB)"
  echo "  • Source code at ${BUILD_DIR}"
  echo ""

  confirm_danger "Start Arc Node uninstall — this cannot be undone." \
    || { echo "Uninstall cancelled."; exit 0; }

  # Services
  info "Stopping and removing services..."
  sudo systemctl stop arc-consensus arc-execution 2>/dev/null || true
  sudo systemctl disable arc-consensus arc-execution 2>/dev/null || true
  sudo rm -f /etc/systemd/system/arc-execution.service \
             /etc/systemd/system/arc-consensus.service
  sudo systemctl daemon-reload
  success "Services removed"

  # Binaries
  info "Removing binaries..."
  for b in arc-node-execution arc-node-consensus arc-snapshots; do
    for p in "/usr/local/bin" "${HOME}/.cargo/bin"; do
      [[ -f "${p}/${b}" ]] && sudo rm -f "${p}/${b}" && info "Removed ${p}/${b}"
    done
  done
  sudo rm -rf "$IPC_DIR" 2>/dev/null || true
  success "Binaries removed"

  rm -f "$STATE_FILE"

  # Sudoers drop-in (offered here so the user leaves with a clean system)
  _rollback_sudo_dropin

  # Chain data (separate heavy confirm)
  if [[ -d "$ARC_DATA_DIR" ]]; then
    local sz; sz=$(du -sh "$ARC_DATA_DIR" 2>/dev/null | cut -f1 || echo "?")
    echo ""
    warn "Chain data at ${ARC_DATA_DIR} (${sz}) — IRREVERSIBLE if deleted!"
    if confirm_danger "Permanently delete chain data at ${ARC_DATA_DIR} (${sz})?"; then
      rm -rf "$ARC_DATA_DIR"; success "Chain data deleted"
    else
      info "Keeping chain data at ${ARC_DATA_DIR}"
    fi
  fi

  # Source code
  if [[ -d "$BUILD_DIR" ]]; then
    confirm "Delete source code at ${BUILD_DIR}?" \
      && { rm -rf "$BUILD_DIR"; success "Source deleted"; }
  fi

  sudo rm -f /etc/systemd/journald.conf.d/arc-node.conf 2>/dev/null || true
  sudo systemctl kill --kill-who=main --signal=SIGUSR2 systemd-journald 2>/dev/null || true

  success "Arc node fully uninstalled."
  echo ""
  echo -e "${DIM}Key backup at ${BACKUP_DIR} was kept — remove manually if desired.${NC}"
  echo ""
}

# ════════════════════════════════════════════════════════════
#  MAIN SETUP FLOW
# ════════════════════════════════════════════════════════════

main_setup() {
  # Prevent concurrent runs from racing on the state file and service files.
  exec 9>"${HOME}/.arc-setup.lock"
  flock -n 9 || fatal "Another instance of setup.sh is already running (lock: ${HOME}/.arc-setup.lock)."
  # Remove the lock file on exit (normal or error). flock releases the fd automatically
  # when the process exits, so a subsequent run can always acquire it — but leaving a
  # stale file confuses users who wonder why the file is there after a crash.
  trap 'rm -f "${HOME}/.arc-setup.lock"' EXIT

  echo "=== Arc Node Setup — $(date) ===" >> "$LOG_FILE"
  require_sudo
  load_state
  phase_welcome
  phase_check_requirements
  phase_install_deps
  phase_build_binaries
  phase_setup_data
  phase_init_consensus
  phase_install_services
  phase_verify
  print_summary
  rm -f "$STATE_FILE"
}

# ════════════════════════════════════════════════════════════
#  ENTRYPOINT
# ════════════════════════════════════════════════════════════

case "${1:-setup}" in
  setup)          shift || true; parse_setup_flags "$@"; main_setup ;;
  monitor)        cmd_monitor ;;
  status)         cmd_status ;;
  logs)           cmd_logs "${2:-both}" ;;
  update)         shift || true; cmd_update "$@" ;;
  restart)        cmd_service restart ;;
  stop)           cmd_service stop ;;
  start)          cmd_service start ;;
  uninstall)      cmd_uninstall ;;
  rollback-sudo)  cmd_rollback_sudo ;;
  -h|--help|help) usage ;;
  *)
    error "Unknown command: ${1}"
    echo -e "Run ${CYAN}./setup.sh help${NC} for usage."
    exit 1 ;;
esac
