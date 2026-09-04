//
//  PhotosView.swift
//  iPod Pro Max
//

import SwiftUI
import Photos

struct PhotosView: View {
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @State private var status = PhotosAccess.authorizationStatus
    @State private var albums: [PhotosAlbumInfo] = []
    @State private var allCount = 0
    @State private var isLoading = false

    var body: some View {
        Group {
            switch status {
            case .authorized, .limited:
                albumList
            case .denied, .restricted:
                EmptyStateView(icon: "photo.on.rectangle.angled", title: "Photos Access Is Off",
                               message: "Allow iPod Pro Max to read your Photos library in System Settings › Privacy & Security › Photos, then come back here to choose albums.") {
                    AnyView(HStack {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { NSWorkspace.shared.open(url) }
                        }
                        Button("Check Again") { Task { status = PhotosAccess.authorizationStatus; if PhotosAccess.isAuthorized { await load() } } }
                    })
                }
            default:
                EmptyStateView(icon: "photo.on.rectangle.angled", title: "Photos on Your iPod",
                               message: "Pick albums from the Photos app and iPod Pro Max copies them to the iPod's Photos menu, sized for its screen and for TV-out.") {
                    AnyView(Button("Choose Albums…") { Task { await requestAccess() } })
                }
            }
        }
        .navigationTitle("Photos")
        .navigationSubtitle(subtitle)
        .task {
            status = PhotosAccess.authorizationStatus
            if status == .notDetermined {
                await requestAccess()
            } else if PhotosAccess.isAuthorized {
                await load()
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!PhotosAccess.isAuthorized || isLoading)
            }
        }
    }

    private var subtitle: String {
        let sel = library.photoSelection
        if sel.isEmpty { return "No albums selected" }
        var n = sel.includeAllPhotos ? allCount : 0
        for a in albums where sel.albumIDs.contains(a.id) { n += a.count }
        let names = sel.includeAllPhotos ? 1 : sel.albumIDs.count
        return "\(names) selection\(names == 1 ? "" : "s"), about \(n) photos"
    }

    private var albumList: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { library.photoSelection.includeAllPhotos }, set: { v in
                    var s = library.photoSelection; s.includeAllPhotos = v; library.updatePhotoSelection(s)
                })) {
                    HStack {
                        Label("All Photos", systemImage: "photo.stack")
                        Spacer()
                        Text("\(allCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } footer: {
                Text("Photos are copied as iPod thumbnails (about 0.9 MB each on an iPod Video), so a large library takes a while and a fair amount of space.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Albums") {
                if isLoading && albums.isEmpty {
                    ProgressView().controlSize(.small)
                } else if albums.isEmpty {
                    Text("No albums found in Photos.").foregroundStyle(.secondary)
                }
                ForEach(albums) { a in
                    Toggle(isOn: Binding(get: { library.photoSelection.albumIDs.contains(a.id) }, set: { v in
                        var s = library.photoSelection
                        if v { if !s.albumIDs.contains(a.id) { s.albumIDs.append(a.id) } } else { s.albumIDs.removeAll { $0 == a.id } }
                        s.albumNames[a.id] = a.title
                        library.updatePhotoSelection(s)
                    })) {
                        HStack {
                            Label(a.title, systemImage: a.isSmart ? "sparkles.rectangle.stack" : "rectangle.stack")
                            Spacer()
                            Text("\(a.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func requestAccess() async {
        status = await PhotosAccess.requestAccess()
        if PhotosAccess.isAuthorized { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let (a, n) = await Task.detached(priority: .userInitiated) { (PhotosAccess.albums(), PhotosAccess.allPhotosCount()) }.value
        albums = a
        allCount = n
        status = PhotosAccess.authorizationStatus
    }
}
