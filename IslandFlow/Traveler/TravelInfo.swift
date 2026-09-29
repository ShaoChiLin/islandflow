import SwiftUI
import SwiftData
import MapKit

// MARK: 旅行便利資訊：上車站、官方時刻、回程、交通排放估算
//
// App 沒有班表與到站時間資料，所以這裡只給「去哪查」，不自己編時間（改版方針 P0-B）。

enum OfficialInfo {
    static let taiwanTripURL = URL(string: "https://www.taiwantrip.com.tw/Frontend/")!
    static let stopsDatasetName = "觀光署開放資料 93967「台灣好行站點」"
    /// App 內附北投竹子湖線站點 CSV 的取得日期
    static let bundledStopsRetrieved = "2026-09"
}

enum MapsLink {
    /// 只在旅客按下按鈕時才開外部地圖；本 App 不因此要求定位權限
    @MainActor
    static func openDirections(to name: String, lat: Double, lon: Double) {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let item: MKMapItem
        if #available(iOS 26.0, *) {
            item = MKMapItem(location: CLLocation(latitude: lat, longitude: lon), address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        }
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }
}

@MainActor
extension FlowService {
    /// 公車係數目前是示範值、來源未核實（K8），畫面一律標示範
    func busEmissionFactor() -> EmissionFactor {
        EmissionFactor(kgPerKm: rules().busFactor, unit: .perPassengerKm, source: nil, isDemo: true)
    }

    /// 任務這一段搭公車的每人交通排放估算。距離是站點直線 × 繞行係數，只算去程這一段
    func segmentEmission(_ m: Mission) -> (km: Double, kg: Double?) {
        let km = distanceKm(m)
        return (km, TransportEmission.perPersonKg(distanceKm: km > 0 ? km : nil, factor: busEmissionFactor()))
    }
}

enum EmissionText {
    static func kg(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v < 1 ? 2 : 1))) + " kgCO₂e"
    }

    static func km(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(1))) + " 公里"
    }

    static func summary(km: Double, kg: Double?) -> String {
        guard let kg else { return "本段交通排放：尚無可靠估算" }
        return "本段約 \(Self.km(km))，搭公車排放估算約 \(Self.kg(kg))"
    }
}

/// 任務詳情「如何估算」展開區與完成頁明細共用
struct EmissionMethodNote: View {
    var factor: EmissionFactor

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("・距離：站點直線距離 × 繞行係數推估，不是實際行駛里程，可信度低")
            Text("・公車係數：\(factor.kgPerKm.formatted(.number.precision(.fractionLength(3)))) kgCO₂e／人公里，\(factor.source ?? "示範值，來源尚未核實")")
            Text("・只算這一段搭車，不含回程、住宿與餐飲")
            Text("・與開車比較需要知道你原本怎麼來；本版尚未提供選填，所以不計算減碳量，也不是碳權")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// 任務詳情：上車站與官方時刻入口
struct BoardingInfoCard: View {
    let from: RouteStop?
    let departure: String?

    var body: some View {
        Card {
            Text("上車資訊").font(.headline)
            VStack(alignment: .leading, spacing: Space.xs) {
                Label(from.map { "上車站：\($0.shortName)" } ?? "上車站資料缺漏", systemImage: "mappin.and.ellipse")
                Label(departure.map { "\($0) 發車（示範班次）・抵達時間請查官方時刻" } ?? "班次時間請查官方時刻",
                      systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            AdaptiveStack {
                if let s = from {
                    Button {
                        MapsLink.openDirections(to: s.shortName, lat: s.lat, lon: s.lon)
                    } label: {
                        Label("前往上車站", systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
                    .buttonStyle(.secondaryAction)
                    .accessibilityHint("開啟「地圖」App 規劃路線")
                    .accessibilityIdentifier("open-boarding-stop")
                }
                Link(destination: OfficialInfo.taiwanTripURL) {
                    Label("官方路線／時刻表", systemImage: "safari")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, Space.m)
                        .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .accessibilityIdentifier("official-timetable")
            }
            Text("站點座標取自\(OfficialInfo.stopsDatasetName)。本 App 沒有班表與即時到站資料。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// 完成頁的交通排放明細：只呈現實際搭車估算，不宣稱減碳
struct EmissionReceiptCard: View {
    let mission: Mission
    @Environment(\.modelContext) private var context

    var body: some View {
        let service = FlowService(context: context)
        let (km, kg) = service.segmentEmission(mission)
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Label("本段交通排放", systemImage: "leaf").font(.subheadline.weight(.semibold))
                DemoBadge(text: "示範估算")
            }
            row("路段", "\(service.stopName(mission.startStopSeq)) → \(service.stopName(mission.endStopSeq))，約 \(EmissionText.km(km))")
            row("方式", "台灣好行公車")
            row("估算", kg.map { "約 \(EmissionText.kg($0))／人" } ?? "尚無可靠估算")
            row("比較", "未提供你原本的交通方式，不計算減碳量")
            DisclosureGroup("如何估算") {
                EmissionMethodNote(factor: service.busEmissionFactor()).padding(.top, Space.xs)
            }
            .font(.caption.weight(.medium))
            .tint(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(Color.inset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityIdentifier("emission-receipt")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(title).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

// MARK: 回程

/// 回程用官方資料的「回程」方向站序；沒有當日班表，所以不寫末班時間，只提醒去官方查
struct ReturnTripView: View {
    let mission: Mission
    @Environment(\.modelContext) private var context

    var body: some View {
        let service = FlowService(context: context)
        let dest = service.stop(mission.endStopSeq)
        let back = OpenData.stops(direction: "回程")
        // 同一路線內，以完整站名找回程上車站；找不到就列整條回程，不自己猜
        let boardIndex = back.firstIndex { $0.name == dest?.name }
        let shown = boardIndex.map { Array(back[$0...]) } ?? back

        List {
            Section {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(boardIndex != nil ? "在「\(dest?.shortName ?? "")」搭回程" : "回程站點")
                        .font(.title3.bold())
                    Label("末班車時間：本 App 沒有當日班表，出發前請查官方時刻表", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("return-last-bus-note")
                }
                .padding(.vertical, Space.xs)
                if let first = shown.first {
                    Button {
                        MapsLink.openDirections(to: SeedData.shortNames[first.name] ?? first.name, lat: first.lat, lon: first.lon)
                    } label: {
                        Label("在地圖開啟回程上車站", systemImage: "map")
                    }
                }
                Link(destination: OfficialInfo.taiwanTripURL) {
                    Label("官方路線／時刻表", systemImage: "safari")
                }
            }
            Section {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: Space.m) {
                        Text("\(s.sequence)")
                            .font(.caption.bold()).monospacedDigit()
                            .frame(width: 24, height: 24)
                            .background(i == 0 ? Color.brand : Color.secondary.opacity(0.18), in: Circle())
                            .foregroundStyle(i == 0 ? Color.white : Color.primary)
                        Text(SeedData.shortNames[s.name] ?? s.name).font(.subheadline)
                        if i == 0 { Text("上車").font(.caption.weight(.semibold)).foregroundStyle(Color.brand) }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("回程停靠順序（官方回程站序）")
            } footer: {
                Text("資料：\(OfficialInfo.stopsDatasetName)，App 內建快照（\(OfficialInfo.bundledStopsRetrieved) 取得）。站點可能已異動，班次依平假日與天候調整，請以官方公告為準。")
            }
        }
        .navigationTitle("回程資訊")
        .navigationBarTitleDisplayMode(.inline)
    }
}
