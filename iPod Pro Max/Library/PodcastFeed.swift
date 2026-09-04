//
//  PodcastFeed.swift
//  iPod Pro Max
//
//  Minimal RSS / iTunes-namespace podcast feed parser.
//

import Foundation

struct ParsedFeed {
    var title: String = ""
    var author: String?
    var summary: String?
    var imageURL: URL?
    var episodes: [ParsedEpisode] = []
}

struct ParsedEpisode {
    var guid: String = ""
    var title: String = ""
    var summary: String?
    var publishedAt: Date?
    var durationMs: Int?
    var enclosureURL: URL?
    var enclosureLength: Int64?
    var mimeType: String?
    var episodeNumber: Int?
    var seasonNumber: Int?
    var imageURL: URL?
}

final class PodcastFeedParser: NSObject, XMLParserDelegate {
    private var feed = ParsedFeed()
    private var current: ParsedEpisode?
    private var path: [String] = []
    private var text = ""
    private var channelImageURLFromTag: URL?
    private var parseError: Error?

    static func parse(data: Data) throws -> ParsedFeed {
        let p = PodcastFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        if !parser.parse() {
            if let e = parser.parserError, p.feed.episodes.isEmpty { throw e }
        }
        if let e = p.parseError, p.feed.episodes.isEmpty { throw e }
        var feed = p.feed
        if feed.imageURL == nil { feed.imageURL = p.channelImageURLFromTag }
        if feed.title.isEmpty { throw IPodDBError.io("This doesn't look like a podcast feed.") }
        return feed
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        path.append(elementName.lowercased())
        text = ""
        let name = elementName.lowercased()
        if name == "item" {
            current = ParsedEpisode()
        } else if name == "enclosure", current != nil {
            if let u = attributes["url"].flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                current?.enclosureURL = u
            }
            current?.enclosureLength = attributes["length"].flatMap { Int64($0) }
            current?.mimeType = attributes["type"]
        } else if name == "itunes:image" {
            if let href = attributes["href"], let u = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)) {
                if current != nil { current?.imageURL = u } else if feed.imageURL == nil { feed.imageURL = u }
            }
        } else if name == "media:content", current != nil, current?.enclosureURL == nil {
            if let u = attributes["url"].flatMap({ URL(string: $0) }), (attributes["type"] ?? "").hasPrefix("audio") {
                current?.enclosureURL = u
                current?.mimeType = attributes["type"]
                current?.enclosureLength = attributes["fileSize"].flatMap { Int64($0) }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inItem = current != nil
        let parent = path.count >= 2 ? path[path.count - 2] : ""

        if inItem {
            switch name {
            case "item":
                if var ep = current {
                    if ep.guid.isEmpty { ep.guid = ep.enclosureURL?.absoluteString ?? ep.title }
                    if ep.title.isEmpty { ep.title = "Untitled Episode" }
                    if ep.enclosureURL != nil { feed.episodes.append(ep) }
                }
                current = nil
            case "title": if current?.title.isEmpty ?? true { current?.title = Self.stripHTML(value) }
            case "guid": current?.guid = value
            case "pubdate", "dc:date": if current?.publishedAt == nil { current?.publishedAt = DateParsing.parseRFC822(value) }
            case "itunes:duration": current?.durationMs = Self.parseDuration(value)
            case "itunes:summary": if current?.summary == nil { current?.summary = Self.stripHTML(value) }
            case "description": if current?.summary == nil || (current?.summary?.isEmpty ?? true) { current?.summary = Self.stripHTML(value) }
            case "content:encoded": if current?.summary == nil { current?.summary = Self.stripHTML(value) }
            case "itunes:episode": current?.episodeNumber = Int(value)
            case "itunes:season": current?.seasonNumber = Int(value)
            default: break
            }
        } else if parent == "channel" || path.count <= 3 {
            switch name {
            case "title": if feed.title.isEmpty && parent == "channel" { feed.title = Self.stripHTML(value) }
            case "itunes:author": if feed.author == nil { feed.author = value }
            case "managingeditor", "dc:creator": if feed.author == nil { feed.author = value }
            case "itunes:summary": if feed.summary == nil { feed.summary = Self.stripHTML(value) }
            case "description": if feed.summary == nil && parent == "channel" { feed.summary = Self.stripHTML(value) }
            case "url": if parent == "image", channelImageURLFromTag == nil { channelImageURLFromTag = URL(string: value) }
            default: break
            }
        }
        path.removeLast()
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = error
    }

    static func parseDuration(_ s: String) -> Int? {
        let parts = s.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        guard !parts.isEmpty else { return nil }
        var seconds = 0
        for p in parts { seconds = seconds * 60 + p }
        if parts.count == 1, let secs = Double(s.trimmingCharacters(in: .whitespaces)) { seconds = Int(secs) }
        return seconds > 0 ? seconds * 1000 : nil
    }

    static func stripHTML(_ s: String) -> String {
        var out = s
        if out.contains("<") {
            out = out.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            out = out.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            out = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        let entities: [(String, String)] = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&#8217;", "’"), ("&#8216;", "‘"), ("&#8220;", "“"), ("&#8221;", "”"), ("&#8230;", "…")]
        for (e, r) in entities { out = out.replacingOccurrences(of: e, with: r) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
