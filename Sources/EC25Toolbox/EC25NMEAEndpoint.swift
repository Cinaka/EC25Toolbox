import Foundation
import IOKit
import IOUSBHost

/// Passive reader for the modem's independent USB NMEA interface — the last
/// fallback of the R4 position-source chain.
///
/// The endpoint enumerates the same USB device, skips the interface the AT
/// transport already claims, and probe-reads each remaining bulk interface
/// for `$`-prefixed NMEA sentences. The first interface that delivers one is
/// kept and its sentences are forwarded to subscribers; every other
/// candidate is released. Nothing is ever written to the device.
actor EC25NMEAEndpoint {
    /// Enumerated but not used as the NMEA port.
    private struct Candidate {
        let service: io_service_t
        let interfaceNumber: Int
    }

    private var hostInterface: IOUSBHostInterface?
    private var reader: EC25InputReader?
    private var pumpTask: Task<Void, Never>?
    private var description = ""
    private var busSubscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    /// Human-readable description of the active NMEA interface, or empty.
    func sessionDescription() -> String { description }

    /// Opens the endpoint on the active/supported identity. Throws when no
    /// candidate delivers NMEA within the probe budget; the GNSS engine must
    /// be running for the port to emit data, so callers start it first.
    func open(
        identities: [ModuleUSBIdentity] = ModuleUSBIdentity.connectionOrder,
        excludingInterface: Int?,
        targetDeviceID: String? = nil
    ) throws -> String {
        var failures: [String] = []
        for identity in identities {
            do {
                return try open(
                    vid: UInt16(identity.vendorID),
                    pid: UInt16(identity.productID),
                    excludingInterface: excludingInterface,
                    targetDeviceID: targetDeviceID
                )
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        throw EC25TransportError.openFailed(localizedFormat(
            "gnss.nmea.endpoint_not_found",
            failures.joined(separator: " · ")
        ))
    }

    private func open(
        vid: UInt16,
        pid: UInt16,
        excludingInterface: Int?,
        targetDeviceID: String?
    ) throws -> String {
        close()

        var iterator: io_iterator_t = 0
        let matching = EC25Transport.matchingDictionary(vid: vid, pid: pid)
        let consumed = Unmanaged.passRetained(matching)
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, consumed.takeUnretainedValue(), &iterator)
        guard result == KERN_SUCCESS else {
            throw EC25TransportError.openFailed(localizedFormat(
                "transport.enumeration_failed",
                EC25Transport.ioMessage(result)
            ))
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [Candidate] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            let number = EC25Transport.interfaceNumber(for: service)
            let descriptor = EC25Transport.deviceDescriptor(
                for: service,
                vendorID: Int(vid),
                productID: Int(pid)
            )
            if number != Int.max,
               number != excludingInterface,
               targetDeviceID == nil || descriptor?.id == targetDeviceID {
                candidates.append(Candidate(service: service, interfaceNumber: number))
            } else {
                IOObjectRelease(service)
            }
        }
        // NMEA sits on a low interface number in the standard EC25 layout;
        // probe from the lowest so the diagnostic port is tried last.
        candidates.sort { $0.interfaceNumber < $1.interfaceNumber }
        defer { candidates.forEach { IOObjectRelease($0.service) } }

        var lastFailure = ""
        for candidate in candidates {
            let interface: IOUSBHostInterface
            do {
                interface = try IOUSBHostInterface(
                    __ioService: candidate.service,
                    options: [],
                    queue: DispatchQueue(label: "ing.fuyaoskyrocket.ec25toolbox.nmea"),
                    interestHandler: nil
                )
            } catch {
                lastFailure = error.localizedDescription
                continue
            }

            guard let addresses = EC25Transport.bulkEndpointAddresses(for: interface) else {
                interface.destroy()
                continue
            }
            let input: IOUSBHostPipe
            do {
                input = try interface.copyPipe(withAddress: Int(addresses.input))
            } catch {
                lastFailure = error.localizedDescription
                interface.destroy()
                continue
            }
            let endpointReader = EC25InputReader(pipe: input)
            endpointReader.start()

            // Probe: NMEA flows once per second at most, so a short window
            // with at least one `$` sentence identifies the port.
            let probeDeadline = Date().addingTimeInterval(2.5)
            var matched = false
            while !matched, probeDeadline.timeIntervalSinceNow > 0 {
                if case let .event(.line(line)) = endpointReader.wait(until: min(probeDeadline, Date().addingTimeInterval(0.5))),
                   line.hasPrefix("$") {
                    matched = true
                }
            }

            guard matched else {
                endpointReader.stop()
                interface.destroy()
                continue
            }

            hostInterface = interface
            reader = endpointReader
            description = "USB \(String(format: "%04x:%04x", Int(vid), Int(pid))) if\(candidate.interfaceNumber) nmea"
            startPump(for: endpointReader)
            return description
        }

        throw EC25TransportError.openFailed(localizedFormat(
            "gnss.nmea.endpoint_not_found",
            lastFailure
        ))
    }

    /// Subscribes to NMEA sentences from the active interface. The stream
    /// finishes when the endpoint closes.
    func sentences() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            busSubscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        busSubscribers.removeValue(forKey: id)?.finish()
    }

    /// Releases the interface, stops the reader, and finishes every stream.
    func close() {
        pumpTask?.cancel()
        pumpTask = nil
        reader?.stop()
        reader = nil
        hostInterface?.destroy()
        hostInterface = nil
        description = ""
        busSubscribers.values.forEach { $0.finish() }
        busSubscribers.removeAll()
    }

    /// Forwards framed `$` lines to every subscriber until the reader stops.
    private func startPump(for endpointReader: EC25InputReader) {
        pumpTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let deadline = Date().addingTimeInterval(2)
                switch endpointReader.wait(until: deadline) {
                case let .event(.line(line)) where line.hasPrefix("$"):
                    await self?.deliver(line)
                case .event:
                    continue
                case .closed:
                    await self?.finishAll()
                    return
                case .timedOut:
                    continue
                }
            }
        }
    }

    private func deliver(_ sentence: String) {
        for continuation in busSubscribers.values {
            continuation.yield(sentence)
        }
    }

    private func finishAll() {
        busSubscribers.values.forEach { $0.finish() }
        busSubscribers.removeAll()
    }
}
