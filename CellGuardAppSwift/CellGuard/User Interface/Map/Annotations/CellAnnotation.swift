//
//  ALSCellAnnotation.swift
//  CellGuard
//
//  Created by Lukas Arnold on 23.01.23.
//

import Foundation
import MapKit
import CoreData

class CellAnnotation: NSObject, MKAnnotation, DatabaseAnnotation {

    let coreDataID: NSManagedObjectID
    let technology: ALSTechnology
    let country: Int32
    let network: Int32
    let area: Int32
    let cell: Int64

    @objc dynamic let coordinate: CLLocationCoordinate2D
    @objc dynamic let title: String?
    @objc dynamic var subtitle: String?
    private var statisticsLoaded = false

    init(cell: CellALS, title: String? = nil, subtitle: String? = nil) {
        coreDataID = cell.objectID
        technology = ALSTechnology(rawValue: cell.technology ?? "") ?? .LTE
        country = cell.country
        network = cell.network
        area = cell.area
        self.cell = cell.cell
        coordinate = CLLocationCoordinate2D(
            latitude: cell.location?.latitude ?? 0,
            longitude: cell.location?.longitude ?? 0
        )
        self.title = title
        self.subtitle = subtitle
    }

    convenience init(cell: CellALS) {
        // Get the first available combined name
        let netOperators = OperatorDefinitions.shared.translate(country: cell.country, network: cell.network)

        self.init(
            cell: cell,
            title: netOperators.firstCombinedName ?? "Network \(formatMNC(cell.network))",
            subtitle: "Area: \(cell.area) - Cell: \(cell.cell)"
        )
    }

    func loadSignalStatistics() {
        guard !statisticsLoaded else { return }
        statisticsLoaded = true
        subtitle = "Loading signal statistics…\nArea: \(area) - Cell: \(cell)"
        let technology = technology.rawValue
        let country = country
        let network = network
        let area = area
        let cell = cell
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let statistics = PersistenceController.shared.fetchSignalStatistics(
                technology: technology, country: country, network: network, area: area, cell: cell
            )
            let lines = SignalStatisticsFormatter.lines(statistics)
            DispatchQueue.main.async {
                self?.subtitle = (lines + ["Area: \(area) - Cell: \(cell)"]).joined(separator: "\n")
            }
        }
    }

}
