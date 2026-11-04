import XCTest
@testable import IslandFlow

/// D36：儀表板匯出 Excel。檔案格式靠解 ZIP 檢查；能不能被 Excel 打開另外用 openpyxl 驗（見開發筆記）。
final class XLSXExportTests: XCTestCase {
    /// 解回不壓縮的 ZIP：檔名 → 內容，順便驗 CRC
    private func unzip(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24 }
        var out: [String: Data] = [:]
        var i = 0
        while i + 4 <= bytes.count, u32(i) == 0x04034b50 {
            let crc = u32(i + 14), size = Int(u32(i + 18)), nameLen = u16(i + 26), extra = u16(i + 28)
            let name = String(decoding: bytes[(i + 30)..<(i + 30 + nameLen)], as: UTF8.self)
            let start = i + 30 + nameLen + extra
            let body = Data(bytes[start..<(start + size)])
            XCTAssertEqual(ZipStore.crc32(body), crc, name)
            out[name] = body
            i = start + size
        }
        XCTAssertEqual(u32(i), 0x02014b50, "本地檔案後面要接中央目錄")
        return out
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(ZipStore.crc32(Data("123456789".utf8)), 0xCBF43926)
    }

    func testColumnNames() {
        XCTAssertEqual(XLSXWriter.columnName(0), "A")
        XCTAssertEqual(XLSXWriter.columnName(25), "Z")
        XCTAssertEqual(XLSXWriter.columnName(26), "AA")
        XCTAssertEqual(XLSXWriter.columnName(701), "ZZ")
    }

    func testEscapeAndSheetNames() {
        XCTAssertEqual(XLSXWriter.escape("A&B<C>\"'\u{1}"), "A&amp;B&lt;C&gt;&quot;&apos;")
        XCTAssertEqual(XLSXWriter.uniqueSheetNames(["指標/總覽", "指標/總覽", ""]), ["指標總覽", "指標總覽(2)", "Sheet3"])
    }

    func testWorkbookStructure() throws {
        let data = XLSXWriter.data(sheets: [
            XLSXSheet(name: "甲", rows: [[.text("名稱"), .text("值")], [.text("旅綠幣"), .number(100)]]),
            XLSXSheet(name: "乙", rows: [[.text("空"), .empty, .number(.nan)]]),
        ])
        let files = try unzip(data)
        XCTAssertEqual(Set(files.keys), ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
                                         "xl/styles.xml", "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"])
        let sheet1 = String(decoding: files["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
        XCTAssertTrue(sheet1.contains("<c r=\"A2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">旅綠幣</t></is></c>"))
        XCTAssertTrue(sheet1.contains("<c r=\"B2\"><v>100.0</v></c>"))
        XCTAssertTrue(sheet1.contains("<c r=\"A1\" t=\"inlineStr\" s=\"1\">"), "標題列粗體")
        let sheet2 = String(decoding: files["xl/worksheets/sheet2.xml"]!, as: UTF8.self)
        XCTAssertFalse(sheet2.contains("C1"), "NaN 不寫進檔案，否則 Excel 會說損毀")
        let workbook = String(decoding: files["xl/workbook.xml"]!, as: UTF8.self)
        XCTAssertTrue(workbook.contains("name=\"乙\" sheetId=\"2\""))
        // 每個 XML 都要能被解析
        for (name, body) in files { XCTAssertTrue(XMLParser(data: body).parse(), name) }
    }

    func testDashboardExportMatchesMetrics() throws {
        var m = DashboardMetrics()
        m.completions = 10; m.coinsIssued = 1000; m.rewardCostNTD = 1000; m.addedRides = 3.5
        m.costPerAddedRide = 1000 / 3.5; m.redemptionCount = 4; m.localSpendNTD = 720; m.leverage = 0.72
        m.offPeakShare = 1; m.redeemedUsers = 4; m.joins = 20; m.views = 50
        m.daily = [DailyPoint(day: Date(timeIntervalSince1970: 1_793_750_400), completions: 2, redemptions: 1)]
        let sheets = DashboardExport.sheets(m, assumptions: MetricAssumptions(), exportedAt: .now)
        XCTAssertEqual(sheets.map(\.name), ["說明", "指標總覽", "任務漏斗", "每日趨勢", "估算假設"])

        let indicators = sheets[1].rows
        XCTAssertEqual(indicators[0].first, .text("指標"))
        let cost = indicators.first { $0.first == .text("每一新增搭乘成本") }!
        XCTAssertEqual(cost[1], .number(285.71), "和畫面上的卡片同一份數字，四捨五入到小數兩位")
        let redemption = indicators.first { $0.first == .text("兌換率") }!
        XCTAssertEqual(redemption[1], .number(40), "百分比換成 0～100")
        XCTAssertTrue(indicators.allSatisfy { $0.count == 5 }, "每一列都有計算方式與資料性質")
        XCTAssertEqual(sheets[3].rows.count, 2)

        // 示範聲明一定要跟著檔案走
        let about = sheets[0].rows.flatMap { $0 }
        XCTAssertTrue(about.contains { if case .text(let s) = $0 { s.contains("不是實測成果") } else { false } })
        XCTAssertTrue(DashboardExport.fileName(at: .now).hasSuffix(".xlsx"))

        // 給 openpyxl 驗證用：寫到暫存資料夾
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("islandflow-dashboard-test.xlsx")
        try DashboardExport.data(m, assumptions: MetricAssumptions(), exportedAt: .now).write(to: url)
        print("XLSX_TEST_FILE \(url.path)")
    }
}
