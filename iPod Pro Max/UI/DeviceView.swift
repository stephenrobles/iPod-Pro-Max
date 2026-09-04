//
//  DeviceView.swift
//  iPod Pro Max
//

import SwiftUI

struct DeviceView: View {
    let device: IPodDevice
    @Environment(LibraryStore.self) private var library
    @Environment(DeviceMonitor.self) private var devices
    @Environment(SyncCoordinator.self) private var sync
    @Environment(AppState.self) private var appState

    @State private var contents: DeviceContents?
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var confirmImport = false
    @State private var confirmForget = false
    @State private var showLog = false

    struct DeviceContents {
        var songs = 0
        var podcasts = 0
        var videos = 0
        var musicBytes: Int64 = 0
        var podcastBytes: Int64 = 0
        var videoBytes: Int64 = 0
        var photoBytes: Int64 = 0
        var photos = 0
        var name = ""
        var readError: String?
    }

    private var record: DeviceSyncRecord { library.record(for: device) }
    private var status: SyncCoordinator.Status { sync.status(for: device) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if device.supportLevel == .unsupported {
                    unsupportedBanner
                } else if device.supportLevel == .experimental {
                    experimentalBanner
                }
                capacity
                syncPanel
                optionsPanel
                actionsPanel
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(displayName)
        .task(id: device.id) { await loadContents() }
        .onChange(of: status.finishedAt) { _, _ in Task { await loadContents() } }
        .alert("Rename iPod", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The new name is written to the iPod at the next sync.")
        }
        .confirmationDialog("Import songs from this iPod?", isPresented: $confirmImport) {
            Button("Import to Library") { Task { await importFromDevice() } }
        } message: {
            Text("Every song and podcast on the iPod is copied into ~/Music/iPod Pro Max and added to your library.")
        }
        .confirmationDialog("Forget this iPod?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { library.forgetDevice(id: device.id) }
        } message: {
            Text("iPod Pro Max forgets what it synced to this iPod. Nothing on the iPod is changed until the next sync, which will then treat every track as new.")
        }
    }

    private var displayName: String {
        if let n = contents?.name, !n.isEmpty { return n }
        if !record.deviceName.isEmpty, library.deviceRecords[device.id] != nil { return record.deviceName }
        return device.displayName
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(systemName: "ipod")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(Color.accentColor)
                .frame(width: 80, height: 80)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(displayName).font(.title.bold())
                    Button { newName = displayName; isRenaming = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Rename")
                }
                Text([device.displayModelName, device.capacityLabel].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if let s = device.serialNumber { Text("Serial \(s)") }
                    if device.isSimulated { Label("Simulated iPod folder", systemImage: "folder") }
                    if let last = record.lastSync { Text("Last synced \(Format.relative(last))") } else { Text("Never synced with iPod Pro Max") }
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var unsupportedBanner: some View {
        banner(color: .red, icon: "xmark.octagon.fill", title: "This iPod isn't supported yet",
               text: "\(device.displayModelName) needs a database signature that iPod Pro Max 1.0 can't produce. iPod Video, iPod nano (1st & 2nd gen), iPod photo, iPod mini and the original click-wheel iPods are fully supported.")
    }

    private var experimentalBanner: some View {
        banner(color: .orange, icon: "flask.fill", title: "Experimental support",
               text: device.generation == .unknown
               ? "iPod Pro Max couldn't identify this model from its SysInfo file. Syncing should work for classic click-wheel iPods, but album art may not display."
               : "\(device.displayModelName) uses a signed database. iPod Pro Max signs it, but this model hasn't been verified yet. Keep a backup of anything important on the iPod.")
    }

    private func banner(color: Color, icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var capacity: some View {
        let stats = device.volumeStats()
        let music = contents?.musicBytes ?? 0
        let podcasts = contents?.podcastBytes ?? 0
        let videos = contents?.videoBytes ?? 0
        let photos = contents?.photoBytes ?? 0
        let used = max(stats.used, music + podcasts + videos + photos)
        let other = max(used - music - podcasts - videos - photos, 0)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    if stats.total > 0 {
                        Rectangle().fill(Color.blue).frame(width: geo.size.width * CGFloat(music) / CGFloat(stats.total))
                        Rectangle().fill(Color.purple).frame(width: geo.size.width * CGFloat(podcasts) / CGFloat(stats.total))
                        Rectangle().fill(Color.orange).frame(width: geo.size.width * CGFloat(videos) / CGFloat(stats.total))
                        Rectangle().fill(Color.green).frame(width: geo.size.width * CGFloat(photos) / CGFloat(stats.total))
                        Rectangle().fill(Color.gray.opacity(0.6)).frame(width: geo.size.width * CGFloat(other) / CGFloat(stats.total))
                    }
                    Rectangle().fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 18) {
                legend(.blue, "Music", Format.bytes(music), detail: contents.map { "\($0.songs) songs" })
                legend(.purple, "Podcasts", Format.bytes(podcasts), detail: contents.map { "\($0.podcasts) episodes" })
                if videos > 0 { legend(.orange, "Videos", Format.bytes(videos), detail: contents.map { "\($0.videos)" }) }
                if photos > 0 { legend(.green, "Photos", Format.bytes(photos), detail: contents.map { "\($0.photos)" }) }
                legend(.gray, "Other", Format.bytes(other))
                legend(Color.secondary.opacity(0.3), "Free", Format.bytes(stats.free))
                Spacer()
                if stats.total > 0 { Text("\(Format.bytes(stats.total)) total").foregroundStyle(.secondary) }
            }
            .font(.caption)
            if let e = contents?.readError {
                Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func legend(_ color: Color, _ name: String, _ value: String, detail: String? = nil) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).bold()
            Text(value)
            if let detail { Text("(\(detail))").foregroundStyle(.secondary) }
        }
    }

    private var syncPanel: some View {
        let plan = planSummary
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.isRunning ? status.phase : "Ready to sync").font(.headline)
                        Text(status.isRunning ? status.detail : plan).foregroundStyle(.secondary).font(.callout).lineLimit(2)
                    }
                    Spacer()
                    if status.isRunning {
                        Button("Cancel") { sync.cancel(device) }
                    } else {
                        Button {
                            sync.startSync(device)
                        } label: {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath").frame(minWidth: 80)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(device.supportLevel == .unsupported || library.isImporting)
                    }
                }
                if status.isRunning {
                    ProgressView(value: status.fraction).progressViewStyle(.linear)
                } else if let err = status.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                } else if let summary = status.lastSummary {
                    Label(summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
                if !status.log.isEmpty {
                    DisclosureGroup("Details", isExpanded: $showLog) {
                        ScrollView {
                            Text(status.log.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                    }
                    .font(.callout)
                }
            }
            .padding(6)
        }
    }

    private var planSummary: String {
        let all = library.tracksToSync(for: record)
        let tracks = all.filter { !$0.isVideo }
        let videos = all.filter { $0.isVideo }
        let bytes = tracks.reduce(Int64(0)) { $0 + $1.fileSize }
        var parts = ["\(tracks.count) song\(tracks.count == 1 ? "" : "s") (\(Format.bytes(bytes)))"]
        if !videos.isEmpty { parts.append("\(videos.count) video\(videos.count == 1 ? "" : "s")") }
        if record.photosEnabled && device.generation.supportsPhotos && !library.photoSelection.isEmpty {
            parts.append("photos from \(library.photoSelection.includeAllPhotos ? "your whole library" : "\(library.photoSelection.albumIDs.count) album\(library.photoSelection.albumIDs.count == 1 ? "" : "s")")")
        }
        if record.syncPodcasts && device.supportsPodcasts {
            let eps = library.shows.reduce(0) { $0 + $1.episodesToSync().count }
            parts.append("\(eps) podcast episode\(eps == 1 ? "" : "s")")
        }
        let pls = library.playlistsToSync(for: record).count
        if pls > 0 { parts.append("\(pls) playlist\(pls == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private var optionsPanel: some View {
        GroupBox("Sync Options") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Music", selection: Binding(get: { record.syncAllMusic }, set: { v in var r = record; r.syncAllMusic = v; library.updateRecord(r) })) {
                    Text("Entire library").tag(true)
                    Text("Selected playlists").tag(false)
                }
                .pickerStyle(.radioGroup)
                if !record.syncAllMusic {
                    if library.playlists.isEmpty {
                        Text("No playlists yet. Create one from the Music view.").font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(library.playlists) { pl in
                                Toggle(pl.name, isOn: Binding(get: { record.selectedPlaylistIDs.contains(pl.id) }, set: { v in
                                    var r = record
                                    if v { r.selectedPlaylistIDs.insert(pl.id) } else { r.selectedPlaylistIDs.remove(pl.id) }
                                    library.updateRecord(r)
                                }))
                            }
                        }
                        .padding(.leading, 20)
                    }
                }
                Divider()
                Toggle("Sync podcasts", isOn: Binding(get: { record.syncPodcasts }, set: { v in var r = record; r.syncPodcasts = v; library.updateRecord(r) }))
                    .disabled(!device.supportsPodcasts)
                if !device.supportsPodcasts {
                    Text("This iPod's firmware has no Podcasts menu.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Sync videos", isOn: Binding(get: { record.videosEnabled }, set: { v in var r = record; r.syncVideos = v; library.updateRecord(r) }))
                Toggle("Sync photos", isOn: Binding(get: { record.photosEnabled }, set: { v in var r = record; r.syncPhotos = v; library.updateRecord(r) }))
                    .disabled(!device.generation.supportsPhotos)
                if !device.generation.supportsPhotos {
                    Text("This iPod has no color screen for photos.").font(.caption).foregroundStyle(.secondary)
                } else if library.photoSelection.isEmpty {
                    Text("Choose albums in the Photos section of the sidebar.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Remove songs that aren't in this library", isOn: Binding(get: { record.removeUnknownTracks }, set: { v in var r = record; r.removeUnknownTracks = v; library.updateRecord(r) }))
                Text("When on, songs that were put on the iPod by iTunes or another Mac are deleted during sync so the iPod mirrors this library. Turn it off to keep them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
    }

    private var actionsPanel: some View {
        HStack(spacing: 12) {
            Button { Task { do { try await devices.eject(device) } catch { appState.alert = AlertMessage(title: "Couldn't Eject", message: error.localizedDescription) } } } label: {
                Label(device.isSimulated ? "Detach Folder" : "Eject", systemImage: "eject")
            }
            .disabled(status.isRunning)
            Button { confirmImport = true } label: { Label("Import Songs from iPod…", systemImage: "square.and.arrow.down") }
                .disabled(status.isRunning || (contents?.songs ?? 0) + (contents?.podcasts ?? 0) == 0)
            Button { NSWorkspace.shared.activateFileViewerSelecting([device.mountPoint]) } label: { Label("Show in Finder", systemImage: "folder") }
            Spacer()
            Button(role: .destructive) { confirmForget = true } label: { Text("Forget iPod") }
                .disabled(status.isRunning || library.deviceRecords[device.id] == nil)
        }
    }

    // MARK: Actions

    private func loadContents() async {
        let dev = device
        let result: DeviceContents = await Task.detached(priority: .utility) {
            var c = DeviceContents()
            do {
                let db = try dev.readDatabase()
                c.name = db.name
                for t in db.tracks {
                    if t.isPodcast { c.podcasts += 1; c.podcastBytes += Int64(t.fileSize) }
                    else if t.mediaType & IPodMediaType.movie != 0 || t.mediaType & IPodMediaType.musicVideo != 0 || t.mediaType & IPodMediaType.tvShow != 0 { c.videos += 1; c.videoBytes += Int64(t.fileSize) }
                    else { c.songs += 1; c.musicBytes += Int64(t.fileSize) }
                }
                let photosDir = dev.mountPoint.appendingPathComponent("Photos")
                if let e = FileManager.default.enumerator(at: photosDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                    while let f = e.nextObject() as? URL {
                        c.photoBytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }
                if let data = try? Data(contentsOf: photosDir.appendingPathComponent("Photo Database")), data.count > 0x84 {
                    let r = ByteReader(data)
                    // mhfd → first mhsd (type 1) → mhli holds the photo count.
                    let mhsd = Int(r.u32(4))
                    if r.hasHeader("mhsd", at: mhsd), r.hasHeader("mhli", at: mhsd + 0x60) { c.photos = Int(r.u32(mhsd + 0x60 + 8)) }
                }
            } catch {
                c.readError = "The iPod's database couldn't be read (\(error.localizedDescription)). Syncing will rebuild it."
            }
            return c
        }.value
        contents = result
        if !result.name.isEmpty, record.deviceName != result.name {
            var r = record
            r.deviceName = result.name
            library.updateRecord(r)
        }
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var r = record
        r.deviceName = name
        library.updateRecord(r)
        contents?.name = name
        // Write the name immediately so it also shows up if the user never syncs.
        let dev = device
        Task.detached(priority: .utility) {
            guard var db = try? dev.readDatabase() else { return }
            db.name = name
            guard let out = try? ITunesDBWriter(database: db, checksum: dev.checksumType, firewireID: dev.firewireIDBytes).write() else { return }
            try? FileManager.default.createDirectory(at: dev.iTunesDir, withIntermediateDirectories: true)
            try? out.data.write(to: dev.iTunesDBURL, options: .atomic)
        }
    }

    private func importFromDevice() async {
        do {
            let n = try await sync.importFromDevice(device)
            appState.alert = AlertMessage(title: "Import Complete", message: "Added \(n) song\(n == 1 ? "" : "s") to your library.")
        } catch {
            appState.alert = AlertMessage(title: "Import Failed", message: error.localizedDescription)
        }
    }
}
