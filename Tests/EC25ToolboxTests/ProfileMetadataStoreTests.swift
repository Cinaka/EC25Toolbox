@testable import EC25Toolbox
import XCTest

final class ProfileMetadataStoreTests: XCTestCase {
    private var store: ProfileMetadataStore!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-metadata-tests-\(UUID().uuidString)", isDirectory: true)
        store = ProfileMetadataStore(applicationSupportDirectory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(
        eid: String = "89000000000000000000000000000001",
        iccid: String = "8900000000000000001",
        label: String = "工作号",
        phone: String = "+8613800000000",
        tags: [String] = ["work"]
    ) -> ProfileMetadata {
        ProfileMetadata(
            eid: eid,
            iccid: iccid,
            label: label,
            phone: phone,
            tags: tags,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func testUpsertRoundTripPerICCID() {
        store.upsert(record())
        XCTAssertEqual(store.metadata(eid: "89000000000000000000000000000001", iccid: "8900000000000000001")?.label, "工作号")

        // Same ICCID replaces; another ICCID coexists.
        store.upsert(record(label: "旅行号", tags: ["travel", " travel ", ""]))
        XCTAssertEqual(store.records(eid: "89000000000000000000000000000001").count, 1)
        XCTAssertEqual(store.metadata(eid: "89000000000000000000000000000001", iccid: "8900000000000000001")?.label, "旅行号")
        // Tags are normalized on save: trimmed, empties and dupes dropped.
        XCTAssertEqual(
            store.metadata(eid: "89000000000000000000000000000001", iccid: "8900000000000000001")?.tags,
            ["travel"]
        )

        store.upsert(record(iccid: "8900000000000000002"))
        XCTAssertEqual(store.records(eid: "89000000000000000000000000000001").count, 2)
    }

    func testEIDIsolation() {
        store.upsert(record(eid: "89000000000000000000000000000001", iccid: "8900000000000000001"))
        store.upsert(record(eid: "89000000000000000000000000000002", iccid: "8900000000000000001"))

        XCTAssertEqual(store.records(eid: "89000000000000000000000000000001").count, 1)
        XCTAssertEqual(store.records(eid: "89000000000000000000000000000002").count, 1)
        XCTAssertEqual(
            store.url(forEID: "89000000000000000000000000000001"),
            store.url(forEID: "89000000000000000000000000000002").deletingLastPathComponent()
                .appendingPathComponent("89000000000000000000000000000001.json")
        )
        XCTAssertNotEqual(
            store.url(forEID: "89000000000000000000000000000001"),
            store.url(forEID: "89000000000000000000000000000002")
        )
    }

    func testEmptiedRecordUpsertRemoves() {
        store.upsert(record())
        store.upsert(record(label: "", phone: "", tags: ["", " "]))
        XCTAssertTrue(store.records(eid: "89000000000000000000000000000001").isEmpty)
        XCTAssertNil(store.metadata(eid: "89000000000000000000000000000001", iccid: "8900000000000000001"))
    }

    func testRemove() {
        store.upsert(record(iccid: "8900000000000000001"))
        store.upsert(record(iccid: "8900000000000000002"))
        store.remove(eid: "89000000000000000000000000000001", iccid: "8900000000000000001")
        XCTAssertEqual(
            store.records(eid: "89000000000000000000000000000001").map(\.iccid),
            ["8900000000000000002"]
        )
    }

    func testPruneDropsVanishedICCIDs() {
        store.upsert(record(iccid: "8900000000000000001"))
        store.upsert(record(iccid: "8900000000000000002"))
        store.upsert(record(iccid: "8900000000000000003"))

        let kept = store.prune(
            eid: "89000000000000000000000000000001",
            keepingICCIDs: ["8900000000000000002", "8900000000000000003", "8900000000000000004"]
        )
        XCTAssertEqual(kept.map(\.iccid).sorted(), ["8900000000000000002", "8900000000000000003"])
        XCTAssertEqual(
            store.records(eid: "89000000000000000000000000000001").map(\.iccid).sorted(),
            ["8900000000000000002", "8900000000000000003"]
        )
    }

    func testCorruptionRecoversToEmpty() throws {
        store.upsert(record())
        try Data("not json".utf8).write(to: store.url(forEID: "89000000000000000000000000000001"))
        XCTAssertTrue(store.records(eid: "89000000000000000000000000000001").isEmpty)
        store.upsert(record(iccid: "8900000000000000009"))
        XCTAssertEqual(store.records(eid: "89000000000000000000000000000001").count, 1)
    }

    func testCodableRoundTripKeepsDates() throws {
        let original = record()
        store.upsert(original)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProfileMetadata.self, from: encoder.encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(
            decoded,
            store.records(eid: "89000000000000000000000000000001").first
        )
    }

    func testIsEmptyAndNormalizedTags() {
        XCTAssertTrue(ProfileMetadata(eid: "e", iccid: "i", label: " ", phone: "", tags: [" "], updatedAt: Date()).isEmpty)
        XCTAssertFalse(record().isEmpty)
        XCTAssertEqual(
            ProfileMetadata(eid: "e", iccid: "i", label: "l", phone: "p", tags: ["a", " a", "b", ""], updatedAt: Date()).normalizedTags,
            ["a", "b"]
        )
    }
}
