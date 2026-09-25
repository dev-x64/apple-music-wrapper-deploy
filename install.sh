#!/usr/bin/env bash
set -Eeuo pipefail

DEPLOY_REPO_URL="${WRAPPER_DEPLOY_REPO_URL:-https://github.com/dev-x64/apple-music-wrapper-deploy.git}"
APP_DIR="${WRAPPER_INSTALL_DIR:-/opt/apple-music-wrapper}"
PORT="${WRAPPER_PORT:-12340}"
TEST_ADAM_ID="${WRAPPER_TEST_ADAM_ID:-1608815075}"
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
[[ "$ID" == ubuntu ]] || die "this installer currently supports Ubuntu 22.04/24.04"
[[ "$VERSION_ID" == 22.04 || "$VERSION_ID" == 24.04 ]] ||
  die "this installer currently supports Ubuntu 22.04/24.04"
[[ "$APP_DIR" == /* && "$APP_DIR" != / ]] || die "WRAPPER_INSTALL_DIR must be an absolute directory"
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
  die "invalid WRAPPER_PORT"
fi
[[ "$TEST_ADAM_ID" =~ ^[0-9]+$ ]] || die "invalid WRAPPER_TEST_ADAM_ID"
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
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl git python3 ufw

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  echo "Configuring Docker's official apt repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
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

source_dir=""
script_path="${BASH_SOURCE[0]}"
if [[ -f "$script_path" ]]; then
  candidate="$(cd "$(dirname "$script_path")" && pwd)"
  if [[ -f "$candidate/wrapper" && -f "$candidate/download-upstream.sh" &&
        -f "$candidate/Dockerfile.template" &&
        -f "$candidate/compose.yaml.template" ]]; then
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
printf 'APP_DIR=%q\nPORT=%q\nTEST_ADAM_ID=%q\n' \
  "$APP_DIR" "$PORT" "$TEST_ADAM_ID" > "$CONFIG_FILE"
chmod 0644 "$CONFIG_FILE"

echo "Building Docker image from the prebuilt lite package..."
docker compose --project-directory "$APP_DIR" --env-file "$APP_DIR/.env" \
  -f "$APP_DIR/compose.yaml" -p apple-music-wrapper build wrapper

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
if ! ufw status | grep -q '^Status: active'; then
  ufw --force enable
fi

echo "Sign in to Apple Music:"
/usr/local/bin/wrapper login
echo
echo "Installed. Commands: wrapper status | wrapper logs | wrapper login | wrapper update | wrapper test"
echo "Endpoint: http://$(hostname -I | awk '{print $1}'):$PORT"
