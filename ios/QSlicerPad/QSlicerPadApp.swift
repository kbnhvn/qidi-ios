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
                // Recherche d'imprimantes : Bonjour (Network.framework) est fourni par l'app.
                .onAppear { model.bonjourHosts = { await BonjourBrowser.browse(seconds: $0) } }
                // « Ouvrir dans QSlicerPad » (Fichiers, Mail, AirDrop…) : importer le fichier.
                .onOpenURL { url in
                    _ = model.acceptDroppedFiles([url])
                }
        }
    }
}
