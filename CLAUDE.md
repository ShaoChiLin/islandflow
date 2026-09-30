# 旅綠（開發代號 IslandFlow）— 專案脈絡

innoserve 黑客松概念驗證 App。正式名稱「旅綠」，點數叫「旅綠幣」；畫面文案用這兩個名字，
舊名「島流旅綠幣」不要再出現在畫面上。程式、專案、Bundle ID、站牌碼／兌換碼格式沿用 IslandFlow，不改。
品牌標誌在 `Assets.xcassets/BrandLogo`（畫面用 `BrandLogo` 元件）與 `AppIcon`，原檔在 `docs/brand/`。
吉祥物「旅綠驢」在 `Assets.xcassets/LuluDonkey`（目前只放歡迎頁，D29）；定稿原檔與去背 PNG 在 `docs/brand/`，外觀已定稿，不要重畫或重新上色。
規格在上一層的 `實作規格.md`（PDF 內容相同）。
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

- `Domain/`：純邏輯，不碰 SwiftData，全部有單元測試（`RewardEngine`、`TokenSigner`、`DashboardMetrics`、`Geo`/`CarbonEstimator`/`TransportEmission`、`OpenData`、`TripAvailability`、`CSV`、`RouteCatalog`）
- 唯讀路線目錄（`RouteCatalog`＋`Services/RouteCatalogStore`）存成 Application Support 的 JSON，**不寫進 SwiftData／`RouteStop`**；匯入路線不等於開任務。全台 CSV 一律用 `CSV.parse`，不要用 `OpenData.csvRows` 的 `split(",")`
- 新路線要先在 `RouteCatalog.localIDs` 配本地穩定 ID；錯誤座標與重複站序保留原值、不自動修正
- `Services/FlowService`：**所有會改資料的動作只能經過這裡**（加入、驗證、入帳、產生兌換碼、核銷）。畫面不直接寫 `LedgerEntry`／`Checkin`／`Redemption`
- 餘額永遠由 `LedgerEntry` 加總，沒有餘額欄位
- SwiftData 的 `@Attribute(.unique)` 遇到重複是**覆寫**不是丟錯，所以拒絕重複要靠 FlowService 先查再寫
- 核銷用 `context.transaction`；冪等鍵在商家開啟確認畫面時產生
- 模擬資料一律 `isSimulated = true`，管理端畫面上要有 `DemoBadge`
- 旅客端分三頁（探索／行程／綠幣），依 `../Claude_Code_遊客端UX改版方針.md`（2026-09-29 版）：旅客畫面不放資料集編號、政策指標；不要加第四個分頁
- 三端角色叫「一般民眾／商家／政府」（`Role.label`），每一端右上角都有 `AccountMenu`「切換身分」（D28 取代 D15 的隱藏入口，使用者 2026-09-30 決定）。旅客探索首頁沒有導覽列，按鈕放在品牌列右側
- 旅客端用 `Theme.swift` 的 `Space`／`Radius`／`.primary` 按鈕與 `ComfortChip`；有標籤或金額的橫排要用 `AdaptiveStack`，大字級才不會撐版
- UI 測試靠 `accessibilityIdentifier` 找元件，改畫面別刪；改完旅客畫面要跑 `IslandFlowUITests`

## 慣例

- 註解用繁體中文，只寫「為什麼」
- 模擬、估算的數字要標示範（規格書硬性要求）。旅客首頁常駐 `DemoModeNotice`，班次標「示範班次」、`ComfortChip` 自帶「預估」、虛構店家用 `Merchant.demoTag`；D14「首頁不放標籤」已被 D19 取代
- 店家營業時間沒有核實來源，不能判斷「現在營業中」；兌換狀態只寫「點數足夠」
- 減碳：旅客端只顯示實際搭車估算（`TransportEmission`），沒有自填基準前不算減碳量；差值保留正負、缺值是未知不是 0
- App 沒有班表／到站時間：不要編時間，寫「請查官方時刻」並給 `OfficialInfo.taiwanTripURL`
- 旅綠幣是活動點數，文案不能暗示可兌現、轉讓
- 規格書禁止：區塊鏈、真實金流、宣稱碳權、把規則包裝成 AI 預測

## 除錯旗標

見 README。截圖驗證可用 `simctl launch ... account=a-gov tab=0` 搭配 `demo-progress=` 直接跳到流程中段。
首頁推薦會依「現在幾點」判斷班次是否已發車；截圖與 UI 測試加 `demo-time=09:30` 才會固定是 10:40 推薦（`DemoClock` 只影響這個判斷）。
