# 島流旅綠幣 IslandFlow — 專案脈絡

innoserve 黑客松概念驗證 App。規格在上一層的 `實作規格.md`（PDF 內容相同）。
原生 SwiftUI + SwiftData，iOS 17+，全繁中介面，單機運作不接後端。
使用者用免費 Apple ID 自簽裝手機展示，不上架。

## 筆記（每次工作都要維護）

- **開始前**先讀 [docs/接手筆記.md](docs/接手筆記.md)：目前狀態、未驗證項目、下一步、待團隊決定
- **結束前**必須更新兩份筆記：
  - `docs/開發筆記.md`：在「工作日誌」最上方新增一筆；新的設計決策加 D 編號；新發現的問題加 K 編號，解決的打勾註明日期。**只增不刪**
  - `docs/接手筆記.md`：整份改成最新狀態，做完的項目直接移除；更新頂部「最後更新」日期
- 驗證狀態要誠實：只過 build、沒實際看到畫面的，就寫「未目視」

## 環境

`xcode-select` 可能指向 Command Line Tools，所有 `xcodebuild`／`xcrun` 前面都加
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

建置與測試指令見 README。**改完一定要實際 build 並跑測試再回報**。

專案檔用 Xcode 16 的資料夾同步群組（`PBXFileSystemSynchronizedRootGroup`），
新增 .swift 檔直接放進 `IslandFlow/` 或 `IslandFlowTests/` 就會被編譯，不用改 pbxproj。

## 架構

- `Domain/`：純邏輯，不碰 SwiftData，全部有單元測試（`RewardEngine`、`TokenSigner`、`DashboardMetrics`、`Geo`/`CarbonEstimator`、`OpenData`）
- `Services/FlowService`：**所有會改資料的動作只能經過這裡**（加入、驗證、入帳、產生兌換碼、核銷）。畫面不直接寫 `LedgerEntry`／`Checkin`／`Redemption`
- 餘額永遠由 `LedgerEntry` 加總，沒有餘額欄位
- SwiftData 的 `@Attribute(.unique)` 遇到重複是**覆寫**不是丟錯，所以拒絕重複要靠 FlowService 先查再寫
- 核銷用 `context.transaction`；冪等鍵在商家開啟確認畫面時產生
- 模擬資料一律 `isSimulated = true`，管理端畫面上要有 `DemoBadge`
- 旅客端分三頁（探索／行程／綠幣），依 `../Claude_Code_遊客端UX改版方針.md`：旅客畫面不放資料集編號、政策指標、展示帳號；商家與管理者只從隱藏的展示選單進入
- 旅客端用 `Theme.swift` 的 `Space`／`Radius`／`.primary` 按鈕與 `ComfortChip`；有標籤或金額的橫排要用 `AdaptiveStack`，大字級才不會撐版
- UI 測試靠 `accessibilityIdentifier` 找元件，改畫面別刪；改完旅客畫面要跑 `IslandFlowUITests`

## 慣例

- 註解用繁體中文，只寫「為什麼」
- 模擬、估算的數字要標「示範資料」（規格書硬性要求）。例外：旅客首頁依改版方針不放標籤，精確載客率只出現在任務詳情展開區並在那裡標示（開發筆記 D14）
- 旅綠幣是活動點數，文案不能暗示可兌現、轉讓
- 規格書禁止：區塊鏈、真實金流、宣稱碳權、把規則包裝成 AI 預測

## 除錯旗標

見 README。截圖驗證可用 `simctl launch ... account=a-gov tab=0` 搭配 `demo-progress=` 直接跳到流程中段。
