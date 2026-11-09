import AppKit
import SwiftUI

// MARK: - Раскладка

enum KeyboardLayout {
    private static let en = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?@#$^&")
    private static let ru = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,\"№;:?")

    private static let enToRu: [Character: Character] = Dictionary(zip(en, ru), uniquingKeysWith: { a, _ in a })
    private static let ruToEn: [Character: Character] = {
        var m = Dictionary(zip(ru, en), uniquingKeysWith: { a, _ in a })
        // точку и запятую в русском тексте почти всегда ставят нарочно — не трогаем
        m["."] = nil; m[","] = nil; m["?"] = nil; m[";"] = nil; m[":"] = nil; m["\""] = nil
        return m
    }()

    static func isCyrillic(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x400...0x4FF).contains($0.value) }
    }

    static func isLatin(_ c: Character) -> Bool {
        c.isASCII && c.isLetter
    }

    /// Переключает раскладку в ту сторону, где букв больше.
    static func flip(_ s: String) -> String {
        let cyr = s.filter(isCyrillic).count
        let lat = s.filter(isLatin).count
        if cyr > lat { return String(s.map { ruToEn[$0] ?? $0 }) }
        return String(s.map { enToRu[$0] ?? $0 })
    }

    /// Если текст набран не в той раскладке — возвращает исправленный вариант.
    static func suggestFix(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, t.count <= 400 else { return nil }
        if t.contains("://") || t.hasPrefix("/") || t.hasPrefix("~") || t.contains("\\") { return nil }
        if !t.contains(" ") && t.contains("@") { return nil }   // почта
        let letters = t.filter(\.isLetter)
        guard letters.count >= 3 else { return nil }
        let cyr = letters.filter(isCyrillic).count
        let lat = letters.filter(isLatin).count
        if lat == letters.count {
            let fixed = flip(t)
            return better(t, "en", fixed, "ru") ? fixed : nil
        }
        if cyr == letters.count {
            let fixed = flip(t)
            return better(t, "ru", fixed, "en") ? fixed : nil
        }
        return nil
    }

    private static func better(_ a: String, _ la: String, _ b: String, _ lb: String) -> Bool {
        let ra = misspelled(a, la)
        let rb = misspelled(b, lb)
        return ra >= 0.5 && rb <= 0.34 && rb < ra
    }

    /// Доля слов с ошибками по системному словарю macOS.
    static func misspelled(_ s: String, _ lang: String) -> Double {
        let words = s.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 2 }
        guard !words.isEmpty else { return 1 }
        let checker = NSSpellChecker.shared
        var bad = 0
        for w in words.prefix(40) {
            let r = checker.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                          inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location != NSNotFound { bad += 1 }
        }
        return Double(bad) / Double(min(words.count, 40))
    }
}

// MARK: - Преобразования текста

enum TextTransform: String, CaseIterable, Identifiable {
    case layout, translit, upper, lower, sentence, oneLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .layout: return "Раскладка"
        case .translit: return "Транслит"
        case .upper: return "ВЕРХНИЙ"
        case .lower: return "нижний"
        case .sentence: return "Как в предложении"
        case .oneLine: return "В одну строку"
        }
    }

    var key: String? { self == .layout ? "⌘L" : nil }

    func available(for text: String) -> Bool {
        switch self {
        case .translit: return text.contains(where: KeyboardLayout.isCyrillic)
        case .oneLine: return text.contains(where: \.isNewline) || text.contains("  ")
        case .layout: return text.contains(where: { KeyboardLayout.isCyrillic($0) || KeyboardLayout.isLatin($0) })
        default: return text.contains(where: \.isLetter) && apply(text) != text
        }
    }

    func apply(_ s: String) -> String {
        switch self {
        case .layout: return KeyboardLayout.flip(s)
        case .translit: return Translit.convert(s)
        case .upper: return s.uppercased()
        case .lower: return s.lowercased()
        case .sentence:
            let low = s.lowercased()
            var out = ""
            var capNext = true
            for ch in low {
                if capNext && ch.isLetter { out += ch.uppercased(); capNext = false } else { out.append(ch) }
                if ".!?\n".contains(ch) { capNext = true }
            }
            return out
        case .oneLine:
            return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
    }
}

enum Translit {
    private static let map: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh", "з": "z",
        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    ]

    static func convert(_ s: String) -> String {
        var out = ""
        for ch in s {
            let low = Character(ch.lowercased())
            guard let t = map[low] else { out.append(ch); continue }
            if ch != low, let f = t.first {
                out += f.uppercased() + t.dropFirst()
            } else {
                out += t
            }
        }
        return out
    }
}

// MARK: - Умные карточки

struct SmartColor {
    let r, g, b, a: Double   // 0...1

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    var hex: String {
        let h = String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
        return a < 1 ? h + String(format: "%02X", Int(round(a * 255))) : h
    }

    var rgb: String {
        let base = "\(Int(round(r * 255))), \(Int(round(g * 255))), \(Int(round(b * 255)))"
        return a < 1 ? "rgba(\(base), \(fmt(a)))" : "rgb(\(base))"
    }

    var hsl: String {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            switch mx {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h *= 60
        }
        let base = "\(Int(round(h))), \(Int(round(s * 100)))%, \(Int(round(l * 100)))%"
        return a < 1 ? "hsla(\(base), \(fmt(a)))" : "hsl(\(base))"
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.2f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    static func parse(_ raw: String) -> SmartColor? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.count > 40 { return nil }
        // #rgb, #rrggbb, #rrggbbaa (без решётки — только 6 знаков и хотя бы одна буква)
        if s.range(of: #"^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$"#, options: .regularExpression) != nil
            || (s.range(of: #"^[0-9a-f]{6}$"#, options: .regularExpression) != nil && s.contains(where: \.isLetter)) {
            var h = s.hasPrefix("#") ? String(s.dropFirst()) : s
            if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
            guard let v = UInt64(h, radix: 16) else { return nil }
            if h.count == 8 {
                return SmartColor(r: Double((v >> 24) & 255) / 255, g: Double((v >> 16) & 255) / 255,
                                  b: Double((v >> 8) & 255) / 255, a: Double(v & 255) / 255)
            }
            return SmartColor(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255,
                              b: Double(v & 255) / 255, a: 1)
        }
        // rgb()/rgba()/hsl()/hsla()
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let fn = String(s[..<open])
        let parts = s[s.index(after: open)..<s.index(before: s.endIndex)]
            .split(whereSeparator: { ", /".contains($0) }).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func num(_ p: String) -> Double? { Double(p.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "deg", with: "")) }
        guard let p0 = num(parts[0]), let p1 = num(parts[1]), let p2 = num(parts[2]) else { return nil }
        var alpha = 1.0
        if parts.count == 4, let a = num(parts[3]) { alpha = parts[3].hasSuffix("%") ? a / 100 : a }
        alpha = min(max(alpha, 0), 1)
        if fn == "rgb" || fn == "rgba" {
            func ch(_ v: Double, _ p: String) -> Double { p.hasSuffix("%") ? v / 100 : v / 255 }
            let c = [ch(p0, parts[0]), ch(p1, parts[1]), ch(p2, parts[2])]
            guard c.allSatisfy({ (0...1).contains($0) }) else { return nil }
            return SmartColor(r: c[0], g: c[1], b: c[2], a: alpha)
        }
        if fn == "hsl" || fn == "hsla" {
            let h = p0.truncatingRemainder(dividingBy: 360) / 360, sat = p1 / 100, l = p2 / 100
            guard (0...1).contains(sat), (0...1).contains(l) else { return nil }
            func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
                var t = t0
                if t < 0 { t += 1 }
                if t > 1 { t -= 1 }
                if t < 1 / 6 { return p + (q - p) * 6 * t }
                if t < 1 / 2 { return q }
                if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
                return p
            }
            if sat == 0 { return SmartColor(r: l, g: l, b: l, a: alpha) }
            let q = l < 0.5 ? l * (1 + sat) : l + sat - l * sat
            let p = 2 * l - q
            return SmartColor(r: hue(p, q, h + 1 / 3), g: hue(p, q, h), b: hue(p, q, h - 1 / 3), a: alpha)
        }
        return nil
    }
}

enum Smart {
    case color(SmartColor)
    case math(result: String)
    case url(URL, clean: URL?)
    case json(pretty: String, compact: String)
    case code
    case email(String)

    var symbol: String {
        switch self {
        case .color: return "paintpalette"
        case .math: return "equal.square"
        case .url: return "link"
        case .json: return "curlybraces"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .email: return "envelope"
        }
    }

    static func detect(_ text: String) -> Smart? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let oneLine = !t.contains(where: \.isNewline)

        if oneLine {
            if let c = SmartColor.parse(t) { return .color(c) }
            if t.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil {
                return .email(t)
            }
            if !t.contains(" "), let u = URL(string: t), let scheme = u.scheme?.lowercased(),
               ["http", "https"].contains(scheme), u.host != nil {
                return .url(u, clean: Tracking.clean(u))
            }
            if let r = Calc.evaluate(t) { return .math(result: r) }
        }
        if let first = t.first, first == "{" || first == "[", t.utf8.count < 2_000_000,
           let data = t.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           !(obj is NSNumber), !(obj is NSString),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let compact = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) {
            return .json(pretty: String(decoding: pretty, as: UTF8.self), compact: String(decoding: compact, as: UTF8.self))
        }
        if Code.looksLikeCode(t) { return .code }
        return nil
    }
}

/// Кэш, чтобы не распознавать одно и то же при каждой перерисовке.
final class SmartCache {
    static let shared = SmartCache()
    private var smart: [String: Smart?] = [:]
    private var layout: [String: String?] = [:]

    func smart(_ item: ClipItem) -> Smart? {
        guard item.kind == .text, let t = item.text else { return nil }
        if let v = smart[item.hash] { return v }
        let v = Smart.detect(t)
        smart[item.hash] = v
        return v
    }

    func layoutFix(_ item: ClipItem) -> String? {
        guard item.kind == .text, let t = item.text, smart(item) == nil else { return nil }
        if let v = layout[item.hash] { return v }
        let v = KeyboardLayout.suggestFix(t)
        layout[item.hash] = v
        return v
    }
}

// MARK: - Калькулятор

enum Calc {
    /// Считает простой пример: + − × ÷ ^ скобки и проценты. Возвращает nil, если это не пример.
    static func evaluate(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("=") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard s.count <= 200, !s.hasPrefix("+") else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789.,+-*/×÷:^%() ")
        guard s.unicodeScalars.allSatisfy(allowed.contains), s.contains(where: \.isNumber) else { return nil }
        // даты и телефоны — не примеры
        if s.range(of: #"^\d{1,4}[-./]\d{1,2}[-./]\d{1,4}$"#, options: .regularExpression) != nil { return nil }
        if s.range(of: #"^[\d\s()-]+$"#, options: .regularExpression) != nil && !s.contains(" - ") { return nil }
        guard s.range(of: #"[+*/×÷:^%]|\s-\s|\)\s*-|-\s*\("#, options: .regularExpression) != nil else { return nil }
        if s.range(of: #"\d\s+\d"#, options: .regularExpression) != nil { return nil }

        let useComma = s.contains(",") && !s.contains(".")
        var p = Parser(Array(s.replacingOccurrences(of: ",", with: ".")))
        guard let v = p.parseExpression(), p.atEnd, v.isFinite else { return nil }
        // пример должен хоть что-то посчитать: «(5)» не в счёт
        if let only = Double(s.replacingOccurrences(of: ",", with: ".")), only == v { return nil }
        var out: String
        if v == v.rounded(), abs(v) < 1e15 {
            out = String(Int64(v))
        } else {
            out = String(format: "%.10g", v)
        }
        if useComma { out = out.replacingOccurrences(of: ".", with: ",") }
        return out
    }

    private struct Parser {
        let c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }

        var atEnd: Bool { mutating get { skip(); return i >= c.count } }

        mutating func skip() { while i < c.count, c[i] == " " { i += 1 } }

        mutating func peek() -> Character? { skip(); return i < c.count ? c[i] : nil }

        var lastPercent = false

        mutating func parseExpression() -> Double? {
            guard var v = parseTerm() else { return nil }
            while let ch = peek(), ch == "+" || ch == "-" {
                i += 1
                guard var r = parseTerm() else { return nil }
                if lastPercent { r = v * r }   // 100 - 15% → 100 - 15
                v = ch == "+" ? v + r : v - r
            }
            return v
        }

        mutating func parseTerm() -> Double? {
            guard var v = parsePower() else { return nil }
            var percentOnly = lastPercent
            defer { lastPercent = percentOnly }
            while let ch = peek(), "*/×÷:".contains(ch) {
                percentOnly = false
                i += 1
                guard let r = parsePower() else { return nil }
                if ch == "*" || ch == "×" { v *= r } else {
                    if r == 0 { return nil }
                    v /= r
                }
            }
            return v
        }

        mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = parsePower() else { return nil }
                lastPercent = false
                return pow(base, e)
            }
            return base
        }

        mutating func parseUnary() -> Double? {
            if peek() == "-" { i += 1; return parseUnary().map { -$0 } }
            return parsePostfix()
        }

        mutating func parsePostfix() -> Double? {
            guard var v = parsePrimary() else { return nil }
            lastPercent = false
            while peek() == "%" { i += 1; v /= 100; lastPercent = true }
            return v
        }

        mutating func parsePrimary() -> Double? {
            if peek() == "(" {
                i += 1
                guard let v = parseExpression(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            skip()
            let start = i
            while i < c.count, c[i].isNumber || c[i] == "." { i += 1 }
            guard i > start else { return nil }
            return Double(String(c[start..<i]))
        }
    }
}

// MARK: - Ссылки без трекинга

enum Tracking {
    private static let params: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "yclid", "ysclid", "msclkid", "mc_cid", "mc_eid",
        "igshid", "igsh", "_hsenc", "_hsmi", "ref_src", "ref_url", "spm", "vero_id", "oly_enc_id", "oly_anon_id",
        "rb_clickid", "s_cid", "twclid", "ttclid", "_openstat", "trk", "trkCampaign",
    ]

    /// Убирает utm_* и прочие метки слежки. nil — если чистить нечего.
    static func clean(_ url: URL) -> URL? {
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comp.queryItems, !items.isEmpty else { return nil }
        let host = (url.host ?? "").lowercased()
        let kept = items.filter { q in
            let n = q.name.lowercased()
            if n.hasPrefix("utm_") || params.contains(n) { return false }
            if n == "si", host.contains("youtu") || host.contains("spotify") { return false }
            if n == "feature", host.contains("youtu") { return false }
            return true
        }
        guard kept.count != items.count else { return nil }
        comp.queryItems = kept.isEmpty ? nil : kept
        return comp.url
    }
}

// MARK: - Код: распознавание и подсветка

enum Code {
    private static let cliStarts = ["git ", "npm ", "npx ", "yarn ", "pnpm ", "brew ", "cd ", "sudo ", "python", "pip ",
                                    "curl ", "swift ", "cargo ", "docker ", "kubectl ", "ssh ", "ls ", "mkdir ",
                                    "rm ", "cp ", "mv ", "chmod ", "export ", "$ ", "./"]
    private static let markers = ["func ", "def ", "class ", "import ", "const ", "let ", "var ", "return ",
                                  "=>", "#include", "fn ", "public ", "private ", "struct ", "if (", "for (",
                                  "</", "/>", "SELECT ", "select ", "function ", "async ", "await "]

    static func looksLikeCode(_ t: String) -> Bool {
        let lines = t.split(whereSeparator: \.isNewline)
        if lines.count == 1 {
            let s = t.trimmingCharacters(in: .whitespaces)
            return cliStarts.contains(where: s.hasPrefix) && s.count < 300
        }
        let structural = lines.filter { l in
            let s = l.trimmingCharacters(in: .whitespaces)
            return s.hasSuffix(";") || s.hasSuffix("{") || s.hasSuffix("}") || s.hasSuffix(":") && s.hasPrefix("def ")
        }.count
        let hasMarker = markers.contains(where: t.contains)
        return (hasMarker && structural >= 1) || structural >= 3
    }

    private static let keywords: Set<String> = [
        "func", "def", "class", "struct", "enum", "import", "from", "return", "if", "else", "elif", "for", "while",
        "in", "let", "var", "const", "function", "async", "await", "try", "catch", "throw", "throws", "guard",
        "switch", "case", "default", "break", "continue", "public", "private", "static", "final", "new", "this",
        "self", "true", "false", "nil", "null", "None", "True", "False", "fn", "pub", "mut", "impl", "use",
        "export", "type", "interface", "extends", "implements", "package", "SELECT", "FROM", "WHERE", "and", "or",
        "not", "with", "as", "lambda", "yield", "do", "then", "fi", "echo", "sudo", "git", "npm",
    ]

    /// Подсветка в стиле тёмной темы Xcode.
    static func highlight(_ text: String) -> AttributedString {
        let src = String(text.prefix(12_000))
        var a = AttributedString(src)
        a.foregroundColor = .white.opacity(0.88)
        let ns = src as NSString
        func paint(_ pattern: String, _ color: Color, _ opts: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                if let r = Range<AttributedString.Index>(m.range, in: a) { a[r].foregroundColor = color }
            }
        }
        let kw = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        paint("\\b(\(kw))\\b", Color(red: 1, green: 0.48, blue: 0.7))
        paint(#"\b\d+(\.\d+)?\b"#, Color(red: 0.85, green: 0.79, blue: 0.49))
        paint(#""(\\.|[^"\\\n])*"|'(\\.|[^'\\\n])*'|`[^`]*`"#, Color(red: 0.99, green: 0.42, blue: 0.36))
        paint(#"//[^\n]*|(^|\s)#[^\n!{]*$|/\*[\s\S]*?\*/"#, Color(red: 0.5, green: 0.55, blue: 0.6), [.anchorsMatchLines])
        return a
    }
}
