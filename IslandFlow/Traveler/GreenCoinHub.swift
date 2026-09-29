import SwiftUI
import SwiftData

/// 旅客看得到的兌換目錄：只有已合作店家（isPartner）的上架品項。
/// 候選店家、「開放資料收錄不代表合作」這類說明只留在管理端。
@MainActor
enum RedeemCatalog {
    enum Status: Equatable {
        case available
        case short(Int)
        case soldOut

        /// 只判斷點數與庫存；店家營業狀態無法確認，所以不寫「現在可兌換」
        var label: String {
            switch self {
            case .available: "點數足夠"
            case .short(let n): "還差 \(n) 枚"
            case .soldOut: "今日已換完"
            }
        }

        var color: Color {
            switch self {
            case .available: .brand
            case .short: .secondary
            case .soldOut: .orange
            }
        }
    }

    static func status(_ item: RewardItem, available: Int) -> Status {
        if item.stock <= 0 { return .soldOut }
        if available < item.coinCost { return .short(item.coinCost - available) }
        return .available
    }

    static func items(atStop seq: Int, service: FlowService) -> [RewardItem] {
        let ids = Set(service.partnerMerchants(atStop: seq).map(\.id))
        return ((try? service.context.fetch(FetchDescriptor<RewardItem>(sortBy: [SortDescriptor(\.coinCost)]))) ?? [])
            .filter { ids.contains($0.merchantID) && $0.isActive }
    }

    /// 站牌到店家的直線距離、每分鐘 75 公尺換算；山區實際步行可能更久，畫面一律標「粗估」
    static func walkMinutes(_ m: Merchant, service: FlowService) -> Int? {
        guard let s = service.stop(m.stopSeq) else { return nil }
        let d = Geo.distanceMeters(lat1: m.lat, lon1: m.lon, lat2: s.lat, lon2: s.lon)
        return max(1, Int((d / 75).rounded(.up)))
    }
}

// MARK: 綠幣中心（原本的「錢包」＋「兌換」）

struct GreenCoinHubView: View {
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Environment(TravelerRouter.self) private var router
    @Query(sort: \Merchant.stopSeq, order: .reverse) private var merchants: [Merchant]
    @Query(sort: \RewardItem.coinCost) private var items: [RewardItem]
    @Query private var entries: [LedgerEntry]
    @Query private var tokens: [RedemptionToken]
    @Query private var parts: [Participation]
    @State private var redeeming: RewardItem?

    init(account: DemoAccount) {
        self.account = account
        let uid = account.id
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.userID == uid })
        _tokens = Query(filter: #Predicate<RedemptionToken> { $0.userID == uid })
        _parts = Query(filter: #Predicate<Participation> { $0.userID == uid }, sort: \Participation.joinedAt, order: .reverse)
    }

    var body: some View {
        let service = FlowService(context: context)
        let available = service.available(for: account.id)
        let held = service.held(for: account.id)
        let partners = merchants.filter(\.isPartner)
        let partnerIDs = Set(partners.map(\.id))
        let catalog = items.filter { partnerIDs.contains($0.merchantID) && $0.isActive }
        // 沒有用即時定位：焦點是剛完成（或最近完成）任務的終點站
        let focus = router.focusStop ?? lastCompletedStop
        let nearby = partners.filter { $0.stopSeq == focus }
        let others = partners.filter { $0.stopSeq != focus }
        let nearbyIDs = Set(nearby.map(\.id))

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    BalanceCard(available: available, held: held)
                    progressLine(catalog: catalog, available: available,
                                 focus: focus.map { (service.stopName($0), catalog.filter { nearbyIDs.contains($0.merchantID) }) })

                    if !nearby.isEmpty, let focus {
                        section("任務終點附近・\(service.stopName(focus))") {
                            ForEach(nearby) { merchantBlock($0, available: available, service: service) }
                        }
                    }
                    section(nearby.isEmpty ? "沿線可兌換" : "沿線其他店家") {
                        ForEach(others) { merchantBlock($0, available: available, service: service) }
                    }

                    NavigationLink {
                        LedgerHistoryView(account: account)
                    } label: {
                        HStack {
                            Label("使用紀錄", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(Space.l)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.xl)
            }
            .background(Color.canvas)
            .navigationTitle("綠幣")
            .sheet(item: $redeeming) { RedeemFlowSheet(item: $0, account: account) }
            .onAppear(perform: consumePending)
            .onChange(of: router.pendingRedeemItemID) { consumePending() }
        }
    }

    private var lastCompletedStop: Int? {
        let service = FlowService(context: context)
        return parts.first { $0.statusValue == .completed }.flatMap { service.mission($0.missionID)?.endStopSeq }
    }

    private func consumePending() {
        guard let id = router.pendingRedeemItemID else { return }
        router.pendingRedeemItemID = nil
        // 從任務完成的 sheet 跳過來時，那個 sheet 還在收合；同時再開一個 sheet 會被系統擋掉
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            redeeming = items.first { $0.id == id }
        }
    }

    /// 「可選」是點數足夠的單一品項數，不是這些點數能一次換完的數量
    @ViewBuilder
    private func progressLine(catalog: [RewardItem], available: Int, focus: (name: String, items: [RewardItem])?) -> some View {
        let inStock = catalog.filter { $0.stock > 0 }
        let affordable = inStock.filter { $0.coinCost <= available }
        let next = inStock.filter { $0.coinCost > available }.min { $0.coinCost < $1.coinCost }
        VStack(alignment: .leading, spacing: Space.s) {
            if !affordable.isEmpty {
                let here = focus.map { f in f.items.filter { $0.stock > 0 && $0.coinCost <= available }.count }
                Label("全線 \(affordable.count) 項可選" + (focus.map { "；\($0.name) \(here ?? 0) 項" } ?? ""),
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.brand)
                    .accessibilityIdentifier("coin-progress")
                Text("「可選」指點數足夠的單一品項，不代表 \(available) 枚能一次全部兌換")
                    .font(.caption.weight(.regular)).foregroundStyle(.secondary)
            } else if let next {
                Label("再 \(next.coinCost - available) 枚可換\(next.name)", systemImage: "flag.checkered")
                if available == 0 {
                    Button("去找任務賺旅綠幣") { router.tab = .explore }
                        .buttonStyle(.secondaryAction)
                }
            } else {
                Label("兌換品今日都已換完", systemImage: "moon.zzz")
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title).font(.title3.bold())
            content()
        }
    }

    private func merchantBlock(_ m: Merchant, available: Int, service: FlowService) -> some View {
        Card {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: m.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.brand)
                    .frame(width: 40, height: 40)
                    .background(Color.brand.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.headline)
                    if let tag = m.demoTag {
                        DemoBadge(text: tag).padding(.vertical, 2).accessibilityIdentifier("merchant-demo-tag")
                    }
                    let walk = RedeemCatalog.walkMinutes(m, service: service).map { "・步行粗估 \($0) 分鐘（非導航）" } ?? ""
                    Text("\(service.stopName(m.stopSeq))站\(walk)").font(.caption).foregroundStyle(.secondary)
                    Text(m.hoursNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(items.filter { $0.merchantID == m.id && $0.isActive }) { it in
                let st = RedeemCatalog.status(it, available: available)
                Button {
                    redeeming = it
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text("\(it.coinCost) 枚").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(st.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                            .background(st.color.opacity(0.12), in: Capsule())
                            .foregroundStyle(st.color)
                    }
                    .padding(.vertical, Space.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("redeem-item-\(it.id)")
            }
        }
    }
}

private struct BalanceCard: View {
    let available: Int
    let held: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("可用旅綠幣").font(.subheadline).foregroundStyle(.white.opacity(0.85))
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("\(available)")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("枚").font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white)
            Text("\(FlowService.campaignEnd.formatted(date: .long, time: .omitted)) 到期")
                .font(.caption).foregroundStyle(.white.opacity(0.85))
            if held > 0 {
                Text("另有 \(held) 枚保留給尚未使用的兌換碼").font(.caption).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.xl)
        .background(
            LinearGradient(colors: [Color.brand, Color.brand.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "leaf.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.coin)
                .padding(Space.l)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coin-balance")
    }
}

// MARK: 使用紀錄

struct LedgerHistoryView: View {
    let account: DemoAccount
    @Query private var entries: [LedgerEntry]

    init(account: DemoAccount) {
        self.account = account
        let uid = account.id
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.userID == uid }, sort: \LedgerEntry.createdAt, order: .reverse)
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Text("完成任務後，獲得與使用的紀錄會出現在這裡").foregroundStyle(.secondary)
            }
            ForEach(entries) { e in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.reason).font(.subheadline)
                        Text(Fmt.dateTime(e.createdAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(e.amount > 0 ? "+\(e.amount)" : "\(e.amount)")
                        .font(.headline).monospacedDigit()
                        .foregroundStyle(e.amount > 0 ? Color.brand : .primary)
                }
            }
            Section {
                Text("旅綠幣是活動點數，不能買賣、轉讓或換現金，只能在合作店家兌換，活動結束後失效。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("使用紀錄")
    }
}

// MARK: T08 兌換：確認 → 等待掃描 → 兌換成功

struct RedeemFlowSheet: View {
    let item: RewardItem
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(TravelerRouter.self) private var router
    @Environment(Session.self) private var session
    @Query private var tokens: [RedemptionToken]
    @Query private var entries: [LedgerEntry]
    @State private var tokenID: String?
    @State private var error: String?

    init(item: RewardItem, account: DemoAccount) {
        self.item = item
        self.account = account
        let uid = account.id
        _tokens = Query(filter: #Predicate<RedemptionToken> { $0.userID == uid })
        _entries = Query(filter: #Predicate<LedgerEntry> { $0.userID == uid })
    }

    private var service: FlowService { FlowService(context: context) }
    private var token: RedemptionToken? { tokens.first { $0.id == tokenID } }
    private var merchant: Merchant? { service.merchant(item.merchantID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.xl) {
                    if let t = token, t.usedAt != nil {
                        doneView
                    } else if let t = token {
                        waitingView(t)
                    } else if let error {
                        blockedView(icon: "exclamationmark.circle", title: "暫時無法兌換", message: error, action: nil)
                    } else {
                        switch RedeemCatalog.status(item, available: service.available(for: account.id)) {
                        case .available:
                            confirmView
                        case .short(let n):
                            blockedView(icon: "leaf", title: "還差 \(n) 枚", message: "完成一個任務就能拿到旅綠幣。",
                                        action: ("去找任務", { router.tab = .explore; dismiss() }))
                        case .soldOut:
                            blockedView(icon: "moon.zzz", title: "今日已換完", message: "明天再來，或看看其他店家的品項。",
                                        action: ("看其他店家", { dismiss() }))
                        }
                    }
                }
                .padding(Space.xl)
            }
            .navigationTitle("兌換")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(token?.usedAt != nil ? "完成" : "關閉") { dismiss() }
                }
            }
            // 關掉畫面不作廢兌換碼：旅客可能只是先收起手機走到櫃台，單機展示也要能切到商家身分去核銷。
            // 沒用掉的碼 5 分鐘後自然失效，同一品項重新產生時舊碼也會被作廢
        }
    }

    private var storeHeader: some View {
        VStack(spacing: Space.xs) {
            Image(systemName: merchant?.symbol ?? "storefront")
                .font(.title2)
                .foregroundStyle(Color.brand)
                .frame(width: 52, height: 52)
                .background(Color.brand.opacity(0.12), in: Circle())
            Text(merchant?.name ?? "").font(.headline)
            if let m = merchant {
                Text("\(service.stopName(m.stopSeq))站・\(m.hoursNote)")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let tag = m.demoTag { DemoBadge(text: tag) }
            }
        }
    }

    private var confirmView: some View {
        let available = service.available(for: account.id)
        return VStack(spacing: Space.xl) {
            storeHeader
            VStack(spacing: Space.s) {
                Text(item.name).font(.title.bold()).multilineTextAlignment(.center)
                Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(spacing: Space.s) {
                HStack {
                    Text("使用")
                    Spacer()
                    CoinLabel(amount: item.coinCost, font: .title3)
                }
                Divider()
                HStack {
                    Text("兌換後剩")
                    Spacer()
                    Text("\(available - item.coinCost) 枚").font(.title3.bold()).monospacedDigit()
                }
            }
            .padding(Space.l)
            .background(Color.inset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            Button("確認兌換") { generate() }
                .buttonStyle(.primary)
                .accessibilityIdentifier("redeem-confirm")
            Text("下一步會顯示 QR Code，請給店員掃描。店員確認後才會扣點。營業資訊待確認，請先確認店家有營業。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private func waitingView(_ t: RedemptionToken) -> some View {
        VStack(spacing: Space.l) {
            // 小螢幕要一眼看到 QR、短碼和倒數，所以店家資訊壓成一行
            VStack(spacing: Space.xs) {
                Label(merchant.map { "\($0.name)・\(service.stopName($0.stopSeq))站" } ?? "", systemImage: merchant?.symbol ?? "storefront")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(item.name).font(.title3.bold())
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                if t.expiresAt > ctx.date {
                    QRCodeView(text: service.payload(for: t))
                        .frame(maxWidth: 280)
                        .accessibilityIdentifier("redeem-qr")
                } else {
                    VStack(spacing: Space.m) {
                        Image(systemName: "clock.badge.xmark").font(.system(size: 56)).foregroundStyle(.orange)
                        Text("兌換碼已過期").font(.headline)
                        Text("點數沒有被扣，重新產生就能繼續").font(.caption).foregroundStyle(.secondary)
                        Button("重新產生") { generate() }.buttonStyle(.primary)
                    }
                    .frame(height: 280)
                }
            }
            VStack(spacing: Space.xs) {
                Text("店員也可以輸入").font(.caption).foregroundStyle(.secondary)
                Text(TokenSigner.shortCode(for: t.id))
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .kerning(4)
                    .accessibilityIdentifier("redeem-short-code")
            }
            HStack(spacing: Space.s) {
                ProgressView()
                Text("等待店員掃描").font(.subheadline.weight(.semibold))
            }
            CountdownText(until: t.expiresAt).font(.caption)
            if session.showDemoTools {
                demoMerchantTools(t)
            }
        }
    }

    /// 單機展示時，旅客與商家是同一支手機，用這兩顆按鈕把核銷那一端接起來
    private func demoMerchantTools(_ t: RedemptionToken) -> some View {
        VStack(spacing: Space.s) {
            Text("展示用").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Button("模擬店員掃描") {
                do {
                    let p = try service.preview(input: service.payload(for: t), merchantID: t.merchantID)
                    _ = try service.confirm(tokenID: p.token.id, merchantID: t.merchantID, idempotencyKey: UUID().uuidString)
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .buttonStyle(.secondaryAction)
            .accessibilityIdentifier("demo-merchant-scan")
            if let merchantAccount = DemoAccounts.find(t.merchantID) {
                Button("切換到「\(merchantAccount.name)」核銷") { session.account = merchantAccount }
                    .font(.subheadline)
            }
        }
        .padding(.top, Space.s)
    }

    private var doneView: some View {
        VStack(spacing: Space.l) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 80)).foregroundStyle(Color.brand)
            Text("兌換成功").font(.largeTitle.bold()).accessibilityIdentifier("redeem-success")
            Text(item.name).font(.title3)
            VStack(spacing: Space.s) {
                HStack { Text("扣除"); Spacer(); Text("\(item.coinCost) 枚").monospacedDigit() }
                Divider()
                HStack { Text("剩餘"); Spacer(); Text("\(service.available(for: account.id)) 枚").font(.headline).monospacedDigit() }
            }
            .padding(Space.l)
            .background(Color.inset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            Button("完成") { dismiss() }.buttonStyle(.primary)
        }
    }

    private func blockedView(icon: String, title: String, message: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: Space.l) {
            storeHeader
            Text(item.name).font(.headline).foregroundStyle(.secondary)
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.orange)
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.primary)
            }
        }
    }

    private func generate() {
        do {
            tokenID = try service.createRedeemToken(user: account.id, item: item).id
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
