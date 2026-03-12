#!/usr/bin/env bash
# prereqs.sh — verify and configure the host before running docker compose up
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()      { echo -e "${GREEN}  [OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}  [WARN]${NC} $*"; }
fail()    { echo -e "${RED}  [FAIL]${NC} $*"; exit 1; }
info()    { echo -e "${BLUE}  [INFO]${NC} $*"; }
section() { echo -e "\n${BLUE}>>> $* ${NC}"; }

# ─── root ────────────────────────────────────────────────────────────────────
section "Permissions"
[[ $EUID -eq 0 ]] || fail "Run with sudo: sudo $0"
ok "Running as root"

# ─── docker ──────────────────────────────────────────────────────────────────
section "Docker"
command -v docker &>/dev/null  || fail "Docker not found. Install it first."
ok "Docker found: $(docker --version)"
docker info &>/dev/null        || fail "Docker daemon is not running. Start it with: systemctl start docker"
ok "Docker daemon is running"

# ─── nvidia drivers ──────────────────────────────────────────────────────────
section "NVIDIA Drivers"
command -v nvidia-smi &>/dev/null || fail "nvidia-smi not found. Install the NVIDIA driver first."
DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
ok "Driver version: ${DRIVER_VER}"

MODESET=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo N)
if [[ "$MODESET" != "Y" ]]; then
  warn "nvidia-drm modeset is not enabled — Wolf requires it."
  warn "Add the following and reboot:"
  warn "  echo 'options nvidia-drm modeset=1' > /etc/modprobe.d/nvidia-drm.conf"
else
  ok "nvidia-drm modeset=1"
fi

# ─── nvidia container toolkit ────────────────────────────────────────────────
section "NVIDIA Container Toolkit"
if command -v nvidia-container-cli &>/dev/null; then
  ok "nvidia-container-cli found"
  nvidia-container-cli info &>/dev/null && ok "nvidia-container-cli reports GPU accessible" \
    || warn "nvidia-container-cli found but GPU query failed — check toolkit config"
else
  # Fall back to checking the Docker runtime config
  if docker info 2>/dev/null | grep -qi nvidia; then
    ok "NVIDIA runtime visible in docker info"
  else
    fail "NVIDIA Container Toolkit not found. Install it:
    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
  fi
fi

# ─── /dev/dri ────────────────────────────────────────────────────────────────
section "DRI Render Node"
if [[ ! -d /dev/dri ]]; then
  fail "/dev/dri does not exist — GPU render nodes are missing"
fi
ok "Render nodes found: $(ls /dev/dri)"

# ─── userns-remap ────────────────────────────────────────────────────────────
section "User Namespace Remapping"
REMAP_USER=""

# Try reading from daemon.json
DAEMON_JSON="/etc/docker/daemon.json"
if [[ -f "$DAEMON_JSON" ]]; then
  REMAP_USER=$(python3 -c \
    "import json,sys; d=json.load(open('$DAEMON_JSON')); print(d.get('userns-remap',''))" \
    2>/dev/null || true)
fi

if [[ -z "$REMAP_USER" ]]; then
  warn "userns-remap is not configured in $DAEMON_JSON"
  warn "Falling back to raw UID 1000 for directory ownership"
  CONTAINER_UID=1000
else
  # "default" is Docker's alias for the auto-created dockremap user
  [[ "$REMAP_USER" == "default" ]] && REMAP_USER="dockremap"
  ok "userns-remap user: ${REMAP_USER}"

  grep -q "^${REMAP_USER}:" /etc/subuid \
    || fail "No entry for '${REMAP_USER}' in /etc/subuid — remap is misconfigured"

  SUBUID_START=$(grep "^${REMAP_USER}:" /etc/subuid | cut -d: -f2)
  CONTAINER_UID=$(( SUBUID_START + 1000 ))
  ok "Container UID 1000 → host UID ${CONTAINER_UID}"
fi

# ─── uinput ──────────────────────────────────────────────────────────────────
section "uinput"
if ! lsmod | grep -q uinput; then
  info "Loading uinput module..."
  modprobe uinput
fi
ok "uinput module loaded"

if [[ -e /dev/uinput ]]; then
  ok "/dev/uinput exists"
else
  fail "/dev/uinput does not exist after modprobe — check kernel support"
fi

# Persist uinput across reboots
MODULES_CONF="/etc/modules-load.d/wolf.conf"
if ! grep -rq "^uinput" /etc/modules-load.d/ 2>/dev/null; then
  echo "uinput" > "$MODULES_CONF"
  ok "Persisted uinput in ${MODULES_CONF}"
else
  ok "uinput already set to load on boot"
fi

# ─── directories ─────────────────────────────────────────────────────────────
section "Directories"
DIRS=(
  /opt/gow/users/player1/dota-cfg
  /opt/gow/users/player2/dota-cfg
  /opt/gow/shared/steamapps
)
for dir in "${DIRS[@]}"; do
  mkdir -p "$dir"
  ok "Ensured $dir"
done

# ─── ownership ───────────────────────────────────────────────────────────────
section "Ownership"
chown -R "${CONTAINER_UID}:${CONTAINER_UID}" /opt/gow
ok "Set /opt/gow ownership to ${CONTAINER_UID}:${CONTAINER_UID}"

# ─── done ────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}All prerequisites satisfied. You can now run:${NC}"
echo "  docker compose up -d"
