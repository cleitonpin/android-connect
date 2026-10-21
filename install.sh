#!/usr/bin/env bash
set -euo pipefail
src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bin/android-connect"
dest="${XDG_BIN_HOME:-$HOME/.local/bin}"
mkdir -p "$dest"
ln -sfn "$src" "$dest/android-connect"
printf 'Instalado em %s/android-connect\n' "$dest"
case ":$PATH:" in *":$dest:"*) ;; *) printf 'Adicione ao PATH: export PATH="%s:$PATH"\n' "$dest";; esac
