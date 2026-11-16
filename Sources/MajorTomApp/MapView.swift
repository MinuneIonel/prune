import GroundControl
import MajorTomCore
import SwiftUI

extension FileKind {
    var color: Color {
        switch self {
        case .photo: Color(red: 0.96, green: 0.72, blue: 0.20)
        case .video: Color(red: 0.93, green: 0.30, blue: 0.48)
        case .audio: Color(red: 0.20, green: 0.72, blue: 0.70)
        case .project: Color(red: 0.62, green: 0.42, blue: 0.92)
        case .code: Color(red: 0.26, green: 0.56, blue: 0.96)
        case .cache: Color(red: 0.95, green: 0.50, blue: 0.22)
        case .archive: Color(red: 0.66, green: 0.52, blue: 0.40)
        case .app: Color(red: 0.42, green: 0.44, blue: 0.84)
        case .document: Color(red: 0.42, green: 0.78, blue: 0.52)
        case .other: Color(white: 0.56)
        }
    }

    var symbol: String {
        switch self {
        case .photo: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .project: "square.stack.3d.down.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .cache: "clock.arrow.2.circlepath"
        case .archive: "archivebox"
        case .app: "app"
        case .document: "doc.text"
        case .other: "doc"
        }
    }
}

/// One ring segment of the sunburst.
struct SunburstArc: Identifiable {
    let id: String
    /// Nil for the "smaller items" remainder of a folder.
    let node: MapNode?
    let depth: Int
    let start: Double
    let end: Double
    let kind: FileKind
}

enum SunburstLayout {
    static let rings = 5
    /// Segments thinner than this are folded into their folder's remainder.
    static let minimumAngle = 0.008

    static func arcs(focus: MapNode) -> [SunburstArc] {
        var out: [SunburstArc] = []
        func place(_ node: MapNode, depth: Int, start: Double, end: Double) {
            guard node.size > 0 else { return }
            let span = end - start
            var angle = start
            for child in node.children {
                let width = span * Double(child.size) / Double(node.size)
                if width < minimumAngle { break }
                out.append(SunburstArc(id: child.path, node: child, depth: depth, start: angle, end: angle + width,
                                       kind: child.kind))
                if child.isDirectory, depth < rings { place(child, depth: depth + 1, start: angle, end: angle + width) }
                angle += width
            }
            if end - angle >= minimumAngle {
                out.append(SunburstArc(id: node.path + "/#smaller", node: nil, depth: depth, start: angle, end: end,
                                       kind: .other))
            }
        }
        place(focus, depth: 1, start: 0, end: 2 * .pi)
        return out
    }

    static func hit(_ point: CGPoint, in size: CGSize, arcs: [SunburstArc]) -> SunburstArc? {
        let g = Geometry(size)
        let dx = point.x - g.center.x, dy = point.y - g.center.y
        let r = hypot(dx, dy)
        guard r >= g.inner, r <= g.outer else { return nil }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        let depth = min(rings, Int((r - g.inner) / g.ring) + 1)
        return arcs.first { $0.depth == depth && angle >= $0.start && angle < $0.end }
    }

    struct Geometry {
        let center: CGPoint
        let inner: CGFloat
        let outer: CGFloat
        let ring: CGFloat

        init(_ size: CGSize) {
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            outer = max(40, min(size.width, size.height) / 2 - 12)
            inner = outer * 0.3
            ring = (outer - inner) / CGFloat(SunburstLayout.rings)
        }
    }
}

struct SunburstView: View {
    let focus: MapNode
    @Binding var hoverPath: String?
    let zoom: (MapNode) -> Void
    let zoomOut: () -> Void
    let canZoomOut: Bool

    var body: some View {
        let arcs = SunburstLayout.arcs(focus: focus)
        let hovered = arcs.first { $0.id == hoverPath }
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in
                    let g = SunburstLayout.Geometry(size)
                    for arc in arcs {
                        let r0 = g.inner + CGFloat(arc.depth - 1) * g.ring
                        let r1 = r0 + g.ring - 1.5
                        // A hairline gap between neighbours, scaled so it stays even on every ring.
                        let gap = min(0.006, (arc.end - arc.start) / 4) * Double(g.inner / r0)
                        let s = Angle(radians: arc.start - .pi / 2 + gap), e = Angle(radians: arc.end - .pi / 2 - gap)
                        var path = Path()
                        path.addArc(center: g.center, radius: r1, startAngle: s, endAngle: e, clockwise: false)
                        path.addArc(center: g.center, radius: r0, startAngle: e, endAngle: s, clockwise: true)
                        path.closeSubpath()
                        let base = arc.node == nil ? Color.secondary.opacity(0.22)
                            : arc.kind.color.opacity(1.0 - 0.14 * Double(arc.depth - 1))
                        context.fill(path, with: .color(base))
                        if arc.id == hoverPath { context.fill(path, with: .color(.white.opacity(0.28))) }
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverPath = SunburstLayout.hit(point, in: geo.size, arcs: arcs)?.id
                    case .ended: hoverPath = nil
                    }
                }
                .gesture(SpatialTapGesture().onEnded { tap in
                    if let node = SunburstLayout.hit(tap.location, in: geo.size, arcs: arcs)?.node { zoom(node) }
                })

                let g = SunburstLayout.Geometry(geo.size)
                Button(action: zoomOut) {
                    VStack(spacing: 3) {
                        if canZoomOut, hovered == nil {
                            Image(systemName: "chevron.up").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        }
                        Text(hovered.map { $0.node?.name ?? "Smaller items" } ?? focus.name)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text(ByteFormat.string(hovered.map { $0.node?.size ?? smallerBytes($0) } ?? focus.size))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        if let node = hovered?.node {
                            Text(node.origin?.name ?? node.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: g.inner * 1.7, height: g.inner * 1.7)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canZoomOut)
                .help(canZoomOut ? "Back out one folder" : "")
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Space map of \(focus.name), \(ByteFormat.string(focus.size))")
    }

    private func smallerBytes(_ arc: SunburstArc) -> Int64 {
        Int64(Double(focus.size) * (arc.end - arc.start) / (2 * .pi))
    }
}

struct MapView: View {
    @Environment(GroundControlModel.self) private var model
    @State private var hoverPath: String?
    @State private var tab = Tab.contents
    @State private var pendingTrash: MapNode?

    enum Tab: String, CaseIterable { case contents = "What's in here", origins = "Where it comes from" }

    private var atlas: AtlasModel { model.atlas }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let focus = atlas.focus, let map = atlas.map {
                HStack(spacing: 0) {
                    SunburstView(focus: focus, hoverPath: $hoverPath, zoom: { atlas.zoom(to: $0) },
                                 zoomOut: { atlas.zoomOut() }, canZoomOut: atlas.breadcrumbs.count > 1)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                        .opacity(atlas.isScanning ? 0.45 : 1)
                    Divider()
                    sidePanel(focus: focus, map: map)
                        .frame(width: 360)
                }
            } else if atlas.isScanning {
                ScanningPlaceholder(progress: atlas.progress, home: atlas.home)
            } else {
                ContentUnavailableView {
                    Label("Nothing mapped yet", systemImage: "circle.hexagongrid")
                } description: {
                    Text(atlas.message ?? "Map a folder to see what fills it.")
                } actions: {
                    Button("Map My Home Folder") { atlas.startScan() }
                }
            }
        }
        .task { await atlas.scanIfNeeded() }
        .confirmationDialog("Move “\(pendingTrash?.name ?? "")” to the Trash?",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                            presenting: pendingTrash) { node in
            Button("Move to Trash", role: .destructive) { atlas.moveToTrash(node) }
        } message: { node in
            Text("\(ByteFormat.string(node.size)). You can put it back from the Trash until you empty it; the space is freed when you do.")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(Array(atlas.breadcrumbs.enumerated()), id: \.element.path) { index, node in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(index == 0 ? rootTitle(node) : node.name) { atlas.zoom(to: node) }
                    .buttonStyle(.plain)
                    .fontWeight(index == atlas.breadcrumbs.count - 1 ? .semibold : .regular)
                    .foregroundStyle(index == atlas.breadcrumbs.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            if atlas.isScanning {
                ProgressView().controlSize(.small)
                Text("Mapping… \(ByteFormat.string(atlas.progress?.bytes ?? 0))").monospacedDigit().foregroundStyle(.secondary)
                Button("Stop") { atlas.cancelScan() }
            } else {
                Text("\(ByteFormat.string(model.disk.freeBytes)) free of \(ByteFormat.string(model.disk.totalBytes))")
                    .monospacedDigit().foregroundStyle(.secondary)
                if let map = atlas.map {
                    Text("· \(map.fileCount.formatted()) files in \(map.duration, format: .number.precision(.fractionLength(1))) s")
                        .foregroundStyle(.tertiary)
                        .help(map.unreadableFolders > 0 ? "\(map.unreadableFolders) folders couldn't be read (Full Disk Access)." : "")
                }
                Menu {
                    Button("Home Folder") { atlas.startScan(root: atlas.home) }
                    Button("Choose Folder or Drive…") { chooseFolder() }
                    Divider()
                    Button("Map Again") { atlas.startScan() }
                } label: {
                    Label("Map", systemImage: "scope")
                }
                .fixedSize()
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    private func rootTitle(_ node: MapNode) -> String {
        URL(filePath: node.path).standardizedFileURL.path == atlas.home.standardizedFileURL.path ? "Home" : node.name
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Map"
        panel.message = "Choose a folder or a drive to map. Nothing is changed."
        if panel.runModal() == .OK, let url = panel.url { atlas.startScan(root: url) }
    }

    @ViewBuilder
    private func sidePanel(focus: MapNode, map: SpaceMap) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            KindBreakdown(node: focus)
                .padding(16)
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            switch tab {
            case .contents: contents(focus)
            case .origins: origins(map)
            }
        }
    }

    private func contents(_ focus: MapNode) -> some View {
        List {
            ForEach(focus.children) { node in
                HStack(spacing: 8) {
                    Image(systemName: node.isDirectory ? "folder.fill" : node.kind.symbol)
                        .foregroundStyle(node.kind.color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                        Text(subtitle(node)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(ByteFormat.string(node.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .listRowBackground(hoverPath == node.path ? Color.accentColor.opacity(0.14) : Color.clear)
                .onHover { hoverPath = $0 ? node.path : (hoverPath == node.path ? nil : hoverPath) }
                .onTapGesture(count: 2) { atlas.zoom(to: node) }
                .contextMenu {
                    if node.isDirectory { Button("Zoom In") { atlas.zoom(to: node) } }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: node.path)]) }
                    Divider()
                    if let why = atlas.trashRefusal(node) {
                        Text(why)
                    } else {
                        Button("Move to Trash…", role: .destructive) { pendingTrash = node }
                    }
                }
            }
            if focus.smallBytes > 0 {
                HStack {
                    Image(systemName: "ellipsis").foregroundStyle(.tertiary).frame(width: 18)
                    Text("\(focus.smallCount.formatted()) smaller items").foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteFormat.string(focus.smallBytes)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func subtitle(_ node: MapNode) -> String {
        var parts: [String] = [node.origin?.name ?? node.kind.title]
        if let used = node.lastUsed {
            parts.append("touched " + used.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func origins(_ map: SpaceMap) -> some View {
        List {
            ForEach(map.origins.prefix(40)) { total in
                DisclosureGroup {
                    ForEach(total.largest, id: \.path) { file in
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file.path)])
                        } label: {
                            HStack {
                                Text(URL(filePath: file.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(ByteFormat.string(file.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: total.origin.symbol).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(total.origin.name).lineLimit(1)
                            Text("\(total.fileCount.formatted()) file\(total.fileCount == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteFormat.string(total.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if map.origins.isEmpty {
                Text("Nothing here carries a recognisable source.").foregroundStyle(.secondary)
            }
        }
    }
}

/// One stacked bar and a legend: how a folder splits into photos, video, code and the rest.
struct KindBreakdown: View {
    let node: MapNode

    var body: some View {
        let parts = FileKind.allCases
            .map { ($0, node.bytes(of: $0)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        let total = Double(max(node.size, 1))
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(parts, id: \.0) { kind, bytes in
                        Rectangle().fill(kind.color)
                            .frame(width: max(2, (geo.size.width - CGFloat(parts.count) * 1.5) * Double(bytes) / total))
                            .help("\(kind.title): \(ByteFormat.string(bytes))")
                    }
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(parts.prefix(6), id: \.0) { kind, bytes in
                    GridRow {
                        Circle().fill(kind.color).frame(width: 8, height: 8)
                        Text(kind.title)
                        Text(ByteFormat.string(bytes)).monospacedDigit().foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text((Double(bytes) / total).formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit().foregroundStyle(.tertiary).gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.callout)
        }
    }
}

private struct ScanningPlaceholder: View {
    let progress: SpaceMapScanner.Progress?
    let home: URL

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Mapping… \(ByteFormat.string(progress?.bytes ?? 0)) in \((progress?.files ?? 0).formatted()) files")
                .monospacedDigit()
            Text((progress?.current ?? "").replacingOccurrences(of: home.path(percentEncoded: false), with: "~/"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
