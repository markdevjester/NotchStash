import AppKit
import SwiftUI

/// Форма чёлки: сверху «уши», которые плавно переходят в край экрана, снизу скруглённые углы.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRoot: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: ClipStore
    @ObservedObject var shelf: ShelfStore
    let actions: NotchActions

    private var ear: CGFloat { model.state == .open ? 14 : 7 }
    private var radius: CGFloat { model.state == .open ? 32 : (model.state == .peek ? 14 : 10) }

    private var size: CGSize {
        let n = model.notchSize
        switch model.state {
        case .closed: return CGSize(width: n.width + 2 * ear, height: n.height)
        case .peek: return CGSize(width: n.width + 2 * model.peekWing + 2 * ear, height: n.height + 2)
        case .open: return CGSize(width: model.openSize.width, height: model.openSize.height)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if model.state == .open {
                OpenContent(model: model, store: store, shelf: shelf, actions: actions)
                    .padding(.horizontal, ear)
                    .frame(width: model.openSize.width, height: model.openSize.height)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.86, anchor: .top))
                            .combined(with: .offset(y: -18)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
            if model.state == .peek, let item = model.peekItem {
                PeekContent(item: item, store: store, notch: model.notchSize, wing: model.peekWing)
                    .padding(.horizontal, ear)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(top: ear, bottom: radius))
        .shadow(color: .black.opacity(model.state == .open ? 0.55 : 0), radius: 22, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: «Скопировано» — короткая вспышка

struct PeekContent: View {
    let item: ClipItem
    let store: ClipStore
    let notch: CGSize
    let wing: CGFloat

    var body: some View {
        let fix = SmartCache.shared.layoutFix(item)
        let smart = SmartCache.shared.smart(item)
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if fix != nil {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.orange)
                        .font(.system(size: 13, weight: .semibold))
                    Text("Не та раскладка?")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.9))
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Скопировано")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: wing, alignment: .leading)
            .padding(.leading, 10)
            Spacer(minLength: notch.width - 10)
            Group {
                if let fix {
                    Text(fix).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        .truncationMode(.tail)
                } else if case .math(let r) = smart {
                    Text("= " + r).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                } else if item.kind == .image, item.ocrLine != nil {
                    HStack(spacing: 5) {
                        Text("есть текст").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        Image(systemName: "text.viewfinder").font(.system(size: 13)).foregroundStyle(.white)
                        ItemIcon(item: item, store: store, size: 18)
                    }
                } else if case .color(let c) = smart {
                    HStack(spacing: 5) {
                        Text(c.hex).font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                        Circle().fill(c.color).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                    }
                } else {
                    ItemIcon(item: item, store: store, size: 18)
                }
            }
            .frame(width: wing, alignment: .trailing)
            .padding(.trailing, 12)
        }
        .frame(height: notch.height)
        .lineLimit(1)
    }
}

// MARK: раскрытая панель

struct OpenContent: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: ClipStore
    @ObservedObject var shelf: ShelfStore
    let actions: NotchActions
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.visible
        VStack(spacing: 0) {
            // полоска на уровне чёлки: слева название, справа счётчик
            HStack(spacing: 4) {
                tabButton(.history, "История", "clock")
                tabButton(.shelf, shelf.items.isEmpty ? "Полка" : "Полка · \(shelf.items.count)", "tray")
                Spacer()
                Text(model.tab == .history ? "\(store.items.count) в истории" : "⇥ переключить")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.leading, 16)
            .padding(.trailing, 22)
            .frame(height: model.notchSize.height)

            if model.tab == .shelf {
                ShelfView(shelf: shelf, model: model, actions: actions)
            } else {
                historyBody(items)
            }

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 12) {
                if model.tab == .shelf {
                    hint("↩", "вставить"); hint("2× клик", "открыть"); hint("тяни", "в любую программу")
                    hint("⌫", "убрать")
                } else {
                    hint("↩", "вставить"); hint("⌘1–9", "быстро")
                    hint("⌘L", "раскладка"); hint("⌘P", "закрепить"); hint("⌘⌫", "удалить")
                }
                Spacer()
                hint("⇥", model.tab == .shelf ? "история" : "полка")
                hint("esc", "закрыть")
            }
            .padding(.horizontal, 20)
            .frame(height: 30)
        }
        .padding(.bottom, 6)
        .overlay { if model.dropTargeted { dropOverlay } }
        .modifier(DropTarget(model: model, actions: actions))
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onChange(of: model.focusToken) { _, _ in searchFocused = true }
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.82))
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 40)).foregroundStyle(.white)
                Text("Отпустите — положу на полку").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text("Файлы, картинки, ссылки и текст").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, model.notchSize.height + 4)
        .padding(.bottom, 12)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func tabButton(_ tab: NotchTab, _ title: String, _ icon: String) -> some View {
        let on = model.tab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { model.tab = tab }
            if tab == .history { model.focusToken += 1 }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(on ? 0.95 : 0.45))
                .padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(.white.opacity(on ? 0.14 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func historyBody(_ items: [ClipItem]) -> some View {

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                if model.staticRender {
                    Text("Поиск в истории").font(.system(size: 14)).foregroundStyle(.white.opacity(0.35))
                    Spacer()
                } else {
                    TextField("Поиск в истории", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($searchFocused)
                }
                if !model.query.isEmpty {
                    Text("\(items.count)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08)))
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 28)).foregroundStyle(.white.opacity(0.3))
                    Text(model.query.isEmpty ? "Скопируйте что-нибудь — оно появится здесь" : "Ничего не нашлось")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list(items).frame(width: 330)
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                    PreviewPane(item: items.indices.contains(model.selected) ? items[model.selected] : nil,
                                store: store, actions: actions, staticRender: model.staticRender)
                }
            }
        }
    }

    @ViewBuilder
    private func list(_ items: [ClipItem]) -> some View {
        if model.staticRender {
            VStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    ClipRow(item: item, index: i, selected: i == model.selected, store: store)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
        } else {
            scrollingList(items)
        }
    }

    private func scrollingList(_ items: [ClipItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        ClipRow(item: item, index: i, selected: i == model.selected, store: store)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onHover { if $0 { model.selected = i } }
                            .onTapGesture { actions.pick(item, true) }
                            .onDrag { dragProvider(item) }
                            .contextMenu {
                                Button("Вставить") { actions.pick(item, true) }
                                Button("Только скопировать") { actions.pick(item, false) }
                                Button(item.pinned ? "Открепить" : "Закрепить") { actions.pin(item) }
                                Divider()
                                Button("Удалить", role: .destructive) { actions.delete(item) }
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selected) { _, new in
                if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
            }
            .onChange(of: model.query) { _, _ in
                if let first = items.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    private func dragProvider(_ item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .text: return NSItemProvider(object: (item.text ?? "") as NSString)
        case .image:
            if let u = store.imageURL(item), let p = NSItemProvider(contentsOf: u) { return p }
        case .files:
            if let first = item.paths.first, let p = NSItemProvider(contentsOf: URL(fileURLWithPath: first)) { return p }
        }
        return NSItemProvider()
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
            Text(text).font(.system(size: 10))
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.white.opacity(0.45))
    }
}

struct ItemIcon: View {
    let item: ClipItem
    let store: ClipStore
    var size: CGFloat = 28

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let img = store.image(item) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else { symbol("photo") }
            case .files:
                if let p = item.paths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable().scaledToFit()
                } else { symbol("doc") }
            case .text:
                if case .color(let c) = SmartCache.shared.smart(item) {
                    ZStack {
                        Rectangle().fill(.white.opacity(0.08))
                        RoundedRectangle(cornerRadius: size * 0.18).fill(c.color)
                            .overlay(RoundedRectangle(cornerRadius: size * 0.18).stroke(.white.opacity(0.25), lineWidth: 1))
                            .padding(size * 0.12)
                    }
                } else if let smart = SmartCache.shared.smart(item) {
                    symbol(smart.symbol)
                } else if let icon = store.appIcon(item) {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else { symbol("text.alignleft") }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.5))
            .foregroundStyle(.white.opacity(0.6))
            .frame(width: size, height: size)
            .background(.white.opacity(0.08))
    }
}

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let store: ClipStore

    var body: some View {
        HStack(spacing: 10) {
            ItemIcon(item: item, store: store)
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.orange)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(selected ? 0.7 : 0.3))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.white.opacity(0.13) : .clear))
    }

    private var rowTitle: String {
        if item.kind == .image, let line = item.ocrLine { return "«\(line)»" }
        switch SmartCache.shared.smart(item) {
        case .math(let r): return item.title + " = " + r
        case .url(let u, _): return (u.host ?? "") + u.path
        default: return item.title
        }
    }

    private var meta: String {
        let ago = Self.rel.localizedString(for: item.date, relativeTo: Date())
        let kind = item.kind == .image && item.ocrLine != nil ? "картинка с текстом" : nil
        return [kind, item.app, ago].compactMap { $0 }.joined(separator: " · ")
    }

    static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()
}

struct PreviewPane: View {
    let item: ClipItem?
    let store: ClipStore
    let actions: NotchActions
    var staticRender = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item {
                if item.kind == .text, let fix = SmartCache.shared.layoutFix(item) {
                    layoutBanner(fix)
                }
                Group {
                    switch item.kind {
                    case .text: textCard(item)
                    case .image:
                        imageCard(item)
                    case .files:
                        scroll {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(item.paths, id: \.self) { p in
                                    HStack(spacing: 8) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: p))
                                            .resizable().frame(width: 22, height: 22)
                                        Text(p).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85))
                                            .lineLimit(2).truncationMode(.middle)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                if item.kind == .text, let t = item.text, SmartCache.shared.smart(item) == nil {
                    transforms(t)
                }
                Text(details(item))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: карточки по типу

    @ViewBuilder
    private func textCard(_ item: ClipItem) -> some View {
        let text = item.text ?? ""
        switch SmartCache.shared.smart(item) {
        case .color(let c):
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 12).fill(c.color)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15), lineWidth: 1))
                    .frame(height: 110)
                ForEach([("HEX", c.hex), ("RGB", c.rgb), ("HSL", c.hsl)], id: \.0) { label, value in
                    Button { actions.pasteText(value, true) } label: {
                        HStack {
                            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                                .frame(width: 34, alignment: .leading)
                            Text(value).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
                            Spacer()
                            Image(systemName: "arrow.turn.down.left").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
        case .math(let r):
            VStack(alignment: .leading, spacing: 6) {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 15, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    .lineLimit(3)
                Text("= " + r)
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .textSelection(.enabled)
                chip("Вставить результат", system: "equal", key: nil) { actions.pasteText(r, true) }
                    .padding(.top, 4)
            }
        case .url(let u, let clean):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe").font(.system(size: 18)).foregroundStyle(.blue.opacity(0.9))
                    Text(u.host ?? "").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(u.absoluteString).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                    .lineLimit(6).truncationMode(.middle).textSelection(.enabled)
                HStack(spacing: 6) {
                    chip("Открыть", system: "safari", key: nil) { actions.open(u) }
                    if let clean {
                        chip("Без слежки", system: "eye.slash", key: nil) { actions.pasteText(clean.absoluteString, true) }
                    }
                }
                .padding(.top, 2)
                if clean != nil {
                    Text("В ссылке есть метки слежки (utm и др.) — «Без слежки» вставит чистую.")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                }
            }
        case .json(let pretty, let compact):
            VStack(alignment: .leading, spacing: 8) {
                scroll { code(pretty) }
                HStack(spacing: 6) {
                    chip("Красиво", system: "text.alignleft", key: nil) { actions.pasteText(pretty, true) }
                    chip("В одну строку", system: "arrow.left.and.right", key: nil) { actions.pasteText(compact, true) }
                }
            }
        case .code:
            scroll { code(text) }
        case .email(let e):
            VStack(alignment: .leading, spacing: 8) {
                Text(e).font(.system(size: 16, weight: .medium)).foregroundStyle(.white).textSelection(.enabled)
                if let u = URL(string: "mailto:" + e) {
                    chip("Написать письмо", system: "envelope", key: nil) { actions.open(u) }
                }
            }
        case nil:
            scroll {
                Text(String(text.prefix(20_000)))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: картинка и текст на ней

    @ViewBuilder
    private func imageCard(_ item: ClipItem) -> some View {
        let text = item.ocrText ?? ""
        VStack(alignment: .leading, spacing: 8) {
            if let img = store.image(item) {
                Image(nsImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: text.isEmpty ? .infinity : 120)
            }
            if item.ocrText == nil {
                HStack(spacing: 6) {
                    if !staticRender { ProgressView().controlSize(.small) }
                    Text(OCR.enabled ? "Читаю текст на картинке…" : "Распознавание текста выключено в меню")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
            } else if text.isEmpty {
                Label("Текста на картинке нет", systemImage: "text.viewfinder")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
            } else {
                Label("Текст с картинки", systemImage: "text.viewfinder")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                scroll {
                    Text(String(text.prefix(20_000)))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                FlowLayout(spacing: 6) {
                    chip("Вставить текст", system: "text.cursor", key: "⌘T") { actions.pasteText(text, true) }
                    chip("Скопировать", system: "doc.on.doc", key: nil) { actions.pasteText(text, false) }
                    ForEach(Array(OCR.links(in: text).enumerated()), id: \.offset) { _, link in
                        chip(link.title, system: link.url.scheme == "tel" ? "phone" : link.url.scheme == "mailto" ? "envelope" : "link", key: nil) { actions.open(link.url) }
                    }
                }
            }
        }
    }

    private func code(_ text: String) -> some View {
        Text(Code.highlight(text))
            .font(.system(size: 11.5, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
    }

    private func layoutBanner(_ fix: String) -> some View {
        Button { actions.pasteText(fix, true) } label: {
            HStack(spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Похоже, не та раскладка").font(.system(size: 10.5)).foregroundStyle(.orange.opacity(0.85))
                    Text(fix).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                }
                Spacer()
                keycap("⌘L")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.13)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: преобразования

    private func transforms(_ text: String) -> some View {
        let list = TextTransform.allCases.filter { $0.available(for: text) }
        return FlowLayout(spacing: 6) {
            ForEach(list) { t in
                chip(t.title, system: nil, key: t.key) { actions.pasteText(t.apply(text), true) }
            }
        }
    }

    private func chip(_ title: String, system: String?, key: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let system { Image(systemName: system).font(.system(size: 10)) }
                Text(title).font(.system(size: 11, weight: .medium))
                if let key { Text(key).font(.system(size: 9.5, weight: .semibold, design: .rounded)).opacity(0.5) }
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(.white.opacity(0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func keycap(_ k: String) -> some View {
        Text(k).font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
    }

    @ViewBuilder
    private func scroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if staticRender { content() } else { ScrollView { content() }.scrollIndicators(.never) }
    }

    private func details(_ item: ClipItem) -> String {
        var parts: [String] = []
        if let app = item.app { parts.append("из \(app)") }
        parts.append(ClipRow.rel.localizedString(for: item.date, relativeTo: Date()))
        if item.kind == .text { parts.append("\((item.text ?? "").count) симв.") }
        return parts.joined(separator: " · ")
    }
}

/// Раскладывает кнопки в строки с переносом.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Принимает перетаскивание на всю панель (в режиме снимка выключено — рендер его не умеет).
struct DropTarget: ViewModifier {
    @ObservedObject var model: NotchModel
    let actions: NotchActions

    func body(content: Content) -> some View {
        if model.staticRender {
            content
        } else {
            content.onDrop(of: ShelfStore.dropTypes, isTargeted: $model.dropTargeted) { providers in
                actions.drop(providers)
                return true
            }
        }
    }
}
