// DWIM — "do what I mean" command palette for any Mac app.
// Hotkey → type what you want → Jev ranks the frontmost app's menu items → Enter runs it.
import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// MARK: - Menu reading (accessibility API)

struct MenuItem {
    let path: String
    let enabled: Bool
    let shortcut: String
    let element: AXUIElement
}

func axAttr(_ e: AXUIElement, _ k: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
}

// Submenus that hold personal or dynamic content. Never read, never sent to the API.
let privateMenus: Set<String> = ["Apple", "Services", "Open Recent", "Recent Items", "Recent Notes", "Recent Folders",
                                 "History", "Bookmarks", "Sharing", "Open With", "Always Open With", "Open Page With",
                                 "Move to", "Copy to", "Profiles", "Tab Groups", "Reading List"]

func shortcutString(_ e: AXUIElement) -> String {
    guard let ch = axAttr(e, "AXMenuItemCmdChar") as? String, !ch.isEmpty else { return "" }
    let m = (axAttr(e, "AXMenuItemCmdModifiers") as? Int) ?? 0
    return (m & 4 != 0 ? "⌃" : "") + (m & 2 != 0 ? "⌥" : "") + (m & 1 != 0 ? "⇧" : "") + (m & 8 == 0 ? "⌘" : "") + ch
}

func readMenus(of app: NSRunningApplication) -> [MenuItem] {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    guard let bar = axAttr(ax, kAXMenuBarAttribute) else { return [] }
    // Window titles show up in the Window menu; they are document names, so drop them.
    var windowTitles = Set<String>()
    for w in (axAttr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        if let t = axAttr(w, kAXTitleAttribute) as? String, !t.isEmpty { windowTitles.insert(t) }
    }
    var out: [MenuItem] = [], seen = Set<String>()
    func walk(_ e: AXUIElement, _ path: [String]) {
        for k in (axAttr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            let role = axAttr(k, kAXRoleAttribute) as? String ?? ""
            let title = (axAttr(k, kAXTitleAttribute) as? String ?? "").trimmingCharacters(in: .whitespaces)
            if privateMenus.contains(title) { continue }
            var p = path
            if (role == "AXMenuItem" || role == "AXMenuBarItem") && !title.isEmpty {
                if windowTitles.contains(title) { continue }
                p.append(title)
                let hasSub = ((axAttr(k, kAXChildrenAttribute) as? [AXUIElement])?.isEmpty == false)
                if role == "AXMenuItem" && !hasSub {
                    let full = p.joined(separator: " > ")
                    if seen.insert(full).inserted {
                        out.append(MenuItem(path: full, enabled: (axAttr(k, kAXEnabledAttribute) as? Bool) ?? false,
                                            shortcut: shortcutString(k), element: k))
                    }
                }
            }
            walk(k, p)
        }
    }
    walk(bar as! AXUIElement, [])
    return out
}

// MARK: - Jev client

enum Jev {
    static let url = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let question = "A user of the Mac app `app` typed `request` into a command palette. Would choosing the menu item \"%@\" do what they asked for?"
    static let criteria = ["true": "Choosing this menu item performs the requested action or opens exactly the feature they need.",
                           "false": "This menu item does something else, or is only loosely related."]

    /// Bring your own key: TYPESAFE_API_KEY in the environment, or in ~/.config/dwim/env (written by "Set Jev API key…").
    static let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/dwim/env")
    static var key: String? {
        if let k = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !k.isEmpty { return k }
        guard let text = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("TYPESAFE_API_KEY=") {
            let k = line.dropFirst("TYPESAFE_API_KEY=".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !k.isEmpty { return k }
        }
        return nil
    }
    static func saveKey(_ k: String) throws {
        try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "TYPESAFE_API_KEY=\(k)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)   // readable only by you
    }

    static func batch(app: String, request: String, paths: [String]) async throws -> [Double] {
        guard let key else { throw NSError(domain: "dwim", code: 1, userInfo: [NSLocalizedDescriptionKey: "No TYPESAFE_API_KEY found"]) }
        var questions: [String: Any] = [:]
        for (i, p) in paths.enumerated() {
            questions["q\(i)"] = ["type": "noul", "instructions": String(format: question, p), "criteria": criteria]
        }
        let body: [String: Any] = ["model": "jev-latest", "state": ["app": app, "request": request], "questions": questions]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = json["answers"] as? [String: [String: Any]] else {
            throw NSError(domain: "dwim", code: 2, userInfo: [NSLocalizedDescriptionKey: "Jev error: " + (String(data: data, encoding: .utf8) ?? "").prefix(200)])
        }
        return paths.indices.map { (answers["q\($0)"]?["noul"] as? Double) ?? 0 }
    }

    /// One yes/no per menu item, batches of 64 in parallel. Returns a probability per path.
    static func rank(app: String, request: String, paths: [String]) async throws -> [Double] {
        let size = 64
        let chunks = stride(from: 0, to: paths.count, by: size).map { Array(paths[$0..<min($0 + size, paths.count)]) }
        return try await withThrowingTaskGroup(of: (Int, [Double]).self) { group in
            for (i, c) in chunks.enumerated() { group.addTask { (i, try await batch(app: app, request: request, paths: c)) } }
            var parts = [[Double]](repeating: [], count: chunks.count)
            for try await (i, p) in group { parts[i] = p }
            return parts.flatMap { $0 }
        }
    }
}

// MARK: - Command-line mode (for testing): DWIM --query <AppName> <request> [--run]

let args = CommandLine.arguments
if args.count >= 4, args[1] == "--query" {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == args[2] }) else { print("app not running"); exit(1) }
    let items = readMenus(of: app)
    let sem = DispatchSemaphore(value: 0)
    Task {
        let t0 = Date()
        do {
            let probs = try await Jev.rank(app: args[2], request: args[3], paths: items.map(\.path))
            let top = zip(items, probs).sorted { $0.1 > $1.1 }.prefix(5)
            print("\(items.count) items, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            for (it, p) in top { print(String(format: "  %.2f  %@%@  %@", p, it.path, it.enabled ? "" : " (disabled)", it.shortcut)) }
            if args.contains("--run"), let first = top.first, first.0.enabled {
                print("pressing:", first.0.path, AXUIElementPerformAction(first.0.element, kAXPressAction as CFString) == .success ? "ok" : "failed")
            }
        } catch { print("error:", error.localizedDescription) }
        sem.signal()
    }
    sem.wait(); exit(0)
}

// MARK: - Palette UI

final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

final class Palette: NSObject, NSTextFieldDelegate {
    let panel: KeyPanel
    let field = NSTextField()
    let status = NSTextField(labelWithString: "")
    var rows: [NSTextField] = []
    let sep = NSBox()
    var expanded = true
    var target: NSRunningApplication?
    var items: [MenuItem] = []
    var results: [(MenuItem, Double)] = []
    var selected = 0
    var pending: Task<Void, Never>?
    var resultsFor = ""          // the text the current results were computed for
    var runWhenReady = false     // Enter was pressed before results arrived
    let maxRows = 5
    // Auto-run threshold. In the 72-intent check: 0.50 alone ran 65/72 with 3 near-synonym misses (all undoable);
    // 0.70 plus a 0.15 lead over the runner-up ran 47/72 with none.
    // Tune without rebuilding: defaults write com.rohitm.dwim confident 0.6 ; defaults write com.rohitm.dwim lead 0.1
    static var confident: Double { UserDefaults.standard.object(forKey: "confident") as? Double ?? 0.50 }
    static var lead: Double { UserDefaults.standard.object(forKey: "lead") as? Double ?? 0.0 }
    static let destructive = try! NSRegularExpression(pattern: "delete|erase|empty|revert|remove|trash|quit|close all|reset|clear", options: .caseInsensitive)

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 250),
                         styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.state = .active
        panel.contentView = fx

        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(field)
        sep.boxType = .separator; stack.addArrangedSubview(sep)
        for _ in 0..<maxRows {
            let r = NSTextField(labelWithString: ""); r.font = .systemFont(ofSize: 14); r.lineBreakMode = .byTruncatingMiddle
            r.wantsLayer = true; r.layer?.cornerRadius = 5
            rows.append(r); stack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
            r.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }
        status.font = .systemFont(ofSize: 11); status.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(status)
        fx.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
                                     field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
                                     sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)])
    }

    /// Compact = just the text field and a status line. Expanded = also the ranked list. The top edge stays put.
    func setExpanded(_ on: Bool) {
        guard on != expanded else { return }
        expanded = on
        sep.isHidden = !on; rows.forEach { $0.isHidden = !on }
        let h: CGFloat = on ? 250 : 84, f = panel.frame
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true, animate: false)
    }

    func toggle() {
        if panel.isVisible { close(); return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary); return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        target = app; items = []; results = []; selected = 0; resultsFor = ""; runWhenReady = false
        field.stringValue = ""; field.placeholderString = "What do you want to do in \(app.localizedName ?? "this app")?"
        setExpanded(false); render(); status.stringValue = "reading menus…"
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.midY + f.height * 0.12))
        }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field)
        DispatchQueue.global(qos: .userInitiated).async {
            let read = readMenus(of: app)
            DispatchQueue.main.async {
                guard self.target == app else { return }
                self.items = read
                self.status.stringValue = Jev.key == nil ? "No Jev API key yet: click ⌘? in the menu bar → Set Jev API key…" : "\(read.count) menu items"
                if !self.field.stringValue.isEmpty { self.query() }
            }
        }
    }

    func close() { pending?.cancel(); panel.orderOut(nil) }

    func controlTextDidChange(_ obj: Notification) { runWhenReady = false; query() }

    func query(debounce: Bool = true) {
        pending?.cancel()
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3, !items.isEmpty, let app = target else { results = []; render(); return }
        let snapshot = items
        pending = Task { @MainActor in
            if debounce { try? await Task.sleep(nanoseconds: 220_000_000) }   // wait for a pause in typing
            if Task.isCancelled { return }
            let t0 = Date()
            do {
                let probs = try await Jev.rank(app: app.localizedName ?? "", request: text, paths: snapshot.map(\.path))
                if Task.isCancelled { return }
                self.results = Array(zip(snapshot, probs).sorted { $0.1 > $1.1 }.prefix(self.maxRows))
                self.selected = 0; self.resultsFor = text
                // Results only arrive after a pause in typing (debounce + Jev). If the top pick is confident, clearly ahead of
                // the runner-up and not destructive, run it without waiting for Enter. Esc or more typing in the flash cancels.
                if let top = self.results.first, self.runWhenReady || (Settings.autoRun && text.count >= 4) {
                    self.runWhenReady = false
                    let risky = Palette.destructive.firstMatch(in: top.0.path, range: NSRange(top.0.path.startIndex..., in: top.0.path)) != nil
                    let ahead = top.1 - (self.results.count > 1 ? self.results[1].1 : 0)
                    if top.1 >= Palette.confident && ahead >= Palette.lead && !risky {
                        self.status.stringValue = "→  " + top.0.path.replacingOccurrences(of: " > ", with: " › ") + (top.0.shortcut.isEmpty ? "" : "   " + top.0.shortcut)
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        if Task.isCancelled || !self.panel.isVisible || self.field.stringValue.trimmingCharacters(in: .whitespaces) != text { return }
                        self.run(); return
                    }
                }
                self.setExpanded(true)
                self.status.stringValue = "not sure — ↑↓ to choose, ↩ to run, esc to close · \(snapshot.count) menu items · \(Int(Date().timeIntervalSince(t0) * 1000)) ms"
            } catch {
                if Task.isCancelled { return }
                self.results = []; self.status.stringValue = error.localizedDescription
            }
            self.render()
        }
    }

    func render() {
        for (i, r) in rows.enumerated() {
            guard i < results.count else { r.stringValue = ""; r.layer?.backgroundColor = nil; continue }
            let (it, p) = results[i]
            let s = NSMutableAttributedString(string: "  " + it.path.replacingOccurrences(of: " > ", with: "  ›  "),
                                              attributes: [.foregroundColor: it.enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor])
            let tail = (it.enabled ? "" : "   may be unavailable") + (it.shortcut.isEmpty ? "" : "   \(it.shortcut)") + String(format: "   %.0f%%", p * 100)
            s.append(NSAttributedString(string: tail, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
            r.attributedStringValue = s
            r.layer?.backgroundColor = i == selected ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): if !results.isEmpty { selected = min(selected + 1, results.count - 1); render() }; return true
        case #selector(NSResponder.moveUp(_:)): if !results.isEmpty { selected = max(selected - 1, 0); render() }; return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if resultsFor == text && !results.isEmpty { run() }
            else if Settings.instantRun { runWhenReady = true; status.stringValue = "finding it…"; query(debounce: false) }
            return true
        default: return false
        }
    }

    func run() {
        guard selected < results.count else { return }
        let item = results[selected].0
        // "enabled" can be stale (apps validate menus lazily), so it is only a hint: always try the press.
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if AXUIElementPerformAction(item.element, kAXPressAction as CFString) != .success { NSSound.beep() }
        }
    }
}

// MARK: - Settings (stored in UserDefaults; changed from the menu-bar icon)

enum Trigger: String, CaseIterable {
    case rightOption, anyOption, doubleOption, hotkey
    var label: String {
        switch self {
        case .rightOption: return "Tap Right Option (⌥)"
        case .anyOption: return "Tap either Option (⌥)"
        case .doubleOption: return "Double-tap Option (⌥⌥)"
        case .hotkey: return "Control + Option + Space"
        }
    }
}

enum Settings {
    static var trigger: Trigger {
        get { Trigger(rawValue: UserDefaults.standard.string(forKey: "trigger") ?? "") ?? .rightOption }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "trigger") }
    }
    static var autoRun: Bool {
        get { UserDefaults.standard.object(forKey: "autoRun") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoRun") }
    }
    static var instantRun: Bool {
        get { UserDefaults.standard.object(forKey: "instantRun") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "instantRun") }
    }
}

/// Detects a clean tap of the Option key: pressed and released quickly, alone, with no other key or click in between.
final class OptionTap {
    var onTrigger: () -> Void = {}
    private var downAt: Date?, downKey: UInt16 = 0, clean = false, lastTap = Date.distantPast
    private var monitors: [Any] = []

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
        let dirty: (NSEvent) -> Void = { [weak self] _ in self?.clean = false }
        let noise: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any,
                    NSEvent.addGlobalMonitorForEvents(matching: noise, handler: dirty) as Any,
                    NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 } as Any,
                    NSEvent.addLocalMonitorForEvents(matching: noise) { dirty($0); return $0 } as Any]
    }

    private func flagsChanged(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.option, .command, .control, .shift])
        let isOptionKey = e.keyCode == 58 || e.keyCode == 61   // left, right
        if mods == [.option], isOptionKey, downAt == nil { downAt = Date(); downKey = e.keyCode; clean = true; return }
        defer { if mods.isEmpty { downAt = nil } }
        guard mods.isEmpty, let t = downAt, clean, Date().timeIntervalSince(t) < 0.35 else { clean = false; return }
        switch Settings.trigger {
        case .rightOption: if downKey == 61 { onTrigger() }
        case .anyOption: onTrigger()
        case .doubleOption:
            if Date().timeIntervalSince(lastTap) < 0.4 { lastTap = .distantPast; onTrigger() } else { lastTap = Date() }
        case .hotkey: break
        }
    }
}

// MARK: - App: menu-bar icon + triggers

final class AppDelegate: NSObject, NSApplicationDelegate {
    let palette = Palette()
    let optionTap = OptionTap()
    var statusItem: NSStatusItem!
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌘?"
        rebuildMenu()
        optionTap.onTrigger = { [weak self] in self?.palette.toggle() }
        optionTap.start()
        applyTrigger()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { me.palette.toggle() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        if Jev.key == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.setKey() } }
        if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open palette", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let head = menu.addItem(withTitle: "Open with", action: nil, keyEquivalent: ""); head.isEnabled = false
        for t in Trigger.allCases {
            let it = menu.addItem(withTitle: t.label, action: #selector(pickTrigger(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = t.rawValue; it.state = Settings.trigger == t ? .on : .off; it.indentationLevel = 1
        }
        menu.addItem(.separator())
        let ar = menu.addItem(withTitle: "Run confident matches automatically (no Enter)", action: #selector(toggleAuto), keyEquivalent: "")
        ar.target = self; ar.state = Settings.autoRun ? .on : .off
        let ir = menu.addItem(withTitle: "Enter runs the top match right away when confident", action: #selector(toggleInstant), keyEquivalent: "")
        ir.target = self; ir.state = Settings.instantRun ? .on : .off
        menu.addItem(.separator())
        let k = menu.addItem(withTitle: Jev.key == nil ? "Set Jev API key… (required)" : "Change Jev API key…", action: #selector(setKey), keyEquivalent: "")
        k.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DWIM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func applyTrigger() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if Settings.trigger == .hotkey {
            RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4457494D, id: 1), GetApplicationEventTarget(), 0, &hotKeyRef)
        }
    }

    @objc func pickTrigger(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let t = Trigger(rawValue: raw) { Settings.trigger = t }
        applyTrigger(); rebuildMenu()
    }

    @objc func setKey() {
        let alert = NSAlert()
        alert.messageText = "Jev API key"
        alert.informativeText = "DWIM uses your own TypeSafe (Jev) key. It is stored only on this Mac, in ~/.config/dwim/env, readable only by you. Get one at typesafe.ai."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "paste your key"
        alert.accessoryView = input
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let k = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        do { try Jev.saveKey(k) } catch { NSAlert(error: error).runModal() }
        rebuildMenu()
    }

    @objc func toggleAuto() { Settings.autoRun.toggle(); rebuildMenu() }

    @objc func toggleInstant() { Settings.instantRun.toggle(); rebuildMenu() }

    @objc func open() {
        // Clicking the menu-bar icon makes no app frontmost change, so the previously active app is still the target.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.palette.toggle() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
