import AppKit
import SwiftUI

enum NotchState { case closed, peek, open }
enum NotchTab { case history, shelf }

final class NotchModel: ObservableObject {
    @Published var state: NotchState = .closed
    @Published var query = "" { didSet { if oldValue != query { selected = 0 } } }
    @Published var selected = 0
    @Published var peekItem: ClipItem?
    @Published var focusToken = 0
    @Published var tab: NotchTab = .history
    @Published var shelfSelected = 0
    @Published var dropTargeted = false
    static let shelfColumns = 6
    var staticRender = false   // только для снимка: без прокрутки и поля ввода
    @Published var notchSize = CGSize(width: 190, height: 32)
    let openSize = CGSize(width: 720, height: 440)
    let peekWing: CGFloat = 130

    let store: ClipStore
    init(store: ClipStore) { self.store = store }

    /// Что показывать в списке: закреплённые сверху, потом по свежести, с учётом поиска.
    var visible: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? store.items : store.items.filter {
            ($0.text ?? $0.title).localizedCaseInsensitiveContains(q)
                || $0.title.localizedCaseInsensitiveContains(q)
                || ($0.app ?? "").localizedCaseInsensitiveContains(q)
                || ($0.ocrText ?? "").localizedCaseInsensitiveContains(q)
        }
        return base.filter(\.pinned) + base.filter { !$0.pinned }
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct NotchActions {
    var pick: (ClipItem, Bool) -> Void
    var pasteText: (String, Bool) -> Void
    var open: (URL) -> Void
    var pin: (ClipItem) -> Void
    var delete: (ClipItem) -> Void
    var shelfPick: (ShelfItem, Bool) -> Void = { _, _ in }
    var shelfOpen: (ShelfItem) -> Void = { _ in }
    var shelfReveal: (ShelfItem) -> Void = { _ in }
    var shelfRemove: (ShelfItem) -> Void = { _ in }
    var shelfAirDrop: ([ShelfItem]) -> Void = { _ in }
    var shelfClear: () -> Void = {}
    var drop: ([NSItemProvider]) -> Void = { _ in }
}

/// Окно, которое живёт в чёлке: прячется за вырезом и выезжает из него.
final class NotchController: NSObject, NSWindowDelegate {
    let store: ClipStore
    let shelf: ShelfStore
    let model: NotchModel
    let panel: NotchPanel
    /// copy — положить в буфер сразу; paste — нажать ⌘V после того, как окно спрячется.
    var onCopy: ((ClipItem) -> Void)?
    var onCopyText: ((String) -> Void)?
    var onPaste: (() -> Void)?

    private var keyMonitor: Any?
    private var mouseTimer: Timer?
    private var hoverSince: Date?
    private var outsideSince: Date?
    private var openedByHover = false
    private var sticky = false
    private var peekWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var screen: NSScreen?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragBase: Int?
    private var dragging = false
    private let margin = CGSize(width: 90, height: 60)   // запас под тень

    static let openAnim = Animation.spring(response: 0.46, dampingFraction: 0.74)
    static let closeAnim = Animation.spring(response: 0.3, dampingFraction: 0.92)

    var hoverEnabled: Bool { UserDefaults.standard.object(forKey: "hoverOpen") as? Bool ?? true }
    var dragOpenEnabled: Bool { UserDefaults.standard.object(forKey: "dragOpen") as? Bool ?? true }

    init(store: ClipStore) {
        self.store = store
        shelf = ShelfStore(baseDir: store.dir)
        model = NotchModel(store: store)
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self

        let host = NSHostingView(rootView: NotchRoot(model: model, store: store, shelf: shelf, actions: makeActions()))
        host.sizingOptions = []
        panel.contentView = host

        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in self?.tick() }
        mouseTimer?.tolerance = 0.03
    }

    private func makeActions() -> NotchActions {
        var a = NotchActions(
            pick: { [weak self] item, paste in self?.pick(item, paste: paste) },
            pasteText: { [weak self] text, paste in self?.pickText(text, paste: paste) },
            open: { [weak self] url in self?.close { NSWorkspace.shared.open(url) } },
            pin: { [weak self] item in self?.store.togglePin(item.id) },
            delete: { [weak self] item in self?.delete(item) })
        a.shelfPick = { [weak self] item, paste in self?.pickShelf(item, paste: paste) }
        a.shelfOpen = { [weak self] item in
            guard let self else { return }
            if let u = item.url { self.close { NSWorkspace.shared.open(u) } } else { self.pickShelf(item, paste: true) }
        }
        a.shelfReveal = { [weak self] item in
            guard let u = item.url, item.kind == .file else { return }
            self?.close { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        }
        a.shelfRemove = { [weak self] item in self?.removeShelf(item) }
        a.shelfAirDrop = { [weak self] list in self?.close { self?.shelf.airDrop(list) } }
        a.shelfClear = { [weak self] in self?.shelf.clear(); self?.model.shelfSelected = 0 }
        a.drop = { [weak self] providers in
            guard let self else { return }
            self.shelf.accept(providers)
            self.sticky = false
            self.model.shelfSelected = 0
            withAnimation(.easeOut(duration: 0.2)) { self.model.tab = .shelf }
        }
        return a
    }

    // MARK: геометрия

    static func notchSize(_ s: NSScreen) -> CGSize {
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        }
        // экран без чёлки — рисуем «виртуальную» чёлку высотой со строку меню
        let bar = s.frame.maxY - s.visibleFrame.maxY
        return CGSize(width: 190, height: max(bar, 24))
    }

    static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    static var screenUnderMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    private func place(on s: NSScreen) {
        screen = s
        model.notchSize = Self.notchSize(s)
        let w = model.openSize.width + margin.width
        let h = model.openSize.height + margin.height
        panel.setFrame(NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h), display: true)
    }

    // MARK: открыть / закрыть / мигнуть

    func toggle() {
        if model.state == .open {
            if panel.isKeyWindow { close() } else { makeKey() }
        } else {
            open(byHover: false)
        }
    }

    func open(byHover: Bool, tab: NotchTab? = nil) {
        hideWork?.cancel()
        peekWork?.cancel()
        let target = byHover ? (Self.screenUnderMouse ?? Self.notchScreen) : Self.screenUnderMouse
        if !panel.isVisible || target != screen, let target {
            withTransaction(Transaction(animation: nil)) { model.state = .closed }
            place(on: target)
        }
        model.query = ""
        model.selected = 0
        model.shelfSelected = 0
        model.tab = tab ?? .history
        openedByHover = byHover
        sticky = !byHover
        outsideSince = nil
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        if !byHover { makeKey() }
        installKeyMonitor()
        // даём окну один кадр в размере чёлки, потом раскрываем
        DispatchQueue.main.async {
            withAnimation(Self.openAnim) { self.model.state = .open }
        }
    }

    private func makeKey() {
        panel.makeKeyAndOrderFront(nil)
        model.focusToken += 1
    }

    func close(then done: (() -> Void)? = nil) {
        guard model.state == .open else { done?(); return }
        removeKeyMonitor()
        withAnimation(Self.closeAnim) { model.state = .closed }
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.model.state == .closed { self.panel.orderOut(nil) }
            done?()
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// Текст на картинке дочитался, пока чёлка показывает «Скопировано», — обновляем вспышку.
    func refreshPeek(_ item: ClipItem) {
        guard model.state == .peek, model.peekItem?.id == item.id else { return }
        withAnimation(.easeOut(duration: 0.2)) { model.peekItem = item }
    }

    /// Короткое «Скопировано» из чёлки после каждого копирования.
    func peek(_ item: ClipItem) {
        guard model.state != .open else { return }
        hideWork?.cancel()
        peekWork?.cancel()
        if !panel.isVisible, let s = Self.notchScreen {
            withTransaction(Transaction(animation: nil)) { model.state = .closed }
            place(on: s)
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
        }
        model.peekItem = item
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.66)) { self.model.state = .peek }
        }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .peek else { return }
            withAnimation(Self.closeAnim) { self.model.state = .closed }
            let hide = DispatchWorkItem { [weak self] in
                if self?.model.state == .closed { self?.panel.orderOut(nil) }
            }
            self.hideWork = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: hide)
        }
        peekWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    // MARK: действия

    private func pick(_ item: ClipItem, paste: Bool) {
        onCopy?(item)
        close { [weak self] in if paste { self?.onPaste?() } }
    }

    private func pickText(_ text: String, paste: Bool) {
        onCopyText?(text)
        close { [weak self] in if paste { self?.onPaste?() } }
    }

    private func pickShelf(_ item: ShelfItem, paste: Bool) {
        shelf.copy(item)
        close { [weak self] in if paste { self?.onPaste?() } }
    }

    private func removeShelf(_ item: ShelfItem) {
        shelf.remove(item.id)
        model.shelfSelected = min(model.shelfSelected, max(shelf.items.count - 1, 0))
    }

    private func delete(_ item: ClipItem) {
        store.delete(item.id)
        model.selected = min(model.selected, max(model.visible.count - 1, 0))
    }

    // MARK: мышь: навели на чёлку — открылось, увели — закрылось

    private func tick() {
        let p = NSEvent.mouseLocation
        if NSEvent.pressedMouseButtons & 1 != 0 {
            if dragBase == nil { dragBase = dragPasteboard.changeCount }
            dragging = dragPasteboard.changeCount != dragBase
        } else {
            dragBase = nil
            dragging = false
        }
        switch model.state {
        case .closed, .peek:
            // тащат что-то к чёлке — открываем полку (на любом экране, у верхнего края по центру)
            if dragging, dragOpenEnabled,
               let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) || abs(p.y - $0.frame.maxY) < 1 && p.x >= $0.frame.minX && p.x <= $0.frame.maxX }) {
                let n = Self.notchSize(s)
                if abs(p.x - s.frame.midX) <= n.width / 2 + 70 && p.y >= s.frame.maxY - n.height - 36 {
                    hoverSince = nil
                    open(byHover: true, tab: .shelf)
                    return
                }
            }
            guard hoverEnabled, let s = NSScreen.screens.first(where: {
                $0.safeAreaInsets.top > 0 && p.x >= $0.frame.minX && p.x <= $0.frame.maxX
            }) else { hoverSince = nil; return }
            let n = Self.notchSize(s)
            let inNotch = abs(p.x - s.frame.midX) <= n.width / 2 + 8 && p.y >= s.frame.maxY - n.height - 2
            if inNotch, NSEvent.pressedMouseButtons == 0 {
                if let t = hoverSince {
                    if Date().timeIntervalSince(t) > 0.12 { hoverSince = nil; open(byHover: true) }
                } else { hoverSince = Date() }
            } else { hoverSince = nil }
        case .open:
            // пока кнопка мыши зажата (тащат внутрь или наружу) — не закрываемся
            if NSEvent.pressedMouseButtons & 1 != 0 { outsideSince = nil; return }
            guard openedByHover, !sticky, let s = screen else { outsideSince = nil; return }
            let o = model.openSize
            let r = NSRect(x: s.frame.midX - o.width / 2, y: s.frame.maxY - o.height,
                           width: o.width, height: o.height + 4).insetBy(dx: -24, dy: -24)
            if NSMouseInRect(p, r, false) {
                outsideSince = nil
            } else if let t = outsideSince {
                if Date().timeIntervalSince(t) > 0.3 { outsideSince = nil; close() }
            } else { outsideSince = Date() }
        }
    }

    // MARK: клавиатура

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, self.model.state == .open, e.window === self.panel || self.panel.isKeyWindow else { return e }
            self.sticky = true
            guard e.type == .keyDown else { return e }
            return self.handleKey(e) ? nil : e
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    private func handleKey(_ e: NSEvent) -> Bool {
        if e.keyCode == 48 { // ⇥
            withAnimation(.easeOut(duration: 0.18)) { model.tab = model.tab == .history ? .shelf : .history }
            if model.tab == .history { model.focusToken += 1 }
            return true
        }
        if model.tab == .shelf { return handleShelfKey(e) }
        let items = model.visible
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cur = items.indices.contains(model.selected) ? items[model.selected] : nil
        switch e.keyCode {
        case 53: // esc
            if !model.query.isEmpty { model.query = "" } else { close() }
            return true
        case 125: // ↓
            if !items.isEmpty { model.selected = min(model.selected + 1, items.count - 1) }
            return true
        case 126: // ↑
            model.selected = max(model.selected - 1, 0)
            return true
        case 36, 76: // return
            if let cur { pick(cur, paste: !f.contains(.option)) }
            return true
        case 51 where f.contains(.command): // ⌘⌫
            if let cur { delete(cur) }
            return true
        case 37 where f.contains(.command): // ⌘L — исправить раскладку и вставить
            if let cur, cur.kind == .text, let t = cur.text {
                pickText(SmartCache.shared.layoutFix(cur) ?? KeyboardLayout.flip(t), paste: !f.contains(.option))
            }
            return true
        case 17 where f.contains(.command): // ⌘T — вставить текст с картинки
            if let cur, let t = cur.ocrText, !t.isEmpty { pickText(t, paste: !f.contains(.option)) }
            return true
        case 35 where f.contains(.command): // ⌘P
            if let cur { store.togglePin(cur.id) }
            return true
        default:
            if f.contains(.command), let n = Self.digitKeys[e.keyCode], items.indices.contains(n - 1) {
                pick(items[n - 1], paste: true)
                return true
            }
            return false
        }
    }

    private func handleShelfKey(_ e: NSEvent) -> Bool {
        let items = shelf.items
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cols = NotchModel.shelfColumns
        let cur = items.indices.contains(model.shelfSelected) ? items[model.shelfSelected] : nil
        func move(_ d: Int) {
            guard !items.isEmpty else { return }
            model.shelfSelected = min(max(model.shelfSelected + d, 0), items.count - 1)
        }
        switch e.keyCode {
        case 53: close(); return true
        case 123: move(-1); return true
        case 124: move(1); return true
        case 126: move(-cols); return true
        case 125: move(cols); return true
        case 36, 76:
            if let cur { pickShelf(cur, paste: !f.contains(.option)) }
            return true
        case 51:
            if let cur { removeShelf(cur) }
            return true
        default:
            return true   // на полке поля ввода нет — остальные клавиши глотаем
        }
    }

    // MARK: окно

    func windowDidBecomeKey(_ notification: Notification) {
        installKeyMonitor()
        model.focusToken += 1
    }

    func windowDidResignKey(_ notification: Notification) {
        if model.state == .open { close() }
    }

    // MARK: снимок для проверки без захвата экрана

    @MainActor func snapshot(state: NotchState, to path: String, done: @escaping () -> Void) {
        if let s = Self.notchScreen { model.notchSize = Self.notchSize(s) }
        if state == .peek { model.peekItem = store.items.first }
        model.state = state
        model.staticRender = true
        if let sel = ProcessInfo.processInfo.environment["NOTCHSTASH_SELECT"], let n = Int(sel) { model.selected = n; model.shelfSelected = n }
        if ProcessInfo.processInfo.environment["NOTCHSTASH_TAB"] == "shelf" { model.tab = .shelf }
        if ProcessInfo.processInfo.environment["NOTCHSTASH_DROP"] != nil { model.dropTargeted = true }
        let actions = NotchActions(pick: { _, _ in }, pasteText: { _, _ in }, open: { _ in }, pin: { _ in }, delete: { _ in })
        let view = NotchRoot(model: model, store: store, shelf: shelf, actions: actions)
            .frame(width: model.openSize.width + margin.width, height: model.openSize.height + margin.height)
            .background(LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.62), Color(red: 0.86, green: 0.45, blue: 0.52), Color(red: 0.98, green: 0.74, blue: 0.52)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        done()
    }
}
