//
//  IPodDevice.swift
//  iPod Pro Max
//
//  A mounted iPod (or a folder standing in for one). Reads SysInfo / SysInfoExtended to identify
//  the model and exposes the well-known paths inside iPod_Control.
//

import Foundation

struct IPodDevice: Identifiable, Hashable {
    /// Stable identifier: serial number, FireWire GUID, or the mount path.
    let id: String
    let mountPoint: URL
    let volumeName: String
    let modelInfo: IPodModelInfo?
    let generation: IPodGeneration
    let sysInfo: [String: String]
    let firewireGUID: String?
    let serialNumber: String?
    /// DBVersion from SysInfoExtended (drives the checksum requirement on newer models).
    let extendedDBVersion: Int?
    let artworkFormatsFromDevice: [ArtworkFormat]?
    let isSimulated: Bool
    /// Name stored in the iPod's database (what the iPod shows about itself), if readable.
    let databaseName: String?

    var displayName: String {
        if let n = databaseName, !n.isEmpty { return n }
        return volumeName
    }

    static func == (lhs: IPodDevice, rhs: IPodDevice) -> Bool { lhs.id == rhs.id && lhs.mountPoint == rhs.mountPoint }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(mountPoint) }

    // MARK: Paths

    var controlDir: URL { mountPoint.appendingPathComponent("iPod_Control", isDirectory: true) }
    var iTunesDir: URL { controlDir.appendingPathComponent("iTunes", isDirectory: true) }
    var musicDir: URL { controlDir.appendingPathComponent("Music", isDirectory: true) }
    var artworkDir: URL { controlDir.appendingPathComponent("Artwork", isDirectory: true) }
    var deviceDir: URL { controlDir.appendingPathComponent("Device", isDirectory: true) }
    var iTunesDBURL: URL { iTunesDir.appendingPathComponent("iTunesDB") }
    var playCountsURL: URL { iTunesDir.appendingPathComponent("Play Counts") }
    var artworkDBURL: URL { artworkDir.appendingPathComponent("ArtworkDB") }

    // MARK: Capabilities

    var checksumType: IPodChecksumType {
        if let v = extendedDBVersion {
            switch v {
            case 0, 1, 2: return .none
            case 3: return .hash58
            case 4: return .hash72
            case 5: return .hashAB
            default: return .unknown
            }
        }
        return generation.checksum
    }

    var supportLevel: IPodSupportLevel {
        switch checksumType {
        case .none: return generation == .unknown ? .experimental : .full
        case .hash58: return firewireGUID == nil ? .unsupported : .experimental
        default: return .unsupported
        }
    }

    var coverArtFormats: [ArtworkFormat] {
        let fromTable = generation.coverArtFormats
        if !fromTable.isEmpty { return fromTable }
        return artworkFormatsFromDevice ?? []
    }

    var supportsArtwork: Bool { !coverArtFormats.isEmpty }
    var supportsPodcasts: Bool { generation.supportsPodcasts }

    var displayModelName: String {
        if let m = modelInfo { return m.marketingName }
        if generation != .unknown { return generation.displayName }
        return "iPod"
    }

    var capacityLabel: String? { modelInfo?.capacityDescription }

    var firewireIDBytes: [UInt8]? {
        guard let g = firewireGUID else { return nil }
        return Hash58.firewireBytes(from: g)
    }

    // MARK: Volume stats

    struct VolumeStats {
        var total: Int64
        var free: Int64
        var used: Int64 { total - free }
    }

    func volumeStats() -> VolumeStats {
        let values = try? mountPoint.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        var free = Int64(values?.volumeAvailableCapacity ?? 0)
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0, isSimulated { free = important }
        return VolumeStats(total: total, free: free)
    }

    /// Existing F00…Fnn folders on the device (created on demand by the sync engine).
    func musicFolderCount() -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: musicDir.path) else { return 0 }
        return items.filter { $0.count == 3 && $0.hasPrefix("F") && Int($0.dropFirst()) != nil }.count
    }

    /// Reads the on-device database, or an empty one named after the volume when none exists.
    func readDatabase() throws -> ITunesDatabase {
        if let data = try? Data(contentsOf: iTunesDBURL), !data.isEmpty {
            return try ITunesDBReader(data: data).parse()
        }
        return ITunesDatabase.empty(named: volumeName)
    }

    // MARK: Detection

    static func detect(volume: URL, simulated: Bool = false) -> IPodDevice? {
        let fm = FileManager.default
        let control = volume.appendingPathComponent("iPod_Control", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: control.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let sysInfo = parseSysInfo(at: control.appendingPathComponent("Device/SysInfo"))
        let extended = parseSysInfoExtended(at: control.appendingPathComponent("Device/SysInfoExtended"))

        var modelNumber = extended?["ModelNumStr"] as? String ?? sysInfo["ModelNumStr"]
        if modelNumber == nil, let pt = extended?["ProductType"] as? String { modelNumber = pt }
        var info = modelNumber.flatMap { IPodModelTable.info(forModelNumber: $0) }
        let firewire = (extended?["FireWireGUID"] as? String) ?? sysInfo["FirewireGuid"] ?? sysInfo["FireWireGUID"]
        var serial = (extended?["SerialNumber"] as? String) ?? sysInfo["pszSerialNumber"] ?? sysInfo["SerialNumber"]
        if let s = serial, s.isEmpty { serial = nil }

        // Fall back to the USB product id when SysInfo can't tell us the model.
        var usbGeneration: IPodGeneration? = nil
        if !simulated, info == nil, let usb = USBIdentification.identify(volume: volume), usb.isApple {
            usbGeneration = usb.generation
            if serial == nil, let s = usb.serialNumber, !s.isEmpty { serial = s }
            if let gen = usbGeneration {
                let total = (try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity) ?? 0
                let gb = Self.marketingCapacity(bytes: Int64(total))
                info = IPodModelInfo(modelNumber: String(format: "USB %04X", usb.productID), capacityGB: gb, generation: gen, color: nil)
            }
        }
        let dbVersion = (extended?["DBVersion"] as? NSNumber)?.intValue

        var deviceFormats: [ArtworkFormat]? = nil
        if let art = extended?["AlbumArt"] as? [[String: Any]] {
            let fmts = art.compactMap { d -> ArtworkFormat? in
                guard let id = (d["FormatId"] as? NSNumber)?.intValue,
                      let w = (d["RenderWidth"] as? NSNumber)?.intValue,
                      let h = (d["RenderHeight"] as? NSNumber)?.intValue else { return nil }
                let pixel = (d["PixelFormat"] as? String) ?? "4C353635"
                guard pixel == "4C353635" else { return nil } // only RGB565 LE is supported
                return ArtworkFormat(id: id, width: w, height: h)
            }
            if !fmts.isEmpty { deviceFormats = fmts }
        }

        let volumeName = simulated ? volume.lastPathComponent : ((try? volume.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? volume.lastPathComponent)
        var identifier = serial ?? firewire ?? ""
        if identifier.isEmpty {
            identifier = (try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? volume.path
        }
        if simulated { identifier = "folder:" + volume.path }

        var databaseName: String? = nil
        let dbURL = control.appendingPathComponent("iTunes/iTunesDB")
        if let handle = try? FileHandle(forReadingFrom: dbURL) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 32 * 1024 * 1024), !data.isEmpty,
               let db = try? ITunesDBReader(data: data).parse() {
                databaseName = db.masterPlaylist?.name
            }
        }

        return IPodDevice(id: identifier,
                          mountPoint: volume,
                          volumeName: volumeName,
                          modelInfo: info,
                          generation: info?.generation ?? usbGeneration ?? .unknown,
                          sysInfo: sysInfo,
                          firewireGUID: firewire,
                          serialNumber: serial,
                          extendedDBVersion: dbVersion,
                          artworkFormatsFromDevice: deviceFormats,
                          isSimulated: simulated,
                          databaseName: databaseName)
    }

    /// Rounds a raw volume size to the capacity printed on the box (30 GB, 60 GB, 4 GB …).
    static func marketingCapacity(bytes: Int64) -> Double {
        guard bytes > 0 else { return 0 }
        let gb = Double(bytes) / 1_000_000_000
        let steps: [Double] = [0.5, 1, 2, 4, 5, 6, 8, 10, 15, 16, 20, 30, 32, 40, 60, 64, 80, 120, 128, 160, 256]
        return steps.first { $0 >= gb * 0.98 } ?? gb.rounded()
    }

    static func parseSysInfo(at url: URL) -> [String: String] {
        // SysInfo is a small text file; read at most 64 KB so an odd file can't stall the scan.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return [:] }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [:] }
        var dict: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { dict[key] = value }
        }
        return dict
    }

    static func parseSysInfoExtended(at url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    /// Creates the folder skeleton of an iPod inside `folder` (used for the simulated device in Settings).
    static func createSimulatedIPod(at folder: URL, modelNumber: String = "xA002", name: String = "Test iPod") throws {
        let fm = FileManager.default
        let control = folder.appendingPathComponent("iPod_Control", isDirectory: true)
        try fm.createDirectory(at: control.appendingPathComponent("Device"), withIntermediateDirectories: true)
        try fm.createDirectory(at: control.appendingPathComponent("iTunes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: control.appendingPathComponent("Artwork"), withIntermediateDirectories: true)
        let music = control.appendingPathComponent("Music")
        try fm.createDirectory(at: music, withIntermediateDirectories: true)
        for i in 0..<50 {
            try fm.createDirectory(at: music.appendingPathComponent(String(format: "F%02d", i)), withIntermediateDirectories: true)
        }
        let sysinfo = """
        BoardHwName: iPod Q45
        pszSerialNumber: TEST0000000
        ModelNumStr: \(modelNumber)
        visibleBuildID: 0x01300000 (1.3)
        buildID: 0x01300000 (1.3)
        """
        try sysinfo.write(to: control.appendingPathComponent("Device/SysInfo"), atomically: true, encoding: .utf8)
        if !fm.fileExists(atPath: control.appendingPathComponent("iTunes/iTunesDB").path) {
            let db = ITunesDatabase.empty(named: name)
            let out = try ITunesDBWriter(database: db).write()
            try out.data.write(to: control.appendingPathComponent("iTunes/iTunesDB"))
        }
    }
}
