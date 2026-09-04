//
//  VideosView.swift
//  iPod Pro Max
//

import SwiftUI
import UniformTypeIdentifiers

struct VideosView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var appState
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\LibraryTrack.title)]
    @State private var search = ""
    @State private var isDropTargeted = false

    private var visible: [LibraryTrack] {
        var v = library.videos
        if !search.isEmpty {
            let q = search.lowercased()
            v = v.filter { $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) ?? false) || ($0.album?.lowercased().contains(q) ?? false) }
        }
        return v.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if library.videos.isEmpty {
                EmptyStateView(icon: "film", title: "No Videos Yet",
                               message: "Add movies or clips (MP4, MOV, M4V and most other formats). They're converted to the iPod's H.264 320×240 format when syncing, which can take a while for long videos.") {
                    AnyView(Button("Add Videos…") { appState.requestAddFiles = true })
                }
            } else {
                table
            }
        }
        .navigationTitle("Videos")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search videos")
        .toolbar {
            ToolbarItemGroup {
                if library.isImporting {
                    HStack(spacing: 6) {
                        ProgressView(value: library.importProgress).progressViewStyle(.linear).frame(width: 90)
                        Text(library.importStatus ?? "Importing…").font(.caption).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                    }
                }
                Button { appState.requestAddFiles = true } label: { Label("Add Videos", systemImage: "plus") }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL { urls.append(url) }
                    else if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                if !urls.isEmpty { await library.importFiles(urls) }
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(6).allowsHitTesting(false)
            }
        }
    }

    private var subtitle: String {
        let n = library.videos.count
        let ms = library.videos.reduce(0) { $0 + $1.durationMs }
        return "\(n) video\(n == 1 ? "" : "s"), \(Format.duration(ms: ms))"
    }

    private var table: some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Sync") { t in
                Toggle("", isOn: Binding(get: { t.syncEnabled }, set: { library.setSync($0, forTracks: selection.contains(t.id) ? selection : [t.id]) })).labelsHidden()
            }
            .width(40)
            TableColumn("Title", value: \.title) { t in
                HStack(spacing: 8) {
                    ArtworkThumb(key: t.artworkKey, size: 28, cornerRadius: 3, placeholder: "film")
                    Text(t.title).lineLimit(1)
                    if !t.fileExists { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("File not found") }
                }
            }
            .width(min: 200, ideal: 340)
            TableColumn("Time", value: \.durationMs) { t in Text(Format.duration(ms: t.durationMs)).monospacedDigit() }.width(70)
            TableColumn("Source") { t in
                Text("\(t.videoWidth ?? 0)×\(t.videoHeight ?? 0) \(t.fileExtension.uppercased())").foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)
            TableColumn("On iPod") { t in
                let (w, h) = VideoTranscoder.targetSize(width: t.videoWidth ?? 0, height: t.videoHeight ?? 0)
                Text("\(w)×\(h) H.264").foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Size", value: \.fileSize) { t in Text(Format.bytes(t.fileSize)).monospacedDigit() }.width(80)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let target = ids.isEmpty ? selection : ids
            Button("Sync to iPod") { library.setSync(true, forTracks: target) }
            Button("Don't Sync") { library.setSync(false, forTracks: target) }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(library.tracks.filter { target.contains($0.id) }.map(\.url))
            }
            Button("Remove from Library", role: .destructive) {
                library.removeTracks(ids: target)
                selection.subtract(target)
            }
        }
    }
}
