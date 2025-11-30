import Cocoa
import UniformTypeIdentifiers

protocol StatsWindowControllerDelegate: AnyObject {
    func statsWindowController(_ controller: StatsWindowController, didSelect preset: TimeRangePreset)
}

enum TimeRangePreset: CaseIterable {
    case lastHour
    case today
    case last7Days
    case last30Days
    case last90Days
    case last365Days

    static var defaultPreset: TimeRangePreset { .today }

    var title: String {
        switch self {
        case .lastHour:
            return "Last Hour"
        case .today:
            return "Today"
        case .last7Days:
            return "Last 7 Days"
        case .last30Days:
            return "Last 30 Days"
        case .last90Days:
            return "Last 90 Days"
        case .last365Days:
            return "Last 365 Days"
        }
    }

    func interval(referenceDate: Date = Date(), calendar: Calendar = Calendar.current) -> DateInterval {
        let end = referenceDate
        let start: Date
        switch self {
        case .lastHour:
            start = calendar.date(byAdding: .hour, value: -1, to: end) ?? end
        case .today:
            start = calendar.startOfDay(for: end)
        case .last7Days:
            start = calendar.date(byAdding: .day, value: -7, to: end) ?? end
        case .last30Days:
            start = calendar.date(byAdding: .day, value: -30, to: end) ?? end
        case .last90Days:
            start = calendar.date(byAdding: .day, value: -90, to: end) ?? end
        case .last365Days:
            start = calendar.date(byAdding: .day, value: -365, to: end) ?? end
        }
        return DateInterval(start: min(start, end), end: end)
    }

    var storageKey: String {
        switch self {
        case .lastHour: return "lastHour"
        case .today: return "today"
        case .last7Days: return "last7Days"
        case .last30Days: return "last30Days"
        case .last90Days: return "last90Days"
        case .last365Days: return "last365Days"
        }
    }

    static func fromStorageKey(_ key: String) -> TimeRangePreset? {
        switch key {
        case "lastHour": return .lastHour
        case "today": return .today
        case "last7Days": return .last7Days
        case "last30Days": return .last30Days
        case "last90Days": return .last90Days
        case "last365Days": return .last365Days
        default: return nil
        }
    }
}

final class StatsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let presets = TimeRangePreset.allCases
    private let filterPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let infoLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
    private let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return formatter
    }()
    private var frequencies: [KeyFrequency] = []
    private var totalCount: Int = 0
    private var store: KeypressStore?
    private var presetSelection: TimeRangePreset
    weak var delegate: StatsWindowControllerDelegate?

    init(store: KeypressStore?, initialPreset: TimeRangePreset, delegate: StatsWindowControllerDelegate?) {
        self.store = store
        self.presetSelection = initialPreset
        self.delegate = delegate
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let width = max(600, screenFrame.width * 0.5)
        let height = max(420, screenFrame.height * 0.5)
        let origin = NSPoint(
            x: screenFrame.midX - (width / 2),
            y: screenFrame.midY - (height / 2)
        )
        let windowRect = NSRect(origin: origin, size: NSSize(width: width, height: height))
        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keydometer – Key Statistics"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        setupContent()
        populateFilter()
        applyPresetSelection(refresh: false, notifyDelegate: false)
        refreshData()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var currentPreset: TimeRangePreset {
        return presetSelection
    }

    func setStore(_ store: KeypressStore) {
        self.store = store
        refreshData()
    }

    func refreshVisibleContent() {
        guard window?.isVisible == true else { return }
        refreshData()
    }

    func synchronizeSelectedPreset(_ preset: TimeRangePreset) {
        guard preset != presetSelection else { return }
        presetSelection = preset
        applyPresetSelection(refresh: window?.isVisible == true, notifyDelegate: false)
    }

    func refreshData() {
        guard let store = store else {
            frequencies = []
            tableView.reloadData()
            infoLabel.stringValue = "No data available"
            return
        }

        let interval = currentPreset.interval()
        let snapshot = store.fetchKeyFrequencies(in: interval)
        frequencies = snapshot
        totalCount = snapshot.reduce(0) { $0 + $1.count }
        tableView.reloadData()
        let formattedTotal = numberFormatter.string(from: NSNumber(value: totalCount)) ?? "\(totalCount)"
        infoLabel.stringValue = "\(currentPreset.title): \(formattedTotal) keypresses"
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return frequencies.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < frequencies.count else { return nil }
        let frequency = frequencies[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier(rawValue: "Cell")
        let value: String
        switch identifier.rawValue {
        case "RankColumn":
            value = "\(row + 1)"
        case "KeyColumn":
            value = displayName(for: frequency.key)
        case "CountColumn":
            value = numberFormatter.string(from: NSNumber(value: frequency.count)) ?? "\(frequency.count)"
        case "PercentColumn":
            value = percentDisplay(for: frequency.count)
        case "CategoryColumn":
            value = categoryLabel(for: frequency.key)
        default:
            value = ""
        }

        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? createCell(identifier: identifier)
        cell.textField?.stringValue = value
        return cell
    }

    // MARK: - Private helpers

    private func setupContent() {
        guard let contentView = window?.contentView else { return }

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        let controlsStack = NSStackView()
        controlsStack.orientation = .horizontal
        controlsStack.spacing = 8
        controlsStack.alignment = .centerY

        let filterLabel = NSTextField(labelWithString: "Time Range:")
        controlsStack.addArrangedSubview(filterLabel)
        controlsStack.addArrangedSubview(filterPopUp)
        infoLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        controlsStack.addArrangedSubview(infoLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsStack.addArrangedSubview(spacer)

        let exportButton = NSButton(title: "Export CSV", target: self, action: #selector(exportToCSV))
        exportButton.bezelStyle = .rounded
        controlsStack.addArrangedSubview(exportButton)

        rootStack.addArrangedSubview(controlsStack)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        rootStack.addArrangedSubview(scrollView)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let columns: [(identifier: String, title: String, width: CGFloat)] = [
            ("RankColumn", "#", 40),
            ("KeyColumn", "Key", 120),
            ("CountColumn", "Count", 100),
            ("PercentColumn", "% of Range", 120),
            ("CategoryColumn", "Group", 140)
        ]

        for columnInfo in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(columnInfo.identifier))
            column.title = columnInfo.title
            column.width = columnInfo.width
            tableView.addTableColumn(column)
        }
    }

    private func populateFilter() {
        filterPopUp.removeAllItems()
        presets.forEach { filterPopUp.addItem(withTitle: $0.title) }
        applyPresetSelection(refresh: false, notifyDelegate: false)
        filterPopUp.target = self
        filterPopUp.action = #selector(presetSelectionChanged)
    }

    private func createCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func displayName(for key: String) -> String {
        return key
    }

    private func percentDisplay(for count: Int) -> String {
        guard totalCount > 0 else { return "0%" }
        let fraction = Double(count) / Double(totalCount)
        return percentFormatter.string(from: NSNumber(value: fraction)) ?? String(format: "%.1f%%", fraction * 100)
    }

    private func categoryLabel(for key: String) -> String {
        if key.count == 1, let scalar = key.unicodeScalars.first, (65...90).contains(Int(scalar.value)) {
            return "Letter"
        }
        return "Symbol / Other"
    }

    private func applyPresetSelection(refresh: Bool, notifyDelegate: Bool) {
        if let index = presets.firstIndex(of: presetSelection) {
            filterPopUp.selectItem(at: index)
        } else if let first = presets.first {
            presetSelection = first
            filterPopUp.selectItem(at: 0)
        }
        if refresh {
            refreshData()
        }
        if notifyDelegate {
            delegate?.statsWindowController(self, didSelect: presetSelection)
        }
    }

    private func presetForCurrentSelection() -> TimeRangePreset {
        let index = filterPopUp.indexOfSelectedItem
        if index >= 0 && index < presets.count {
            return presets[index]
        }
        return presets.first ?? .today
    }

    @objc private func presetSelectionChanged() {
        presetSelection = presetForCurrentSelection()
        refreshData()
        delegate?.statsWindowController(self, didSelect: presetSelection)
    }

    @objc private func exportToCSV() {
        guard !frequencies.isEmpty else {
            presentAlert(
                title: "No data to export",
                message: "Select a time range that contains keypresses before exporting."
            )
            return
        }
        guard let window = window else { return }

        let panel = NSSavePanel()
        panel.title = "Export Key Statistics"
        panel.nameFieldStringValue = suggestedFileName()
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType.commaSeparatedText]
        } else {
            panel.allowedFileTypes = ["csv"]
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writeCSV(to: url)
        }
    }

    private func writeCSV(to url: URL) {
        let csv = buildCSVString()
        do {
            try csv.data(using: .utf8)?.write(to: url)
        } catch {
            presentAlert(title: "Export failed", message: error.localizedDescription)
        }
    }

    private func buildCSVString() -> String {
        var lines: [String] = []
        lines.append("Rank,Key,Count,Percent,Category")
        for (index, frequency) in frequencies.enumerated() {
            let columns = [
                "\(index + 1)",
                escapeCSV(displayName(for: frequency.key)),
                "\(frequency.count)",
                escapeCSV(percentDisplay(for: frequency.count)),
                escapeCSV(categoryLabel(for: frequency.key))
            ]
            lines.append(columns.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private func suggestedFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let presetName = currentPreset.title.replacingOccurrences(of: " ", with: "-")
        return "KeyStats-\(presetName)-\(timestamp).csv"
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

}
