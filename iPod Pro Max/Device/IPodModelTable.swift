//
//  IPodModelTable.swift
//  iPod Pro Max
//
//  Model-number → generation table and per-generation capabilities (artwork formats, database
//  signature requirements). Data derived from libgpod's itdb_device.c.
//

import Foundation

enum IPodGeneration: String, Codable, CaseIterable {
    case unknown
    case first, second, third, fourth
    case photo
    case mini1, mini2
    case shuffle1, shuffle2, shuffle3, shuffle4
    case nano1, nano2, nano3, nano4, nano5, nano6, nano7
    case video1, video2
    case classic1, classic2, classic3
    case touch, iphone, ipad

    var displayName: String {
        switch self {
        case .unknown: return "iPod"
        case .first: return "iPod (1st generation)"
        case .second: return "iPod (2nd generation)"
        case .third: return "iPod (3rd generation)"
        case .fourth: return "iPod (4th generation)"
        case .photo: return "iPod photo / color"
        case .mini1: return "iPod mini"
        case .mini2: return "iPod mini (2nd generation)"
        case .shuffle1: return "iPod shuffle"
        case .shuffle2: return "iPod shuffle (2nd generation)"
        case .shuffle3: return "iPod shuffle (3rd generation)"
        case .shuffle4: return "iPod shuffle (4th generation)"
        case .nano1: return "iPod nano"
        case .nano2: return "iPod nano (2nd generation)"
        case .nano3: return "iPod nano (3rd generation)"
        case .nano4: return "iPod nano (4th generation)"
        case .nano5: return "iPod nano (5th generation)"
        case .nano6: return "iPod nano (6th generation)"
        case .nano7: return "iPod nano (7th generation)"
        case .video1: return "iPod (5th generation) with video"
        case .video2: return "iPod (5.5 generation) with video"
        case .classic1: return "iPod classic"
        case .classic2: return "iPod classic (120 GB)"
        case .classic3: return "iPod classic (160 GB, 2009)"
        case .touch: return "iPod touch"
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        }
    }

    /// What the app can do with this generation.
    var supportLevel: IPodSupportLevel {
        switch self {
        case .first, .second, .third, .fourth, .photo, .mini1, .mini2, .nano1, .nano2, .video1, .video2:
            return .full
        case .classic1, .classic2, .classic3, .nano3, .nano4:
            return .experimental
        case .unknown:
            return .experimental
        case .shuffle1, .shuffle2, .shuffle3, .shuffle4, .nano5, .nano6, .nano7, .touch, .iphone, .ipad:
            return .unsupported
        }
    }

    var checksum: IPodChecksumType {
        switch self {
        case .classic1, .classic2, .classic3, .nano3, .nano4: return .hash58
        case .nano5, .touch, .iphone: return .hash72
        case .nano6, .nano7, .ipad: return .hashAB
        default: return .none
        }
    }

    var supportsPodcasts: Bool {
        switch self {
        case .first, .second, .third: return false
        default: return true
        }
    }

    var supportsArtwork: Bool { !coverArtFormats.isEmpty }

    var supportsSparseArtwork: Bool {
        switch self {
        case .nano3, .nano4, .nano5, .classic1, .classic2, .classic3, .touch, .iphone, .ipad, .nano6, .nano7: return true
        default: return false
        }
    }

    /// Default number of F00.. music folders when the iPod has none yet.
    var defaultMusicFolderCount: Int {
        switch self {
        case .first, .second, .third: return 20
        case .mini1: return 6
        case .mini2: return 20
        case .nano1, .nano2: return 6
        case .nano3, .nano4, .nano5, .nano6, .nano7: return 14
        case .shuffle1, .shuffle2, .shuffle3, .shuffle4: return 3
        default: return 50
        }
    }

    var coverArtFormats: [ArtworkFormat] {
        switch self {
        case .photo:
            return [ArtworkFormat(id: 1017, width: 56, height: 56), ArtworkFormat(id: 1016, width: 140, height: 140)]
        case .video1, .video2:
            return [ArtworkFormat(id: 1028, width: 100, height: 100), ArtworkFormat(id: 1029, width: 200, height: 200)]
        case .nano1, .nano2:
            return [ArtworkFormat(id: 1031, width: 42, height: 42), ArtworkFormat(id: 1027, width: 100, height: 100)]
        case .nano3, .classic1, .classic2, .classic3:
            return [ArtworkFormat(id: 1061, width: 56, height: 56), ArtworkFormat(id: 1055, width: 128, height: 128),
                    ArtworkFormat(id: 1068, width: 128, height: 128), ArtworkFormat(id: 1060, width: 320, height: 320)]
        case .nano4:
            return [ArtworkFormat(id: 1055, width: 128, height: 128), ArtworkFormat(id: 1068, width: 128, height: 128),
                    ArtworkFormat(id: 1071, width: 240, height: 240), ArtworkFormat(id: 1074, width: 50, height: 50),
                    ArtworkFormat(id: 1078, width: 80, height: 80), ArtworkFormat(id: 1084, width: 240, height: 240)]
        default:
            return []
        }
    }
}

enum IPodSupportLevel {
    case full
    case experimental
    case unsupported
}

/// Album-art thumbnail format (RGB565 little-endian on every supported device).
struct ArtworkFormat: Hashable, Codable {
    let id: Int
    let width: Int
    let height: Int
    var bytesPerImage: Int { width * height * 2 }
}

struct IPodModelInfo: Hashable {
    let modelNumber: String
    let capacityGB: Double
    let generation: IPodGeneration
    let color: String?

    var marketingName: String {
        var name = generation.displayName
        if let color { name += " \(color)" }
        return name
    }

    var capacityDescription: String {
        if capacityGB < 1 { return "\(Int(capacityGB * 1024)) MB" }
        return "\(Int(capacityGB)) GB"
    }
}

enum IPodModelTable {
    private static let entries: [IPodModelInfo] = {
        func e(_ m: String, _ gb: Double, _ g: IPodGeneration, _ color: String? = nil) -> IPodModelInfo {
            IPodModelInfo(modelNumber: m, capacityGB: gb, generation: g, color: color)
        }
        return [
            // 1st generation
            e("8513", 5, .first), e("8541", 5, .first), e("8697", 5, .first), e("8709", 10, .first),
            // 2nd
            e("8737", 10, .second), e("8740", 10, .second), e("8738", 20, .second), e("8741", 20, .second),
            // 3rd
            e("8976", 10, .third), e("8946", 15, .third), e("9460", 15, .third), e("9244", 20, .third), e("8948", 30, .third), e("9245", 40, .third),
            // 4th
            e("9282", 20, .fourth), e("9787", 25, .fourth, "U2"), e("9268", 40, .fourth), e("E436", 40, .fourth, "HP"),
            // mini
            e("9160", 4, .mini1, "Silver"), e("9436", 4, .mini1, "Blue"), e("9435", 4, .mini1, "Pink"), e("9434", 4, .mini1, "Green"), e("9437", 4, .mini1, "Gold"),
            e("9800", 4, .mini2, "Silver"), e("9802", 4, .mini2, "Blue"), e("9804", 4, .mini2, "Pink"), e("9806", 4, .mini2, "Green"),
            e("9801", 6, .mini2, "Silver"), e("9803", 6, .mini2, "Blue"), e("9805", 6, .mini2, "Pink"), e("9807", 6, .mini2, "Green"),
            // photo / color
            e("A079", 20, .photo), e("A127", 20, .photo, "U2"), e("9829", 30, .photo), e("9585", 40, .photo), e("9830", 60, .photo), e("9586", 60, .photo), e("S492", 30, .photo, "HP"),
            // shuffle
            e("9724", 0.5, .shuffle1), e("9725", 1, .shuffle1),
            e("A546", 1, .shuffle2, "Silver"), e("A947", 1, .shuffle2, "Pink"), e("A949", 1, .shuffle2, "Blue"), e("A951", 1, .shuffle2, "Green"), e("A953", 1, .shuffle2, "Orange"), e("C167", 1, .shuffle2, "Gold"),
            e("B225", 1, .shuffle2, "Silver"), e("B233", 1, .shuffle2, "Purple"), e("B231", 1, .shuffle2, "Red"), e("B227", 1, .shuffle2, "Blue"), e("B228", 1, .shuffle2, "Blue"), e("B229", 1, .shuffle2, "Green"),
            e("B518", 2, .shuffle2, "Silver"), e("B520", 2, .shuffle2, "Blue"), e("B522", 2, .shuffle2, "Green"), e("B524", 2, .shuffle2, "Red"), e("B526", 2, .shuffle2, "Purple"),
            e("C306", 2, .shuffle3, "Silver"), e("C323", 2, .shuffle3, "Black"), e("C381", 2, .shuffle3, "Green"), e("C384", 2, .shuffle3, "Blue"), e("C387", 2, .shuffle3, "Pink"),
            e("B867", 4, .shuffle3, "Silver"), e("C164", 4, .shuffle3, "Black"), e("C303", 4, .shuffle3, "Stainless"), e("C307", 4, .shuffle3, "Green"), e("C328", 4, .shuffle3, "Blue"), e("C331", 4, .shuffle3, "Pink"),
            e("C584", 2, .shuffle4, "Silver"), e("C585", 2, .shuffle4, "Pink"), e("C749", 2, .shuffle4, "Orange"), e("C750", 2, .shuffle4, "Green"), e("C751", 2, .shuffle4, "Blue"),
            // nano 1G
            e("A350", 1, .nano1, "White"), e("A352", 1, .nano1, "Black"), e("A004", 2, .nano1, "White"), e("A099", 2, .nano1, "Black"), e("A005", 4, .nano1, "White"), e("A107", 4, .nano1, "Black"),
            // video 5G
            e("A002", 30, .video1, "White"), e("A146", 30, .video1, "Black"), e("A003", 60, .video1, "White"), e("A147", 60, .video1, "Black"), e("A452", 30, .video1, "U2"),
            // video 5.5G
            e("A444", 30, .video2, "White"), e("A446", 30, .video2, "Black"), e("A664", 30, .video2, "U2"), e("A448", 80, .video2, "White"), e("A450", 80, .video2, "Black"),
            // nano 2G
            e("A477", 2, .nano2, "Silver"), e("A426", 4, .nano2, "Silver"), e("A428", 4, .nano2, "Blue"), e("A487", 4, .nano2, "Green"), e("A489", 4, .nano2, "Pink"), e("A725", 4, .nano2, "Red"), e("A726", 8, .nano2, "Red"), e("A497", 8, .nano2, "Black"),
            // classic
            e("B029", 80, .classic1, "Silver"), e("B147", 80, .classic1, "Black"), e("B145", 160, .classic1, "Silver"), e("B150", 160, .classic1, "Black"),
            e("B562", 120, .classic2, "Silver"), e("B565", 120, .classic2, "Black"),
            e("C293", 160, .classic3, "Silver"), e("C297", 160, .classic3, "Black"),
            // nano 3G
            e("A978", 4, .nano3, "Silver"), e("A980", 8, .nano3, "Silver"), e("B261", 8, .nano3, "Black"), e("B249", 8, .nano3, "Blue"), e("B253", 8, .nano3, "Green"), e("B257", 8, .nano3, "Red"),
            // nano 4G
            e("B480", 4, .nano4, "Silver"), e("B651", 4, .nano4, "Blue"), e("B654", 4, .nano4, "Pink"), e("B657", 4, .nano4, "Purple"), e("B660", 4, .nano4, "Orange"), e("B663", 4, .nano4, "Green"), e("B666", 4, .nano4, "Yellow"),
            e("B598", 8, .nano4, "Silver"), e("B732", 8, .nano4, "Blue"), e("B735", 8, .nano4, "Pink"), e("B739", 8, .nano4, "Purple"), e("B742", 8, .nano4, "Orange"), e("B745", 8, .nano4, "Green"), e("B748", 8, .nano4, "Yellow"), e("B751", 8, .nano4, "Red"), e("B754", 8, .nano4, "Black"),
            e("B903", 16, .nano4, "Silver"), e("B905", 16, .nano4, "Blue"), e("B907", 16, .nano4, "Pink"), e("B909", 16, .nano4, "Purple"), e("B911", 16, .nano4, "Orange"), e("B913", 16, .nano4, "Green"), e("B915", 16, .nano4, "Yellow"), e("B917", 16, .nano4, "Red"), e("B918", 16, .nano4, "Black"),
            // nano 5G
            e("C027", 8, .nano5, "Silver"), e("C031", 8, .nano5, "Black"), e("C034", 8, .nano5, "Purple"), e("C037", 8, .nano5, "Blue"), e("C040", 8, .nano5, "Green"), e("C043", 8, .nano5, "Yellow"), e("C046", 8, .nano5, "Orange"), e("C049", 8, .nano5, "Red"), e("C050", 8, .nano5, "Pink"),
            e("C060", 16, .nano5, "Silver"), e("C062", 16, .nano5, "Black"), e("C064", 16, .nano5, "Purple"), e("C066", 16, .nano5, "Blue"), e("C068", 16, .nano5, "Green"), e("C070", 16, .nano5, "Yellow"), e("C072", 16, .nano5, "Orange"), e("C074", 16, .nano5, "Red"), e("C075", 16, .nano5, "Pink"),
            // nano 6G
            e("C525", 8, .nano6, "Silver"), e("C688", 8, .nano6, "Black"), e("C689", 8, .nano6, "Blue"), e("C690", 8, .nano6, "Green"), e("C691", 8, .nano6, "Orange"), e("C692", 8, .nano6, "Pink"), e("C693", 8, .nano6, "Red"),
            e("C526", 16, .nano6, "Silver"), e("C694", 16, .nano6, "Black"), e("C695", 16, .nano6, "Blue"), e("C696", 16, .nano6, "Green"), e("C697", 16, .nano6, "Orange"), e("C698", 16, .nano6, "Pink"), e("C699", 16, .nano6, "Red"),
            // touch
            e("A623", 8, .touch), e("A627", 16, .touch), e("B376", 32, .touch), e("B528", 8, .touch), e("B531", 16, .touch), e("B533", 32, .touch),
        ]
    }()

    private static let byModel: [String: IPodModelInfo] = {
        var d: [String: IPodModelInfo] = [:]
        for e in entries { d[e.modelNumber] = e }
        return d
    }()

    /// Looks up a model number string as found in SysInfo ("xA002", "MA002", "PA002" …).
    static func info(forModelNumber raw: String) -> IPodModelInfo? {
        var m = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let first = m.first, first.isLetter, m.count > 4 { m.removeFirst() }
        if m.count > 4 { m = String(m.suffix(4)) }
        return byModel[m]
    }
}
