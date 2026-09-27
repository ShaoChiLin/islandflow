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
        let app = launch(["account=t-demo", "reset-demo"])
        XCTAssertTrue(app.staticTexts["今天搭哪班上山？"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["目前站附近・竹子湖"].exists)
        XCTAssertTrue(app.buttons["redeem-item-r-veg"].exists)
        XCTAssertFalse(app.staticTexts["竹子湖野菜餐廳"].exists, "未合作店家不應出現在旅客兌換清單")
        snap("07-綠幣中心")
    }

    /// 第一次打開：旅客語言的歡迎頁，只有「開始探索」
    func testWelcomeLeadsToExplore() {
        let app = launch(["show-welcome", "reset-demo"])
        let start = app.buttons["welcome-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["選擇示範身分"].exists)
        snap("00-歡迎")
        start.tap()
        XCTAssertTrue(app.staticTexts["今天搭哪班上山？"].waitForExistence(timeout: 5))
    }
}
