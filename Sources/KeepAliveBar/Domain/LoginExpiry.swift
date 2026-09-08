import Foundation
import CoreFoundation

// Only the refresh-token deadline represents login renewal. Never substitute access-token expiry.
enum LoginExpiry {
    static let warningInterval: TimeInterval = 3 * 24 * 3600

    static func claudeDeadline(from object: [String: Any]) -> Date? {
        let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
        guard let value = oauth["refreshTokenExpiresAt"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue / 1000)
    }

    static func needsReminder(_ deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        return deadline.timeIntervalSince(now) <= warningInterval
    }
}
