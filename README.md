# local-dev

Small macOS helpers for local development.

## ports

See which processes are listening on localhost, open them in the browser, or kill them.
Pure Python 3 + macOS `lsof`/`ps`, no dependencies.

```
./install.sh          # copies ports.py to ~/.local/bin/ports
ports                 # interactive list
ports list [-d]       # plain table (-d hides system/app processes)
ports open 3000       # open http://localhost:3000
ports kill 3000 [-9]  # kill whatever listens on :3000
```

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
