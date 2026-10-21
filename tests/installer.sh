#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/mock-bin"
cat > "$tmp/mock-bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
out=''
url=''
while (( $# )); do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
relative="${url#https://raw.githubusercontent.com/cleitonpin/android-connect/v0.1.1/}"
[[ "$relative" != "$url" && -n "$out" ]]
cp "$ANDROID_CONNECT_TEST_SOURCE/$relative" "$out"
if [[ "${ANDROID_CONNECT_TEST_CORRUPT:-}" == "$relative" ]]; then
  printf 'corrupted\n' >> "$out"
fi
MOCK
chmod +x "$tmp/mock-bin/curl"
export PATH="$tmp/mock-bin:$PATH"
export ANDROID_CONNECT_TEST_SOURCE="$root"
export XDG_DATA_HOME="$tmp/user data"
export XDG_BIN_HOME="$tmp/user bin"

# Simulate curl | bash: installer must work outside a source checkout.
(cd "$tmp"; bash < "$root/install.sh")
target="$(readlink -f "$XDG_BIN_HOME/android-connect")"
[[ "$target" == "$XDG_DATA_HOME/android-connect/versions/v0.1.1/bin/android-connect" ]]
[[ -f "${target%/bin/android-connect}/src/AndroidConnect.ps1" ]]
sha256sum "$target" > "$tmp/before"
(cd "$tmp"; bash < "$root/install.sh")
sha256sum "$target" > "$tmp/after"
cmp "$tmp/before" "$tmp/after"

# A damaged download must fail without replacing a working installation.
export ANDROID_CONNECT_TEST_CORRUPT=src/AndroidConnect.ps1
if bash < "$root/install.sh" > "$tmp/failure.log" 2>&1; then
  printf 'installer accepted a corrupted payload\n' >&2
  exit 1
fi
[[ "$(readlink -f "$XDG_BIN_HOME/android-connect")" == "$target" ]]
(cd "${target%/bin/android-connect}"; sha256sum --check SHA256SUMS)
printf 'installer: remote layout, spaces, repeated install and checksum rejection: ok\n'
