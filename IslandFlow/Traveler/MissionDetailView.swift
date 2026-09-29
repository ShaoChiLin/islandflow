import SwiftUI
import SwiftData
import MapKit

// MARK: T02 任務詳情 ＋ T03 加入任務 ＋ 任務進行中
//
// 首屏順序固定：目的地與發車時間 → 可得旅綠幣 → 三步驟；主要按鈕固定在底部，依狀態只出現一個動作。
// 地圖、獎勵算法、載客率數字、注意事項都收進可展開區，旅客想看再看。

struct MissionDetailView: View {
    let mission: Mission
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Environment(TravelerRouter.self) private var router
    @Query private var parts: [Participation]
    @Query private var trips: [BusTrip]
    @Query private var rules: [RuleConfig]
    @Query private var items: [RewardItem]
    @State private var error: String?
    @State private var notice: String?
    @State private var scanning = false
    @State private var countedView = false

    init(mission: Mission, account: DemoAccount) {
        self.mission = mission
        self.account = account
        let key = "\(mission.id)|\(account.id)"
        _parts = Query(filter: #Predicate<Participation> { $0.key == key })
    }

    private var service: FlowService { FlowService(context: context) }
    private var participation: Participation? { parts.first }

    var body: some View {
        let trip = service.trip(mission.tripID)
        let result = service.reward(for: mission)
        let tier = RewardEngine.tier(for: trip?.predictedLoad ?? 0, rules: RewardRules(service.rules()))
        let from = service.stopName(mission.startStopSeq), to = service.stopName(mission.endStopSeq)
        let redeemable = RedeemCatalog.items(atStop: mission.endStopSeq, service: service).filter { $0.stock > 0 }

        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(mission.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
                    Text("前往\(to)").font(.largeTitle.bold())
                    Label("\(trip?.departure ?? "--:--") 從\(from)出發", systemImage: "clock")
                        .font(.subheadline)
                    // 標籤另起一排：和時間擠同一排會把站名從中間折行
                    AdaptiveStack {
                        DemoBadge(text: "示範班次")
                        ComfortChip(tier: tier, short: true)
                    }
                    Text(mission.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }

                Card {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center) { coinBlock(result.coins); Spacer(minLength: Space.m); nearbyBlock(to, redeemable.count, alignTrailing: true) }
                        VStack(alignment: .leading, spacing: Space.s) { coinBlock(result.coins); nearbyBlock(to, redeemable.count, alignTrailing: false) }
                    }
                    Divider()
                    let emission = service.segmentEmission(mission)
                    Label(EmissionText.summary(km: emission.km, kg: emission.kg) + "（示範係數）", systemImage: "leaf")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("mission-emission-summary")
                }

                stepsCard(trip: trip, from: from, to: to)

                BoardingInfoCard(from: service.stop(mission.startStopSeq), departure: trip?.departure)

                if let error { ErrorBanner(message: error) }
                if let notice {
                    Label(notice, systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
                }

                moreInfo(trip: trip, result: result, redeemable: redeemable)
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xl)
        }
        .background(Color.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $scanning) {
            if let p = participation {
                CheckinSheet(participation: p, mission: mission, account: account)
            }
        }
        .onAppear {
            // 任務瀏覽數是「參加率」的分母；同一次進頁面只算一次
            guard !countedView else { return }
            countedView = true
            mission.viewCount += 1
            try? context.save()
        }
    }

    private func coinBlock(_ coins: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(participation == nil ? "完成可得" : "已為你鎖定").font(.caption).foregroundStyle(.secondary)
            CoinLabel(amount: participation?.rewardAmount ?? coins, font: .largeTitle)
        }
    }

    private func nearbyBlock(_ to: String, _ count: Int, alignTrailing: Bool) -> some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 2) {
            Text("\(to)站附近").font(.caption).foregroundStyle(.secondary)
            Text(count > 0 ? "兌換品 \(count) 項" : "兌換品已換完").font(.headline)
        }
    }

    private func stepsCard(trip: BusTrip?, from: String, to: String) -> some View {
        let s = participation?.statusValue
        let coins = participation?.rewardAmount ?? service.reward(for: mission).coins
        return Card {
            Text(participation == nil ? "加入後三個步驟" : "任務進度").font(.headline)
            StepRow(n: 1, title: "在「\(from)」掃出發碼",
                    detail: participation?.departedAt.map { "已完成 \(Fmt.time($0))" } ?? "搭 \(trip?.departure ?? "") 班次上車前掃站牌",
                    done: s == .departed || s == .completed)
            StepRow(n: 2, title: "到「\(to)」掃到站碼",
                    detail: participation?.completedAt.map { "已完成 \(Fmt.time($0))" } ?? "下車後掃站牌",
                    done: s == .completed)
            StepRow(n: 3, title: "領 \(coins) 枚，到店兌換",
                    detail: s == .completed ? "已入帳，可以去兌換了" : "兩次掃碼都完成就自動入帳",
                    done: s == .completed)
        }
    }

    private func moreInfo(trip: BusTrip?, result: RewardResult, redeemable: [RewardItem]) -> some View {
        Card {
            DisclosureGroup("路線地圖") {
                RouteMap(highlightFrom: mission.startStopSeq, to: mission.endStopSeq)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    .padding(.top, Space.s)
            }
            Divider()
            DisclosureGroup("旅綠幣怎麼算") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(result.lines) { line in
                        HStack(alignment: .top) {
                            Text(line.text)
                            Spacer()
                            if let c = line.coins { Text(c >= 0 ? "+\(c)" : "\(c)").monospacedDigit() }
                        }
                    }
                    if let p = participation {
                        Text("你加入時已鎖定 \(p.rewardAmount) 枚，之後不會因班次變化而減少。")
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: Space.xs) {
                        Text("載客率為預估值")
                        DemoBadge()
                    }
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.top, Space.s)
            }
            Divider()
            DisclosureGroup("交通排放怎麼估") {
                EmissionMethodNote(factor: service.busEmissionFactor())
                    .padding(.top, Space.s)
            }
            Divider()
            DisclosureGroup("可兌換品項") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(redeemable) { it in
                        HStack {
                            Text(it.name)
                            Spacer()
                            Text("\(it.coinCost) 枚").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if redeemable.isEmpty { Text("今日已換完").foregroundStyle(.secondary) }
                    if redeemable.contains(where: { service.merchant($0.merchantID)?.isFictional == true }) {
                        Text("以上為示範店家，尚未提供真實兌換；營業資訊待確認。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                .padding(.top, Space.s)
            }
            Divider()
            DisclosureGroup("注意事項") {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("・今日剩 \(service.remaining(mission)) / \(mission.capacity) 個名額")
                    Text("・每人每天最多參加 \(service.rules().dailyMissionLimit) 個任務")
                    Text("・站牌上的碼每 30 秒更新，請現場掃描")
                    Text("・旅綠幣不能買賣、轉讓或換現金，\(FlowService.campaignEnd.formatted(date: .abbreviated, time: .omitted)) 到期")
                    if !mission.notes.isEmpty { Text("・\(mission.notes)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, Space.s)
            }
        }
        .font(.subheadline.weight(.medium))
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            Group {
                if let p = participation {
                    switch p.statusValue {
                    case .joined:
                        Button { scanning = true } label: { Label("掃描出發碼", systemImage: "qrcode.viewfinder") }
                    case .departed:
                        Button { scanning = true } label: { Label("掃描到站碼", systemImage: "qrcode.viewfinder") }
                    case .completed:
                        Button { router.goRedeem(stop: mission.endStopSeq) } label: { Label("前往兌換", systemImage: "basket") }
                    }
                } else {
                    Button(action: join) { Label("加入任務", systemImage: "plus.circle.fill") }
                }
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("mission-primary-action")
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
        }
        .background(.bar)
    }

    private func join() {
        error = nil
        do {
            let (_, already) = try service.join(mission: mission, user: account.id)
            notice = already ? "你已經加入過這個任務了" : nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

struct StepRow: View {
    var n: Int
    var title: String
    var detail: String
    var done = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            ZStack {
                Circle().fill(done ? Color.brand : Color.secondary.opacity(0.18)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.caption.bold())
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "已完成" : "未完成")
    }
}

/// 管理端用的完整獎勵拆解（旅客端改放在可展開區）
struct RewardBreakdownCard: View {
    let result: RewardResult
    var title = "獎勵計算"

    var body: some View {
        Card {
            HStack {
                Text(title).font(.headline)
                Spacer()
                CoinLabel(amount: result.coins, font: .title2)
            }
            ForEach(result.lines) { line in
                HStack(alignment: .top) {
                    Text(line.text).font(.subheadline)
                    Spacer()
                    if let c = line.coins {
                        Text(c >= 0 ? "+\(c)" : "\(c)").monospacedDigit().font(.subheadline.weight(.semibold))
                    }
                }
            }
            Text("規則可解釋、不使用預測模型；管理端可調整門檻與加碼。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: 路線地圖

struct RouteMap: View {
    var highlightFrom: Int? = nil
    var to: Int? = nil
    @Query(sort: \RouteStop.sequence) private var stops: [RouteStop]
    @Query private var merchants: [Merchant]

    var body: some View {
        Map(initialPosition: .automatic) {
            MapPolyline(coordinates: stops.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                .stroke(Color.secondary.opacity(0.5), lineWidth: 3)
            if let a = highlightFrom, let b = to {
                MapPolyline(coordinates: stops.filter { $0.sequence >= min(a, b) && $0.sequence <= max(a, b) }
                    .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                    .stroke(Color.brand, lineWidth: 5)
            }
            ForEach(stops) { s in
                Annotation(s.shortName, coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)) {
                    ZStack {
                        Circle().fill(s.isDiversionTarget ? Color.orange : Color.brand).frame(width: 18, height: 18)
                        Text("\(s.sequence)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
            }
            ForEach(merchants.filter(\.isPartner)) { m in
                Marker(m.name, systemImage: m.symbol, coordinate: CLLocationCoordinate2D(latitude: m.lat, longitude: m.lon))
                    .tint(Color.coin)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}
