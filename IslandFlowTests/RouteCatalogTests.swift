import XCTest
import SwiftData
@testable import IslandFlow

final class CSVTests: XCTestCase {
    func testBOMCRLFQuotedCommaAndEscapedQuote() {
        let text = "\u{FEFF}a,b\r\n\"x,y\",\"he said \"\"hi\"\"\"\r\n\r\n1,\n"
        XCTAssertEqual(CSV.parse(text), [
            .init(number: 1, fields: ["a", "b"]),
            .init(number: 2, fields: ["x,y", "he said \"hi\""]),
            .init(number: 3, fields: ["1", ""]),
        ])
    }

    func testNewlineInsideQuotesStaysInField() {
        XCTAssertEqual(CSV.parse("\"line1\nline2\",z\n").first?.fields, ["line1\nline2", "z"])
    }
}

/// 改版方針 P1-A 驗收：以 App 內附的官方原檔（2026-09-29 快照）驗證
@MainActor
final class RouteCatalogTests: XCTestCase {
    private func parsed() throws -> ParsedRouteFile {
        let data = try XCTUnwrap(RouteCatalogStore.bundledCSV())
        return try RouteImporter.parse(data: data, fileName: "t.csv", url: RouteCatalog.officialCSVURL, retrievedOn: "2026-09-29")
    }

    private func tempStore() -> RouteCatalogStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "RouteCatalogTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return RouteCatalogStore(directory: dir)
    }

    func testOfficialFileReportMatchesAudit() throws {
        let p = try parsed()
        XCTAssertEqual(p.source.sha256, "bf03103e22be74476c962fe04fcdd25bbf31e5f094fa5895acda78dd3f6c46d2")
        XCTAssertEqual(p.report.records, 2585)
        XCTAssertEqual(p.report.routeNames, 97)
        XCTAssertEqual(p.report.recordsWithEmbeddedComma, 32)
        XCTAssertEqual(p.report.issues.filter { $0.kind == .badCoordinate }.count, 7)
        XCTAssertEqual(p.report.issues.filter { $0.kind == .duplicateKey }.count, 2, "一組重複鍵、兩筆都標記")
        XCTAssertTrue(p.report.issues.allSatisfy { !$0.isolated }, "這份原檔沒有必須隔離的列")
    }

    func testBadRowsAreKeptWithReasonsNotGuessed() throws {
        let p = try parsed()
        let sunMoon = try XCTUnwrap(p.report.issues.first { $0.record == 130 })
        XCTAssertEqual(sunMoon.route, "日月潭線")
        XCTAssertEqual(sunMoon.kind, .badCoordinate)
        XCTAssertTrue(sunMoon.detail.contains("1234120.964"), "原值要保留在報告裡")
        let dup = p.report.issues.filter { $0.kind == .duplicateKey }
        XCTAssertEqual(Set(dup.map(\.route)), ["雲林草嶺線(周三-周日運行)"])
        XCTAssertEqual(Set(dup.map(\.sequence)), ["19"])
    }

    func testRouteNameWithAsciiCommaIsParsedWhole() throws {
        let names = try parsed().routes.map(\.name)
        XCTAssertTrue(names.contains("南竿-東線北海坑道線(上午,郵輪式公車)"))
        XCTAssertFalse(names.contains("南竿-東線北海坑道線(上午"))
    }

    func testThreeSampleRoutesKeepDirectionsSeparate() throws {
        let s = try parsed().snapshot(routeIDs: RouteCatalog.defaultSelection)
        XCTAssertEqual(s.routes.map(\.id), ["btz", "shishan", "nanzhuang"])
        let counts = s.routes.map { r in r.directions.map(\.stops.count) }
        XCTAssertEqual(counts, [[9, 9], [15, 15], [12, 12]])
        let btz = try XCTUnwrap(s.route("btz"))
        XCTAssertEqual(btz.direction("去程")?.stops.first?.name, "捷運北投站")
        XCTAssertEqual(btz.direction("回程")?.stops.first?.name, "竹子湖")
        // 獅山線回程有去程沒有的站：證明不是把去程倒過來
        let shishan = try XCTUnwrap(s.route("shishan"))
        XCTAssertTrue(shishan.direction("回程")!.stops.contains { $0.name == "恩霖堂站" })
        XCTAssertFalse(shishan.direction("去程")!.stops.contains { $0.name == "恩霖堂站" })
        XCTAssertTrue(s.routes.allSatisfy { $0.issueCount == 0 })
        XCTAssertTrue(btz.hasMissions)
        XCTAssertFalse(shishan.hasMissions)
    }

    func testUnmappedRouteIsNotImported() throws {
        XCTAssertTrue(try parsed().snapshot(routeIDs: ["sun-moon-lake"]).routes.isEmpty)
    }

    func testReimportSameSnapshotIsIdempotentAndReopensOffline() throws {
        let store = tempStore()
        store.load()
        let first = try XCTUnwrap(store.snapshot)
        XCTAssertEqual(first.routes.count, 3)
        let bytes = try Data(contentsOf: store.fileURL)

        XCTAssertEqual(try store.apply(store.builtIn()), .unchanged)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes, "相同快照不得改寫或倍增")

        let fewer = try parsed().snapshot(routeIDs: ["btz", "shishan"])
        XCTAssertEqual(CatalogDiff.between(first, fewer).removedRoutes, ["nanzhuang"])
        XCTAssertEqual(try store.apply(fewer), .updated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.previousURL.path), "換版前要留上一版")

        // 重開（新的 store、同一個資料夾、不讀內建檔）
        let reopened = RouteCatalogStore(directory: store.directory, bundledData: { nil })
        reopened.load()
        XCTAssertEqual(reopened.snapshot?.routes.map(\.id), ["btz", "shishan"])
        XCTAssertNil(reopened.problem)
    }

    func testFailedWriteKeepsPreviousVersion() throws {
        let store = tempStore()
        store.load()
        let before = try XCTUnwrap(store.snapshot)
        // 讓 catalog.json 變成資料夾，寫檔一定失敗
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.apply(try parsed().snapshot(routeIDs: ["btz"])))
        XCTAssertEqual(store.snapshot, before)
    }

    func testCorruptFileFallsBackWithoutOverwriting() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        store.load()
        XCTAssertNotNil(store.problem)
        XCTAssertEqual(store.snapshot?.routes.count, 3)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), Data("not json".utf8))
    }

    func testCodableRoundTripAndStaleness() throws {
        var s = try parsed().snapshot(routeIDs: RouteCatalog.defaultSelection)
        s.importedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let back = try RouteCatalogStore.decoder.decode(RouteCatalogSnapshot.self, from: RouteCatalogStore.encoder.encode(s))
        XCTAssertEqual(back, s)
        let retrieved = try XCTUnwrap(RouteCatalogSnapshot.day.date(from: "2026-09-29"))
        XCTAssertFalse(s.isStale(now: retrieved.addingTimeInterval(30 * 86_400)))
        XCTAssertTrue(s.isStale(now: retrieved.addingTimeInterval(401 * 86_400)))
    }

    func testCatalogDoesNotTouchMissionData() throws {
        let container = try AppSchema.makeContainer(inMemory: true)
        SeedData.seed(container.mainContext)
        let ctx = container.mainContext
        let stops = try ctx.fetchCount(FetchDescriptor<RouteStop>())
        let ledger = try ctx.fetchCount(FetchDescriptor<LedgerEntry>())
        let store = tempStore()
        store.load()
        try store.apply(try parsed().snapshot(routeIDs: ["shishan"]))
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<RouteStop>()), stops)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<LedgerEntry>()), ledger)
        XCTAssertEqual(OpenData.outboundStops.count, 9, "北投任務仍用原本的站點資料")
    }
}
