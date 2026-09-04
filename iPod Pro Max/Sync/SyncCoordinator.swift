//
//  SyncCoordinator.swift
//  iPod Pro Max
//
//  Main-actor façade that runs syncs in the background and publishes progress to the UI.
//

import Foundation
import Observation

@MainActor
@Observable
final class SyncCoordinator {
    struct Status: Identifiable {
        let id: String
        var isRunning = false
        var phase = ""
        var detail = ""
        var fraction: Double?
        var log: [String] = []
        var lastError: String?
        var lastSummary: String?
        var finishedAt: Date?
    }

    private(set) var statuses: [String: Status] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    let library: LibraryStore
    let devices: DeviceMonitor

    init(library: LibraryStore, devices: DeviceMonitor) {
        self.library = library
        self.devices = devices
    }

    func status(for device: IPodDevice) -> Status {
        statuses[device.id] ?? Status(id: device.id)
    }

    func isSyncing(_ device: IPodDevice) -> Bool { statuses[device.id]?.isRunning ?? false }

    var anySyncRunning: Bool { statuses.values.contains { $0.isRunning } }

    func cancel(_ device: IPodDevice) {
        tasks[device.id]?.cancel()
    }

    func startSync(_ device: IPodDevice, downloadPodcastsFirst: Bool = true) {
        guard !isSyncing(device) else { return }
        var status = Status(id: device.id)
        status.isRunning = true
        status.phase = "Preparing"
        status.detail = ""
        statuses[device.id] = status

        let defaults = UserDefaults.standard
        let ejectAfter = defaults.bool(forKey: "ejectAfterSync")
        let record = library.record(for: device)
        var options = SyncOptions()
        options.removeUnknownTracks = record.removeUnknownTracks
        options.writeArtwork = defaults.object(forKey: "syncArtwork") as? Bool ?? true
        options.syncPodcasts = record.syncPodcasts
        options.syncPhotos = record.photosEnabled

        let task = Task { [weak self] in
            guard let self else { return }
            if downloadPodcastsFirst && record.syncPodcasts && !library.pendingEpisodeDownloads.isEmpty {
                self.update(device.id) { $0.phase = "Podcasts"; $0.detail = "Downloading new episodes…" }
                await library.downloadPendingEpisodes()
            }
            let request = SyncRequest(device: device,
                                      record: library.record(for: device),
                                      tracks: library.tracksToSync(for: record),
                                      playlists: library.playlistsToSync(for: record),
                                      shows: library.shows,
                                      artworkDir: library.artworkDir,
                                      transcodeDir: library.transcodeDir,
                                      photoCacheDir: library.photoCacheDir,
                                      photoSelection: library.photoSelection,
                                      options: options)
            let deviceID = device.id
            let engine = SyncEngine(request: request) { progress in
                Task { @MainActor [weak self] in
                    self?.update(deviceID) {
                        $0.phase = progress.phase
                        $0.detail = progress.detail
                        $0.fraction = progress.fraction
                    }
                }
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try await engine.run() }.value
                library.updateRecord(result.record)
                library.applyPlayback(trackStats: result.trackStats, episodeStats: result.episodeStats)
                library.pruneOldDownloads()
                var summary = "Added \(result.added), removed \(result.removed)."
                if result.photosWritten > 0 { summary += " \(result.photosWritten) photos." }
                if !result.failed.isEmpty { summary += " \(result.failed.count) item\(result.failed.count == 1 ? "" : "s") failed." }
                self.update(deviceID) {
                    $0.isRunning = false
                    $0.phase = "Done"
                    $0.detail = summary
                    $0.fraction = 1
                    $0.log = result.log + result.failed.map { "Failed: \($0)" }
                    $0.lastSummary = summary
                    $0.lastError = nil
                    $0.finishedAt = Date()
                }
                if ejectAfter {
                    try? await self.devices.eject(device)
                }
            } catch {
                let message = (error as? SyncError)?.errorDescription ?? error.localizedDescription
                self.update(deviceID) {
                    $0.isRunning = false
                    $0.phase = error is CancellationError || (error as? SyncError).map { if case .cancelled = $0 { return true } else { return false } } == true ? "Cancelled" : "Failed"
                    $0.detail = message
                    $0.fraction = nil
                    $0.lastError = message
                    $0.finishedAt = Date()
                }
            }
            self.tasks[deviceID] = nil
        }
        tasks[device.id] = task
    }

    private func update(_ id: String, _ body: (inout Status) -> Void) {
        var s = statuses[id] ?? Status(id: id)
        body(&s)
        statuses[id] = s
    }

    /// Copies the iPod's contents into the library.
    func importFromDevice(_ device: IPodDevice) async throws -> Int {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let destination = music.appendingPathComponent("iPod Pro Max").appendingPathComponent(device.volumeName)
        update(device.id) { $0.isRunning = true; $0.phase = "Importing"; $0.detail = "Copying songs from the iPod…"; $0.fraction = 0 }
        defer { update(device.id) { $0.isRunning = false } }
        let deviceID = device.id
        let files = try await Task.detached(priority: .userInitiated) {
            try IPodImporter.importAll(from: device, to: destination) { done, total in
                Task { @MainActor [weak self] in
                    self?.update(deviceID) { $0.fraction = total > 0 ? Double(done) / Double(total) : nil; $0.detail = "\(done) of \(total)" }
                }
            }
        }.value
        update(device.id) { $0.phase = "Importing"; $0.detail = "Adding \(files.count) files to the library…" }
        let added = await library.importFiles(files)
        update(device.id) { $0.phase = "Done"; $0.detail = "Imported \(added) songs to \(destination.path)"; $0.fraction = 1; $0.finishedAt = Date() }
        return added
    }
}
