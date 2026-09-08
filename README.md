# Wharfinger

See what is listening on localhost, what answers there, and open, kill or restart it.
For macOS. A menu bar app plus a terminal command, no dependencies beyond what ships with macOS.

```
:5173  node        Vite · My App              ~/code/my-app
:8000  python3     Uvicorn · API docs         ~/code/api
:5432  docker:pg   postgres:16
```

## Menu bar app

```
./build.sh --install   # builds Wharfinger.app with swiftc, copies it to ~/Applications and launches it
```

- The icon shows how many dev servers and containers are listening. Click it for the list.
- Each row: port, process, what answers on it (framework · page title), project directory.
- Submenu per server: **Open** in browser, **Copy URL**, **Restart**, **Kill**, **Force Kill**.
- **Restart** stops the process and runs the exact same command again, in the same directory
  with the same environment, in a new Terminal window so you can see its output.
- Docker containers with published ports get their own section: Open, Copy URL, Stop, Restart.
- **Who has port…** looks up a single port and offers Open / Kill. For the "address already in use" moment.
- Notifications when a dev server or container starts or stops. Click a "started" notification to open it.
  Toggle in the menu; macOS asks for notification permission on first launch.
- **⌃⌥P** pops the menu up at the mouse, handy on a notch MacBook when the menu bar is too full to show the icon.
- Pick the menu bar icon under **Icon**. **Start at login** registers it as a login item.

Apps and system processes (Spotify, Dropbox, Control Center …) are folded into an "Apps & system" submenu
so the list stays about your servers. A process counts as an app when its executable lives in
/Applications, /System, /Library or ~/Library.

Requires macOS 13 or newer and the Xcode Command Line Tools (for `swiftc`). Source: `Wharfinger/main.swift`.
`PORTS_DEBUG=1 build/Wharfinger.app/Contents/MacOS/Wharfinger` runs it in the terminal and logs
refreshes, probes and notifications.

## Terminal command

```
./install.sh              # copies ports.py to ~/.local/bin/ports
ports                     # interactive list
ports list [-d]           # plain table (-d hides apps/system processes)
ports who 3000            # who is using :3000? process, cwd, command, what answers (exit 1 if free)
ports open 3000           # open http://localhost:3000
ports kill 3000 [-9]      # kill whatever listens on :3000 (docker stop for containers)
ports restart 3000        # stop and re-run the same command in a new Terminal window
ports restart 3000 --here # same, but run it in this terminal
```

Keys in the interactive list:

| Key | Action |
|-----|--------|
| ↑ ↓ | move |
| Enter / o | open in browser |
| c | copy URL |
| k / K | kill (SIGTERM / SIGKILL), asks first |
| R | restart in a new Terminal window |
| a | toggle all / dev-only |
| / | filter by port, process, command or directory |
| r | refresh (auto-refreshes every 2 s anyway) |
| q | quit |

Green process names are dev servers, yellow are apps/system, cyan are Docker containers.

## How it works

- `lsof -iTCP -sTCP:LISTEN` finds listening sockets; `ps` and `lsof -d cwd` add the command line and working directory.
- Each dev server gets one HTTP GET. The response is matched against ~30 framework fingerprints
  (Vite, Next.js, Nuxt, SvelteKit, Django, FastAPI, Uvicorn, Flask, Express, Jupyter, Ollama …) and the `<title>` is read.
- Docker rows come from `docker ps`, when the daemon is running.
- Restart reads the exact argv and environment of the process via `sysctl KERN_PROCARGS2`,
  writes them to a `.command` script under `~/Library/Application Support/Wharfinger/` and opens it in Terminal.
- Only your own processes can be inspected or killed without sudo.

## License

MIT
