import Foundation
import CryptoKit

/// 站牌動態碼：綁定路線、班次、站點與到期時間，不含任何個人資料。
struct StationToken: Codable, Equatable {
    var v = 1
    var p = "station"
    var route: String
    var trip: String
    var stop: Int
    var iat: Int
    var exp: Int
    var nonce: String
}

/// 兌換碼：只放憑證 id 與到期時間，品項與扣點一律以伺服端（這裡是本機資料庫）為準。
struct RedeemToken: Codable, Equatable {
    var v = 1
    var p = "redeem"
    var tid: String
    var exp: Int
}

enum TokenError: LocalizedError, Equatable {
    case malformed, badSignature, wrongPurpose, expired

    var errorDescription: String? {
        switch self {
        case .malformed: "無法辨識這個二維碼，請確認掃的是旅綠的碼"
        case .badSignature: "二維碼簽章不符，可能是偽造或被竄改過的碼"
        case .wrongPurpose: "這不是這個步驟要掃的碼"
        case .expired: "這個碼已過期，請掃描畫面上最新的碼"
        }
    }
}

/// 以 HMAC-SHA256 簽章。
///
/// 概念驗證版把金鑰放在 App 內，任何人拆 App 都拿得到——這只用來展示「碼無法被竄改、會過期」的流程，
/// 正式版必須改由伺服器簽發與驗證，金鑰永遠不下發到手機。
enum TokenSigner {
    private static let key = SymmetricKey(data: Data("islandflow-poc-demo-signing-key-v1".utf8))
    static let prefix = "IF1"

    static func sign<T: Encodable>(_ payload: T) -> String {
        let body = try! JSONEncoder.sorted.encode(payload)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return "\(prefix).\(body.base64URL).\(Data(mac).base64URL)"
    }

    static func verify<T: Decodable>(_ token: String, as: T.Type, now: Date = .now,
                                     expiry: (T) -> Int) throws -> T {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3, parts[0] == prefix,
              let body = Data(base64URL: String(parts[1])),
              let sig = Data(base64URL: String(parts[2])) else { throw TokenError.malformed }
        guard HMAC<SHA256>.isValidAuthenticationCode(sig, authenticating: body, using: key) else {
            throw TokenError.badSignature
        }
        guard let payload = try? JSONDecoder().decode(T.self, from: body) else { throw TokenError.wrongPurpose }
        guard expiry(payload) > Int(now.timeIntervalSince1970) else { throw TokenError.expired }
        return payload
    }

    static func verifyStation(_ token: String, now: Date = .now) throws -> StationToken {
        let t = try verify(token, as: StationToken.self, now: now) { $0.exp }
        guard t.p == "station" else { throw TokenError.wrongPurpose }
        return t
    }

    static func verifyRedeem(_ token: String, now: Date = .now) throws -> RedeemToken {
        let t = try verify(token, as: RedeemToken.self, now: now) { $0.exp }
        guard t.p == "redeem" else { throw TokenError.wrongPurpose }
        return t
    }

    /// 站牌碼每 30 秒換一次、有效 ttl 秒，所以任一時刻至少有一個能用、截圖轉傳很快就失效。
    static let rotation = 30

    static func stationToken(route: String, trip: String, stop: Int, ttl: Int, now: Date = .now) -> String {
        let t = Int(now.timeIntervalSince1970)
        let bucket = t - t % rotation
        return sign(StationToken(route: route, trip: trip, stop: stop, iat: bucket, exp: bucket + ttl,
                                 nonce: "\(trip)-\(stop)-\(bucket)"))
    }

    /// 給商家手動輸入用的 6 位數短碼。由金鑰推導而不是亂數，資料庫只需存雜湊。
    static func shortCode(for tokenID: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("short|\(tokenID)".utf8), using: key)
        let n = Data(mac).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return String(format: "%06d", n % 1_000_000)
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
