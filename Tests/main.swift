import AppKit
setvbuf(stdout, nil, _IONBF, 0)
setenv("NOTCHSTASH_LANG", "ru", 1)   // проверки ждут русские подписи

var fails = 0
func check(_ name: String, _ got: String?, _ want: String?) {
    let ok = got == want
    if !ok { fails += 1 }
    print(ok ? "ok  " : "FAIL", name, "→", got ?? "nil", ok ? "" : "(ждали \(want ?? "nil"))")
}
func kind(_ s: String) -> String {
    switch Smart.detect(s) {
    case .color(let c): return "color \(c.hex)"
    case .math(let r): return "math \(r)"
    case .url(_, let clean): return "url" + (clean.map { " clean=\($0.absoluteString)" } ?? "")
    case .json: return "json"
    case .code: return "code"
    case .email: return "email"
    case nil: return "text"
    }
}

print("— раскладка")
check("ghbdtn", KeyboardLayout.suggestFix("ghbdtn"), "привет")
check("Ghbdtn? rfr ltkf", KeyboardLayout.suggestFix("Ghbdtn? rfr ltkf"), "Привет, как дела")
check("руддщ цщкдв", KeyboardLayout.suggestFix("руддщ цщкдв"), "hello world")
check("hello world", KeyboardLayout.suggestFix("hello world"), nil)
check("привет мир", KeyboardLayout.suggestFix("привет мир"), nil)
check("useState", KeyboardLayout.suggestFix("useState"), nil)
check("ntrcn yf heccrjv", KeyboardLayout.suggestFix("ntrcn yf heccrjv"), "текст на русском")
check("me@site.com", KeyboardLayout.suggestFix("me@site.com"), nil)
check("flip lf", KeyboardLayout.flip("lf"), "да")

print("— преобразования")
check("translit", TextTransform.translit.apply("Щука и Ёжик"), "Shchuka i Yozhik")
check("sentence", TextTransform.sentence.apply("ПРИВЕТ. КАК ДЕЛА?"), "Привет. Как дела?")
check("oneLine", TextTransform.oneLine.apply("a\n  b\tc"), "a b c")

print("— калькулятор")
for (i, w) in [("2+2*3", "math 8"), ("(10 - 4) / 4", "math 1,5".replacingOccurrences(of: ",", with: ".")),
               ("1,5 * 2", "math 3"), ("200*15%", "math 30"), ("2^10", "math 1024"), ("100/3", "math 33.33333333"),
               ("2026-11-09", "text"), ("+7 999 123-45-67", "text"), ("123-45-67", "text"), ("42", "text"),
               ("1/0", "text"), ("09.11.2026", "text"), ("3 - 1", "math 2"), ("1499 * 12 - 15%", "math 15289.8"), ("100 + 20%", "math 120"),
               ("50% * 10", "math 5"), ("200 - 10% - 10%", "math 162"), ("2*(3+4)", "math 14")] {
    check(i, kind(i), w)
}
print("— цвета")
for (i, w) in [("#FF5A5F", "color #FF5A5F"), ("#fff", "color #FFFFFF"), ("ff5a5f", "color #FF5A5F"),
               ("123456", "text"), ("rgb(255, 90, 95)", "color #FF5A5F"), ("hsl(0, 100%, 50%)", "color #FF0000"),
               ("rgba(0,0,0,0.5)", "color #00000080")] {
    check(i, kind(i), w)
}
check("hsl out", SmartColor.parse("#FF5A5F")?.hsl, "hsl(358, 100%, 68%)")
print("— ссылки, почта, json, код")
check("url", kind("https://example.com/a?utm_source=tg&id=5&fbclid=xyz"), "url clean=https://example.com/a?id=5")
check("url plain", kind("https://folivora.ai"), "url")
check("yt", kind("https://youtu.be/abc?si=XYZ"), "url clean=https://youtu.be/abc")
check("email", kind("mark@dev.ru"), "email")
check("json", kind("{\"a\":1,\"b\":[1,2]}"), "json")
check("cli", kind("git commit -m \"hi\""), "code")
check("swift", kind("func a() {\n    return 1\n}"), "code")
check("prose", kind("Привет!\nКак дела? Всё хорошо."), "text")
print("— полка")
do {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bufer-shelf-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let shelf = ShelfStore(baseDir: base)
    // обычный файл (не во временной папке) — кладём ссылку на него
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bufer-test-file.txt")
    try? "hi".write(to: home, atomically: true, encoding: .utf8)
    // временный файл (как превью скриншота) — должен скопироваться на полку
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Снимок экрана.png")
    let img = NSImage(size: NSSize(width: 4, height: 4)); img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
    let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try? png.write(to: tmp)
    let pImage = NSItemProvider(); pImage.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { $0(png, nil); return nil }
    let providers: [NSItemProvider] = [
        NSItemProvider(contentsOf: home)!,
        NSItemProvider(contentsOf: tmp)!,
        NSItemProvider(object: NSURL(string: "https://markdev.app/bufer")!),
        pImage,
        NSItemProvider(object: "Заметка на полку\nвторая строка" as NSString),
        NSItemProvider(object: "https://github.com" as NSString),
    ]
    shelf.accept(providers)
    let deadline = Date().addingTimeInterval(3)
    while shelf.items.count < 6 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let kinds = shelf.items.map { "\($0.kind.rawValue)\($0.owned ? "*" : ""):\($0.name)" }
    check("порядок и виды", kinds.joined(separator: " | "),
          "file:.bufer-test-file.txt | file*:Снимок экрана.png | link:markdev.app | file*:\(shelf.items[3].name) | text:Заметка на полку | link:github.com")
    check("картинка сохранена", shelf.items[3].name.hasPrefix("Картинка ") && shelf.items[3].exists ? "да" : "нет", "да")
    check("временный файл скопирован", shelf.items[1].path?.hasPrefix(shelf.dir.path) == true ? "да" : "нет", "да")
    // повтор не дублируется
    shelf.accept([NSItemProvider(object: NSURL(string: "https://markdev.app/bufer")!)])
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check("без дублей", "\(shelf.items.count) \(shelf.items[0].name)", "6 markdev.app")
    // сохранилось на диск
    let again = ShelfStore(baseDir: base)
    check("после перезапуска", "\(again.items.count)", "6")
    // наружу: файл отдаётся как файл, текст — как текст
    check("наружу файл", shelf.provider(shelf.items.first { $0.kind == .file }!).hasItemConformingToTypeIdentifier("public.file-url") ? "file-url" : "нет", "file-url")
    check("наружу текст", shelf.provider(shelf.items.first { $0.kind == .text }!).canLoadObject(ofClass: NSString.self) ? "text" : "нет", "text")
    // убрать: свой файл удаляется с диска, чужой — нет
    let owned = shelf.items.first { $0.owned && $0.name == "Снимок экрана.png" }!
    shelf.remove(owned.id)
    check("свой файл удалён", FileManager.default.fileExists(atPath: owned.path!) ? "остался" : "удалён", "удалён")
    shelf.remove(shelf.items.first { $0.kind == .file && !$0.owned && $0.path == home.path }!.id)
    check("чужой файл цел", FileManager.default.fileExists(atPath: home.path) ? "цел" : "удалён", "цел")
    shelf.clear()
    check("очистка", "\(shelf.items.count) \((try? FileManager.default.contentsOfDirectory(atPath: shelf.dir.path).filter { !$0.hasSuffix(".json") }.count) ?? -1)", "0 0")
    try? FileManager.default.removeItem(at: home)
    try? FileManager.default.removeItem(at: base)
}
print("— текст с картинок")
do {
    func render(_ lines: [String], size: NSSize = NSSize(width: 1000, height: 360), dark: Bool = false) -> URL {
        let img = NSImage(size: size)
        img.lockFocus()
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: dark ? NSColor.white : NSColor.black]
        for (i, l) in lines.enumerated() {
            (l as NSString).draw(at: NSPoint(x: 40, y: size.height - 70 - CGFloat(i) * 60), withAttributes: attrs)
        }
        img.unlockFocus()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ocr-\(UUID().uuidString).png")
        try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }
    func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "ё", with: "е") }

    let ru = OCR.recognizeNow(url: render(["Счёт на оплату № 4815", "Итого к оплате: 12 500 руб."]))
    print("     распознано:", ru.replacingOccurrences(of: "\n", with: " | "))
    check("русский текст", norm(ru).contains("счет на оплату") && ru.contains("4815") ? "да" : "нет", "да")
    check("две строки", "\(ru.split(separator: "\n").count)", "2")

    let en = OCR.recognizeNow(url: render(["Meeting at 5 pm", "Docs: https://markdev.app/bufer", "Call +7 999 123-45-67"], dark: true))
    print("     распознано:", en.replacingOccurrences(of: "\n", with: " | "))
    check("английский на тёмном", en.contains("Meeting at 5") ? "да" : "нет", "да")
    let links = OCR.links(in: en).map(\.url.absoluteString)
    check("ссылка найдена", links.contains { $0.contains("markdev.app") } ? "да" : "нет", "да")
    check("телефон найден", links.contains { $0.hasPrefix("tel:") } ? "да" : "нет", "да")

    let mixed = OCR.links(in: "Трек: RU 4815 1623 42\nСчёт 40817810099910004312\nТелефон: +7 999 123-45-67\nhelp@markdev.app")
    check("трек и счёт — не телефоны", mixed.map(\.title).joined(separator: ", "), "help@markdev.app, +7 999 123-45-67")
    let empty = render([])
    check("пустая картинка", OCR.recognizeNow(url: empty), "")

    // связка с историей: картинка попадает в историю, текст дочитывается, сохраняется и ищется
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bufer-ocr-\(UUID().uuidString)")
    setenv("NOTCHSTASH_DATA_DIR", dir.path, 1)
    let store = ClipStore()
    let pic = render(["Пароль от Wi-Fi: kotik2026"])
    let data = try! Data(contentsOf: pic)
    let item = store.add(ClipItem(kind: .image, imageName: "pic.png", date: Date(), hash: "i:test"), imageData: data)
    var updated: ClipItem?
    store.recognizeIfNeeded(item) { updated = $0 }
    let deadline = Date().addingTimeInterval(10)
    while updated == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check("текст записан в историю", updated?.ocrText?.contains("kotik2026") == true ? "да" : "нет", "да")
    check("строка для списка", updated?.ocrLine.map { norm($0).hasPrefix("пароль") ? "да" : $0 } ?? "nil", "да")
    store.saveNow()
    let reloaded = ClipStore()
    check("после перезапуска", reloaded.items.first?.ocrText?.contains("kotik2026") == true ? "да" : "нет", "да")
    // второй раз не распознаёт
    var again = false
    reloaded.recognizeIfNeeded(reloaded.items[0]) { _ in again = true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check("без повторного чтения", again ? "читал снова" : "нет", "нет")
    try? FileManager.default.removeItem(at: dir)
}
print(fails == 0 ? "\nВСЁ ОК" : "\nОШИБОК: \(fails)")
