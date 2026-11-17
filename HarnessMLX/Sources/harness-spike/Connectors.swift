import Foundation
import HarnessKit

// Stand-in connectors for the spike: the kinds of tools a phone assistant would
// have (calendar, reminders, GitHub, mail, health and so on), answering from
// canned data. They exist to measure how a small model copes with a large tool
// set, so what matters is that the names, descriptions and schemas are
// realistic, not that anything real happens.

struct Param: Sendable {
    var name: String
    var type: String
    var description: String
    var required: Bool

    init(_ name: String, _ description: String, type: String = "string", required: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

/// Records which tools actually ran, whichever way the model reached them
/// (a direct tool call or a shell command).
final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(name: String, arguments: String)] = []

    func record(_ name: String, _ arguments: JSONValue) {
        lock.lock()
        calls.append((name, arguments.jsonString))
        lock.unlock()
    }

    func take() -> [(name: String, arguments: String)] {
        lock.lock()
        defer { calls = []; lock.unlock() }
        return calls
    }
}

struct ConnectorTool: Tool {
    var group: String
    var action: String
    /// One sentence: what the tool does.
    var brief: String
    /// The rest of a full description: when to use it, formats, what comes back.
    var more: String
    var params: [Param]
    var handler: @Sendable ([String: JSONValue]) async -> ToolResult
    var useBrief = false
    var recorder: CallRecorder?

    var name: String { action.isEmpty ? group : "\(group)_\(action)" }
    var detail: String { more.isEmpty ? brief : brief + " " + more }

    var spec: ToolSpec {
        var properties: [String: JSONValue] = [:]
        for param in params {
            properties[param.name] = ["type": .string(param.type), "description": .string(param.description)]
        }
        return ToolSpec(
            name: name, description: useBrief ? brief : detail,
            parameters: [
                "type": "object", "properties": .object(properties),
                "required": .array(params.filter(\.required).map { .string($0.name) }),
            ])
    }

    func call(_ arguments: JSONValue) async -> ToolResult {
        recorder?.record(name, arguments)
        let values = arguments.objectValue ?? [:]
        for param in params where param.required && values[param.name] == nil {
            return .error("Missing required argument: \(param.name).")
        }
        return await handler(values)
    }
}

/// One line per connector, for prompts that list connectors instead of tools.
let connectorSummaries: [(group: String, summary: String)] = [
    ("calendar", "the user's calendar: see, add and remove events, find free time"),
    ("reminders", "the user's reminders and to-dos"),
    ("contacts", "the user's address book: phone numbers, emails"),
    ("notes", "the user's notes: search, read, write"),
    ("github", "GitHub repositories: issues, pull requests, code"),
    ("mail", "the user's email: unread, search, read, draft"),
    ("health", "the user's health data: steps, sleep, heart rate, workouts"),
    ("weather", "current weather and forecasts for a place"),
    ("maps", "places, directions and travel times"),
    ("files", "files stored on the device"),
    ("music", "music playback"),
    ("timer", "timers and alarms"),
    ("home", "smart home: lights and thermostat"),
]

private func text(_ values: [String: JSONValue], _ key: String) -> String {
    if let string = values[key]?.stringValue { return string }
    if let int = values[key]?.intValue { return String(int) }
    return ""
}

private func tool(
    _ group: String, _ action: String, _ brief: String, _ more: String, _ params: [Param],
    _ handler: @escaping @Sendable ([String: JSONValue]) -> ToolResult
) -> ConnectorTool {
    ConnectorTool(group: group, action: action, brief: brief, more: more, params: params, handler: handler)
}

/// "today", "tomorrow" or "yesterday" for a date written out that is one of them, so a
/// model that works the date out itself gets the same answer as one that says the word.
private func dayWord(_ value: String) -> String {
    let lowered = value.lowercased().trimmingCharacters(in: .whitespaces)
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd"
    for (offset, word) in [(0, "today"), (1, "tomorrow"), (-1, "yesterday")] {
        if let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()), lowered.hasPrefix(format.string(from: date)) {
            return word
        }
    }
    return lowered
}

private let dayParam = Param("day", "today, tomorrow, yesterday, or a date as YYYY-MM-DD")

let connectorTools: [ConnectorTool] = [
    // MARK: Calendar
    tool(
        "calendar", "list", "List the user's calendar events for one day.",
        "Use this for any question about the user's schedule, meetings or appointments. Returns one line per event with its id, start and end time, title and location, in time order. Call it before creating or deleting events so you know what is already there.",
        [dayParam]
    ) { values in
        switch dayWord(text(values, "day")) {
        case "tomorrow":
            return ToolResult(
                """
                evt_201  09:30-10:15  Dentist (Dr. Okafor)  at 12 Mill Lane
                evt_202  13:00-14:00  Lunch with Priya  at Cafe Lumen
                evt_203  18:30-20:00  Choir rehearsal  at St Mark's Hall
                """)
        case "today": return ToolResult("evt_190  16:00-16:30  Call with accountant")
        default: return ToolResult("No events.")
        }
    },
    tool(
        "calendar", "create", "Add an event to the user's calendar.",
        "Use when the user asks to schedule, book or add something at a specific time. `start` is a date and 24-hour time such as 2026-11-15 14:00. Returns the new event's id. Do not use this for to-dos without a fixed time; those are reminders.",
        [
            Param("title", "Short title of the event"), Param("start", "Start as YYYY-MM-DD HH:MM, 24-hour"),
            Param("duration_minutes", "Length in minutes, default 60", type: "integer", required: false),
        ]
    ) { values in ToolResult("Created evt_310: \(text(values, "title")) at \(text(values, "start")).") },
    tool(
        "calendar", "delete", "Remove an event from the user's calendar.",
        "Needs the event id from calendar_list. Only call this when the user clearly asked to cancel or delete that event.",
        [Param("event_id", "Event id such as evt_201")]
    ) { values in ToolResult("Deleted \(text(values, "event_id")).") },
    tool(
        "calendar", "find_free", "Find free time slots in the user's calendar on a day.",
        "Use when the user asks when they are free or wants to fit something in. Returns the gaps between events that are at least the requested length.",
        [dayParam, Param("duration_minutes", "Shortest slot to return, in minutes", type: "integer", required: false)]
    ) { _ in ToolResult("Free: 08:00-09:30, 10:15-13:00, 14:00-18:30") },

    // MARK: Reminders
    tool(
        "reminders", "list", "List the user's open reminders.",
        "Returns one line per reminder with its id, title and due time if it has one. Use it to answer what the user still has to do, or to find an id before completing or deleting a reminder.",
        [Param("list_name", "Name of a reminder list; omit for all lists", required: false)]
    ) { _ in
        ToolResult(
            """
            rem_11  Renew passport  due 2026-11-20
            rem_12  Buy oat milk
            rem_13  Email landlord about boiler  due 2026-11-15 10:00
            """)
    },
    tool(
        "reminders", "add", "Create a reminder for the user.",
        "Use whenever the user says remind me, don't let me forget, or asks to add a to-do. `due` is optional: give it as YYYY-MM-DD HH:MM in 24-hour time when the user names a time, working it out from today's date. Returns the new reminder's id. This is different from saving a memory, which is for lasting facts about the user.",
        [
            Param("title", "What to be reminded of, a short phrase"),
            Param("due", "When to remind, as YYYY-MM-DD HH:MM, 24-hour", required: false),
        ]
    ) { values in
        let due = text(values, "due")
        return ToolResult("Created rem_20: \(text(values, "title"))\(due.isEmpty ? "" : " due \(due)").")
    },
    tool(
        "reminders", "complete", "Mark a reminder as done.",
        "Needs the reminder id from reminders_list.", [Param("reminder_id", "Reminder id such as rem_11")]
    ) { values in ToolResult("Completed \(text(values, "reminder_id")).") },
    tool(
        "reminders", "delete", "Delete a reminder without completing it.",
        "Needs the reminder id from reminders_list. Use only when the user asks to remove it.",
        [Param("reminder_id", "Reminder id such as rem_11")]
    ) { values in ToolResult("Deleted \(text(values, "reminder_id")).") },

    // MARK: Contacts
    tool(
        "contacts", "search", "Search the user's contacts by name.",
        "Use for questions about someone's phone number, email or address. Matches part of a first or last name. Returns matching contacts with id, name, phone and email.",
        [Param("query", "Part of the person's name")]
    ) { values in
        let query = text(values, "query").lowercased()
        if query.contains("maria") || query.contains("lopez") {
            return ToolResult("con_7  Maria Lopez  phone 555-0142  email maria.lopez@example.com")
        }
        if query.contains("priya") { return ToolResult("con_9  Priya Raman  phone 555-0177  email priya@example.com") }
        return ToolResult("No contacts match.")
    },
    tool(
        "contacts", "get", "Get every detail stored for one contact.",
        "Needs the contact id from contacts_search. Returns address, birthday and notes as well as phone and email.",
        [Param("contact_id", "Contact id such as con_7")]
    ) { values in
        text(values, "contact_id").contains("9")
            ? ToolResult("Priya Raman, 555-0177, priya@example.com, 18 Orchard Way, birthday 22 July")
            : ToolResult("Maria Lopez, 555-0142, maria.lopez@example.com, 4 Harbour Road, birthday 3 March")
    },
    tool(
        "contacts", "add", "Add a new person to the user's contacts.",
        "Use only when the user asks to save a contact. Returns the new contact's id.",
        [
            Param("name", "Full name"), Param("phone", "Phone number", required: false),
            Param("email", "Email address", required: false),
        ]
    ) { values in ToolResult("Added con_30: \(text(values, "name")).") },

    // MARK: Notes
    tool(
        "notes", "search", "Search the user's notes by keyword.",
        "Returns matching notes with id, title and the first few words only. To see what a note says, follow up with notes_read using its id.",
        [Param("query", "One or two keywords")]
    ) { values in
        let query = text(values, "query").lowercased()
        if query.contains("wifi") || query.contains("wi-fi") || query.contains("password") {
            return ToolResult("note_4  Home wifi  \"Router is in the hallway cupboard…\"")
        }
        if query.contains("recipe") { return ToolResult("note_8  Dal recipe  \"Rinse the lentils…\"") }
        return ToolResult("No notes match.")
    },
    tool(
        "notes", "read", "Read the full text of one note.",
        "Needs the note id from notes_search.", [Param("note_id", "Note id such as note_4")]
    ) { values in
        text(values, "note_id") == "note_4"
            ? ToolResult("Home wifi\nRouter is in the hallway cupboard. Network: Lopez-5G. Password: tangerine-42. Guest network is off.")
            : ToolResult("Rinse the lentils, simmer 25 minutes with turmeric.")
    },
    tool(
        "notes", "create", "Create a new note.",
        "Use when the user asks to write something down or start a note. Returns the new note's id.",
        [Param("title", "Title of the note"), Param("body", "Text of the note")]
    ) { values in ToolResult("Created note_40: \(text(values, "title")).") },
    tool(
        "notes", "append", "Add text to the end of an existing note.",
        "Needs the note id from notes_search.", [Param("note_id", "Note id"), Param("text", "Text to add")]
    ) { values in ToolResult("Appended to \(text(values, "note_id")).") },

    // MARK: GitHub
    tool(
        "github", "issues", "List issues in a GitHub repository.",
        "Returns one line per issue with number, state, date opened and title, oldest first. `repo` is owner/name. Use for questions about bugs, open issues or what is being worked on. Follow up with github_issue to read one.",
        [
            Param("repo", "Repository as owner/name, e.g. acme/rocket"),
            Param("state", "open, closed or all; default open", required: false),
        ]
    ) { _ in
        ToolResult(
            """
            #12  open  2026-08-02  Fuel gauge reads negative after refuelling
            #31  open  2026-10-19  Telemetry export drops the last row
            #40  open  2026-11-09  Docs: launch checklist is out of date
            3 open issues.
            """)
    },
    tool(
        "github", "issue", "Read one GitHub issue with its comments.",
        "Needs the repository and the issue number from github_issues.",
        [Param("repo", "Repository as owner/name"), Param("number", "Issue number", type: "integer")]
    ) { values in
        switch text(values, "number") {
        case "31": return ToolResult("#31 Telemetry export drops the last row. 1 comment. Latest: \"Off-by-one in the writer loop.\"")
        case "40": return ToolResult("#40 Docs: launch checklist is out of date. No comments.")
        default: return ToolResult("#12 Fuel gauge reads negative after refuelling. 2 comments. Latest: \"Reproduced on v2.3.\"")
        }
    },
    tool(
        "github", "comment", "Post a comment on a GitHub issue or pull request.",
        "This is visible to everyone with access to the repository, so only call it when the user asked for a comment to be posted.",
        [
            Param("repo", "Repository as owner/name"), Param("number", "Issue or pull request number", type: "integer"),
            Param("body", "Comment text in Markdown"),
        ]
    ) { _ in ToolResult("Comment posted.") },
    tool(
        "github", "create_issue", "Open a new issue in a GitHub repository.",
        "Only when the user asks to file or open an issue. Returns the new issue number.",
        [
            Param("repo", "Repository as owner/name"), Param("title", "Issue title"),
            Param("body", "Issue description in Markdown", required: false),
        ]
    ) { _ in ToolResult("Opened #41.") },
    tool(
        "github", "pulls", "List open pull requests in a GitHub repository.",
        "Returns number, author, title and review status for each.", [Param("repo", "Repository as owner/name")]
    ) { _ in ToolResult("#38  dana  Fix telemetry export  (approved)\n#39  li  Bump dependencies  (review needed)") },
    tool(
        "github", "search_code", "Search code on GitHub.",
        "Returns matching file paths with the matching line. Give `repo` to search one repository only.",
        [Param("query", "Text or symbol to find"), Param("repo", "Repository as owner/name", required: false)]
    ) { _ in ToolResult("src/gauge.py:42  def read_fuel_level(sensor):") },
    tool(
        "github", "read_file", "Read a file from a GitHub repository.",
        "Returns the file's text from the default branch.",
        [Param("repo", "Repository as owner/name"), Param("path", "Path of the file in the repository")]
    ) { _ in ToolResult("def read_fuel_level(sensor):\n    return sensor.raw - OFFSET") },

    // MARK: Mail
    tool(
        "mail", "unread", "List the user's unread email.",
        "Returns one line per message with id, sender, date and subject, newest first. It does not include the message text: follow up with mail_read to see what a message says.",
        []
    ) { _ in
        ToolResult(
            """
            msg_88  Tom Becker (landlord) <tom@beckerlets.example>  14 Nov  Boiler visit
            msg_87  Cafe Lumen <hello@lumen.example>  13 Nov  Your booking is confirmed
            """)
    },
    tool(
        "mail", "search", "Search the user's email.",
        "Matches sender, subject and body. Returns id, sender, date and subject for each match, not the message text: follow up with mail_read.",
        [Param("query", "Sender name or keywords")]
    ) { values in
        let query = text(values, "query").lowercased()
        return query.contains("landlord") || query.contains("tom") || query.contains("boiler") || query.contains("becker")
            ? ToolResult("msg_88  Tom Becker (landlord) <tom@beckerlets.example>  14 Nov  Boiler visit  (unread)")
            : ToolResult("No messages match.")
    },
    tool(
        "mail", "read", "Read the full text of one email.",
        "Needs the message id from mail_unread or mail_search.", [Param("message_id", "Message id such as msg_88")]
    ) { values in
        text(values, "message_id") == "msg_88"
            ? ToolResult("From: Tom Becker\nSubject: Boiler visit\nHi, the engineer will come to service the boiler on Tuesday between 8 and 10am. Please make sure someone is in. Tom")
            : ToolResult("Your table for two at 13:00 on 15 November is confirmed.")
    },
    tool(
        "mail", "draft", "Write an email draft for the user to review and send.",
        "Nothing is sent: the draft is saved for the user. Use when the user asks to write, reply to or send an email.",
        [Param("to", "Recipient email address"), Param("subject", "Subject line"), Param("body", "Message text")]
    ) { _ in ToolResult("Draft saved.") },

    // MARK: Health
    tool(
        "health", "steps", "Get the user's step count for a day.",
        "Returns the number of steps and the distance walked.", [dayParam]
    ) { values in
        dayWord(text(values, "day")) == "yesterday" ? ToolResult("8412 steps, 6.1 km") : ToolResult("2310 steps so far, 1.7 km")
    },
    tool(
        "health", "sleep", "Get how long the user slept on a night.",
        "Returns time asleep and time in bed for the night ending on that day.", [dayParam]
    ) { _ in ToolResult("Asleep 6 h 48 min, in bed 7 h 30 min") },
    tool(
        "health", "heart_rate", "Get the user's heart rate for a day.",
        "Returns resting, average and peak heart rate in beats per minute.", [dayParam]
    ) { _ in ToolResult("Resting 58, average 71, peak 142") },
    tool(
        "health", "workouts", "List the user's recent workouts.",
        "Returns type, date, duration and energy burned for each workout in the last few days.",
        [Param("days", "How many days back to look, default 7", type: "integer", required: false)]
    ) { _ in ToolResult("Run  12 Nov  32 min  310 kcal\nYoga  10 Nov  45 min  140 kcal") },

    // MARK: Weather
    tool(
        "weather", "current", "Get the current weather for a place.",
        "Returns temperature in Celsius, conditions, wind and chance of rain right now. Use this instead of a web search for weather questions.",
        [Param("city", "City name, e.g. Lisbon")]
    ) { values in ToolResult("\(text(values, "city")): 19°C, partly cloudy, wind 14 km/h, 10% chance of rain") },
    tool(
        "weather", "forecast", "Get the weather forecast for the coming days.",
        "Returns one line per day with high, low and conditions.",
        [Param("city", "City name"), Param("days", "Number of days, 1 to 7", type: "integer", required: false)]
    ) { _ in ToolResult("Sun  high 20°C  low 13°C  sunny\nMon  high 18°C  low 12°C  showers\nTue  high 17°C  low 11°C  rain") },

    // MARK: Maps
    tool(
        "maps", "search", "Find places such as shops, restaurants or addresses.",
        "Returns name, address, distance and opening hours for the closest matches.",
        [Param("query", "What to look for, e.g. pharmacy"), Param("near", "Area or address to search around", required: false)]
    ) { _ in ToolResult("Greenway Pharmacy, 3 Station Road, 400 m, open until 20:00") },
    tool(
        "maps", "directions", "Get step-by-step directions between two places.",
        "`from` and `to` can be addresses, place names, or the words home and work. Returns the route as numbered steps with the total distance.",
        [
            Param("from", "Starting point"), Param("to", "Destination"),
            Param("mode", "driving, walking, cycling or transit; default driving", required: false),
        ]
    ) { _ in ToolResult("1. Head north on Mill Lane. 2. Join the A40. 3. Take exit 4 to the airport. 31 km.") },
    tool(
        "maps", "travel_time", "Get the current travel time between two places.",
        "Uses live traffic. `from` and `to` can be addresses, place names, or the words home and work. Returns minutes and distance. Use this for how long will it take questions.",
        [
            Param("from", "Starting point"), Param("to", "Destination"),
            Param("mode", "driving, walking, cycling or transit; default driving", required: false),
        ]
    ) { _ in ToolResult("42 minutes, 31 km, moderate traffic") },

    // MARK: Files
    tool(
        "files", "list", "List files in a folder on the device.", "Returns names, sizes and dates.",
        [Param("path", "Folder path; omit for the top level", required: false)]
    ) { _ in ToolResult("Documents/  Downloads/  taxes-2025.pdf  packing-list.txt") },
    tool(
        "files", "read", "Read a text file stored on the device.", "Returns the file's text. PDFs are converted to text.",
        [Param("path", "Path of the file")]
    ) { _ in ToolResult("Passport, charger, adapter, sunscreen") },
    tool(
        "files", "search", "Search files on the device by name or content.", "Returns matching paths.",
        [Param("query", "Words to look for")]
    ) { _ in ToolResult("packing-list.txt") },

    // MARK: Music
    tool(
        "music", "play", "Play music.", "Starts playing the best match for a song, album, artist or playlist.",
        [Param("query", "Song, album, artist or playlist")]
    ) { values in ToolResult("Playing \(text(values, "query")).") },
    tool("music", "pause", "Pause the music.", "", []) { _ in ToolResult("Paused.") },
    tool("music", "now_playing", "Say what is playing now.", "Returns the song, artist and album.", []) { _ in
        ToolResult("Nothing is playing.")
    },

    // MARK: Timer
    tool(
        "timer", "start", "Start a countdown timer.", "Use for requests like set a timer for ten minutes.",
        [Param("minutes", "Length in minutes", type: "integer"), Param("label", "What the timer is for", required: false)]
    ) { values in ToolResult("Timer started: \(text(values, "minutes")) minutes.") },
    tool(
        "timer", "alarm", "Set an alarm for a time of day.", "`time` is 24-hour HH:MM.",
        [Param("time", "Time as HH:MM, 24-hour"), Param("label", "What the alarm is for", required: false)]
    ) { values in ToolResult("Alarm set for \(text(values, "time")).") },
    tool("timer", "list", "List running timers and alarms.", "", []) { _ in ToolResult("No timers running.") },

    // MARK: Home
    tool(
        "home", "lights", "Turn the lights in a room on or off.", "",
        [Param("room", "Room name"), Param("on", "true for on, false for off", type: "boolean")]
    ) { _ in ToolResult("Done.") },
    tool(
        "home", "thermostat", "Set the home thermostat.", "Temperature in Celsius.",
        [Param("temperature", "Target temperature in Celsius", type: "integer")]
    ) { _ in ToolResult("Thermostat set.") },
]

/// Wraps a real tool so the recorder sees its calls too.
struct RecordedTool: Tool {
    var base: any Tool
    var recorder: CallRecorder

    var spec: ToolSpec { base.spec }
    func summary(for arguments: JSONValue) -> String { base.summary(for: arguments) }
    func call(_ arguments: JSONValue) async -> ToolResult {
        recorder.record(base.spec.name, arguments)
        return await base.call(arguments)
    }
}
