import Foundation

public struct GoogleCalendarInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let colorHex: String?
    /// True for the user's primary calendar — its `id` is their Google account email.
    public let isPrimary: Bool

    public init(id: String, title: String, colorHex: String?, isPrimary: Bool = false) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.isPrimary = isPrimary
    }
}
