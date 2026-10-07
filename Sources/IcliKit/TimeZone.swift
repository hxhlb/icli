import Foundation
import IcliPrivate
import IcliSystem

private let zoneInfoDirectory = "/var/db/timezone/zoneinfo/"
private let localTimeLink = "/var/db/timezone/localtime"

/// The Olson name the system time zone link points to. Read from the link,
/// not `TimeZone.current`, which a long-running process caches.
private func systemTimeZoneIdentifier() -> String? {
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: localTimeLink) else {
        return nil
    }
    return target.hasPrefix(zoneInfoDirectory) ? String(target.dropFirst(zoneInfoDirectory.count)) : target
}

/// Whether timed sets the zone itself; nil when CoreTime does not offer it.
private func automaticTimeZoneEnabled() throws -> Bool? {
    switch icli_automatic_time_zone_get() {
    case 1: true
    case 0: false
    case -2: throw IcliError.unavailable("timed did not answer within 3 seconds.")
    default: nil
    }
}

/// The system time zone: `identifier`, the Olson name, `automatic`, whether
/// timed sets it from the network and location (null when CoreTime does not
/// say), and `seconds_from_gmt` now.
public func timeZone() throws -> [String: Any] {
    let identifier = systemTimeZoneIdentifier()
    let zone = identifier.flatMap(TimeZone.init(identifier:))
    return try [
        "identifier": identifier.map { $0 as Any } ?? NSNull(),
        "automatic": automaticTimeZoneEnabled().map { $0 as Any } ?? NSNull(),
        "seconds_from_gmt": zone.map { $0.secondsFromGMT() as Any } ?? NSNull(),
    ]
}

/// Turns timed's automatic time zone on or off, as Settings' Set Automatically
/// does, and waits until timed reports the change. `changed` is false when it
/// already had that setting.
public func setAutomaticTimeZone(_ enabled: Bool) throws -> [String: Any] {
    var state = try timeZone()
    guard let current = state["automatic"] as? Bool else {
        throw IcliError.unavailable("CoreTime's automatic time zone setting is unavailable on this device.")
    }
    if current != enabled {
        guard icli_automatic_time_zone_set(enabled) == 0 else {
            throw IcliError.unavailable("CoreTime's automatic time zone setting is unavailable on this device.")
        }
        let deadline = Date().addingTimeInterval(2)
        while try automaticTimeZoneEnabled() != enabled {
            guard Date() < deadline else {
                throw IcliError.unavailable("timed did not apply the change. The process needs the com.apple.timed entitlement.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        state = try timeZone()
    }
    state["changed"] = current != enabled
    return state
}

/// Sets the system time zone to an Olson name such as `Asia/Shanghai`. The
/// automatic time zone is turned off first, as Settings does when a city is
/// picked, so timed does not put its own zone back. tzlinkd re-points the link
/// and posts SignificantTimeChangeNotification, and notifyd posts
/// com.apple.system.timezone, so running apps and SpringBoard follow at once.
/// `changed` is false when the device was already set to it by hand.
public func setTimeZone(_ identifier: String) throws -> [String: Any] {
    let components = identifier.split(separator: "/", omittingEmptySubsequences: false)
    var isDirectory: ObjCBool = false
    guard !components.contains(where: { $0.isEmpty || $0.hasPrefix(".") }),
          FileManager.default.fileExists(atPath: zoneInfoDirectory + identifier, isDirectory: &isDirectory),
          !isDirectory.boolValue
    else {
        throw IcliError.failed("'\(identifier)' is not a time zone in \(zoneInfoDirectory); pass an Olson name such as Asia/Shanghai")
    }
    let automaticChanged = try setAutomaticTimeZone(false)["changed"] as? Bool ?? false
    let linked = systemTimeZoneIdentifier() != identifier
    if linked {
        // A zone that is not applied hands the automatic setting back as it was.
        var applied = false
        defer {
            if !applied, automaticChanged {
                _ = try? setAutomaticTimeZone(true)
            }
        }
        switch icli_time_zone_link(identifier) {
        case 0:
            break
        case -1:
            throw IcliError.unavailable("libutil's tzlink is unavailable on this device.")
        case -2:
            throw IcliError.unavailable("tzlinkd did not answer within 5 seconds.")
        case EPERM:
            throw IcliError.unavailable("tzlinkd refused the change. The process needs the com.apple.tzlink.allow entitlement.")
        case let error:
            throw IcliError.unavailable("tzlinkd could not set \(identifier): \(String(cString: strerror(error))).")
        }
        guard systemTimeZoneIdentifier() == identifier else {
            throw IcliError.unavailable("tzlinkd accepted \(identifier), but \(localTimeLink) did not change.")
        }
        applied = true
    }
    var state = try timeZone()
    state["changed"] = automaticChanged || linked
    return state
}
