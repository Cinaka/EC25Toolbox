import Contacts
import Foundation

/// Contacts authorization mapped from `CNAuthorizationStatus`. A future
/// unknown status is treated like `restricted`: there is no access, and a
/// Settings button would not help.
enum ContactsAuthorizationState: Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case limited
    case authorized

    /// Reading a snapshot is only possible with full or limited access.
    var allowsReading: Bool { self == .authorized || self == .limited }

    init(_ status: CNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .limited: self = .limited
        case .authorized: self = .authorized
        @unknown default: self = .restricted
        }
    }
}

/// One phone number attached to a contact. The label arrives already
/// localized for display; the digits are normalized for matching.
struct ContactPhoneEntry: Equatable, Identifiable, Sendable {
    var id: String { "\(label)|\(value)" }
    let label: String
    let value: String
    let digits: String
}

/// Minimal projection of a system contact used by caller-ID surfaces and the
/// contacts browser. Only fields the app displays or matches are carried over.
struct ContactRecord: Identifiable, Equatable, Sendable {
    let identifier: String
    /// Name ordered by the user's system preference (`CNContactFormatter`).
    let formattedName: String
    let givenName: String
    let familyName: String
    let organizationName: String
    let phoneNumbers: [ContactPhoneEntry]
    let thumbnailData: Data?

    var id: String { identifier }

    /// Personal name, possibly empty; the formatter output may also be empty.
    var personName: String { formattedName }

    /// Best display name: personal name, else organization, else a number.
    var displayName: String {
        if !personName.isEmpty { return personName }
        if !organizationName.isEmpty { return organizationName }
        return phoneNumbers.first?.value ?? ""
    }

    /// Free-form search across name, organization, and phone numbers.
    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if displayName.localizedCaseInsensitiveContains(trimmed) { return true }
        if organizationName.localizedCaseInsensitiveContains(trimmed) { return true }
        return phoneNumbers.contains { PhoneNumberMatcher.number($0.value, matchesQuery: trimmed) }
    }
}

/// Abstracts `CNContactStore` so the main-actor store stays testable without
/// ever touching the real Contacts database or permission prompts.
protocol ContactsProviding: Sendable {
    func authorizationStatus() async -> CNAuthorizationStatus
    func requestAccess() async throws -> Bool
    func fetchContacts() async throws -> [ContactRecord]
}
