//
//  Packets.swift
//  CellGuard
//
//  Created by Lukas Arnold on 04.05.24.
//

import CoreData
import Foundation

/// A distribution summary after obviously invalid signal packets have been removed.
struct SignalMetricSummary: Equatable {
    let minimum: Double
    let maximum: Double
    let percentile10: Double
    let percentile30: Double
}

struct SignalStatistics: Equatable {
    let rsrp: SignalMetricSummary?
    let rsrq: SignalMetricSummary?
    let snr: SignalMetricSummary?
    let packetCount: Int
    let removedPacketCount: Int

    static let empty = SignalStatistics(
        rsrp: nil, rsrq: nil, snr: nil,
        packetCount: 0, removedPacketCount: 0
    )

    var hasMeasurements: Bool {
        rsrp != nil || rsrq != nil || snr != nil
    }
}

private struct SignalSample {
    let rsrp: Double?
    let rsrq: Double?
    let snr: Double?
}

struct SignalCellKey: Hashable, Identifiable {
    let technology: String
    let country: Int32
    let network: Int32
    let area: Int32
    let cell: Int64

    var id: String { "\(technology)-\(country)-\(network)-\(area)-\(cell)" }
}

struct SignalTowerCandidate: Identifiable {
    let key: SignalCellKey
    let band: Int32
    let latitude: Double?
    let longitude: Double?
    let statistics: SignalStatistics

    var id: String { key.id }
}

struct PacketImportRefs {
    var cellInfo: [NSManagedObjectID] = []
    var connectivityEvents: [NSManagedObjectID] = []
}

extension PersistenceController {

    static let minimumSignalSamplesForAutomaticTower = 5

    /// Calculates signal distributions for every occurrence of a cell. Values outside
    /// three interquartile ranges are treated as strong packet anomalies. This wider
    /// variant of Tukey's rule deliberately preserves normal changes in reception.
    func fetchSignalStatistics(for cell: Cell) -> SignalStatistics {
        fetchSignalStatistics(
            technology: cell.technology, country: cell.country, network: cell.network,
            area: cell.area, cell: cell.cell
        )
    }

    func fetchSignalStatistics(
        technology: String?, country: Int32, network: Int32, area: Int32, cell: Int64
    ) -> SignalStatistics {
        let ids: [NSManagedObjectID] = (try? performAndWait(name: "fetchContext", author: "fetchSignalStatistics") { _ in
            let request = CellTweak.fetchRequest()
            request.predicate = NSPredicate(
                format: "technology == %@ AND country == %@ AND network == %@ AND area == %@ AND cell == %@",
                technology ?? "", country as NSNumber, network as NSNumber,
                area as NSNumber, cell as NSNumber
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CellTweak.collected, ascending: true)]
            return try request.execute().map(\.objectID)
        }) ?? []

        return fetchSignalStatistics(cellIDs: ids, technology: technology ?? "")
    }

    /// Calculates a combined distribution for all cells recorded on an operator.
    func fetchSignalStatisticsForOperator(technology: String, country: Int32, network: Int32) -> SignalStatistics {
        let ids: [NSManagedObjectID] = (try? performAndWait(name: "fetchContext", author: "fetchOperatorSignalStatistics") { _ in
            let request = CellTweak.fetchRequest()
            request.predicate = NSPredicate(
                format: "technology == %@ AND country == %@ AND network == %@",
                technology, country as NSNumber, network as NSNumber
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CellTweak.collected, ascending: true)]
            return try request.execute().map(\.objectID)
        }) ?? []

        return fetchSignalStatistics(cellIDs: ids, technology: technology)
    }

    private func fetchSignalStatistics(cellIDs ids: [NSManagedObjectID], technology: String) -> SignalStatistics {

        var parsedPackets: [NSManagedObjectID: ParsedQMIPacket] = [:]
        for id in ids {
            let lifespan: (start: Date, end: Date, after: NSManagedObjectID?, simSlotID: UInt8)?
            if let fetched = (try? fetchCellLifespan(of: id)) ?? nil {
                lifespan = (fetched.start, fetched.end, fetched.after, fetched.simSlotID)
            } else {
                let active: (start: Date, simSlotID: UInt8)? = fetchCellAttribute(
                    cell: id,
                    extract: { cell -> (start: Date, simSlotID: UInt8)? in
                        guard let start = cell.collected else { return nil }
                        return (start: start, simSlotID: UInt8(cell.simSlotID))
                    }
                )
                if let active {
                    // fetchCellLifespan has no end for the currently connected (last)
                    // cell. Include its packets up to now instead of silently losing it.
                    lifespan = (active.start, Date(), nil, active.simSlotID)
                } else {
                    lifespan = nil
                }
            }
            guard let lifespan else { continue }
            guard let packets = try? fetchIndexedQMIPackets(
                start: lifespan.start,
                end: lifespan.end,
                simSlotID: lifespan.simSlotID,
                signal: true
            ) else { continue }
            parsedPackets.merge(packets) { current, _ in current }
        }

        let samples = parsedPackets.values.compactMap { packet -> SignalSample? in
            guard let info = try? ParsedQMISignalInfoIndication(qmiPacket: packet) else { return nil }
            if technology == ALSTechnology.NR.rawValue, let nr = info.nr {
                return SignalSample(
                    rsrp: nr.rsrp.map(Double.init),
                    rsrq: nr.rsrq.map(Double.init),
                    snr: nr.snr
                )
            }
            if technology == ALSTechnology.LTE.rawValue, let lte = info.lte {
                return SignalSample(
                    rsrp: Double(lte.rsrp), rsrq: Double(lte.rsrq), snr: lte.snr
                )
            }
            return nil
        }.filter { $0.rsrp != nil || $0.rsrq != nil || $0.snr != nil }

        return Self.summarizeSignalSamples(samples)
    }

    private static func summarizeSignalSamples(_ samples: [SignalSample]) -> SignalStatistics {
        let columns: [[Double]] = [
            samples.compactMap(\.rsrp), samples.compactMap(\.rsrq), samples.compactMap(\.snr)
        ]
        let bounds = columns.map(outlierBounds)
        let filtered = samples.filter { sample in
            let values = [sample.rsrp, sample.rsrq, sample.snr]
            return zip(values, bounds).allSatisfy { value, bound in
                guard let value, let bound else { return true }
                return bound.contains(value)
            }
        }

        return SignalStatistics(
            rsrp: metricSummary(filtered.compactMap(\.rsrp)),
            rsrq: metricSummary(filtered.compactMap(\.rsrq)),
            snr: metricSummary(filtered.compactMap(\.snr)),
            packetCount: filtered.count,
            removedPacketCount: samples.count - filtered.count
        )
    }

    private static func outlierBounds(_ values: [Double]) -> ClosedRange<Double>? {
        guard values.count >= 4 else { return nil }
        let sorted = values.sorted()
        let q1 = percentile(sorted, 0.25)
        let q3 = percentile(sorted, 0.75)
        let spread = q3 - q1
        // A zero IQR is common for radio measurements. Do not discard a packet
        // merely because all the other integer readings happen to be identical.
        guard spread > 0 else { return nil }
        return (q1 - 3 * spread)...(q3 + 3 * spread)
    }

    private static func metricSummary(_ values: [Double]) -> SignalMetricSummary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return SignalMetricSummary(
            minimum: sorted[0], maximum: sorted[sorted.count - 1],
            percentile10: percentile(sorted, 0.10),
            percentile30: percentile(sorted, 0.30)
        )
    }

    func fetchSignalTowerCandidates(technology: String, country: Int32, network: Int32) -> [SignalTowerCandidate] {
        struct Metadata {
            let key: SignalCellKey
            let band: Int32
            let latitude: Double?
            let longitude: Double?
        }

        let metadata: [Metadata] = (try? performAndWait(name: "fetchContext", author: "fetchSignalTowerCandidates") { _ in
            let request = CellTweak.fetchRequest()
            request.predicate = NSPredicate(
                format: "technology == %@ AND country == %@ AND network == %@",
                technology, country as NSNumber, network as NSNumber
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \CellTweak.collected, ascending: false)]
            var seen = Set<SignalCellKey>()
            return try request.execute().compactMap { measurement in
                let key = SignalCellKey(
                    technology: technology, country: country, network: network,
                    area: measurement.area, cell: measurement.cell
                )
                guard seen.insert(key).inserted else { return nil }
                let location = measurement.appleDatabase?.location
                return Metadata(
                    key: key,
                    band: measurement.band,
                    latitude: location?.latitude ?? measurement.location?.latitude,
                    longitude: location?.longitude ?? measurement.location?.longitude
                )
            }
        }) ?? []

        return metadata.map { item in
            SignalTowerCandidate(
                key: item.key, band: item.band, latitude: item.latitude, longitude: item.longitude,
                statistics: fetchSignalStatistics(
                    technology: item.key.technology, country: item.key.country, network: item.key.network,
                    area: item.key.area, cell: item.key.cell
                )
            )
        }
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        guard sorted.count > 1 else { return sorted[0] }
        let position = percentile * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// Uses `NSBatchInsertRequest` (BIR) to import QMI packets into the Core Data store on a private queue.
    /// Returns the number of imported packets and references to packets with (a) cell information and (b) connectivity events.
    func importQMIPackets(from packets: [(CPTPacket, ParsedQMIPacket)], sysdiagnoseId: NSManagedObjectID?) throws -> (Int, PacketImportRefs) {
        if packets.isEmpty {
            return (0, PacketImportRefs())
        }

        let objectIds: [NSManagedObjectID] = try performAndWait(name: "importContext", author: "importQMIPackets") { context in
            var index = 0
            let total = packets.count
            let importedDate = Date()

            let batchInsertRequest = NSBatchInsertRequest(entity: PacketQMI.entity(), managedObjectHandler: { dbPacket in
                guard index < total else { return true }

                if let dbPacket = dbPacket as? PacketQMI {
                    let (tweakPacket, parsedPacket) = packets[index]
                    dbPacket.data = tweakPacket.data
                    dbPacket.collected = tweakPacket.timestamp
                    dbPacket.direction = tweakPacket.direction.rawValue
                    // dbPacket.proto = tweakPacket.proto.rawValue
                    dbPacket.simSlotID = tweakPacket.simSlotID != nil ? Int16(tweakPacket.simSlotID!) : 0

                    dbPacket.service = Int16(parsedPacket.qmuxHeader.serviceId)
                    dbPacket.message = Int32(parsedPacket.messageHeader.messageId)
                    dbPacket.indication = parsedPacket.transactionHeader.indication

                    dbPacket.imported = importedDate
                }

                index += 1
                return false
            })

            batchInsertRequest.resultType = .objectIDs

            guard let fetchResult = try? context.execute(batchInsertRequest),
                  let batchInsertResult = fetchResult as? NSBatchInsertResult else {
                return []
            }

            return batchInsertResult.result as? [NSManagedObjectID]
        } ?? []

        var packetRefs = PacketImportRefs()
        try performAndWait(name: "importContext", author: "importQMIPackets") { context in
            let sysdiagnose = Sysdiagnose.getSysdiagnoseById(context: context, id: sysdiagnoseId)

            var added = false
            for objectId in objectIds {
                guard let qmiPacket = context.object(with: objectId) as? PacketQMI else {
                    continue
                }
                qmiPacket.sysdiagnose = sysdiagnose

                if CCTParser.isCellPacket(qmi: qmiPacket, ari: nil) {
                    packetRefs.cellInfo.append(qmiPacket.objectID)
                }
                if ConnectivityEventParser.isConnectivityEventPacket(qmi: qmiPacket, ari: nil) {
                    packetRefs.connectivityEvents.append(qmiPacket.objectID)
                }

                if qmiPacket.indication == PacketConstants.qmiRejectIndication
                    && qmiPacket.service == PacketConstants.qmiRejectService
                    && qmiPacket.direction == PacketConstants.qmiRejectDirection.rawValue {

                    if qmiPacket.message == PacketConstants.qmiRejectMessage {
                        let index = PacketIndexQMI(context: context)
                        index.collected = qmiPacket.collected
                        index.simSlotID = qmiPacket.simSlotID
                        index.reject = true
                        qmiPacket.index = index
                        added = true
                    } else if qmiPacket.message == PacketConstants.qmiSignalMessage {
                        let index = PacketIndexQMI(context: context)
                        index.collected = qmiPacket.collected
                        index.simSlotID = qmiPacket.simSlotID
                        index.signal = true
                        qmiPacket.index = index
                        added = true
                    }
                }
            }

            if added {
                try context.save()
            }
        }

        // It can be the case the newly imported data is already in the database
        /* if objectIds.isEmpty {
            logger.debug("Failed to execute batch import request for QMI packets.")
            throw PersistenceError.batchInsertError
        } */

        logger.debug("Successfully inserted \(packets.count) tweak QMI packets.")
        return (objectIds.count, packetRefs)
    }

    /// Uses `NSBatchInsertRequest` (BIR) to import ARI packets into the Core Data store on a private queue.
    /// Returns the number of imported packets and references to packets with (a) cell information and (b) connectivity events.
    func importARIPackets(from packets: [(CPTPacket, ParsedARIPacket)], sysdiagnoseId: NSManagedObjectID?) throws -> (Int, PacketImportRefs) {
        if packets.isEmpty {
            return (0, PacketImportRefs())
        }

        let objectIds: [NSManagedObjectID] = try performAndWait(name: "importContext", author: "importARIPackets") { context in
            var index = 0
            let total = packets.count
            let importedDate = Date()

            let batchInsertRequest = NSBatchInsertRequest(entity: PacketARI.entity(), managedObjectHandler: { dbPacket in
                guard index < total else { return true }

                if let dbPacket = dbPacket as? PacketARI {
                    let (tweakPacket, parsedPacket) = packets[index]
                    dbPacket.data = tweakPacket.data
                    dbPacket.collected = tweakPacket.timestamp
                    dbPacket.direction = tweakPacket.direction.rawValue
                    // dbPacket.proto = tweakPacket.proto.rawValue
                    dbPacket.simSlotID = tweakPacket.simSlotID != nil ? Int16(tweakPacket.simSlotID!) : 0

                    dbPacket.group = Int16(parsedPacket.header.group)
                    dbPacket.type = Int32(parsedPacket.header.type)

                    dbPacket.imported = importedDate
                }

                index += 1
                return false
            })

            batchInsertRequest.resultType = .objectIDs

            guard let fetchResult = try? context.execute(batchInsertRequest),
                  let batchInsertResult = fetchResult as? NSBatchInsertResult else {
                return []
            }

            return batchInsertResult.result as? [NSManagedObjectID]
        } ?? []

        var packetRefs = PacketImportRefs()
        try performAndWait(name: "importContext", author: "importARIPackets") { context in
            let sysdiagnose = sysdiagnoseId != nil ? context.object(with: sysdiagnoseId!) as? Sysdiagnose : nil

            // TODO: Can we do that in parallel?
            let ariPackets = objectIds
                .compactMap { context.object(with: $0) as? PacketARI }
                .sorted { $0.collected ?? Date.distantPast < $1.collected ?? Date.distantPast }

            var added = false
            for ariPacket in ariPackets {
                ariPacket.sysdiagnose = sysdiagnose

                if CCTParser.isCellPacket(qmi: nil, ari: ariPacket) {
                    packetRefs.cellInfo.append(ariPacket.objectID)
                }
                if ConnectivityEventParser.isConnectivityEventPacket(qmi: nil, ari: ariPacket) {
                    packetRefs.connectivityEvents.append(ariPacket.objectID)
                }

                if ariPacket.direction == PacketConstants.ariRejectDirection.rawValue {
                    if ariPacket.group == PacketConstants.ariRejectGroup && ariPacket.type == PacketConstants.ariRejectType {
                        let index = PacketIndexARI(context: context)
                        index.reject = true
                        index.collected = ariPacket.collected
                        index.simSlotID = ariPacket.simSlotID
                        ariPacket.index = index
                        added = true
                    } else if ariPacket.group == PacketConstants.ariSignalGroup && ariPacket.type == PacketConstants.ariSignalType {
                        let index = PacketIndexARI(context: context)
                        index.signal = true
                        index.collected = ariPacket.collected
                        index.simSlotID = ariPacket.simSlotID
                        ariPacket.index = index
                        added = true
                    }
                }
            }

            if added {
                try context.save()
            }
        }

        /* if objectIds.isEmpty {
            logger.debug("Failed to execute batch import request for ARI packets.")
            throw PersistenceError.batchInsertError
        } */

        logger.debug("Successfully inserted \(packets.count) tweak ARI packets.")
        return (objectIds.count, packetRefs)
    }

    func fetchIndexedQMIPackets(start: Date, end: Date, simSlotID: UInt8, reject: Bool = false, signal: Bool = false) throws -> [NSManagedObjectID: ParsedQMIPacket] {
        return try performAndWait(name: "fetchContext", author: "fetchIndexedQMIPackets") { _ in
            let request = PacketIndexQMI.fetchRequest()
            var predicateList: [NSPredicate] = []
            predicateList.append(NSPredicate(format: "reject = %@", NSNumber(booleanLiteral: reject)))
            predicateList.append(NSPredicate(format: "signal = %@", NSNumber(booleanLiteral: signal)))
            predicateList.append(NSPredicate(format: "simSlotID = 0 or simSlotID = %@", NSNumber(value: simSlotID)))
            predicateList.append(NSPredicate(format: "%@ <= collected", start as NSDate))
            predicateList.append(NSPredicate(format: "collected <= %@", end as NSDate))
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicateList)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \PacketIndexQMI.collected, ascending: false)]
            request.includesSubentities = true

            var packets: [NSManagedObjectID: ParsedQMIPacket] = [:]
            for indexedQMIPacket in try request.execute() {
                guard let packet = indexedQMIPacket.packet else {
                    logger.warning("No QMI packet for indexed packet \(indexedQMIPacket)")
                    continue
                }
                guard let data = packet.data else {
                    logger.warning("Skipping packet \(packet) as it provides no binary data")
                    continue
                }

                packets[packet.objectID] = try ParsedQMIPacket(nsData: data)
            }

            return packets
        } ?? [:]
    }

    func fetchIndexedARIPackets(start: Date, end: Date, simSlotID: UInt8, reject: Bool = false, signal: Bool = false) throws -> [NSManagedObjectID: ParsedARIPacket] {
        return try performAndWait(name: "fetchContext", author: "fetchIndexedARIPackets") { _ in
            let request = PacketIndexARI.fetchRequest()

            request.predicate = NSPredicate(
                format: "reject = %@ and signal = %@ and %@ <= collected and collected <= %@ and (simSlotID = 0 or simSlotID = %@)",
                NSNumber(booleanLiteral: reject), NSNumber(booleanLiteral: signal), start as NSDate, end as NSDate, NSNumber(value: simSlotID)
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \PacketIndexARI.collected, ascending: false)]
            request.includesSubentities = true

            var packets: [NSManagedObjectID: ParsedARIPacket] = [:]
            for indexedARIPacket in try request.execute() {
                guard let packet = indexedARIPacket.packet else {
                    logger.warning("No ARI packet for indexed packet \(indexedARIPacket)")
                    continue
                }
                guard let data = packet.data else {
                    logger.warning("Skipping packet \(packet) as it provides no binary data")
                    continue
                }
                packets[packet.objectID] = try ParsedARIPacket(data: data)
            }

            return packets
        } ?? [:]
    }

    /// Fetches QMI packets with the specified properties from Core Data.
    /// Remember to update the fetch index `byQMIPacketPropertiesIndex` when fetching new types of packets, otherwise the query slows down significantly.
    func fetchQMIPackets(start: Date, end: Date, direction: CPTDirection, service: Int16, message: Int32, indication: Bool) throws -> [NSManagedObjectID: ParsedQMIPacket] {
        return try performAndWait(name: "fetchContext", author: "fetchQMIPackets") { _ in
            let request = PacketQMI.fetchRequest()
            request.predicate = NSPredicate(
                format: "indication = %@ and service = %@ and message = %@ and %@ <= collected and collected <= %@ and direction = %@",
                NSNumber(booleanLiteral: indication), service as NSNumber, message as NSNumber, start as NSDate, end as NSDate, direction.rawValue as NSString
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \PacketQMI.collected, ascending: false)]
            // See: https://stackoverflow.com/a/11165883
            request.propertiesToFetch = ["data"]

            var dict: [NSManagedObjectID: ParsedQMIPacket] = [:]
            for qmiPacket in try request.execute() {
                guard let data = qmiPacket.data else {
                    logger.warning("Skipping packet \(qmiPacket) as it provides no binary data")
                    continue
                }
                dict[qmiPacket.objectID] = try ParsedQMIPacket(nsData: data)
            }

            return dict
        } ?? [:]
    }

    /// Fetches ARI packets with the specified properties from Core Data.
    /// Remember to update the fetch index `byARIPacketPropertiesIndex` when fetching new types of packets, otherwise the query slows down significantly.
    func fetchARIPackets(direction: CPTDirection, group: Int16, type: Int32, start: Date, end: Date) throws -> [NSManagedObjectID: ParsedARIPacket] {
        return try performAndWait(name: "fetchContext", author: "fetchARIPackets") { _ in
            let request = NSFetchRequest<PacketARI>()
            request.entity = PacketARI.entity()
            request.predicate = NSPredicate(
                format: "group = %@ and type = %@ and %@ <= collected and collected <= %@ and direction = %@",
                group as NSNumber, type as NSNumber, start as NSDate, end as NSDate, direction.rawValue as NSString
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \PacketARI.collected, ascending: false)]
            request.returnsObjectsAsFaults = false

            var dict: [NSManagedObjectID: ParsedARIPacket] = [:]
            for ariPacket in try request.execute() {
                guard let data = ariPacket.data else {
                    logger.warning("Skipping packet \(ariPacket) as it provides no binary data")
                    continue
                }
                dict[ariPacket.objectID] = try ParsedARIPacket(data: data)
            }
            return dict
        } ?? [:]
    }

    func countPacketsByType(completion: @escaping (Result<(Int, Int), Error>) -> Void) {
        let backgroundContext = newTaskContext()
        backgroundContext.perform {
            let qmiRequest = NSFetchRequest<PacketQMI>()
            qmiRequest.entity = PacketQMI.entity()

            let ariRequest = NSFetchRequest<PacketARI>()
            ariRequest.entity = PacketARI.entity()

            let result = Result {
                let qmiCount = try backgroundContext.count(for: qmiRequest)
                let ariCount = try backgroundContext.count(for: ariRequest)

                return (qmiCount, ariCount)
            }

            // Call the callback on the main queue
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func deletePacketsOlderThan(days: Int) {
        do {
            try performAndWait { context in
                logger.debug("Start deleting packets older than \(days) day(s) from the store...")
                let startOfDay = Calendar.current.startOfDay(for: Date())
                guard let daysAgo = Calendar.current.date(byAdding: .day, value: -days, to: startOfDay) else {
                    logger.debug("Can't calculate the date for packet deletion")
                    return
                }
                logger.debug("Deleting packets older than \(startOfDay)")

                // Only delete packets not referenced by cells
                let predicate = NSPredicate(format: "collected < %@ AND index = nil AND cells.@count == 0", daysAgo as NSDate)

                let qmiCount = try deleteData(entity: PacketQMI.entity(), predicate: predicate, context: context)
                let ariCount = try deleteData(entity: PacketARI.entity(), predicate: predicate, context: context)
                logger.debug("Successfully deleted \(qmiCount + ariCount) old packets")
            }
        } catch {
            logger.warning("Failed to delete old packets: \(error)")
        }
    }

}
