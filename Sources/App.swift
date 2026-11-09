import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = ClipStore()
    lazy var watcher = ClipboardWatcher(store: store)
    var notch: NotchController!
    var hotKey: HotKey?
    var statusItem: NSStatusItem!
    private var askedAccessibility = false
    private let d = UserDefaults.standard

    private func flag(_ key: String, _ def: Bool = true) -> Bool { d.object(forKey: key) as? Bool ?? def }

    @MainActor func applicationDidFinishLaunching(_ n: Notification) {
        notch = NotchController(store: store)

        // режим проверки: нарисовать окно в PNG и выйти
        if let path = ProcessInfo.processInfo.environment["NOTCHSTASH_SNAPSHOT"] {
            let st: NotchState = ProcessInfo.processInfo.environment["NOTCHSTASH_STATE"] == "peek" ? .peek : .open
            notch.snapshot(state: st, to: path) { NSApp.terminate(nil) }
            return
        }

        notch.onCopy = { [weak self] item in self?.watcher.write(item) }
        notch.onCopyText = { [weak self] text in self?.watcher.writeText(text) }
        notch.onPaste = { [weak self] in self?.pasteIntoFrontApp() }

        watcher.onNewItem = { [weak self] item in
            guard let self else { return }
            self.store.recognizeIfNeeded(item) { [weak self] done in self?.notch.refreshPeek(done) }
            guard self.flag("peekOnCopy") else { return }
            self.notch.peek(item)
        }
        watcher.paused = flag("paused", false)
        watcher.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.store.backfillOCR() }

        hotKey = HotKey(id: 1, keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.notch.toggle()
        }

        if ProcessInfo.processInfo.environment["NOTCHSTASH_AUTOTEST"] != nil { runAutotest() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "NotchStash")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Прогон сценариев без мыши: открыть, выбрать вторую запись, закрыть.
    private func runAutotest() {
        func log(_ s: String) { print("AUTOTEST", s, "state=\(notch.model.state)", "shown=\(notch.isShown)", "onActiveSpace=\(notch.panel.isOnActiveSpace)", "key=\(notch.panel.isKeyWindow)"); fflush(stdout) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { log("after peek") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self.notch.toggle(); log("toggle open") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) { log("opened, key=\(self.notch.panel.isKeyWindow)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            let items = self.notch.model.visible
            self.notch.onCopy?(items[1])
            self.notch.close()
            log("picked: \(items[1].title)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) {
            log("closed, clipboard=\(NSPasteboard.general.string(forType: .string) ?? "-")")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ n: Notification) { store.saveNow() }

    private func pasteIntoFrontApp() {
        guard flag("autoPaste") else { return }
        if ClipboardWatcher.canPaste {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { ClipboardWatcher.pressPaste() }
        } else if !askedAccessibility {
            askedAccessibility = true
            ClipboardWatcher.askForAccessibility()
        }
    }

    // MARK: меню в строке меню

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(L("Открыть историю", "Open History"), #selector(openHistory), key: "v", mods: [.command, .shift]))
        menu.addItem(.separator())

        let recent = Array(store.items.prefix(10))
        if recent.isEmpty {
            let empty = NSMenuItem(title: L("История пуста", "History is empty"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for clip in recent {
            var t = clip.title
            if t.count > 48 { t = String(t.prefix(48)) + "…" }
            let mi = item((clip.pinned ? "📌 " : "") + t, #selector(pickRecent(_:)))
            mi.representedObject = clip.id
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        menu.addItem(toggle(L("Пауза записи", "Pause Recording"), "paused", false))
        menu.addItem(toggle(L("Открывать наведением на чёлку", "Open on Notch Hover"), "hoverOpen"))
        menu.addItem(toggle(L("Показывать «Скопировано» в чёлке", "Show “Copied” in the Notch"), "peekOnCopy"))
        menu.addItem(toggle(L("Распознавать текст на картинках", "Recognize Text in Images"), "ocr"))
        menu.addItem(toggle(L("Открывать полку при перетаскивании к чёлке", "Open Shelf When Dragging to the Notch"), "dragOpen"))
        menu.addItem(toggle(L("Вставлять сразу (⌘V)", "Paste Immediately (⌘V)"), "autoPaste"))

        let limit = NSMenuItem(title: L("Хранить записей", "History Size"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for n in [100, 200, 500, 1000, 5000] {
            let mi = item("\(n)", #selector(setLimit(_:)))
            mi.tag = n
            mi.state = store.maxItems == n ? .on : .off
            sub.addItem(mi)
        }
        limit.submenu = sub
        menu.addItem(limit)

        let langItem = NSMenuItem(title: L("Язык", "Language"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (code, title) in [("auto", L("Как в системе", "System")), ("en", "English"), ("ru", "Русский")] {
            let mi = item(title, #selector(setLanguage(_:)))
            mi.representedObject = code
            mi.state = Lang.setting == code ? .on : .off
            langMenu.addItem(mi)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        let login = item(L("Запускать при входе", "Launch at Login"), #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if !ClipboardWatcher.canPaste {
            menu.addItem(item(L("Разрешить автовставку…", "Allow Auto-Paste…"), #selector(grantAccess)))
        }
        menu.addItem(.separator())
        menu.addItem(item(L("Очистить историю (кроме закреплённых)", "Clear History (Keep Pinned)"), #selector(clearHistory)))
        menu.addItem(item(L("Показать папку с историей", "Show Data Folder"), #selector(revealData)))
        menu.addItem(.separator())
        menu.addItem(item(L("Выйти", "Quit NotchStash"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ sel: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.keyEquivalentModifierMask = mods
        mi.target = self
        return mi
    }

    private func toggle(_ title: String, _ key: String, _ def: Bool = true) -> NSMenuItem {
        let mi = item(title, #selector(toggleFlag(_:)))
        mi.representedObject = key
        mi.state = flag(key, def) ? .on : .off
        return mi
    }

    @objc private func openHistory() { notch.open(byHover: false) }

    @objc private func pickRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let clip = store.items.first(where: { $0.id == id }) else { return }
        watcher.write(clip)
        pasteIntoFrontApp()
    }

    @objc private func toggleFlag(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let new = sender.state != .on
        d.set(new, forKey: key)
        if key == "paused" { watcher.paused = new }
        if key == "ocr" && new { store.backfillOCR() }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "language")
        notch.model.objectWillChange.send()
    }

    @objc private func setLimit(_ sender: NSMenuItem) { store.maxItems = sender.tag }

    @objc private func toggleLogin() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister() } else { try s.register() }
        } catch {
            let a = NSAlert()
            a.messageText = L("Не получилось изменить автозапуск", "Couldn’t change Launch at Login")
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc private func grantAccess() { ClipboardWatcher.askForAccessibility() }

    @objc private func clearHistory() { store.clear(keepPinned: true) }

    @objc private func revealData() { NSWorkspace.shared.activateFileViewerSelecting([store.dir]) }

    @objc private func quit() { NSApp.terminate(nil) }
}
