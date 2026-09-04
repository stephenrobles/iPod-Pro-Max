//
//  DeviceMonitor.swift
//  iPod Pro Max
//
//  Watches mounted volumes and keeps the list of connected iPods up to date.
//

import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class DeviceMonitor {
    private(set) var devices: [IPodDevice] = []
    /// Folders attached through Settings › Advanced as simulated iPods (persisted as paths).
    private(set) var simulatedFolders: [URL] = []

    private var observers: [NSObjectProtocol] = []
    private let defaultsKey = "simulatedIPodFolders"

    init() {
        if let paths = UserDefaults.standard.array(forKey: defaultsKey) as? [String] {
            simulatedFolders = paths.map { URL(fileURLWithPath: $0) }
        }
        // Development aid: `-simulatedIPodFolder /path` on the command line attaches a folder for this launch only.
        if let extra = UserDefaults.standard.string(forKey: "simulatedIPodFolder"), !extra.isEmpty {
            let url = URL(fileURLWithPath: extra)
            if !simulatedFolders.contains(url) { simulatedFolders.append(url) }
        }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rescan() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rescan() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rescan() }
        })
        rescan()
    }

    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    /// Scans volumes on a background thread (network or wedged volumes must never block the UI).
    func rescan() {
        scanGeneration += 1
        let generation = scanGeneration
        let folders = simulatedFolders
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let found = Self.scanVolumes(simulatedFolders: folders)
            guard let self else { return }
            await self.applyScan(found, generation: generation)
        }
    }

    private func applyScan(_ found: [IPodDevice], generation: Int) {
        guard generation == scanGeneration else { return }
        if found != devices { devices = found }
    }

    nonisolated static func scanVolumes(simulatedFolders: [URL]) -> [IPodDevice] {
        var found: [IPodDevice] = []
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]
        // Development aid: `-ignoreDevices YES` hides real iPods.
        let volumes = UserDefaults.standard.bool(forKey: "ignoreDevices") ? [] : (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
        for v in volumes {
            guard let values = try? v.resourceValues(forKeys: Set(keys)) else { continue }
            // iPods are local, ejectable USB/FireWire disks. Skip network shares, the boot disk and internal drives.
            if values.volumeIsLocal == false { continue }
            if values.volumeIsRootFileSystem == true { continue }
            let ejectable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
            if !ejectable && (values.volumeIsInternal ?? true) { continue }
            if let dev = IPodDevice.detect(volume: v) {
                found.append(dev)
            }
        }
        for folder in simulatedFolders {
            if let dev = IPodDevice.detect(volume: folder, simulated: true) {
                found.append(dev)
            }
        }
        return found
    }

    func device(id: String) -> IPodDevice? { devices.first { $0.id == id } }

    func attachSimulatedFolder(_ url: URL) {
        if !simulatedFolders.contains(url) {
            simulatedFolders.append(url)
            persistSimulated()
        }
        rescan()
    }

    func detachSimulatedFolder(_ url: URL) {
        simulatedFolders.removeAll { $0 == url }
        persistSimulated()
        rescan()
    }

    private func persistSimulated() {
        UserDefaults.standard.set(simulatedFolders.map(\.path), forKey: defaultsKey)
    }

    /// Ejects (unmounts) a real iPod. Simulated folders are simply detached.
    func eject(_ device: IPodDevice) async throws {
        if device.isSimulated {
            detachSimulatedFolder(device.mountPoint)
            return
        }
        let url = device.mountPoint
        try await Task.detached(priority: .userInitiated) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }.value
        rescan()
    }
}
