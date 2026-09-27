import Foundation
import Observation

enum Role: String {
    case traveler, merchant, admin

    var label: String {
        switch self {
        case .traveler: "旅客"
        case .merchant: "商家"
        case .admin: "管理者"
        }
    }
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
        .init(id: "m-lake", role: .merchant, name: "湖田小農市集", subtitle: "竹子湖站・虛構示範商家", merchantID: "m-lake", symbol: "leaf"),
        .init(id: "m-tea", role: .merchant, name: "山嵐茶屋", subtitle: "陽明書屋站・虛構示範商家", merchantID: "m-tea", symbol: "cup.and.saucer"),
        .init(id: "m-onsen", role: .merchant, name: "湯守咖啡", subtitle: "北投公園站・虛構示範商家", merchantID: "m-onsen", symbol: "cup.and.heat.waves"),
        .init(id: "a-gov", role: .admin, name: "觀光主管機關", subtitle: "示範管理者", symbol: "building.columns"),
    ]

    static func find(_ id: String?) -> DemoAccount? { all.first { $0.id == id } }
}

/// 一般使用者一律是旅客；商家與管理者只是競賽展示用的身分，從隱藏的展示選單切換。
@Observable
final class Session {
    private static let storeKey = "currentAccountID"
    private static let onboardedKey = "hasOnboarded"
    private static let demoToolsKey = "showDemoTools"
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

    init() {
        let d = UserDefaults.standard
        account = DemoAccounts.find(d.string(forKey: Self.storeKey)) ?? Self.defaultTraveler
        hasOnboarded = d.bool(forKey: Self.onboardedKey)
        showDemoTools = d.object(forKey: Self.demoToolsKey) as? Bool ?? true
        #if DEBUG
        // 模擬器的 UserDefaults 常被 cfprefsd 蓋回去，用啟動參數切身分比較可靠
        if let id = LaunchArgs.value("account"), let a = DemoAccounts.find(id) {
            account = a
            hasOnboarded = true
        }
        if LaunchArgs.has("show-welcome") { hasOnboarded = false }
        #endif
    }
}
