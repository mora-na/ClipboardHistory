import AppKit
import Foundation

/// 剪切板内容类型
enum ClipboardItemType: String, Codable {
    case text
    case image
    case file
    case other
}

/// 剪切板历史记录条目
struct ClipboardHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let type: ClipboardItemType
    var title: String
    let textPreview: String?
    let createdAt: Date
    var fileURLStrings: [String]?
    var cacheFileURL: URL?
    var pasteboardTypes: [String]

    // 计算属性
    var idStr: String { id.uuidString }

    var fileURLs: [URL]? {
        fileURLStrings?.compactMap { URL(string: $0) }
    }

    init(
        id: UUID = UUID(),
        type: ClipboardItemType,
        title: String,
        textPreview: String? = nil,
        createdAt: Date = Date(),
        fileURLStrings: [String]? = nil,
        cacheFileURL: URL? = nil,
        pasteboardTypes: [String] = []
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.textPreview = textPreview
        self.createdAt = createdAt
        self.fileURLStrings = fileURLStrings
        self.cacheFileURL = cacheFileURL
        self.pasteboardTypes = pasteboardTypes
    }
}
