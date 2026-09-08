#!/bin/sh
# Installs `ports` into ~/.local/bin (already on PATH on this machine).
set -e
dest="${1:-$HOME/.local/bin}"
mkdir -p "$dest"
cp "$(dirname "$0")/ports.py" "$dest/ports"
chmod +x "$dest/ports"
echo "installed $dest/ports"
