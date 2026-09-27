import SwiftUI
import SwiftData
import Charts

// MARK: A02 任務管理

struct MissionAdminView: View {
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Query(sort: \Mission.id) private var missions: [Mission]
    @Query(sort: \BusTrip.departure) private var trips: [BusTrip]
    @Query(sort: \RouteStop.sequence) private var stops: [RouteStop]
    @Query private var parts: [Participation]

    var body: some View {
        let service = FlowService(context: context)
        NavigationStack {
            List {
                ForEach(missions) { m in
                    NavigationLink {
                        MissionEditor(mission: m, account: account)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(m.title).font(.headline)
                                Spacer()
                                Text(m.isActive ? "啟用中" : "已停用")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(m.isActive ? Color.brand : .secondary)
                            }
                            Text("\(service.trip(m.tripID)?.departure ?? "") 班次・\(service.stopName(m.startStopSeq)) → \(service.stopName(m.endStopSeq))")
                                .font(.subheadline).foregroundStyle(.secondary)
                            HStack {
                                Text("今日 \(service.joinedToday(m))/\(m.capacity) 人・瀏覽 \(m.viewCount)")
                                Spacer()
                                CoinLabel(amount: service.reward(for: m).coins, font: .subheadline)
                            }
                            .font(.caption)
                        }
                    }
                }
                Section {
                    Button {
                        addMission()
                    } label: {
                        Label("新增任務", systemImage: "plus")
                    }
                } footer: {
                    Text("任務名稱、班次、目的地、名額與啟用狀態都可以在這裡調整，不需要改程式。獎勵由「獎勵規則」統一計算。")
                }
            }
            .navigationTitle("任務管理")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountMenu() } }
        }
    }

    private func addMission() {
        let n = missions.count + 1
        let m = Mission(id: "M-\(UUID().uuidString.prefix(6))", tripID: trips.last?.id ?? "T1310",
                        title: "新任務 \(n)", subtitle: "請填寫任務說明", startStopSeq: 1,
                        endStopSeq: stops.last?.sequence ?? 9, capacity: 20)
        m.isActive = false
        context.insert(m)
        FlowService(context: context).audit(account.id, "mission_create", "mission", m.id, "")
        try? context.save()
    }
}

struct MissionEditor: View {
    @Bindable var mission: Mission
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Query(sort: \BusTrip.departure) private var trips: [BusTrip]
    @Query(sort: \RouteStop.sequence) private var stops: [RouteStop]
    @Query private var rules: [RuleConfig]

    var body: some View {
        let service = FlowService(context: context)
        Form {
            Section("基本資料") {
                TextField("任務名稱", text: $mission.title)
                TextField("說明", text: $mission.subtitle, axis: .vertical)
                TextField("注意事項", text: $mission.notes, axis: .vertical)
                Toggle("啟用", isOn: $mission.isActive)
            }
            Section("班次與站點") {
                Picker("班次", selection: $mission.tripID) {
                    ForEach(trips) { t in Text("\(t.departure)（預估 \(Fmt.pct(t.predictedLoad))）").tag(t.id) }
                }
                Picker("起點", selection: $mission.startStopSeq) {
                    ForEach(stops) { s in Text("\(s.sequence). \(s.shortName)").tag(s.sequence) }
                }
                Picker("目的地", selection: $mission.endStopSeq) {
                    ForEach(stops) { s in Text("\(s.sequence). \(s.shortName)\(s.isDiversionTarget ? "（分流站）" : "")").tag(s.sequence) }
                }
                Stepper("每日名額 \(mission.capacity)", value: $mission.capacity, in: 0...200, step: 5)
            }
            Section("依目前規則計算的獎勵") {
                RewardBreakdownCard(result: service.reward(for: mission), title: "加入者可得")
                    .listRowInsets(EdgeInsets())
            }
        }
        .navigationTitle(mission.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            service.audit(account.id, "mission_update", "mission", mission.id, "\(mission.title)・名額 \(mission.capacity)・\(mission.isActive ? "啟用" : "停用")")
            try? context.save()
        }
    }
}

// MARK: A03 動態獎勵規則

struct RulesView: View {
    let account: DemoAccount
    @Environment(\.modelContext) private var context
    @Query private var rules: [RuleConfig]
    @Query(sort: \Mission.id) private var missions: [Mission]
    @Query private var trips: [BusTrip]

    var body: some View {
        NavigationStack {
            Group {
                if let r = rules.first {
                    RulesForm(rules: r, missions: missions)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("動態獎勵規則")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountMenu() } }
            .onDisappear {
                FlowService(context: context).audit(account.id, "rules_update", "rule_config", "default", "")
                try? context.save()
            }
        }
    }
}

private struct RulesForm: View {
    @Bindable var rules: RuleConfig
    let missions: [Mission]
    @Environment(\.modelContext) private var context

    var body: some View {
        let service = FlowService(context: context)
        Form {
            Section {
                Picker("計算方式", selection: $rules.mode) {
                    ForEach(RewardMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(rules.mode == RewardMode.tier.rawValue
                     ? "依預估載客率分三級，再加離峰或分流加碼。最容易向評審與旅客解釋。"
                     : "mission_score = 0.35×低載客需求 + 0.25×目的地承載 + 0.20×商家量能 + 0.10×天氣 + 0.10×減碳；獎勵 = 40 + 80×分數。")
            }

            Section("即時預覽（改動會立刻反映在旅客端）") {
                ForEach(missions.filter(\.isActive)) { m in
                    let r = service.reward(for: m)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(service.trip(m.tripID)?.departure ?? "") \(m.title)").font(.subheadline.weight(.medium))
                            Spacer()
                            CoinLabel(amount: r.coins, font: .subheadline)
                        }
                        Text(r.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if rules.mode == RewardMode.tier.rawValue {
                Section("載客率級距") {
                    PercentStepper(title: "低載客門檻（低於）", value: $rules.lowThreshold)
                    PercentStepper(title: "高載客門檻（高於）", value: $rules.highThreshold)
                    Stepper("低載客基礎 \(rules.lowBase) 枚", value: $rules.lowBase, in: 0...200, step: 5)
                    Stepper("中載客基礎 \(rules.midBase) 枚", value: $rules.midBase, in: 0...200, step: 5)
                    Stepper("高載客基礎 \(rules.highBase) 枚", value: $rules.highBase, in: 0...200, step: 5)
                }
                Section("加碼") {
                    Stepper("離峰加碼（低載客級距）\(rules.offPeakBonus) 枚", value: $rules.offPeakBonus, in: 0...100, step: 5)
                    Stepper("分流站點加碼（中載客級距）\(rules.diversionBonus) 枚", value: $rules.diversionBonus, in: 0...100, step: 5)
                }
            } else {
                Section("權重（建議合計 1.0，目前 \(String(format: "%.2f", rules.wLoad + rules.wDestination + rules.wMerchant + rules.wWeather + rules.wCarbon))）") {
                    WeightSlider(title: "低載客需求", value: $rules.wLoad)
                    WeightSlider(title: "目的地承載空間", value: $rules.wDestination)
                    WeightSlider(title: "商家接待量能", value: $rules.wMerchant)
                    WeightSlider(title: "天氣適配", value: $rules.wWeather)
                    WeightSlider(title: "減碳效益", value: $rules.wCarbon)
                    WeightSlider(title: "天氣適配分數（模擬）", value: $rules.weatherFit)
                }
            }

            Section("上限與防弊") {
                Stepper("單一任務下限 \(rules.minReward) 枚", value: $rules.minReward, in: 0...200, step: 5)
                Stepper("單一任務上限 \(rules.maxReward) 枚", value: $rules.maxReward, in: 20...300, step: 10)
                Stepper("每人每日最多 \(rules.dailyMissionLimit) 個任務", value: $rules.dailyMissionLimit, in: 1...10)
                Stepper("站牌碼有效 \(rules.stationTokenTTL) 秒", value: $rules.stationTokenTTL, in: 30...600, step: 30)
                Stepper("兌換碼有效 \(rules.redeemTokenTTL / 60) 分鐘", value: $rules.redeemTokenTTL, in: 60...1800, step: 60)
                Toggle("到站時檢查定位（半徑 \(Int(rules.locationRadius)) 公尺）", isOn: $rules.requireLocation)
                Toggle("嚴格檢查發車時間窗", isOn: $rules.enforceSchedule)
            }
        }
    }
}

struct PercentStepper: View {
    var title: String
    @Binding var value: Double

    var body: some View {
        Stepper("\(title) \(Fmt.pct(value))", value: $value, in: 0.05...1.5, step: 0.05)
    }
}

struct WeightSlider: View {
    var title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value)).monospacedDigit()
            }
            Slider(value: $value, in: 0...1, step: 0.05)
        }
    }
}

// MARK: A01 路線與班次

/// 展示記憶點：拖動某班的預估載客率，旅綠幣立刻跟著變。旅客首頁的「展示控制」也是這個畫面。
struct TripLoadEditor: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BusTrip.departure) private var trips: [BusTrip]
    @Query private var missions: [Mission]
    @Query private var rules: [RuleConfig]

    var body: some View {
        let service = FlowService(context: context)
        List {
            Section {
                ForEach(trips) { t in
                    TripRow(trip: t, mission: missions.first { $0.tripID == t.id && $0.isActive }, service: service)
                }
            } header: {
                HStack { Text("各班次預估載客率"); DemoBadge(text: "模擬") }
            } footer: {
                Text("拖動滑桿模擬載客率變化，任務獎勵依規則即時重算；已加入的旅客維持加入時鎖定的獎勵。")
            }
        }
    }
}

private struct TripRow: View {
    @Bindable var trip: BusTrip
    let mission: Mission?
    let service: FlowService

    var body: some View {
        let tier = RewardEngine.tier(for: trip.predictedLoad, rules: RewardRules(service.rules()))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(trip.departure).font(.title3.bold()).monospacedDigit()
                Text(trip.isOffPeak ? "離峰" : "尖峰").font(.caption).foregroundStyle(.secondary)
                LoadBadge(load: trip.predictedLoad, tier: tier)
                Spacer()
                if let mission {
                    CoinLabel(amount: service.reward(for: mission).coins)
                } else {
                    Text("無任務").font(.caption).foregroundStyle(.secondary)
                }
            }
            Slider(value: $trip.predictedLoad, in: 0...1.6, step: 0.01) {
                Text("\(trip.departure) 預估載客率")
            }
            .onChange(of: trip.predictedLoad) { try? service.context.save() }
            if let mission {
                Text(mission.title).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("班次取消", isOn: $trip.isCancelled).font(.caption)
        }
        .padding(.vertical, 4)
    }
}

struct TripsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RouteStop.sequence) private var stops: [RouteStop]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RouteMap().frame(height: 220).listRowInsets(EdgeInsets())
                }
                Section {
                    NavigationLink("調整班次預估載客率") {
                        TripLoadEditor().navigationTitle("班次載客率")
                    }
                }
                Section {
                    RidershipChart()
                } header: {
                    HStack { Text("北投竹子湖線 115 年月搭乘率"); OpenDataBadge() }
                } footer: {
                    Text("資料集 172679（臺北市政府觀光傳播局）。月平均搭乘率超過 100% 代表站位載客、全線已飽和；本案重點因此是把尖峰人流移到離峰班次，而不是單純補量。月資料不代表單一班次即時載客率。")
                }
                Section {
                    ForEach(stops) { s in
                        StopRow(stop: s)
                    }
                } header: {
                    HStack { Text("站點（去程）"); OpenDataBadge(text: "開放資料 93967") }
                } footer: {
                    Text("站名與座標取自交通部觀光署「台灣好行站點資料」。分流站點由管理者指定。")
                }
            }
            .navigationTitle("路線與班次")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { AccountMenu() } }
        }
    }
}

private struct StopRow: View {
    @Bindable var stop: RouteStop
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(stop.sequence). \(stop.name)").font(.subheadline)
            Text(String(format: "%.5f, %.5f", stop.lat, stop.lon)).font(.caption.monospaced()).foregroundStyle(.secondary)
            Toggle("指定分流站點", isOn: $stop.isDiversionTarget)
                .font(.caption)
                .onChange(of: stop.isDiversionTarget) { try? context.save() }
        }
    }
}

struct RidershipChart: View {
    private let rows = OpenData.ridership

    var body: some View {
        let weekday = rows.filter { $0.dayType == "平日" }
        let holiday = rows.filter { $0.dayType == "假日" }
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(weekday) { r in
                    LineMark(x: .value("月", r.month), y: .value("搭乘率", r.occupancy * 100), series: .value("類型", "平日"))
                        .foregroundStyle(Color.brand)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("月", r.month), y: .value("搭乘率", r.occupancy * 100))
                        .foregroundStyle(Color.brand).symbolSize(30)
                }
                ForEach(holiday) { r in
                    LineMark(x: .value("月", r.month), y: .value("搭乘率", r.occupancy * 100), series: .value("類型", "假日"))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
                RuleMark(y: .value("滿載", 100))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .annotation(position: .top, alignment: .leading) { Text("座位滿載 100%").font(.caption2).foregroundStyle(.secondary) }
            }
            .chartXAxis { AxisMarks(values: weekday.map(\.month)) { v in AxisValueLabel { Text("\(v.as(Int.self) ?? 0)月") } } }
            .chartXScale(domain: (weekday.map(\.month).min() ?? 1)...(weekday.map(\.month).max() ?? 12),
                         range: .plotDimension(padding: 14))
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") } } }
            .chartYScale(domain: 80...170)
            .frame(height: 180)
            HStack(spacing: 16) {
                Label("平日", systemImage: "line.diagonal").foregroundStyle(Color.brand)
                Label("假日（虛線）", systemImage: "line.diagonal").foregroundStyle(Color.orange)
            }
            .font(.caption)
            if let latest = weekday.last {
                Text("\(latest.month) 月平日：\(latest.trips) 班、\(latest.passengers.formatted()) 人次、搭乘率 \(Fmt.pct(latest.occupancy))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
