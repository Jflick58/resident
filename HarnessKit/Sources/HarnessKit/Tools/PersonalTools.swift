import Foundation

// Calendar and reminders tools. They talk to a `PersonalDataSource` so the
// logic (argument reading, formatting, matching) is testable without the
// device's calendar; the app supplies an EventKit-backed source.

public struct CalendarEvent: Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var isAllDay: Bool

    public init(title: String, start: Date, end: Date, location: String? = nil, isAllDay: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.isAllDay = isAllDay
    }
}

public struct ReminderItem: Sendable, Hashable {
    public var id: String
    public var title: String
    public var due: Date?

    public init(id: String, title: String, due: Date? = nil) {
        self.id = id
        self.title = title
        self.due = due
    }
}

/// The user's calendar and reminders. Methods throw `PersonalDataError` when
/// the user has not allowed access.
public protocol PersonalDataSource: Sendable {
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
    func addEvent(title: String, start: Date, minutes: Int) async throws
    /// Reminders that are not completed.
    func openReminders() async throws -> [ReminderItem]
    func addReminder(title: String, due: Date?) async throws
    func completeReminder(id: String) async throws
}

public struct PersonalDataError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Groups of tools that reach the user's own data. Presets switch them on by name.
public enum Connector: String, Codable, CaseIterable, Sendable, Identifiable {
    case calendar
    case reminders
    /// A folder of files on this device: `FileTool` and `Workspace`.
    case files

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .files: return "Files"
        }
    }

    public var detail: String {
        switch self {
        case .calendar: return "See your schedule and add events"
        case .reminders: return "See, add and complete reminders"
        case .files: return "Keep, search and edit files in a folder on this device"
        }
    }

    public var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .files: return "folder"
        }
    }

    /// A plain line for the transcript describing a connector tool call, or nil
    /// when the name is not a connector tool.
    public static func activity(forTool name: String, isRunning: Bool) -> String? {
        switch name {
        case "calendar_list": return isRunning ? "Checking the calendar" : "Checked the calendar"
        case "calendar_create": return isRunning ? "Adding an event" : "Added an event"
        case "reminders_list": return isRunning ? "Checking reminders" : "Checked reminders"
        case "reminders_add": return isRunning ? "Adding a reminder" : "Added a reminder"
        case "reminders_complete": return isRunning ? "Completing a reminder" : "Completed a reminder"
        default: return nil
        }
    }

    /// The tools that read and change the user's calendar or reminders. The file tools
    /// work on a folder, not on this source, and are made by `FileTool.group`.
    public func tools(source: any PersonalDataSource) -> [any Tool] {
        switch self {
        case .calendar: return [CalendarListTool(source: source), CalendarCreateTool(source: source)]
        case .reminders:
            return [RemindersListTool(source: source), RemindersAddTool(source: source), RemindersCompleteTool(source: source)]
        case .files: return []
        }
    }
}

enum PersonalFormat {
    static func day(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return formatter.string(from: date)
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func moment(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0) + time(date, calendar: calendar)
    }
}

public struct CalendarListTool: Tool {
    let source: any PersonalDataSource
    var calendar = Calendar.current
    var now: @Sendable () -> Date = { Date() }

    public init(source: any PersonalDataSource) { self.source = source }

    public var spec: ToolSpec {
        ToolSpec(
            name: "calendar_list",
            description:
                "List the user's calendar events for a day. Use this for any question about the user's schedule, meetings, appointments or whether they are free. Returns one line per event with start and end time, title and place, in time order. Call it before adding an event so you know what is already there.",
            parameters: [
                "type": "object",
                "properties": [
                    "day": ["type": "string", "description": "today, tomorrow, a weekday name, or a date as YYYY-MM-DD"],
                    "days": ["type": "integer", "description": "How many days to list starting at `day`, 1 to 14. Default 1."],
                ],
                "required": ["day"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "Checked the calendar" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        let text = arguments["day"]?.stringValue ?? "today"
        guard let first = DateArgument.day(text, now: now(), calendar: calendar) else {
            return .error("Could not read the day \"\(text)\". Use today, tomorrow, a weekday name, or YYYY-MM-DD.")
        }
        let count = min(14, max(1, arguments["days"]?.intValue ?? 1))
        do {
            var sections: [String] = []
            for offset in 0..<count {
                guard let start = calendar.date(byAdding: .day, value: offset, to: first),
                    let end = calendar.date(byAdding: .day, value: 1, to: start)
                else { continue }
                let events = try await source.events(from: start, to: end).sorted { $0.start < $1.start }
                let heading = PersonalFormat.day(start, calendar: calendar)
                if events.isEmpty {
                    sections.append("\(heading): no events.")
                    continue
                }
                let lines = events.map { event -> String in
                    let when = event.isAllDay
                        ? "all day"
                        : "\(PersonalFormat.time(event.start, calendar: calendar))-\(PersonalFormat.time(event.end, calendar: calendar))"
                    let place = (event.location?.isEmpty == false) ? "  at \(event.location!)" : ""
                    return "\(when)  \(event.title)\(place)"
                }
                sections.append(heading + "\n" + lines.joined(separator: "\n"))
            }
            return ToolResult(sections.joined(separator: "\n\n"))
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct CalendarCreateTool: Tool {
    let source: any PersonalDataSource
    var calendar = Calendar.current
    var now: @Sendable () -> Date = { Date() }

    public init(source: any PersonalDataSource) { self.source = source }

    public var spec: ToolSpec {
        ToolSpec(
            name: "calendar_create",
            description:
                "Add an event to the user's calendar. Use when the user asks to schedule, book or add something at a specific time. Work out the date from today's date. Do not use this for to-dos without a fixed time; those are reminders.",
            parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Short title of the event"],
                    "start": ["type": "string", "description": "Start as YYYY-MM-DD HH:MM in 24-hour time"],
                    "duration_minutes": ["type": "integer", "description": "Length in minutes. Default 60."],
                ],
                "required": ["title", "start"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "Added an event" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else { return .error("Give the event a title.") }
        let text = arguments["start"]?.stringValue ?? ""
        guard let start = DateArgument.moment(text, now: now(), calendar: calendar) else {
            return .error("Could not read the start time \"\(text)\". Use YYYY-MM-DD HH:MM, for example 2026-11-15 14:00.")
        }
        let minutes = min(24 * 60, max(5, arguments["duration_minutes"]?.intValue ?? 60))
        do {
            try await source.addEvent(title: title, start: start, minutes: minutes)
            return ToolResult("Added \"\(title)\" on \(PersonalFormat.day(start, calendar: calendar)) at \(PersonalFormat.time(start, calendar: calendar)) for \(minutes) minutes.")
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct RemindersListTool: Tool {
    let source: any PersonalDataSource
    var calendar = Calendar.current

    public init(source: any PersonalDataSource) { self.source = source }

    public var spec: ToolSpec {
        ToolSpec(
            name: "reminders_list",
            description:
                "List the user's open reminders and to-dos. Returns one line per reminder with its title and due time if it has one. Use it to answer what the user still has to do.",
            parameters: ["type": "object", "properties": [:], "required": []])
    }

    public func summary(for arguments: JSONValue) -> String { "Checked reminders" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        do {
            let reminders = try await source.openReminders().sorted {
                ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title)
            }
            if reminders.isEmpty { return ToolResult("There are no open reminders.") }
            let lines = reminders.prefix(40).map { item in
                item.due.map { "\(item.title)  (due \(PersonalFormat.moment($0, calendar: calendar)))" } ?? item.title
            }
            let more = reminders.count > 40 ? "\n…and \(reminders.count - 40) more." : ""
            return ToolResult(lines.joined(separator: "\n") + more)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct RemindersAddTool: Tool {
    let source: any PersonalDataSource
    var calendar = Calendar.current
    var now: @Sendable () -> Date = { Date() }

    public init(source: any PersonalDataSource) { self.source = source }

    public var spec: ToolSpec {
        ToolSpec(
            name: "reminders_add",
            description:
                "Create a reminder for the user. Use whenever the user says remind me, don't let me forget, or asks to add a to-do. Give `due` when the user names a time, working it out from today's date. This is different from saving a memory, which is for lasting facts about the user.",
            parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "What to be reminded of, a short phrase"],
                    "due": ["type": "string", "description": "When to remind, as YYYY-MM-DD HH:MM in 24-hour time"],
                ],
                "required": ["title"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "Added a reminder" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else { return .error("Say what the reminder is for.") }
        var due: Date?
        if let text = arguments["due"]?.stringValue, !text.isEmpty {
            // A day without a time is reminded at 9 in the morning.
            due = DateArgument.moment(text, now: now(), calendar: calendar)
                ?? DateArgument.day(text, now: now(), calendar: calendar).flatMap {
                    calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0)
                }
            if due == nil {
                return .error("Could not read the time \"\(text)\". Use YYYY-MM-DD HH:MM, for example 2026-11-15 17:00.")
            }
        }
        do {
            try await source.addReminder(title: title, due: due)
            return ToolResult("Added the reminder \"\(title)\"" + (due.map { ", due \(PersonalFormat.moment($0, calendar: calendar))." } ?? "."))
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct RemindersCompleteTool: Tool {
    let source: any PersonalDataSource

    public init(source: any PersonalDataSource) { self.source = source }

    public var spec: ToolSpec {
        ToolSpec(
            name: "reminders_complete",
            description:
                "Mark one of the user's reminders as done. Give some words from its title; it must match exactly one open reminder.",
            parameters: [
                "type": "object",
                "properties": ["title": ["type": "string", "description": "Words from the reminder's title"]],
                "required": ["title"],
            ])
    }

    public func summary(for arguments: JSONValue) -> String { "Completed a reminder" }

    public func call(_ arguments: JSONValue) async -> ToolResult {
        let wanted = (arguments["title"]?.stringValue ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return .error("Give some words from the reminder's title.") }
        do {
            let open = try await source.openReminders()
            let exact = open.filter { $0.title.lowercased() == wanted }
            let matches = exact.isEmpty ? open.filter { $0.title.lowercased().contains(wanted) } : exact
            switch matches.count {
            case 0: return .error("No open reminder matches \"\(wanted)\". Call reminders_list to see them.")
            case 1:
                try await source.completeReminder(id: matches[0].id)
                return ToolResult("Marked \"\(matches[0].title)\" as done.")
            default:
                return .error("Several reminders match: \(matches.prefix(6).map { "\"\($0.title)\"" }.joined(separator: ", ")). Give more of the title.")
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
