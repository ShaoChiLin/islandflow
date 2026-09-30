import SwiftUI
import SwiftData

struct AdminMoreView: View {
    let account: DemoAccount

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { StationBoardView() } label: {
                        Label("站牌動態碼看板", systemImage: "qrcode")
                    }
                } footer: {
                    Text("兩支手機展示時，把這支手機當站牌，用另一支手機的一般民眾身分掃描。")
                }
                Section {
                    NavigationLink { MerchantAdminView(account: account) } label: {
                        Label("商家與獎品", systemImage: "storefront")
                    }
                    NavigationLink { DataSourcesView() } label: {
                        Label("資料來源與估算方法", systemImage: "doc.text.magnifyingglass")
                    }
                    NavigationLink { AuditLogView() } label: {
                        Label("稽核紀錄", systemImage: "list.bullet.clipboard")
                    }
                }
            }
            .navigationTitle("更多")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountMenu() } }
        }
    }
}

// MARK: 站牌動態碼

struct StationBoardView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BusTrip.departure) private var trips: [BusTrip]
    @Query(sort: \RouteStop.sequence) private var stops: [RouteStop]
    @State private var tripID = "T1040"
    @State private var stopSeq = 1

    var body: some View {
        let service = FlowService(context: context)
        ScrollView {
            VStack(spacing: 14) {
                Picker("班次", selection: $tripID) {
                    ForEach(trips) { Text($0.departure).tag($0.id) }
                }
                .pickerStyle(.segmented)
                Picker("站點", selection: $stopSeq) {
                    ForEach(stops) { Text("\($0.sequence). \($0.shortName)").tag($0.sequence) }
                }
                Text("\(service.stopName(stopSeq))・\(trips.first { $0.id == tripID }?.departure ?? "") 班次")
                    .font(.title2.bold())
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let token = service.currentStationToken(trip: tripID, stop: stopSeq, now: ctx.date)
                    let t = Int(ctx.date.timeIntervalSince1970)
                    VStack(spacing: 8) {
                        QRCodeView(text: token).frame(maxWidth: 300)
                        Text("\(TokenSigner.rotation - t % TokenSigner.rotation) 秒後換新碼")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("碼內含路線、班次、站點與到期時間的簽章，不含個人資料；每 \(TokenSigner.rotation) 秒換一次、有效 \(service.rules().stationTokenTTL) 秒。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
        }
        .navigationTitle("站牌動態碼")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

// MARK: A04 商家與獎品

struct MerchantAdminView: View {
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Query(sort: \Merchant.stopSeq) private var merchants: [Merchant]
    @Query(sort: \RewardItem.coinCost) private var items: [RewardItem]

    var body: some View {
        List {
            ForEach(merchants) { m in
                Section {
                    MerchantPartnerRow(merchant: m)
                    ForEach(items.filter { $0.merchantID == m.id }) { it in
                        ItemEditorRow(item: it)
                    }
                    if m.isPartner {
                        Button {
                            let it = RewardItem(id: "r-\(UUID().uuidString.prefix(6))", merchantID: m.id,
                                                name: "新品項", detail: "請填寫說明", coinCost: 50, stock: 10)
                            context.insert(it)
                            FlowService(context: context).audit(account.id, "item_create", "reward", it.id, m.name)
                            try? context.save()
                        } label: {
                            Label("新增品項", systemImage: "plus")
                        }
                    }
                } header: {
                    Text("\(m.name)・\(FlowService(context: context).stopName(m.stopSeq))")
                }
            }
        }
        .navigationTitle("商家與獎品")
        .onDisappear { try? context.save() }
    }
}

private struct MerchantPartnerRow: View {
    @Bindable var merchant: Merchant

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("已簽約合作（is_partner）", isOn: $merchant.isPartner)
            if merchant.isFictional {
                Text("虛構示範商家；公開展示前若改用真實店名，須先取得同意。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ItemEditorRow: View {
    @Bindable var item: RewardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("品項名稱", text: $item.name).font(.subheadline.weight(.medium))
            Stepper("所需 \(item.coinCost) 枚", value: $item.coinCost, in: 10...300, step: 10)
            Stepper("庫存 \(item.stock)", value: $item.stock, in: 0...500)
                .foregroundStyle(item.stock > 0 ? Color.primary : Color.red)
            Toggle("上架", isOn: $item.isActive)
        }
        .font(.subheadline)
    }
}

// MARK: 資料來源與估算方法

struct DataSourcesView: View {
    @Query private var rules: [RuleConfig]

    var body: some View {
        Form {
            Section("本版使用的開放資料") {
                SourceRow(title: "台灣好行站點資料（93967）", status: "已匯入", real: true,
                          detail: "交通部觀光署。北投竹子湖線 9 站的站名、站序與座標，原始 CSV 附在 App 內。")
                SourceRow(title: "北投竹子湖線每月搭乘人次（172679）", status: "已匯入", real: true,
                          detail: "臺北市政府觀光傳播局，115 年 1～8 月平日／假日班次、座位數、搭乘人數。用於選線與管理展示，不代表單一班次即時載客率。")
                SourceRow(title: "景點觀光資訊資料庫（7777）", status: "待匯入", real: false,
                          detail: "下一版篩選北投與竹子湖沿線景點。")
                SourceRow(title: "餐飲觀光資訊資料庫（7779）", status: "待匯入", real: false,
                          detail: "作為合作店家候選；收錄不等於已合作（is_partner 區分）。")
                SourceRow(title: "TDX 公車班次與即時動態", status: "保留介面", real: false,
                          detail: "未取得憑證前，班次載客率使用模擬值。")
            }
            Section("模擬資料") {
                Text("・各班次預估載客率\n・三家示範商家與兌換品項（虛構）\n・過去 14 天的參加、完成與核銷紀錄\n・天氣適配分數")
                    .font(.subheadline)
            }
            if let r = rules.first {
                AssumptionsSection(rules: r)
            }
        }
        .navigationTitle("資料來源與估算方法")
    }
}

private struct SourceRow: View {
    var title: String
    var status: String
    var real: Bool
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                if real { OpenDataBadge(text: status) } else { DemoBadge(text: status) }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AssumptionsSection: View {
    @Bindable var rules: RuleConfig

    var body: some View {
        Section {
            Stepper("1 枚旅綠幣 = NT$\(String(format: "%.1f", rules.coinValueNTD))", value: $rules.coinValueNTD, in: 0.1...5, step: 0.1)
            Stepper("新增搭乘增量比例 \(Fmt.pct(rules.incrementalRideRatio))", value: $rules.incrementalRideRatio, in: 0.05...1, step: 0.05)
            Stepper("平均加購金額 \(Fmt.ntd(rules.avgLocalSpendNTD))", value: $rules.avgLocalSpendNTD, in: 0...1000, step: 10)
            Stepper("分流站點基準值 \(rules.diversionBaseline) 人次", value: $rules.diversionBaseline, in: 0...500, step: 5)
            Stepper("自用小客車 \(String(format: "%.3f", rules.carFactor)) kgCO₂e/人公里", value: $rules.carFactor, in: 0...0.5, step: 0.005)
            Stepper("公車 \(String(format: "%.3f", rules.busFactor)) kgCO₂e/人公里", value: $rules.busFactor, in: 0...0.5, step: 0.005)
            Stepper("道路繞行係數 ×\(String(format: "%.2f", rules.routeDetourFactor))", value: $rules.routeDetourFactor, in: 1...2, step: 0.05)
        } header: {
            HStack { Text("估算假設"); DemoBadge() }
        } footer: {
            Text("估算避免排放量 = 路線距離 ×（自用車係數 − 公車係數）。以上係數為示範值，公開展示前請改用環境部產品碳足跡資料庫等可引用來源，並記錄版本與適用年份。路線距離由站點座標直線距離 × 繞行係數估算。這不是碳權。")
        }
    }
}

// MARK: 稽核紀錄

struct AuditLogView: View {
    @Query(sort: \AuditLog.createdAt, order: .reverse) private var logs: [AuditLog]

    var body: some View {
        List {
            if logs.isEmpty {
                Text("尚無紀錄").foregroundStyle(.secondary)
            }
            ForEach(logs.prefix(200)) { l in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(l.action).font(.subheadline.monospaced())
                        Spacer()
                        Text(Fmt.dateTime(l.createdAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(DemoAccounts.find(l.actorID)?.name ?? l.actorID) → \(l.targetType)/\(l.targetID.prefix(8))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !l.detail.isEmpty {
                        Text(l.detail).font(.caption)
                    }
                }
            }
        }
        .navigationTitle("稽核紀錄")
    }
}
