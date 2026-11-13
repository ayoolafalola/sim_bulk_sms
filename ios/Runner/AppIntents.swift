import AppIntents
import Foundation

/// Siri, Spotlight and the Shortcuts app: open Messages++ at the right
/// screen. Nothing is ever sent without the person tapping Send.
@available(iOS 16.0, *)
private protocol MessagesDeepLinkIntent: AppIntent {
    static var target: URL { get }
}

@available(iOS 16.0, *)
extension MessagesDeepLinkIntent {
    static var openAppWhenRun: Bool { true }
    func perform() async throws -> some IntentResult {
        UserDefaults.standard
            .set(Self.target.absoluteString, forKey: NativeIntegrationBridge.pendingLinkKey)
        return .result()
    }
}

@available(iOS 16.0, *)
struct NewMessageIntent: MessagesDeepLinkIntent {
    static var title: LocalizedStringResource = "New Message"
    static var description = IntentDescription("Write a new text in Messages++.")
    static let target = URL(string: "messagesplus://messages/new")!
}

@available(iOS 16.0, *)
struct MessageGroupIntent: MessagesDeepLinkIntent {
    static var title: LocalizedStringResource = "Message a Group"
    static var description = IntentDescription("Send one message to a whole group.")
    static let target = URL(string: "messagesplus://campaigns/new")!
}

@available(iOS 16.0, *)
struct OpenChatsIntent: MessagesDeepLinkIntent {
    static var title: LocalizedStringResource = "Open Contacts++ Chats"
    static let target = URL(string: "messagesplus://messages")!
}

@available(iOS 16.0, *)
struct BirthdayWishesIntent: MessagesDeepLinkIntent {
    static var title: LocalizedStringResource = "Birthday Wishes"
    static let target = URL(string: "messagesplus://birthdays")!
}

@available(iOS 16.0, *)
struct MessagesAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewMessageIntent(), phrases: ["New message in \(.applicationName)", "Text with \(.applicationName)"],
                    shortTitle: "New message", systemImageName: "square.and.pencil")
        AppShortcut(intent: MessageGroupIntent(), phrases: ["Message a group with \(.applicationName)"],
                    shortTitle: "Message a group", systemImageName: "person.3")
        AppShortcut(intent: OpenChatsIntent(), phrases: ["Open my chats in \(.applicationName)"],
                    shortTitle: "Chats", systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(intent: BirthdayWishesIntent(), phrases: ["Birthday wishes in \(.applicationName)"],
                    shortTitle: "Birthdays", systemImageName: "gift")
    }
}
