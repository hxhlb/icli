import Foundation
import IcliPrivate
import IcliSystem

/// notify(3) status codes other than success, as notifyd reports them.
private func notifyError(_ status: UInt32, _ name: String) -> IcliError {
    switch status {
    case 1:
        .failed("notifyd rejected the notification name '\(name)'")
    case 7:
        .unavailable("notifyd did not allow this process to post or change '\(name)'; it may be reserved for root")
    case 9:
        .unavailable("notifyd is not reachable")
    default:
        .unavailable("notifyd failed with status \(status) for '\(name)'")
    }
}

private func validNotificationName(_ name: String) throws -> String {
    guard !name.isEmpty, !name.contains("\0") else {
        throw IcliError.failed("pass a notification name, such as com.apple.springboard.lockcomplete")
    }
    return name
}

/// Posts a Darwin notification, the way notifyutil -p does. With a state, it
/// first stores that value, the way notifyutil -s does, so observers that call
/// notify_get_state read it. notifyd drops the state once no process is
/// registered for the name, so it outlives this call only on a name something
/// else observes. `delivered` is whether notifyd delivered the post to a
/// listener of this process within a second.
public func postDarwinNotification(_ name: String, state: UInt64? = nil) throws -> [String: Any] {
    let name = try validNotificationName(name)
    var delivered = false
    let status = icli_notify_post(name, state != nil, state ?? 0, &delivered)
    guard status == 0 else {
        throw notifyError(status, name)
    }
    var result: [String: Any] = ["name": name, "posted": true, "delivered": delivered]
    if let state {
        result["state"] = state
    }
    return result
}

/// A Darwin notification's current state value, 0 when nothing set one.
public func darwinNotificationState(_ name: String) throws -> [String: Any] {
    let name = try validNotificationName(name)
    var state: UInt64 = 0
    let status = icli_notify_get_state(name, &state)
    guard status == 0 else {
        throw notifyError(status, name)
    }
    return ["name": name, "state": state]
}
