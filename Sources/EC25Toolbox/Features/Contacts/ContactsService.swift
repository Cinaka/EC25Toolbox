import Contacts
import Foundation

/// Performs all Contacts work off the main actor. `CNContactStore` is created
/// here and never leaves the actor, which keeps the non-Sendable instance
/// confined to a single isolation domain.
actor ContactsService: ContactsProviding {
    private let backingStore = CNContactStore()

    func authorizationStatus() async -> CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAccess() async throws -> Bool {
        try await backingStore.requestAccess(for: .contacts)
    }

    func fetchContacts() async throws -> [ContactRecord] {
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = CNContactSortOrder.userDefault
        var records: [ContactRecord] = []
        try backingStore.enumerateContacts(with: request) { contact, _ in
            records.append(ContactRecord(contact: contact))
        }
        return records
    }
}

private extension ContactRecord {
    init(contact: CNContact) {
        identifier = contact.identifier
        formattedName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        givenName = contact.givenName
        familyName = contact.familyName
        organizationName = contact.organizationName
        phoneNumbers = contact.phoneNumbers.map { labeled in
            ContactPhoneEntry(
                label: CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: labeled.label ?? ""),
                value: labeled.value.stringValue,
                digits: PhoneNumberMatcher.digits(labeled.value.stringValue)
            )
        }
        thumbnailData = contact.thumbnailImageData
    }
}
