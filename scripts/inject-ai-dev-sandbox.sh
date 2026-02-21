#!/bin/bash
# =============================================================================
# inject-ai-dev-sandbox.sh
# =============================================================================
# Runs inside a privileged Docker container launched by build.sh.
# Transforms base.ext4 into ai-dev-sandbox.ext4 by
#   1 Copy base.ext4 and resize it
#   2 Mount the ext4 via loop device
#   3 Copy ai-dev-sandbox.tar into /var/lib/ai-dev-sandbox inside the rootfs
#   4 Install load-ai-dev-sandbox.service to load image into guest Docker on first boot
#   5 Install guest egress firewall systemd unit to lock down LAN access
#   6 Patch /home/sandbox/.bash_profile to auto-launch ai-dev-sandbox on login
#   7 Unmount cleanly
#
# Called by build.sh
# Runs as root inside ubuntu 24.04 privileged container
# Volume /build points at host .build directory
# =============================================================================

set -euo pipefail

BUILD_DIR="/build"
BASE_EXT4="$BUILD_DIR/base.ext4"
SANDBOX_EXT4="$BUILD_DIR/ai-dev-sandbox.ext4"
SANDBOX_TAR="$BUILD_DIR/ai-dev-sandbox.tar"
EXTRA_MB="${AI_SANDBOX_ROOTFS_EXTRA_MB:-6144}"
MOUNT="/mnt/rootfs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[inject]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[inject]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[inject]${NC} $*"; }
log_error() { echo -e "${RED}[inject]${NC} $*" >&2; }

cleanup() {
  if mountpoint -q "$MOUNT" 2>/dev/null; then
    umount "$MOUNT" 2>/dev/null || true
  fi
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

[ -f "$BASE_EXT4" ] || { log_error "base.ext4 not found at $BASE_EXT4"; exit 1; }
[ -f "$SANDBOX_TAR" ] || { log_error "ai-dev-sandbox.tar not found at $SANDBOX_TAR"; exit 1; }

TAR_SIZE_MB=$(( $(stat -c%s "$SANDBOX_TAR") / 1024 / 1024 ))
log_info "ai-dev-sandbox.tar size ${TAR_SIZE_MB}MB"
log_info "Adding ${EXTRA_MB}MB to rootfs for Docker image plus metadata"

log_info "Copying base.ext4 to ai-dev-sandbox.ext4"
cp "$BASE_EXT4" "$SANDBOX_EXT4"

CURRENT_MB=$(( $(stat -c%s "$SANDBOX_EXT4") / 1024 / 1024 ))
NEW_MB=$(( CURRENT_MB + EXTRA_MB ))
log_info "Resizing ${CURRENT_MB}MB to ${NEW_MB}MB"

truncate -s "${NEW_MB}M" "$SANDBOX_EXT4"
e2fsck -f -y "$SANDBOX_EXT4" >/dev/null 2>&1 || true
resize2fs "$SANDBOX_EXT4" >/dev/null 2>&1
log_ok "Filesystem resized to ${NEW_MB}MB"

mkdir -p "$MOUNT"
mount -o loop "$SANDBOX_EXT4" "$MOUNT"
log_ok "Mounted at $MOUNT"

log_info "Copying ai-dev-sandbox.tar into rootfs"
mkdir -p "$MOUNT/var/lib/ai-dev-sandbox"
cp "$SANDBOX_TAR" "$MOUNT/var/lib/ai-dev-sandbox/ai-dev-sandbox.tar"
log_ok "Copied $(du -sh "$MOUNT/var/lib/ai-dev-sandbox/ai-dev-sandbox.tar" | cut -f1)"

log_info "Installing load-ai-dev-sandbox systemd service"

cat > "$MOUNT/usr/local/bin/load-ai-dev-sandbox.sh" << 'LOADSCRIPT'
#!/bin/bash
set -e

TAR="/var/lib/ai-dev-sandbox/ai-dev-sandbox.tar"
MARKER="/var/lib/ai-dev-sandbox/.loaded"

if [ -f "$MARKER" ]; then
  echo "[load-ai-dev-sandbox] Image already loaded, skipping"
  exit 0
fi

if [ ! -f "$TAR" ]; then
  echo "[load-ai-dev-sandbox] ERROR $TAR not found" >&2
  exit 1
fi

echo "[load-ai-dev-sandbox] Loading ai-dev-sandbox Docker image from $TAR"
docker load < "$TAR"

touch "$MARKER"
echo "[load-ai-dev-sandbox] Done"
LOADSCRIPT
chmod +x "$MOUNT/usr/local/bin/load-ai-dev-sandbox.sh"

cat > "$MOUNT/etc/systemd/system/load-ai-dev-sandbox.service" << 'LOADSVC'
[Unit]
Description=Load ai-dev-sandbox Docker Image first boot
After=docker.service guest-init.service
Requires=docker.service
ConditionPathExists=!/var/lib/ai-dev-sandbox/.loaded

[Service]
Type=oneshot
ExecStart=/usr/local/bin/load-ai-dev-sandbox.sh
RemainAfterExit=yes
StandardOutput=journal+console
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
LOADSVC

mkdir -p "$MOUNT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/load-ai-dev-sandbox.service \
  "$MOUNT/etc/systemd/system/multi-user.target.wants/load-ai-dev-sandbox.service"

log_ok "load-ai-dev-sandbox.service installed and enabled"

log_info "Ensuring iptables exists in guest"
chroot "$MOUNT" /bin/bash -lc 'command -v iptables >/dev/null 2>&1 || (apt-get update && apt-get install -y iptables)' || true

# =============================================================================
# Guest egress policy
# Internet stays open for DNS plus HTTP plus HTTPS
# All RFC1918 is blocked
# One LAN IP is allowed on the ports you set using env in /workspace/.sandbox.env
# The env file is moved into guest disk at /var/lib/ai-dev-sandbox/env/sandbox.env
# =============================================================================

log_info "Installing guest egress firewall script"

cat > "$MOUNT/usr/local/bin/ai-dev-sandbox-egress.sh" << 'EGRESS'
#!/bin/bash
set -euo pipefail

ENV_SRC="/workspace/.sandbox.env"
ENV_DST_DIR="/var/lib/ai-dev-sandbox/env"
ENV_DST="${ENV_DST_DIR}/sandbox.env"

ALLOW_IP=""
ALLOW_PORTS="11434"

mkdir -p "$ENV_DST_DIR"
chmod 700 "$ENV_DST_DIR"

if [ -f "$ENV_SRC" ]; then
  cp "$ENV_SRC" "$ENV_DST"
  chmod 600 "$ENV_DST"
  rm -f "$ENV_SRC"

  set +u
  source "$ENV_DST"
  set -u

  ALLOW_IP="${EGRESS_ALLOW_IP:-}"
  ALLOW_PORTS="${EGRESS_ALLOW_TCP_PORTS:-11434}"
fi

iptables -P OUTPUT DROP
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 80 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT

if [ -n "$ALLOW_IP" ]; then
  IFS=',' read -ra PORT_ARR <<< "$ALLOW_PORTS"
  for p in "${PORT_ARR[@]}"; do
    p="$(echo "$p" | xargs)"
    [ -n "$p" ] || continue
    iptables -A OUTPUT -d "$ALLOW_IP" -p tcp --dport "$p" -j ACCEPT
  done
fi

iptables -A OUTPUT -d 10.0.0.0/8 -j REJECT
iptables -A OUTPUT -d 172.16.0.0/12 -j REJECT
iptables -A OUTPUT -d 192.168.0.0/16 -j REJECT

iptables -A OUTPUT -j REJECT
EGRESS

chmod +x "$MOUNT/usr/local/bin/ai-dev-sandbox-egress.sh"
log_ok "Guest egress firewall script installed"

log_info "Installing guest egress firewall systemd service"

cat > "$MOUNT/etc/systemd/system/ai-dev-sandbox-egress.service" << 'EGSVC'
[Unit]
Description=AI Sandbox egress firewall
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ai-dev-sandbox-egress.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EGSVC

mkdir -p "$MOUNT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/ai-dev-sandbox-egress.service \
  "$MOUNT/etc/systemd/system/multi-user.target.wants/ai-dev-sandbox-egress.service"

log_ok "ai-dev-sandbox-egress.service installed and enabled"

log_info "Patching sandbox .bash_profile for auto-launch"

mkdir -p "$MOUNT/home/sandbox"

cat > "$MOUNT/home/sandbox/.bash_profile" << 'PROFILE'
# =============================================================================
# sandbox .bash_profile auto-launch ai-dev-sandbox on login
# =============================================================================

[ -f ~/.bashrc ] && source ~/.bashrc

if [ -t 0 ] && [ -z "${SANDBOX_MODE:-}" ] && command -v docker >/dev/null 2>&1; then

  echo ""
  echo "  ╔══════════════════════════════════════════════════════════╗"
  echo "  ║                     AI-Sandbox MicroVM                   ║"
  echo "  ╚══════════════════════════════════════════════════════════╝"
  echo ""

  echo "  Waiting for ai-dev-sandbox image"
  for i in $(seq 1 120); do
    if docker image inspect ai-dev-sandbox:latest >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if docker image inspect ai-dev-sandbox:latest >/dev/null 2>&1; then
    ENV_FILE_ARG=""
    if [ -f /var/lib/ai-dev-sandbox/env/sandbox.env ]; then
      ENV_FILE_ARG="--env-file /var/lib/ai-dev-sandbox/env/sandbox.env"
    fi

    exec docker run -it --rm \
      --name ai-dev-sandbox \
      --hostname ai-dev-sandbox \
      -v /workspace:/workspace \
      $ENV_FILE_ARG \
      ai-dev-sandbox:latest
  else
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo " Work location cd /workspace"
    echo "────────────────────────────────────────────────────────"
    echo "  WARNING AI-Sandbox image not ready after 120s" >&2
    echo "  You are at the guest VM shell. Run manually" >&2
    echo "    docker run -it ai-dev-sandbox:latest" >&2
    echo ""
  fi
fi
PROFILE

chown 1000:1000 "$MOUNT/home/sandbox/.bash_profile"
log_ok ".bash_profile patched"

umount "$MOUNT"
trap - EXIT
rmdir "$MOUNT" 2>/dev/null || true

log_ok "Injection complete at $SANDBOX_EXT4"
