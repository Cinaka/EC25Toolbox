import CryptoKit
import Foundation

/// Stable identity of one physical EC25-compatible/DJI USB modem.
///
/// IMEI becomes the long-lived module identity after the AT session connects.
/// USB serial/location is retained as the provisional transport locator needed
/// to open that first session. Public identifiers are digests so neither IMEI
/// nor serial is exposed in notification identifiers or UserDefaults keys.
struct USBModemDescriptor: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var vendorID: Int
    var productID: Int
    var serialNumber: String?
    var locationID: UInt32?
    var productName: String?
    /// Hardware identity read from `AT+CGSN` after the provisional USB
    /// session connects. USB serial/location remains the transport locator;
    /// IMEI becomes the long-lived module index used by UI and persistence.
    var imei: String?

    init(
        vendorID: Int,
        productID: Int,
        serialNumber: String?,
        locationID: UInt32?,
        productName: String? = nil,
        imei: String? = nil
    ) {
        let serial = Self.normalized(serialNumber)
        let product = Self.normalized(productName)
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serial
        self.locationID = locationID
        self.productName = product
        self.imei = Self.normalizedIMEI(imei)

        let physicalIdentity: String
        if let serial {
            physicalIdentity = String(format: "%04x:%04x|serial|%@", vendorID, productID, serial)
        } else if let locationID {
            physicalIdentity = String(format: "%04x:%04x|location|%08x", vendorID, productID, locationID)
        } else {
            physicalIdentity = String(format: "%04x:%04x|unknown", vendorID, productID)
        }
        id = Self.digest(physicalIdentity)
    }

    var usbIdentity: String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    /// Stable module identity. Before the first successful AT read it falls
    /// back to the USB transport identity, then deterministically migrates to
    /// the IMEI-derived key without exposing the IMEI in UserDefaults keys or
    /// notification identifiers.
    var moduleID: String {
        guard let imei else { return id }
        return Self.digest("imei|\(imei)")
    }

    /// Serial shown to users. Location fallback stays explicit rather than
    /// pretending that a USB port anchor is a manufacturer serial number.
    var displaySerial: String {
        if let serialNumber { return serialNumber }
        if let locationID { return String(format: "port-%08x", locationID) }
        return String(id.prefix(12))
    }

    var audioParentKey: USBAudioParentKey? {
        guard let locationID else { return nil }
        return USBAudioParentKey(
            vid: UInt32(vendorID),
            pid: UInt32(productID),
            location: locationID
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    static func normalizedIMEI(_ value: String?) -> String? {
        guard let clean = normalized(value),
              (14...16).contains(clean.count),
              clean.allSatisfy(\.isNumber)
        else { return nil }
        return clean
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
