#!/bin/sh
# Builds Wharfinger.app from source. With --install, copies it to ~/Applications and launches it.
#
#   ./build.sh --install
#
# Needs only the Xcode Command Line Tools (for swiftc): xcode-select --install
set -e
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
    echo "swiftc not found. Install the Xcode Command Line Tools first:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi

app="build/Wharfinger.app"
rm -rf build
mkdir -p "$app/Contents/MacOS"
echo "compiling Wharfinger/main.swift …"
swiftc -O -o "$app/Contents/MacOS/Wharfinger" Wharfinger/main.swift
cp Wharfinger/Info.plist "$app/Contents/"
# Ad-hoc signature: enough to run on the machine that built it. A downloaded copy would need notarisation.
codesign --force --sign - "$app" 2>/dev/null
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
    echo "tip: ./install.sh puts the 'ports' command in ~/.local/bin"
fi
