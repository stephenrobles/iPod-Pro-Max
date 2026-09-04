//
//  PlayCounts.swift
//  iPod Pro Max
//
//  Parser for iPod_Control/iTunes/Play Counts, the file the iPod writes with play statistics
//  since the last sync. Entries are in the same order as the tracks in the iTunesDB on the device.
//

import Foundation

struct PlayCountEntry {
    var playCount: UInt32 = 0
    var timePlayed: Date?
    var bookmarkTimeMs: UInt32 = 0
    /// nil when the file format did not include a rating
    var rating: UInt32?
    var skipCount: UInt32 = 0
    var lastSkipped: Date?
}

enum PlayCountsFile {
    static func parse(_ data: Data, tzOffset: Int32) throws -> [PlayCountEntry] {
        let r = ByteReader(data)
        guard r.hasHeader("mhdp", at: 0) else { throw IPodDBError.corrupt("Play Counts file is missing its mhdp header") }
        let headerLength = Int(r.u32(4))
        let entryLength = Int(r.u32(8))
        let entryCount = Int(r.u32(12))
        guard headerLength >= 0x60, entryLength >= 0x0C else { throw IPodDBError.corrupt("Play Counts header is too short") }
        var result: [PlayCountEntry] = []
        result.reserveCapacity(entryCount)
        for i in 0..<entryCount {
            let seek = headerLength + i * entryLength
            guard seek + entryLength <= r.count else { break }
            var e = PlayCountEntry()
            e.playCount = r.u32(seek)
            e.timePlayed = MacTime.toDate(r.u32(seek + 4), tzOffset: tzOffset)
            e.bookmarkTimeMs = r.u32(seek + 8)
            if entryLength >= 0x10 { e.rating = r.u32(seek + 12) }
            if entryLength >= 0x1C {
                e.skipCount = r.u32(seek + 20)
                e.lastSkipped = MacTime.toDate(r.u32(seek + 24), tzOffset: tzOffset)
            }
            result.append(e)
        }
        return result
    }

    /// Merges play statistics into `tracks` (which must be in the order they were written to the device).
    static func apply(_ entries: [PlayCountEntry], to tracks: inout [IPodTrack]) {
        for (i, e) in entries.enumerated() where i < tracks.count {
            if e.playCount > 0 {
                tracks[i].playCount &+= e.playCount
                tracks[i].playCount2 &+= e.playCount
                if let t = e.timePlayed { tracks[i].timePlayed = t }
                if tracks[i].isPodcast { tracks[i].markUnplayed = 0x01 }
            }
            if e.bookmarkTimeMs != 0 || tracks[i].rememberPlaybackPosition == 1 {
                tracks[i].bookmarkTimeMs = e.bookmarkTimeMs
            }
            if let rating = e.rating, rating != 0 {
                tracks[i].rating = UInt8(min(rating, 100))
            }
            if e.skipCount > 0 {
                tracks[i].skipCount &+= e.skipCount
                if let s = e.lastSkipped { tracks[i].lastSkipped = s }
            }
        }
    }
}
