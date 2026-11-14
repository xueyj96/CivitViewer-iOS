import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct LocalDiagnosticsView: View {
    @State private var entries: [DiagnosticEntry] = []
    @State private var showingClear = false
    @State private var errorMessage: String?
    @State private var loading = true
    @State private var busy = false
    @State private var operationRevision = 0
    @State private var active = false

    var body: some View {
        List {
            Group {
                if loading { ProgressView("读取本机记录…") }
                if entries.isEmpty && !loading { Text("暂无记录").foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: FloatingPageChrome.groupInset) {
                        HStack {
                            Text(entry.area.title).font(.subheadline.weight(.semibold))
                            Text(entry.code.title).font(.subheadline)
                            Spacer()
                            if let status = entry.httpStatus { Text("HTTP \(status)").font(.caption.monospacedDigit()) }
                        }
                        HStack(spacing: FloatingPageChrome.spacing) {
                            Text(entry.timestamp.formatted(.dateTime.locale(Locale(identifier: "zh_Hans_CN")).month().day().hour().minute().second()))
                            Text("版本 \(entry.build)")
                            if let count = entry.count { Text(entry.code.isFrameReadyMeasurement ? "首帧 \(count) ms" : "数量 \(count)") }
                            if entry.suppressed > 0 { Text("合并 \(entry.suppressed) 条重复记录") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let playback = entry.playback {
                            Text(playback.summary).font(.caption.monospacedDigit()).textSelection(.enabled)
                        }
                        if let tagSearch = entry.tagSearch {
                            Text(tagSearch.summary).font(.caption.monospacedDigit()).textSelection(.enabled)
                        }
                        if let download = entry.download {
                            Text(download.summary).font(.caption.monospacedDigit()).textSelection(.enabled)
                        }
                    }.padding(.vertical, FloatingPageChrome.groupInset)
                }
            }
            .floatingCardListRows()
        }
        .accessibilityIdentifier("diagnostics.card-list")
        .listStyle(.plain)
        .listRowSpacing(FloatingPageChrome.groupInset)
        .avoidOverlaidTabBar(constrainViewport: true)
        .floatingTitleBar("本机诊断记录") {
            AppMenu {
                AppMenuShareLink(prepare: { await prepareExport() }, onFinish: { url in
                    try? FileManager.default.removeItem(at: url)
                }) {
                    Label("导出记录", systemImage: "square.and.arrow.up")
                }
                .disabled(busy)
                .accessibilityIdentifier("diagnostics.export")
                Button("清空记录", systemImage: "trash", role: .destructive) { showingClear = true }
                    .disabled(entries.isEmpty || busy)
                    .accessibilityIdentifier("diagnostics.clear")
            } label: {
                FloatingPageIcon(symbol: "ellipsis")
            }
            .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
            .accessibilityLabel("本机诊断记录操作")
            .accessibilityIdentifier("diagnostics.actions")
        }
        .ordinaryAppearance()
        .existingFeedbackToast(errorMessage, id: operationRevision, active: active, scope: operationRevision)
        .task { await reload() }
        .onDisappear { leaveView() }
        .appConfirmationDialog("清空诊断记录？", isPresented: $showingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { Task { await clear() } }.disabled(busy)
        }
    }

    @MainActor private func reload() async {
        active = true
        errorMessage = nil
        operationRevision += 1
        busy = false
        loading = true
        defer { loading = false }
        do { entries = try await LocalDiagnosticsStore.shared.entries(); errorMessage = nil }
        catch { errorMessage = "暂时无法读取本机记录。" }
    }

    @MainActor private func prepareExport() async -> URL? {
        guard active, !busy else { return nil }
        errorMessage = nil
        busy = true
        operationRevision += 1
        let revision = operationRevision
        defer { if operationRevision == revision { busy = false } }
        let destination = Self.exportDirectory.appendingPathComponent("diagnostics-" + UUID().uuidString + ".json")
        do {
            let data = try await LocalDiagnosticsStore.shared.exportData()
            guard operationRevision == revision else { return nil }
            let directory = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var directoryValues = URLResourceValues(); directoryValues.isExcludedFromBackup = true
            var mutableDirectory = directory; try mutableDirectory.setResourceValues(directoryValues)
            try data.write(to: destination, options: .atomic)
            var fileValues = URLResourceValues(); fileValues.isExcludedFromBackup = true
            var mutableFile = destination; try mutableFile.setResourceValues(fileValues)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            #endif
            guard operationRevision == revision else {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
            errorMessage = nil
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if active, operationRevision == revision { errorMessage = "暂时无法准备导出文件。" }
        }
        return nil
    }

    @MainActor private func clear() async {
        guard active, !busy else { return }
        errorMessage = nil
        busy = true
        operationRevision += 1
        let revision = operationRevision
        defer { if operationRevision == revision { busy = false } }
        do {
            try await LocalDiagnosticsStore.shared.clear()
            guard operationRevision == revision else { return }
            entries = []; errorMessage = nil
        } catch { if active, operationRevision == revision { errorMessage = "暂时无法清除本机记录。" } }
    }

    @MainActor private func leaveView() {
        operationRevision += 1
        active = false
        busy = false
    }

    private static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CivitViewerDiagnostics", isDirectory: true)
    }
}
