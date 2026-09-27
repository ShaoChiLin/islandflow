import Foundation

/// 讀取 App 內附的兩份政府開放資料 CSV（原檔直接放進 Resources，未經手改）。
enum OpenData {
    struct StopRow: Equatable {
        var route: String
        var direction: String
        var sequence: Int
        var name: String
        var lat: Double
        var lon: Double
    }

    struct RidershipRow: Identifiable, Equatable {
        var id: String { "\(rocYear)-\(month)-\(dayType)" }
        var rocYear: Int
        var month: Int
        var dayType: String
        var trips: Int
        var seats: Int
        var passengers: Int
        var occupancy: Double
    }

    static let stopsFile = "opendata_93967_beitou_zhuzihu_stops"
    static let ridershipFile = "opendata_172679_beitou_zhuzihu_ridership"

    static func csvRows(_ text: String) -> [[String]] {
        text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) } }
    }

    static func parseStops(_ text: String) -> [StopRow] {
        csvRows(text).compactMap { c in
            guard c.count >= 6, let seq = Int(c[2]), let lat = Double(c[4]), let lon = Double(c[5]) else { return nil }
            return StopRow(route: c[0], direction: c[1], sequence: seq, name: c[3], lat: lat, lon: lon)
        }
    }

    static func parseRidership(_ text: String) -> [RidershipRow] {
        csvRows(text).compactMap { c in
            guard c.count >= 7, let y = Int(c[0]), let m = Int(c[1]), let trips = Int(c[3]),
                  let seats = Int(c[4]), let pax = Int(c[5]),
                  let occ = Double(c[6].replacingOccurrences(of: "%", with: "")) else { return nil }
            return RidershipRow(rocYear: y, month: m, dayType: c[2], trips: trips, seats: seats, passengers: pax, occupancy: occ / 100)
        }
    }

    static func bundled(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    static var outboundStops: [StopRow] {
        parseStops(bundled(stopsFile)).filter { $0.direction == "去程" }.sorted { $0.sequence < $1.sequence }
    }

    static var ridership: [RidershipRow] { parseRidership(bundled(ridershipFile)) }
}
