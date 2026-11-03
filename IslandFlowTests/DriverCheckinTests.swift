import XCTest
import SwiftData
@testable import IslandFlow

/// D34：旅客先輸入購票序號，App 顯示票券 QR（模擬台灣好行電子票券，整天不變），司機掃描確認上下車。
/// 同一支手機，所以旅客與司機共用一個資料庫。
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

    private func joinedWithTicket() throws -> Participation {
        let p = try service.join(mission: service.mission("M-A")!, user: user).0
        try service.bindTicket(serial: serial, participation: p)
        return p
    }

    private func pass(_ p: Participation) -> String { service.boardingPassPayload(for: p)! }

    func testNoTicketQRBeforeSerialEntered() throws {
        let p = try service.join(mission: service.mission("M-A")!, user: user).0
        XCTAssertNil(service.boardingPassPayload(for: p), "沒輸入序號就沒有票券 QR")
        XCTAssertNil(service.ticketSerial(participationID: p.id))
    }

    func testSerialRequiredAndOnlyDemoSerialAccepted() throws {
        let p = try service.join(mission: service.mission("M-A")!, user: user).0
        XCTAssertThrowsError(try service.bindTicket(serial: "  ", participation: p)) {
            XCTAssertEqual(($0 as? FlowError)?.message, "請輸入購票序號")
        }
        XCTAssertThrowsError(try service.bindTicket(serial: "12345678", participation: p)) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("查無購票序號") ?? false)
        }
        XCTAssertNil(service.boardingPassPayload(for: p))
        XCTAssertNoThrow(try service.bindTicket(serial: " \(serial) ", participation: p))
        XCTAssertEqual(service.ticketSerial(participationID: p.id), serial)
    }

    func testFullDriverFlowAwardsOnce() throws {
        let p = try joinedWithTicket()
        let depart = try service.driverCheckIn(raw: pass(p), driverID: driver)
        XCTAssertEqual(depart.stage, .depart)
        XCTAssertEqual(depart.stopName, service.stopName(1))
        XCTAssertNil(depart.coinsAwarded)
        XCTAssertEqual(p.statusValue, .departed)

        let arrive = try service.driverCheckIn(raw: pass(p), driverID: driver)
        XCTAssertEqual(arrive.coinsAwarded, 100)
        XCTAssertEqual(service.balance(for: user), 100)

        let methods = try container.mainContext.fetch(FetchDescriptor<Checkin>()).map(\.method)
        XCTAssertEqual(methods, ["driver", "driver"])
        let details = try container.mainContext.fetch(FetchDescriptor<AuditLog>())
            .filter { $0.action.hasPrefix("checkin_") }.map(\.detail)
        XCTAssertTrue(details.allSatisfy { $0.contains("購票序號 \(serial)") }, "稽核紀錄要記下是哪張票")
    }

    /// 票券 QR 像真的電子票券一樣整天不變，上下車都是同一張
    func testTicketQRIsStaticAcrossTheDayAndStages() throws {
        let p = try joinedWithTicket()
        let first = pass(p)
        service.now = { .now.addingTimeInterval(120) }
        XCTAssertEqual(pass(p), first, "不會每 30 秒換碼")
        try service.driverCheckIn(raw: first, driverID: driver)
        XCTAssertEqual(pass(p), first, "下車出示同一張")
        XCTAssertEqual(try service.driverCheckIn(raw: first, driverID: driver).coinsAwarded, 100)
    }

    func testCompletedMissionRejectsFurtherScans() throws {
        let p = try joinedWithTicket()
        let ticket = pass(p)
        try service.driverCheckIn(raw: ticket, driverID: driver)
        try service.driverCheckIn(raw: ticket, driverID: driver)
        XCTAssertNil(service.boardingPassPayload(for: p), "完成後不再顯示票券 QR")
        XCTAssertThrowsError(try service.driverCheckIn(raw: ticket, driverID: driver)) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("任務已完成") ?? false)
        }
        XCTAssertEqual(service.balance(for: user), 100)
        // 被擋也要留下稽核紀錄
        let rejected = try container.mainContext.fetch(FetchDescriptor<AuditLog>()).filter { $0.action == "checkin_rejected" }
        XCTAssertEqual(rejected.first?.actorID, driver)
    }

    func testTicketExpiresAtEndOfDay() throws {
        let p = try joinedWithTicket()
        let today = pass(p)
        service.now = { Calendar.current.startOfDay(for: .now).addingTimeInterval(24 * 3600 + 60) }
        XCTAssertThrowsError(try service.driverCheckIn(raw: today, driverID: driver)) {
            XCTAssertEqual($0 as? TokenError, .expired)
        }
    }

    func testTamperedTicketRejected() throws {
        let p = try joinedWithTicket()
        let parts = pass(p).split(separator: ".")
        var payload = try TokenSigner.verifyBoarding(pass(p))
        payload.serial = "99999999"
        let forged = "\(parts[0]).\(try JSONEncoder.sorted.encode(payload).base64URL).\(parts[2])"
        XCTAssertThrowsError(try service.driverCheckIn(raw: forged, driverID: driver)) {
            XCTAssertEqual($0 as? TokenError, .badSignature)
        }
    }

    func testStationCodeAndTicketQRAreNotInterchangeable() throws {
        let p = try joinedWithTicket()
        let station = service.currentStationToken(trip: "T1040", stop: 1)
        XCTAssertThrowsError(try service.driverCheckIn(raw: station, driverID: driver)) {
            XCTAssertEqual($0 as? TokenError, .wrongPurpose)
        }
        XCTAssertThrowsError(try service.checkIn(raw: pass(p), participation: p, method: "camera"))
    }

    func testTicketFromAnotherPhoneNotFound() throws {
        let other = try AppSchema.makeContainer(inMemory: true)
        SeedData.seed(other.mainContext)
        let otherService = FlowService(context: other.mainContext)
        let q = try otherService.join(mission: otherService.mission("M-A")!, user: user).0
        try otherService.bindTicket(serial: serial, participation: q)
        XCTAssertThrowsError(try service.boardingPreview(raw: otherService.boardingPassPayload(for: q)!)) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("同一支手機") ?? false)
        }
    }

    func testStationFlowStillWorksAlongsideDriverFlow() throws {
        let p = try joinedWithTicket()
        try service.checkIn(raw: service.currentStationToken(trip: "T1040", stop: 1), participation: p, method: "camera")
        // 混用：出發掃站牌、到站給司機掃，也只入帳一次
        let r = try service.driverCheckIn(raw: pass(p), driverID: driver)
        XCTAssertEqual(r.coinsAwarded, 100)
        XCTAssertEqual(service.balance(for: user), 100)
    }

    func testCannotBindTicketAfterCompletion() throws {
        let p = try joinedWithTicket()
        try service.driverCheckIn(raw: pass(p), driverID: driver)
        try service.driverCheckIn(raw: pass(p), driverID: driver)
        XCTAssertThrowsError(try service.bindTicket(serial: serial, participation: p))
    }
}
