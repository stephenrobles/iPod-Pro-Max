//
//  ArtworkDB.swift
//  iPod Pro Max
//
//  Writes album art for the iPod: raw RGB565 thumbnails into iPod_Control/Artwork/F<format>_<n>.ithmb
//  files plus the ArtworkDB index that links them to tracks (by dbid). Layout follows libgpod / iTunes.
//

import Foundation
import CoreGraphics
import ImageIO

/// One rendered thumbnail stored inside an .ithmb file.
struct ThumbnailRef: Hashable {
    let format: ArtworkFormat
    /// iPod-style path, e.g. ":F1028_1.ithmb"
    let filename: String
    let offset: UInt32
    let size: UInt32
    let verticalPadding: Int16
    let horizontalPadding: Int16
    /// Width/height including the leading padding (as iTunes records them).
    let width: UInt16
    let height: UInt16
}

/// An ArtworkDB image entry (mhii) for one track.
struct ArtworkEntry {
    let imageID: UInt32
    let trackDBID: UInt64
    let originalImageSize: UInt32
    let thumbnails: [ThumbnailRef]
}

/// Renders artwork into .ithmb files. Identical images (same key) are stored once and shared.
final class IThumbWriter {
    static let maxFileSize = 256 * 1024 * 1024

    private struct FormatState {
        var fileIndex = 1
        var handle: FileHandle?
        var offset: UInt32 = 0
    }

    let artworkDir: URL
    let formats: [ArtworkFormat]
    private var states: [Int: FormatState] = [:]
    private var cache: [String: [ThumbnailRef]] = [:]
    private(set) var uniqueImageCount = 0

    init(artworkDir: URL, formats: [ArtworkFormat]) {
        self.artworkDir = artworkDir
        self.formats = formats
        for f in formats { states[f.id] = FormatState() }
    }

    /// Removes any existing thumbnail files so the ArtworkDB and ithmb files stay consistent.
    func removeExistingFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        if let items = try? fm.contentsOfDirectory(at: artworkDir, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension.lowercased() == "ithmb" && url.lastPathComponent.hasPrefix("F") {
                try? fm.removeItem(at: url)
            }
        }
        let dbURL = artworkDir.appendingPathComponent("ArtworkDB")
        if fm.fileExists(atPath: dbURL.path) { try? fm.removeItem(at: dbURL) }
    }

    /// Returns thumbnail references for the given image, rendering and appending it when not seen before.
    func thumbnails(forKey key: String, image: CGImage) throws -> [ThumbnailRef] {
        if let cached = cache[key] { return cached }
        var refs: [ThumbnailRef] = []
        for f in formats {
            let rendered = Self.render(image: image, format: f)
            let ref = try append(pixels: rendered.pixels, format: f, scaledWidth: rendered.width, scaledHeight: rendered.height)
            refs.append(ref)
        }
        cache[key] = refs
        uniqueImageCount += 1
        return refs
    }

    func finish() {
        for (id, var s) in states {
            try? s.handle?.close()
            s.handle = nil
            states[id] = s
        }
    }

    private func append(pixels: [UInt8], format: ArtworkFormat, scaledWidth: Int, scaledHeight: Int) throws -> ThumbnailRef {
        guard var s = states[format.id] else { throw IPodDBError.io("unknown artwork format \(format.id)") }
        if s.handle == nil || Int(s.offset) + pixels.count > Self.maxFileSize {
            if s.handle != nil {
                try? s.handle?.close()
                s.fileIndex += 1
            }
            let url = artworkDir.appendingPathComponent("F\(format.id)_\(s.fileIndex).ithmb")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            s.handle = try FileHandle(forWritingTo: url)
            let end = try s.handle?.seekToEnd() ?? 0
            s.offset = UInt32(end)
        }
        try s.handle?.write(contentsOf: pixels)
        let hpad = Int16((format.width - scaledWidth) / 2)
        let vpad = Int16((format.height - scaledHeight) / 2)
        let ref = ThumbnailRef(format: format, filename: ":F\(format.id)_\(s.fileIndex).ithmb", offset: s.offset, size: UInt32(pixels.count),
                               verticalPadding: vpad, horizontalPadding: hpad,
                               width: UInt16(Int(hpad) + scaledWidth), height: UInt16(Int(vpad) + scaledHeight))
        s.offset += UInt32(pixels.count)
        states[format.id] = s
        return ref
    }

    /// Scales the image to fit the format (preserving aspect ratio, centered on black) and packs it as RGB565 little-endian.
    static func render(image: CGImage, format: ArtworkFormat) -> (pixels: [UInt8], width: Int, height: Int) {
        let W = format.width, H = format.height
        let iw = max(image.width, 1), ih = max(image.height, 1)
        let ws = Double(W) / Double(iw)
        let hs = Double(H) / Double(ih)
        var sw = W, sh = H
        if ws < hs {
            sw = W
            sh = min(Int(ceil(Double(ih) * ws)), H)
        } else if ws > hs {
            sw = min(Int(ceil(Double(iw) * hs)), W)
            sh = H
        }
        sw = max(sw, 1); sh = max(sh, 1)
        let hpad = (W - sw) / 2
        let vpad = (H - sh) / 2

        let bytesPerRow = W * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * H)
        rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.interpolationQuality = .high
            // A bitmap context's buffer stores the top row first, and CGContext.draw keeps the image upright,
            // so no flip is needed: row 0 of `rgba` is the top of the thumbnail.
            ctx.draw(image, in: CGRect(x: hpad, y: vpad, width: sw, height: sh))
        }
        var out = [UInt8](repeating: 0, count: W * H * 2)
        var o = 0
        for y in 0..<H {
            var i = y * bytesPerRow
            for _ in 0..<W {
                let r = UInt16(rgba[i]) >> 3
                let g = UInt16(rgba[i + 1]) >> 2
                let b = UInt16(rgba[i + 2]) >> 3
                let p = (r << 11) | (g << 5) | b
                out[o] = UInt8(p & 0xFF)
                out[o + 1] = UInt8(p >> 8)
                o += 2
                i += 4
            }
        }
        return (out, sw, sh)
    }
}

enum ArtworkDBWriter {
    static let firstImageID: UInt32 = 0x64

    static func write(entries: [ArtworkEntry], formats: [ArtworkFormat], tzOffset: Int32) -> Data {
        var w = ByteWriter(capacity: 4096 + entries.count * 512)
        let maxID = entries.map(\.imageID).max() ?? 0

        // mhfd
        w.header("mhfd")
        w.u32(0x84)
        w.u32(0)
        w.u32(0) // unknown1
        w.u32(2) // unknown2 (must be 2, iTunes 7 drops the db otherwise)
        w.u32(3) // children
        w.u32(0) // unknown3
        w.u32(maxID) // next id
        w.u64(0)
        w.u64(0)
        w.u8(2) // unknown_flag1
        w.u8(0); w.u8(0); w.u8(0)
        w.u32(0); w.u32(0); w.u32(0); w.u32(0)
        w.padTo(length: 0x84, from: 0)

        // mhsd 1: image list
        var mhsd = writeMHSD(&w, type: 1)
        let mhli = w.count
        w.header("mhli")
        w.u32(0x5C)
        w.u32(UInt32(entries.count))
        w.padTo(length: 0x5C, from: mhli)
        for e in entries {
            writeMHII(&w, entry: e, tzOffset: tzOffset)
        }
        w.fixTotalLength(headerStart: mhsd)

        // mhsd 2: album list (empty for the music ArtworkDB)
        mhsd = writeMHSD(&w, type: 2)
        let mhla = w.count
        w.header("mhla")
        w.u32(0x5C)
        w.u32(0)
        w.padTo(length: 0x5C, from: mhla)
        w.fixTotalLength(headerStart: mhsd)

        // mhsd 3: file list
        mhsd = writeMHSD(&w, type: 3)
        let mhlf = w.count
        w.header("mhlf")
        w.u32(0x5C)
        w.u32(UInt32(formats.count))
        w.padTo(length: 0x5C, from: mhlf)
        for f in formats {
            let s = w.count
            w.header("mhif")
            w.u32(0x7C)
            w.u32(0x7C)
            w.u32(0)
            w.u32(UInt32(f.id))
            w.u32(UInt32(f.bytesPerImage))
            w.padTo(length: 0x7C, from: s)
        }
        w.fixTotalLength(headerStart: mhsd)

        w.fixTotalLength(headerStart: 0)
        return w.data
    }

    private static func writeMHSD(_ w: inout ByteWriter, type: UInt16) -> Int {
        let s = w.count
        w.header("mhsd")
        w.u32(0x60)
        w.u32(0)
        w.u16(type)
        w.u16(0)
        w.padTo(length: 0x60, from: s)
        return s
    }

    private static func writeMHII(_ w: inout ByteWriter, entry e: ArtworkEntry, tzOffset: Int32) {
        let s = w.count
        w.header("mhii")
        w.u32(0x98)
        w.u32(0)
        w.u32(UInt32(e.thumbnails.count))
        w.u32(e.imageID)
        w.u64(e.trackDBID)
        w.u32(0) // unknown4
        w.u32(0) // rating
        w.u32(0) // unknown6
        w.u32(0) // orig date
        w.u32(0) // digitized date
        w.u32(e.originalImageSize)
        w.padTo(length: 0x98, from: s)
        for t in e.thumbnails {
            // mhod type 2 container
            let m = w.count
            w.header("mhod")
            w.u32(24)
            w.u32(0)
            w.u16(2)
            w.u16(0)
            w.u32(0)
            w.u32(0)
            // mhni
            let n = w.count
            w.header("mhni")
            w.u32(0x4C)
            w.u32(0)
            w.u32(1)
            w.u32(UInt32(t.format.id))
            w.u32(t.offset)
            w.u32(t.size)
            w.u16(UInt16(bitPattern: t.verticalPadding))
            w.u16(UInt16(bitPattern: t.horizontalPadding))
            w.u16(t.height)
            w.u16(t.width)
            w.padTo(length: 0x4C, from: n)
            // mhod type 3: filename (UTF-16LE)
            let f = w.count
            let units = Array(t.filename.utf16)
            let strBytes = units.count * 2
            var padding = 4 - ((36 + strBytes) % 4)
            if padding == 4 { padding = 0 }
            w.header("mhod")
            w.u32(24)
            w.u32(UInt32(36 + strBytes + padding))
            w.u16(3)
            w.u8(0)
            w.u8(UInt8(padding))
            w.u32(0)
            w.u32(0)
            w.u32(UInt32(strBytes))
            w.u8(2) // UTF-16LE
            w.u8(0)
            w.u16(0)
            w.u32(0)
            for u in units { w.u16(u) }
            w.zeros(padding)
            assert(w.count - f == 36 + strBytes + padding)
            w.fixTotalLength(headerStart: n)
            w.fixTotalLength(headerStart: m)
        }
        w.fixTotalLength(headerStart: s)
    }
}

enum ImageLoading {
    /// Decodes image data (JPEG/PNG/…) into a CGImage.
    static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func cgImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Re-encodes an image as JPEG, downscaling so the longest side is at most `maxDimension`.
    static func jpegData(from image: CGImage, maxDimension: Int = 600, quality: Double = 0.85) -> Data? {
        var img = image
        let longest = max(image.width, image.height)
        if longest > maxDimension {
            let scale = Double(maxDimension) / Double(longest)
            let w = max(Int(Double(image.width) * scale), 1)
            let h = max(Int(Double(image.height) * scale), 1)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { img = scaled }
            }
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
