import AppKit

/// 剪切板历史工具入口
/// 极简 macOS 后台应用，监听剪切板变化并提供历史记录查看
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
