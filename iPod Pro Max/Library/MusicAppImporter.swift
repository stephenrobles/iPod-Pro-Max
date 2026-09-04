//
//  MusicAppImporter.swift
//  iPod Pro Max
//
//  Reads the Music app library (iTunesLibrary framework) so the user can choose what to import.
//  Apple Music subscription tracks are FairPlay-protected and can't play on an iPod; items that
//  live only in iCloud need to be downloaded in Music first.
//

import Foundation
import iTunesLibrary

enum MusicItemStatus: String {
    case ready
    case appleMusic
    case notDownloaded
    case protected
    case missingFile
    case video

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .appleMusic: return "Apple Music (protected)"
        case .notDownloaded: return "Not downloaded"
        case .protected: return "Protected (DRM)"
        case .missingFile: return "File missing"
        case .video: return "Video"
        }
    }

    var canImport: Bool { self == .ready || self == .video }
}

struct MusicAppItem: Identifiable, Hashable {
    let id: String              // persistent id (hex)
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?
    let genre: String?
    let composer: String?
    let comment: String?
    let grouping: String?
    let year: Int
    let trackNumber: Int
    let trackCount: Int
    let discNumber: Int
    let discCount: Int
    let durationMs: Int
    let bitrate: Int
    let sampleRate: Int
    let fileSize: Int64
    let isLossless: Bool
    let compilation: Bool
    let bpm: Int
    let rating: Int
    let playCount: Int
    let lastPlayed: Date?
    let dateAdded: Date
    let dateModified: Date?
    let location: URL?
    let status: MusicItemStatus
    let kindDescription: String
    let mediaKind: MediaKind
}

struct MusicAppPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let itemIDs: [String]
}

struct MusicAppCatalog {
    var items: [MusicAppItem] = []
    var playlists: [MusicAppPlaylist] = []

    var counts: [MusicItemStatus: Int] {
        var d: [MusicItemStatus: Int] = [:]
        for i in items { d[i.status, default: 0] += 1 }
        return d
    }
}

enum MusicAppImporter {
    /// Reads every song and video in the Music library with a status describing whether it can go on an iPod.
    static func loadCatalog() throws -> MusicAppCatalog {
        let library = try ITLibrary(apiVersion: "1.1")
        var catalog = MusicAppCatalog()
        var idSet = Set<String>()

        for item in library.allMediaItems {
            let kind: MediaKind
            switch item.mediaKind {
            case .kindSong: kind = .song
            case .kindMovie, .kindMusicVideo, .kindTVShow, .kindHomeVideo: kind = .video
            default: continue
            }
            let pid = MusicPID.normalize(String(item.persistentID.uint64Value, radix: 16, uppercase: true))
            if idSet.contains(pid) { continue }
            idSet.insert(pid)

            let status: MusicItemStatus
            let kindDesc = item.kind ?? ""
            let isAppleMusic = kindDesc.localizedCaseInsensitiveContains("Apple Music") || item.isDRMProtected && item.locationType != .file && kindDesc.isEmpty
            if item.isDRMProtected || kindDesc.localizedCaseInsensitiveContains("Apple Music") {
                status = isAppleMusic || kindDesc.localizedCaseInsensitiveContains("Apple Music") ? .appleMusic : .protected
            } else if item.locationType != .file {
                status = .notDownloaded
            } else if let url = item.location, FileManager.default.fileExists(atPath: url.path) {
                status = kind == .video ? .video : .ready
            } else {
                status = .missingFile
            }

            catalog.items.append(MusicAppItem(
                id: pid,
                title: item.title.isEmpty ? (item.location?.deletingPathExtension().lastPathComponent ?? "Untitled") : item.title,
                artist: item.artist?.name ?? "",
                album: item.album.title ?? "",
                albumArtist: item.album.albumArtist,
                genre: item.genre.isEmpty ? nil : item.genre,
                composer: item.composer.isEmpty ? nil : item.composer,
                comment: item.comments,
                grouping: item.grouping,
                year: item.year,
                trackNumber: item.trackNumber,
                trackCount: item.album.trackCount,
                discNumber: item.album.discNumber,
                discCount: item.album.discCount,
                durationMs: item.totalTime,
                bitrate: item.bitrate,
                sampleRate: item.sampleRate,
                fileSize: Int64(item.fileSize),
                isLossless: kindDesc.localizedCaseInsensitiveContains("lossless"),
                compilation: item.album.isCompilation,
                bpm: item.beatsPerMinute,
                rating: item.rating / 20,
                playCount: item.playCount,
                lastPlayed: item.lastPlayedDate,
                dateAdded: item.addedDate ?? Date(),
                dateModified: item.modifiedDate,
                location: item.location,
                status: status,
                kindDescription: kindDesc,
                mediaKind: kind))
        }

        for pl in library.allPlaylists {
            guard !pl.isPrimary, pl.kind == .regular || pl.kind == .smart, pl.distinguishedKind == .kindNone, pl.isVisible else { continue }
            let pid = MusicPID.normalize(String(pl.persistentID.uint64Value, radix: 16, uppercase: true))
            let ids = pl.items.map { MusicPID.normalize(String($0.persistentID.uint64Value, radix: 16, uppercase: true)) }
            guard !ids.isEmpty else { continue }
            catalog.playlists.append(MusicAppPlaylist(id: pid, name: pl.name, itemIDs: ids))
        }
        catalog.items.sort { ($0.artist, $0.album, $0.discNumber, $0.trackNumber, $0.title) < ($1.artist, $1.album, $1.discNumber, $1.trackNumber, $1.title) }
        return catalog
    }

    /// Artwork data for the given persistent ids (looked up again because ITLibArtwork isn't kept in the catalog).
    static func artwork(forPersistentIDs ids: Set<String>) -> [String: Data] {
        guard let library = try? ITLibrary(apiVersion: "1.1") else { return [:] }
        var out: [String: Data] = [:]
        for item in library.allMediaItems {
            let pid = MusicPID.normalize(String(item.persistentID.uint64Value, radix: 16, uppercase: true))
            guard ids.contains(pid) else { continue }
            if let data = item.artwork?.imageData, !data.isEmpty { out[pid] = data }
        }
        return out
    }

    static func makeTrack(from m: MusicAppItem, id: UUID) -> LibraryTrack? {
        guard let url = m.location else { return nil }
        var t = LibraryTrack(id: id, path: url.path, source: .musicApp, musicPersistentID: m.id, title: m.title, fileExtension: url.pathExtension.lowercased())
        t.kind = m.mediaKind
        t.artist = m.artist.isEmpty ? nil : m.artist
        t.album = m.album.isEmpty ? nil : m.album
        t.albumArtist = m.albumArtist
        t.genre = m.genre
        t.composer = m.composer
        t.comment = m.comment
        t.grouping = m.grouping
        t.year = m.year
        t.trackNumber = m.trackNumber
        t.trackCount = m.trackCount
        t.discNumber = m.discNumber
        t.discCount = m.discCount
        t.durationMs = m.durationMs
        t.bitrate = m.bitrate
        t.sampleRate = m.sampleRate
        t.fileSize = m.fileSize
        t.isLossless = m.isLossless
        t.compilation = m.compilation
        t.bpm = m.bpm
        t.rating = m.rating
        t.playCount = m.playCount
        t.lastPlayed = m.lastPlayed
        t.dateAdded = m.dateAdded
        t.dateModified = m.dateModified
        return t
    }
}
