import AppKit

enum CloudLogRange: CaseIterable {
    case today
    case days7
    case days30

    var title: String {
        switch self {
        case .today:
            return "今日"
        case .days7:
            return "近7日"
        case .days30:
            return "近30日"
        }
    }
}

struct CloudRequestLogEntry {
    let rawLine: String
    let timestamp: Date?
    let status: String
    let durationSeconds: Double
    let latencyMs: Int
    let estimatedCostCNY: Double

    var isSuccess: Bool {
        status.uppercased().hasPrefix("OK")
    }
}

struct CloudRequestLogStats {
    let requestCount: Int
    let successCount: Int
    let totalDurationSeconds: Double
    let averageLatencyMs: Int
    let totalEstimatedCostCNY: Double

    static let zero = CloudRequestLogStats(
        requestCount: 0,
        successCount: 0,
        totalDurationSeconds: 0,
        averageLatencyMs: 0,
        totalEstimatedCostCNY: 0
    )
}

enum CloudRequestLogAnalyzer {
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let legacyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    static func parse(lines: [String], now: Date = Date()) -> [CloudRequestLogEntry] {
        lines.map { parse(line: $0, now: now) }
    }

    static func filteredEntries(
        from entries: [CloudRequestLogEntry],
        range: CloudLogRange,
        now: Date = Date()
    ) -> [CloudRequestLogEntry] {
        let calendar = Calendar.current
        let start: Date
        switch range {
        case .today:
            start = calendar.startOfDay(for: now)
        case .days7:
            start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .days30:
            start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        }
        return entries.filter { entry in
            guard let ts = entry.timestamp else { return false }
            return ts >= start && ts <= now.addingTimeInterval(120)
        }
    }

    static func stats(from entries: [CloudRequestLogEntry]) -> CloudRequestLogStats {
        guard !entries.isEmpty else { return .zero }
        let requestCount = entries.count
        let successCount = entries.filter(\.isSuccess).count
        let totalDuration = entries.reduce(0) { $0 + max(0, $1.durationSeconds) }
        let latencySum = entries.reduce(0) { $0 + max(0, $1.latencyMs) }
        let avgLatency = Int(Double(latencySum) / Double(requestCount))
        let totalCost = entries.reduce(0) { $0 + max(0, $1.estimatedCostCNY) }
        return CloudRequestLogStats(
            requestCount: requestCount,
            successCount: successCount,
            totalDurationSeconds: totalDuration,
            averageLatencyMs: avgLatency,
            totalEstimatedCostCNY: totalCost
        )
    }

    static func pruneOlderThan30Days(lines: [String], now: Date = Date()) -> (kept: [String], removed: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        var kept: [String] = []
        var removed = 0
        for line in lines {
            let entry = parse(line: line, now: now)
            if let ts = entry.timestamp, ts < cutoff {
                removed += 1
            } else {
                kept.append(line)
            }
        }
        return (kept, removed)
    }

    private static func parse(line: String, now: Date) -> CloudRequestLogEntry {
        let timestamp = parseTimestamp(from: line, now: now)
        let status = extractStatus(from: line)
        let durationSeconds = extractDouble(from: line, pattern: "音频([0-9]+(?:\\.[0-9]+)?)s") ?? 0
        let latencyMs = Int(extractDouble(from: line, pattern: "请求([0-9]+(?:\\.[0-9]+)?)ms") ?? 0)
        let estimatedCostCNY = extractDouble(from: line, pattern: "估算¥([0-9]+(?:\\.[0-9]+)?)") ?? 0
        return CloudRequestLogEntry(
            rawLine: line,
            timestamp: timestamp,
            status: status,
            durationSeconds: durationSeconds,
            latencyMs: latencyMs,
            estimatedCostCNY: estimatedCostCNY
        )
    }

    private static func parseTimestamp(from line: String, now: Date) -> Date? {
        guard let stamp = extractBracketContent(from: line) else { return nil }
        if let date = fullDateFormatter.date(from: stamp) {
            return date
        }
        guard let legacy = legacyDateFormatter.date(from: stamp) else { return nil }

        let calendar = Calendar.current
        let legacyParts = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: legacy)
        var components = DateComponents()
        components.year = calendar.component(.year, from: now)
        components.month = legacyParts.month
        components.day = legacyParts.day
        components.hour = legacyParts.hour
        components.minute = legacyParts.minute
        components.second = legacyParts.second

        guard var resolved = calendar.date(from: components) else { return nil }
        // Handle year cross-over for old MM-dd logs: if it lands in future, assume previous year.
        if resolved > now.addingTimeInterval(2 * 24 * 60 * 60) {
            resolved = calendar.date(byAdding: .year, value: -1, to: resolved) ?? resolved
        }
        return resolved
    }

    private static func extractBracketContent(from line: String) -> String? {
        guard let start = line.firstIndex(of: "["),
              let end = line[start...].firstIndex(of: "]"),
              end > start else {
            return nil
        }
        let value = line[line.index(after: start)..<end]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractStatus(from line: String) -> String {
        guard let end = line.firstIndex(of: "]") else { return "UNKNOWN" }
        let rest = line[line.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if let separatorRange = rest.range(of: " | ") {
            let status = rest[..<separatorRange.lowerBound]
            let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "UNKNOWN" : trimmed
        }
        return rest.isEmpty ? "UNKNOWN" : rest
    }

    private static func extractDouble(from text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        let value = nsText.substring(with: match.range(at: 1))
        return Double(value)
    }
}

@MainActor
final class CloudLogViewerWindowController: NSWindowController {
    private let logsProvider: () -> [String]
    private let onLogsUpdated: ([String]) -> Void

    private let rangePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statsLabel = NSTextField(wrappingLabelWithString: "")
    private let logTextView = NSTextView(frame: .zero)
    private let clearOldButton = NSButton(title: "清理30天前日志", target: nil, action: nil)

    init(
        logsProvider: @escaping () -> [String],
        onLogsUpdated: @escaping ([String]) -> Void
    ) {
        self.logsProvider = logsProvider
        self.onLogsUpdated = onLogsUpdated

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "云端请求日志"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        super.init(window: panel)
        configureUI(in: panel)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPanel(relativeTo parent: NSWindow?) {
        guard let window else { return }
        refresh()
        if let parent {
            parent.addChildWindow(window, ordered: .above)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        let now = Date()
        let lines = logsProvider()
        let entries = CloudRequestLogAnalyzer.parse(lines: lines, now: now)
        let range = selectedRange()
        let filtered = CloudRequestLogAnalyzer.filteredEntries(from: entries, range: range, now: now)
        let stats = CloudRequestLogAnalyzer.stats(from: filtered)

        let successRate: String
        if stats.requestCount > 0 {
            let value = Double(stats.successCount) / Double(stats.requestCount) * 100
            successRate = String(format: "%.1f%%", value)
        } else {
            successRate = "0.0%"
        }

        statsLabel.stringValue = """
        请求数：\(stats.requestCount)（成功\(stats.successCount)，成功率\(successRate)）
        音频总时长：\(String(format: "%.1f", stats.totalDurationSeconds))s    平均请求耗时：\(stats.averageLatencyMs)ms
        估算总费用：¥\(String(format: "%.4f", stats.totalEstimatedCostCNY))
        """

        logTextView.string = filtered.isEmpty ? "该时间范围暂无日志。" : filtered.map(\.rawLine).joined(separator: "\n")
    }

    private func configureUI(in panel: NSPanel) {
        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        rangePopup.addItems(withTitles: CloudLogRange.allCases.map(\.title))
        rangePopup.selectItem(at: 0)
        rangePopup.target = self
        rangePopup.action = #selector(rangeChanged)
        rangePopup.controlSize = .small

        clearOldButton.target = self
        clearOldButton.action = #selector(clearOldLogsTapped)
        clearOldButton.controlSize = .small

        let rangeLabel = NSTextField(labelWithString: "统计范围")
        rangeLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let topRow = NSStackView(views: [rangeLabel, rangePopup, NSView(), clearOldButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8
        topRow.translatesAutoresizingMaskIntoConstraints = false

        statsLabel.font = .systemFont(ofSize: 12)
        statsLabel.textColor = .labelColor
        statsLabel.lineBreakMode = .byWordWrapping
        statsLabel.maximumNumberOfLines = 0
        statsLabel.translatesAutoresizingMaskIntoConstraints = false

        let statsBox = NSBox()
        statsBox.titlePosition = .noTitle
        statsBox.boxType = .custom
        statsBox.borderWidth = 1
        statsBox.cornerRadius = 8
        statsBox.borderColor = NSColor.separatorColor.withAlphaComponent(0.6)
        statsBox.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35)
        statsBox.contentViewMargins = NSSize(width: 10, height: 8)
        statsBox.translatesAutoresizingMaskIntoConstraints = false
        statsBox.contentView?.addSubview(statsLabel)

        if let statsContent = statsBox.contentView {
            NSLayoutConstraint.activate([
                statsLabel.leadingAnchor.constraint(equalTo: statsContent.leadingAnchor),
                statsLabel.trailingAnchor.constraint(equalTo: statsContent.trailingAnchor),
                statsLabel.topAnchor.constraint(equalTo: statsContent.topAnchor),
                statsLabel.bottomAnchor.constraint(equalTo: statsContent.bottomAnchor)
            ])
        }

        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.isHorizontallyResizable = false
        logTextView.isVerticallyResizable = true
        logTextView.backgroundColor = .clear
        logTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.textContainerInset = NSSize(width: 4, height: 6)
        logTextView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.documentView = logTextView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [topRow, statsBox, scroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            statsBox.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            rangePopup.widthAnchor.constraint(equalToConstant: 110)
        ])
    }

    private func selectedRange() -> CloudLogRange {
        switch rangePopup.indexOfSelectedItem {
        case 1:
            return .days7
        case 2:
            return .days30
        default:
            return .today
        }
    }

    @objc
    private func rangeChanged() {
        refresh()
    }

    @objc
    private func clearOldLogsTapped() {
        let result = CloudRequestLogAnalyzer.pruneOlderThan30Days(lines: logsProvider())
        onLogsUpdated(result.kept)
        refresh()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "清理完成"
        alert.informativeText = "已清理 \(result.removed) 条 30 天前日志。"
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}
