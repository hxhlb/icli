import Foundation

/// `value` reduced to what `JSONSerialization` accepts: data as Base64, dates
/// as ISO-8601, a NaN or infinite number as its description, dictionary keys
/// as strings and anything else as its description. On Darwin a value outside
/// this set makes `JSONSerialization` raise an Objective-C exception, which
/// Swift cannot catch, so results built from plists and private APIs pass
/// through here before a host serializes them.
public func jsonSafe(_ value: Any) -> Any {
    switch value {
    case let string as String:
        string
    case let number as NSNumber:
        number.doubleValue.isFinite ? number : "\(number.doubleValue)"
    case let data as Data:
        data.base64EncodedString()
    case let date as Date:
        ISO8601DateFormatter().string(from: date)
    case let dictionary as [String: Any]:
        dictionary.mapValues(jsonSafe)
    case let dictionary as NSDictionary:
        Dictionary(dictionary.map { ("\($0.key)", jsonSafe($0.value)) }, uniquingKeysWith: { first, _ in first })
    case let array as [Any]:
        array.map(jsonSafe)
    case is NSNull:
        value
    default:
        "\(value)"
    }
}
