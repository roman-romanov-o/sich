import AppKit
import UserNotifications

@MainActor
enum SystemNotifier {
    static func requestAuthorization() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notifyAttention(count: Int) {
        guard !isRunningTests else { return }
        guard canUseUserNotifications else {
            deliverScriptNotification(count: count)
            fallbackAttention()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "Ghostling needs you" : "\(count) Ghostling tasks need you"
        content.body = count == 1
            ? "A task is waiting for input."
            : "Multiple tasks are waiting for input."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "ghostling-attention-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil {
                Task { @MainActor in
                    deliverScriptNotification(count: count)
                    fallbackAttention()
                }
            }
        }
    }

    private static var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static func deliverScriptNotification(count: Int) {
        let title = count == 1 ? "Ghostling needs you" : "\(count) Ghostling tasks need you"
        let body = count == 1
            ? "A task is waiting for input."
            : "Multiple tasks are waiting for input."
        let script = """
        display notification "\(escapeAppleScript(body))" with title "\(escapeAppleScript(title))"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    private static func escapeAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func fallbackAttention() {
        NSApp.requestUserAttention(.informationalRequest)
        NSSound(named: "Ping")?.play()
    }
}
