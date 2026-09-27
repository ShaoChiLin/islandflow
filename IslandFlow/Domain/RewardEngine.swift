import Foundation

/// RuleConfig 的純值快照，讓獎勵計算不依賴 SwiftData，方便單元測試與「規則預覽」。
struct RewardRules: Equatable {
    var mode: RewardMode = .tier
    var lowThreshold = 0.35
    var highThreshold = 0.60
    var lowBase = 80
    var midBase = 60
    var highBase = 40
    var offPeakBonus = 20
    var diversionBonus = 20
    var minReward = 40
    var maxReward = 120
    var wLoad = 0.35
    var wDestination = 0.25
    var wMerchant = 0.20
    var wWeather = 0.10
    var wCarbon = 0.10
    var weatherFit = 0.7

    init() {}

    init(_ c: RuleConfig) {
        mode = RewardMode(rawValue: c.mode) ?? .tier
        lowThreshold = c.lowThreshold
        highThreshold = c.highThreshold
        lowBase = c.lowBase
        midBase = c.midBase
        highBase = c.highBase
        offPeakBonus = c.offPeakBonus
        diversionBonus = c.diversionBonus
        minReward = c.minReward
        maxReward = c.maxReward
        wLoad = c.wLoad
        wDestination = c.wDestination
        wMerchant = c.wMerchant
        wWeather = c.wWeather
        wCarbon = c.wCarbon
        weatherFit = c.weatherFit
    }
}

struct RewardInput: Equatable {
    var predictedLoad: Double
    var isOffPeak: Bool
    var destinationIsDiversionTarget: Bool
    var destinationName: String
    /// 以下三項只在加權分數模式使用，皆為 0~1
    var destinationSlack: Double = 0.5
    var merchantCapacity: Double = 0.5
    var carbonBenefit: Double = 0.5
}

enum LoadTier: String {
    case low, mid, high
    var label: String {
        switch self {
        case .low: "空位多"
        case .mid: "普通"
        case .high: "擁擠"
        }
    }
    var symbol: String {
        switch self {
        case .low: "person"
        case .mid: "person.2"
        case .high: "person.3.fill"
        }
    }
}

struct RewardLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var coins: Int?

    static func == (a: RewardLine, b: RewardLine) -> Bool { a.text == b.text && a.coins == b.coins }
}

struct RewardResult: Equatable {
    var coins: Int
    var tier: LoadTier
    var lines: [RewardLine]
    var score: Double?

    /// 存進 Participation 的文字版說明，之後即使規則改了也看得到當初為什麼拿這麼多
    var explanation: String {
        lines.map { line in
            if let c = line.coins { return "\(line.text)（\(c >= 0 ? "+" : "")\(c)）" }
            return line.text
        }.joined(separator: "\n")
    }
}

/// 可解釋的動態獎勵規則。刻意不用任何預測模型：評審要能看懂每一枚旅綠幣為什麼被投放。
enum RewardEngine {
    static func tier(for load: Double, rules: RewardRules) -> LoadTier {
        if load < rules.lowThreshold { return .low }
        if load <= rules.highThreshold { return .mid }
        return .high
    }

    static func compute(_ input: RewardInput, rules: RewardRules) -> RewardResult {
        switch rules.mode {
        case .tier: tierMode(input, rules)
        case .score: scoreMode(input, rules)
        }
    }

    private static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private static func tierMode(_ input: RewardInput, _ r: RewardRules) -> RewardResult {
        let t = tier(for: input.predictedLoad, rules: r)
        var lines: [RewardLine] = []
        var total: Int
        switch t {
        case .low:
            total = r.lowBase
            lines.append(.init(text: "預估載客率 \(pct(input.predictedLoad))，低於 \(pct(r.lowThreshold))：基礎獎勵", coins: r.lowBase))
            if input.isOffPeak {
                total += r.offPeakBonus
                lines.append(.init(text: "離峰班次加碼", coins: r.offPeakBonus))
            }
        case .mid:
            total = r.midBase
            lines.append(.init(text: "預估載客率 \(pct(input.predictedLoad))，介於 \(pct(r.lowThreshold))～\(pct(r.highThreshold))：基礎獎勵", coins: r.midBase))
            if input.destinationIsDiversionTarget {
                total += r.diversionBonus
                lines.append(.init(text: "目的地「\(input.destinationName)」為指定分流站點", coins: r.diversionBonus))
            }
        case .high:
            total = r.highBase
            lines.append(.init(text: "預估載客率 \(pct(input.predictedLoad))，高於 \(pct(r.highThreshold))：基礎獎勵", coins: r.highBase))
            lines.append(.init(text: "班次已擁擠，不提供載客加碼", coins: nil))
        }
        return RewardResult(coins: clamp(total, r, &lines), tier: t, lines: lines, score: nil)
    }

    private static func scoreMode(_ input: RewardInput, _ r: RewardRules) -> RewardResult {
        let lowLoadNeed = max(0, min(1, 1 - input.predictedLoad))
        let parts: [(String, Double, Double)] = [
            ("低載客需求", r.wLoad, lowLoadNeed),
            ("目的地承載空間", r.wDestination, input.destinationSlack),
            ("商家接待量能", r.wMerchant, input.merchantCapacity),
            ("天氣適配（模擬）", r.wWeather, r.weatherFit),
            ("減碳效益", r.wCarbon, input.carbonBenefit),
        ]
        var score = 0.0
        var lines: [RewardLine] = []
        for (name, w, v) in parts {
            score += w * v
            lines.append(.init(text: "\(name) \(String(format: "%.2f", v)) × 權重 \(String(format: "%.2f", w))", coins: nil))
        }
        let raw = Int((40 + 80 * score).rounded())
        lines.append(.init(text: "任務分數 \(String(format: "%.2f", score))，40 + 80 × 分數", coins: raw))
        let t = tier(for: input.predictedLoad, rules: r)
        return RewardResult(coins: clamp(raw, r, &lines), tier: t, lines: lines, score: score)
    }

    private static func clamp(_ value: Int, _ r: RewardRules, _ lines: inout [RewardLine]) -> Int {
        if value > r.maxReward {
            lines.append(.init(text: "單一任務上限 \(r.maxReward) 枚", coins: r.maxReward - value))
            return r.maxReward
        }
        if value < r.minReward {
            lines.append(.init(text: "單一任務下限 \(r.minReward) 枚", coins: r.minReward - value))
            return r.minReward
        }
        return value
    }
}
