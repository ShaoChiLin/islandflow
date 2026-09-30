import XCTest

/// 端對端流程。每個關鍵畫面都存一張截圖到測試結果，在不同尺寸的模擬器上跑就是版面檢查。
final class TravelerFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // TEST_RUNNER_EXTRA_ARGS="layout-width=320" 之類的額外參數，用來在同一台模擬器檢查更窄的版面
        let extra = ProcessInfo.processInfo.environment["EXTRA_ARGS"]?.split(separator: " ").map(String.init) ?? []
        app.launchArguments = args + extra
        app.launch()
        return app
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let p = NSPredicate(format: "label == %@", label)
        let ok = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: element)], timeout: 5) == .completed
        XCTAssertTrue(ok, "按鈕文字應為「\(label)」，實際是「\(element.label)」", file: file, line: line)
    }

    /// 旅客：探索 → 加入 → 出發碼 → 到站碼 → 完成後兩次點擊拿到兌換 QR
    func testTravelerCompletesMissionAndGetsRedeemQR() {
        // demo-time 固定「現在」是 09:30：兩班都還沒發車，推薦才會固定是 10:40／100 枚
        let app = launch(["account=t-demo", "reset-demo", "demo-time=09:30"])
        XCTAssertTrue(app.staticTexts["今天搭哪班上山？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["demo-mode-notice"].exists, "首頁要常駐示範模式提示")
        snap("01-探索")

        app.buttons["recommended-view-mission"].tap()
        let primary = app.buttons["mission-primary-action"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        waitForLabel(primary, "加入任務")
        snap("02-任務詳情")

        primary.tap()
        waitForLabel(primary, "掃描出發碼")
        primary.tap()
        XCTAssertTrue(app.buttons["demo-scan-valid"].waitForExistence(timeout: 5))
        snap("03-掃出發碼")
        app.buttons["demo-scan-valid"].tap()
        XCTAssertTrue(app.buttons["checkin-continue"].waitForExistence(timeout: 5))
        // 出發成功畫面的標題不能提前變成「到站驗證」
        XCTAssertTrue(app.navigationBars["出發驗證完成"].exists)
        XCTAssertFalse(app.navigationBars["到站驗證"].exists)
        app.buttons["checkin-continue"].tap()

        waitForLabel(primary, "掃描到站碼")
        primary.tap()
        app.buttons["demo-scan-valid"].tap()
        XCTAssertTrue(app.staticTexts["checkin-reward"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["checkin-reward"].label, "已獲得 100 枚")
        snap("04-任務完成")

        // 驗收：完成後最多兩次點擊產生 QR
        app.buttons.matching(identifier: "completion-redeem-item").firstMatch.tap()      // 第 1 次
        let confirm = app.buttons["redeem-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snap("05-兌換確認")
        confirm.tap()                                                                      // 第 2 次
        XCTAssertTrue(app.descendants(matching: .any)["redeem-qr"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["redeem-short-code"].label.count, 6)
        snap("06-兌換QR")

        // 單機展示：模擬店員掃描後，旅客畫面要切到「兌換成功」
        app.buttons["demo-merchant-scan"].tap()
        XCTAssertTrue(app.staticTexts["redeem-success"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["40 枚"].exists, "海芋小花束 60 枚，100 − 60 應剩 40 枚")
        snap("08-兌換成功")
    }

    /// 商家：待核銷兌換碼 → 確認 → 核銷成功
    func testMerchantScansAndConfirmsRedemption() {
        let app = launch(["account=m-lake", "reset-demo", "demo-progress=token"])
        let pending = app.buttons.matching(identifier: "pending-token").firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        pending.tap()
        let confirm = app.buttons["merchant-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snap("商家-核銷確認")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["merchant-success"].waitForExistence(timeout: 5))
        snap("商家-核銷成功")
    }

    /// 綠幣中心：餘額、可換品、只列合作店家
    func testGreenCoinHubShowsBalanceAndOnlyPartners() {
        let app = launch(["account=t-demo", "reset-demo", "demo-progress=completed", "tab=2"])
        XCTAssertTrue(app.descendants(matching: .any)["coin-balance"].waitForExistence(timeout: 5))
        // 沒有即時定位，焦點是任務終點，不能寫「目前站」
        XCTAssertTrue(app.staticTexts["任務終點附近・竹子湖"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "merchant-demo-tag").firstMatch.exists)
        XCTAssertTrue(app.buttons["redeem-item-r-veg"].exists)
        XCTAssertFalse(app.staticTexts["竹子湖野菜餐廳"].exists, "未合作店家不應出現在旅客兌換清單")
        snap("07-綠幣中心")
    }

    /// 行程：未出發可以取消，取消後名額釋放、行程清空
    func testTravelerCancelsMissionBeforeDeparture() {
        let app = launch(["account=t-demo", "reset-demo", "demo-progress=joined", "tab=1"])
        let cancel = app.buttons["trip-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        snap("09-行程可取消")
        cancel.tap()
        // iOS 26 的確認對話框會出現兩個相同的按鈕元素（彈出層與其容器），取第一個即可
        let confirm = app.buttons.matching(identifier: "trip-cancel-confirm").firstMatch
        if confirm.waitForExistence(timeout: 3) {
            confirm.tap()
        } else {
            app.sheets.buttons["取消任務"].firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts["還沒有行程"].waitForExistence(timeout: 5))
    }

    /// 唯讀路線目錄：三條樣本路線可切換、去回程分開，沒有任務的路線要明講
    func testRouteCatalogShowsReadOnlyRoutes() {
        let app = launch(["account=t-demo", "reset-demo", "demo-time=09:30"])
        let entry = app.buttons["route-catalog-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let shishan = app.buttons["catalog-route-shishan"]
        XCTAssertTrue(shishan.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["catalog-route-btz"].exists)
        XCTAssertTrue(app.buttons["catalog-route-nanzhuang"].exists)
        snap("10-路線目錄")
        shishan.tap()
        XCTAssertTrue(app.staticTexts["可查路線・目前無旅綠幣任務"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["去程 15 站（依官方站序）"].waitForExistence(timeout: 5))
        app.buttons["回程"].tap()
        XCTAssertTrue(app.staticTexts["回程 15 站（依官方站序）"].waitForExistence(timeout: 5))
        snap("11-路線詳情-回程")
    }

    /// 三端展示切換：每一端右上角都有「切換身分」，一般民眾 → 政府 → 商家 → 一般民眾（D28）
    func testRoleSwitchReachesAllThreeSides() {
        let app = launch(["account=t-demo", "reset-demo", "demo-time=09:30"])
        func switchTo(_ name: String) {
            // iOS 26 工具列按鈕可能出現兩個相同元素，取第一個即可
            let button = app.buttons.matching(identifier: "role-switch").firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "切換到「\(name)」前找不到「切換身分」")
            button.tap()
            let item = app.buttons[name].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "選單裡沒有「\(name)」")
            item.tap()
        }

        XCTAssertTrue(app.staticTexts["今天搭哪班上山？"].waitForExistence(timeout: 5))
        snap("12-一般民眾-切換身分")
        switchTo("觀光主管機關")
        XCTAssertTrue(app.staticTexts["政策效益"].waitForExistence(timeout: 5))
        switchTo("湖田小農市集")
        XCTAssertTrue(app.staticTexts["掃碼核銷"].waitForExistence(timeout: 5))
        switchTo("小綠")
        XCTAssertTrue(app.staticTexts["今天搭哪班上山？"].waitForExistence(timeout: 5))
    }

    /// 第一次打開：旅客語言的歡迎頁，只有「開始探索」；旅綠驢只在留白夠時出現，而且不能蓋到三步驟或按鈕
    func testWelcomeLeadsToExplore() {
        let app = launch(["show-welcome", "reset-demo"])
        let start = app.buttons["welcome-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["選擇示範身分"].exists)
        let mascot = app.images["welcome-mascot"]
        // SE 這類 667pt 高的機型留白不夠，本來就會隱藏
        if app.windows.firstMatch.frame.height >= 800 {
            XCTAssertTrue(mascot.exists, "高度夠的機型應該看得到旅綠驢")
        }
        if mascot.exists {
            XCTAssertLessThanOrEqual(mascot.frame.maxY, start.frame.minY, "旅綠驢蓋到「開始探索」")
            XCTAssertGreaterThanOrEqual(mascot.frame.minY, app.staticTexts["到沿線小農店家換好物"].frame.maxY, "旅綠驢蓋到三步驟")
        }
        snap("00-歡迎")
        start.tap()
        XCTAssertTrue(app.staticTexts["今天搭哪班上山？"].waitForExistence(timeout: 5))
    }
}
