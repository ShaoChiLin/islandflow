import Foundation
import SwiftData

// 資料表對應規格書「資料模型」一節。
//
// SwiftData 的 @Attribute(.unique) 遇到重複鍵會「覆寫」而不是丟錯，
// 所以唯一限制只保證不會出現兩列；真正的「拒絕重複」由 FlowService 先查再寫負責。

@Model
final class RouteStop {
    @Attribute(.unique) var key: String
    var routeCode: String
    var sequence: Int
    var name: String
    var shortName: String
    var lat: Double
    var lon: Double
    /// 管理者指定需要導流的站點；中級距任務的目的地若在這裡會加碼
    var isDiversionTarget: Bool
    /// 0~1，越高代表目的地越有承載空間（示範值，正式版應由景點人流資料計算）
    var destinationSlack: Double

    init(routeCode: String, sequence: Int, name: String, shortName: String, lat: Double, lon: Double,
         isDiversionTarget: Bool = false, destinationSlack: Double = 0.5) {
        self.key = "\(routeCode)-\(sequence)"
        self.routeCode = routeCode
        self.sequence = sequence
        self.name = name
        self.shortName = shortName
        self.lat = lat
        self.lon = lon
        self.isDiversionTarget = isDiversionTarget
        self.destinationSlack = destinationSlack
    }
}

@Model
final class BusTrip {
    @Attribute(.unique) var id: String
    var routeCode: String
    /// "10:40"，每日固定班次
    var departure: String
    /// 0~1.6 的示範值；超過 1 代表預估有站位。月搭乘率（172679）超過 100% 不等於單班超載，不能拿來推算這個值
    var predictedLoad: Double
    var isOffPeak: Bool
    var isCancelled: Bool
    var loadIsSimulated: Bool

    init(id: String, routeCode: String, departure: String, predictedLoad: Double, isOffPeak: Bool) {
        self.id = id
        self.routeCode = routeCode
        self.departure = departure
        self.predictedLoad = predictedLoad
        self.isOffPeak = isOffPeak
        self.isCancelled = false
        self.loadIsSimulated = true
    }
}

@Model
final class Mission {
    @Attribute(.unique) var id: String
    var tripID: String
    var title: String
    var subtitle: String
    var startStopSeq: Int
    var endStopSeq: Int
    var capacity: Int
    var isActive: Bool
    var viewCount: Int
    var notes: String
    var createdAt: Date

    init(id: String, tripID: String, title: String, subtitle: String, startStopSeq: Int, endStopSeq: Int,
         capacity: Int, viewCount: Int = 0, notes: String = "") {
        self.id = id
        self.tripID = tripID
        self.title = title
        self.subtitle = subtitle
        self.startStopSeq = startStopSeq
        self.endStopSeq = endStopSeq
        self.capacity = capacity
        self.isActive = true
        self.viewCount = viewCount
        self.notes = notes
        self.createdAt = .now
    }
}

/// 全域只有一筆（key = "default"）。管理者在 App 裡改，不需要改程式。
@Model
final class RuleConfig {
    @Attribute(.unique) var key: String = "default"

    // 級距表模式
    var mode: String = RewardMode.tier.rawValue
    var lowThreshold: Double = 0.35
    var highThreshold: Double = 0.60
    var lowBase: Int = 80
    var midBase: Int = 60
    var highBase: Int = 40
    var offPeakBonus: Int = 20
    var diversionBonus: Int = 20
    var minReward: Int = 40
    var maxReward: Int = 120

    // 加權分數模式
    var wLoad: Double = 0.35
    var wDestination: Double = 0.25
    var wMerchant: Double = 0.20
    var wWeather: Double = 0.10
    var wCarbon: Double = 0.10
    var weatherFit: Double = 0.7

    // 名額與防弊
    var dailyMissionLimit: Int = 2
    var stationTokenTTL: Int = 60
    var redeemTokenTTL: Int = 300
    var requireLocation: Bool = false
    var locationRadius: Double = 300
    /// 展示時不可能剛好在發車時間，預設不卡時段；時間窗仍會顯示
    var enforceSchedule: Bool = false

    // 儀表板假設（全部是示範值）
    var coinValueNTD: Double = 1.0
    var incrementalRideRatio: Double = 0.35
    var avgLocalSpendNTD: Double = 180
    var diversionBaseline: Int = 40
    var carFactor: Double = 0.115
    var busFactor: Double = 0.040
    var routeDetourFactor: Double = 1.4

    init() {}
}

enum RewardMode: String, CaseIterable, Identifiable {
    case tier, score
    var id: String { rawValue }
    var label: String { self == .tier ? "級距表" : "加權分數" }
}

@Model
final class Merchant {
    @Attribute(.unique) var id: String
    var name: String
    var stopSeq: Int
    var address: String
    var lat: Double
    var lon: Double
    /// 開放資料收錄 ≠ 已合作；只有 isPartner 的商家能被兌換
    var isPartner: Bool
    var isFictional: Bool
    var hours: String
    var intro: String
    var symbol: String

    init(id: String, name: String, stopSeq: Int, address: String, lat: Double, lon: Double,
         isPartner: Bool, isFictional: Bool, hours: String, intro: String, symbol: String) {
        self.id = id
        self.name = name
        self.stopSeq = stopSeq
        self.address = address
        self.lat = lat
        self.lon = lon
        self.isPartner = isPartner
        self.isFictional = isFictional
        self.hours = hours
        self.intro = intro
        self.symbol = symbol
    }
}

@Model
final class RewardItem {
    @Attribute(.unique) var id: String
    var merchantID: String
    var name: String
    var detail: String
    var coinCost: Int
    var stock: Int
    var isActive: Bool

    init(id: String, merchantID: String, name: String, detail: String, coinCost: Int, stock: Int) {
        self.id = id
        self.merchantID = merchantID
        self.name = name
        self.detail = detail
        self.coinCost = coinCost
        self.stock = stock
        self.isActive = true
    }
}

enum ParticipationStatus: String {
    case joined, departed, completed
    var label: String {
        switch self {
        case .joined: "已加入，待出發驗證"
        case .departed: "已出發，待到站驗證"
        case .completed: "已完成"
        }
    }
}

@Model
final class Participation {
    /// "\(missionID)|\(userID)"：同一人同一任務只能一筆
    @Attribute(.unique) var key: String
    var id: String
    var missionID: String
    var userID: String
    var status: String
    var joinedAt: Date
    var departedAt: Date?
    var completedAt: Date?
    /// 加入當下鎖定；之後管理者調整載客率不影響已加入的人
    var rewardAmount: Int
    var rewardExplanation: String
    var loadAtJoin: Double
    var isSimulated: Bool

    init(missionID: String, userID: String, rewardAmount: Int, rewardExplanation: String,
         loadAtJoin: Double, joinedAt: Date = .now, isSimulated: Bool = false) {
        self.key = "\(missionID)|\(userID)"
        self.id = UUID().uuidString
        self.missionID = missionID
        self.userID = userID
        self.status = ParticipationStatus.joined.rawValue
        self.joinedAt = joinedAt
        self.rewardAmount = rewardAmount
        self.rewardExplanation = rewardExplanation
        self.loadAtJoin = loadAtJoin
        self.isSimulated = isSimulated
    }

    var statusValue: ParticipationStatus { ParticipationStatus(rawValue: status) ?? .joined }
}

enum CheckinStage: String {
    case depart, arrive
    var label: String { self == .depart ? "出發驗證" : "到站驗證" }
}

@Model
final class Checkin {
    /// "\(participationID)|\(stage)"：同一任務同一階段只能成功一次
    @Attribute(.unique) var key: String
    var participationID: String
    var stage: String
    var stopSeq: Int
    var tokenNonce: String
    /// camera / demo（展示用模擬掃描）/ manual（定位失敗時人工通過）
    var method: String
    var lat: Double?
    var lon: Double?
    var distanceMeters: Double?
    var verifiedAt: Date

    init(participationID: String, stage: CheckinStage, stopSeq: Int, tokenNonce: String, method: String,
         lat: Double? = nil, lon: Double? = nil, distanceMeters: Double? = nil, verifiedAt: Date = .now) {
        self.key = "\(participationID)|\(stage.rawValue)"
        self.participationID = participationID
        self.stage = stage.rawValue
        self.stopSeq = stopSeq
        self.tokenNonce = tokenNonce
        self.method = method
        self.lat = lat
        self.lon = lon
        self.distanceMeters = distanceMeters
        self.verifiedAt = verifiedAt
    }
}

/// 點數帳本。只新增、不修改；餘額一律由這張表加總。
@Model
final class LedgerEntry {
    /// "\(referenceType)|\(referenceID)"：同一個來源只能入帳一次
    @Attribute(.unique) var key: String
    var userID: String
    var amount: Int
    var reason: String
    var referenceType: String
    var referenceID: String
    var expiresAt: Date
    var createdAt: Date
    var isSimulated: Bool

    init(userID: String, amount: Int, reason: String, referenceType: String, referenceID: String,
         expiresAt: Date, createdAt: Date = .now, isSimulated: Bool = false) {
        self.key = "\(referenceType)|\(referenceID)"
        self.userID = userID
        self.amount = amount
        self.reason = reason
        self.referenceType = referenceType
        self.referenceID = referenceID
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.isSimulated = isSimulated
    }
}

@Model
final class RedemptionToken {
    @Attribute(.unique) var id: String
    var userID: String
    var rewardID: String
    var merchantID: String
    /// 只存短碼的雜湊；短碼本身由簽章金鑰從 id 推導，旅客端隨時可重算顯示
    var codeHash: String
    var createdAt: Date
    var expiresAt: Date
    var usedAt: Date?
    var cancelledAt: Date?

    init(id: String, userID: String, rewardID: String, merchantID: String, codeHash: String,
         createdAt: Date = .now, expiresAt: Date) {
        self.id = id
        self.userID = userID
        self.rewardID = rewardID
        self.merchantID = merchantID
        self.codeHash = codeHash
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    func isUsable(at now: Date = .now) -> Bool {
        usedAt == nil && cancelledAt == nil && expiresAt > now
    }
}

@Model
final class Redemption {
    @Attribute(.unique) var idempotencyKey: String
    var id: String
    var userID: String
    var merchantID: String
    var rewardID: String
    var rewardName: String
    var coinAmount: Int
    /// success / failed
    var status: String
    var failureReason: String
    var tokenID: String
    var redeemedAt: Date
    var isSimulated: Bool

    init(idempotencyKey: String, userID: String, merchantID: String, rewardID: String, rewardName: String,
         coinAmount: Int, status: String, failureReason: String = "", tokenID: String,
         redeemedAt: Date = .now, isSimulated: Bool = false) {
        self.idempotencyKey = idempotencyKey
        self.id = UUID().uuidString
        self.userID = userID
        self.merchantID = merchantID
        self.rewardID = rewardID
        self.rewardName = rewardName
        self.coinAmount = coinAmount
        self.status = status
        self.failureReason = failureReason
        self.tokenID = tokenID
        self.redeemedAt = redeemedAt
        self.isSimulated = isSimulated
    }

    var isSuccess: Bool { status == "success" }
}

@Model
final class AuditLog {
    var id: String
    var actorID: String
    var action: String
    var targetType: String
    var targetID: String
    var detail: String
    var createdAt: Date

    init(actorID: String, action: String, targetType: String, targetID: String, detail: String) {
        self.id = UUID().uuidString
        self.actorID = actorID
        self.action = action
        self.targetType = targetType
        self.targetID = targetID
        self.detail = detail
        self.createdAt = .now
    }
}

enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        RouteStop.self, BusTrip.self, Mission.self, RuleConfig.self, Merchant.self, RewardItem.self,
        Participation.self, Checkin.self, LedgerEntry.self, RedemptionToken.self, Redemption.self, AuditLog.self,
    ]

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
