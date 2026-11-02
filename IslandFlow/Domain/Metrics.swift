import Foundation

/// 政策儀表板的指標定義，逐條對應規格書「儀表板指標」表。純函式，方便測試與說明。
struct MetricAssumptions: Equatable {
    var coinValueNTD = 1.0
    var incrementalRideRatio = 0.35
    var avgLocalSpendNTD = 180.0
    var diversionBaseline = 40
    var busFactor = 0.040

    init() {}

    init(_ c: RuleConfig) {
        coinValueNTD = c.coinValueNTD
        incrementalRideRatio = c.incrementalRideRatio
        avgLocalSpendNTD = c.avgLocalSpendNTD
        diversionBaseline = c.diversionBaseline
        busFactor = c.busFactor
    }
}

struct ParticipationFact {
    var userID: String
    var missionID: String
    var completed: Bool
    var completedAt: Date?
    var joinedAt: Date
    var isOffPeak: Bool
    var toDiversionTarget: Bool
    var distanceKm: Double
    var isSimulated: Bool
}

struct RedemptionFact {
    var userID: String
    var success: Bool
    var at: Date
    var isSimulated: Bool
}

struct DailyPoint: Identifiable {
    var id: Date { day }
    var day: Date
    var completions: Int
    var redemptions: Int
}

struct DashboardMetrics {
    var views = 0
    var joins = 0
    var completions = 0
    var redeemedUsers = 0
    var redemptionCount = 0
    var coinsIssued = 0
    var rewardCostNTD = 0.0
    var addedRides = 0.0
    var costPerAddedRide: Double?
    var localSpendNTD = 0.0
    var leverage: Double?
    var offPeakShare: Double?
    var diversionVisits = 0
    var diversionBaseline = 0
    /// 完成任務的搭公車排放估算加總（kgCO₂e）。和旅客端同一套 TransportEmission；不算減碳（K21）
    var busEmissionKg = 0.0
    var emissionEstimatedSegments = 0
    /// 缺距離或係數、算不出來的段落；未知不是 0，所以不加進總和
    var emissionUnknownSegments = 0
    var liveCompletions = 0
    var liveRedemptions = 0
    var daily: [DailyPoint] = []

    var joinRate: Double? { views > 0 ? Double(joins) / Double(views) : nil }
    var completionRate: Double? { joins > 0 ? Double(completions) / Double(joins) : nil }
    var redemptionRate: Double? { completions > 0 ? Double(redeemedUsers) / Double(completions) : nil }
    var diversionDelta: Int { diversionVisits - diversionBaseline }

    static func compute(views: Int, participations: [ParticipationFact], redemptions: [RedemptionFact],
                        coinsIssued: Int, assumptions a: MetricAssumptions,
                        calendar: Calendar = .current, now: Date = .now, days: Int = 14) -> DashboardMetrics {
        var m = DashboardMetrics()
        m.views = views
        m.joins = participations.count
        let done = participations.filter(\.completed)
        m.completions = done.count
        m.liveCompletions = done.filter { !$0.isSimulated }.count

        let ok = redemptions.filter(\.success)
        m.redemptionCount = ok.count
        m.liveRedemptions = ok.filter { !$0.isSimulated }.count
        // 「已核銷人數」只算有完成任務的人，避免分子分母母體不同
        let completedUsers = Set(done.map(\.userID))
        m.redeemedUsers = Set(ok.map(\.userID)).intersection(completedUsers).count

        m.coinsIssued = coinsIssued
        m.rewardCostNTD = Double(coinsIssued) * a.coinValueNTD
        m.addedRides = Double(m.completions) * a.incrementalRideRatio
        m.costPerAddedRide = m.addedRides > 0 ? m.rewardCostNTD / m.addedRides : nil
        m.localSpendNTD = Double(m.redemptionCount) * a.avgLocalSpendNTD
        m.leverage = m.rewardCostNTD > 0 ? m.localSpendNTD / m.rewardCostNTD : nil
        m.offPeakShare = done.isEmpty ? nil : Double(done.filter(\.isOffPeak).count) / Double(done.count)
        m.diversionVisits = done.filter(\.toDiversionTarget).count
        m.diversionBaseline = a.diversionBaseline
        // 原交通方式還沒蒐集（P0-C），所以只加總實際搭公車的排放，不和開車比
        let bus = EmissionFactor(kgPerKm: a.busFactor, unit: .perPassengerKm, source: nil, isDemo: true)
        for p in done {
            if let kg = TransportEmission.perPersonKg(distanceKm: p.distanceKm > 0 ? p.distanceKm : nil, factor: bus) {
                m.busEmissionKg += kg
                m.emissionEstimatedSegments += 1
            } else {
                m.emissionUnknownSegments += 1
            }
        }

        let today = calendar.startOfDay(for: now)
        m.daily = (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let c = done.filter { $0.completedAt.map { calendar.isDate($0, inSameDayAs: day) } ?? false }.count
            let r = ok.filter { calendar.isDate($0.at, inSameDayAs: day) }.count
            return DailyPoint(day: day, completions: c, redemptions: r)
        }
        return m
    }
}
