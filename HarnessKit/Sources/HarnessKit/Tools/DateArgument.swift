import Foundation

/// Reads the dates and times a model writes as tool arguments.
///
/// Tool descriptions ask for `YYYY-MM-DD` and `YYYY-MM-DD HH:MM`, but small
/// models also write "tomorrow", "friday" or "5pm", so those are accepted too
/// rather than bounced back as errors.
public enum DateArgument {
    /// The start of the day a phrase names: today, tomorrow, yesterday, a weekday
    /// (its next occurrence), or a date as YYYY-MM-DD.
    public static func day(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let today = calendar.startOfDay(for: now)
        switch word {
        case "today", "now", "tonight": return today
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        default: break
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let bare = word.hasPrefix("next ") ? String(word.dropFirst(5)) : word
        if let index = weekdays.firstIndex(where: { $0 == bare || $0.prefix(3) == bare }) {
            let current = calendar.component(.weekday, from: today) - 1
            var ahead = (index - current + 7) % 7
            if ahead == 0 { ahead = 7 }
            return calendar.date(byAdding: .day, value: ahead, to: today)
        }
        let parts = word.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 1900, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// A date and time such as "2026-11-15 17:00", "2026-11-15T17:00:00",
    /// "tomorrow 5pm" or "friday at 9:30". Nil when there is no time of day.
    public static func moment(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cleaned = cleaned.replacingOccurrences(of: " at ", with: " ")
        // Split an ISO "T" between a date and a time.
        if cleaned.count > 10, cleaned.dropFirst(10).first == "t", day(String(cleaned.prefix(10)), now: now, calendar: calendar) != nil {
            cleaned = cleaned.prefix(10) + " " + cleaned.dropFirst(11)
        }
        guard let space = cleaned.firstIndex(of: " ") else {
            // A time alone means today.
            return time(cleaned).flatMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: now) }
        }
        var dayPart = String(cleaned[..<space])
        var timePart = String(cleaned[cleaned.index(after: space)...])
        if dayPart == "next", let second = timePart.firstIndex(of: " ") {
            dayPart += " " + timePart[..<second]
            timePart = String(timePart[timePart.index(after: second)...])
        }
        guard let date = day(dayPart, now: now, calendar: calendar), let clock = time(timePart) else { return nil }
        return calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: date)
    }

    /// A time of day: "17:00", "17:00:00", "5pm", "5:30 pm".
    static func time(_ text: String) -> (hour: Int, minute: Int)? {
        var word = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
        if word.hasSuffix("z") { word.removeLast() }
        var offset = 0
        var isTwelveHour = false
        for (suffix, add) in [("pm", 12), ("am", 0)] where word.hasSuffix(suffix) {
            word = String(word.dropLast(2)).trimmingCharacters(in: .whitespaces)
            offset = add
            isTwelveHour = true
        }
        let parts = word.split(separator: ":").map { Int($0) }
        guard let first = parts.first, var hour = first, parts.count <= 3 else { return nil }
        let minute = parts.count > 1 ? parts[1] : 0
        guard let minute, (0..<60).contains(minute) else { return nil }
        if isTwelveHour {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + offset
        }
        guard (0..<24).contains(hour) else { return nil }
        return (hour, minute)
    }
}
