//
//  ITunesDBReader.swift
//  iPod Pro Max
//
//  Parses an existing iTunesDB (written by iTunes, libgpod or this app) into an ITunesDatabase.
//

import Foundation

struct ITunesDBReader {
    let reader: ByteReader

    init(data: Data) {
        reader = ByteReader(data)
    }

    func parse() throws -> ITunesDatabase {
        let r = reader
        guard r.hasHeader("mhbd", at: 0) else { throw IPodDBError.notAnITunesDB("missing mhbd header") }
        var db = ITunesDatabase()
        let headerLen = Int(r.u32(4))
        let totalLen = Int(r.u32(8))
        db.version = r.u32(0x10)
        let children = Int(r.u32(0x14))
        db.databaseID = r.u64(0x18)
        if headerLen >= 0x70 {
            db.platform = r.u16(0x20)
            db.unk0x22 = r.u16(0x22)
            db.id0x24 = r.u64(0x24)
            db.language = r.u16(0x46)
            db.libraryPersistentID = r.u64(0x48)
            db.unk0x50 = r.u32(0x50)
            db.unk0x54 = r.u32(0x54)
            db.tzOffset = r.i32(0x6C)
        }
        if headerLen >= 0xA4 {
            db.audioLanguage = r.u16(0xA0)
            db.subtitleLanguage = r.u16(0xA2)
        }
        if db.tzOffset.magnitude > 15 * 3600 { db.tzOffset = 0 }
        if db.version == 0 { db.version = 0x30 }
        let tz = db.tzOffset

        // Locate mhsd blocks.
        var seek = headerLen
        var trackListSeek: Int?
        var playlistSeek: Int?
        var podcastPlaylistSeek: Int?
        var count = 0
        while seek + 16 <= min(totalLen, r.count), count < max(children, 12) {
            guard r.hasHeader("mhsd", at: seek) else { break }
            let hlen = Int(r.u32(seek + 4))
            let tlen = Int(r.u32(seek + 8))
            let type = r.u32(seek + 12)
            switch type {
            case 1: trackListSeek = seek + hlen
            case 2: playlistSeek = seek + hlen
            case 3: podcastPlaylistSeek = seek + hlen
            default: break
            }
            guard tlen > 0 else { break }
            seek += tlen
            count += 1
        }

        var trackIDToDBID: [UInt32: UInt64] = [:]
        if let ts = trackListSeek {
            db.tracks = try parseTracks(at: ts, tz: tz)
            for t in db.tracks { trackIDToDBID[t.trackID] = t.dbid }
        }
        let plSeek = playlistSeek ?? podcastPlaylistSeek
        if let ps = plSeek {
            db.playlists = try parsePlaylists(at: ps, tz: tz, trackIDToDBID: trackIDToDBID, special: playlistSeek == nil)
        }
        if db.masterPlaylist == nil {
            var mpl = IPodPlaylist(name: "iPod")
            mpl.isMaster = true
            mpl.memberDBIDs = db.tracks.filter { !$0.isPodcast }.map(\.dbid)
            db.playlists.insert(mpl, at: 0)
        }
        return db
    }

    // MARK: - Tracks

    private func parseTracks(at mhlt: Int, tz: Int32) throws -> [IPodTrack] {
        let r = reader
        guard r.hasHeader("mhlt", at: mhlt) else { throw IPodDBError.corrupt("missing track list (mhlt)") }
        let hlen = Int(r.u32(mhlt + 4))
        let n = Int(r.u32(mhlt + 8))
        var seek = mhlt + hlen
        var tracks: [IPodTrack] = []
        tracks.reserveCapacity(n)
        for _ in 0..<n {
            guard r.hasHeader("mhit", at: seek) else { break }
            let (track, len) = parseMHIT(at: seek, tz: tz)
            tracks.append(track)
            guard len > 0 else { break }
            seek += len
        }
        return tracks
    }

    private func parseMHIT(at s: Int, tz: Int32) -> (IPodTrack, Int) {
        let r = reader
        let hlen = Int(r.u32(s + 4))
        let tlen = Int(r.u32(s + 8))
        let mhods = Int(r.u32(s + 12))
        var t = IPodTrack(dbid: r.u64(s + 0x70))
        t.trackID = r.u32(s + 0x10)
        t.filetypeMarker = r.u32(s + 0x18)
        t.type1 = r.u8(s + 0x1C)
        t.type2 = r.u8(s + 0x1D)
        t.compilation = r.u8(s + 0x1E)
        t.rating = r.u8(s + 0x1F)
        t.timeModified = MacTime.toDate(r.u32(s + 0x20), tzOffset: tz)
        t.fileSize = r.u32(s + 0x24)
        t.durationMs = r.u32(s + 0x28)
        t.trackNumber = r.u32(s + 0x2C)
        t.trackCount = r.u32(s + 0x30)
        t.year = r.u32(s + 0x34)
        t.bitrate = r.u32(s + 0x38)
        t.sampleRate = r.u32(s + 0x3C) >> 16
        t.volume = r.i32(s + 0x40)
        t.startTime = r.u32(s + 0x44)
        t.stopTime = r.u32(s + 0x48)
        t.soundCheck = r.u32(s + 0x4C)
        t.playCount = r.u32(s + 0x50)
        t.playCount2 = r.u32(s + 0x54)
        t.timePlayed = MacTime.toDate(r.u32(s + 0x58), tzOffset: tz)
        t.discNumber = r.u32(s + 0x5C)
        t.discCount = r.u32(s + 0x60)
        t.drmUserID = r.u32(s + 0x64)
        t.timeAdded = MacTime.toDate(r.u32(s + 0x68), tzOffset: tz)
        t.bookmarkTimeMs = r.u32(s + 0x6C)
        t.checked = r.u8(s + 0x78)
        t.appRating = r.u8(s + 0x79)
        t.bpm = r.u16(s + 0x7A)
        t.artworkCount = r.u16(s + 0x7C)
        t.unk126 = r.u16(s + 0x7E)
        t.artworkSize = r.u32(s + 0x80)
        t.unk132 = r.u32(s + 0x84)
        t.timeReleased = MacTime.toDate(r.u32(s + 0x8C), tzOffset: tz)
        if hlen >= 0xA4 {
            t.unk144 = r.u16(s + 0x90)
            t.explicitFlag = r.u16(s + 0x92)
            t.unk148 = r.u32(s + 0x94)
            t.unk152 = r.u32(s + 0x98)
            t.skipCount = r.u32(s + 0x9C)
            t.lastSkipped = MacTime.toDate(r.u32(s + 0xA0), tzOffset: tz)
        }
        if hlen >= 0xB0 {
            t.hasArtwork = r.u8(s + 0xA4)
            t.skipWhenShuffling = r.u8(s + 0xA5)
            t.rememberPlaybackPosition = r.u8(s + 0xA6)
            t.flag4 = r.u8(s + 0xA7)
            t.dbid2 = r.u64(s + 0xA8)
        }
        if hlen >= 0xD4 {
            t.lyricsFlag = r.u8(s + 0xB0)
            t.movieFlag = r.u8(s + 0xB1)
            t.markUnplayed = r.u8(s + 0xB2)
            t.unk179 = r.u8(s + 0xB3)
            t.unk180 = r.u32(s + 0xB4)
            t.pregap = r.u32(s + 0xB8)
            t.sampleCount = r.u64(s + 0xBC)
            t.unk196 = r.u32(s + 0xC4)
            t.postgap = r.u32(s + 0xC8)
            t.unk204 = r.u32(s + 0xCC)
            t.mediaType = r.u32(s + 0xD0)
        }
        if hlen >= 0xDC {
            t.seasonNumber = r.u32(s + 0xD4)
            t.episodeNumber = r.u32(s + 0xD8)
        }
        if hlen >= 0x104 {
            t.gaplessData = r.u32(s + 0xF8)
            t.gaplessTrackFlag = r.u16(s + 0x100)
            t.gaplessAlbumFlag = r.u16(s + 0x102)
        }
        if hlen >= 0x164 {
            t.mhiiLink = r.u32(s + 0x160)
        }
        if t.mediaType == 0 { t.mediaType = IPodMediaType.audio }
        if t.dbid2 == 0 { t.dbid2 = t.dbid }
        if t.hasArtwork == 0 { t.hasArtwork = 0x02 }
        if t.markUnplayed == 0 { t.markUnplayed = 0x01 }

        var seek = s + hlen
        for _ in 0..<mhods {
            guard r.hasHeader("mhod", at: seek) else { break }
            let mlen = Int(r.u32(seek + 8))
            let type = r.u32(seek + 12)
            let hl = Int(r.u32(seek + 4))
            if MHODType.stringTypes.contains(type) {
                let str = readString(at: seek + hl)
                switch type {
                case MHODType.title: t.title = str
                case MHODType.path: t.ipodPath = str
                case MHODType.album: t.album = str
                case MHODType.artist: t.artist = str
                case MHODType.genre: t.genre = str
                case MHODType.filetype: t.filetypeDescription = str
                case MHODType.comment: t.comment = str
                case MHODType.category: t.category = str
                case MHODType.composer: t.composer = str
                case MHODType.grouping: t.grouping = str
                case MHODType.description: t.description = str
                case MHODType.subtitle: t.subtitle = str
                case MHODType.albumArtist: t.albumArtist = str
                case MHODType.sortArtist: t.sortArtist = str
                case MHODType.sortTitle: t.sortTitle = str
                case MHODType.sortAlbum: t.sortAlbum = str
                case MHODType.sortAlbumArtist: t.sortAlbumArtist = str
                case MHODType.sortComposer: t.sortComposer = str
                default: break
                }
            } else if type == MHODType.podcastURL || type == MHODType.podcastRSS {
                let str = r.utf8String(seek + hl, byteLength: mlen - hl).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                if type == MHODType.podcastURL { t.podcastURL = str } else { t.podcastRSS = str }
            }
            guard mlen > 0 else { break }
            seek += mlen
        }
        return (t, max(tlen, seek - s))
    }

    /// Reads the string body that follows a string-type mhod header.
    private func readString(at s: Int) -> String {
        let r = reader
        let encoding = r.u32(s)
        let byteLen = Int(r.u32(s + 4))
        guard byteLen >= 0, byteLen < 1 << 20 else { return "" }
        if encoding == 2 {
            return r.utf8String(s + 16, byteLength: byteLen)
        }
        return r.utf16LEString(s + 16, byteLength: byteLen)
    }

    // MARK: - Playlists

    private func parsePlaylists(at mhlp: Int, tz: Int32, trackIDToDBID: [UInt32: UInt64], special: Bool) throws -> [IPodPlaylist] {
        let r = reader
        guard r.hasHeader("mhlp", at: mhlp) else { throw IPodDBError.corrupt("missing playlist list (mhlp)") }
        let hlen = Int(r.u32(mhlp + 4))
        let n = Int(r.u32(mhlp + 8))
        var seek = mhlp + hlen
        var playlists: [IPodPlaylist] = []
        for _ in 0..<n {
            guard r.hasHeader("mhyp", at: seek) else { break }
            let (pl, len) = parseMHYP(at: seek, tz: tz, trackIDToDBID: trackIDToDBID)
            playlists.append(pl)
            guard len > 0 else { break }
            seek += len
        }
        return playlists
    }

    private func parseMHYP(at s: Int, tz: Int32, trackIDToDBID: [UInt32: UInt64]) -> (IPodPlaylist, Int) {
        let r = reader
        let hlen = Int(r.u32(s + 4))
        let tlen = Int(r.u32(s + 8))
        let mhods = Int(r.u32(s + 12))
        let mhips = Int(r.u32(s + 16))
        var pl = IPodPlaylist(id: r.u64(s + 28), name: "")
        pl.isMaster = r.u8(s + 20) == 1
        pl.flag1 = r.u8(s + 21)
        pl.flag2 = r.u8(s + 22)
        pl.flag3 = r.u8(s + 23)
        pl.timestamp = MacTime.toDate(r.u32(s + 24), tzOffset: tz)
        if hlen >= 48 {
            pl.isPodcasts = r.u16(s + 42) == 1
            pl.sortOrder = r.u32(s + 44)
        }
        var seek = s + hlen
        for _ in 0..<mhods {
            guard r.hasHeader("mhod", at: seek) else { break }
            let mlen = Int(r.u32(seek + 8))
            let type = r.u32(seek + 12)
            let hl = Int(r.u32(seek + 4))
            if type == MHODType.title {
                pl.name = readString(at: seek + hl)
            } else if type == MHODType.smartPlaylistRules || type == MHODType.smartPlaylistPrefs {
                pl.isSmart = true
            }
            guard mlen > 0 else { break }
            seek += mlen
        }
        for _ in 0..<mhips {
            // Tolerate stray mhods (some writers count them differently).
            while r.hasHeader("mhod", at: seek) {
                let mlen = Int(r.u32(seek + 8))
                guard mlen > 0 else { break }
                seek += mlen
            }
            guard r.hasHeader("mhip", at: seek) else { break }
            let ilen = Int(r.u32(seek + 8))
            let groupFlag = r.u32(seek + 16)
            let trackID = r.u32(seek + 24)
            if groupFlag == 0, let dbid = trackIDToDBID[trackID] {
                pl.memberDBIDs.append(dbid)
            }
            guard ilen > 0 else { break }
            seek += ilen
        }
        if pl.name.isEmpty { pl.name = pl.isMaster ? "iPod" : "Playlist" }
        return (pl, max(tlen, seek - s))
    }
}
