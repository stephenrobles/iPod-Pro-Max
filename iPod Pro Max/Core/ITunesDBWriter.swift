//
//  ITunesDBWriter.swift
//  iPod Pro Max
//
//  Serializes an ITunesDatabase to the binary iTunesDB format. The layout mirrors what libgpod
//  (and iTunes 9.x) write, which is what iPod firmware expects.
//

import Foundation

enum IPodChecksumType {
    case none
    case hash58
    case hash72
    case hashAB
    case unknown
}

struct ITunesDBWriter {
    var database: ITunesDatabase
    var checksum: IPodChecksumType = .none
    /// FireWire GUID bytes (needed for hash58).
    var firewireID: [UInt8]?
    /// Whether the device wants the "compressed database" flag (iPhone / nano 5G). Always false for our targets.
    var supportsCompressedDB = false

    private static let firstTrackID: UInt32 = 52

    /// Writes the database and returns the bytes. `database.tracks` are re-ordered (master playlist order first)
    /// and receive their track ids; the mutated database is returned alongside so callers can persist ids.
    func write() throws -> (data: Data, database: ITunesDatabase) {
        var db = database
        // Always write the iTunes 9.2 layout regardless of what the device had; the firmware only checks a minimum.
        db.version = 0x30
        prepare(&db)

        var w = ByteWriter(capacity: 1 << 20)
        var nextID = Self.firstTrackID + UInt32(db.tracks.count)

        let albums = Self.groupIDs(db.tracks, key: { $0.album == nil ? nil : "\($0.album ?? "")\u{1}\($0.albumArtist ?? $0.artist ?? "")" })
        let artists = Self.groupIDs(db.tracks, key: { $0.artist })
        let composers = Self.groupIDs(db.tracks, key: { $0.composer })
        for i in db.tracks.indices {
            let t = db.tracks[i]
            db.tracks[i].albumID = t.album == nil ? 0 : (albums.ids["\(t.album ?? "")\u{1}\(t.albumArtist ?? t.artist ?? "")"] ?? 0)
            db.tracks[i].artistID = t.artist == nil ? 0 : (artists.ids[t.artist ?? ""] ?? 0)
            db.tracks[i].composerID = t.composer == nil ? 0 : (composers.ids[t.composer ?? ""] ?? 0)
        }

        writeMHBD(&w, db: db, children: 8)

        writeTracksMHSD(&w, db: db)
        try writePlaylistsMHSD(&w, db: db, type: 3, nextID: &nextID)
        try writePlaylistsMHSD(&w, db: db, type: 2, nextID: &nextID)
        writeAlbumsMHSD(&w, db: db, albums: albums)
        writeArtistsMHSD(&w, db: db, artists: artists)
        writeEmptyTrackListMHSD(&w, type: 6)
        writeEmptyTrackListMHSD(&w, type: 10)
        writeEmptyPlaylistsMHSD(&w, type: 5)

        w.fixTotalLength(headerStart: 0)

        var bytes = w.bytes
        switch checksum {
        case .none:
            break
        case .hash58:
            guard let fw = firewireID else { throw IPodDBError.unsupported("This iPod requires a signed database, but its FireWire ID could not be read.") }
            try Hash58.sign(database: &bytes, firewireID: fw)
        case .hash72, .hashAB, .unknown:
            throw IPodDBError.unsupported("This iPod model uses a database signature that iPod Pro Max does not support yet.")
        }
        return (Data(bytes), db)
    }

    // MARK: - Preparation

    private func prepare(_ db: inout ITunesDatabase) {
        // Order tracks like the master playlist (podcasts and other non-MPL tracks follow).
        var ordered: [IPodTrack] = []
        var seen = Set<UInt64>()
        let byDBID = Dictionary(db.tracks.map { ($0.dbid, $0) }, uniquingKeysWith: { a, _ in a })
        if let mpl = db.masterPlaylist {
            for dbid in mpl.memberDBIDs {
                if !seen.contains(dbid), let t = byDBID[dbid] {
                    ordered.append(t)
                    seen.insert(dbid)
                }
            }
        }
        for t in db.tracks where !seen.contains(t.dbid) {
            ordered.append(t)
            seen.insert(t.dbid)
        }
        for i in ordered.indices {
            ordered[i].trackID = Self.firstTrackID + UInt32(i)
            if ordered[i].dbid2 == 0 { ordered[i].dbid2 = ordered[i].dbid }
        }
        db.tracks = ordered

        // Make sure a master playlist exists and is first.
        if db.masterPlaylist == nil {
            var mpl = IPodPlaylist(name: "iPod")
            mpl.isMaster = true
            db.playlists.insert(mpl, at: 0)
        } else if let idx = db.playlists.firstIndex(where: { $0.isMaster }), idx != 0 {
            let mpl = db.playlists.remove(at: idx)
            db.playlists.insert(mpl, at: 0)
        }
        // Smart playlists cannot be round-tripped; drop them.
        db.playlists.removeAll { $0.isSmart }
        // Master playlist must contain every non-podcast track.
        if let idx = db.playlists.firstIndex(where: { $0.isMaster }) {
            let existing = Set(db.playlists[idx].memberDBIDs)
            let podcastIDs = Set(db.tracks.filter { $0.isPodcast }.map(\.dbid))
            db.playlists[idx].memberDBIDs.removeAll { podcastIDs.contains($0) || byDBID[$0] == nil }
            for t in db.tracks where !t.isPodcast && !existing.contains(t.dbid) {
                db.playlists[idx].memberDBIDs.append(t.dbid)
            }
        }
    }

    private struct GroupIDs {
        var ids: [String: UInt32] = [:]
        /// First track (by key) representative for writing names, in id order.
        var representatives: [(id: UInt32, track: IPodTrack)] = []
    }

    private static func groupIDs(_ tracks: [IPodTrack], key: (IPodTrack) -> String?) -> GroupIDs {
        var g = GroupIDs()
        var next: UInt32 = 1
        for t in tracks {
            guard let k = key(t) else { continue }
            if g.ids[k] == nil {
                g.ids[k] = next
                g.representatives.append((next, t))
                next += 1
            }
        }
        return g
    }

    // MARK: - mhbd

    private func writeMHBD(_ w: inout ByteWriter, db: ITunesDatabase, children: UInt32) {
        w.header("mhbd")
        w.u32(244)
        w.u32(0) // total length, fixed later
        w.u32(supportsCompressedDB ? 2 : 1)
        w.u32(db.version)
        w.u32(children)
        w.u64(db.databaseID)
        // 0x20
        w.u16(db.platform)
        w.u16(db.unk0x22)
        w.u64(db.id0x24)
        w.u32(0)
        // 0x30
        w.u16(0) // hashing scheme, set by the signer
        w.zeros(20) // 0x32..0x46
        // 0x46
        w.u16(db.language)
        w.u64(db.libraryPersistentID)
        // 0x50
        w.u32(db.unk0x50)
        w.u32(db.unk0x54)
        w.zero32(5) // hash58 at 0x58
        w.i32(db.tzOffset) // 0x6C
        // 0x70
        switch checksum {
        case .hashAB: w.u16(4)
        case .hash72: w.u16(2)
        default: w.u16(0)
        }
        w.u16(0)
        w.zero32(11) // hash72
        // 0xA0
        w.u16(db.audioLanguage)
        w.u16(db.subtitleLanguage)
        w.u16(0)
        w.u16(0)
        w.u16(0)
        w.u8(0)
        // 0xAB
        w.u8(0)
        w.zero32(14)
        w.zero32(4)
        assert(w.count == 244)
    }

    private func writeMHSDHeader(_ w: inout ByteWriter, type: UInt32) -> Int {
        let start = w.count
        w.header("mhsd")
        w.u32(96)
        w.u32(0)
        w.u32(type)
        w.zero32(20)
        return start
    }

    // MARK: - Tracks (mhsd 1)

    private func writeTracksMHSD(_ w: inout ByteWriter, db: ITunesDatabase) {
        let mhsd = writeMHSDHeader(&w, type: 1)
        w.header("mhlt")
        w.u32(92)
        w.u32(UInt32(db.tracks.count))
        w.zero32(20)
        for t in db.tracks {
            writeMHIT(&w, track: t, db: db)
        }
        w.fixTotalLength(headerStart: mhsd)
    }

    private func writeMHIT(_ w: inout ByteWriter, track t: IPodTrack, db: ITunesDatabase) {
        let start = w.count
        let tz = db.tzOffset
        w.header("mhit")
        w.u32(0x248)
        w.u32(0) // total, later
        w.u32(0) // mhod count, later
        // 0x10
        w.u32(t.trackID)
        w.u32(1) // visible
        w.u32(t.filetypeMarker)
        w.u8(t.type1)
        w.u8(t.type2)
        w.u8(t.compilation)
        w.u8(t.rating)
        // 0x20
        w.u32(MacTime.fromDate(t.timeModified, tzOffset: tz))
        w.u32(t.fileSize)
        w.u32(t.durationMs)
        w.u32(t.trackNumber)
        // 0x30
        w.u32(t.trackCount)
        w.u32(t.year)
        w.u32(t.bitrate)
        w.u32(t.sampleRate << 16)
        // 0x40
        w.i32(t.volume)
        w.u32(t.startTime)
        w.u32(t.stopTime)
        w.u32(t.soundCheck)
        // 0x50
        w.u32(t.playCount)
        w.u32(t.playCount2)
        w.u32(MacTime.fromDate(t.timePlayed, tzOffset: tz))
        w.u32(t.discNumber)
        // 0x60
        w.u32(t.discCount)
        w.u32(t.drmUserID)
        w.u32(MacTime.fromDate(t.timeAdded, tzOffset: tz))
        w.u32(t.bookmarkTimeMs)
        // 0x70
        w.u64(t.dbid)
        w.u8(t.checked)
        w.u8(t.appRating)
        w.u16(t.bpm)
        w.u16(t.artworkCount)
        w.u16(t.unk126)
        // 0x80
        w.u32(t.artworkSize)
        w.u32(t.unk132)
        w.f32(Float(t.sampleRate))
        w.u32(MacTime.fromDate(t.timeReleased, tzOffset: tz))
        // 0x90
        w.u16(t.unk144)
        w.u16(t.explicitFlag)
        w.u32(t.unk148)
        w.u32(t.unk152)
        w.u32(t.skipCount)
        // 0xA0
        w.u32(MacTime.fromDate(t.lastSkipped, tzOffset: tz))
        w.u8(t.hasArtwork)
        w.u8(t.skipWhenShuffling)
        w.u8(t.rememberPlaybackPosition)
        w.u8(t.flag4)
        w.u64(t.dbid2 == 0 ? t.dbid : t.dbid2)
        // 0xB0
        w.u8(t.lyricsFlag)
        w.u8(t.movieFlag)
        w.u8(t.markUnplayed)
        w.u8(t.unk179)
        w.u32(t.unk180)
        w.u32(t.pregap)
        w.u64(t.sampleCount)
        w.u32(t.unk196)
        w.u32(t.postgap)
        w.u32(t.unk204)
        // 0xD0
        w.u32(t.mediaType)
        w.u32(t.seasonNumber)
        w.u32(t.episodeNumber)
        w.u32(0)
        // 0xE0
        w.zero32(4)
        // 0xF0
        w.u32(0)
        w.u32(0)
        w.u32(t.gaplessData)
        w.u32(0)
        // 0x100
        w.u16(t.gaplessTrackFlag)
        w.u16(t.gaplessAlbumFlag)
        w.zero32(7)
        // 0x120
        w.u32(t.albumID)
        w.u64(db.id0x24)
        w.u32(t.fileSize)
        // 0x130
        w.u32(0)
        w.u64(0x8080_8080_8080)
        w.u32(0)
        // 0x140
        w.zero32(2)
        w.u32(0)
        w.zero32(5)
        // 0x160
        w.u32(t.mhiiLink)
        w.u32(0)
        w.u32(1)
        w.u32(0)
        // 0x170
        w.zero32(28)
        // 0x1E0
        w.u32(t.artistID)
        w.zero32(4)
        // 0x1F4
        w.u32(t.composerID)
        w.zero32(20)
        assert(w.count - start == 0x248)

        var mhods: UInt32 = 0
        func str(_ type: UInt32, _ s: String?) {
            guard let s, !s.isEmpty else { return }
            Self.writeStringMHOD(&w, type: type, string: s)
            mhods += 1
        }
        str(MHODType.title, t.title)
        str(MHODType.artist, t.artist)
        str(MHODType.album, t.album)
        str(MHODType.filetype, t.filetypeDescription)
        str(MHODType.comment, t.comment)
        str(MHODType.path, t.ipodPath)
        str(MHODType.genre, t.genre)
        str(MHODType.category, t.category)
        str(MHODType.composer, t.composer)
        str(MHODType.grouping, t.grouping)
        str(MHODType.description, t.description)
        str(MHODType.subtitle, t.subtitle)
        str(MHODType.albumArtist, t.albumArtist)
        if let u = t.podcastURL, !u.isEmpty { Self.writeURLMHOD(&w, type: MHODType.podcastURL, string: u); mhods += 1 }
        if let u = t.podcastRSS, !u.isEmpty { Self.writeURLMHOD(&w, type: MHODType.podcastRSS, string: u); mhods += 1 }
        str(MHODType.sortArtist, t.sortArtist)
        str(MHODType.sortTitle, t.sortTitle)
        str(MHODType.sortAlbum, t.sortAlbum)
        str(MHODType.sortAlbumArtist, t.sortAlbumArtist)
        str(MHODType.sortComposer, t.sortComposer)

        w.fixTotalLength(headerStart: start)
        w.patchU32(mhods, at: start + 12)
    }

    // MARK: - mhod helpers

    static func writeStringMHOD(_ w: inout ByteWriter, type: UInt32, string: String) {
        let units = Array(string.utf16)
        let byteLen = UInt32(units.count * 2)
        w.header("mhod")
        w.u32(24)
        w.u32(byteLen + 40)
        w.u32(type)
        w.u32(0)
        w.u32(0)
        w.u32(1) // string type UTF-16
        w.u32(byteLen)
        w.u32(1)
        w.u32(0)
        for u in units { w.u16(u) }
    }

    static func writeURLMHOD(_ w: inout ByteWriter, type: UInt32, string: String) {
        let bytes = Array(string.utf8)
        w.header("mhod")
        w.u32(24)
        w.u32(UInt32(24 + bytes.count))
        w.u32(type)
        w.u32(0)
        w.u32(0)
        w.append(bytes)
    }

    private static func writePlaylistPositionMHOD(_ w: inout ByteWriter, position: UInt32) {
        w.header("mhod")
        w.u32(24)
        w.u32(44)
        w.u32(MHODType.playlistPosition)
        w.u32(0)
        w.u32(0)
        w.u32(position)
        w.zero32(4)
    }

    /// iTunes preferences blob attached to every playlist (column layout). Values copied from libgpod.
    private static func writeLongPlaylistMHOD(_ w: inout ByteWriter) {
        let start = w.count
        w.header("mhod")
        w.u32(0x18)
        w.u32(0x288)
        w.u32(MHODType.playlistPosition)
        w.zero32(6)
        w.u32(0x010084)
        w.u32(0x05)
        w.u32(0x09)
        w.u32(0x03)
        w.u32(0x120001)
        w.zero32(3)
        w.u32(0xc80002)
        w.zero32(3)
        w.u32(0x3c000d)
        w.zero32(3)
        w.u32(0x7d0004)
        w.zero32(3)
        w.u32(0x7d0003)
        w.zero32(3)
        w.u32(0x640008)
        w.zero32(3)
        w.u32(0x640017)
        w.u32(0x01)
        w.zero32(2)
        w.u32(0x500014)
        w.u32(0x01)
        w.zero32(2)
        w.u32(0x7d0015)
        w.u32(0x01)
        w.zero32(2)
        w.padTo(length: 0x288, from: start)
        assert(w.count - start == 0x288)
    }

    // MARK: - Playlists (mhsd 2 / 3)

    private func writePlaylistsMHSD(_ w: inout ByteWriter, db: ITunesDatabase, type: UInt32, nextID: inout UInt32) throws {
        let mhsd = writeMHSDHeader(&w, type: type)
        let mhlp = w.count
        w.header("mhlp")
        w.u32(92)
        w.u32(0) // count later
        w.zero32(20)
        var count: UInt32 = 0
        let trackIDByDBID = Dictionary(db.tracks.map { ($0.dbid, $0.trackID) }, uniquingKeysWith: { a, _ in a })
        let indexByDBID = Dictionary(db.tracks.enumerated().map { ($0.element.dbid, UInt32($0.offset)) }, uniquingKeysWith: { a, _ in a })
        for pl in db.playlists {
            writeMHYP(&w, playlist: pl, db: db, mhsdType: type, trackIDByDBID: trackIDByDBID, indexByDBID: indexByDBID, nextID: &nextID)
            count += 1
        }
        w.patchU32(count, at: mhlp + 8)
        w.fixTotalLength(headerStart: mhsd)
    }

    private func writeMHYP(_ w: inout ByteWriter, playlist pl: IPodPlaylist, db: ITunesDatabase, mhsdType: UInt32,
                           trackIDByDBID: [UInt64: UInt32], indexByDBID: [UInt64: UInt32], nextID: inout UInt32) {
        let start = w.count
        let members = pl.memberDBIDs.filter { trackIDByDBID[$0] != nil }
        let isMPLWithMembers = pl.isMaster && !members.isEmpty
        w.header("mhyp")
        w.u32(108)
        w.u32(0)
        w.u32(isMPLWithMembers ? 12 : 2)
        w.u32(0) // mhip count, later
        w.u8(pl.isMaster ? 1 : 0)
        w.u8(pl.flag1)
        w.u8(pl.flag2)
        w.u8(pl.flag3)
        w.u32(MacTime.fromDate(pl.timestamp ?? Date(), tzOffset: db.tzOffset))
        w.u64(pl.id)
        w.u32(0)
        w.u16(1)
        w.u16(pl.isPodcasts ? 1 : 0)
        w.u32(pl.sortOrder)
        w.zero32(15)
        assert(w.count - start == 108)

        Self.writeStringMHOD(&w, type: MHODType.title, string: pl.name)
        Self.writeLongPlaylistMHOD(&w)

        if isMPLWithMembers {
            let tracks = members.compactMap { dbid -> (index: UInt32, track: IPodTrack)? in
                guard let idx = indexByDBID[dbid] else { return nil }
                return (idx, db.tracks[Int(idx)])
            }
            for sort in LibraryIndexSort.allCases {
                Self.writeLibraryIndexMHODs(&w, sort: sort, tracks: tracks)
            }
        }

        var mhipCount: UInt32 = 0
        if pl.isPodcasts && mhsdType == 3 {
            // Group episodes by show (album) — the iPod shows these as expandable groups.
            var groups: [(album: String, members: [UInt64])] = []
            var groupIndex: [String: Int] = [:]
            for dbid in members {
                let album = db.track(dbid: dbid)?.album ?? ""
                if let gi = groupIndex[album] {
                    groups[gi].members.append(dbid)
                } else {
                    groupIndex[album] = groups.count
                    groups.append((album, [dbid]))
                }
            }
            for g in groups {
                let groupID = nextID
                nextID += 1
                let mhip = w.count
                Self.writeMHIP(&w, podcastGroupFlag: 256, id: groupID, trackID: 0, groupRef: 0)
                Self.writeStringMHOD(&w, type: MHODType.title, string: g.album)
                w.fixTotalLength(headerStart: mhip)
                mhipCount += 1
                for dbid in g.members {
                    let mhipID = nextID
                    nextID += 1
                    let s = w.count
                    Self.writeMHIP(&w, podcastGroupFlag: 0, id: mhipID, trackID: trackIDByDBID[dbid] ?? 0, groupRef: groupID)
                    Self.writePlaylistPositionMHOD(&w, position: mhipID)
                    w.fixTotalLength(headerStart: s)
                    mhipCount += 1
                }
            }
        } else {
            for (i, dbid) in members.enumerated() {
                let s = w.count
                Self.writeMHIP(&w, podcastGroupFlag: 0, id: 0, trackID: trackIDByDBID[dbid] ?? 0, groupRef: 0)
                Self.writePlaylistPositionMHOD(&w, position: UInt32(i))
                w.fixTotalLength(headerStart: s)
                mhipCount += 1
            }
        }
        w.patchU32(mhipCount, at: start + 16)
        w.fixTotalLength(headerStart: start)
    }

    private static func writeMHIP(_ w: inout ByteWriter, podcastGroupFlag: UInt32, id: UInt32, trackID: UInt32, groupRef: UInt32) {
        w.header("mhip")
        w.u32(76)
        w.u32(0)
        w.u32(1) // one child mhod
        w.u32(podcastGroupFlag)
        w.u32(id)
        w.u32(trackID)
        w.u32(0) // timestamp
        w.u32(groupRef)
        w.zero32(10)
    }

    // MARK: - Library index (mhod 52 / 53)

    enum LibraryIndexSort: UInt32, CaseIterable {
        case title = 0x03
        case artist = 0x05
        case album = 0x04
        case genre = 0x07
        case composer = 0x12
    }

    private static func writeLibraryIndexMHODs(_ w: inout ByteWriter, sort: LibraryIndexSort, tracks: [(index: UInt32, track: IPodTrack)]) {
        struct Key {
            let index: UInt32
            let title: String
            let album: String
            let artist: String
            let genre: String
            let composer: String
            let disc: UInt32
            let trackNr: UInt32
            let letter: UInt16
        }
        let keys: [Key] = tracks.map { entry in
            let t = entry.track
            let title = SortKey.collate(t.sortTitle ?? t.title)
            let album = SortKey.collate(t.sortAlbum ?? t.album)
            let artist = SortKey.collate(t.sortArtist ?? SortKey.articleAware(t.artist))
            let genre = SortKey.collate(t.genre)
            let composer = SortKey.collate(t.sortComposer ?? t.composer)
            let primary: String?
            switch sort {
            case .title: primary = t.sortTitle ?? t.title
            case .artist: primary = t.sortArtist ?? SortKey.articleAware(t.artist)
            case .album: primary = t.sortAlbum ?? t.album
            case .genre: primary = t.genre
            case .composer: primary = t.sortComposer ?? t.composer
            }
            return Key(index: entry.index, title: title, album: album, artist: artist, genre: genre, composer: composer,
                       disc: t.discNumber, trackNr: t.trackNumber, letter: SortKey.jumpLetter(primary))
        }
        let sorted = keys.sorted { a, b in
            func cmp(_ x: String, _ y: String) -> Int { x < y ? -1 : (x > y ? 1 : 0) }
            var r = 0
            switch sort {
            case .title:
                r = cmp(a.title, b.title)
            case .album:
                r = cmp(a.album, b.album)
                if r == 0 { r = a.disc < b.disc ? -1 : (a.disc > b.disc ? 1 : 0) }
                if r == 0 { r = a.trackNr < b.trackNr ? -1 : (a.trackNr > b.trackNr ? 1 : 0) }
                if r == 0 { r = cmp(a.title, b.title) }
            case .artist:
                r = cmp(a.artist, b.artist)
                if r == 0 { r = cmp(a.album, b.album) }
                if r == 0 { r = a.disc < b.disc ? -1 : (a.disc > b.disc ? 1 : 0) }
                if r == 0 { r = a.trackNr < b.trackNr ? -1 : (a.trackNr > b.trackNr ? 1 : 0) }
                if r == 0 { r = cmp(a.title, b.title) }
            case .genre:
                r = cmp(a.genre, b.genre)
                if r == 0 { r = cmp(a.artist, b.artist) }
                if r == 0 { r = cmp(a.album, b.album) }
                if r == 0 { r = a.disc < b.disc ? -1 : (a.disc > b.disc ? 1 : 0) }
                if r == 0 { r = a.trackNr < b.trackNr ? -1 : (a.trackNr > b.trackNr ? 1 : 0) }
                if r == 0 { r = cmp(a.title, b.title) }
            case .composer:
                r = cmp(a.composer, b.composer)
                if r == 0 { r = cmp(a.album, b.album) }
                if r == 0 { r = a.disc < b.disc ? -1 : (a.disc > b.disc ? 1 : 0) }
                if r == 0 { r = a.trackNr < b.trackNr ? -1 : (a.trackNr > b.trackNr ? 1 : 0) }
                if r == 0 { r = cmp(a.title, b.title) }
            }
            if r == 0 { return a.index < b.index }
            return r < 0
        }

        // mhod 52
        w.header("mhod")
        w.u32(24)
        w.u32(UInt32(4 * sorted.count + 72))
        w.u32(MHODType.libraryPlaylistIndex)
        w.u32(0)
        w.u32(0)
        w.u32(sort.rawValue)
        w.u32(UInt32(sorted.count))
        w.zero32(10)
        var jump: [(letter: UInt16, start: UInt32, count: UInt32)] = []
        for (i, k) in sorted.enumerated() {
            w.u32(k.index)
            if let last = jump.last, last.letter == k.letter {
                jump[jump.count - 1].count += 1
            } else {
                jump.append((k.letter, UInt32(i), 1))
            }
        }
        // mhod 53
        w.header("mhod")
        w.u32(24)
        w.u32(UInt32(12 * jump.count + 40))
        w.u32(MHODType.libraryPlaylistJumpTable)
        w.u32(0)
        w.u32(0)
        w.u32(sort.rawValue)
        w.u32(UInt32(jump.count))
        w.zero32(2)
        for j in jump {
            w.u16(j.letter)
            w.u16(0)
            w.u32(j.start)
            w.u32(j.count)
        }
    }

    // MARK: - Albums (mhsd 4) / Artists (mhsd 8)

    private func writeAlbumsMHSD(_ w: inout ByteWriter, db: ITunesDatabase, albums: GroupIDs) {
        let mhsd = writeMHSDHeader(&w, type: 4)
        w.header("mhla")
        w.u32(92)
        w.u32(UInt32(albums.representatives.count))
        w.zero32(20)
        for rep in albums.representatives {
            let start = w.count
            let t = rep.track
            w.header("mhia")
            w.u32(88)
            w.u32(0)
            w.u32(2)
            w.u32(rep.id)
            w.u64(UInt64(rep.id) &* 0x9E37_79B9_7F4A_7C15) // stand-in for the sqlite id
            w.u32(2)
            w.zero32(14)
            var n: UInt32 = 0
            if let a = t.album, !a.isEmpty { Self.writeStringMHOD(&w, type: MHODType.albumListAlbum, string: a); n += 1 }
            if let a = t.albumArtist, !a.isEmpty {
                Self.writeStringMHOD(&w, type: MHODType.albumListArtist, string: a); n += 1
            } else if let a = t.artist, !a.isEmpty {
                Self.writeStringMHOD(&w, type: MHODType.albumListArtist, string: a); n += 1
            }
            if let a = t.sortAlbumArtist, !a.isEmpty {
                Self.writeStringMHOD(&w, type: MHODType.albumListSortArtist, string: a); n += 1
            } else if let a = t.sortArtist, !a.isEmpty {
                Self.writeStringMHOD(&w, type: MHODType.albumListSortArtist, string: a); n += 1
            }
            w.fixTotalLength(headerStart: start)
            w.patchU32(n, at: start + 12)
        }
        w.fixTotalLength(headerStart: mhsd)
    }

    private func writeArtistsMHSD(_ w: inout ByteWriter, db: ITunesDatabase, artists: GroupIDs) {
        let mhsd = writeMHSDHeader(&w, type: 8)
        w.header("mhli")
        w.u32(92)
        w.u32(UInt32(artists.representatives.count))
        w.zero32(20)
        for rep in artists.representatives {
            let start = w.count
            w.header("mhii")
            w.u32(80)
            w.u32(0)
            w.u32(1)
            w.u32(rep.id)
            w.u64(UInt64(rep.id) &* 0xC2B2_AE3D_27D4_EB4F)
            w.u32(2)
            w.zero32(12)
            var n: UInt32 = 0
            if let a = rep.track.artist, !a.isEmpty { Self.writeStringMHOD(&w, type: MHODType.artistListName, string: a); n += 1 }
            w.fixTotalLength(headerStart: start)
            w.patchU32(n, at: start + 12)
        }
        w.fixTotalLength(headerStart: mhsd)
    }

    private func writeEmptyTrackListMHSD(_ w: inout ByteWriter, type: UInt32) {
        let mhsd = writeMHSDHeader(&w, type: type)
        w.header("mhlt")
        w.u32(92)
        w.u32(0)
        w.zero32(20)
        w.fixTotalLength(headerStart: mhsd)
    }

    private func writeEmptyPlaylistsMHSD(_ w: inout ByteWriter, type: UInt32) {
        let mhsd = writeMHSDHeader(&w, type: type)
        w.header("mhlp")
        w.u32(92)
        w.u32(0)
        w.zero32(20)
        w.fixTotalLength(headerStart: mhsd)
    }
}

/// Sorting helpers approximating iTunes' collation for the on-device library index.
enum SortKey {
    static func collate(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        var key = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        for article in ["the ", "a ", "an "] where key.hasPrefix(article) && key.count > article.count {
            key.removeFirst(article.count)
            break
        }
        return key
    }

    /// Returns "Artist, The" style sort names like iTunes does for artists with a leading "The".
    static func articleAware(_ s: String?) -> String? {
        guard let s else { return nil }
        if s.lowercased().hasPrefix("the "), s.count > 4 {
            return String(s.dropFirst(4)) + ", The"
        }
        return s
    }

    /// First alphanumeric character uppercased (UTF-16 unit), or '0' when none / digit.
    static func jumpLetter(_ s: String?) -> UInt16 {
        guard let s else { return 0x30 }
        for scalar in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if CharacterSet.letters.contains(scalar) {
                    let upper = String(scalar).uppercased()
                    return upper.utf16.first ?? 0x30
                }
                return 0x30
            }
        }
        return 0x30
    }
}
