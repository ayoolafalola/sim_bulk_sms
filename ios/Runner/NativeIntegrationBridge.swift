import Flutter
import Intents
import UIKit

/// `app.sim_bulk_sms/ios_integration`: links left by Siri/Spotlight shortcuts
/// (App Intents run in the app; the Share Extension opens a link instead), and conversation
/// donations so recent people appear at the top of the share sheet.
final class NativeIntegrationBridge {
    static let appGroup = "group.com.comeriver.messages"
    static let pendingLinkKey = "pending-app-link"
    static let incomingShareFile = "incoming-share.json"

    static func register(with messenger: FlutterBinaryMessenger) {
        let ch = FlutterMethodChannel(name: "app.sim_bulk_sms/ios_integration", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            switch call.method {
            case "takePendingLink":
                let defaults: UserDefaults? = UserDefaults.standard
                let link = defaults?.string(forKey: pendingLinkKey)
                defaults?.removeObject(forKey: pendingLinkKey)
                result(link)
            case "takeIncomingShare":
                result(takeIncomingShare())
            case "donateConversation":
                let args = call.arguments as? [String: Any] ?? [:]
                donate(
                    conversationId: args["id"] as? String ?? "",
                    name: args["name"] as? String ?? "",
                    handle: args["handle"] as? String
                )
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// What the Share Extension saved: {"text": …, "conversation": …}. Read once.
    private static func takeIncomingShare() -> [String: Any]? {
        guard let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let file = folder.appendingPathComponent(incomingShareFile)
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        try? FileManager.default.removeItem(at: file)
        return json
    }

    /// A conversation the person used: iOS suggests it in the share sheet,
    /// and picking it there opens the Share Extension already addressed to it.
    private static func donate(conversationId: String, name: String, handle: String?) {
        guard !conversationId.isEmpty else { return }
        let person = INPerson(
            personHandle: INPersonHandle(value: handle ?? conversationId, type: handle == nil ? .unknown : .phoneNumber),
            nameComponents: nil,
            displayName: name.isEmpty ? handle : name,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: conversationId
        )
        let intent = INSendMessageIntent(
            recipients: [person],
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: INSpeakableString(spokenPhrase: name.isEmpty ? (handle ?? "") : name),
            conversationIdentifier: conversationId,
            serviceName: nil,
            sender: nil,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.donate(completion: nil)
    }
}
