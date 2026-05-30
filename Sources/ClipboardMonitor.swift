import AppKit
import Foundation
import ImageIO

/// 剪切板监听器
/// 通过轮询 NSPasteboard.general.changeCount 检测剪切板变化
class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: DispatchSourceTimer?
    private let pollInterval: TimeInterval = 0.75 // 0.75 秒轮询间隔
    private let store = ClipboardStore.shared

    /// 跳过自身恢复操作的时间窗口（恢复完成后 0.5 秒内的变更将被忽略）
    private var skipUntil: Date?

    private init() {
        lastChangeCount = pasteboard.changeCount
    }

    /// 开始监听
    func start() {
        let queue = DispatchQueue(label: "com.clipboardhistory.monitor", qos: .utility)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer?.schedule(deadline: .now(), repeating: pollInterval)
        timer?.setEventHandler { [weak self] in
            self?.checkPasteboard()
        }
        timer?.resume()
    }

    /// 停止监听
    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 通知监听器即将修改剪切板（用于自身恢复操作时过滤后续变更）
    func willModifyPasteboard() {
        // 设置 0.5 秒的跳过窗口，覆盖 clearContents + writeObjects 可能触发的多次变更
        skipUntil = Date().addingTimeInterval(0.5)
    }

    // MARK: - 私有方法

    private func checkPasteboard() {
        let currentChangeCount = pasteboard.changeCount

        // 在跳过窗口内忽略所有变更（自身恢复操作触发）
        if let until = skipUntil {
            if Date() < until {
                lastChangeCount = currentChangeCount
                return
            }
            skipUntil = nil
        }

        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        // 读取粘贴板内容
        guard let item = readPasteboard() else { return }
        store.addItem(item)
        store.releaseAllocatorPressure()
    }

    /// 读取当前粘贴板内容并创建历史记录条目
    private func readPasteboard() -> ClipboardHistoryItem? {
        let types = pasteboard.types ?? []

        // 检测类型（按优先级）
        if types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) {
            return readFileItem(types: types)
        } else if types.contains(.png) || types.contains(.tiff) {
            return readImageItem(types: types)
        } else if types.contains(.string) {
            return readTextItem(types: types)
        } else if !types.isEmpty {
            return readOtherItem(types: types)
        }

        return nil
    }

    /// 读取文本类型
    /// 小文本直接保存在内存中，大文本（>10KB）写入磁盘缓存以控制内存占用
    private func readTextItem(types: [NSPasteboard.PasteboardType]) -> ClipboardHistoryItem? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }

        let title = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.count > 80 ? String(title.prefix(80)) + "…" : title

        let textPreview: String?
        let cacheURL: URL?
        let textBytes = text.utf8.count

        if textBytes > 10_000 {
            // 大文本：全文写入磁盘缓存，内存中只保留前 5000 字符用于预览
            let data = Data(text.utf8)
            cacheURL = store.cacheData(data, prefix: "text")
            textPreview = String(text.prefix(5000))
        } else {
            cacheURL = nil
            textPreview = text
        }

        return ClipboardHistoryItem(
            type: .text,
            title: displayTitle.isEmpty ? "(空文本)" : displayTitle,
            textPreview: textPreview,
            cacheFileURL: cacheURL,
            pasteboardTypes: types.map { $0.rawValue }
        )
    }

    /// 读取图片类型
    private func readImageItem(types: [NSPasteboard.PasteboardType]) -> ClipboardHistoryItem? {
        return autoreleasepool {
            let imageData: Data
            let fileExtension: String

            if let pngData = pasteboard.data(forType: .png), !pngData.isEmpty {
                imageData = pngData
                fileExtension = "png"
            } else if let tiffData = pasteboard.data(forType: .tiff), !tiffData.isEmpty {
                imageData = tiffData
                fileExtension = "tiff"
            } else {
                return nil
            }

            guard let cacheURL = store.cacheImageData(imageData, fileExtension: fileExtension) else { return nil }
            let size = imageSize(from: imageData)
            let title = "图片 (\(Int(size.width))×\(Int(size.height)))"

            return ClipboardHistoryItem(
                type: .image,
                title: title,
                cacheFileURL: cacheURL,
                pasteboardTypes: types.map { $0.rawValue }
            )
        }
    }

    private func imageSize(from data: Data) -> NSSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return .zero
        }

        let width = properties[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        return NSSize(width: width, height: height)
    }

    /// 读取文件类型
    private func readFileItem(types: [NSPasteboard.PasteboardType]) -> ClipboardHistoryItem? {
        // 尝试读取文件 URL
        var urls: [URL] = []

        if let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !fileURLs.isEmpty {
            urls = fileURLs
        } else if types.contains(.fileURL),
                  let data = pasteboard.data(forType: .fileURL),
                  let url = URL(dataRepresentation: data, relativeTo: nil) {
            urls = [url]
        }

        guard !urls.isEmpty else { return nil }

        let urlStrings = urls.map { $0.absoluteString }
        let title: String
        if urls.count == 1 {
            title = urls[0].lastPathComponent
        } else {
            title = "\(urls.count) 个文件"
        }

        return ClipboardHistoryItem(
            type: .file,
            title: title,
            fileURLStrings: urlStrings,
            pasteboardTypes: types.map { $0.rawValue }
        )
    }

    /// 读取其他类型（降级保存）
    private func readOtherItem(types: [NSPasteboard.PasteboardType]) -> ClipboardHistoryItem? {
        // 尝试读取第一个可用类型的数据
        var cachedURL: URL?
        var dataDescription = ""

        for type in types {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                if let cacheURL = store.cacheData(data, prefix: "other") {
                    cachedURL = cacheURL
                    dataDescription = "\(data.count) 字节"
                    break
                }
            }
        }

        let typeNames = types.map { $0.rawValue }.joined(separator: ", ")
        let title: String
        if !dataDescription.isEmpty {
            title = "\(typeNames) (\(dataDescription))"
        } else {
            title = typeNames
        }

        return ClipboardHistoryItem(
            type: .other,
            title: title,
            cacheFileURL: cachedURL,
            pasteboardTypes: types.map { $0.rawValue }
        )
    }
}
