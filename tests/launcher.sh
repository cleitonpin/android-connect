#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/user-bin"
ln -s "$root/bin/android-connect" "$tmp/user-bin/android-connect"
cat > "$tmp/wslpath" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' 'C:\android-connect\src\AndroidConnect.ps1'
MOCK
cat > "$tmp/powershell.exe" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ANDROID_CONNECT_TEST_ARGS"
MOCK
chmod +x "$tmp/wslpath" "$tmp/powershell.exe"
export PATH="$tmp:$PATH"
export ANDROID_CONNECT_TEST_ARGS="$tmp/args"
"$tmp/user-bin/android-connect" doctor --json --output 'report with spaces.json' --distro Ubuntu
grep -Fx -- '-Json' "$tmp/args" >/dev/null
grep -Fx -- '-OutputPath' "$tmp/args" >/dev/null
grep -Fx -- 'report with spaces.json' "$tmp/args" >/dev/null
grep -Fx -- '-Distro' "$tmp/args" >/dev/null
grep -Fx -- 'Ubuntu' "$tmp/args" >/dev/null
grep -Fx -- 'doctor' "$tmp/args" >/dev/null
"$tmp/user-bin/android-connect" exec -- npx expo run:android --device 'serial with spaces' --flag='a;b'
grep -Fx -- '--device' "$tmp/args" >/dev/null
grep -Fx -- 'serial with spaces' "$tmp/args" >/dev/null
grep -Fx -- '--flag=a;b' "$tmp/args" >/dev/null
printf 'launcher argument mapping: ok\n'
