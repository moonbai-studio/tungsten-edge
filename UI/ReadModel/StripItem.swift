import Foundation

struct StripItem: Hashable {
    let id: String
    let title: String
    let status: String
    let appID: String
    let bundleIdentifier: String?
    let sameAppCardCount: Int
    let showsTitle: Bool
    let isAppLevelFallback: Bool
    let canMinimize: Bool
    let canHide: Bool
    let canClose: Bool

    init(record: WindowRecord, sameAppCardCount: Int = 1) {
        self.id = record.id.rawValue
        self.title = record.title
        self.status = record.status.rawValue
        self.appID = record.appID.rawValue
        self.bundleIdentifier = record.bundleIdentifier
        self.sameAppCardCount = sameAppCardCount
        self.showsTitle = sameAppCardCount >= 2
        self.isAppLevelFallback = record.id.rawValue.hasPrefix("app-")
        self.canMinimize = self.isAppLevelFallback == false
        self.canHide = true
        self.canClose = self.isAppLevelFallback == false
    }

    static func items(from snapshot: DockSnapshot) -> [StripItem] {
        let records = snapshot.orderedWindowIDs.compactMap { windowID in
            snapshot.windows[windowID]
        }
        let countsByApp = Dictionary(grouping: records, by: appGroupingKey(for:))
            .mapValues(\.count)

        return records.map { record in
            StripItem(
                record: record,
                sameAppCardCount: countsByApp[appGroupingKey(for: record)] ?? 1
            )
        }
    }

    private static func appGroupingKey(for record: WindowRecord) -> String {
        record.bundleIdentifier ?? record.appID.rawValue
    }
}
