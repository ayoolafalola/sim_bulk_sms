import Flutter
import MessageUI
import UIKit
import UserNotifications

/// Public MessageUI only. The user must tap Send. Registered in AppDelegate.
/// Also schedules the local reminders for scheduled campaigns (texts can't be sent in the background on iOS).
final class MessagingBridge: NSObject, MFMessageComposeViewControllerDelegate {
    private var pending: FlutterResult?

    static func register(with messenger: FlutterBinaryMessenger, bridge: MessagingBridge) {
        let ch = FlutterMethodChannel(name: "app.sim_bulk_sms/sms_methods", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            switch call.method {
            case "getCapabilities":
                result(["canSendText": MFMessageComposeViewController.canSendText()])
            case "presentMessageComposer":
                bridge.present(call.arguments as? [String: Any], result)
            case "requestReminderPermission":
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                    DispatchQueue.main.async { result(ok) }
                }
            case "setReminders":
                MessagingBridge.setReminders(call.arguments as? [[String: Any]] ?? [], result)
            default: result(FlutterMethodNotImplemented)
            }
        }
    }

    private func present(_ args: [String: Any]?, _ result: @escaping FlutterResult) {
        guard pending == nil else { result("unsupported"); return }   // one composer at a time
        guard MFMessageComposeViewController.canSendText() else { result("unavailable"); return }
        guard let args = args, let recipients = args["recipients"] as? [String],
              let body = args["body"] as? String else { result("unsupported"); return }
        guard let top = Self.topViewController() else { result("failed"); return }
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = self
        vc.recipients = recipients
        vc.body = body
        pending = result
        top.present(vc, animated: true)
    }

    func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                      didFinishWith r: MessageComposeResult) {
        let out: String
        switch r {
        case .sent: out = "sent"          // queued by iOS; NOT proof of delivery
        case .cancelled: out = "cancelled"
        case .failed: out = "failed"
        @unknown default: out = "unsupported"
        }
        controller.dismiss(animated: true) { [weak self] in
            self?.pending?(out); self?.pending = nil
        }
    }

    /// Replaces all scheduled-campaign reminders with [list]: [{id, at (ms since epoch), title, body}].
    private static func setReminders(_ list: [[String: Any]], _ result: @escaping FlutterResult) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers:
                pending.map(\.identifier).filter { $0.hasPrefix("schedule-") })
            for r in list.prefix(60) {   // iOS keeps at most 64 pending
                guard let id = r["id"] as? String, let ms = (r["at"] as? NSNumber)?.doubleValue,
                      let title = r["title"] as? String, let body = r["body"] as? String else { continue }
                let when = Date(timeIntervalSince1970: ms / 1000)
                guard when > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
                center.add(UNNotificationRequest(identifier: "schedule-\(id)", content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
            }
            DispatchQueue.main.async { result(true) }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
