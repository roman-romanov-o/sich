import AppKit
import UserNotifications

@MainActor
enum SystemNotifier {
    static func requestAuthorization() {
        guard canUseUserNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notifyAttention(count: Int) {
        let title = count == 1 ? "Sich needs you" : "\(count) Sich tasks need you"
        let body = count == 1
            ? "A task is waiting for input."
            : "Multiple tasks are waiting for input."
        deliver(title: title, body: body, category: "attention")
    }

    /// Fire on a task's manual transition into DONE. Names the task so the operator
    /// knows which of several parallel tasks was completed.
    static func notifyDone(taskName: String) {
        deliver(title: "✅ Task done — \(taskName)",
                body: "The task was marked complete.",
                category: "done")
    }

    /// Single delivery path: try `UNUserNotificationCenter` when we're a real .app
    /// bundle, else fall back to `osascript` + a dock/sound nudge. One place so
    /// every notification kind behaves identically (US: "good notifications").
    private static func deliver(title: String, body: String, category: String) {
        guard !isRunningTests else { return }
        guard canUseUserNotifications else {
            deliverScriptNotification(title: title, body: body)
            fallbackAttention()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "sich-\(category)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil {
                Task { @MainActor in
                    deliverScriptNotification(title: title, body: body)
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

    private static func deliverScriptNotification(title: String, body: String) {
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
