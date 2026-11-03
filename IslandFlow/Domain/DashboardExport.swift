import Foundation

/// 儀表板匯出 Excel（D36）：數字和畫面上的卡片同一份 `DashboardMetrics`，不另外算。
/// 每一列都寫明計算方式與資料性質，檔案離開 App 之後也看得出哪些是示範估算。
enum DashboardExport {
    static func fileName(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "旅綠政策效益儀表板_\(f.string(from: date)).xlsx"
    }

    static func sheets(_ m: DashboardMetrics, assumptions a: MetricAssumptions, exportedAt: Date) -> [XLSXSheet] {
        [about(m, exportedAt: exportedAt), indicators(m, a), funnel(m), daily(m), assumptionSheet(a)]
    }

    static func data(_ m: DashboardMetrics, assumptions a: MetricAssumptions, exportedAt: Date) -> Data {
        XLSXWriter.data(sheets: sheets(m, assumptions: a, exportedAt: exportedAt))
    }

    private static func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    private static func about(_ m: DashboardMetrics, exportedAt: Date) -> XLSXSheet {
        XLSXSheet(name: "說明", rows: [
            [.text("旅綠｜政策效益儀表板匯出")],
            [.text("匯出時間"), .text(timestamp(exportedAt))],
            [.text("路線"), .text("台灣好行北投竹子湖線")],
            [.text("資料範圍"), .text("過去 \(m.daily.count) 天模擬歷史＋本機即時操作")],
            [.text("本次展示即時產生"), .text("完成任務 \(m.liveCompletions) 筆・核銷 \(m.liveRedemptions) 筆")],
            [.text("示範聲明"), .text("班次載客率、店家與歷史紀錄為示範資料；成本、新增搭乘、地方消費與交通排放皆依情境假設估算，不是實測成果。")],
            [.text("減碳"), .text("「搭公車排放估算」只計算搭公車本身的排放，沒有旅客原本交通方式的基準，不代表減碳量，也不是碳權。")],
        ], columnWidths: [18, 80])
    }

    /// 數值欄放原始數字，方便在 Excel 裡再算；百分比換成 0～100
    private static func indicators(_ m: DashboardMetrics, _ a: MetricAssumptions) -> XLSXSheet {
        func num(_ v: Double?) -> XLSXCell { v.map { .number(($0 * 100).rounded() / 100) } ?? .text("—") }
        func pct(_ v: Double?) -> XLSXCell { v.map { .number(($0 * 1000).rounded() / 10) } ?? .text("—") }
        let est = "示範估算"
        return XLSXSheet(name: "指標總覽", rows: [
            [.text("指標"), .text("數值"), .text("單位"), .text("計算方式"), .text("資料性質")],
            [.text("每 1 元獎勵帶動的地方消費"), num(m.leverage), .text("倍"), .text("地方消費 ÷ 獎勵成本"), .text(est)],
            [.text("獎勵成本"), num(m.rewardCostNTD), .text("元"), .text("已發 \(m.coinsIssued) 枚 × 每枚 \(String(format: "%g", a.coinValueNTD)) 元"), .text(est)],
            [.text("估算新增搭乘"), num(m.addedRides), .text("人次"), .text("完成 \(m.completions) × 增量比例 \(a.incrementalRideRatio)"), .text(est)],
            [.text("每一新增搭乘成本"), num(m.costPerAddedRide), .text("元"), .text("獎勵成本 ÷ 估算新增搭乘"), .text(est)],
            [.text("地方消費帶動"), num(m.localSpendNTD), .text("元"), .text("核銷 \(m.redemptionCount) 筆 × 平均加購 \(Int(a.avgLocalSpendNTD)) 元"), .text(est)],
            [.text("離峰占比"), pct(m.offPeakShare), .text("%"), .text("離峰完成 ÷ 全部完成"), .text("示範資料")],
            [.text("分流達成"), .number(Double(m.diversionDelta)), .text("人次"), .text("分流站到訪 \(m.diversionVisits) − 基準 \(m.diversionBaseline)"), .text(est)],
            [.text("搭公車排放估算"), num(m.busEmissionKg), .text("kgCO₂e"),
             .text("完成 \(m.emissionEstimatedSegments) 段 × 距離 × 公車係數 \(a.busFactor)\(m.emissionUnknownSegments > 0 ? "；\(m.emissionUnknownSegments) 段無法估算" : "")；不算減碳"), .text(est)],
            [.text("兌換率"), pct(m.redemptionRate), .text("%"), .text("已核銷人數 ÷ 完成人數"), .text("示範資料")],
        ], columnWidths: [26, 12, 10, 48, 12])
    }

    private static func funnel(_ m: DashboardMetrics) -> XLSXSheet {
        func pct(_ v: Double?) -> XLSXCell { v.map { .number(($0 * 1000).rounded() / 10) } ?? .text("—") }
        return XLSXSheet(name: "任務漏斗", rows: [
            [.text("階段"), .text("人數"), .text("轉換率（%）"), .text("說明")],
            [.text("瀏覽任務"), .number(Double(m.views)), .empty, .text("任務頁瀏覽次數")],
            [.text("加入任務"), .number(Double(m.joins)), pct(m.joinRate), .text("加入 ÷ 瀏覽")],
            [.text("完成任務"), .number(Double(m.completions)), pct(m.completionRate), .text("完成 ÷ 加入；上車驗證通過即完成")],
            [.text("到店核銷"), .number(Double(m.redeemedUsers)), pct(m.redemptionRate), .text("已核銷人數 ÷ 完成人數")],
            [.text("核銷筆數"), .number(Double(m.redemptionCount)), .empty, .text("成功核銷交易數")],
        ], columnWidths: [14, 10, 14, 36])
    }

    private static func daily(_ m: DashboardMetrics) -> XLSXSheet {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.dateFormat = "yyyy-MM-dd"
        return XLSXSheet(name: "每日趨勢",
                         rows: [[.text("日期"), .text("完成任務"), .text("核銷")]] + m.daily.map {
                             [.text(f.string(from: $0.day)), .number(Double($0.completions)), .number(Double($0.redemptions))]
                         },
                         columnWidths: [14, 12, 10])
    }

    private static func assumptionSheet(_ a: MetricAssumptions) -> XLSXSheet {
        XLSXSheet(name: "估算假設", rows: [
            [.text("假設"), .text("數值"), .text("單位"), .text("說明")],
            [.text("每枚旅綠幣成本"), .number(a.coinValueNTD), .text("元"), .text("活動點數，不能兌現；這裡只用來換算預算")],
            [.text("增量比例"), .number(a.incrementalRideRatio), .text("比例"), .text("完成任務中，估計原本不會搭這班的比例")],
            [.text("平均加購"), .number(a.avgLocalSpendNTD), .text("元／筆"), .text("每筆核銷估計帶動的地方消費")],
            [.text("分流基準"), .number(Double(a.diversionBaseline)), .text("人次"), .text("沒有任務時分流站的預期到訪")],
            [.text("公車排放係數"), .number(a.busFactor), .text("kgCO₂e／人公里"), .text("示範係數，待換成可引用的正式來源")],
        ], columnWidths: [16, 10, 16, 44])
    }
}
