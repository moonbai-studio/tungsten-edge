import ApplicationServices

struct PermissionService {
    func hasRequiredPermissions() -> Bool {
        AXIsProcessTrusted()
    }
}
