//
//  HomeTabView.swift
//  CellGuard
//
//  Created by Lukas Arnold on 07.01.23.
//

import CoreData
import CoreLocation
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
    case rsrpP10 = "RSRP P10"
    case rsrpP30 = "RSRP P30"
    case rsrqMinimum = "RSRQ minimum"
    case rsrqMaximum = "RSRQ maximum"
    case rsrqP10 = "RSRQ P10"
    case rsrqP30 = "RSRQ P30"
    case snrMinimum = "SNR minimum"
    case snrMaximum = "SNR maximum"
    case snrP10 = "SNR P10"
    case snrP30 = "SNR P30"

    var id: Self { self }
}

private struct OperatorSignalRow: Identifiable {
    let country: Int32
    let network: Int32
    let technology: String
    let name: String
    let towers: [SignalTowerCandidate]
    var id: String { "\(technology)-\(country)-\(network)" }
}

private struct OperatorComparisonView: View {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \CellTweak.collected, ascending: false)])
    private var cells: FetchedResults<CellTweak>
    @State private var rows: [OperatorSignalRow] = []
    @State private var sort = OperatorSort.rsrpP10
    @State private var loading = true
    @State private var technology = ALSTechnology.LTE.rawValue
    @State private var manualTowerIDs: [String: String] = [:]
    @ObservedObject private var locationInfo = LocationDataManagerPublished.shared

    private var technologies: [String] {
        let supported = Set(ALSTechnology.allCases.filter { $0 != .OFF }.map(\.rawValue))
        return Array(Set(cells.compactMap(\.technology)).intersection(supported)).sorted {
            technologyOrder($0) < technologyOrder($1)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("Network type", selection: $technology) {
                        ForEach(technologies, id: \.self) { Text(technologyName($0)).tag($0) }
                    }
                    .onChange(of: technology) { _ in
                        manualTowerIDs = [:]
                        loadRows()
                    }
                    Picker("Sort by", selection: $sort) {
                        ForEach(OperatorSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section(header: Text("Operators"), footer: Text("P10 is the weak-signal value that approximately 90% of samples meet or exceed; P30 is met or exceeded by approximately 70%. Strong packet outliers are excluded using the 3×IQR rule.")) {
                    if loading {
                        ProgressView()
                    }
                    ForEach(sortedRows) { row in
                        operatorRow(row)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Operator comparison")
            .onAppear {
                if !technologies.contains(technology), let first = technologies.first {
                    technology = first
                    return
                }
                loadRows()
            }
        }
    }

    private var sortedRows: [OperatorSignalRow] {
        rows.sorted { score(selectedTower(for: $0)?.statistics) > score(selectedTower(for: $1)?.statistics) }
    }

    private func score(_ value: SignalStatistics?) -> Double {
        switch sort {
        case .rsrpMinimum: value?.rsrp?.minimum ?? -.infinity
        case .rsrpMaximum: value?.rsrp?.maximum ?? -.infinity
        case .rsrpP10: value?.rsrp?.percentile10 ?? -.infinity
        case .rsrpP30: value?.rsrp?.percentile30 ?? -.infinity
        case .rsrqMinimum: value?.rsrq?.minimum ?? -.infinity
        case .rsrqMaximum: value?.rsrq?.maximum ?? -.infinity
        case .rsrqP10: value?.rsrq?.percentile10 ?? -.infinity
        case .rsrqP30: value?.rsrq?.percentile30 ?? -.infinity
        case .snrMinimum: value?.snr?.minimum ?? -.infinity
        case .snrMaximum: value?.snr?.maximum ?? -.infinity
        case .snrP10: value?.snr?.percentile10 ?? -.infinity
        case .snrP30: value?.snr?.percentile30 ?? -.infinity
        }
    }

    private func loadRows() {
        loading = true
        let selectedTechnology = technology
        let keys = Set(cells.filter { $0.technology == selectedTechnology }.map {
            OperatorKey(technology: selectedTechnology, country: $0.country, network: $0.network)
        })
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = keys.compactMap { key -> OperatorSignalRow? in
                let towers = PersistenceController.shared.fetchSignalTowerCandidates(
                    technology: key.technology, country: key.country, network: key.network
                )
                let names = OperatorDefinitions.shared.translate(country: key.country, network: key.network)
                return OperatorSignalRow(
                    country: key.country, network: key.network, technology: key.technology,
                    name: names.firstCombinedName ?? "Network \(formatMNC(key.network))",
                    towers: towers
                )
            }
            DispatchQueue.main.async {
                guard technology == selectedTechnology else { return }
                rows = loaded
                loading = false
            }
        }
    }

    private func selectedTower(for row: OperatorSignalRow) -> SignalTowerCandidate? {
        if let manualID = manualTowerIDs[row.id] {
            return row.towers.first { $0.id == manualID }
        }
        return row.towers
            .filter { $0.statistics.packetCount >= PersistenceController.minimumSignalSamplesForAutomaticTower }
            .filter { $0.statistics.rsrp != nil }
            .max { $0.statistics.rsrp!.percentile10 < $1.statistics.rsrp!.percentile10 }
    }

    @ViewBuilder private func operatorRow(_ row: OperatorSignalRow) -> some View {
        let tower = selectedTower(for: row)
        VStack(alignment: .leading, spacing: 7) {
            Text(row.name).font(.headline)
            Text("MCC \(row.country) · MNC \(formatMNC(row.network))")
                .font(.caption).foregroundColor(.secondary)
            Picker("Tower", selection: Binding(
                get: { manualTowerIDs[row.id] ?? "best" },
                set: { manualTowerIDs[row.id] = $0 == "best" ? nil : $0 }
            )) {
                Text("Best tower").tag("best")
                ForEach(sortedTowers(row.towers)) { candidate in
                    Text(towerDescription(candidate)).tag(candidate.id)
                }
            }
            if let tower {
                Text(towerDescription(tower)).font(.caption).foregroundColor(.secondary)
                ForEach(SignalStatisticsFormatter.lines(tower.statistics), id: \.self) {
                    Text($0).font(.system(.caption, design: .monospaced))
                }
            } else if row.towers.isEmpty {
                Text("No measurements for this network type").foregroundColor(.secondary)
            } else {
                Text("Insufficient data for automatic selection; select a tower manually.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.padding(.vertical, 3)
    }

    private func sortedTowers(_ towers: [SignalTowerCandidate]) -> [SignalTowerCandidate] {
        towers.sorted { lhs, rhs in
            (towerDistance(lhs) ?? .greatestFiniteMagnitude) <
                (towerDistance(rhs) ?? .greatestFiniteMagnitude)
        }
    }

    private func towerDistance(_ tower: SignalTowerCandidate) -> CLLocationDistance? {
        guard let reference = locationInfo.lastLocation,
              let latitude = tower.latitude, let longitude = tower.longitude else { return nil }
        return reference.distance(from: CLLocation(latitude: latitude, longitude: longitude))
    }

    private func towerDescription(_ tower: SignalTowerCandidate) -> String {
        var parts: [String] = []
        if let distance = towerDistance(tower) {
            parts.append(String(format: "%.1f km", distance / 1_000))
        }
        parts.append(towerIdentifier(tower.key))
        if tower.band > 0 { parts.append("B\(tower.band)") }
        return parts.joined(separator: " · ")
    }

    private func towerIdentifier(_ key: SignalCellKey) -> String {
        switch ALSTechnology(rawValue: key.technology) {
        case .LTE:
            let value = CellIdentification.lte(eci: key.cell)
            return "eNB \(value.eNodeB) / sector \(value.sector)"
        case .UMTS:
            let value = CellIdentification.umts(lcid: key.cell)
            return "RNC \(value.rnc) / cell \(value.cid)"
        case .GSM:
            let value = CellIdentification.gsm(cellId: key.cell)
            return "BTS \(value.bts) / sector \(value.sector)"
        case .NR:
            return "NCI \(key.cell)"
        default:
            return "Cell \(key.cell)"
        }
    }

    private func technologyName(_ value: String) -> String {
        guard let technology = ALSTechnology(rawValue: value) else { return value }
        return "\(CellTechnologyFormatter.userInfo(technology)) / \(technology.rawValue)"
    }

    private func technologyOrder(_ value: String) -> Int {
        switch ALSTechnology(rawValue: value) {
        case .GSM, .CDMA: return 2
        case .UMTS, .SCDMA: return 3
        case .LTE: return 4
        case .NR: return 5
        default: return 99
        }
    }
}

private struct OperatorKey: Hashable {
    let technology: String
    let country: Int32
    let network: Int32
}

struct CompositeTabView_Previews: PreviewProvider {
    static var previews: some View {
        HomeTabView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
