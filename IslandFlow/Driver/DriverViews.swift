import SwiftUI
import SwiftData

// MARK: D33／D34／D35 司機驗票

/// 司機掃旅客出示的票券 QR（D34：旅客先輸入購票序號才會出現）。D35 起上車驗票通過就入帳。
/// 展示版只支援同一支手機：任務與帳本都在本機，別支手機的票券會查無乘客。
struct DriverRoot: View {
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Participation> { $0.isSimulated == false && $0.status != "completed" },
           sort: \Participation.joinedAt, order: .reverse) private var waiting: [Participation]
    @Query(filter: #Predicate<Checkin> { $0.method == "driver" },
           sort: \Checkin.verifiedAt, order: .reverse) private var log: [Checkin]
    @State private var scanned: ScannedPass?
    @State private var error: String?

    struct ScannedPass: Identifiable {
        let raw: String
        var id: String { raw }
    }

    private var service: FlowService { FlowService(context: context) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("台灣好行北投竹子湖線・小9").font(.title3.bold())
                    QRScannerView { scan($0) }
                        .frame(height: 240)
                    if let error { ErrorBanner(message: error) }

                    Text("本機待驗票乘客").font(.subheadline.weight(.semibold))
                    if waiting.isEmpty {
                        Text("目前沒有。請先切到一般民眾身分加入任務，輸入購票序號後出示票券。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(waiting) { p in
                        let raw = service.boardingPassPayload(for: p)
                        Button {
                            if let raw { scan(raw) }
                        } label: {
                            waitingRow(p, hasTicket: raw != nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(raw == nil)
                        .accessibilityIdentifier("driver-waiting-row")
                    }
                    Text("同一支手機展示時，點乘客等同掃他畫面上的票券 QR；驗證規則和相機掃描相同。")
                        .font(.caption).foregroundStyle(.secondary)

                    Text("今日驗票紀錄").font(.subheadline.weight(.semibold)).padding(.top, Space.s)
                    if log.isEmpty {
                        Text("沒有紀錄").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(log.prefix(20)) { c in logRow(c) }
                }
                .padding()
            }
            .navigationTitle("司機驗票")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountMenu() } }
            .sheet(item: $scanned) { s in
                NavigationStack {
                    ScrollView {
                        DriverConfirmPanel(raw: s.raw, driverID: account.id, showsSwitchBack: true)
                            .padding(Space.l)
                    }
                    .navigationTitle("驗票確認")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("關閉") { scanned = nil } }
                    }
                }
            }
        }
    }

    private func scan(_ raw: String) {
        do {
            _ = try service.boardingPreview(raw: raw)
            error = nil
            scanned = ScannedPass(raw: raw)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func waitingRow(_ p: Participation, hasTicket: Bool) -> some View {
        let m = service.mission(p.missionID)
        let stage = service.expectedStage(p) ?? .depart
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(DemoAccounts.find(p.userID)?.name ?? "旅客").font(.subheadline.weight(.semibold))
                Text("\(m.flatMap { service.trip($0.tripID)?.departure } ?? "") 班次・\(m.map { service.stopName($0.startStopSeq) } ?? "") → \(m.map { service.stopName($0.endStopSeq) } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(!hasTicket ? "尚未出示票券" : stage == .depart ? "待上車" : "待下車")
                .font(.caption.weight(.semibold))
                .foregroundStyle(!hasTicket ? Color.secondary : stage == .depart ? Color.brand : Color.orange)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(Space.m)
        .background(Color.inset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func logRow(_ c: Checkin) -> some View {
        let pid = c.participationID
        let p = (try? context.fetch(FetchDescriptor<Participation>(
            predicate: #Predicate { $0.id == pid })))?.first
        let serial = service.ticketSerial(participationID: c.participationID)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(Fmt.time(c.verifiedAt))・\(p.flatMap { DemoAccounts.find($0.userID)?.name } ?? "旅客")")
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                Spacer()
                Text(c.stage == CheckinStage.depart.rawValue ? "上車" : "下車").font(.caption.weight(.semibold))
            }
            Text("\(service.stopName(c.stopSeq))" + (serial.map { "・購票序號 \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// 司機看完票券內容後確認上下車。司機端與旅客畫面的「模擬司機掃描」共用這一塊，規則只有一份。
struct DriverConfirmPanel: View {
    let raw: String
    let driverID: String
    /// 在司機身分下完成後，提供一鍵切回那位旅客
    var showsSwitchBack = false
    var onSuccess: ((CheckinResult) -> Void)?
    @Environment(\.modelContext) private var context
    @Environment(Session.self) private var session
    @State private var error: String?
    @State private var done: CheckinResult?

    private var service: FlowService { FlowService(context: context) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let done {
                donePanel(done)
            } else {
                switch Result(catching: { try service.boardingPreview(raw: raw) }) {
                case .success(let pv): confirmForm(pv)
                case .failure(let e): ErrorBanner(message: e.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder private func confirmForm(_ pv: FlowService.BoardingPreview) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(pv.stage == .depart ? "上車驗票" : "下車驗票").font(.title2.bold())
            Text("乘客 \(pv.passengerName)・\(pv.departure) 班次").font(.subheadline)
            Text("\(pv.stage == .depart ? "上車站" : "下車站")：\(pv.stopName)").font(.subheadline).foregroundStyle(.secondary)
        }
        Label("購票序號 \(pv.pass.serial)・台灣好行電子票券（模擬）", systemImage: "ticket")
            .font(.subheadline).foregroundStyle(.secondary)
            .accessibilityIdentifier("driver-ticket-serial")
        if let error { ErrorBanner(message: error) }
        Button(pv.stage == .depart ? "確認上車" : "確認下車") { confirm() }
            .buttonStyle(.primary)
            .accessibilityIdentifier("driver-confirm")
    }

    @ViewBuilder private func donePanel(_ r: CheckinResult) -> some View {
        VStack(spacing: Space.m) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(Color.brand)
            Text(r.stage == .depart ? "上車驗票完成" : "下車驗票完成").font(.title2.bold())
                .accessibilityIdentifier("driver-done")
            if let coins = r.coinsAwarded {
                Text("乘客獲得 \(coins) 枚旅綠幣").font(.headline)
            }
            if showsSwitchBack, let uid = (try? TokenSigner.verifyBoarding(raw))?.uid,
               let traveler = DemoAccounts.find(uid) {
                Button("切回「\(traveler.name)」") { session.account = traveler }
                    .buttonStyle(.secondaryAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func confirm() {
        do {
            let r = try service.driverCheckIn(raw: raw, driverID: driverID)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if let onSuccess { onSuccess(r) } else { withAnimation { done = r } }
        } catch {
            self.error = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
