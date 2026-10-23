import Testing
@testable import QuackKit

@Suite struct ProcessUsageTests {
    let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"

    @Test func outermostBundleWins() {
        #expect(ProcessUsage.appBundlePath(forExecutable: helper) == "/Applications/Google Chrome.app")
        #expect(ProcessUsage.appBundlePath(forExecutable: "/usr/bin/yes") == nil)
    }

    @Test func helpersGroupIntoTheirApp() {
        let prev = [ProcessSample(pid: 1, path: chrome, cpuTimeNs: 0),
                    ProcessSample(pid: 2, path: helper, cpuTimeNs: 0)]
        let cur = [ProcessSample(pid: 1, path: chrome, cpuTimeNs: 1_000_000_000, memoryBytes: 100),
                   ProcessSample(pid: 2, path: helper, cpuTimeNs: 2_000_000_000, memoryBytes: 50)]
        let apps = ProcessUsage.aggregate(previous: prev, current: cur, interval: 2)
        #expect(apps.count == 1)
        #expect(apps[0].name == "Google Chrome")
        #expect(abs(apps[0].cpuPercent - 150) < 1e-9)   // 3s of CPU over 2s
        #expect(apps[0].memoryBytes == 150)
        #expect(Set(apps[0].pids) == [1, 2])
    }

    @Test func gpuAndEnergyRates() {
        let prev = [ProcessSample(pid: 3, path: "/usr/bin/yes", cpuTimeNs: 0, gpuTimeNs: 0, energyNj: 0)]
        let cur = [ProcessSample(pid: 3, path: "/usr/bin/yes", cpuTimeNs: 0, gpuTimeNs: 500_000_000, energyNj: 4_000_000_000)]
        let app = ProcessUsage.aggregate(previous: prev, current: cur, interval: 1)[0]
        #expect(app.id == "pid:3" && app.name == "yes" && !app.isSystem)
        #expect(abs(app.gpuPercent - 50) < 1e-9)
        #expect(abs(app.watts - 4) < 1e-9)
    }

    @Test func reusedPidCountsAsNew() {
        let prev = [ProcessSample(pid: 4, path: "/usr/bin/old", cpuTimeNs: 9_000_000_000)]
        let cur = [ProcessSample(pid: 4, path: "/usr/bin/new", cpuTimeNs: 1_000_000_000)]
        #expect(ProcessUsage.aggregate(previous: prev, current: cur, interval: 1)[0].cpuPercent == 0)
    }

    @Test func systemDaemonsGetFriendlyNames() {
        let path = "/System/Library/PrivateFrameworks/CoreSuggestions.framework/Versions/A/Support/suggestd"
        let app = ProcessUsage.aggregate(previous: [], current: [ProcessSample(pid: 5, path: path, cpuTimeNs: 0)], interval: 1)[0]
        #expect(app.name == "Siri Suggestions" && app.processName == "suggestd" && app.isSystem)
        // A user's own binary with a colliding name keeps it.
        let own = ProcessUsage.aggregate(previous: [], current: [ProcessSample(pid: 6, path: "/Users/me/bin/suggestd", cpuTimeNs: 0)], interval: 1)[0]
        #expect(own.name == "suggestd")
    }

    @Test func systemPathsAreProtected() {
        #expect(ProcessUsage.isSystemPath("/System/Library/CoreServices/loginwindow.app"))
        #expect(ProcessUsage.isSystemPath("/usr/libexec/trustd"))
        #expect(!ProcessUsage.isSystemPath("/usr/bin/yes"))
        #expect(!ProcessUsage.isSystemPath("/Applications/Safari.app"))
        #expect(!ProcessUsage.isSystemPath("/System/Applications/Photos.app"))
    }
}
