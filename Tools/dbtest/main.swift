// dbtest: end-to-end check of the sync engine against a simulated iPod folder.
// Build: see Tools/dbtest/run.sh
import Foundation

@main
struct DBTest {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: dbtest <samples dir> <ipod folder> [--read-only]")
            exit(1)
        }
        let samples = URL(fileURLWithPath: args[1])
        let ipod = URL(fileURLWithPath: args[2])
        let readOnly = args.contains("--read-only")

        if args.contains("--photos") {
            guard let dev = IPodDevice.detect(volume: ipod, simulated: true) else { fatalError("no device") }
            let images = ["cover1.png", "cover2.png"].map { samples.appendingPathComponent($0) }
            let items = images.map { url -> PhotoItem in
                PhotoItem(key: url.lastPathComponent, jpegURL: url, creationDate: Date(), originalSize: UInt32((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            }
            let albums = [PhotoAlbumItem(name: "Holiday", photoKeys: [items[0].key]), PhotoAlbumItem(name: "Both", photoKeys: items.map(\.key))]
            let writer = PhotoDBWriter(mountPoint: ipod, formats: dev.generation.photoFormats)
            let n = try writer.write(photos: items, albums: albums, tzOffset: 0) { _, _ in }
            print("Wrote \(n) photos, formats \(dev.generation.photoFormats.map(\.id))")
            return
        }
        if readOnly {
            let dev = IPodDevice.detect(volume: ipod, simulated: true)!
            let db = try dev.readDatabase()
            dump(db)
            return
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: ipod.appendingPathComponent("iPod_Control").path) {
            try IPodDevice.createSimulatedIPod(at: ipod, name: "Test iPod")
        }
        guard let device = IPodDevice.detect(volume: ipod, simulated: true) else { fatalError("no device") }
        print("Device: \(device.displayModelName) gen=\(device.generation) checksum=\(device.checksumType) formats=\(device.coverArtFormats.map(\.id))")

        let work = ipod.deletingLastPathComponent().appendingPathComponent("dbtest-work")
        let artworkDir = work.appendingPathComponent("Artwork")
        let transcodeDir = work.appendingPathComponent("Transcodes")
        try fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: transcodeDir, withIntermediateDirectories: true)

        var tracks: [LibraryTrack] = []
        for name in ["song1.mp3", "song2.mp3", "song3.m4a", "song4.flac", "song5.wav"] {
            let url = samples.appendingPathComponent(name)
            let md = try await MetadataExtractor.extract(from: url)
            var t = LibraryTrack(path: url.path, title: md.title ?? name, fileExtension: url.pathExtension.lowercased())
            t.artist = md.artist; t.album = md.album; t.albumArtist = md.albumArtist; t.genre = md.genre; t.composer = md.composer
            t.year = md.year; t.trackNumber = md.trackNumber; t.trackCount = md.trackCount; t.discNumber = md.discNumber
            t.durationMs = md.durationMs; t.bitrate = md.bitrate; t.sampleRate = md.sampleRate; t.isLossless = md.isLossless
            t.fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            t.rating = 4
            if let art = md.artworkData { t.artworkKey = LibraryStore.storeArtwork(art, in: artworkDir) }
            print("Extracted \(name): title=\(t.title) artist=\(t.artist ?? "-") album=\(t.album ?? "-") genre=\(t.genre ?? "-") year=\(t.year) track=\(t.trackNumber)/\(t.trackCount) dur=\(t.durationMs) br=\(t.bitrate) sr=\(t.sampleRate) lossless=\(t.isLossless) art=\(t.artworkKey ?? "none")")
            tracks.append(t)
        }
        for name in ["clip1.mp4", "clip2.mov"] {
            let url = samples.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let info = try await VideoTranscoder.info(for: url)
            var t = LibraryTrack(path: url.path, title: name, fileExtension: url.pathExtension.lowercased())
            t.kind = .video
            t.videoWidth = info.width; t.videoHeight = info.height; t.durationMs = info.durationMs
            t.fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if let poster = await VideoTranscoder.posterFrame(for: url) { t.artworkKey = LibraryStore.storeArtwork(poster, in: artworkDir) }
            print("Video \(name): \(info.width)x\(info.height) \(info.durationMs)ms audio=\(info.hasAudio) poster=\(t.artworkKey ?? "none")")
            tracks.append(t)
        }
        let playlist = LibraryPlaylist(name: "Road Trip", trackIDs: [tracks[0].id, tracks[2].id, tracks[3].id])

        var show = PodcastShow(feedURL: URL(string: "https://example.com/feed.xml")!, title: "Great Show", author: "Podcaster", summary: "A show.")
        show.artworkKey = LibraryStore.storeArtwork(try Data(contentsOf: samples.appendingPathComponent("cover2.png")), in: artworkDir)
        var ep = PodcastEpisode(guid: "ep1", title: "Episode One", enclosureURL: URL(string: "https://example.com/ep1.mp3")!)
        ep.publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        ep.durationMs = 5000
        ep.localPath = samples.appendingPathComponent("episode1.mp3").path
        ep.summary = "The first episode."
        show.episodes = [ep]

        var record = DeviceSyncRecord(deviceID: device.id, deviceName: device.volumeName)
        record.removeUnknownTracks = args.contains("--remove-unknown")

        func runSync(label: String, tracks: [LibraryTrack], record: DeviceSyncRecord) async throws -> SyncResult {
            let req = SyncRequest(device: device, record: record, tracks: tracks, playlists: [playlist], shows: [show], artworkDir: artworkDir, transcodeDir: transcodeDir, photoCacheDir: work.appendingPathComponent("PhotoCache"), photoSelection: PhotoSelection(), options: SyncOptions(removeUnknownTracks: record.removeUnknownTracks, syncPhotos: false))
            let engine = SyncEngine(request: req) { p in print("  [\(p.phase)] \(p.detail) \(p.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "")") }
            let r = try await engine.run()
            print("\(label): added=\(r.added) removed=\(r.removed) failed=\(r.failed) log=\(r.log)")
            return r
        }

        let r1 = try await runSync(label: "Sync 1", tracks: tracks, record: record)
        record = r1.record

        // Simulate the iPod writing a Play Counts file for the first two tracks.
        let db1 = try device.readDatabase()
        var w = ByteWriter()
        w.header("mhdp"); w.u32(0x60); w.u32(0x1C); w.u32(UInt32(db1.tracks.count)); w.zeros(0x60 - 16)
        for (i, _) in db1.tracks.enumerated() {
            w.u32(i == 0 ? 3 : 0)  // playcount
            w.u32(i == 0 ? MacTime.fromDate(Date(), tzOffset: db1.tzOffset) : 0)
            w.u32(i == db1.tracks.count - 1 ? 2500 : 0) // bookmark
            w.u32(i == 1 ? 100 : 0) // rating
            w.u32(0); w.u32(0); w.u32(0)
        }
        try w.data.write(to: device.playCountsURL)

        // Second sync: drop one song, everything else should be kept.
        let r2 = try await runSync(label: "Sync 2", tracks: tracks.filter { $0.title != "song5.wav" }, record: record)
        print("Track stats from iPod: \(r2.trackStats)")
        print("Episode stats from iPod: \(r2.episodeStats)")
        record = r2.record

        let db = try device.readDatabase()
        dump(db)
    }

    static func dump(_ db: ITunesDatabase) {
        print("DB name=\(db.name) version=0x\(String(db.version, radix: 16)) tracks=\(db.tracks.count) playlists=\(db.playlists.count)")
        for t in db.tracks {
            print("  TRACK id=\(t.trackID) title=\(t.title ?? "") artist=\(t.artist ?? "") album=\(t.album ?? "") path=\(t.ipodPath) len=\(t.durationMs) size=\(t.fileSize) nr=\(t.trackNumber) year=\(t.year) br=\(t.bitrate) sr=\(t.sampleRate) rating=\(t.rating) pc=\(t.playCount) media=\(t.mediaType) art=\(t.hasArtwork) mhii=\(t.mhiiLink) ft=\(t.filetypeDescription ?? "") bookmark=\(t.bookmarkTimeMs) unplayed=\(t.markUnplayed)")
        }
        for p in db.playlists {
            print("  PLAYLIST \(p.name) master=\(p.isMaster) podcast=\(p.isPodcasts) members=\(p.memberDBIDs.count)")
        }
    }
}
