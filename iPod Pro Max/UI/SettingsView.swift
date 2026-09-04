//
//  SettingsView.swift
//  iPod Pro Max
//

import SwiftUI

struct SettingsView: View {
    @Environment(LibraryStore.self) private var envLibrary: LibraryStore?
    private var library: LibraryStore { envLibrary ?? AppServices.shared.library }
    @Environment(DeviceMonitor.self) private var envDevices: DeviceMonitor?
    private var devices: DeviceMonitor { envDevices ?? AppServices.shared.devices }
    @Environment(AppState.self) private var envAppState: AppState?
    private var appState: AppState { envAppState ?? AppServices.shared.appState }
    @AppStorage("ejectAfterSync") private var ejectAfterSync = false
    @AppStorage("syncArtwork") private var syncArtwork = true
    @AppStorage("defaultKeepLatest") private var defaultKeepLatest = 5

    var body: some View {
        TabView {
            Form {
                Section("Syncing") {
                    Toggle("Eject the iPod when a sync finishes", isOn: $ejectAfterSync)
                    Toggle("Sync album artwork", isOn: $syncArtwork)
                    Text("Artwork is converted to the iPod's native thumbnail sizes during each sync.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Podcasts") {
                    Picker("New subscriptions keep", selection: $defaultKeepLatest) {
                        Text("the latest episode").tag(1)
                        Text("the latest 3 episodes").tag(3)
                        Text("the latest 5 episodes").tag(5)
                        Text("the latest 10 episodes").tag(10)
                        Text("all episodes").tag(0)
                    }
                }
                Section("Library") {
                    LabeledContent("Location") {
                        HStack {
                            Text(library.baseDir.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([library.baseDir]) }
                        }
                    }
                    Text("Songs stay where they are on your Mac; the library only records their locations. Podcast downloads and converted files live here.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Section("Simulated iPod") {
                    Text("For testing without hardware, a folder with an iPod_Control directory can stand in for an iPod. iPod Pro Max writes a real database into it.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Create Test iPod Folder…") { createTestFolder() }
                        Button("Attach Existing Folder…") { attachFolder() }
                    }
                    ForEach(devices.simulatedFolders, id: \.self) { url in
                        HStack {
                            Text(url.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Detach") { devices.detachSimulatedFolder(url) }
                        }
                    }
                }
                Section("Remembered iPods") {
                    if library.deviceRecords.isEmpty {
                        Text("None yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(library.deviceRecords.values).sorted { $0.deviceName < $1.deviceName }, id: \.deviceID) { r in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(r.deviceName)
                                Text("\(r.trackDBIDs.count) songs, \(r.episodeDBIDs.count) episodes · last sync \(Format.relative(r.lastSync))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget") { library.forgetDevice(id: r.deviceID) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 420)
    }

    private func createTestFolder() {
        let panel = NSSavePanel()
        panel.title = "Create Test iPod"
        panel.nameFieldStringValue = "Test iPod"
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try IPodDevice.createSimulatedIPod(at: url, name: url.lastPathComponent)
            devices.attachSimulatedFolder(url)
        } catch {
            appState.alert = AlertMessage(title: "Couldn't Create Folder", message: error.localizedDescription)
        }
    }

    private func attachFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder that contains an iPod_Control directory."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if IPodDevice.detect(volume: url, simulated: true) == nil {
            appState.alert = AlertMessage(title: "Not an iPod Folder", message: "That folder has no iPod_Control directory. Use “Create Test iPod Folder…” to make one.")
            return
        }
        devices.attachSimulatedFolder(url)
    }
}
