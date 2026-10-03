import Dispatch
import Foundation

// Archive names must survive the C locale a launchd daemon starts in.
// The ZIP builder and most cases come from Yanni Pang's vphone-cli#530.

enum TestFailure: Error {
    case check(String)
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure.check(message) }
}

func codeset() -> String { String(cString: nl_langinfo(CODESET)) }

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

/// A stored ZIP made entirely from synthetic bytes, with the UTF-8 flag set.
/// Building the records directly also allows invalid UTF-8 and CRC fixtures.
struct ZIPEntry {
    var name: Data
    var contents: Data
    var mode: UInt32
    var corruptCRC = false

    init(_ name: String, _ contents: String, mode: UInt32 = 0o100644) {
        self.name = Data(name.utf8)
        self.contents = Data(contents.utf8)
        self.mode = mode
    }
}

func zip(_ entries: [ZIPEntry]) -> Data {
    var output = Data(), directory = Data()
    for entry in entries {
        let offset = UInt32(output.count)
        let checksum = entry.contents.withUnsafeBytes {
            UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)))
        } ^ (entry.corruptCRC ? 1 : 0)
        output.appendLE(UInt32(0x04034B50))
        output.appendLE(UInt16(20))
        output.appendLE(UInt16(0x0800))
        output.appendLE(UInt16(0)) // stored
        output.appendLE(UInt16(0)) // time
        output.appendLE(UInt16(0)) // date
        output.appendLE(checksum)
        output.appendLE(UInt32(entry.contents.count))
        output.appendLE(UInt32(entry.contents.count))
        output.appendLE(UInt16(entry.name.count))
        output.appendLE(UInt16(0)) // extra
        output.append(entry.name)
        output.append(entry.contents)

        directory.appendLE(UInt32(0x02014B50))
        directory.appendLE(UInt16(0x0314)) // Unix creator
        directory.appendLE(UInt16(20))
        directory.appendLE(UInt16(0x0800))
        directory.appendLE(UInt16(0))
        directory.appendLE(UInt16(0))
        directory.appendLE(UInt16(0))
        directory.appendLE(checksum)
        directory.appendLE(UInt32(entry.contents.count))
        directory.appendLE(UInt32(entry.contents.count))
        directory.appendLE(UInt16(entry.name.count))
        directory.appendLE(UInt16(0)) // extra
        directory.appendLE(UInt16(0)) // comment
        directory.appendLE(UInt16(0)) // disk
        directory.appendLE(UInt16(0)) // internal attributes
        directory.appendLE(entry.mode << 16)
        directory.appendLE(offset)
        directory.append(entry.name)
    }
    let offset = UInt32(output.count)
    output.append(directory)
    output.appendLE(UInt32(0x06054B50))
    output.appendLE(UInt16(0))
    output.appendLE(UInt16(0))
    output.appendLE(UInt16(entries.count))
    output.appendLE(UInt16(entries.count))
    output.appendLE(UInt32(directory.count))
    output.appendLE(offset)
    output.appendLE(UInt16(0))
    return output
}

func json(_ result: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
    guard let result else { throw TestFailure.check("bridge returned no result") }
    defer { free(result) }
    return try JSONSerialization.jsonObject(with: Data(String(cString: result).utf8)) as! [String: Any]
}

func extract(_ archive: URL, _ destination: URL) throws -> [String: Any] {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    return try json(icli_extract_ipa_json(archive.path, destination.path))
}

final class Observation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func store(_ charset: String) { lock.lock(); value = charset; lock.unlock() }
    func read() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

func run(deb: URL) throws {
    setlocale(LC_ALL, "C")
    let original = uselocale(nil)
    let originalCodeset = codeset()
    try check(originalCodeset == "US-ASCII", "the test needs the C codeset")
    func restored() -> Bool { uselocale(nil) == original && codeset() == originalCodeset }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // IPA: a UTF-8 flagged name extracts with its bytes intact.
    let name = "Payload/Test.app/What’s New 中文.html"
    let content = "Synthetic Unicode resource\n"
    let resourceName = "Payload/Test.app/_CodeSignature/CodeResources"
    let resourceBytes = "Synthetic resource manifest\n"
    let data = zip([ZIPEntry(name, content), ZIPEntry(resourceName, resourceBytes)])
    let archive = root.appendingPathComponent("unicode.ipa")
    try data.write(to: archive)
    let destination = root.appendingPathComponent("unicode")
    let result = try extract(archive, destination)
    try check(result["error"] == nil && result["entries"] as? Int == 2, "Unicode IPA extraction failed: \(result)")
    try check(try Data(contentsOf: destination.appendingPathComponent(name)) == Data(content.utf8), "Unicode name or bytes changed")
    try check(try Data(contentsOf: destination.appendingPathComponent(resourceName)) == Data(resourceBytes.utf8), "resource bytes changed")
    try check(try Data(contentsOf: archive) == data, "input archive changed")
    try check(restored(), "IPA extraction changed the caller's locale")

    // IPA: the __MACOSX tree and AppleDouble files a Mac zips alongside are left out.
    let macZip = root.appendingPathComponent("mac.ipa")
    try zip([
        ZIPEntry("Payload/X.app/Info.plist", "plist"),
        ZIPEntry("Payload/._X.app", "appledouble"),
        ZIPEntry("Payload/X.app/._Info.plist", "appledouble"),
        ZIPEntry("Payload/X.app/._Link", "Info.plist", mode: 0o120777),
        ZIPEntry("__MACOSX/Payload/._X.app", "appledouble"),
    ]).write(to: macZip)
    let macRoot = root.appendingPathComponent("mac")
    let macResult = try extract(macZip, macRoot)
    try check(macResult["error"] == nil, "Mac-zipped IPA extraction failed: \(macResult)")
    // contentsOfDirectory hides "._" names on macOS; iOS lists them.
    let extracted = try FileManager.default.subpathsOfDirectory(atPath: macRoot.path).sorted()
    let expected = ["Payload", "Payload/X.app", "Payload/X.app/._Link", "Payload/X.app/Info.plist"]
    try check(extracted == expected, "Mac metadata was extracted, or a symlink was lost: \(extracted)")

    // The existing integrity and path-safety checks still reject bad entries.
    var invalid = ZIPEntry("Payload/Test.app/invalid.txt", "data")
    invalid.name = Data("Payload/Test.app/".utf8) + Data([0xFF]) + Data(".txt".utf8)
    var badCRC = ZIPEntry(name, content)
    badCRC.corruptCRC = true
    let failures: [(String, [ZIPEntry], String)] = [
        ("invalid-utf8", [invalid], "current locale"),
        ("crc", [badCRC], "CRC"),
        ("traversal", [ZIPEntry("../escape", "data")], "unsafe entry path"),
        ("symlink", [ZIPEntry("Payload/Test.app/link", "../../../../escape", mode: 0o120777)], "symlink escapes"),
    ]
    for (label, entries, expected) in failures {
        let source = root.appendingPathComponent("\(label).ipa")
        try zip(entries).write(to: source)
        let failure = try extract(source, root.appendingPathComponent(label))
        try check((failure["error"] as? String)?.contains(expected) == true, "\(label) was not rejected: \(failure)")
        try check(restored(), "\(label) changed the caller's locale")
    }
    try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path), "traversal wrote outside its root")

    // deb: a PAX data member with a UTF-8 path lists, unpacks and reads back.
    let debName = "/var/jb/usr/share/icli-locale-test/What’s New 中文.txt"
    let listing = try json(icli_deb_read_json(deb.path, nil))
    let files = (listing["files"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
    try check(listing["error"] == nil && files.contains("." + debName), "Unicode deb listing failed: \(listing)")
    let prefix = root.appendingPathComponent("prefix")
    let unpacked = try json(icli_deb_unpack_json(deb.path, prefix.path, nil, 0))
    try check((unpacked["installed"] as? [String])?.contains(debName) == true && unpacked["error"] == nil, "Unicode deb unpack failed: \(unpacked)")
    try check(try String(contentsOf: URL(fileURLWithPath: prefix.path + debName), encoding: .utf8) == "unicode deb\n", "unpacked deb bytes changed")
    let dataTar = deb.deletingLastPathComponent().appendingPathComponent("data.tar.gz")
    guard let text = icli_tar_entry_text(dataTar.path, String(debName.dropFirst())) else {
        throw TestFailure.check("Unicode tar entry was not found")
    }
    defer { free(text) }
    try check(String(cString: text) == "unicode deb\n", "tar entry text changed")
    try check(restored(), "deb reading changed the caller's locale")

    // The UTF-8 locale belongs to the calling thread only, and nests.
    let observing = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    let observation = Observation()
    DispatchQueue.global().async {
        observing.wait()
        observation.store(codeset())
        finished.signal()
    }
    var inside = "", nested = "", other = "", afterNested = false
    _ = icli_archive_with_utf8_names {
        inside = codeset()
        let outer = uselocale(nil)
        _ = icli_archive_with_utf8_names { nested = codeset(); return nil }
        afterNested = uselocale(nil) == outer
        observing.signal()
        _ = finished.wait(timeout: .now() + 5)
        other = observation.read()
        return nil
    }
    try check(inside == "UTF-8" && nested == "UTF-8", "the reader did not see UTF-8 (\(inside), \(nested))")
    try check(afterNested, "a nested scope did not restore the outer locale")
    try check(other == originalCodeset, "the UTF-8 scope leaked to another thread: \(other)")
    try check(restored(), "the scope did not restore the caller's locale")
}

/// An ar archive with one member, built by hand so its name can be any bytes.
func arArchive(memberName: Data, contents: Data) -> Data {
    func field(_ text: String, _ width: Int) -> Data {
        Data(text.utf8) + Data(repeating: 0x20, count: width - text.utf8.count)
    }
    var output = Data("!<arch>\n".utf8)
    output.append(memberName + Data(repeating: 0x20, count: 16 - memberName.count))
    output.append(field("0", 12) + field("0", 6) + field("0", 6) + field("100644", 8))
    output.append(field(String(contents.count), 10) + Data("`\n".utf8))
    output.append(contents)
    if contents.count % 2 == 1 { output.append(0x0A) }
    return output
}

func runDebSafety(links: URL, escape: URL, outside: URL) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Only top-level control members count, and never one named "list".
    let listing = try json(icli_deb_read_json(links.path, nil))
    let texts = listing["control_texts"] as? [String: Any] ?? [:]
    try check(listing["error"] == nil, "hard-link deb listing failed: \(listing)")
    try check(Set(texts.keys) == ["control"], "a nested or reserved control member was taken: \(texts.keys.sorted())")
    try check((listing["scripts"] as? [String])?.isEmpty == true, "a nested postinst was reported as a script")

    // A tar hard link installs as a link to the file, not as an empty file.
    let prefix = root.appendingPathComponent("prefix")
    let unpacked = try json(icli_deb_unpack_json(links.path, prefix.path, nil, 0))
    try check(unpacked["error"] == nil, "hard-link deb unpack failed: \(unpacked)")
    let tool = prefix.path + "/var/jb/usr/bin/tool", alias = prefix.path + "/var/jb/usr/bin/alias"
    try check(try String(contentsOfFile: alias, encoding: .utf8) == "linked tool\n", "the hard link was installed empty")
    let toolInode = try FileManager.default.attributesOfItem(atPath: tool)[.systemFileNumber] as? Int
    let aliasInode = try FileManager.default.attributesOfItem(atPath: alias)[.systemFileNumber] as? Int
    try check(toolInode != nil && toolInode == aliasInode, "the alias is a copy, not a hard link")

    // Writing through a planted symlink is refused before any directory is made.
    let staging = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let escaped = try json(icli_deb_read_json(escape.path, staging.path))
    try check((escaped["error"] as? String)?.contains("escapes") == true, "the symlink escape was not rejected: \(escaped)")
    try check(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("x").path), "directories were created outside the staging root")

    // A member name that is not UTF-8 fails the read instead of throwing.
    let invalid = root.appendingPathComponent("invalid.deb")
    try arArchive(memberName: Data("data".utf8) + Data([0xFF, 0xFE]) + Data(".tar/".utf8), contents: Data("x".utf8)).write(to: invalid)
    for result in [try json(icli_deb_read_json(invalid.path, nil)), try json(icli_deb_unpack_json(invalid.path, prefix.path, nil, 0))] {
        try check(result["error"] is String, "a non-UTF-8 member name was accepted: \(result)")
    }
}

func runJSONGuards() throws {
    // NSJSONSerialization throws on these; the guards must answer nil instead.
    try check(icli_json(["x": Double.nan]) == nil, "icli_json serialized NaN")
    try check(icli_system_json(["x": Double.infinity]) == nil, "icli_system_json serialized infinity")
    if let valid = icli_json(["x": 1]) { free(valid) } else { throw TestFailure.check("icli_json rejected a valid object") }
    let bytes: [CChar] = [0x61, -1, 0x62, 0]
    try check(icli_system_string(bytes, 4) == "a\u{FF}b", "a non-UTF-8 name was not decoded as Latin-1")
    try check(icli_system_double(.nan) as? String == "nan", "a NaN double was not turned into text")
    let safe = jsonSafe([
        "nan": Double.nan,
        "nested": ["inf": -Double.infinity, "date": Date(timeIntervalSince1970: 0), "data": Data([1, 2])],
        "keys": NSDictionary(dictionary: [1: "one"]),
    ] as [String: Any])
    try check(JSONSerialization.isValidJSONObject(safe), "jsonSafe left a value JSONSerialization rejects: \(safe)")
}

do {
    guard CommandLine.arguments.count == 5 else {
        throw TestFailure.check("usage: archive-locale-tests <deb> <hard-link deb> <escape deb> <outside dir>")
    }
    try run(deb: URL(fileURLWithPath: CommandLine.arguments[1]))
    try runDebSafety(
        links: URL(fileURLWithPath: CommandLine.arguments[2]),
        escape: URL(fileURLWithPath: CommandLine.arguments[3]),
        outside: URL(fileURLWithPath: CommandLine.arguments[4]),
    )
    try runJSONGuards()
    print("PASS: Unicode IPA and deb names in the C locale, byte preservation, Mac metadata skipped, rejection checks, thread-local restoration, deb hard links and control members, symlink escapes, non-UTF-8 member names, JSON guards")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
