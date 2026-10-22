import Contacts
import Flutter

/// Read-only access to the phone's contacts: the full sync snapshot and a simple name + number list.
final class ContactsBridge {
    private let store = CNContactStore()

    static func register(with messenger: FlutterBinaryMessenger, bridge: ContactsBridge) {
        let ch = FlutterMethodChannel(name: "app.sim_bulk_sms/contacts", binaryMessenger: messenger)
        ch.setMethodCallHandler { call, result in
            switch call.method {
            case "hasPermission": result(bridge.granted())
            case "requestPermission": bridge.requestPermission(result)
            case "getPhoneContacts": bridge.load(result)
            case "syncContacts": bridge.sync(result)
            case "editContact": result(false) // edited in the Contacts app; sync brings changes back
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

    private static func dateString(_ d: DateComponents) -> String? {
        guard let m = d.month, let day = d.day else { return nil }
        if let y = d.year { return String(format: "%04d-%02d-%02d", y, m, day) }
        return String(format: "--%02d-%02d", m, day) // no year, as Android stores it
    }

    /// Full snapshot in the same shape as Android's (iOS has no "changed since" query).
    func sync(_ result: @escaping FlutterResult) {
        guard granted() else {
            result(FlutterError(code: "permission_denied", message: "Contacts access not granted", details: nil))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [[String: Any]] = []
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactBirthdayKey as CNKeyDescriptor, CNContactDatesKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor,
                CNContactPostalAddressesKey as CNKeyDescriptor,
            ]
            let req = CNContactFetchRequest(keysToFetch: keys)
            do {
                try self.store.enumerateContacts(with: req) { c, _ in
                    func label(_ l: String?) -> String { l.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
                    var dates: [[String: Any]] = []
                    if let b = c.birthday, let v = ContactsBridge.dateString(b) { dates.append(["value": v, "kind": "birthday", "label": "Birthday"]) }
                    for d in c.dates {
                        if let v = ContactsBridge.dateString(d.value as DateComponents) {
                            dates.append(["value": v, "kind": d.label == CNLabelDateAnniversary ? "anniversary" : "other", "label": label(d.label)])
                        }
                    }
                    let address = c.postalAddresses.first.map {
                        CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ")
                    }
                    out.append([
                        "contactId": 0, "lookupKey": c.identifier,
                        "name": CNContactFormatter.string(from: c, style: .fullName) ?? "",
                        "given": c.givenName, "family": c.familyName,
                        "phones": c.phoneNumbers.enumerated().map { (i, p) in
                            ["value": p.value.stringValue, "type": p.label == CNLabelPhoneNumberMobile ? 2 : 0,
                             "primary": i == 0, "label": label(p.label)] as [String: Any] },
                        "emails": c.emailAddresses.enumerated().map { (i, e) in
                            ["value": e.value as String, "type": 0, "primary": i == 0, "label": label(e.label)] as [String: Any] },
                        "dates": dates,
                        "organization": c.organizationName.isEmpty ? NSNull() as Any : c.organizationName as Any,
                        "jobTitle": c.jobTitle.isEmpty ? NSNull() as Any : c.jobTitle as Any,
                        "address": address.map { $0 as Any } ?? NSNull(),
                    ])
                }
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                DispatchQueue.main.async { result(["contacts": out, "deleted": [], "now": now, "full": true]) }
            } catch {
                DispatchQueue.main.async { result(FlutterError(code: "read_failed", message: "\(error)", details: nil)) }
            }
        }
    }
}
