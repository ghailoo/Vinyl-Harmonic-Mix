//
//  Item.swift
//  VinylHarmonicMix
//
//  Created by Ghailen Ben Othman on 19/05/2026.
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
