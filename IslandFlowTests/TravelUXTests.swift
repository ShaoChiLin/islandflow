import XCTest
import SwiftData
@testable import IslandFlow

/// 改版方針 P0-B：先判斷能不能參加，再比獎勵
final class TripAvailabilityTests: XCTestCase {
    private func eval(_ dep: String = "10:40", now: String = "09:30", cancelled: Bool = false, remaining: Int = 5,
                      stock: Bool = true, enforce: Bool = false, joined: Bool = false) -> TripAvailability {
        TripAvailability.evaluate(departure: dep, nowMinute: ClockTime.minutes(now)!, isCancelled: cancelled,
                                  remaining: remaining, hasRewardStock: stock, enforceSchedule: enforce, alreadyJoined: joined)
    }

    func testBeforeDepartureIsOpen() {
        XCTAssertEqual(eval(), .open)
    }

    func testPastDepartureIsReplayInDemoAndClosedWhenScheduleEnforced() {
        XCTAssertEqual(eval(now: "11:00"), .replay)
        XCTAssertEqual(eval(now: "11:00", enforce: true), .closed("已發車"))
    }

    func testFullCancelledOrNoStockAreClosed() {
        XCTAssertEqual(eval(remaining: 0), .closed("今日名額已滿"))
        XCTAssertEqual(eval(cancelled: true), .closed("班次已取消"))
        XCTAssertEqual(eval(stock: false), .closed("兌換品已送完"))
    }

    func testJoinedUserCanAlwaysComeBack() {
        XCTAssertEqual(eval(now: "23:00", remaining: 0, enforce: true, joined: true), .open)
    }

    func testClockParsing() {
        XCTAssertEqual(ClockTime.minutes("10:40"), 640)
        XCTAssertNil(ClockTime.minutes("24:00"))
        XCTAssertNil(ClockTime.minutes("—"))
    }
}

/// 改版方針 P0-C 的示範單元案例（純假設係數，非官方數字）：測單位與負值，不測「算出正值」
final class TransportEmissionTests: XCTestCase {
    let car = EmissionFactor(kgPerKm: 0.20, unit: .perVehicleKm, source: nil, isDemo: true)
    let bus = EmissionFactor(kgPerKm: 0.06, unit: .perPassengerKm, source: nil, isDemo: true)

    func testCarpoolOfTwoSavesAndOfFourEmitsMore() {
        let actual = TransportEmission.perPersonKg(distanceKm: 10, factor: bus)!
        XCTAssertEqual(actual, 0.6, accuracy: 1e-9)
        let two = TransportEmission.perPersonKg(distanceKm: 10, factor: car, occupants: 2)!
        XCTAssertEqual(two, 1.0, accuracy: 1e-9)
        XCTAssertEqual(TransportEmission.signedDifference(baselineKg: two, actualKg: actual)!, 0.4, accuracy: 1e-9)
        let four = TransportEmission.perPersonKg(distanceKm: 10, factor: car, occupants: 4)!
        // 負值要保留：這個情境下搭公車反而多排放，不能截成 0
        XCTAssertEqual(TransportEmission.signedDifference(baselineKg: four, actualKg: actual)!, -0.1, accuracy: 1e-9)
    }

    func testPerPassengerFactorIsNotDividedAgain() {
        XCTAssertEqual(TransportEmission.perPersonKg(distanceKm: 10, factor: bus, occupants: 4)!, 0.6, accuracy: 1e-9)
    }

    func testMissingInputsAreUnknownNotZero() {
        XCTAssertNil(TransportEmission.perPersonKg(distanceKm: nil, factor: bus))
        XCTAssertNil(TransportEmission.perPersonKg(distanceKm: 10, factor: nil))
        XCTAssertNil(TransportEmission.perPersonKg(distanceKm: 10, factor: car), "每車公里沒有同車人數就不能算")
        XCTAssertNil(TransportEmission.perPersonKg(distanceKm: 10, factor: car, occupants: 0))
        XCTAssertNil(TransportEmission.signedDifference(baselineKg: nil, actualKg: 0.6))
    }
}

@MainActor
final class TravelUXIntegrationTests: XCTestCase {
    var container: ModelContainer!
    var service: FlowService!

    override func setUp() async throws {
        container = try AppSchema.makeContainer(inMemory: true)
        SeedData.seed(container.mainContext)
        service = FlowService(context: container.mainContext)
    }

    private func at(_ hhmm: String) -> Date {
        let m = ClockTime.minutes(hhmm)!
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: .now)!
    }

    private func missions() -> [Mission] { (try? container.mainContext.fetch(FetchDescriptor<Mission>())) ?? [] }

    func testRecommendationPrefersJoinableTripOverDepartedOne() {
        let morning = MissionOptions.build(service, missions: missions(), user: "t-demo", now: at("09:30"))
        XCTAssertEqual(morning.map(\.mission.id), ["M-A", "M-B"], "兩班都還沒發車時，獎勵高的 10:40 排第一")
        let noon = MissionOptions.build(service, missions: missions(), user: "t-demo", now: at("11:00"))
        XCTAssertEqual(noon.first?.mission.id, "M-B", "10:40 已發車，不能再當首推")
        XCTAssertEqual(noon.last?.availability, .replay)
    }

    func testFullMissionIsNotRecommended() throws {
        service.mission("M-A")!.capacity = 1
        try service.join(mission: service.mission("M-A")!, user: "someone")
        let options = MissionOptions.build(service, missions: missions(), user: "t-demo", now: at("09:30"))
        XCTAssertEqual(options.first?.mission.id, "M-B")
        XCTAssertEqual(options.last?.availability, .closed("今日名額已滿"))
    }

    func testLeaveReleasesSeatAndKeepsAudit() throws {
        let m = service.mission("M-A")!
        m.capacity = 1
        let (p, _) = try service.join(mission: m, user: "t-demo")
        XCTAssertEqual(service.remaining(m), 0)
        try service.leave(p, user: "t-demo")
        XCTAssertEqual(service.remaining(m), 1)
        XCTAssertNil(service.participation(mission: "M-A", user: "t-demo"))
        let logs = try container.mainContext.fetch(FetchDescriptor<AuditLog>(predicate: #Predicate { $0.action == "leave" }))
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(service.balance(for: "t-demo"), 0, "取消不入帳")
    }

    func testCannotLeaveSomeoneElsesParticipation() throws {
        let (p, _) = try service.join(mission: service.mission("M-A")!, user: "t-demo")
        XCTAssertThrowsError(try service.leave(p, user: "t-demo2")) {
            XCTAssertEqual(($0 as? FlowError)?.message, "只能取消自己加入的任務")
        }
        XCTAssertNotNil(service.participation(mission: "M-A", user: "t-demo"))
    }

    func testCannotLeaveAfterDeparture() throws {
        let m = service.mission("M-A")!
        let (p, _) = try service.join(mission: m, user: "t-demo")
        _ = try service.checkIn(raw: service.currentStationToken(trip: m.tripID, stop: m.startStopSeq), participation: p, method: "demo")
        XCTAssertThrowsError(try service.leave(p, user: "t-demo"))
        XCTAssertEqual(p.statusValue, .departed)
    }

    func testSegmentEmissionIsDemoAndPositive() {
        let (km, kg) = service.segmentEmission(service.mission("M-A")!)
        XCTAssertGreaterThan(km, 5)
        XCTAssertEqual(kg!, km * 0.040, accuracy: 1e-9)
        XCTAssertTrue(service.busEmissionFactor().isDemo)
        XCTAssertNil(service.busEmissionFactor().source, "係數來源未核實前不得填來源")
    }

    func testReturnDirectionHasItsOwnStopOrder() {
        let back = OpenData.stops(direction: "回程")
        XCTAssertEqual(back.count, 9)
        XCTAssertEqual(back.first?.name, "竹子湖")
        XCTAssertEqual(back.last?.name, "捷運北投站")
    }
}
