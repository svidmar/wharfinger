#!/bin/sh
# Builds Ports.app. With --install, copies it to ~/Applications and launches it.
set -e
cd "$(dirname "$0")"
app="build/Ports.app"
rm -rf build
mkdir -p "$app/Contents/MacOS"
swiftc -O -o "$app/Contents/MacOS/Ports" Ports/main.swift
cp Ports/Info.plist "$app/Contents/"
codesign --force --sign - "$app"
echo "built $app"
if [ "$1" = "--install" ]; then
    pkill -x Ports 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Ports.app
    cp -R "$app" ~/Applications/
    open ~/Applications/Ports.app
    echo "installed and launched ~/Applications/Ports.app"
fi
