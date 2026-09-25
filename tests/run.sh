#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/app/data" "$TEMP_DIR/app/upstream"
printf 'APP_DIR=%q\nPORT=12340\nTEST_ADAM_ID=1608815075\n' \
  "$TEMP_DIR/app" > "$TEMP_DIR/config"
printf 'WRAPPER_PORT=12340\n' > "$TEMP_DIR/app/.env"
cp "$ROOT/compose.yaml.template" "$TEMP_DIR/app/compose.yaml"
cp "$ROOT/Dockerfile.template" "$TEMP_DIR/app/Dockerfile"

cat > "$TEMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in
    */status)
      if [[ "${MOCK_FAIL_STATUS:-0}" == 1 ]]; then
        printf '%s\n' '{"code":-1,"msg":"not logged in","data":null}'
      else
        printf '%s\n' '{"code":0,"msg":"SUCCESS","data":{"regions":["id"]}}'
      fi
      exit 0
      ;;
    */m3u8)
      if [[ "${MOCK_FAIL_M3U8:-0}" == 1 ]]; then
        printf '%s\n' '{"code":-1,"msg":"no playlist","data":null}'
      else
        printf '%s\n' '{"code":0,"msg":"SUCCESS","data":{"m3u8":"#EXTM3U"}}'
      fi
      exit 0
      ;;
  esac
done
exit 2
EOF
chmod +x "$TEMP_DIR/bin/curl"

bash -n "$ROOT/install.sh" "$ROOT/wrapper"
docker compose --project-directory "$TEMP_DIR/app" --env-file "$TEMP_DIR/app/.env" \
  -f "$TEMP_DIR/app/compose.yaml" config --quiet

export WRAPPER_CONFIG_FILE="$TEMP_DIR/config"
export PATH="$TEMP_DIR/bin:$PATH"
"$ROOT/wrapper" status | grep -q 'OK: id'
"$ROOT/wrapper" test | grep -q 'playback manifest received'
"$ROOT/wrapper" test 0 | grep -q 'Playback probe skipped'
if MOCK_FAIL_STATUS=1 "$ROOT/wrapper" status >/dev/null 2>&1; then
  echo "status accepted an unauthenticated wrapper" >&2
  exit 1
fi
if MOCK_FAIL_M3U8=1 "$ROOT/wrapper" test >/dev/null 2>&1; then
  echo "test accepted a failed playlist response" >&2
  exit 1
fi
if "$ROOT/wrapper" test abc >/dev/null 2>&1; then
  echo "test accepted a nonnumeric track ID" >&2
  exit 1
fi
echo "CLI, failure cases, Compose and shell syntax: OK"
