import Darwin
import Foundation
import IcliSystemPrivate

/// Physical paths for this process; bootstrap path conversion stays in Runtime.m.
public struct JailbreakRoot: Equatable {
    public enum Layout: String { case rootful, rootless, roothide }

    public let layout: Layout?
    public let jbroot: String
    public let source: String

    /// The bootstrap this process sees. A long-running host may start before
    /// the bootstrap is installed or outlive its removal, so an answer that
    /// found none, or whose jbroot is gone, is looked up again, at most once
    /// a second.
    public static var current: JailbreakRoot {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if let root = cache.root, root.layout != nil, access(root.jbroot, F_OK) == 0 {
            return root
        }
        if let root = cache.root, now - cache.checked < 1 {
            return root
        }
        let root = detect()
        cache.root = root
        cache.checked = now
        return root
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var root: JailbreakRoot?
        var checked: TimeInterval = 0
    }

    private static let cache = Cache()

    public func jbrootPath(_ path: String) -> String {
        takeCString(icli_jbroot_path(path)) ?? path
    }

    /// Translate a path for an external bootstrap tool, not Foundation file APIs.
    public func rootfsPath(_ path: String) -> String {
        takeCString(icli_rootfs_path(path)) ?? path
    }

    public func scratchDirectory() -> String {
        let candidates = [NSTemporaryDirectory(), jbrootPath("/tmp")]
        return candidates.first { FileManager.default.isWritableFile(atPath: $0) } ?? NSTemporaryDirectory()
    }

    public func binary(_ name: String) -> String {
        if name.contains("/") {
            if FileManager.default.isExecutableFile(atPath: name) {
                return name
            }
            return jbrootPath(name)
        }
        let dirs = ["/usr/bin", "/usr/sbin", "/bin", "/sbin"]
        let candidates = dirs.map { jbrootPath($0 + "/" + name) } + dirs.map { $0 + "/" + name }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? jbrootPath("/usr/bin/" + name)
    }

    private static func detect() -> JailbreakRoot {
        let raw = takeCString(icli_bootstrap_json()) ?? "{}"
        let data = Data(raw.utf8)
        let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return JailbreakRoot(
            layout: (info["layout"] as? String).flatMap(Layout.init(rawValue:)),
            jbroot: info["jbroot"] as? String ?? "/",
            source: info["source"] as? String ?? "unavailable",
        )
    }
}
