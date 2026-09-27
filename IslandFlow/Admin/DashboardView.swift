import SwiftUI
import SwiftData
import Charts

struct AdminRoot: View {
    let account: DemoAccount
    @State private var tab = LaunchArgs.startTab

    var body: some View {
        TabView(selection: $tab) {
            DashboardView()
                .tabItem { Label("總覽", systemImage: "chart.bar.xaxis") }.tag(0)
            MissionAdminView(account: account)
                .tabItem { Label("任務", systemImage: "flag") }.tag(1)
            RulesView(account: account)
                .tabItem { Label("獎勵規則", systemImage: "slider.horizontal.3") }.tag(2)
            TripsView()
                .tabItem { Label("班次", systemImage: "bus") }.tag(3)
            AdminMoreView(account: account)
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }.tag(4)
        }
    }
}

// MARK: A05 政策效益儀表板

struct DashboardView: View {
    @Environment(\.modelContext) private var context
    // 這些 @Query 只是為了讓資料一變動畫面就重算
    @Query private var parts: [Participation]
    @Query private var reds: [Redemption]
    @Query private var ledger: [LedgerEntry]
    @Query private var rules: [RuleConfig]
    @Query private var missions: [Mission]

    var body: some View {
        let m = FlowService(context: context).dashboard()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        Text("含過去 14 天模擬歷史＋本機即時操作。成本、新增搭乘、地方消費與減碳皆依情境假設估算，不是實測成果。")
                            .font(.caption).foregroundStyle(.secondary)
                        DemoBadge()
                    }

                    liveStrip(m)

                    Text("政策槓桿").font(.headline)
                    HeroTile(title: "每 1 元獎勵帶動的地方消費",
                             value: m.leverage.map { String(format: "%.1f 倍", $0) } ?? "—",
                             caption: "地方消費 \(Fmt.ntd(m.localSpendNTD)) ÷ 獎勵成本 \(Fmt.ntd(m.rewardCostNTD))")

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        StatTile(title: "獎勵成本", value: Fmt.ntd(m.rewardCostNTD), caption: "已發 \(m.coinsIssued) 枚")
                        StatTile(title: "估算新增搭乘", value: String(format: "%.0f 人次", m.addedRides), caption: "完成 \(m.completions) × 增量比例")
                        StatTile(title: "每一新增搭乘成本", value: Fmt.ntd(m.costPerAddedRide), caption: "獎勵成本 ÷ 新增搭乘")
                        StatTile(title: "地方消費帶動", value: Fmt.ntd(m.localSpendNTD), caption: "核銷 \(m.redemptionCount) 筆 × 平均加購")
                        StatTile(title: "離峰占比", value: Fmt.pct(m.offPeakShare), caption: "離峰完成 ÷ 全部完成")
                        StatTile(title: "分流達成", value: "\(m.diversionDelta >= 0 ? "+" : "")\(m.diversionDelta) 人次",
                                 caption: "分流站到訪 \(m.diversionVisits)，基準 \(m.diversionBaseline)")
                        StatTile(title: "估算避免排放", value: Fmt.kg(m.avoidedKg), caption: "非碳權，情境估算")
                        StatTile(title: "兌換率", value: Fmt.pct(m.redemptionRate), caption: "已核銷人數 ÷ 完成人數")
                    }

                    Text("任務漏斗").font(.headline)
                    FunnelChart(m: m)

                    Text("近 14 天每日完成任務").font(.headline)
                    Chart(m.daily) { p in
                        BarMark(x: .value("日期", p.day, unit: .day), y: .value("完成", p.completions), width: .ratio(0.6))
                            .foregroundStyle(Color.brand)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
                    .frame(height: 180)
                    .accessibilityLabel("近 14 天每日完成任務數長條圖")

                    MetricDefinitions()
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("政策效益")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountMenu() } }
        }
    }

    private func liveStrip(_ m: DashboardMetrics) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("本次展示即時產生").font(.caption).foregroundStyle(.secondary)
                Text("完成任務 \(m.liveCompletions) 筆・核銷 \(m.liveRedemptions) 筆")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
        }
        .padding(12)
        .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct HeroTile: View {
    var title: String
    var value: String
    var caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.system(size: 44, weight: .bold)).monospacedDigit()
                .foregroundStyle(Color.brand)
                .contentTransition(.numericText())
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct FunnelChart: View {
    let m: DashboardMetrics

    struct Step: Identifiable {
        var id: String { name }
        var name: String
        var value: Int
        var rate: String
    }

    var body: some View {
        let steps = [
            Step(name: "瀏覽任務", value: m.views, rate: ""),
            Step(name: "加入", value: m.joins, rate: "參加率 \(Fmt.pct(m.joinRate))"),
            Step(name: "完成", value: m.completions, rate: "完成率 \(Fmt.pct(m.completionRate))"),
            Step(name: "兌換", value: m.redeemedUsers, rate: "兌換率 \(Fmt.pct(m.redemptionRate))"),
        ]
        Chart(steps) { s in
            BarMark(x: .value("人數", s.value), y: .value("階段", s.name), height: .ratio(0.6))
                .foregroundStyle(Color.brand)
                .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                .annotation(position: .trailing, alignment: .leading) {
                    Text("\(s.value)  \(s.rate)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: 0...(Double(max(1, m.views)) * 1.45))
        .frame(height: 170)
        .accessibilityLabel("任務漏斗：瀏覽 \(m.views)、加入 \(m.joins)、完成 \(m.completions)、兌換 \(m.redeemedUsers)")
    }
}

struct MetricDefinitions: View {
    var body: some View {
        DisclosureGroup("指標定義") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.defs, id: \.0) { d in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.0).font(.caption.weight(.semibold))
                        Text(d.1).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    static let defs: [(String, String)] = [
        ("任務參加率", "參加人數 ÷ 任務瀏覽人數"),
        ("任務完成率", "完成人數 ÷ 參加人數"),
        ("兌換率", "已核銷人數 ÷ 完成人數"),
        ("獎勵成本", "已發放旅綠幣 × 活動換算價值（示範：1 枚 = NT$1）"),
        ("估算新增搭乘", "完成任務人數 × 情境假設的增量比例"),
        ("每一新增搭乘成本", "獎勵成本 ÷ 估算新增搭乘"),
        ("地方消費帶動", "核銷交易數 × 示範平均加購金額"),
        ("政策槓桿", "地方消費帶動 ÷ 獎勵成本"),
        ("離峰占比", "離峰完成任務數 ÷ 全部完成任務數"),
        ("分流達成", "指定分流站點到訪數 − 基準值"),
        ("估算避免排放量", "路線距離 ×（自用車係數 − 公車係數），以自用小客車為比較基準；不是碳權"),
    ]
}
