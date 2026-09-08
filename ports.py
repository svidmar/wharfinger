#!/usr/bin/env python3
"""ports - see, open and kill local listening servers on macOS.

Usage:
  ports                 interactive list (arrow keys, Enter/o = open, k = kill)
  ports list [-d]       plain table (-d hides system/app processes)
  ports open PORT       open http://localhost:PORT in the browser
  ports kill PORT [-9]  kill the process listening on PORT

No dependencies beyond macOS's lsof/ps and Python 3.
"""

import curses
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass

HOME = os.path.expanduser("~")

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


def open_url(entry: Entry):
    subprocess.Popen(["open", entry.url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def copy_url(entry: Entry):
    subprocess.run(["pbcopy"], input=entry.url, text=True, check=False)


def kill(entry: Entry, force: bool = False) -> str:
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


def short_cmd(cmd: str, width: int) -> str:
    parts = cmd.split(" ")
    parts[0] = os.path.basename(parts[0]) or parts[0]
    s = " ".join(_tilde(p) for p in parts)
    return s if len(s) <= width else s[: max(0, width - 1)] + "…"


# ----------------------------------------------------------------- CLI modes


def cmd_list(include_system: bool):
    entries = collect(include_system)
    if not entries:
        print("nothing listening" + ("" if include_system else " (drop -d to include system/app processes)"))
        return
    print(f"{'PORT':>5}  {'ADDR':<15} {'PID':>6}  {'PROCESS':<20} {'CWD / COMMAND'}")
    for e in entries:
        where = e.cwd or short_cmd(e.cmd, 60)
        print(f"{e.port:>5}  {e.addr:<15} {e.pid:>6}  {e.name[:20]:<20} {where}")


def find_port(port: int):
    for e in collect(True):
        if e.port == port:
            return e
    return None


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


# ----------------------------------------------------------------- TUI


HELP = "↑↓ move  ⏎/o open  c copy url  k kill  K kill -9  a all/dev-only  / filter  r refresh  q quit"


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
    entries = collect(include_system)

    def visible():
        if not query:
            return entries
        q = query.lower()
        return [e for e in entries if q in f"{e.port} {e.addr} {e.name} {e.cmd} {e.cwd}".lower()]

    def refresh_data():
        nonlocal entries
        entries = collect(include_system)

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
        header = f"{'PORT':>6}  {'ADDR':<{addr_w}} {'PID':>7}  {'PROCESS':<{name_w}} {'CWD  ·  COMMAND'}"
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
            if where and cmd:
                tail = f"{where}  ·  {cmd}"
            else:
                tail = where or cmd
            if len(tail) > rest_w:
                tail = tail[: rest_w - 1] + "…"
            line = f"{e.port:>6}  {e.addr:<{addr_w}} {e.pid:>7}  {e.name[:name_w]:<{name_w}} {tail}"
            if selected:
                stdscr.addnstr(y, 0, line.ljust(w), w - 1, attr)
            else:
                stdscr.addnstr(y, 0, f"{e.port:>6}", w - 1, curses.color_pair(1) | curses.A_BOLD)
                stdscr.addnstr(y, 8, f"{e.addr:<{addr_w}}", w - 9, curses.A_DIM)
                stdscr.addnstr(y, 8 + addr_w + 1, f"{e.pid:>7}", w - 9 - addr_w - 1, curses.A_DIM)
                x = 8 + addr_w + 1 + 7 + 2
                if x < w - 1:
                    stdscr.addnstr(y, x, f"{e.name[:name_w]:<{name_w}}", w - x - 1, curses.color_pair(2) if e.system else curses.color_pair(3))
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
            if ask(f"Kill {e.name} (pid {e.pid}) on :{e.port}?"):
                set_status(kill(e, False))
                refresh_data()
        elif ch == ord("K") and rows:
            e = rows[sel]
            if ask(f"Force kill (-9) {e.name} (pid {e.pid}) on :{e.port}?"):
                set_status(kill(e, True))
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
    elif sub in ("open", "o") and len(args) >= 2 and args[1].isdigit():
        cmd_open(int(args[1]))
    elif sub in ("kill", "k") and len(args) >= 2 and args[1].isdigit():
        cmd_kill(int(args[1]), "-9" in args or "--force" in args)
    elif sub in ("-h", "--help", "help"):
        print(__doc__.strip())
    else:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
