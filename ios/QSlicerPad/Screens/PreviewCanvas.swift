//
//  PreviewCanvas.swift
//  Mode « Aperçu » : trajectoires du G-code (rubans), double curseur de couches,
//  légende par type avec durée et pourcentage, modes de couleur, déplacements.
//

import SwiftUI

struct PreviewCanvas: View {
    @EnvironmentObject private var model: SlicerModel

    /// Couches affichées (indices inclus) ; nil = toutes.
    @State private var lower = 0
    @State private var upper = Int.max
    @State private var legendOpen = true
    @State private var revision = 0
    @State private var topProgress = 1.0
    @State private var playing = false

    private var layerCount: Int { model.gcodeMesh?.layers.count ?? 0 }
    private var range: ClosedRange<Int> {
        let hi = min(upper, max(layerCount - 1, 0))
        return min(lower, hi)...hi
    }

    var body: some View {
        ZStack {
            GCodeSceneView(mesh: model.gcodeMesh, layerRange: range, bed: model.scene?.bed, revision: revision,
                           topProgress: topProgress)
                .ignoresSafeArea(edges: .bottom)

            if model.gcodeMesh == nil {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text(model.isSlicing ? L10n.t("Slicing…") : L10n.t("Aucun résultat : slicez le plateau."))
                        .foregroundStyle(.secondary)
                    if !model.isSlicing && model.canSlice {
                        Button { model.slice() } label: { Label(L10n.t("Slicer"), systemImage: "scissors").frame(minHeight: 44) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }

            VStack {
                Spacer()
                if layerCount > 1 { playbackBar }
            }
            .padding(10)
            .padding(.trailing, 94)

            HStack(alignment: .top) {
                VStack(spacing: 8) {
                    if model.resultIsStale {
                        Banner(icon: "exclamationmark.arrow.triangle.2.circlepath",
                               text: L10n.t("Aperçu obsolète : le plateau ou les réglages ont changé."),
                               action: L10n.t("Re-slicer"), perform: { model.slice() }, dismiss: nil)
                    }
                    LegendCard(open: $legendOpen)
                    Spacer()
                }
                .frame(maxWidth: 330)
                Spacer()
                if layerCount > 1 {
                    LayerRangeSlider(count: layerCount, lower: $lower, upper: Binding(
                        get: { min(upper, layerCount - 1) }, set: { upper = $0 }),
                        heights: model.gcodeMesh?.layers.map(\.z) ?? [])
                        .frame(width: 84)
                        .padding(.vertical, 8)
                }
            }
            .padding(10)
        }
        .onChange(of: model.gcodeMesh?.layers.count) { _, _ in
            upper = Int.max
            lower = 0
            topProgress = 1
            playing = false
        }
        .onChange(of: upper) { _, _ in if !playing { topProgress = 1 } }
        .task(id: playing) { await play() }
        .onChange(of: model.gcodeMeshGeneration) { _, _ in revision += 1 }
        .onAppear { revision += 1 }
    }
}

extension PreviewCanvas {
    /// Curseur de mouvements de la dernière couche, et lecture couche par couche.
    fileprivate var playbackBar: some View {
        HStack(spacing: 12) {
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.t(playing ? "Pause" : "Lecture"))
            Slider(value: $topProgress, in: 0...1) { Text(L10n.t("Mouvements")) }
            Text("\(Int(topProgress * 100)) %").font(.caption.monospacedDigit()).frame(width: 44)
        }
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: 520)
    }

    /// Avance de ~5 % de couche toutes les 33 ms ; passe à la couche suivante en fin de couche.
    @MainActor
    fileprivate func play() async {
        guard playing else { return }
        if upper >= layerCount - 1 && topProgress >= 1 { upper = lower; topProgress = 0 }
        while !Task.isCancelled && playing {
            try? await Task.sleep(nanoseconds: 33_000_000)
            topProgress += 0.05
            if topProgress >= 1 {
                let top = min(upper, layerCount - 1)
                if top < layerCount - 1 { upper = top + 1; topProgress = 0 }
                else { topProgress = 1; playing = false }
            }
        }
    }
}

// MARK: - Légende

struct LegendCard: View {
    @EnvironmentObject private var model: SlicerModel
    @Binding var open: Bool

    var body: some View {
        if let summary = model.summary {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation { open.toggle() } } label: {
                    HStack {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption)
                        Text(L10n.t("Légende")).font(.headline)
                        Spacer()
                        Text(summary.timeNormal.isEmpty ? formatDuration(seconds: summary.timeNormalS) : summary.timeNormal)
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 36)
                }
                .buttonStyle(.plain)

                if open {
                    Picker(L10n.t("Couleur"), selection: $model.colorMode) {
                        ForEach(GCodeColorMode.allCases) { Text(L10n.t($0.label)).tag($0) }
                    }
                    .pickerStyle(.menu)

                    if model.colorMode == .featureType {
                        let total = max(summary.roles.reduce(0) { $0 + $1.timeS }, 1)
                        ForEach(summary.roles, id: \.role) { role in
                            let kind = GCodeRole(rawValue: UInt8(role.role)) ?? .none
                            Button {
                                if model.hiddenRoles.contains(UInt8(role.role)) { model.hiddenRoles.remove(UInt8(role.role)) }
                                else { model.hiddenRoles.insert(UInt8(role.role)) }
                            } label: {
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(red: Double(kind.rgb.0) / 255, green: Double(kind.rgb.1) / 255, blue: Double(kind.rgb.2) / 255))
                                        .frame(width: 16, height: 16)
                                        .opacity(model.hiddenRoles.contains(UInt8(role.role)) ? 0.25 : 1)
                                    Text(L10n.t(kind.label)).font(.footnote).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(formatDuration(seconds: role.timeS)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(String(format: "%.0f %%", role.timeS / total * 100))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                                }
                                .frame(minHeight: 30)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } else if model.colorMode == .tool {
                        let colors = model.filamentColors
                        ForEach(Array(model.usedExtruders.enumerated()), id: \.offset) { _, tool in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(hex: tool < colors.count ? colors[tool] : "#999999"))
                                    .frame(width: 16, height: 16)
                                Text("T\(tool + 1)").font(.footnote.monospacedDigit())
                                if tool < model.extruderFilaments.count {
                                    Text(model.extruderFilaments[tool].components(separatedBy: " @").first ?? "")
                                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    } else if let range = model.gcodeMesh?.valueRange {
                        GradientLegend(low: range.min, high: range.max, unit: model.colorMode.unit)
                    }

                    Toggle(L10n.t("Déplacements à vide"), isOn: $model.showTravel).font(.footnote)

                    Divider()
                    LegendStat(L10n.t("Filament"), String(format: "%.1f g · %.2f m", summary.filamentG, summary.filamentMm / 1000))
                    if summary.cost > 0 { LegendStat(L10n.t("Coût"), String(format: "%.2f", summary.cost)) }
                    LegendStat(L10n.t("Couches"), "\(summary.layers)")
                    if model.gcodeMesh?.simplified == true {
                        Text(L10n.t("Fichier très volumineux : les remplissages internes ne sont pas dessinés dans l'aperçu (le G-code est complet)."))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct LegendStat: View {
    let title: String, value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        HStack { Text(title).font(.footnote).foregroundStyle(.secondary); Spacer(); Text(value).font(.footnote.monospacedDigit()) }
    }
}

struct GradientLegend: View {
    let low: Float, high: Float, unit: String
    var body: some View {
        VStack(spacing: 4) {
            LinearGradient(colors: (0...10).map { i -> Color in
                let c = gcodeRangeColor(Float(i) / 10)
                return Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255)
            }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack {
                Text(String(format: "%.2f", low)); Spacer(); Text(unit); Spacer(); Text(String(format: "%.2f", high))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Double curseur de couches

/// Curseur vertical à deux poignées (couche mini / maxi), comme celui du bureau.
struct LayerRangeSlider: View {
    let count: Int
    @Binding var lower: Int
    @Binding var upper: Int
    let heights: [Float]

    var body: some View {
        GeometryReader { geo in
            let trackTop: CGFloat = 40, trackBottom: CGFloat = geo.size.height - 40
            let span = max(trackBottom - trackTop, 1)
            func y(_ layer: Int) -> CGFloat { trackBottom - span * CGFloat(layer) / CGFloat(max(count - 1, 1)) }
            func layer(at y: CGFloat) -> Int {
                let t = (trackBottom - min(max(y, trackTop), trackBottom)) / span
                return Int((t * CGFloat(count - 1)).rounded())
            }

            ZStack(alignment: .top) {
                Capsule().fill(.regularMaterial).frame(width: 84)
                Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 6, height: span).position(x: 42, y: trackTop + span / 2)
                Capsule().fill(Color.accentColor).frame(width: 6, height: max(y(lower) - y(upper), 2))
                    .position(x: 42, y: (y(lower) + y(upper)) / 2)

                handle(layer: upper, at: y(upper), geo: geo) { upper = max(layer(at: $0), lower) }
                handle(layer: lower, at: y(lower), geo: geo) { lower = min(layer(at: $0), upper) }
            }
            .coordinateSpace(name: "layerSlider")
        }
    }

    private func handle(layer index: Int, at y: CGFloat, geo: GeometryProxy, set: @escaping (CGFloat) -> Void) -> some View {
        VStack(spacing: 0) {
            Text("\(index + 1)").font(.caption.bold().monospacedDigit())
            if index < heights.count { Text(String(format: "%.2f", heights[index])).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary) }
        }
        .frame(width: 64, height: 40)
        .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .position(x: 42, y: y)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("layerSlider")).onChanged { value in set(value.location.y) })
    }
}
