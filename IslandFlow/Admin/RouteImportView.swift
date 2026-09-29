import SwiftUI
import UniformTypeIdentifiers

// MARK: A 管理端：路線目錄匯入（唯讀目錄，不影響任務與帳本）
//
// 流程：選來源（App 內建原檔或自選 CSV）→ 看檢查報告與問題列 → 勾選已配置本地 ID 的路線 → 看差異 → 確認匯入。

struct RouteImportView: View {
    @State private var store = RouteCatalogStore.shared
    @State private var parsed: ParsedRouteFile?
    @State private var selection: Set<String> = []
    @State private var picking = false
    @State private var message: String?
    @State private var parseError: String?

    var body: some View {
        List {
            currentSection
            Section {
                Button {
                    load { try store.parseBuiltIn() }
                } label: {
                    Label("讀取 App 內建原檔（\(RouteCatalog.bundledRetrievedOn) 下載）", systemImage: "shippingbox")
                }
                .accessibilityIdentifier("import-builtin")
                Button {
                    picking = true
                } label: {
                    Label("選擇 CSV 檔…", systemImage: "doc")
                }
            } header: {
                Text("匯入來源")
            } footer: {
                Text("官方原檔：\(RouteCatalog.officialCSVURL)。請先在瀏覽器下載，再從「檔案」選取；App 不會自行連網下載。")
            }
            if let parseError {
                Section { Label(parseError, systemImage: "xmark.octagon").foregroundStyle(.red) }
            }
            if let parsed {
                reportSection(parsed)
                issuesSection(parsed)
                routesSection(parsed)
                confirmSection(parsed)
            }
        }
        .navigationTitle("路線目錄匯入")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.loadIfNeeded() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { result in
            load {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                // 自選檔案不知道實際下載日，留空，不拿檔案修改時間冒充
                return try RouteImporter.parse(data: data, fileName: url.lastPathComponent,
                                               url: RouteCatalog.officialCSVURL, retrievedOn: nil)
            }
        }
        .alert("路線目錄", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") {}
        } message: {
            Text(message ?? "")
        }
    }

    private func load(_ make: () throws -> ParsedRouteFile) {
        do {
            let p = try make()
            parsed = p
            parseError = nil
            // 預設勾選目前目錄裡已有的路線，避免一匯入就把現有路線拿掉
            let current = Set(store.snapshot?.routes.map(\.id) ?? RouteCatalog.defaultSelection)
            selection = Set(p.routes.compactMap(\.localID)).intersection(current)
        } catch {
            parsed = nil
            parseError = error.localizedDescription
        }
    }

    @ViewBuilder private var currentSection: some View {
        Section("目前目錄") {
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let s = store.snapshot {
                LabeledContent("來源檔", value: s.source.fileName)
                LabeledContent("下載日", value: s.source.retrievedOn ?? "未提供")
                LabeledContent("來源更新日", value: s.source.sourceUpdatedOn ?? "未提供")
                LabeledContent("SHA-256", value: String(s.source.sha256.prefix(12)) + "…")
                LabeledContent("解析器", value: s.source.parserVersion)
                LabeledContent("匯入時間", value: Fmt.dateTime(s.importedAt))
                ForEach(s.routes) { r in
                    LabeledContent(r.sourceName, value: r.directions.map { "\($0.name) \($0.stops.count)" }.joined(separator: "・"))
                }
            }
        }
        .font(.subheadline)
    }

    private func reportSection(_ p: ParsedRouteFile) -> some View {
        Section {
            LabeledContent("資料列", value: "\(p.report.records)")
            LabeledContent("不同路線名稱", value: "\(p.report.routeNames)")
            LabeledContent("欄位內含逗號", value: "\(p.report.recordsWithEmbeddedComma) 筆（已正確解析）")
            LabeledContent("SHA-256", value: String(p.source.sha256.prefix(12)) + "…")
        } header: {
            Text("檔案檢查")
        } footer: {
            Text("路線名稱數只代表這份快照，不代表目前都在營運。")
        }
        .font(.subheadline)
        .accessibilityIdentifier("import-report")
    }

    private func issuesSection(_ p: ParsedRouteFile) -> some View {
        Section {
            if p.report.issues.isEmpty { Text("沒有發現問題列") }
            ForEach(p.report.issues) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text("第 \(i.record) 筆・\(i.route)・\(i.direction) \(i.sequence)").font(.caption.weight(.semibold))
                    Text("\(i.kind.label)：\(i.detail)").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("問題列（\(p.report.issues.count)）")
        } footer: {
            Text("錯誤座標不會自動修正、重複站序不會自動刪除；原值保留，等核對來源後人工處理。")
        }
    }

    private func routesSection(_ p: ParsedRouteFile) -> some View {
        let mapped = p.routes.filter { $0.localID != nil }
        let unmapped = p.routes.filter { $0.localID == nil }
        return Section {
            ForEach(mapped) { r in
                Toggle(isOn: Binding(get: { selection.contains(r.localID!) },
                                     set: { if $0 { selection.insert(r.localID!) } else { selection.remove(r.localID!) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name)
                        Text("\(r.rows) 列・本地 ID \(r.localID!)\(r.issues > 0 ? "・問題 \(r.issues) 筆" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !unmapped.isEmpty {
                DisclosureGroup("其他 \(unmapped.count) 條（尚未配置本地 ID，不能匯入）") {
                    ForEach(unmapped) { r in
                        Text("\(r.name)・\(r.rows) 列\(r.issues > 0 ? "・問題 \(r.issues) 筆" : "")").font(.caption)
                    }
                }
            }
        } header: {
            Text("選擇路線")
        } footer: {
            Text("官方資料只有路線名稱沒有 ID；要新增路線，先在程式的對照表配置穩定本地 ID。匯入路線不會開任務、不會產生班次或店家。")
        }
    }

    private func confirmSection(_ p: ParsedRouteFile) -> some View {
        let ids = RouteCatalog.defaultSelection.filter(selection.contains)
            + selection.subtracting(RouteCatalog.defaultSelection).sorted()
        let next = p.snapshot(routeIDs: ids)
        let diff = CatalogDiff.between(store.snapshot, next)
        return Section {
            if diff.isUnchanged {
                Label("與目前版本完全相同，不需要匯入", systemImage: "checkmark.circle")
            } else {
                if diff.sourceChanged { Text("來源檔不同（SHA-256 變更）") }
                if !diff.addedRoutes.isEmpty { Text("新增路線：\(names(diff.addedRoutes))") }
                if !diff.removedRoutes.isEmpty { Text("移出目錄：\(names(diff.removedRoutes))").foregroundStyle(.orange) }
                Text("站點：新增 \(diff.addedStops)、異動 \(diff.changedStops)、失效 \(diff.removedStops)")
            }
            Button("確認匯入") {
                do {
                    message = try store.apply(next) == .unchanged ? "內容相同，未變更" : "已更新路線目錄；上一版已備份"
                } catch {
                    message = "匯入失敗，目錄維持上一版：\(error.localizedDescription)"
                }
            }
            .disabled(ids.isEmpty || diff.isUnchanged)
            .accessibilityIdentifier("import-confirm")
        } header: {
            Text("與目前版本比較")
        }
        .font(.subheadline)
    }

    private func names(_ ids: [String]) -> String {
        ids.map { RouteCatalog.sourceName(for: $0) ?? $0 }.joined(separator: "、")
    }
}
