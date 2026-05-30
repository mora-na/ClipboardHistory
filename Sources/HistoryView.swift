import SwiftUI
import AppKit

/// 剪切板历史记录弹出视图
/// 无标题栏的极简浮窗，鼠标点击直接选中，键盘上下导航+回车确认
struct HistoryView: View {
    @ObservedObject var store = ClipboardStore.shared
    var onSelectItem: (ClipboardHistoryItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if store.items.isEmpty {
                emptyView
            } else {
                listView
            }

            Divider()

            // 底部退出按钮
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("退出")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(Color(NSColor.controlBackgroundColor))
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
    }

    // MARK: - 空状态

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

    // MARK: - 历史列表（手动实现，不使用 List，以精确控制选中行为）

    private var listView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.items) { item in
                        HistoryRowView(
                            item: item,
                            isSelected: store.selectedItemID == item.id
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            if hovering {
                                store.selectedItemID = item.id
                            }
                        }
                        .onTapGesture {
                            store.selectedItemID = item.id
                            onSelectItem(item)
                        }

                        // 分隔线
                        if item.id != store.items.last?.id {
                            Divider()
                                .padding(.leading, 38)
                        }
                    }
                }
            }
            .onChange(of: store.selectedItemID) { newID in
                guard let id = newID else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

// MARK: - 单行历史记录视图

struct HistoryRowView: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // 类型图标
            Image(systemName: iconName)
                .frame(width: 20, height: 20)
                .foregroundColor(iconColor)

            // 内容摘要
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
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
