import Foundation

/// 首頁推薦前先判斷「這班現在還能不能參加」，再比獎勵。
/// 班次時間是示範資料；展示模式不卡發車時間（D12），所以已過發車時間的班次改標「示範可重播」而不是首推。
enum TripAvailability: Equatable {
    case open
    case replay
    case closed(String)

    /// 排序用：可參加 → 示範重播 → 不可參加
    var rank: Int {
        switch self {
        case .open: 0
        case .replay: 1
        case .closed: 2
        }
    }

    var isClosed: Bool { rank == 2 }

    static func evaluate(departure: String, nowMinute: Int, isCancelled: Bool, remaining: Int,
                         hasRewardStock: Bool, enforceSchedule: Bool, alreadyJoined: Bool) -> TripAvailability {
        // 已加入的人要能回來看進度，不因名額或時間被擋在外面
        if alreadyJoined { return .open }
        if isCancelled { return .closed("班次已取消") }
        if remaining <= 0 { return .closed("今日名額已滿") }
        if !hasRewardStock { return .closed("兌換品已送完") }
        if let dep = ClockTime.minutes(departure), nowMinute > dep {
            return enforceSchedule ? .closed("已發車") : .replay
        }
        return .open
    }
}

enum ClockTime {
    /// "10:40" → 640；格式不對回傳 nil，呼叫端當作「不知道發車時間」
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let h = parts[0], let m = parts[1], (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
