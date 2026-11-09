import AppKit
import SwiftUI

/// Вкладка «Полка»: сетка вещей, которые можно утащить в любую программу.
struct ShelfView: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var model: NotchModel
    let actions: NotchActions

    var body: some View {
        if shelf.items.isEmpty {
            empty
        } else {
            VStack(spacing: 0) {
                grid
                HStack(spacing: 8) {
                    Text(countText)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    bar("AirDrop всё", "dot.radiowaves.left.and.right") { actions.shelfAirDrop(shelf.items) }
                    bar("Очистить", "trash") { actions.shelfClear() }
                }
                .padding(.horizontal, 18)
                .frame(height: 36)
            }
        }
    }

    private var countText: String {
        let n = shelf.items.count
        let word = n % 10 == 1 && n % 100 != 11 ? "вещь"
            : (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? "вещи" : "вещей"
        return "\(n) \(word) на полке"
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34)).foregroundStyle(.white.opacity(0.35))
            Text("Перетащите сюда файлы, картинки, ссылки или текст")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            Text("Полка открывается сама, если тащить что-нибудь к чёлке.\nПотом вытаскивайте вещи в любую программу или отправляйте по AirDrop.")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
        )
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var grid: some View {
        let cols = Array(repeating: GridItem(.fixed(100), spacing: 10), count: NotchModel.shelfColumns)
        let content = LazyVGrid(columns: cols, spacing: 10) {
            ForEach(Array(shelf.items.enumerated()), id: \.element.id) { i, item in
                ShelfTile(item: item, shelf: shelf, selected: i == model.shelfSelected)
                    .onDrag { shelf.provider(item) }
                    .onTapGesture(count: 2) { actions.shelfOpen(item) }
                    .simultaneousGesture(TapGesture().onEnded { model.shelfSelected = i })
                    .contextMenu {
                        Button("Вставить") { actions.shelfPick(item, true) }
                        Button("Скопировать") { actions.shelfPick(item, false) }
                        if item.url != nil { Button("Открыть") { actions.shelfOpen(item) } }
                        if item.kind == .file { Button("Показать в Finder") { actions.shelfReveal(item) } }
                        Button("Отправить по AirDrop") { actions.shelfAirDrop([item]) }
                        Divider()
                        Button("Убрать с полки", role: .destructive) { actions.shelfRemove(item) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if i == model.shelfSelected {
                            Button { actions.shelfRemove(item) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .white.opacity(0.25))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    }
                    .onHover { if $0 { model.shelfSelected = i } }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)

        return Group {
            if model.staticRender {
                VStack { content; Spacer(minLength: 0) }
            } else {
                ScrollView { content }.scrollIndicators(.never)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func bar(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(.white.opacity(0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    let shelf: ShelfStore
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            thumb
                .frame(width: 58, height: 58)
                .opacity(item.exists ? 1 : 0.35)
            Text(item.exists ? item.name : "Файл пропал")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(item.exists ? 0.85 : 0.4))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(height: 28, alignment: .top)
        }
        .padding(.top, 8)
        .padding(.horizontal, 5)
        .frame(width: 100, height: 104)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(selected ? 0.13 : 0.04)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var thumb: some View {
        switch item.kind {
        case .file:
            if let img = shelf.icon(item) {
                Image(nsImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                symbol("questionmark.folder")
            }
        case .link:
            symbol("link", tint: .blue)
        case .text:
            Text((item.text ?? "").prefix(80))
                .font(.system(size: 7.5))
                .foregroundStyle(.black.opacity(0.75))
                .lineLimit(6)
                .padding(5)
                .frame(width: 48, height: 58, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.92)))
        }
    }

    private func symbol(_ name: String, tint: Color = .white) -> some View {
        Image(systemName: name)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(tint.opacity(0.85))
            .frame(width: 58, height: 58)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08)))
    }
}
