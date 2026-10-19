//
//  PrinterDiscoverySheet.swift
//  Recherche des imprimantes Klipper (Moonraker) du réseau local.
//

import SwiftUI

struct PrinterDiscoverySheet: View {
    @EnvironmentObject private var model: SlicerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.isDiscovering {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: model.discoveryProgress)
                            Text(L10n.t("Recherche sur le réseau local…")).font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if model.discoveredPrinters.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L10n.t("Aucune imprimante trouvée."), systemImage: "wifi.slash")
                            Text(L10n.t("Vérifiez que l'iPad et l'imprimante sont sur le même réseau Wi-Fi, et que l'accès au réseau local est autorisé pour l'app (Réglages iOS → QSlicerPad)."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.discoveredPrinters) { printer in
                        Button {
                            model.usePrinter(printer)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "printer.fill").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(printer.title).foregroundStyle(.primary)
                                    Text("\(printer.host):\(printer.port)" + (printer.version.map { " · Moonraker \($0)" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let state = printer.klippyState {
                                    Text(state).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                    }
                } footer: {
                    Text(L10n.t("Touchez une imprimante pour l'utiliser."))
                }

                Section {
                    Button { model.startDiscovery() } label: {
                        Label(L10n.t("Relancer la recherche"), systemImage: "arrow.clockwise").frame(minHeight: 44)
                    }
                    .disabled(model.isDiscovering)
                }
            }
            .navigationTitle(L10n.t("Rechercher une imprimante"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Fermer")) { model.cancelDiscovery(); dismiss() }
                }
            }
            .task { model.startDiscovery() }
            .onDisappear { model.cancelDiscovery() }
        }
    }
}
