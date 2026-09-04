//
//  ContentView.swift
//  iPod Pro Max
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceMonitor.self) private var devices
    @Environment(SyncCoordinator.self) private var sync
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .sheet(isPresented: $appState.showNewPlaylist) {
            NewPlaylistSheet()
        }
        .sheet(isPresented: $appState.showAddPodcast) {
            AddPodcastSheet()
        }
        .sheet(isPresented: $appState.showMusicImport) {
            MusicImportSheet()
        }
        .alert(item: $appState.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
        .modifier(MenuRequestHandler(currentDevice: currentDevice))
        .onAppear {
            if appState.selection == nil, let d = devices.devices.first { appState.selection = .device(d.id) }
        }
        .onChange(of: devices.devices) { old, new in
            handleDeviceChange(old: old, new: new)
        }
        .onChange(of: library.lastError) { _, e in
            if let e {
                appState.alert = AlertMessage(title: "Something Went Wrong", message: e)
                library.lastError = nil
            }
        }
    }

    private func handleDeviceChange(old: [IPodDevice], new: [IPodDevice]) {
        // Jump to a newly connected iPod; fall back to Music when the selected one disappears.
        let initial = UserDefaults.standard.string(forKey: "initialSelection")
        let pinned = initial != nil && initial != "device" && old.isEmpty
        if pinned { return }
        if let added = new.first(where: { d in !old.contains(where: { $0.id == d.id }) }) {
            appState.selection = .device(added.id)
        } else if case .device(let id) = appState.selection, !new.contains(where: { $0.id == id }) {
            appState.selection = .music
        }
    }

    private var currentDevice: IPodDevice? {
        if case .device(let id) = appState.selection { return devices.device(id: id) }
        return nil
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case .device(let id):
            if let d = devices.device(id: id) {
                DeviceView(device: d)
            } else {
                WelcomeView()
            }
        case .music:
            MusicView()
        case .videos:
            VideosView()
        case .podcasts:
            PodcastsView()
        case .photos:
            PhotosView()
        case .playlist(let id):
            if let pl = library.playlists.first(where: { $0.id == id }) {
                PlaylistView(playlistID: pl.id)
            } else {
                MusicView()
            }
        case nil:
            WelcomeView()
        }
    }
}

/// Turns menu-bar requests (flags on AppState) into actions.
struct MenuRequestHandler: ViewModifier {
    let currentDevice: IPodDevice?
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceMonitor.self) private var devices
    @Environment(SyncCoordinator.self) private var sync
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.requestAddFiles) { _, v in
                guard v else { return }
                appState.requestAddFiles = false
                Task { await FileImportActions.addFiles(library: library) }
            }
            .onChange(of: appState.requestMusicImport) { _, v in
                guard v else { return }
                appState.requestMusicImport = false
                appState.showMusicImport = true
            }
            .onChange(of: appState.requestRefreshPodcasts) { _, v in
                guard v else { return }
                appState.requestRefreshPodcasts = false
                Task { await library.refreshAllShows() }
            }
            .onChange(of: appState.requestSync) { _, v in
                guard v else { return }
                appState.requestSync = false
                startSync()
            }
            .onChange(of: appState.requestEject) { _, v in
                guard v else { return }
                appState.requestEject = false
                eject()
            }
    }

    private func startSync() {
        if let d = currentDevice {
            sync.startSync(d)
        } else if let d = devices.devices.first {
            appState.selection = .device(d.id)
            sync.startSync(d)
        } else {
            appState.alert = AlertMessage(title: "No iPod Connected", message: "Plug in an iPod to sync.")
        }
    }

    private func eject() {
        guard let d = currentDevice ?? devices.devices.first else { return }
        Task {
            do { try await devices.eject(d) } catch { appState.alert = AlertMessage(title: "Couldn't Eject", message: error.localizedDescription) }
        }
    }
}

struct SidebarView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceMonitor.self) private var devices
    @Environment(SyncCoordinator.self) private var sync
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        List(selection: $appState.selection) {
            Section("iPods") {
                if devices.devices.isEmpty {
                    Label("No iPod connected", systemImage: "ipod")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(devices.devices) { d in
                        HStack {
                            Label(deviceName(d), systemImage: "ipod")
                            Spacer()
                            if sync.isSyncing(d) {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .tag(SidebarItem.device(d.id))
                        .contextMenu {
                            Button("Sync") { sync.startSync(d) }.disabled(sync.isSyncing(d))
                            Button("Eject") { Task { try? await devices.eject(d) } }
                        }
                    }
                }
            }
            Section("Library") {
                Label("Music", systemImage: "music.note").tag(SidebarItem.music)
                Label("Videos", systemImage: "film").tag(SidebarItem.videos)
                Label("Podcasts", systemImage: "antenna.radiowaves.left.and.right").tag(SidebarItem.podcasts)
                Label("Photos", systemImage: "photo.on.rectangle.angled").tag(SidebarItem.photos)
            }
            Section("Playlists") {
                ForEach(library.playlists) { pl in
                    Label(pl.name, systemImage: "music.note.list")
                        .tag(SidebarItem.playlist(pl.id))
                        .contextMenu {
                            Button("Delete Playlist", role: .destructive) {
                                library.deletePlaylist(id: pl.id)
                                if appState.selection == .playlist(pl.id) { appState.selection = .music }
                            }
                        }
                }
                Button {
                    appState.showNewPlaylist = true
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    private func deviceName(_ d: IPodDevice) -> String {
        library.deviceRecords[d.id]?.deviceName ?? d.displayName
    }
}

struct WelcomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "ipod")
                .font(.system(size: 72, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Connect an iPod")
                .font(.title.bold())
            Text("Plug in an iPod Video, nano, mini or photo with its USB cable. It will show up in the sidebar, and you can sync music, videos, podcasts and photos from your library.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            HStack {
                Button("Add Music…") { appState.requestAddFiles = true }
                Button("Import from Music App") { appState.requestMusicImport = true }
                Button("Add Podcast…") { appState.showAddPodcast = true }
            }
            .padding(.top, 8)
            if library.tracks.isEmpty && library.shows.isEmpty {
                Text("Your library is empty. Add some songs or podcasts to get started.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum FileImportActions {
    @MainActor
    static func addFiles(library: LibraryStore) async {
        let panel = NSOpenPanel()
        panel.title = "Add to Library"
        panel.message = "Choose music or video files (or folders) to add to your iPod Pro Max library."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie, .video, .folder, .mp3, .mpeg4Audio, .wav, .aiff, .mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video]
        guard panel.runModal() == .OK else { return }
        await library.importFiles(panel.urls)
    }
}

struct NewPlaylistSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var name = "New Playlist"
    var initialTrackIDs: [UUID] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Playlist").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        let pl = library.addPlaylist(name: name.trimmingCharacters(in: .whitespaces), trackIDs: initialTrackIDs)
        appState.selection = .playlist(pl.id)
        dismiss()
    }
}
