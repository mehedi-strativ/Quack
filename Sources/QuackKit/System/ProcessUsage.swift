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
    public var name: String
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
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
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
            var app = apps[key] ?? AppUsage(
                id: key,
                name: displayName(bundle ?? s.path),
                bundlePath: bundle,
                pids: [],
                cpuPercent: 0, gpuPercent: 0, watts: 0, memoryBytes: 0,
                isSystem: isSystemPath(bundle ?? s.path)
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

    private static func displayName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }
}
