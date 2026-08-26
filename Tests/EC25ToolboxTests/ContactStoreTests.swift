import Contacts
import XCTest
@testable import EC25Toolbox

/// In-memory `ContactsProviding` so store tests never touch the real Contacts
/// database or trigger permission prompts.
actor MockContactsService: ContactsProviding {
    private var status: CNAuthorizationStatus = .notDetermined
    private var records: [ContactRecord] = []
    private var fetchError: Error?
    private var grantOnRequest = true
    private(set) var fetchCallCount = 0

    func configure(
        status: CNAuthorizationStatus? = nil,
        records: [ContactRecord]? = nil,
        fetchError: Error? = nil,
        grantOnRequest: Bool? = nil
    ) {
        if let status { self.status = status }
        if let records { self.records = records }
        if let fetchError { self.fetchError = fetchError }
        if let grantOnRequest { self.grantOnRequest = grantOnRequest }
    }

    func authorizationStatus() async -> CNAuthorizationStatus { status }

    func requestAccess() async throws -> Bool {
        if grantOnRequest {
            status = .authorized
        } else {
            status = .denied
        }
        return grantOnRequest
    }

    func fetchContacts() async throws -> [ContactRecord] {
        fetchCallCount += 1
        if let fetchError { throw fetchError }
        return records
    }
}

@MainActor
final class ContactStoreTests: XCTestCase {
    private func makeRecord(
        identifier: String,
        given: String = "",
        family: String = "",
        organization: String = "",
        numbers: [String] = []
    ) -> ContactRecord {
        ContactRecord(
            identifier: identifier,
            formattedName: [family, given].filter { !$0.isEmpty }.joined(separator: " "),
            givenName: given,
            familyName: family,
            organizationName: organization,
            phoneNumbers: numbers.map {
                ContactPhoneEntry(label: "phone", value: $0, digits: PhoneNumberMatcher.digits($0))
            },
            thumbnailData: nil
        )
    }

    func testUnknownAuthorizationStatusMapsToRestricted() {
        let unknown = CNAuthorizationStatus(rawValue: 99)!
        XCTAssertEqual(ContactsAuthorizationState(unknown), .restricted)
        XCTAssertEqual(ContactsAuthorizationState(.notDetermined), .notDetermined)
        // `.limited` only exists on iOS today; the app enum still models it
        // and must treat it as readable.
        XCTAssertTrue(ContactsAuthorizationState.limited.allowsReading)
        XCTAssertFalse(ContactsAuthorizationState.denied.allowsReading)
    }

    func testRequestAccessGrantedLoadsContacts() async {
        let service = MockContactsService()
        await service.configure(records: [
            makeRecord(identifier: "c1", given: "伟", family: "张", numbers: ["+8613800138000"])
        ])
        let store = ContactStore(service: service)

        await store.requestAccessIfNeeded()

        XCTAssertEqual(store.authorization, .authorized)
        XCTAssertEqual(store.contacts.count, 1)
        let fetchCount = await service.fetchCallCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testRequestAccessDeniedClearsContactsAndSkipsFetch() async {
        let service = MockContactsService()
        await service.configure(grantOnRequest: false)
        let store = ContactStore(service: service)

        await store.requestAccessIfNeeded()

        XCTAssertEqual(store.authorization, .denied)
        XCTAssertTrue(store.contacts.isEmpty)
        let fetchCount = await service.fetchCallCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testAlreadyAuthorizedAutoloadsOnInit() async {
        let service = MockContactsService()
        await service.configure(
            status: .authorized,
            records: [makeRecord(identifier: "c1", organization: "Acme", numbers: ["5551234567"])]
        )
        let store = ContactStore(service: service)
        await store.statusRefreshTask?.value

        XCTAssertEqual(store.authorization, .authorized)
        XCTAssertEqual(store.contacts.count, 1)
    }

    func testFetchErrorSurfacesAndKeepsSnapshotEmpty() async {
        struct StubError: Error {}
        let service = MockContactsService()
        await service.configure(status: .authorized, fetchError: StubError())
        let store = ContactStore(service: service)
        await store.statusRefreshTask?.value

        XCTAssertEqual(store.authorization, .authorized)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(store.contacts.isEmpty)
    }

    func testDisplayNameResolvesCountryCodeVariants() async {
        let service = MockContactsService()
        await service.configure(
            status: .authorized,
            records: [
                makeRecord(identifier: "c1", given: "伟", family: "张", numbers: ["+8613800138000"]),
                makeRecord(identifier: "c2", organization: "Hotline", numbers: ["01012345678"])
            ]
        )
        let store = ContactStore(service: service)
        await store.statusRefreshTask?.value

        XCTAssertEqual(store.displayName(forNumber: "13800138000"), "张 伟")
        XCTAssertEqual(store.displayName(forNumber: "+86 138-0013-8000"), "张 伟")
        XCTAssertEqual(store.displayName(forNumber: "+861012345678"), "Hotline")
        XCTAssertNil(store.displayName(forNumber: "10086"))
        XCTAssertNil(store.displayName(forNumber: ""))
    }

    func testContactLookupReturnsFullRecordForAvatarResolution() async {
        let service = MockContactsService()
        await service.configure(
            status: .authorized,
            records: [
                makeRecord(identifier: "c1", given: "伟", family: "张", numbers: ["+8613800138000"]),
                makeRecord(identifier: "c2", organization: "Hotline", numbers: ["01012345678"])
            ]
        )
        let store = ContactStore(service: service)
        await store.statusRefreshTask?.value

        XCTAssertEqual(store.contact(forNumber: "+86 138-0013-8000")?.identifier, "c1")
        XCTAssertEqual(store.contact(forNumber: "+861012345678")?.displayName, "Hotline")
        XCTAssertNil(store.contact(forNumber: "10086"))
        XCTAssertNil(store.contact(forNumber: "not-a-number"))
    }

    func testSearchFiltersByNameOrganizationAndDigits() async {
        let service = MockContactsService()
        await service.configure(
            status: .authorized,
            records: [
                makeRecord(identifier: "c1", given: "Wei", family: "Zhang", numbers: ["13800138000"]),
                makeRecord(identifier: "c2", organization: "Acme Ltd", numbers: ["95555"]),
                makeRecord(identifier: "c3", given: "N", family: "NoPhone")
            ]
        )
        let store = ContactStore(service: service)
        await store.statusRefreshTask?.value

        XCTAssertEqual(store.search("").count, 3)
        XCTAssertEqual(store.search("   ").count, 3)
        XCTAssertEqual(store.search("zhang").map(\.id), ["c1"])
        XCTAssertEqual(store.search("acme").map(\.id), ["c2"])
        XCTAssertEqual(store.search("1380").map(\.id), ["c1"])
        XCTAssertTrue(store.search("nobody").isEmpty)
    }
}
