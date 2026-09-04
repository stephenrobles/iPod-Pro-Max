//
//  BinaryIO.swift
//  iPod Pro Max
//
//  Little-endian binary helpers used by the iTunesDB / ArtworkDB readers and writers.
//

import Foundation

/// Seconds between 1904-01-01 (HFS/Mac epoch) and 1970-01-01 (Unix epoch).
let macEpochOffset: Int64 = 2_082_844_800

enum MacTime {
    /// Converts a Date to the iPod's 32-bit "Mac time" (seconds since 1904, shifted by the device time zone offset).
    static func fromDate(_ date: Date?, tzOffset: Int32) -> UInt32 {
        guard let date else { return 0 }
        let unix = Int64(date.timeIntervalSince1970.rounded())
        let mac = unix + macEpochOffset + Int64(tzOffset)
        if mac <= 0 { return 0 }
        return UInt32(truncatingIfNeeded: mac)
    }

    static func toDate(_ mac: UInt32, tzOffset: Int32) -> Date? {
        if mac == 0 { return nil }
        let unix = Int64(mac) - macEpochOffset - Int64(tzOffset)
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }
}

struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    var count: Int { bytes.count }
    var data: Data { Data(bytes) }

    mutating func header(_ id: String) {
        precondition(id.utf8.count == 4, "header ids are 4 ASCII chars")
        bytes.append(contentsOf: Array(id.utf8))
    }

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8(v >> 8))
    }

    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 24) & 0xFF))
    }

    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

    mutating func u64(_ v: UInt64) {
        u32(UInt32(truncatingIfNeeded: v))
        u32(UInt32(truncatingIfNeeded: v >> 32))
    }

    mutating func f32(_ v: Float) { u32(v.bitPattern) }

    mutating func zeros(_ n: Int) {
        if n > 0 { bytes.append(contentsOf: [UInt8](repeating: 0, count: n)) }
    }

    /// Writes `n` 32-bit zero words (mirrors libgpod's put32_n0).
    mutating func zero32(_ n: Int) { zeros(n * 4) }

    mutating func append(_ d: [UInt8]) { bytes.append(contentsOf: d) }
    mutating func append(_ d: Data) { bytes.append(contentsOf: d) }

    mutating func patchU32(_ v: UInt32, at offset: Int) {
        precondition(offset + 4 <= bytes.count)
        bytes[offset] = UInt8(v & 0xFF)
        bytes[offset + 1] = UInt8((v >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((v >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((v >> 24) & 0xFF)
    }

    mutating func patchU16(_ v: UInt16, at offset: Int) {
        bytes[offset] = UInt8(v & 0xFF)
        bytes[offset + 1] = UInt8(v >> 8)
    }

    mutating func patchBytes(_ d: [UInt8], at offset: Int) {
        for (i, b) in d.enumerated() { bytes[offset + i] = b }
    }

    /// Writes the current length minus `headerStart` into the "total length" slot at headerStart + 8.
    mutating func fixTotalLength(headerStart: Int) {
        patchU32(UInt32(bytes.count - headerStart), at: headerStart + 8)
    }

    /// Pads the buffer with zeros up to `length` bytes past `start`.
    mutating func padTo(length: Int, from start: Int) {
        let target = start + length
        if bytes.count < target { zeros(target - bytes.count) }
    }
}

struct ByteReader {
    let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }
    init(bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }

    func u8(_ at: Int) -> UInt8 {
        guard at >= 0, at < bytes.count else { return 0 }
        return bytes[at]
    }

    func u16(_ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }

    func u32(_ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }

    func i32(_ at: Int) -> Int32 { Int32(bitPattern: u32(at)) }

    func u64(_ at: Int) -> UInt64 {
        UInt64(u32(at)) | (UInt64(u32(at + 4)) << 32)
    }

    func f32(_ at: Int) -> Float { Float(bitPattern: u32(at)) }

    func slice(_ at: Int, _ length: Int) -> [UInt8] {
        guard at >= 0, length >= 0, at + length <= bytes.count else { return [] }
        return Array(bytes[at..<(at + length)])
    }

    func hasHeader(_ id: String, at: Int) -> Bool {
        guard at >= 0, at + 4 <= bytes.count else { return false }
        let idBytes = Array(id.utf8)
        return bytes[at] == idBytes[0] && bytes[at + 1] == idBytes[1] && bytes[at + 2] == idBytes[2] && bytes[at + 3] == idBytes[3]
    }

    func headerID(at: Int) -> String? {
        guard at >= 0, at + 4 <= bytes.count else { return nil }
        let s = bytes[at..<(at + 4)]
        guard s.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return nil }
        return String(decoding: s, as: UTF8.self)
    }

    func utf16LEString(_ at: Int, byteLength: Int) -> String {
        let s = slice(at, byteLength & ~1)
        var units: [UInt16] = []
        units.reserveCapacity(s.count / 2)
        var i = 0
        while i + 1 < s.count {
            units.append(UInt16(s[i]) | (UInt16(s[i + 1]) << 8))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    func utf8String(_ at: Int, byteLength: Int) -> String {
        String(decoding: slice(at, byteLength), as: UTF8.self)
    }
}

enum IPodDBError: LocalizedError {
    case notAnITunesDB(String)
    case corrupt(String)
    case unsupported(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notAnITunesDB(let s): return "Not an iTunesDB file: \(s)"
        case .corrupt(let s): return "The iPod database is damaged: \(s)"
        case .unsupported(let s): return s
        case .io(let s): return s
        }
    }
}
