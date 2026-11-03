import XCTest
import SwiftData
@testable import IslandFlow

/// D33：旅客出示乘車碼、司機掃描，上車時輸入購票序號。同一支手機，所以旅客與司機共用一個資料庫。
@MainActor
final class DriverCheckinTests: XCTestCase {
    var container: ModelContainer!
    var service: FlowService!
    let user = "t-demo"
    let driver = "d-bus9"
    let serial = FlowService.demoTicketSerial

    override func setUp() async throws {
        container = try AppSchema.makeContainer(inMemory: true)
        SeedData.seed(container.mainContext)
        service = FlowService(context: container.mainContext)
    }

    private func joined() throws -> Participation {
        try service.join(mission: service.mission("M-A")!, user: user).0
    }

    private func pass(_ p: Participation) -> String { service.boardingPassPayload(for: p)! }

    func testFullDriverFlowAwardsOnce() throws {
        let p = try joined()
        let depart = try service.driverCheckIn(raw: pass(p), ticketSerial: serial, driverID: driver, scannedAt: .now)
        XCTAssertEqual(depart.stage, .depart)
        XCTAssertEqual(depart.stopName, service.stopName(1))
        XCTAssertNil(depart.coinsAwarded)
        XCTAssertEqual(p.statusValue, .departed)

        // 下車不必再輸入序號
        let arrive = try service.driverCheckIn(raw: pass(p), ticketSerial: "", driverID: driver, scannedAt: .now)
        XCTAssertEqual(arrive.coinsAwarded, 100)
        XCTAssertEqual(service.balance(for: user), 100)
        XCTAssertEqual(service.ticketSerial(participationID: p.id), serial)

        let methods = try container.mainContext.fetch(FetchDescriptor<Checkin>()).map(\.method)
        XCTAssertEqual(methods, ["driver", "driver"])
    }

    func testSerialRequiredAtBoarding() throws {
        let p = try joined()
        XCTAssertThrowsError(try service.driverCheckIn(raw: pass(p), ticketSerial: "  ", driverID: driver, scannedAt: .now)) {
            XCTAssertEqual(($0 as? FlowError)?.message, "請輸入購票序號")
        }
        XCTAssertEqual(p.statusValue, .joined)
    }

    func testUnknownSerialRejected() throws {
        let p = try joined()
        XCTAssertThrowsError(try service.driverCheckIn(raw: pass(p), ticketSerial: "12345678", driverID: driver, scannedAt: .now)) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("查無購票序號") ?? false)
        }
        XCTAssertEqual(p.statusValue, .joined)
        // 被擋也要留下稽核紀錄，事後查得到誰試過哪個序號
        let rejected = try container.mainContext.fetch(FetchDescriptor<AuditLog>()).filter { $0.action == "checkin_rejected" }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertEqual(rejected.first?.actorID, driver)
    }

    func testSerialWithSurroundingSpacesAccepted() throws {
        let p = try joined()
        XCTAssertNoThrow(try service.driverCheckIn(raw: pass(p), ticketSerial: " \(serial) ", driverID: driver, scannedAt: .now))
    }

    func testBoardingPassCannotBeReusedForAlighting() throws {
        let p = try joined()
        let boardingPass = pass(p)
        try service.driverCheckIn(raw: boardingPass, ticketSerial: serial, driverID: driver, scannedAt: .now)
        XCTAssertThrowsError(try service.driverCheckIn(raw: boardingPass, ticketSerial: "", driverID: driver, scannedAt: .now)) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("上車用的乘車碼") ?? false)
        }
        XCTAssertEqual(p.statusValue, .departed)
    }

    func testCompletedMissionRejectsFurtherScans() throws {
        let p = try joined()
        try service.driverCheckIn(raw: pass(p), ticketSerial: serial, driverID: driver, scannedAt: .now)
        let alighting = pass(p)
        try service.driverCheckIn(raw: alighting, ticketSerial: "", driverID: driver, scannedAt: .now)
        XCTAssertNil(service.boardingPassPayload(for: p), "完成後不再產生乘車碼")
        XCTAssertThrowsError(try service.driverCheckIn(raw: alighting, ticketSerial: "", driverID: driver, scannedAt: .now))
        XCTAssertEqual(service.balance(for: user), 100)
    }

    func testExpiredPassRejected() throws {
        let p = try joined()
        let old = service.boardingPassPayload(for: p, now: .now.addingTimeInterval(-120))!
        XCTAssertThrowsError(try service.driverCheckIn(raw: old, ticketSerial: serial, driverID: driver, scannedAt: .now)) {
            XCTAssertEqual($0 as? TokenError, .expired)
        }
    }

    /// 掃描當下有效就好，司機輸入序號花一點時間不會讓碼過期；但超過確認時限要重掃
    func testConfirmWindowAfterScan() throws {
        let p = try joined()
        let raw = pass(p)
        let scannedAt = Date.now
        service.now = { scannedAt.addingTimeInterval(90) }
        XCTAssertNoThrow(try service.driverCheckIn(raw: raw, ticketSerial: serial, driverID: driver, scannedAt: scannedAt))

        let q = try service.join(mission: service.mission("M-B")!, user: user).0
        service.now = { .now }
        let raw2 = pass(q)
        let scanned2 = Date.now
        service.now = { scanned2.addingTimeInterval(FlowService.boardingConfirmWindow + 1) }
        XCTAssertThrowsError(try service.driverCheckIn(raw: raw2, ticketSerial: serial, driverID: driver, scannedAt: scanned2)) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("重新掃") ?? false)
        }
    }

    func testTamperedPassRejected() throws {
        let p = try joined()
        let parts = pass(p).split(separator: ".")
        var payload = try TokenSigner.verifyBoarding(pass(p))
        payload.stage = CheckinStage.arrive.rawValue
        let forged = "\(parts[0]).\(try JSONEncoder.sorted.encode(payload).base64URL).\(parts[2])"
        XCTAssertThrowsError(try service.driverCheckIn(raw: forged, ticketSerial: serial, driverID: driver, scannedAt: .now)) {
            XCTAssertEqual($0 as? TokenError, .badSignature)
        }
    }

    func testStationCodeIsNotABoardingPass() throws {
        let p = try joined()
        let station = service.currentStationToken(trip: "T1040", stop: 1)
        XCTAssertThrowsError(try service.driverCheckIn(raw: station, ticketSerial: serial, driverID: driver, scannedAt: .now)) {
            XCTAssertEqual($0 as? TokenError, .wrongPurpose)
        }
        // 反過來，乘車碼也不能拿去當站牌碼掃
        XCTAssertThrowsError(try service.checkIn(raw: pass(p), participation: p, method: "camera"))
    }

    func testPassFromAnotherPhoneNotFound() throws {
        let other = try AppSchema.makeContainer(inMemory: true)
        SeedData.seed(other.mainContext)
        let otherService = FlowService(context: other.mainContext)
        let q = try otherService.join(mission: otherService.mission("M-A")!, user: user).0
        XCTAssertThrowsError(try service.boardingPreview(raw: otherService.boardingPassPayload(for: q)!)) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("同一支手機") ?? false)
        }
    }

    func testStationFlowStillWorksAlongsideDriverFlow() throws {
        let p = try joined()
        try service.checkIn(raw: service.currentStationToken(trip: "T1040", stop: 1), participation: p, method: "camera")
        // 混用：出發掃站牌、到站給司機掃，也只入帳一次
        let r = try service.driverCheckIn(raw: pass(p), ticketSerial: "", driverID: driver, scannedAt: .now)
        XCTAssertEqual(r.coinsAwarded, 100)
        XCTAssertEqual(service.balance(for: user), 100)
    }
}
