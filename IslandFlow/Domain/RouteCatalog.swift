import Foundation
import CryptoKit

// MARK: 唯讀路線目錄（改版方針 P1-A）
//
// 從官方 93967 CSV 匯入「可查詢」的路線與站序，存成 JSON，完全不寫進任務用的 RouteStop／SwiftData。
// 匯入路線 ≠ 開放任務：任務、班次、合作店家、發幣都另外決定。

enum RouteCatalog {
    static let schemaVersion = 1
    static let parserVersion = "93967-csv/1"
    static let datasetID = "93967"
    static let officialCSVURL = "https://media.taiwan.net.tw/od/07_DTD/%E5%8F%B0%E7%81%A3%E5%A5%BD%E8%A1%8C.csv"
    static let bundledFile = "opendata_93967_taiwantrip_all_20260929"
    static let bundledRetrievedOn = "2026-09-29"

    /// 來源只有路線名稱、沒有官方 ID，所以用明確對照表配本地穩定 ID。
    /// 表上沒有的路線可以預覽，但不能匯入；名稱改了會變成「表上的路線消失」，列為待覆核而不是自動改名
    static let localIDs: [String: String] = [
        "北投竹子湖線": "btz",
        "獅山線": "shishan",
        "南庄線": "nanzhuang",
    ]
    /// 第二階段驗收樣本：減少首次匯入錯誤的工程選擇，不是需求或效益排名
    static let defaultSelection = ["btz", "shishan", "nanzhuang"]
    /// 目前只有這條路線有旅綠幣任務
    static let missionRouteIDs: Set<String> = ["btz"]
    static let directions = ["去程", "回程"]
    /// 台灣本島與離島的大致範圍；只用來抓經緯度對調這類明顯錯誤，不證明範圍內的座標就正確
    static let latRange = 21.5...26.5
    static let lonRange = 118.0...122.5
    /// 資料集標示為年更新；超過這個天數就提示可能過舊
    static let staleAfterDays = 400

    static func sourceName(for id: String) -> String? { localIDs.first { $0.value == id }?.key }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ImportIssue: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case columnCount, missingRoute, badDirection, badSequence, missingName, badCoordinate, outOfRegion, duplicateKey

        var label: String {
            switch self {
            case .columnCount: "欄位數不符"
            case .missingRoute: "路線名稱空白"
            case .badDirection: "方向不明"
            case .badSequence: "站序錯誤"
            case .missingName: "站名空白"
            case .badCoordinate: "座標無法使用"
            case .outOfRegion: "座標超出台灣範圍"
            case .duplicateKey: "站序重複"
            }
        }
    }

    var id: String { "\(record)-\(kind.rawValue)" }
    /// 第幾筆記錄（標題列算第 1 筆）
    var record: Int
    var route: String
    var direction: String
    var sequence: String
    var kind: Kind
    var detail: String
    /// true：這列沒有放進站序（無法判斷它屬於哪裡）；false：保留原值、只標記問題
    var isolated: Bool
}

struct CatalogStop: Codable, Hashable {
    var record: Int
    var sequence: Int
    var name: String
    /// 座標有問題時為 nil：站名照列，但地圖與距離估算略過這站，不自動猜座標
    var lat: Double?
    var lon: Double?
    var rawLat: String
    var rawLon: String
    var issues: [ImportIssue.Kind]

    var hasCoordinate: Bool { lat != nil && lon != nil }
}

struct CatalogDirection: Codable, Hashable {
    var name: String
    var stops: [CatalogStop]
}

struct CatalogRoute: Codable, Hashable, Identifiable {
    var id: String
    var sourceName: String
    var directions: [CatalogDirection]
    /// 隔離、沒放進任何方向的記錄編號
    var isolatedRecords: [Int]
    var issueCount: Int

    var hasMissions: Bool { RouteCatalog.missionRouteIDs.contains(id) }
    func direction(_ name: String) -> CatalogDirection? { directions.first { $0.name == name } }
}

struct CatalogSource: Codable, Hashable {
    var datasetID: String
    var url: String
    var fileName: String
    /// 下載日；使用者自選的檔案不知道就留空
    var retrievedOn: String?
    /// 資料集頁面的更新日不等於每條路線的更新日，沒有可靠來源就留空
    var sourceUpdatedOn: String?
    var sha256: String
    var parserVersion: String
}

struct CatalogReport: Codable, Hashable {
    /// 不含標題列
    var records: Int
    var routeNames: Int
    var recordsWithEmbeddedComma: Int
    var issues: [ImportIssue]
}

struct RouteCatalogSnapshot: Codable, Hashable {
    var schemaVersion: Int
    var source: CatalogSource
    var importedAt: Date
    var routes: [CatalogRoute]
    var report: CatalogReport

    func route(_ id: String) -> CatalogRoute? { routes.first { $0.id == id } }

    func isStale(now: Date = .now) -> Bool {
        guard let day = source.retrievedOn, let d = Self.day.date(from: day) else { return false }
        return now.timeIntervalSince(d) > Double(RouteCatalog.staleAfterDays) * 86_400
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// 整份檔案的解析結果，給管理端預覽；確認後再挑路線做成 snapshot
struct ParsedRouteFile {
    struct RouteSummary: Identifiable {
        var id: String { name }
        var name: String
        var rows: Int
        var issues: Int
        var localID: String?
    }

    var source: CatalogSource
    var report: CatalogReport
    /// 依原檔第一次出現的順序
    var routes: [RouteSummary]
    fileprivate var rowsByRoute: [String: [RouteImporter.Row]]

    func snapshot(routeIDs: [String], importedAt: Date = .now) -> RouteCatalogSnapshot {
        let built = routeIDs.compactMap { id -> CatalogRoute? in
            guard let name = RouteCatalog.sourceName(for: id), let rows = rowsByRoute[name] else { return nil }
            let placed = rows.filter { !$0.isolated }
            let directions = RouteCatalog.directions.compactMap { dir -> CatalogDirection? in
                let stops = placed.filter { $0.direction == dir }
                    .sorted { ($0.sequence ?? 0, $0.record) < ($1.sequence ?? 0, $1.record) }
                    .map { CatalogStop(record: $0.record, sequence: $0.sequence ?? 0, name: $0.name, lat: $0.lat, lon: $0.lon,
                                       rawLat: $0.rawLat, rawLon: $0.rawLon, issues: $0.issues.map(\.kind)) }
                return stops.isEmpty ? nil : CatalogDirection(name: dir, stops: stops)
            }
            return CatalogRoute(id: id, sourceName: name, directions: directions,
                                isolatedRecords: rows.filter(\.isolated).map(\.record),
                                issueCount: rows.reduce(0) { $0 + $1.issues.count })
        }
        return RouteCatalogSnapshot(schemaVersion: RouteCatalog.schemaVersion, source: source, importedAt: importedAt,
                                    routes: built, report: report)
    }
}

enum RouteImporter {
    enum ImportError: LocalizedError, Equatable {
        case notUTF8
        case empty
        case missingColumns([String])

        var errorDescription: String? {
            switch self {
            case .notUTF8: "檔案不是 UTF-8 編碼，請下載官方 CSV 原檔"
            case .empty: "檔案沒有資料列"
            case .missingColumns(let c): "缺少欄位：\(c.joined(separator: "、"))；請確認是 93967「台灣好行站點」CSV"
            }
        }
    }

    static let columns = ["路線名稱", "方向性", "站序", "站牌名稱", "緯度", "經度"]

    fileprivate struct Row {
        var record: Int
        var route: String
        var direction: String
        var rawSequence: String
        var sequence: Int?
        var name: String
        var rawLat: String
        var rawLon: String
        var lat: Double?
        var lon: Double?
        var issues: [ImportIssue]
        var isolated: Bool { issues.contains(where: \.isolated) }
    }

    static func parse(data: Data, fileName: String, url: String, retrievedOn: String?) throws -> ParsedRouteFile {
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.notUTF8 }
        let records = CSV.parse(text)
        guard let header = records.first else { throw ImportError.empty }
        let names = header.fields.map { $0.trimmingCharacters(in: .whitespaces) }
        let missing = columns.filter { !names.contains($0) }
        guard missing.isEmpty else { throw ImportError.missingColumns(missing) }
        let idx = Dictionary(uniqueKeysWithValues: columns.map { c in (c, names.firstIndex(of: c)!) })
        let body = records.dropFirst()
        guard !body.isEmpty else { throw ImportError.empty }

        var rows: [Row] = []
        var order: [String] = []
        for rec in body {
            let f = rec.fields
            func col(_ c: String) -> String {
                let i = idx[c]!
                return i < f.count ? f[i].trimmingCharacters(in: .whitespaces) : ""
            }
            var row = Row(record: rec.number, route: col("路線名稱"), direction: col("方向性"), rawSequence: col("站序"),
                          sequence: nil, name: col("站牌名稱"), rawLat: col("緯度"), rawLon: col("經度"), issues: [])
            func issue(_ k: ImportIssue.Kind, _ detail: String, isolated: Bool) {
                row.issues.append(ImportIssue(record: rec.number, route: row.route, direction: row.direction,
                                              sequence: row.rawSequence, kind: k, detail: detail, isolated: isolated))
            }
            if f.count != names.count {
                issue(.columnCount, "欄位數 \(f.count)，應為 \(names.count)；此列隔離", isolated: true)
            }
            if row.route.isEmpty { issue(.missingRoute, "路線名稱空白；此列隔離", isolated: true) }
            if !RouteCatalog.directions.contains(row.direction) {
                issue(.badDirection, "方向「\(row.direction)」不是去程或回程；此列隔離", isolated: true)
            }
            if let s = Int(row.rawSequence), s > 0 {
                row.sequence = s
            } else {
                issue(.badSequence, "站序「\(row.rawSequence)」不是正整數；此列隔離", isolated: true)
            }
            if row.name.isEmpty {
                row.name = "（未提供站名）"
                issue(.missingName, "站名空白", isolated: false)
            }
            if let la = Double(row.rawLat), let lo = Double(row.rawLon), la.isFinite, lo.isFinite,
               (-90...90).contains(la), (-180...180).contains(lo) {
                if RouteCatalog.latRange.contains(la) && RouteCatalog.lonRange.contains(lo) {
                    row.lat = la
                    row.lon = lo
                } else {
                    issue(.outOfRegion, "座標（\(row.rawLat), \(row.rawLon)）超出台灣範圍，可能經緯度對調；保留原值待人工覆核", isolated: false)
                }
            } else {
                issue(.badCoordinate, "緯度「\(row.rawLat)」、經度「\(row.rawLon)」無法使用；保留原值，地圖與距離估算略過此站", isolated: false)
            }
            if !row.route.isEmpty, !order.contains(row.route) { order.append(row.route) }
            rows.append(row)
        }

        // 同路線、方向、站序重複：兩筆都保留，不自動刪任何一站
        let groups = Dictionary(grouping: rows.indices.filter { !rows[$0].isolated }) {
            "\(rows[$0].route)|\(rows[$0].direction)|\(rows[$0].sequence ?? 0)"
        }
        for (_, members) in groups where members.count > 1 {
            for i in members {
                let r = rows[i]
                rows[i].issues.append(ImportIssue(record: r.record, route: r.route, direction: r.direction, sequence: r.rawSequence,
                                                  kind: .duplicateKey,
                                                  detail: "\(r.direction)站序 \(r.rawSequence) 出現 \(members.count) 次；全部保留，待核對來源",
                                                  isolated: false))
            }
        }

        let byRoute = Dictionary(grouping: rows, by: \.route)
        let report = CatalogReport(
            records: body.count,
            routeNames: order.count,
            recordsWithEmbeddedComma: body.filter { $0.fields.contains { $0.contains(",") } }.count,
            issues: rows.flatMap(\.issues).sorted { ($0.record, $0.kind.rawValue) < ($1.record, $1.kind.rawValue) })
        let summaries = order.map { name in
            ParsedRouteFile.RouteSummary(name: name, rows: byRoute[name]?.count ?? 0,
                                         issues: byRoute[name]?.reduce(0) { $0 + $1.issues.count } ?? 0,
                                         localID: RouteCatalog.localIDs[name])
        }
        let source = CatalogSource(datasetID: RouteCatalog.datasetID, url: url, fileName: fileName, retrievedOn: retrievedOn,
                                   sourceUpdatedOn: nil, sha256: RouteCatalog.sha256Hex(data),
                                   parserVersion: RouteCatalog.parserVersion)
        return ParsedRouteFile(source: source, report: report, routes: summaries, rowsByRoute: byRoute)
    }
}

/// 匯入前給管理者看的差異；站點以「路線｜方向｜站序｜同站序第幾筆」對齊
struct CatalogDiff: Equatable {
    var addedRoutes: [String] = []
    var removedRoutes: [String] = []
    var addedStops = 0
    var removedStops = 0
    var changedStops = 0
    var sourceChanged = false

    var isUnchanged: Bool {
        !sourceChanged && addedRoutes.isEmpty && removedRoutes.isEmpty && addedStops == 0 && removedStops == 0 && changedStops == 0
    }

    static func between(_ old: RouteCatalogSnapshot?, _ new: RouteCatalogSnapshot) -> CatalogDiff {
        var d = CatalogDiff()
        let oldRoutes = old?.routes ?? []
        d.sourceChanged = old?.source.sha256 != new.source.sha256
        d.addedRoutes = new.routes.map(\.id).filter { id in !oldRoutes.contains { $0.id == id } }
        d.removedRoutes = oldRoutes.map(\.id).filter { id in !new.routes.contains { $0.id == id } }
        func keyed(_ routes: [CatalogRoute]) -> [String: CatalogStop] {
            var out: [String: CatalogStop] = [:]
            for r in routes {
                for dir in r.directions {
                    var seen: [Int: Int] = [:]
                    for s in dir.stops {
                        let n = seen[s.sequence, default: 0]
                        seen[s.sequence] = n + 1
                        out["\(r.id)|\(dir.name)|\(s.sequence)|\(n)"] = s
                    }
                }
            }
            return out
        }
        let a = keyed(oldRoutes), b = keyed(new.routes)
        for (k, s) in b {
            if let o = a[k] {
                if o.name != s.name || o.rawLat != s.rawLat || o.rawLon != s.rawLon { d.changedStops += 1 }
            } else {
                d.addedStops += 1
            }
        }
        d.removedStops = a.keys.filter { b[$0] == nil }.count
        return d
    }
}
