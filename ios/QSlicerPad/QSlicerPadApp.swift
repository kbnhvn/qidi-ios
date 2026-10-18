//
//  QSlicerPadApp.swift
//  Point d'entrée de l'app.
//

import SwiftUI

@main
struct QSlicerPadApp: App {
    @StateObject private var model = SlicerModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                // Reconstruit l'interface quand la langue change dans les réglages.
                .id(model.languageVersion)
        }
    }
}
