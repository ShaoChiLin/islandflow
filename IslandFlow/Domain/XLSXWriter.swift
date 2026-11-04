import Foundation

/// 最小的 .xlsx 產生器（D36）。xlsx 就是一包 XML 用 ZIP 包起來；這裡只做內嵌字串、數字、
/// 標題列粗體與欄寬，ZIP 用不壓縮（stored）的格式，所以不必引入第三方套件。
/// Excel、Numbers、Google 試算表都打得開；公式、圖表、合併儲存格一律不做。
enum XLSXCell: Equatable {
    case text(String)
    case number(Double)
    case empty
}

struct XLSXSheet {
    var name: String
    var rows: [[XLSXCell]]
    /// 以字元寬度計；沒給的欄位用 Excel 預設寬度
    var columnWidths: [Double] = []
    /// 前幾列用粗體當標題
    var headerRows = 1
}

enum XLSXWriter {
    static let contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    static func data(sheets: [XLSXSheet]) -> Data {
        var files: [(String, Data)] = []
        let n = sheets.count
        files.append(("[Content_Types].xml", xml("""
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \((0..<n).map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())\
        </Types>
        """)))
        files.append(("_rels/.rels", xml("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """)))
        let names = uniqueSheetNames(sheets.map(\.name))
        files.append(("xl/workbook.xml", xml("""
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(names.enumerated().map { "<sheet name=\"\(escape($1))\" sheetId=\"\($0 + 1)\" r:id=\"rId\($0 + 1)\"/>" }.joined())</sheets>\
        </workbook>
        """)))
        files.append(("xl/_rels/workbook.xml.rels", xml("""
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \((0..<n).map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())\
        <Relationship Id="rId\(n + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """)))
        files.append(("xl/styles.xml", xml("""
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """)))
        for (i, sheet) in sheets.enumerated() {
            files.append(("xl/worksheets/sheet\(i + 1).xml", xml(sheetXML(sheet))))
        }
        return ZipStore.archive(files)
    }

    static func sheetXML(_ sheet: XLSXSheet) -> String {
        var out = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if !sheet.columnWidths.isEmpty {
            out += "<cols>" + sheet.columnWidths.enumerated().map {
                "<col min=\"\($0 + 1)\" max=\"\($0 + 1)\" width=\"\($1)\" customWidth=\"1\"/>"
            }.joined() + "</cols>"
        }
        out += "<sheetData>"
        for (r, row) in sheet.rows.enumerated() {
            let style = r < sheet.headerRows ? " s=\"1\"" : ""
            out += "<row r=\"\(r + 1)\">"
            for (c, cell) in row.enumerated() {
                let ref = "\(columnName(c))\(r + 1)"
                switch cell {
                case .text(let s):
                    out += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(escape(s))</t></is></c>"
                case .number(let v) where v.isFinite:
                    out += "<c r=\"\(ref)\"\(style)><v>\(v)</v></c>"
                case .number, .empty:
                    break
                }
            }
            out += "</row>"
        }
        return out + "</sheetData></worksheet>"
    }

    /// 0 → A、25 → Z、26 → AA
    static func columnName(_ index: Int) -> String {
        var n = index + 1, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(65 + r)!) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// Excel 的工作表名稱最多 31 字、不能有 []:*?/\，也不能重複
    static func uniqueSheetNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.enumerated().map { i, raw in
            var base = String(raw.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            if base.isEmpty { base = "Sheet\(i + 1)" }
            var name = base, k = 2
            while seen.contains(name) { name = String(base.prefix(28)) + "(\(k))"; k += 1 }
            seen.insert(name)
            return name
        }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            // XML 1.0 不允許的控制字元直接丟掉，否則 Excel 會說檔案損毀
            case _ where ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r": continue
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private static func xml(_ body: String) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + body).utf8)
    }
}

/// 不壓縮的 ZIP。檔名都是 ASCII，檔案也小，用 stored 就夠，Excel 一樣接受
enum ZipStore {
    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data(), central = Data()
        // 固定 1980-01-01 00:00，同樣內容產生同樣的檔案，測試才比得出來
        let dosTime: UInt16 = 0, dosDate: UInt16 = 0x21
        for (name, data) in files {
            let nameData = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            out.append(le32(0x04034b50)); out.append(le16(20)); out.append(le16(0)); out.append(le16(0))
            out.append(le16(dosTime)); out.append(le16(dosDate))
            out.append(le32(crc)); out.append(le32(UInt32(data.count))); out.append(le32(UInt32(data.count)))
            out.append(le16(UInt16(nameData.count))); out.append(le16(0))
            out.append(nameData); out.append(data)

            central.append(le32(0x02014b50)); central.append(le16(20)); central.append(le16(20))
            central.append(le16(0)); central.append(le16(0)); central.append(le16(dosTime)); central.append(le16(dosDate))
            central.append(le32(crc)); central.append(le32(UInt32(data.count))); central.append(le32(UInt32(data.count)))
            central.append(le16(UInt16(nameData.count))); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
            central.append(nameData)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.append(le32(0x06054b50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(UInt16(files.count))); out.append(le16(UInt16(files.count)))
        out.append(le32(UInt32(central.count))); out.append(le32(cdOffset)); out.append(le16(0))
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
