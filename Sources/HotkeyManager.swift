import Carbon
import AppKit

/// 全局快捷键管理器
/// 使用 Carbon 的 RegisterEventHotKey API 注册全局快捷键
/// 使用原生 Carbon 框架，无需第三方依赖
class HotkeyManager {
    static let shared = HotkeyManager()

    /// 全局快捷键回调
    var onHotkey: (() -> Void)?

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// 快捷键签名（用于唯一标识）
    private let hotkeySignature = OSType(0x434C4948) // "CLIH"

    private init() {}

    /// 注册全局快捷键 Command + Shift + V
    func register() {
        // 定义事件处理器（监听热键按下事件）
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        // 保存 self 指针以便在 C 回调中使用
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        guard status == noErr else {
            print("ClipboardHistory: 安装事件处理器失败: \(status)")
            return
        }

        // 注册 Command + Shift + V 快捷键
        // kVK_ANSI_V = 0x09 (V 键)
        // cmdKey = 0x0100, shiftKey = 0x0200
        let hotkeyID = EventHotKeyID(signature: hotkeySignature, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),        // V 键
            UInt32(cmdKey | shiftKey), // Command + Shift
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if registerStatus != noErr {
            print("ClipboardHistory: 注册快捷键失败: \(registerStatus)")
            // 如果 Command+Shift+V 注册失败，尝试 Option+Shift+V
            let fallbackStatus = RegisterEventHotKey(
                UInt32(kVK_ANSI_V),
                UInt32(optionKey | shiftKey),
                hotkeyID,
                GetApplicationEventTarget(),
                0,
                &hotkeyRef
            )
            if fallbackStatus == noErr {
                print("ClipboardHistory: 已使用 Option+Shift+V 作为备用快捷键")
            } else {
                print("ClipboardHistory: 备用快捷键注册也失败: \(fallbackStatus)")
            }
        }
    }

    /// 注销全局快捷键
    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}

/// Carbon 事件处理回调
/// 当全局快捷键被按下时，此回调在后台线程触发
private func hotkeyEventHandler(
    _ handler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = userData else { return OSStatus(eventNotHandledErr) }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

    // 切换到主线程执行回调
    DispatchQueue.main.async {
        manager.onHotkey?()
    }

    return noErr
}
