// Wharfinger – menu bar app: see, open, kill and restart local listening servers.
// Build with ./build.sh (plain swiftc, no Xcode project needed).

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

let home = NSHomeDirectory()
let debug = ProcessInfo.processInfo.environment["PORTS_DEBUG"] != nil
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

    var key: String { "\(pid):\(port)" }
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
            if let existing = seen[key], ["*", "0.0.0.0", "::"].contains(existing.addr) { continue }
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

    return order.map { key -> Entry in
        let s = seen[key]!
        let cmd = cmds[s.pid] ?? ""
        return Entry(port: s.port, addr: s.addr, pid: s.pid, name: s.name, cmd: cmd,
                     cwd: tilde(cwds[s.pid] ?? ""), system: isSystem(cmd: cmd, name: s.name))
    }.sorted { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
}

// MARK: - Restart

/// Exact argv and environment of one of our own processes (KERN_PROCARGS2).
func procArgsEnv(_ pid: Int32) -> (argv: [String], env: [String: String])? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size, buf[i] != 0 { i += 1 }        // exec path
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
    return (Array(strings[..<argc]), env)
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
    struct Result { let label: String; let at: Date }
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

    func probe(key: String, url: String) {
        if let r = cache[key], Date().timeIntervalSince(r.at) < (r.label.isEmpty ? 30 : 120) { return }
        guard !inflight.contains(key), let u = URL(string: url) else { return }
        inflight.insert(key)
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.setValue("Ports/1.0", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, resp, _ in
            let label = Prober.describe(data: data, resp: resp as? HTTPURLResponse)
            dbg("probe \(key) \(url) -> status \(resp.map { String(($0 as? HTTPURLResponse)?.statusCode ?? 0) } ?? "nil") label '\(label)'")
            DispatchQueue.main.async {
                self.inflight.remove(key)
                self.cache[key] = Result(label: label, at: Date())
                if !label.isEmpty { self.onResult?(key) }
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
            ("Jupyter", { lower.contains("jupyter") }),
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
        dbg("refresh: \(e.count) listeners, \(c.count) containers, dev: " + devEntries().map { ":\($0.port) \($0.name)" }.joined(separator: ", "))
        let dev = devEntries()
        let n = dev.count + containers.count
        item.button?.title = n > 0 ? " \(n)" : ""
        for e in dev { prober.probe(key: e.key, url: e.url) }
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
        content.body = body
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
        let dev = devEntries()
        let devKeys = Set(dev.map { $0.key })
        let other = entries.filter { !devKeys.contains($0.key) }

        if dev.isEmpty {
            menu.addItem(header("No dev servers listening"))
        } else {
            menu.addItem(header("Dev servers"))
            dev.forEach { menu.addItem(entryItem($0)) }
        }
        if !containers.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Docker"))
            containers.forEach { menu.addItem(containerItem($0)) }
        }
        menu.addItem(.separator())
        if !other.isEmpty {
            let sub = NSMenu()
            other.forEach { sub.addItem(entryItem($0)) }
            let it = NSMenuItem(title: "Apps & system (\(other.count))", action: nil, keyEquivalent: "")
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
        let t = NSMutableAttributedString(string: port.padding(toLength: 7, withPad: " ", startingAt: 0), attributes: [.font: mono])
        t.append(NSAttributedString(string: name, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        if let p = probe, !p.isEmpty {
            t.append(NSAttributedString(string: "   \(p)", attributes: [.font: small, .foregroundColor: NSColor.labelColor]))
        }
        if !detail.isEmpty {
            t.append(NSAttributedString(string: "   \(detail)", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return t
    }

    func updateRow(_ key: String) {
        guard let it = menuItems[key] else { return }
        if let box = it.representedObject as? Box {
            if let e = box.entry {
                it.attributedTitle = rowTitle(port: ":\(e.port)", name: e.name, probe: prober.label(e.key), detail: e.cwd == "/" ? "" : e.cwd)
            } else if let c = box.container {
                it.attributedTitle = containerTitle(c)
            }
        }
    }

    func entryItem(_ e: Entry) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.attributedTitle = rowTitle(port: ":\(e.port)", name: e.name, probe: prober.label(e.key), detail: e.cwd == "/" ? "" : e.cwd)
        let box = Box(e)
        it.representedObject = box
        menuItems[e.key] = it

        let sub = NSMenu()
        sub.addItem(action("Open \(e.url)", #selector(openURL(_:)), box))
        sub.addItem(action("Copy URL", #selector(copyURL(_:)), box))
        sub.addItem(.separator())
        sub.addItem(action("Restart (in a new Terminal window)", #selector(restart(_:)), box))
        sub.addItem(action("Kill (SIGTERM)", #selector(killTerm(_:)), box))
        sub.addItem(action("Force Kill (SIGKILL)", #selector(killForce(_:)), box))
        sub.addItem(.separator())
        sub.addItem(header("pid \(e.pid)  ·  \(e.addr):\(e.port)"))
        if !e.shortCmd.isEmpty { sub.addItem(header(String(e.shortCmd.prefix(90)))) }
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

    @objc func chooseIcon(_ sender: Any?) {
        if let s = (sender as? NSMenuItem)?.representedObject as? String { iconSymbol = s }
    }

    @objc func restart(_ sender: Any?) {
        guard let e = box(sender)?.entry else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard let (argv, env) = procArgsEnv(e.pid) else {
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
