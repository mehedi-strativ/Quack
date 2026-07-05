import Foundation
import Testing
@testable import QuackKit

@Suite struct MouseButtonActionTests {
    @Test func rawValueRoundTrip() {
        for action in MouseButtonAction.allCases {
            #expect(MouseButtonAction.from(action.rawValue) == action)
        }
    }
    @Test func unknownRawFallsBackToDefault() {
        #expect(MouseButtonAction.from("garbage") == .default_)
        #expect(MouseButtonAction.from("") == .default_)
    }
    @Test func stableRawValues() {
        // Persisted in settings JSON — must never change.
        #expect(MouseButtonAction.default_.rawValue == "default")
        #expect(MouseButtonAction.disabled.rawValue == "none")
        #expect(MouseButtonAction.customShortcut.rawValue == "customShortcut")
    }
    @Test func titlesNonEmpty() {
        for action in MouseButtonAction.allCases { #expect(!action.title.isEmpty) }
    }
}

@Suite struct MouseShortcutTests {
    @Test func codableRoundTrip() throws {
        let s = MouseShortcut(keyCode: 40, modifiers: 0b1001)   // ⌘⇧K
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(MouseShortcut.self, from: data) == s)
    }
    @Test func displayShowsModifiersAndKey() {
        // Canonical macOS modifier order: ⌃⌥⇧⌘.
        #expect(MouseShortcut(keyCode: 40, modifiers: 0b1001).display == "⇧⌘K")
        #expect(MouseShortcut(keyCode: 126, modifiers: 0b0100).display == "⌃↑")
    }
    @Test func displayFallsBackForUnknownKey() {
        #expect(MouseShortcut(keyCode: 999, modifiers: 0b0001).display == "⌘key999")
    }
}

@Suite struct MouseFeatureTests {
    @Test func disabledByDefault() {
        #expect(Feature.mouse.isEnabled(in: QuackSettings()) == false)
    }
    @Test func anySubFeatureEnables() {
        var s = QuackSettings(); s.mouseSensitivityEnabled = true
        #expect(Feature.mouse.isEnabled(in: s))
        s = QuackSettings(); s.smoothScrollEnabled = true
        #expect(Feature.mouse.isEnabled(in: s))
        s = QuackSettings(); s.mouseButton4Action = MouseButtonAction.missionControl.rawValue
        #expect(Feature.mouse.isEnabled(in: s))
        s = QuackSettings(); s.mouseButton5Action = MouseButtonAction.disabled.rawValue
        #expect(Feature.mouse.isEnabled(in: s))
    }
}
