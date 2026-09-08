# local-dev

Small macOS helpers for local development.

## ports

See which processes are listening on localhost, open them in the browser, or kill them.
Pure Python 3 + macOS `lsof`/`ps`, no dependencies.

```
./install.sh          # copies ports.py to ~/.local/bin/ports
ports                 # interactive list
ports list [-d]       # plain table (-d hides system/app processes)
ports who 3000        # who is using :3000? process, cwd, command, what answers (exit 1 if free)
ports open 3000       # open http://localhost:3000
ports kill 3000 [-9]  # kill whatever listens on :3000 (or stop the docker container)
```

Every dev server gets one HTTP GET so the list can show what answers: framework
(Vite, Next.js, Uvicorn, Flask, Express …) and the page title. Running Docker containers
with published ports are listed as `docker:<name>` rows; kill on those runs `docker stop`.

Keys in the interactive list:

| Key | Action |
|-----|--------|
| ↑ ↓ | move |
| Enter / o | open in browser |
| c | copy URL to clipboard |
| k | kill (SIGTERM, asks first) |
| K | force kill (SIGKILL, asks first) |
| a | toggle all / dev-only (hides apps in /Applications, /System, ~/Library …) |
| / | filter by port, process, command or directory |
| r | refresh (auto-refreshes every 2 s anyway) |
| q | quit |

Green process names are dev servers, yellow are apps/system. The last column shows the
process working directory, which is usually the project the server belongs to.

## Ports.app (menu bar)

The same thing as a native menu bar app, built with plain `swiftc` (no Xcode project, no dependencies).

```
./build.sh --install   # builds build/Ports.app, copies to ~/Applications and launches it
```

- The icon shows a count of dev servers and containers. Click it for the list.
- Each row shows port, process, what answers on it (framework · page title) and the project directory.
- Each server has a submenu: Open in browser, Copy URL, Kill, Force Kill.
- Docker containers with published ports get their own section, with Open, Copy URL, Stop and Restart.
- "Who has port…" looks up a single port and offers Open / Kill, for the "address already in use" moment.
- Notifications when a dev server or container starts or stops (toggle in the menu). Clicking a
  "started" notification opens it in the browser. macOS asks for notification permission on first launch.
- Apps and system processes (Spotify, Dropbox, ControlCenter …) live in a collapsed "Apps & system" submenu.
- "Start at login" registers it as a login item. "Quit Ports" removes it from the menu bar.
- The list is rebuilt every time the menu opens, and the count refreshes every 15 s.
- ⌃⌥P pops the menu up at the mouse, handy on a notch MacBook when the menu bar is too full to show the icon.

Source is in `Ports/main.swift`. Re-run `./build.sh --install` after changes.
`PORTS_DEBUG=1 build/Ports.app/Contents/MacOS/Ports` runs it in the terminal and logs refreshes, probes and notifications.
