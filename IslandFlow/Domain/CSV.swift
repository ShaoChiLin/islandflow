import Foundation

/// RFC 4180 CSV 解析。全台 93967 原檔有 BOM、CRLF，路線名稱與座標欄裡有被雙引號包住的逗號，
/// 不能沿用 OpenData.csvRows 的 split(",")（K19）。
enum CSV {
    struct Record: Equatable {
        /// 第幾筆記錄，標題列是 1；和檢測報告的 csv_record_including_header 對得起來
        var number: Int
        var fields: [String]
    }

    /// 逐個 Unicode scalar 讀：Swift 的 Character 會把 "\r\n" 當成一個字元，逐字元判斷換行會出錯
    static func parse(_ text: String) -> [Record] {
        var records: [Record] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }

        func endRecord() {
            fields.append(String(field))
            field = String.UnicodeScalarView()
            // 空白行不算一筆記錄
            if !(fields.count == 1 && fields[0].isEmpty) {
                records.append(Record(number: records.count + 1, fields: fields))
            }
            fields = []
        }

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"" where field.isEmpty:
                    inQuotes = true
                case ",":
                    fields.append(String(field))
                    field = String.UnicodeScalarView()
                case "\r":
                    if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                    endRecord()
                case "\n":
                    endRecord()
                default:
                    // 欄位中間出現的引號不是合法 CSV，但照原樣保留，交給上層判斷
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !fields.isEmpty { endRecord() }
        return records
    }
}
