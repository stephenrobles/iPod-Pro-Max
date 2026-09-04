//
//  ITunesDBModel.swift
//  iPod Pro Max
//
//  In-memory model of the iPod's iTunesDB (tracks + playlists). Field names and semantics
//  follow the documented format (ipodlinux wiki / libgpod) so behavior matches what iTunes wrote.
//

import Foundation

enum IPodMediaType {
    static let audio: UInt32 = 1 << 0
    static let movie: UInt32 = 1 << 1
    static let podcast: UInt32 = 1 << 2
    static let audiobook: UInt32 = 1 << 3
    static let musicVideo: UInt32 = 1 << 5
    static let tvShow: UInt32 = 1 << 6
}

enum MHODType {
    static let title: UInt32 = 1
    static let path: UInt32 = 2
    static let album: UInt32 = 3
    static let artist: UInt32 = 4
    static let genre: UInt32 = 5
    static let filetype: UInt32 = 6
    static let comment: UInt32 = 8
    static let category: UInt32 = 9
    static let composer: UInt32 = 12
    static let grouping: UInt32 = 13
    static let description: UInt32 = 14
    static let podcastURL: UInt32 = 15
    static let podcastRSS: UInt32 = 16
    static let chapterData: UInt32 = 17
    static let subtitle: UInt32 = 18
    static let tvShow: UInt32 = 19
    static let tvEpisode: UInt32 = 20
    static let tvNetwork: UInt32 = 21
    static let albumArtist: UInt32 = 22
    static let sortArtist: UInt32 = 23
    static let keywords: UInt32 = 24
    static let sortTitle: UInt32 = 27
    static let sortAlbum: UInt32 = 28
    static let sortAlbumArtist: UInt32 = 29
    static let sortComposer: UInt32 = 30
    static let sortTVShow: UInt32 = 31
    static let smartPlaylistPrefs: UInt32 = 50
    static let smartPlaylistRules: UInt32 = 51
    static let libraryPlaylistIndex: UInt32 = 52
    static let libraryPlaylistJumpTable: UInt32 = 53
    static let playlistPosition: UInt32 = 100
    static let albumListAlbum: UInt32 = 200
    static let albumListArtist: UInt32 = 201
    static let albumListSortArtist: UInt32 = 202
    static let artistListName: UInt32 = 300

    /// mhod types whose payload is a UTF-16 string with the standard 16-byte string header.
    static let stringTypes: Set<UInt32> = [1, 2, 3, 4, 5, 6, 8, 9, 12, 13, 14, 18, 19, 20, 21, 22, 23, 24, 27, 28, 29, 30, 31, 200, 201, 202, 300]
}

/// A track record (mhit) with its string objects.
struct IPodTrack: Identifiable, Hashable {
    /// Unique database id; persists across syncs and links to ArtworkDB.
    var dbid: UInt64
    var id: UInt64 { dbid }

    /// Transient id assigned when the database is written (mhit "track id"). Set by the reader/writer.
    var trackID: UInt32 = 0

    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var composer: String?
    var comment: String?
    var grouping: String?
    var description: String?
    var category: String?
    var subtitle: String?
    var podcastURL: String?
    var podcastRSS: String?
    var sortTitle: String?
    var sortArtist: String?
    var sortAlbum: String?
    var sortAlbumArtist: String?
    var sortComposer: String?
    var filetypeDescription: String?
    /// Path on the iPod using ':' separators, e.g. ":iPod_Control:Music:F03:ABCD.mp3"
    var ipodPath: String = ""

    var filetypeMarker: UInt32 = 0
    var type1: UInt8 = 0
    var type2: UInt8 = 0
    var compilation: UInt8 = 0
    /// 0-100 in steps of 20 (stars * 20)
    var rating: UInt8 = 0

    var timeModified: Date?
    var timeAdded: Date?
    var timePlayed: Date?
    var timeReleased: Date?
    var lastSkipped: Date?

    var fileSize: UInt32 = 0
    var durationMs: UInt32 = 0
    var trackNumber: UInt32 = 0
    var trackCount: UInt32 = 0
    var year: UInt32 = 0
    var bitrate: UInt32 = 0
    var sampleRate: UInt32 = 44100
    var volume: Int32 = 0
    var startTime: UInt32 = 0
    var stopTime: UInt32 = 0
    var soundCheck: UInt32 = 0
    var playCount: UInt32 = 0
    var playCount2: UInt32 = 0
    var discNumber: UInt32 = 0
    var discCount: UInt32 = 0
    var drmUserID: UInt32 = 0
    var bookmarkTimeMs: UInt32 = 0
    var checked: UInt8 = 0
    var appRating: UInt8 = 0
    var bpm: UInt16 = 0
    var artworkCount: UInt16 = 0
    var unk126: UInt16 = 0xFFFF
    var artworkSize: UInt32 = 0
    var unk132: UInt32 = 0
    var unk144: UInt16 = 0
    var explicitFlag: UInt16 = 0
    var unk148: UInt32 = 0
    var unk152: UInt32 = 0
    var skipCount: UInt32 = 0
    /// 0x01 has artwork, 0x02 no artwork
    var hasArtwork: UInt8 = 0x02
    var skipWhenShuffling: UInt8 = 0
    var rememberPlaybackPosition: UInt8 = 0
    var flag4: UInt8 = 0
    var dbid2: UInt64 = 0
    var lyricsFlag: UInt8 = 0
    var movieFlag: UInt8 = 0
    /// 0x02 = unplayed (podcast bullet), 0x01 = played / normal track
    var markUnplayed: UInt8 = 0x01
    var unk179: UInt8 = 0
    var unk180: UInt32 = 0
    var pregap: UInt32 = 0
    var sampleCount: UInt64 = 0
    var unk196: UInt32 = 0
    var postgap: UInt32 = 0
    var unk204: UInt32 = 0
    var mediaType: UInt32 = IPodMediaType.audio
    var seasonNumber: UInt32 = 0
    var episodeNumber: UInt32 = 0
    var gaplessData: UInt32 = 0
    var gaplessTrackFlag: UInt16 = 0
    var gaplessAlbumFlag: UInt16 = 0
    /// Image id in ArtworkDB (mhii) for this track; 0 when no artwork.
    var mhiiLink: UInt32 = 0

    /// Transient ids assigned during write (album/artist/composer lists).
    var albumID: UInt32 = 0
    var artistID: UInt32 = 0
    var composerID: UInt32 = 0

    init(dbid: UInt64) {
        self.dbid = dbid
        self.dbid2 = dbid
    }

    var isPodcast: Bool { mediaType & IPodMediaType.podcast != 0 }

    static func randomDBID() -> UInt64 {
        var v: UInt64 = 0
        repeat { v = UInt64.random(in: 1...UInt64.max) } while v == 0
        return v
    }

    /// Full path of the track's file on a mounted iPod volume.
    func fileURL(mountPoint: URL) -> URL? {
        var path = ipodPath
        if path.hasPrefix(":") { path.removeFirst() }
        if path.isEmpty { return nil }
        let components = path.split(separator: ":").map(String.init)
        var url = mountPoint
        for c in components { url.appendPathComponent(c) }
        return url
    }
}

struct IPodPlaylist: Identifiable, Hashable {
    var id: UInt64
    var name: String
    var isMaster: Bool = false
    var isPodcasts: Bool = false
    var isSmart: Bool = false
    var flag1: UInt8 = 0
    var flag2: UInt8 = 0
    var flag3: UInt8 = 0
    var sortOrder: UInt32 = 1
    var timestamp: Date?
    /// Members referenced by track dbid, in playlist order.
    var memberDBIDs: [UInt64] = []

    init(id: UInt64 = IPodTrack.randomDBID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// The whole iTunesDB.
struct ITunesDatabase {
    var tracks: [IPodTrack] = []
    /// Master playlist first.
    var playlists: [IPodPlaylist] = []
    var version: UInt32 = 0x30
    var databaseID: UInt64 = IPodTrack.randomDBID()
    var libraryPersistentID: UInt64 = IPodTrack.randomDBID()
    var id0x24: UInt64 = 0
    var platform: UInt16 = 1 // 1 = macOS, 2 = Windows
    var unk0x22: UInt16 = 0
    var language: UInt16 = 0x656E
    var unk0x50: UInt32 = 0
    var unk0x54: UInt32 = 0
    /// Time zone offset (seconds from GMT) used to translate timestamps.
    var tzOffset: Int32 = Int32(TimeZone.current.secondsFromGMT())
    var audioLanguage: UInt16 = 0
    var subtitleLanguage: UInt16 = 0

    init() {}

    var masterPlaylist: IPodPlaylist? { playlists.first(where: { $0.isMaster }) }

    var name: String {
        get { masterPlaylist?.name ?? "iPod" }
        set {
            if let idx = playlists.firstIndex(where: { $0.isMaster }) {
                playlists[idx].name = newValue
            } else {
                var mpl = IPodPlaylist(name: newValue)
                mpl.isMaster = true
                playlists.insert(mpl, at: 0)
            }
        }
    }

    var podcastPlaylist: IPodPlaylist? { playlists.first(where: { $0.isPodcasts }) }

    func track(dbid: UInt64) -> IPodTrack? { tracks.first(where: { $0.dbid == dbid }) }

    /// Creates a minimal database with an empty master playlist.
    static func empty(named name: String) -> ITunesDatabase {
        var db = ITunesDatabase()
        var mpl = IPodPlaylist(name: name)
        mpl.isMaster = true
        mpl.timestamp = Date()
        db.playlists = [mpl]
        return db
    }
}

/// File-type helpers shared by the writer and the sync engine.
enum IPodFileType {
    struct Info {
        let ext: String
        let description: String
        let marker: UInt32
        let type2: UInt8
        let unk144: UInt16
        let unk126: UInt16
        let isNative: Bool
    }

    /// Big-endian-looking marker stored in the little-endian field, e.g. "MP3 " -> 0x4D503320.
    static func marker(forExtension ext: String) -> UInt32 {
        var m: UInt32 = 0
        let chars = Array(ext.uppercased().utf8)
        for i in 0..<4 {
            m <<= 8
            if i < chars.count { m |= UInt32(chars[i]) } else { m |= 0x20 }
        }
        return m
    }

    static func info(forExtension rawExt: String, isLossless: Bool = false) -> Info {
        let ext = rawExt.lowercased()
        switch ext {
        case "mp3":
            return Info(ext: ext, description: "MPEG audio file", marker: marker(forExtension: "MP3"), type2: 1, unk144: 0x0C, unk126: 0xFFFF, isNative: true)
        case "m4a", "mp4", "aac":
            if isLossless {
                return Info(ext: "m4a", description: "Apple Lossless audio file", marker: marker(forExtension: "M4A"), type2: 0, unk144: 0x33, unk126: 0xFFFF, isNative: true)
            }
            return Info(ext: "m4a", description: "AAC audio file", marker: marker(forExtension: "M4A"), type2: 0, unk144: 0x33, unk126: 0xFFFF, isNative: true)
        case "m4b":
            return Info(ext: ext, description: "AAC audio file", marker: marker(forExtension: "M4B"), type2: 0, unk144: 0x33, unk126: 0xFFFF, isNative: true)
        case "m4p":
            return Info(ext: ext, description: "Protected AAC audio file", marker: marker(forExtension: "M4P"), type2: 0, unk144: 0x33, unk126: 0xFFFF, isNative: true)
        case "wav":
            return Info(ext: ext, description: "WAV audio file", marker: marker(forExtension: "WAV"), type2: 0, unk144: 0, unk126: 0, isNative: true)
        case "aif", "aiff", "aifc":
            return Info(ext: ext, description: "AIFF audio file", marker: marker(forExtension: "AIFF"), type2: 0, unk144: 0, unk126: 0, isNative: true)
        case "aa":
            return Info(ext: ext, description: "Audible file", marker: marker(forExtension: "AA"), type2: 0, unk144: 0x29, unk126: 1, isNative: true)
        default:
            return Info(ext: ext, description: "\(ext.uppercased()) audio file", marker: marker(forExtension: ext), type2: 0, unk144: 0, unk126: 0xFFFF, isNative: false)
        }
    }

    static let nativeExtensions: Set<String> = ["mp3", "m4a", "m4b", "m4p", "mp4", "aac", "wav", "aif", "aiff", "aifc", "aa"]
    /// Formats AVFoundation can decode that need transcoding to AAC before going onto the iPod.
    static let transcodableExtensions: Set<String> = ["flac", "caf", "ac3", "eac3", "amr", "3gp", "m4r", "mp2", "mp1", "snd", "au", "sd2", "w64", "ogg", "oga", "opus", "wma"]
}
