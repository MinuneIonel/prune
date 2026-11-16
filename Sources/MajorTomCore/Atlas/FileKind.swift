import Darwin
import Foundation

/// What a file is, in an artist's terms. The space map colours by this.
public enum FileKind: Int, CaseIterable, Codable, Sendable, Hashable {
    case photo, video, audio, project, code, cache, archive, app, document, other

    public var title: String {
        switch self {
        case .photo: "Photos"
        case .video: "Video"
        case .audio: "Audio"
        case .project: "Project files"
        case .code: "Code"
        case .cache: "Caches & renders"
        case .archive: "Archives & installers"
        case .app: "Apps"
        case .document: "Documents"
        case .other: "Other"
        }
    }
}

/// Where something came from: the app that made it, the camera that shot it, the site it was downloaded from.
public struct Origin: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// SF Symbol name.
    public var symbol: String

    public init(_ id: String, _ name: String, _ symbol: String = "app.dashed") {
        self.id = id
        self.name = name
        self.symbol = symbol
    }

    public static let resolve = Origin("resolve", "DaVinci Resolve", "film.stack")
    public static let captureOne = Origin("capture-one", "Capture One", "camera.aperture")
    public static let applePhotos = Origin("apple-photos", "Apple Photos", "photo.on.rectangle.angled")
    public static let lightroom = Origin("lightroom", "Lightroom", "camera.filters")
    public static let adobe = Origin("adobe", "Adobe", "paintbrush.pointed")
    public static let finalCut = Origin("final-cut", "Final Cut Pro", "film")
    public static let obs = Origin("obs", "OBS recordings", "record.circle")
    public static let screenCapture = Origin("screen-capture", "macOS screen capture", "camera.viewfinder")
    public static let whatsApp = Origin("whatsapp", "WhatsApp", "message")
    public static let camera = Origin("camera", "Camera", "camera")
    public static let phone = Origin("phone", "Phone or camera roll", "iphone")
    public static let goPro = Origin("gopro", "GoPro", "video")
    public static let drone = Origin("dji", "DJI drone", "airplane")
    public static let topaz = Origin("topaz", "Topaz", "wand.and.stars")
    public static let affinity = Origin("affinity", "Affinity", "paintpalette")
    public static let reaper = Origin("reaper", "REAPER", "waveform")
    public static let blender = Origin("blender", "Blender", "cube.transparent")
    public static let resolume = Origin("resolume", "Resolume", "rectangle.3.group")
    public static let touchDesigner = Origin("touchdesigner", "TouchDesigner", "point.3.connected.trianglepath.dotted")
    public static let ableton = Origin("ableton", "Ableton Live", "waveform.path")
    public static let garageBand = Origin("garageband", "GarageBand", "guitars")
    public static let steam = Origin("steam", "Steam", "gamecontroller")
    public static let xcode = Origin("xcode", "Xcode", "hammer")
    public static let npm = Origin("npm", "JavaScript packages", "shippingbox")
    public static let git = Origin("git", "Git history", "arrow.triangle.branch")
    public static let iCloud = Origin("icloud", "iCloud Drive", "icloud")
    public static let appleTV = Origin("apple-tv", "Apple TV", "tv")
    public static let appleMusic = Origin("apple-music", "Apple Music", "music.note")
    public static let trash = Origin("trash", "Trash", "trash")
    public static let airDrop = Origin("airdrop", "AirDrop", "dot.radiowaves.left.and.right")

    static func camera(brand: String) -> Origin { Origin("camera-" + brand.lowercased(), brand + " camera", "camera") }
    static func app(_ name: String) -> Origin { Origin("app-" + name.lowercased(), name, "app") }
    static func web(_ host: String) -> Origin { Origin("web-" + host, host, "arrow.down.circle") }
}

/// Sorts files into kinds and works out where they came from, from names and locations alone
/// (plus, for bigger files, the download metadata macOS keeps). Never reads file contents.
public enum FileClassifier {
    private static let kinds: [String: FileKind] = {
        var m: [String: FileKind] = [:]
        func add(_ k: FileKind, _ exts: String) { for e in exts.split(separator: " ") { m[String(e)] = k } }
        add(.photo, "jpg jpeg png heic heif tif tiff gif bmp webp avif exr tga jp2 svg hdr "
            + rawBrands.keys.joined(separator: " "))
        add(.video, "mov mp4 m4v mkv avi mxf braw r3d webm flv wmv mpg mpeg mts m2ts 3gp dv prores")
        add(.audio, "wav aif aiff mp3 flac m4a aac ogg opus wma caf mid midi")
        add(.project, "drp dra drt prproj aep aet psd psb ai indd afphoto afdesign afpub af rpp blend avc toe tox "
            + "als band logicx c4d sketch fig procreate kra xcf cosessiondb cocatalogdb lrcat fcpxml cube edl")
        add(.code, "swift py js jsx ts tsx json html css scss c h cpp hpp m mm rs go java kt rb php sh zsh yml "
            + "yaml toml glsl frag vert metal hlsl isf sql ipynb lock o a dylib so wasm map")
        add(.archive, "zip dmg pkg xip tar gz tgz bz2 xz 7z rar iso")
        add(.document, "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf md epub csv")
        return m
    }()

    static let rawBrands: [String: String] = [
        "cr2": "Canon", "cr3": "Canon", "crw": "Canon", "nef": "Nikon", "nrw": "Nikon", "arw": "Sony", "srf": "Sony",
        "sr2": "Sony", "raf": "Fujifilm", "orf": "Olympus", "rw2": "Panasonic", "pef": "Pentax", "dng": "DNG",
        "3fr": "Hasselblad", "fff": "Hasselblad", "iiq": "Phase One", "x3f": "Sigma", "erf": "Epson", "mrw": "Minolta",
    ]

    private static let projectOrigins: [String: Origin] = [
        "drp": .resolve, "dra": .resolve, "drt": .resolve, "prproj": .adobe, "aep": .adobe, "aet": .adobe,
        "psd": .adobe, "psb": .adobe, "ai": .adobe, "indd": .adobe, "afphoto": .affinity, "afdesign": .affinity,
        "afpub": .affinity, "af": .affinity, "rpp": .reaper, "blend": .blender, "avc": .resolume,
        "toe": .touchDesigner, "tox": .touchDesigner, "als": .ableton, "band": .garageBand,
        "cosessiondb": .captureOne, "cocatalogdb": .captureOne, "lrcat": .lightroom, "fcpxml": .finalCut,
        "braw": Origin.camera(brand: "Blackmagic"), "r3d": Origin.camera(brand: "RED"),
    ]

    public static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    public static func kind(ofFile name: String) -> FileKind {
        kinds[fileExtension(name)] ?? .other
    }

    /// What a folder's name or place says about everything inside it. `homeRelative` is the folder's path
    /// below the home folder (`Library/Caches/com.x`), nil when it lives elsewhere.
    public static func directory(name: String, homeRelative: String?) -> (kind: FileKind?, origin: Origin?) {
        let lower = name.lowercased()
        switch lower {
        case "node_modules": return (.cache, .npm)
        case ".git": return (.code, .git)
        case "deriveddata": return (.cache, .xcode)
        case "cacheclip", "proxymedia", "optimizedmedia": return (.cache, .resolve)
        case "resolve project backups": return (.project, .resolve)
        case "media cache", "media cache files", "peak files", "adobe premiere pro audio previews",
             "adobe premiere pro video previews", "adobe premiere pro auto-save", "adobe after effects auto-save":
            return (.cache, .adobe)
        case "render files", "transcoded media": return (.cache, .finalCut)
        case ".trash": return (nil, .trash)
        default: break
        }
        switch fileExtension(name) {
        case "photoslibrary": return (.photo, .applePhotos)
        case "cocatalog", "cosession": return (nil, .captureOne)
        case "lrdata": return (.cache, .lightroom)
        case "lrlibrary": return (.photo, .lightroom)
        case "fcpbundle": return (nil, .finalCut)
        case "app": return (.app, nil)
        case "xcodeproj", "xcworkspace": return (.code, .xcode)
        default: break
        }
        guard let rel = homeRelative else { return (nil, nil) }
        let parts = rel.split(separator: "/").map(String.init)
        if parts.first == "Library" {
            if parts.count == 2 {
                switch parts[1] {
                case "Caches", "Logs": return (.cache, nil)
                case "Developer": return (nil, .xcode)
                case "Mobile Documents", "CloudStorage": return (nil, .iCloud)
                case "Messages": return (nil, .app("Messages"))
                case "Mail": return (nil, .app("Mail"))
                default: return (nil, nil)
                }
            }
            if parts.count == 3, ["Caches", "Application Support", "Containers", "Group Containers"].contains(parts[1]) {
                return (nil, appOrigin(folder: parts[2]))
            }
        }
        if rel == "Movies/TV" { return (.video, .appleTV) }
        if rel == "Music/Music" { return (.audio, .appleMusic) }
        if rel == "Pictures/Photo Booth Library" { return (.photo, .app("Photo Booth")) }
        return (nil, nil)
    }

    private static let knownApps: [(needle: String, origin: Origin)] = [
        ("blackmagic", .resolve), ("davinci", .resolve), ("captureone", .captureOne), ("phaseone", .captureOne),
        ("adobe", .adobe), ("obs", .obs), ("steam", .steam), ("valve", .steam), ("cockos", .reaper),
        ("reaper", .reaper), ("topaz", .topaz), ("resolume", .resolume), ("ableton", .ableton),
        ("blender", .blender), ("derivative", .touchDesigner), ("serif", .affinity), ("affinity", .affinity),
        ("garageband", .garageBand), ("whatsapp", .whatsApp), ("xcode", .xcode), ("coresimulator", .xcode),
    ]

    /// `com.blackmagic-design.DaVinciResolve` → DaVinci Resolve; unknown folders become an app named after them.
    static func appOrigin(folder: String) -> Origin? {
        let lower = folder.lowercased()
        for known in knownApps where lower.contains(known.needle) { return known.origin }
        // Team-prefixed group containers (`ABCDE12345.com.vendor.App`) and bundle IDs: keep the last component.
        var name = folder
        if folder.contains("."), folder.split(separator: ".").count >= 3 || lower.hasPrefix("com.") {
            name = String(folder.split(separator: ".").last ?? Substring(folder))
        }
        guard !name.isEmpty else { return nil }
        return .app(name)
    }

    /// Where a file came from, judged from its name alone.
    public static func origin(ofFile name: String) -> Origin? {
        let ext = fileExtension(name)
        if let brand = rawBrands[ext], brand != "DNG" { return .camera(brand: brand) }
        if let o = projectOrigins[ext] { return o }
        let kind = kinds[ext]
        guard kind == .photo || kind == .video || kind == .audio else { return nil }
        let stem = String(name.dropLast(ext.count + 1))
        if isOBSStamp(stem), kind == .video { return .obs }
        if stem.hasPrefix("Screen Recording ") || stem.hasPrefix("Screenshot ") || stem.hasPrefix("Screen Shot ") {
            return .screenCapture
        }
        if stem.hasPrefix("WhatsApp ") || stem.contains("-WA0") { return .whatsApp }
        let lower = stem.lowercased()
        if lower.contains("gigapixel") || lower.contains("-topaz") { return .topaz }
        if stem.hasPrefix("GOPR") || stem.hasPrefix("GH0") || stem.hasPrefix("GX0") { return .goPro }
        if stem.hasPrefix("DJI_") { return .drone }
        if stem.hasPrefix("DSC") || stem.hasPrefix("_DSC") || stem.hasPrefix("MVI_") || isCameraClip(stem) {
            return .camera
        }
        if stem.hasPrefix("IMG_") || stem.hasPrefix("PXL_") || stem.hasPrefix("VID_") { return .phone }
        return nil
    }

    /// `2026-11-15 19-33-50`: the name OBS gives a recording.
    static func isOBSStamp(_ stem: String) -> Bool {
        let c = Array(stem.utf8)
        guard c.count == 19 else { return false }
        for (i, ch) in c.enumerated() {
            switch i {
            case 4, 7, 13, 16: if ch != UInt8(ascii: "-") { return false }
            case 10: if ch != UInt8(ascii: " ") { return false }
            default: if ch < 48 || ch > 57 { return false }
            }
        }
        return true
    }

    /// `C0001`, `A001C003_…`: clip names straight off a cinema or mirrorless camera card.
    static func isCameraClip(_ stem: String) -> Bool {
        let c = Array(stem.utf8)
        func digits(_ r: Range<Int>) -> Bool { r.allSatisfy { $0 < c.count && c[$0] >= 48 && c[$0] <= 57 } }
        if c.count == 5, c[0] == UInt8(ascii: "C"), digits(1..<5) { return true }
        if c.count >= 8, c[0] >= 65, c[0] <= 90, digits(1..<4), c[4] == UInt8(ascii: "C"), digits(5..<8) { return true }
        return false
    }

    /// Where macOS says a file was downloaded from: the site, or the app that saved it (AirDrop, a browser…).
    /// Reads two small extended attributes; nil when neither is there.
    public static func downloadOrigin(path: String) -> Origin? {
        if let data = xattr(path, "com.apple.metadata:kMDItemWhereFroms"),
           let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            for entry in list.reversed() {
                if let host = URL(string: entry)?.host(), !host.isEmpty {
                    return .web(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                }
            }
        }
        if let data = xattr(path, "com.apple.quarantine"), let text = String(data: data, encoding: .utf8) {
            let fields = text.split(separator: ";", omittingEmptySubsequences: false)
            if fields.count >= 3 {
                let agent = String(fields[2])
                if agent == "sharingd" { return .airDrop }
                if !agent.isEmpty { return appOrigin(folder: agent) }
            }
        }
        return nil
    }

    private static func xattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 65536 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
        guard read > 0 else { return nil }
        return Data(buffer[0..<read])
    }
}
