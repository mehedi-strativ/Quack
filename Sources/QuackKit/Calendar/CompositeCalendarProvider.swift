import Foundation

/// Wraps multiple `CalendarProvider` instances and aggregates their events.
/// Each provider is fetched concurrently; results are merged into a single list.
public final class CompositeCalendarProvider: CalendarProvider {
    private let providers: [CalendarProvider]

    public init(providers: [CalendarProvider]) {
        self.providers = providers
    }

    public func requestAccess() async -> Bool {
        var allGranted = true
        for provider in providers {
            if !(await provider.requestAccess()) { allGranted = false }
        }
        return allGranted
    }

    public func fetchEvents(window: DateInterval) async throws -> [MeetingEvent] {
        try await withThrowingTaskGroup(of: [MeetingEvent].self) { group in
            for provider in providers {
                group.addTask { try await provider.fetchEvents(window: window) }
            }
            return try await group.reduce([], +)
        }
    }
}
