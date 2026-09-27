import Foundation
import SwiftData

extension FlowService {
    func dashboard() -> DashboardMetrics {
        let missions = (try? context.fetch(FetchDescriptor<Mission>())) ?? []
        let trips = Dictionary(uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<BusTrip>())) ?? []).map { ($0.id, $0) })
        let byID = Dictionary(uniqueKeysWithValues: missions.map { ($0.id, $0) })
        let diversionStops = Set(stops().filter(\.isDiversionTarget).map(\.sequence))
        let km = Dictionary(uniqueKeysWithValues: missions.map { ($0.id, distanceKm($0)) })

        let parts = ((try? context.fetch(FetchDescriptor<Participation>())) ?? []).map { p in
            let m = byID[p.missionID]
            return ParticipationFact(
                userID: p.userID, missionID: p.missionID, completed: p.statusValue == .completed,
                completedAt: p.completedAt, joinedAt: p.joinedAt,
                isOffPeak: m.flatMap { trips[$0.tripID]?.isOffPeak } ?? false,
                toDiversionTarget: m.map { diversionStops.contains($0.endStopSeq) } ?? false,
                distanceKm: km[p.missionID] ?? 0, isSimulated: p.isSimulated)
        }
        let reds = ((try? context.fetch(FetchDescriptor<Redemption>())) ?? []).map {
            RedemptionFact(userID: $0.userID, success: $0.isSuccess, at: $0.redeemedAt, isSimulated: $0.isSimulated)
        }
        let issued = ((try? context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.referenceType == "participation" }))) ?? [])
            .reduce(0) { $0 + $1.amount }

        return DashboardMetrics.compute(views: missions.reduce(0) { $0 + $1.viewCount }, participations: parts,
                                        redemptions: reds, coinsIssued: issued,
                                        assumptions: MetricAssumptions(rules()), now: now())
    }
}
