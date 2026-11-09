import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Вещь на полке: файл, ссылка или кусок текста.
struct ShelfItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case file, link, text }

    var id = UUID()
    var kind: Kind
    var path: String?        // для файлов
    var text: String?        // для ссылок и текста
    var owned = false        // файл лежит в папке полки (картинка из браузера, временный скриншот)
    var date = Date()

    var url: URL? {
        switch kind {
        case .file: return path.map { URL(fileURLWithPath: $0) }
        case .link: return text.flatMap(URL.init(string:))
        case .text: return nil
        }
    }

    var name: String {
        switch kind {
        case .file: return ((path ?? "") as NSString).lastPathComponent
        case .link: return url?.host ?? text ?? ""
        case .text:
            let t = (text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(t.prefix(60))
        }
    }

    var exists: Bool {
        kind != .file || FileManager.default.fileExists(atPath: path ?? "")
    }
}

final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    let dir: URL
    private var url: URL { dir.appendingPathComponent("shelf.json") }
    private var icons: [String: NSImage] = [:]

    init(baseDir: URL) {
        dir = baseDir.appendingPathComponent("shelf")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            items = (try? dec.decode([ShelfItem].self, from: data)) ?? []
        }
    }

    func add(_ new: [ShelfItem]) {
        for it in new {
            // одно и то же второй раз не кладём — просто поднимаем наверх
            if let i = items.firstIndex(where: { $0.kind == it.kind && $0.path == it.path && $0.text == it.text }) {
                var old = items.remove(at: i)
                old.date = Date()
                items.insert(old, at: 0)
            } else {
                items.insert(it, at: 0)
            }
        }
        save()
    }

    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let it = items.remove(at: i)
        if it.owned, let p = it.path { try? FileManager.default.removeItem(atPath: p) }
        save()
    }

    func clear() {
        for it in items where it.owned { if let p = it.path { try? FileManager.default.removeItem(atPath: p) } }
        items.removeAll()
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(items) { try? data.write(to: url, options: .atomic) }
    }

    func icon(_ item: ShelfItem) -> NSImage? {
        guard item.kind == .file, let p = item.path, item.exists else { return nil }
        if let i = icons[p] { return i }
        let ext = (p as NSString).pathExtension.lowercased()
        let img: NSImage
        if ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains(ext), let pic = NSImage(contentsOfFile: p) {
            img = pic
        } else {
            img = NSWorkspace.shared.icon(forFile: p)
        }
        icons[p] = img
        return img
    }

    // MARK: перетаскивание внутрь

    static let dropTypes: [UTType] = [.fileURL, .url, .image, .utf8PlainText, .plainText]

    /// Достаёт из перетаскивания файлы, ссылки, картинки и текст и кладёт их на полку.
    func accept(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var found: [(Int, ShelfItem)] = []
        let lock = NSLock()
        func put(_ i: Int, _ it: ShelfItem) { lock.lock(); found.append((i, it)); lock.unlock() }

        for (i, p) in providers.enumerated() {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL { put(i, self.fileItem(url)) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { put(i, ShelfItem(kind: .link, text: url.absoluteString)) }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data, let saved = self.saveImage(data) { put(i, saved) }
                    group.leave()
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                _ = p.loadObject(ofClass: NSString.self) { s, _ in
                    if let s = s as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.contains(where: \.isWhitespace), let u = URL(string: t), u.scheme?.hasPrefix("http") == true {
                            put(i, ShelfItem(kind: .link, text: t))
                        } else {
                            put(i, ShelfItem(kind: .text, text: s))
                        }
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // сохраняем порядок, в котором вещи тащили
            self.add(found.sorted { $0.0 > $1.0 }.map(\.1))
        }
    }

    /// Временные файлы (превью скриншота и т.п.) исчезнут — копируем их к себе.
    private func fileItem(_ url: URL) -> ShelfItem {
        let p = url.standardizedFileURL.path
        let temp = ["/private/var/folders", "/var/folders", "/private/tmp", "/tmp", NSTemporaryDirectory()]
        guard temp.contains(where: { p.hasPrefix($0) }) else { return ShelfItem(kind: .file, path: p) }
        let dest = uniqueURL(url.lastPathComponent)
        if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
            return ShelfItem(kind: .file, path: dest.path, owned: true)
        }
        return ShelfItem(kind: .file, path: p)
    }

    private func saveImage(_ data: Data) -> ShelfItem? {
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dest = uniqueURL(L("Картинка", "Image") + " \(f.string(from: Date())).png")
        guard (try? png.write(to: dest)) != nil else { return nil }
        return ShelfItem(kind: .file, path: dest.path, owned: true)
    }

    private func uniqueURL(_ name: String) -> URL {
        var dest = dir.appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return dest
    }

    // MARK: наружу

    /// Что отдаём при перетаскивании с полки в другую программу.
    func provider(_ item: ShelfItem) -> NSItemProvider {
        switch item.kind {
        case .file:
            if let u = item.url, item.exists, let p = NSItemProvider(contentsOf: u) {
                p.suggestedName = u.lastPathComponent
                return p
            }
            return NSItemProvider()
        case .link:
            if let u = item.url { return NSItemProvider(object: u as NSURL) }
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .text:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        }
    }

    /// Кладёт вещь в буфер обмена (файлы — как файлы, чтобы вставлялись в Finder и мессенджеры).
    func copy(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .file: if let u = item.url { pb.writeObjects([u as NSURL]) }
        case .link:
            if let u = item.url { pb.writeObjects([u as NSURL]) }
            pb.setString(item.text ?? "", forType: .string)
        case .text: pb.setString(item.text ?? "", forType: .string)
        }
    }

    func airDrop(_ list: [ShelfItem]) {
        let things: [Any] = list.compactMap { it in
            switch it.kind {
            case .file: return it.exists ? it.url : nil
            case .link: return it.url
            case .text: return it.text
            }
        }
        guard !things.isEmpty, let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: things) else {
            NSSound.beep()
            return
        }
        s.perform(withItems: things)
    }
}
