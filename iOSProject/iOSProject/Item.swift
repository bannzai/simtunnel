//
//  Item.swift
//  iOSProject
//
//  Created by bannzai on 2026/07/05.
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
