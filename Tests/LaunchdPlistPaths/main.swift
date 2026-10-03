import Foundation

// RootHide launchctl's plist rewrite (plistpatch.m) and the `svc paths`
// report, checked on the Mac. The rewrite cases follow Knife's port.

enum TestFailure: Error {
    case check(String)
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure.check(message) }
}

func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure.check(message) }
    return value
}

let root = "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
let earlier = "/var/containers/Bundle/Application/.jbroot-FEDCBA9876543210"
let daemonPlist = root + "/Library/LaunchDaemons/com.example.daemon.plist"

func prepared(_ job: [String: Any], plist: String = daemonPlist) -> [String: Any]? {
    LaunchdPlistPaths.prepared(job, plistPath: plist, root: root)
}

func movesWhatLaunchdOpens() throws {
    let job: [String: Any] = [
        "Label": "com.example.daemon",
        "ProgramArguments": ["/usr/libexec/daemon", "--config", "/etc/daemon.conf"],
        "StandardErrorPath": "/var/log/daemon.log",
        "WorkingDirectory": "/var/mobile",
        "WatchPaths": ["/etc/daemon.conf", 7],
        "EnvironmentVariables": ["HOME": "/var/root", "PATH": "/usr/bin:/bin"],
        "KeepAlive": ["PathState": ["/var/run/daemon.flag": true]],
        "Sockets": [
            "Listener": ["SockPathName": "/var/run/daemon.sock"],
            "Pair": [["SockPathName": "/var/run/a.sock"], ["SockServiceName": "80"]],
        ],
        "LaunchEvents": ["com.apple.fsevents.matching": ["conf": ["Path": "/etc/daemon.conf"]]],
    ]
    let plist = try unwrap(prepared(job), "an unpatched daemon was not rewritten")
    try check(plist["__Patched"] as? Bool == true, "__Patched not set")
    // Only the executable moves; the program reads its own arguments.
    try check(
        plist["ProgramArguments"] as? [String] == [root + "/usr/libexec/daemon", "--config", "/etc/daemon.conf"],
        "program arguments: \(plist["ProgramArguments"] ?? "nil")",
    )
    try check(plist["StandardErrorPath"] as? String == root + "/var/log/daemon.log", "StandardErrorPath")
    try check(plist["WorkingDirectory"] as? String == root + "/var/mobile", "WorkingDirectory")
    let watch = try unwrap(plist["WatchPaths"] as? [Any], "WatchPaths missing")
    try check(watch.first as? String == root + "/etc/daemon.conf" && watch.last as? Int == 7, "WatchPaths: \(watch)")
    let environment = try unwrap(plist["EnvironmentVariables"] as? [String: String], "environment missing")
    try check(environment == ["HOME": root + "/var/root", "PATH": "/usr/bin:/bin"], "environment: \(environment)")
    let keepAlive = try unwrap(plist["KeepAlive"] as? [String: Any], "KeepAlive missing")
    try check(
        (keepAlive["PathState"] as? [String: Bool])?.keys.first == root + "/var/run/daemon.flag",
        "PathState: \(keepAlive)",
    )
    let sockets = try unwrap(plist["Sockets"] as? [String: Any], "Sockets missing")
    try check((sockets["Listener"] as? [String: String])?["SockPathName"] == root + "/var/run/daemon.sock", "Listener socket")
    try check(
        sockets["Pair"] as? [[String: String]] == [["SockPathName": root + "/var/run/a.sock"], ["SockServiceName": "80"]],
        "socket array: \(sockets["Pair"] ?? "nil")",
    )
    let events = try unwrap(plist["LaunchEvents"] as? [String: [String: [String: String]]], "LaunchEvents missing")
    try check(events["com.apple.fsevents.matching"]?["conf"]?["Path"] == root + "/etc/daemon.conf", "fsevents path")
    // Preparing again changes nothing.
    try check(prepared(plist) == nil, "a prepared plist was rewritten again")
}

func leavesSystemJobsAndCurrentRootsAlone() throws {
    try check(prepared(["Label": "sys", "Program": "/rootfs/usr/libexec/sys"]) == nil, "a /rootfs/ program was rewritten")
    try check(
        prepared(["Label": "sys", "ProgramArguments": ["/rootfs/usr/libexec/sys"], "WatchPaths": ["/var/x"]]) == nil,
        "a /rootfs/ ProgramArguments[0] was rewritten",
    )
    try check(
        prepared(["Label": "done", "Program": root + "/usr/bin/done", "__Patched": true]) == nil,
        "a plist patched for the current root was rewritten",
    )
    // A patched path that names no root was decided on already.
    try check(prepared(["Label": "sys", "Program": "/usr/libexec/sys", "__Patched": true]) == nil, "a decided path moved")
    // A plist outside the jbroot is the system's, as /rootfs/… is to launchctl.
    try check(
        prepared(["Label": "tmp", "Program": "/usr/bin/sleep"], plist: "/private/var/tmp/x.plist") == nil,
        "a plist outside the jbroot was rewritten",
    )
    // Irisin's preparePlist: the kernel path and __Patched, nothing else.
    let irisin: [String: Any] = [
        "Label": "wiki.qaq.irisin",
        "ProgramArguments": [root + "/usr/libexec/irisind", "serve"],
        "MachServices": ["wiki.qaq.irisin": true],
        "__Patched": true,
    ]
    try check(prepared(irisin) == nil, "Irisin's prepared plist was rewritten")
}

func movesAnEarlierRoot() throws {
    let job: [String: Any] = [
        "Label": "moved",
        "Program": earlier + "/usr/libexec/moved",
        "StandardOutPath": "/dev/null",
        "WatchPaths": [earlier + "/var/mobile/Library/Logs/CrashReporter"],
        "__Patched": true,
    ]
    let plist = try unwrap(prepared(job), "an earlier root was not moved")
    try check(plist["Program"] as? String == root + "/usr/libexec/moved", "Program: \(plist["Program"] ?? "nil")")
    try check(plist["StandardOutPath"] as? String == "/dev/null", "a rootless patched path moved")
    try check(
        plist["WatchPaths"] as? [String] == [root + "/var/mobile/Library/Logs/CrashReporter"],
        "WatchPaths: \(plist["WatchPaths"] ?? "nil")",
    )
}

func physicalSpellings() throws {
    let physical = { LaunchdPlistPaths.physical($0, root: root) }
    try check(physical("/rootfs/x") == "/x", "/rootfs/x")
    try check(physical("/rootfs/usr/bin/x") == "/usr/bin/x", "/rootfs/usr/bin/x")
    try check(
        physical("/private/var/mobile/Library/Logs/CrashReporter") == root + "/private/var/mobile/Library/Logs/CrashReporter",
        "a bare /private/var path did not get the jbroot",
    )
    try check(physical(root + "/bin/x") == root + "/bin/x", "a path under the root moved")
    let aliased = String(root.dropFirst("/private".count)) + "/bin/x"
    try check(physical(aliased) == aliased, "the /var spelling of the root moved")
    try check(physical(earlier + "/bin/x") == root + "/bin/x", "an earlier root was not replaced")
    try check(physical("relative") == "relative", "a relative path moved")
    try check(LaunchdPlistPaths.rootPrefix(of: "/var/.jbroot-XYZ/bin") == nil, "a short root name matched")
    try check(LaunchdPlistPaths.relative("/var/jb/usr", root: "/var/jb") == "/usr", "rootless relative")
    try check(LaunchdPlistPaths.relative("/private/var/jb/usr", root: "/var/jb") == "/usr", "rootless /private spelling")
    try check(LaunchdPlistPaths.relative("/usr", root: "/var/jb") == nil, "outside the root")
}

/// Xrash's daemon on RootHide: `/rootfs/…` in WatchPaths becomes the system
/// path, and the report says it exists; the bare spelling would be put under
/// the jbroot, where it does not, and the hint says what to write.
func reports() throws {
    let crashes = "/private/var/mobile/Library/Logs/CrashReporter"
    let existing: Set<String> = [crashes, root + "/usr/libexec/xrashd"]
    let exists: (String) -> Bool? = { existing.contains($0) }
    let shipped: [String: Any] = [
        "Label": "wiki.qaq.xrashd",
        "ProgramArguments": ["/usr/libexec/xrashd"],
        "WatchPaths": ["/rootfs" + crashes],
    ]
    let good = LaunchdPlistPaths.report(shipped, plistPath: daemonPlist, root: root, rootHide: true, exists: exists)
    let goodRows = try unwrap(good["paths"] as? [[String: Any]], "no rows")
    try check(goodRows.count == 2, "rows: \(goodRows)")
    try check(goodRows[0]["key"] as? String == "ProgramArguments[0]" && goodRows[0]["exists"] as? Bool == true, "program row: \(goodRows[0])")
    try check(goodRows[1]["launchd"] as? String == crashes && goodRows[1]["exists"] as? Bool == true, "watch row: \(goodRows[1])")
    try check(good["load_rewrites"] as? Bool == true && good["system_job"] as? Bool == false, "flags: \(good)")

    var bare = shipped
    bare["WatchPaths"] = [crashes]
    let wrong = LaunchdPlistPaths.report(bare, plistPath: daemonPlist, root: root, rootHide: true, exists: exists)
    let row = try unwrap((wrong["paths"] as? [[String: Any]])?.last, "no rows")
    try check(row["launchd"] as? String == root + crashes && row["exists"] as? Bool == false, "bare row: \(row)")
    try check(row["suggested"] as? String == "/rootfs" + crashes, "suggestion: \(row)")

    // Rootless: launchd opens what is written.
    let rootless = LaunchdPlistPaths.report(
        ["Label": "x", "Program": "/var/jb/usr/bin/x", "WatchPaths": ["/var/mobile/x"]],
        plistPath: "/var/jb/Library/LaunchDaemons/x.plist",
        root: "/var/jb",
        rootHide: false,
        exists: { $0 == "/var/jb/var/mobile/x" },
    )
    let rows = try unwrap(rootless["paths"] as? [[String: Any]], "no rows")
    try check(rows.allSatisfy { $0["written"] as? String == $0["launchd"] as? String }, "rootless moved a path: \(rows)")
    try check(rows[1]["suggested"] as? String == "/var/jb/var/mobile/x", "rootless suggestion: \(rows[1])")
    try check(rootless["system_job"] == nil, "rootless reported a RootHide flag")
}

do {
    try movesWhatLaunchdOpens()
    try leavesSystemJobsAndCurrentRootsAlone()
    try movesAnEarlierRoot()
    try physicalSpellings()
    try reports()
    print("PASS: RootHide plist rewrite, system jobs and current roots left alone, earlier roots moved, path spellings, svc paths reports")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
