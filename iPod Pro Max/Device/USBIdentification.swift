//
//  USBIdentification.swift
//  iPod Pro Max
//
//  Identifies an iPod from its USB product id when SysInfo is missing or empty (common on
//  iPods restored or synced by recent versions of iTunes / Finder).
//

import Foundation
import DiskArbitration
import IOKit

struct USBDeviceIdentity {
    let vendorID: Int
    let productID: Int
    let serialNumber: String?
    let productName: String?

    var isApple: Bool { vendorID == 0x05AC }

    /// Generation by Apple USB product id (from the USB ID repository and libgpod/podsleuth).
    var generation: IPodGeneration? {
        guard isApple else { return nil }
        switch productID {
        case 0x1201: return .third
        case 0x1202: return .second
        case 0x1203: return .fourth
        case 0x1204: return .photo
        case 0x1205: return .mini1
        case 0x1206: return .mini2
        case 0x1207: return .fourth
        case 0x1208: return .photo
        case 0x1209: return .video1
        case 0x120A: return .nano1
        case 0x1240, 0x1260: return .nano2
        case 0x1261: return .classic1
        case 0x1262: return .nano3
        case 0x1263: return .nano4
        case 0x1265: return .nano5
        case 0x1266: return .nano6
        case 0x1267: return .nano7
        case 0x1300: return .shuffle1
        case 0x1301: return .shuffle2
        case 0x1302: return .shuffle3
        case 0x1303: return .shuffle4
        case 0x1290, 0x1292, 0x1294, 0x1297, 0x129A, 0x129C, 0x12A0: return .iphone
        case 0x1291, 0x1293, 0x1299, 0x129E, 0x129F: return .touch
        default: return nil
        }
    }
}

enum USBIdentification {
    /// Walks from the mounted volume up the IORegistry to the USB device that hosts it.
    static func identify(volume: URL) -> USBDeviceIdentity? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL) else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }

        var entry: io_registry_entry_t = media
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        for _ in 0..<24 {
            if let vendor = property(entry, "idVendor") as? Int, let product = property(entry, "idProduct") as? Int {
                let serial = property(entry, "USB Serial Number") as? String ?? property(entry, "kUSBSerialNumberString") as? String
                let name = property(entry, "USB Product Name") as? String ?? property(entry, "kUSBProductString") as? String
                return USBDeviceIdentity(vendorID: vendor, productID: product, serialNumber: serial, productName: name)
            }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != IO_OBJECT_NULL else { return nil }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return value.takeRetainedValue()
    }
}
