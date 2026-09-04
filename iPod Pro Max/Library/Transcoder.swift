//
//  Transcoder.swift
//  iPod Pro Max
//
//  Converts audio the iPod can't play (FLAC, etc.) to AAC in an .m4a container with AVFoundation.
//

import Foundation
import AVFoundation

enum Transcoder {
    static func transcodeToAAC(source: URL, destination: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw IPodDBError.unsupported("This file can't be converted to AAC: \(source.lastPathComponent)")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        session.metadata = try? await asset.load(.metadata)
        try await session.export(to: destination, as: .m4a)
        return destination
    }

    /// Returns a cached transcode when it is newer than the source, otherwise transcodes.
    static func cachedAAC(for track: LibraryTrack, cacheDir: URL) async throws -> URL {
        let dest = cacheDir.appendingPathComponent("\(track.id.uuidString).m4a")
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            let srcDate = (try? track.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dstDate = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if dstDate >= srcDate { return dest }
        }
        return try await transcodeToAAC(source: track.url, destination: dest)
    }
}
