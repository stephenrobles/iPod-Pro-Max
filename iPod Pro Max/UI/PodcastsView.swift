//
//  PodcastsView.swift
//  iPod Pro Max
//

import SwiftUI

struct PodcastsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var appState
    @State private var selectedShowID: UUID?

    var body: some View {
        Group {
            if library.shows.isEmpty {
                EmptyStateView(icon: "antenna.radiowaves.left.and.right", title: "No Podcasts Yet",
                               message: "Subscribe to podcasts by searching or pasting an RSS feed. New episodes download automatically and sync to the iPod's Podcasts menu, complete with unplayed dots and resume positions.") {
                    AnyView(Button("Add Podcast…") { appState.showAddPodcast = true })
                }
            } else {
                HSplitView {
                    showList
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                    if let id = selectedShowID, let show = library.show(id: id) {
                        ShowDetailView(showID: show.id)
                            .frame(minWidth: 420)
                    } else {
                        Text("Select a podcast").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Podcasts")
        .toolbar {
            ToolbarItemGroup {
                Button { appState.showAddPodcast = true } label: { Label("Add Podcast", systemImage: "plus") }
                Button { Task { await library.refreshAllShows() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!library.refreshingShows.isEmpty)
                Button { Task { await library.downloadPendingEpisodes() } } label: { Label("Download New Episodes", systemImage: "arrow.down.circle") }
                    .disabled(library.pendingEpisodeDownloads.isEmpty)
                    .help("Download the episodes that will sync to the iPod")
            }
        }
        .onAppear { if selectedShowID == nil { selectedShowID = library.shows.first?.id } }
        .onChange(of: library.shows.count) { _, _ in
            if selectedShowID == nil || library.show(id: selectedShowID!) == nil { selectedShowID = library.shows.first?.id }
        }
    }

    private var showList: some View {
        List(selection: $selectedShowID) {
            ForEach(library.shows) { show in
                HStack(spacing: 10) {
                    ArtworkThumb(key: show.artworkKey, size: 40, cornerRadius: 6, placeholder: "antenna.radiowaves.left.and.right")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(show.title).lineLimit(1)
                        let downloaded = show.episodes.filter(\.isDownloaded).count
                        Text("\(show.episodes.count) episodes · \(downloaded) downloaded").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if library.refreshingShows.contains(show.id) { ProgressView().controlSize(.small) }
                    else if !show.syncEnabled { Image(systemName: "pause.circle").foregroundStyle(.secondary).help("Not syncing") }
                }
                .tag(show.id)
                .contextMenu {
                    Button("Refresh") { Task { await library.refreshShow(id: show.id) } }
                    Button("Unsubscribe", role: .destructive) { library.unsubscribe(showID: show.id) }
                }
            }
        }
        .listStyle(.inset)
    }
}

struct ShowDetailView: View {
    let showID: UUID
    @Environment(LibraryStore.self) private var library
    @State private var confirmUnsubscribe = false

    private var show: PodcastShow? { library.show(id: showID) }

    var body: some View {
        if let show {
            let syncSet = Set(show.episodesToSync().map(\.id))
            VStack(spacing: 0) {
                header(show)
                Divider()
                List {
                    ForEach(show.sortedEpisodes) { ep in
                        EpisodeRow(show: show, episode: ep, willSync: syncSet.contains(ep.id))
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func header(_ show: PodcastShow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ArtworkThumb(key: show.artworkKey, size: 88, cornerRadius: 10, placeholder: "antenna.radiowaves.left.and.right")
                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title).font(.title2.bold()).lineLimit(2)
                    if let a = show.author { Text(a).foregroundStyle(.secondary) }
                    if let s = show.summary, !s.isEmpty {
                        Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    }
                    Text("Updated \(Format.relative(show.lastRefreshed))").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle("Sync to iPod", isOn: Binding(get: { show.syncEnabled }, set: { v in var s = show; s.syncEnabled = v; library.updateShow(s) }))
                    .toggleStyle(.switch).controlSize(.small)
                HStack(spacing: 6) {
                    Text("Keep")
                    Picker("Keep", selection: Binding(get: { show.keepLatest }, set: { v in var s = show; s.keepLatest = v; library.updateShow(s) })) {
                        Text("latest episode").tag(1)
                        Text("latest 3").tag(3)
                        Text("latest 5").tag(5)
                        Text("latest 10").tag(10)
                        Text("latest 25").tag(25)
                        Text("all episodes").tag(0)
                    }
                    .labelsHidden().frame(width: 150)
                }
                Spacer()
                Button {
                    Task { await library.refreshShow(id: show.id) }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(library.refreshingShows.contains(show.id))
                Button(role: .destructive) { confirmUnsubscribe = true } label: { Label("Unsubscribe", systemImage: "trash") }
            }
            .font(.callout)
        }
        .padding(16)
        .confirmationDialog("Unsubscribe from “\(show.title)”?", isPresented: $confirmUnsubscribe) {
            Button("Unsubscribe", role: .destructive) { library.unsubscribe(showID: show.id) }
        } message: {
            Text("Downloaded episodes will be deleted from your Mac. Episodes already on the iPod are removed at the next sync.")
        }
    }
}

struct EpisodeRow: View {
    let show: PodcastShow
    let episode: PodcastEpisode
    let willSync: Bool
    @Environment(LibraryStore.self) private var library
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(episode.played ? Color.clear : Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
                    .help(episode.played ? "Played" : "Unplayed")
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title).lineLimit(expanded ? nil : 1)
                    HStack(spacing: 8) {
                        Text(Format.shortDate(episode.publishedAt))
                        if let d = episode.durationMs { Text(Format.duration(ms: d)) }
                        if let s = episode.fileSize ?? episode.enclosureLength { Text(Format.bytes(s)) }
                        if episode.isDownloaded {
                            Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        if willSync {
                            Label("Syncs", systemImage: "ipod").foregroundStyle(.blue)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if expanded, let s = episode.summary, !s.isEmpty {
                        Text(s).font(.callout).foregroundStyle(.secondary).padding(.top, 4).textSelection(.enabled)
                    }
                }
                Spacer()
                trailing
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { expanded.toggle() }
        .contextMenu {
            Button(expanded ? "Hide Description" : "Show Description") { expanded.toggle() }
            Divider()
            if episode.isDownloaded {
                Button("Delete Download") { library.deleteDownload(showID: show.id, episodeID: episode.id) }
            } else if library.isDownloading(episode.id) {
                Button("Cancel Download") { library.cancelDownload(episodeID: episode.id) }
            } else {
                Button("Download") { Task { await library.downloadEpisode(showID: show.id, episodeID: episode.id) } }
            }
            Menu("Sync") {
                Button("Follow show rule") { library.setEpisodeSync(showID: show.id, episodeID: episode.id, override: nil) }
                Button("Always sync this episode") { library.setEpisodeSync(showID: show.id, episodeID: episode.id, override: true) }
                Button("Never sync this episode") { library.setEpisodeSync(showID: show.id, episodeID: episode.id, override: false) }
            }
            Button(episode.played ? "Mark as Unplayed" : "Mark as Played") {
                library.setEpisodePlayed(showID: show.id, episodeID: episode.id, played: !episode.played)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let p = library.downloadProgress[episode.id] {
            HStack(spacing: 6) {
                ProgressView(value: p).progressViewStyle(.linear).frame(width: 80)
                Button { library.cancelDownload(episodeID: episode.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
            }
        } else if episode.isDownloaded {
            Button { library.deleteDownload(showID: show.id, episodeID: episode.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete download")
        } else {
            Button { Task { await library.downloadEpisode(showID: show.id, episodeID: episode.id) } } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.plain).help("Download")
        }
    }
}

struct AddPodcastSheet: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var isSubscribing = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Podcast").font(.headline)
                Spacer()
            }
            .padding([.top, .horizontal])
            HStack {
                TextField("Search podcasts or paste a feed URL", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await go() } }
                Button(isFeedURL ? "Subscribe" : "Search") { Task { await go() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching || isSubscribing)
            }
            .padding()
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal)
            }
            List(results) { r in
                HStack(spacing: 10) {
                    AsyncImage(url: r.artworkURL) { img in img.resizable() } placeholder: { Color.secondary.opacity(0.15) }
                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading) {
                        Text(r.name).lineLimit(1)
                        Text(r.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if library.shows.contains(where: { $0.feedURL == r.feedURL }) {
                        Text("Subscribed").foregroundStyle(.secondary)
                    } else {
                        Button("Subscribe") { Task { await subscribe(r.feedURL) } }.disabled(isSubscribing)
                    }
                }
            }
            .overlay {
                if isSearching || isSubscribing { ProgressView().controlSize(.large) }
                else if results.isEmpty && !isFeedURL {
                    Text("Search Apple Podcasts, or paste a feed URL.").foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 560, height: 460)
    }

    private var isFeedURL: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.hasPrefix("http://") || q.hasPrefix("https://") || q.hasPrefix("feed://")
    }

    private func go() async {
        error = nil
        if isFeedURL {
            var s = query.trimmingCharacters(in: .whitespaces)
            if s.lowercased().hasPrefix("feed://") { s = "https://" + s.dropFirst(7) }
            guard let url = URL(string: s) else { error = "That doesn't look like a valid URL."; return }
            await subscribe(url)
        } else {
            isSearching = true
            defer { isSearching = false }
            do { results = try await PodcastSearch.search(query) }
            catch { self.error = "Search failed: \(error.localizedDescription)" }
        }
    }

    private func subscribe(_ url: URL) async {
        isSubscribing = true
        defer { isSubscribing = false }
        do {
            _ = try await library.subscribe(feedURL: url)
            if isFeedURL { dismiss() }
        } catch {
            self.error = "Couldn't subscribe: \(error.localizedDescription)"
        }
    }
}

struct PodcastSearchResult: Identifiable, Decodable {
    var id: Int { collectionId }
    let collectionId: Int
    let collectionName: String?
    let artistName: String?
    let feedUrl: String?
    let artworkUrl100: String?

    var name: String { collectionName ?? "Untitled" }
    var artist: String { artistName ?? "" }
    var feedURL: URL { URL(string: feedUrl ?? "") ?? URL(string: "about:blank")! }
    var artworkURL: URL? { artworkUrl100.flatMap { URL(string: $0) } }
}

enum PodcastSearch {
    struct Response: Decodable { let results: [PodcastSearchResult] }

    static func search(_ term: String) async throws -> [PodcastSearchResult] {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [URLQueryItem(name: "media", value: "podcast"), URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "term", value: term)]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        let r = try JSONDecoder().decode(Response.self, from: data)
        return r.results.filter { $0.feedUrl != nil }
    }
}
