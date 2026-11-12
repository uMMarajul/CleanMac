import AppKit
import Foundation

struct HistoryPoint: Identifiable {
    let time: Date
    let value: Double
    var id: Date { time }
}

struct ProcessRow: Identifiable {
    let pid: Int32
    let name: String
    let isOwn: Bool
    let cpu: Double?
    let memory: Int64?
    /// Set for apps (Dock or menu bar), which can be quit.
    let app: NSRunningApplication?
    let uid: UInt32?

    var id: Int32 { pid }
    var cpuSort: Double { cpu ?? -1 }
    var memorySort: Int64 { memory ?? -1 }
}

/// Samples system activity every 2 seconds while at least one screen is watching.
@MainActor
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var cpuTotal: Double = 0
    @Published private(set) var cpuPerCore: [Double] = []
    @Published private(set) var cpuHistory: [HistoryPoint] = []
    @Published private(set) var memory: MemoryStats?
    @Published private(set) var memoryHistory: [HistoryPoint] = []
    @Published private(set) var diskReadPerSecond: Int64 = 0
    @Published private(set) var diskWritePerSecond: Int64 = 0
    @Published private(set) var downloadPerSecond: Int64 = 0
    @Published private(set) var uploadPerSecond: Int64 = 0
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var processes: [ProcessRow] = []

    static let interval: Double = 2
    private static let historyLength = 30

    private var watchers = 0
    private var loop: Task<Void, Never>?
    private var lastTicks: [CoreTicks] = []
    private var lastDisk: (read: UInt64, written: UInt64)?
    private var lastNetwork: (received: UInt64, sent: UInt64)?
    private var lastCPUTime: [Int32: UInt64] = [:]
    private var lastSample = Date()

    func start() {
        watchers += 1
        guard watchers == 1 else { return }
        loop = Task {
            while !Task.isCancelled {
                await sample()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func stop() {
        watchers = max(0, watchers - 1)
        if watchers == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    private func sample() async {
        let reading = await Task.detached(priority: .utility) {
            (SystemStats.coreTicks(), SystemStats.memory(), SystemStats.diskBytes(),
             SystemStats.networkBytes(), SystemStats.battery(), SystemStats.processes())
        }.value
        let (ticks, memory, disk, network, battery, samples) = reading
        let now = Date()
        let elapsed = max(0.5, now.timeIntervalSince(lastSample))
        lastSample = now

        if lastTicks.count == ticks.count {
            cpuPerCore = zip(lastTicks, ticks).map { SystemStats.usage(from: $0, to: $1) }
            cpuTotal = cpuPerCore.isEmpty ? 0 : cpuPerCore.reduce(0, +) / Double(cpuPerCore.count)
            append(&cpuHistory, cpuTotal * 100, at: now)
        }
        lastTicks = ticks

        self.memory = memory
        if let memory, memory.total > 0 {
            append(&memoryHistory, Double(memory.used) / Double(memory.total) * 100, at: now)
        }

        if let lastDisk {
            diskReadPerSecond = rate(lastDisk.read, disk.read, elapsed)
            diskWritePerSecond = rate(lastDisk.written, disk.written, elapsed)
        }
        lastDisk = disk
        if let lastNetwork {
            downloadPerSecond = rate(lastNetwork.received, network.received, elapsed)
            uploadPerSecond = rate(lastNetwork.sent, network.sent, elapsed)
        }
        lastNetwork = network
        self.battery = battery

        let apps = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let me = getuid()
        processes = rows(from: samples, apps: apps, elapsed: elapsed, me: me)
    }

    private func rows(from samples: [ProcessSample], apps: [Int32: NSRunningApplication], elapsed: Double, me: uid_t) -> [ProcessRow] {
        var times: [Int32: UInt64] = [:]
        let rows = samples.map { sample -> ProcessRow in
            var cpu: Double?
            if let now = sample.cpuNanoseconds {
                times[sample.pid] = now
                if let before = lastCPUTime[sample.pid], now >= before {
                    cpu = Double(now - before) / (elapsed * 1_000_000_000) * 100
                }
            }
            return ProcessRow(
                pid: sample.pid,
                name: apps[sample.pid]?.localizedName ?? sample.name,
                isOwn: sample.uid == me,
                cpu: cpu,
                memory: sample.memory,
                app: apps[sample.pid].flatMap { $0.activationPolicy == .prohibited ? nil : $0 },
                uid: sample.uid
            )
        }
        lastCPUTime = times
        return rows
    }

    private func rate(_ before: UInt64, _ after: UInt64, _ seconds: Double) -> Int64 {
        after >= before ? Int64(Double(after - before) / seconds) : 0
    }

    private func append(_ history: inout [HistoryPoint], _ value: Double, at time: Date) {
        history.append(HistoryPoint(time: time, value: value))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }
}
