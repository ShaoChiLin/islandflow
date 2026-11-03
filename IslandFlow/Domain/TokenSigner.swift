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

/// 兌換碼。v1 只放憑證 id 與到期時間，品項與扣點以本機資料庫為準，只能在產生它的同一支手機核銷。
/// v2 另外簽進旅客、品項、店家與點數：沒有後端時，另一支手機的商家端只能靠簽章相信這些內容（K30）。
struct RedeemToken: Codable, Equatable {
    var v = 1
    var p = "redeem"
    var tid: String
    var exp: Int
    var uid: String?
    var rid: String?
    var mid: String?
    var amt: Int?

    /// 四個欄位都有才算能跨機核銷的碼；缺任何一個就當 v1 處理
    var remote: (user: String, reward: String, merchant: String, amount: Int)? {
        guard let uid, let rid, let mid, let amt else { return nil }
        return (uid, rid, mid, amt)
    }
}

/// 核銷完成碼：商家手機核銷「別支手機產生的兌換碼」後顯示，旅客手機回掃才扣自己的帳本。
/// 兩支手機之間沒有連線，這張碼就是商家端「已經把東西交出去」的簽章證明。
struct RedeemReceipt: Codable, Equatable {
    var v = 1
    var p = "redeemDone"
    /// 旅客手機上的兌換憑證 id
    var tid: String
    /// 商家手機上的核銷交易 id，旅客端拿來當扣點的唯一鍵
    var rdm: String
    var uid: String
    var rid: String
    var mid: String
    var amt: Int
    var at: Int
    var exp: Int
}

/// 票券 QR（D34 取代 D33 的動態乘車碼）：模擬台灣好行電子票券上的 QR Code。
/// 旅客先輸入購票序號，App 找出這張票券並顯示它的 QR，上下車都出示同一張、不會換碼。
/// 真實的票券 QR 由售票通路發行，展示版用自己的簽章模擬，綁定序號、參加紀錄、旅客與班次。
struct BoardingPass: Codable, Equatable {
    var v = 2
    var p = "boarding"
    var serial: String
    var pid: String
    var uid: String
    var trip: String
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

    static func verifyReceipt(_ token: String, now: Date = .now) throws -> RedeemReceipt {
        let t = try verify(token, as: RedeemReceipt.self, now: now) { $0.exp }
        guard t.p == "redeemDone" else { throw TokenError.wrongPurpose }
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

    static func verifyBoarding(_ token: String, now: Date = .now) throws -> BoardingPass {
        let t = try verify(token, as: BoardingPass.self, now: now) { $0.exp }
        guard t.p == "boarding" else { throw TokenError.wrongPurpose }
        return t
    }

    /// 內容固定就產生同一張碼，像紙本或電子票券一樣整天不變
    static func boardingPass(serial: String, pid: String, uid: String, trip: String, exp: Int) -> String {
        sign(BoardingPass(serial: serial, pid: pid, uid: uid, trip: trip, exp: exp))
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
