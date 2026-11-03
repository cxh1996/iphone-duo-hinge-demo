import Darwin
import Observation
import SwiftUI
import UIKit

// MARK: - Clock

/// A monotonic clock that keeps running while the device is asleep.
///
/// `ProcessInfo.systemUptime` is backed by `mach_absolute_time`, which stops
/// while the device sleeps. A fold that ends with the lid shut would look like
/// a zero-duration event, which is exactly the segment we care about.
private enum HingeClock {
    /// `mach_continuous_time` counts in ticks; convert them to nanoseconds once.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    static func nowNanos() -> UInt64 {
        let ticks = mach_continuous_time()
        let numer = timebase.numer
        let denom = max(timebase.denom, 1)
        // Split into whole and remainder parts so the multiplication cannot overflow.
        return ticks / denom * numer + (ticks % denom) * numer / denom
    }
}

// MARK: - Raw row

/// The only thing stored per event. Every derived quantity (Δt, Δangle,
/// degrees per second) is computed offline from these three numbers, so a
/// mistake in this app can never bake itself into the recording.
struct HingeRawRow {
    enum Event: String {
        case hinge
        case geom
        case phase
        case mark
    }

    enum Status: String {
        case closed
        case partiallyOpen
        case fullyOpen
        case unknown

        var label: String {
            switch self {
            case .closed: "Closed"
            case .partiallyOpen: "Partially Open"
            case .fullyOpen: "Fully Open"
            case .unknown: "Unknown"
            }
        }
    }

    var seq = 0
    var event: Event = .hinge
    var monoNs: UInt64 = 0
    var epoch: Double = 0
    var angleDeg: Double?
    var status: Status?
    var width: Double?
    var height: Double?
    var note = ""
}

// MARK: - Export

struct HingeExport: Identifiable {
    let id = UUID()
    let createdAt: Date
    let csv: URL
    let txt: URL
    let rows: Int

    var urls: [URL] {
        [csv, txt].filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}

// MARK: - Recorder

/// App-wide recorder. One session = one CSV file, written incrementally.
///
/// The recorder is deliberately dull on the hot path: the hinge callback only
/// reads the angle, stamps a monotonic time, and appends a struct to an array.
/// No formatting, no diffing, no animation, no observable state — those would
/// compete with the system for the main thread and pollute the very timing we
/// are trying to measure.
@Observable
final class HingeRecorder {
    static let shared = HingeRecorder()

    /// Hard ceiling for a single session. Reaching it stops the recording and
    /// says so, instead of silently dropping the oldest samples.
    static let maxRows = 50_000

    // Observed properties: they change rarely, so observation is harmless.
    private(set) var isRecording = false
    private(set) var hasHinge = false
    private(set) var exports: [HingeExport] = []
    private(set) var statusMessage: String?
    private(set) var sessionStartedAt: Date?

    // Live readouts. Deliberately *not* observable: they change on every hinge
    // delivery, and invalidating the view at that rate would steal main-thread
    // time from the callback itself. The HUD redraws them on a 2 Hz timeline.
    @ObservationIgnored private(set) var angleDegrees: Double?
    @ObservationIgnored private(set) var statusTag: HingeRawRow.Status?
    @ObservationIgnored private(set) var lastIntervalMs: Double?
    @ObservationIgnored private(set) var rowCount = 0

    @ObservationIgnored private var rows: [HingeRawRow] = []
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var flushed = 0
    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private var csvURL: URL?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var lastHingeMono: UInt64?
    @ObservationIgnored private var lastGeometry: CGSize?
    @ObservationIgnored private var isFinishing = false

    private init() {
        reloadExports()
    }

    // MARK: Ingest (called from the root of the app)

    func ingest(hinge: DeviceHinge?) {
        hasHinge = hinge != nil
        guard let hinge else { return }

        let mono = HingeClock.nowNanos()
        angleDegrees = hinge.angle.degrees
        statusTag = Self.tag(of: hinge.status)
        if let previous = lastHingeMono {
            lastIntervalMs = Double(mono &- previous) / 1_000_000
        }
        lastHingeMono = mono

        guard isRecording else { return }
        append(HingeRawRow(event: .hinge,
                           monoNs: mono,
                           epoch: Date().timeIntervalSince1970,
                           angleDeg: hinge.angle.degrees,
                           status: Self.tag(of: hinge.status)))
    }

    /// A window size change is the moment the system actually reconfigured the
    /// display. It is the most direct evidence of "the screen switched", and it
    /// is recorded on the same timeline as the angles so the two can be aligned.
    func ingestGeometry(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastGeometry = size
        guard isRecording else { return }
        append(HingeRawRow(event: .geom,
                           monoNs: HingeClock.nowNanos(),
                           epoch: Date().timeIntervalSince1970,
                           width: Double(size.width),
                           height: Double(size.height)))
    }

    func ingestPhase(_ name: String) {
        guard isRecording else { return }
        append(HingeRawRow(event: .phase,
                           monoNs: HingeClock.nowNanos(),
                           epoch: Date().timeIntervalSince1970,
                           note: name))
    }

    func mark(_ note: String) {
        guard isRecording else { return }
        append(HingeRawRow(event: .mark,
                           monoNs: HingeClock.nowNanos(),
                           epoch: Date().timeIntervalSince1970,
                           note: note.isEmpty ? "mark" : note))
    }

    // MARK: Session control

    func start() {
        guard !isRecording else { return }

        rows.removeAll(keepingCapacity: true)
        seq = 0
        flushed = 0
        rowCount = 0
        isFinishing = false
        lastHingeMono = nil
        lastIntervalMs = nil
        statusMessage = nil

        let directory = Self.exportsDirectory()
        let stamp = Self.stampFormatter.string(from: .now)
        let csv = directory.appending(path: "hinge-\(stamp).csv")

        // A byte-order mark keeps Windows Excel from mangling the file; every
        // row after it is plain UTF-8 and can be appended incrementally.
        let header = "\u{FEFF}seq,event,mono_ns,epoch_s,angle_deg,angle_rad,status,w_pt,h_pt,note\n"
        guard FileManager.default.createFile(atPath: csv.path(percentEncoded: false),
                                            contents: Data(header.utf8)),
              let handle = try? FileHandle(forWritingTo: csv) else {
            statusMessage = "Could not create \(csv.lastPathComponent)."
            return
        }

        self.handle = handle
        csvURL = csv
        sessionStartedAt = .now
        isRecording = true
        append(HingeRawRow(event: .phase,
                           monoNs: HingeClock.nowNanos(),
                           epoch: Date().timeIntervalSince1970,
                           note: "start"))
        // Baseline size, so a geometry row later can be told apart from "no
        // geometry row yet".
        if let size = lastGeometry {
            append(HingeRawRow(event: .geom,
                               monoNs: HingeClock.nowNanos(),
                               epoch: Date().timeIntervalSince1970,
                               width: Double(size.width),
                               height: Double(size.height),
                               note: "baseline"))
        }
        flush()

        // Flush once a second so a crash or a kill costs at most the tail of
        // the recording instead of all of it.
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.flush()
            }
        }
    }

    func stop() {
        finish(reason: nil)
    }

    private func finish(reason: String?) {
        guard isRecording, !isFinishing else { return }
        isFinishing = true

        append(HingeRawRow(event: .mark,
                           monoNs: HingeClock.nowNanos(),
                           epoch: Date().timeIntervalSince1970,
                           note: reason.map { "stop: \($0)" } ?? "stop"))
        flush()

        isRecording = false
        flushTask?.cancel()
        flushTask = nil
        try? handle?.close()
        handle = nil

        defer {
            csvURL = nil
            isFinishing = false
            reloadExports()
            if !exports.isEmpty {
                statusMessage = "Saved \(exports[0].csv.lastPathComponent) · \(rowCount) rows"
            }
        }

        guard let csv = csvURL else { return }
        let startedAt = sessionStartedAt ?? .now
        let report = Self.textReport(rows: rows, startedAt: startedAt)
        // Same BOM rule as the CSV, for the same reason.
        let txt = csv.deletingPathExtension().appendingPathExtension("txt")
        try? Data(("\u{FEFF}" + report).utf8).write(to: txt)
    }

    // MARK: Buffering and file writing

    private func append(_ row: HingeRawRow) {
        guard isRecording else { return }
        guard rows.count < Self.maxRows else {
            if !isFinishing { finish(reason: "row limit \(Self.maxRows) reached") }
            return
        }
        seq += 1
        var row = row
        row.seq = seq
        rows.append(row)
        rowCount = rows.count
    }

    private func flush() {
        guard let handle, flushed < rows.count else { return }
        var text = ""
        text.reserveCapacity((rows.count - flushed) * 80)
        for row in rows[flushed...] {
            text += Self.csvLine(row)
        }
        try? handle.write(contentsOf: Data(text.utf8))
        flushed = rows.count
    }

    private func reloadExports() {
        let directory = Self.exportsDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        var found: [HingeExport] = []
        for csv in urls where csv.pathExtension == "csv" {
            let date = (try? csv.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            found.append(HingeExport(createdAt: date,
                                     csv: csv,
                                     txt: csv.deletingPathExtension().appendingPathExtension("txt"),
                                     rows: 0))
        }
        exports = Array(found.sorted { $0.createdAt > $1.createdAt }.prefix(20))
    }

    // MARK: Formatting

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func decimals(_ value: Double, _ digits: Int) -> String {
        value.formatted(.number
            .precision(.fractionLength(digits))
            .grouping(.never)
            .locale(posix))
    }

    private static func csvLine(_ row: HingeRawRow) -> String {
        let degrees = row.angleDeg.map { decimals($0, 3) } ?? ""
        let radians = row.angleDeg.map { decimals($0 * .pi / 180, 4) } ?? ""
        let width = row.width.map { decimals($0, 1) } ?? ""
        let height = row.height.map { decimals($0, 1) } ?? ""
        let note = escaped(row.note)
        return "\(row.seq),\(row.event.rawValue),\(row.monoNs),\(decimals(row.epoch, 6)),"
            + "\(degrees),\(radians),\(row.status?.rawValue ?? ""),\(width),\(height),\(note)\n"
    }

    private static func escaped(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func tag(of status: DeviceHinge.Status) -> HingeRawRow.Status {
        switch status {
        case .closed: .closed
        case .partiallyOpen: .partiallyOpen
        case .fullyOpen: .fullyOpen
        default: .unknown
        }
    }

    private static func exportsDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appending(path: "Exports", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Human-readable report

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func textReport(rows: [HingeRawRow], startedAt: Date) -> String {
        guard let first = rows.first else { return "# empty session\n" }
        let origin = first.monoNs
        func elapsedMs(_ nanos: UInt64) -> Double { Double(nanos &- origin) / 1_000_000 }
        func num(_ value: Double, _ digits: Int) -> String { decimals(value, digits) }

        let hinges = rows.filter { $0.event == .hinge && $0.angleDeg != nil }
        var intervals: [Double] = []
        var steps: [Double] = []
        if hinges.count > 1 {
            for index in 1 ..< hinges.count {
                intervals.append(elapsedMs(hinges[index].monoNs) - elapsedMs(hinges[index - 1].monoNs))
                if let a = hinges[index].angleDeg, let b = hinges[index - 1].angleDeg {
                    steps.append(abs(a - b))
                }
            }
        }

        let sortedIntervals = intervals.sorted()
        let nonZeroSteps = steps.filter { $0 > 0.0005 }
        let angles = hinges.compactMap(\.angleDeg)

        // Nearest hinge angle on either side of every geometry change — the
        // honest way to report "at what angle did the display switch".
        var angleAfter = [Double?](repeating: nil, count: rows.count)
        var upcoming: Double?
        var index = rows.count - 1
        while index >= 0 {
            angleAfter[index] = upcoming
            if rows[index].event == .hinge, let value = rows[index].angleDeg { upcoming = value }
            index -= 1
        }

        var out = ""
        out += "# iPhone Duo hinge recording\n"
        out += "# session    \(startedAt.formatted(date: .abbreviated, time: .standard))\n"
        out += "# file       \(stampFormatter.string(from: startedAt))\n"
        let duration = elapsedMs(rows[rows.count - 1].monoNs) / 1000
        out += "# duration   \(num(duration, 3)) s\n"

        let counts = Dictionary(grouping: rows, by: \.event).mapValues(\.count)
        out += "# rows       \(rows.count)  ("
            + HingeRawRow.Event.allDisplayOrder
                .map { "\($0.rawValue) \(counts[$0] ?? 0)" }
                .joined(separator: ", ") + ")\n"

        if let median = percentile(sortedIntervals, 0.5) {
            out += "# delivery   median \(num(median, 1)) ms"
            if let p95 = percentile(sortedIntervals, 0.95) { out += " | p95 \(num(p95, 1)) ms" }
            if let maxValue = sortedIntervals.last { out += " | max \(num(maxValue, 1)) ms" }
            out += "  (n=\(intervals.count))\n"
        } else {
            out += "# delivery   not enough hinge samples\n"
        }

        if let low = angles.min(), let high = angles.max() {
            out += "# angle      \(num(low, 3))° .. \(num(high, 3))°"
            if let resolution = nonZeroSteps.min() {
                out += "   smallest non-zero step \(num(resolution, 3))°"
            }
            out += "\n"
        }

        let gaps = intervals.enumerated().filter { $0.element > 200 }
        out += "# gaps >200ms \(gaps.count)\n"
        for (position, gap) in gaps.prefix(40) {
            out += "#   after hinge #\(position + 1)  t=\(num(elapsedMs(hinges[position].monoNs), 1)) ms  gap=\(num(gap, 1)) ms\n"
        }

        let geometry = rows.enumerated().filter { $0.element.event == .geom }
        out += "# display configuration changes \(geometry.count)\n"
        var previousAngle: Double?
        for (position, row) in rows.enumerated() {
            if row.event == .hinge, let value = row.angleDeg { previousAngle = value; continue }
            guard row.event == .geom else { continue }
            let before = previousAngle.map { num($0, 1) + "°" } ?? "?"
            let after = angleAfter[position].map { num($0, 1) + "°" } ?? "?"
            let bracket = (previousAngle != nil && angleAfter[position] != nil)
                ? num(abs((previousAngle ?? 0) - (angleAfter[position] ?? 0)), 1) + "°"
                : "?"
            out += "#   t=\(num(elapsedMs(row.monoNs), 1)) ms  w=\(num(row.width ?? 0, 0)) h=\(num(row.height ?? 0, 0))"
                + "  angle \(before) -> \(after)  (bracket \(bracket))\n"
        }

        out += "\n# Columns: t_ms is elapsed time from the first row, using a monotonic\n"
        out += "# clock that keeps running while the device is asleep. angle is in\n"
        out += "# degrees. A geometry row has no angle of its own: read the bracket\n"
        out += "# above to see which interval it fell into.\n"
        out += "\nseq\tevent\tt_ms\tangle_deg\tstatus\tw_pt\th_pt\tnote\n"
        for row in rows {
            let angle = row.angleDeg.map { num($0, 3) } ?? "-"
            let width = row.width.map { num($0, 0) } ?? "-"
            let height = row.height.map { num($0, 0) } ?? "-"
            let note = row.note.isEmpty ? "" : row.note.replacingOccurrences(of: "\t", with: " ")
            out += "\(row.seq)\t\(row.event.rawValue)\t\(num(elapsedMs(row.monoNs), 1))\t\(angle)\t"
                + "\(row.status?.rawValue ?? "-")\t\(width)\t\(height)\t\(note)\n"
        }
        return out
    }
}

private extension HingeRawRow.Event {
    static let allDisplayOrder: [HingeRawRow.Event] = [.hinge, .geom, .phase, .mark]
}

// MARK: - Host modifier

/// Subscribes once, at the root of the window, so a recording survives
/// navigation and does not depend on which example is on screen.
struct HingeRecordingHost: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onHingeChange { _, newContext in
                HingeRecorder.shared.ingest(hinge: newContext.hinge)
            }
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                HingeRecorder.shared.ingestGeometry(size)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: HingeRecorder.shared.ingestPhase("foreground")
                case .inactive: HingeRecorder.shared.ingestPhase("inactive")
                case .background: HingeRecorder.shared.ingestPhase("background")
                @unknown default: break
                }
            }
    }
}

// MARK: - Share

struct HingeShareRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Example

/// Records every hinge delivery on one timeline with display reconfigurations
/// and manual markers, then exports the session as CSV plus a readable TXT.
///
/// iOS keeps no history of hinge angles: an update is delivered once and is
/// gone. This screen is the only place the samples exist, which is why it
/// records at the app root and offers an explicit, file-backed session.
struct HingeRecorderExample: View {
    private var recorder: HingeRecorder { HingeRecorder.shared }

    @State private var note = ""
    @State private var share: HingeShareRequest?

    var body: some View {
        List {
            liveSection
            controlsSection
            exportSection
            guideSection
        }
        .listStyle(.insetGrouped)
        .sheet(item: $share) { request in
            ActivityView(items: request.urls)
                .ignoresSafeArea()
        }
    }

    // MARK: Live

    private var liveSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                VStack(spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(recorder.angleDegrees.map {
                            $0.formatted(.number.precision(.fractionLength(2)))
                        } ?? "--")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        Text("°")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Text(recorder.statusTag?.label ?? "No hinge reported")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(recorder.statusTag == nil ? .secondary : .primary)

                    if recorder.isRecording, let started = recorder.sessionStartedAt {
                        Text("● \(context.date.timeIntervalSince(started), format: .number.precision(.fractionLength(1))) s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.red)
                    }

                    Grid(horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            metric("Samples", "\(recorder.rowCount)")
                            metric("Last Δt", recorder.lastIntervalMs.map {
                                String(format: "%.1f ms", $0)
                            } ?? "—")
                        }
                    }
                    .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
        } header: {
            Text("Live")
        } footer: {
            Text("Refreshed at 2 Hz on purpose. The readouts are not observable state: redrawing them at the delivery rate would compete with the callback being measured.")
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Controls

    private var controlsSection: some View {
        Section {
            Button {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    recorder.start()
                }
            } label: {
                Label(recorder.isRecording ? "Stop & Save" : "Start Recording",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(recorder.isRecording ? .red : .accentColor)

            HStack {
                TextField("Marker label (optional)", text: $note)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Mark") {
                    recorder.mark(note)
                    note = ""
                }
                .disabled(!recorder.isRecording)
            }

            if let message = recorder.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Session")
        } footer: {
            Text(recorder.isRecording
                 ? "Tap Mark to stamp a moment while you fold. Recording keeps running when you leave this screen."
                 : "Recording is app-wide and file-backed: one session writes one CSV, flushed every second so a crash costs at most the tail.")
        }
    }

    // MARK: Exports

    private var exportSection: some View {
        Section {
            if recorder.exports.isEmpty {
                Text("No sessions yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recorder.exports) { export in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(export.csv.lastPathComponent)
                            .font(.callout.monospaced())
                        HStack {
                            Text(export.createdAt, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Share CSV + TXT", systemImage: "square.and.arrow.up") {
                                share = HingeShareRequest(urls: export.urls)
                            }
                            .font(.footnote)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Exports")
        } footer: {
            Text("Files stay in Documents/Exports and are listed here so nothing is lost if you forget to share on the spot. Sharing hands both files to the system sheet — WeChat File Transfer, Mail, or Save to Files all keep them as attachments. Turn on UIFileSharingEnabled (already set) to see them in the Files app.")
        }
    }

    // MARK: Guide

    private var guideSection: some View {
        Section("What to capture") {
            VStack(alignment: .leading, spacing: 10) {
                protocolRow("P1 Idle", "Hold at 90° for 10 s. Zero rows means delivery is change-driven, not periodic — no fixed sampling rate exists to assume.")
                protocolRow("P2 Slow sweep", "Sweep 0°→180° in about 5 s, three times. Gives delivery jitter and the smallest non-zero angle step.")
                protocolRow("P3 Fast flip", "Snap it open and shut in under 0.5 s, three times. Shows dropped samples and the largest single step.")
                protocolRow("Expect a gap", "Closer to 0° iOS locks the screen, so the tail of a fold is not recordable. Phase rows and gaps >200 ms mark it instead of faking continuity.")
            }
            .font(.footnote)
        }
    }

    private func protocolRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        HingeRecorderExample()
    }
}
