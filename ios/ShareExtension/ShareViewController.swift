import Intents
import Social
import UniformTypeIdentifiers

/// "Messages++" in the share sheet: shared text and links open Messages++,
/// where the person picks who gets it (or it goes to the conversation they
/// picked at the top of the share sheet). Nothing is sent from here.
final class ShareViewController: SLComposeServiceViewController {
    override func isContentValid() -> Bool { true }

    override func didSelectPost() {
        let providers = (extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []).flatMap { $0.attachments ?? [] }
        let lock = NSLock()
        let dispatch = DispatchGroup()
        var texts = [contentText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""].filter { !$0.isEmpty }
        for provider in providers {
            for type in [UTType.url, UTType.plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                dispatch.enter()
                provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                    lock.lock(); defer { lock.unlock(); dispatch.leave() }
                    if let url = item as? URL { texts.append(url.absoluteString) }
                    else if let text = item as? String, !texts.contains(text) { texts.append(text) }
                }
                break
            }
        }
        dispatch.notify(queue: .main) { [weak self] in self?.finish(text: texts.joined(separator: "\n")) }
    }

    /// Opens Messages++ with the text in the link (no App Group needed):
    /// the picked conversation's chat, or the screen to choose who gets it.
    private func finish(text: String) {
        let clipped = String(text.prefix(4000))
        var components = URLComponents()
        components.scheme = "messagesplus"
        components.host = "messages"
        if let intent = extensionContext?.intent as? INSendMessageIntent,
           let id = intent.conversationIdentifier, id.hasPrefix("chat:") {
            components.path = "/chat/\(id.dropFirst(5))"
            components.queryItems = [URLQueryItem(name: "draft", value: clipped)]
        } else {
            components.path = "/share"
            components.queryItems = [URLQueryItem(name: "text", value: clipped)]
        }
        guard let link = components.url else {
            extensionContext?.cancelRequest(withError: CocoaError(.fileNoSuchFile)); return
        }
        if openThroughApp(link) {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.open(link) { [weak self] _ in self?.extensionContext?.completeRequest(returningItems: nil) }
        }
    }

    /// Share extensions can't open their app through the extension context;
    /// the application object, found through the responder chain, can.
    private func openThroughApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), NSStringFromClass(type(of: current)).contains("Application") {
                typealias Open = @convention(c) (AnyObject, Selector, URL, NSDictionary, ((Bool) -> Void)?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                open(current, selector, url, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}
