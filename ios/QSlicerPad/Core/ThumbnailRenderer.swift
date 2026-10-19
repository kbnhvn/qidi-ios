//
//  ThumbnailRenderer.swift
//  Fournisseur de vignettes du G-code (aperçu affiché par l'écran de l'imprimante). Le moteur
//  encode (QIDI/PNG, selon `thumbnails` du preset) ; l'hôte fournit les pixels. Le rendu est
//  logiciel (SoftwareThumbnail) : il s'exécute sur le thread de slicing, sans SceneKit ni Metal.
//

import Foundation

final class ThumbnailProvider {
    typealias Item = SoftwareThumbnail.Item

    private let items: [Item]
    private let boundsMin: Vec3
    private let boundsMax: Vec3

    init(items: [Item], boundsMin: Vec3, boundsMax: Vec3) {
        self.items = items
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
    }

    /// Rend `width`×`height` pixels RGBA (lignes de haut en bas). nil si rien à dessiner.
    func render(width: Int, height: Int) -> [UInt8]? {
        guard !items.isEmpty, width > 0, height > 0 else { return nil }
        return SoftwareThumbnail.render(items: items, boundsMin: boundsMin, boundsMax: boundsMax, width: width, height: height)
    }
}
