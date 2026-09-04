//
//  Formatters.swift
//  iPod Pro Max
//

import SwiftUI
import AppKit

enum Format {
    static func duration(ms: Int) -> String {
        let total = max(ms / 1000, 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    static func shortDate(_ d: Date?) -> String {
        guard let d else { return "" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

extension LibraryTrack {
    var artistForSort: String { artist ?? albumArtist ?? "" }
    var albumForSort: String { album ?? "" }
    var genreForSort: String { genre ?? "" }
    var formatLabel: String {
        let ext = fileExtension.uppercased()
        if needsTranscode { return "\(ext) → AAC" }
        if isLossless && (ext == "M4A") { return "ALAC" }
        return ext
    }
}

/// Small artwork thumbnail loaded off the main thread. Takes the file URL directly so it never depends on
/// environment objects — table cells on macOS can be hosted outside the main view tree.
struct ArtworkThumb: View {
    let url: URL?
    var size: CGFloat = 40
    var cornerRadius: CGFloat = 4
    var placeholder: String = "music.note"
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.secondary.opacity(0.15))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                Image(systemName: placeholder)
                    .foregroundStyle(.secondary)
                    .font(.system(size: size * 0.4))
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url else { image = nil; return }
            let target = size * 2
            let loaded: NSImage? = await Task.detached(priority: .utility) {
                guard let cg = ImageLoading.cgImage(from: url) else { return nil }
                let longest = max(cg.width, cg.height)
                let scale = min(1, target / CGFloat(longest))
                let w = max(Int(CGFloat(cg.width) * scale), 1), h = max(Int(CGFloat(cg.height) * scale), 1)
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let out = ctx.makeImage() else { return nil }
                return NSImage(cgImage: out, size: NSSize(width: w, height: h))
            }.value
            if !Task.isCancelled { image = loaded }
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actions: () -> AnyView = { AnyView(EmptyView()) }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 48, weight: .thin)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            actions().padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
