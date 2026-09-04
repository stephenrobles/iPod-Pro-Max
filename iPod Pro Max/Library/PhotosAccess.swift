//
//  PhotosAccess.swift
//  iPod Pro Max
//
//  Reads albums from the Photos app (PhotoKit) and exports the photos the user picked as JPEGs
//  sized for the iPod, cached under Application Support/PhotoCache.
//

import Foundation
import Photos
import AppKit
import CoreGraphics
import ImageIO

struct PhotosAlbumInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
    let isSmart: Bool
}

enum PhotosAccess {
    static var authorizationStatus: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static var isAuthorized: Bool {
        let s = authorizationStatus
        return s == .authorized || s == .limited
    }

    static func allPhotosCount() -> Int {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return PHAsset.fetchAssets(with: opts).count
    }

    /// User albums plus a few useful smart albums (Favorites, Recents).
    static func albums() -> [PhotosAlbumInfo] {
        var out: [PhotosAlbumInfo] = []
        let imageOpts = PHFetchOptions()
        imageOpts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        user.enumerateObjects { c, _, _ in
            let n = PHAsset.fetchAssets(in: c, options: imageOpts).count
            out.append(PhotosAlbumInfo(id: c.localIdentifier, title: c.localizedTitle ?? "Untitled", count: n, isSmart: false))
        }
        for subtype in [PHAssetCollectionSubtype.smartAlbumFavorites, .smartAlbumRecentlyAdded] {
            let smart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
            smart.enumerateObjects { c, _, _ in
                let n = PHAsset.fetchAssets(in: c, options: imageOpts).count
                if n > 0 { out.append(PhotosAlbumInfo(id: c.localIdentifier, title: c.localizedTitle ?? "Album", count: n, isSmart: true)) }
            }
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    struct ExportedAlbum {
        let name: String
        let photoKeys: [String]
    }

    struct ExportResult {
        var photos: [PhotoItem] = []
        var albums: [ExportedAlbum] = []
        var failed = 0
    }

    /// Exports the selection to JPEGs (longest side 1024 px) in `cacheDir`; returns items and album membership.
    static func export(selection: PhotoSelection, cacheDir: URL, progress: @escaping (Int, Int) -> Void) throws -> ExportResult {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        var result = ExportResult()
        var seen: [String: PhotoItem] = [:]
        let imageOpts = PHFetchOptions()
        imageOpts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        imageOpts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        var groups: [(name: String, assets: PHFetchResult<PHAsset>)] = []
        if selection.includeAllPhotos {
            groups.append(("All Photos", PHAsset.fetchAssets(with: imageOpts)))
        }
        if !selection.albumIDs.isEmpty {
            let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: selection.albumIDs, options: nil)
            collections.enumerateObjects { c, _, _ in
                groups.append((c.localizedTitle ?? "Album", PHAsset.fetchAssets(in: c, options: imageOpts)))
            }
        }
        let total = groups.reduce(0) { $0 + $1.assets.count }
        var done = 0
        let manager = PHImageManager.default()
        let reqOpts = PHImageRequestOptions()
        reqOpts.isSynchronous = true
        reqOpts.deliveryMode = .highQualityFormat
        reqOpts.resizeMode = .exact
        reqOpts.isNetworkAccessAllowed = true
        reqOpts.version = .current

        for g in groups {
            var keys: [String] = []
            g.assets.enumerateObjects { asset, _, _ in
                defer { done += 1; progress(done, total) }
                let stamp = Int(asset.modificationDate?.timeIntervalSince1970 ?? asset.creationDate?.timeIntervalSince1970 ?? 0)
                let key = asset.localIdentifier.replacingOccurrences(of: "/", with: "_") + "-\(stamp)"
                if let existing = seen[key] {
                    keys.append(existing.key)
                    return
                }
                let url = cacheDir.appendingPathComponent(key + ".jpg")
                if !FileManager.default.fileExists(atPath: url.path) {
                    var written = false
                    manager.requestImage(for: asset, targetSize: CGSize(width: 1024, height: 1024), contentMode: .aspectFit, options: reqOpts) { image, info in
                        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                        if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded { return }
                        if let jpeg = ImageLoading.jpegData(from: cg, maxDimension: 1024, quality: 0.9) {
                            try? jpeg.write(to: url, options: .atomic)
                            written = true
                        }
                    }
                    if !written {
                        result.failed += 1
                        return
                    }
                }
                let size = UInt32((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let item = PhotoItem(key: key, jpegURL: url, creationDate: asset.creationDate, originalSize: size)
                seen[key] = item
                result.photos.append(item)
                keys.append(key)
            }
            result.albums.append(ExportedAlbum(name: g.name, photoKeys: keys))
        }
        return result
    }

    /// Deletes cached JPEGs that aren't in `keep`.
    static func pruneCache(_ cacheDir: URL, keep: Set<String>) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for u in items where !keep.contains(u.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: u)
        }
    }
}
