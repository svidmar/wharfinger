// Ports – menu bar app: see, open and kill local listening servers.
// Build with ./build.sh (plain swiftc, no Xcode project needed).

import AppKit
import Carbon.HIToolbox
import ServiceManagement

let home = NSHomeDirectory()
let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/", "/Applications/", home + "/Library/", "/private/var/"]
let localAddrs: Set<String> = ["*", "0.0.0.0", "127.0.0.1", "::", "::1", "[::]", "[::1]", "localhost"]

struct Entry {
    let port: Int
    let addr: String
    let pid: Int32
    let name: String
    let cmd: String
    let cwd: String
    let system: Bool

    var url: String { "http://\(localAddrs.contains(addr) ? "localhost" : addr):\(port)" }

    var shortCmd: String {
        var parts = cmd.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return "" }
        parts[0] = (parts[0] as NSString).lastPathComponent
        return parts.map(tilde).joined(separator: " ")
    }
}

final class Box: NSObject {
    let entry: Entry
    init(_ e: Entry) { entry = e }
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

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    var entries: [Entry] = []
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Ports")
        item.button?.imagePosition = .imageLeading
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        menu.delegate = self
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        registerHotKey()
    }

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

    func refresh() {
        entries = collect()
        let dev = entries.filter { !$0.system }.count
        item.button?.title = dev > 0 ? " \(dev)" : ""
    }

    // Rebuild the menu every time it opens so it is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        let dev = entries.filter { !$0.system }
        let other = entries.filter { $0.system }

        if dev.isEmpty {
            menu.addItem(header("No dev servers listening"))
        } else {
            menu.addItem(header("Dev servers"))
            dev.forEach { menu.addItem(entryItem($0)) }
        }
        menu.addItem(.separator())
        if !other.isEmpty {
            let sub = NSMenu()
            other.forEach { sub.addItem(entryItem($0)) }
            let it = NSMenuItem(title: "Apps & system (\(other.count))", action: nil, keyEquivalent: "")
            it.submenu = sub
            menu.addItem(it)
            menu.addItem(.separator())
        }
        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(header("⌃⌥P opens this menu anywhere"))
        menu.addItem(withTitle: "Quit Ports", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func header(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    func entryItem(_ e: Entry) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let mono = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString(string: String(format: ":%-5d  ", e.port), attributes: [.font: mono])
        title.append(NSAttributedString(string: e.name, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
        let where_ = e.cwd.isEmpty || e.cwd == "/" ? "" : e.cwd
        if !where_.isEmpty {
            title.append(NSAttributedString(string: "   \(where_)", attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        it.attributedTitle = title

        let sub = NSMenu()
        let box = Box(e)
        func action(_ t: String, _ sel: Selector, _ key: String = "") {
            let m = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            m.target = self
            m.representedObject = box
            sub.addItem(m)
        }
        action("Open \(e.url)", #selector(openURL(_:)))
        action("Copy URL", #selector(copyURL(_:)))
        sub.addItem(.separator())
        action("Kill (SIGTERM)", #selector(killTerm(_:)))
        action("Force Kill (SIGKILL)", #selector(killForce(_:)))
        sub.addItem(.separator())
        sub.addItem(header("pid \(e.pid)  ·  \(e.addr):\(e.port)"))
        if !e.shortCmd.isEmpty { sub.addItem(header(String(e.shortCmd.prefix(90)))) }
        it.submenu = sub
        return it
    }

    func entry(_ sender: Any?) -> Entry? { ((sender as? NSMenuItem)?.representedObject as? Box)?.entry }

    @objc func openURL(_ sender: Any?) {
        guard let e = entry(sender), let url = URL(string: e.url) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func copyURL(_ sender: Any?) {
        guard let e = entry(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.url, forType: .string)
    }

    @objc func killTerm(_ sender: Any?) { doKill(sender, SIGTERM) }
    @objc func killForce(_ sender: Any?) { doKill(sender, SIGKILL) }

    func doKill(_ sender: Any?, _ sig: Int32) {
        guard let e = entry(sender) else { return }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

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
