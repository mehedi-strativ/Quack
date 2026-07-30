import Foundation
import QuackKit

// MARK: - API response models (internal)

private struct GoogleCalendarListResponse: Decodable {
    let items: [GoogleCalendarItem]?
}

private struct GoogleCalendarItem: Decodable {
    let id: String
    let summary: String
    let backgroundColor: String?
    let primary: Bool?
    let accessRole: String?
}

private struct GoogleEventListResponse: Decodable {
    let items: [GoogleEventItem]?
    let nextPageToken: String?
}

private struct GoogleEventItem: Decodable {
    let id: String
    let summary: String?
    let start: GoogleEventDateTime
    let end: GoogleEventDateTime
    let location: String?
    let description: String?
    let hangoutLink: String?
    let conferenceData: GoogleConferenceData?
    let transparency: String?
    let status: String?
}

private struct GoogleEventDateTime: Decodable {
    let dateTime: String?
    let date: String?
}

private struct GoogleConferenceData: Decodable {
    let entryPoints: [GoogleEntryPoint]?
}

private struct GoogleEntryPoint: Decodable {
    let entryPointType: String?
    let uri: String?
}

// MARK: - Provider

/// Fetches calendar events from the Google Calendar API v3 using OAuth tokens
/// managed by `GoogleOAuthService`.
final class GoogleCalendarProvider: CalendarProvider, @unchecked Sendable {
    private let oauth: GoogleOAuthService
    private let enabled: () -> Bool
    private let calendarIDs: () -> [String]

    init(oauth: GoogleOAuthService, enabled: @escaping () -> Bool, calendarIDs: @escaping () -> [String]) {
        self.oauth = oauth
        self.enabled = enabled
        self.calendarIDs = calendarIDs
    }

    func requestAccess() async -> Bool {
        await oauth.isAuthenticated
    }

    func fetchEvents(window: DateInterval) async throws -> [MeetingEvent] {
        guard enabled() else { return [] }
        guard let token = try await oauth.validAccessToken() else { return [] }

        let calendars = try await fetchCalendarList(token: token)
        let ids = calendarIDs()
        let selected = ids.isEmpty ? calendars : calendars.filter { ids.contains($0.id) }

        let colorMap = Dictionary(uniqueKeysWithValues: calendars.map { ($0.id, $0.colorHex) })

        var allEvents: [MeetingEvent] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for cal in selected {
            let calEvents = try await fetchEventsForCalendar(
                calendarID: cal.id,
                token: token,
                window: window,
                isoFormatter: isoFormatter,
                colorMap: colorMap
            )
            allEvents.append(contentsOf: calEvents)
        }

        return allEvents
    }

    func availableCalendars() async -> [GoogleCalendarInfo] {
        guard let token = try? await oauth.validAccessToken() else { return [] }
        return (try? await fetchCalendarList(token: token)) ?? []
    }

    // MARK: - API calls

    private func fetchCalendarList(token: String) async throws -> [GoogleCalendarInfo] {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }

        let decoded = try JSONDecoder().decode(GoogleCalendarListResponse.self, from: data)
        return decoded.items?.map {
            GoogleCalendarInfo(id: $0.id, title: $0.summary, colorHex: $0.backgroundColor)
        } ?? []
    }

    private func fetchEventsForCalendar(
        calendarID: String,
        token: String,
        window: DateInterval,
        isoFormatter: ISO8601DateFormatter,
        colorMap: [String: String?]
    ) async throws -> [MeetingEvent] {
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        dateOnlyFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")

        let baseURL = URL(string: "https://www.googleapis.com")!
            .appendingPathComponent("calendar")
            .appendingPathComponent("v3")
            .appendingPathComponent("calendars")
            .appendingPathComponent(calendarID)
            .appendingPathComponent("events")
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "timeMin", value: isoFormatter.string(from: window.start)),
            URLQueryItem(name: "timeMax", value: isoFormatter.string(from: window.end)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
        ]

        var allItems: [GoogleEventItem] = []
        var pageToken: String?

        repeat {
            if let pt = pageToken {
                comps.queryItems?.append(URLQueryItem(name: "pageToken", value: pt))
            }

            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { continue }

            if http.statusCode == 401 {
                _ = try? await oauth.validAccessToken()
                return []
            }
            guard http.statusCode == 200 else { continue }

            let decoded = try JSONDecoder().decode(GoogleEventListResponse.self, from: data)
            if let items = decoded.items {
                allItems.append(contentsOf: items)
            }
            pageToken = decoded.nextPageToken
            if pageToken != nil {
                comps.queryItems?.removeLast()
            }
        } while pageToken != nil

        let colorHex = colorMap[calendarID] ?? nil
        return allItems.compactMap { mapEvent($0, calendarID: calendarID, calendarColorHex: colorHex, isoFormatter: isoFormatter, dateOnlyFormatter: dateOnlyFormatter) }
    }

    private func mapEvent(
        _ event: GoogleEventItem,
        calendarID: String,
        calendarColorHex: String?,
        isoFormatter: ISO8601DateFormatter,
        dateOnlyFormatter: DateFormatter
    ) -> MeetingEvent? {
        guard event.status != "cancelled" else { return nil }

        let startDate = parseDate(event.start, isoFormatter: isoFormatter, dateOnlyFormatter: dateOnlyFormatter)
        let endDate = parseDate(event.end, isoFormatter: isoFormatter, dateOnlyFormatter: dateOnlyFormatter)
        guard let start = startDate, let end = endDate else { return nil }

        let isAllDay = event.start.dateTime == nil && event.start.date != nil
        let joinURL: URL?
        if let hangout = event.hangoutLink {
            joinURL = URL(string: hangout)
        } else if let videoURI = event.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri {
            joinURL = URL(string: videoURI)
        } else {
            joinURL = nil
        }

        return MeetingEvent(
            id: "google-\(calendarID)-\(event.id)",
            title: event.summary ?? "(No title)",
            start: start,
            end: end,
            location: event.location,
            notes: event.description,
            conferencingURL: joinURL,
            calendarID: calendarID,
            isAllDay: isAllDay,
            calendarColorHex: calendarColorHex
        )
    }

    private func parseDate(_ dt: GoogleEventDateTime, isoFormatter: ISO8601DateFormatter, dateOnlyFormatter: DateFormatter) -> Date? {
        if let dateTime = dt.dateTime {
            return isoFormatter.date(from: dateTime)
        }
        if let date = dt.date {
            return dateOnlyFormatter.date(from: date)
        }
        return nil
    }
}
