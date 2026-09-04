//
//  MusicImportSheet.swift
//  iPod Pro Max
//
//  Lets the user choose which Music-app songs, videos and playlists to import, and explains why
//  Apple Music tracks can't be synced.
//

import SwiftUI

struct MusicImportSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var catalog: MusicAppCatalog?
    @State private var error: String?
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var importPlaylists = true
    @State private var isImporting = false
    @State private var pendingDownloads = Set<String>()
    @State private var downloadNote: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var sortOrder = [KeyPathComparator(\MusicAppItem.artist), KeyPathComparator(\MusicAppItem.album), KeyPathComparator(\MusicAppItem.trackNumber)]

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case ready = "Ready to sync"
        case appleMusic = "Apple Music"
        case notDownloaded = "Not downloaded"
        var id: String { rawValue }
    }

    private var visible: [MusicAppItem] {
        guard let catalog else { return [] }
        var items = catalog.items
        switch filter {
        case .all: break
        case .ready: items = items.filter { $0.status.canImport }
        case .appleMusic: items = items.filter { $0.status == .appleMusic || $0.status == .protected }
        case .notDownloaded: items = items.filter { $0.status == .notDownloaded }
        }
        if !search.isEmpty {
            let q = search.lowercased()
            items = items.filter { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.album.lowercased().contains(q) }
        }
        return items.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 860, height: 620)
        .task { await load() }
        .onDisappear { refreshTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Import from Music").font(.title2.bold())
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            if let c = catalog {
                let counts = c.counts
                HStack(spacing: 14) {
                    statChip("\(counts[.ready, default: 0] + counts[.video, default: 0]) ready", color: .green)
                    statChip("\(counts[.appleMusic, default: 0] + counts[.protected, default: 0]) Apple Music / protected", color: .orange)
                    statChip("\(counts[.notDownloaded, default: 0]) not downloaded", color: .gray)
                    if counts[.missingFile, default: 0] > 0 { statChip("\(counts[.missingFile, default: 0]) missing files", color: .red) }
                    Spacer()
                    Picker("", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 380)
                }
                Text("Songs from an Apple Music subscription are copy-protected and no iPod can play them. Songs you bought from the iTunes Store, ripped from CDs, or added as files sync fine. Songs that live only in iCloud show as “Not downloaded”: select them and click Download in Music, and they become ready once Music has fetched them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let downloadNote {
                    Label(downloadNote, systemImage: pendingDownloads.isEmpty ? "checkmark.circle" : "arrow.down.circle")
                        .font(.callout).foregroundStyle(pendingDownloads.isEmpty ? .green : .blue)
                }
            }
        }
        .padding(16)
    }

    private func statChip(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            EmptyStateView(icon: "exclamationmark.triangle", title: "Couldn't Read the Music Library", message: error)
        } else if catalog == nil {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading your Music library…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Title", value: \.title) { i in
                    HStack(spacing: 6) {
                        if i.mediaKind == .video { Image(systemName: "film").foregroundStyle(.secondary) }
                        Text(i.title).lineLimit(1).foregroundStyle(i.status.canImport ? .primary : .secondary)
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Artist", value: \.artist) { i in Text(i.artist).lineLimit(1).foregroundStyle(i.status.canImport ? .primary : .secondary) }
                TableColumn("Album", value: \.album) { i in Text(i.album).lineLimit(1).foregroundStyle(i.status.canImport ? .primary : .secondary) }
                TableColumn("Time", value: \.durationMs) { i in Text(Format.duration(ms: i.durationMs)).monospacedDigit() }.width(60)
                TableColumn("Status") { i in
                    Text(i.status.label).foregroundStyle(statusColor(i.status))
                }
                .width(min: 110, ideal: 160)
            }
        }
    }

    private func statusColor(_ s: MusicItemStatus) -> Color {
        switch s {
        case .ready, .video: return .green
        case .appleMusic, .protected: return .orange
        case .notDownloaded: return .gray
        case .missingFile: return .red
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Also import playlists", isOn: $importPlaylists)
            Spacer()
            if isImporting {
                ProgressView().controlSize(.small)
                Text(library.importStatus ?? "Importing…").foregroundStyle(.secondary)
            } else if let c = catalog {
                let readyCount = c.items.filter { $0.status.canImport }.count
                let selectedReady = c.items.filter { selection.contains($0.id) && $0.status.canImport }.count
                let selectedCloud = c.items.filter { selection.contains($0.id) && $0.status == .notDownloaded }.count
                Text(selectedReady > 0 ? "\(selectedReady) selected" : "").foregroundStyle(.secondary)
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Re-read the Music library")
                if selectedCloud > 0 {
                    Button("Download in Music (\(selectedCloud))") { downloadSelected(c) }
                        .help("Ask the Music app to download these songs from iCloud")
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import Selected") { Task { await importItems(c.items.filter { selection.contains($0.id) }) } }
                    .disabled(selectedReady == 0)
                Button("Import All Ready (\(readyCount))") { Task { await importItems(c.items.filter { $0.status.canImport }) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(readyCount == 0)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
    }

    private func downloadSelected(_ c: MusicAppCatalog) {
        let ids = c.items.filter { selection.contains($0.id) && $0.status == .notDownloaded }.map(\.id)
        let r = MusicDownloader.download(persistentIDs: ids)
        if let e = r.errorMessage {
            appState.alert = AlertMessage(title: "Couldn't Ask Music to Download", message: e)
            return
        }
        pendingDownloads.formUnion(ids)
        downloadNote = "Music is downloading \(r.requested) song\(r.requested == 1 ? "" : "s")… this list updates as they arrive." + (r.notFound > 0 ? " \(r.notFound) couldn't be found in Music." : "")
        refreshTask?.cancel()
        refreshTask = Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(8))
                if Task.isCancelled { return }
                await load()
                guard let cat = catalog else { continue }
                let still = pendingDownloads.filter { id in cat.items.first(where: { $0.id == id })?.status == .notDownloaded }
                pendingDownloads = still
                if still.isEmpty {
                    downloadNote = "Downloads finished — the songs are ready to import."
                    return
                }
            }
        }
    }

    private func load() async {
        do {
            catalog = try await library.loadMusicCatalog()
        } catch {
            self.error = error.localizedDescription + "\n\nIf macOS asked for permission to access your media library, allow it in System Settings › Privacy & Security › Media & Apple Music, then try again."
        }
    }

    private func importItems(_ items: [MusicAppItem]) async {
        guard let catalog else { return }
        isImporting = true
        let importable = items.filter { $0.status.canImport }
        let ids = Set(importable.map(\.id))
        let playlists = importPlaylists ? catalog.playlists.filter { pl in pl.itemIDs.contains(where: { ids.contains($0) }) } : []
        let summary = await library.importMusicItems(importable, playlists: playlists)
        isImporting = false
        dismiss()
        appState.alert = AlertMessage(title: "Music Library Imported", message: summary)
    }
}
