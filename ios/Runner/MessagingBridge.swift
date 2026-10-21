import Flutter
import MessageUI
import UIKit

/// Public MessageUI only. The user must tap Send. Registered in AppDelegate.
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

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
