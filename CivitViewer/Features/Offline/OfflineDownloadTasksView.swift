import SwiftUI

struct OfflineDownloadTasksView: View {
    enum Section: String, CaseIterable { case tasks = "任务", space = "空间" }
    @State private var section: Section = .tasks
    @State private var showSettings = false
    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var library = OfflineLibrary.shared

    var body: some View {
        SegmentedContentPager(selection: section, options: Section.allCases,
                              identifier: "downloads.section") { section, _ in
            switch section {
            case .tasks: OfflineDownloadTaskContent().pageContentViewport(active: self.section == .tasks)
            case .space: OfflineStorageView(embedded: true).pageContentViewport(active: self.section == .space)
            }
        }
        .floatingPageBar("page-title.下载管理", layout: .doubleRow) {
            VStack(spacing: 0) {
                HStack(spacing: FloatingPageChrome.groupInset) {
                    FloatingPageBackButton()
                    Text("下载管理")
                        .font(FloatingPageChrome.controlFont)
                        .frame(maxWidth: .infinity, minHeight: FloatingPageChrome.controlHeight)
                        .background { FloatingSegmentedTrack(nested: true, overMedia: false) }
                        .accessibilityAddTraits(.isHeader)
                    AppMenu {
                        Button("检查待下载收藏", systemImage: "arrow.clockwise") {
                            library.resumeAll(session: session)
                        }
                        .disabled(!session.hasCollectionAccess || library.busy)
                        Button("下载设置", systemImage: "gearshape") { showSettings = true }
                    } label: { FloatingPageIcon(symbol: "ellipsis") }
                    .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                    .accessibilityLabel("下载操作")
                    .accessibilityIdentifier("downloads.menu")
                }
                FloatingSegmentedControl(title: "下载管理分类", selection: $section,
                                         options: Section.allCases, optionTitle: { $0.rawValue },
                                         identifier: "downloads.section")
            }
        }
        .edgeSwitchingSegments(selection: $section, options: Section.allCases,
                               identifier: "downloads.section", reservesPageEdges: false,
                               leftEdge: false, rightEdge: false, centerSwipe: false)
        .navigationDestination(isPresented: $showSettings) { OfflineDownloadSettingsView() }
        .ordinaryAppearance()
    }
}

/// Queue content shares the management page chrome with the capacity pane.
private struct OfflineDownloadTaskContent: View {
    private enum TaskAction {
        case download, pause, resume, retry

        var symbol: String {
            switch self {
            case .download: "arrow.down"
            case .pause: "pause.fill"
            case .resume: "play.fill"
            case .retry: "arrow.clockwise"
            }
        }
        var title: String {
            switch self {
            case .download: "下载"
            case .pause: "暂停下载"
            case .resume: "继续下载"
            case .retry: "重试下载"
            }
        }
    }

    @EnvironmentObject private var session: SiteSession
    @ObservedObject private var library = OfflineLibrary.shared
    @ObservedObject private var blockedAuthors = AuthorBlocklist.shared
    @ObservedObject private var blockedTags = TagBlocklist.shared

    private var ownsQueue: Bool {
        guard let account = session.account else { return false }
        return library.accountID == account.id
    }

    private var visibleTasks: [OfflineRecord] {
        guard ownsQueue else { return [] }
        return library.downloadRecords.filter { record in
            TagPolicy.verdict(names: record.tagNames, blocked: blockedTags.names) == .allowed &&
            !AuthorHandlePolicy.blocks(creatorID: record.creatorID, username: record.username,
                                       blockedIDs: blockedAuthors.blockedIDs, blockedHandles: blockedAuthors.blockedHandles)
        }
    }

    private var checkingQueue: Bool { ownsQueue && library.busy && library.currentID == nil }

    private var emptyState: (title: String, symbol: String?) {
        if !session.hasCollectionAccess { return ("启用账号收藏后可同步下载", "person") }
        if !ownsQueue || library.loading { return ("正在读取下载任务…", nil) }
        if checkingQueue { return (library.status, nil) }
        if library.queueNotice != nil, library.networkWaitNotice == nil { return ("", "exclamationmark.circle") }
        if library.pausedByUser { return ("下载已暂停", "pause") }
        return ("暂无下载任务", "arrow.down.to.line")
    }

    var body: some View {
        let tasks = visibleTasks
        let front = tasks.first { $0.id == (library.currentID ?? library.pausedTaskID) }
        let networkNotice = ownsQueue && !library.loading && session.hasCollectionAccess && !library.busy
            ? library.networkWaitNotice : nil
        Group {
            if tasks.isEmpty && (!ownsQueue || library.loading) && session.hasCollectionAccess {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("正在读取下载任务")
            } else if tasks.isEmpty && ownsQueue && !library.loading && !checkingQueue
                        && library.queueNotice == nil && networkNotice == nil && !library.pausedByUser {
                VStack(spacing: FloatingPageChrome.spacing) {
                    FloatingPageIcon(symbol: "arrow.down.to.line").foregroundStyle(.secondary)
                    Text("暂无下载任务").font(AppTypography.rowTitle)
                    Text("收藏作品后自动下载").font(AppTypography.supportingText).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("downloads.empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: FloatingPageChrome.spacing) {
                        if tasks.isEmpty {
                            let state = emptyState
                            queueStatus(state.title, symbol: state.symbol, detail: networkNotice)
                        } else {
                            if let networkNotice {
                                queueStatus(networkNotice, symbol: "wifi")
                            } else if checkingQueue {
                                queueStatus(library.status, symbol: nil)
                            }
                            if let front { taskRow(front) }
                            ForEach(tasks.filter { $0.id != front?.id }, content: taskRow)
                        }
                    }
                    .pageScrollContentInsets()
                }
            }
        }
        .existingFeedbackToast(ownsQueue && session.hasCollectionAccess && !library.loading && !checkingQueue
                               && library.networkWaitNotice == nil && (tasks.isEmpty || !library.busy) ? library.queueNotice : nil,
                               scope: library.bindingID)
    }

    @ViewBuilder private func queueStatus(_ title: String, symbol: String?, detail: String? = nil) -> some View {
        if let symbol {
            PageStatusCard(title: title, symbol: symbol, detail: detail)
        } else {
            PageContentCard {
                HStack(spacing: FloatingPageChrome.spacing) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, FloatingPageChrome.groupInset)
                .frame(minHeight: FloatingPageChrome.controlHeight)
            }
        }
    }

    private func taskRow(_ record: OfflineRecord) -> some View {
        let active = record.id == library.currentID
        let paused = record.id == library.pausedTaskID
        let failed = record.fileState == .failed
        let progress = active ? library.progress : nil
        let action: TaskAction = if active { .pause } else if paused { .resume } else if failed { .retry } else { .download }
        let enabled = active ? library.canPauseWork : (!library.busy && session.hasCollectionAccess)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: FloatingPageChrome.spacing) {
                Image(systemName: record.video ? "play.rectangle" : "photo")
                    .font(.subheadline).foregroundStyle(.secondary).frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text((record.video ? "视频" : "图片") + " #\(record.id)")
                        .font(.subheadline.weight(.medium))
                    if let username = record.username {
                        Text("@" + username).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    switch action {
                    case .pause: library.pauseDownloads()
                    case .resume: library.resumeAll(session: session)
                    case .download, .retry: library.download(record.id, session: session)
                    }
                } label: {
                    Image(systemName: action.symbol).font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(AppActionButtonStyle(circular: true))
                .disabled(!enabled)
                .accessibilityLabel("\(action.title)作品 \(record.id)")
                .accessibilityIdentifier("downloads.task-action.\(record.id)")
            }
            if active {
                HStack(spacing: 8) {
                    DownloadTaskProgress(value: progress)
                        .accessibilityIdentifier("downloads.progress.\(record.id)")
                    if let progress {
                        Text(progress, format: .percent.precision(.fractionLength(0))).accessibilityHidden(true)
                    } else if library.downloadedBytes > 0 {
                        Text(AppTheme.storageSize(library.downloadedBytes))
                    }
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.leading, 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FloatingPageChrome.cardInset)
        .padding(.vertical, FloatingPageChrome.groupInset)
        .background(AppTheme.secondarySurface, in: FloatingPageChrome.controlShape)
    }
}


/// Explicit track geometry; an unknown total stays indeterminate.
private struct DownloadTaskProgress: View {
    let value: Double?
    var body: some View {
        Group {
            if let value, value.isFinite {
                let fraction = min(1, max(0, value))
                GeometryReader { geometry in
                    Capsule().fill(Color.primary.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.accentColor)
                                .frame(width: geometry.size.width * fraction)
                        }
                }
                .frame(height: ContentMetrics.Media.trackHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
            } else {
                ProgressView().controlSize(.mini)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityValue("总大小未知")
            }
        }
        .accessibilityLabel("下载进度")
    }
}
