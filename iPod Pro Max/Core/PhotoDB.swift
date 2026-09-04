//
//  PhotoDB.swift
//  iPod Pro Max
//
//  Writes the iPod's Photo Database (Photos/Photo Database) and its thumbnail files (Photos/Thumbs/F*.ithmb).
//  The structure is the ArtworkDB layout with albums; pixel formats follow libgpod.
//

import Foundation
import CoreGraphics

enum ThumbPixelFormat: String, Codable {
    case rgb565LE
    case rgb565BE
    /// Packed 4:2:2 YUV, big-endian byte order, even lines first then odd lines (used for TV-out).
    case uyvyBE
    /// Planar 4:2:0 YUV.
    case i420
}

struct PhotoFormat: Hashable {
    let id: Int
    let width: Int
    let height: Int
    let pixelFormat: ThumbPixelFormat

    var artworkFormat: ArtworkFormat { ArtworkFormat(id: id, width: width, height: height) }

    var bytesPerImage: Int {
        switch pixelFormat {
        case .rgb565LE, .rgb565BE, .uyvyBE: return width * height * 2
        case .i420: return width * height * 3 / 2
        }
    }
}

extension IPodGeneration {
    var photoFormats: [PhotoFormat] {
        switch self {
        case .photo:
            return [PhotoFormat(id: 1009, width: 42, height: 30, pixelFormat: .rgb565LE),
                    PhotoFormat(id: 1015, width: 130, height: 88, pixelFormat: .rgb565LE),
                    PhotoFormat(id: 1019, width: 720, height: 480, pixelFormat: .uyvyBE)]
        case .nano1, .nano2:
            return [PhotoFormat(id: 1032, width: 42, height: 37, pixelFormat: .rgb565LE),
                    PhotoFormat(id: 1023, width: 176, height: 132, pixelFormat: .rgb565BE)]
        case .video1, .video2:
            return [PhotoFormat(id: 1036, width: 50, height: 41, pixelFormat: .rgb565LE),
                    PhotoFormat(id: 1015, width: 130, height: 88, pixelFormat: .rgb565LE),
                    PhotoFormat(id: 1024, width: 320, height: 240, pixelFormat: .rgb565LE),
                    PhotoFormat(id: 1019, width: 720, height: 480, pixelFormat: .uyvyBE)]
        case .nano3, .classic1, .classic2, .classic3:
            return [PhotoFormat(id: 1067, width: 720, height: 480, pixelFormat: .i420),
                    PhotoFormat(id: 1024, width: 320, height: 240, pixelFormat: .rgb565LE),
                    PhotoFormat(id: 1066, width: 64, height: 64, pixelFormat: .rgb565LE)]
        case .nano4:
            return [PhotoFormat(id: 1024, width: 320, height: 240, pixelFormat: .rgb565LE),
                    PhotoFormat(id: 1066, width: 64, height: 64, pixelFormat: .rgb565LE),
                    PhotoFormat(id: 1079, width: 80, height: 80, pixelFormat: .rgb565LE),
                    PhotoFormat(id: 1083, width: 240, height: 320, pixelFormat: .rgb565LE)]
        default:
            return []
        }
    }

    var supportsPhotos: Bool { !photoFormats.isEmpty }
}

/// A photo to put on the iPod.
struct PhotoItem {
    /// Stable key (Photos asset identifier + modification date).
    let key: String
    let jpegURL: URL
    let creationDate: Date?
    let originalSize: UInt32
}

struct PhotoAlbumItem {
    let name: String
    let photoKeys: [String]
}

/// Renders photo thumbnails in every format the device wants and writes the Photo Database.
final class PhotoDBWriter {
    let photosDir: URL
    let thumbsDir: URL
    let formats: [PhotoFormat]

    private struct FileState {
        var index = 1
        var handle: FileHandle?
        var offset: UInt32 = 0
    }
    private var files: [Int: FileState] = [:]

    init(mountPoint: URL, formats: [PhotoFormat]) {
        photosDir = mountPoint.appendingPathComponent("Photos", isDirectory: true)
        thumbsDir = photosDir.appendingPathComponent("Thumbs", isDirectory: true)
        self.formats = formats
        for f in formats { files[f.id] = FileState() }
    }

    func removeExisting() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        if let items = try? fm.contentsOfDirectory(at: thumbsDir, includingPropertiesForKeys: nil) {
            for u in items where u.pathExtension.lowercased() == "ithmb" { try? fm.removeItem(at: u) }
        }
        let db = photosDir.appendingPathComponent("Photo Database")
        if fm.fileExists(atPath: db.path) { try? fm.removeItem(at: db) }
    }

    /// Writes thumbnails for all photos, then the database. Returns the number of photos written.
    func write(photos: [PhotoItem], albums: [PhotoAlbumItem], tzOffset: Int32, progress: (Int, Int) -> Void) throws -> Int {
        try removeExisting()
        var imageIDs: [String: UInt32] = [:]
        var entries: [ArtworkEntry] = []
        var nextID: UInt32 = 0x40
        for (i, p) in photos.enumerated() {
            progress(i, photos.count)
            guard imageIDs[p.key] == nil, let image = ImageLoading.cgImage(from: p.jpegURL) else { continue }
            var thumbs: [ThumbnailRef] = []
            for f in formats {
                let rendered = Self.render(image: image, format: f)
                // TV-out (YUV) frames are declared full-size with the black bars baked in; the iPod expects whole frames there.
                let fullFrame = f.pixelFormat == .uyvyBE || f.pixelFormat == .i420
                thumbs.append(try append(pixels: rendered.pixels, format: f,
                                         scaledWidth: fullFrame ? f.width : rendered.width,
                                         scaledHeight: fullFrame ? f.height : rendered.height))
            }
            let id = nextID
            nextID += 1
            imageIDs[p.key] = id
            entries.append(ArtworkEntry(imageID: id, trackDBID: UInt64(id) + 2, originalImageSize: p.originalSize, thumbnails: thumbs))
        }
        for (_, var s) in files { try? s.handle?.close(); s.handle = nil }
        progress(photos.count, photos.count)

        // Albums: the master "Photo Library" first, then the user's albums.
        var albumList: [(name: String, type: UInt8, ids: [UInt32])] = []
        albumList.append(("Photo Library", 1, entries.map(\.imageID)))
        for a in albums {
            let ids = a.photoKeys.compactMap { imageIDs[$0] }
            if !ids.isEmpty { albumList.append((a.name, 2, ids)) }
        }
        let data = Self.buildDatabase(entries: entries, albums: albumList, formats: formats, photoCount: entries.count, tzOffset: tzOffset)
        try data.write(to: photosDir.appendingPathComponent("Photo Database"), options: .atomic)
        return entries.count
    }

    private func append(pixels: [UInt8], format: PhotoFormat, scaledWidth: Int, scaledHeight: Int) throws -> ThumbnailRef {
        guard var s = files[format.id] else { throw IPodDBError.io("unknown photo format") }
        if s.handle == nil || Int(s.offset) + pixels.count > IThumbWriter.maxFileSize {
            if s.handle != nil { try? s.handle?.close(); s.index += 1 }
            let url = thumbsDir.appendingPathComponent("F\(format.id)_\(s.index).ithmb")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            s.handle = try FileHandle(forWritingTo: url)
            s.offset = UInt32(try s.handle?.seekToEnd() ?? 0)
        }
        try s.handle?.write(contentsOf: pixels)
        let hpad = Int16((format.width - scaledWidth) / 2)
        let vpad = Int16((format.height - scaledHeight) / 2)
        let ref = ThumbnailRef(format: format.artworkFormat, filename: ":Thumbs:F\(format.id)_\(s.index).ithmb", offset: s.offset, size: UInt32(pixels.count),
                               verticalPadding: vpad, horizontalPadding: hpad, width: UInt16(Int(hpad) + scaledWidth), height: UInt16(Int(vpad) + scaledHeight))
        s.offset += UInt32(pixels.count)
        files[format.id] = s
        return ref
    }

    // MARK: Rendering

    static func render(image: CGImage, format: PhotoFormat) -> (pixels: [UInt8], width: Int, height: Int) {
        let W = format.width, H = format.height
        let (rgba, sw, sh) = rasterize(image: image, width: W, height: H)
        switch format.pixelFormat {
        case .rgb565LE, .rgb565BE:
            let be = format.pixelFormat == .rgb565BE
            var out = [UInt8](repeating: 0, count: W * H * 2)
            var o = 0
            var i = 0
            for _ in 0..<(W * H) {
                let r = UInt16(rgba[i]) >> 3, g = UInt16(rgba[i + 1]) >> 2, b = UInt16(rgba[i + 2]) >> 3
                let p = (r << 11) | (g << 5) | b
                if be { out[o] = UInt8(p >> 8); out[o + 1] = UInt8(p & 0xFF) } else { out[o] = UInt8(p & 0xFF); out[o + 1] = UInt8(p >> 8) }
                o += 2; i += 4
            }
            return (out, sw, sh)
        case .uyvyBE:
            return (packUYVY(rgba: rgba, width: W, height: H), sw, sh)
        case .i420:
            return (packI420(rgba: rgba, width: W, height: H), sw, sh)
        }
    }

    /// Aspect-fit the image into W×H on black; returns RGBA bytes (4 per pixel) and the scaled size.
    private static func rasterize(image: CGImage, width W: Int, height H: Int) -> ([UInt8], Int, Int) {
        let iw = max(image.width, 1), ih = max(image.height, 1)
        let ws = Double(W) / Double(iw), hs = Double(H) / Double(ih)
        var sw = W, sh = H
        if ws < hs { sw = W; sh = min(Int(ceil(Double(ih) * ws)), H) }
        else if ws > hs { sw = min(Int(ceil(Double(iw) * hs)), W); sh = H }
        sw = max(sw, 1); sh = max(sh, 1)
        let hpad = (W - sw) / 2, vpad = (H - sh) / 2
        var rgba = [UInt8](repeating: 0, count: W * 4 * H)
        rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: hpad, y: vpad, width: sw, height: sh))
        }
        return (rgba, sw, sh)
    }

    @inline(__always) private static func yuv(_ r: Int, _ g: Int, _ b: Int) -> (UInt8, UInt8, UInt8) {
        let y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16
        let u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128
        let v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128
        return (UInt8(clamping: y), UInt8(clamping: u), UInt8(clamping: v))
    }

    /// UYVY, even rows in the first half of the buffer and odd rows in the second (interlaced TV output).
    static func packUYVY(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 2)
        let half = out.count / 2
        var z = 0, z2 = 0
        for h in 0..<height {
            var w = 0
            var x = h * width * 4
            while w < width {
                let (y0, u0, v0) = yuv(Int(rgba[x]), Int(rgba[x + 1]), Int(rgba[x + 2]))
                let (y1, _, _) = yuv(Int(rgba[x + 4]), Int(rgba[x + 5]), Int(rgba[x + 6]))
                if h % 2 == 0 {
                    out[z] = u0; out[z + 1] = y0; out[z + 2] = v0; out[z + 3] = y1
                    z += 4
                } else {
                    out[half + z2] = u0; out[half + z2 + 1] = y0; out[half + z2 + 2] = v0; out[half + z2 + 3] = y1
                    z2 += 4
                }
                w += 2
                x += 8
            }
        }
        return out
    }

    /// Planar YUV 4:2:0.
    static func packI420(rgba: [UInt8], width: Int, height: Int) -> [UInt8] {
        let n = width * height
        var out = [UInt8](repeating: 0, count: n * 3 / 2)
        let ustart = n, vstart = n + n / 4
        for h in 0..<height {
            for wI in 0..<width {
                let i = (h * width + wI) * 4
                let (y, u, v) = yuv(Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
                out[h * width + wI] = y
                let ci = (h / 2) * (width / 2) + wI / 2
                out[ustart + ci] = u
                out[vstart + ci] = v
            }
        }
        return out
    }

    // MARK: Database

    static func buildDatabase(entries: [ArtworkEntry], albums: [(name: String, type: UInt8, ids: [UInt32])], formats: [PhotoFormat], photoCount: Int, tzOffset: Int32) -> Data {
        var w = ByteWriter(capacity: 4096 + entries.count * 640)
        // Album ids follow libgpod: first album id = 0x64 + photo count.
        var albumID: UInt32 = 0x64 + UInt32(photoCount)
        var prevAlbumID: UInt32 = 0x64
        let maxAlbumID = albumID + UInt32(max(albums.count - 1, 0))

        w.header("mhfd")
        w.u32(0x84); w.u32(0); w.u32(0); w.u32(2); w.u32(3); w.u32(0)
        w.u32(maxAlbumID + 1) // next id
        w.u64(0); w.u64(0)
        w.u8(2); w.u8(0); w.u8(0); w.u8(0)
        w.u32(0); w.u32(0); w.u32(0); w.u32(0)
        w.padTo(length: 0x84, from: 0)

        // mhsd 1: images
        var mhsd = writeMHSD(&w, type: 1)
        let mhli = w.count
        w.header("mhli"); w.u32(0x5C); w.u32(UInt32(entries.count)); w.padTo(length: 0x5C, from: mhli)
        for e in entries { writeMHII(&w, entry: e, tzOffset: tzOffset) }
        w.fixTotalLength(headerStart: mhsd)

        // mhsd 2: albums
        mhsd = writeMHSD(&w, type: 2)
        let mhla = w.count
        w.header("mhla"); w.u32(0x5C); w.u32(UInt32(albums.count)); w.padTo(length: 0x5C, from: mhla)
        for (idx, a) in albums.enumerated() {
            let s = w.count
            w.header("mhba")
            w.u32(0x94); w.u32(0)
            w.u32(1)                       // mhods (name)
            w.u32(UInt32(a.ids.count))     // mhias
            w.u32(albumID)
            w.u32(0); w.u16(0)
            w.u8(a.type); w.u8(0); w.u8(0); w.u8(0); w.u8(0); w.u8(0)
            w.u32(3)  // slide duration
            w.u32(0)  // transition duration
            w.u32(0); w.u32(0)
            w.u64(0)  // song id
            w.u32(prevAlbumID)
            w.padTo(length: 0x94, from: s)
            writeUTF8NameMHOD(&w, name: a.name)
            for id in a.ids {
                let m = w.count
                w.header("mhia"); w.u32(40); w.u32(40); w.u32(0); w.u32(id); w.padTo(length: 40, from: m)
            }
            w.fixTotalLength(headerStart: s)
            albumID += 1
            prevAlbumID += 1
            if idx != 0 { prevAlbumID += UInt32(a.ids.count) }
        }
        w.fixTotalLength(headerStart: mhsd)

        // mhsd 3: file formats
        mhsd = writeMHSD(&w, type: 3)
        let mhlf = w.count
        w.header("mhlf"); w.u32(0x5C); w.u32(UInt32(formats.count)); w.padTo(length: 0x5C, from: mhlf)
        for f in formats {
            let s = w.count
            w.header("mhif"); w.u32(0x7C); w.u32(0x7C); w.u32(0); w.u32(UInt32(f.id)); w.u32(UInt32(f.bytesPerImage)); w.padTo(length: 0x7C, from: s)
        }
        w.fixTotalLength(headerStart: mhsd)
        w.fixTotalLength(headerStart: 0)
        return w.data
    }

    private static func writeMHSD(_ w: inout ByteWriter, type: UInt16) -> Int {
        let s = w.count
        w.header("mhsd"); w.u32(0x60); w.u32(0); w.u16(type); w.u16(0); w.padTo(length: 0x60, from: s)
        return s
    }

    private static func writeUTF8NameMHOD(_ w: inout ByteWriter, name: String) {
        let bytes = Array(name.utf8)
        var padding = 4 - ((36 + bytes.count) % 4)
        if padding == 4 { padding = 0 }
        w.header("mhod"); w.u32(24); w.u32(UInt32(36 + bytes.count + padding))
        w.u16(1); w.u8(0); w.u8(UInt8(padding))
        w.u32(0); w.u32(0)
        w.u32(UInt32(bytes.count))
        w.u8(1); w.u8(0); w.u16(0)
        w.u32(0)
        w.append(bytes)
        w.zeros(padding)
    }

    private static func writeMHII(_ w: inout ByteWriter, entry e: ArtworkEntry, tzOffset: Int32) {
        let s = w.count
        w.header("mhii"); w.u32(0x98); w.u32(0)
        w.u32(UInt32(e.thumbnails.count))
        w.u32(e.imageID)
        w.u64(e.trackDBID)
        w.u32(0); w.u32(0); w.u32(0)
        w.u32(0); w.u32(0)
        w.u32(e.originalImageSize)
        w.padTo(length: 0x98, from: s)
        for t in e.thumbnails {
            let m = w.count
            w.header("mhod"); w.u32(24); w.u32(0); w.u16(2); w.u16(0); w.u32(0); w.u32(0)
            let n = w.count
            w.header("mhni"); w.u32(0x4C); w.u32(0); w.u32(1)
            w.u32(UInt32(t.format.id)); w.u32(t.offset); w.u32(t.size)
            w.u16(UInt16(bitPattern: t.verticalPadding)); w.u16(UInt16(bitPattern: t.horizontalPadding))
            w.u16(t.height); w.u16(t.width)
            w.padTo(length: 0x4C, from: n)
            let units = Array(t.filename.utf16)
            let strBytes = units.count * 2
            var padding = 4 - ((36 + strBytes) % 4)
            if padding == 4 { padding = 0 }
            w.header("mhod"); w.u32(24); w.u32(UInt32(36 + strBytes + padding))
            w.u16(3); w.u8(0); w.u8(UInt8(padding)); w.u32(0); w.u32(0)
            w.u32(UInt32(strBytes)); w.u8(2); w.u8(0); w.u16(0); w.u32(0)
            for u in units { w.u16(u) }
            w.zeros(padding)
            w.fixTotalLength(headerStart: n)
            w.fixTotalLength(headerStart: m)
        }
        w.fixTotalLength(headerStart: s)
    }
}
