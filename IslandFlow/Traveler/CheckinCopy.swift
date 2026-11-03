import Foundation

/// 上下車驗證的旅客端文案。兩種方式（D33）共用同一套流程，只有「誰掃誰」不同，
/// 集中在這裡才不會有畫面還寫「掃站牌」而實際是司機掃碼。
struct CheckinCopy {
    let mode: CheckinMode

    func stepTitle(_ stage: CheckinStage, stop: String) -> String {
        switch (mode, stage) {
        case (.driver, .depart): "在「\(stop)」上車，請司機掃乘車碼"
        case (.driver, .arrive): "到「\(stop)」下車，請司機再掃一次"
        case (.station, .depart): "在「\(stop)」掃出發碼"
        case (.station, .arrive): "到「\(stop)」掃到站碼"
        }
    }

    func stepHint(_ stage: CheckinStage, departure: String) -> String {
        switch (mode, stage) {
        case (.driver, .depart): "搭 \(departure) 班次，上車時出示"
        case (.driver, .arrive): "下車時出示"
        case (.station, .depart): "搭 \(departure) 班次上車前掃站牌"
        case (.station, .arrive): "下車後掃站牌"
        }
    }

    func action(_ stage: CheckinStage) -> String {
        switch (mode, stage) {
        case (.driver, .depart): "出示上車乘車碼"
        case (.driver, .arrive): "出示下車乘車碼"
        case (.station, .depart): "掃描出發碼"
        case (.station, .arrive): "掃描到站碼"
        }
    }

    func nextStep(_ stage: CheckinStage) -> String {
        switch (mode, stage) {
        case (.driver, .depart): "下一步：上車時請司機掃乘車碼"
        case (.driver, .arrive): "下一步：下車時請司機再掃一次"
        case (.station, .depart): "下一步：在起點掃出發碼"
        case (.station, .arrive): "下一步：到站後掃到站碼"
        }
    }

    var ruleNote: String {
        mode == .driver ? "乘車碼每 30 秒更新，請在車上出示給司機掃描" : "站牌上的碼每 30 秒更新，請現場掃描"
    }

    var cannotCancelNote: String {
        mode == .driver ? "已完成上車驗證，任務不能取消；下車時記得請司機再掃一次。"
                        : "已完成出發驗證，任務不能取消；抵達後記得掃到站碼。"
    }

    func departDone(stop: String, reward: Int) -> String {
        mode == .driver ? "在\(stop)下車時，再請司機掃一次就能領 \(reward) 枚"
                        : "抵達\(stop)後，再掃一次站牌就能領 \(reward) 枚"
    }
}
