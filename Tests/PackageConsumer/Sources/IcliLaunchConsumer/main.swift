import Foundation
import IcliLaunch

/// The launch product on its own: no IcliKit, no private bridge import, and
/// no UIKit or ArchiveKit in the link. With a bundle identifier it launches
/// that app, which is what the device check runs.
let launchAPIs: [Any] = [
    lockState as () -> [String: Any],
    frontmostApp as () -> [String: Any],
    launchApp as (String) throws -> [String: Any],
]
precondition(launchAPIs.count == 3)
var report: [String: Any] = [
    "library": "IcliLaunch",
    "api_count": launchAPIs.count,
    "lock": lockState(),
    "frontmost": frontmostApp(),
]
if CommandLine.arguments.count > 1 {
    do {
        report["launch"] = try launchApp(CommandLine.arguments[1])
    } catch let error as IcliError {
        report["launch"] = error.payload
    }
}

try print(String(decoding: JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
