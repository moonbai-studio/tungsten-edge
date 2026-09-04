import Foundation

/// 同一应用的几张窗口卡共享的那一段标题，不承担区分作用，从标签上去掉（issue #41）。
///
/// Safari 开两个同配置窗口时标题是「个人 — 起始页」「个人 — 哔哩哔哩」，「个人 —」在两张卡上
/// 一模一样，却把真正区分窗口的后半截挤过 `WindowTitleTextMetrics.maximumWidth`（140pt）截断。
/// 应用名后缀（`WindowDisplayTitle.trimmingAppNameSuffix`）是这件事的一个特例，但够不着
/// 配置文件名这种**前缀**式重复，也够不着「mio: 」这种不是应用名的重复。
///
/// **动态是有意的**（owner 2026-09-04）：再开一个「工作」配置的窗口后，「个人」开始能区分窗口，
/// 于是三张卡都重新显示它。标签因此会随窗口开关变长变短——这正是「只显示当前能区分的部分」。
///
/// 调用点在投影层（`DockStripView.makeProjection`），按**这条 bar 上实际显示的卡**分组：
/// 多屏模式 ④ 下每块屏只显示本屏的窗口，公共段各屏不同，在数据层按全集算会把某块屏上
/// 仅剩的一张卡剥掉它唯一的区分信息。
enum StripSharedAffixTrim {
    /// 同一应用的一组标题 → 去掉公共前缀 / 后缀之后的标题（顺序与入参一一对应）。
    ///
    /// **全有或全无**：任何一条会被截空、或公共段切不到分隔符边界，就整组原样返回。
    /// 只截其中几张卡是最坏的结果——用户看到的是一排对不齐的半截标题。
    static func trimmingSharedAffixes(_ titles: [String]) -> [String] {
        guard titles.count >= 2 else { return titles }

        let afterPrefix = trimmingSharedPrefix(titles)
        return trimmingSharedSuffix(afterPrefix)
    }

    // MARK: - 前缀

    private static func trimmingSharedPrefix(_ titles: [String]) -> [String] {
        guard let raw = sharedPrefix(titles), !raw.isEmpty else { return titles }
        // **回退到最后一个分隔符边界**。这一步不能省：「mio: Notifications」和「mio: New Tab」
        // 的原始公共前缀是「mio: N」（两个词都以 N 开头），直接切会得到「otifications」。
        guard let cut = raw.range(ofLastSeparatorBoundary: separators)?.upperBound else { return titles }
        let affix = String(raw[raw.startIndex..<cut])
        guard !affix.isEmpty else { return titles }

        let trimmed = titles.map { String($0.dropFirst(affix.count)) }
        return isAcceptable(trimmed) ? trimmed.map(cleaned) : titles
    }

    private static func sharedPrefix(_ titles: [String]) -> String? {
        titles.dropFirst().reduce(titles[0]) { $0.commonPrefix(with: $1) }
    }

    // MARK: - 后缀

    private static func trimmingSharedSuffix(_ titles: [String]) -> [String] {
        let reversed = titles.map { String($0.reversed()) }
        guard let rawReversed = sharedPrefix(reversed), !rawReversed.isEmpty else { return titles }
        let raw = String(rawReversed.reversed())
        // 后缀方向找**第一个**分隔符边界（在反转前的字符串里看就是最靠左的那个）。
        guard let cut = raw.range(ofFirstSeparatorBoundary: separators)?.lowerBound else { return titles }
        let affix = String(raw[cut..<raw.endIndex])
        guard !affix.isEmpty else { return titles }

        let trimmed = titles.map { String($0.dropLast(affix.count)) }
        return isAcceptable(trimmed) ? trimmed.map(cleaned) : titles
    }

    // MARK: - 护栏

    /// 截完之后每一条都必须还剩下东西。留一条空标签，那张卡就成了一张没名字的窗口卡。
    private static func isAcceptable(_ trimmed: [String]) -> Bool {
        trimmed.allSatisfy { !cleaned($0).isEmpty }
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 分隔符边界。比 `WindowDisplayTitle` 那张表多了冒号——它只服务尾部应用名，
    /// 而「mio: 」这种前缀式重复靠的正是冒号。长的排前面，避免短的先命中切掉半个。
    static let separators = [" — ", " – ", " - ", " | ", " · ", " » ", " > ",
                            "：", ": ", "—", "–", "|", "·", "»", ">", ":", "-"]
}

private extension String {
    /// 落在本串内的**最后一个**分隔符出现位置（用于回退公共前缀）。
    func range(ofLastSeparatorBoundary separators: [String]) -> Range<String.Index>? {
        separators.compactMap { range(of: $0, options: .backwards) }
            .max { $0.upperBound < $1.upperBound }
    }

    /// 落在本串内的**第一个**分隔符出现位置（用于收紧公共后缀）。
    func range(ofFirstSeparatorBoundary separators: [String]) -> Range<String.Index>? {
        separators.compactMap { range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }
}
