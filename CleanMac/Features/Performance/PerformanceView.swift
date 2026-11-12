import AppKit
import Charts
import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject private var monitor: PerformanceMonitor

    @State private var sortOrder = [KeyPathComparator(\ProcessRow.cpuSort, order: .reverse)]
    @State private var search = ""
    @State private var selection = Set<ProcessRow.ID>()
    @State private var forceQuit: ProcessRow?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    cpuCard
                    memoryCard
                    ioCard
                    if let battery = monitor.battery { batteryCard(battery) }
                }
                .padding()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 330)
            Divider()
            processTable
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $search, placement: .toolbar, prompt: "Search processes")
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .confirmationDialog(
            forceQuit.map { "Force quit \($0.name)?" } ?? "",
            isPresented: Binding(get: { forceQuit != nil }, set: { if !$0 { forceQuit = nil } }),
            titleVisibility: .visible
        ) {
            if let row = forceQuit {
                Button("Force Quit", role: .destructive) { row.app?.forceTerminate() }
            }
        } message: {
            Text("Unsaved changes in this app will be lost.")
        }
    }

    // MARK: Cards

    private var cpuCard: some View {
        card("CPU", systemImage: "cpu") {
            Text(percent(monitor.cpuTotal * 100)).font(.title.weight(.semibold)).monospacedDigit()
            history(monitor.cpuHistory, color: .blue)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(monitor.cpuPerCore.enumerated()), id: \.offset) { _, usage in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.blue.opacity(0.7))
                        .frame(height: max(2, 24 * usage))
                        .frame(maxHeight: 24, alignment: .bottom)
                }
            }
            .help("Usage per core")
        }
    }

    private var memoryCard: some View {
        card("Memory", systemImage: "memorychip") {
            if let memory = monitor.memory {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatBytes(memory.used)).font(.title.weight(.semibold)).monospacedDigit()
                    Text("of \(formatBytes(memory.total))").foregroundStyle(.secondary)
                    Spacer()
                    pressureBadge(memory.pressure)
                }
                history(monitor.memoryHistory, color: .purple)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow { label("App memory"); value(memory.app) }
                    GridRow { label("Wired"); value(memory.wired) }
                    GridRow { label("Compressed"); value(memory.compressed) }
                    GridRow { label("Cached files"); value(memory.cached) }
                    GridRow { label("Swap used"); value(memory.swapUsed) }
                }
                .font(.caption)
            } else {
                ProgressView()
            }
        }
    }

    private var ioCard: some View {
        card("Disk & Network", systemImage: "arrow.up.arrow.down") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { label("Disk read"); speed(monitor.diskReadPerSecond) }
                GridRow { label("Disk write"); speed(monitor.diskWritePerSecond) }
                GridRow { label("Download"); speed(monitor.downloadPerSecond) }
                GridRow { label("Upload"); speed(monitor.uploadPerSecond) }
            }
        }
    }

    private func batteryCard(_ battery: BatteryInfo) -> some View {
        card("Battery", systemImage: battery.isCharging ? "battery.100.bolt" : "battery.75") {
            HStack(alignment: .firstTextBaseline) {
                Text("\(battery.charge)%").font(.title.weight(.semibold)).monospacedDigit()
                Text(battery.isCharging ? "Charging" : battery.onPower ? "On power" : "On battery")
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let minutes = battery.minutesRemaining, !battery.onPower {
                    GridRow { label("Time left"); Text("\(minutes / 60) h \(minutes % 60) min") }
                }
                if let health = battery.healthPercent {
                    GridRow { label("Health"); Text(percent(health)).monospacedDigit() }
                }
                if let cycles = battery.cycleCount {
                    GridRow { label("Cycle count"); Text("\(cycles)").monospacedDigit() }
                }
                if let condition = battery.condition {
                    GridRow { label("Condition"); Text(condition) }
                }
            }
            .font(.callout)
        }
    }

    // MARK: Processes

    private var processTable: some View {
        let rows = monitor.processes
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Process", value: \.name) { row in
                HStack(spacing: 6) {
                    if let icon = row.app?.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 16)
                    }
                    Text(row.name).lineLimit(1)
                }
            }
            TableColumn("CPU %", value: \.cpuSort) { row in
                Text(row.cpu.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
            }
            .width(70)
            TableColumn("Memory", value: \.memorySort) { row in
                Text(row.memory.map(formatBytes) ?? "—").monospacedDigit()
            }
            .width(90)
            TableColumn("User") { row in
                Text(row.isOwn ? "You" : "System").foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("PID", value: \.pid) { row in
                Text("\(row.pid)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
        }
        .contextMenu(forSelectionType: ProcessRow.ID.self) { ids in
            if let row = rows.first(where: { ids.contains($0.id) }) {
                let refusal = ProcessActions.refusal(pid: row.pid, uid: row.uid, isApp: row.app != nil)
                Button("Quit \(row.name)") { row.app?.terminate() }
                    .disabled(refusal != nil)
                Button("Force Quit \(row.name)…") { forceQuit = row }
                    .disabled(refusal != nil)
                if let refusal {
                    Text(refusal)
                }
            }
        }
    }

    // MARK: Pieces

    private func card(_ title: String, systemImage: String, @ViewBuilder content: () -> some View) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func history(_ points: [HistoryPoint], color: Color) -> some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.time), y: .value("Percent", point.value))
                .foregroundStyle(color.opacity(0.25))
            LineMark(x: .value("Time", point.time), y: .value("Percent", point.value))
                .foregroundStyle(color)
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 50)
    }

    private func pressureBadge(_ pressure: MemoryPressure) -> some View {
        let color: Color = switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
        return Text("Pressure: \(pressure.rawValue)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func value(_ bytes: Int64) -> some View {
        Text(formatBytes(bytes)).monospacedDigit()
    }

    private func speed(_ bytesPerSecond: Int64) -> some View {
        Text("\(formatBytes(bytesPerSecond))/s").monospacedDigit()
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }
}
