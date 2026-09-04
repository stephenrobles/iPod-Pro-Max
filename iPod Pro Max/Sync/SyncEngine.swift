//
//  SyncEngine.swift
//  iPod Pro Max
//
//  Performs a sync: reads the iPod database and play counts, copies new songs and podcast episodes,
//  removes deselected ones, rebuilds playlists and artwork, and writes the database back.
//

import Foundation
import CoreGraphics

struct SyncOptions: Sendable {
    var removeUnknownTracks = true
    var writeArtwork = true
    var syncPodcasts = true
    var syncPhotos = true
    var maxParallelCopies = 1
}

struct SyncProgress: Sendable {
    var phase: String
    var detail: String = ""
    /// 0…1, or nil when indeterminate
    var fraction: Double?
}

struct SyncResult: Sendable {
    var record: DeviceSyncRecord
    var added = 0
    var removed = 0
    var kept = 0
    var failed: [String] = []
    var trackStats: [UUID: (playCount: Int, lastPlayed: Date?, rating: Int?)] = [:]
    var episodeStats: [UUID: (played: Bool, positionMs: Int)] = [:]
    var log: [String] = []
    var bytesCopied: Int64 = 0
    var photosWritten = 0
}

/// Immutable snapshot of what the library wants on the device.
struct SyncRequest: Sendable {
    var device: IPodDevice
    var record: DeviceSyncRecord
    var tracks: [LibraryTrack]
    var playlists: [LibraryPlaylist]
    var shows: [PodcastShow]
    var artworkDir: URL
    var transcodeDir: URL
    var photoCacheDir: URL
    var photoSelection: PhotoSelection
    var options: SyncOptions
}

enum SyncError: LocalizedError {
    case cancelled
    case notEnoughSpace(needed: Int64, available: Int64)
    case unsupportedDevice(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sync was cancelled."
        case .notEnoughSpace(let needed, let available):
            return "Not enough free space on the iPod. Needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) but only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is free."
        case .unsupportedDevice(let s): return s
        case .writeFailed(let s): return s
        }
    }
}

final class SyncEngine: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (SyncProgress) -> Void

    private let request: SyncRequest
    private let progress: ProgressHandler
    private var log: [String] = []
    private let musicFolderRoundRobin = RoundRobin()

    init(request: SyncRequest, progress: @escaping ProgressHandler) {
        self.request = request
        self.progress = progress
    }

    private func report(_ phase: String, _ detail: String = "", fraction: Double? = nil) {
        progress(SyncProgress(phase: phase, detail: detail, fraction: fraction))
    }

    private func note(_ s: String) {
        log.append(s)
    }

    private func checkCancelled() throws {
        if Task.isCancelled { throw SyncError.cancelled }
    }

    // MARK: - Run

    func run() async throws -> SyncResult {
        let device = request.device
        var record = request.record
        var result = SyncResult(record: record)
        let fm = FileManager.default

        switch device.supportLevel {
        case .unsupported:
            throw SyncError.unsupportedDevice("\(device.displayModelName) isn't supported by iPod Pro Max 1.0. iPod Video, iPod nano (1st/2nd gen), iPod photo, iPod mini and older click-wheel iPods work today.")
        default: break
        }

        // 1. Read the database and play counts.
        report("Reading iPod", "Opening the iPod database…")
        var db = try device.readDatabase()
        note("Read \(db.tracks.count) tracks and \(db.playlists.count) playlists from the iPod.")
        try importPlayCounts(device: device, db: &db, record: record, result: &result)

        // 2. Figure out what should be on the device.
        report("Planning", "Comparing library and iPod…")
        let dbidsOnDevice = Set(db.tracks.map(\.dbid))
        let ourDBIDs = Set(record.trackDBIDs.values).union(record.episodeDBIDs.values)

        struct Add {
            let libraryTrack: LibraryTrack?
            let episode: (show: PodcastShow, ep: PodcastEpisode)?
            let source: URL
            let estimatedSize: Int64
        }
        var adds: [Add] = []
        var desiredDBIDs = Set<UInt64>()
        var trackIDByDBID: [UInt64: UUID] = [:]
        var episodeIDByDBID: [UInt64: UUID] = [:]

        for t in request.tracks {
            guard t.fileExists else {
                result.failed.append("Missing file: \(t.title)")
                continue
            }
            if let dbid = record.trackDBIDs[t.id], dbidsOnDevice.contains(dbid), deviceFileExists(db, dbid: dbid) {
                desiredDBIDs.insert(dbid)
                trackIDByDBID[dbid] = t.id
                continue
            }
            let estimate: Int64
            if t.isVideo {
                estimate = Int64(Double(t.durationMs) / 1000 * Double(VideoTranscoder.videoBitrate + VideoTranscoder.audioBitrate) / 8)
            } else if t.needsTranscode {
                estimate = Int64(Double(t.durationMs) / 1000 * 256_000 / 8)
            } else {
                estimate = t.fileSize
            }
            adds.append(Add(libraryTrack: t, episode: nil, source: t.url, estimatedSize: max(estimate, 1)))
        }

        if request.options.syncPodcasts && device.supportsPodcasts && record.syncPodcasts {
            for show in request.shows {
                for ep in show.episodesToSync() where ep.isDownloaded {
                    if let dbid = record.episodeDBIDs[ep.id], dbidsOnDevice.contains(dbid), deviceFileExists(db, dbid: dbid) {
                        desiredDBIDs.insert(dbid)
                        episodeIDByDBID[dbid] = ep.id
                        continue
                    }
                    let size = ep.fileSize ?? (try? ep.localURL!.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                    adds.append(Add(libraryTrack: nil, episode: (show, ep), source: ep.localURL!, estimatedSize: max(size, 1)))
                }
            }
        }

        // 3. Removals.
        var removals: [IPodTrack] = []
        for t in db.tracks where !desiredDBIDs.contains(t.dbid) {
            if ourDBIDs.contains(t.dbid) {
                removals.append(t)
            } else if request.options.removeUnknownTracks {
                removals.append(t)
            } else {
                result.kept += 1
            }
        }

        // 4. Space check.
        let stats = device.volumeStats()
        let bytesFreed = removals.reduce(Int64(0)) { $0 + Int64($1.fileSize) }
        var bytesNeeded = adds.reduce(Int64(0)) { $0 + $1.estimatedSize }
        let wantPhotos = request.options.syncPhotos && record.photosEnabled && device.generation.supportsPhotos && !request.photoSelection.isEmpty
        if wantPhotos {
            let perPhoto = device.generation.photoFormats.reduce(0) { $0 + $1.bytesPerImage }
            bytesNeeded += Int64(perPhoto) * Int64(estimatedPhotoCount())
        }
        let margin: Int64 = 48 * 1024 * 1024
        if stats.total > 0, bytesNeeded + margin > stats.free + bytesFreed {
            throw SyncError.notEnoughSpace(needed: bytesNeeded + margin, available: stats.free + bytesFreed)
        }
        note("Plan: add \(adds.count), remove \(removals.count), keep \(desiredDBIDs.count).")

        // 5. Remove tracks.
        if !removals.isEmpty {
            report("Removing", "Removing \(removals.count) item\(removals.count == 1 ? "" : "s")…", fraction: 0)
            let removedIDs = Set(removals.map(\.dbid))
            for (i, t) in removals.enumerated() {
                try checkCancelled()
                if let url = t.fileURL(mountPoint: device.mountPoint), fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
                report("Removing", t.title ?? "", fraction: Double(i + 1) / Double(removals.count))
            }
            db.tracks.removeAll { removedIDs.contains($0.dbid) }
            for i in db.playlists.indices { db.playlists[i].memberDBIDs.removeAll { removedIDs.contains($0) } }
            result.removed = removals.count
            record.trackDBIDs = record.trackDBIDs.filter { !removedIDs.contains($0.value) }
            record.episodeDBIDs = record.episodeDBIDs.filter { !removedIDs.contains($0.value) }
        }

        // 6. Copy new items.
        try ensureMusicFolders(device: device)
        let folderCount = device.musicFolderCount()
        var copied: Int64 = 0
        for (i, add) in adds.enumerated() {
            try checkCancelled()
            let name = add.libraryTrack?.title ?? add.episode?.ep.title ?? add.source.lastPathComponent
            report("Copying", "\(i + 1) of \(adds.count): \(name)", fraction: bytesNeeded > 0 ? Double(copied) / Double(bytesNeeded) : nil)
            do {
                var source = add.source
                var ext = source.pathExtension.lowercased()
                if let t = add.libraryTrack, t.isVideo {
                    let base = bytesNeeded > 0 ? Double(copied) / Double(bytesNeeded) : 0
                    let share = bytesNeeded > 0 ? Double(add.estimatedSize) / Double(bytesNeeded) : 0
                    let label = "\(i + 1) of \(adds.count): \(name)"
                    let handler = progress
                    source = try await VideoTranscoder.cachedIPodVideo(for: t, cacheDir: request.transcodeDir) { f in
                        handler(SyncProgress(phase: "Converting video", detail: "\(label) — \(Int(f * 100))%", fraction: base + share * f))
                    }
                    ext = "m4v"
                } else if let t = add.libraryTrack, t.needsTranscode {
                    report("Converting", "\(i + 1) of \(adds.count): \(name)", fraction: bytesNeeded > 0 ? Double(copied) / Double(bytesNeeded) : nil)
                    source = try await Transcoder.cachedAAC(for: t, cacheDir: request.transcodeDir)
                    ext = "m4a"
                }
                let (ipodPath, destURL) = try allocateDestination(device: device, folderCount: folderCount, ext: ext)
                try fm.copyItem(at: source, to: destURL)
                let realSize = (try? destURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? add.estimatedSize
                copied += add.estimatedSize
                result.bytesCopied += realSize

                var track: IPodTrack
                if let t = add.libraryTrack {
                    track = makeTrack(from: t, ipodPath: ipodPath, fileSize: UInt32(clamping: realSize), extOnDevice: ext)
                    record.trackDBIDs[t.id] = track.dbid
                    trackIDByDBID[track.dbid] = t.id
                } else if let (show, ep) = add.episode {
                    track = makeTrack(show: show, episode: ep, ipodPath: ipodPath, fileSize: UInt32(clamping: realSize), extOnDevice: ext)
                    record.episodeDBIDs[ep.id] = track.dbid
                    episodeIDByDBID[track.dbid] = ep.id
                } else { continue }
                db.tracks.append(track)
                desiredDBIDs.insert(track.dbid)
                result.added += 1
            } catch let e as SyncError {
                throw e
            } catch {
                result.failed.append("\(name): \(error.localizedDescription)")
                note("Failed: \(name) — \(error.localizedDescription)")
            }
        }

        // 7. Refresh mutable metadata on tracks we manage.
        let libraryByID = Dictionary(request.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var episodeByID: [UUID: (PodcastShow, PodcastEpisode)] = [:]
        for s in request.shows { for e in s.episodes { episodeByID[e.id] = (s, e) } }
        for i in db.tracks.indices {
            let dbid = db.tracks[i].dbid
            if let tid = trackIDByDBID[dbid], let lt = libraryByID[tid] {
                if lt.rating > 0 { db.tracks[i].rating = UInt8(lt.rating * 20) }
                db.tracks[i].title = lt.title
                db.tracks[i].artist = lt.artist
                db.tracks[i].album = lt.album
                db.tracks[i].albumArtist = lt.albumArtist
                db.tracks[i].genre = lt.genre
                db.tracks[i].composer = lt.composer
                db.tracks[i].year = UInt32(max(lt.year, 0))
                db.tracks[i].trackNumber = UInt32(max(lt.trackNumber, 0))
                db.tracks[i].trackCount = UInt32(max(lt.trackCount, 0))
                db.tracks[i].discNumber = UInt32(max(lt.discNumber, 0))
                db.tracks[i].discCount = UInt32(max(lt.discCount, 0))
                db.tracks[i].compilation = lt.compilation ? 1 : 0
            } else if let eid = episodeIDByDBID[dbid], let (show, ep) = episodeByID[eid] {
                db.tracks[i].title = ep.title
                db.tracks[i].album = show.title
                db.tracks[i].artist = show.author ?? show.title
                db.tracks[i].markUnplayed = ep.played ? 0x01 : 0x02
                if ep.playbackPositionMs > 0 { db.tracks[i].bookmarkTimeMs = UInt32(ep.playbackPositionMs) }
            }
        }

        // 8. Playlists.
        report("Playlists", "Rebuilding playlists…")
        rebuildPlaylists(db: &db, record: &record, trackIDByDBID: trackIDByDBID, episodeIDByDBID: episodeIDByDBID)

        // 9. Artwork.
        if request.options.writeArtwork && device.supportsArtwork {
            report("Artwork", "Preparing album art…", fraction: 0)
            try writeArtwork(device: device, db: &db, trackIDByDBID: trackIDByDBID, episodeIDByDBID: episodeIDByDBID, libraryByID: libraryByID, episodeByID: episodeByID)
        } else {
            for i in db.tracks.indices { db.tracks[i].hasArtwork = 0x02; db.tracks[i].mhiiLink = 0; db.tracks[i].artworkCount = 0 }
        }

        // 10. Photos.
        if wantPhotos {
            do {
                result.photosWritten = try writePhotos(device: device, tzOffset: db.tzOffset)
            } catch {
                note("Photos failed: \(error.localizedDescription)")
                result.failed.append("Photos: \(error.localizedDescription)")
            }
        } else if request.options.syncPhotos && record.photosEnabled && device.generation.supportsPhotos && request.photoSelection.isEmpty {
            // Nothing selected: leave whatever photos are on the iPod alone.
        }

        // 11. Write the database.
        report("Finishing", "Writing the iPod database…")
        try checkCancelledForWrite()
        let writer = ITunesDBWriter(database: db, checksum: device.checksumType, firewireID: device.firewireIDBytes)
        let output = try writer.write()
        try fm.createDirectory(at: device.iTunesDir, withIntermediateDirectories: true)
        let tmp = device.iTunesDir.appendingPathComponent("iTunesDB.ipodpromax.tmp")
        try output.data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: device.iTunesDBURL.path) {
            _ = try fm.replaceItemAt(device.iTunesDBURL, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: device.iTunesDBURL)
        }
        // Old-style extra files that would confuse the firmware if left stale.
        for stale in ["iTunesDB.ext", "iTunesCDB"] {
            let u = device.iTunesDir.appendingPathComponent(stale)
            if fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u) }
        }
        note("Wrote iTunesDB (\(output.data.count) bytes, \(db.tracks.count) tracks, \(db.playlists.count) playlists).")

        record.lastSync = Date()
        record.deviceName = db.name
        result.record = record
        result.log = log
        report("Done", "Sync complete.", fraction: 1)
        return result
    }

    private func checkCancelledForWrite() throws {
        // Once files are on the device we still write the database so it stays consistent.
    }

    // MARK: - Play counts

    private func importPlayCounts(device: IPodDevice, db: inout ITunesDatabase, record: DeviceSyncRecord, result: inout SyncResult) throws {
        guard let data = try? Data(contentsOf: device.playCountsURL), !data.isEmpty else { return }
        do {
            let entries = try PlayCountsFile.parse(data, tzOffset: db.tzOffset)
            let trackIDByDBID = Dictionary(record.trackDBIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
            let episodeIDByDBID = Dictionary(record.episodeDBIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
            for (i, e) in entries.enumerated() where i < db.tracks.count {
                let dbid = db.tracks[i].dbid
                if let tid = trackIDByDBID[dbid], e.playCount > 0 || (e.rating ?? 0) > 0 {
                    result.trackStats[tid] = (Int(e.playCount), e.timePlayed, e.rating.map { Int($0 / 20) })
                }
                if let eid = episodeIDByDBID[dbid] {
                    let played = e.playCount > 0 || db.tracks[i].markUnplayed == 0x01
                    if played || e.bookmarkTimeMs > 0 {
                        result.episodeStats[eid] = (played, Int(e.bookmarkTimeMs))
                    }
                }
            }
            PlayCountsFile.apply(entries, to: &db.tracks)
            note("Imported play counts for \(entries.count) tracks.")
            try? FileManager.default.removeItem(at: device.playCountsURL)
        } catch {
            note("Play Counts file could not be read: \(error.localizedDescription)")
        }
    }

    // MARK: - Files

    private func deviceFileExists(_ db: ITunesDatabase, dbid: UInt64) -> Bool {
        guard let t = db.track(dbid: dbid), let url = t.fileURL(mountPoint: request.device.mountPoint) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func ensureMusicFolders(device: IPodDevice) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: device.musicDir, withIntermediateDirectories: true)
        if device.musicFolderCount() == 0 {
            for i in 0..<device.generation.defaultMusicFolderCount {
                try fm.createDirectory(at: device.musicDir.appendingPathComponent(String(format: "F%02d", i)), withIntermediateDirectories: true)
            }
        }
    }

    private func allocateDestination(device: IPodDevice, folderCount: Int, ext: String) throws -> (ipodPath: String, url: URL) {
        let count = max(folderCount, 1)
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for _ in 0..<64 {
            let folder = String(format: "F%02d", musicFolderRoundRobin.next(modulo: count))
            let name = String((0..<4).map { _ in letters.randomElement()! }) + "." + ext
            let url = device.musicDir.appendingPathComponent(folder).appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                return (":iPod_Control:Music:\(folder):\(name)", url)
            }
        }
        throw SyncError.writeFailed("Couldn't find a free file name on the iPod.")
    }

    // MARK: - Track construction

    private func makeTrack(from t: LibraryTrack, ipodPath: String, fileSize: UInt32, extOnDevice: String) -> IPodTrack {
        var track = IPodTrack(dbid: IPodTrack.randomDBID())
        if t.isVideo { return makeVideoTrack(from: t, ipodPath: ipodPath, fileSize: fileSize) }
        let info = IPodFileType.info(forExtension: extOnDevice, isLossless: t.isLossless && !t.needsTranscode)
        track.title = t.title
        track.artist = t.artist
        track.album = t.album
        track.albumArtist = t.albumArtist
        track.genre = t.genre
        track.composer = t.composer
        track.comment = t.comment
        track.grouping = t.grouping
        track.ipodPath = ipodPath
        track.filetypeDescription = info.description
        track.filetypeMarker = info.marker
        track.type1 = 0
        track.type2 = info.type2
        track.unk144 = info.unk144
        track.unk126 = info.unk126
        track.compilation = t.compilation ? 1 : 0
        track.rating = UInt8(min(max(t.rating, 0), 5) * 20)
        track.timeModified = t.dateModified ?? Date()
        track.timeAdded = Date()
        track.timePlayed = t.lastPlayed
        track.fileSize = fileSize
        track.durationMs = UInt32(max(t.durationMs, 0))
        track.trackNumber = UInt32(max(t.trackNumber, 0))
        track.trackCount = UInt32(max(t.trackCount, 0))
        track.discNumber = UInt32(max(t.discNumber, 0))
        track.discCount = UInt32(max(t.discCount, 0))
        track.year = UInt32(max(t.year, 0))
        track.bitrate = UInt32(max(t.needsTranscode ? 256 : t.bitrate, 0))
        track.sampleRate = UInt32(max(t.sampleRate, 8000))
        track.playCount = UInt32(max(t.playCount, 0))
        track.playCount2 = track.playCount
        track.bpm = UInt16(clamping: max(t.bpm, 0))
        track.mediaType = IPodMediaType.audio
        track.markUnplayed = 0x01
        track.hasArtwork = 0x02
        track.sortArtist = SortKey.articleAware(t.artist).flatMap { $0 == t.artist ? nil : $0 }
        return track
    }

    private func makeVideoTrack(from t: LibraryTrack, ipodPath: String, fileSize: UInt32) -> IPodTrack {
        var track = IPodTrack(dbid: IPodTrack.randomDBID())
        track.title = t.title
        track.artist = t.artist
        track.album = t.album
        track.genre = t.genre
        track.comment = t.comment
        track.ipodPath = ipodPath
        track.filetypeDescription = "MPEG-4 video file"
        track.filetypeMarker = IPodFileType.marker(forExtension: "M4V")
        track.type1 = 0
        track.type2 = 0
        track.unk144 = 0x33
        track.unk126 = 0xFFFF
        track.timeModified = t.dateModified ?? Date()
        track.timeAdded = Date()
        track.fileSize = fileSize
        track.durationMs = UInt32(max(t.durationMs, 0))
        track.year = UInt32(max(t.year, 0))
        track.bitrate = t.durationMs > 0 ? UInt32(Double(fileSize) * 8 / Double(t.durationMs)) : 0
        track.sampleRate = 44100
        track.mediaType = IPodMediaType.movie
        track.movieFlag = 1
        track.markUnplayed = 0x01
        track.hasArtwork = 0x02
        return track
    }

    private func makeTrack(show: PodcastShow, episode ep: PodcastEpisode, ipodPath: String, fileSize: UInt32, extOnDevice: String) -> IPodTrack {
        var track = IPodTrack(dbid: IPodTrack.randomDBID())
        let info = IPodFileType.info(forExtension: extOnDevice)
        track.title = ep.title
        track.album = show.title
        track.artist = show.author ?? show.title
        track.albumArtist = show.author
        track.genre = "Podcast"
        track.description = ep.summary.map { String($0.prefix(4000)) }
        track.ipodPath = ipodPath
        track.filetypeDescription = info.description
        track.filetypeMarker = info.marker
        track.type2 = info.type2
        track.unk144 = info.unk144
        track.unk126 = info.unk126
        track.timeModified = Date()
        track.timeAdded = Date()
        track.timeReleased = ep.publishedAt
        track.fileSize = fileSize
        track.durationMs = UInt32(max(ep.durationMs ?? 0, 0))
        track.bitrate = ep.durationMs.map { $0 > 0 ? UInt32(Double(fileSize) * 8 / Double($0)) : 0 } ?? 0
        track.sampleRate = 44100
        track.mediaType = IPodMediaType.podcast
        track.flag4 = 0x01
        track.skipWhenShuffling = 1
        track.rememberPlaybackPosition = 1
        track.markUnplayed = ep.played ? 0x01 : 0x02
        track.bookmarkTimeMs = UInt32(max(ep.playbackPositionMs, 0))
        track.podcastURL = ep.enclosureURL.absoluteString
        track.podcastRSS = show.feedURL.absoluteString
        track.episodeNumber = UInt32(max(ep.episodeNumber ?? 0, 0))
        track.seasonNumber = UInt32(max(ep.seasonNumber ?? 0, 0))
        track.hasArtwork = 0x02
        return track
    }

    // MARK: - Playlists

    private func rebuildPlaylists(db: inout ITunesDatabase, record: inout DeviceSyncRecord, trackIDByDBID: [UInt64: UUID], episodeIDByDBID: [UInt64: UUID]) {
        let ourPlaylistIDs = Set(record.playlistIDs.values)
        var kept = db.playlists.filter { $0.isMaster || (!ourPlaylistIDs.contains($0.id) && !$0.isPodcasts && !$0.isSmart) }
        if kept.first(where: { $0.isMaster }) == nil {
            var mpl = IPodPlaylist(name: request.device.volumeName)
            mpl.isMaster = true
            kept.insert(mpl, at: 0)
        }
        let existingPodcastPL = db.playlists.first { $0.isPodcasts }

        // Library playlists
        var newPlaylistIDs: [UUID: UInt64] = [:]
        let dbidByTrackID = Dictionary(trackIDByDBID.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        for pl in request.playlists {
            let members = pl.trackIDs.compactMap { dbidByTrackID[$0] }
            guard !members.isEmpty else { continue }
            var ip = IPodPlaylist(id: record.playlistIDs[pl.id] ?? IPodTrack.randomDBID(), name: pl.name)
            ip.memberDBIDs = members
            ip.timestamp = pl.dateCreated
            ip.sortOrder = 1
            kept.append(ip)
            newPlaylistIDs[pl.id] = ip.id
        }
        record.playlistIDs = newPlaylistIDs

        // Podcasts playlist: newest first, grouped by show.
        let podcastTracks = db.tracks.filter { $0.isPodcast }
        if !podcastTracks.isEmpty {
            var pp = existingPodcastPL ?? IPodPlaylist(name: "Podcasts")
            pp.isPodcasts = true
            pp.isSmart = false
            pp.sortOrder = 1
            let sorted = podcastTracks.sorted { a, b in
                if a.album != b.album { return (a.album ?? "") < (b.album ?? "") }
                return (a.timeReleased ?? .distantPast) > (b.timeReleased ?? .distantPast)
            }
            pp.memberDBIDs = sorted.map(\.dbid)
            kept.append(pp)
        }
        db.playlists = kept
    }

    // MARK: - Artwork

    private func writeArtwork(device: IPodDevice, db: inout ITunesDatabase, trackIDByDBID: [UInt64: UUID], episodeIDByDBID: [UInt64: UUID],
                              libraryByID: [UUID: LibraryTrack], episodeByID: [UUID: (PodcastShow, PodcastEpisode)]) throws {
        let formats = device.coverArtFormats
        let writer = IThumbWriter(artworkDir: device.artworkDir, formats: formats)
        try writer.removeExistingFiles()
        var entries: [ArtworkEntry] = []
        var nextID = ArtworkDBWriter.firstImageID
        var sizeCache: [String: UInt32] = [:]
        var imageCache: [String: CGImage] = [:]
        let total = db.tracks.count

        for i in db.tracks.indices {
            if i % 20 == 0 { report("Artwork", "\(i) of \(total)", fraction: Double(i) / Double(max(total, 1))) }
            let dbid = db.tracks[i].dbid
            var key: String? = nil
            if let tid = trackIDByDBID[dbid] { key = libraryByID[tid]?.artworkKey }
            else if let eid = episodeIDByDBID[dbid] { key = episodeByID[eid]?.0.artworkKey }
            guard let key else {
                db.tracks[i].hasArtwork = 0x02
                db.tracks[i].mhiiLink = 0
                db.tracks[i].artworkCount = 0
                continue
            }
            let url = request.artworkDir.appendingPathComponent("\(key).jpg")
            var image = imageCache[key]
            if image == nil, let img = ImageLoading.cgImage(from: url) {
                image = img
                if imageCache.count < 64 { imageCache[key] = img }
            }
            guard let image else {
                db.tracks[i].hasArtwork = 0x02
                db.tracks[i].mhiiLink = 0
                continue
            }
            let thumbs: [ThumbnailRef]
            do {
                thumbs = try writer.thumbnails(forKey: key, image: image)
            } catch {
                note("Artwork failed for \(db.tracks[i].title ?? ""): \(error.localizedDescription)")
                db.tracks[i].hasArtwork = 0x02
                continue
            }
            let size = sizeCache[key] ?? UInt32((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            sizeCache[key] = size
            let imageID = nextID
            nextID += 1
            entries.append(ArtworkEntry(imageID: imageID, trackDBID: dbid, originalImageSize: size, thumbnails: thumbs))
            db.tracks[i].hasArtwork = 0x01
            db.tracks[i].artworkCount = 1
            db.tracks[i].artworkSize = size
            db.tracks[i].mhiiLink = imageID
        }
        writer.finish()
        let data = ArtworkDBWriter.write(entries: entries, formats: formats, tzOffset: db.tzOffset)
        try FileManager.default.createDirectory(at: device.artworkDir, withIntermediateDirectories: true)
        try data.write(to: device.artworkDBURL, options: .atomic)
        note("Wrote artwork for \(entries.count) tracks (\(writer.uniqueImageCount) unique images).")
    }
}

extension SyncEngine {
    /// Rough count used only for the free-space check.
    fileprivate func estimatedPhotoCount() -> Int {
        guard PhotosAccess.isAuthorized else { return 0 }
        var n = 0
        if request.photoSelection.includeAllPhotos { n += PhotosAccess.allPhotosCount() }
        let albums = PhotosAccess.albums()
        for a in albums where request.photoSelection.albumIDs.contains(a.id) { n += a.count }
        return n
    }

    fileprivate func writePhotos(device: IPodDevice, tzOffset: Int32) throws -> Int {
        guard PhotosAccess.isAuthorized else {
            throw IPodDBError.unsupported("iPod Pro Max doesn't have permission to read your Photos library. Allow it in System Settings › Privacy & Security › Photos.")
        }
        report("Photos", "Exporting photos from the Photos app…", fraction: 0)
        let export = try PhotosAccess.export(selection: request.photoSelection, cacheDir: request.photoCacheDir) { done, total in
            if done % 5 == 0 { self.report("Photos", "Exporting \(done) of \(total)", fraction: total > 0 ? Double(done) / Double(total) * 0.5 : nil) }
        }
        let writer = PhotoDBWriter(mountPoint: device.mountPoint, formats: device.generation.photoFormats)
        let albums = export.albums.map { PhotoAlbumItem(name: $0.name, photoKeys: $0.photoKeys) }
        let count = try writer.write(photos: export.photos, albums: albums, tzOffset: tzOffset) { done, total in
            if done % 5 == 0 { self.report("Photos", "Writing \(done) of \(total) to the iPod", fraction: total > 0 ? 0.5 + Double(done) / Double(total) * 0.5 : nil) }
        }
        PhotosAccess.pruneCache(request.photoCacheDir, keep: Set(export.photos.map(\.key)))
        note("Wrote \(count) photos in \(albums.count) album\(albums.count == 1 ? "" : "s")" + (export.failed > 0 ? " (\(export.failed) could not be exported)" : "") + ".")
        return count
    }
}

final class RoundRobin: @unchecked Sendable {
    private var counter = Int.random(in: 0..<1000)
    func next(modulo: Int) -> Int {
        counter += 1
        return counter % max(modulo, 1)
    }
}

// MARK: - Import from iPod

enum IPodImporter {
    /// Copies every track on the iPod into `destination`/Artist/Album/ and returns the copied files.
    static func importAll(from device: IPodDevice, to destination: URL, progress: @Sendable (Int, Int) -> Void) throws -> [URL] {
        let db = try device.readDatabase()
        let fm = FileManager.default
        var out: [URL] = []
        let tracks = db.tracks
        for (i, t) in tracks.enumerated() {
            progress(i, tracks.count)
            guard let src = t.fileURL(mountPoint: device.mountPoint), fm.fileExists(atPath: src.path) else { continue }
            let artist = sanitize(t.isPodcast ? "Podcasts" : (t.albumArtist ?? t.artist ?? "Unknown Artist"))
            let album = sanitize(t.album ?? "Unknown Album")
            let dir = destination.appendingPathComponent(artist).appendingPathComponent(album)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var name = ""
            if t.trackNumber > 0 { name += String(format: "%02d ", t.trackNumber) }
            name += sanitize(t.title ?? src.deletingPathExtension().lastPathComponent)
            var dest = dir.appendingPathComponent(name).appendingPathExtension(src.pathExtension)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(name) \(n)").appendingPathExtension(src.pathExtension)
                n += 1
            }
            try fm.copyItem(at: src, to: dest)
            out.append(dest)
        }
        progress(tracks.count, tracks.count)
        return out
    }

    private static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?*\"<>|")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(120))
    }
}
