import Foundation

/// A native membership-menu descriptor shared by launcher and window chips.
struct LauncherMembershipItem {
    let label: String
    /// nil = ordinary command; non-nil = native NSMenuItem check state.
    var isChecked: Bool? = nil
    let action: () -> Void
}

extension LauncherMembershipItem {
    /// Keeps the four menu construction paths on one membership matrix. Messaging uses a
    /// constant title: unchecked calls mark, checked calls unmark; neither path changes drawer.
    @MainActor
    static func items(
        surface: AppMembershipMenuPlan.Surface,
        bundleID: String,
        isKept: Bool,
        isMessaging: Bool,
        controller: AppMembershipController
    ) -> [LauncherMembershipItem] {
        AppMembershipMenuPlan.items(
            surface: surface,
            isFinder: bundleID == KeptAppStore.forbiddenBundleID,
            isKept: isKept,
            isMessaging: isMessaging
        ).map { item in
            switch item {
            case let .keep(isChecked):
                return LauncherMembershipItem(label: String(localized: "Keep in Dock"), isChecked: isChecked) {
                    controller.setKept(bundleID, enabled: !isChecked)
                }
            case let .messaging(isChecked):
                return LauncherMembershipItem(label: String(localized: "Mark as Messaging App"), isChecked: isChecked) {
                    if isChecked {
                        controller.unmarkMessaging(bundleID)
                    } else {
                        controller.markMessaging(bundleID)
                    }
                }
            }
        }
    }
}
