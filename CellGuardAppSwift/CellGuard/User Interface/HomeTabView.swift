//
//  HomeTabView.swift
//  CellGuard
//
//  Created by Lukas Arnold on 07.01.23.
//

import CoreData
import OSLog
import SwiftUI
import NavigationBackport

private enum ShownTab: Identifiable {
    case summary
    case map
    case operators
    case packets

    var id: Self {
        return self
    }
}

private enum ShownSheet: Hashable, Identifiable {
    case importFile(URL)

    var id: Self {
        return self
    }
}

struct HomeTabView: View {

    var body: some View {
        if #available(iOS 15, *) {
            HomeTabViewIOS15()
        } else {
            HomeTabViewIOS14()
        }
    }

}

@available(iOS 15, *)
private struct HomeTabViewIOS15: View {

    @AppStorage(UserDefaultsKeys.introductionShown.rawValue) var introductionShown: Bool = false

    @State private var showingTab = ShownTab.summary
    @State private var showingSheet: ShownSheet?

    var body: some View {
        CompositeTabView(shownTab: $showingTab, shownSheet: $showingSheet)
            .sheet(item: $showingSheet) { (sheet: ShownSheet) in
                switch sheet {
                case let .importFile(url):
                    NBNavigationStack {
                        ImportView(fileUrl: url)
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(get: {
                !introductionShown
            }, set: { _ in
                // Ignore the change
            })) {
                IntroductionView()
            }
    }
}

// Multiple .sheet() & .fullScreenCover() statements on a single view are not supported in iOS 14
// See: https://stackoverflow.com/a/63181811
// See: https://www.hackingwithswift.com/forums/swiftui/using-sheet-and-fullscreencover-together/4258/13585
private struct HomeTabViewIOS14: View {

    @AppStorage(UserDefaultsKeys.introductionShown.rawValue) var introductionShown: Bool = false

    @State private var shownTab = ShownTab.summary
    @State private var shownSheet: ShownSheet?

    var body: some View {
        ZStack {
            EmptyView()
                .sheet(item: $shownSheet) { (sheet: ShownSheet) in
                    switch sheet {
                    case let .importFile(url):
                        NBNavigationStack {
                            ImportView(fileUrl: url)
                        }
                    }
                }

            CompositeTabView(shownTab: $shownTab, shownSheet: $shownSheet)
                .fullScreenCover(isPresented: Binding(get: {
                    !introductionShown
                }, set: { _ in
                    // Ignore the change
                })) {
                    IntroductionView()
                }
        }
    }

}

private struct CompositeTabView: View {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: CompositeTabView.self)
    )

    @Binding var shownTab: ShownTab
    @Binding var shownSheet: ShownSheet?

    var body: some View {
        TabView(selection: $shownTab) {
            SummaryTabView()
                .tabItem {
                    Label("Summary", systemImage: "shield.fill")
                }
                .tag(ShownTab.summary)
            MapTabView()
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
                .tag(ShownTab.map)
            OperatorComparisonView()
                .tabItem {
                    Label("Compare", systemImage: "chart.bar.xaxis")
                }
                .tag(ShownTab.operators)
            PacketTabView()
                .tabItem {
                    Label("Packets", systemImage: "shippingbox")
                }
                .tag(ShownTab.packets)
        }
        .onAppear {
            // The tab bar on iOS 15 and above is by default translucent.
            // However in the map tab, it doesn't switch from the transparent to its opaque mode.
            // Therefore, we keep the tab for now always opaque.
            CGTabBarAppearance.opaque()
        }
        .onOpenURL { url in
            Self.logger.debug("Open URL: \(url)")

            // Switch to the summary tab and close the shown sheet (if there's any)
            self.shownTab = .summary
            self.shownSheet = nil

            // Wait a bit so the sheet can close and we can present the alert
            // See: https://stackoverflow.com/a/71638878
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.shownSheet = ShownSheet.importFile(url)
            }
        }
    }

}

private enum OperatorSort: String, CaseIterable, Identifiable {
    case rsrpMinimum = "RSRP minimum"
    case rsrpMaximum = "RSRP maximum"
    case rsrpP70 = "RSRP P70"
    case rsrpP90 = "RSRP P90"
    case rsrqMinimum = "RSRQ minimum"
    case rsrqMaximum = "RSRQ maximum"
    case rsrqP70 = "RSRQ P70"
    case rsrqP90 = "RSRQ P90"
    case sinr0Minimum = "SINR0 minimum"
    case sinr0Maximum = "SINR0 maximum"
    case sinr0P70 = "SINR0 P70"
    case sinr0P90 = "SINR0 P90"
    case sinr1Minimum = "SINR1 minimum"
    case sinr1Maximum = "SINR1 maximum"
    case sinr1P70 = "SINR1 P70"
    case sinr1P90 = "SINR1 P90"

    var id: Self { self }
}

private struct OperatorSignalRow: Identifiable {
    let country: Int32
    let network: Int32
    let name: String
    let statistics: SignalStatistics
    var id: String { "\(country)-\(network)" }
}

private struct OperatorComparisonView: View {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \CellTweak.collected, ascending: false)])
    private var cells: FetchedResults<CellTweak>
    @State private var rows: [OperatorSignalRow] = []
    @State private var sort = OperatorSort.rsrpP70

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("Sort by", selection: $sort) {
                        ForEach(OperatorSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section(header: Text("Operators"), footer: Text("Statistics exclude strong packet outliers using the 3×IQR rule.")) {
                    ForEach(sortedRows) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.name).font(.headline)
                            Text("MCC \(row.country) · MNC \(formatMNC(row.network))")
                                .font(.caption).foregroundColor(.secondary)
                            ForEach(SignalStatisticsFormatter.lines(row.statistics), id: \.self) {
                                Text($0).font(.caption).monospacedDigit()
                            }
                        }.padding(.vertical, 3)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Operator comparison")
            .onAppear(perform: loadRows)
        }
    }

    private var sortedRows: [OperatorSignalRow] {
        rows.sorted { score($0.statistics) > score($1.statistics) }
    }

    private func score(_ value: SignalStatistics) -> Double {
        switch sort {
        case .rsrpMinimum: value.rsrp?.minimum ?? -.infinity
        case .rsrpMaximum: value.rsrp?.maximum ?? -.infinity
        case .rsrpP70: value.rsrp?.percentile70 ?? -.infinity
        case .rsrpP90: value.rsrp?.percentile90 ?? -.infinity
        case .rsrqMinimum: value.rsrq?.minimum ?? -.infinity
        case .rsrqMaximum: value.rsrq?.maximum ?? -.infinity
        case .rsrqP70: value.rsrq?.percentile70 ?? -.infinity
        case .rsrqP90: value.rsrq?.percentile90 ?? -.infinity
        case .sinr0Minimum: value.sinr0?.minimum ?? -.infinity
        case .sinr0Maximum: value.sinr0?.maximum ?? -.infinity
        case .sinr0P70: value.sinr0?.percentile70 ?? -.infinity
        case .sinr0P90: value.sinr0?.percentile90 ?? -.infinity
        case .sinr1Minimum: value.sinr1?.minimum ?? -.infinity
        case .sinr1Maximum: value.sinr1?.maximum ?? -.infinity
        case .sinr1P70: value.sinr1?.percentile70 ?? -.infinity
        case .sinr1P90: value.sinr1?.percentile90 ?? -.infinity
        }
    }

    private func loadRows() {
        let unique = Dictionary(grouping: cells, by: { "\($0.country)-\($0.network)" })
        rows = unique.values.compactMap { group in
            guard let cell = group.first else { return nil }
            let statistics = PersistenceController.shared.fetchSignalStatisticsForOperator(
                country: cell.country, network: cell.network
            )
            let names = OperatorDefinitions.shared.translate(country: cell.country, network: cell.network)
            return OperatorSignalRow(
                country: cell.country, network: cell.network,
                name: names.firstCombinedName ?? "Network \(formatMNC(cell.network))",
                statistics: statistics
            )
        }.filter { $0.statistics.hasMeasurements }
    }
}

struct CompositeTabView_Previews: PreviewProvider {
    static var previews: some View {
        HomeTabView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
