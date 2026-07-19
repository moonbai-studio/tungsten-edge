import ApplicationServices

struct PermissionService {
    private let trustCheck: () -> Bool
    private let promptRequest: () -> Bool

    init(
        trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        promptRequest: @escaping () -> Bool = {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    ) {
        self.trustCheck = trustCheck
        self.promptRequest = promptRequest
    }

    func hasRequiredPermissions() -> Bool {
        trustCheck()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        promptRequest()
    }
}
