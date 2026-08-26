import XCTest
@testable import EC25Toolbox

final class GNSSParsingTests: XCTestCase {
    // MARK: - +QGPSLOC

    func testQGPSLOCHemisphereForm() {
        let lines = ["+QGPSLOC: 061951.000,3150.7223N,11711.9293E,1.1,90.0,3,12.50,0.34,0.6,230513,09", "OK"]
        let fix = GNSSParsing.parseQGPSLOC(lines)
        XCTAssertNotNil(fix)
        XCTAssertEqual(fix?.utc, "061951.000")
        XCTAssertEqual(fix?.latitude ?? 0, 31.845371, accuracy: 0.000001)
        XCTAssertEqual(fix?.longitude ?? 0, 117.198821, accuracy: 0.000001)
        XCTAssertEqual(fix?.latitudeRaw, "3150.7223N")
        XCTAssertEqual(fix?.longitudeRaw, "11711.9293E")
        XCTAssertEqual(fix?.hdop, 1.1)
        XCTAssertEqual(fix?.altitudeMeters, 90.0)
        XCTAssertEqual(fix?.fixType, 3)
        XCTAssertEqual(fix?.courseDegrees, 12.50)
        XCTAssertEqual(fix?.speedKmh, 0.34)
        XCTAssertEqual(fix?.speedKnots, 0.6)
        XCTAssertEqual(fix?.date, "230513")
        XCTAssertEqual(fix?.satelliteCount, 9)
    }

    func testQGPSLOCDecimalForm() {
        let lines = ["+QGPSLOC: 075717.000,31.81975,-117.19706,0.7,55.3,2,0.00,0.0,0.0,100323,10"]
        let fix = GNSSParsing.parseQGPSLOC(lines)
        XCTAssertEqual(fix?.latitude, 31.81975)
        XCTAssertEqual(fix?.longitude, -117.19706)
        XCTAssertEqual(fix?.satelliteCount, 10)
    }

    func testQGPSLOCNegativeHemispheres() {
        let lines = ["+QGPSLOC: 120000.000,3352.1111S,15112.3456W,2.0,10.0,2,0.00,0.0,0.0,010124,05"]
        let fix = GNSSParsing.parseQGPSLOC(lines)
        XCTAssertEqual(fix?.latitude ?? 0, -(33 + 52.1111 / 60), accuracy: 0.000001)
        XCTAssertEqual(fix?.longitude ?? 0, -(151 + 12.3456 / 60), accuracy: 0.000001)
    }

    func testQGPSLOCMissingFieldsStayNil() {
        let lines = ["+QGPSLOC: 120000.000,,,,,,,,,,"]
        let fix = GNSSParsing.parseQGPSLOC(lines)
        XCTAssertNotNil(fix)
        XCTAssertNil(fix?.latitude)
        XCTAssertNil(fix?.hdop)
        XCTAssertNil(fix?.satelliteCount)
        XCTAssertEqual(fix?.utc, "120000.000")
    }

    func testQGPSLOCAbsentOrMalformedReturnsNil() {
        XCTAssertNil(GNSSParsing.parseQGPSLOC(["OK"]))
        XCTAssertNil(GNSSParsing.parseQGPSLOC(["+QGPSLOC: 1,2"]))
    }

    // MARK: - Coordinates

    func testCoordinateEdgeCases() {
        XCTAssertNil(GNSSParsing.parseCoordinate(""))
        XCTAssertNil(GNSSParsing.parseCoordinate(nil))
        XCTAssertNil(GNSSParsing.parseCoordinate("1.5N")) // too short for ddmm form
        XCTAssertNil(GNSSParsing.parseCoordinate("abcN"))
        XCTAssertEqual(GNSSParsing.parseCoordinate("0.0")?.value, 0)
        XCTAssertEqual(GNSSParsing.parseCoordinate("9000.0000N")?.value, 90)
    }

    // MARK: - NMEA

    func testChecksumValidation() {
        XCTAssertTrue(GNSSParsing.checksumValid("$GNRMC,061951.000,A,3150.7223,N,11711.9293,E,0.0,0.0,230513,,,A*79"))
        XCTAssertFalse(GNSSParsing.checksumValid("$GNRMC,061951.000,A,3150.7223,N,11711.9293,E,0.0,0.0,230513,,,A*67"))
        XCTAssertFalse(GNSSParsing.checksumValid("not-nmea"))
    }

    func testRMCValidAndVoid() {
        let valid = GNSSParsing.parseRMC("$GNRMC,061951.000,A,3150.7223,N,11711.9293,E,0.6,12.50,230513,,,A*79")
        XCTAssertEqual(valid?.valid, true)
        XCTAssertEqual(valid?.latitude?.value ?? 0, 31.845371, accuracy: 0.000001)
        XCTAssertEqual(valid?.longitude?.value ?? 0, 117.198821, accuracy: 0.000001)
        XCTAssertEqual(valid?.speedKnots, 0.6)
        XCTAssertEqual(valid?.courseDegrees, 12.50)
        XCTAssertEqual(valid?.date, "230513")

        let void = GNSSParsing.parseRMC("$GNRMC,120000.000,V,,,,,,,010124,,,N*56")
        XCTAssertEqual(void?.valid, false)
        XCTAssertNil(void?.latitude)
    }

    func testGGAFields() {
        let fix = GNSSParsing.parseGGA("$GNGGA,061951.000,3150.7223,N,11711.9293,E,1,09,1.1,90.0,M,0.0,M,,*4D")
        XCTAssertEqual(fix?.quality, 1)
        XCTAssertEqual(fix?.satelliteCount, 9)
        XCTAssertEqual(fix?.hdop, 1.1)
        XCTAssertEqual(fix?.altitudeMeters, 90.0)
        XCTAssertEqual(fix?.latitude?.raw, "3150.7223N")
    }

    func testGSVSummaryAveragesSNR() {
        let summary = GNSSParsing.parseGSV([
            "$GPGSV,2,1,07,01,40,083,42,02,17,308,38,03,25,156,39,04,10,220,35*7E",
            "$GPGSV,2,2,07,05,30,050,44,06,15,180,30,07,05,300,28*4E",
        ])
        XCTAssertEqual(summary?.satellitesInView, 7)
        XCTAssertEqual(summary?.averageSNR ?? 0, (42.0 + 38 + 39 + 35 + 44 + 30 + 28) / 7, accuracy: 0.001)
    }

    func testNMEAWrongTypeOrBadChecksumReturnsNil() {
        XCTAssertNil(GNSSParsing.parseRMC("$GNGGA,061951.000,3150.7223,N,11711.9293,E,1,09,1.1,90.0,M,0.0,M,,*4D"))
        XCTAssertNil(GNSSParsing.parseGGA("$GNGGA,061951.000,3150.7223,N,11711.9293,E,1,09,1.1,90.0,M,0.0,M,,*FF"))
    }
}
