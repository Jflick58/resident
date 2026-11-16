import EventKit
import Foundation
import HarnessKit

/// The device's calendar and reminders, for the Calendar and Reminders connectors.
///
/// Access is asked for the first time a tool needs it, so the permission prompt
/// appears in answer to something the user asked, not at launch.
final class EventKitSource: PersonalDataSource, @unchecked Sendable {
    static let shared = EventKitSource()

    private let store = EKEventStore()

    private func requireEvents() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return }
        do {
            if try await store.requestFullAccessToEvents() { return }
        } catch {
            throw PersonalDataError("Calendar access failed: \(error.localizedDescription)")
        }
        throw PersonalDataError(
            "Calendar access is turned off for this app (status \(EKEventStore.authorizationStatus(for: .event).rawValue)). Tell the user they can turn it on in Settings > Privacy & Security > Calendars.")
    }

    private func requireReminders() async throws {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return }
        do {
            if try await store.requestFullAccessToReminders() { return }
        } catch {
            throw PersonalDataError("Reminders access failed: \(error.localizedDescription)")
        }
        throw PersonalDataError(
            "Reminders access is turned off for this app (status \(EKEventStore.authorizationStatus(for: .reminder).rawValue)). Tell the user they can turn it on in Settings > Privacy & Security > Reminders.")
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try await requireEvents()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                title: event.title ?? "Untitled", start: event.startDate, end: event.endDate,
                location: event.location, isAllDay: event.isAllDay)
        }
    }

    func addEvent(title: String, start: Date, minutes: Int) async throws {
        try await requireEvents()
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw PersonalDataError("There is no calendar to add events to on this device.")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(Double(minutes) * 60)
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
    }

    func openReminders() async throws -> [ReminderItem] {
        try await requireReminders()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? []).map { reminder in
                    ReminderItem(
                        id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled",
                        due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
                }
                continuation.resume(returning: items)
            }
        }
    }

    func addReminder(title: String, due: Date?) async throws {
        try await requireReminders()
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw PersonalDataError("There is no reminders list to add to on this device.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            // The alarm is what makes the phone notify at the due time.
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
    }

    func completeReminder(id: String) async throws {
        try await requireReminders()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw PersonalDataError("That reminder no longer exists.")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }
}
