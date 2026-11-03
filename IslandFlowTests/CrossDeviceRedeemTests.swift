import XCTest
import SwiftData
@testable import IslandFlow

/// K30：兩支手機各有一個資料庫，旅客在 A 產生兌換碼、商家在 B 核銷、A 回掃完成碼。
/// 兩個記憶體資料庫之間只靠字串（QR 內容）傳遞，等同實機上互掃。
@MainActor
final class CrossDeviceRedeemTests: XCTestCase {
    var phoneA: ModelContainer!
    var phoneB: ModelContainer!
    var a: FlowService!
    var b: FlowService!
    let user = "t-demo"

    override func setUp() async throws {
        phoneA = try AppSchema.makeContainer(inMemory: true)
        phoneB = try AppSchema.makeContainer(inMemory: true)
        SeedData.seed(phoneA.mainContext)
        SeedData.seed(phoneB.mainContext)
        a = FlowService(context: phoneA.mainContext)
        b = FlowService(context: phoneB.mainContext)
    }

    private func earnCoins() throws {
        let m = a.mission("M-A")!
        let (p, _) = try a.join(mission: m, user: user)
        // D35：上車驗證就入帳
        _ = try a.checkIn(raw: a.currentStationToken(trip: m.tripID, stop: m.startStopSeq), participation: p, method: "demo")
    }

    private func redemptions(_ c: ModelContainer, status: String) throws -> [Redemption] {
        try c.mainContext.fetch(FetchDescriptor<Redemption>(predicate: #Predicate { $0.status == status && $0.isSimulated == false }))
    }

    /// 回傳 A 的兌換碼與 B 的核銷結果
    private func redeemOnB(_ itemID: String = "r-veg", key: String = UUID().uuidString) throws -> (RedemptionToken, Redemption) {
        let tok = try a.createRedeemToken(user: user, item: a.item(itemID)!)
        let p = try b.preview(input: a.payload(for: tok), merchantID: "m-lake")
        XCTAssertNotNil(p.remote)
        let (r, _) = try b.confirm(tokenID: p.tokenID, merchantID: "m-lake", idempotencyKey: key, remote: p.remote)
        return (tok, r)
    }

    func testFullCrossDeviceFlow() throws {
        try earnCoins()
        let stockA = a.item("r-veg")!.stock, stockB = b.item("r-veg")!.stock
        let (tok, r) = try redeemOnB()

        // B：記交易、扣庫存，但 B 沒有這位旅客的帳本，也不該寫
        XCTAssertEqual(r.status, "success")
        XCTAssertEqual(b.item("r-veg")!.stock, stockB - 1)
        XCTAssertEqual(b.ledger(for: user).count, 0)
        XCTAssertTrue(b.needsReceipt(r))

        // A：還沒回掃前，點數仍圈存、未扣
        XCTAssertEqual(a.balance(for: user), 100)
        XCTAssertEqual(a.available(for: user), 20)

        let (_, replayed) = try a.applyReceipt(raw: b.receiptPayload(for: r), user: user)
        XCTAssertFalse(replayed)
        XCTAssertNotNil(tok.usedAt)
        XCTAssertEqual(a.balance(for: user), 20)
        XCTAssertEqual(a.available(for: user), 20, "扣點後圈存要釋放，不能扣兩次")
        XCTAssertEqual(a.item("r-veg")!.stock, stockA, "A 的庫存不是這次核銷的店家庫存")
        XCTAssertEqual(try redemptions(phoneA, status: "success").count, 1, "A 的儀表板也要看得到這次核銷")
        XCTAssertFalse(a.needsReceipt(try redemptions(phoneA, status: "success")[0]))
    }

    func testSecondScanOnMerchantPhoneBlocked() throws {
        try earnCoins()
        let (tok, _) = try redeemOnB()
        XCTAssertThrowsError(try b.preview(input: a.payload(for: tok), merchantID: "m-lake")) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("使用過") ?? false)
        }
        // 繞過預覽直接換一把新鍵確認也一樣擋
        let payload = try TokenSigner.verifyRedeem(a.payload(for: tok))
        XCTAssertThrowsError(try b.confirm(tokenID: tok.id, merchantID: "m-lake", idempotencyKey: "other", remote: payload))
        XCTAssertEqual(try redemptions(phoneB, status: "success").count, 1)
    }

    func testMerchantConfirmIsIdempotent() throws {
        try earnCoins()
        let tok = try a.createRedeemToken(user: user, item: a.item("r-veg")!)
        let p = try b.preview(input: a.payload(for: tok), merchantID: "m-lake")
        let stock = b.item("r-veg")!.stock
        let (r1, rep1) = try b.confirm(tokenID: p.tokenID, merchantID: "m-lake", idempotencyKey: "k", remote: p.remote)
        let (r2, rep2) = try b.confirm(tokenID: p.tokenID, merchantID: "m-lake", idempotencyKey: "k", remote: p.remote)
        XCTAssertFalse(rep1)
        XCTAssertTrue(rep2)
        XCTAssertEqual(r1.id, r2.id)
        XCTAssertEqual(b.item("r-veg")!.stock, stock - 1)
    }

    func testReceiptScannedTwiceDeductsOnce() throws {
        try earnCoins()
        let (_, r) = try redeemOnB()
        let receipt = b.receiptPayload(for: r)
        try a.applyReceipt(raw: receipt, user: user)
        let (_, replayed) = try a.applyReceipt(raw: receipt, user: user)
        XCTAssertTrue(replayed)
        XCTAssertEqual(a.balance(for: user), 20)
        XCTAssertEqual(try redemptions(phoneA, status: "success").count, 1)
    }

    func testWrongMerchantPhoneRejectsWithoutLogging() throws {
        try earnCoins()
        let tok = try a.createRedeemToken(user: user, item: a.item("r-veg")!)
        XCTAssertThrowsError(try b.preview(input: a.payload(for: tok), merchantID: "m-tea"))
        XCTAssertEqual(try redemptions(phoneB, status: "failed").count, 0, "不寫進別家店的紀錄")
    }

    func testExpiredCodeRejectedAndLoggedOnMerchantPhone() throws {
        try earnCoins()
        let tok = try a.createRedeemToken(user: user, item: a.item("r-veg")!)
        b.now = { .now.addingTimeInterval(301) }
        XCTAssertThrowsError(try b.preview(input: a.payload(for: tok), merchantID: "m-lake"))
        XCTAssertEqual(try redemptions(phoneB, status: "failed").count, 1)
    }

    func testForgedCodeRejected() throws {
        try earnCoins()
        let tok = try a.createRedeemToken(user: user, item: a.item("r-veg")!)
        // 把簽章內容改成便宜的點數，簽章就對不上
        var payload = try TokenSigner.verifyRedeem(a.payload(for: tok))
        payload.amt = 1
        let parts = a.payload(for: tok).split(separator: ".")
        let forged = "\(parts[0]).\(try JSONEncoder.sorted.encode(payload).base64URL).\(parts[2])"
        XCTAssertThrowsError(try b.preview(input: forged, merchantID: "m-lake")) {
            XCTAssertEqual($0 as? TokenError, .badSignature)
        }
    }

    func testPriceMismatchRejected() throws {
        try earnCoins()
        let tok = try a.createRedeemToken(user: user, item: a.item("r-veg")!)
        b.item("r-veg")!.coinCost += 10
        XCTAssertThrowsError(try b.preview(input: a.payload(for: tok), merchantID: "m-lake"))
    }

    func testOutOfStockOnMerchantPhone() throws {
        try earnCoins()
        let tok = try a.createRedeemToken(user: user, item: a.item("r-veg")!)
        let p = try b.preview(input: a.payload(for: tok), merchantID: "m-lake")
        b.item("r-veg")!.stock = 0
        XCTAssertThrowsError(try b.confirm(tokenID: p.tokenID, merchantID: "m-lake", idempotencyKey: "k", remote: p.remote))
        XCTAssertEqual(try redemptions(phoneB, status: "success").count, 0)
    }

    func testShortCodeCannotCrossPhones() throws {
        try earnCoins()
        let tok = try a.createRedeemToken(user: user, item: a.item("r-veg")!)
        XCTAssertThrowsError(try b.preview(input: TokenSigner.shortCode(for: tok.id), merchantID: "m-lake")) {
            XCTAssertTrue(($0 as? FlowError)?.message.contains("QR Code") ?? false)
        }
    }

    func testV1CodeFromOtherPhoneNotFound() throws {
        try earnCoins()
        let tok = try a.createRedeemToken(user: user, item: a.item("r-veg")!)
        let v1 = TokenSigner.sign(RedeemToken(tid: tok.id, exp: Int(tok.expiresAt.timeIntervalSince1970)))
        XCTAssertThrowsError(try b.preview(input: v1, merchantID: "m-lake")) {
            XCTAssertEqual(($0 as? FlowError)?.message, "查無此兌換碼")
        }
        // 同一支手機上 v1 碼照舊可用
        XCTAssertNil(try a.preview(input: v1, merchantID: "m-lake").remote)
    }

    func testSamePhoneFlowStillLocalWithV2Code() throws {
        try earnCoins()
        let tok = try a.createRedeemToken(user: user, item: a.item("r-veg")!)
        let p = try a.preview(input: a.payload(for: tok), merchantID: "m-lake")
        XCTAssertNil(p.remote, "本機查得到憑證就走原本的同機核銷")
        let (r, _) = try a.confirm(tokenID: p.tokenID, merchantID: "m-lake", idempotencyKey: "k")
        XCTAssertFalse(a.needsReceipt(r))
        XCTAssertEqual(a.balance(for: user), 20)
    }

    func testLateReceiptStillDeductsAfterHoldExpired() throws {
        try earnCoins()
        let (tok, r) = try redeemOnB()
        a.now = { .now.addingTimeInterval(3600) }
        XCTAssertEqual(a.available(for: user), 100, "圈存到期已退回")
        try a.applyReceipt(raw: b.receiptPayload(for: r), user: user)
        XCTAssertEqual(a.balance(for: user), 20, "店家已交出品項，逾時回掃照樣扣點")
        XCTAssertNotNil(tok.usedAt)
    }

    func testReceiptRejectedForOtherUserOrUnknownToken() throws {
        try earnCoins()
        let (_, r) = try redeemOnB()
        let receipt = b.receiptPayload(for: r)
        XCTAssertThrowsError(try a.applyReceipt(raw: receipt, user: "t-other"))
        XCTAssertThrowsError(try b.applyReceipt(raw: receipt, user: user), "B 沒有這張兌換碼")
        XCTAssertThrowsError(try a.applyReceipt(raw: a.payload(for: a.redemptionToken(r.tokenID)!), user: user)) {
            XCTAssertEqual($0 as? TokenError, .wrongPurpose, "兌換碼不能當完成碼")
        }
        XCTAssertEqual(a.balance(for: user), 100)
    }

    func testReceiptExpiresAfter24Hours() throws {
        try earnCoins()
        let (_, r) = try redeemOnB()
        a.now = { .now.addingTimeInterval(FlowService.receiptTTL + 60) }
        XCTAssertThrowsError(try a.applyReceipt(raw: b.receiptPayload(for: r), user: user)) {
            XCTAssertEqual($0 as? TokenError, .expired)
        }
    }

    func testAwaitingReceiptListsUnusedRecentTokens() throws {
        try earnCoins()
        let (_, r) = try redeemOnB()
        XCTAssertEqual(a.awaitingReceipt(for: user).count, 1)
        try a.applyReceipt(raw: b.receiptPayload(for: r), user: user)
        XCTAssertEqual(a.awaitingReceipt(for: user).count, 0)
    }
}
