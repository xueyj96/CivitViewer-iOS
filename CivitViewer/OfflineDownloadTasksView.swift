import SwiftUI

struct OfflineDownloadTasksView: View {
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

    private var queueAction: (symbol: String, title: String) {
        if library.canPauseWork { ("pause", "暂停下载") }
        else if library.pausedByUser || library.pausedTaskID != nil { ("play", "继续下载") }
        else { ("arrow.clockwise", "同步收藏") }
    }

    private var checkingQueue: Bool { ownsQueue && library.busy && library.currentID == nil }

    private var emptyState: (title: String, symbol: String?) {
        if !session.hasCollectionAccess { return ("启用账号收藏后可同步下载", "person") }
        if !ownsQueue || library.loading { return ("正在读取下载任务…", nil) }
        if checkingQueue { return (library.status, nil) }
        if let notice = library.queueNotice, library.networkWaitNotice == nil { return (notice, "exclamationmark.circle") }
        if library.pausedByUser { return ("下载已暂停", "pause") }
        return ("暂无下载任务", "arrow.down.to.line")
    }

    var body: some View {
        let tasks = visibleTasks
        let front = tasks.first { $0.id == (library.currentID ?? library.pausedTaskID) }
        let networkNotice = ownsQueue && !library.loading && session.hasCollectionAccess && !library.busy
            ? library.networkWaitNotice : nil
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
                    } else if session.hasCollectionAccess && !library.busy, let notice = library.queueNotice {
                        queueStatus(notice, symbol: "exclamationmark.circle")
                    }
                    if let front { taskRow(front) }
                    ForEach(tasks.filter { $0.id != front?.id }, content: taskRow)
                }
            }
            .pageScrollContentInsets()
        }
        .floatingTitleBar("下载管理") {
            if front == nil || (library.busy && library.currentID == nil) {
                Button {
                    if library.canPauseWork { library.pauseDownloads() }
                    else { library.resumeAll(session: session) }
                } label: {
                    FloatingPageIcon(symbol: queueAction.symbol)
                }
                .buttonStyle(FloatingPageButtonStyle(iconOnly: true))
                .disabled(!ownsQueue || !session.hasCollectionAccess || (library.busy && !library.canPauseWork))
                .accessibilityLabel(queueAction.title)
                .accessibilityIdentifier("downloads.queue-action")
            }
        }
        .ordinaryAppearance()
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
            HStack(spacing: 10) {
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
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                        .scaleEffect(x: 1, y: 0.55, anchor: .center)
                        .accessibilityLabel("下载进度")
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
