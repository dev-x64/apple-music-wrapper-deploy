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
      if [[ "${MOCK_FAIL_STATUS:-0}" == 1 && ! -e "${MOCK_HEALTHY_FLAG:-/nonexistent}" ]]; then
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

# docker mock: logs every call; "compose up" or "run --login" can make the API healthy.
cat > "$TEMP_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
case " $* " in
  *" compose "*" up "*) [[ "${MOCK_RESTART_FIXES:-0}" != 1 ]] || touch "$MOCK_HEALTHY_FLAG" ;;
  *" run "*"--login "*) [[ "${MOCK_LOGIN_FIXES:-0}" != 1 ]] || touch "$MOCK_HEALTHY_FLAG" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$TEMP_DIR/bin/sleep"
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$TEMP_DIR/bin/timeout"
# iptables/ip6tables mocks: -C succeeds once -I has inserted the rule.
cat > "$TEMP_DIR/bin/iptables" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s %s\n' "$name" "$*" >> "$MOCK_IPTABLES_LOG"
case " $* " in
  *" -C "*) [[ -e "$MOCK_IPTABLES_STATE.$name" ]] ;;
  *" -I "*) touch "$MOCK_IPTABLES_STATE.$name" ;;
esac
EOF
cp "$TEMP_DIR/bin/iptables" "$TEMP_DIR/bin/ip6tables"
chmod +x "$TEMP_DIR/bin/docker" "$TEMP_DIR/bin/sleep" "$TEMP_DIR/bin/timeout" \
  "$TEMP_DIR/bin/iptables" "$TEMP_DIR/bin/ip6tables"

bash -n "$ROOT/install.sh" "$ROOT/wrapper"
grep -q '@INTERVAL@' "$ROOT/wrapper-watchdog.timer.template"
grep -q '^ExecStart=/usr/local/bin/wrapper watchdog run$' "$ROOT/wrapper-watchdog.service"
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

export WRAPPER_TEST_MODE=1
export WRAPPER_STATE_DIR="$TEMP_DIR/state"
export WRAPPER_LOCK_FILE="$TEMP_DIR/lock"
export WRAPPER_CREDENTIALS_FILE="$TEMP_DIR/credentials"
export MOCK_DOCKER_LOG="$TEMP_DIR/docker.log"
export MOCK_HEALTHY_FLAG="$TEMP_DIR/healthy"
reset_watchdog() { rm -rf "$WRAPPER_STATE_DIR" "$MOCK_HEALTHY_FLAG" "$WRAPPER_CREDENTIALS_FILE"; : > "$MOCK_DOCKER_LOG"; }
fail() { echo "watchdog: $*" >&2; exit 1; }

reset_watchdog
"$ROOT/wrapper" watchdog run >/dev/null || fail "healthy wrapper reported as failed"
[[ ! -s "$MOCK_DOCKER_LOG" ]] || fail "healthy wrapper was restarted"

reset_watchdog
MOCK_FAIL_STATUS=1 MOCK_RESTART_FIXES=1 "$ROOT/wrapper" watchdog run >/dev/null ||
  fail "restart did not recover"
grep -q 'compose .* up -d --force-recreate wrapper' "$MOCK_DOCKER_LOG" || fail "no restart"
! grep -q -- '--login' "$MOCK_DOCKER_LOG" || fail "logged in although restart was enough"

reset_watchdog
if MOCK_FAIL_STATUS=1 "$ROOT/wrapper" watchdog run >/dev/null; then
  fail "reported success without credentials"
fi
! grep -q -- '--login' "$MOCK_DOCKER_LOG" || fail "logged in without saved credentials"

reset_watchdog
printf '%s\n%s\n' 'user@example.com' 'p@ss word' > "$WRAPPER_CREDENTIALS_FILE"
MOCK_FAIL_STATUS=1 MOCK_LOGIN_FIXES=1 "$ROOT/wrapper" watchdog run >/dev/null ||
  fail "re-login did not recover"
grep -q -- '--login user@example.com:p@ss word --base-dir /data' "$MOCK_DOCKER_LOG" ||
  fail "re-login used wrong credentials"
rm -f "$MOCK_HEALTHY_FLAG"; : > "$MOCK_DOCKER_LOG"
if MOCK_FAIL_STATUS=1 MOCK_LOGIN_FIXES=1 "$ROOT/wrapper" watchdog run >/dev/null; then
  fail "second re-login was not rate-limited"
fi
! grep -q -- '--login' "$MOCK_DOCKER_LOG" || fail "re-login cooldown ignored"

reset_watchdog
printf 'user@example.com\nsecret\n' > "$WRAPPER_CREDENTIALS_FILE"
"$ROOT/wrapper" forget-credentials >/dev/null
[[ ! -e "$WRAPPER_CREDENTIALS_FILE" ]] || fail "forget-credentials kept the file"

export MOCK_IPTABLES_LOG="$TEMP_DIR/iptables.log"
export MOCK_IPTABLES_STATE="$TEMP_DIR/iptables-rule"
rule='INPUT -p tcp --dport 12340 -m comment --comment apple-music-wrapper -j ACCEPT'
"$ROOT/wrapper" firewall >/dev/null
grep -q "^iptables -w -I $rule$" "$MOCK_IPTABLES_LOG" || fail "iptables rule not inserted"
grep -q "^ip6tables -w -I $rule$" "$MOCK_IPTABLES_LOG" || fail "ip6tables rule not inserted"
: > "$MOCK_IPTABLES_LOG"
output="$("$ROOT/wrapper" firewall)"
grep -q 'already allowed' <<<"$output" || fail "existing rule not detected"
! grep -q -- ' -I ' "$MOCK_IPTABLES_LOG" || fail "rule inserted twice"
reset_watchdog; rm -f "$MOCK_IPTABLES_STATE".*; : > "$MOCK_IPTABLES_LOG"
FIREWALL=iptables "$ROOT/wrapper" watchdog run >/dev/null || fail "watchdog failed with iptables"
grep -q "^iptables -w -I $rule$" "$MOCK_IPTABLES_LOG" || fail "watchdog did not restore the rule"
: > "$MOCK_IPTABLES_LOG"
"$ROOT/wrapper" watchdog run >/dev/null
[[ ! -s "$MOCK_IPTABLES_LOG" ]] || fail "watchdog touched iptables although FIREWALL is not iptables"

echo "CLI, watchdog, firewall, failure cases, Compose and shell syntax: OK"
