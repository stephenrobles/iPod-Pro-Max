//
//  MetadataExtractor.swift
//  iPod Pro Max
//
//  Reads tags, duration, bitrate and artwork from audio files with AVFoundation.
//

import Foundation
import AVFoundation
import CoreMedia

struct ExtractedMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var composer: String?
    var comment: String?
    var grouping: String?
    var year: Int = 0
    var trackNumber: Int = 0
    var trackCount: Int = 0
    var discNumber: Int = 0
    var discCount: Int = 0
    var durationMs: Int = 0
    var bitrate: Int = 0
    var sampleRate: Int = 44100
    var isLossless = false
    var compilation = false
    var bpm: Int = 0
    var artworkData: Data?
    var isPodcast = false
    var releaseDate: Date?
}

enum MetadataExtractor {
    static let audioExtensions: Set<String> = IPodFileType.nativeExtensions.union(IPodFileType.transcodableExtensions)

    static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    static func extract(from url: URL) async throws -> ExtractedMetadata {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var md = ExtractedMetadata()

        let duration = try await asset.load(.duration)
        if duration.isNumeric { md.durationMs = Int((CMTimeGetSeconds(duration) * 1000).rounded()) }

        // Audio track properties
        if let track = try await asset.loadTracks(withMediaType: .audio).first {
            let descs = try await track.load(.formatDescriptions)
            if let desc = descs.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                if asbd.mSampleRate > 0 { md.sampleRate = Int(asbd.mSampleRate) }
                if asbd.mFormatID == kAudioFormatAppleLossless || asbd.mFormatID == kAudioFormatFLAC || asbd.mFormatID == kAudioFormatLinearPCM {
                    md.isLossless = true
                }
            }
            let rate = try await track.load(.estimatedDataRate)
            if rate > 0 { md.bitrate = Int((rate / 1000).rounded()) }
        }
        if md.bitrate == 0, md.durationMs > 0, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            md.bitrate = Int((Double(size) * 8 / Double(md.durationMs)).rounded())
        }

        var items: [AVMetadataItem] = []
        let formats = try await asset.load(.availableMetadataFormats)
        for f in formats {
            items.append(contentsOf: try await asset.loadMetadata(for: f))
        }
        items.append(contentsOf: try await asset.load(.commonMetadata))

        for item in items {
            let id = item.identifier
            let key = item.commonKey
            func str() async -> String? {
                if let s = try? await item.load(.stringValue) { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let v = try? await item.load(.value) as? NSNumber { return v.stringValue }
                return nil
            }
            func num() async -> Int? {
                if let n = try? await item.load(.numberValue) { return n.intValue }
                if let s = await str(), let n = Int(s.split(separator: "/").first ?? "") { return n }
                return nil
            }
            func pair() async -> (Int, Int)? {
                if let d = try? await item.load(.dataValue), d.count >= 6 {
                    let b = [UInt8](d)
                    let n = Int(b[2]) << 8 | Int(b[3])
                    let total = Int(b[4]) << 8 | Int(b[5])
                    if n > 0 || total > 0 { return (n, total) }
                }
                if let s = await str() {
                    let parts = s.split(separator: "/")
                    let n = Int(parts.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
                    let total = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 : 0
                    if n > 0 || total > 0 { return (n, total) }
                }
                if let n = try? await item.load(.numberValue) { return (n.intValue, 0) }
                return nil
            }

            switch id {
            case .commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName:
                if md.title == nil { md.title = await str() }
            case .commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist:
                if md.artist == nil { md.artist = await str() }
            case .commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum:
                if md.album == nil { md.album = await str() }
            case .id3MetadataBand, .iTunesMetadataAlbumArtist:
                if md.albumArtist == nil { md.albumArtist = await str() }
            case .id3MetadataContentType, .iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre, .commonIdentifierType:
                if md.genre == nil {
                    if id == .iTunesMetadataPredefinedGenre, let n = try? await item.load(.numberValue) {
                        md.genre = ID3Genres.name(forIndex: n.intValue - 1)
                    } else if let s = await str(), !s.isEmpty {
                        md.genre = ID3Genres.normalize(s)
                    }
                }
            case .id3MetadataComposer, .iTunesMetadataComposer:
                if md.composer == nil { md.composer = await str() }
            case .id3MetadataComments, .iTunesMetadataUserComment, .commonIdentifierDescription:
                if md.comment == nil { md.comment = await str() }
            case .id3MetadataContentGroupDescription, .iTunesMetadataGrouping:
                if md.grouping == nil { md.grouping = await str() }
            case .id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate, .commonIdentifierCreationDate:
                if md.year == 0, let s = await str(), let y = Int(s.prefix(4)) { md.year = y }
                if md.releaseDate == nil, let s = await str() { md.releaseDate = DateParsing.parseISO(s) }
            case .id3MetadataTrackNumber, .iTunesMetadataTrackNumber:
                if md.trackNumber == 0, let p = await pair() { md.trackNumber = p.0; md.trackCount = p.1 }
            case .id3MetadataPartOfASet, .iTunesMetadataDiscNumber:
                if md.discNumber == 0, let p = await pair() { md.discNumber = p.0; md.discCount = p.1 }
            case .id3MetadataBeatsPerMinute, .iTunesMetadataBeatsPerMin:
                if md.bpm == 0, let n = await num() { md.bpm = n }
            case .iTunesMetadataDiscCompilation:
                if let n = await num() { md.compilation = n != 0 }
            case .commonIdentifierArtwork, .id3MetadataAttachedPicture, .iTunesMetadataCoverArt:
                if md.artworkData == nil, let d = try? await item.load(.dataValue), !d.isEmpty { md.artworkData = d }
            default:
                // Vorbis comments (FLAC/OGG) arrive with plain string keys.
                if let vk = (item.key as? String)?.uppercased(), item.keySpace == .init(rawValue: "vorb") || item.identifier?.rawValue.hasPrefix("vorb/") == true {
                    switch vk {
                    case "TITLE": if md.title == nil { md.title = await str() }
                    case "ARTIST": if md.artist == nil { md.artist = await str() }
                    case "ALBUM": if md.album == nil { md.album = await str() }
                    case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": if md.albumArtist == nil { md.albumArtist = await str() }
                    case "GENRE": if md.genre == nil { md.genre = await str() }
                    case "COMPOSER": if md.composer == nil { md.composer = await str() }
                    case "COMMENT", "DESCRIPTION": if md.comment == nil { md.comment = await str() }
                    case "GROUPING": if md.grouping == nil { md.grouping = await str() }
                    case "DATE", "YEAR", "ORIGINALDATE":
                        if md.year == 0, let s = await str(), let y = Int(s.prefix(4)) { md.year = y }
                    case "TRACKNUMBER": if md.trackNumber == 0, let p = await pair() { md.trackNumber = p.0; if p.1 > 0 { md.trackCount = p.1 } }
                    case "TRACKTOTAL", "TOTALTRACKS": if md.trackCount == 0, let n = await num() { md.trackCount = n }
                    case "DISCNUMBER": if md.discNumber == 0, let p = await pair() { md.discNumber = p.0; if p.1 > 0 { md.discCount = p.1 } }
                    case "DISCTOTAL", "TOTALDISCS": if md.discCount == 0, let n = await num() { md.discCount = n }
                    case "BPM": if md.bpm == 0, let n = await num() { md.bpm = n }
                    case "COMPILATION": if let n = await num() { md.compilation = n != 0 }
                    case "METADATA_BLOCK_PICTURE", "COVERART":
                        if md.artworkData == nil, let d = try? await item.load(.dataValue), !d.isEmpty { md.artworkData = d }
                    default: break
                    }
                    continue
                }
                if key == .commonKeyTitle, md.title == nil { md.title = await str() }
                else if key == .commonKeyArtist, md.artist == nil { md.artist = await str() }
                else if key == .commonKeyAlbumName, md.album == nil { md.album = await str() }
                else if key == .commonKeyArtwork, md.artworkData == nil, let d = try? await item.load(.dataValue) { md.artworkData = d }
                else if let raw = id?.rawValue {
                    if raw.hasSuffix("TCMP") || raw.hasSuffix("cpil"), let n = await num() { md.compilation = n != 0 }
                    else if raw.hasSuffix("pcst"), let n = await num() { md.isPodcast = n != 0 }
                    else if raw.hasSuffix("TPE2"), md.albumArtist == nil { md.albumArtist = await str() }
                    else if raw.hasSuffix("TSOA") || raw.hasSuffix("soal") { /* sort album: ignored */ }
                }
            }
        }

        if let t = md.title, t.isEmpty { md.title = nil }
        for kp in [\ExtractedMetadata.artist, \.album, \.albumArtist, \.genre, \.composer, \.comment, \.grouping] {
            if let v = md[keyPath: kp], v.isEmpty { md[keyPath: kp] = nil }
        }
        return md
    }

    /// Looks for a cover image next to the audio file (folder.jpg, cover.png, …).
    static func sidecarArtwork(for url: URL) -> Data? {
        let dir = url.deletingLastPathComponent()
        let names = ["cover", "folder", "front", "album", "artwork", "Cover", "Folder", "Front", "Album", "Artwork"]
        let exts = ["jpg", "jpeg", "png"]
        for n in names {
            for e in exts {
                let candidate = dir.appendingPathComponent("\(n).\(e)")
                if let d = try? Data(contentsOf: candidate), !d.isEmpty { return d }
            }
        }
        return nil
    }
}

enum DateParsing {
    private static let isoFormatters: [DateFormatter] = {
        let fmts = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "yyyy"]
        return fmts.map { f in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = f
            return df
        }
    }()

    static func parseISO(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for f in isoFormatters {
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    private static let rfc822Formatters: [DateFormatter] = {
        let fmts = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
                    "dd MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "EEE, dd MMM yyyy", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ss"]
        return fmts.map { f in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = f
            return df
        }
    }()

    static func parseRFC822(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for f in rfc822Formatters {
            if let d = f.date(from: trimmed) { return d }
        }
        return parseISO(trimmed)
    }
}

enum ID3Genres {
    static let names: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B",
        "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient",
        "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave",
        "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap",
        "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk",
        "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock", "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebob",
        "Latin", "Revival", "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock",
        "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass",
        "Primus", "Porn Groove", "Satire", "Slow Jam", "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
        "Duet", "Punk Rock", "Drum Solo", "A capella", "Euro-House", "Dance Hall",
    ]

    static func name(forIndex i: Int) -> String? {
        guard i >= 0, i < names.count else { return nil }
        return names[i]
    }

    /// Converts "(17)" style genre references into names.
    static func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")"), let n = Int(trimmed[trimmed.index(after: trimmed.startIndex)..<close]) {
            let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
            return name(forIndex: n) ?? trimmed
        }
        if let n = Int(trimmed), let name = name(forIndex: n) { return name }
        return trimmed
    }
}
