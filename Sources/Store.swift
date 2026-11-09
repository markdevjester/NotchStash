import AppKit
import CryptoKit

enum ClipKind: String, Codable {
    case text, image, files
}

struct ClipItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ClipKind
    var text: String?          // текст или пути файлов через перевод строки
    var imageName: String?     // имя PNG-файла в папке images
    var imageSize: CGSize?
    var date: Date
    var pinned = false
    var app: String?
    var appBundle: String?
    var hash: String
    var ocrText: String?       // текст с картинки; nil — ещё не читали, "" — текста нет

    /// Первая строка текста с картинки — для списка.
    var ocrLine: String? {
        guard let o = ocrText, let first = o.split(whereSeparator: \.isNewline).first else { return nil }
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(120))
    }

    var paths: [String] {
        kind == .files ? (text ?? "").split(separator: "\n").map(String.init) : []
    }

    /// Короткая строка для списка
    var title: String {
        switch kind {
        case .text:
            let t = String((text ?? "").prefix(400))
            return t.split(whereSeparator: { $0.isNewline || $0 == "\t" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ⏎ ")
        case .image:
            if let s = imageSize { return L("Картинка", "Image") + " \(Int(s.width))×\(Int(s.height))" }
            return L("Картинка", "Image")
        case .files:
            let names = paths.map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : L("\(names.count) файл(а): ", "\(names.count) files: ") + names.joined(separator: ", ")
        }
    }
}

final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []

    let dir: URL
    let imagesDir: URL
    private var historyURL: URL { dir.appendingPathComponent("history.json") }
    private var saveWork: DispatchWorkItem?
    private let thumbs = NSCache<NSString, NSImage>()
    var ocrPending = Set<UUID>()

    var maxItems: Int {
        get { let v = UserDefaults.standard.integer(forKey: "maxItems"); return v > 0 ? v : 500 }
        set { UserDefaults.standard.set(newValue, forKey: "maxItems"); trim(); scheduleSave() }
    }

    init() {
        if let custom = ProcessInfo.processInfo.environment["NOTCHSTASH_DATA_DIR"] {
            dir = URL(fileURLWithPath: custom)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = support.appendingPathComponent("NotchStash")
            Self.migrateFromBufer(support: support, to: dir)
        }
        imagesDir = dir.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    /// Раньше приложение называлось «Буфер» (Bufer) — переносим историю, полку и настройки.
    private static func migrateFromBufer(support: URL, to dir: URL) {
        let fm = FileManager.default
        let old = support.appendingPathComponent("Bufer")
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)
        }
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromBufer") else { return }
        if let oldPrefs = UserDefaults(suiteName: "com.markdisk.bufer")?.dictionaryRepresentation() {
            for key in ["maxItems", "autoPaste", "hoverOpen", "peekOnCopy", "paused", "dragOpen", "ocr"] {
                if let v = oldPrefs[key], d.object(forKey: key) == nil { d.set(v, forKey: key) }
            }
        }
        d.set(true, forKey: "migratedFromBufer")
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: изменения

    /// Добавляет запись. Если такая уже есть — поднимает её наверх.
    @discardableResult
    func add(_ item: ClipItem, imageData: Data? = nil) -> ClipItem {
        if let i = items.firstIndex(where: { $0.hash == item.hash }) {
            var old = items.remove(at: i)
            old.date = Date()
            if item.app != nil { old.app = item.app; old.appBundle = item.appBundle }
            items.insert(old, at: 0)
            scheduleSave()
            return old
        }
        if let data = imageData, let name = item.imageName {
            try? data.write(to: imagesDir.appendingPathComponent(name), options: .atomic)
        }
        items.insert(item, at: 0)
        trim()
        scheduleSave()
        return item
    }

    func bump(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var it = items.remove(at: i)
        it.date = Date()
        items.insert(it, at: 0)
        scheduleSave()
    }

    /// Записывает распознанный текст и возвращает обновлённую запись.
    @discardableResult
    func setOCR(_ id: UUID, _ text: String) -> ClipItem? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[i].ocrText = text
        scheduleSave()
        return items[i]
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        removeFiles(of: items[i])
        items.remove(at: i)
        scheduleSave()
    }

    func clear(keepPinned: Bool = true) {
        for it in items where !(keepPinned && it.pinned) { removeFiles(of: it) }
        items.removeAll { !(keepPinned && $0.pinned) }
        scheduleSave()
    }

    private func trim() {
        var unpinned = items.filter { !$0.pinned }.count
        while unpinned > maxItems, let i = items.lastIndex(where: { !$0.pinned }) {
            removeFiles(of: items[i])
            items.remove(at: i)
            unpinned -= 1
        }
    }

    private func removeFiles(of item: ClipItem) {
        if let name = item.imageName {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
            thumbs.removeObject(forKey: name as NSString)
        }
    }

    // MARK: картинки

    func imageURL(_ item: ClipItem) -> URL? {
        item.imageName.map { imagesDir.appendingPathComponent($0) }
    }

    func image(_ item: ClipItem) -> NSImage? {
        guard let name = item.imageName else { return nil }
        if let img = thumbs.object(forKey: name as NSString) { return img }
        guard let img = NSImage(contentsOf: imagesDir.appendingPathComponent(name)) else { return nil }
        thumbs.setObject(img, forKey: name as NSString)
        return img
    }

    private var appIcons: [String: NSImage] = [:]

    func appIcon(_ item: ClipItem) -> NSImage? {
        guard let b = item.appBundle else { return nil }
        if let i = appIcons[b] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        appIcons[b] = i
        return i
    }

    // MARK: диск

    private func load() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        items = (try? dec.decode([ClipItem].self, from: data)) ?? []
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(items) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }
}
