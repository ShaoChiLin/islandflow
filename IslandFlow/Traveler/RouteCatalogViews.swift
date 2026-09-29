import SwiftUI
import MapKit

// MARK: 旅客端路線目錄（唯讀）
//
// 旅客只需要「選路線看站」，不用碰 CSV。沒有任務的路線明講「目前無旅綠幣任務」，
// 不生成班次、店家或任務。

struct RouteCatalogListView: View {
    @State private var store = RouteCatalogStore.shared

    var body: some View {
        List {
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let s = store.snapshot {
                Section {
                    ForEach(s.routes) { r in
                        NavigationLink {
                            RouteCatalogDetailView(route: r, snapshot: s)
                        } label: {
                            RouteCatalogRow(route: r)
                        }
                        .accessibilityIdentifier("catalog-route-\(r.id)")
                    }
                } footer: {
                    CatalogSourceFooter(snapshot: s)
                }
            } else if store.problem == nil {
                ProgressView()
            }
        }
        .navigationTitle("台灣好行路線")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.loadIfNeeded() }
    }
}

private struct RouteCatalogRow: View {
    let route: CatalogRoute

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(route.sourceName).font(.headline)
            Text(route.directions.map { "\($0.name) \($0.stops.count) 站" }.joined(separator: "・"))
                .font(.caption).foregroundStyle(.secondary)
            AdaptiveStack {
                RouteStatusTag(route: route)
                if route.issueCount > 0 {
                    Label("資料待覆核 \(route.issueCount) 筆", systemImage: "exclamationmark.triangle")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, Space.xs)
    }
}

struct RouteStatusTag: View {
    let route: CatalogRoute

    var body: some View {
        Text(route.hasMissions ? "有旅綠幣任務" : "可查路線・目前無旅綠幣任務")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((route.hasMissions ? Color.brand : Color.secondary).opacity(0.14), in: Capsule())
            .foregroundStyle(route.hasMissions ? Color.brand : Color.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

struct CatalogSourceFooter: View {
    let snapshot: RouteCatalogSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if snapshot.isStale() {
                Label("資料快照已超過一年，站點可能已異動，請查官方資訊", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            Text("資料：\(OfficialInfo.stopsDatasetName)，\(snapshot.source.retrievedOn.map { "\($0) 下載的快照" } ?? "下載日未提供")，App 內離線可查。只有站名與站序，沒有班表、票價或即時資訊；出發前請查官方公告。")
        }
        .font(.caption)
    }
}

struct RouteCatalogDetailView: View {
    let route: CatalogRoute
    let snapshot: RouteCatalogSnapshot
    @State private var direction: String

    init(route: CatalogRoute, snapshot: RouteCatalogSnapshot) {
        self.route = route
        self.snapshot = snapshot
        _direction = State(initialValue: route.directions.first?.name ?? "去程")
    }

    var body: some View {
        let dir = route.direction(direction)
        let stops = dir?.stops ?? []
        List {
            Section {
                RouteStatusTag(route: route)
                if route.hasMissions {
                    Text("本路線有旅綠幣任務，回「探索」首頁查看班次。").font(.subheadline)
                } else {
                    Text("目前沒有旅綠幣任務，也沒有合作店家；這裡只提供站點查詢。").font(.subheadline).foregroundStyle(.secondary)
                }
                Link(destination: OfficialInfo.taiwanTripURL) {
                    Label("官方路線／時刻表", systemImage: "safari")
                }
            }
            if route.directions.count > 1 {
                Picker("方向", selection: $direction) {
                    ForEach(route.directions, id: \.name) { Text($0.name).tag($0.name) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("catalog-direction")
            }
            Section {
                CatalogRouteMap(stops: stops)
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
            } footer: {
                if stops.contains(where: { !$0.hasCoordinate }) {
                    Text("有站點座標無法使用，地圖在該站斷開，不自動補座標。")
                }
            }
            Section {
                ForEach(Array(stops.enumerated()), id: \.offset) { _, s in
                    CatalogStopRow(stop: s)
                }
            } header: {
                Text("\(direction) \(stops.count) 站（依官方站序）")
            } footer: {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if !route.isolatedRecords.isEmpty {
                        Text("另有 \(route.isolatedRecords.count) 筆記錄因站序或方向無法判斷而隔離，沒有列入。")
                    }
                    Text("去程與回程各自的站序，不互相推算。")
                    CatalogSourceFooter(snapshot: snapshot)
                }
            }
        }
        .navigationTitle(route.sourceName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CatalogStopRow: View {
    let stop: CatalogStop

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Text("\(stop.sequence)")
                .font(.caption.bold()).monospacedDigit()
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.name).font(.subheadline)
                ForEach(stop.issues, id: \.self) { k in
                    Label(k.label + (k == .badCoordinate || k == .outOfRegion ? "：此站不畫在地圖上" : "：待核對來源"),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 缺座標的站不畫、線段在那裡斷開，避免把錯誤座標連成一條看起來很合理的線
struct CatalogRouteMap: View {
    let stops: [CatalogStop]

    var body: some View {
        let segments = stops.split { !$0.hasCoordinate }.map { seg in
            seg.map { CLLocationCoordinate2D(latitude: $0.lat!, longitude: $0.lon!) }
        }
        Map(initialPosition: .automatic) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, coords in
                MapPolyline(coordinates: coords).stroke(Color.brand, lineWidth: 4)
            }
            ForEach(Array(stops.enumerated()), id: \.offset) { _, s in
                if let lat = s.lat, let lon = s.lon {
                    Annotation(s.name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                        ZStack {
                            Circle().fill(Color.brand).frame(width: 18, height: 18)
                            Text("\(s.sequence)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // 切換方向或路線時重建地圖，讓鏡頭重新對準這組站點
        .id(stops.map(\.record))
    }
}
