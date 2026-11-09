import AppKit
import Vision

/// Распознавание текста на картинках через Apple Vision — прямо на Mac, без интернета.
enum OCR {
    private static let queue = DispatchQueue(label: "notchstash.ocr", qos: .utility)   // по одной картинке за раз

    static var enabled: Bool { UserDefaults.standard.object(forKey: "ocr") as? Bool ?? true }

    /// Распознаёт текст в файле картинки. Ответ приходит на главном потоке; "" — текста нет.
    static func recognize(url: URL, completion: @escaping (String) -> Void) {
        queue.async {
            let text = recognizeNow(url: url)
            DispatchQueue.main.async { completion(text) }
        }
    }

    static func recognizeNow(url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
        // совсем крошечные картинки (иконки) не читаем
        guard cg.width >= 24, cg.height >= 12 else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let wanted = ["ru-RU", "en-US", "uk-UA"]
        if let supported = try? req.supportedRecognitionLanguages() {
            req.recognitionLanguages = wanted.filter(supported.contains)
        }
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        let obs = (req.results ?? []).filter { ($0.topCandidates(1).first?.confidence ?? 0) > 0.3 }
        return lines(obs).joined(separator: "\n")
    }

    /// Собирает строки сверху вниз; куски на одной высоте склеивает слева направо.
    private static func lines(_ obs: [VNRecognizedTextObservation]) -> [String] {
        let sorted = obs.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [[VNRecognizedTextObservation]] = []
        for o in sorted {
            if let last = rows.last?.first,
               abs(last.boundingBox.midY - o.boundingBox.midY) < min(last.boundingBox.height, o.boundingBox.height) * 0.5 {
                rows[rows.count - 1].append(o)
            } else {
                rows.append([o])
            }
        }
        return rows.map { row in
            row.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "  ")
        }
    }

    /// Ссылки, почта и телефоны внутри распознанного текста.
    static func links(in text: String) -> [(title: String, url: URL)] {
        guard !text.isEmpty,
              let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
                                                | NSTextCheckingResult.CheckingType.phoneNumber.rawValue) else { return [] }
        var links: [(String, URL)] = [], mails: [(String, URL)] = [], phones: [(String, URL)] = []
        for m in det.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let raw = String(text[r])
            if let u = m.url {
                if u.scheme == "mailto" { mails.append((raw, u)) } else { links.append((u.host ?? raw, u)) }
            } else if let phone = m.phoneNumber {
                // телефоном считаем только номер с «+» или с 8 в начале — иначе это трек, счёт или артикул
                let p = phone.trimmingCharacters(in: .whitespaces)
                let digits = p.filter(\.isNumber)
                let looksLikePhone = (p.hasPrefix("+") && (10...15).contains(digits.count))
                    || (p.hasPrefix("8") && digits.count == 11)
                if looksLikePhone, let u = URL(string: "tel:" + (p.hasPrefix("+") ? "+" : "") + digits) {
                    phones.append((p, u))
                }
            }
        }
        return Array((links + mails + phones).prefix(4))
    }
}

extension ClipStore {
    /// Запускает распознавание для картинки, если его ещё не было.
    func recognizeIfNeeded(_ item: ClipItem, done: ((ClipItem) -> Void)? = nil) {
        guard OCR.enabled, item.kind == .image, item.ocrText == nil,
              !ocrPending.contains(item.id), let url = imageURL(item) else { return }
        ocrPending.insert(item.id)
        OCR.recognize(url: url) { [weak self] text in
            guard let self else { return }
            self.ocrPending.remove(item.id)
            if let updated = self.setOCR(item.id, text) { done?(updated) }
        }
    }

    /// Дочитывает картинки, которые попали в историю раньше (по одной, в фоне).
    func backfillOCR() {
        for it in items where it.kind == .image && it.ocrText == nil { recognizeIfNeeded(it) }
    }
}
