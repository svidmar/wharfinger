#!/bin/sh
# Builds Wharfinger.app. With --install, copies it to ~/Applications and launches it.
set -e
cd "$(dirname "$0")"
app="build/Wharfinger.app"
rm -rf build
mkdir -p "$app/Contents/MacOS"
swiftc -O -o "$app/Contents/MacOS/Wharfinger" Wharfinger/main.swift
cp Wharfinger/Info.plist "$app/Contents/"
codesign --force --sign - "$app"
echo "built $app"
if [ "$1" = "--install" ]; then
    pkill -x Wharfinger 2>/dev/null || true
    pkill -x Ports 2>/dev/null || true; pkill -x Portkeeper 2>/dev/null || true   # old names
    rm -rf ~/Applications/Ports.app ~/Applications/Portkeeper.app
    mkdir -p ~/Applications
    rm -rf ~/Applications/Wharfinger.app
    cp -R "$app" ~/Applications/
    open ~/Applications/Wharfinger.app
    echo "installed and launched ~/Applications/Wharfinger.app"
fi
