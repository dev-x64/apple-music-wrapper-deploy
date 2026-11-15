#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_REPO_URL="${WRAPPER_DEPLOY_REPO_URL:-https://github.com/dev-x64/apple-music-wrapper-deploy.git}"
APP_DIR="${WRAPPER_INSTALL_DIR:-/opt/apple-music-wrapper}"
PORT="${WRAPPER_PORT:-12340}"
TEST_ADAM_ID="${WRAPPER_TEST_ADAM_ID:-1608815075}"
WATCHDOG="${WRAPPER_WATCHDOG:-1}"
WATCHDOG_INTERVAL="${WRAPPER_WATCHDOG_INTERVAL:-5min}"
RELOGIN_COOLDOWN="${WRAPPER_RELOGIN_COOLDOWN:-21600}"
SAVE_CREDENTIALS="${WRAPPER_SAVE_CREDENTIALS:-0}"
REPLACE_CONTAINER="${WRAPPER_REPLACE_CONTAINER:-0}"
IMPORT_DATA="${WRAPPER_IMPORT_DATA:-}"
FIREWALL_MODE="${WRAPPER_FIREWALL:-}"
if [[ -z "$FIREWALL_MODE" ]]; then
  # WRAPPER_UFW=auto|enable|off is the older name of this setting.
  case "${WRAPPER_UFW:-auto}" in
    enable) FIREWALL_MODE=ufw ;;
    *) FIREWALL_MODE="${WRAPPER_UFW:-auto}" ;;
  esac
fi
CONFIG_FILE="/etc/apple-music-wrapper.conf"
TEMP_DIR=""

die() { echo "install: $*" >&2; exit 1; }
cleanup() { [[ -z "$TEMP_DIR" ]] || rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "run as root: sudo bash install.sh"
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] ||
  die "this installer currently supports Linux x86_64 only"
[[ -r /etc/os-release ]] || die "/etc/os-release is missing"
# shellcheck source=/dev/null
source /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
  *) die "this installer supports Ubuntu 22.04/24.04 and Debian 12/13 (found ${PRETTY_NAME:-unknown})" ;;
esac
[[ "$APP_DIR" == /* && "$APP_DIR" != / ]] || die "WRAPPER_INSTALL_DIR must be an absolute directory"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
  die "invalid WRAPPER_PORT"
fi
[[ "$TEST_ADAM_ID" =~ ^[0-9]+$ ]] || die "invalid WRAPPER_TEST_ADAM_ID"
[[ "$WATCHDOG" == 0 || "$WATCHDOG" == 1 ]] || die "WRAPPER_WATCHDOG must be 0 or 1"
[[ "$WATCHDOG_INTERVAL" =~ ^[0-9]+(s|sec|m|min|h)$ ]] ||
  die "invalid WRAPPER_WATCHDOG_INTERVAL (examples: 300s, 5min, 1h)"
[[ "$RELOGIN_COOLDOWN" =~ ^[0-9]+$ ]] || die "WRAPPER_RELOGIN_COOLDOWN must be seconds"
[[ "$SAVE_CREDENTIALS" == 0 || "$SAVE_CREDENTIALS" == 1 ]] ||
  die "WRAPPER_SAVE_CREDENTIALS must be 0 or 1"
[[ "$REPLACE_CONTAINER" == 0 || "$REPLACE_CONTAINER" == 1 ]] ||
  die "WRAPPER_REPLACE_CONTAINER must be 0 or 1"
case "$FIREWALL_MODE" in
  auto|ufw|iptables|off) ;;
  *) die "WRAPPER_FIREWALL must be auto, ufw, iptables or off" ;;
esac
[[ -t 0 ]] || die "an interactive terminal is required for login and possible 2FA"

if [[ -e "$APP_DIR" && ! -e "$APP_DIR/.wrapper-deploy-managed" ]] &&
   [[ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then
  die "$APP_DIR already contains an unmanaged installation; choose another WRAPPER_INSTALL_DIR"
fi
if [[ -e /usr/local/bin/wrapper ]] &&
   ! grep -q 'apple-music-wrapper.conf' /usr/local/bin/wrapper; then
  die "/usr/local/bin/wrapper already exists and is not managed by this installer"
fi
if [[ -e "$CONFIG_FILE" ]] && ! grep -q '^APP_DIR=' "$CONFIG_FILE"; then
  die "$CONFIG_FILE already exists and is not managed by this installer"
fi

echo "Installing host prerequisites..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl git python3
if [[ "$FIREWALL_MODE" == ufw ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
elif [[ "$FIREWALL_MODE" == iptables ]] && ! command -v iptables >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Configuring Docker's official apt repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -qq
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing Docker Engine and Compose..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
elif ! docker compose version >/dev/null 2>&1; then
  echo "Installing Docker Compose plugin..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin
fi
docker compose version >/dev/null 2>&1 ||
  die "Docker Compose v2 is required; install docker-compose-plugin before retrying"
systemctl enable --now docker >/dev/null
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

# A container named "wrapper" that this installer did not create (for example a manual
# deployment of the upstream image) would clash with ours on the name and the port.
foreign_container=0
if docker container inspect wrapper >/dev/null 2>&1; then
  project="$(docker container inspect wrapper \
    --format '{{with .Config.Labels}}{{index . "com.docker.compose.project"}}{{end}}')"
  if [[ "$project" != apple-music-wrapper ]]; then
    [[ "$REPLACE_CONTAINER" == 1 ]] ||
      die "a container named 'wrapper' already exists and was not created by this installer;
  rerun with WRAPPER_REPLACE_CONTAINER=1 to stop it (it is kept as a backup and its
  account data is imported, so no new login is needed)"
    foreign_container=1
    if [[ -z "$IMPORT_DATA" ]]; then
      IMPORT_DATA="$(docker container inspect wrapper --format \
        '{{range .Mounts}}{{if eq .Destination "/app/rootfs/data"}}{{.Source}}{{end}}{{end}}')"
      [[ -z "$IMPORT_DATA" ]] || echo "Account data of the existing container: $IMPORT_DATA"
    fi
  fi
fi
[[ -z "$IMPORT_DATA" || -d "$IMPORT_DATA" ]] ||
  die "WRAPPER_IMPORT_DATA is not a directory: $IMPORT_DATA"

source_dir=""
script_path="${BASH_SOURCE[0]}"
if [[ -f "$script_path" ]]; then
  candidate="$(cd "$(dirname "$script_path")" && pwd)"
  if [[ -f "$candidate/wrapper" && -f "$candidate/download-upstream.sh" &&
        -f "$candidate/Dockerfile.template" &&
        -f "$candidate/compose.yaml.template" &&
        -f "$candidate/wrapper-watchdog.service" &&
        -f "$candidate/wrapper-watchdog.timer.template" ]]; then
    source_dir="$candidate"
  fi
fi
if [[ -z "$source_dir" ]]; then
  TEMP_DIR="$(mktemp -d)"
  echo "Downloading installer files from GitHub..."
  git clone --depth 1 "$DEPLOY_REPO_URL" "$TEMP_DIR/deploy"
  source_dir="$TEMP_DIR/deploy"
fi

install -d -m 0755 "$APP_DIR"
install -d -m 0700 "$APP_DIR/data"
touch "$APP_DIR/.wrapper-deploy-managed"
install -m 0755 "$source_dir/download-upstream.sh" "$APP_DIR/download-upstream.sh"
if [[ ! -f "$APP_DIR/upstream/.source-commit" ]]; then
  "$APP_DIR/download-upstream.sh" "$APP_DIR/upstream.download"
  if [[ -e "$APP_DIR/upstream" ]]; then
    mv "$APP_DIR/upstream" "$APP_DIR/upstream.source-backup.$(date +%s)"
  fi
  mv "$APP_DIR/upstream.download" "$APP_DIR/upstream"
fi
install -m 0644 "$source_dir/Dockerfile.template" "$APP_DIR/Dockerfile"
install -m 0644 "$source_dir/compose.yaml.template" "$APP_DIR/compose.yaml"
install -m 0644 "$source_dir/dockerignore.template" "$APP_DIR/.dockerignore"
install -m 0755 "$source_dir/wrapper" /usr/local/bin/wrapper
printf 'WRAPPER_PORT=%s\n' "$PORT" > "$APP_DIR/.env"
chmod 0644 "$APP_DIR/.env"
printf 'APP_DIR=%q\nPORT=%q\nTEST_ADAM_ID=%q\nRELOGIN_COOLDOWN=%q\n' \
  "$APP_DIR" "$PORT" "$TEST_ADAM_ID" "$RELOGIN_COOLDOWN" > "$CONFIG_FILE"
chmod 0644 "$CONFIG_FILE"

echo "Building Docker image from the prebuilt lite package..."
docker compose --project-directory "$APP_DIR" --env-file "$APP_DIR/.env" \
  -f "$APP_DIR/compose.yaml" -p apple-music-wrapper build wrapper

# Firewall. "auto" never turns a firewall on, so servers that run other services keep
# their firewall state: it adds a UFW rule when UFW is active, otherwise an iptables
# ACCEPT rule when iptables is installed. "ufw" also installs and turns UFW on (allowing
# the detected SSH ports first), which suits a fresh server. "iptables" forces the
# iptables rule. "off" leaves the firewall alone.
ufw_active=0
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw_active=1
fi
firewall=off
case "$FIREWALL_MODE" in
  ufw|iptables) firewall="$FIREWALL_MODE" ;;
  auto)
    if [[ "$ufw_active" == 1 ]]; then
      firewall=ufw
    elif command -v iptables >/dev/null 2>&1; then
      firewall=iptables
    fi
    ;;
esac
printf 'FIREWALL=%q\n' "$firewall" >> "$CONFIG_FILE"
if [[ "$firewall" == ufw ]]; then
  echo "Opening port $PORT/tcp in UFW..."
  ssh_ports=()
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ssh_ports+=("${SSH_CONNECTION##* }")
  fi
  if [[ -x /usr/sbin/sshd ]]; then
    while read -r ssh_port; do ssh_ports+=("$ssh_port"); done < <(
      /usr/sbin/sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'
    )
  fi
  if command -v ss >/dev/null 2>&1; then
    while read -r ssh_port; do ssh_ports+=("$ssh_port"); done < <(
      ss -ltnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'
    )
  fi
  ssh_allowed=0
  for ssh_port in "${ssh_ports[@]}"; do
    if [[ "$ssh_port" =~ ^[0-9]+$ ]] && ((ssh_port >= 1 && ssh_port <= 65535)); then
      ufw allow "$ssh_port/tcp" comment 'SSH'
      ssh_allowed=1
    fi
  done
  if [[ "$ssh_allowed" == 0 ]]; then ufw allow 22/tcp comment 'SSH'; fi
  ufw allow "$PORT/tcp" comment 'Apple Music wrapper'
  if [[ "$ufw_active" == 0 ]]; then
    ufw --force enable
  fi
elif [[ "$firewall" == iptables ]]; then
  echo "Allowing port $PORT/tcp in iptables (re-applied by the watchdog after reboots)..."
  /usr/local/bin/wrapper firewall
else
  echo "No active UFW and no iptables found; leaving the firewall unchanged."
  echo "Make sure port $PORT/tcp is reachable."
fi

if [[ "$foreign_container" == 1 ]]; then
  backup_name="wrapper-replaced-$(date +%s)"
  echo "Stopping the existing 'wrapper' container and keeping it as '$backup_name'..."
  docker stop wrapper >/dev/null
  docker rename wrapper "$backup_name"
  docker update --restart=no "$backup_name" >/dev/null
fi
if [[ -n "$IMPORT_DATA" ]]; then
  if [[ -n "$(ls -A "$APP_DIR/data")" ]]; then
    echo "Skipping account data import: $APP_DIR/data is not empty"
  else
    echo "Importing account data from $IMPORT_DATA..."
    cp -a "$IMPORT_DATA/." "$APP_DIR/data/"
  fi
fi

logged_in=0
if [[ -n "$(ls -A "$APP_DIR/data")" ]]; then
  echo "Existing account data found; starting wrapper with it..."
  /usr/local/bin/wrapper restart || true
  if /usr/local/bin/wrapper status >/dev/null 2>&1; then logged_in=1; fi
fi
if [[ "$logged_in" == 0 ]]; then
  echo "Sign in to Apple Music:"
  if [[ "$SAVE_CREDENTIALS" == 1 ]]; then
    /usr/local/bin/wrapper login --save
  else
    /usr/local/bin/wrapper login
  fi
elif [[ "$SAVE_CREDENTIALS" == 1 ]]; then
  echo "Already signed in. Run 'sudo wrapper login --save' to store credentials for re-login."
fi

if [[ "$WATCHDOG" == 1 ]]; then
  echo "Enabling the watchdog (every $WATCHDOG_INTERVAL)..."
  install -m 0644 "$source_dir/wrapper-watchdog.service" \
    /etc/systemd/system/wrapper-watchdog.service
  sed "s/@INTERVAL@/$WATCHDOG_INTERVAL/" "$source_dir/wrapper-watchdog.timer.template" \
    > /etc/systemd/system/wrapper-watchdog.timer
  chmod 0644 /etc/systemd/system/wrapper-watchdog.timer
  systemctl daemon-reload
  systemctl enable wrapper-watchdog.timer >/dev/null 2>&1
  systemctl restart wrapper-watchdog.timer
else
  systemctl disable --now wrapper-watchdog.timer >/dev/null 2>&1 || true
fi

echo
if [[ "$foreign_container" == 1 ]]; then
  echo "The previous container is stopped and kept as '$backup_name'."
  echo "Remove it when you no longer need it: docker rm $backup_name"
fi
echo "Installed. Commands: wrapper status | wrapper logs | wrapper login | wrapper update | wrapper test | wrapper watchdog"
echo "Endpoint: http://$(hostname -I | awk '{print $1}'):$PORT"
