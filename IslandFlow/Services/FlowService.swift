import Foundation
import SwiftData

struct FlowError: LocalizedError, Equatable {
    enum Kind: Equatable { case general, location }
    var message: String
    var kind: Kind = .general
    var errorDescription: String? { message }

    static func msg(_ s: String) -> FlowError { FlowError(message: s) }
}

struct CheckinResult {
    var stage: CheckinStage
    var stopName: String
    var coinsAwarded: Int?
}

struct RedemptionPreview: Identifiable {
    var id: String { token.id }
    var token: RedemptionToken
    var item: RewardItem
    var userName: String
}

/// 所有會改資料的動作都集中在這裡，對應規格書的 API 一節。
/// 畫面只負責呼叫與顯示，不直接寫 LedgerEntry、Checkin、Redemption。
@MainActor
final class FlowService {
    let context: ModelContext
    var now: () -> Date = { .now }

    init(context: ModelContext) {
        self.context = context
    }

    static let routeCode = "BTZ"
    static let routeName = "台灣好行 北投竹子湖線"
    /// 旅綠幣是活動點數，示範活動結束即失效
    static let campaignEnd: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 12; c.day = 31; c.hour = 23; c.minute = 59
        return Calendar.current.date(from: c) ?? .distantFuture
    }()

    // MARK: 查詢

    func rules() -> RuleConfig {
        if let r = try? context.fetch(FetchDescriptor<RuleConfig>()).first { return r }
        let r = RuleConfig()
        context.insert(r)
        return r
    }

    func stops() -> [RouteStop] {
        (try? context.fetch(FetchDescriptor<RouteStop>(sortBy: [SortDescriptor(\.sequence)]))) ?? []
    }

    func stop(_ seq: Int) -> RouteStop? { stops().first { $0.sequence == seq } }
    func stopName(_ seq: Int) -> String { stop(seq)?.shortName ?? "第 \(seq) 站" }

    func trip(_ id: String) -> BusTrip? {
        try? context.fetch(FetchDescriptor<BusTrip>(predicate: #Predicate { $0.id == id })).first
    }

    func mission(_ id: String) -> Mission? {
        try? context.fetch(FetchDescriptor<Mission>(predicate: #Predicate { $0.id == id })).first
    }

    func merchant(_ id: String) -> Merchant? {
        try? context.fetch(FetchDescriptor<Merchant>(predicate: #Predicate { $0.id == id })).first
    }

    func item(_ id: String) -> RewardItem? {
        try? context.fetch(FetchDescriptor<RewardItem>(predicate: #Predicate { $0.id == id })).first
    }

    func participation(mission: String, user: String) -> Participation? {
        let key = "\(mission)|\(user)"
        return try? context.fetch(FetchDescriptor<Participation>(predicate: #Predicate { $0.key == key })).first
    }

    func distanceKm(_ m: Mission) -> Double {
        let path = stops().filter { $0.sequence >= min(m.startStopSeq, m.endStopSeq) && $0.sequence <= max(m.startStopSeq, m.endStopSeq) }
        return Geo.routeKm(stops: path.map { ($0.lat, $0.lon) }, detourFactor: rules().routeDetourFactor)
    }

    func fullRouteKm() -> Double {
        Geo.routeKm(stops: stops().map { ($0.lat, $0.lon) }, detourFactor: rules().routeDetourFactor)
    }

    /// 目的地站合作商家的剩餘兌換量，換算成 0~1 的接待量能
    func merchantCapacity(atStop seq: Int) -> Double {
        let ids = partnerMerchants(atStop: seq).map(\.id)
        let items = (try? context.fetch(FetchDescriptor<RewardItem>())) ?? []
        let stock = items.filter { ids.contains($0.merchantID) && $0.isActive }.reduce(0) { $0 + max(0, $1.stock) }
        return min(1, Double(stock) / 40)
    }

    func partnerMerchants(atStop seq: Int) -> [Merchant] {
        ((try? context.fetch(FetchDescriptor<Merchant>())) ?? []).filter { $0.stopSeq == seq && $0.isPartner }
    }

    func rewardInput(for m: Mission, overrideLoad: Double? = nil) -> RewardInput {
        let trip = trip(m.tripID)
        let dest = stop(m.endStopSeq)
        return RewardInput(
            predictedLoad: overrideLoad ?? trip?.predictedLoad ?? 0.5,
            isOffPeak: trip?.isOffPeak ?? false,
            destinationIsDiversionTarget: dest?.isDiversionTarget ?? false,
            destinationName: dest?.shortName ?? "",
            destinationSlack: dest?.destinationSlack ?? 0.5,
            merchantCapacity: merchantCapacity(atStop: m.endStopSeq),
            carbonBenefit: fullRouteKm() > 0 ? min(1, distanceKm(m) / fullRouteKm()) : 0.5
        )
    }

    func reward(for m: Mission, overrideLoad: Double? = nil) -> RewardResult {
        RewardEngine.compute(rewardInput(for: m, overrideLoad: overrideLoad), rules: RewardRules(rules()))
    }

    func joinedToday(_ m: Mission) -> Int {
        let id = m.id
        let start = Calendar.current.startOfDay(for: now())
        let d = FetchDescriptor<Participation>(predicate: #Predicate { $0.missionID == id && $0.joinedAt >= start })
        return (try? context.fetchCount(d)) ?? 0
    }

    func remaining(_ m: Mission) -> Int { max(0, m.capacity - joinedToday(m)) }

    func userJoinsToday(_ user: String) -> Int {
        let start = Calendar.current.startOfDay(for: now())
        let d = FetchDescriptor<Participation>(predicate: #Predicate { $0.userID == user && $0.joinedAt >= start })
        return (try? context.fetchCount(d)) ?? 0
    }

    func ledger(for user: String) -> [LedgerEntry] {
        let d = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.userID == user },
                                             sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(d)) ?? []
    }

    /// 餘額永遠由帳本加總，沒有任何地方存「餘額」這個欄位
    func balance(for user: String) -> Int {
        let t = now()
        return ledger(for: user).filter { $0.expiresAt > t }.reduce(0) { $0 + $1.amount }
    }

    /// 已產生但還沒核銷的兌換碼先圈存，避免同時開多張碼超用
    func held(for user: String, excluding tokenID: String? = nil) -> Int {
        let t = now()
        let tokens = (try? context.fetch(FetchDescriptor<RedemptionToken>(predicate: #Predicate { $0.userID == user }))) ?? []
        return tokens.filter { $0.isUsable(at: t) && $0.id != tokenID }.reduce(0) { sum, tok in
            sum + (item(tok.rewardID)?.coinCost ?? 0)
        }
    }

    func available(for user: String) -> Int { balance(for: user) - held(for: user) }

    // MARK: T03 加入任務

    @discardableResult
    func join(mission m: Mission, user: String) throws -> (Participation, alreadyJoined: Bool) {
        if let existing = participation(mission: m.id, user: user) {
            return (existing, true)
        }
        guard m.isActive else { throw FlowError.msg("這個任務目前暫停中") }
        guard let trip = trip(m.tripID), !trip.isCancelled else { throw FlowError.msg("班次已取消，任務停止發放新名額") }
        let r = rules()
        if r.enforceSchedule, let dep = departureDate(trip), now() > dep {
            throw FlowError.msg("\(trip.departure) 班次已發車，無法再加入")
        }
        guard userJoinsToday(user) < r.dailyMissionLimit else {
            throw FlowError.msg("每人每日最多參加 \(r.dailyMissionLimit) 個任務，明天再來")
        }
        guard remaining(m) > 0 else { throw FlowError.msg("這個任務今日名額已滿") }
        guard merchantCapacity(atStop: m.endStopSeq) > 0 else {
            throw FlowError.msg("目的地合作店家的兌換品已送完，暫停發放新名額")
        }
        let result = reward(for: m)
        let p = Participation(missionID: m.id, userID: user, rewardAmount: result.coins,
                              rewardExplanation: result.explanation, loadAtJoin: trip.predictedLoad, joinedAt: now())
        context.insert(p)
        audit(user, "join", "mission", m.id, "鎖定獎勵 \(result.coins) 枚")
        try context.save()
        return (p, false)
    }

    func leave(_ p: Participation, user: String) throws {
        guard p.statusValue == .joined else { throw FlowError.msg("已完成出發驗證，無法取消") }
        audit(user, "leave", "mission", p.missionID, "")
        context.delete(p)
        try context.save()
    }

    func departureDate(_ trip: BusTrip) -> Date? {
        let parts = trip.departure.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now())
    }

    // MARK: T04/T05 出發與到站驗證

    struct Location { var lat: Double; var lon: Double }

    func expectedStage(_ p: Participation) -> CheckinStage? {
        switch p.statusValue {
        case .joined: .depart
        case .departed: .arrive
        case .completed: nil
        }
    }

    func checkIn(raw: String, participation p: Participation, method: String,
                 location: Location? = nil, manualOverride: Bool = false) throws -> CheckinResult {
        do {
            return try performCheckIn(raw: raw, p: p, method: method, location: location, manualOverride: manualOverride)
        } catch let e as FlowError {
            audit(p.userID, "checkin_rejected", "participation", p.id, e.message)
            try? context.save()
            throw e
        } catch {
            let msg = error.localizedDescription
            audit(p.userID, "checkin_rejected", "participation", p.id, msg)
            try? context.save()
            throw FlowError.msg(msg)
        }
    }

    private func performCheckIn(raw: String, p: Participation, method: String,
                                location: Location?, manualOverride: Bool) throws -> CheckinResult {
        guard let m = mission(p.missionID), let trip = trip(m.tripID) else { throw FlowError.msg("找不到任務資料") }
        let token = try TokenSigner.verifyStation(raw, now: now())
        guard token.route == Self.routeCode else {
            throw FlowError.msg("這是其他路線的站牌碼，你參加的是\(Self.routeName)")
        }
        guard token.trip == trip.id else {
            let other = self.trip(token.trip)?.departure ?? token.trip
            throw FlowError.msg("這是 \(other) 班次的碼，你參加的是 \(trip.departure) 班次")
        }
        guard !trip.isCancelled else { throw FlowError.msg("班次已取消") }

        guard let stage = expectedStage(p) else {
            throw FlowError.msg("任務已完成，旅綠幣已入帳，不會重複發放")
        }
        let startName = stopName(m.startStopSeq), endName = stopName(m.endStopSeq)
        switch stage {
        case .depart:
            if token.stop == m.endStopSeq {
                throw FlowError.msg("還沒完成出發驗證，不能直接完成任務。請先在「\(startName)」掃描出發碼")
            }
            guard token.stop == m.startStopSeq else {
                throw FlowError.msg("這是「\(stopName(token.stop))」的碼，出發驗證要在「\(startName)」掃描")
            }
            let r = rules()
            if r.enforceSchedule, let dep = departureDate(trip) {
                let open = dep.addingTimeInterval(-15 * 60), close = dep.addingTimeInterval(30 * 60)
                guard now() >= open && now() <= close else {
                    throw FlowError.msg("不在出發驗證時間窗內（\(trip.departure) 前 15 分鐘到後 30 分鐘）")
                }
            }
        case .arrive:
            if token.stop == m.startStopSeq {
                throw FlowError.msg("重複掃描：出發驗證已完成，請在抵達「\(endName)」後掃描到站碼")
            }
            guard token.stop == m.endStopSeq else {
                throw FlowError.msg("這是「\(stopName(token.stop))」的碼，到站驗證要在「\(endName)」掃描")
            }
        }

        var distance: Double?
        var usedMethod = method
        let r = rules()
        if stage == .arrive, r.requireLocation {
            if manualOverride {
                usedMethod = "manual"
            } else {
                guard let loc = location, let dest = stop(m.endStopSeq) else {
                    throw FlowError(message: "無法取得定位，到站驗證需要確認你在「\(endName)」附近", kind: .location)
                }
                let d = Geo.distanceMeters(lat1: loc.lat, lon1: loc.lon, lat2: dest.lat, lon2: dest.lon)
                distance = d
                guard d <= r.locationRadius else {
                    throw FlowError(message: "你距離「\(endName)」約 \(Int(d)) 公尺，超過允許的 \(Int(r.locationRadius)) 公尺", kind: .location)
                }
            }
        }

        let key = "\(p.id)|\(stage.rawValue)"
        let existing = try context.fetchCount(FetchDescriptor<Checkin>(predicate: #Predicate { $0.key == key }))
        guard existing == 0 else { throw FlowError.msg("重複掃描：\(stage.label)已經完成過") }

        let t = now()
        context.insert(Checkin(participationID: p.id, stage: stage, stopSeq: token.stop, tokenNonce: token.nonce,
                               method: usedMethod, lat: location?.lat, lon: location?.lon, distanceMeters: distance,
                               verifiedAt: t))
        var awarded: Int?
        switch stage {
        case .depart:
            p.status = ParticipationStatus.departed.rawValue
            p.departedAt = t
        case .arrive:
            p.status = ParticipationStatus.completed.rawValue
            p.completedAt = t
            awarded = try award(p, missionTitle: m.title)
        }
        audit(p.userID, "checkin_\(stage.rawValue)", "participation", p.id, "方式：\(usedMethod)")
        try context.save()
        return CheckinResult(stage: stage, stopName: stage == .depart ? startName : endName, coinsAwarded: awarded)
    }

    /// 以參加紀錄 id 當帳本唯一鍵，就算這段被呼叫兩次也只會入帳一次
    private func award(_ p: Participation, missionTitle: String) throws -> Int? {
        let key = "participation|\(p.id)"
        let exists = try context.fetchCount(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.key == key }))
        guard exists == 0 else { return nil }
        context.insert(LedgerEntry(userID: p.userID, amount: p.rewardAmount, reason: "完成任務：\(missionTitle)",
                                   referenceType: "participation", referenceID: p.id,
                                   expiresAt: Self.campaignEnd, createdAt: now()))
        return p.rewardAmount
    }

    /// 展示用：產生「現在這一刻」某站的有效動態碼，等同拿相機掃站牌
    func currentStationToken(trip: String, stop: Int, now at: Date? = nil) -> String {
        TokenSigner.stationToken(route: Self.routeCode, trip: trip, stop: stop, ttl: rules().stationTokenTTL, now: at ?? now())
    }

    // MARK: T08 兌換憑證

    func createRedeemToken(user: String, item: RewardItem) throws -> RedemptionToken {
        guard let merchant = merchant(item.merchantID), merchant.isPartner else {
            throw FlowError.msg("這家店尚未加入合作，不能兌換")
        }
        guard item.isActive, item.stock > 0 else { throw FlowError.msg("「\(item.name)」已兌換完畢，暫停產生兌換碼") }
        let t = now()
        // 同一人同一品項只保留最新一張，舊的直接作廢
        let uid = user, rid = item.id
        let old = (try? context.fetch(FetchDescriptor<RedemptionToken>(predicate: #Predicate { $0.userID == uid && $0.rewardID == rid }))) ?? []
        for o in old where o.isUsable(at: t) { o.cancelledAt = t }
        guard available(for: user) >= item.coinCost else {
            throw FlowError.msg("可用旅綠幣不足（需要 \(item.coinCost) 枚，可用 \(max(0, available(for: user))) 枚）")
        }
        let id = UUID().uuidString
        let token = RedemptionToken(id: id, userID: user, rewardID: item.id, merchantID: merchant.id,
                                    codeHash: TokenSigner.hash(TokenSigner.shortCode(for: id)), createdAt: t,
                                    expiresAt: t.addingTimeInterval(TimeInterval(rules().redeemTokenTTL)))
        context.insert(token)
        audit(user, "redeem_token", "reward", item.id, "")
        try context.save()
        return token
    }

    func cancelToken(_ token: RedemptionToken) {
        guard token.usedAt == nil else { return }
        token.cancelledAt = now()
        try? context.save()
    }

    func payload(for token: RedemptionToken) -> String {
        TokenSigner.sign(RedeemToken(tid: token.id, exp: Int(token.expiresAt.timeIntervalSince1970)))
    }

    // MARK: M02 商家預覽

    func preview(input raw: String, merchantID: String) throws -> RedemptionPreview {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: RedemptionToken?
        if text.hasPrefix(TokenSigner.prefix + ".") {
            do {
                let payload = try TokenSigner.verifyRedeem(text, now: now())
                token = redemptionToken(payload.tid)
            } catch TokenError.expired {
                // 過期的碼仍然記一筆失敗，讓商家事後查得到原因
                if let tid = try? JSONDecoder().decode(RedeemToken.self, from: Data(base64URL: String(text.split(separator: ".")[1])) ?? Data()).tid,
                   let tok = redemptionToken(tid) {
                    recordFailure(tok, merchantID: merchantID, reason: "兌換碼已過期")
                }
                throw FlowError.msg("兌換碼已過期（有效 \(rules().redeemTokenTTL / 60) 分鐘），請旅客重新產生")
            }
        } else if text.count == 6, text.allSatisfy(\.isNumber) {
            let h = TokenSigner.hash(text)
            token = try? context.fetch(FetchDescriptor<RedemptionToken>(
                predicate: #Predicate { $0.codeHash == h },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)])).first
        } else {
            throw TokenError.malformed
        }
        guard let tok = token else { throw FlowError.msg("查無此兌換碼") }
        try validate(tok, merchantID: merchantID, recordFailures: true)
        guard let item = item(tok.rewardID) else { throw FlowError.msg("找不到兌換品項") }
        let name = DemoAccounts.find(tok.userID)?.name ?? "旅客"
        return RedemptionPreview(token: tok, item: item, userName: name)
    }

    func redemptionToken(_ id: String) -> RedemptionToken? {
        try? context.fetch(FetchDescriptor<RedemptionToken>(predicate: #Predicate { $0.id == id })).first
    }

    private func validate(_ tok: RedemptionToken, merchantID: String, recordFailures: Bool) throws {
        func fail(_ reason: String) -> FlowError {
            if recordFailures { recordFailure(tok, merchantID: merchantID, reason: reason) }
            return FlowError.msg(reason)
        }
        if tok.merchantID != merchantID {
            // 不寫進對方商家的紀錄，避免商家看到別家的交易
            throw FlowError.msg("這張兌換碼屬於「\(merchant(tok.merchantID)?.name ?? "其他商家")」，不能在本店核銷")
        }
        if let used = tok.usedAt {
            throw fail("此兌換碼已於 \(used.formatted(date: .omitted, time: .shortened)) 使用過，不能再次核銷")
        }
        if tok.cancelledAt != nil { throw fail("旅客已作廢這張兌換碼") }
        if tok.expiresAt <= now() { throw fail("兌換碼已過期，請旅客重新產生") }
    }

    private func recordFailure(_ tok: RedemptionToken, merchantID: String, reason: String) {
        let it = item(tok.rewardID)
        context.insert(Redemption(idempotencyKey: "fail|\(UUID().uuidString)", userID: tok.userID, merchantID: merchantID,
                                  rewardID: tok.rewardID, rewardName: it?.name ?? "", coinAmount: it?.coinCost ?? 0,
                                  status: "failed", failureReason: reason, tokenID: tok.id, redeemedAt: now()))
        try? context.save()
    }

    // MARK: M03 確認兌換

    /// 冪等：同一個 idempotencyKey 送幾次都只會有一筆成功交易，重送會拿回第一次的結果。
    func confirm(tokenID: String, merchantID: String, idempotencyKey: String) throws -> (Redemption, replayed: Bool) {
        let k = idempotencyKey
        if let existing = try context.fetch(FetchDescriptor<Redemption>(predicate: #Predicate { $0.idempotencyKey == k })).first {
            return (existing, true)
        }
        guard let tok = redemptionToken(tokenID) else { throw FlowError.msg("查無此兌換碼") }
        try validate(tok, merchantID: merchantID, recordFailures: true)
        guard let it = item(tok.rewardID) else { throw FlowError.msg("找不到兌換品項") }
        guard it.stock > 0 else {
            recordFailure(tok, merchantID: merchantID, reason: "品項已兌換完畢")
            throw FlowError.msg("「\(it.name)」已兌換完畢")
        }
        guard balance(for: tok.userID) >= it.coinCost else {
            recordFailure(tok, merchantID: merchantID, reason: "旅客旅綠幣不足")
            throw FlowError.msg("旅客旅綠幣不足")
        }

        let t = now()
        let r = Redemption(idempotencyKey: idempotencyKey, userID: tok.userID, merchantID: merchantID, rewardID: it.id,
                           rewardName: it.name, coinAmount: it.coinCost, status: "success", tokenID: tok.id, redeemedAt: t)
        // 扣點、扣庫存、作廢憑證、寫核銷紀錄放在同一個交易，任何一步失敗全部不生效
        try context.transaction {
            context.insert(r)
            context.insert(LedgerEntry(userID: tok.userID, amount: -it.coinCost, reason: "兌換：\(it.name)",
                                       referenceType: "redemption", referenceID: r.id,
                                       expiresAt: Self.campaignEnd, createdAt: t))
            it.stock -= 1
            tok.usedAt = t
            audit(merchantID, "redeem_confirm", "redemption", r.id, "\(it.name) −\(it.coinCost)")
        }
        return (r, false)
    }

    // MARK: 稽核

    func audit(_ actor: String, _ action: String, _ type: String, _ target: String, _ detail: String) {
        context.insert(AuditLog(actorID: actor, action: action, targetType: type, targetID: target, detail: detail))
    }
}
