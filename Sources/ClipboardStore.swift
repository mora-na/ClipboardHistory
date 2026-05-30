import AppKit
import Foundation
import CryptoKit

/// 剪切板历史记录存储管理器
/// 负责管理最多 100 条历史记录，文本保存在内存中，大对象缓存到磁盘
class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    /// 最大历史记录数
    private let maxItems = 100

    /// 历史记录列表（最新在前）
    @Published var items: [ClipboardHistoryItem] = []

    /// 当前选中条目的 ID（用于键盘导航和视觉高亮）
    @Published var selectedItemID: UUID?

    /// 磁盘缓存目录
    private let cacheDir: URL

    /// 元数据存储文件路径
    private let metadataFile: URL

    /// 用于去重的图片哈希缓存
    private var imageHashes: [UUID: String] = [:]

    private init() {
        // 使用 Caches 目录存储大对象缓存
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("ClipboardHistory/cache")
        // 使用 Application Support 存储轻量元数据
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClipboardHistory")
        metadataFile = appDir.appendingPathComponent("history.json")

        // 创建目录
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        // 恢复历史记录
        loadMetadata()
        // 清理孤立缓存文件
        cleanupOrphanedCache()
    }

    // MARK: - 添加记录

    /// 添加新的剪切板记录
    /// - Returns: 是否成功添加（重复内容会返回 false 但会移到最前面）
    @discardableResult
    func addItem(_ item: ClipboardHistoryItem) -> Bool {
        DispatchQueue.main.async {
            // 检查是否与最近一条完全相同
            if let last = self.items.first, self.isSameContent(item, last) {
                return
            }

            // 检查是否已存在于历史记录中
            if let existingIndex = self.items.firstIndex(where: { self.isSameContent(item, $0) }) {
                // 移动到最前面
                let existing = self.items.remove(at: existingIndex)
                var moved = existing
                moved.title = item.title // 更新标题（可能是更新的文件名等）
                self.items.insert(moved, at: 0)
                self.saveMetadata()
                return
            }

            // 添加新记录到最前面
            self.items.insert(item, at: 0)

            // 超过上限则删除最旧记录
            while self.items.count > self.maxItems {
                let removed = self.items.removeLast()
                self.cleanupCacheForItem(removed)
            }

            self.saveMetadata()
        }
        return true
    }

    // MARK: - 移动记录到首位

    /// 选中某条历史记录后将其移到列表最前面
    func moveToTop(_ item: ClipboardHistoryItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            let moved = self.items.remove(at: index)
            self.items.insert(moved, at: 0)
            self.saveMetadata()
        }
    }

    // MARK: - 恢复记录到剪切板

    /// 将历史记录恢复到系统剪切板
    func restoreItem(_ item: ClipboardHistoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text:
            // 大文本从磁盘缓存读取，小文本直接从内存恢复
            if let cacheURL = item.cacheFileURL,
               let data = try? Data(contentsOf: cacheURL),
               let fullText = String(data: data, encoding: .utf8) {
                pasteboard.setString(fullText, forType: .string)
            } else if let text = item.textPreview {
                pasteboard.setString(text, forType: .string)
            }

        case .image:
            if let cacheURL = item.cacheFileURL,
               let image = NSImage(contentsOf: cacheURL) {
                pasteboard.writeObjects([image])
            }

        case .file:
            if let urls = item.fileURLs, !urls.isEmpty {
                pasteboard.writeObjects(urls as [NSURL])
            }

        case .other:
            // 尝试恢复已知的粘贴板类型
            if let cacheURL = item.cacheFileURL,
               let data = try? Data(contentsOf: cacheURL) {
                for typeStr in item.pasteboardTypes {
                    let pbType = NSPasteboard.PasteboardType(typeStr)
                    pasteboard.setData(data, forType: pbType)
                }
            }
        }
    }

    // MARK: - 去重判断

    /// 判断两个记录内容是否相同
    private func isSameContent(_ a: ClipboardHistoryItem, _ b: ClipboardHistoryItem) -> Bool {
        guard a.type == b.type else { return false }

        switch a.type {
        case .text:
            // 大文本用缓存文件 URL（基于 SHA256）比较；小文本直接比较内容
            if let aURL = a.cacheFileURL, let bURL = b.cacheFileURL {
                return aURL == bURL
            }
            if a.cacheFileURL != nil || b.cacheFileURL != nil {
                return false
            }
            return a.textPreview == b.textPreview
        case .image:
            return a.cacheFileURL == b.cacheFileURL
        case .file:
            return a.fileURLStrings == b.fileURLStrings
        case .other:
            return a.pasteboardTypes == b.pasteboardTypes &&
                   a.cacheFileURL == b.cacheFileURL
        }
    }

    // MARK: - 图片缓存

    /// 缓存图片到磁盘，返回缓存文件 URL
    func cacheImage(_ image: NSImage) -> URL? {
        guard let tiffData = image.tiffRepresentation else { return nil }
        let hash = SHA256.hash(data: tiffData).compactMap { String(format: "%02x", $0) }.joined()
        let filename = "img_\(hash).tiff"
        let fileURL = cacheDir.appendingPathComponent(filename)

        // 如果已存在则跳过写入
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        do {
            try tiffData.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            print("ClipboardHistory: 图片缓存写入失败: \(error)")
            return nil
        }
    }

    /// 缓存通用数据到磁盘
    func cacheData(_ data: Data, prefix: String = "data") -> URL? {
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let filename = "\(prefix)_\(hash)"
        let fileURL = cacheDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            print("ClipboardHistory: 数据缓存写入失败: \(error)")
            return nil
        }
    }

    // MARK: - 缓存清理

    /// 清理指定记录对应的缓存
    private func cleanupCacheForItem(_ item: ClipboardHistoryItem) {
        if let cacheURL = item.cacheFileURL {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    /// 清理不再被任何历史记录引用的孤立缓存文件
    private func cleanupOrphanedCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        ) else { return }

        let referencedURLs = Set(items.compactMap { $0.cacheFileURL })
        for file in files {
            if !referencedURLs.contains(file) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - 元数据持久化

    /// 保存元数据到 JSON 文件
    private func saveMetadata() {
        // 只保存元数据（不包含大文本内容，文本已在 textPreview 中）
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: metadataFile, options: .atomic)
        } catch {
            print("ClipboardHistory: 元数据保存失败: \(error)")
        }
    }

    /// 从 JSON 文件加载元数据
    private func loadMetadata() {
        guard FileManager.default.fileExists(atPath: metadataFile.path) else { return }
        do {
            let data = try Data(contentsOf: metadataFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([ClipboardHistoryItem].self, from: data)
            // 裁剪到最大数量
            while items.count > maxItems {
                let removed = items.removeLast()
                cleanupCacheForItem(removed)
            }
        } catch {
            print("ClipboardHistory: 元数据加载失败: \(error)")
        }
    }
}
