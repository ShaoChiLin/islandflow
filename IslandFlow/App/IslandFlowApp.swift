import SwiftUI
import SwiftData

@main
struct IslandFlowApp: App {
    let container: ModelContainer
    @State private var session = Session()

    init() {
        do {
            container = try AppSchema.makeContainer()
        } catch {
            // 資料結構改過而舊資料打不開時，展示用 App 直接改用記憶體資料庫，至少能開起來
            container = try! AppSchema.makeContainer(inMemory: true)
        }
        let context = container.mainContext
        #if DEBUG
        if LaunchArgs.has("reset-demo") { SeedData.reset(context) }
        #endif
        SeedData.seedIfNeeded(context)
        #if DEBUG
        if let stage = LaunchArgs.value("demo-progress") { Self.fastForward(context, to: stage) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .debugLayoutWidth()
        }
        .modelContainer(container)
    }

    #if DEBUG
    /// 排練、截圖、UI 測試時直接跳到流程中段；走的是和畫面上完全相同的 FlowService 流程
    @MainActor
    private static func fastForward(_ context: ModelContext, to stage: String) {
        let order = ["joined", "departed", "completed", "token", "redeemed"]
        guard let level = order.firstIndex(of: stage) else { return }
        let service = FlowService(context: context)
        guard let m = service.mission("M-A"), let (p, _) = try? service.join(mission: m, user: "t-demo") else { return }
        if level >= 1 {
            _ = try? service.checkIn(raw: service.currentStationToken(trip: m.tripID, stop: m.startStopSeq), participation: p, method: "demo")
        }
        if level >= 2 {
            _ = try? service.checkIn(raw: service.currentStationToken(trip: m.tripID, stop: m.endStopSeq), participation: p, method: "demo")
        }
        if level >= 3, let item = service.item("r-veg"), let tok = try? service.createRedeemToken(user: "t-demo", item: item) {
            if level >= 4 {
                _ = try? service.confirm(tokenID: tok.id, merchantID: "m-lake", idempotencyKey: UUID().uuidString)
            }
        }
    }
    #endif
}

enum LaunchArgs {
    static func has(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    static func value(_ key: String) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        #else
        return nil
        #endif
    }

    static var startTab: Int { value("tab").flatMap(Int.init) ?? 0 }
}

/// 只給「班次是否已發車」的排序與標示使用。帳本、站牌碼、兌換碼一律用真實時間，
/// 否則兌換碼的倒數會和畫面時鐘對不上。`demo-time=09:30` 讓截圖與 UI 測試不受執行時段影響。
enum DemoClock {
    static var now: Date {
        if let v = LaunchArgs.value("demo-time"), let m = ClockTime.minutes(v) {
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: .now) ?? .now
        }
        return .now
    }
}

private extension View {
    /// `layout-width=320`：iOS 17 已沒有 320pt 寬的機型，用這個把整個畫面壓窄來檢查最小寬度版面
    @ViewBuilder func debugLayoutWidth() -> some View {
        if let w = LaunchArgs.value("layout-width").flatMap(Double.init) {
            self.frame(width: w).frame(maxWidth: .infinity).background(Color.gray)
        } else {
            self
        }
    }
}

struct RootView: View {
    @Environment(Session.self) private var session

    var body: some View {
        Group {
            if !session.hasOnboarded {
                WelcomeView()
            } else {
                switch session.account.role {
                case .traveler: TravelerRoot(account: session.account)
                case .merchant: MerchantRoot(account: session.account)
                case .admin: AdminRoot(account: session.account)
                }
            }
        }
        .id("\(session.account.id)-\(session.hasOnboarded)")
    }
}

// MARK: 首次進入

struct WelcomeView: View {
    @Environment(Session.self) private var session
    @State private var showDemoMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Spacer()
            BrandLogo(size: 132, decorative: false)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
                .frame(maxWidth: .infinity)
                // 長按圖示打開展示選單：評審展示時切商家／管理者用，一般旅客不會看到
                .onLongPressGesture(minimumDuration: 0.8) { showDemoMenu = true }
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel("旅綠")

            VStack(alignment: .leading, spacing: Space.m) {
                Text("旅綠").font(.subheadline.weight(.semibold)).foregroundStyle(Color.brand)
                Text("搭台灣好行\n完成低碳任務\n沿線兌換在地好物")
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Space.m) {
                WelcomeStep(icon: "bus.fill", text: "選一班比較空的車，獎勵更多")
                WelcomeStep(icon: "qrcode.viewfinder", text: "上車、下車各掃一次站牌")
                WelcomeStep(icon: "basket.fill", text: "到沿線小農店家換好物")
            }
            Spacer()
            Button("開始探索") {
                if session.account.role != .traveler { session.account = Session.defaultTraveler }
                session.hasOnboarded = true
            }
                .buttonStyle(.primary)
                .accessibilityIdentifier("welcome-start")
        }
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.l)
        .background(Color.canvas)
        .sheet(isPresented: $showDemoMenu) { DemoMenuSheet() }
    }
}

private struct WelcomeStep: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.brand)
                .frame(width: 36, height: 36)
                .background(Color.brand.opacity(0.12), in: Circle())
            Text(text).font(.body)
        }
    }
}

// MARK: 展示選單（競賽展示用）

/// 三端共用的「切換身分」按鈕（D28 取代 D15 的隱藏入口）：評審現場要一眼看到、兩下點擊就換角色，
/// 所以直接用選單列出帳號；載客率、重置等較少用的控制留在「展示控制」表單。
struct AccountMenu: View {
    @Environment(Session.self) private var session
    @State private var showControls = false

    var body: some View {
        Menu {
            ForEach([Role.traveler, .merchant, .admin], id: \.self) { role in
                // 用 Toggle 打勾而不用內嵌 Picker：Picker 會吃掉 Section 標題，評審就看不到角色名
                Section(role.label) {
                    ForEach(DemoAccounts.all.filter { $0.role == role }) { a in
                        Toggle(isOn: isCurrent(a)) {
                            Label(a.name, systemImage: a.symbol)
                        }
                    }
                }
            }
            Divider()
            Button {
                showControls = true
            } label: {
                Label("展示控制…", systemImage: "slider.horizontal.3")
            }
        } label: {
            // 工具列會把 Label 收成只剩圖示，手組才能保證文字一直在
            HStack(spacing: Space.xs) {
                Image(systemName: "person.2")
                Text("切換身分")
            }
        }
        .accessibilityIdentifier("role-switch")
        .sheet(isPresented: $showControls) { DemoMenuSheet() }
    }

    /// 點目前帳號不做事（Toggle 會想把它關掉，但總要有一個身分）
    private func isCurrent(_ a: DemoAccount) -> Binding<Bool> {
        Binding {
            session.account.id == a.id
        } set: { on in
            guard on else { return }
            session.hasOnboarded = true
            session.account = a
        }
    }
}

struct DemoMenuSheet: View {
    @Environment(Session.self) private var session
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            List {
                Section {
                    Label("目前：\(session.account.role.label)・\(session.account.name)", systemImage: session.account.symbol)
                } footer: {
                    Text("競賽展示用。正式版的一般民眾不會有「切換身分」與這個選單。")
                }
                ForEach([Role.traveler, .merchant, .admin], id: \.self) { role in
                    Section("切換為\(role.label)") {
                        ForEach(DemoAccounts.all.filter { $0.role == role }) { a in
                            Button {
                                session.hasOnboarded = true
                                session.account = a
                                dismiss()
                            } label: {
                                HStack {
                                    Label {
                                        VStack(alignment: .leading) {
                                            Text(a.name).foregroundStyle(.primary)
                                            Text(a.subtitle).font(.caption).foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: a.symbol)
                                    }
                                    Spacer()
                                    if a.id == session.account.id {
                                        Image(systemName: "checkmark").foregroundStyle(Color.brand)
                                    }
                                }
                            }
                        }
                    }
                }
                Section("展示控制") {
                    NavigationLink {
                        TripLoadEditor().navigationTitle("班次載客率")
                    } label: {
                        Label("調整班次預估載客率", systemImage: "slider.horizontal.3")
                    }
                    Toggle(isOn: $session.showDemoTools) {
                        Label("掃碼頁顯示「模擬掃描」", systemImage: "qrcode")
                    }
                    Button {
                        session.hasOnboarded = false
                        dismiss()
                    } label: {
                        Label("重新顯示歡迎頁", systemImage: "sparkles")
                    }
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("重置示範資料", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("展示選單")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("清除所有展示過程產生的紀錄，回到初始示範資料？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("重置", role: .destructive) {
                    SeedData.reset(context)
                    dismiss()
                }
            }
        }
    }
}
