import AppKit
import SwiftUI

/// 应用委托
/// 负责应用生命周期管理、初始化剪切板监听和全局快捷键
class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = ClipboardMonitor.shared
    private let hotkeyManager = HotkeyManager.shared
    private let windowController = HistoryWindowController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置为后台应用（无 Dock 图标）
        NSApplication.shared.setActivationPolicy(.accessory)

        // 初始化剪切板存储（恢复历史记录）
        _ = ClipboardStore.shared

        // 启动剪切板监听
        monitor.start()

        // 注册全局快捷键
        hotkeyManager.onHotkey = { [weak self] in
            self?.windowController.show()
        }
        hotkeyManager.register()

        print("ClipboardHistory: 已启动，使用 ⌘⇧V 查看剪切板历史")

        // 检查辅助功能权限
        checkAccessibilityPermission()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 释放资源
        monitor.stop()
        hotkeyManager.unregister()
    }

    /// 允许应用在 Dock 不可见时也能接收全局事件
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.hide()
        return false
    }

    // MARK: - 辅助功能权限

    /// 检查辅助功能权限，未授权时弹窗引导用户开启
    private func checkAccessibilityPermission() {
        if AXIsProcessTrusted() { return }

        // 延迟弹出，避免与应用启动时序冲突
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.promptForAccessibility()
        }
    }

    private func promptForAccessibility() {
        // 再次检查，避免用户在此期间已授权
        guard !AXIsProcessTrusted() else { return }

        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = """
        ClipboardHistory 需要「辅助功能」权限才能在选择历史记录后自动粘贴到输入框。

        请在打开的「隐私与安全性」设置中：
        1. 点按「辅助功能」
        2. 找到 ClipboardHistory 并开启开关
        （如果未显示在列表中，请点按 + 手动添加此应用）

        授权后无需重启，即刻生效。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        alert.alertStyle = .informational

        // 短暂激活应用以显示弹窗
        NSApplication.shared.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
