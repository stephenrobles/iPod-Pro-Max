//
//  iPod_Pro_MaxApp.swift
//  iPod Pro Max
//
//  Created by Stephen Robles on 9/3/26.
//

import SwiftUI

@main
struct iPod_Pro_MaxApp: App {
    @State private var library: LibraryStore
    @State private var devices: DeviceMonitor
    @State private var sync: SyncCoordinator
    @State private var appState = AppState()

    init() {
        let l = LibraryStore()
        let d = DeviceMonitor()
        _library = State(initialValue: l)
        _devices = State(initialValue: d)
        _sync = State(initialValue: SyncCoordinator(library: l, devices: d))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(devices)
                .environment(sync)
                .environment(appState)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Playlist") { appState.showNewPlaylist = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Add Music or Videos to Library…") { appState.requestAddFiles = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Import from Music App…") { appState.showMusicImport = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Add Podcast…") { appState.showAddPodcast = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Refresh Podcasts") { appState.requestRefreshPodcasts = true }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("iPod") {
                Button("Sync") { appState.requestSync = true }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Eject") { appState.requestEject = true }
                    .keyboardShortcut("e", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Link("iPod Pro Max Help", destination: URL(string: "https://beard.fm")!)
            }
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(devices)
                .environment(sync)
                .environment(appState)
        }
    }
}

/// UI-level state shared between menus and views.
@MainActor
@Observable
final class AppState {
    var selection: SidebarItem? = {
        // Development aid: `-initialSelection device|podcasts|music`.
        switch UserDefaults.standard.string(forKey: "initialSelection") {
        case "podcasts": return .podcasts
        case "videos": return .videos
        case "photos": return .photos
        case "device": return nil
        default: return .music
        }
    }()
    var showNewPlaylist = false
    var showAddPodcast = false
    var showMusicImport = false
    var requestAddFiles = false
    var requestMusicImport = false
    var requestRefreshPodcasts = false
    var requestSync = false
    var requestEject = false
    var alert: AlertMessage?
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum SidebarItem: Hashable {
    case device(String)
    case music
    case videos
    case podcasts
    case photos
    case playlist(UUID)
}
