import Foundation

/// The paths launchd itself opens from a job's property list, and the rewrite
/// RootHide's `launchctl` makes to them before a bootstrap (`plistpatch.m`).
///
/// launchd runs outside the bootstrap's view of the file system, so on
/// RootHide the executable and the other paths launchd reads get the jbroot
/// put in front (`/rootfs/x` names the real `/x`), and the file is marked
/// `__Patched`. RootHide renames its root at every jailbreak: a `__Patched`
/// plist still naming an earlier root has that root replaced with the current
/// one, and its paths that name no root are left alone, because the rewrite
/// already decided about them. A job whose program is under `/rootfs/`, or
/// whose plist lies outside the jbroot, is a system job and is not touched.
/// Rootless and rootful `launchctl` rewrite nothing.
///
/// Only the paths launchd reads move. The other program arguments are read by
/// the program itself, inside the bootstrap's view, and stay as written.
///
/// Pure: no file system access, so it is tested on the Mac.
public enum LaunchdPlistPaths {
    /// The top-level keys whose string value is a path launchd opens.
    static let pathKeys = ["RootDirectory", "WorkingDirectory", "StandardInPath", "StandardOutPath", "StandardErrorPath"]
    /// The top-level keys whose value is a list of such paths.
    static let pathListKeys = ["WatchPaths", "QueueDirectories"]
    /// The environment variables launchd sets that name a directory.
    static let environmentPathKeys = ["CFFIXED_USER_HOME", "HOME", "TMPDIR"]

    /// One path launchd reads: where it sits in the plist, as written, and as
    /// launchd opens it.
    public struct Entry: Equatable {
        public let key: String
        public let written: String
        public let launchd: String
    }

    /// The job as RootHide's `launchctl` leaves it for launchd, or nil when
    /// it is right already or is a system job. `plistPath` and `root` are
    /// physical paths; `root` is the current jbroot.
    public static func prepared(_ job: [String: Any], plistPath: String, root: String) -> [String: Any]? {
        guard let move = rootHideMove(job, plistPath: plistPath, root: root) else { return nil }
        var plist = rewrite(job) { _, path in move(path) }
        plist["__Patched"] = true
        return NSDictionary(dictionary: plist).isEqual(to: job) ? nil : plist
    }

    /// Every path launchd reads from `job`, as it opens them under `root`:
    /// RootHide's rewrite when `rootHide`, the written path otherwise.
    public static func entries(_ job: [String: Any], plistPath: String, root: String, rootHide: Bool) -> [Entry] {
        let move = rootHide ? rootHideMove(job, plistPath: plistPath, root: root) : nil
        var entries: [Entry] = []
        _ = rewrite(job) { key, path in
            entries.append(Entry(key: key, written: path, launchd: move?(path) ?? path))
            return path
        }
        return entries
    }

    /// Whether RootHide's `launchctl` leaves this job alone.
    public static func isSystemJob(_ job: [String: Any], plistPath: String, root: String) -> Bool {
        rootHideMove(job, plistPath: plistPath, root: root) == nil
    }

    /// The rewrite RootHide applies to each path of this job, or nil for a
    /// system job.
    static func rootHideMove(_ job: [String: Any], plistPath: String, root: String) -> ((String) -> String)? {
        guard isUnder(plistPath, root: root) else { return nil }
        let isPatched = job["__Patched"] as? Bool == true
        let arguments = job["ProgramArguments"] as? [Any]
        let program = job["Program"] as? String ?? arguments?.first as? String
        if !isPatched, program?.hasPrefix("/rootfs/") == true {
            return nil
        }
        return isPatched ? { rerooted($0, root: root) } : { physical($0, root: root) }
    }

    /// `job` with every path launchd reads replaced by `move(key, path)`, in
    /// plistpatch.m's order. `Program` wins over `ProgramArguments[0]`. A
    /// socket entry may also be an array of dictionaries, which launchd
    /// accepts and plistpatch.m skips.
    static func rewrite(_ job: [String: Any], _ move: (String, String) -> String) -> [String: Any] {
        var plist = job
        if let value = job["Program"] as? String {
            plist["Program"] = move("Program", value)
        } else if var arguments = job["ProgramArguments"] as? [Any], let first = arguments.first as? String {
            arguments[0] = move("ProgramArguments[0]", first)
            plist["ProgramArguments"] = arguments
        }
        for key in pathKeys {
            if let value = plist[key] as? String {
                plist[key] = move(key, value)
            }
        }
        for key in pathListKeys {
            if let values = plist[key] as? [Any] {
                plist[key] = values.enumerated().map { index, value in
                    (value as? String).map { move("\(key)[\(index)]", $0) } ?? value
                }
            }
        }
        if var environment = plist["EnvironmentVariables"] as? [String: Any] {
            for key in environmentPathKeys {
                if let value = environment[key] as? String {
                    environment[key] = move("EnvironmentVariables.\(key)", value)
                }
            }
            plist["EnvironmentVariables"] = environment
        }
        if var keepAlive = plist["KeepAlive"] as? [String: Any], let states = keepAlive["PathState"] as? [String: Any] {
            var moved: [String: Any] = [:]
            for (path, value) in states.sorted(by: { $0.key < $1.key }) {
                let key = move("KeepAlive.PathState", path)
                if moved[key] == nil {
                    moved[key] = value
                }
            }
            keepAlive["PathState"] = moved
            plist["KeepAlive"] = keepAlive
        }
        if var sockets = plist["Sockets"] as? [String: Any] {
            for (name, value) in sockets.sorted(by: { $0.key < $1.key }) {
                if let list = value as? [Any] {
                    sockets[name] = list.enumerated().map { index, socket in
                        moveSocket(socket, key: "Sockets.\(name)[\(index)].SockPathName", move)
                    }
                } else {
                    sockets[name] = moveSocket(value, key: "Sockets.\(name).SockPathName", move)
                }
            }
            plist["Sockets"] = sockets
        }
        let fsevents = "com.apple.fsevents.matching"
        if var events = plist["LaunchEvents"] as? [String: Any], var matching = events[fsevents] as? [String: Any] {
            for (name, value) in matching.sorted(by: { $0.key < $1.key }) {
                guard var event = value as? [String: Any], let path = event["Path"] as? String else { continue }
                event["Path"] = move("LaunchEvents.\(fsevents).\(name).Path", path)
                matching[name] = event
            }
            events[fsevents] = matching
            plist["LaunchEvents"] = events
        }
        return plist
    }

    private static func moveSocket(_ value: Any, key: String, _ move: (String, String) -> String) -> Any {
        guard var socket = value as? [String: Any], let name = socket["SockPathName"] as? String else { return value }
        socket["SockPathName"] = move(key, name)
        return socket
    }

    /// A path as written inside the bootstrap, as the kernel sees it:
    /// libroothide's `jbroot()`.
    static func physical(_ value: String, root: String) -> String {
        guard value.hasPrefix("/") else { return value }
        if value.hasPrefix("/rootfs/") {
            return String(value.dropFirst("/rootfs".count))
        }
        if isUnder(value, root: root) {
            return value
        }
        if let earlier = rootPrefix(of: value) {
            return root + value.dropFirst(earlier.count)
        }
        return root + value
    }

    /// A path a rewrite already made, moved from an earlier root to `root`.
    static func rerooted(_ value: String, root: String) -> String {
        guard !isUnder(value, root: root), let earlier = rootPrefix(of: value) else { return value }
        return root + value.dropFirst(earlier.count)
    }

    /// Whether `value` is `root` or inside it, in either spelling of `/var`.
    public static func isUnder(_ value: String, root: String) -> Bool {
        relative(value, root: root) != nil
    }

    /// `value` with `root` taken off the front ("/" for the root itself), or
    /// nil when it is not inside `root`.
    public static func relative(_ value: String, root: String) -> String? {
        guard root != "/" else { return value }
        var spellings = [root]
        if root.hasPrefix("/private/var/") {
            spellings.append(String(root.dropFirst("/private".count)))
        }
        if root.hasPrefix("/var/") {
            spellings.append("/private" + root)
        }
        for spelling in spellings {
            if value == spelling {
                return "/"
            }
            if value.hasPrefix(spelling + "/") {
                return String(value.dropFirst(spelling.count))
            }
        }
        return nil
    }

    /// The leading part of `value` up to and including a RootHide root
    /// directory name, when it has one.
    static func rootPrefix(of value: String) -> String? {
        var prefix = ""
        for component in value.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + component
            if isRootName(component) {
                return prefix
            }
        }
        return nil
    }

    /// `.jbroot-` followed by sixteen hex digits.
    static func isRootName(_ component: Substring) -> Bool {
        guard component.hasPrefix(".jbroot-") else { return false }
        let digits = component.dropFirst(".jbroot-".count)
        return digits.count == 16 && digits.allSatisfy(\.isHexDigit)
    }

    /// One plist's report for `svc paths`: each path launchd reads, whether
    /// launchd's spelling exists, and, when it does not but the spelling on
    /// the other side of the jbroot does, a hint naming what to write.
    /// `exists` answers true, false or nil (could not tell).
    public static func report(
        _ job: [String: Any],
        plistPath: String,
        root: String,
        rootHide: Bool,
        exists: (String) -> Bool?,
    ) -> [String: Any] {
        let system = rootHide && isSystemJob(job, plistPath: plistPath, root: root)
        let isPatched = job["__Patched"] as? Bool == true
        var rows: [[String: Any]] = []
        for entry in entries(job, plistPath: plistPath, root: root, rootHide: rootHide) {
            var row: [String: Any] = ["key": entry.key, "written": entry.written, "launchd": entry.launchd]
            guard entry.launchd.hasPrefix("/") else {
                row["exists"] = NSNull()
                row["hint"] = "relative path; launchd resolves it against its own working directory"
                rows.append(row)
                continue
            }
            let found = exists(entry.launchd)
            row["exists"] = found ?? NSNull()
            if found == false, root != "/" {
                let other = relative(entry.launchd, root: root) ?? root + entry.launchd
                if exists(other) == true {
                    let spelling = suggestedSpelling(
                        other,
                        root: root,
                        rewritten: rootHide && !system && !isPatched,
                    )
                    row["hint"] = "\(entry.launchd) does not exist; \(other) does. Write \(spelling)."
                    row["suggested"] = spelling
                }
            }
            rows.append(row)
        }
        var result: [String: Any] = [
            "path": plistPath,
            "label": job["Label"] as? String ?? NSNull(),
            "patched": isPatched,
            "paths": rows,
        ]
        if rootHide {
            result["system_job"] = system
            result["load_rewrites"] = prepared(job, plistPath: plistPath, root: root) != nil
        }
        return result
    }

    /// How to write `target` so launchd opens it: through RootHide's rewrite
    /// a path inside the jbroot is written without it and one outside under
    /// `/rootfs`; with no rewrite, as the kernel names it.
    static func suggestedSpelling(_ target: String, root: String, rewritten: Bool) -> String {
        guard rewritten else { return target }
        return relative(target, root: root) ?? "/rootfs" + target
    }
}
