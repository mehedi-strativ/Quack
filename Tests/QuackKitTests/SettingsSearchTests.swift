import Testing
@testable import QuackKit

@Suite struct SettingsSearchTests {
    private let entries = [
        SettingEntry(id: "mouse.smoothScroll", title: "Smooth scrolling", tabID: "mouse",
                     section: "Scrolling", keywords: ["wheel", "animate"]),
        SettingEntry(id: "mouse.tracking", title: "Override tracking speed", tabID: "mouse",
                     section: "Pointer", keywords: ["cursor", "sensitivity", "speed"]),
        SettingEntry(id: "hiddenbar.enable", title: "Hidden menu bar", tabID: "hiddenIcons",
                     section: "Hidden icons", keywords: ["bartender", "chevron", "hide icons"]),
        SettingEntry(id: "time.rest", title: "Remind me to take breaks", tabID: "stats",
                     section: "Rest reminders", keywords: ["break", "rest", "pomodoro"]),
    ]

    @Test func titlePrefixBeatsKeyword() {
        let r = SettingsSearch.matches("smooth", in: entries)
        #expect(r.first?.id == "mouse.smoothScroll")
    }

    @Test func synonymKeywordMatches() {
        #expect(SettingsSearch.matches("bartender", in: entries).first?.id == "hiddenbar.enable")
        #expect(SettingsSearch.matches("cursor", in: entries).first?.id == "mouse.tracking")
        #expect(SettingsSearch.matches("pomodoro", in: entries).first?.id == "time.rest")
    }

    @Test func wordPrefixInsideTitle() {
        let r = SettingsSearch.matches("scroll", in: entries)
        #expect(r.contains { $0.id == "mouse.smoothScroll" })
    }

    @Test func emptyAndNoMatch() {
        #expect(SettingsSearch.matches("", in: entries).isEmpty)
        #expect(SettingsSearch.matches("   ", in: entries).isEmpty)
        #expect(SettingsSearch.matches("zzzz", in: entries).isEmpty)
    }

    @Test func caseAndDiacriticInsensitive() {
        #expect(!SettingsSearch.matches("SMOOTH", in: entries).isEmpty)
        #expect(!SettingsSearch.matches("Smoöth", in: entries).isEmpty)
    }

    @Test func limitRespected() {
        let many = (0..<30).map {
            SettingEntry(id: "e\($0)", title: "Toggle \($0)", tabID: "t", section: "s")
        }
        #expect(SettingsSearch.matches("toggle", in: many, limit: 5).count == 5)
    }
}
