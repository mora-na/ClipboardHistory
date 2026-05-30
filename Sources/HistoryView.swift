import SwiftUI
import AppKit
import ImageIO

/// 剪切板历史记录弹出视图
/// 无标题栏的极简浮窗，鼠标点击直接选中，键盘上下导航+回车确认
struct HistoryView: View {
    @ObservedObject var store = ClipboardStore.shared
    @FocusState private var searchFocused: Bool
    var onSelectItem: (ClipboardHistoryItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchView

            if store.items.isEmpty {
                emptyView
            } else if store.visibleItems.isEmpty {
                noResultsView
            } else {
                listView
            }
        }
        .frame(width: 380, height: 460)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .onMouseMove {
            store.noteMouseMoved()
        }
    }

    // MARK: - 空状态

    private var searchView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            SearchTextField(
                text: Binding(
                    get: { store.searchQuery },
                    set: { store.updateSearchQuery($0) }
                ),
                placeholder: "/text、/file、/image 或输入关键词",
                focusRequestID: store.searchFocusRequestID,
                onMarkedTextChanged: { store.updateSearchMarkedText($0) }
            )
            .frame(height: 18)

            if !store.searchQuery.isEmpty {
                Button {
                    store.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            searchFocused = true
        }
        .onChange(of: store.searchFocusRequestID) { _ in
            searchFocused = true
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("暂无剪切板历史")
                .font(.body)
                .foregroundColor(.secondary)
            Text("使用 ⌘⇧V 打开此窗口")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text("没有匹配的历史记录")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 历史列表（手动实现，不使用 List，以精确控制选中行为）

    private var listView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.visibleItems) { item in
                        HistoryRowView(
                            item: item,
                            isSelected: store.selectedItemID == item.id,
                            highlightKeyword: store.highlightKeyword
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                store.selectFromHover(item.id)
                            }
                        }
                        .onTapGesture {
                            store.selectedItemID = item.id
                            onSelectItem(item)
                        }

                        // 分隔线
                        if item.id != store.visibleItems.last?.id {
                            Divider()
                                .padding(.leading, 38)
                        }
                    }
                }
            }
            .onChange(of: store.scrollRequestID) { _ in
                guard let id = store.keyboardScrollItemID else { return }
                withTransaction(Transaction(animation: .easeOut(duration: 0.12))) {
                    if store.scrollRequestUsesTopAnchor {
                        proxy.scrollTo(id, anchor: .top)
                    } else {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }
}

// MARK: - Search field with IME marked-text tracking

private struct SearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequestID: UUID
    let onMarkedTextChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onMarkedTextChanged: onMarkedTextChanged)
    }

    func makeNSView(context: Context) -> SearchNSTextField {
        let textField = SearchNSTextField()
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: SearchNSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        if context.coordinator.focusRequestID != focusRequestID {
            context.coordinator.focusRequestID = focusRequestID
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var focusRequestID: UUID?
        let onMarkedTextChanged: (Bool) -> Void

        init(text: Binding<String>, onMarkedTextChanged: @escaping (Bool) -> Void) {
            _text = text
            self.onMarkedTextChanged = onMarkedTextChanged
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? SearchNSTextField else { return }
            text = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            onMarkedTextChanged(false)
        }
    }
}

private final class SearchNSTextField: NSTextField {
}

func searchFieldHasMarkedText() -> Bool {
    guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
        return false
    }
    return textView.hasMarkedText()
}

// MARK: - Mouse move tracking

private struct MouseMovedViewModifier: ViewModifier {
    let mouseMoved: () -> Void

    func body(content: Content) -> some View {
        content.background(MouseMovedRepresentable(mouseMoved: mouseMoved))
    }
}

private struct MouseMovedRepresentable: NSViewRepresentable {
    let mouseMoved: () -> Void

    func makeNSView(context: Context) -> MouseMovedView {
        let view = MouseMovedView()
        view.mouseMoved = mouseMoved
        return view
    }

    func updateNSView(_ nsView: MouseMovedView, context: Context) {
        nsView.mouseMoved = mouseMoved
        nsView.refreshTrackingArea()
    }
}

private final class MouseMovedView: NSView {
    var mouseMoved: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea()
    }

    func refreshTrackingArea() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .activeAlways,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        mouseMoved?()
    }
}

private extension View {
    func onMouseMove(_ mouseMoved: @escaping () -> Void) -> some View {
        modifier(MouseMovedViewModifier(mouseMoved: mouseMoved))
    }
}

// MARK: - 单行历史记录视图

struct HistoryRowView: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool
    let highlightKeyword: String?

    var body: some View {
        HStack(spacing: 10) {
            leadingVisual

            // 内容摘要
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(timeAgo)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
    }

    // MARK: - 辅助属性

    @ViewBuilder
    private var leadingVisual: some View {
        if item.type == .image,
           let cacheURL = item.cacheFileURL,
           let image = ImageThumbnailProvider.shared.thumbnail(for: cacheURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
        } else {
            Image(systemName: iconName)
                .frame(width: 20, height: 20)
                .foregroundColor(iconColor)
        }
    }

    private var highlightedTitle: AttributedString {
        var result = AttributedString(item.title)
        guard let keyword = highlightKeyword,
              !keyword.isEmpty else {
            return result
        }

        let title = item.title
        var searchStart = title.startIndex
        while searchStart < title.endIndex,
              let range = title.range(
                of: keyword,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<title.endIndex
              ),
              let attributedRange = Range(range, in: result) {
            result[attributedRange].backgroundColor = .yellow
            result[attributedRange].foregroundColor = .black
            searchStart = range.upperBound
        }
        return result
    }

    private var iconName: String {
        switch item.type {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .file: return "doc"
        case .other: return "questionmark.square"
        }
    }

    private var iconColor: Color {
        switch item.type {
        case .text: return .blue
        case .image: return .purple
        case .file: return .orange
        case .other: return .gray
        }
    }

    private var timeAgo: String {
        let interval = Date().timeIntervalSince(item.createdAt)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        return "\(Int(interval / 86400)) 天前"
    }
}

final class ImageThumbnailProvider {
    static let shared = ImageThumbnailProvider()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 12
        cache.totalCostLimit = 256 * 1024
    }

    func thumbnail(for url: URL) -> NSImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: 24
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: 24, height: 24))
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    func remove(url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
