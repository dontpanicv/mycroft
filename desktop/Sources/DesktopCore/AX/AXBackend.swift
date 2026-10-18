// The real backend: Accessibility, NSWorkspace and CGEvent. App, folder and URL handling is adapted from jev-use's
// `Desktop.collect` and `Desktop.perform` (https://github.com/savka777/jev-use, MIT, Copyright (c) 2026 Savva Bojko).

import AppKit
import ApplicationServices

public final class AXBackend: DesktopBackend {
    /// Lets Chromium and Electron apps be asked to expose their web content during ui.observe.
    public var pokeChromium: Bool

    /// Seconds an Accessibility call may wait for an app before giving up (the system default is about 6 s), so a hung
    /// app cannot stall the helper for long.
    public static let messagingTimeout: Float = 1.5

    public init(pokeChromium: Bool = true) {
        self.pokeChromium = pokeChromium
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    public var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own Accessibility prompt for this process. Only the user can grant it.
    public static func requestTrust() -> Bool {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Observe

    public func observe(app: String?, maxElements: Int) throws -> Snapshot {
        let application: NSRunningApplication
        if let app {
            guard let running = Apps.running(matching: app) else {
                throw DesktopError.notFound("No running app matches “\(app)”. Open it first with OPEN_APP.")
            }
            application = running
        } else {
            guard let pid = AX.frontmostPID(), let running = NSRunningApplication(processIdentifier: pid) else {
                throw DesktopError.notFound("No app is in front.")
            }
            application = running
        }
        let capture = AXTree.capture(application: application, maxElements: maxElements, pokeChromium: pokeChromium)
        let available = Available(apps: Apps.availableNames(limit: Available.appsLimit), folders: Apps.availableFolders(),
                                  sites: [], menus: capture.menus)
        return Snapshot(target: Apps.target(application), window: capture.windowTitle, otherWindows: capture.otherWindows,
                        elements: capture.elements, available: available, secureInputActive: capture.secureInputActive)
    }

    public func fingerprint(_ scope: FingerprintScope) -> ScreenFingerprint {
        let pid: pid_t?
        switch scope {
        case .frontmost: pid = AX.frontmostPID()
        case .app(let target): pid = target.pid
        }
        guard let pid, NSRunningApplication(processIdentifier: pid).map({ !$0.isTerminated }) ?? false else { return .empty }
        return AXTree.fingerprint(pid: pid)
    }

    // MARK: Act

    public func perform(_ action: BackendAction) throws -> String {
        switch action {
        case .openApp(let name): return try Apps.open(name)
        case .quitApp(let name): return try Apps.quit(name)
        case .openURL(let url): return try Apps.open(url: url)
        case .openFolder(let url): return try Apps.open(folder: url)
        case .press(let element, let target):
            let handle = try handle(element)
            try AXActions.bringToFront(target)
            return try AXActions.press(handle, label: element.label, appName: target.name)
        case .select(let element, let target):
            let handle = try handle(element)
            try AXActions.bringToFront(target)
            return try AXActions.select(handle, label: element.label, appName: target.name)
        case .click(let element, let target):
            let handle = try handle(element)
            try AXActions.bringToFront(target)
            return try AXActions.click(handle, label: element.label, appName: target.name)
        case .focus(let element, let target):
            let handle = try handle(element)
            try AXActions.bringToFront(target)
            return try AXActions.focus(handle, label: element.label, appName: target.name)
        case .typeText(let text, let element, let target):
            let handle = try element.map(handle)
            try AXActions.bringToFront(target)
            return try AXActions.type(text, into: handle, label: element?.label, target: target)
        case .pressKey(let stroke, let times, let target):
            try AXActions.bringToFront(target)
            return try AXActions.press(stroke, times: times, target: target)
        case .scroll(let direction, let times, let target):
            try AXActions.bringToFront(target)
            return try AXActions.scroll(direction, times: times, target: target)
        case .menu(let path, let target):
            try AXActions.bringToFront(target)
            return try AXActions.menu(path, target: target)
        }
    }

    private func handle(_ element: SnapshotElement) throws(DesktopError) -> AXHandle {
        guard let handle = element.handle as? AXHandle else { throw .stale("The element does not belong to this helper.") }
        return handle
    }
}

/// Running and installed apps, folders, and the app-level operations.
enum Apps {
    static func target(_ app: NSRunningApplication) -> TargetApp {
        TargetApp(pid: app.processIdentifier, name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "app",
                  bundleId: app.bundleIdentifier)
    }

    /// A normal app with windows; background helpers and this process are never targets.
    static func isControllable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && app.bundleIdentifier != "com.apple.WindowManager" && !app.isTerminated
    }

    static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(isControllable)
    }

    /// Matches a bundle id, the app's name or its bundle's file name, ignoring case.
    static func running(matching query: String) -> NSRunningApplication? {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let apps = running()
        return apps.first { $0.bundleIdentifier?.lowercased() == wanted }
            ?? apps.first { $0.localizedName?.lowercased() == wanted }
            ?? apps.first { $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == wanted }
    }

    static let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]

    private struct Installed { let url: URL; let name: String; let identifier: String }
    /// A bundle's name and identifier do not change while it sits at the same path; reading Info.plists is the slow part.
    private static let names = Locked([String: Installed]())

    private static func installed() -> [Installed] {
        var urls: [URL] = []
        for root in roots {
            urls += (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "app" } ?? []
        }
        return urls.compactMap { url in
            if let known = names.with({ $0[url.path] }) { return known }
            guard let bundle = Bundle(url: url) else { return nil }
            let fileName = url.deletingPathExtension().lastPathComponent
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? fileName
            let entry = Installed(url: url, name: name, identifier: bundle.bundleIdentifier ?? "")
            names.with { $0[url.path] = entry }
            return entry
        }
    }

    /// Running apps first, then installed ones, by name, without duplicates.
    static func availableNames(limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for app in running() {
            if let name = app.localizedName, seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        for app in installed().sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            guard result.count < limit else { break }
            if seen.insert(app.name.lowercased()).inserted { result.append(app.name) }
        }
        return Array(result.prefix(limit))
    }

    /// The named folders OPEN_FOLDER accepts that exist. Only the folders are checked; their contents are never listed.
    static func availableFolders() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Targets.namedFolders.filter { name in
            guard let url = try? Targets.folderURL(name, home: home) else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func installedURL(matching query: String) -> URL? {
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if wanted.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: wanted) { return url }
        let lower = wanted.lowercased()
        let apps = installed()
        return apps.first { $0.identifier.lowercased() == lower }?.url
            ?? apps.first { $0.name.lowercased() == lower }?.url
            ?? apps.first { $0.url.deletingPathExtension().lastPathComponent.lowercased() == lower }?.url
    }

    // MARK: Operations

    private final class Completion<Value>: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var value: Value?
        var error: Error?
    }

    static func open(_ query: String) throws(DesktopError) -> String {
        if let running = running(matching: query) {
            let target = target(running)
            if AX.frontmostPID() == target.pid { return "\(target.name) is already in front" }
            try AXActions.bringToFront(target)
            return "Switched to \(target.name)"
        }
        guard let url = installedURL(matching: query) else { throw .notFound("No app named “\(query)” is installed.") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion = Completion<NSRunningApplication>()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            completion.value = app
            completion.error = error
            completion.semaphore.signal()
        }
        guard completion.semaphore.wait(timeout: .now() + 15) == .success else {
            return "Launch requested: \(url.deletingPathExtension().lastPathComponent) is still starting"
        }
        if let error = completion.error { throw .failed("Could not open \(url.lastPathComponent): \(error.localizedDescription)") }
        guard let app = completion.value else { return "Launch requested: \(url.deletingPathExtension().lastPathComponent)" }
        let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
        return AXActions.waitForFront(app.processIdentifier, upTo: 3) ? "Opened \(name)" : "Launch requested: \(name)"
    }

    /// Quits normally with terminate(); the app may ask to save. Never forced.
    static func quit(_ query: String) throws(DesktopError) -> String {
        guard let app = running(matching: query) else { throw .notFound("No running app matches “\(query)”.") }
        let name = app.localizedName ?? query
        guard app.terminate() else { throw .failed("\(name) did not accept the request to quit.") }
        for _ in 0..<20 where !app.isTerminated { AXActions.sleep(0.1) }
        return app.isTerminated ? "Quit \(name)" : "Asked \(name) to quit; it is asking something first, answer it on screen"
    }

    static func open(url: URL) throws(DesktopError) -> String {
        guard let probe = URL(string: "https://example.com"), let browser = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            throw .failed("No default web browser is set.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion = Completion<NSRunningApplication>()
        NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: configuration) { app, error in
            completion.value = app
            completion.error = error
            completion.semaphore.signal()
        }
        let browserName = browser.deletingPathExtension().lastPathComponent
        guard completion.semaphore.wait(timeout: .now() + 15) == .success else { return "Asked \(browserName) to open \(url.host ?? url.absoluteString)" }
        if let error = completion.error { throw .failed("Could not open \(url.absoluteString): \(error.localizedDescription)") }
        if let app = completion.value { _ = AXActions.waitForFront(app.processIdentifier, upTo: 2) }
        return "Opened \(url.host ?? url.absoluteString) in \(browserName)"
    }

    static func open(folder url: URL) throws(DesktopError) -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true else {
            throw .notFound("No folder at \(url.path).")
        }
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            throw .failed("Finder was not found.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion = Completion<NSRunningApplication>()
        NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: configuration) { app, error in
            completion.value = app
            completion.error = error
            completion.semaphore.signal()
        }
        guard completion.semaphore.wait(timeout: .now() + 10) == .success else { return "Asked Finder to open \(url.lastPathComponent)" }
        if let error = completion.error { throw .failed("Could not open \(url.path): \(error.localizedDescription)") }
        if let app = completion.value { _ = AXActions.waitForFront(app.processIdentifier, upTo: 2) }
        return "Opened the folder \(url.lastPathComponent) in Finder"
    }
}
