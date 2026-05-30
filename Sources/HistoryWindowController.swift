import SwiftUI
import AppKit
import Quartz

private final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class HistoryPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
        super.init()
    }
}

/// 历史记录弹出窗口控制器
/// 无标题栏浮动面板，弹出时短暂激活以接收键盘事件
/// 失去焦点自动关闭，选中后还原上一个应用的焦点再粘贴
class HistoryWindowController: NSObject, NSWindowDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = HistoryWindowController()

    private var panel: NSPanel?
    private var keyEventMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var isConfirming = false
    private var isPreviewing = false
    private var isRestoringFocusAfterPreview = false
    private var previewReturnApp: NSRunningApplication?
    private var previewItem: HistoryPreviewItem?
    private var previewAutoCloseToken = UUID()

    private let monitor = ClipboardMonitor.shared
    private let store = ClipboardStore.shared

    private let windowWidth: CGFloat = 380
    private let windowHeight: CGFloat = 460
    private let mouseHorizontalOffset: CGFloat = 16
    private let mouseVerticalOffset: CGFloat = 6

    private override init() {
        super.init()
    }

    // MARK: - 显示 / 隐藏

    func show() {
        // 记住当前前台应用，以便稍后还原焦点
        previousApp = NSWorkspace.shared.frontmostApplication

        if panel?.isVisible == true {
            hide()
        }

        let p = panel ?? createPanel()
        panel = p
        let targetFrame = frameAtMouse()

        p.alphaValue = 0
        p.orderOut(nil)
        p.setFrame(targetFrame, display: false)
        p.contentView?.layoutSubtreeIfNeeded()

        setupKeyMonitor()
        resetSelection()

        p.orderFrontRegardless()
        p.makeKey()

        p.alphaValue = 1

        DispatchQueue.main.async {
            self.store.focusSearchField()
        }
    }

    private func createPanel() -> NSPanel {
        let historyView = HistoryView { [weak self] item in
            self?.confirmSelection(item)
        }

        let hostingView = NSHostingView(rootView: historyView)
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        let p = HistoryPanel(
            contentRect: offscreenFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        p.contentView = hostingView
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isFloatingPanel = true
        p.collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.hidesOnDeactivate = false
        p.delegate = self
        p.alphaValue = 0
        return p
    }

    func hide() {
        closePreview(restoreFocus: false)
        keyEventMonitor.map { NSEvent.removeMonitor($0) }
        keyEventMonitor = nil

        if let currentPanel = panel {
            currentPanel.alphaValue = 0
            currentPanel.orderOut(nil)
            currentPanel.setFrame(offscreenFrame(), display: false)
        }

        store.releaseTransientMemoryAfterClose()
        cleanupPreviewTempFiles()
        isConfirming = false
    }

    // MARK: - 定位：鼠标为窗口左上角

    private func offscreenFrame() -> NSRect {
        NSRect(x: -10000, y: -10000, width: windowWidth, height: windowHeight)
    }

    private func frameAtMouse() -> NSRect {
        let mouseLoc = NSEvent.mouseLocation

        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLoc, $0.frame, false)
        }) else {
            let fallbackFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
            let x = fallbackFrame.midX - windowWidth / 2
            let y = fallbackFrame.midY - windowHeight / 2
            return NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
        }

        let screenFrame = screen.visibleFrame

        // 从鼠标右下方弹出，避免唤醒后鼠标直接落在列表行上触发 hover 选中
        var x = mouseLoc.x + mouseHorizontalOffset
        var y = mouseLoc.y - windowHeight - mouseVerticalOffset

        // 水平约束
        if x + windowWidth > screenFrame.maxX { x = screenFrame.maxX - windowWidth - 8 }
        if x < screenFrame.minX { x = screenFrame.minX + 8 }

        // 垂直约束：只在屏幕边缘做最小修正，避免显示后再跳位置
        if y + windowHeight > screenFrame.maxY { y = screenFrame.maxY - windowHeight - 8 }
        if y < screenFrame.minY {
            y = screenFrame.minY + 8
        }

        return NSRect(x: x, y: y, width: windowWidth, height: windowHeight)
    }

    // MARK: - 键盘事件

    private func setupKeyMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command), event.keyCode == 13 {
                if self.isPreviewing {
                    self.closePreview(restoreFocus: true)
                } else {
                    self.hide()
                }
                return nil
            }

            if flags.contains(.command), event.keyCode == 12 {
                NSApplication.shared.terminate(nil)
                return nil
            }

            if flags.contains([.command, .option]), event.keyCode == 51 || event.keyCode == 117 {
                self.store.clearAll()
                return nil
            }

            if flags.contains(.command), event.keyCode == 51 || event.keyCode == 117 {
                self.store.deleteSelectedVisibleItem()
                return nil
            }

            switch Int(event.keyCode) {
            case 49: // Space → Quick Look 预览选中项
                if searchFieldHasMarkedText() {
                    return event
                }
                self.togglePreview()
                return nil

            case 126, 123: // ↑ / ← → 上移
                self.moveSelectionUp()
                return nil

            case 125, 124: // ↓ / → → 下移
                self.moveSelectionDown()
                return nil

            case 36: // 回车 → 确认选中
                if let id = self.store.selectedItemID,
                   let item = self.store.visibleItems.first(where: { $0.id == id }) {
                    self.confirmSelection(item)
                }
                return nil

            case 53: // Esc → 关闭
                if !self.store.searchQuery.isEmpty {
                    self.store.clearSearch()
                    return nil
                }
                self.hide()
                return nil

            default:
                return event
            }
        }
    }

    private func moveSelectionUp() {
        let items = store.visibleItems
        guard !items.isEmpty else { return }

        guard let current = store.selectedItemID,
              let idx = items.firstIndex(where: { $0.id == current }) else {
            store.selectFromKeyboard(items.last?.id)
            return
        }

        let nextIndex = idx > 0 ? idx - 1 : items.count - 1
        store.selectFromKeyboard(items[nextIndex].id)
    }

    private func moveSelectionDown() {
        let items = store.visibleItems
        guard !items.isEmpty else { return }

        guard let current = store.selectedItemID,
              let idx = items.firstIndex(where: { $0.id == current }) else {
            store.selectFromKeyboard(items.first?.id)
            return
        }

        let nextIndex = idx < items.count - 1 ? idx + 1 : 0
        store.selectFromKeyboard(items[nextIndex].id)
    }

    private func resetSelection() {
        store.prepareForPopupOpen()
    }

    // MARK: - Quick Look

    private func togglePreview() {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            closePreview(restoreFocus: true)
            return
        }

        guard let id = store.selectedItemID,
              let item = store.visibleItems.first(where: { $0.id == id }),
              let previewURL = previewURL(for: item) else {
            return
        }

        previewItem = HistoryPreviewItem(url: previewURL, title: item.title)
        previewReturnApp = NSWorkspace.shared.frontmostApplication ?? previousApp
        isPreviewing = true
        isRestoringFocusAfterPreview = false

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        schedulePreviewAutoClose()
    }

    private func closePreview(restoreFocus: Bool) {
        previewAutoCloseToken = UUID()

        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }

        previewItem = nil
        let shouldRestoreFocus = restoreFocus && isPreviewing
        isPreviewing = false

        if shouldRestoreFocus {
            restoreExternalFocusAfterPreview()
        }
    }

    private func schedulePreviewAutoClose() {
        let token = UUID()
        previewAutoCloseToken = token

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self,
                  self.previewAutoCloseToken == token,
                  self.isPreviewing,
                  let panel = QLPreviewPanel.shared(),
                  panel.isVisible else {
                return
            }

            self.closePreview(restoreFocus: true)
        }
    }

    private func restoreExternalFocusAfterPreview() {
        isRestoringFocusAfterPreview = true
        previewReturnApp?.activate(options: .activateIgnoringOtherApps)
        previewReturnApp = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.isRestoringFocusAfterPreview = false
        }
    }

    private func previewURL(for item: ClipboardHistoryItem) -> URL? {
        switch item.type {
        case .text:
            return textPreviewURL(for: item)
        case .image:
            return item.cacheFileURL
        case .file:
            return item.fileURLs?.first
        case .other:
            return item.cacheFileURL
        }
    }

    private func textPreviewURL(for item: ClipboardHistoryItem) -> URL? {
        let previewDir = previewTempDirectory()
        try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

        let fileURL = previewDir.appendingPathComponent("\(item.id.uuidString).txt")
        let text: String

        if let cacheURL = item.cacheFileURL,
           let data = try? Data(contentsOf: cacheURL),
           let fullText = String(data: data, encoding: .utf8) {
            text = fullText
        } else {
            text = item.textPreview ?? item.title
        }

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            print("ClipboardHistory: 写入预览文本失败: \(error)")
            return nil
        }
    }

    private func previewTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClipboardHistoryPreview", isDirectory: true)
    }

    private func cleanupPreviewTempFiles() {
        try? FileManager.default.removeItem(at: previewTempDirectory())
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItem == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItem
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        previewAutoCloseToken = UUID()
        previewItem = nil
        if isPreviewing {
            isPreviewing = false
            restoreExternalFocusAfterPreview()
        }
    }

    // MARK: - 确认选中

    private func confirmSelection(_ item: ClipboardHistoryItem) {
        isConfirming = true
        let targetApp = previousApp

        monitor.willModifyPasteboard()
        store.restoreItem(item)
        store.moveToTop(item) // 选中的条目移到列表首位
        hide()

        // 立即激活目标应用（同步调用，与 orderOut 由窗口服务器依次处理）
        targetApp?.activate(options: .activateIgnoringOtherApps)

        // 给窗口服务器一个短暂周期完成焦点切换，然后粘贴
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            self.simulatePaste()
            self.isConfirming = false
        }
    }

    // MARK: - 模拟粘贴

    private func simulatePaste() {
        // 辅助功能权限是 CGEvent 模拟按键的前提，未授权时静默跳过
        guard AXIsProcessTrusted() else {
            print("ClipboardHistory: 无辅助功能权限，跳过自动粘贴（剪切板内容已恢复）")
            return
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09 // V 键

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            print("ClipboardHistory: 创建粘贴模拟事件失败")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)

        // 按键按下和释放之间需要短暂间隔，否则系统可能不识别
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            keyUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - NSWindowDelegate

    /// 窗口失去焦点 → 用户点击了其他地方 → 关闭
    func windowDidResignKey(_ notification: Notification) {
        if isPreviewing || isRestoringFocusAfterPreview {
            return
        }

        if !isConfirming {
            hide()
        }
    }
}
