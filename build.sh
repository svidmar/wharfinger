#!/bin/sh
# Builds Portkeeper.app. With --install, copies it to ~/Applications and launches it.
set -e
cd "$(dirname "$0")"
app="build/Portkeeper.app"
rm -rf build
mkdir -p "$app/Contents/MacOS"
swiftc -O -o "$app/Contents/MacOS/Portkeeper" Portkeeper/main.swift
cp Portkeeper/Info.plist "$app/Contents/"
codesign --force --sign - "$app"
echo "built $app"
if [ "$1" = "--install" ]; then
    pkill -x Portkeeper 2>/dev/null || true
    pkill -x Ports 2>/dev/null || true          # the app's old name
    rm -rf ~/Applications/Ports.app
    mkdir -p ~/Applications
    rm -rf ~/Applications/Portkeeper.app
    cp -R "$app" ~/Applications/
    open ~/Applications/Portkeeper.app
    echo "installed and launched ~/Applications/Portkeeper.app"
fi
