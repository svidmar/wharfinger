#!/usr/bin/env python3
"""ports - see, open and kill local listening servers on macOS.

Usage:
  ports                 interactive list (arrow keys, Enter/o = open, k = kill)
  ports list [-d]       plain table (-d hides system/app processes)
  ports who PORT        who is using PORT? (exit 1 if free)
  ports open PORT       open http://localhost:PORT in the browser
  ports kill PORT [-9]  kill the process (or stop the container) listening on PORT
  ports restart PORT    stop it and start the same command again (same cwd and env)
                        in a new Terminal window; --here runs it in this terminal instead

Docker containers with published ports are listed too, when the daemon runs.
Each dev server is probed with one HTTP GET to show the framework / page title.
No dependencies beyond macOS's lsof/ps and Python 3.
"""

import ctypes
import curses
import html
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

HOME = os.path.expanduser("~")
DOCKER = next((p for p in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", HOME + "/.docker/bin/docker",
                           "/Applications/Docker.app/Contents/Resources/bin/docker"] if os.access(p, os.X_OK)), shutil.which("docker"))

# Executable locations that are almost certainly not your dev servers.
SYSTEM_PREFIXES = (
    "/System/",
    "/usr/libexec/",
    "/usr/sbin/",
    "/Library/",
    "/Applications/",
    HOME + "/Library/",
    "/private/var/",
)


@dataclass
class Entry:
    port: int
    addr: str
    pid: int
    name: str
    cmd: str
    cwd: str
    system: bool
    container: str = ""   # docker container id, when this row is a container
    label: str = ""       # what answered the HTTP probe

    @property
    def key(self) -> str:
        return f"{self.container or self.pid}:{self.port}"

    @property
    def url(self) -> str:
        host = self.addr
        if host in ("*", "0.0.0.0", "127.0.0.1", "::", "::1", "[::]", "[::1]", "localhost"):
            host = "localhost"
        return f"http://{host}:{self.port}"


def _run(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, check=False).stdout
    except FileNotFoundError:
        return ""


def _tilde(path: str) -> str:
    if path == HOME or path.startswith(HOME + "/"):
        return "~" + path[len(HOME):]
    return path


def _is_system(cmd: str, name: str) -> bool:
    exe = cmd.split(" ", 1)[0] if cmd else name
    if ".app/Contents/" in exe:
        return True
    return exe.startswith(SYSTEM_PREFIXES)


def collect(include_system: bool = True):
    """Return one Entry per (pid, port) that is listening on TCP."""
    out = _run(["lsof", "-iTCP", "-sTCP:LISTEN", "-P", "-n", "+c", "0", "-F", "pcn"])
    seen = {}
    pid = None
    name = ""
    for line in out.splitlines():
        tag, val = line[0], line[1:]
        if tag == "p":
            pid = int(val)
        elif tag == "c":
            name = val
        elif tag == "n" and pid is not None:
            addr, _, port = val.rpartition(":")
            if not port.isdigit():
                continue
            port = int(port)
            key = (pid, port)
            # IPv4 + IPv6 on the same port collapse to one row; prefer the wildcard.
            if key in seen and seen[key].addr in ("*", "0.0.0.0", "::"):
                continue
            seen[key] = Entry(port, addr, pid, name, "", "", False)

    if not seen:
        return []

    pids = sorted({e.pid for e in seen.values()})
    pid_list = ",".join(map(str, pids))

    cmds = {}
    for line in _run(["ps", "-o", "pid=,command=", "-p", pid_list]).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            cmds[int(parts[0])] = parts[1]

    cwds = {}
    cur = None
    for line in _run(["lsof", "-a", "-p", pid_list, "-d", "cwd", "-F", "pn"]).splitlines():
        if line[0] == "p":
            cur = int(line[1:])
        elif line[0] == "n" and cur is not None:
            cwds[cur] = line[1:]

    entries = []
    for e in seen.values():
        e.cmd = cmds.get(e.pid, "")
        e.cwd = _tilde(cwds.get(e.pid, ""))
        e.system = _is_system(e.cmd, e.name)
        if include_system or not e.system:
            entries.append(e)

    entries.sort(key=lambda e: (e.port, e.pid))
    return entries


def collect_docker():
    """One Entry per published host port of each running container."""
    if not DOCKER:
        return []
    out = _run([DOCKER, "ps", "--format", "{{json .}}"])
    entries = []
    for line in out.splitlines():
        try:
            c = json.loads(line)
        except ValueError:
            continue
        seen = set()
        for host, cport, proto in re.findall(r"(?:[\d.]+|\[?::\]?):(\d+)->(\d+)/(\w+)", c.get("Ports", "")):
            if host in seen:
                continue
            seen.add(host)
            entries.append(Entry(int(host), "0.0.0.0", 0, "docker:" + c.get("Names", "?"),
                                 f"{c.get('Image', '')}  ({c.get('Status', '')})", "", False, c.get("ID", "")))
    return entries


def collect_all(include_system: bool = True):
    docker = collect_docker()
    docker_ports = {e.port for e in docker}
    procs = [e for e in collect(include_system)
             if not (e.port in docker_ports and "docker" in e.name.lower())]
    return sorted(procs + docker, key=lambda e: (e.port, e.pid))


FRAMEWORK_HINTS = [
    ("Vite", lambda b, sv, pw: "/@vite/client" in b or "@vite/client" in b),
    ("Next.js", lambda b, sv, pw: "/_next/" in b or "next.js" in pw),
    ("Nuxt", lambda b, sv, pw: "__nuxt" in b),
    ("SvelteKit", lambda b, sv, pw: "__sveltekit" in b),
    ("Remix", lambda b, sv, pw: "__remixcontext" in b),
    ("Astro", lambda b, sv, pw: "astro-island" in b or "/_astro/" in b),
    ("Angular", lambda b, sv, pw: "ng-version" in b),
    ("Storybook", lambda b, sv, pw: "storybook" in b),
    ("Streamlit", lambda b, sv, pw: "streamlit" in b),
    ("Gradio", lambda b, sv, pw: "gradio" in b),
    ("Jupyter", lambda b, sv, pw: "jupyter" in b),
    ("Ollama", lambda b, sv, pw: "ollama is running" in b),
    ("Grafana", lambda b, sv, pw: "grafana" in b),
    ("Swagger UI", lambda b, sv, pw: "swagger-ui" in b),
    ("Django", lambda b, sv, pw: "django" in b or "wsgiserver" in sv),
    ("FastAPI", lambda b, sv, pw: "fastapi" in b),
    ("Uvicorn", lambda b, sv, pw: "uvicorn" in sv),
    ("Flask", lambda b, sv, pw: "werkzeug" in sv),
    ("Express", lambda b, sv, pw: "express" in pw),
    ("PHP", lambda b, sv, pw: "php" in pw),
    ("Rails", lambda b, sv, pw: "csrf-param" in b and "rails" in b),
    ("Phoenix", lambda b, sv, pw: "phoenix" in b and "csrf" in b),
    ("MkDocs", lambda b, sv, pw: "mkdocs" in b),
    ("Docusaurus", lambda b, sv, pw: "docusaurus" in b),
    ("Hugo", lambda b, sv, pw: 'generator" content="hugo' in b),
    ("Jekyll", lambda b, sv, pw: 'generator" content="jekyll' in b),
    ("Python http.server", lambda b, sv, pw: "simplehttp" in sv),
    ("Webpack dev server", lambda b, sv, pw: "webpack" in b),
]


def probe(url: str, timeout: float = 1.5) -> str:
    """One GET; returns 'Framework · Page title' or '' when nothing HTTP answers."""
    req = urllib.request.Request(url, headers={"User-Agent": "ports/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            status, headers, body = r.status, r.headers, r.read(200_000).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        status, headers, body = e.code, e.headers, e.read(200_000).decode("utf-8", "replace")
    except Exception:
        return ""
    lower = body.lower()
    sv = (headers.get("Server") or "").lower()
    pw = (headers.get("X-Powered-By") or "").lower()
    framework = next((name for name, test in FRAMEWORK_HINTS if test(lower, sv, pw)), "")
    if not framework and sv:
        framework = sv.split("/")[0].capitalize()
    m = re.search(r"<title[^>]*>\s*(.*?)\s*</title>", body, re.I | re.S)
    title = html.unescape(re.sub(r"\s+", " ", m.group(1))).strip() if m else ""
    if len(title) > 45:
        title = title[:44] + "…"
    if not title and not framework and "json" in (headers.get("Content-Type") or ""):
        framework = "JSON API"
    parts = [p for p in (framework, title) if p]
    if not parts:
        return f"HTTP {status}"
    if status >= 400:
        parts.append(f"({status})")
    return " · ".join(parts)


def probe_all(entries, only_dev: bool = True):
    targets = [e for e in entries if not e.system or not only_dev]
    if not targets:
        return
    with ThreadPoolExecutor(max_workers=8) as ex:
        for e, label in zip(targets, ex.map(lambda e: probe(e.url), targets)):
            e.label = label


def open_url(entry: Entry):
    subprocess.Popen(["open", entry.url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def copy_url(entry: Entry):
    subprocess.run(["pbcopy"], input=entry.url, text=True, check=False)


def kill(entry: Entry, force: bool = False) -> str:
    if entry.container:
        verb = "kill" if force else "stop"
        _run([DOCKER, verb, entry.container])
        return f"docker {verb} {entry.name[7:]} (:{entry.port})"
    sig = signal.SIGKILL if force else signal.SIGTERM
    try:
        os.kill(entry.pid, sig)
    except ProcessLookupError:
        return f"pid {entry.pid} already gone"
    except PermissionError:
        return f"no permission to kill pid {entry.pid} (try sudo)"
    # Give it a moment so the refresh reflects reality.
    for _ in range(20):
        time.sleep(0.05)
        try:
            os.kill(entry.pid, 0)
        except ProcessLookupError:
            return f"killed {entry.name} (pid {entry.pid}) on :{entry.port}"
    return f"sent {'SIGKILL' if force else 'SIGTERM'} to pid {entry.pid}, still running (try K)"


def proc_args_env(pid: int):
    """Exact argv and environment of one of our own processes (sysctl KERN_PROCARGS2)."""
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or size.value <= 4:
        return None
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return None
    raw = buf.raw[: size.value]
    argc = int.from_bytes(raw[:4], sys.byteorder)
    i = raw.index(b"\0", 4)          # end of exec path
    while i < len(raw) and raw[i:i + 1] == b"\0":
        i += 1
    strings = [x.decode("utf-8", "replace") for x in raw[i:].split(b"\0") if x]
    if argc <= 0 or len(strings) < argc:
        return None
    env = dict(x.split("=", 1) for x in strings[argc:] if "=" in x)
    return strings[:argc], env


SKIP_ENV_PREFIXES = ("TERM", "SHLVL", "PWD", "OLDPWD", "_", "__CF", "XPC_", "TMPDIR", "SECURITYSESSIONID", "COMMAND_MODE", "LaunchInstanceID", "SSH_")


def sh_quote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


def write_restart_script(argv, env, cwd: str, port: int) -> str:
    d = os.path.join(HOME, "Library", "Application Support", "Portkeeper")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, f"restart-{port}.command")
    lines = ["#!/bin/sh", f"# Portkeeper restart of :{port}", f"cd {sh_quote(cwd)} || exit 1"]
    for k in sorted(env):
        if not k.startswith(SKIP_ENV_PREFIXES):
            lines.append(f"export {k}={sh_quote(env[k])}")
    lines.append("echo " + sh_quote(f"Portkeeper: restarting {' '.join(argv)} in {cwd}"))
    lines.append("exec " + " ".join(sh_quote(a) for a in argv))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(path, 0o755)
    return path


def restart(entry: Entry, here: bool = False) -> str:
    """Kill the process and re-run its exact command in its cwd with its env."""
    if entry.container:
        _run([DOCKER, "restart", entry.container])
        return f"docker restart {entry.name[7:]} (:{entry.port})"
    got = proc_args_env(entry.pid)
    if not got:
        return f"cannot read the command line of pid {entry.pid} (only your own processes can be restarted)"
    argv, env = got
    cwd = os.path.expanduser(entry.cwd) if entry.cwd else HOME
    script = write_restart_script(argv, env, cwd, entry.port)
    msg = kill(entry, False)
    if "still running" in msg:
        kill(entry, True)
        time.sleep(0.3)
    if here:
        os.execv("/bin/sh", ["/bin/sh", script])
    subprocess.run(["open", "-b", "com.apple.terminal", script], check=False)
    return f"restarting {entry.name} on :{entry.port} in a new Terminal window"


def short_cmd(cmd: str, width: int) -> str:
    parts = cmd.split(" ")
    parts[0] = os.path.basename(parts[0]) or parts[0]
    s = " ".join(_tilde(p) for p in parts)
    return s if len(s) <= width else s[: max(0, width - 1)] + "…"


# ----------------------------------------------------------------- CLI modes


def cmd_list(include_system: bool):
    entries = collect_all(include_system)
    if not entries:
        print("nothing listening" + ("" if include_system else " (drop -d to include system/app processes)"))
        return
    probe_all(entries)
    print(f"{'PORT':>5}  {'ADDR':<15} {'PID':>6}  {'PROCESS':<20} {'ANSWERS':<32} {'CWD / COMMAND'}")
    for e in entries:
        where = e.cwd or short_cmd(e.cmd, 60)
        pid = "-" if e.container else str(e.pid)
        print(f"{e.port:>5}  {e.addr:<15} {pid:>6}  {e.name[:20]:<20} {e.label[:32]:<32} {where}")


def find_port(port: int):
    for e in collect_all(True):
        if e.port == port:
            return e
    return None


def cmd_who(port: int):
    e = find_port(port)
    if e is None:
        print(f"port {port} is free")
        sys.exit(1)
    e.label = probe(e.url)
    if e.container:
        print(f"port {port} is published by docker container {e.name[7:]}")
        print(f"  image:   {e.cmd}")
        print(f"  id:      {e.container}")
    else:
        print(f"port {port} is used by {e.name} (pid {e.pid}) on {e.addr}:{e.port}")
        if e.cwd:
            print(f"  cwd:     {e.cwd}")
        if e.cmd:
            print(f"  command: {short_cmd(e.cmd, 200)}")
    if e.label:
        print(f"  answers: {e.label}")
    print(f"  url:     {e.url}")
    print(f"  free it: ports kill {port}")


def cmd_open(port: int):
    e = find_port(port)
    if e is None:
        print(f"nothing listening on :{port}", file=sys.stderr)
        sys.exit(1)
    open_url(e)
    print(e.url)


def cmd_kill(port: int, force: bool):
    e = find_port(port)
    if e is None:
        print(f"nothing listening on :{port}", file=sys.stderr)
        sys.exit(1)
    print(kill(e, force))


def cmd_restart(port: int, here: bool):
    e = find_port(port)
    if e is None:
        print(f"nothing listening on :{port}", file=sys.stderr)
        sys.exit(1)
    print(restart(e, here))


# ----------------------------------------------------------------- TUI


HELP = "↑↓ move  ⏎/o open  c copy url  k kill  K kill -9  R restart  a all/dev-only  / filter  r refresh  q quit"


def tui(stdscr):
    curses.curs_set(0)
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_CYAN, -1)
    curses.init_pair(2, curses.COLOR_YELLOW, -1)
    curses.init_pair(3, curses.COLOR_GREEN, -1)
    curses.init_pair(4, curses.COLOR_RED, -1)
    curses.init_pair(5, -1, -1)
    stdscr.timeout(2000)  # auto refresh every 2s when idle

    include_system = True
    query = ""
    sel = 0
    top = 0
    status = ""
    status_at = 0.0
    labels = {}  # entry.key -> (label, time)
    entries = collect_all(include_system)

    def probe_missing():
        now = time.time()
        todo = [e for e in entries if not e.system and (e.key not in labels or now - labels[e.key][1] > (120 if labels[e.key][0] else 30))]
        if todo:
            probe_all(todo)
            for e in todo:
                labels[e.key] = (e.label, now)
        for e in entries:
            e.label = labels.get(e.key, ("", 0))[0]

    probe_missing()

    def visible():
        if not query:
            return entries
        q = query.lower()
        return [e for e in entries if q in f"{e.port} {e.addr} {e.name} {e.cmd} {e.cwd}".lower()]

    def refresh_data():
        nonlocal entries
        entries = collect_all(include_system)
        probe_missing()

    def set_status(msg):
        nonlocal status, status_at
        status, status_at = msg, time.time()

    def ask(prompt: str) -> bool:
        h, w = stdscr.getmaxyx()
        stdscr.move(h - 1, 0)
        stdscr.clrtoeol()
        stdscr.addnstr(h - 1, 0, prompt + " [y/N] ", w - 1, curses.color_pair(4) | curses.A_BOLD)
        stdscr.refresh()
        stdscr.timeout(-1)
        ch = stdscr.getch()
        stdscr.timeout(2000)
        return ch in (ord("y"), ord("Y"))

    def read_query():
        nonlocal query
        curses.curs_set(1)
        stdscr.timeout(-1)
        buf = query
        while True:
            h, w = stdscr.getmaxyx()
            stdscr.move(h - 1, 0)
            stdscr.clrtoeol()
            stdscr.addnstr(h - 1, 0, "/" + buf, w - 1)
            stdscr.refresh()
            ch = stdscr.getch()
            if ch in (10, 13):
                query = buf
                break
            if ch == 27:
                break
            if ch in (curses.KEY_BACKSPACE, 127, 8):
                buf = buf[:-1]
            elif 32 <= ch < 127:
                buf += chr(ch)
        stdscr.timeout(2000)
        curses.curs_set(0)

    while True:
        rows = visible()
        if rows:
            sel = max(0, min(sel, len(rows) - 1))
        else:
            sel = 0
        h, w = stdscr.getmaxyx()
        list_h = max(1, h - 3)
        if sel < top:
            top = sel
        elif sel >= top + list_h:
            top = sel - list_h + 1

        stdscr.erase()
        mode = "all" if include_system else "dev"
        title = f" ports  ·  {len(rows)} listening  ·  {mode}"
        if query:
            title += f"  ·  /{query}"
        stdscr.addnstr(0, 0, title.ljust(w), w - 1, curses.A_REVERSE)

        name_w = 18
        addr_w = 15
        rest_w = max(10, w - (6 + 2 + addr_w + 1 + 7 + 2 + name_w + 1) - 1)
        header = f"{'PORT':>6}  {'ADDR':<{addr_w}} {'PID':>7}  {'PROCESS':<{name_w}} {'ANSWERS  ·  CWD  ·  COMMAND'}"
        stdscr.addnstr(1, 0, header, w - 1, curses.A_BOLD)

        if not rows:
            msg = "nothing listening" if entries or include_system else "no dev servers found  ·  press a to show all"
            stdscr.addnstr(2, 2, msg, w - 3, curses.A_DIM)

        for i, e in enumerate(rows[top : top + list_h]):
            y = 2 + i
            selected = (top + i) == sel
            attr = curses.A_REVERSE if selected else 0
            where = e.cwd
            cmd = short_cmd(e.cmd, rest_w)
            tail = "  ·  ".join(p for p in (e.label, where, cmd) if p)
            if len(tail) > rest_w:
                tail = tail[: rest_w - 1] + "…"
            pid = "-" if e.container else str(e.pid)
            line = f"{e.port:>6}  {e.addr:<{addr_w}} {pid:>7}  {e.name[:name_w]:<{name_w}} {tail}"
            if selected:
                stdscr.addnstr(y, 0, line.ljust(w), w - 1, attr)
            else:
                stdscr.addnstr(y, 0, f"{e.port:>6}", w - 1, curses.color_pair(1) | curses.A_BOLD)
                stdscr.addnstr(y, 8, f"{e.addr:<{addr_w}}", w - 9, curses.A_DIM)
                stdscr.addnstr(y, 8 + addr_w + 1, f"{pid:>7}", w - 9 - addr_w - 1, curses.A_DIM)
                x = 8 + addr_w + 1 + 7 + 2
                if x < w - 1:
                    stdscr.addnstr(y, x, f"{e.name[:name_w]:<{name_w}}", w - x - 1, curses.color_pair(1) if e.container else curses.color_pair(2) if e.system else curses.color_pair(3))
                x += name_w + 1
                if x < w - 1:
                    stdscr.addnstr(y, x, tail, w - x - 1)

        footer = status if status and time.time() - status_at < 5 else HELP
        stdscr.addnstr(h - 1, 0, footer[: w - 1], w - 1, curses.A_DIM if footer is HELP else curses.color_pair(3) | curses.A_BOLD)
        stdscr.refresh()

        ch = stdscr.getch()
        if ch == -1:
            refresh_data()
            continue
        if ch in (ord("q"), 27):
            break
        elif ch in (curses.KEY_DOWN, ord("j")):
            sel += 1
        elif ch == curses.KEY_UP:
            sel -= 1
        elif ch == curses.KEY_NPAGE:
            sel += list_h
        elif ch == curses.KEY_PPAGE:
            sel -= list_h
        elif ch in (curses.KEY_HOME, ord("g")):
            sel = 0
        elif ch in (curses.KEY_END, ord("G")):
            sel = len(rows) - 1
        elif ch in (10, 13, ord("o")) and rows:
            open_url(rows[sel])
            set_status(f"opened {rows[sel].url}")
        elif ch == ord("c") and rows:
            copy_url(rows[sel])
            set_status(f"copied {rows[sel].url}")
        elif ch == ord("k") and rows:
            e = rows[sel]
            if ask(f"{'Stop container' if e.container else 'Kill'} {e.name} on :{e.port}?"):
                set_status(kill(e, False))
                refresh_data()
        elif ch == ord("K") and rows:
            e = rows[sel]
            if ask(f"Force {'stop' if e.container else 'kill (-9)'} {e.name} on :{e.port}?"):
                set_status(kill(e, True))
                refresh_data()
        elif ch == ord("R") and rows:
            e = rows[sel]
            if ask(f"Restart {e.name} on :{e.port} in a new Terminal window?"):
                set_status(restart(e))
                time.sleep(1.0)
                refresh_data()
        elif ch == ord("a"):
            include_system = not include_system
            refresh_data()
        elif ch == ord("/"):
            read_query()
        elif ch == ord("r"):
            refresh_data()
            set_status("refreshed")
        elif ch == curses.KEY_RESIZE:
            pass


def main(argv):
    args = argv[1:]
    if not args:
        if not sys.stdout.isatty():
            cmd_list(False)
            return
        curses.wrapper(tui)
        return
    sub = args[0]
    if sub in ("list", "ls", "l"):
        cmd_list(not ("-d" in args or "--dev" in args))
    elif sub in ("who", "w") and len(args) >= 2 and args[1].isdigit():
        cmd_who(int(args[1]))
    elif sub in ("open", "o") and len(args) >= 2 and args[1].isdigit():
        cmd_open(int(args[1]))
    elif sub in ("kill", "k") and len(args) >= 2 and args[1].isdigit():
        cmd_kill(int(args[1]), "-9" in args or "--force" in args)
    elif sub in ("restart", "rs") and len(args) >= 2 and args[1].isdigit():
        cmd_restart(int(args[1]), "--here" in args)
    elif sub in ("-h", "--help", "help"):
        print(__doc__.strip())
    else:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
