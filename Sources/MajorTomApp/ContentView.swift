import GroundControl
import MajorTomCore
import SwiftUI

enum SidebarSelection: Hashable {
    case map
    case links
    case all
    case category(RuleCategory)
    case projects
    case offload
    case offloaded
    case history
}

struct ContentView: View {
    @Environment(GroundControlModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @State private var sidebar: SidebarSelection? = ContentView.initialSidebar()

    /// A function, not an inline `switch`: the `@State` macro (Swift 6.4) rejects a switch expression initialiser.
    static func initialSidebar() -> SidebarSelection {
        switch Snapshotter.argument("--sidebar") {
        case "history": return .history
        case "projects": return .projects
        case "files": return .category(.files)
        case "offload": return .offload
        case "offloaded": return .offloaded
        case "map": return .map
        case "links": return .links
        case "clean": return .all
        default: return .map
        }
    }
    @State private var selectedRuleID: String?

    /// The reclaimable-by-tier gauge belongs to the clean-up screens; the map and links have their own headers.
    private var showsCleanHeader: Bool {
        switch sidebar ?? .map {
        case .map, .links: false
        default: true
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if model.environment.isFixture { FixtureBanner() }
                if model.fullDiskAccess == .denied { FullDiskAccessBanner() }
                if showsCleanHeader {
                    DiskGaugeHeader()
                    Divider()
                }
                switch sidebar ?? .map {
                case .map:
                    MapView()
                case .links:
                    LinksView()
                case .history:
                    HistoryView()
                case .projects:
                    ProjectsView()
                case .offload:
                    OffloadView()
                case .offloaded:
                    OffloadedView()
                case .all:
                    RulesBrowser(category: nil, selectedRuleID: $selectedRuleID)
                case .category(let c):
                    RulesBrowser(category: c, selectedRuleID: $selectedRuleID)
                }
            }
            .toolbar { MainToolbar() }
            .sheet(isPresented: Binding(get: { model.offloadSession != nil },
                                        set: { if !$0 { model.dismissOffload() } })) {
                OffloadSheet().environment(model).interactiveDismissDisabled(model.offloadSession?.isRunning ?? false)
            }
            .sheet(isPresented: Binding(get: { model.restoreSession != nil },
                                        set: { if !$0 { model.dismissRestore() } })) {
                RestoreSheet().environment(model).interactiveDismissDisabled(model.restoreSession?.isRunning ?? false)
            }
        }
        .sheet(isPresented: Binding(get: { model.cleanSession != nil },
                                    set: { if !$0 { model.dismissResult() } })) {
            CleanSheet()
                .environment(model)
        }
        .onChange(of: sidebar) { selectedRuleID = nil }
        .onAppear { if CommandLine.arguments.contains("--open-settings") { openSettings() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshFullDiskAccess(); model.refreshDisk(); model.refreshDestination() } }
        }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(GroundControlModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if model.isScanning {
                Button { model.cancelScan() } label: {
                    Label("Stop Scan", systemImage: "stop.circle")
                }
                .help("Stop scanning")
            } else {
                Button { model.startScanAll() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Rescan everything (⌘R)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.quickClean() }
            } label: {
                Label("Quick Clean", systemImage: "sparkles")
            }
            .help("Select every safe item (\(ByteFormat.string(model.safeReclaimable))) and review (⇧⌘K)")
            .disabled(model.safeReclaimable == 0 || model.isScanning)

            let plan = model.plan
            Button {
                Task { await model.review() }
            } label: {
                Text(plan.isEmpty ? "Review…" : "Review \(selectionSummary(plan))…")
            }
            .buttonStyle(.glassProminent)
            .help("Review the selected items before anything is removed (⌘↩)")
            .disabled(plan.isEmpty)
        }
    }

    private func selectionSummary(_ plan: CleanPlan) -> String {
        var parts: [String] = []
        if plan.itemCount > 0 { parts.append(ByteFormat.string(plan.estimatedBytes)) }
        if plan.actionCount > 0 { parts.append("\(plan.actionCount) action\(plan.actionCount == 1 ? "" : "s")") }
        return parts.joined(separator: " + ")
    }
}

struct FixtureBanner: View {
    @Environment(GroundControlModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "testtube.2")
            Text("Fixture mode — cleaning only touches a throwaway folder; commands are simulated.")
            Spacer()
            if let root = model.environment.fixture?.root {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.purple.opacity(0.12))
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Prune doesn't have Full Disk Access").fontWeight(.semibold)
                Text("The Trash and some app caches can't be measured until you allow it. Add Prune, then come back.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.10))
    }
}
