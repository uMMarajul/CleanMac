import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Raw counters for one CPU core since boot.
struct CoreTicks: Equatable {
    var user: UInt32, system: UInt32, idle: UInt32, nice: UInt32
}

enum MemoryPressure: String {
    case normal = "Normal", warning = "Warning", critical = "Critical"

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    init(level: Int32) {
        switch level {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }
}

struct MemoryStats {
    let total: Int64
    /// App memory + wired + compressed, as Activity Monitor's "Memory Used".
    let used: Int64
    let app: Int64
    let wired: Int64
    let compressed: Int64
    let cached: Int64
    let swapUsed: Int64
    let pressure: MemoryPressure
}

struct BatteryInfo {
    let charge: Int
    let isCharging: Bool
    let onPower: Bool
    let minutesRemaining: Int?
    let cycleCount: Int?
    /// Current full-charge capacity as a share of the original design capacity.
    let healthPercent: Double?
    let condition: String?
}

struct ProcessSample {
    let pid: Int32
    let name: String
    /// nil when macOS does not share it (processes of macOS or other users).
    let uid: UInt32?
    let cpuNanoseconds: UInt64?
    let memory: Int64?
}

/// Read-only system counters from public macOS interfaces.
enum SystemStats {
    // MARK: CPU

    static func coreTicks() -> [CoreTicks] {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(coreCount)).map { core in
            let base = Int(CPU_STATE_MAX) * core
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                             idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    /// Busy share (0…1) of one core between two readings. Counters may wrap around.
    static func usage(from old: CoreTicks, to new: CoreTicks) -> Double {
        let busy = Double((new.user &- old.user) &+ (new.system &- old.system) &+ (new.nice &- old.nice))
        let idle = Double(new.idle &- old.idle)
        return busy + idle > 0 ? busy / (busy + idle) : 0
    }

    // MARK: Memory

    static func memory() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Int64(vm_kernel_page_size)
        let app = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        return MemoryStats(
            total: Int64(ProcessInfo.processInfo.physicalMemory),
            used: app + wired + compressed,
            app: app,
            wired: wired,
            compressed: compressed,
            cached: (Int64(stats.external_page_count) + Int64(stats.purgeable_count)) * page,
            swapUsed: Int64(swap.xsu_used),
            pressure: MemoryPressure(level: level)
        )
    }

    // MARK: Disk and network

    /// Total bytes read and written by all disks since boot.
    static func diskBytes() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, written)
    }

    /// Total bytes received and sent on all network interfaces except loopback.
    static func networkBytes() -> (received: UInt64, sent: UInt64) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (0, 0) }
        defer { freeifaddrs(list) }
        var received: UInt64 = 0, sent: UInt64 = 0
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data,
                  !String(cString: entry.pointee.ifa_name).hasPrefix("lo") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(counters.ifi_ibytes)
            sent += UInt64(counters.ifi_obytes)
        }
        return (received, sent)
    }

    // MARK: Battery

    static func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(1, info[kIOPSMaxCapacityKey] as? Int ?? 100)
            let minutes = info[kIOPSTimeToEmptyKey] as? Int
            let registry = smartBatteryProperties()
            let data = registry["BatteryData"] as? [String: Any] ?? [:]
            let design = (registry["DesignCapacity"] ?? data["DesignCapacity"]) as? Int
            let rawMax = (registry["AppleRawMaxCapacity"] ?? data["AppleRawMaxCapacity"]) as? Int

            return BatteryInfo(
                charge: current * 100 / maximum,
                isCharging: info[kIOPSIsChargingKey] as? Bool ?? false,
                onPower: info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                minutesRemaining: minutes.flatMap { $0 > 0 ? $0 : nil },
                cycleCount: registry["CycleCount"] as? Int,
                healthPercent: healthPercent(rawMax: rawMax, design: design),
                condition: info["BatteryHealth"] as? String
            )
        }
        return nil
    }

    static func healthPercent(rawMax: Int?, design: Int?) -> Double? {
        guard let rawMax, let design, design > 0 else { return nil }
        return min(100, Double(rawMax) / Double(design) * 100)
    }

    private static func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    // MARK: Processes

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func processes() -> [ProcessSample] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let found = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        return pids.prefix(max(0, min(found, capacity))).compactMap { pid in
            guard pid > 0 else { return nil }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)
            guard !name.isEmpty else { return nil }

            var info = proc_bsdinfo()
            let hasInfo = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0

            var usage = rusage_info_v4()
            let hasUsage = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            } == 0
            let ticks = usage.ri_user_time + usage.ri_system_time

            return ProcessSample(
                pid: pid,
                name: name,
                uid: hasInfo ? info.pbi_uid : nil,
                cpuNanoseconds: hasUsage ? ticks * UInt64(timebase.numer) / UInt64(timebase.denom) : nil,
                memory: hasUsage ? Int64(usage.ri_phys_footprint) : nil
            )
        }
    }
}

/// Which processes CleanMac may quit: only the user's own apps, never itself or system processes.
enum ProcessActions {
    static func refusal(pid: Int32, uid: UInt32?, isApp: Bool) -> String? {
        if pid == getpid() { return "This is CleanMac" }
        if !isApp { return "Only apps can be quit from CleanMac" }
        if uid != getuid() { return "Belongs to macOS or another user" }
        return nil
    }
}
