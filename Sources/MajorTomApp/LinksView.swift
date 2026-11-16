import GroundControl
import MajorTomCore
import SwiftUI

extension EntryState {
    var title: String {
        switch self {
        case .backedUp: "Backed up"
        case .partial: "Partly backed up"
        case .notBackedUp: "Not backed up"
        case .offloaded: "On backup only"
        case .conflict: "Newer on backup"
        }
    }

    var color: Color {
        switch self {
        case .backedUp: .green
        case .partial: .orange
        case .notBackedUp: .red
        case .offloaded: .blue
        case .conflict: .purple
        }
    }

    var symbol: String {
        switch self {
        case .backedUp: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .notBackedUp: "circle.dashed"
        case .offloaded: "externaldrive.fill"
        case .conflict: "exclamationmark.triangle.fill"
        }
    }
}

/// Linked folders: a working folder on this Mac next to its copy on another drive.
struct LinksView: View {
    @Environment(GroundControlModel.self) private var model
    @State private var adding = false
    @State private var removing: FolderLink?

    private var links: LinksModel { model.links }

    var body: some View {
        Group {
            if let link = links.selectedLink {
                VStack(spacing: 0) {
                    if links.links.count > 1 { linkPicker }
                    LinkDetail(link: link, report: links.reports[link.id], addLink: { adding = true },
                               remove: { removing = link })
                }
            } else {
                ContentUnavailableView {
                    Label("Link a folder to its backup", systemImage: "link")
                } description: {
                    Text("Pick a folder you work in and the folder on an external drive that holds its copy. Prune then shows what is backed up, copies what isn't, and points out what you haven't touched in a while and could take off this Mac.")
                        .frame(maxWidth: 460)
                } actions: {
                    Button("Link a Folder…") { adding = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await links.compareAll() }
        .sheet(isPresented: $adding) { AddLinkSheet().environment(model) }
        .sheet(isPresented: Binding(get: { links.run != nil }, set: { if !$0 { links.dismissRun() } })) {
            LinkRunSheet().environment(model).interactiveDismissDisabled(links.run?.isRunning ?? false)
        }
        .confirmationDialog("Stop linking “\(removing?.name ?? "")”?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { link in
            Button("Remove Link") { links.removeLink(link) }
        } message: { _ in
            Text("Only the link is forgotten. Both folders and everything in them stay exactly as they are.")
        }
    }

    private var linkPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(links.links) { link in
                    Button { links.select(link) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(link.destinationConnected ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(link.name)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(link.id == links.selectedLink?.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }
    }
}

private struct LinkDetail: View {
    @Environment(GroundControlModel.self) private var model
    let link: FolderLink
    let report: LinkReport?
    let addLink: () -> Void
    let remove: () -> Void

    private var links: LinksModel { model.links }
    private var connected: Bool { report?.destinationConnected ?? link.destinationConnected }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            if let report, !report.entries.isEmpty {
                table(report)
            } else if links.comparing.contains(link.id) {
                VStack(spacing: 8) { ProgressView(); Text("Comparing the two folders…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(report?.sourceExists == false ? "The folder isn't there" : "Nothing in this folder yet",
                                       systemImage: "folder",
                                       description: Text(short(link.source)))
            }
        }
    }

    private func short(_ path: String) -> String {
        let home = model.environment.context.home.path(percentEncoded: false)
        return path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
    }

    private var summary: some View {
        let candidates = report?.offloadCandidates(afterDays: link.offloadAfterDays) ?? []
        let offloadable = candidates.reduce(0) { $0 + $1.localBytes }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(link.name).font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Image(systemName: "laptopcomputer")
                        Text(short(link.source)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "arrow.right").font(.caption)
                        Image(systemName: connected ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.xmark")
                            .foregroundStyle(connected ? .green : .secondary)
                        Text(short(link.destination)).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if links.comparing.contains(link.id) { ProgressView().controlSize(.small) }
                Menu {
                    Button("Compare Again") { Task { await links.compare(link) } }
                    Button("Show Folder in Finder") { NSWorkspace.shared.open(link.sourceURL) }
                    Button("Show Backup in Finder") { NSWorkspace.shared.open(link.destinationURL) }.disabled(!connected)
                    Divider()
                    Picker("Suggest offloading after", selection: Binding(get: { link.offloadAfterDays },
                                                                           set: { links.setOffloadAfterDays($0, for: link) })) {
                        ForEach([14, 30, 60, 90, 180, 365], id: \.self) { Text("\($0) days untouched").tag($0) }
                    }
                    Toggle("Compare every byte before offloading", isOn: Binding(get: { links.thoroughVerification },
                                                                                 set: { links.thoroughVerification = $0 }))
                    Divider()
                    Button("Link Another Folder…", action: addLink)
                    Button("Remove This Link…", action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
            }

            if let report {
                BackupBar(backedUp: report.backedUpBytes, offloadable: offloadable, pending: report.pendingBytes)
                    .frame(height: 10)
                HStack(spacing: 18) {
                    stat(.green, "Backed up", report.backedUpBytes)
                    stat(.orange, "Not yet", report.pendingBytes)
                    stat(.blue, "Could leave this Mac", offloadable)
                    if report.backupOnlyBytes > 0 { stat(.secondary, "On backup only", report.backupOnlyBytes) }
                    Spacer()
                }
                .font(.callout)
                if !connected {
                    Label(report.comparedAt.map { "The backup drive isn't connected. Showing what was true when they were last compared, \($0.formatted(.relative(presentation: .named)))." }
                          ?? "The backup drive isn't connected, so nothing can be compared yet.",
                          systemImage: "externaldrive.badge.xmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        links.reviewBackUp(link)
                    } label: {
                        Label(report.pendingCount > 0 ? "Back Up \(ByteFormat.string(report.pendingBytes))…" : "Everything Is Backed Up",
                              systemImage: "arrow.right.doc.on.clipboard")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(report.pendingCount == 0 || !connected)

                    let chosen = links.offloadable(link)
                    Button {
                        links.reviewOffload(link)
                    } label: {
                        Label(chosen.isEmpty ? "Offload Selected…" : "Offload \(ByteFormat.string(chosen.reduce(0) { $0 + $1.localBytes }))…",
                              systemImage: "arrow.up.forward.app")
                    }
                    .disabled(chosen.isEmpty || !connected)
                    .help("Check each file against its backup copy, then move the local copy to the Trash")

                    if !candidates.isEmpty {
                        Button("Select the \(candidates.count) Suggested") { links.checkOffloadCandidates(link) }
                            .buttonStyle(.link)
                            .help("Fully backed up and untouched for \(link.offloadAfterDays) days or more")
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func stat(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
            Text(ByteFormat.string(bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func table(_ report: LinkReport) -> some View {
        List {
            ForEach(report.entries) { entry in
                LinkEntryRow(link: link, entry: entry, connected: connected)
            }
        }
        .listStyle(.inset)
    }
}

private struct LinkEntryRow: View {
    @Environment(GroundControlModel.self) private var model
    let link: FolderLink
    let entry: LinkEntry
    let connected: Bool

    var body: some View {
        let links = model.links
        let canCheck = entry.state == .backedUp && !entry.remembered && connected
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { links.checked.contains(entry.name) },
                                     set: { on in if on { links.checked.insert(entry.name) } else { links.checked.remove(entry.name) } }))
                .labelsHidden()
                .disabled(!canCheck)
                .opacity(canCheck ? 1 : 0.25)
                .help(canCheck ? "Select to offload" : "Only items that are fully on the backup can be offloaded")
            Image(systemName: entry.isDirectory ? "folder.fill" : entry.kind.symbol)
                .foregroundStyle(entry.kind.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(advice).font(.caption).foregroundStyle(isSuggested ? AnyShapeStyle(.blue) : AnyShapeStyle(.secondary)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if entry.state == .offloaded {
                Button("Bring Back") { links.reviewBringBack(link, entry: entry) }
                    .controlSize(.small)
                    .disabled(!connected)
            }
            Label(entry.remembered && entry.state == .backedUp ? "Backed up (last check)" : entry.state.title,
                  systemImage: entry.state.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(entry.state.color)
                .frame(width: 150, alignment: .leading)
            Text(ByteFormat.string(entry.state == .offloaded ? entry.backupOnlyBytes : entry.localBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Show in Finder") {
                let base = entry.state == .offloaded ? link.destinationURL : link.sourceURL
                NSWorkspace.shared.activateFileViewerSelecting([base.appending(path: entry.name)])
            }
        }
    }

    private var isSuggested: Bool { !entry.remembered && entry.isOffloadCandidate(afterDays: link.offloadAfterDays) }

    private var advice: String {
        let untouched = entry.daysUntouched().map { $0 == 0 ? "touched today" : "untouched for \($0) day\($0 == 1 ? "" : "s")" }
        switch entry.state {
        case .backedUp:
            if isSuggested { return "Could leave this Mac: safely on the backup, \(untouched ?? "untouched")" }
            return "\(entry.localCount) file\(entry.localCount == 1 ? "" : "s") · \(untouched ?? "")"
        case .partial, .notBackedUp:
            return "\(entry.pendingCount) file\(entry.pendingCount == 1 ? "" : "s") (\(ByteFormat.string(entry.pendingBytes))) not on the backup yet · \(untouched ?? "")"
        case .offloaded:
            return "\(entry.backupOnlyCount) file\(entry.backupOnlyCount == 1 ? "" : "s") on the backup, none on this Mac"
        case .conflict:
            return "\(entry.conflictCount) file\(entry.conflictCount == 1 ? " is" : "s are") newer on the backup than here. Nothing is overwritten; check by hand."
        }
    }
}

/// Backed up (the part that could leave this Mac drawn deeper) next to what still needs copying.
private struct BackupBar: View {
    let backedUp: Int64
    let offloadable: Int64
    let pending: Int64

    var body: some View {
        GeometryReader { geo in
            let total = Double(max(backedUp + pending, 1))
            let keep = Double(max(0, backedUp - offloadable))
            HStack(spacing: 1.5) {
                Rectangle().fill(.green).frame(width: geo.size.width * keep / total)
                Rectangle().fill(.blue).frame(width: geo.size.width * Double(min(offloadable, backedUp)) / total)
                Rectangle().fill(.orange).frame(width: geo.size.width * Double(pending) / total)
                Spacer(minLength: 0)
            }
            .background(.secondary.opacity(0.15))
            .clipShape(Capsule())
        }
        .accessibilityElement()
        .accessibilityLabel("Backup state")
        .accessibilityValue("\(ByteFormat.string(backedUp)) backed up, \(ByteFormat.string(pending)) not yet")
    }
}

private struct AddLinkSheet: View {
    @Environment(GroundControlModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var source: URL?
    @State private var destination: URL?
    @State private var days = 60

    var body: some View {
        let problem = source.flatMap { s in destination.flatMap { model.links.problem(source: s, destination: $0) } }
        VStack(alignment: .leading, spacing: 16) {
            Text("Link a folder to its backup").font(.title2.weight(.semibold))
            Text("Nothing is copied or changed by linking. You decide when to back up and what to offload.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Working folder").gridColumnAlignment(.trailing)
                    folderButton(source, placeholder: "Choose the folder on this Mac…") { pick(start: model.environment.context.home, into: $source) }
                }
                GridRow {
                    Text("Backup folder")
                    folderButton(destination, placeholder: "Choose the folder on the other drive…") {
                        pick(start: URL(filePath: "/Volumes", directoryHint: .isDirectory), into: $destination, canCreate: true)
                    }
                }
                GridRow {
                    Text("Name")
                    TextField(source?.lastPathComponent ?? "e.g. Shoots", text: $name).frame(width: 260)
                }
                GridRow {
                    Text("Suggest offloading")
                    Picker("", selection: $days) {
                        ForEach([14, 30, 60, 90, 180, 365], id: \.self) { Text("after \($0) days untouched").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link") {
                    if let source, let destination {
                        model.links.addLink(name: name, source: source, destination: destination, offloadAfterDays: days)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || destination == nil || problem != nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func folderButton(_ url: URL?, placeholder: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: "folder")
                Text(url?.path(percentEncoded: false) ?? placeholder).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
            }
            .frame(width: 240)
        }
    }

    private func pick(start: URL, into binding: Binding<URL?>, canCreate: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.directoryURL = start
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url }
    }
}

/// Confirm → progress → result for a backup, an offload or a bring-back.
private struct LinkRunSheet: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let run = model.links.run {
                switch run.phase {
                case .confirm: confirm(run)
                case .running(let progress): running(run, progress)
                case .finished(let report): finished(run, report)
                }
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func title(_ run: LinkRun) -> String {
        switch run.action {
        case .backUp: "Back up “\(run.link.name)”"
        case .offload: "Offload from this Mac"
        case .bringBack: "Bring back from the backup"
        }
    }

    @ViewBuilder
    private func confirm(_ run: LinkRun) -> some View {
        Text(title(run)).font(.title2.weight(.semibold))
        Text("\(run.files.formatted()) file\(run.files == 1 ? "" : "s"), \(ByteFormat.string(run.bytes))")
            .font(.title3).monospacedDigit()
        VStack(alignment: .leading, spacing: 8) {
            switch run.action {
            case .backUp:
                point("doc.on.doc", "Each file is copied to \(run.link.destination), read back from the drive and compared with the original.")
                point("lock.shield", "Nothing on the backup is deleted. A file that is newer on the backup is left alone.")
            case .offload:
                ForEach(run.entries ?? [], id: \.self) { Label($0, systemImage: "folder").lineLimit(1) }
                Divider()
                point("checkmark.shield", model.links.thoroughVerification
                      ? "Every byte of every file is compared with its backup copy first."
                      : "Every file is compared with its backup copy first: size, date and content (large files by a sample of their content).")
                point("trash", "Then the local copy moves to the Trash. The space is freed when you empty it; until then you can put it back.")
                point("xmark.shield", "If a single file doesn't match, that whole item stays where it is.")
            case .bringBack:
                point("arrow.down.doc", "Copied back into \(run.link.source) and verified. The backup keeps its copy.")
            }
        }
        .foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("Cancel") { model.links.cancelRun() }.keyboardShortcut(.cancelAction)
            Button(run.action == .offload ? "Verify and Offload" : run.action == .backUp ? "Back Up" : "Bring Back") {
                Task { await model.links.confirmRun() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func running(_ run: LinkRun, _ progress: LinkProgress) -> some View {
        Text(title(run)).font(.title2.weight(.semibold))
        ProgressView(value: Double(progress.doneBytes), total: Double(max(progress.totalBytes, 1)))
        HStack {
            Text("\(ByteFormat.string(progress.doneBytes)) of \(ByteFormat.string(progress.totalBytes))").monospacedDigit()
            Spacer()
            Text("\(progress.doneFiles) of \(progress.totalFiles) files").monospacedDigit()
        }
        .foregroundStyle(.secondary)
        Text(progress.current).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        HStack { Spacer(); Button("Stop") { model.links.cancelRun() } }
    }

    @ViewBuilder
    private func finished(_ run: LinkRun, _ report: LinkRunReport) -> some View {
        let verb = switch run.action {
        case .backUp: "backed up"
        case .offload: "moved to the Trash"
        case .bringBack: "brought back"
        }
        Label(report.problems.isEmpty && !report.cancelled ? "Done" : report.files > 0 ? "Partly done" : "Nothing was changed",
              systemImage: report.problems.isEmpty && !report.cancelled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.title2.weight(.semibold))
            .foregroundStyle(report.problems.isEmpty && !report.cancelled ? .green : .orange)
        Text("\(report.files.formatted()) file\(report.files == 1 ? "" : "s") (\(ByteFormat.string(report.bytes))) \(verb).")
            .monospacedDigit()
        if run.action == .offload, report.files > 0 {
            Text("Empty the Trash to get the space back.").foregroundStyle(.secondary)
        }
        ForEach(report.problems) { outcome in
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.name).fontWeight(.medium)
                Text(outcome.error ?? outcome.skipped ?? "").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack {
            Spacer()
            Button("Done") { model.links.dismissRun() }.keyboardShortcut(.defaultAction)
        }
    }
}
