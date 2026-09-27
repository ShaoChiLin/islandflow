import SwiftUI
import SwiftData

@Observable
final class TravelerRouter {
    enum Tab: Int { case explore = 0, trips = 1, coins = 2 }

    var tab: Tab = Tab(rawValue: LaunchArgs.startTab) ?? .explore
    /// 任務完成後按「去兌換」，綠幣中心會把這一站排到「目前站附近」
    var focusStop: Int?
    /// 從任務完成畫面直接點商品時帶過去，綠幣中心一出現就打開兌換確認頁（完成後兩次點擊內拿到 QR）
    var pendingRedeemItemID: String?

    func goRedeem(stop: Int?, itemID: String? = nil) {
        focusStop = stop
        pendingRedeemItemID = itemID
        tab = .coins
    }
}

struct TravelerRoot: View {
    let account: DemoAccount
    @State private var router = TravelerRouter()

    var body: some View {
        TabView(selection: $router.tab) {
            ExploreView(account: account)
                .tabItem { Label("探索", systemImage: "map") }.tag(TravelerRouter.Tab.explore)
            MyTripsView(account: account)
                .tabItem { Label("行程", systemImage: "ticket") }.tag(TravelerRouter.Tab.trips)
            GreenCoinHubView(account: account)
                .tabItem { Label("綠幣", systemImage: "leaf.circle") }.tag(TravelerRouter.Tab.coins)
        }
        .environment(router)
    }
}

/// 首頁一張卡需要的資料，集中算一次
struct MissionOption: Identifiable {
    var id: String { mission.id }
    var mission: Mission
    var trip: BusTrip
    var coins: Int
    var tier: LoadTier
    var from: String
    var to: String
    var remaining: Int
    var featuredItem: String?
    var participation: Participation?
}

@MainActor
enum MissionOptions {
    static func build(_ service: FlowService, missions: [Mission], user: String) -> [MissionOption] {
        let rules = RewardRules(service.rules())
        return missions.filter(\.isActive).compactMap { m -> MissionOption? in
            guard let trip = service.trip(m.tripID), !trip.isCancelled else { return nil }
            let items = service.partnerMerchants(atStop: m.endStopSeq).flatMap { merchant in
                ((try? service.context.fetch(FetchDescriptor<RewardItem>())) ?? [])
                    .filter { $0.merchantID == merchant.id && $0.isActive && $0.stock > 0 }
            }
            return MissionOption(
                mission: m, trip: trip, coins: service.reward(for: m).coins,
                tier: RewardEngine.tier(for: trip.predictedLoad, rules: rules),
                from: service.stopName(m.startStopSeq), to: service.stopName(m.endStopSeq),
                remaining: service.remaining(m),
                featuredItem: items.max { $0.coinCost < $1.coinCost }?.name,
                participation: service.participation(mission: m.id, user: user))
        }
        // 獎勵最高的排第一當推薦；同分時早班優先
        .sorted { ($0.coins, $1.trip.departure) > ($1.coins, $0.trip.departure) }
    }
}

// MARK: 探索（T01）

struct ExploreView: View {
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Environment(TravelerRouter.self) private var router
    // 這些 @Query 讓管理端調載客率、有人加入任務時首頁立刻重算
    @Query(sort: \BusTrip.departure) private var trips: [BusTrip]
    @Query private var missions: [Mission]
    @Query private var rules: [RuleConfig]
    @Query private var items: [RewardItem]
    @Query private var parts: [Participation]
    @State private var path: [String] = LaunchArgs.value("open-mission").map { [$0] } ?? []
    @State private var showDemoMenu = false

    init(account: DemoAccount) {
        self.account = account
        let uid = account.id
        _parts = Query(filter: #Predicate<Participation> { $0.userID == uid })
    }

    var body: some View {
        let service = FlowService(context: context)
        let options = MissionOptions.build(service, missions: missions, user: account.id)
        let peakTrips = trips.filter { t in !missions.contains { $0.tripID == t.id && $0.isActive } }
        let active = parts.first { $0.statusValue != .completed }

        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    header
                    if let active, let m = missions.first(where: { $0.id == active.missionID }) {
                        ActiveTripBanner(participation: active, destination: service.stopName(m.endStopSeq)) {
                            router.tab = .trips
                        }
                    }
                    if let best = options.first {
                        RecommendedCard(option: best) { path.append(best.id) }
                    }
                    if options.count > 1 || !peakTrips.isEmpty {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text("其他班次").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(options.dropFirst()) { o in
                                CompareRow(option: o, bestCoins: options.first?.coins ?? o.coins) { path.append(o.id) }
                            }
                            ForEach(peakTrips) { t in
                                PeakRow(trip: t, tier: RewardEngine.tier(for: t.predictedLoad, rules: RewardRules(service.rules())))
                            }
                        }
                    }
                    if options.isEmpty {
                        ContentUnavailableView("今天沒有任務", systemImage: "bus", description: Text("晚點再回來看看"))
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.xl)
            }
            .background(Color.canvas)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                if let m = missions.first(where: { $0.id == id }) {
                    MissionDetailView(mission: m, account: account)
                }
            }
            .sheet(isPresented: $showDemoMenu) { DemoMenuSheet() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Image(systemName: "leaf.circle.fill").foregroundStyle(Color.coin)
                Text("島流旅綠幣").foregroundStyle(Color.brand)
            }
            .font(.subheadline.weight(.semibold))
            // 隱藏的展示選單入口：長按品牌名稱
            .onLongPressGesture(minimumDuration: 0.8) { showDemoMenu = true }
            .accessibilityIdentifier("brand-demo-entry")
            Text("今天搭哪班上山？").font(.largeTitle.bold())
            Text("台灣好行北投竹子湖線・\(Date.now.formatted(.dateTime.month().day().weekday()))")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.top, Space.s)
    }
}

private struct ActiveTripBanner: View {
    let participation: Participation
    let destination: String
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.m) {
                Image(systemName: "figure.walk.motion")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.brand, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("進行中：前往\(destination)").font(.subheadline.weight(.semibold))
                    Text(participation.statusValue == .joined ? "下一步：在起點掃出發碼" : "下一步：到站後掃到站碼")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("繼續").font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
            }
            .padding(Space.m)
            .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("active-trip-banner")
    }
}

private struct RecommendedCard: View {
    let option: MissionOption
    var onOpen: () -> Void

    var body: some View {
        Card {
            AdaptiveStack {
                Label("推薦・獎勵最高", systemImage: "star.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brand)
                HSpacer()
                ComfortChip(tier: option.tier)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom) { timeBlock; Spacer(minLength: Space.m); coinBlock }
                VStack(alignment: .leading, spacing: Space.s) { timeBlock; coinBlock }
            }
            Divider()
            VStack(alignment: .leading, spacing: Space.xs) {
                if let item = option.featuredItem {
                    Label("可換：\(item)", systemImage: "basket")
                }
                Label(option.participation.map { "你已加入・\($0.statusValue == .completed ? "已完成" : "進行中")" }
                      ?? "今日剩 \(option.remaining) 個名額", systemImage: "person.2")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Button("查看任務", action: onOpen)
                .buttonStyle(.primary)
                .accessibilityIdentifier("recommended-view-mission")
        }
    }

    private var timeBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(option.trip.departure)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("\(option.from) → \(option.to)").font(.headline)
        }
    }

    private var coinBlock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("完成可得").font(.caption).foregroundStyle(.secondary)
            CoinLabel(amount: option.coins, font: .title)
        }
    }
}

private struct CompareRow: View {
    let option: MissionOption
    let bestCoins: Int
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            AdaptiveStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Text(option.trip.departure).font(.title3.bold()).monospacedDigit()
                        Text("→ \(option.to)").font(.subheadline.weight(.medium))
                    }
                    AdaptiveStack {
                        ComfortChip(tier: option.tier, short: true)
                        if bestCoins > option.coins {
                            Text("比推薦少 \(bestCoins - option.coins) 枚").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HSpacer()
                VStack(alignment: .trailing, spacing: Space.xs) {
                    CoinLabel(amount: option.coins, font: .headline)
                    Text("查看任務").font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
                }
            }
            .padding(Space.m)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(option.trip.departure) 往\(option.to)，\(option.tier.comfortLabel)，可得 \(option.coins) 枚")
        .accessibilityHint("查看任務")
        .accessibilityIdentifier("compare-\(option.id)")
    }
}

/// 沒有任務的尖峰班次也列出來，讓旅客看懂「改搭別班才有獎勵」
private struct PeakRow: View {
    let trip: BusTrip
    let tier: LoadTier

    var body: some View {
        AdaptiveStack(spacing: Space.m) {
            Text(trip.departure).font(.title3.bold()).monospacedDigit().foregroundStyle(.secondary)
            ComfortChip(tier: tier, short: true)
            HSpacer()
            Text("此班無旅綠幣").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .accessibilityElement(children: .combine)
    }
}
