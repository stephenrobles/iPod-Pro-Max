//
//  Item.swift
//  iPod Pro Max
//
//  Created by Stephen Robles on 9/3/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
