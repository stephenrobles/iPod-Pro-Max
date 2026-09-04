//
//  LibraryStore.swift
//  iPod Pro Max
//
//  Owns the app library (songs, playlists, podcasts, per-iPod sync records) and persists it as JSON
//  under ~/Library/Application Support/iPod Pro Max.
//

import Foundation
import Observation
import CryptoKit
import AppKit

@MainActor
@Observable
final class LibraryStore {
    var tracks: [LibraryTrack] = []
    var playlists: [LibraryPlaylist] = []
    var shows: [PodcastShow] = []
    var deviceRecords: [String: DeviceSyncRecord] = [:]
    var photoSelection = PhotoSelection()

    // Transient UI state
    var isImporting = false
    var importStatus: String?
    var importProgress: Double?
    var downloadProgress: [UUID: Double] = [:]
    var refreshingShows: Set<UUID> = []
    var lastError: String?

    let baseDir: URL
    let artworkDir: URL
    let podcastsDir: URL
    let transcodeDir: URL
    let photoCacheDir: URL
    private let documentURL: URL
    private var saveTask: Task<Void, Never>?
    private var activeDownloads: [UUID: Task<Void, Never>] = [:]

    init(baseDir: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Development aid: `-libraryDir /path` uses a different library for this launch only.
        let override = UserDefaults.standard.string(forKey: "libraryDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let base = baseDir ?? override ?? support.appendingPathComponent("iPod Pro Max", isDirectory: true)
        self.baseDir = base
        artworkDir = base.appendingPathComponent("Artwork", isDirectory: true)
        podcastsDir = base.appendingPathComponent("Podcasts", isDirectory: true)
        transcodeDir = base.appendingPathComponent("Transcodes", isDirectory: true)
        photoCacheDir = base.appendingPathComponent("PhotoCache", isDirectory: true)
        documentURL = base.appendingPathComponent("library.json")
        for d in [base, artworkDir, podcastsDir, transcodeDir, photoCacheDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: documentURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let doc = try decoder.decode(LibraryDocument.self, from: data)
            tracks = doc.tracks
            playlists = doc.playlists
            shows = doc.shows
            deviceRecords = doc.deviceRecords
            photoSelection = doc.photoSelection ?? PhotoSelection()
        } catch {
            lastError = "Couldn't read the library file: \(error.localizedDescription)"
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let doc = LibraryDocument(tracks: tracks, playlists: playlists, shows: shows, deviceRecords: deviceRecords, photoSelection: photoSelection)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(doc)
            let tmp = documentURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(documentURL, withItemAt: tmp)
        } catch {
            lastError = "Couldn't save the library: \(error.localizedDescription)"
        }
    }

    // MARK: - Artwork

    func artworkURL(for key: String) -> URL {
        artworkDir.appendingPathComponent("\(key).jpg")
    }

    /// Stores artwork (re-encoded as JPEG, max 600px) and returns its key. Thread-safe file work is done inline.
    nonisolated static func storeArtwork(_ data: Data, in artworkDir: URL) -> String? {
        guard let image = ImageLoading.cgImage(from: data) else { return nil }
        guard let jpeg = ImageLoading.jpegData(from: image) else { return nil }
        let digest = SHA256.hash(data: jpeg)
        let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = artworkDir.appendingPathComponent("\(key).jpg")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? jpeg.write(to: url, options: .atomic)
        }
        return key
    }

    func storeArtwork(_ data: Data) -> String? {
        Self.storeArtwork(data, in: artworkDir)
    }

    func artworkImage(for key: String?) -> NSImage? {
        guard let key else { return nil }
        return NSImage(contentsOf: artworkURL(for: key))
    }

    // MARK: - Tracks

    var songs: [LibraryTrack] { tracks.filter { !$0.isVideo } }
    var videos: [LibraryTrack] { tracks.filter { $0.isVideo } }

    func track(id: UUID) -> LibraryTrack? { tracks.first { $0.id == id } }

    func updatePhotoSelection(_ sel: PhotoSelection) {
        photoSelection = sel
        scheduleSave()
    }

    func removeTracks(ids: Set<UUID>) {
        tracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
        scheduleSave()
    }

    func setSync(_ enabled: Bool, forTracks ids: Set<UUID>) {
        for i in tracks.indices where ids.contains(tracks[i].id) { tracks[i].syncEnabled = enabled }
        scheduleSave()
    }

    /// Imports audio and video files (folders are searched recursively). Returns the number of items added.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> Int {
        isImporting = true
        importStatus = "Looking for media files…"
        importProgress = nil
        defer {
            isImporting = false
            importStatus = nil
            importProgress = nil
        }
        let files = await Task.detached(priority: .userInitiated) { Self.collectAudioFiles(urls) }.value
        let existing = Set(tracks.map(\.path))
        let toImport = files.filter { !existing.contains($0.path) }
        guard !toImport.isEmpty else { return 0 }

        var added = 0
        let artworkDir = self.artworkDir
        for (i, url) in toImport.enumerated() {
            importStatus = "Importing \(url.lastPathComponent)"
            importProgress = Double(i) / Double(toImport.count)
            let result: (LibraryTrack, String?)? = await Task.detached(priority: .userInitiated) {
                let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if VideoTranscoder.isVideoFile(url) {
                    guard let info = try? await VideoTranscoder.info(for: url) else { return nil }
                    let md = try? await MetadataExtractor.extract(from: url)
                    var t = LibraryTrack(path: url.path, title: md?.title ?? url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension.lowercased())
                    t.kind = .video
                    t.videoWidth = info.width
                    t.videoHeight = info.height
                    t.durationMs = info.durationMs
                    t.artist = md?.artist
                    t.album = md?.album
                    t.genre = md?.genre
                    t.year = md?.year ?? 0
                    t.fileSize = Int64(attrs?.fileSize ?? 0)
                    t.bitrate = info.durationMs > 0 ? Int(Double(t.fileSize) * 8 / Double(info.durationMs)) : 0
                    t.dateModified = attrs?.contentModificationDate
                    var art = md?.artworkData
                    if art == nil { art = await VideoTranscoder.posterFrame(for: url) }
                    let key = art.flatMap { Self.storeArtwork($0, in: artworkDir) }
                    return (t, key)
                }
                guard let md = try? await MetadataExtractor.extract(from: url) else { return nil }
                var t = LibraryTrack(path: url.path, title: md.title ?? url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension.lowercased())
                t.artist = md.artist
                t.album = md.album
                t.albumArtist = md.albumArtist
                t.genre = md.genre
                t.composer = md.composer
                t.comment = md.comment
                t.grouping = md.grouping
                t.year = md.year
                t.trackNumber = md.trackNumber
                t.trackCount = md.trackCount
                t.discNumber = md.discNumber
                t.discCount = md.discCount
                t.durationMs = md.durationMs
                t.bitrate = md.bitrate
                t.sampleRate = md.sampleRate
                t.fileSize = Int64(attrs?.fileSize ?? 0)
                t.isLossless = md.isLossless
                t.compilation = md.compilation
                t.bpm = md.bpm
                t.dateModified = attrs?.contentModificationDate
                let art = md.artworkData ?? MetadataExtractor.sidecarArtwork(for: url)
                let key = art.flatMap { Self.storeArtwork($0, in: artworkDir) }
                return (t, key)
            }.value
            if let (track0, key) = result {
                var track = track0
                track.artworkKey = key
                tracks.append(track)
                added += 1
            }
            if i % 25 == 0 { scheduleSave() }
        }
        scheduleSave()
        return added
    }

    nonisolated static func collectAudioFiles(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in e where MetadataExtractor.isAudioFile(f) || VideoTranscoder.isVideoFile(f) {
                        out.append(f)
                    }
                }
            } else if MetadataExtractor.isAudioFile(url) || VideoTranscoder.isVideoFile(url) {
                out.append(url)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Loads the Music app catalog off the main thread.
    func loadMusicCatalog() async throws -> MusicAppCatalog {
        try await Task.detached(priority: .userInitiated) { try MusicAppImporter.loadCatalog() }.value
    }

    /// Imports the chosen Music items (and optionally playlists). Returns a summary string.
    func importMusicItems(_ items: [MusicAppItem], playlists: [MusicAppPlaylist]) async -> String {
        isImporting = true
        importStatus = "Importing from Music…"
        importProgress = nil
        defer {
            isImporting = false
            importStatus = nil
        }
        let existingByPID = Dictionary(tracks.compactMap { t -> (String, UUID)? in
            guard let pid = t.musicPersistentID else { return nil }
            return (MusicPID.normalize(pid), t.id)
        }, uniquingKeysWith: { a, _ in a })
        let byPath = Dictionary(tracks.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        var byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Artwork for the new items.
        let importable = items.filter { $0.status.canImport }
        let wantArt = Set(importable.map(\.id).filter { pid in
            guard let id = existingByPID[pid], let t = byID[id] else { return true }
            return t.artworkKey == nil
        })
        let artworkDir = self.artworkDir
        importStatus = "Copying artwork…"
        let keys: [String: String] = await Task.detached(priority: .userInitiated) {
            let data = MusicAppImporter.artwork(forPersistentIDs: wantArt)
            var d: [String: String] = [:]
            for (pid, bytes) in data {
                if let k = Self.storeArtwork(bytes, in: artworkDir) { d[pid] = k }
            }
            return d
        }.value

        var added = 0, updated = 0
        var order: [UUID] = tracks.map(\.id)
        for m in importable {
            let id = existingByPID[m.id] ?? (m.location.flatMap { byPath[$0.path] }) ?? UUID()
            guard var t = MusicAppImporter.makeTrack(from: m, id: id) else { continue }
            if let old = byID[id] {
                t.syncEnabled = old.syncEnabled
                t.artworkKey = keys[m.id] ?? old.artworkKey
                t.kind = t.kind ?? old.kind
                byID[id] = t
                updated += 1
            } else {
                t.artworkKey = keys[m.id]
                byID[id] = t
                order.append(id)
                added += 1
            }
        }
        tracks = order.compactMap { byID[$0] }

        let pidToID = Dictionary(tracks.compactMap { t -> (String, UUID)? in
            guard let pid = t.musicPersistentID else { return nil }
            return (MusicPID.normalize(pid), t.id)
        }, uniquingKeysWith: { a, _ in a })
        var playlistsAdded = 0
        for pl in playlists {
            let ids = pl.itemIDs.compactMap { pidToID[$0] }
            guard !ids.isEmpty else { continue }
            if let idx = self.playlists.firstIndex(where: { $0.musicPersistentID.map(MusicPID.normalize) == pl.id }) {
                self.playlists[idx].name = pl.name
                self.playlists[idx].trackIDs = ids
            } else {
                var p = LibraryPlaylist(name: pl.name, trackIDs: ids)
                p.musicPersistentID = pl.id
                self.playlists.append(p)
                playlistsAdded += 1
            }
        }
        scheduleSave()
        var parts = ["Added \(added) item\(added == 1 ? "" : "s")"]
        if updated > 0 { parts.append("updated \(updated)") }
        if playlistsAdded > 0 { parts.append("added \(playlistsAdded) playlist\(playlistsAdded == 1 ? "" : "s")") }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: - Playlists

    @discardableResult
    func addPlaylist(name: String, trackIDs: [UUID] = []) -> LibraryPlaylist {
        let pl = LibraryPlaylist(name: name, trackIDs: trackIDs)
        playlists.append(pl)
        scheduleSave()
        return pl
    }

    func renamePlaylist(id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = name
        scheduleSave()
    }

    func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        for k in deviceRecords.keys {
            deviceRecords[k]?.selectedPlaylistIDs.remove(id)
        }
        scheduleSave()
    }

    func addTracks(_ ids: [UUID], toPlaylist playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let existing = Set(playlists[i].trackIDs)
        for id in ids where !existing.contains(id) { playlists[i].trackIDs.append(id) }
        scheduleSave()
    }

    func removeTracks(_ ids: Set<UUID>, fromPlaylist playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.removeAll { ids.contains($0) }
        scheduleSave()
    }

    func moveTracks(in playlistID: UUID, from source: IndexSet, to destination: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var ids = playlists[i].trackIDs
        let moving = source.sorted().map { ids[$0] }
        let before = ids.enumerated().filter { !source.contains($0.offset) && $0.offset < destination }.map(\.element)
        let after = ids.enumerated().filter { !source.contains($0.offset) && $0.offset >= destination }.map(\.element)
        ids = before + moving + after
        playlists[i].trackIDs = ids
        scheduleSave()
    }

    func tracks(in playlist: LibraryPlaylist) -> [LibraryTrack] {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return playlist.trackIDs.compactMap { byID[$0] }
    }

    // MARK: - Podcasts

    func show(id: UUID) -> PodcastShow? { shows.first { $0.id == id } }

    @discardableResult
    func subscribe(feedURL: URL) async throws -> PodcastShow {
        if let existing = shows.first(where: { $0.feedURL == feedURL }) { return existing }
        let feed = try await Self.fetchFeed(feedURL)
        var show = PodcastShow(feedURL: feedURL, title: feed.title, author: feed.author, summary: feed.summary, imageURL: feed.imageURL)
        show.keepLatest = UserDefaults.standard.object(forKey: "defaultKeepLatest") as? Int ?? 5
        show.episodes = feed.episodes.map { Self.makeEpisode($0) }
        show.lastRefreshed = Date()
        if let img = feed.imageURL {
            show.artworkKey = await Self.downloadArtwork(img, into: artworkDir)
        }
        shows.append(show)
        scheduleSave()
        return show
    }

    func unsubscribe(showID: UUID) {
        guard let show = show(id: showID) else { return }
        for id in show.episodes.map(\.id) { activeDownloads[id]?.cancel() }
        try? FileManager.default.removeItem(at: podcastsDir.appendingPathComponent(show.id.uuidString))
        shows.removeAll { $0.id == showID }
        scheduleSave()
    }

    func updateShow(_ show: PodcastShow) {
        guard let i = shows.firstIndex(where: { $0.id == show.id }) else { return }
        shows[i] = show
        scheduleSave()
    }

    func refreshShow(id: UUID) async {
        guard let i = shows.firstIndex(where: { $0.id == id }) else { return }
        refreshingShows.insert(id)
        defer { refreshingShows.remove(id) }
        let url = shows[i].feedURL
        do {
            let feed = try await Self.fetchFeed(url)
            guard let idx = shows.firstIndex(where: { $0.id == id }) else { return }
            var show = shows[idx]
            show.title = feed.title.isEmpty ? show.title : feed.title
            show.author = feed.author ?? show.author
            show.summary = feed.summary ?? show.summary
            if show.artworkKey == nil, let img = feed.imageURL {
                show.imageURL = img
                show.artworkKey = await Self.downloadArtwork(img, into: artworkDir)
            }
            let existingByGUID = Dictionary(show.episodes.map { ($0.guid, $0) }, uniquingKeysWith: { a, _ in a })
            var merged: [PodcastEpisode] = []
            var seen = Set<String>()
            for parsed in feed.episodes {
                let guid = parsed.guid.isEmpty ? (parsed.enclosureURL?.absoluteString ?? parsed.title) : parsed.guid
                if seen.contains(guid) { continue }
                seen.insert(guid)
                if var old = existingByGUID[guid] {
                    old.title = parsed.title
                    old.summary = parsed.summary ?? old.summary
                    old.publishedAt = parsed.publishedAt ?? old.publishedAt
                    old.durationMs = parsed.durationMs ?? old.durationMs
                    if !old.isDownloaded, let u = parsed.enclosureURL { old.enclosureURL = u }
                    merged.append(old)
                } else {
                    merged.append(Self.makeEpisode(parsed))
                }
            }
            // Keep downloaded episodes that dropped out of the feed.
            for old in show.episodes where !seen.contains(old.guid) && old.isDownloaded {
                merged.append(old)
            }
            show.episodes = merged
            show.lastRefreshed = Date()
            if let idx2 = shows.firstIndex(where: { $0.id == id }) { shows[idx2] = show }
            scheduleSave()
        } catch {
            lastError = "Couldn't refresh \(shows[i].title): \(error.localizedDescription)"
        }
    }

    func refreshAllShows() async {
        for id in shows.map(\.id) {
            await refreshShow(id: id)
        }
    }

    private static func makeEpisode(_ p: ParsedEpisode) -> PodcastEpisode {
        var e = PodcastEpisode(guid: p.guid.isEmpty ? (p.enclosureURL?.absoluteString ?? p.title) : p.guid,
                               title: p.title, enclosureURL: p.enclosureURL ?? URL(string: "about:blank")!)
        e.summary = p.summary
        e.publishedAt = p.publishedAt
        e.durationMs = p.durationMs
        e.enclosureLength = p.enclosureLength
        e.mimeType = p.mimeType
        e.episodeNumber = p.episodeNumber
        e.seasonNumber = p.seasonNumber
        return e
    }

    nonisolated static func fetchFeed(_ url: URL) async throws -> ParsedFeed {
        var request = URLRequest(url: url)
        request.setValue("iPod Pro Max/1.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw IPodDBError.io("The feed server returned status \(http.statusCode).")
        }
        return try await Task.detached { try PodcastFeedParser.parse(data: data) }.value
    }

    nonisolated static func downloadArtwork(_ url: URL, into artworkDir: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return storeArtwork(data, in: artworkDir)
    }

    /// Episodes that the sync rules want but which aren't downloaded yet.
    var pendingEpisodeDownloads: [(show: PodcastShow, episode: PodcastEpisode)] {
        var out: [(PodcastShow, PodcastEpisode)] = []
        for s in shows {
            for e in s.episodesToSync() where !e.isDownloaded && activeDownloads[e.id] == nil {
                out.append((s, e))
            }
        }
        return out
    }

    func downloadPendingEpisodes() async {
        let pending = pendingEpisodeDownloads
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for (show, ep) in pending {
                if running >= 3 { await group.next(); running -= 1 }
                group.addTask { await self.downloadEpisode(showID: show.id, episodeID: ep.id) }
                running += 1
            }
        }
    }

    func isDownloading(_ episodeID: UUID) -> Bool { activeDownloads[episodeID] != nil }

    func cancelDownload(episodeID: UUID) {
        activeDownloads[episodeID]?.cancel()
        activeDownloads[episodeID] = nil
        downloadProgress[episodeID] = nil
    }

    func downloadEpisode(showID: UUID, episodeID: UUID) async {
        guard let show = show(id: showID), let ep = show.episodes.first(where: { $0.id == episodeID }) else { return }
        if ep.isDownloaded || activeDownloads[episodeID] != nil { return }
        let dir = podcastsDir.appendingPathComponent(show.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ext = ep.enclosureURL.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 4 {
            if let mime = ep.mimeType?.lowercased() {
                ext = mime.contains("mp4") || mime.contains("m4a") || mime.contains("aac") ? "m4a" : "mp3"
            } else { ext = "mp3" }
        }
        let dest = dir.appendingPathComponent("\(ep.id.uuidString).\(ext)")
        downloadProgress[episodeID] = 0
        let task = Task { [weak self] in
            do {
                let delegate = DownloadProgressDelegate { fraction in
                    Task { @MainActor in self?.downloadProgress[episodeID] = fraction }
                }
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                var request = URLRequest(url: ep.enclosureURL)
                request.setValue("iPod Pro Max/1.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
                let (tmp, response) = try await session.download(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw IPodDBError.io("Server returned status \(http.statusCode)")
                }
                if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: tmp, to: dest)
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
                var durationMs: Int? = nil
                if let md = try? await MetadataExtractor.extract(from: dest), md.durationMs > 0 { durationMs = md.durationMs }
                await MainActor.run {
                    guard let self, let si = self.shows.firstIndex(where: { $0.id == showID }),
                          let ei = self.shows[si].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
                    self.shows[si].episodes[ei].localPath = dest.path
                    self.shows[si].episodes[ei].fileSize = size
                    if let d = durationMs { self.shows[si].episodes[ei].durationMs = d }
                    self.scheduleSave()
                }
            } catch {
                if !(error is CancellationError) {
                    await MainActor.run { self?.lastError = "Download failed for “\(ep.title)”: \(error.localizedDescription)" }
                }
            }
            await MainActor.run {
                self?.downloadProgress[episodeID] = nil
                self?.activeDownloads[episodeID] = nil
            }
        }
        activeDownloads[episodeID] = task
        await task.value
    }

    func deleteDownload(showID: UUID, episodeID: UUID) {
        guard let si = shows.firstIndex(where: { $0.id == showID }), let ei = shows[si].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        if let p = shows[si].episodes[ei].localPath { try? FileManager.default.removeItem(atPath: p) }
        shows[si].episodes[ei].localPath = nil
        shows[si].episodes[ei].fileSize = nil
        scheduleSave()
    }

    func setEpisodeSync(showID: UUID, episodeID: UUID, override: Bool?) {
        guard let si = shows.firstIndex(where: { $0.id == showID }), let ei = shows[si].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        shows[si].episodes[ei].syncOverride = override
        scheduleSave()
    }

    func setEpisodePlayed(showID: UUID, episodeID: UUID, played: Bool) {
        guard let si = shows.firstIndex(where: { $0.id == showID }), let ei = shows[si].episodes.firstIndex(where: { $0.id == episodeID }) else { return }
        shows[si].episodes[ei].played = played
        if !played { shows[si].episodes[ei].playbackPositionMs = 0 }
        scheduleSave()
    }

    /// Removes downloads that fall outside the keep rule (called after a sync).
    func pruneOldDownloads() {
        for si in shows.indices {
            let keep = Set(shows[si].episodesToSync().map(\.id))
            for ei in shows[si].episodes.indices where shows[si].episodes[ei].isDownloaded && !keep.contains(shows[si].episodes[ei].id) {
                if let p = shows[si].episodes[ei].localPath { try? FileManager.default.removeItem(atPath: p) }
                shows[si].episodes[ei].localPath = nil
                shows[si].episodes[ei].fileSize = nil
            }
        }
        scheduleSave()
    }

    // MARK: - Device records

    func record(for device: IPodDevice) -> DeviceSyncRecord {
        if let r = deviceRecords[device.id] { return r }
        return DeviceSyncRecord(deviceID: device.id, deviceName: device.volumeName)
    }

    func updateRecord(_ record: DeviceSyncRecord) {
        deviceRecords[record.deviceID] = record
        scheduleSave()
    }

    func forgetDevice(id: String) {
        deviceRecords[id] = nil
        scheduleSave()
    }

    /// Music tracks that a device wants, honoring its "all music" / "selected playlists" choice, plus videos when enabled.
    func tracksToSync(for record: DeviceSyncRecord) -> [LibraryTrack] {
        var out: [LibraryTrack]
        if record.syncAllMusic {
            out = tracks.filter { $0.syncEnabled && !$0.isVideo }
        } else {
            var ids = Set<UUID>()
            for pl in playlists where record.selectedPlaylistIDs.contains(pl.id) {
                ids.formUnion(pl.trackIDs)
            }
            out = tracks.filter { ids.contains($0.id) && $0.syncEnabled && !$0.isVideo }
        }
        if record.videosEnabled {
            out += tracks.filter { $0.isVideo && $0.syncEnabled }
        }
        return out
    }

    func playlistsToSync(for record: DeviceSyncRecord) -> [LibraryPlaylist] {
        if record.syncAllMusic { return playlists.filter { $0.syncEnabled } }
        return playlists.filter { record.selectedPlaylistIDs.contains($0.id) }
    }

    /// Applies play statistics read back from an iPod.
    func applyPlayback(trackStats: [UUID: (playCount: Int, lastPlayed: Date?, rating: Int?)],
                       episodeStats: [UUID: (played: Bool, positionMs: Int)]) {
        for (id, s) in trackStats {
            guard let i = tracks.firstIndex(where: { $0.id == id }) else { continue }
            tracks[i].playCount += s.playCount
            if let d = s.lastPlayed, d > (tracks[i].lastPlayed ?? .distantPast) { tracks[i].lastPlayed = d }
            if let r = s.rating, r > 0 { tracks[i].rating = r }
        }
        for (id, s) in episodeStats {
            for si in shows.indices {
                if let ei = shows[si].episodes.firstIndex(where: { $0.id == id }) {
                    if s.played { shows[si].episodes[ei].played = true }
                    shows[si].episodes[ei].playbackPositionMs = s.positionMs
                }
            }
        }
        scheduleSave()
    }
}

/// Reports download progress from URLSession.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}
