import Testing
import Foundation
@testable import QuackKit

@Suite struct SettingsTests {

    @Test func defaults() {
        let s = QuackSettings()
        #expect(s.calendarEnabled)
        #expect(s.remindersEnabled)
        #expect(s.menuBarCountdownEnabled)
        #expect(!s.brightnessEnabled)
        #expect(!s.windowSwipeEnabled)
        #expect(s.reminderLeadMinutes == [10, 5])
        #expect(abs(s.swipeSensitivity - 0.5) < 0.0001)
    }

    @Test func encodeDecodeRoundTrip() throws {
        var s = QuackSettings()
        s.brightnessEnabled = true
        s.reminderLeadMinutes = [20, 10, 5]
        s.selectedCalendarIDs = ["cal-1", "cal-2"]
        s.displayBrightness = ["DELL-1": 0.7]
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(QuackSettings.self, from: data)
        #expect(s == decoded)
    }

    @Test func decodingMissingFieldsFallsBackToDefaults() throws {
        let json = #"{"brightnessEnabled": true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(QuackSettings.self, from: json)
        #expect(decoded.brightnessEnabled)
        #expect(decoded.reminderLeadMinutes == [10, 5])
        #expect(decoded.calendarEnabled)
        #expect(decoded.syncAllCalendars)   // new field defaults true for old blobs
    }

    @Test func persistsAndReloadsFromBacking() {
        let backing = InMemoryKeyValueStore()
        let store = SettingsStore(backing: backing, key: "test")
        store.update { $0.brightnessEnabled = true; $0.swipeSensitivity = 0.9 }

        let reloaded = SettingsStore(backing: backing, key: "test")
        #expect(reloaded.settings.brightnessEnabled)
        #expect(abs(reloaded.settings.swipeSensitivity - 0.9) < 0.0001)
    }

    @Test func updatePublishesOnlyOnRealChange() {
        let store = SettingsStore(backing: InMemoryKeyValueStore(), key: "test")
        var published = 0
        let c = store.$settings.dropFirst().sink { _ in published += 1 }
        store.update { $0.windowSwipeEnabled = true }
        store.update { $0.windowSwipeEnabled = true }   // no-op -> no publish
        store.update { $0.windowSwipeEnabled = false }
        c.cancel()
        #expect(published == 2)
    }

    @Test func notchMediaDefaultsOff() {
        #expect(!QuackSettings().notchMediaEnabled)
    }

    @Test func notchMediaDecodesFromOldBlobAsDefault() throws {
        let json = #"{"brightnessEnabled": true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(QuackSettings.self, from: json)
        #expect(!decoded.notchMediaEnabled)
    }

    @Test func notchMediaFeatureFollowsFlag() {
        var s = QuackSettings()
        s.notchMediaEnabled = true
        #expect(Feature.notch.isEnabled(in: s))
        s.notchMediaEnabled = false
        #expect(!Feature.notch.isEnabled(in: s))
    }

    @Test func notchAgentsDefaultsOff() {
        #expect(!QuackSettings().notchAgentsEnabled)
    }

    @Test func notchAgentsDecodesFromOldBlobAsDefault() throws {
        let json = #"{"brightnessEnabled": true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(QuackSettings.self, from: json)
        #expect(!decoded.notchAgentsEnabled)
    }

    @Test func notchAgentsFeatureFollowsFlag() {
        var s = QuackSettings()
        s.notchMediaEnabled = false
        s.notchAgentsEnabled = true
        #expect(Feature.notch.isEnabled(in: s))
        s.notchAgentsEnabled = false
        #expect(!Feature.notch.isEnabled(in: s))
    }

}

@Suite struct TimeAwarenessSettingsTests {
    @Test func fieldsDefaultWhenMissing() throws {
        let old = #"{"calendarEnabled": true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(QuackSettings.self, from: old)
        #expect(s.timeAwarenessEnabled == false)
        #expect(s.restRemindersEnabled == true)
        #expect(s.activityReminderMinutes == 50)
        #expect(s.activityRepeatMinutes == 10)
        #expect(s.activityIdleResetMinutes == 5)
    }
    @Test func fieldsRoundTrip() throws {
        var s = QuackSettings()
        s.timeAwarenessEnabled = true
        s.restRemindersEnabled = false
        s.activityReminderMinutes = 25
        s.activityRepeatMinutes = 15
        s.activityIdleResetMinutes = 3
        let back = try JSONDecoder().decode(QuackSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
    @Test func featureGatedOnMasterToggle() {
        var s = QuackSettings()
        #expect(Feature.timeAwareness.isEnabled(in: s) == false)
        s.timeAwarenessEnabled = true
        #expect(Feature.timeAwareness.isEnabled(in: s))
        s.restRemindersEnabled = false   // reminders toggle must NOT gate the feature
        #expect(Feature.timeAwareness.isEnabled(in: s))
    }
}
