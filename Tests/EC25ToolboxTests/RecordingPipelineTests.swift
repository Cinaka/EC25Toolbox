import XCTest
import AVFAudio
@testable import EC25Toolbox

final class RecordingPipelineTests: XCTestCase {
    // MARK: - Pure mixing math

    func testMixSumsEqualLengthArrays() {
        let mixed = RecordingMixer.mix([0.25, -0.5, 0.1], [0.25, 0.5, 0.1])
        XCTAssertEqual(mixed, [0.5, 0.0, 0.2])
    }

    func testMixUsesShorterLength() {
        let mixed = RecordingMixer.mix([0.1, 0.2, 0.3, 0.4], [0.5, 0.25])
        XCTAssertEqual(mixed, [0.6, 0.45])
        XCTAssertTrue(RecordingMixer.mix([], [0.1, 0.2]).isEmpty)
        XCTAssertTrue(RecordingMixer.mix([0.1, 0.2], []).isEmpty)
    }

    func testMixClampsToUnitRange() {
        XCTAssertEqual(RecordingMixer.mix([0.9, -0.9], [0.9, -0.9]), [1, -1])
        XCTAssertEqual(RecordingMixer.clamp(1.7), 1)
        XCTAssertEqual(RecordingMixer.clamp(-2.5), -1)
    }

    // MARK: - Sample ring

    func testRingDrainsFIFO() {
        let ring = AudioSampleRing(capacity: 8)
        var values: [Float] = [1, 2, 3, 4, 5]
        ring.append(&values, count: values.count)
        XCTAssertEqual(ring.available, 5)
        XCTAssertEqual(ring.drain(upTo: 2), [1, 2])
        XCTAssertEqual(ring.available, 3)

        var more: [Float] = [6, 7]
        ring.append(&more, count: more.count)
        XCTAssertEqual(ring.drain(upTo: 10), [3, 4, 5, 6, 7])
        XCTAssertEqual(ring.available, 0)
    }

    func testRingWrapsAroundCapacity() {
        let ring = AudioSampleRing(capacity: 8)
        var first: [Float] = [1, 2, 3, 4, 5, 6]
        ring.append(&first, count: first.count)
        _ = ring.drain(upTo: 6)
        var second: [Float] = [7, 8, 9, 10, 11]
        ring.append(&second, count: second.count)
        XCTAssertEqual(ring.available, 5)
        XCTAssertEqual(ring.drain(upTo: 10), [7, 8, 9, 10, 11])
    }

    func testRingOverflowKeepsNewestSamples() {
        let ring = AudioSampleRing(capacity: 3)
        var values: [Float] = [1, 2, 3, 4, 5]
        ring.append(&values, count: values.count)
        XCTAssertEqual(ring.available, 3)
        XCTAssertEqual(ring.drain(upTo: 10), [3, 4, 5])
    }

    // MARK: - Recorder round-trip (file I/O without hardware)

    private func makeMonoBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    func testRecorderWritesMixedPairsAndClosesFile() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recorder-roundtrip-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let recorder = CallRecorder(format: format)
        try recorder.start(fileURL: fileURL)
        XCTAssertTrue(recorder.isRunning)

        let uplink = makeMonoBuffer(Array(repeating: 0.25, count: 160), format: format)
        let downlink = makeMonoBuffer(Array(repeating: 0.5, count: 160), format: format)
        recorder.append(.uplink, buffer: uplink)
        recorder.append(.downlink, buffer: downlink)
        recorder.drainOnce()

        let finished = recorder.stop()
        XCTAssertNotNil(finished)
        XCTAssertEqual(finished?.frames, 160)
        XCTAssertEqual(finished?.duration ?? 0, 0.02, accuracy: 0.001)
        XCTAssertFalse(recorder.isRunning)

        let readBack = try AVAudioFile(forReading: fileURL)
        let readFormat = readBack.processingFormat
        let target = AVAudioPCMBuffer(
            pcmFormat: readFormat,
            frameCapacity: AVAudioFrameCount(readBack.length)
        )!
        try readBack.read(into: target)
        XCTAssertEqual(target.frameLength, 160)
        // 0.25 + 0.5 = 0.75 on every mixed frame.
        let samples = Array(UnsafeBufferPointer(
            start: target.floatChannelData![0],
            count: Int(target.frameLength)
        ))
        XCTAssertTrue(samples.allSatisfy { abs($0 - 0.75) < 0.001 })
    }

    func testRecorderDoesNotConsumeUnpairedSamples() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recorder-unpaired-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let recorder = CallRecorder(format: format)
        try recorder.start(fileURL: fileURL)
        let uplink = makeMonoBuffer(Array(repeating: 0.3, count: 100), format: format)
        recorder.append(.uplink, buffer: uplink)
        // No downlink yet: nothing may be consumed or written.
        recorder.drainOnce()
        let finished = recorder.stop()
        XCTAssertEqual(finished?.frames, 0, "unpaired samples must never be written")
    }

    // MARK: - Recording store

    private func makeTempStore(limit: Int = 100) -> (store: RecordingStore, scope: SIMMessageScope) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recstore-\(UUID().uuidString)", isDirectory: true)
        let store = RecordingStore(
            applicationSupportDirectory: directory,
            limit: limit
        )
        return (store, SIMMessageScope(eid: "EID-1", iccid: "ICCID-1"))
    }

    func testStoreRegisterLoadRoundTrip() {
        let (store, scope) = makeTempStore()
        let entry = RecordingEntry(
            fileName: "call-a.caf",
            createdAt: Date(timeIntervalSince1970: 1_000),
            duration: 12,
            byteSize: 100,
            number: "13800138000"
        )
        let entries = store.register(entry, scope: scope)
        XCTAssertEqual(entries.first?.fileName, "call-a.caf")
        XCTAssertEqual(store.load(scope: scope).first?.number, "13800138000")
        XCTAssertEqual(store.load(scope: scope).first?.duration, 12)
        XCTAssertTrue(store.totalBytes(scope: scope) > 0)
    }

    func testStoreRegisterSortsNewestFirstAndKeepsScopeIsolated() {
        let (store, scope) = makeTempStore()
        let otherScope = SIMMessageScope(eid: "EID-2", iccid: "ICCID-2")
        _ = store.register(
            RecordingEntry(fileName: "old.caf", createdAt: Date(timeIntervalSince1970: 1), duration: 1, byteSize: 1, number: nil),
            scope: scope
        )
        _ = store.register(
            RecordingEntry(fileName: "new.caf", createdAt: Date(timeIntervalSince1970: 2), duration: 1, byteSize: 1, number: nil),
            scope: scope
        )
        _ = store.register(
            RecordingEntry(fileName: "foreign.caf", createdAt: Date(timeIntervalSince1970: 3), duration: 1, byteSize: 1, number: nil),
            scope: otherScope
        )
        XCTAssertEqual(store.load(scope: scope).map(\.fileName), ["new.caf", "old.caf"])
        XCTAssertEqual(store.load(scope: otherScope).map(\.fileName), ["foreign.caf"])
    }

    func testStoreDeleteRemovesEntry() {
        let (store, scope) = makeTempStore()
        let entry = RecordingEntry(fileName: "call.caf", createdAt: Date(), duration: 5, byteSize: 50, number: nil)
        _ = store.register(entry, scope: scope)
        let remaining = store.delete(entry, scope: scope)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(store.load(scope: scope).isEmpty)
    }

    func testStoreCorruptIndexReadsEmpty() throws {
        let (store, scope) = makeTempStore()
        try FileManager.default.createDirectory(at: store.directory(for: scope), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.indexURL(for: scope))
        XCTAssertTrue(store.load(scope: scope).isEmpty)
    }

    func testStorePrunesOldestBeyondLimit() {
        let (store, scope) = makeTempStore(limit: 2)
        for index in 0..<3 {
            _ = store.register(
                RecordingEntry(fileName: "call-\(index).caf", createdAt: Date(timeIntervalSince1970: Double(index)), duration: 1, byteSize: 1, number: nil),
                scope: scope
            )
        }
        XCTAssertEqual(store.load(scope: scope).map(\.fileName), ["call-2.caf", "call-1.caf"])
    }

    func testNextFileNameAvoidsCollisions() throws {
        let (store, scope) = makeTempStore()
        try FileManager.default.createDirectory(
            at: store.directory(for: scope),
            withIntermediateDirectories: true
        )
        let date = Date(timeIntervalSince1970: 0)
        let first = store.nextFileName(scope: scope, createdAt: date)
        let path = store.directory(for: scope).appendingPathComponent(first).path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data([0])))
        let second = store.nextFileName(scope: scope, createdAt: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasSuffix(".caf"))
    }

    // MARK: - Ringtone store

    func testRingtoneImportRejectsUnsupportedTypes() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ringtones-\(UUID().uuidString)", isDirectory: true)
        let store = RingtoneStore(applicationSupportDirectory: directory)

        let source = directory.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source)

        XCTAssertThrowsError(try store.importFile(at: source, securityScoped: false)) { error in
            XCTAssertEqual(error as? RingtoneError, RingtoneError.unsupportedType)
        }
    }

    func testRingtoneImportCopiesAndLists() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ringtones-\(UUID().uuidString)", isDirectory: true)
        let store = RingtoneStore(applicationSupportDirectory: directory)

        let source = directory.appendingPathComponent("chime.mp3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: source)

        let stored = try store.importFile(at: source, securityScoped: false)
        XCTAssertEqual(stored, "chime.mp3")
        XCTAssertEqual(store.list(), ["chime.mp3"])
        XCTAssertNotNil(store.url(for: stored))
        XCTAssertNil(store.url(for: "missing.mp3"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: stored)!.path))

        let remaining = store.delete(stored)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(store.url(for: stored))
    }

    func testRingtoneImportSanitizesNamesAndDeduplicates() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ringtones-\(UUID().uuidString)", isDirectory: true)
        let store = RingtoneStore(applicationSupportDirectory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let first = directory.appendingPathComponent("tone .wav")
        try Data("a".utf8).write(to: first)
        let storedFirst = try store.importFile(at: first, securityScoped: false)
        XCTAssertEqual(storedFirst, "tone.wav")

        let second = directory.appendingPathComponent("tone .wav")
        let storedSecond = try store.importFile(at: second, securityScoped: false)
        XCTAssertEqual(storedSecond, "tone-2.wav")
        XCTAssertEqual(store.list().count, 2)
    }
}
