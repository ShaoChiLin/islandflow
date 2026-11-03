import Foundation
import Observation

enum Role: String {
    case traveler, driver, merchant, admin

    var label: String {
        switch self {
        case .traveler: "一般民眾"
        case .driver: "司機"
        case .merchant: "商家"
        case .admin: "政府"
        }
    }

    /// 「切換身分」選單的順序，照旅程先後：搭車 → 司機驗票 → 店家兌換 → 政府看成效
    static let menuOrder: [Role] = [.traveler, .driver, .merchant, .admin]
}

/// 上下車怎麼驗證（D33）。預設司機掃旅客的乘車碼；站牌動態碼保留，兩支手機展示或司機端出狀況時切回去
enum CheckinMode: String {
    case driver, station
}

/// 示範帳號。概念驗證版不做真實登入，但權限範圍照正式版切：
/// 商家只看得到自己的獎品與核銷紀錄，旅客進不了管理功能。
struct DemoAccount: Identifiable, Hashable {
    var id: String
    var role: Role
    var name: String
    var subtitle: String
    var merchantID: String?
    var symbol: String
}

enum DemoAccounts {
    static let all: [DemoAccount] = [
        .init(id: "t-demo", role: .traveler, name: "小綠", subtitle: "示範旅客", symbol: "figure.walk"),
        .init(id: "t-demo2", role: .traveler, name: "阿山", subtitle: "第二位示範旅客（驗證名額與帳本分開）", symbol: "figure.hiking"),
        .init(id: "d-bus9", role: .driver, name: "小9 司機", subtitle: "北投竹子湖線・示範司機端", symbol: "bus"),
        .init(id: "m-lake", role: .merchant, name: "湖田小農市集", subtitle: "竹子湖站・虛構示範商家", merchantID: "m-lake", symbol: "leaf"),
        .init(id: "m-tea", role: .merchant, name: "山嵐茶屋", subtitle: "陽明書屋站・虛構示範商家", merchantID: "m-tea", symbol: "cup.and.saucer"),
        .init(id: "m-onsen", role: .merchant, name: "湯守咖啡", subtitle: "北投公園站・虛構示範商家", merchantID: "m-onsen", symbol: "cup.and.heat.waves"),
        .init(id: "a-gov", role: .admin, name: "觀光主管機關", subtitle: "示範政府管理端", symbol: "building.columns"),
    ]

    static func find(_ id: String?) -> DemoAccount? { all.first { $0.id == id } }
}

/// 一般使用者一律是旅客；商家與政府是競賽展示用的身分，從各頁右上角的「切換身分」切換（D28）。
@Observable
final class Session {
    private static let storeKey = "currentAccountID"
    private static let onboardedKey = "hasOnboarded"
    private static let demoToolsKey = "showDemoTools"
    private static let demoTimeKey = "demoTimeMinutes"
    private static let checkinModeKey = "checkinMode"
    static let defaultTraveler = DemoAccounts.all[0]

    var account: DemoAccount {
        didSet { UserDefaults.standard.set(account.id, forKey: Self.storeKey) }
    }

    var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: Self.onboardedKey) }
    }

    /// 掃碼頁的「模擬掃描」按鈕。單機展示與模擬器沒有相機時需要，所以預設開啟
    var showDemoTools: Bool {
        didSet { UserDefaults.standard.set(showDemoTools, forKey: Self.demoToolsKey) }
    }

    /// 固定的展示時刻（當天第幾分鐘），nil 是用實際時間。放在 Session 而不是只讀 UserDefaults，首頁才會跟著重算
    var demoTimeMinutes: Int? {
        didSet { UserDefaults.standard.set(demoTimeMinutes, forKey: Self.demoTimeKey) }
    }

    var checkinMode: CheckinMode {
        didSet { UserDefaults.standard.set(checkinMode.rawValue, forKey: Self.checkinModeKey) }
    }

    init() {
        let d = UserDefaults.standard
        account = DemoAccounts.find(d.string(forKey: Self.storeKey)) ?? Self.defaultTraveler
        hasOnboarded = d.bool(forKey: Self.onboardedKey)
        showDemoTools = d.object(forKey: Self.demoToolsKey) as? Bool ?? true
        demoTimeMinutes = d.object(forKey: Self.demoTimeKey) as? Int
        checkinMode = d.string(forKey: Self.checkinModeKey).flatMap(CheckinMode.init) ?? .driver
        #if DEBUG
        // 模擬器的 UserDefaults 常被 cfprefsd 蓋回去，用啟動參數切身分比較可靠
        if let id = LaunchArgs.value("account"), let a = DemoAccounts.find(id) {
            account = a
            hasOnboarded = true
        }
        if LaunchArgs.has("show-welcome") { hasOnboarded = false }
        if let m = LaunchArgs.value("checkin-mode").flatMap(CheckinMode.init) { checkinMode = m }
        #endif
    }
}
