import XCTest
import SwiftData
@testable import IslandFlow

/// 整合測試：用記憶體資料庫跑完整流程，對應規格書「必須通過的展示案例」。
@MainActor
final class FlowIntegrationTests: XCTestCase {
    var container: ModelContainer!
    var service: FlowService!
    let user = "t-demo"

    override func setUp() async throws {
        container = try AppSchema.makeContainer(inMemory: true)
        SeedData.seed(container.mainContext)
        service = FlowService(context: container.mainContext)
    }

    private var missionA: Mission { service.mission("M-A")! }
    private var missionB: Mission { service.mission("M-B")! }

    private func token(_ m: Mission, stop: Int, at: Date = .now) -> String {
        service.currentStationToken(trip: m.tripID, stop: stop, now: at)
    }

    private func complete(_ m: Mission, user: String) throws -> Participation {
        let (p, _) = try service.join(mission: m, user: user)
        _ = try service.checkIn(raw: token(m, stop: m.startStopSeq), participation: p, method: "demo")
        _ = try service.checkIn(raw: token(m, stop: m.endStopSeq), participation: p, method: "demo")
        return p
    }

    // 驗收 1
    func testLowLoadTripShowsHigherReward() {
        XCTAssertGreaterThan(service.reward(for: missionA).coins, service.reward(for: missionB).coins)
        service.trip("T1310")!.predictedLoad = 0.2
        XCTAssertEqual(service.reward(for: missionB).coins, 100)
    }

    // 驗收 2
    func testJoinTwiceCreatesOneRecord() throws {
        let (p1, a1) = try service.join(mission: missionA, user: user)
        let (p2, a2) = try service.join(mission: missionA, user: user)
        XCTAssertFalse(a1)
        XCTAssertTrue(a2)
        XCTAssertEqual(p1.id, p2.id)
        let uid = user
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Participation>(predicate: #Predicate { $0.userID == uid })), 1)
    }

    func testRewardLockedAtJoin() throws {
        let (p, _) = try service.join(mission: missionA, user: user)
        service.trip("T1040")!.predictedLoad = 0.9
        XCTAssertEqual(p.rewardAmount, 100)
        XCTAssertEqual(service.reward(for: missionA).coins, 40)
    }

    func testDailyLimit() throws {
        service.rules().dailyMissionLimit = 1
        try service.join(mission: missionA, user: user)
        XCTAssertThrowsError(try service.join(mission: missionB, user: user))
    }

    func testCapacity() throws {
        missionA.capacity = 1
        try service.join(mission: missionA, user: "x")
        XCTAssertThrowsError(try service.join(mission: missionA, user: user))
    }

    func testNoStockStopsNewJoins() throws {
        for id in ["r-veg", "r-calla"] { service.item(id)!.stock = 0 }
        XCTAssertThrowsError(try service.join(mission: missionA, user: user))
    }

    // 驗收 3
    func testArriveBeforeDepartRejected() throws {
        let (p, _) = try service.join(mission: missionA, user: user)
        XCTAssertThrowsError(try service.checkIn(raw: token(missionA, stop: 9), participation: p, method: "demo")) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("還沒完成出發驗證") ?? false)
        }
        XCTAssertEqual(p.statusValue, .joined)
    }

    func testExpiredWrongStopWrongTripRejected() throws {
        let (p, _) = try service.join(mission: missionA, user: user)
        XCTAssertThrowsError(try service.checkIn(raw: token(missionA, stop: 1, at: .now.addingTimeInterval(-600)), participation: p, method: "demo"))
        XCTAssertThrowsError(try service.checkIn(raw: token(missionA, stop: 4), participation: p, method: "demo"))
        XCTAssertThrowsError(try service.checkIn(raw: service.currentStationToken(trip: "T1310", stop: 1), participation: p, method: "demo")) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("13:10") ?? false)
        }
        XCTAssertEqual(p.statusValue, .joined)
    }

    // 驗收 4
    func testCoinsCreditedExactlyOnce() throws {
        let p = try complete(missionA, user: user)
        XCTAssertEqual(p.statusValue, .completed)
        XCTAssertEqual(service.balance(for: user), 100)
        XCTAssertThrowsError(try service.checkIn(raw: token(missionA, stop: 9), participation: p, method: "demo"))
        XCTAssertEqual(service.balance(for: user), 100)
        XCTAssertEqual(service.ledger(for: user).count, 1)
    }

    func testLocationCheck() throws {
        service.rules().requireLocation = true
        let (p, _) = try service.join(mission: missionA, user: user)
        _ = try service.checkIn(raw: token(missionA, stop: 1), participation: p, method: "demo")
        // 在捷運北投站，離竹子湖太遠
        XCTAssertThrowsError(try service.checkIn(raw: token(missionA, stop: 9), participation: p, method: "demo",
                                                 location: .init(lat: 25.132265, lon: 121.49798))) {
            XCTAssertEqual(($0 as? FlowError)?.kind, .location)
        }
        let dest = service.stop(9)!
        let r = try service.checkIn(raw: token(missionA, stop: 9), participation: p, method: "demo",
                                    location: .init(lat: dest.lat + 0.001, lon: dest.lon))
        XCTAssertEqual(r.coinsAwarded, 100)
    }

    // 驗收 5、6
    func testRedemptionDeductsCoinsAndStockOnceEvenWhenResent() throws {
        _ = try complete(missionA, user: user)
        let item = service.item("r-veg")!
        let stock = item.stock
        let tok = try service.createRedeemToken(user: user, item: item)
        XCTAssertEqual(service.available(for: user), 20, "未核銷前先圈存")
        XCTAssertEqual(service.balance(for: user), 100, "確認前不得扣點")

        let preview = try service.preview(input: service.payload(for: tok), merchantID: "m-lake")
        XCTAssertEqual(preview.item.id, "r-veg")

        let key = UUID().uuidString
        let (r1, replay1) = try service.confirm(tokenID: tok.id, merchantID: "m-lake", idempotencyKey: key)
        let (r2, replay2) = try service.confirm(tokenID: tok.id, merchantID: "m-lake", idempotencyKey: key)
        XCTAssertFalse(replay1)
        XCTAssertTrue(replay2)
        XCTAssertEqual(r1.id, r2.id)
        XCTAssertEqual(service.balance(for: user), 20)
        XCTAssertEqual(item.stock, stock - 1)

        // 同一張碼換一把新的鍵也不能再核銷
        XCTAssertThrowsError(try service.confirm(tokenID: tok.id, merchantID: "m-lake", idempotencyKey: UUID().uuidString))
        XCTAssertEqual(service.balance(for: user), 20)
    }

    func testShortCodeLookup() throws {
        _ = try complete(missionA, user: user)
        let tok = try service.createRedeemToken(user: user, item: service.item("r-calla")!)
        let p = try service.preview(input: TokenSigner.shortCode(for: tok.id), merchantID: "m-lake")
        XCTAssertEqual(p.token.id, tok.id)
    }

    func testExpiredRedeemTokenRejectedAndLogged() throws {
        _ = try complete(missionA, user: user)
        let tok = try service.createRedeemToken(user: user, item: service.item("r-calla")!)
        service.now = { .now.addingTimeInterval(301) }
        XCTAssertThrowsError(try service.preview(input: service.payload(for: tok), merchantID: "m-lake"))
        let mid = "m-lake"
        let failed = try container.mainContext.fetch(FetchDescriptor<Redemption>(predicate: #Predicate { $0.merchantID == mid && $0.status == "failed" }))
        XCTAssertEqual(failed.count, 1)
    }

    // 權限：商家不能核銷別家的碼，也不會把失敗紀錄寫進別家
    func testOtherMerchantCannotRedeem() throws {
        _ = try complete(missionA, user: user)
        let tok = try service.createRedeemToken(user: user, item: service.item("r-veg")!)
        XCTAssertThrowsError(try service.preview(input: service.payload(for: tok), merchantID: "m-tea"))
        XCTAssertThrowsError(try service.confirm(tokenID: tok.id, merchantID: "m-tea", idempotencyKey: "k"))
        let mid = "m-tea"
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Redemption>(predicate: #Predicate { $0.merchantID == mid && $0.isSimulated == false })), 0)
        XCTAssertEqual(service.balance(for: user), 100)
    }

    func testCannotRedeemWithoutEnoughCoins() {
        XCTAssertThrowsError(try service.createRedeemToken(user: user, item: service.item("r-veg")!))
    }

    func testOutOfStockItemCannotIssueToken() throws {
        _ = try complete(missionA, user: user)
        let it = service.item("r-veg")!
        it.stock = 0
        XCTAssertThrowsError(try service.createRedeemToken(user: user, item: it))
    }

    func testNonPartnerCannotRedeem() throws {
        _ = try complete(missionA, user: user)
        let it = RewardItem(id: "x", merchantID: "m-candidate", name: "x", detail: "", coinCost: 10, stock: 5)
        container.mainContext.insert(it)
        XCTAssertThrowsError(try service.createRedeemToken(user: user, item: it))
    }

    // 驗收 7
    func testDashboardUpdatesAfterLiveFlow() throws {
        let before = service.dashboard()
        _ = try complete(missionA, user: user)
        let tok = try service.createRedeemToken(user: user, item: service.item("r-veg")!)
        _ = try service.confirm(tokenID: tok.id, merchantID: "m-lake", idempotencyKey: "k1")
        let after = service.dashboard()
        XCTAssertEqual(after.completions, before.completions + 1)
        XCTAssertEqual(after.redemptionCount, before.redemptionCount + 1)
        XCTAssertEqual(after.coinsIssued, before.coinsIssued + 100)
        XCTAssertEqual(after.liveCompletions, 1)
        XCTAssertEqual(after.liveRedemptions, 1)
        XCTAssertGreaterThan(before.views, 0)
    }
}
