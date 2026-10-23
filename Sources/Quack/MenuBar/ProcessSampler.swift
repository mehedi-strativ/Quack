import Darwin
import Foundation
import IOKit
import QuackKit

/// Reads every visible process's cumulative CPU time, energy and memory
/// (libproc) plus GPU time (IORegistry AGX user clients). Blocking — call off
/// the main thread. Processes we may not inspect (other users') are skipped.
enum ProcessSampler {
    /// rusage CPU times are mach ticks (125/3 ns each on Apple Silicon).
    private static let nsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    static func sample() -> [ProcessSample] {
        let gpu = gpuTimes()
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE

        var out: [ProcessSample] = []
        out.reserveCapacity(count)
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var ri = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            } == 0
            guard ok, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            out.append(ProcessSample(
                pid: pid,
                path: String(cString: path),
                cpuTimeNs: UInt64(Double(ri.ri_user_time + ri.ri_system_time) * nsPerTick),
                gpuTimeNs: gpu[pid] ?? 0,
                energyNj: ri.ri_energy_nj,
                memoryBytes: ri.ri_phys_footprint
            ))
        }
        return out
    }

    /// Cumulative GPU ns per pid. Each Metal/GL client of the GPU is an
    /// IORegistry child of the accelerator, tagged "pid 123, Name" and holding
    /// an `AppUsage` array of `accumulatedGPUTime` (ns). Same source nvtop uses.
    private static func gpuTimes() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        forEachEntry(IOServiceMatching("IOAccelerator")) { accel in
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS else { return }
            drain(children) { client in
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      creator.hasPrefix("pid "),
                      let pid = pid_t(creator.dropFirst(4).prefix(while: \.isNumber)),
                      let usage = property(client, "AppUsage") as? [[String: Any]]
                else { return }
                result[pid, default: 0] += usage.reduce(0) {
                    $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
                }
            }
        }
        return result
    }

    private static func forEachEntry(_ matching: CFDictionary, _ body: (io_object_t) -> Void) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return }
        drain(iter, body)
    }

    /// Visits and releases every object in `iter`, then releases `iter`.
    private static func drain(_ iter: io_iterator_t, _ body: (io_object_t) -> Void) {
        defer { IOObjectRelease(iter) }
        while case let obj = IOIteratorNext(iter), obj != 0 {
            body(obj)
            IOObjectRelease(obj)
        }
    }

    private static func property(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
