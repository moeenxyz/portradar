import AppKit
import Darwin
import Foundation
import ServiceManagement

struct ManagedService: Hashable, Sendable {
    let label: String
    let domain: String
}

struct ProcessMetadata: Sendable {
    let parentPID: Int
    let args: String
    let currentWorkingDirectory: String?
}

struct PortRecord: Hashable, Sendable {
    let port: Int
    let processName: String
    let appName: String
    let pid: Int
    let managedService: ManagedService?
}

struct PortSnapshot: Sendable {
    let records: [PortRecord]
    let refreshedAt: Date
    let errorMessage: String?
}

struct PortScanner: Sendable {
    func scan() -> PortSnapshot {
        do {
            let outputData = try runCommand(
                executablePath: "/usr/sbin/lsof",
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]
            )
            let output = String(decoding: outputData, as: UTF8.self)
            let baseRecords = parse(output: output)
            let records = enrich(records: baseRecords)
            return PortSnapshot(records: records, refreshedAt: Date(), errorMessage: nil)
        } catch {
            return PortSnapshot(records: [], refreshedAt: Date(), errorMessage: error.localizedDescription)
        }
    }

    private func parse(output: String) -> [PortRecord] {
        var records: [PortRecord] = []
        var seen = Set<String>()
        var currentPID: Int?
        var currentCommand = "-"

        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let prefix = rawLine.first else {
                continue
            }

            let value = String(rawLine.dropFirst())

            switch prefix {
            case "p":
                currentPID = Int(value)
                currentCommand = "-"
            case "c":
                currentCommand = value.isEmpty ? "-" : value
            case "n":
                guard
                    let pid = currentPID,
                    let port = extractPort(from: value)
                else {
                    continue
                }

                let key = "\(pid)-\(port)"
                guard seen.insert(key).inserted else {
                    continue
                }

                let appName = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "-"
                records.append(
                    PortRecord(
                        port: port,
                        processName: currentCommand,
                        appName: appName,
                        pid: pid,
                        managedService: nil
                    )
                )
            default:
                continue
            }
        }

        return records.sorted {
            if $0.port != $1.port {
                return $0.port < $1.port
            }

            if $0.processName != $1.processName {
                return $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending
            }

            return $0.pid < $1.pid
        }
    }

    private func extractPort(from endpoint: String) -> Int? {
        guard let portText = endpoint.split(separator: ":").last else {
            return nil
        }

        return Int(portText)
    }

    private func enrich(records: [PortRecord]) -> [PortRecord] {
        let pids = records.map(\.pid)
        let processMetadata = processMetadataMap(for: pids)
        let launchdManagedPIDs = Set(
            processMetadata.compactMap { pid, metadata in
                metadata.parentPID == 1 ? pid : nil
            }
        )
        let managedServices = managedServiceMap(for: launchdManagedPIDs)

        return records.map { record in
            let managedService = managedServices[record.pid]
            return PortRecord(
                port: record.port,
                processName: record.processName,
                appName: inferredAppName(for: record, metadata: processMetadata) ?? managedService?.label ?? record.appName,
                pid: record.pid,
                managedService: managedService
            )
        }
    }

    private func processMetadataMap(for pids: [Int]) -> [Int: ProcessMetadata] {
        guard !pids.isEmpty else {
            return [:]
        }

        let pidArgument = pids.map(String.init).joined(separator: ",")
        let currentWorkingDirectories = currentWorkingDirectoryMap(for: pids)

        do {
            let data = try runCommand(
                executablePath: "/bin/ps",
                arguments: ["-o", "pid=,ppid=,args=", "-p", pidArgument]
            )
            let output = String(decoding: data, as: UTF8.self)
            var result: [Int: ProcessMetadata] = [:]

            for line in output.split(whereSeparator: \.isNewline) {
                let columns = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
                guard
                    columns.count >= 2,
                    let pid = Int(columns[0]),
                    let parentPID = Int(columns[1])
                else {
                    continue
                }

                let args = columns.count == 3 ? String(columns[2]) : ""
                result[pid] = ProcessMetadata(
                    parentPID: parentPID,
                    args: args,
                    currentWorkingDirectory: currentWorkingDirectories[pid]
                )
            }

            return result
        } catch {
            return [:]
        }
    }

    private func inferredAppName(for record: PortRecord, metadata: [Int: ProcessMetadata]) -> String? {
        if record.appName != "-" {
            return record.appName
        }

        var currentPID: Int? = record.pid
        var visited = Set<Int>()

        while let pid = currentPID, visited.insert(pid).inserted, let process = metadata[pid] {
            if let bundlePath = extractAppBundlePath(from: process.args) {
                return bundleDisplayName(at: bundlePath)
            }

            if let cwd = process.currentWorkingDirectory, !cwd.isEmpty {
                return projectDisplayName(from: cwd)
            }

            currentPID = process.parentPID > 1 ? process.parentPID : nil
        }

        return nil
    }

    private func extractAppBundlePath(from args: String) -> String? {
        guard let range = args.range(of: #"/.+?\.app"#, options: .regularExpression) else {
            return nil
        }

        var candidate = String(args[range])

        while candidate.hasSuffix("/") {
            candidate.removeLast()
        }

        return candidate
    }

    private func bundleDisplayName(at path: String) -> String {
        let bundleURL = URL(fileURLWithPath: path)

        if let bundle = Bundle(url: bundleURL) {
            if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !displayName.isEmpty {
                return displayName
            }

            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
        }

        return bundleURL.deletingPathExtension().lastPathComponent
    }

    private func currentWorkingDirectoryMap(for pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else {
            return [:]
        }

        let pidArgument = pids.map(String.init).joined(separator: ",")

        do {
            let data = try runCommand(
                executablePath: "/usr/sbin/lsof",
                arguments: ["-a", "-p", pidArgument, "-d", "cwd", "-Fn"]
            )
            let output = String(decoding: data, as: UTF8.self)
            var result: [Int: String] = [:]
            var currentPID: Int?

            for line in output.split(whereSeparator: \.isNewline) {
                guard let prefix = line.first else {
                    continue
                }

                let value = String(line.dropFirst())

                switch prefix {
                case "p":
                    currentPID = Int(value)
                case "n":
                    if let currentPID {
                        result[currentPID] = value
                    }
                default:
                    continue
                }
            }

            return result
        } catch {
            return [:]
        }
    }

    private func projectDisplayName(from cwd: String) -> String {
        let url = URL(fileURLWithPath: cwd)
        let last = url.lastPathComponent
        let previous = url.deletingLastPathComponent().lastPathComponent
        let genericNames = Set(["app", "apps", "api", "backend", "frontend", "server", "services", "web"])

        if genericNames.contains(last.lowercased()), !previous.isEmpty {
            return "\(previous)/\(last)"
        }

        return last
    }

    private func managedServiceMap(for pids: Set<Int>) -> [Int: ManagedService] {
        guard !pids.isEmpty else {
            return [:]
        }

        var result = parseLaunchctlDomain(domain: "gui/\(getuid())", candidatePIDs: pids)
        let unresolved = pids.subtracting(result.keys)

        if !unresolved.isEmpty {
            result.merge(parseLaunchctlDomain(domain: "system", candidatePIDs: unresolved)) { current, _ in current }
        }

        return result
    }

    private func parseLaunchctlDomain(domain: String, candidatePIDs: Set<Int>) -> [Int: ManagedService] {
        guard !candidatePIDs.isEmpty else {
            return [:]
        }

        do {
            let data = try runCommand(
                executablePath: "/bin/launchctl",
                arguments: ["print", domain]
            )
            let output = String(decoding: data, as: UTF8.self)
            var result: [Int: ManagedService] = [:]

            for line in output.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let columns = trimmed.split(whereSeparator: \.isWhitespace)

                guard
                    columns.count >= 3,
                    let pid = Int(columns[0]),
                    candidatePIDs.contains(pid)
                else {
                    continue
                }

                let label = String(columns[2])
                result[pid] = ManagedService(label: label, domain: domain)
            }

            return result
        } catch {
            return [:]
        }
    }

    private func runCommand(executablePath: String, arguments: [String]) throws -> Data {
        let task = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = arguments
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        try task.run()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "PortScanner",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "\(executablePath) exited with code \(task.terminationStatus)"]
            )
        }

        return outputData
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Layout {
        static let maxVisibleNameLength = 20
        static let minimumMenuWidth: CGFloat = 620
        static let portTab: CGFloat = 72
        static let processTab: CGFloat = 240
        static let appTab: CGFloat = 430
        static let actionTab: CGFloat = 590
    }

    private let scanner = PortScanner()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    private var statusItem: NSStatusItem?
    private var menu = NSMenu()
    private var latestSnapshot = PortSnapshot(records: [], refreshedAt: Date(), errorMessage: nil)
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private var launchesAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Ports"
        item.button?.toolTip = "Show listening local ports"
        item.menu = menu
        menu.minimumWidth = Layout.minimumMenuWidth

        menu.delegate = self
        statusItem = item

        refreshLaunchAtLoginState()
        rebuildMenu()
        refreshPorts()

        refreshTimer = Timer.scheduledTimer(
            timeInterval: 30,
            target: self,
            selector: #selector(refreshTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPorts()
    }

    @objc private func refreshTimerFired() {
        refreshPorts()
    }

    @objc private func refreshNow() {
        refreshPorts(force: true)
    }

    @objc private func forceCloseFromMenuItem(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? PortRecord else {
            return
        }

        if let service = record.managedService {
            confirmStopService(service, for: record)
        } else {
            confirmForceClose(for: record)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard isRunningAsBundledApp else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Launch at login needs the app bundle"
            alert.informativeText = "Use PortCheck.app from the dist folder or move it into Applications, then enable this option again."
            alert.runModal()
            return
        }

        do {
            if launchesAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Unable to update launch at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }

        refreshLaunchAtLoginState()
        rebuildMenu()

        if SMAppService.mainApp.status == .requiresApproval {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Approval needed"
            alert.informativeText = "macOS may ask you to approve PortCheck in System Settings > General > Login Items."
            alert.runModal()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func confirmForceClose(for record: PortRecord) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Force close \(record.processName)?"
        alert.informativeText = "This will kill PID \(record.pid) listening on port \(record.port). Unsaved work may be lost."
        alert.addButton(withTitle: "Force Close")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        guard kill(pid_t(record.pid), SIGKILL) == 0 else {
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .critical
            errorAlert.messageText = "Unable to force close \(record.processName)"
            errorAlert.informativeText = String(cString: strerror(errno))
            errorAlert.runModal()
            return
        }

        refreshPorts(force: true)
    }

    private func confirmStopService(_ service: ManagedService, for record: PortRecord) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop service \(service.label)?"
        alert.informativeText = "\(record.processName) on port \(record.port) is managed by launchd. Stopping the service prevents it from being immediately respawned."
        alert.addButton(withTitle: "Stop Service")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return
        }

        do {
            try runCommand(executablePath: "/bin/launchctl", arguments: ["bootout", "\(service.domain)/\(service.label)"])
            refreshPorts(force: true)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.alertStyle = .critical
            errorAlert.messageText = "Unable to stop service \(service.label)"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.runModal()
        }
    }

    private func refreshPorts(force: Bool = false) {
        guard force || !isRefreshing else {
            return
        }

        isRefreshing = true
        let portScanner = scanner

        Task.detached(priority: .utility) {
            let snapshot = portScanner.scan()

            await MainActor.run {
                self.latestSnapshot = snapshot
                self.isRefreshing = false
                self.rebuildMenu()
            }
        }
    }

    private var isRunningAsBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func refreshLaunchAtLoginState() {
        guard isRunningAsBundledApp else {
            launchesAtLogin = false
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            launchesAtLogin = true
        case .notRegistered, .requiresApproval, .notFound:
            launchesAtLogin = false
        @unknown default:
            launchesAtLogin = false
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.minimumWidth = Layout.minimumMenuWidth

        let header = NSMenuItem()
        header.attributedTitle = styledTitle("PORT\tPROCESS\tAPP\tACTION")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let errorMessage = latestSnapshot.errorMessage {
            let item = NSMenuItem(title: "Error: \(errorMessage)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if latestSnapshot.records.isEmpty {
            let item = NSMenuItem(title: "No listening TCP ports found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for record in latestSnapshot.records {
                let item = NSMenuItem(title: "", action: #selector(forceCloseFromMenuItem(_:)), keyEquivalent: "")
                item.attributedTitle = styledRecordTitle(for: record)
                item.representedObject = record
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let refreshedItem = NSMenuItem(
            title: "Updated \(dateFormatter.string(from: latestSnapshot.refreshedAt))",
            action: nil,
            keyEquivalent: ""
        )
        refreshedItem.isEnabled = false
        menu.addItem(refreshedItem)

        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = launchesAtLogin ? .on : .off
        menu.addItem(launchAtLoginItem)

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.button?.title = latestSnapshot.records.isEmpty ? "Ports" : "Ports \(latestSnapshot.records.count)"
    }

    private func styledTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .paragraphStyle: menuParagraphStyle(),
            ]
        )
    }

    private func styledRecordTitle(for record: PortRecord) -> NSAttributedString {
        let portText = String(record.port)
        let processText = truncated(record.processName)
        let appText = truncated(record.appName)
        let actionText = record.managedService == nil ? "Force Close" : "Stop Service"
        let fullText = "\(portText)\t\(processText)\t\(appText)\t\(actionText)"

        let attributed = NSMutableAttributedString(
            string: fullText,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: menuParagraphStyle(),
            ]
        )

        attributed.addAttributes(
            [
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.95),
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            ],
            range: NSRange(location: 0, length: portText.count)
        )

        let actionRange = (fullText as NSString).range(of: actionText)
        attributed.addAttributes(
            [
                .foregroundColor: record.managedService == nil ? NSColor.systemRed : NSColor.systemOrange,
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            ],
            range: actionRange
        )

        return attributed
    }

    private func menuParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = 0
        style.tabStops = [
            NSTextTab(textAlignment: .left, location: Layout.portTab),
            NSTextTab(textAlignment: .left, location: Layout.processTab),
            NSTextTab(textAlignment: .left, location: Layout.appTab),
            NSTextTab(textAlignment: .right, location: Layout.actionTab),
        ]
        return style
    }

    private func truncated(_ text: String) -> String {
        guard text.count > Layout.maxVisibleNameLength else {
            return text
        }

        return String(text.prefix(Layout.maxVisibleNameLength - 3)) + "..."
    }

    private func runCommand(executablePath: String, arguments: [String]) throws {
        let task = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = arguments
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        try task.run()

        _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "AppDelegate",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "\(executablePath) exited with code \(task.terminationStatus)"]
            )
        }
    }
}

@main
enum PortCheckApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
