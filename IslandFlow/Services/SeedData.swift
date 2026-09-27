import Foundation
import SwiftData

/// 種子資料。
/// - 站點：直接讀 App 內附的開放資料 93967（真實資料）
/// - 班次載客率、商家、過去 14 天的參加與核銷：全部是模擬資料，畫面上一律標「示範資料」
@MainActor
enum SeedData {
    static let shortNames: [String: String] = [
        "北投溫泉博物館、梅庭、地熱谷(北投公園)": "北投公園",
        "硫磺谷(彌陀寺)": "硫磺谷",
        "陽明公園、花鐘(陽明公園服務中心)": "陽明公園花鐘",
        "草山行館(陽明山立體停車場)": "草山行館",
        "公車轉乘站(陽明山)": "陽明山轉乘站",
        "陽明山國家公園遊客中心(陽明山國家公園管理處)": "遊客中心",
    ]

    static func seedIfNeeded(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<RouteStop>())) ?? 0
        if count == 0 { seed(context) }
    }

    static func reset(_ context: ModelContext) {
        for type in AppSchema.models {
            try? context.delete(model: type)
        }
        try? context.save()
        seed(context)
    }

    static func seed(_ context: ModelContext, now: Date = .now, stopRows: [OpenData.StopRow]? = nil) {
        let route = FlowService.routeCode
        for row in stopRows ?? OpenData.outboundStops {
            context.insert(RouteStop(
                routeCode: route, sequence: row.sequence, name: row.name,
                shortName: shortNames[row.name] ?? row.name, lat: row.lat, lon: row.lon,
                isDiversionTarget: row.name == "陽明書屋",
                destinationSlack: row.name == "竹子湖" ? 0.45 : (row.name == "陽明書屋" ? 0.85 : 0.6)))
        }

        context.insert(RuleConfig())

        // 09:10 是尖峰對照組，不開任務；另外兩班是平日離峰
        context.insert(BusTrip(id: "T0910", routeCode: route, departure: "09:10", predictedLoad: 1.42, isOffPeak: false))
        context.insert(BusTrip(id: "T1040", routeCode: route, departure: "10:40", predictedLoad: 0.28, isOffPeak: true))
        context.insert(BusTrip(id: "T1310", routeCode: route, departure: "13:10", predictedLoad: 0.52, isOffPeak: true))

        let missionA = Mission(id: "M-A", tripID: "T1040", title: "竹子湖小農早市任務",
                               subtitle: "搭離峰班次上山，到湖田小農市集換當季高冷蔬菜",
                               startStopSeq: 1, endStopSeq: 9, capacity: 30,
                               notes: "請在捷運北投站站牌掃描出發碼，抵達竹子湖站牌後掃描到站碼。")
        let missionB = Mission(id: "M-B", tripID: "T1310", title: "陽明書屋山嵐茶席任務",
                               subtitle: "避開竹子湖人潮，到陽明書屋喝一壺山茶",
                               startStopSeq: 1, endStopSeq: 8, capacity: 25,
                               notes: "陽明書屋為本期指定分流站點。請在捷運北投站掃描出發碼，抵達陽明書屋後掃描到站碼。")
        context.insert(missionA)
        context.insert(missionB)

        let stops = stopRows ?? OpenData.outboundStops
        func coord(_ seq: Int) -> (Double, Double) {
            let s = stops.first { $0.sequence == seq }
            return (s?.lat ?? 25.17, s?.lon ?? 121.53)
        }
        let lake = coord(9), tea = coord(8), onsen = coord(2)
        let merchants = [
            Merchant(id: "m-lake", name: "湖田小農市集", stopSeq: 9, address: "竹子湖站旁（虛構）",
                     lat: lake.0 + 0.0008, lon: lake.1 + 0.0006, isPartner: true, isFictional: true,
                     hours: "09:00–16:00", intro: "竹子湖在地小農聯合攤位，販售高冷蔬菜與季節花卉。", symbol: "leaf"),
            Merchant(id: "m-tea", name: "山嵐茶屋", stopSeq: 8, address: "陽明書屋站步行 3 分鐘（虛構）",
                     lat: tea.0 + 0.0005, lon: tea.1 - 0.0007, isPartner: true, isFictional: true,
                     hours: "10:00–17:00", intro: "以陽明山在地茶葉為主的小茶屋。", symbol: "cup.and.saucer"),
            Merchant(id: "m-onsen", name: "湯守咖啡", stopSeq: 2, address: "北投公園站旁（虛構）",
                     lat: onsen.0 + 0.0004, lon: onsen.1 + 0.0005, isPartner: true, isFictional: true,
                     hours: "08:00–18:00", intro: "北投溫泉區的社區咖啡店，提供溫泉蛋。", symbol: "cup.and.heat.waves"),
            Merchant(id: "m-candidate", name: "竹子湖野菜餐廳", stopSeq: 9, address: "竹子湖（候選店家）",
                     lat: lake.0 - 0.0010, lon: lake.1 + 0.0012, isPartner: false, isFictional: true,
                     hours: "—", intro: "開放資料收錄的地點不代表已合作；此店尚未洽談，不能兌換。", symbol: "fork.knife"),
        ]
        merchants.forEach(context.insert)

        let items = [
            RewardItem(id: "r-veg", merchantID: "m-lake", name: "當季高冷蔬菜包", detail: "約 600 公克，依當日採收", coinCost: 80, stock: 20),
            RewardItem(id: "r-calla", merchantID: "m-lake", name: "海芋小花束", detail: "三支入，季節限定", coinCost: 60, stock: 15),
            RewardItem(id: "r-tea", merchantID: "m-tea", name: "陽明山茶一壺", detail: "內用，可回沖兩次", coinCost: 50, stock: 20),
            RewardItem(id: "r-snack", merchantID: "m-tea", name: "手作茶點", detail: "當日現做", coinCost: 30, stock: 30),
            RewardItem(id: "r-egg", merchantID: "m-onsen", name: "溫泉蛋兩顆", detail: "北投溫泉水煮", coinCost: 30, stock: 40),
            RewardItem(id: "r-coffee", merchantID: "m-onsen", name: "手沖咖啡折抵 50 元", detail: "限單杯", coinCost: 60, stock: 25),
        ]
        items.forEach(context.insert)

        seedHistory(context, now: now, missions: [missionA, missionB], items: items)
        try? context.save()
    }

    /// 過去 14 天的模擬參加紀錄，讓儀表板一打開就有趨勢可看。用固定亂數種子，每次重置長得一樣。
    private static func seedHistory(_ context: ModelContext, now: Date, missions: [Mission], items: [RewardItem]) {
        var rng = SeededRNG(seed: 20261005)
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let itemsByStop: [Int: [RewardItem]] = [
            9: items.filter { $0.merchantID == "m-lake" },
            8: items.filter { $0.merchantID == "m-tea" },
        ]
        let rewards: [String: Int] = ["M-A": 100, "M-B": 80]
        var views: [String: Int] = [:]

        for dayOffset in 1...14 {
            guard let day = cal.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            // 越近期參加越多，呈現「任務上線後逐步成長」
            let growth = Double(15 - dayOffset) / 14
            for m in missions {
                let joins = Int(4 + growth * 8) + Int(rng.next() % 4)
                views[m.id, default: 0] += joins * 3 + Int(rng.next() % 10)
                for i in 0..<joins {
                    let user = "sim-\(m.id)-\(dayOffset)-\(i)"
                    let joinedAt = day.addingTimeInterval(8 * 3600 + Double(rng.next() % 7200))
                    let reward = rewards[m.id] ?? 60
                    let p = Participation(missionID: m.id, userID: user, rewardAmount: reward,
                                          rewardExplanation: "（示範資料）", loadAtJoin: 0.4,
                                          joinedAt: joinedAt, isSimulated: true)
                    context.insert(p)
                    guard rng.chance(0.8) else { continue }
                    let done = joinedAt.addingTimeInterval(2 * 3600)
                    p.status = ParticipationStatus.completed.rawValue
                    p.departedAt = joinedAt.addingTimeInterval(3600)
                    p.completedAt = done
                    context.insert(LedgerEntry(userID: user, amount: reward, reason: "完成任務（示範資料）",
                                               referenceType: "participation", referenceID: p.id,
                                               expiresAt: FlowService.campaignEnd, createdAt: done, isSimulated: true))
                    guard rng.chance(0.65), let pool = itemsByStop[m.endStopSeq], !pool.isEmpty else { continue }
                    let it = pool[Int(rng.next() % UInt64(pool.count))]
                    let at = done.addingTimeInterval(1800)
                    let r = Redemption(idempotencyKey: "sim|\(p.id)", userID: user, merchantID: it.merchantID,
                                       rewardID: it.id, rewardName: it.name, coinAmount: it.coinCost, status: "success",
                                       tokenID: "sim", redeemedAt: at, isSimulated: true)
                    context.insert(r)
                    context.insert(LedgerEntry(userID: user, amount: -it.coinCost, reason: "兌換（示範資料）",
                                               referenceType: "redemption", referenceID: r.id,
                                               expiresAt: FlowService.campaignEnd, createdAt: at, isSimulated: true))
                }
            }
        }
        for m in missions { m.viewCount = views[m.id] ?? 0 }
    }
}

struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
}
