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

do {
    guard CommandLine.arguments.count == 2 else { throw TestFailure.check("usage: archive-locale-tests <deb>") }
    try run(deb: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("PASS: Unicode IPA and deb names in the C locale, byte preservation, rejection checks, thread-local restoration")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
