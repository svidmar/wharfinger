// Wharfinger – menu bar app: see, open, kill and restart local listening servers.
// Build with ./build.sh (plain swiftc, no Xcode project needed).

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

let home = NSHomeDirectory()
let debug = ProcessInfo.processInfo.environment["WHARFINGER_DEBUG"] != nil
func dbg(_ s: String) { if debug { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) } }
let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/", "/Applications/", home + "/Library/", "/private/var/"]
let localAddrs: Set<String> = ["*", "0.0.0.0", "127.0.0.1", "::", "::1", "[::]", "[::1]", "localhost"]
let dockerCandidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", home + "/.docker/bin/docker",
                        "/Applications/Docker.app/Contents/Resources/bin/docker",
                        "/Applications/OrbStack.app/Contents/MacOS/xbin/docker"]

// MARK: - Data

struct Entry {
    let port: Int
    let addr: String
    let pid: Int32
    let name: String
    let cmd: String
    let cwd: String
    let system: Bool
    var info: EnvInfo? = nil
    var branch = ""                 // git branch of the project directory, if any

    var key: String { "\(pid):\(port)" }
    var project: String { (cwd.isEmpty || cwd == "/") ? "" : cwd }
    /// What to call it in the list: the app we recognised (uvicorn, Vite, Jupyter …) or the process name.
    var display: String { info?.app ?? name }
    var url: String { "http://\(localAddrs.contains(addr) ? "localhost" : addr):\(port)" }

    var shortCmd: String {
        var parts = cmd.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return "" }
        parts[0] = (parts[0] as NSString).lastPathComponent
        return parts.map(tilde).joined(separator: " ")
    }
}

struct Container {
    let id: String
    let name: String
    let image: String
    let status: String
    let ports: [(host: Int, container: Int, proto: String)]

    var key: String { "docker:\(name)" }
    func url(_ p: Int) -> String { "http://localhost:\(p)" }
}

final class Box: NSObject {
    let entry: Entry?
    let container: Container?
    let port: Int
    init(_ e: Entry) { entry = e; container = nil; port = e.port }
    init(_ c: Container, port: Int) { entry = nil; container = c; self.port = port }
}

func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func tilde(_ s: String) -> String {
    (s == home || s.hasPrefix(home + "/")) ? "~" + s.dropFirst(home.count) : s
}

func isSystem(cmd: String, name: String) -> Bool {
    let exe = cmd.isEmpty ? name : String(cmd.split(separator: " ", maxSplits: 1)[0])
    // Language runtimes installed as frameworks (python.org's Python.framework, R.framework …) are dev, not system,
    // even though they live under /Library and launch through an embedded .app.
    if exe.contains("/Frameworks/") && exe.contains(".framework/") { return false }
    if exe.contains(".app/Contents/") { return true }
    return systemPrefixes.contains { exe.hasPrefix($0) }
}

func collect() -> [Entry] {
    let out = run("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n", "+c", "0", "-F", "pcn"])
    var pid: Int32 = 0
    var name = ""
    var seen: [String: (port: Int, addr: String, pid: Int32, name: String)] = [:]
    var order: [String] = []
    for line in out.split(separator: "\n") {
        guard let tag = line.first else { continue }
        let val = String(line.dropFirst())
        switch tag {
        case "p": pid = Int32(val) ?? 0
        case "c": name = val
        case "n":
            guard let colon = val.lastIndex(of: ":"), let port = Int(val[val.index(after: colon)...]) else { continue }
            let addr = String(val[..<colon])
            let key = "\(pid):\(port)"
            // IPv4 + IPv6 on the same port collapse to one row; prefer the wildcard.
            if seen[key] != nil, !["*", "0.0.0.0", "::"].contains(addr) { continue }   // keep the first (IPv4) row
            if seen[key] == nil { order.append(key) }
            seen[key] = (port, addr, pid, name)
        default: break
        }
    }
    if seen.isEmpty { return [] }

    let pidList = Set(seen.values.map { $0.pid }).sorted().map(String.init).joined(separator: ",")

    var cmds: [Int32: String] = [:]
    for line in run("/bin/ps", ["-o", "pid=,command=", "-p", pidList]).split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let sp = t.firstIndex(of: " "), let p = Int32(t[..<sp]) else { continue }
        cmds[p] = t[sp...].trimmingCharacters(in: .whitespaces)
    }

    var cwds: [Int32: String] = [:]
    var cur: Int32 = 0
    for line in run("/usr/sbin/lsof", ["-a", "-p", pidList, "-d", "cwd", "-F", "pn"]).split(separator: "\n") {
        if line.first == "p" { cur = Int32(line.dropFirst()) ?? 0 }
        else if line.first == "n" { cwds[cur] = String(line.dropFirst()) }
    }

    var branches: [String: String] = [:]
    return order.map { key -> Entry in
        let s = seen[key]!
        let cmd = cmds[s.pid] ?? ""
        var e = Entry(port: s.port, addr: s.addr, pid: s.pid, name: s.name, cmd: cmd,
                      cwd: tilde(cwds[s.pid] ?? ""), system: isSystem(cmd: cmd, name: s.name))
        if !e.system {
            e.info = describeEnv(pid: e.pid, cwd: e.cwd)
            if !e.project.isEmpty {
                if branches[e.cwd] == nil { branches[e.cwd] = gitBranch(e.cwd) }
                e.branch = branches[e.cwd] ?? ""
            }
        }
        return e
    }.sorted { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
}

// MARK: - Environment per process

struct EnvInfo {
    var app: String? = nil          // recognised program: uvicorn, Vite, Jupyter kernel …
    var runtime = ""                // "python 3.12.3", "node 20.11.0"
    var manager = ""                // ".venv", "pyenv", "nvm", "Homebrew", "system" …
    var exe = ""                    // resolved executable path
    var argv: [String] = []         // exact command line, for restart / start again
    var env: [String: String] = [:] // environment (minus terminal noise), for restart / start again
    var details: [String] = []      // extra lines for the submenu
    var tag: String { [runtime, manager].filter { !$0.isEmpty }.joined(separator: " · ") }
}

let envLock = NSLock()
var envCache: [Int32: EnvInfo] = [:]
var versionCache: [String: String] = [:]
let knownRuntimes: Set<String> = ["python", "node", "bun", "deno", "ruby", "php", "java", "perl", "elixir", "julia", "R"]
let interestingEnv = ["NODE_ENV", "PORT", "HOST", "DJANGO_SETTINGS_MODULE", "FLASK_APP", "FLASK_ENV", "FLASK_DEBUG", "RAILS_ENV", "RACK_ENV",
                      "MIX_ENV", "APP_ENV", "ENV", "ENVIRONMENT", "DEBUG", "PYTHONPATH", "CONDA_DEFAULT_ENV", "JUPYTER_CONFIG_DIR"]

func runBoth(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func firstMatch(_ pattern: String, _ text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

func versionOf(_ exe: String, runtime: String) -> String {
    envLock.lock(); if let v = versionCache[exe] { envLock.unlock(); return v }; envLock.unlock()
    let out = runBoth(exe, [runtime == "java" ? "-version" : "--version"])
    let v = firstMatch(#"(\d+\.\d+(?:\.\d+)?)"#, out) ?? ""
    envLock.lock(); versionCache[exe] = v; envLock.unlock()
    return v
}

func runtimeName(_ base: String) -> String {
    if firstMatch(#"^(python)\d*(?:\.\d+)?$"#, base) != nil { return "python" }
    if firstMatch(#"^(ruby)\d*(?:\.\d+)?$"#, base) != nil { return "ruby" }
    if firstMatch(#"^(php)\d*(?:\.\d+)?$"#, base) != nil { return "php" }
    if base == "node" || base == "nodejs" { return "node" }
    return base
}

func describeEnv(pid: Int32, cwd: String) -> EnvInfo? {
    envLock.lock(); if let c = envCache[pid] { envLock.unlock(); return c }; envLock.unlock()
    guard let (execPath, argv, env) = procArgsEnv(pid) else { return nil }
    var info = EnvInfo()
    info.argv = argv
    info.env = env.filter { k, _ in !skipEnvPrefixes.contains { k.hasPrefix($0) } }
    let absCwd = ((cwd.hasPrefix("~") ? home + cwd.dropFirst() : cwd) as NSString).resolvingSymlinksInPath
    var exe = execPath.hasPrefix("/") ? execPath : (absCwd + "/" + execPath)
    exe = (exe as NSString).standardizingPath   // keep symlinks: <venv>/bin/python must stay the venv path
    info.exe = exe
    let base = (exe as NSString).lastPathComponent
    let runtime = runtimeName(base.lowercased())
    var version = ""
    let joined = argv.joined(separator: " ")

    // Which program is it really? (argv beats the interpreter name)
    let apps: [(String, String)] = [
        ("ipykernel_launcher", "Jupyter kernel"), ("jupyter-lab", "JupyterLab"), ("jupyter lab", "JupyterLab"), ("jupyterlab", "JupyterLab"),
        ("jupyter-notebook", "Jupyter Notebook"), ("jupyter notebook", "Jupyter Notebook"), ("jupyter", "Jupyter"),
        ("uvicorn", "uvicorn"), ("gunicorn", "gunicorn"), ("hypercorn", "hypercorn"), ("manage.py runserver", "Django runserver"),
        ("flask", "Flask"), ("streamlit", "Streamlit"), ("gradio", "Gradio"), ("mkdocs", "MkDocs"), ("http.server", "http.server"),
        ("vite", "Vite"), ("next", "Next.js"), ("nuxt", "Nuxt"), ("astro", "Astro"), ("remix", "Remix"), ("webpack", "webpack"),
        ("storybook", "Storybook"), ("nodemon", "nodemon"), ("ts-node", "ts-node"), ("tsx", "tsx"), ("rails", "Rails"), ("puma", "Puma"),
        ("php artisan serve", "Laravel"), ("mix phx.server", "Phoenix"), ("hugo", "Hugo"), ("jekyll", "Jekyll"), ("ollama", "Ollama"),
    ]
    let argvLower = joined.lowercased()
    for (needle, name) in apps {
        // match on whole path components / words so "next" doesn't match "nextcloud-foo"
        if let _ = firstMatch("(^|[/ ])(" + NSRegularExpression.escapedPattern(for: needle.lowercased()) + ")($|[ /.])", argvLower) {
            info.app = name; break
        }
    }

    // Python virtualenv: VIRTUAL_ENV or <venv>/bin/python with a pyvenv.cfg next to bin/
    let binDir = (exe as NSString).deletingLastPathComponent
    let venvDir = ((env["VIRTUAL_ENV"] ?? ((binDir as NSString).lastPathComponent == "bin" ? (binDir as NSString).deletingLastPathComponent : "")) as NSString).resolvingSymlinksInPath
    if runtime == "python", !venvDir.isEmpty, let cfg = try? String(contentsOfFile: venvDir + "/pyvenv.cfg", encoding: .utf8) {
        version = firstMatch(#"(?m)^version(?:_info)?\s*=\s*(\d+\.\d+(?:\.\d+)?)"#, cfg) ?? ""
        let name = venvDir.hasPrefix(absCwd + "/") ? String(venvDir.dropFirst(absCwd.count + 1)) : tilde(venvDir)
        var kind = "venv"
        if cfg.contains("\nuv = ") || cfg.hasPrefix("uv = ") { kind = "uv venv" }
        else if venvDir.contains("pypoetry/virtualenvs") { kind = "poetry venv" }
        else if venvDir.contains("/.virtualenvs/") || env["PIPENV_ACTIVE"] != nil { kind = "virtualenv" }
        info.manager = "\(kind) \(name)"
        info.details.append("venv: \(tilde(venvDir))")
        if let home = firstMatch(#"(?m)^home\s*=\s*(.+)$"#, cfg) {
            if let v = firstMatch(#"\.pyenv/versions/([^/]+)"#, home) { info.details.append("base python: pyenv \(v)") }
            else if let v = firstMatch(#"Python\.framework/Versions/([^/]+)"#, home) { info.details.append("base python: python.org \(v)") }
            else if home.contains("/opt/homebrew") || home.contains("/Cellar/") { info.details.append("base python: Homebrew") }
            else if home.hasPrefix("/usr/bin") || home.hasPrefix("/Library/Developer") { info.details.append("base python: system") }
            else if home.contains("uv/python") { info.details.append("base python: uv-managed") }
            else { info.details.append("base python: \(tilde(home))") }
        }
    } else if let prefix = env["CONDA_PREFIX"], !prefix.isEmpty {
        info.manager = "conda " + (env["CONDA_DEFAULT_ENV"] ?? (prefix as NSString).lastPathComponent)
        info.details.append("conda prefix: \(tilde(prefix))")
    } else if exe.contains("conda") || exe.contains("miniforge") || exe.contains("mambaforge") {
        info.manager = "conda " + ((firstMatch(#"/envs/([^/]+)/"#, exe)) ?? "base")
    } else if let v = firstMatch(#"\.pyenv/versions/([^/]+)/"#, exe) {
        version = v; info.manager = "pyenv"
    } else if let v = firstMatch(#"\.nvm/versions/node/v([^/]+)/"#, exe) {
        version = v; info.manager = "nvm"
    } else if let v = firstMatch(#"\.asdf/installs/[^/]+/([^/]+)/"#, exe) {
        version = v; info.manager = "asdf"
    } else if let v = firstMatch(#"mise/installs/[^/]+/([^/]+)/"#, exe) {
        version = v; info.manager = "mise"
    } else if let v = firstMatch(#"Python\.framework/Versions/([^/]+)/"#, exe) {
        version = v; info.manager = "python.org"
    } else if exe.contains("/.volta/") { info.manager = "volta" }
    else if exe.contains("/fnm") { info.manager = "fnm" }
    else if exe.hasPrefix(home + "/.bun/") { info.manager = "bun" }
    else if exe.hasPrefix(home + "/.deno/") { info.manager = "deno" }
    else if exe.hasPrefix("/opt/homebrew/") || exe.contains("/Cellar/") { info.manager = "Homebrew" }
    else if exe.hasPrefix("/usr/bin/") || exe.hasPrefix("/System/") || exe.hasPrefix("/Library/Developer/") { info.manager = "system" }
    else if exe.hasPrefix("/usr/local/") { info.manager = runtime == "node" ? "nodejs.org" : "/usr/local" }
    else if exe.contains("node_modules/.bin/") { info.manager = "node_modules" }
    else if exe.hasPrefix(absCwd + "/") { info.manager = "in project" }

    if version.isEmpty, knownRuntimes.contains(runtime) { version = versionOf(exe, runtime: runtime) }
    if knownRuntimes.contains(runtime) || !version.isEmpty {
        info.runtime = version.isEmpty ? runtime : "\(runtime) \(version)"
    } else {
        info.runtime = base
    }
    info.details.append("exec: \(tilde(exe))")
    for k in interestingEnv { if let v = env[k], !v.isEmpty { info.details.append("\(k)=\(v.prefix(80))") } }

    envLock.lock(); envCache[pid] = info; envLock.unlock()
    return info
}

// MARK: - Git branch

/// Branch checked out in `dir` (or its nearest parent repo); handles worktrees and detached HEADs.
func gitBranch(_ dir: String) -> String {
    var d = dir.hasPrefix("~") ? home + dir.dropFirst() : dir
    let fm = FileManager.default
    for _ in 0..<12 {
        let dotGit = d + "/.git"
        var gitDir = ""
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
            if isDir.boolValue { gitDir = dotGit }
            else if let s = try? String(contentsOfFile: dotGit, encoding: .utf8), s.hasPrefix("gitdir:") {
                let g = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                gitDir = g.hasPrefix("/") ? g : d + "/" + g
            }
        }
        if !gitDir.isEmpty {
            guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return "" }
            let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if h.hasPrefix("ref: refs/heads/") { return String(h.dropFirst(16)) }
            if h.hasPrefix("ref: ") { return String(h.dropFirst(5)) }
            return String(h.prefix(7))
        }
        let parent = (d as NSString).deletingLastPathComponent
        if parent == d || parent.isEmpty || parent == home || parent == "/" { break }
        d = parent
    }
    return ""
}

// MARK: - Known routes per framework

let knownRoutes: [String: [String]] = [
    "FastAPI": ["/docs", "/redoc", "/openapi.json"], "Uvicorn": ["/docs", "/redoc"], "uvicorn": ["/docs", "/redoc"],
    "Django": ["/admin/"], "Django runserver": ["/admin/"], "Rails": ["/rails/info/routes"], "Phoenix": ["/dev/dashboard"],
    "Jupyter": ["/lab", "/tree"], "JupyterLab": ["/lab", "/tree"], "Jupyter Notebook": ["/tree"], "Grafana": ["/dashboards"],
    "Ollama": ["/api/tags"], "Laravel": ["/telescope"], "Swagger UI": ["/openapi.json"], "Storybook": ["/?path=/docs"],
    "Vite": ["/__inspect/"], "Next.js": ["/_next/static/"], "Streamlit": ["/healthz"], "Gradio": ["/docs"],
    "Hugo": ["/index.xml"], "MkDocs": ["/search/"], "Docusaurus": ["/docs"],
]

func routes(for e: Entry, probeLabel: String?) -> [String] {
    var names: [String] = []
    if let a = e.info?.app { names.append(a) }
    if let l = probeLabel, let f = l.split(separator: "·").first { names.append(f.trimmingCharacters(in: .whitespaces)) }
    var out: [String] = []
    for n in names { for r in knownRoutes[n] ?? [] where !out.contains(r) { out.append(r) } }
    return out
}

// MARK: - Remembered servers ("start again")

struct RememberedServer: Codable {
    var id: String            // cwd + command
    var port: Int
    var display: String
    var cwd: String           // absolute
    var argv: [String]
    var env: [String: String]
    var lastSeen: Date
}

final class ServerStore {
    private(set) var servers: [String: RememberedServer] = [:]
    let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wharfinger")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("servers.json")
    }()

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: file), let list = try? dec.decode([RememberedServer].self, from: d) {
            for s in list { servers[s.id] = s }
        }
    }

    static func id(cwd: String, argv: [String]) -> String { cwd + " | " + argv.joined(separator: " ") }

    /// Record every running dev server that we know how to start again.
    func remember(_ entries: [Entry]) {
        var changed = false
        for e in entries {
            guard let info = e.info, !info.argv.isEmpty, !e.project.isEmpty else { continue }
            let cwd = e.cwd.hasPrefix("~") ? home + e.cwd.dropFirst() : e.cwd
            let id = ServerStore.id(cwd: cwd, argv: info.argv)
            servers[id] = RememberedServer(id: id, port: e.port, display: e.display, cwd: cwd, argv: info.argv, env: info.env, lastSeen: Date())
            changed = true
        }
        if changed { save() }
    }

    func forget(_ id: String) { servers[id] = nil; save() }

    /// Remembered servers that are not running right now, newest first, at most `limit`.
    func stopped(running: [Entry], limit: Int = 8) -> [RememberedServer] {
        var runningIds = Set<String>()
        for e in running {
            guard let info = e.info, !info.argv.isEmpty else { continue }
            let cwd = e.cwd.hasPrefix("~") ? home + e.cwd.dropFirst() : e.cwd
            runningIds.insert(ServerStore.id(cwd: cwd, argv: info.argv))
        }
        return servers.values.filter { !runningIds.contains($0.id) && FileManager.default.fileExists(atPath: $0.cwd) }
            .sorted { $0.lastSeen > $1.lastSeen }.prefix(limit).map { $0 }
    }

    private func save() {
        // Trim to the 40 most recent; the file can hold environment variables, so keep it private.
        let keep = servers.values.sorted { $0.lastSeen > $1.lastSeen }.prefix(40)
        servers = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601   // shared with the CLI
        if let d = try? enc.encode(Array(keep)) {
            try? d.write(to: file, options: .atomic)
            chmod(file.path, 0o600)
        }
    }
}

func ago(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60) min ago" }
    if s < 86400 { return "\(s / 3600) h ago" }
    return "\(s / 86400) d ago"
}

// MARK: - Editors & terminals

let editorCandidates: [(name: String, apps: [String])] = [
    ("Visual Studio Code", ["Visual Studio Code.app"]), ("Cursor", ["Cursor.app"]), ("Zed", ["Zed.app"]), ("Windsurf", ["Windsurf.app"]),
    ("Sublime Text", ["Sublime Text.app"]), ("PyCharm", ["PyCharm.app", "PyCharm CE.app", "PyCharm Professional.app", "PyCharm Community Edition.app"]),
    ("IntelliJ IDEA", ["IntelliJ IDEA.app", "IntelliJ IDEA CE.app"]), ("WebStorm", ["WebStorm.app"]), ("RustRover", ["RustRover.app"]),
    ("GoLand", ["GoLand.app"]), ("Fleet", ["Fleet.app"]), ("Positron", ["Positron.app"]), ("RStudio", ["RStudio.app"]),
    ("Nova", ["Nova.app"]), ("TextMate", ["TextMate.app"]), ("BBEdit", ["BBEdit.app"]), ("Emacs", ["Emacs.app"]), ("Xcode", ["Xcode.app"]),
]
let terminalCandidates: [(name: String, apps: [String])] = [
    ("Terminal", ["/System/Applications/Utilities/Terminal.app"]), ("iTerm", ["iTerm.app"]), ("Ghostty", ["Ghostty.app"]),
    ("Warp", ["Warp.app"]), ("kitty", ["kitty.app"]), ("Alacritty", ["Alacritty.app"]), ("WezTerm", ["WezTerm.app"]),
]

func installedApps(_ candidates: [(name: String, apps: [String])]) -> [String] {
    candidates.filter { c in
        c.apps.contains { app in
            app.hasPrefix("/") ? FileManager.default.fileExists(atPath: app)
                : ["/Applications/", home + "/Applications/", home + "/Applications/JetBrains Toolbox/"].contains { FileManager.default.fileExists(atPath: $0 + app) }
        }
    }.map { $0.name }
}

func openInTerminal(_ name: String, dir: String) {
    var args = ["-a", name]
    switch name {
    case "Ghostty": args += ["--args", "--working-directory=\(dir)"]
    case "kitty": args += ["--args", "-d", dir]
    case "Alacritty": args += ["--args", "--working-directory", dir]
    case "WezTerm": args += ["--args", "start", "--cwd", dir]
    default: args.append(dir)     // Terminal, iTerm, Warp open a window at the folder
    }
    _ = run("/usr/bin/open", args)
}

// MARK: - Restart

/// Exact exec path, argv and environment of one of our own processes (KERN_PROCARGS2).
func procArgsEnv(_ pid: Int32) -> (execPath: String, argv: [String], env: [String: String])? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    let execStart = i
    while i < size, buf[i] != 0 { i += 1 }        // exec path
    let execPath = String(decoding: buf[execStart..<i], as: UTF8.self)
    while i < size, buf[i] == 0 { i += 1 }        // padding
    var strings: [String] = []
    var start = i
    while i < size {
        if buf[i] == 0 {
            if i > start { strings.append(String(decoding: buf[start..<i], as: UTF8.self)) }
            start = i + 1
        }
        i += 1
    }
    guard strings.count >= argc, argc > 0 else { return nil }
    var env: [String: String] = [:]
    for s in strings[argc...] {
        if let eq = s.firstIndex(of: "=") { env[String(s[..<eq])] = String(s[s.index(after: eq)...]) }
    }
    return (execPath, Array(strings[..<argc]), env)
}

func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

let skipEnvPrefixes = ["TERM", "SHLVL", "PWD", "OLDPWD", "_", "__CF", "XPC_", "TMPDIR", "SECURITYSESSIONID", "COMMAND_MODE", "LaunchInstanceID", "SSH_"]

/// Writes a .command script that re-runs the process in its cwd with its environment, for Terminal.app.
func writeRestartScript(argv: [String], env: [String: String], cwd: String, port: Int) -> URL? {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Wharfinger")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("restart-\(port).command")
    var lines = ["#!/bin/sh", "# Wharfinger restart of :\(port)", "cd \(shQuote(cwd)) || exit 1"]
    for (k, v) in env.sorted(by: { $0.key < $1.key }) where !skipEnvPrefixes.contains(where: { k.hasPrefix($0) }) {
        lines.append("export \(k)=\(shQuote(v))")
    }
    lines.append("echo \(shQuote("Wharfinger: restarting " + argv.joined(separator: " ") + " in " + cwd))")
    lines.append("exec " + argv.map(shQuote).joined(separator: " "))
    guard (try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
    chmod(file.path, 0o755)
    return file
}

// MARK: - Docker

let dockerBin: String? = dockerCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }

func collectDocker() -> [Container] {
    guard let bin = dockerBin else { return [] }
    let out = run(bin, ["ps", "--format", "{{json .}}"])
    let portRe = try! NSRegularExpression(pattern: #"(?:[\d.]+|\[?::\]?):(\d+)->(\d+)/(\w+)"#)
    var result: [Container] = []
    for line in out.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        let portsStr = obj["Ports"] as? String ?? ""
        var ports: [(host: Int, container: Int, proto: String)] = []
        var seenHost: Set<Int> = []
        for m in portRe.matches(in: portsStr, range: NSRange(portsStr.startIndex..., in: portsStr)) {
            guard let h = Int(portsStr[Range(m.range(at: 1), in: portsStr)!]),
                  let c = Int(portsStr[Range(m.range(at: 2), in: portsStr)!]) else { continue }
            let proto = String(portsStr[Range(m.range(at: 3), in: portsStr)!])
            if seenHost.insert(h).inserted { ports.append((h, c, proto)) }
        }
        result.append(Container(id: obj["ID"] as? String ?? "", name: obj["Names"] as? String ?? "?",
                                image: obj["Image"] as? String ?? "", status: obj["Status"] as? String ?? "",
                                ports: ports.sorted { $0.host < $1.host }))
    }
    return result.sorted { $0.name < $1.name }
}

// MARK: - HTTP probe: what answers on the port?

final class Prober {
    struct Result { var label: String; var at: Date; var ok: Bool; var hadSuccess: Bool }
    private(set) var cache: [String: Result] = [:]
    private var inflight: Set<String> = []
    var onResult: ((String) -> Void)?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        c.timeoutIntervalForResource = 2.0
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c)
    }()

    func label(_ key: String) -> String? { cache[key]?.label }
    /// Answered HTTP before, but not any more: the process is alive, the server is not.
    func hung(_ key: String) -> Bool { cache[key].map { $0.hadSuccess && !$0.ok } ?? false }
    var onHung: ((String) -> Void)?

    func probe(key: String, url: String) {
        if let r = cache[key], Date().timeIntervalSince(r.at) < (r.hadSuccess ? 30 : 60) { return }
        guard !inflight.contains(key), let u = URL(string: url) else { return }
        inflight.insert(key)
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.setValue("Wharfinger/1.0", forHTTPHeaderField: "User-Agent")
        // A server that answered before gets more patience before we call it hung.
        if cache[key]?.hadSuccess == true { req.timeoutInterval = 5 }
        session.dataTask(with: req) { data, resp, _ in
            let answered = resp != nil
            let label = Prober.describe(data: data, resp: resp as? HTTPURLResponse)
            dbg("probe \(key) \(url) -> status \(resp.map { String(($0 as? HTTPURLResponse)?.statusCode ?? 0) } ?? "nil") label '\(label)'")
            DispatchQueue.main.async {
                self.inflight.remove(key)
                let old = self.cache[key]
                if answered {
                    self.cache[key] = Result(label: label, at: Date(), ok: true, hadSuccess: true)
                } else {
                    // keep the last good label so the row still says what it was
                    self.cache[key] = Result(label: old?.label ?? "", at: Date(), ok: false, hadSuccess: old?.hadSuccess ?? false)
                }
                let wasHung = old.map { $0.hadSuccess && !$0.ok } ?? false
                if self.hung(key) && !wasHung { self.onHung?(key) }
                if !label.isEmpty || old?.ok != self.cache[key]?.ok { self.onResult?(key) }
            }
        }.resume()
    }

    static let titleRe = try! NSRegularExpression(pattern: #"<title[^>]*>\s*(.*?)\s*</title>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])

    static func describe(data: Data?, resp: HTTPURLResponse?) -> String {
        guard let resp = resp else { return "" }
        let body = data.map { String(decoding: $0.prefix(200_000), as: UTF8.self) } ?? ""
        let lower = body.lowercased()
        let server = (resp.value(forHTTPHeaderField: "Server") ?? "").lowercased()
        let powered = (resp.value(forHTTPHeaderField: "X-Powered-By") ?? "").lowercased()

        var framework = ""
        let hints: [(String, () -> Bool)] = [
            ("Vite", { lower.contains("/@vite/client") || lower.contains("@vite/client") }),
            ("Next.js", { lower.contains("/_next/") || powered.contains("next.js") }),
            ("Nuxt", { lower.contains("__nuxt") }),
            ("SvelteKit", { lower.contains("__sveltekit") }),
            ("Remix", { lower.contains("__remixcontext") }),
            ("Astro", { lower.contains("astro-island") || lower.contains("/_astro/") }),
            ("Angular", { lower.contains("ng-version") }),
            ("Storybook", { lower.contains("storybook") }),
            ("Streamlit", { lower.contains("streamlit") }),
            ("Gradio", { lower.contains("gradio") }),
            ("Jupyter", { lower.contains("jupyter-config-data") || lower.contains("jupyterlab") || lower.contains("/static/notebook/") }),
            ("Ollama", { lower.contains("ollama is running") }),
            ("Grafana", { lower.contains("grafana") }),
            ("Swagger UI", { lower.contains("swagger-ui") }),
            ("Django", { lower.contains("django") || server.contains("wsgiserver") }),
            ("FastAPI", { lower.contains("fastapi") }),
            ("Uvicorn", { server.contains("uvicorn") }),
            ("Flask", { server.contains("werkzeug") }),
            ("Express", { powered.contains("express") }),
            ("PHP", { powered.contains("php") }),
            ("Rails", { lower.contains("csrf-param") && lower.contains("rails") }),
            ("Phoenix", { lower.contains("phoenix") && lower.contains("csrf") }),
            ("MkDocs", { lower.contains("mkdocs") }),
            ("Docusaurus", { lower.contains("docusaurus") }),
            ("Hugo", { lower.contains("generator\" content=\"hugo") }),
            ("Jekyll", { lower.contains("generator\" content=\"jekyll") }),
            ("Python http.server", { server.contains("simplehttp") }),
            ("Webpack dev server", { lower.contains("webpack") }),
        ]
        for (name, test) in hints where test() { framework = name; break }
        if framework.isEmpty, !server.isEmpty {
            framework = String(server.split(separator: "/").first ?? "").capitalized
        }

        var title = ""
        if let m = Prober.titleRe.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
           let r = Range(m.range(at: 1), in: body) {
            title = body[r].replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count > 45 { title = String(title.prefix(44)) + "…" }
        }
        if title.isEmpty, framework.isEmpty, (resp.mimeType ?? "").contains("json") { framework = "JSON API" }

        var parts = [framework, title].filter { !$0.isEmpty }
        if parts.isEmpty { parts = ["HTTP \(resp.statusCode)"] }
        else if resp.statusCode >= 400 { parts.append("(\(resp.statusCode))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Row icons

/// SF Symbol + colour for a row, keyed on what we know about it.
func rowSymbol(_ e: Entry) -> (String, NSColor) {
    let app = (e.info?.app ?? "").lowercased()
    let rt = (e.info?.runtime ?? "").lowercased()
    let name = e.name.lowercased()
    if app.contains("jupyter") { return ("book.closed.fill", .systemOrange) }
    if ["postgres", "mysql", "mariadb", "mongod", "redis", "sqlite", "clickhouse", "elasticsearch"].contains(where: { name.contains($0) }) {
        return ("cylinder.fill", .systemTeal)
    }
    if rt.hasPrefix("python") { return ("chevron.left.forwardslash.chevron.right", .systemBlue) }
    if rt.hasPrefix("node") || rt.hasPrefix("bun") || rt.hasPrefix("deno") { return ("curlybraces", .systemGreen) }
    if rt.hasPrefix("ruby") { return ("diamond.fill", .systemRed) }
    if rt.hasPrefix("php") { return ("p.square.fill", .systemIndigo) }
    if rt.hasPrefix("java") { return ("cup.and.saucer.fill", .systemBrown) }
    if rt.hasPrefix("elixir") { return ("drop.fill", .systemPurple) }
    if e.system { return ("app.fill", .tertiaryLabelColor) }
    return ("bolt.horizontal.fill", .systemGray)
}

func symbolImage(_ name: String, _ color: NSColor, size: CGFloat = 13) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    img?.isTemplate = false
    return img
}

// MARK: - App

let iconChoices: [(name: String, symbol: String)] = [
    ("Server rack", "server.rack"),
    ("Nodes", "point.3.connected.trianglepath.dotted"),
    ("Antenna", "antenna.radiowaves.left.and.right"),
    ("Terminal", "terminal"),
    ("Bolt", "bolt.horizontal"),
    ("Plug", "powerplug"),
    ("Chip", "cpu"),
    ("Globe", "network"),
]

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    var entries: [Entry] = []
    var containers: [Container] = []
    var timer: Timer?
    let prober = Prober()
    let store = ServerStore()
    var menuItems: [String: NSMenuItem] = [:]
    var known: [String: String]? = nil       // key -> description, baseline for notifications
    var notifyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "notify") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notify") }
    }
    var refreshing = false
    var iconSymbol: String {
        get { UserDefaults.standard.string(forKey: "icon") ?? iconChoices[0].symbol }
        set { UserDefaults.standard.set(newValue, forKey: "icon"); applyIcon() }
    }

    var editor: String {
        get { UserDefaults.standard.string(forKey: "editor") ?? installedApps(editorCandidates).first ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "editor") }
    }
    var terminal: String {
        get { UserDefaults.standard.string(forKey: "terminal") ?? "Terminal" }
        set { UserDefaults.standard.set(newValue, forKey: "terminal") }
    }

    func applyIcon() {
        let img = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: "Wharfinger")
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "Wharfinger")
        img?.isTemplate = true
        item.button?.image = img
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyIcon()
        item.button?.imagePosition = .imageLeading
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        menu.delegate = self
        item.menu = menu
        prober.onResult = { [weak self] key in self?.updateRow(key) }
        prober.onHung = { [weak self] key in
            guard let self = self, self.notifyEnabled, let e = self.entries.first(where: { $0.key == key }) else { return }
            self.notify(title: "Dev server not responding", body: ":\(e.port) \(e.display)" + (e.project.isEmpty ? "" : "  ·  \(e.cwd)"), url: e.url)
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        refreshAsync()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshAsync() }
        registerHotKey()
    }

    // MARK: refresh

    func devEntries() -> [Entry] {
        let dockerPorts = Set(containers.flatMap { $0.ports.map { $0.host } })
        return entries.filter { !$0.system && !(dockerPorts.contains($0.port) && $0.name.lowercased().contains("docker")) }
    }

    func apply(entries e: [Entry], containers c: [Container]) {
        entries = e
        containers = c
        dbg("refresh: \(e.count) listeners, \(c.count) containers, dev: " + devEntries().map { ":\($0.port) \($0.display) [\($0.info?.tag ?? "")] \($0.branch.isEmpty ? "" : "⎇" + $0.branch) \(self.prober.hung($0.key) ? "HUNG" : "")" }.joined(separator: ", "))
        let dev = devEntries()
        dbg("stopped: " + store.stopped(running: dev).map { ":\($0.port) \($0.display) \(tilde($0.cwd))" }.joined(separator: ", "))
        let n = dev.count + containers.count
        item.button?.title = n > 0 ? " \(n)" : ""
        for e in dev { prober.probe(key: e.key, url: e.url) }
        store.remember(dev)
        for c in containers { for p in c.ports where p.proto == "tcp" { prober.probe(key: "\(c.key):\(p.host)", url: c.url(p.host)) } }
        diffAndNotify(dev: dev, containers: containers)
    }

    func refreshSync() { apply(entries: collect(), containers: containers) }

    func refreshAsync() {
        if refreshing { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let e = collect()
            let c = collectDocker()
            DispatchQueue.main.async {
                self.refreshing = false
                self.apply(entries: e, containers: c)
            }
        }
    }

    // MARK: notifications

    func diffAndNotify(dev: [Entry], containers: [Container]) {
        var now: [String: String] = [:]
        for e in dev { now["\(e.port):\(e.name)"] = ":\(e.port) \(e.name)" + (e.cwd.isEmpty || e.cwd == "/" ? "" : "  ·  \(e.cwd)") }
        for c in containers { now[c.key] = "container \(c.name)" + (c.ports.isEmpty ? "" : "  ·  :" + c.ports.map { String($0.host) }.joined(separator: ", :")) }
        defer { known = now }
        guard let before = known, notifyEnabled else { return }
        for (k, desc) in now where before[k] == nil {
            let port = k.hasPrefix("docker:") ? containers.first { $0.key == k }?.ports.first?.host : Int(k.split(separator: ":")[0])
            notify(title: k.hasPrefix("docker:") ? "Container started" : "Dev server started", body: desc,
                   url: port.map { "http://localhost:\($0)" })
        }
        for (k, desc) in before where now[k] == nil {
            notify(title: k.hasPrefix("docker:") ? "Container stopped" : "Dev server stopped", body: desc, url: nil)
        }
    }

    func notify(title: String, body: String, url: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        // "  ·  " splits "port program" from the project directory: the directory becomes the subtitle.
        let parts = body.components(separatedBy: "  ·  ")
        content.body = parts[0]
        if parts.count > 1 { content.subtitle = parts[1...].joined(separator: " · ") }
        content.threadIdentifier = url ?? body
        if let url = url { content.userInfo = ["url": url] }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        dbg("notify: \(title) – \(body)")
        UNUserNotificationCenter.current().add(req) { err in if let err = err { dbg("notify error: \(err)") } }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let u = URL(string: s) {
            NSWorkspace.shared.open(u)
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // MARK: hotkey

    // ⌃⌥P pops the menu at the mouse, useful when the menu bar is too full to show the icon.
    var hotKeyRef: EventHotKeyRef?
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { delegate.showMenuAtMouse() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: 0x50525453, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func showMenuAtMouse() {
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: menu

    // Rebuild the menu every time it opens so it is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshSync()
        menu.removeAllItems()
        menuItems.removeAll()
        rowGroups.removeAll()
        rowInProject.removeAll()
        searchable.removeAll()
        sectionHeaders.removeAll()
        menu.addItem(searchItem())
        let dev = devEntries()
        let devKeys = Set(dev.map { $0.key })
        let other = entries.filter { !devKeys.contains($0.key) }

        if dev.isEmpty {
            menu.addItem(header("No dev servers listening"))
        } else {
            let h = header("Dev servers"); menu.addItem(h)
            var rowsInSection: [NSMenuItem] = []
            defer { sectionHeaders.append((h, rowsInSection)) }
            // A process with many ports (a Jupyter kernel has five) becomes one row.
            var byPid: [[Entry]] = []
            for e in dev {
                if let i = byPid.firstIndex(where: { $0[0].pid == e.pid }) { byPid[i].append(e) } else { byPid.append([e]) }
            }
            var rows: [[Entry]] = []
            for g in byPid { if g.count >= 3 { rows.append(g) } else { g.forEach { rows.append([$0]) } } }
            // Projects with more than one server get a project row with the servers indented under it.
            var projects: [String: [[Entry]]] = [:]
            var order: [String] = []
            for r in rows {
                let p = r[0].project
                if projects[p] == nil { order.append(p) }
                projects[p, default: []].append(r)
            }
            for p in order {
                let group = projects[p]!
                if !p.isEmpty && group.count > 1 {
                    let pi = projectItem(group[0][0]); menu.addItem(pi); rowsInSection.append(pi)
                    let ptext = (p + " " + group[0][0].branch).lowercased()
                    searchable.append((pi, ptext))
                    for r in group { let it = entryItem(r, inProject: true); it.indentationLevel = 1; menu.addItem(it); rowsInSection.append(it) }
                } else {
                    group.forEach { let it = entryItem($0); menu.addItem(it); rowsInSection.append(it) }
                }
            }
        }
        let stopped = store.stopped(running: dev)
        if !stopped.isEmpty {
            menu.addItem(.separator())
            let h = header("Recently stopped"); menu.addItem(h)
            var rows: [NSMenuItem] = []
            stopped.forEach { let it = stoppedItem($0); menu.addItem(it); rows.append(it) }
            sectionHeaders.append((h, rows))
        }
        if !containers.isEmpty {
            menu.addItem(.separator())
            let h = header("Docker"); menu.addItem(h)
            var rows: [NSMenuItem] = []
            containers.forEach { let it = containerItem($0); menu.addItem(it); rows.append(it) }
            sectionHeaders.append((h, rows))
        }
        menu.addItem(.separator())
        if !other.isEmpty {
            let sub = NSMenu()
            // One row per program, its ports in the submenu.
            var byPid: [[Entry]] = []
            for e in other {
                if let i = byPid.firstIndex(where: { $0[0].pid == e.pid }) { byPid[i].append(e) } else { byPid.append([e]) }
            }
            byPid.sort { $0[0].name.lowercased() < $1[0].name.lowercased() }
            byPid.forEach { sub.addItem(entryItem($0)) }
            let it = NSMenuItem(title: "Apps & system (\(byPid.count) apps, \(other.count) ports)", action: nil, keyEquivalent: "")
            it.submenu = sub
            menu.addItem(it)
        }
        let who = NSMenuItem(title: "Who has port…", action: #selector(whoHasPort), keyEquivalent: "")
        who.target = self
        menu.addItem(who)
        menu.addItem(.separator())
        let notify = NSMenuItem(title: "Notify when servers start or stop", action: #selector(toggleNotify), keyEquivalent: "")
        notify.target = self
        notify.state = notifyEnabled ? .on : .off
        menu.addItem(notify)
        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let icons = NSMenu()
        for c in iconChoices {
            let m = NSMenuItem(title: c.name, action: #selector(chooseIcon(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = c.symbol
            m.image = NSImage(systemSymbolName: c.symbol, accessibilityDescription: nil)
            m.state = c.symbol == iconSymbol ? .on : .off
            icons.addItem(m)
        }
        let iconItem = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        iconItem.submenu = icons
        menu.addItem(iconItem)
        let editors = NSMenu()
        for name in installedApps(editorCandidates) {
            let m = NSMenuItem(title: name, action: #selector(chooseEditor(_:)), keyEquivalent: "")
            m.target = self; m.representedObject = name; m.state = name == editor ? .on : .off
            editors.addItem(m)
        }
        if !editor.isEmpty, !installedApps(editorCandidates).contains(editor) {
            let m = NSMenuItem(title: editor, action: #selector(chooseEditor(_:)), keyEquivalent: "")
            m.target = self; m.representedObject = editor; m.state = .on
            editors.addItem(m)
        }
        editors.addItem(.separator())
        let pick = NSMenuItem(title: "Choose another app…", action: #selector(pickEditor), keyEquivalent: "")
        pick.target = self
        editors.addItem(pick)
        let editorItem = NSMenuItem(title: "Editor", action: nil, keyEquivalent: "")
        editorItem.submenu = editors
        menu.addItem(editorItem)
        let terminals = NSMenu()
        for name in installedApps(terminalCandidates) {
            let m = NSMenuItem(title: name, action: #selector(chooseTerminal(_:)), keyEquivalent: "")
            m.target = self; m.representedObject = name; m.state = name == terminal ? .on : .off
            terminals.addItem(m)
        }
        if !installedApps(terminalCandidates).contains(terminal) {
            let m = NSMenuItem(title: terminal, action: #selector(chooseTerminal(_:)), keyEquivalent: "")
            m.target = self; m.representedObject = terminal; m.state = .on
            terminals.addItem(m)
        }
        terminals.addItem(.separator())
        let pickT = NSMenuItem(title: "Choose another app…", action: #selector(pickTerminal), keyEquivalent: "")
        pickT.target = self
        terminals.addItem(pickT)
        let termItem = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
        termItem.submenu = terminals
        menu.addItem(termItem)
        menu.addItem(header("⌃⌥P opens this menu anywhere"))
        menu.addItem(withTitle: "Quit Wharfinger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func header(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    let mono = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let small = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)

    func rowTitle(port: String, name: String, probe: String?, detail: String) -> NSAttributedString {
        let t = NSMutableAttributedString(string: port.isEmpty ? "" : port.padding(toLength: 7, withPad: " ", startingAt: 0), attributes: [.font: mono])
        t.append(NSAttributedString(string: name, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        if let p = probe, !p.isEmpty {
            t.append(NSAttributedString(string: "   \(p)", attributes: [.font: small, .foregroundColor: NSColor.labelColor]))
        }
        if !detail.isEmpty {
            t.append(NSAttributedString(string: "   \(detail)", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return t
    }

    func entryTitle(_ group: [Entry], inProject: Bool = false) -> NSAttributedString {
        let e = group[0]
        if e.system {
            let ports = group.map { ":\($0.port)" }.joined(separator: " ")
            return rowTitle(port: "", name: e.name, probe: nil, detail: ports)
        }
        let port = group.count > 1 ? ":\(e.port) +\(group.count - 1)" : ":\(e.port)"
        let probe = group.compactMap { prober.label($0.key) }.first { !$0.isEmpty }
        var detail = e.info?.tag ?? ""
        if !inProject && !e.project.isEmpty {
            detail += (detail.isEmpty ? "" : "   ") + e.cwd + (e.branch.isEmpty ? "" : "  ⎇ \(e.branch)")
        }
        let hung = group.contains { prober.hung($0.key) }
        let t = NSMutableAttributedString(attributedString: rowTitle(port: port, name: e.display, probe: probe, detail: detail))
        if hung, let it = menuItems[e.key] { it.image = symbolImage("exclamationmark.triangle.fill", .systemRed) }
        if hung {
            t.append(NSAttributedString(string: "   ⚠︎ not responding", attributes: [.font: small, .foregroundColor: NSColor.systemRed]))
        }
        return t
    }

    func projectItem(_ e: Entry) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let t = NSMutableAttributedString(string: e.cwd, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if !e.branch.isEmpty {
            t.append(NSAttributedString(string: "   ⎇ \(e.branch)", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        it.attributedTitle = t
        it.image = symbolImage("folder.fill", .secondaryLabelColor)
        let box = Box(e)
        it.representedObject = box
        let sub = NSMenu()
        if !editor.isEmpty { sub.addItem(action("Open project in \(editor)", #selector(openInEditor(_:)), box)) }
        sub.addItem(action("Open project in \(terminal)", #selector(openInTerm(_:)), box))
        sub.addItem(action("Reveal project in Finder", #selector(revealInFinder(_:)), box))
        it.submenu = sub
        return it
    }

    func stoppedItem(_ r: RememberedServer) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let t = NSMutableAttributedString(string: ":\(r.port)".padding(toLength: 7, withPad: " ", startingAt: 0), attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor])
        t.append(NSAttributedString(string: r.display, attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
        t.append(NSAttributedString(string: "   \(tilde(r.cwd))   \(ago(r.lastSeen))", attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor]))
        it.attributedTitle = t
        it.image = symbolImage("clock.arrow.circlepath", .tertiaryLabelColor)
        searchable.append((it, (":\(r.port) " + r.display + " " + tilde(r.cwd) + " stopped").lowercased()))
        let sub = NSMenu()
        let start = NSMenuItem(title: "Start again (in a new Terminal window)", action: #selector(startAgain(_:)), keyEquivalent: "")
        start.target = self; start.representedObject = r.id
        sub.addItem(start)
        let forget = NSMenuItem(title: "Forget", action: #selector(forgetServer(_:)), keyEquivalent: "")
        forget.target = self; forget.representedObject = r.id
        sub.addItem(forget)
        sub.addItem(.separator())
        sub.addItem(header(String(r.argv.joined(separator: " ").prefix(100))))
        sub.addItem(header("in \(tilde(r.cwd))"))
        it.submenu = sub
        return it
    }

    func updateRow(_ key: String) {
        guard let it = menuItems[key] else { return }
        if let box = it.representedObject as? Box {
            if box.entry != nil, let group = rowGroups[key] {
                it.attributedTitle = entryTitle(group, inProject: rowInProject.contains(key))
            } else if let c = box.container {
                it.attributedTitle = containerTitle(c)
            }
        }
    }

    var rowGroups: [String: [Entry]] = [:]

    var rowInProject: Set<String> = []

    // Search: a text field at the top of the menu; rows that don't match are hidden while it is open.
    let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 520, height: 24))
    var searchable: [(item: NSMenuItem, text: String)] = []
    var sectionHeaders: [(header: NSMenuItem, rows: [NSMenuItem])] = []

    func searchItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 548, height: 30))
        container.autoresizingMask = [.width]
        searchField.frame = NSRect(x: 14, y: 3, width: container.frame.width - 28, height: 24)
        searchField.autoresizingMask = [.width]
        searchField.placeholderString = "Filter by port, program, project, branch…"
        searchField.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        searchField.controlSize = .small
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.stringValue = ""
        container.addSubview(searchField)
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.view = container
        return it
    }

    @objc func searchChanged() { applyFilter(searchField.stringValue) }

    func applyFilter(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        for (item, text) in searchable { item.isHidden = !q.isEmpty && !text.contains(q) }
        for (header, rows) in sectionHeaders { header.isHidden = !q.isEmpty && rows.allSatisfy { $0.isHidden } }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.searchField.window?.makeFirstResponder(self.searchField)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        searchField.stringValue = ""
    }

    func entryItem(_ group: [Entry], inProject: Bool = false) -> NSMenuItem {
        let e = group[0]
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.attributedTitle = entryTitle(group, inProject: inProject)
        if inProject { for g in group { rowInProject.insert(g.key) } }
        let (sym, color) = rowSymbol(e)
        it.image = group.contains(where: { prober.hung($0.key) }) ? symbolImage("exclamationmark.triangle.fill", .systemRed) : symbolImage(sym, color)
        let text = (group.map { ":\($0.port)" }.joined(separator: " ") + " " + e.display + " " + e.name + " " + (prober.label(e.key) ?? "")
                    + " " + (e.info?.tag ?? "") + " " + e.cwd + " " + e.branch).lowercased()
        searchable.append((it, text))
        let box = Box(e)
        it.representedObject = box
        for g in group { menuItems[g.key] = it; rowGroups[g.key] = group }

        let sub = NSMenu()
        if group.contains(where: { prober.hung($0.key) }) {
            sub.addItem(header("⚠︎ Answered HTTP before, but not any more"))
            sub.addItem(action("Restart (in a new Terminal window)", #selector(restart(_:)), box))
            sub.addItem(.separator())
        }
        for g in group {
            let b = Box(g)
            sub.addItem(action("Open \(g.url)", #selector(openURL(_:)), b))
        }
        for r in routes(for: e, probeLabel: prober.label(e.key)) {
            let m = action("Open \(r)", #selector(openRoute(_:)), box)
            m.representedObject = [box, r] as [Any]
            m.indentationLevel = 1
            sub.addItem(m)
        }
        sub.addItem(action(group.count > 1 ? "Copy URL (:\(e.port))" : "Copy URL", #selector(copyURL(_:)), box))
        sub.addItem(.separator())
        let hasDir = !e.cwd.isEmpty && e.cwd != "/"
        if hasDir {
            if !editor.isEmpty { sub.addItem(action("Open project in \(editor)", #selector(openInEditor(_:)), box)) }
            let others = installedApps(editorCandidates).filter { $0 != editor }
            if !others.isEmpty {
                let m = NSMenuItem(title: "Open project in…", action: nil, keyEquivalent: "")
                let om = NSMenu()
                for name in others {
                    let a = action(name, #selector(openInNamedEditor(_:)), box)
                    a.representedObject = [box, name] as [Any]
                    om.addItem(a)
                }
                m.submenu = om
                sub.addItem(m)
            }
            sub.addItem(action("Open project in \(terminal)", #selector(openInTerm(_:)), box))
            sub.addItem(action("Reveal project in Finder", #selector(revealInFinder(_:)), box))
            sub.addItem(.separator())
        }
        sub.addItem(action("Restart (in a new Terminal window)", #selector(restart(_:)), box))
        sub.addItem(action("Kill (SIGTERM)", #selector(killTerm(_:)), box))
        sub.addItem(action("Force Kill (SIGKILL)", #selector(killForce(_:)), box))
        sub.addItem(.separator())
        let ports = group.map { "\($0.addr):\($0.port)" }.joined(separator: ", ")
        sub.addItem(header("\(e.name)  ·  pid \(e.pid)  ·  \(ports.prefix(80))"))
        if let info = e.info {
            if !info.tag.isEmpty { sub.addItem(header(info.tag)) }
            for d in info.details { sub.addItem(header(String(d.prefix(100)))) }
        }
        if !e.shortCmd.isEmpty { sub.addItem(header(String(e.shortCmd.prefix(100)))) }
        it.submenu = sub
        return it
    }

    func containerTitle(_ c: Container) -> NSAttributedString {
        let ports = c.ports.map { ":\($0.host)" }.joined(separator: " ")
        let probe = c.ports.compactMap { prober.label("\(c.key):\($0.host)") }.first { !$0.isEmpty }
        return rowTitle(port: ports.isEmpty ? "—" : ports, name: c.name, probe: probe, detail: c.image)
    }

    func containerItem(_ c: Container) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.attributedTitle = containerTitle(c)
        it.image = symbolImage("shippingbox.fill", .systemBlue)
        searchable.append((it, (c.ports.map { ":\($0.host)" }.joined(separator: " ") + " " + c.name + " " + c.image + " docker").lowercased()))
        let box = Box(c, port: c.ports.first?.host ?? 0)
        it.representedObject = box
        for p in c.ports { menuItems["\(c.key):\(p.host)"] = it }

        let sub = NSMenu()
        for p in c.ports where p.proto == "tcp" {
            let b = Box(c, port: p.host)
            sub.addItem(action("Open \(c.url(p.host))  (container :\(p.container))", #selector(openURL(_:)), b))
            sub.addItem(action("Copy \(c.url(p.host))", #selector(copyURL(_:)), b))
        }
        if !c.ports.isEmpty { sub.addItem(.separator()) }
        sub.addItem(action("Stop container", #selector(dockerStop(_:)), box))
        sub.addItem(action("Restart container", #selector(dockerRestart(_:)), box))
        sub.addItem(.separator())
        sub.addItem(header("\(c.image)  ·  \(c.status)"))
        sub.addItem(header("id \(c.id)"))
        it.submenu = sub
        return it
    }

    func action(_ t: String, _ sel: Selector, _ box: Box) -> NSMenuItem {
        let m = NSMenuItem(title: t, action: sel, keyEquivalent: "")
        m.target = self
        m.representedObject = box
        return m
    }

    func box(_ sender: Any?) -> Box? { (sender as? NSMenuItem)?.representedObject as? Box }

    // MARK: actions

    @objc func openURL(_ sender: Any?) {
        guard let b = box(sender) else { return }
        let s = b.entry?.url ?? b.container?.url(b.port) ?? ""
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    @objc func copyURL(_ sender: Any?) {
        guard let b = box(sender) else { return }
        let s = b.entry?.url ?? b.container?.url(b.port) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func killTerm(_ sender: Any?) { if let e = box(sender)?.entry { doKill(e, SIGTERM) } }
    @objc func killForce(_ sender: Any?) { if let e = box(sender)?.entry { doKill(e, SIGKILL) } }

    func doKill(_ e: Entry, _ sig: Int32) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(sig == SIGKILL ? "Force kill" : "Kill") \(e.name) on :\(e.port)?"
        a.informativeText = "pid \(e.pid)\n\(e.shortCmd.prefix(200))"
        a.alertStyle = .warning
        a.addButton(withTitle: sig == SIGKILL ? "Force Kill" : "Kill")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if kill(e.pid, sig) != 0 {
            let err = NSAlert()
            err.messageText = "Could not kill pid \(e.pid)"
            err.informativeText = String(cString: strerror(errno))
            err.runModal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refreshAsync() }
    }

    func projectDir(_ sender: Any?) -> String? {
        guard let e = (box(sender) ?? ((sender as? NSMenuItem)?.representedObject as? [Any])?.first as? Box)?.entry,
              !e.cwd.isEmpty, e.cwd != "/" else { return nil }
        return e.cwd.hasPrefix("~") ? home + e.cwd.dropFirst() : e.cwd
    }

    @objc func openRoute(_ sender: Any?) {
        guard let pair = (sender as? NSMenuItem)?.representedObject as? [Any], let b = pair.first as? Box, let e = b.entry,
              let r = pair.last as? String, let u = URL(string: e.url + r) else { return }
        NSWorkspace.shared.open(u)
    }

    @objc func startAgain(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String, let r = store.servers[id] else { return }
        guard let script = writeRestartScript(argv: r.argv, env: r.env, cwd: r.cwd, port: r.port) else { return }
        _ = run("/usr/bin/open", ["-b", "com.apple.terminal", script.path])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refreshAsync() }
    }

    @objc func forgetServer(_ sender: Any?) {
        if let id = (sender as? NSMenuItem)?.representedObject as? String { store.forget(id) }
    }

    @objc func openInEditor(_ sender: Any?) {
        guard let dir = projectDir(sender), !editor.isEmpty else { return }
        _ = run("/usr/bin/open", ["-a", editor, dir])
    }

    @objc func openInNamedEditor(_ sender: Any?) {
        guard let dir = projectDir(sender), let pair = (sender as? NSMenuItem)?.representedObject as? [Any], let name = pair.last as? String else { return }
        _ = run("/usr/bin/open", ["-a", name, dir])
    }

    @objc func openInTerm(_ sender: Any?) {
        guard let dir = projectDir(sender) else { return }
        openInTerminal(terminal, dir: dir)
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let dir = projectDir(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
    }

    func pickApp() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    @objc func pickEditor() { if let name = pickApp() { editor = name } }
    @objc func pickTerminal() { if let name = pickApp() { terminal = name } }

    @objc func chooseEditor(_ sender: Any?) {
        if let s = (sender as? NSMenuItem)?.representedObject as? String { editor = s }
    }

    @objc func chooseTerminal(_ sender: Any?) {
        if let s = (sender as? NSMenuItem)?.representedObject as? String { terminal = s }
    }

    @objc func chooseIcon(_ sender: Any?) {
        if let s = (sender as? NSMenuItem)?.representedObject as? String { iconSymbol = s }
    }

    @objc func restart(_ sender: Any?) {
        guard let e = box(sender)?.entry else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let (_, argv, env) = procArgsEnv(e.pid) else {
            let a = NSAlert()
            a.messageText = "Cannot read the command line of pid \(e.pid)"
            a.informativeText = "Only your own processes can be restarted."
            a.runModal()
            return
        }
        let cwd = e.cwd.hasPrefix("~") ? home + e.cwd.dropFirst() : e.cwd
        let a = NSAlert()
        a.messageText = "Restart \(e.name) on :\(e.port)?"
        a.informativeText = "It will be stopped and started again in a new Terminal window, with the same command, directory and environment.\n\n\(argv.joined(separator: " ").prefix(200))\nin \(e.cwd)"
        a.addButton(withTitle: "Restart")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let script = writeRestartScript(argv: argv, env: env, cwd: cwd, port: e.port) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            kill(e.pid, SIGTERM)
            var gone = false
            for _ in 0..<50 { usleep(100_000); if kill(e.pid, 0) != 0 { gone = true; break } }
            if !gone { kill(e.pid, SIGKILL); usleep(300_000) }
            _ = run("/usr/bin/open", ["-b", "com.apple.terminal", script.path])
            DispatchQueue.main.async { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshAsync() } }
        }
    }

    @objc func dockerStop(_ sender: Any?) { if let c = box(sender)?.container { dockerCmd("stop", c) } }
    @objc func dockerRestart(_ sender: Any?) { if let c = box(sender)?.container { dockerCmd("restart", c) } }

    func dockerCmd(_ verb: String, _ c: Container) {
        guard let bin = dockerBin else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = run(bin, [verb, c.id])
            DispatchQueue.main.async { self.refreshAsync() }
        }
    }

    @objc func whoHasPort() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Who has port…"
        a.informativeText = "Enter a port number to see which process or container is using it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "3000"
        a.accessoryView = field
        a.addButton(withTitle: "Look up")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn, let port = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
        refreshSync()
        let r = NSAlert()
        if let e = entries.first(where: { $0.port == port }) {
            r.messageText = "Port \(port) is used by \(e.name) (pid \(e.pid))"
            var info = "\(e.addr):\(e.port)"
            if !e.cwd.isEmpty && e.cwd != "/" { info += "\n\(e.cwd)" }
            if !e.shortCmd.isEmpty { info += "\n\(e.shortCmd.prefix(200))" }
            if let i = e.info ?? describeEnv(pid: e.pid, cwd: e.cwd), !i.tag.isEmpty { info += "\n\(i.tag)" }
            if let c = containers.first(where: { $0.ports.contains { $0.host == port } }) { info += "\nDocker container: \(c.name) (\(c.image))" }
            r.informativeText = info
            r.addButton(withTitle: "Open")
            r.addButton(withTitle: "Kill")
            r.addButton(withTitle: "Close")
            switch r.runModal() {
            case .alertFirstButtonReturn: if let u = URL(string: e.url) { NSWorkspace.shared.open(u) }
            case .alertSecondButtonReturn: doKill(e, SIGTERM)
            default: break
            }
        } else {
            r.messageText = "Port \(port) is free"
            r.informativeText = "Nothing is listening on TCP port \(port)."
            r.runModal()
        }
    }

    @objc func toggleNotify() { notifyEnabled.toggle() }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
