import Foundation

/// 菜单版本行的「这份包是从哪来的」标记。
///
/// 存在的理由是一次真实事故：登录项被 `SMAppService.mainApp.register()` 钉在
/// `build/DerivedData/.../Debug/` 上（它注册的是当时正在运行的 bundle），于是开机
/// 自动起来的一直是开发构建、而不是 `/Applications` 里的正式包。发布后主线版本号
/// 又不 bump，菜单上两者显示完全一样，导致「最小化手感不对」被误判成版本回归、
/// 「屏幕上两个任务条」被误判成修复无效。把来源直接写进版本行，肉眼即可分辨。
enum BuildProvenance {
    /// 正式安装位置。结尾的 `/` 不能省——否则 `/ApplicationsOld/Foo.app` 这类路径
    /// 会被 `hasPrefix` 误判成已安装。
    static let installedPrefix = "/Applications/"

    /// 版本行后缀；`nil` = 正式安装位置的 Release 包，不加任何标记。
    ///
    /// Debug 优先于位置判断：开发构建即使被拷进 `/Applications` 也仍是开发构建，
    /// 手感与正式包不同（Debug 无编译器优化），这一点比它在哪儿更重要。
    static func suffix(isDebugBuild: Bool, bundlePath: String) -> String? {
        if isDebugBuild { return String(localized: "Debug Build") }
        return bundlePath.hasPrefix(installedPrefix) ? nil : String(localized: "Not Installed")
    }

    /// 拼好的完整版本行。version / build 任一缺失时的退化文案与加标记前的旧实现一致。
    static func versionTitle(
        version: String?,
        build: String?,
        isDebugBuild: Bool,
        bundlePath: String
    ) -> String? {
        let base: String
        switch (version, build) {
        case let (version?, build?): base = String(format: String(localized: "Version %@ (%@)"), version, build)
        case let (version?, nil): base = String(format: String(localized: "Version %@"), version)
        case let (nil, build?): base = String(format: String(localized: "Version (%@)"), build)
        case (nil, nil): return nil
        }
        guard let suffix = suffix(isDebugBuild: isDebugBuild, bundlePath: bundlePath) else {
            return base
        }
        return "\(base) · \(suffix)"
    }
}
