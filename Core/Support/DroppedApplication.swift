import Foundation
import UniformTypeIdentifiers

/// Which app bundle a dropped file URL stands for. Reads the disk: call it once per drag session.
enum DroppedApplication {
    /// The app bundle `url` stands for — itself, or the target of a symlink or Finder alias — or nil.
    /// Since macOS 13 `/Applications/Safari.app` is a symlink into the Safari Cryptex and reads as
    /// `public.symlink`, so the item itself must not be asked. Callers pass this URL on, not the
    /// dragged one: `Bundle(url:)` cannot read an alias file.
    ///
    /// UTType first (it knows a bundle whose extension was renamed or dropped), the extension only
    /// when no type reads. An `.app` is a directory, so a directory test can never decide this.
    static func bundleURL(for url: URL, homeDirectory: URL) -> URL? {
        guard url.isFileURL else { return nil }
        var target = url
        if (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true {
            // An alias whose volume is not mounted stays unresolved (not an app), never a mount prompt.
            // A dangling symlink resolves to its missing destination, which the extension test would pass.
            guard let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]),
                  (try? resolved.checkResourceIsReachable()) == true
            else { return nil }
            // The Trash gate looks at the dragged item; a link into the Trash must not slip past it.
            guard !TrashPath.isInsideTrash(resolved, homeDirectory: homeDirectory) else { return nil }
            target = resolved
        }
        if let type = (try? target.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            return type.conforms(to: .application) ? target : nil
        }
        return target.pathExtension.lowercased() == "app" ? target : nil
    }
}
