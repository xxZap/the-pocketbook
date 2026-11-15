//
//  the_pocketbookApp.swift
//  the pocketbook
//
//  Created by Alessio Boerio on 27/09/2026.
//

import SwiftData
import SwiftUI

@main
struct the_pocketbookApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Theme.rust)
                .preferredColorScheme(.light) // carta e inchiostro, sempre
        }
        .modelContainer(for: [Note.self, Tag.self, NoteImage.self])
    }
}
