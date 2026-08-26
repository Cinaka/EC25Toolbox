import Foundation

/// Read-only classification for binary SMS payloads. The app never acts on
/// these payloads; the label only explains why the body is not shown.
enum BinarySMSKind: String, Codable, Equatable, Sendable {
    case omaCP = "oma_cp"
    case wapSI = "wap_si"
    case wapSL = "wap_sl"
    case mmsNotification = "mms_notification"
    case simOTA = "sim_ota"
    case unknownBinary = "unknown_binary"

    var localizationKey: String {
        "sms.binary.\(rawValue)"
    }
}

/// Classifies 8-bit SMS user data without executing or persisting any of it.
enum BinarySMSClassifier {
    /// WAP Push destination port (WSP over SMS).
    private static let wapPushPort: UInt16 = 2948

    // WSP well-known content-type tokens (single octet, high bit set).
    private static let contentTypeSI: UInt8 = 0x2E // application/vnd.wap.sic
    private static let contentTypeSL: UInt8 = 0x30 // application/vnd.wap.slc
    private static let contentTypeConnectivity: UInt8 = 0x36 // application/vnd.wap.connectivity-wbxml
    private static let contentTypeMMS: UInt8 = 0x3E // application/vnd.wap.mms-message

    /// Returns nil for textual messages; binary payloads always get a kind.
    static func classify(decoded: DecodedSMS) -> BinarySMSKind? {
        guard let payload = decoded.binary else { return nil }

        // SIM data download / SIM toolkit push (TS 23.048 style envelopes).
        if decoded.pid == 0x7F || decoded.dcs == 0xF6 {
            return .simOTA
        }

        if decoded.header?.destinationPort == wapPushPort {
            guard let contentType = payload.first else { return .unknownBinary }
            switch contentType & 0x7F {
            case contentTypeSI:
                return .wapSI
            case contentTypeSL:
                return .wapSL
            case contentTypeConnectivity:
                return .omaCP
            case contentTypeMMS:
                // X-Mms-Message-Type (0x8C) = m-notification-ind (0x82).
                if payload.count > 2, payload[1] == 0x8C, payload[2] == 0x82 {
                    return .mmsNotification
                }
                return .unknownBinary
            default:
                return .unknownBinary
            }
        }

        return .unknownBinary
    }
}
