import Foundation
import Testing

@testable import HarnessKit

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// Saturday 14 November 2026, 10:00 UTC.
private let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10))!

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite struct DateArgumentTests {
    @Test func readsDayWords() {
        #expect(DateArgument.day("today", now: now, calendar: utc) == date(2026, 11, 14))
        #expect(DateArgument.day("Tomorrow", now: now, calendar: utc) == date(2026, 11, 15))
        #expect(DateArgument.day("yesterday", now: now, calendar: utc) == date(2026, 11, 13))
        #expect(DateArgument.day("2026-12-01", now: now, calendar: utc) == date(2026, 12, 1))
        #expect(DateArgument.day("soon", now: now, calendar: utc) == nil)
    }

    @Test func weekdayMeansItsNextOccurrence() {
        #expect(DateArgument.day("monday", now: now, calendar: utc) == date(2026, 11, 16))
        #expect(DateArgument.day("fri", now: now, calendar: utc) == date(2026, 11, 20))
        // Today is Saturday, so "saturday" is a week away.
        #expect(DateArgument.day("saturday", now: now, calendar: utc) == date(2026, 11, 21))
        #expect(DateArgument.day("next tuesday", now: now, calendar: utc) == date(2026, 11, 17))
    }

    @Test func readsMoments() {
        #expect(DateArgument.moment("2026-11-15 17:00", now: now, calendar: utc) == date(2026, 11, 15, 17))
        #expect(DateArgument.moment("2026-11-15T09:30:00", now: now, calendar: utc) == date(2026, 11, 15, 9, 30))
        #expect(DateArgument.moment("tomorrow 5pm", now: now, calendar: utc) == date(2026, 11, 15, 17))
        #expect(DateArgument.moment("tomorrow at 5:30 pm", now: now, calendar: utc) == date(2026, 11, 15, 17, 30))
        #expect(DateArgument.moment("friday 12am", now: now, calendar: utc) == date(2026, 11, 20, 0))
        #expect(DateArgument.moment("18:15", now: now, calendar: utc) == date(2026, 11, 14, 18, 15))
        #expect(DateArgument.moment("tomorrow", now: now, calendar: utc) == nil)
        #expect(DateArgument.moment("2026-11-15 25:00", now: now, calendar: utc) == nil)
    }
}

private actor FakeSource: PersonalDataSource {
    var stored: [CalendarEvent] = []
    var reminders: [ReminderItem] = []
    var completed: [String] = []
    var denied = false

    func seed(events: [CalendarEvent] = [], reminders: [ReminderItem] = [], denied: Bool = false) {
        stored = events
        self.reminders = reminders
        self.denied = denied
    }

    private func check() throws {
        if denied { throw PersonalDataError("Calendar access is turned off.") }
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try check()
        return stored.filter { $0.start < end && $0.end > start }
    }

    func addEvent(title: String, start: Date, minutes: Int) async throws {
        try check()
        stored.append(CalendarEvent(title: title, start: start, end: start.addingTimeInterval(Double(minutes) * 60)))
    }

    func openReminders() async throws -> [ReminderItem] {
        try check()
        return reminders.filter { !completed.contains($0.id) }
    }

    func addReminder(title: String, due: Date?) async throws {
        try check()
        reminders.append(ReminderItem(id: "r\(reminders.count + 1)", title: title, due: due))
    }

    func completeReminder(id: String) async throws {
        try check()
        completed.append(id)
    }
}

@Suite struct PersonalToolTests {
    private func listTool(_ source: FakeSource) -> CalendarListTool {
        var tool = CalendarListTool(source: source)
        tool.calendar = utc
        tool.now = { now }
        return tool
    }

    @Test func listsEventsInTimeOrder() async {
        let source = FakeSource()
        await source.seed(events: [
            CalendarEvent(title: "Lunch", start: date(2026, 11, 15, 13), end: date(2026, 11, 15, 14), location: "Cafe Lumen"),
            CalendarEvent(title: "Dentist", start: date(2026, 11, 15, 9, 30), end: date(2026, 11, 15, 10, 15)),
            CalendarEvent(title: "Other day", start: date(2026, 11, 16, 9), end: date(2026, 11, 16, 10)),
        ])
        let result = await listTool(source).call(["day": "tomorrow"])
        #expect(!result.isError)
        #expect(result.text == "Sunday 15 November 2026\n09:30-10:15  Dentist\n13:00-14:00  Lunch  at Cafe Lumen")
    }

    @Test func saysWhenADayIsEmptyAndRejectsBadDays() async {
        let source = FakeSource()
        let tool = listTool(source)
        #expect(await tool.call(["day": "today"]).text == "Saturday 14 November 2026: no events.")
        #expect(await tool.call(["day": "whenever"]).isError)
    }

    @Test func accessDeniedIsAResultTheModelCanRead() async {
        let source = FakeSource()
        await source.seed(denied: true)
        let result = await listTool(source).call(["day": "today"])
        #expect(result.isError)
        #expect(result.text.contains("turned off"))
    }

    @Test func createsAnEvent() async {
        let source = FakeSource()
        var tool = CalendarCreateTool(source: source)
        tool.calendar = utc
        tool.now = { now }
        let result = await tool.call(["title": "Haircut", "start": "tomorrow 3pm", "duration_minutes": 30])
        #expect(result.text == "Added \"Haircut\" on Sunday 15 November 2026 at 15:00 for 30 minutes.")
        #expect(await source.stored.first?.start == date(2026, 11, 15, 15))
        #expect(await tool.call(["title": "Haircut", "start": "later"]).isError)
    }

    @Test func addsRemindersWithAndWithoutATime() async {
        let source = FakeSource()
        var tool = RemindersAddTool(source: source)
        tool.calendar = utc
        tool.now = { now }
        #expect(await tool.call(["title": "Call the plumber", "due": "2026-11-15 17:00"]).text.contains("due 2026-11-15 17:00"))
        #expect(await tool.call(["title": "Buy milk"]).text == "Added the reminder \"Buy milk\".")
        // A day alone is reminded at nine.
        #expect(await tool.call(["title": "Renew passport", "due": "monday"]).text.contains("due 2026-11-16 09:00"))
        #expect(await source.reminders.count == 3)
    }

    @Test func completesAReminderByTitleAndAsksWhenAmbiguous() async {
        let source = FakeSource()
        await source.seed(reminders: [
            ReminderItem(id: "a", title: "Buy oat milk"), ReminderItem(id: "b", title: "Buy stamps"),
            ReminderItem(id: "c", title: "Renew passport"),
        ])
        let tool = RemindersCompleteTool(source: source)
        #expect(await tool.call(["title": "buy"]).isError)
        #expect(await tool.call(["title": "passport"]).text == "Marked \"Renew passport\" as done.")
        #expect(await source.completed == ["c"])
        #expect(await tool.call(["title": "dentist"]).isError)
    }

    @Test func presetsSavedBeforeConnectorsStillLoad() throws {
        let old = """
            {"id":"A0000000-0000-4000-8000-000000000009","name":"Mine","symbol":"star","summary":"","systemPrompt":"Hi",
             "tools":["web_search"],"thinking":"low","maxOutputTokens":2048,"temperature":0.6,"isBuiltIn":false}
            """
        let preset = try JSONDecoder().decode(HarnessPreset.self, from: Data(old.utf8))
        #expect(preset.connectors.isEmpty)
        #expect(preset.tools == [.webSearch])
    }
}
