import Foundation
import IOKit
import IOUSBHost

/// Minimal ADB wire client for the QDC507 module's ff/42/01 USB interface.
///
/// It intentionally implements only CNXN, shell, and sync push. The client is
/// opened for one `USBModemDescriptor`, so multiple attached modems cannot be
/// crossed by a first-device-wins lookup.
final class NativeUSBADBClient {
    private enum Command {
        static let sync = fourCC("SYNC")
        static let cnxn = fourCC("CNXN")
        static let open = fourCC("OPEN")
        static let okay = fourCC("OKAY")
        static let close = fourCC("CLSE")
        static let write = fourCC("WRTE")
        static let auth = fourCC("AUTH")
    }

    private struct Message {
        var command: UInt32
        var argument0: UInt32
        var argument1: UInt32
        var payload: Data
    }

    private struct Stream {
        var localID: UInt32
        var remoteID: UInt32
    }

    private static let protocolVersion: UInt32 = 0x01000001
    private static let localMaximumPayload = 4_096

    private var hostInterface: IOUSBHostInterface?
    private var inputPipe: IOUSBHostPipe?
    private var outputPipe: IOUSBHostPipe?
    private var remoteMaximumPayload = localMaximumPayload
    private var nextLocalID: UInt32 = 1
    private var connected = false

    deinit {
        close()
    }

    static func open(target: USBModemDescriptor) throws -> NativeUSBADBClient {
        var iterator: io_iterator_t = 0
        let matching = EC25Transport.matchingDictionary(
            vid: UInt16(target.vendorID),
            pid: UInt16(target.productID)
        )
        let consumed = Unmanaged.passRetained(matching)
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            consumed.takeUnretainedValue(),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            throw ModuleVoiceRuntimeError.adbUnavailable(EC25Transport.ioMessage(result))
        }
        defer { IOObjectRelease(iterator) }

        var lastError = localized("modulevoice.error.adb_interface_missing")
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let discovered = EC25Transport.deviceDescriptor(
                for: service,
                vendorID: target.vendorID,
                productID: target.productID
            ), Self.matchesPhysicalDevice(discovered, target) else { continue }

            let interface: IOUSBHostInterface
            do {
                interface = try IOUSBHostInterface(
                    __ioService: service,
                    options: [],
                    queue: DispatchQueue(label: "ing.fuyaoskyrocket.ec25toolbox.qdc507-adb"),
                    interestHandler: nil
                )
            } catch {
                lastError = error.localizedDescription
                continue
            }

            let descriptor = interface.interfaceDescriptor.pointee
            guard descriptor.bInterfaceClass == 0xff,
                  descriptor.bInterfaceSubClass == 0x42,
                  descriptor.bInterfaceProtocol == 0x01,
                  let addresses = EC25Transport.bulkEndpointAddresses(for: interface) else {
                interface.destroy()
                continue
            }

            do {
                let client = NativeUSBADBClient()
                client.hostInterface = interface
                client.inputPipe = try interface.copyPipe(withAddress: Int(addresses.input))
                client.outputPipe = try interface.copyPipe(withAddress: Int(addresses.output))
                return client
            } catch {
                lastError = error.localizedDescription
                interface.destroy()
            }
        }
        throw ModuleVoiceRuntimeError.adbUnavailable(lastError)
    }

    func close() {
        inputPipe = nil
        outputPipe = nil
        hostInterface?.destroy()
        hostInterface = nil
        connected = false
    }

    func probeRoot(timeout: TimeInterval = 8) throws {
        let result = try shell("id -u", timeout: timeout)
        guard result.status == 0,
              result.output.split(whereSeparator: \Character.isWhitespace).contains("0") else {
            throw ModuleVoiceRuntimeError.rootRequired
        }
    }

    func shell(_ command: String, timeout: TimeInterval = 15) throws -> (output: String, status: Int) {
        try connect()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let marker = "__EC25_STATUS_\(token)_"
        let wrapper = "{ \(command); }; rc=$?; printf '\\n\(marker)%u__\\n' \"$rc\""
        let stream = try openService("shell:\(wrapper)")
        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()

        while deadline.timeIntervalSinceNow > 0 {
            let message = try receive(until: deadline)
            switch message.command {
            case Command.write where message.argument0 == stream.remoteID && message.argument1 == stream.localID:
                output.append(message.payload)
                try send(
                    command: Command.okay,
                    argument0: stream.localID,
                    argument1: stream.remoteID,
                    payload: Data(),
                    timeout: 2
                )
            case Command.close where message.argument1 == stream.localID:
                if message.argument0 != 0 {
                    try? send(
                        command: Command.close,
                        argument0: stream.localID,
                        argument1: stream.remoteID,
                        payload: Data(),
                        timeout: 2
                    )
                }
                let raw = String(decoding: output, as: UTF8.self)
                guard let parsed = Self.parseShellResult(raw, marker: marker) else {
                    connected = false
                    throw ModuleVoiceRuntimeError.commandFailed(
                        localized("modulevoice.error.shell_status_missing")
                    )
                }
                return parsed
            default:
                continue
            }
        }
        connected = false
        throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.shell_timeout"))
    }

    func push(_ data: Data, to remotePath: String, permissions: Int, timeout: TimeInterval = 35) throws {
        guard !remotePath.contains(","), !remotePath.contains("\0") else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.push_path"))
        }
        try connect()
        let stream = try openService("sync:")
        do {
            let mode = 0o100000 | permissions
            try writeSync(
                stream: stream,
                identifier: "SEND",
                payload: Data("\(remotePath),\(mode)".utf8),
                timeout: timeout
            )
            let chunkSize = max(1, remoteMaximumPayload - 8)
            var offset = 0
            while offset < data.count {
                let end = min(data.count, offset + chunkSize)
                try writeSync(
                    stream: stream,
                    identifier: "DATA",
                    payload: data.subdata(in: offset..<end),
                    timeout: timeout
                )
                offset = end
            }

            var done = Data("DONE".utf8)
            done.appendLittleEndian(UInt32(Date().timeIntervalSince1970))
            try write(stream: stream, data: done, timeout: timeout)
            try readSyncCompletion(stream: stream)
            try close(stream: stream)
        } catch {
            try? close(stream: stream)
            throw error
        }
    }

    private func connect() throws {
        guard !connected else { return }
        var banner = Data("host::EC25Toolbox".utf8)
        banner.append(0)
        try send(
            command: Command.cnxn,
            argument0: Self.protocolVersion,
            argument1: UInt32(Self.localMaximumPayload),
            payload: banner,
            timeout: 2
        )
        let deadline = Date().addingTimeInterval(8)
        while deadline.timeIntervalSinceNow > 0 {
            let message = try receive(until: deadline)
            switch message.command {
            case Command.auth:
                throw ModuleVoiceRuntimeError.adbAuthorizationRequired
            case Command.cnxn:
                if message.argument1 > 0 {
                    remoteMaximumPayload = min(Self.localMaximumPayload, Int(message.argument1))
                }
                connected = true
                return
            case Command.write, Command.okay, Command.close:
                if message.argument0 != 0, message.argument1 != 0 {
                    try? send(
                        command: Command.close,
                        argument0: message.argument1,
                        argument1: message.argument0,
                        payload: Data(),
                        timeout: 2
                    )
                }
            default:
                throw ModuleVoiceRuntimeError.adbUnavailable(
                    String(format: "unexpected command 0x%08X", message.command)
                )
            }
        }
        throw ModuleVoiceRuntimeError.adbUnavailable(localized("modulevoice.error.adb_connect_timeout"))
    }

    private func openService(_ name: String) throws -> Stream {
        var payload = Data(name.utf8)
        payload.append(0)
        guard payload.count <= remoteMaximumPayload else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.service_too_long"))
        }
        let localID = nextLocalID
        nextLocalID &+= 1
        if nextLocalID == 0 { nextLocalID = 1 }
        try send(
            command: Command.open,
            argument0: localID,
            argument1: 0,
            payload: payload,
            timeout: 2
        )

        let deadline = Date().addingTimeInterval(8)
        while deadline.timeIntervalSinceNow > 0 {
            let message = try receive(until: deadline)
            if message.command == Command.okay,
               message.argument1 == localID,
               message.argument0 != 0 {
                return Stream(localID: localID, remoteID: message.argument0)
            }
            if message.command == Command.close, message.argument1 == localID {
                throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.service_rejected"))
            }
        }
        throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.service_timeout"))
    }

    private func write(stream: Stream, data: Data, timeout: TimeInterval) throws {
        guard data.count <= remoteMaximumPayload else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.adb_payload"))
        }
        try send(
            command: Command.write,
            argument0: stream.localID,
            argument1: stream.remoteID,
            payload: data,
            timeout: timeout
        )
        let response = try receive(until: Date().addingTimeInterval(min(10, max(2, timeout))))
        guard response.command == Command.okay,
              response.argument0 == stream.remoteID,
              response.argument1 == stream.localID else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.adb_write_ack"))
        }
    }

    private func close(stream: Stream) throws {
        try send(
            command: Command.close,
            argument0: stream.localID,
            argument1: stream.remoteID,
            payload: Data(),
            timeout: 2
        )
        let deadline = Date().addingTimeInterval(5)
        while deadline.timeIntervalSinceNow > 0 {
            let message = try receive(until: deadline)
            if message.command == Command.close,
               message.argument0 == stream.remoteID,
               message.argument1 == stream.localID {
                return
            }
            if message.command == Command.write,
               message.argument0 == stream.remoteID,
               message.argument1 == stream.localID {
                try send(
                    command: Command.okay,
                    argument0: stream.localID,
                    argument1: stream.remoteID,
                    payload: Data(),
                    timeout: 2
                )
            }
        }
        throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.stream_close_timeout"))
    }

    private func writeSync(
        stream: Stream,
        identifier: String,
        payload: Data,
        timeout: TimeInterval
    ) throws {
        var packet = Data(identifier.utf8)
        packet.appendLittleEndian(UInt32(payload.count))
        packet.append(payload)
        try write(stream: stream, data: packet, timeout: timeout)
    }

    private func readSyncCompletion(stream: Stream) throws {
        let deadline = Date().addingTimeInterval(20)
        var response = Data()
        while response.count < 8, deadline.timeIntervalSinceNow > 0 {
            let message = try receive(until: deadline)
            if message.command == Command.write,
               message.argument0 == stream.remoteID,
               message.argument1 == stream.localID {
                response.append(message.payload)
                try send(
                    command: Command.okay,
                    argument0: stream.localID,
                    argument1: stream.remoteID,
                    payload: Data(),
                    timeout: 2
                )
            } else if message.command == Command.close {
                throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.sync_closed"))
            }
        }
        guard response.count >= 8 else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.sync_timeout"))
        }
        let identifier = String(decoding: response.prefix(4), as: UTF8.self)
        let value = response.readLittleEndianUInt32(at: 4)
        if identifier == "FAIL" {
            let length = Int(value)
            let detail = response.count >= 8 + length
                ? String(decoding: response[8..<(8 + length)], as: UTF8.self)
                : localized("modulevoice.error.sync_failed")
            throw ModuleVoiceRuntimeError.commandFailed(detail)
        }
        guard identifier == "OKAY", value == 0 else {
            throw ModuleVoiceRuntimeError.commandFailed(localized("modulevoice.error.sync_invalid"))
        }
    }

    private func send(
        command: UInt32,
        argument0: UInt32,
        argument1: UInt32,
        payload: Data,
        timeout: TimeInterval
    ) throws {
        var header = Data()
        header.appendLittleEndian(command)
        header.appendLittleEndian(argument0)
        header.appendLittleEndian(argument1)
        header.appendLittleEndian(UInt32(payload.count))
        header.appendLittleEndian(Self.checksum(payload))
        header.appendLittleEndian(command ^ 0xffff_ffff)
        try writeUSB(header, timeout: timeout)
        if !payload.isEmpty {
            try writeUSB(payload, timeout: timeout)
        }
    }

    private func receive(until deadline: Date) throws -> Message {
        let header = try readExactly(24, until: deadline)
        let command = header.readLittleEndianUInt32(at: 0)
        let argument0 = header.readLittleEndianUInt32(at: 4)
        let argument1 = header.readLittleEndianUInt32(at: 8)
        let length = Int(header.readLittleEndianUInt32(at: 12))
        let expectedChecksum = header.readLittleEndianUInt32(at: 16)
        let magic = header.readLittleEndianUInt32(at: 20)
        guard magic == command ^ 0xffff_ffff else {
            throw ModuleVoiceRuntimeError.adbUnavailable(localized("modulevoice.error.adb_magic"))
        }
        guard length >= 0, length <= min(Self.localMaximumPayload, remoteMaximumPayload) else {
            throw ModuleVoiceRuntimeError.adbUnavailable(localized("modulevoice.error.adb_length"))
        }
        let payload = try readExactly(length, until: deadline)
        guard Self.checksum(payload) == expectedChecksum else {
            throw ModuleVoiceRuntimeError.adbUnavailable(localized("modulevoice.error.adb_checksum"))
        }
        return Message(command: command, argument0: argument0, argument1: argument1, payload: payload)
    }

    private func writeUSB(_ data: Data, timeout: TimeInterval) throws {
        guard let outputPipe else {
            throw ModuleVoiceRuntimeError.adbUnavailable(localized("modulevoice.error.adb_not_open"))
        }
        var offset = 0
        while offset < data.count {
            let buffer = NSMutableData(data: data.subdata(in: offset..<data.count))
            var transferred = 0
            try outputPipe.__sendIORequest(
                with: buffer,
                bytesTransferred: &transferred,
                completionTimeout: timeout
            )
            guard transferred > 0 else {
                throw ModuleVoiceRuntimeError.adbUnavailable(localized("modulevoice.error.adb_write_stalled"))
            }
            offset += transferred
        }
    }

    private func readExactly(_ length: Int, until deadline: Date) throws -> Data {
        guard let inputPipe else {
            throw ModuleVoiceRuntimeError.adbUnavailable(localized("modulevoice.error.adb_not_open"))
        }
        guard length > 0 else { return Data() }
        var output = Data()
        while output.count < length, deadline.timeIntervalSinceNow > 0 {
            let requestLength = min(4_096, length - output.count)
            let buffer = NSMutableData(length: requestLength)!
            var transferred = 0
            do {
                try inputPipe.__sendIORequest(
                    with: buffer,
                    bytesTransferred: &transferred,
                    completionTimeout: min(0.25, max(0.01, deadline.timeIntervalSinceNow))
                )
            } catch let error as NSError where Int32(truncatingIfNeeded: error.code) == kIOReturnTimeout {
                continue
            }
            if transferred > 0 {
                output.append(Data(bytes: buffer.bytes, count: transferred))
            }
        }
        guard output.count == length else {
            throw ModuleVoiceRuntimeError.adbUnavailable(localized("modulevoice.error.adb_read_timeout"))
        }
        return output
    }

    private static func matchesPhysicalDevice(
        _ discovered: USBModemDescriptor,
        _ target: USBModemDescriptor
    ) -> Bool {
        if let targetLocation = target.locationID,
           let discoveredLocation = discovered.locationID {
            return targetLocation == discoveredLocation
        }
        if let targetSerial = target.serialNumber,
           let discoveredSerial = discovered.serialNumber {
            return targetSerial == discoveredSerial
        }
        return discovered.id == target.id
    }

    private static func parseShellResult(
        _ raw: String,
        marker: String
    ) -> (output: String, status: Int)? {
        guard let markerRange = raw.range(of: marker, options: .backwards) else { return nil }
        let statusStart = markerRange.upperBound
        guard let statusEnd = raw[statusStart...].range(of: "__")?.lowerBound,
              let status = Int(raw[statusStart..<statusEnd]),
              (0...255).contains(status) else { return nil }
        let output = raw[..<markerRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (output, status)
    }

    private static func checksum(_ data: Data) -> UInt32 {
        data.reduce(into: UInt32(0)) { $0 &+= UInt32($1) }
    }

    private static func fourCC(_ value: String) -> UInt32 {
        let bytes = Array(value.utf8)
        precondition(bytes.count == 4)
        return UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[index(startIndex, offsetBy: offset)])
            | UInt32(self[index(startIndex, offsetBy: offset + 1)]) << 8
            | UInt32(self[index(startIndex, offsetBy: offset + 2)]) << 16
            | UInt32(self[index(startIndex, offsetBy: offset + 3)]) << 24
    }
}
