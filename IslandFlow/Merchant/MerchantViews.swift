import SwiftUI
import SwiftData

struct MerchantRoot: View {
    let account: DemoAccount
    @State private var tab = LaunchArgs.startTab

    var body: some View {
        let mid = account.merchantID ?? ""
        TabView(selection: $tab) {
            ScanRedeemView(merchantID: mid)
                .tabItem { Label("核銷", systemImage: "qrcode.viewfinder") }.tag(0)
            RedemptionLogView(merchantID: mid)
                .tabItem { Label("紀錄", systemImage: "list.bullet.rectangle") }.tag(1)
            MerchantItemsView(merchantID: mid)
                .tabItem { Label("品項", systemImage: "shippingbox") }.tag(2)
        }
    }
}

// MARK: M02 掃碼核銷

struct ScanRedeemView: View {
    let merchantID: String
    @Environment(\.modelContext) private var context
    @Query private var tokens: [RedemptionToken]
    @Query private var items: [RewardItem]
    @State private var code = ""
    @State private var error: String?
    @State private var preview: RedemptionPreview?
    @FocusState private var codeFocused: Bool

    init(merchantID: String) {
        self.merchantID = merchantID
        let mid = merchantID
        _tokens = Query(filter: #Predicate<RedemptionToken> { $0.merchantID == mid }, sort: \RedemptionToken.createdAt, order: .reverse)
    }

    private var service: FlowService { FlowService(context: context) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(service.merchant(merchantID)?.name ?? "").font(.title3.bold())
                    QRScannerView { lookup($0) }
                        .frame(height: 240)
                    HStack {
                        TextField("或輸入 6 位數短碼", text: $code)
                            .keyboardType(.numberPad)
                            .font(.title3.monospaced())
                            .textFieldStyle(.roundedBorder)
                            .focused($codeFocused)
                        Button("查詢") { lookup(code) }
                            .buttonStyle(.borderedProminent)
                            .disabled(code.count != 6)
                    }
                    if !QRScannerView.hasCamera {
                        PasteCodeButton { lookup($0) }
                    }
                    if let error { ErrorBanner(message: error) }
                    pendingDemo
                }
                .padding()
            }
            // 數字鍵盤沒有收合鍵，不收的話錯誤訊息會被鍵盤蓋住
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("掃碼核銷")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountMenu() } }
            .sheet(item: $preview) { p in
                RedeemConfirmSheet(preview: p, merchantID: merchantID)
            }
        }
    }

    /// 單機展示時旅客與商家是同一支手機，列出待核銷碼等同「旅客把手機遞過來給你掃」
    private var pendingDemo: some View {
        let usable = tokens.filter { $0.isUsable() }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本店待核銷兌換碼").font(.subheadline.weight(.semibold))
                DemoBadge(text: "單機展示用")
            }
            if usable.isEmpty {
                Text("目前沒有。請先切到一般民眾身分，在「綠幣」頁產生兌換碼。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(usable) { t in
                Button {
                    lookup(service.payload(for: t))
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(items.first { $0.id == t.rewardID }?.name ?? "").foregroundStyle(.primary)
                            Text("\(DemoAccounts.find(t.userID)?.name ?? "旅客")・短碼 \(TokenSigner.shortCode(for: t.id))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        CountdownText(until: t.expiresAt).font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pending-token")
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }

    private func lookup(_ raw: String) {
        codeFocused = false
        do {
            preview = try service.preview(input: raw, merchantID: merchantID)
            error = nil
            code = ""
        } catch {
            self.error = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

// MARK: M03 確認兌換

struct RedeemConfirmSheet: View {
    let preview: RedemptionPreview
    let merchantID: String
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 開啟這個畫面時就決定好；之後不論按幾次、網路重送幾次，都用同一把鍵
    @State private var idempotencyKey = UUID().uuidString
    @State private var done: Redemption?
    @State private var replayNote: String?
    @State private var error: String?

    var body: some View {
        let service = FlowService(context: context)
        NavigationStack {
            // 跨機核銷的成功畫面多了完成碼，小螢幕放不下要能捲動
            ScrollView {
            VStack(spacing: 16) {
                if let done {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: service.needsReceipt(done) ? 48 : 72)).foregroundStyle(Color.brand)
                    Text("核銷成功").font(.title.bold()).accessibilityIdentifier("merchant-success")
                    Text("請將「\(done.rewardName)」交給旅客").font(.headline)
                    if service.needsReceipt(done) {
                        ReceiptCodeCard(payload: service.receiptPayload(for: done), amount: done.coinAmount)
                        Text("交易編號 \(done.id.prefix(8))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else {
                        Text("已扣 \(done.coinAmount) 枚・交易編號 \(done.id.prefix(8))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if let replayNote {
                        Label(replayNote, systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline).foregroundStyle(.orange)
                            .padding(10)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    DisclosureGroup("防重複展示（展示用）") {
                        Button {
                            confirm(service)
                        } label: {
                            Label("重送同一個確認請求", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            do {
                                _ = try service.preview(input: preview.payload, merchantID: merchantID)
                            } catch {
                                replayNote = "再掃一次同一張碼：\(error.localizedDescription)"
                            }
                        } label: {
                            Label("再掃一次同一張兌換碼", systemImage: "qrcode").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.subheadline)
                    .tint(.orange)
                    .padding(.top)
                } else {
                    Text("旅客 \(preview.userName) 要兌換").font(.subheadline).foregroundStyle(.secondary)
                    Text(preview.item.name).font(.title.bold())
                    CoinLabel(amount: preview.item.coinCost, font: .title2)
                    Text("庫存剩 \(preview.item.stock) 份").font(.subheadline).foregroundStyle(.secondary)
                    CountdownText(until: preview.expiresAt).font(.subheadline)
                    Text(preview.remote == nil
                         ? "確認後才會扣旅客的點數，這張兌換碼也會同時失效。"
                         : "這張碼來自旅客自己的手機。確認後畫面會出現完成碼，請旅客回掃，點數在旅客手機上扣除。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let error { ErrorBanner(message: error) }
                    Spacer()
                    Button("確認兌換") { confirm(service) }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("merchant-confirm")
                }
                Spacer(minLength: 0)
            }
            .padding()
            }
            .navigationTitle("核銷確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done == nil ? "取消" : "完成") { dismiss() } }
            }
        }
    }

    private func confirm(_ service: FlowService) {
        do {
            let (r, replayed) = try service.confirm(tokenID: preview.tokenID, merchantID: merchantID,
                                                     idempotencyKey: idempotencyKey, remote: preview.remote)
            if replayed {
                replayNote = "偵測到重送：沿用第一次的結果，沒有重複扣點或扣庫存"
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            withAnimation { done = r }
        } catch {
            self.error = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

/// 跨機核銷完成後給旅客回掃的碼。兩支手機沒有連線，旅客那邊要靠這張碼才知道店家已經核銷
struct ReceiptCodeCard: View {
    let payload: String
    let amount: Int

    var body: some View {
        VStack(spacing: 8) {
            Text("請旅客掃這個完成碼").font(.headline)
            QRCodeView(text: payload)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("merchant-receipt-qr")
            Text("旅客在自己手機的兌換畫面按「掃店家完成碼」，回掃後才會扣 \(amount) 枚。完成碼 24 小時內有效。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(14)
        .background(Color.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// 模擬器沒有相機：開發時用 `simctl pbcopy` 把另一台模擬器的碼放進剪貼簿再貼上。實機有相機就不顯示
struct PasteCodeButton: View {
    var onCode: (String) -> Void

    var body: some View {
        Button {
            if let s = UIPasteboard.general.string { onCode(s) }
        } label: {
            Label("從剪貼簿貼上碼（模擬器沒有相機）", systemImage: "doc.on.clipboard")
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("paste-code")
    }
}

// MARK: M04 核銷紀錄

struct RedemptionLogView: View {
    let merchantID: String
    @Environment(\.modelContext) private var context
    @Query private var records: [Redemption]
    @State private var todayOnly = true
    @State private var receiptFor: Redemption?

    init(merchantID: String) {
        self.merchantID = merchantID
        let mid = merchantID
        // 只查自己的商家，別家的紀錄在查詢層就拿不到
        _records = Query(filter: #Predicate<Redemption> { $0.merchantID == mid }, sort: \Redemption.redeemedAt, order: .reverse)
    }

    var body: some View {
        let shown = todayOnly ? records.filter { Calendar.current.isDateInToday($0.redeemedAt) } : records
        let ok = shown.filter(\.isSuccess)
        NavigationStack {
            List {
                Section {
                    Picker("範圍", selection: $todayOnly) {
                        Text("今日").tag(true)
                        Text("全部").tag(false)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("成功 \(ok.count) 筆・失敗 \(shown.count - ok.count) 筆")
                        Spacer()
                        Text("共 \(ok.reduce(0) { $0 + $1.coinAmount }) 枚").monospacedDigit()
                    }
                    .font(.subheadline)
                }
                if shown.isEmpty {
                    Text("沒有紀錄").foregroundStyle(.secondary)
                }
                ForEach(shown) { r in
                    HStack(alignment: .top) {
                        Image(systemName: r.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.isSuccess ? Color.brand : Color.red)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(r.rewardName).font(.subheadline.weight(.medium))
                                if r.isSimulated { DemoBadge() }
                            }
                            Text(Fmt.dateTime(r.redeemedAt)).font(.caption).foregroundStyle(.secondary)
                            if !r.isSuccess {
                                Text("失敗原因：\(r.failureReason)").font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(r.isSuccess ? "−\(r.coinAmount)" : "未扣點").font(.subheadline).monospacedDigit()
                                .foregroundStyle(.secondary)
                            // 旅客當下沒回掃，事後還能從紀錄叫出完成碼
                            if FlowService(context: context).needsReceipt(r) {
                                Button("完成碼") { receiptFor = r }
                                    .font(.caption).buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .navigationTitle("核銷紀錄")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountMenu() } }
            .sheet(item: $receiptFor) { r in
                ReceiptCodeCard(payload: FlowService(context: context).receiptPayload(for: r), amount: r.coinAmount)
                    .padding()
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

struct MerchantItemsView: View {
    let merchantID: String
    @Query private var items: [RewardItem]

    init(merchantID: String) {
        self.merchantID = merchantID
        let mid = merchantID
        _items = Query(filter: #Predicate<RewardItem> { $0.merchantID == mid }, sort: \RewardItem.coinCost)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { it in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(it.name)
                                Text(it.isActive ? it.detail : "已下架").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                CoinLabel(amount: it.coinCost, font: .subheadline)
                                Text("庫存 \(it.stock)").font(.caption).monospacedDigit()
                                    .foregroundStyle(it.stock > 0 ? Color.secondary : Color.red)
                            }
                        }
                    }
                } footer: {
                    Text("品項、點數與庫存由管理端設定。庫存歸零時旅客無法再產生兌換碼。")
                }
            }
            .navigationTitle("本店品項")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountMenu() } }
        }
    }
}
