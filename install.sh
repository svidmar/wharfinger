#!/bin/sh
# Installs the `wharf` terminal command into ~/.local/bin (or the directory given as first argument).
set -e
dest="${1:-$HOME/.local/bin}"
mkdir -p "$dest"
cp "$(dirname "$0")/wharf.py" "$dest/wharf"
chmod +x "$dest/wharf"
rm -f "$dest/ports"   # the command's old name
echo "installed $dest/wharf"
case ":$PATH:" in *":$dest:"*) ;; *) echo "note: $dest is not on your PATH" ;; esac
