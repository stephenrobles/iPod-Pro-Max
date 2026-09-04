//
//  MusicView.swift
//  iPod Pro Max
//

import SwiftUI
import UniformTypeIdentifiers

struct MusicView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var appState
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\LibraryTrack.title)]
    @State private var search = ""
    @State private var showNewPlaylistFromSelection = false
    @State private var isDropTargeted = false

    private var visibleTracks: [LibraryTrack] {
        var t = library.songs
        if !search.isEmpty {
            let q = search.lowercased()
            t = t.filter {
                $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) ?? false) || ($0.album?.lowercased().contains(q) ?? false) || ($0.genre?.lowercased().contains(q) ?? false)
            }
        }
        return t.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if library.songs.isEmpty {
                EmptyStateView(icon: "music.note", title: "No Music Yet",
                               message: "Add MP3, AAC, Apple Lossless, WAV or AIFF files, or import your Music app library. FLAC and other formats are converted to AAC when syncing.") {
                    AnyView(HStack {
                        Button("Add Files…") { appState.requestAddFiles = true }
                        Button("Import from Music App…") { appState.showMusicImport = true }
                    })
                }
            } else {
                table
            }
        }
        .navigationTitle("Music")
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search songs")
        .toolbar {
            ToolbarItemGroup {
                if library.isImporting {
                    HStack(spacing: 6) {
                        ProgressView(value: library.importProgress).progressViewStyle(.linear).frame(width: 90)
                        Text(library.importStatus ?? "Importing…").font(.caption).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                    }
                }
                Button { appState.requestAddFiles = true } label: { Label("Add Files", systemImage: "plus") }
                    .help("Add audio files or folders to the library")
                Button { appState.showMusicImport = true } label: { Label("Import from Music", systemImage: "square.and.arrow.down") }
                    .help("Import songs and playlists from the Music app")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                        urls.append(url)
                    } else if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty { await library.importFiles(urls) }
            }
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(6)
                    .overlay(Text("Drop audio files or folders to add them").font(.title3).padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8)))
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showNewPlaylistFromSelection) {
            NewPlaylistSheet(initialTrackIDs: Array(selection))
        }
    }

    private var subtitle: String {
        let n = library.songs.count
        let synced = library.songs.filter(\.syncEnabled).count
        let bytes = library.songs.filter(\.syncEnabled).reduce(Int64(0)) { $0 + $1.fileSize }
        return "\(n) song\(n == 1 ? "" : "s"), \(synced) set to sync, \(Format.bytes(bytes))"
    }

    private var table: some View {
        Table(visibleTracks, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Sync") { t in
                Toggle("", isOn: Binding(get: { t.syncEnabled }, set: { library.setSync($0, forTracks: selection.contains(t.id) ? selection : [t.id]) }))
                    .labelsHidden()
            }
            .width(40)
            TableColumn("Title", value: \.title) { t in
                HStack(spacing: 8) {
                    ArtworkThumb(key: t.artworkKey, size: 22, cornerRadius: 3)
                    Text(t.title).lineLimit(1)
                    if !t.fileExists {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("File not found")
                    }
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Artist", value: \.artistForSort) { t in Text(t.displayArtist).lineLimit(1) }
            TableColumn("Album", value: \.albumForSort) { t in Text(t.displayAlbum).lineLimit(1) }
            TableColumn("Time", value: \.durationMs) { t in Text(Format.duration(ms: t.durationMs)).monospacedDigit() }
                .width(60)
            TableColumn("Genre", value: \.genreForSort) { t in Text(t.genre ?? "").lineLimit(1) }
                .width(min: 60, ideal: 100)
            TableColumn("Format", value: \.fileExtension) { t in
                Text(t.formatLabel).foregroundStyle(t.needsTranscode ? .orange : .primary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Plays", value: \.playCount) { t in Text(t.playCount == 0 ? "" : "\(t.playCount)").monospacedDigit() }
                .width(45)
            TableColumn("Size", value: \.fileSize) { t in Text(Format.bytes(t.fileSize)).monospacedDigit() }
                .width(70)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let target = ids.isEmpty ? selection : ids
            Menu("Add to Playlist") {
                ForEach(library.playlists) { pl in
                    Button(pl.name) { library.addTracks(Array(target), toPlaylist: pl.id) }
                }
                if !library.playlists.isEmpty { Divider() }
                Button("New Playlist…") {
                    selection = target
                    showNewPlaylistFromSelection = true
                }
            }
            Button("Sync to iPod") { library.setSync(true, forTracks: target) }
            Button("Don't Sync") { library.setSync(false, forTracks: target) }
            Divider()
            Button("Show in Finder") {
                let urls = library.tracks.filter { target.contains($0.id) }.map(\.url)
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            Button("Remove from Library", role: .destructive) {
                library.removeTracks(ids: target)
                selection.subtract(target)
            }
        }
    }
}
