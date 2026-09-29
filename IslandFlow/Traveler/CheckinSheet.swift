import SwiftUI
import SwiftData

// MARK: T04/T05 出發與到站驗證

struct CheckinSheet: View {
    let participation: Participation
    let mission: Mission
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(TravelerRouter.self) private var router
    @Environment(Session.self) private var session
    @State private var outcome: Outcome?
    @State private var working = false
    @State private var lastRaw: String?
    @State private var lastMethod = "camera"
    @State private var locator = LocationProvider()

    enum Outcome {
        case success(CheckinResult)
        case failure(FlowError)
    }

    private var service: FlowService { FlowService(context: context) }

    /// 驗證成功後參加紀錄已經進到下一階段；標題要跟著畫面上的結果走，
    /// 不然出發成功的畫面會頂著「到站驗證」的標題（K22）
    private var title: String {
        if case .success(let r) = outcome { return "\(r.stage.label)完成" }
        return service.expectedStage(participation)?.label ?? "驗證完成"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    switch outcome {
                    case .success(let r):
                        SuccessPanel(result: r, reward: participation.rewardAmount, mission: mission, account: account) { itemID in
                            if r.stage == .arrive {
                                router.goRedeem(stop: mission.endStopSeq, itemID: itemID)
                            }
                            dismiss()
                        }
                    case .failure(let e):
                        failurePanel(e)
                        scannerSection
                    case nil:
                        scannerSection
                    }
                }
                .padding(Space.l)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
            }
            .overlay { if working { ProgressView().controlSize(.large) } }
        }
    }

    @ViewBuilder private var scannerSection: some View {
        if let stage = service.expectedStage(participation) {
            let seq = stage == .depart ? mission.startStopSeq : mission.endStopSeq
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("對準「\(service.stopName(seq))」站牌上的 QR Code").font(.title3.bold())
                Text(stage == .depart ? "上車前掃一次，確認你從這站出發" : "下車後掃一次，旅綠幣就會入帳")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            QRScannerView { code in submit(code, method: "camera") }
                .frame(height: 240)

            if session.showDemoTools {
                DemoScanButtons(participation: participation, mission: mission, stage: stage) { raw in
                    submit(raw, method: "demo")
                }
            }
        }
    }

    private func failurePanel(_ e: FlowError) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ErrorBanner(message: e.message)
            if e.kind == .location, let raw = lastRaw {
                Button {
                    submit(raw, method: lastMethod, manual: true)
                } label: {
                    Label("請站務人員協助通過（會留下紀錄）", systemImage: "hand.raised")
                }
                .buttonStyle(.secondaryAction)
            }
        }
    }

    private func submit(_ raw: String, method: String, manual: Bool = false) {
        lastRaw = raw
        lastMethod = method
        working = true
        Task {
            var loc: FlowService.Location?
            if service.rules().requireLocation, service.expectedStage(participation) == .arrive, !manual,
               let l = await locator.currentLocation() {
                loc = .init(lat: l.coordinate.latitude, lon: l.coordinate.longitude)
            }
            do {
                let r = try service.checkIn(raw: raw, participation: participation, method: method,
                                            location: loc, manualOverride: manual)
                withAnimation { outcome = .success(r) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch let e as FlowError {
                withAnimation { outcome = .failure(e) }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            } catch {
                withAnimation { outcome = .failure(.msg(error.localizedDescription)) }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            working = false
        }
    }
}

/// 只有一支手機展示、或模擬器沒有相機時，用這些按鈕產生「此刻站牌上會顯示的碼」與各種錯誤碼，
/// 走的是和相機完全相同的驗證流程。可在展示選單關掉。
struct DemoScanButtons: View {
    let participation: Participation
    let mission: Mission
    let stage: CheckinStage
    var submit: (String) -> Void
    @Environment(\.modelContext) private var context
    @State private var showCases = false

    var body: some View {
        let service = FlowService(context: context)
        let expected = stage == .depart ? mission.startStopSeq : mission.endStopSeq
        let otherTrip = ((try? context.fetch(FetchDescriptor<BusTrip>())) ?? []).first { $0.id != mission.tripID }
        let wrongStop = stage == .depart ? mission.endStopSeq : 4

        VStack(alignment: .leading, spacing: Space.m) {
            Button {
                submit(service.currentStationToken(trip: mission.tripID, stop: expected))
            } label: {
                Label("模擬掃描站牌（展示用）", systemImage: "qrcode")
            }
            .buttonStyle(.secondaryAction)
            .accessibilityIdentifier("demo-scan-valid")

            DisclosureGroup("防弊情境（展示用）", isExpanded: $showCases) {
                VStack(spacing: Space.s) {
                    demoButton("過期的碼（10 分鐘前）", "clock.badge.xmark") {
                        service.currentStationToken(trip: mission.tripID, stop: expected, now: .now.addingTimeInterval(-600))
                    }
                    demoButton("錯誤站點：「\(service.stopName(wrongStop))」", "mappin.slash") {
                        service.currentStationToken(trip: mission.tripID, stop: wrongStop)
                    }
                    if let otherTrip {
                        demoButton("其他班次（\(otherTrip.departure)）的碼", "bus") {
                            service.currentStationToken(trip: otherTrip.id, stop: expected)
                        }
                    }
                    demoButton("偽造／竄改過的碼", "exclamationmark.shield") {
                        let t = service.currentStationToken(trip: mission.tripID, stop: expected)
                        return String(t.dropLast(4)) + "AAAA"
                    }
                    if stage == .arrive {
                        demoButton("再掃一次出發碼（重複掃描）", "repeat") {
                            service.currentStationToken(trip: mission.tripID, stop: mission.startStopSeq)
                        }
                    }
                }
                .padding(.top, Space.s)
            }
            .font(.subheadline)
            .tint(.secondary)
        }
    }

    private func demoButton(_ title: String, _ icon: String, _ make: @escaping () -> String) -> some View {
        Button {
            submit(make())
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
    }
}

/// 驗證成功。到站完成時直接列出附近可兌換品，點一下就進兌換確認頁
struct SuccessPanel: View {
    let result: CheckinResult
    let reward: Int
    let mission: Mission
    let account: DemoAccount
    /// 參數是旅客直接點選的品項 id；nil 代表只是關閉或看全部
    var onContinue: (String?) -> Void
    @Environment(\.modelContext) private var context
    @State private var pop = false

    var body: some View {
        let service = FlowService(context: context)
        let available = service.available(for: account.id)
        let nearby = RedeemCatalog.items(atStop: mission.endStopSeq, service: service)
        let stopName = service.stopName(mission.endStopSeq)

        VStack(spacing: Space.l) {
            Image(systemName: result.stage == .arrive ? "leaf.circle.fill" : "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(result.stage == .arrive ? Color.coin : Color.brand)
                .scaleEffect(pop ? 1 : 0.4)
                .animation(.spring(response: 0.4, dampingFraction: 0.5), value: pop)

            if result.stage == .arrive {
                Text("已獲得 \(result.coinsAwarded ?? reward) 枚")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("checkin-reward")
                Text("\(stopName)站附近有 \(nearby.filter { $0.stock > 0 }.count) 項兌換品")
                    .font(.headline).foregroundStyle(.secondary)
                VStack(spacing: Space.s) {
                    ForEach(nearby) { it in
                        let st = RedeemCatalog.status(it, available: available)
                        Button {
                            onContinue(it.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(it.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                    let m = service.merchant(it.merchantID)
                                    Text([m?.name, m?.isFictional == true ? "示範店家" : nil].compactMap { $0 }.joined(separator: "・"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(it.coinCost) 枚").font(.subheadline).monospacedDigit()
                                    Text(st.label).font(.caption.weight(.semibold)).foregroundStyle(st.color)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(Space.m)
                            .background(Color.inset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("completion-redeem-item")
                    }
                }
                Button("查看所有兌換品") { onContinue(nil) }
                    .buttonStyle(.secondaryAction)
                // 以下放在兌換品之後，不影響「完成後兩次點擊拿到 QR」
                EmissionReceiptCard(mission: mission)
                NavigationLink {
                    ReturnTripView(mission: mission)
                } label: {
                    Label("查看回程", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("completion-return-trip")
            } else {
                Text("出發驗證成功").font(.title.bold())
                Text("抵達\(service.stopName(mission.endStopSeq))後，再掃一次站牌就能領 \(reward) 枚")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("好，出發！") { onContinue(nil) }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("checkin-continue")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.l)
        .onAppear { pop = true }
    }
}
