import Foundation

enum Geo {
    static func distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// 沿站序把站點直線距離加總，再乘上道路繞行係數。
    /// 開放資料只有站點座標沒有路線線型，所以只能這樣估；係數在管理端可調。
    static func routeKm(stops: [(lat: Double, lon: Double)], detourFactor: Double) -> Double {
        guard stops.count > 1 else { return 0 }
        var m = 0.0
        for i in 1..<stops.count {
            m += distanceMeters(lat1: stops[i - 1].lat, lon1: stops[i - 1].lon, lat2: stops[i].lat, lon2: stops[i].lon)
        }
        return m / 1000 * detourFactor
    }
}

/// 估算避免排放量。這不是碳權，只是「如果這位旅客原本開車」的情境估算。
/// 管理端儀表板仍用這條（K21）：對所有完成者套自用車基準、負值截零，改版方針 P0-C 要換成下方的 TransportEmission。
enum CarbonEstimator {
    static func avoidedKg(distanceKm: Double, carFactor: Double, busFactor: Double) -> Double {
        max(0, distanceKm * (carFactor - busFactor))
    }
}

enum EmissionFactorUnit: String, Codable {
    /// 每人公里：公車這類已攤到每位乘客的係數，不可再除載客率或同車人數
    case perPassengerKm
    /// 每車公里：私人運具要除以同車人數才是每人排放
    case perVehicleKm
}

struct EmissionFactor: Equatable {
    var kgPerKm: Double
    var unit: EmissionFactorUnit
    /// nil 代表來源尚未核實；畫面要跟著標示範
    var source: String?
    var isDemo: Bool
}

/// 單段交通排放（kgCO₂e／人）。規則依改版方針 P0-C：
/// 缺距離、缺係數、每車公里缺人數時回傳 nil（未知），絕不把未知當 0；差值保留正負，不截零。
enum TransportEmission {
    static func perPersonKg(distanceKm: Double?, factor: EmissionFactor?, occupants: Int? = nil) -> Double? {
        guard let d = distanceKm, d.isFinite, d >= 0,
              let f = factor, f.kgPerKm.isFinite, f.kgPerKm >= 0 else { return nil }
        switch f.unit {
        case .perPassengerKm:
            return d * f.kgPerKm
        case .perVehicleKm:
            guard let n = occupants, n >= 1 else { return nil }
            return d * f.kgPerKm / Double(n)
        }
    }

    /// 基準 − 實際。正值＝此情境下約少排放；負值＝約多排放
    static func signedDifference(baselineKg: Double?, actualKg: Double?) -> Double? {
        guard let b = baselineKg, let a = actualKg else { return nil }
        return b - a
    }
}
