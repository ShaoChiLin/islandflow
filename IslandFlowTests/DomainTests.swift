import XCTest
@testable import IslandFlow

final class RewardEngineTests: XCTestCase {
    private func input(_ load: Double, offPeak: Bool = true, diversion: Bool = false) -> RewardInput {
        RewardInput(predictedLoad: load, isOffPeak: offPeak, destinationIsDiversionTarget: diversion, destinationName: "陽明書屋")
    }

    func testLowLoadOffPeakGetsBasePlusBonus() {
        let r = RewardEngine.compute(input(0.28), rules: RewardRules())
        XCTAssertEqual(r.coins, 100)
        XCTAssertEqual(r.tier, .low)
        XCTAssertTrue(r.explanation.contains("離峰"))
    }

    func testMidLoadDiversionBonus() {
        XCTAssertEqual(RewardEngine.compute(input(0.52, diversion: true), rules: RewardRules()).coins, 80)
        XCTAssertEqual(RewardEngine.compute(input(0.52, diversion: false), rules: RewardRules()).coins, 60)
    }

    func testHighLoadNoBonus() {
        let r = RewardEngine.compute(input(0.9, diversion: true), rules: RewardRules())
        XCTAssertEqual(r.coins, 40)
        XCTAssertEqual(r.tier, .high)
    }

    /// 驗收 1：低載客班次一定比高載客班次拿得多
    func testLowerLoadNeverPaysLess() {
        let rules = RewardRules()
        var previous = Int.max
        for load in stride(from: 0.0, through: 1.6, by: 0.05) {
            let c = RewardEngine.compute(input(load), rules: rules).coins
            XCTAssertLessThanOrEqual(c, previous, "load \(load)")
            previous = c
        }
    }

    func testCapAt120() {
        var rules = RewardRules()
        rules.lowBase = 110
        let r = RewardEngine.compute(input(0.1), rules: rules)
        XCTAssertEqual(r.coins, 120)
        XCTAssertTrue(r.explanation.contains("上限"))
    }

    func testScoreModeFormula() {
        var rules = RewardRules()
        rules.mode = .score
        var i = input(0.0)
        i.destinationSlack = 1; i.merchantCapacity = 1; i.carbonBenefit = 1
        rules.weatherFit = 1
        // 全部為 1 → 分數 1.0 → 40 + 80 = 120
        XCTAssertEqual(RewardEngine.compute(i, rules: rules).coins, 120)
        i = input(1.0)
        i.destinationSlack = 0; i.merchantCapacity = 0; i.carbonBenefit = 0
        rules.weatherFit = 0
        XCTAssertEqual(RewardEngine.compute(i, rules: rules).coins, 40)
    }
}

final class TokenTests: XCTestCase {
    func testStationTokenRoundTrip() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = TokenSigner.stationToken(route: "BTZ", trip: "T1040", stop: 1, ttl: 60, now: now)
        let t = try TokenSigner.verifyStation(raw, now: now.addingTimeInterval(10))
        XCTAssertEqual(t.trip, "T1040")
        XCTAssertEqual(t.stop, 1)
    }

    func testStationTokenExpires() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = TokenSigner.stationToken(route: "BTZ", trip: "T1040", stop: 1, ttl: 60, now: now)
        XCTAssertThrowsError(try TokenSigner.verifyStation(raw, now: now.addingTimeInterval(61))) {
            XCTAssertEqual($0 as? TokenError, .expired)
        }
    }

    func testTamperedTokenRejected() {
        let raw = TokenSigner.stationToken(route: "BTZ", trip: "T1040", stop: 1, ttl: 60)
        let parts = raw.split(separator: ".")
        var body = try! JSONDecoder().decode(StationToken.self, from: Data(base64URL: String(parts[1]))!)
        body.stop = 9
        let forged = "IF1.\(try! JSONEncoder.sorted.encode(body).base64URL).\(parts[2])"
        XCTAssertThrowsError(try TokenSigner.verifyStation(forged)) {
            XCTAssertEqual($0 as? TokenError, .badSignature)
        }
    }

    func testRedeemTokenIsNotAStationToken() {
        let raw = TokenSigner.sign(RedeemToken(tid: "x", exp: Int(Date().timeIntervalSince1970) + 60))
        XCTAssertThrowsError(try TokenSigner.verifyStation(raw))
    }

    func testShortCodeIsStableSixDigits() {
        let a = TokenSigner.shortCode(for: "abc")
        XCTAssertEqual(a, TokenSigner.shortCode(for: "abc"))
        XCTAssertEqual(a.count, 6)
        XCTAssertTrue(a.allSatisfy(\.isNumber))
    }
}

final class CarbonAndMetricsTests: XCTestCase {
    func testAvoidedEmission() {
        XCTAssertEqual(CarbonEstimator.avoidedKg(distanceKm: 10, carFactor: 0.115, busFactor: 0.04), 0.75, accuracy: 1e-9)
        XCTAssertEqual(CarbonEstimator.avoidedKg(distanceKm: 10, carFactor: 0.02, busFactor: 0.04), 0)
    }

    func testRouteDistanceUsesDetourFactor() {
        let pts = [(lat: 25.132265, lon: 121.49798), (lat: 25.172625, lon: 121.533392)]
        let straight = Geo.routeKm(stops: pts, detourFactor: 1)
        // 捷運北投站到竹子湖的直線距離約 5.73 公里
        XCTAssertEqual(straight, 5.73, accuracy: 0.05)
        XCTAssertEqual(Geo.routeKm(stops: pts, detourFactor: 1.4), straight * 1.4, accuracy: 1e-9)
    }

    func testDashboardDefinitions() {
        let now = Date()
        func p(_ u: String, done: Bool, offPeak: Bool, div: Bool) -> ParticipationFact {
            ParticipationFact(userID: u, missionID: "M", completed: done, completedAt: done ? now : nil, joinedAt: now,
                              isOffPeak: offPeak, toDiversionTarget: div, distanceKm: 10, isSimulated: false)
        }
        let parts = [p("a", done: true, offPeak: true, div: true), p("b", done: true, offPeak: false, div: false),
                     p("c", done: false, offPeak: true, div: false), p("d", done: true, offPeak: true, div: true)]
        let reds = [RedemptionFact(userID: "a", success: true, at: now, isSimulated: false),
                    RedemptionFact(userID: "a", success: true, at: now, isSimulated: false),
                    RedemptionFact(userID: "b", success: false, at: now, isSimulated: false),
                    RedemptionFact(userID: "zz", success: true, at: now, isSimulated: false)]
        var a = MetricAssumptions()
        a.diversionBaseline = 1
        let m = DashboardMetrics.compute(views: 8, participations: parts, redemptions: reds, coinsIssued: 300, assumptions: a, now: now)
        XCTAssertEqual(m.joinRate!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(m.completionRate!, 0.75, accuracy: 1e-9)
        // 已核銷人數只算有完成任務的人：a（zz 沒完成任務，不算）
        XCTAssertEqual(m.redeemedUsers, 1)
        XCTAssertEqual(m.redemptionCount, 3)
        XCTAssertEqual(m.rewardCostNTD, 300)
        XCTAssertEqual(m.addedRides, 3 * 0.35, accuracy: 1e-9)
        XCTAssertEqual(m.localSpendNTD, 3 * 180)
        XCTAssertEqual(m.leverage!, 540.0 / 300, accuracy: 1e-9)
        XCTAssertEqual(m.offPeakShare!, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(m.diversionDelta, 1)
        XCTAssertEqual(m.avoidedKg, 3 * 0.75, accuracy: 1e-9)
    }

    func testOpenDataParsing() {
        let stops = OpenData.parseStops("\u{FEFF}路線名稱,方向性,站序,站牌名稱,緯度,經度\n北投竹子湖線,去程,1,捷運北投站,25.132265,121.49798\n")
        XCTAssertEqual(stops, [.init(route: "北投竹子湖線", direction: "去程", sequence: 1, name: "捷運北投站", lat: 25.132265, lon: 121.49798)])
        let rows = OpenData.parseRidership("年度,月份,平／假日,班次,總座位數,總搭乘人數,搭乘率\n115,1,平日,1232,23408,29064,124.16%\n")
        XCTAssertEqual(rows.first?.occupancy ?? 0, 1.2416, accuracy: 1e-9)
    }

    func testBundledOpenDataHasNineOutboundStops() {
        XCTAssertEqual(OpenData.outboundStops.count, 9)
        XCTAssertEqual(OpenData.outboundStops.last?.name, "竹子湖")
        XCTAssertFalse(OpenData.ridership.isEmpty)
    }
}
