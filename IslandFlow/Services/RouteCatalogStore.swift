import Foundation
import Observation

/// 唯讀路線目錄的存放處：Application Support 裡的一個 JSON 檔，不進 SwiftData。
/// 第一次開啟時用 App 內附的官方原檔建出預設三條路線；之後只有管理者確認匯入才會換版。
@MainActor
@Observable
final class RouteCatalogStore {
    static let shared = RouteCatalogStore()

    private(set) var snapshot: RouteCatalogSnapshot?
    /// 讀檔或建立失敗的原因，畫面照實顯示
    private(set) var problem: String?

    let directory: URL
    private let bundledData: () -> Data?
    private var loaded = false

    init(directory: URL? = nil, bundledData: @escaping () -> Data? = RouteCatalogStore.bundledCSV) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "RouteCatalog", directoryHint: .isDirectory)
        self.bundledData = bundledData
    }

    var fileURL: URL { directory.appending(path: "catalog.json") }
    /// 換版前的上一份，出事時可以手動還原
    var previousURL: URL { directory.appending(path: "catalog.previous.json") }

    nonisolated static func bundledCSV() -> Data? {
        Bundle.main.url(forResource: RouteCatalog.bundledFile, withExtension: "csv").flatMap { try? Data(contentsOf: $0) }
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        load()
    }

    func load() {
        loaded = true
        if let data = try? Data(contentsOf: fileURL) {
            do {
                snapshot = try Self.decoder.decode(RouteCatalogSnapshot.self, from: data)
                problem = nil
            } catch {
                // 壞掉的檔案不覆寫，留著查原因；畫面先用內建快照
                problem = "已存的路線目錄無法讀取，暫時改用 App 內建快照（原檔未覆寫）"
                snapshot = try? builtIn()
            }
            return
        }
        do {
            let s = try builtIn()
            try write(s)
            snapshot = s
            problem = nil
        } catch {
            problem = "無法建立路線目錄：\(error.localizedDescription)"
        }
    }

    func parseBuiltIn() throws -> ParsedRouteFile {
        guard let data = bundledData() else { throw CocoaError(.fileNoSuchFile) }
        return try RouteImporter.parse(data: data, fileName: RouteCatalog.bundledFile + ".csv",
                                       url: RouteCatalog.officialCSVURL, retrievedOn: RouteCatalog.bundledRetrievedOn)
    }

    func builtIn() throws -> RouteCatalogSnapshot {
        try parseBuiltIn().snapshot(routeIDs: RouteCatalog.defaultSelection)
    }

    enum ApplyResult: Equatable { case unchanged, updated }

    /// 內容與目前版本完全相同就不寫檔（重匯同一份快照不會多出任何東西）；
    /// 寫檔失敗會丟錯，畫面上的目錄維持上一版
    @discardableResult
    func apply(_ new: RouteCatalogSnapshot) throws -> ApplyResult {
        if snapshot != nil, CatalogDiff.between(snapshot, new).isUnchanged { return .unchanged }
        try write(new)
        snapshot = new
        problem = nil
        return .updated
    }

    private func write(_ s: RouteCatalogSnapshot) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(s)
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: previousURL)
            try fm.copyItem(at: fileURL, to: previousURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
