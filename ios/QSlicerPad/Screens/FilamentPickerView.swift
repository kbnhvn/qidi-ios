//
//  FilamentPickerView.swift
//  Choix du filament : recherche, regroupement par matière (PLA, PETG, ABS…).
//  Seuls les filaments compatibles avec l'imprimante et le preset d'impression
//  (décidé par le moteur) sont proposés.
//

import SwiftUI

struct FilamentPickerView: View {
    @EnvironmentObject private var model: SlicerModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var entries: [FilamentEntry] { FilamentIndex.entries(model.filamentPresets) }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    ForEach(FilamentIndex.grouped(entries), id: \.material) { group in
                        Section(group.material) { rows(group.items) }
                    }
                } else {
                    let hits = FilamentIndex.search(entries, query: query)
                    if hits.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        rows(hits)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L10n.t("Rechercher un filament"))
            .navigationTitle(L10n.t("Filament"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("Annuler")) { dismiss() } }
            }
        }
    }

    private func rows(_ items: [FilamentEntry]) -> some View {
        ForEach(items) { entry in
            Button {
                model.selectFilament(entry.id)
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.display).foregroundStyle(.primary)
                        Text(entry.vendor).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.id == model.selection.filament {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .frame(minHeight: 44)
            }
        }
    }
}
