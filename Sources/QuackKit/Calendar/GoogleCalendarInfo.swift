import Foundation

public struct GoogleCalendarInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let colorHex: String?

    public init(id: String, title: String, colorHex: String?) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
    }
}
