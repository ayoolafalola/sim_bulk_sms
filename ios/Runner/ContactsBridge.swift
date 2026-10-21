import Contacts
import Flutter

/// Read-only access to the phone's contacts: name + phone number only, one entry per number.
final class ContactsBridge {
    private let store = CNContactStore()

    static func register(with messenger: FlutterBinaryMessenger, bridge: ContactsBridge) {
        let ch = FlutterMethodChannel(name: "app.sim_bulk_sms/contacts", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            switch call.method {
            case "hasPermission": result(bridge.granted())
            case "requestPermission": bridge.requestPermission(result)
            case "getPhoneContacts": bridge.load(result)
            default: result(FlutterMethodNotImplemented)
            }
        }
    }

    private func granted() -> Bool {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        if #available(iOS 18.0, *), s == .limited { return true }
        return s == .authorized
    }

    private func requestPermission(_ result: @escaping FlutterResult) {
        if granted() { result(true); return }
        store.requestAccess(for: .contacts) { ok, _ in DispatchQueue.main.async { result(ok) } }
    }

    private func load(_ result: @escaping FlutterResult) {
        guard granted() else {
            result(FlutterError(code: "permission_denied", message: "Contacts access not granted", details: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [[String: String]] = []
            let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                        CNContactPhoneNumbersKey as CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            req.sortOrder = .userDefault
            do {
                try self.store.enumerateContacts(with: req) { c, _ in
                    let name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
                    for n in c.phoneNumbers {
                        let phone = n.value.stringValue.trimmingCharacters(in: .whitespaces)
                        if !phone.isEmpty { out.append(["name": name, "phone": phone]) }
                    }
                }
                DispatchQueue.main.async { result(out) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "read_failed", message: "\(error)", details: nil))
                }
            }
        }
    }
}
