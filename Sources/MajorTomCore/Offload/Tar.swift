import Foundation

/// Just enough POSIX pax/ustar to archive a folder into one file and read it back.
///
/// Folders (projects, .xcarchive bundles, packages) go to the NAS as one uncompressed pax tar instead of thousands of
/// small files: SMB pays a round trip per file and per attribute, can't store symlinks portably, mangles names with
/// `:` `\` `*` `?` `"` `<` `>` `|` or trailing dots/spaces, is case-insensitive, and keeps extended attributes only as
/// named streams. Inside a tar none of that matters. The format is standard: `tar -xpf` on any Mac (or the NAS) can
/// unpack it. Long or non-ASCII names, long link targets, sizes ≥ 8 GiB and extended attributes
/// (`SCHILY.xattr.<name>`, as GNU tar and bsdtar write them) use pax records.
enum Tar {
    static let block = 512

    enum EntryType: UInt8 {
        case file = 0x30       // '0'
        case symlink = 0x32    // '2'
        case directory = 0x35  // '5'
        case pax = 0x78        // 'x'
        case globalPax = 0x67  // 'g'
        case gnuLongName = 0x4C  // 'L'
        case gnuLongLink = 0x4B  // 'K'
    }

    struct Entry {
        var name: String
        var type: UInt8
        var size: Int64
        var mode: UInt32
        var mtime: Double
        var linkName: String
        var xattrs: [(name: String, value: Data)]
    }

    // MARK: Writing

    static func headers(name: String, type: EntryType, size: Int64, mode: UInt16, mtime: Date, linkName: String = "",
                        xattrs: [(name: String, value: Data)] = []) -> [UInt8] {
        var pax: [(String, [UInt8])] = []
        let seconds = Int64(mtime.timeIntervalSince1970.rounded(.down))
        let nameBytes = Array(name.utf8)
        if nameBytes.count > 99 || !name.allSatisfy(\.isASCII) { pax.append(("path", nameBytes)) }
        let linkBytes = Array(linkName.utf8)
        if linkBytes.count > 99 || !linkName.allSatisfy(\.isASCII) { pax.append(("linkpath", linkBytes)) }
        let maxOctal11: Int64 = 0o77777777777
        if size > maxOctal11 { pax.append(("size", Array(String(size).utf8))) }
        if seconds < 0 || seconds > maxOctal11 {
            pax.append(("mtime", Array(String(format: "%.9f", mtime.timeIntervalSince1970).utf8)))
        }
        for (key, value) in xattrs where !key.contains("=") {
            pax.append(("SCHILY.xattr." + key, [UInt8](value)))
        }

        var out: [UInt8] = []
        if !pax.isEmpty {
            var data: [UInt8] = []
            for (key, value) in pax { data += record(key: key, value: value) }
            out += ustar(name: "PaxHeaders/" + asciiName(name, max: 80), type: EntryType.pax.rawValue, size: Int64(data.count),
                         mode: 0o644, mtime: max(0, min(seconds, maxOctal11)), linkName: "")
            out += data
            out += [UInt8](repeating: 0, count: padding(Int64(data.count)))
        }
        out += ustar(name: asciiName(name, max: 99), type: type.rawValue, size: size > maxOctal11 ? 0 : size, mode: UInt32(mode),
                     mtime: max(0, min(seconds, maxOctal11)), linkName: asciiName(linkName, max: 99))
        return out
    }

    static func end() -> [UInt8] { [UInt8](repeating: 0, count: block * 2) }

    static func padding(_ size: Int64) -> Int {
        let r = Int(size % Int64(block))
        return r == 0 ? 0 : block - r
    }

    /// `"<len> key=value\n"`, where len counts the whole record including its own digits.
    static func record(key: String, value: [UInt8]) -> [UInt8] {
        let body = Array(" \(key)=".utf8) + value + [0x0A]
        var len = body.count + 1
        while String(len).utf8.count + body.count != len { len = String(len).utf8.count + body.count }
        return Array(String(len).utf8) + body
    }

    /// The ustar fallback name (pax `path` carries the real one).
    private static func asciiName(_ s: String, max: Int) -> String {
        var out = String(s.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 ? Character($0) : "_" })
        if out.utf8.count > max { out = String(out.utf8.suffix(max)) ?? String(out.suffix(max)) }
        return out
    }

    private static func ustar(name: String, type: UInt8, size: Int64, mode: UInt32, mtime: Int64, linkName: String) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: block)
        func put(_ s: String, _ offset: Int, _ len: Int) {
            for (i, b) in s.utf8.prefix(len).enumerated() { h[offset + i] = b }
        }
        func octal(_ v: Int64, _ offset: Int, _ len: Int) {
            let s = String(v, radix: 8)
            put(String(repeating: "0", count: max(0, len - 1 - s.count)) + s, offset, len - 1)
        }
        put(name, 0, 100)
        octal(Int64(mode & 0o7777), 100, 8)
        octal(Int64(getuid()), 108, 8)
        octal(Int64(getgid()), 116, 8)
        octal(size, 124, 12)
        octal(mtime, 136, 12)
        h[156] = type
        put(linkName, 157, 100)
        put("ustar", 257, 6)  // "ustar\0"
        put("00", 263, 2)
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        let s = String(sum, radix: 8)
        put(String(repeating: "0", count: max(0, 6 - s.count)) + s, 148, 6)
        h[154] = 0
        h[155] = 0x20
        return h
    }

    // MARK: Reading

    /// Reads the next entry header (handling pax / GNU long-name records). Nil at the end of the archive.
    /// The caller must then consume exactly `size` bytes plus padding.
    static func next(_ src: PayloadSource) throws -> Entry? {
        var pending: [String: [UInt8]] = [:]
        var xattrs: [(String, Data)] = []
        var longName: String?
        var longLink: String?
        while true {
            if try src.atEnd() { throw OffloadError.verification("archive ends without an end marker (truncated)") }
            let h = try src.readBytes(block)
            if h.allSatisfy({ $0 == 0 }) {
                // End marker: a second zero block should follow (tolerate its absence at EOF).
                if try !src.atEnd() { _ = try src.readBytes(block) }
                return nil
            }
            guard checksumOK(h) else { throw OffloadError.verification("damaged tar header at byte \(src.offset - Int64(block))") }
            let type = h[156]
            let size = try parseNumber(h, 124, 12)
            switch type {
            case EntryType.pax.rawValue, EntryType.globalPax.rawValue:
                let data = try src.readBytes(Int(size))
                try src.skip(Int64(padding(size)))
                guard type == EntryType.pax.rawValue else { continue }
                for (k, v) in try parseRecords(data) {
                    if k.hasPrefix("SCHILY.xattr.") {
                        xattrs.append((String(k.dropFirst("SCHILY.xattr.".count)), Data(v)))
                    } else {
                        pending[k] = v
                    }
                }
            case EntryType.gnuLongName.rawValue, EntryType.gnuLongLink.rawValue:
                var data = try src.readBytes(Int(size))
                try src.skip(Int64(padding(size)))
                while data.last == 0 { data.removeLast() }
                let s = String(decoding: data, as: UTF8.self)
                if type == EntryType.gnuLongName.rawValue { longName = s } else { longLink = s }
            default:
                var name = cString(h, 0, 100)
                let prefix = cString(h, 345, 155)
                if cString(h, 257, 5) == "ustar", !prefix.isEmpty { name = prefix + "/" + name }
                if let n = longName { name = n }
                if let p = pending["path"] { name = String(decoding: p, as: UTF8.self) }
                var link = cString(h, 157, 100)
                if let l = longLink { link = l }
                if let l = pending["linkpath"] { link = String(decoding: l, as: UTF8.self) }
                var entrySize = size
                if let s = pending["size"], let v = Int64(String(decoding: s, as: UTF8.self)) { entrySize = v }
                var mtime = Double(try parseNumber(h, 136, 12))
                if let m = pending["mtime"], let v = Double(String(decoding: m, as: UTF8.self)) { mtime = v }
                let mode = UInt32(try parseNumber(h, 100, 8))
                var t = type
                if t == 0 { t = EntryType.file.rawValue }  // old-style regular file
                return Entry(name: name, type: t, size: entrySize, mode: mode, mtime: mtime, linkName: link,
                             xattrs: xattrs.sorted { $0.0 < $1.0 })
            }
        }
    }

    static func checksumOK(_ h: [UInt8]) -> Bool {
        guard let stored = try? parseNumber(h, 148, 8) else { return false }
        var sum = 0
        for (i, b) in h.enumerated() { sum += (148..<156).contains(i) ? 0x20 : Int(b) }
        return Int64(sum) == stored
    }

    static func parseNumber(_ h: [UInt8], _ offset: Int, _ len: Int) throws -> Int64 {
        let field = h[offset..<(offset + len)]
        if let first = field.first, first & 0x80 != 0 {  // GNU base-256
            var v: Int64 = Int64(first & 0x7F)
            for b in field.dropFirst() { v = (v << 8) | Int64(b) }
            return v
        }
        let s = String(decoding: field.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return 0 }
        guard let v = Int64(s, radix: 8) else { throw OffloadError.verification("bad number in tar header") }
        return v
    }

    static func parseRecords(_ data: [UInt8]) throws -> [(String, [UInt8])] {
        var out: [(String, [UInt8])] = []
        var i = 0
        while i < data.count {
            guard let space = data[i...].firstIndex(of: 0x20),
                  let len = Int(String(decoding: data[i..<space], as: UTF8.self)), len > 0, i + len <= data.count,
                  let eq = data[(space + 1)..<(i + len)].firstIndex(of: 0x3D) else {
                throw OffloadError.verification("damaged pax header")
            }
            let key = String(decoding: data[(space + 1)..<eq], as: UTF8.self)
            let value = Array(data[(eq + 1)..<(i + len - 1)])
            out.append((key, value))
            i += len
        }
        return out
    }

    private static func cString(_ h: [UInt8], _ offset: Int, _ len: Int) -> String {
        String(decoding: h[offset..<(offset + len)].prefix { $0 != 0 }, as: UTF8.self)
    }
}
