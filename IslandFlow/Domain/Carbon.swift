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
enum CarbonEstimator {
    static func avoidedKg(distanceKm: Double, carFactor: Double, busFactor: Double) -> Double {
        max(0, distanceKm * (carFactor - busFactor))
    }
}
