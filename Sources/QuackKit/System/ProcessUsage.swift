import Foundation

/// One process's cumulative counters at a sample instant. Times are in ns.
public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var path: String
    public var cpuTimeNs: UInt64
    public var gpuTimeNs: UInt64
    public var energyNj: UInt64
    public var memoryBytes: UInt64

    public init(pid: Int32, path: String, cpuTimeNs: UInt64, gpuTimeNs: UInt64 = 0,
                energyNj: UInt64 = 0, memoryBytes: UInt64 = 0) {
        self.pid = pid
        self.path = path
        self.cpuTimeNs = cpuTimeNs
        self.gpuTimeNs = gpuTimeNs
        self.energyNj = energyNj
        self.memoryBytes = memoryBytes
    }
}

/// Resource use of one app (all its helper processes summed) or one bare
/// process, over the interval between two samples.
public struct AppUsage: Identifiable, Equatable, Sendable {
    /// The `.app` bundle path, or "pid:<n>" for a process outside any bundle.
    public var id: String
    /// Human-readable name ("Siri Suggestions" rather than "suggestd").
    public var name: String
    /// The raw executable or bundle name, as Activity Monitor shows it.
    public var processName: String
    public var bundlePath: String?
    public var pids: [Int32]
    /// 100 = one full core (like Activity Monitor), so it can exceed 100.
    public var cpuPercent: Double
    /// 100 = the GPU busy the whole interval.
    public var gpuPercent: Double
    public var watts: Double
    public var memoryBytes: UInt64
    /// Part of macOS itself — quitting it breaks or logs out the session.
    public var isSystem: Bool
}

public enum ProcessUsage {
    /// The outermost `.app` bundle containing an executable, so helpers like
    /// `Google Chrome.app/.../Google Chrome Helper.app/...` group under Chrome.
    public static func appBundlePath(forExecutable path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// OS components (loginwindow, Dock, WindowServer, daemons). Never offer
    /// to quit these. /usr/bin stays quittable (scripts, `yes`, compilers).
    // ponytail: path heuristic, not ownership; switch to a uid check if a user-owned daemon slips through.
    public static func isSystemPath(_ path: String) -> Bool {
        // Built-in user apps (Photos, Mail, Safari…) live under /System but quit fine.
        if path.contains("/System/Applications/") { return false }
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
            .contains { path.hasPrefix($0) }
    }

    /// Per-app usage between two samples taken `interval` seconds apart.
    /// Processes missing from `previous` (just started) count with zero
    /// activity; a counter that went backwards means the pid was reused.
    public static func aggregate(previous: [ProcessSample], current: [ProcessSample],
                                 interval: TimeInterval) -> [AppUsage] {
        guard interval > 0 else { return [] }
        let before = Dictionary(previous.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let intervalNs = interval * 1e9
        var apps: [String: AppUsage] = [:]

        for s in current {
            var cpu = 0.0, gpu = 0.0, energy = 0.0
            if let p = before[s.pid], p.path == s.path, s.cpuTimeNs >= p.cpuTimeNs {
                cpu = Double(s.cpuTimeNs - p.cpuTimeNs)
                // GPU clients come and go, so their summed time can drop.
                gpu = s.gpuTimeNs >= p.gpuTimeNs ? Double(s.gpuTimeNs - p.gpuTimeNs) : 0
                energy = s.energyNj >= p.energyNj ? Double(s.energyNj - p.energyNj) : 0
            }
            let bundle = appBundlePath(forExecutable: s.path)
            let key = bundle ?? "pid:\(s.pid)"
            let raw = rawName(bundle ?? s.path)
            let system = isSystemPath(bundle ?? s.path)
            var app = apps[key] ?? AppUsage(
                id: key,
                name: system ? (systemNames[raw] ?? raw) : raw,
                processName: raw,
                bundlePath: bundle,
                pids: [],
                cpuPercent: 0, gpuPercent: 0, watts: 0, memoryBytes: 0,
                isSystem: system
            )
            app.pids.append(s.pid)
            app.cpuPercent += cpu / intervalNs * 100
            app.gpuPercent += gpu / intervalNs * 100
            app.watts += energy / intervalNs   // nJ per ns = W
            app.memoryBytes += s.memoryBytes
            apps[key] = app
        }
        return Array(apps.values)
    }

    private static func rawName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// What the macOS processes that most often heat a Mac actually do.
    /// macOS has no API for this; unknown ones keep their raw name.
    // ponytail: hand-picked list of usual suspects; extend when a new cryptic name shows up on top.
    static let systemNames: [String: String] = [
        "suggestd": "Siri Suggestions",
        "knowledgeconstructiond": "Siri Knowledge",
        "intelligenceplatformd": "Apple Intelligence",
        "generativeexperiencesd": "Apple Intelligence",
        "mds": "Spotlight Indexing",
        "mds_stores": "Spotlight Indexing",
        "mdworker": "Spotlight Indexing",
        "mdworker_shared": "Spotlight Indexing",
        "mdbulkimport": "Spotlight Indexing",
        "corespotlightd": "Spotlight Indexing",
        "mediaanalysisd": "Photos Analysis",
        "photoanalysisd": "Photos Analysis",
        "photolibraryd": "Photos Library",
        "cloudphotod": "iCloud Photos Sync",
        "bird": "iCloud Drive Sync",
        "cloudd": "iCloud Sync",
        "fileproviderd": "File Sync (iCloud, Drive…)",
        "backupd": "Time Machine Backup",
        "backupd-helper": "Time Machine Backup",
        "softwareupdated": "Software Update",
        "nsurlsessiond": "Background Downloads",
        "syspolicyd": "Gatekeeper App Checks",
        "XprotectService": "XProtect Malware Scan",
        "trustd": "Certificate Checks",
        "secd": "Keychain",
        "WindowServer": "Screen Drawing (WindowServer)",
        "coreaudiod": "Audio",
        "bluetoothd": "Bluetooth",
        "sharingd": "AirDrop & Handoff",
        "locationd": "Location Services",
        "searchpartyd": "Find My",
        "ReportCrash": "Crash Reporter",
        "screencapture": "Screenshot",
        "WiFiAgent": "Wi-Fi",
        "Wi-Fi": "Wi-Fi Menu",
        "com.apple.WebKit.WebContent": "Web Page (Safari & apps)",
        "com.apple.WebKit.GPU": "Web Graphics (Safari & apps)",
        "com.apple.WebKit.Networking": "Web Networking (Safari & apps)",
    ]
}
