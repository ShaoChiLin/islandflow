import SwiftUI
import SwiftData

// MARK: 行程：已加入的任務、掃碼、目前進度

struct MyTripsView: View {
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Environment(TravelerRouter.self) private var router
    @Query private var parts: [Participation]
    @Query private var missions: [Mission]
    @Query private var trips: [BusTrip]
    @State private var scanning: Participation?
    @State private var cancelling: Participation?
    @State private var cancelError: String?

    init(account: DemoAccount) {
        self.account = account
        let uid = account.id
        _parts = Query(filter: #Predicate<Participation> { $0.userID == uid }, sort: \Participation.joinedAt, order: .reverse)
    }

    var body: some View {
        let service = FlowService(context: context)
        let active = parts.filter { $0.statusValue != .completed }
        let done = parts.filter { $0.statusValue == .completed }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if parts.isEmpty {
                        VStack(spacing: Space.l) {
                            ContentUnavailableView("還沒有行程", systemImage: "ticket",
                                                   description: Text("到「探索」挑一班車加入任務"))
                            Button("去探索") { router.tab = .explore }
                                .buttonStyle(.primary)
                        }
                        .padding(.top, Space.xxl)
                    }
                    ForEach(active) { p in
                        if let m = missions.first(where: { $0.id == p.missionID }) {
                            activeCard(p, m, service: service)
                        }
                    }
                    if !done.isEmpty {
                        VStack(alignment: .leading, spacing: Space.m) {
                            Text("已完成").font(.title3.bold())
                            ForEach(done) { p in
                                if let m = missions.first(where: { $0.id == p.missionID }) {
                                    doneRow(p, m, service: service)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.xl)
            }
            .background(Color.canvas)
            .navigationTitle("行程")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountMenu() } }
            .navigationDestination(for: String.self) { id in
                if let m = missions.first(where: { $0.id == id }) {
                    MissionDetailView(mission: m, account: account)
                }
            }
            .sheet(item: $scanning) { p in
                if let m = missions.first(where: { $0.id == p.missionID }) {
                    CheckinSheet(participation: p, mission: m, account: account)
                }
            }
            .confirmationDialog("取消這個任務？", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                                titleVisibility: .visible, presenting: cancelling) { p in
                Button("取消任務", role: .destructive) { leave(p, service: service) }
                    .accessibilityIdentifier("trip-cancel-confirm")
                Button("保留", role: .cancel) {}
            } message: { p in
                Text("名額會釋放給其他人，鎖定的 \(p.rewardAmount) 枚不會發放。之後可以再加入，但獎勵依當時班次重新計算。")
            }
            .alert("無法取消", isPresented: Binding(get: { cancelError != nil }, set: { if !$0 { cancelError = nil } })) {
                Button("好") {}
            } message: {
                Text(cancelError ?? "")
            }
        }
    }

    private func leave(_ p: Participation, service: FlowService) {
        do {
            try service.leave(p, user: account.id)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            cancelError = error.localizedDescription
        }
    }

    private func activeCard(_ p: Participation, _ m: Mission, service: FlowService) -> some View {
        let from = service.stopName(m.startStopSeq), to = service.stopName(m.endStopSeq)
        let dep = service.trip(m.tripID)?.departure ?? ""
        return Card {
            HStack {
                Label("進行中", systemImage: "figure.walk.motion").font(.caption.weight(.semibold)).foregroundStyle(Color.brand)
                Spacer()
                CoinLabel(amount: p.rewardAmount, font: .headline)
            }
            Text("前往\(to)").font(.title2.bold())
            Text("\(dep) 從\(from)出發・\(m.title)").font(.subheadline).foregroundStyle(.secondary)
            StepRow(n: 1, title: "在「\(from)」掃出發碼",
                    detail: p.departedAt.map { "已完成 \(Fmt.time($0))" } ?? "上車前掃站牌", done: p.statusValue != .joined)
            StepRow(n: 2, title: "到「\(to)」掃到站碼", detail: "下車後掃站牌", done: false)
            Button {
                scanning = p
            } label: {
                Label(p.statusValue == .joined ? "掃描出發碼" : "掃描到站碼", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("trip-primary-action")
            NavigationLink(value: m.id) {
                Text("查看任務詳情").font(.subheadline).frame(maxWidth: .infinity)
            }
            if p.statusValue == .joined {
                Button("取消任務", role: .destructive) { cancelling = p }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("trip-cancel")
            } else {
                Text("已完成出發驗證，任務不能取消；抵達後記得掃到站碼。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func doneRow(_ p: Participation, _ m: Mission, service: FlowService) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Color.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.subheadline.weight(.medium))
                    Text(p.completedAt.map(Fmt.dateTime) ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: Space.xs) {
                    CoinLabel(amount: p.rewardAmount, font: .subheadline, showSign: true)
                    Button("去兌換") { router.goRedeem(stop: m.endStopSeq) }
                        .font(.caption.weight(.semibold))
                }
            }
            NavigationLink {
                ReturnTripView(mission: m)
            } label: {
                Label("回程資訊：從\(service.stopName(m.endStopSeq))回\(service.stopName(m.startStopSeq))", systemImage: "arrow.uturn.backward")
                    .font(.caption.weight(.semibold))
            }
            .accessibilityIdentifier("trip-return-info")
        }
        .padding(Space.m)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}
