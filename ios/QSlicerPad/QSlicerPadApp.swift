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
            RootView()
                .environmentObject(model)
                // Reconstruit l'interface quand la langue change dans les réglages.
                .id(model.languageVersion)
                // « Ouvrir dans QSlicerPad » (Fichiers, Mail, AirDrop…) : importer le fichier.
                .onOpenURL { url in
                    _ = model.acceptDroppedFiles([url])
                }
        }
    }
}
