#!/usr/bin/env bash
set -euo pipefail
version="${ANDROID_CONNECT_VERSION:-v0.1.1}"
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Versao invalida\n' >&2; exit 1; }
for dependency in curl sha256sum awk; do
  command -v "$dependency" >/dev/null || { printf 'Dependencia ausente: %s\n' "$dependency" >&2; exit 1; }
done
base="https://raw.githubusercontent.com/cleitonpin/android-connect/$version"
data="${XDG_DATA_HOME:-$HOME/.local/share}/android-connect"
dest="${XDG_BIN_HOME:-$HOME/.local/bin}"
mkdir -p "$data/versions" "$dest"
stage="$(mktemp -d "$data/versions/.stage-XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
download() {
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 30 --output "$stage/$1" "$base/$1"
}
download SHA256SUMS
files=(src/AndroidConnect.ps1 src/AndroidConnect.Core.psm1 bin/android-connect bin/android-connect.ps1)
for file in "${files[@]}"; do
  mkdir -p "$(dirname -- "$stage/$file")"
  expected="$(awk -v file="$file" '$2 == file { print $1 }' "$stage/SHA256SUMS")"
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || { printf 'SHA256 ausente/invalido: %s\n' "$file" >&2; exit 1; }
  download "$file"
  actual="$(sha256sum "$stage/$file")"
  [[ "${actual%% *}" == "$expected" ]] || { printf 'SHA256 divergente: %s\n' "$file" >&2; exit 1; }
done
chmod 700 "$stage/bin/android-connect"
release="$data/versions/$version"
if [[ -e "$release" ]]; then
  for file in "${files[@]}"; do
    cmp -- "$release/$file" "$stage/$file" >/dev/null || { printf 'Instalacao existente difere da versao %s: %s\n' "$version" "$file" >&2; exit 1; }
  done
else
  mv -- "$stage" "$release"
fi
ln -sfn -- "$release/bin/android-connect" "$dest/android-connect"
printf 'Android Connect %s instalado em %s/android-connect\n' "$version" "$dest"
case ":$PATH:" in *":$dest:"*) ;; *) printf 'Adicione a sessao: export PATH="%s:$PATH"\n' "$dest";; esac
