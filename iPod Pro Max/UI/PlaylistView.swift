//
//  PlaylistView.swift
//  iPod Pro Max
//

import SwiftUI

struct PlaylistView: View {
    let playlistID: UUID
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @State private var selection = Set<UUID>()
    @State private var showAddSongs = false
    @State private var isRenaming = false
    @State private var newName = ""

    private var playlist: LibraryPlaylist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        if let playlist {
            let tracks = library.tracks(in: playlist)
            VStack(spacing: 0) {
                header(playlist, tracks: tracks)
                Divider()
                if tracks.isEmpty {
                    EmptyStateView(icon: "music.note.list", title: "Empty Playlist", message: "Add songs from your library to this playlist. Playlists sync to the iPod with the same name and order.") {
                        AnyView(Button("Add Songs…") { showAddSongs = true })
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(tracks) { t in
                            HStack(spacing: 10) {
                                ArtworkThumb(url: library.artworkURL(t.artworkKey), size: 30, cornerRadius: 3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.title).lineLimit(1)
                                    Text("\(t.displayArtist) — \(t.displayAlbum)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if !t.syncEnabled {
                                    Text("not syncing").font(.caption).foregroundStyle(.orange)
                                }
                                Text(Format.duration(ms: t.durationMs)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .tag(t.id)
                            .contextMenu {
                                Button("Remove from Playlist") {
                                    library.removeTracks(selection.contains(t.id) ? selection : [t.id], fromPlaylist: playlist.id)
                                }
                            }
                        }
                        .onMove { from, to in library.moveTracks(in: playlist.id, from: from, to: to) }
                        .onDelete { offsets in
                            let ids = Set(offsets.map { tracks[$0].id })
                            library.removeTracks(ids, fromPlaylist: playlist.id)
                        }
                    }
                    .onDeleteCommand {
                        library.removeTracks(selection, fromPlaylist: playlist.id)
                        selection.removeAll()
                    }
                }
            }
            .navigationTitle(playlist.name)
            .toolbar {
                ToolbarItemGroup {
                    Toggle(isOn: Binding(get: { playlist.syncEnabled }, set: { v in
                        var p = playlist; p.syncEnabled = v
                        if let i = library.playlists.firstIndex(where: { $0.id == p.id }) { library.playlists[i] = p; library.scheduleSave() }
                    })) { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                    .help("Include this playlist when syncing all music")
                    Button { showAddSongs = true } label: { Label("Add Songs", systemImage: "plus") }
                    Button { newName = playlist.name; isRenaming = true } label: { Label("Rename", systemImage: "pencil") }
                }
            }
            .sheet(isPresented: $showAddSongs) {
                AddSongsSheet(playlistID: playlist.id)
            }
            .alert("Rename Playlist", isPresented: $isRenaming) {
                TextField("Name", text: $newName)
                Button("Rename") { library.renamePlaylist(id: playlist.id, to: newName) }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            WelcomeView()
        }
    }

    private func header(_ playlist: LibraryPlaylist, tracks: [LibraryTrack]) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15))
                Image(systemName: "music.note.list").font(.system(size: 28)).foregroundStyle(Color.accentColor)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name).font(.title2.bold())
                let ms = tracks.reduce(0) { $0 + $1.durationMs }
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s") · \(Format.duration(ms: ms))").foregroundStyle(.secondary)
                if playlist.musicPersistentID != nil {
                    Text("Imported from the Music app").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(16)
    }
}

struct AddSongsSheet: View {
    let playlistID: UUID
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()
    @State private var search = ""

    private var candidates: [LibraryTrack] {
        let inPlaylist = Set(library.playlists.first { $0.id == playlistID }?.trackIDs ?? [])
        var t = library.tracks.filter { !inPlaylist.contains($0.id) }
        if !search.isEmpty {
            let q = search.lowercased()
            t = t.filter { $0.title.lowercased().contains(q) || ($0.artist?.lowercased().contains(q) ?? false) || ($0.album?.lowercased().contains(q) ?? false) }
        }
        return t.sorted { ($0.artistForSort, $0.albumForSort, $0.discNumber, $0.trackNumber, $0.title) < ($1.artistForSort, $1.albumForSort, $1.discNumber, $1.trackNumber, $1.title) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Songs").font(.headline)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            .padding()
            Table(candidates, selection: $selection) {
                TableColumn("Title") { t in Text(t.title) }
                TableColumn("Artist") { t in Text(t.displayArtist) }
                TableColumn("Album") { t in Text(t.displayAlbum) }
                TableColumn("Time") { t in Text(Format.duration(ms: t.durationMs)) }.width(60)
            }
            Divider()
            HStack {
                Text("\(selection.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let ordered = candidates.filter { selection.contains($0.id) }.map(\.id)
                    library.addTracks(ordered, toPlaylist: playlistID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
            .padding()
        }
        .frame(width: 720, height: 480)
    }
}
