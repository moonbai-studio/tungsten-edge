import Foundation

struct StripItem: Hashable {
    let id: String
    let title: String
    let status: String
    let appID: String
    let isAppLevelFallback: Bool
    let canMinimize: Bool
    let canHide: Bool
    let canClose: Bool

    init(record: WindowRecord) {
        self.id = record.id.rawValue
        self.title = record.title
        self.status = record.status.rawValue
        self.appID = record.appID.rawValue
        self.isAppLevelFallback = record.id.rawValue.hasPrefix("app-")
        self.canMinimize = self.isAppLevelFallback == false
        self.canHide = true
        self.canClose = self.isAppLevelFallback == false
    }
}
