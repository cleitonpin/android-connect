#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/android-connect" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$ANDROID_CONNECT_TEST_ARGS"
if [[ "${1:-connect}" == env ]]; then
  [[ "${ANDROID_CONNECT_TEST_ENV_FAILURE:-0}" == 0 ]] || exit 9
  printf "export ANDROID_ADB_SERVER_PORT='5401'\nexport ADB_SERVER_SOCKET='tcp:localhost:5401'\n"
  exit 0
fi
[[ "${ANDROID_CONNECT_TEST_CONNECT_FAILURE:-0}" == 0 ]] || exit 7
printf 'mock connection validated\n'
MOCK
chmod +x "$tmp/bin/android-connect"
export PATH="$tmp/bin:$PATH"
export ANDROID_CONNECT_TEST_ARGS="$tmp/args"
unset ANDROID_ADB_SERVER_PORT ADB_SERVER_SOCKET
# The same file is installed and emitted by shell-init.
source "$root/src/android-connect.bash"

android-connect
[[ "$ANDROID_ADB_SERVER_PORT" == 5401 && "$ADB_SERVER_SOCKET" == tcp:localhost:5401 ]]
[[ "$(bash -c 'printf "%s|%s" "$ANDROID_ADB_SERVER_PORT" "$ADB_SERVER_SOCKET"')" == '5401|tcp:localhost:5401' ]]

export ANDROID_CONNECT_TEST_CONNECT_FAILURE=1
if android-connect connect; then exit 1; else [[ "$?" == 7 ]]; fi
[[ "$ADB_SERVER_SOCKET" == tcp:localhost:5401 ]]
unset ANDROID_CONNECT_TEST_CONNECT_FAILURE

export ANDROID_CONNECT_TEST_ENV_FAILURE=1
if android-connect fix; then exit 1; else [[ "$?" == 9 ]]; fi
[[ "$ADB_SERVER_SOCKET" == tcp:localhost:5401 ]]
unset ANDROID_CONNECT_TEST_ENV_FAILURE

unset ANDROID_ADB_SERVER_PORT ADB_SERVER_SOCKET
android-connect status --port 5037
[[ ! -v ADB_SERVER_SOCKET && ! -v ANDROID_ADB_SERVER_PORT ]]
grep -Fx -- '--port' "$tmp/args" >/dev/null
grep -Fx -- '5037' "$tmp/args" >/dev/null

android-connect exec -- printf '%s' 'argument with spaces;literal'
grep -Fx -- 'argument with spaces;literal' "$tmp/args" >/dev/null
[[ ! -v ADB_SERVER_SOCKET ]]
printf 'shell integration: session export, child inheritance, failures and argument forwarding: ok\n'
