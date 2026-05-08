import AppKit
import ApplicationServices
import CoreServices
import Crypto
import Foundation

public struct ComputerUseSnapshotMetadata: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var appName: String
    public var bundleID: String
    public var pid: pid_t
    public var windowTitle: String
    public var windowID: Int
    public var windowFrame: CGRectCodable
    public var screenshotPath: String?
    public var screenshotSize: CGSizeCodable?
    public var fingerprint: String
    public var nodeSignatures: [CachedNodeSignature]
}

public struct CachedNodeSignature: Codable, Equatable, Sendable {
    public var depth: Int
    public var role: String
    public var subrole: String
    public var title: String
    public var description: String?
    public var identifier: String
    public var childIndexAmongSameRole: Int
}

public struct CGRectCodable: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct CGSizeCodable: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

public enum ComputerUseError: Error, CustomStringConvertible {
    case accessibilityPermissionDenied
    case appNotFound(String)
    case appNotRunning(String)
    case windowNotFound(app: String, title: String?)
    case snapshotNotFound(String)
    case staleState(appName: String)
    case screenshotUnavailable(windowID: Int)
    case coordinateActionRequiresScreenshot
    case elementNotFound(Int)
    case elementFrameUnavailable(Int)
    case elementNotSettable(Int)
    case elementNotScrollable(Int)
    case focusedElementUnavailable
    case secondaryActionNotFound(elementIndex: Int, action: String)
    case unsupportedKey(String)
    case invalidArgument(String)
    case snapshotStoreFailure(String)

    public var description: String {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required. Grant Accessibility access to the current KW process in System Settings > Privacy & Security > Accessibility."
        case let .appNotFound(app):
            return "appNotFound \(app)"
        case let .appNotRunning(app):
            return "appNotRunning \(app)"
        case let .windowNotFound(app, title):
            if let title, title.isEmpty == false {
                return "windowNotFound app=\(app) title~\"\(title)\""
            }
            return "windowNotFound app=\(app)"
        case let .snapshotNotFound(id):
            return "snapshotNotFound \(id)"
        case let .staleState(appName):
            return "The user changed '\(appName)'. Re-query the latest state with get-app-state before sending more actions."
        case let .screenshotUnavailable(windowID):
            return "screenshotUnavailable windowID=\(windowID)"
        case .coordinateActionRequiresScreenshot:
            return "coordinateActionRequiresScreenshot: call get-app-state with include_screenshot=true before coordinate click/drag"
        case let .elementNotFound(index):
            return "elementNotFound \(index)"
        case let .elementFrameUnavailable(index):
            return "elementFrameUnavailable \(index)"
        case let .elementNotSettable(index):
            return "elementNotSettable \(index)"
        case let .elementNotScrollable(index):
            return "elementNotScrollable \(index)"
        case .focusedElementUnavailable:
            return "focusedElementUnavailable"
        case let .secondaryActionNotFound(elementIndex, action):
            return "secondaryActionNotFound element=\(elementIndex) action=\"\(action)\""
        case let .unsupportedKey(key):
            return "unsupportedKey \(key)"
        case let .invalidArgument(message):
            return "invalidArgument \(message)"
        case let .snapshotStoreFailure(message):
            return "snapshotStoreFailure \(message)"
        }
    }
}

public struct RunningAppDescriptor: Equatable, Sendable {
    public var name: String
    public var bundleID: String
    public var pid: pid_t
    public var isActive: Bool
}

public struct ComputerUseAppDescriptor: Equatable, Sendable {
    public var name: String
    public var bundleID: String
    public var pid: pid_t?
    public var isRunning: Bool
    public var isFrontmost: Bool
    public var lastUsedDate: Date?
    public var useCount: Int?
}

struct RunningWindowDescriptor: Equatable, Sendable {
    var appName: String
    var bundleID: String
    var pid: pid_t
    var windowID: Int
    var title: String
    var isMain: Bool
}

public struct ComputerUseCommandOutput: Codable, Sendable {
    public var text: String
    public var metadata: ComputerUseSnapshotMetadata?

    public init(text: String, metadata: ComputerUseSnapshotMetadata? = nil) {
        self.text = text
        self.metadata = metadata
    }
}

struct CUWindowSnapshot {
    let windowID: Int
    let ownerName: String
    let name: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

struct RuntimeAXNode {
    let index: Int
    let depth: Int
    let element: AXUIElement
    let role: String
    let subrole: String
    let title: String
    let description: String
    let value: Any?
    let help: String
    let identifier: String
    let url: URL?
    let enabled: Bool?
    let selected: Bool?
    let expanded: Bool?
    let focused: Bool?
    let frame: CGRect?
    let actions: [String]
    let isValueSettable: Bool
    let valueTypeDescription: String?
}

struct RuntimeAppSnapshot {
    let app: NSRunningApplication
    let appElement: AXUIElement
    let windowElement: AXUIElement
    let windowID: Int
    let windowTitle: String
    let windowFrame: CGRect
    let nodes: [RuntimeAXNode]
    let focusedElementIndex: Int?
    let selectedText: String?
    let screenshotURL: URL?
    let screenshotSize: CGSize?
    let fingerprint: String

    func node(index: Int) throws -> RuntimeAXNode {
        guard let node = nodes.first(where: { $0.index == index }) else {
            throw ComputerUseError.elementNotFound(index)
        }
        return node
    }
}

private struct WindowCandidate {
    let element: AXUIElement
    let title: String
    let frame: CGRect
    let cgWindow: CUWindowSnapshot
    let isMain: Bool
    let isFocused: Bool
}

private struct PopupMenuCandidate {
    let element: AXUIElement
    let frame: CGRect
}

struct WindowSelection {
    var titleSubstring: String?
}

struct ComputerUseSnapshotFile: Codable {
    var metadata: ComputerUseSnapshotMetadata
}

enum ComputerUseSnapshotStore {
    static var rootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "kwwk-computer-use",
            isDirectory: true
        )
    }

    static func ensureRootDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    static func metadataURL(for snapshotID: String) -> URL {
        rootURL.appendingPathComponent("\(snapshotID).json")
    }

    static func screenshotURL(for snapshotID: String, pathExtension: String = "png") -> URL {
        let ext = pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "png"
            : pathExtension
        return rootURL.appendingPathComponent("\(snapshotID).\(ext)")
    }

    static func save(snapshot: RuntimeAppSnapshot) throws -> ComputerUseSnapshotMetadata {
        try ensureRootDirectory()

        let snapshotID = UUID().uuidString.lowercased()
        let screenshotPath: String?
        let screenshotSize: CGSizeCodable?

        if let sourceScreenshotURL = snapshot.screenshotURL {
            let targetURL = screenshotURL(
                for: snapshotID,
                pathExtension: sourceScreenshotURL.pathExtension
            )
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: sourceScreenshotURL, to: targetURL)
            screenshotPath = targetURL.path
            screenshotSize = snapshot.screenshotSize.map(CGSizeCodable.init)
        } else {
            screenshotPath = nil
            screenshotSize = nil
        }

        let metadata = ComputerUseSnapshotMetadata(
            id: snapshotID,
            createdAt: Date(),
            appName: snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "Unknown",
            bundleID: snapshot.app.bundleIdentifier ?? "",
            pid: snapshot.app.processIdentifier,
            windowTitle: snapshot.windowTitle,
            windowID: snapshot.windowID,
            windowFrame: CGRectCodable(snapshot.windowFrame),
            screenshotPath: screenshotPath,
            screenshotSize: screenshotSize,
            fingerprint: snapshot.fingerprint,
            nodeSignatures: nodeSignatures(for: snapshot.nodes)
        )

        let data = try JSONEncoder.computerUse.encode(ComputerUseSnapshotFile(metadata: metadata))
        try data.write(to: metadataURL(for: snapshotID), options: .atomic)
        return metadata
    }

    static func load(snapshotID: String) throws -> ComputerUseSnapshotMetadata {
        let url = metadataURL(for: snapshotID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ComputerUseError.snapshotNotFound(snapshotID)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.computerUse.decode(ComputerUseSnapshotFile.self, from: data).metadata
    }
}

enum ComputerUseCore {
    static func startupInventoryText() -> String {
        let apps = listRunningApps()
        guard apps.isEmpty == false else {
            return ""
        }

        var lines = [
            "Startup macOS app/window inventory.",
            "<computer_use_inventory>",
            "<apps>",
        ]

        lines.append(contentsOf: apps.map(formatRunningApp))
        lines.append("</apps>")

        guard AXIsProcessTrusted() else {
            lines.append("<windows unavailable=\"accessibility_permission_required\" />")
            lines.append("</computer_use_inventory>")
            return lines.joined(separator: "\n")
        }

        lines.append("<windows>")
        var wroteWindowApp = false
        for app in apps {
            guard cuCGWindows(for: app.pid).isEmpty == false else {
                continue
            }

            let identifier = app.bundleID.isEmpty ? app.name : app.bundleID
            guard let windows = try? listWindows(appIdentifier: identifier),
                  windows.isEmpty == false
            else {
                continue
            }

            wroteWindowApp = true
            lines.append("\(app.name) — \(app.bundleID) [pid \(app.pid)]")
            for (index, window) in windows.enumerated() {
                var flags: [String] = []
                if window.isMain { flags.append("main") }
                let flagText = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
                lines.append("[\(index)] window_id=\(window.windowID) title=\"\(window.title)\"\(flagText)")
            }
        }
        if wroteWindowApp == false {
            lines.append("(no readable windows)")
        }
        lines.append("</windows>")
        lines.append("</computer_use_inventory>")
        return lines.joined(separator: "\n")
    }

    private static func formatRunningApp(_ app: RunningAppDescriptor) -> String {
        "\(app.name) — \(app.bundleID) [pid \(app.pid)\(app.isActive ? ", active" : "")]"
    }

    static func listApps(recentDays: Int = 14) -> [ComputerUseAppDescriptor] {
        let now = Date()
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -max(0, recentDays),
            to: now
        ) ?? now
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var appsByKey: [String: ComputerUseAppDescriptor] = [:]

        for url in discoverApplicationBundleURLs() {
            guard let descriptor = appDescriptor(bundleURL: url) else {
                continue
            }
            guard descriptor.lastUsedDate.map({ $0 >= cutoff }) == true else {
                continue
            }
            mergeAppDescriptor(descriptor, into: &appsByKey)
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            guard let descriptor = appDescriptor(
                runningApplication: app,
                frontmostPID: frontmostPID
            ) else { continue }
            mergeAppDescriptor(descriptor, into: &appsByKey)
        }

        return appsByKey.values.sorted(by: appListSort)
    }

    static func openApp(appIdentifier: String) async throws -> (app: ComputerUseAppDescriptor, didLaunch: Bool) {
        if let running = resolveRunningApplicationIfAvailable(matching: appIdentifier),
           let descriptor = appDescriptor(
               runningApplication: running,
               frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
           ) {
            return (descriptor, false)
        }

        let appURL = try resolveApplicationBundleURL(matching: appIdentifier)
        let launched = try await launchApplication(at: appURL)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            if let running = launched ?? resolveRunningApplicationForBundle(at: appURL),
               let descriptor = appDescriptor(
                   runningApplication: running,
                   frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
               ) {
                return (descriptor, true)
            }

            if ProcessInfo.processInfo.systemUptime >= deadline {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        guard let descriptor = appDescriptor(bundleURL: appURL) else {
            throw ComputerUseError.appNotFound(appIdentifier)
        }
        return (descriptor, true)
    }

    static func formatAppListLine(_ app: ComputerUseAppDescriptor) -> String {
        var flags: [String] = []
        if app.isFrontmost {
            flags.append("frontmost")
        }
        if app.isRunning {
            flags.append("running")
        }
        if let lastUsedDate = app.lastUsedDate {
            flags.append("last-used=\(appListDateString(lastUsedDate))")
        }
        if let useCount = app.useCount {
            flags.append("uses=\(useCount)")
        }

        let suffix = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
        return "\(app.name) — \(app.bundleID)\(suffix)"
    }

    static func listRunningApps() -> [RunningAppDescriptor] {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy != .prohibited &&
                    (app.localizedName?.isEmpty == false || app.bundleIdentifier?.isEmpty == false)
            }
            .sorted { lhs, rhs in
                let lhsName = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
                let rhsName = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
            .map { app in
                RunningAppDescriptor(
                    name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                    bundleID: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    isActive: frontmostPID == app.processIdentifier
                )
            }
    }

    private static func mergeAppDescriptor(
        _ incoming: ComputerUseAppDescriptor,
        into appsByKey: inout [String: ComputerUseAppDescriptor]
    ) {
        let key = appListKey(name: incoming.name, bundleID: incoming.bundleID)
        guard var existing = appsByKey[key] else {
            appsByKey[key] = incoming
            return
        }

        existing.name = preferredAppName(existing.name, incoming.name)
        if existing.bundleID.isEmpty {
            existing.bundleID = incoming.bundleID
        }
        existing.pid = existing.pid ?? incoming.pid
        existing.isRunning = existing.isRunning || incoming.isRunning
        existing.isFrontmost = existing.isFrontmost || incoming.isFrontmost
        existing.lastUsedDate = latest(existing.lastUsedDate, incoming.lastUsedDate)
        existing.useCount = maxOptional(existing.useCount, incoming.useCount)
        appsByKey[key] = existing
    }

    private static func discoverApplicationBundleURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]

        var urls: [URL] = []
        var seen = Set<String>()
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                let standardizedPath = url.standardizedFileURL.path
                if seen.insert(standardizedPath).inserted {
                    urls.append(url)
                }
                enumerator.skipDescendants()
            }
        }
        return urls
    }

    private static func appDescriptor(bundleURL: URL) -> ComputerUseAppDescriptor? {
        guard let metadata = MDItemCreate(kCFAllocatorDefault, bundleURL.path as CFString) else {
            return nil
        }

        let bundle = Bundle(url: bundleURL)
        let displayName = mdString(metadata, kMDItemDisplayName)
        let name = firstNonEmpty([
            displayName,
            bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
            bundleURL.deletingPathExtension().lastPathComponent,
        ]) ?? "Unknown"
        let bundleID = firstNonEmpty([
            bundle?.bundleIdentifier,
            mdString(metadata, kMDItemCFBundleIdentifier),
        ]) ?? ""

        return ComputerUseAppDescriptor(
            name: name,
            bundleID: bundleID,
            pid: nil,
            isRunning: false,
            isFrontmost: false,
            lastUsedDate: MDItemCopyAttribute(metadata, kMDItemLastUsedDate) as? Date,
            useCount: mdInt(metadata, "kMDItemUseCount" as CFString)
        )
    }

    private static func appDescriptor(
        runningApplication app: NSRunningApplication,
        frontmostPID: pid_t?
    ) -> ComputerUseAppDescriptor? {
        guard app.localizedName?.isEmpty == false || app.bundleIdentifier?.isEmpty == false else {
            return nil
        }

        let metadata = app.bundleURL.flatMap(appDescriptor(bundleURL:))
        return ComputerUseAppDescriptor(
            name: app.localizedName ?? metadata?.name ?? app.bundleIdentifier ?? "Unknown",
            bundleID: app.bundleIdentifier ?? metadata?.bundleID ?? "",
            pid: app.processIdentifier,
            isRunning: true,
            isFrontmost: frontmostPID == app.processIdentifier,
            lastUsedDate: metadata?.lastUsedDate,
            useCount: metadata?.useCount
        )
    }

    private static func resolveApplicationBundleURL(matching identifier: String) throws -> URL {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw ComputerUseError.invalidArgument("app is required")
        }

        let explicitURL = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        if explicitURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame,
           FileManager.default.fileExists(atPath: explicitURL.path) {
            return explicitURL
        }

        let candidates = discoverApplicationBundleURLs().compactMap { url -> (url: URL, descriptor: ComputerUseAppDescriptor)? in
            guard let descriptor = appDescriptor(bundleURL: url) else { return nil }
            return (url, descriptor)
        }

        if let exactBundleID = candidates.first(where: {
            $0.descriptor.bundleID.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exactBundleID.url
        }

        if let exactName = candidates.first(where: {
            $0.descriptor.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exactName.url
        }

        if let containsName = candidates.first(where: {
            $0.descriptor.name.localizedCaseInsensitiveContains(trimmed)
        }) {
            return containsName.url
        }

        throw ComputerUseError.appNotFound(identifier)
    }

    private static func launchApplication(at url: URL) async throws -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false

        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: app)
                }
            }
        }
    }

    private static func resolveRunningApplicationForBundle(at url: URL) -> NSRunningApplication? {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            return nil
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.activationPolicy != .prohibited })
    }

    private static func mdString(_ item: MDItem, _ attribute: CFString) -> String? {
        MDItemCopyAttribute(item, attribute) as? String
    }

    private static func mdInt(_ item: MDItem, _ attribute: CFString) -> Int? {
        switch MDItemCopyAttribute(item, attribute) {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.first { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        } ?? nil
    }

    private static func appListKey(name: String, bundleID: String) -> String {
        if bundleID.isEmpty == false {
            return "bundle:\(bundleID)"
        }
        return "name:\(name.lowercased())"
    }

    private static func preferredAppName(_ lhs: String, _ rhs: String) -> String {
        if lhs == "Unknown" { return rhs }
        if rhs == "Unknown" { return lhs }
        return lhs.count <= rhs.count ? lhs : rhs
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private static func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private static func appListSort(
        lhs: ComputerUseAppDescriptor,
        rhs: ComputerUseAppDescriptor
    ) -> Bool {
        if lhs.isFrontmost != rhs.isFrontmost {
            return lhs.isFrontmost
        }
        if lhs.isRunning != rhs.isRunning {
            return lhs.isRunning
        }
        switch (lhs.lastUsedDate, rhs.lastUsedDate) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        switch (lhs.useCount, rhs.useCount) {
        case let (lhsCount?, rhsCount?) where lhsCount != rhsCount:
            return lhsCount > rhsCount
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func appListDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func listWindows(appIdentifier: String) throws -> [RunningWindowDescriptor] {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        let app = try resolveRunningApplication(matching: appIdentifier)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ChromiumAccessibilityActivation.shared.activateIfNeeded(
            pid: app.processIdentifier,
            root: appElement
        )

        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? ""
        return windowCandidates(in: appElement, app: app).map { candidate in
            RunningWindowDescriptor(
                appName: appName,
                bundleID: bundleID,
                pid: app.processIdentifier,
                windowID: candidate.cgWindow.windowID,
                title: candidate.title,
                isMain: candidate.isMain
            )
        }
    }

    static func captureSnapshot(
        appIdentifier: String,
        selection: WindowSelection = .init(),
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault,
        filterVisibleNodes: Bool = false
    ) throws -> RuntimeAppSnapshot {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        let app = try resolveRunningApplication(matching: appIdentifier)
        return try captureSnapshot(
            app: app,
            selection: selection,
            includeScreenshot: includeScreenshot,
            screenshotCompression: screenshotCompression,
            filterVisibleNodes: filterVisibleNodes
        )
    }

    static func captureSnapshot(
        metadata: ComputerUseSnapshotMetadata,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault,
        filterVisibleNodes: Bool = false
    ) throws -> RuntimeAppSnapshot {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        guard let app = resolveRunningApp(metadata: metadata) else {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }

        return try captureSnapshot(
            app: app,
            selection: WindowSelection(titleSubstring: metadata.windowTitle),
            includeScreenshot: includeScreenshot,
            screenshotCompression: screenshotCompression,
            preferredWindowID: metadata.windowID,
            preferredWindowFrame: metadata.windowFrame.cgRect,
            filterVisibleNodes: filterVisibleNodes
        )
    }

    static func validateSnapshot(_ metadata: ComputerUseSnapshotMetadata) throws -> RuntimeAppSnapshot {
        do {
            return try captureSnapshot(metadata: metadata, includeScreenshot: false)
        } catch {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }
    }

    static func resolveCachedElement(
        cachedIndex: Int,
        metadata: ComputerUseSnapshotMetadata,
        fresh: RuntimeAppSnapshot
    ) throws -> RuntimeAXNode {
        guard let freshIndex = resolveFreshElementIndex(
            cachedIndex: cachedIndex,
            cached: metadata.nodeSignatures,
            fresh: fresh.nodes
        ) else {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }
        return try fresh.node(index: freshIndex)
    }

    static func persistAndFormat(snapshot: RuntimeAppSnapshot) throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.save(snapshot: snapshot)
        return formattedState(snapshot: snapshot, metadata: metadata)
    }

    static func formattedState(
        snapshot: RuntimeAppSnapshot,
        metadata: ComputerUseSnapshotMetadata
    ) -> ComputerUseCommandOutput {
        let stateDump = ComputerUseStateFormatter.format(snapshot: snapshot)
        var text = """
        Computer Use state (Snapshot: \(metadata.id))
        <app_state>
        \(stateDump)
        </app_state>
        """

        if let screenshotPath = metadata.screenshotPath {
            text += "\nScreenshot: \(screenshotPath)"
        }

        if let screenshotSize = metadata.screenshotSize {
            text += "\nScreenshotSize: \(Int(screenshotSize.width))x\(Int(screenshotSize.height))"
        }

        return ComputerUseCommandOutput(text: text, metadata: metadata)
    }

    private static let coordinateFrameTolerance: CGFloat = 8

    static func ensureStableFrameForCoordinateAction(
        metadata: ComputerUseSnapshotMetadata,
        fresh: RuntimeAppSnapshot
    ) throws {
        guard nearlyEqualRects(
            fresh.windowFrame,
            metadata.windowFrame.cgRect,
            tolerance: coordinateFrameTolerance
        ) else {
            throw ComputerUseError.staleState(appName: metadata.appName)
        }
    }

    static func captureSettledSnapshot(
        afterActionOn snapshot: RuntimeAppSnapshot,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression = .foregroundDefault,
        filterVisibleNodes: Bool = false
    ) throws -> RuntimeAppSnapshot {
        guard AXIsProcessTrusted() else {
            throw ComputerUseError.accessibilityPermissionDenied
        }

        let deadline = ProcessInfo.processInfo.systemUptime + ComputerUseActionSettleTiming.timeout
        let requiredStablePasses = ComputerUseActionSettleTiming.requiredStablePasses
        var lastFingerprint: String?
        var stablePasses = 0
        var latestSnapshot: RuntimeAppSnapshot?

        while true {
            let candidate = try captureSnapshot(
                app: snapshot.app,
                selection: WindowSelection(titleSubstring: snapshot.windowTitle),
                includeScreenshot: false,
                screenshotCompression: screenshotCompression,
                preferredWindowID: snapshot.windowID,
                filterVisibleNodes: filterVisibleNodes
            )
            latestSnapshot = candidate

            if candidate.fingerprint == lastFingerprint {
                stablePasses += 1
            } else {
                lastFingerprint = candidate.fingerprint
                stablePasses = 1
            }

            if stablePasses >= requiredStablePasses {
                break
            }

            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 {
                break
            }

            RunLoop.current.run(until: Date(timeIntervalSinceNow: min(ComputerUseActionSettleTiming.pollInterval, remaining)))
        }

        guard let latestSnapshot else {
            throw ComputerUseError.windowNotFound(
                app: snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "Unknown",
                title: snapshot.windowTitle
            )
        }

        guard includeScreenshot else {
            return latestSnapshot
        }

        return try captureSnapshot(
            app: latestSnapshot.app,
            selection: WindowSelection(titleSubstring: latestSnapshot.windowTitle),
            includeScreenshot: true,
            screenshotCompression: screenshotCompression,
            preferredWindowID: latestSnapshot.windowID,
            filterVisibleNodes: filterVisibleNodes
        )
    }

    private static func captureSnapshot(
        app: NSRunningApplication,
        selection: WindowSelection,
        includeScreenshot: Bool,
        screenshotCompression: ComputerUseScreenshotCompression,
        preferredWindowID: Int? = nil,
        preferredWindowFrame: CGRect? = nil,
        filterVisibleNodes: Bool = false
    ) throws -> RuntimeAppSnapshot {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ChromiumAccessibilityActivation.shared.activateIfNeeded(
            pid: app.processIdentifier,
            root: appElement
        )
        let windowMatch = try resolveWindow(
            in: appElement,
            app: app,
            titleSubstring: selection.titleSubstring,
            preferredWindowID: preferredWindowID,
            preferredWindowFrame: preferredWindowFrame
        )

        let focusedElement = cuAttribute(
            appElement,
            name: kAXFocusedUIElementAttribute as String
        ) as AXUIElement?

        if let popupMenu = popupMenuCandidate(in: appElement) ?? activeMenuBarItemCandidate(in: appElement) {
            let nodes = flattenTree(
                from: popupMenu.element,
                focusedElement: focusedElement,
                visibleFrame: popupMenu.frame,
                filterVisibleNodes: filterVisibleNodes
            )
            let focusedIndex = focusedElement.flatMap { focused in
                nodes.first(where: { CFEqual($0.element, focused) })?.index
            }
            let selectedText = focusedElement.flatMap {
                cuAttribute($0, name: kAXSelectedTextAttribute as String) as String?
            }
            let fingerprint = fingerprint(
                app: app,
                windowID: windowMatch.cgWindow.windowID,
                windowTitle: windowMatch.title,
                windowFrame: windowMatch.frame,
                nodes: nodes,
                focusedElementIndex: focusedIndex,
                selectedText: selectedText
            )

            return RuntimeAppSnapshot(
                app: app,
                appElement: appElement,
                windowElement: popupMenu.element,
                windowID: windowMatch.cgWindow.windowID,
                windowTitle: windowMatch.title,
                windowFrame: windowMatch.frame,
                nodes: nodes,
                focusedElementIndex: focusedIndex,
                selectedText: selectedText,
                screenshotURL: nil,
                screenshotSize: nil,
                fingerprint: fingerprint
            )
        }

        var nodes = flattenTree(
            from: windowMatch.element,
            focusedElement: focusedElement,
            visibleFrame: windowMatch.frame,
            filterVisibleNodes: filterVisibleNodes
        )
        if let menuBar = cuAttribute(appElement, name: kAXMenuBarAttribute as String) as AXUIElement? {
            nodes.append(contentsOf: reindexedNodes(
                flattenTree(
                    from: menuBar,
                    focusedElement: focusedElement,
                    visibleFrame: cuFrame(menuBar) ?? windowMatch.frame,
                    filterVisibleNodes: filterVisibleNodes,
                    maxDepth: 1
                ),
                startingAt: nodes.count
            ))
        }

        let focusedIndex = focusedElement.flatMap { focused in
            nodes.first(where: { CFEqual($0.element, focused) })?.index
        }

        let selectedText = focusedElement.flatMap {
            cuAttribute($0, name: kAXSelectedTextAttribute as String) as String?
        }

        let screenshotCapture = includeScreenshot
            ? BackgroundWindowCapture.captureWindowScreenshot(
                windowID: windowMatch.cgWindow.windowID,
                compression: screenshotCompression
            )
            : nil

        let fingerprint = fingerprint(
            app: app,
            windowID: windowMatch.cgWindow.windowID,
            windowTitle: windowMatch.title,
            windowFrame: windowMatch.frame,
            nodes: nodes,
            focusedElementIndex: focusedIndex,
            selectedText: selectedText
        )

        return RuntimeAppSnapshot(
            app: app,
            appElement: appElement,
            windowElement: windowMatch.element,
            windowID: windowMatch.cgWindow.windowID,
            windowTitle: windowMatch.title,
            windowFrame: windowMatch.frame,
            nodes: nodes,
            focusedElementIndex: focusedIndex,
            selectedText: selectedText,
            screenshotURL: screenshotCapture?.url,
            screenshotSize: screenshotCapture?.size,
            fingerprint: fingerprint
        )
    }

    private static func resolveRunningApp(
        metadata: ComputerUseSnapshotMetadata
    ) -> NSRunningApplication? {
        if metadata.bundleID.isEmpty == false {
            if let match = NSRunningApplication.runningApplications(
                withBundleIdentifier: metadata.bundleID
            ).first(where: { $0.processIdentifier == metadata.pid }) {
                return match
            }
        }
        return NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier == metadata.pid
        })
    }

    private static func resolveRunningApplication(matching identifier: String) throws -> NSRunningApplication {
        if let app = resolveRunningApplicationIfAvailable(matching: identifier) {
            return app
        }

        throw ComputerUseError.appNotRunning(identifier)
    }

    private static func resolveRunningApplicationIfAvailable(matching identifier: String) -> NSRunningApplication? {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }

        if let byBundleID = runningApps.first(where: { $0.bundleIdentifier == identifier }) {
            return byBundleID
        }

        if let byName = runningApps.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return byName
        }

        if let containsName = runningApps.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(identifier)
        }) {
            return containsName
        }

        return nil
    }

    private static func resolveWindow(
        in appElement: AXUIElement,
        app: NSRunningApplication,
        titleSubstring: String?,
        preferredWindowID: Int?,
        preferredWindowFrame: CGRect? = nil
    ) throws -> (element: AXUIElement, title: String, frame: CGRect, cgWindow: CUWindowSnapshot) {
        let candidates = windowCandidates(
            in: appElement,
            app: app,
            preferredWindowID: preferredWindowID
        )

        if let preferredWindowID,
           let exact = candidates.first(where: { $0.cgWindow.windowID == preferredWindowID })
        {
            return resolvedWindow(exact)
        }

        if let preferredWindowFrame,
           let best = bestCandidateByFrame(candidates, hint: preferredWindowFrame)
        {
            return resolvedWindow(best)
        }

        let filtered: [WindowCandidate] = if let titleSubstring, titleSubstring.isEmpty == false {
            candidates.filter { candidate in
                candidate.title.localizedCaseInsensitiveContains(titleSubstring)
            }
        } else {
            candidates
        }

        if let main = filtered.first(where: { $0.isMain }) {
            return resolvedWindow(main)
        }

        if let focused = filtered.first(where: { $0.isFocused }) {
            return resolvedWindow(focused)
        }

        if let first = filtered.first {
            return resolvedWindow(first)
        }

        throw ComputerUseError.windowNotFound(
            app: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
            title: titleSubstring
        )
    }

    private static func windowCandidates(
        in appElement: AXUIElement,
        app: NSRunningApplication,
        preferredWindowID: Int? = nil
    ) -> [WindowCandidate] {
        let windows = mergeAXWindowCandidates(
            listedWindows: cuAttribute(appElement, name: kAXWindowsAttribute as String) as [AXUIElement]? ?? [],
            focusedWindow: cuAttribute(appElement, name: kAXFocusedWindowAttribute as String) as AXUIElement?,
            mainWindow: cuAttribute(appElement, name: kAXMainWindowAttribute as String) as AXUIElement?
        )
        let cgWindows = cuCGWindows(for: app.processIdentifier)

        var candidates: [WindowCandidate] = []

        for window in windows {
            guard let frame = cuFrame(window) else {
                continue
            }

            let title = cuTitle(window)
            let matchingWindow = matchCGWindow(
                axWindow: window,
                candidates: cgWindows,
                preferredWindowID: preferredWindowID,
                title: title,
                frame: frame
            )

            guard let cgWindow = matchingWindow else {
                continue
            }

            candidates.append(WindowCandidate(
                element: window,
                title: title,
                frame: frame,
                cgWindow: cgWindow,
                isMain: cuBoolAttribute(window, name: kAXMainAttribute as String) == true,
                isFocused: cuBoolAttribute(window, name: kAXFocusedAttribute as String) == true
            ))
        }

        return candidates
    }

    private static func resolvedWindow(
        _ candidate: WindowCandidate
    ) -> (element: AXUIElement, title: String, frame: CGRect, cgWindow: CUWindowSnapshot) {
        (candidate.element, candidate.title, candidate.frame, candidate.cgWindow)
    }

    private static func bestCandidateByFrame(
        _ candidates: [WindowCandidate],
        hint: CGRect
    ) -> WindowCandidate? {
        func score(_ frame: CGRect) -> CGFloat {
            let dx = frame.midX - hint.midX
            let dy = frame.midY - hint.midY
            let dw = frame.width - hint.width
            let dh = frame.height - hint.height
            return sqrt(dx * dx + dy * dy) + abs(dw) + abs(dh)
        }
        return candidates
            .map { ($0, score($0.frame)) }
            .min(by: { $0.1 < $1.1 })?.0
    }

    private static func matchCGWindow(
        axWindow: AXUIElement,
        candidates: [CUWindowSnapshot],
        preferredWindowID: Int?,
        title: String,
        frame: CGRect
    ) -> CUWindowSnapshot? {
        if let exactWindowID = AXWindowIDResolver.cgWindowID(forAXWindow: axWindow),
           let exact = candidates.first(where: { $0.windowID == Int(exactWindowID) })
        {
            return exact
        }

        if let preferredWindowID,
           let preferred = candidates.first(where: { $0.windowID == preferredWindowID }),
           nearlyEqualRects(preferred.bounds, frame, tolerance: 4)
        {
            return preferred
        }

        if title.isEmpty == false {
            let sameTitle = candidates.filter {
                $0.name.localizedCaseInsensitiveContains(title)
            }
            if let frameMatch = sameTitle.first(where: {
                nearlyEqualRects($0.bounds, frame)
            }) {
                return frameMatch
            }
            if let firstTitle = sameTitle.first {
                return firstTitle
            }
        }

        return candidates.first(where: { nearlyEqualRects($0.bounds, frame) }) ??
            candidates.first(where: { $0.layer == 0 })
    }

    private static func popupMenuCandidate(in appElement: AXUIElement) -> PopupMenuCandidate? {
        let roots = cuElements(from: cuRawAttribute(appElement, name: kAXFocusedWindowAttribute as String)) +
            cuElements(from: cuRawAttribute(appElement, name: kAXWindowsAttribute as String)) +
            cuElements(from: cuRawAttribute(appElement, name: kAXFocusedUIElementAttribute as String))
        var stack = roots
        var visited = Set<CFHashCode>()
        var best: PopupMenuCandidate?

        while let element = stack.popLast() {
            let identifier = CFHash(element)
            if visited.contains(identifier) {
                continue
            }
            visited.insert(identifier)

            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            if role == (kAXMenuRole as String),
               let frame = cuFrame(element),
               popupMenuHasItems(element),
               isTransientPopupMenu(element) {
                let candidate = PopupMenuCandidate(element: element, frame: frame)
                if best == nil || menuItemCount(in: element) > menuItemCount(in: best!.element) {
                    best = candidate
                }
            }

            stack.append(contentsOf: cuChildElements(element))
        }

        return best
    }

    private static func isTransientPopupMenu(_ menu: AXUIElement) -> Bool {
        var current: AXUIElement? = menu
        var visited = Set<CFHashCode>()

        while let element = current {
            let identifier = CFHash(element)
            if visited.contains(identifier) {
                return false
            }
            visited.insert(identifier)

            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            if role == (kAXMenuBarItemRole as String) ||
                role == (kAXMenuItemRole as String) ||
                role == (kAXPopUpButtonRole as String) ||
                role == "AXMenuButton" {
                return true
            }

            if role == "AXWebArea" ||
                role == (kAXWindowRole as String) {
                return false
            }

            current = cuAttribute(element, name: kAXParentAttribute as String) as AXUIElement?
        }

        return false
    }

    private static func activeMenuBarItemCandidate(in appElement: AXUIElement) -> PopupMenuCandidate? {
        guard let menuBar = cuAttribute(appElement, name: kAXMenuBarAttribute as String) as AXUIElement? else {
            return nil
        }

        let items = cuChildElements(menuBar).filter { element in
            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? ""
            return role == (kAXMenuBarItemRole as String) && cuTitle(element) != "Apple"
        }

        for item in items where cuBoolAttribute(item, name: kAXSelectedAttribute as String) == true {
            let menus = cuChildElements(item).filter { child in
                let role = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
                return role == (kAXMenuRole as String) && popupMenuHasItems(child)
            }
            guard menus.isEmpty == false else {
                continue
            }
            let frame = cuFrame(item) ?? menus.compactMap(cuFrame).first
            if let frame {
                return PopupMenuCandidate(element: item, frame: frame)
            }
        }

        return nil
    }

    private static func reindexedNodes(
        _ nodes: [RuntimeAXNode],
        startingAt offset: Int
    ) -> [RuntimeAXNode] {
        nodes.map { node in
            RuntimeAXNode(
                index: node.index + offset,
                depth: node.depth,
                element: node.element,
                role: node.role,
                subrole: node.subrole,
                title: node.title,
                description: node.description,
                value: node.value,
                help: node.help,
                identifier: node.identifier,
                url: node.url,
                enabled: node.enabled,
                selected: node.selected,
                expanded: node.expanded,
                focused: node.focused,
                frame: node.frame,
                actions: node.actions,
                isValueSettable: node.isValueSettable,
                valueTypeDescription: node.valueTypeDescription
            )
        }
    }

    private static func popupMenuHasItems(_ menu: AXUIElement) -> Bool {
        menuItemCount(in: menu) > 0
    }

    private static func menuItemCount(in menu: AXUIElement) -> Int {
        cuMenuChildren(menu).filter { child in
            let role = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
            return role == (kAXMenuItemRole as String) || !cuTitle(child).isEmpty || !cuDescription(child).isEmpty
        }.count
    }

    private static func flattenTree(
        from root: AXUIElement,
        focusedElement: AXUIElement?,
        visibleFrame: CGRect,
        filterVisibleNodes: Bool,
        maxDepth: Int = 64
    ) -> [RuntimeAXNode] {
        struct PendingNode {
            let element: AXUIElement
            let role: String
            let subrole: String
            let title: String
            let description: String
            let value: Any?
            let help: String
            let identifier: String
            let url: URL?
            let enabled: Bool?
            let selected: Bool?
            let expanded: Bool?
            let focused: Bool?
            let frame: CGRect?
            let actions: [String]
            let isValueSettable: Bool
            let valueTypeDescription: String?
            let children: [PendingNode]
        }

        var visited = Set<CFHashCode>()

        func build(_ element: AXUIElement, depth: Int, visibleClip: CGRect) -> PendingNode? {
            guard depth <= maxDepth else {
                return nil
            }

            let identifier = CFHash(element)
            if visited.contains(identifier) {
                return nil
            }
            visited.insert(identifier)

            let role = cuAttribute(element, name: kAXRoleAttribute as String) as String? ?? "AXUnknown"
            let subrole = cuAttribute(element, name: kAXSubroleAttribute as String) as String? ?? ""
            let title = cuTitle(element)
            let description = cuDescription(element)
            let frame = cuFrame(element)
            let focused = focusedElement.map { CFEqual($0, element) }
            let selected = cuBoolAttribute(element, name: kAXSelectedAttribute as String)
            let hidden = cuBoolAttribute(element, name: "AXHidden") == true
            if hidden, depth > 0, focused != true, selected != true {
                return nil
            }

            let rawChildren = cuChildElementsForWalk(element, role: role)
            let childVisibleClip = filterVisibleNodes
                ? cuDescendantVisibleClip(role: role, frame: frame, inheritedClip: visibleClip)
                : visibleClip
            let children = rawChildren.compactMap {
                build($0, depth: depth + 1, visibleClip: childVisibleClip)
            }

            let visible = if roleCanContainVisibleDescendants(role) {
                cuFrameIsVisible(frame, in: visibleClip) || children.isEmpty == false
            } else {
                cuFrameIsMeaningfullyVisible(frame, in: visibleClip)
            }
            let selfDescribingStructuralNode = roleCanContainVisibleDescendants(role) &&
                (!title.isEmpty || !description.isEmpty)
            let visibleFilteringDisabled = ProcessInfo.processInfo.environment["KWWK_CU_DISABLE_VISIBLE_FILTER"] == "1"
            if filterVisibleNodes,
               !visibleFilteringDisabled,
               depth > 0,
               !visible,
               !selfDescribingStructuralNode,
               focused != true,
               selected != true
            {
                return nil
            }

            let value = cuRawAttribute(element, name: kAXValueAttribute as String)
            return PendingNode(
                element: element,
                role: role,
                subrole: subrole,
                title: title,
                description: description,
                value: value,
                help: cuAttribute(element, name: kAXHelpAttribute as String) as String? ?? "",
                identifier: cuAttribute(element, name: kAXIdentifierAttribute as String) as String? ?? "",
                url: cuAttribute(element, name: kAXURLAttribute as String) as URL?,
                enabled: cuBoolAttribute(element, name: kAXEnabledAttribute as String),
                selected: selected,
                expanded: cuBoolAttribute(element, name: kAXExpandedAttribute as String),
                focused: focused,
                frame: frame,
                actions: cuActions(element),
                isValueSettable: cuIsAttributeSettable(element, name: kAXValueAttribute as String),
                valueTypeDescription: describeValueType(value),
                children: children
            )
        }

        guard let rootNode = build(root, depth: 0, visibleClip: visibleFrame) else {
            return []
        }

        var nodes: [RuntimeAXNode] = []
        func emit(_ pending: PendingNode, depth: Int) {
            let index = nodes.count
            nodes.append(RuntimeAXNode(
                index: index,
                depth: depth,
                element: pending.element,
                role: pending.role,
                subrole: pending.subrole,
                title: pending.title,
                description: pending.description,
                value: pending.value,
                help: pending.help,
                identifier: pending.identifier,
                url: pending.url,
                enabled: pending.enabled,
                selected: pending.selected,
                expanded: pending.expanded,
                focused: pending.focused,
                frame: pending.frame,
                actions: pending.actions,
                isValueSettable: pending.isValueSettable,
                valueTypeDescription: pending.valueTypeDescription
            ))
            for child in pending.children {
                emit(child, depth: depth + 1)
            }
        }
        emit(rootNode, depth: 0)

        return nodes
    }

    private static func fingerprint(
        app: NSRunningApplication,
        windowID: Int,
        windowTitle: String,
        windowFrame: CGRect,
        nodes: [RuntimeAXNode],
        focusedElementIndex: Int?,
        selectedText: String?
    ) -> String {
        let parts = nodes.map { node -> String in
            let components: [String] = [
                "\(node.index)",
                node.role,
                node.subrole,
                node.title,
                stableFingerprintValue(for: node),
                node.help,
                node.identifier,
                stableFingerprintURL(for: node),
                node.enabled.map(String.init) ?? "",
                node.selected.map(String.init) ?? "",
                node.expanded.map(String.init) ?? "",
                node.frame.map(stableRectString) ?? "",
                node.actions.joined(separator: ","),
            ]
            return components.joined(separator: "|")
        }

        let payload = """
        \(app.bundleIdentifier ?? "")
        |\(app.processIdentifier)
        |\(windowID)
        |\(windowTitle)
        |\(stableRectString(windowFrame))
        |focus=\(focusedElementIndex.map(String.init) ?? "")
        |selected=\(selectedText ?? "")
        |\(parts.joined(separator: "\n"))
        """

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum ComputerUseActionSettleTiming {
    static var timeout: TimeInterval {
        milliseconds(from: "KWWK_CU_ACTION_SETTLE_TIMEOUT_MS", fallback: 1600)
    }

    static var pollInterval: TimeInterval {
        milliseconds(from: "KWWK_CU_ACTION_SETTLE_POLL_MS", fallback: 120)
    }

    static var requiredStablePasses: Int {
        guard
            let raw = ProcessInfo.processInfo.environment["KWWK_CU_ACTION_SETTLE_STABLE_PASSES"],
            let value = Int(raw)
        else {
            return 3
        }

        return max(1, value)
    }

    private static func milliseconds(from key: String, fallback: Double) -> TimeInterval {
        guard
            let raw = ProcessInfo.processInfo.environment[key],
            let value = Double(raw),
            value >= 0
        else {
            return fallback / 1000
        }

        return value / 1000
    }
}

enum ComputerUseStateFormatter {
    static func format(snapshot: RuntimeAppSnapshot) -> String {
        let appName = snapshot.app.localizedName ?? snapshot.app.bundleIdentifier ?? "Unknown"
        let focusedLine = if let focusedIndex = snapshot.focusedElementIndex,
                             let focusedNode = try? snapshot.node(index: focusedIndex)
        {
            "\nThe focused UI element is \(focusedIndex) \(describeRole(focusedNode.role))."
        } else {
            ""
        }

        let selectedTextLine = if let selectedText = snapshot.selectedText, selectedText.isEmpty == false {
            """

            Selected text: ```
            \(selectedText)
            ```
            """
        } else {
            ""
        }

        let lines = snapshot.nodes.map(format(node:))
        return """
        App=\(snapshot.app.bundleIdentifier ?? appName) (pid \(snapshot.app.processIdentifier))
        Window: "\(snapshot.windowTitle)", App: \(appName).
        \(lines.joined(separator: "\n"))\(focusedLine)\(selectedTextLine)
        """
    }

    private static func format(node: RuntimeAXNode) -> String {
        let indent = String(repeating: "\t", count: node.depth)
        let stateDescription = describeStates(node)
        let suffixParts = describeDetails(node)
        let suffix = suffixParts.isEmpty ? "" : " " + suffixParts.joined(separator: ", ")
        let label = displayLabel(for: node)
        let labelPart = label.isEmpty ? "" : " \(label)"
        return "\(indent)\(node.index)\(labelPart)\(stateDescription)\(suffix)"
    }

    private static func displayLabel(for node: RuntimeAXNode) -> String {
        if node.role == kAXMenuBarItemRole as String,
           node.title.isEmpty == false {
            return node.title
        }
        if node.role == kAXMenuItemRole as String,
           node.title.isEmpty == false {
            return ""
        }
        return describeRole(node.role)
    }

    private static func describeStates(_ node: RuntimeAXNode) -> String {
        var states: [String] = []

        if node.enabled == false {
            states.append("disabled")
        }
        if node.selected == true {
            states.append("selected")
        }
        if node.expanded == true {
            states.append("expanded")
        }
        if node.isValueSettable {
            states.append("settable")
        }
        if let valueTypeDescription = node.valueTypeDescription, node.isValueSettable {
            states.append(valueTypeDescription)
        }

        guard states.isEmpty == false else {
            return ""
        }
        return " (\(states.joined(separator: ", ")))"
    }

    private static func describeDetails(_ node: RuntimeAXNode) -> [String] {
        var details: [String] = []

        if node.title.isEmpty == false,
           node.role != kAXMenuBarItemRole as String
        {
            details.append(node.title)
        }

        if node.description.isEmpty == false,
           node.description != node.title
        {
            details.append("Description: \(node.description)")
        }

        if node.identifier.isEmpty == false {
            details.append("ID: \(node.identifier)")
        }

        if node.help.isEmpty == false {
            details.append("Help: \(node.help)")
        }

        if let url = node.url {
            details.append("URL: \(url.absoluteString)")
        }

        if ProcessInfo.processInfo.environment["KWWK_CU_INCLUDE_FRAMES"] == "1",
           let frame = node.frame
        {
            details.append("Frame: \(stableRectString(frame))")
        }

        let valueString = stringifyValue(node.value)
        if valueString.isEmpty == false,
           valueString != node.title
        {
            details.append("Value: \(valueString)")
        }

        let secondaryActions = node.actions
            .map(displayName(forAction:))
            .filter { $0.caseInsensitiveCompare("Press") != .orderedSame }

        if secondaryActions.isEmpty == false {
            details.append("Secondary Actions: \(secondaryActions.joined(separator: ", "))")
        }

        return details
    }
}

extension JSONEncoder {
    static var computerUse: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var computerUse: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

func displayName(forAction action: String) -> String {
    let trimmed = action.hasPrefix("AX") ? String(action.dropFirst(2)) : action
    let noByPage = trimmed.replacingOccurrences(of: "ByPage", with: "")
    return splitCamelCase(noByPage).joined(separator: " ")
}

func describeRole(_ role: String) -> String {
    if role == kAXWindowRole as String {
        return "standard window"
    }
    if role == kAXStaticTextRole as String {
        return "text"
    }
    return splitCamelCase(role.hasPrefix("AX") ? String(role.dropFirst(2)) : role)
        .joined(separator: " ")
        .lowercased()
}

func splitCamelCase(_ string: String) -> [String] {
    guard string.isEmpty == false else {
        return []
    }

    var words: [String] = []
    var current = ""

    for scalar in string.unicodeScalars {
        let character = Character(scalar)
        if current.isEmpty == false,
           CharacterSet.uppercaseLetters.contains(scalar)
        {
            words.append(current)
            current = String(character)
        } else {
            current.append(character)
        }
    }

    if current.isEmpty == false {
        words.append(current)
    }

    return words
}

func stringifyValue(_ value: Any?) -> String {
    guard let value else {
        return ""
    }

    if let string = value as? String {
        return string
    }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "1" : "0"
        }
        return number.stringValue
    }
    if let url = value as? URL {
        return url.absoluteString
    }
    let cfObject = value as AnyObject
    if CFGetTypeID(cfObject) == AXValueGetTypeID() {
        let axValue = value as! AXValue
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(axValue, .cgPoint, &point) else {
                return ""
            }
            return NSStringFromPoint(point)
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(axValue, .cgSize, &size) else {
                return ""
            }
            return NSStringFromSize(size)
        case .cfRange:
            var range = CFRange()
            guard AXValueGetValue(axValue, .cfRange, &range) else {
                return ""
            }
            return "{\(range.location), \(range.length)}"
        default:
            return ""
        }
    }
    return String(describing: value)
}

func describeValueType(_ value: Any?) -> String? {
    guard let value else {
        return nil
    }
    if value is String {
        return "string"
    }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return "bool"
        }
        if CFNumberIsFloatType(number) {
            return "float"
        }
        return "int"
    }
    return nil
}

func stableRectString(_ rect: CGRect) -> String {
    "\(round(rect.origin.x * 100) / 100),\(round(rect.origin.y * 100) / 100),\(round(rect.width * 100) / 100),\(round(rect.height * 100) / 100)"
}

func stableFingerprintValue(for node: RuntimeAXNode) -> String {
    if node.role == kAXStaticTextRole as String {
        return ""
    }

    if node.isValueSettable {
        return stringifyValue(node.value)
    }

    let valueRelevantRoles: Set<String> = [
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXSliderRole as String,
        kAXScrollBarRole as String,
    ]
    switch node.role {
    case let role where valueRelevantRoles.contains(role):
        return stringifyValue(node.value)
    default:
        return ""
    }
}

func stableFingerprintURL(for node: RuntimeAXNode) -> String {
    guard node.role == kAXTextFieldRole as String else {
        return ""
    }
    return node.url?.absoluteString ?? ""
}

func parentIndicesFromDepths(_ depths: [Int]) -> [Int?] {
    var parents: [Int?] = Array(repeating: nil, count: depths.count)
    var stack: [Int] = []
    for i in 0 ..< depths.count {
        while let top = stack.last, depths[top] >= depths[i] {
            stack.removeLast()
        }
        parents[i] = stack.last
        stack.append(i)
    }
    return parents
}

func childIndicesAmongSameRole(
    roles: [String],
    subroles: [String],
    parents: [Int?]
) -> [Int] {
    var counts: [Int: [String: Int]] = [:]
    var result: [Int] = Array(repeating: 0, count: roles.count)
    for i in 0 ..< roles.count {
        let parentKey = parents[i] ?? -1
        let bucketKey = "\(roles[i])|\(subroles[i])"
        let next = counts[parentKey, default: [:]][bucketKey, default: 0]
        result[i] = next
        counts[parentKey, default: [:]][bucketKey] = next + 1
    }
    return result
}

func nodeSignatures(for nodes: [RuntimeAXNode]) -> [CachedNodeSignature] {
    let depths = nodes.map(\.depth)
    let roles = nodes.map(\.role)
    let subroles = nodes.map(\.subrole)
    let parents = parentIndicesFromDepths(depths)
    let childIndices = childIndicesAmongSameRole(
        roles: roles,
        subroles: subroles,
        parents: parents
    )
    return nodes.enumerated().map { i, node in
        CachedNodeSignature(
            depth: node.depth,
            role: node.role,
            subrole: node.subrole,
            title: node.title,
            description: node.description.isEmpty ? nil : node.description,
            identifier: node.identifier,
            childIndexAmongSameRole: childIndices[i]
        )
    }
}

func resolveFreshElementIndex(
    cachedIndex: Int,
    cached: [CachedNodeSignature],
    fresh: [RuntimeAXNode]
) -> Int? {
    guard cachedIndex >= 0, cachedIndex < cached.count, !fresh.isEmpty else {
        return nil
    }

    let cachedParents = parentIndicesFromDepths(cached.map(\.depth))
    var path: [CachedNodeSignature] = []
    var cursor: Int? = cachedIndex
    while let c = cursor {
        path.append(cached[c])
        cursor = cachedParents[c]
    }
    path.reverse()

    let freshDepths = fresh.map(\.depth)
    let freshParents = parentIndicesFromDepths(freshDepths)
    let freshChildIndices = childIndicesAmongSameRole(
        roles: fresh.map(\.role),
        subroles: fresh.map(\.subrole),
        parents: freshParents
    )

    guard let rootStep = path.first else {
        return nil
    }

    let rootCandidates = fresh.indices.filter {
        fresh[$0].depth == rootStep.depth &&
            matchScore(
                candidate: fresh[$0],
                childIndex: freshChildIndices[$0],
                target: rootStep
            ) >= 0
    }

    for rootCandidate in rootCandidates {
        var freshCursor = rootCandidate
        var matched = true
        for step in path.dropFirst() {
            let children = (0 ..< fresh.count).filter { freshParents[$0] == freshCursor }
            var bestScore = Int.min
            var best: Int?
            for child in children {
                let s = matchScore(
                    candidate: fresh[child],
                    childIndex: freshChildIndices[child],
                    target: step
                )
                if s > bestScore {
                    bestScore = s
                    best = child
                }
            }
            guard let best, bestScore >= 0 else {
                matched = false
                break
            }
            freshCursor = best
        }
        if matched {
            return freshCursor
        }
    }

    return nil
}

private func matchScore(
    candidate: RuntimeAXNode,
    childIndex: Int,
    target: CachedNodeSignature
) -> Int {
    guard candidate.role == target.role else { return Int.min }
    var score = 0

    if !target.subrole.isEmpty {
        if candidate.subrole == target.subrole { score += 2 }
        else if !candidate.subrole.isEmpty { score -= 2 }
    } else if !candidate.subrole.isEmpty {
        score -= 1
    }

    if !target.identifier.isEmpty {
        if candidate.identifier == target.identifier { score += 4 }
        else if !candidate.identifier.isEmpty { score -= 3 }
    }

    if !target.title.isEmpty {
        if candidate.title == target.title { score += 3 }
        else if !candidate.title.isEmpty { score -= 2 }
    }

    if let description = target.description, !description.isEmpty {
        if candidate.description == description { score += 3 }
        else if !candidate.description.isEmpty { score -= 2 }
    }

    if childIndex == target.childIndexAmongSameRole { score += 1 }

    return score
}

func windowLocalPoint(
    fromScreenshotPixel point: CGPoint,
    screenshotSize: CGSize,
    windowFrame: CGRect
) -> CGPoint {
    windowLocalPoint(
        fromScreenshotPixel: Point<ScreenshotPixelSpace>(point),
        screenshotSize: screenshotSize,
        windowFrame: windowFrame
    ).cgPoint
}

func nearlyEqualRects(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
}

func cuRawAttribute(_ element: AXUIElement, name: String) -> Any? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else {
        return nil
    }
    return value
}

func cuAttribute<T>(_ element: AXUIElement, name: String) -> T? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard error == .success else {
        return nil
    }
    return value as? T
}

func cuBoolAttribute(_ element: AXUIElement, name: String) -> Bool? {
    cuAttribute(element, name: name) as Bool?
}

func cuTitle(_ element: AXUIElement) -> String {
    cuAttribute(element, name: kAXTitleAttribute as String) as String? ?? ""
}

func cuDescription(_ element: AXUIElement) -> String {
    cuAttribute(element, name: kAXDescriptionAttribute as String) as String? ?? ""
}

func cuActions(_ element: AXUIElement) -> [String] {
    var value: CFArray?
    let error = AXUIElementCopyActionNames(element, &value)
    guard error == .success else {
        return []
    }
    return value as? [String] ?? []
}

func cuFrame(_ element: AXUIElement) -> CGRect? {
    guard
        let positionValue = cuAttribute(element, name: kAXPositionAttribute as String) as AXValue?,
        let sizeValue = cuAttribute(element, name: kAXSizeAttribute as String) as AXValue?,
        let position = cuCGPoint(from: positionValue),
        let size = cuCGSize(from: sizeValue)
    else {
        return nil
    }

    return CGRect(origin: position, size: size)
}

private let cuChildRelationshipAttributes: [String] = [
    kAXChildrenAttribute as String,
]

func cuChildElements(_ element: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []

    func append(_ child: AXUIElement) {
        guard !result.contains(where: { CFEqual($0, child) }) else { return }
        result.append(child)
    }

    for attribute in cuChildRelationshipAttributes {
        guard let value = cuRawAttribute(element, name: attribute) else {
            continue
        }

        if CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() {
            append(value as! AXUIElement)
        } else if CFGetTypeID(value as CFTypeRef) == CFArrayGetTypeID(),
                  let children = value as? [AXUIElement]
        {
            children.forEach(append)
        }
    }

    return result
}

func cuElements(from value: Any?) -> [AXUIElement] {
    guard let value else { return [] }
    if CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() {
        return [value as! AXUIElement]
    }
    if CFGetTypeID(value as CFTypeRef) == CFArrayGetTypeID(),
       let children = value as? [AXUIElement] {
        return children
    }
    return []
}

func cuMenuChildren(_ element: AXUIElement) -> [AXUIElement] {
    let visible = cuElements(from: cuRawAttribute(element, name: "AXVisibleChildren"))
    if visible.isEmpty == false {
        return visible
    }
    return cuChildElements(element)
}

func cuChildElementsForWalk(_ element: AXUIElement, role: String) -> [AXUIElement] {
    if role == (kAXMenuRole as String) {
        return cuMenuChildren(element)
    }
    if role == (kAXMenuBarRole as String) {
        return cuChildElements(element).filter { child in
            let childRole = cuAttribute(child, name: kAXRoleAttribute as String) as String? ?? ""
            return childRole != (kAXMenuBarItemRole as String) || cuTitle(child) != "Apple"
        }
    }
    return cuChildElements(element)
}

func cuShouldSkipChildWalk(role: String, element: AXUIElement) -> Bool {
    guard role == (kAXMenuRole as String) else {
        return false
    }

    guard let visibleChildren = cuRawAttribute(element, name: "AXVisibleChildren") else {
        return true
    }
    guard CFGetTypeID(visibleChildren as CFTypeRef) == CFArrayGetTypeID(),
          let children = visibleChildren as? [AXUIElement]
    else {
        return true
    }
    return children.isEmpty
}

func cuFrameIsVisible(_ frame: CGRect?, in visibleFrame: CGRect) -> Bool {
    guard let frame else {
        return false
    }
    guard frame.width > 0, frame.height > 0, visibleFrame.width > 0, visibleFrame.height > 0 else {
        return false
    }
    return frame.intersects(visibleFrame.insetBy(dx: -1, dy: -1))
}

func cuFrameIsMeaningfullyVisible(_ frame: CGRect?, in visibleFrame: CGRect) -> Bool {
    guard let frame,
          frame.width > 0,
          frame.height > 0,
          visibleFrame.width > 0,
          visibleFrame.height > 0,
          let intersection = cuVisibleIntersection(frame, visibleFrame.insetBy(dx: -1, dy: -1))
    else {
        return false
    }

    let frameArea = frame.width * frame.height
    guard frameArea > 0 else {
        return false
    }

    let visibleArea = intersection.width * intersection.height
    let visibleRatio = visibleArea / frameArea
    return visibleRatio >= 0.25 || (intersection.width >= 8 && intersection.height >= 12)
}

func cuVisibleIntersection(_ lhs: CGRect, _ rhs: CGRect) -> CGRect? {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
        return nil
    }
    return intersection
}

private let rolesThatCanContainVisibleDescendants: Set<String> = [
    kAXApplicationRole as String,
    kAXWindowRole as String,
    kAXGroupRole as String,
    kAXScrollAreaRole as String,
    kAXListRole as String,
    kAXOutlineRole as String,
    kAXTableRole as String,
    kAXRowRole as String,
    kAXColumnRole as String,
    kAXSplitGroupRole as String,
    kAXSplitterRole as String,
    kAXTabGroupRole as String,
    kAXToolbarRole as String,
    "AXWebArea",
    "AXGenericElement",
]

func roleCanContainVisibleDescendants(_ role: String) -> Bool {
    rolesThatCanContainVisibleDescendants.contains(role)
}

private let rolesThatClipVisibleDescendants: Set<String> = [
    kAXScrollAreaRole as String,
    kAXListRole as String,
    kAXOutlineRole as String,
    kAXTableRole as String,
    kAXColumnRole as String,
    kAXTabGroupRole as String,
    "AXWebArea",
]

func roleClipsVisibleDescendants(_ role: String) -> Bool {
    rolesThatClipVisibleDescendants.contains(role)
}

func cuDescendantVisibleClip(
    role: String,
    frame: CGRect?,
    inheritedClip: CGRect
) -> CGRect {
    guard roleClipsVisibleDescendants(role), let frame else {
        return inheritedClip
    }
    return cuVisibleIntersection(frame, inheritedClip) ?? inheritedClip
}

func cuIsAttributeSettable(_ element: AXUIElement, name: String) -> Bool {
    var settable = DarwinBoolean(false)
    let error = AXUIElementIsAttributeSettable(
        element,
        name as CFString,
        &settable
    )
    return error == .success && settable.boolValue
}

func cuCGPoint(from value: AXValue) -> CGPoint? {
    guard AXValueGetType(value) == .cgPoint else {
        return nil
    }

    var point = CGPoint.zero
    return AXValueGetValue(value, .cgPoint, &point) ? point : nil
}

func cuCGSize(from value: AXValue) -> CGSize? {
    guard AXValueGetType(value) == .cgSize else {
        return nil
    }

    var size = CGSize.zero
    return AXValueGetValue(value, .cgSize, &size) ? size : nil
}

func cuCGWindows(for pid: pid_t) -> [CUWindowSnapshot] {
    guard
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    else {
        return []
    }

    return info.compactMap { entry in
        guard
            let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
            ownerPID == Int(pid),
            let windowID = entry[kCGWindowNumber as String] as? Int,
            let layer = entry[kCGWindowLayer as String] as? Int
        else {
            return nil
        }

        let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
        let name = entry[kCGWindowName as String] as? String ?? ""
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? -1
        let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0) } ?? .null

        return CUWindowSnapshot(
            windowID: windowID,
            ownerName: ownerName,
            name: name,
            layer: layer,
            alpha: alpha,
            bounds: bounds
        )
    }
}

func mergeAXWindowCandidates(
    listedWindows: [AXUIElement],
    focusedWindow: AXUIElement?,
    mainWindow: AXUIElement?
) -> [AXUIElement] {
    var merged: [AXUIElement] = []

    for candidate in listedWindows + [focusedWindow, mainWindow].compactMap(\.self) {
        if merged.contains(where: { CFEqual($0, candidate) }) {
            continue
        }
        merged.append(candidate)
    }

    return merged
}
