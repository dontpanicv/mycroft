// The window walk and element building, ported from jev-use's `Desktop.collect` (https://github.com/savka777/jev-use,
// MIT, Copyright (c) 2026 Savva Bojko). Changes: the result is the protocol's element list (role, label, value, place,
// operations) instead of Jev candidates; places follow docs/desktop-protocol.md; app, folder, website, key and window
// candidates are not built here (they are operations of their own in ui.act).

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// An element the AX backend can act on later.
struct AXHandle: ElementHandle {
    let element: AXUIElement
    let pid: pid_t
    /// The window the element was read in; acting checks it is still the focused one.
    let window: AXUIElement?
    let role: String
    /// The element's own label at observation time; acting compares it to detect a changed control.
    let ownLabel: String
    /// The press action found at observation time (AXPress, AXConfirm, AXPick or AXShowMenu).
    let pressAction: String?
}

struct AXCapture {
    var window: AXUIElement?
    var windowTitle: String?
    var otherWindows: Int
    var elements: [SnapshotElement]
    var menus: [String]
    var secureInputActive: Bool
}

enum AXTree {
    static let log = Logger(subsystem: "dev.mycroft.hands-desktop", category: "tree")
    /// A cap on walked controls, so a pathological tree cannot stall the helper.
    static let walkLimit = 6000

    // MARK: Chromium web content

    static func usesChromium(_ application: NSRunningApplication) -> Bool {
        guard let frameworks = application.bundleURL?.appendingPathComponent("Contents/Frameworks"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return false }
        func hasRendererHelper(_ entries: [String]) -> Bool { entries.contains { $0.hasSuffix("(Renderer).app") } }
        if hasRendererHelper(names) { return true }
        for name in names where name.hasSuffix(".framework") {
            let helpers = frameworks.appendingPathComponent("\(name)/Versions/Current/Helpers")
            if let inner = try? FileManager.default.contentsOfDirectory(atPath: helpers.path), hasRendererHelper(inner) { return true }
        }
        return false
    }

    private static let browsers = ["com.brave.browser", "com.google.chrome", "com.apple.safari", "com.microsoft.edgemac", "org.mozilla.firefox"]
    static func isBrowser(_ application: NSRunningApplication) -> Bool { browsers.contains(application.bundleIdentifier?.lowercased() ?? "") }

    private struct WebContentState {
        var pokedProcesses = Set<pid_t>()
        var windowsWithoutWebContent = Set<AXUIElement>()
    }
    private static let webContent = Locked(WebContentState())

    /// Chromium serialises web content for Accessibility only after a client asks. Ask once per process, then wait briefly.
    static func waitForWebContent(app: AXUIElement, pid: pid_t) -> Bool {
        var loading = false
        func present() -> Bool {
            guard let window = AX.focusedWindow(app) else { return false }
            var pending = [window]
            var visited = 0
            var found = false
            loading = false
            while let control = pending.popLast(), visited < 600 {
                visited += 1
                let info = AX.read(control)
                if info.role == "AXWebArea" {
                    if !info.children.isEmpty { found = true }
                    if (AX.attribute(control, "AXLoaded") as? Bool) == false { loading = true }
                    continue
                }
                pending.append(contentsOf: info.children.reversed())
            }
            return found && !loading
        }
        if present() { return true }
        guard let window = AX.focusedWindow(app) else { return false }
        let (gaveUp, firstAsk) = webContent.with { state in
            (state.windowsWithoutWebContent.contains(window), state.pokedProcesses.insert(pid).inserted)
        }
        if gaveUp { return false }
        // Electron honours AXManualAccessibility; Chromium browsers honour AXEnhancedUserInterface. Set once per process.
        if firstAsk {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        let began = Date()
        var askedAgain = firstAsk
        while Date().timeIntervalSince(began) < 3 {
            Thread.sleep(forTimeInterval: 0.1)
            if present() { return true }
            // Chromium can drop its tree after a navigation; ask once more when it stays away.
            if !askedAgain, Date().timeIntervalSince(began) > 0.8 {
                askedAgain = true
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }
        log.notice("Web content \(loading ? "was still loading" : "did not appear", privacy: .public) for pid \(pid) after 3s")
        if loading || (NSRunningApplication(processIdentifier: pid).map(isBrowser) ?? false) { return false }
        webContent.with { _ = $0.windowsWithoutWebContent.insert(window) }
        return false
    }

    // MARK: Capture

    enum Verb { case type, press(String), select, clickAt }

    private struct Node {
        let element: AXUIElement, info: AX.Control, parent: Int, inPage: Bool, container: String, region: String?, clip: CGRect?
    }

    private struct Item {
        let element: AXUIElement, verb: Verb, info: AX.Control, name: String, inPage: Bool, position: CGPoint, container: String, region: String?
        /// Rows also take a click at their centre.
        var clickable: Bool
    }

    /// Reads the app's focused window and its menu bar. `pokeChromium` lets Chromium and Electron apps be asked to expose
    /// their web content (it sets an accessibility flag on the app; it is not a UI action).
    static func capture(application: NSRunningApplication, maxElements: Int, pokeChromium: Bool = true) -> AXCapture {
        let pid = application.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        let isChromium = usesChromium(application)
        if isChromium, pokeChromium { _ = waitForWebContent(app: app, pid: pid) }
        let window = AX.focusedWindow(app) ?? (AX.attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        let focusedInput = AX.focusedElement(app)
        let secureFocused = focusedInput.map(AX.isSecure) ?? false
        let allWindows = (AX.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            (AX.attribute($0, kAXMinimizedAttribute) as? Bool) != true
        }
        let otherWindows = window.map { window in allWindows.filter { !CFEqual($0, window) }.count } ?? allWindows.count
        var capture = AXCapture(window: window, windowTitle: window.map(AX.label).flatMap { $0.isEmpty ? nil : $0 },
                                otherWindows: otherWindows, elements: [], menus: [], secureInputActive: secureFocused || secureEventInput())
        if let window {
            capture.elements = elements(app: app, pid: pid, window: window, focusedInput: focusedInput, isChromium: isChromium,
                                        maxElements: maxElements)
        }
        capture.menus = menus(app: app, limit: Available.menusLimit)
        return capture
    }

    /// True while some process has secure keyboard entry on (a password field has focus, or Terminal's Secure Keyboard Entry).
    static func secureEventInput() -> Bool { IsSecureEventInputEnabled() }

    private static func elements(app: AXUIElement, pid: pid_t, window: AXUIElement, focusedInput: AXUIElement?, isChromium: Bool,
                                 maxElements: Int) -> [SnapshotElement] {
        let regions = [kAXToolbarRole: "toolbar", kAXSheetRole: "dialog", "AXPopover": "dialog", kAXMenuRole: "menu",
                       kAXMenuBarRole: "menu", kAXTabGroupRole: "tabs", kAXTableRole: "table", kAXOutlineRole: "list", "AXWebArea": "page"]
        let windowInfo = AX.read(window)
        let windowRegion: String? = [kAXDialogSubrole, kAXSystemDialogSubrole, kAXFloatingWindowSubrole].contains(windowInfo.subrole) ? "dialog" : nil
        var nodes: [Node] = []
        var pending: [(AXUIElement, Int, Bool, String, String?, CGRect?)] = [(window, -1, false, "", windowRegion, windowInfo.frame)]
        var seen: [AXUIElement: Int] = [:]
        var walked = 0

        /// A sidebar is named so by the app, or is the narrow first pane of a split view.
        func sidebarRegion(_ info: AX.Control, parent: Int) -> String? {
            let words = "\(info.identifier) \(info.name) \(info.roleDescription)".lowercased()
            if words.contains("sidebar") || words.contains("source list") || info.subrole == "AXSourceList" { return "sidebar" }
            guard parent >= 0, nodes[parent].info.role == kAXSplitGroupRole, let frame = info.frame, let split = nodes[parent].info.frame,
                  let windowFrame = windowInfo.frame, windowFrame.width > 0 else { return nil }
            if abs(frame.minX - split.minX) < 2, frame.width < windowFrame.width * 0.4, frame.height > split.height * 0.5 { return "sidebar" }
            return nil
        }

        func walk() {
            while let (control, parent, parentInPage, container, parentRegion, parentClip) = pending.popLast(), walked < walkLimit {
                guard seen[control] == nil else { continue }
                seen[control] = -1
                let info = AX.read(control)
                walked += 1
                let inPage = parentInPage || info.role == "AXWebArea"
                // Secure text fields are left out entirely, and so is anything hidden.
                if info.subrole == kAXSecureTextFieldSubrole || info.hidden { continue }
                let below = info.name.isEmpty || info.role == "AXWebArea" ? container : String(info.name.prefix(40))
                // Scroll areas and pages clip what a person can see; controls scrolled out of them are not on screen.
                var clip = parentClip
                if [kAXScrollAreaRole, "AXWebArea"].contains(info.role), let frame = info.frame, frame.width > 0, frame.height > 0 {
                    clip = clip.map { $0.intersection(frame) } ?? frame
                }
                if let frame = info.frame, frame.width > 0, frame.height > 0, let clip, !frame.intersects(clip.insetBy(dx: -200, dy: -200)) {
                    continue
                }
                let region = regions[info.role] ?? sidebarRegion(info, parent: parent) ?? parentRegion
                nodes.append(Node(element: control, info: info, parent: parent, inPage: inPage, container: container, region: region, clip: clip))
                let index = nodes.count - 1
                seen[control] = index
                pending.append(contentsOf: info.children.reversed().map { ($0, index, inPage, below, region, clip) })
            }
        }
        walk()

        // An unreached element (a stale child list, an open menu or pop-up, focus inside a replaced pane) is climbed to its
        // highest unseen ancestor; that subtree is walked under the seen ancestor above it.
        func walkUnreached(from start: AXUIElement) {
            var top = start
            var above = -1
            for _ in 0..<40 {
                guard let parent = AX.element(AX.attribute(top, kAXParentAttribute)),
                      ![kAXApplicationRole, kAXWindowRole].contains(AX.role(parent)) else { break }
                if let index = seen[parent] { above = index; break }
                top = parent
            }
            if above >= 0 {
                let parent = nodes[above]
                pending = [(top, above, parent.inPage, parent.container, parent.region, parent.clip)]
            } else { pending = [(top, -1, isChromium, "", nil, nil)] }
            walk()
        }
        if let focused = focusedInput, seen[focused] == nil, !AX.isSecure(focused) { walkUnreached(from: focused) }

        // A coarse sweep of the window asks macOS what is under each point; anything unseen is climbed and walked like above.
        if let frame = windowInfo.frame, frame.width > 0, frame.height > 0 {
            var y = frame.minY + 48
            while y < frame.maxY, walked < walkLimit {
                var x = frame.minX + 48
                while x < frame.maxX {
                    var found: AXUIElement?
                    if AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &found) == .success, let found, seen[found] == nil,
                       AX.element(AX.attribute(found, kAXWindowAttribute)).map({ CFEqual($0, window) }) ?? false {
                        walkUnreached(from: found)
                    }
                    x += 96
                }
                y += 96
            }
        }

        // What a person reads inside a control names it when it has no name of its own. Children come after their parent
        // in `nodes`, so one backwards pass gathers each node's text and subtree size.
        let readable: Set<String> = [kAXStaticTextRole, kAXImageRole]
        var text = Array(repeating: "", count: nodes.count), subtree = Array(repeating: 0, count: nodes.count)
        var hint = nodes.map(\.info.dom)
        for index in nodes.indices.reversed() {
            let node = nodes[index]
            guard node.parent >= 0 else { continue }
            subtree[node.parent] += subtree[index] + 1
            let said = !node.info.name.isEmpty ? node.info.name : !text[index].isEmpty ? text[index]
                : AX.editableRoles.contains(node.info.role) ? node.info.value ?? "" : ""
            if !said.isEmpty { text[node.parent] = String((text[node.parent].isEmpty ? said : said + " " + text[node.parent]).prefix(160)) }
            if !hint[index].isEmpty, readable.contains(node.info.role) || hint[node.parent].isEmpty { hint[node.parent] = hint[index] }
        }

        let rows: Set<String> = [kAXRowRole, kAXCellRole]
        func isControl(_ role: String) -> Bool {
            role.hasSuffix("Button") || rows.contains(role)
                || ["AXLink", kAXCheckBoxRole, kAXDisclosureTriangleRole, kAXSliderRole, kAXIncrementorRole, kAXMenuItemRole].contains(role)
        }
        var items: [Item] = []
        var isTarget = Array(repeating: false, count: nodes.count), coveredBy = Array(repeating: -1, count: nodes.count)
        var centreClicks: [Int] = []
        var names: [Int: String] = [:]
        for (index, node) in nodes.enumerated() {
            let info = node.info
            let cover = node.parent < 0 ? -1 : (isTarget[node.parent] ? node.parent : coveredBy[node.parent])
            coveredBy[index] = cover
            guard info.enabled else { continue }
            if let frame = info.frame, frame.width > 0, frame.height > 0, let clip = node.clip, !frame.intersects(clip) { continue }
            let position = info.position ?? CGPoint(x: 0, y: Double(index))
            if AX.editableRoles.contains(info.role) {
                isTarget[index] = true
                let held = info.value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                // A row's label drawn as a text field (a file name in a list) is the row itself; the row is the target.
                if cover >= 0, rows.contains(nodes[cover].info.role), !held.isEmpty, !(focusedInput.map { CFEqual($0, node.element) } ?? false) { continue }
                let name = info.name.isEmpty && !held.isEmpty ? "holding '\(held.prefix(40))'" : info.name
                items.append(Item(element: node.element, verb: .type, info: info, name: name, inPage: node.inPage, position: position,
                                  container: node.container, region: node.region, clickable: false))
                continue
            }
            if info.role == "AXWebArea" || (cover >= 0 && (readable.contains(info.role) || rows.contains(info.role))) { continue }
            var name = String((info.name.isEmpty && subtree[index] <= 25 ? text[index] : info.name).prefix(80))
            if name.isEmpty, !info.subrole.isEmpty, !info.roleDescription.isEmpty, isControl(info.role) { name = info.roleDescription }
            if name.isEmpty, subtree[index] <= 25, !hint[index].isEmpty, !readable.contains(info.role) {
                let beside = node.parent >= 0 ? text[node.parent] : ""
                name = "unlabelled \(hint[index])" + (beside.isEmpty || beside.count > 40 ? "" : " next to '\(beside)'")
            }
            guard !name.isEmpty || isControl(info.role) else { continue }
            let available = AX.actions(node.element)
            // Show-menu is a press only where the menu is the control. "Open" is not a press: a click selects.
            let usable = [kAXPressAction, kAXConfirmAction, kAXPickAction]
                + ([kAXPopUpButtonRole, kAXMenuButtonRole, kAXComboBoxRole].contains(info.role) ? [kAXShowMenuAction] : [])
            let hasFrame = info.frame.map { $0.width > 0 && $0.height > 0 } ?? false
            if let action = usable.first(where: { available.contains($0) }) {
                items.append(Item(element: node.element, verb: .press(action), info: info, name: name, inPage: node.inPage, position: position,
                                  container: node.container, region: node.region, clickable: false))
                isTarget[index] = true
            } else if rows.contains(info.role), !name.isEmpty, AX.isSettable(node.element, kAXSelectedAttribute) {
                // A person clicks a row; selection through Accessibility is the route for rows without a frame.
                items.append(Item(element: node.element, verb: .select, info: info, name: name, inPage: node.inPage, position: position,
                                  container: node.container, region: node.region, clickable: hasFrame))
                isTarget[index] = true
            } else if !name.isEmpty, cover < 0, hasFrame,
                      (readable.contains(info.role) && info.name.count <= 40 && name.count <= 40)
                        || (isControl(info.role) && !rows.contains(info.role) && ![kAXSliderRole, kAXIncrementorRole].contains(info.role)) {
                centreClicks.append(index)
                names[index] = name
            }
        }
        // Text and images that accept nothing are clicked at their centre, only when no real target carries that name.
        let taken = Set(items.map(\.name))
        for index in centreClicks.prefix(max(0, min(60, 240 - items.count))) where !taken.contains(names[index]!) {
            let node = nodes[index]
            items.append(Item(element: node.element, verb: .clickAt, info: node.info, name: names[index]!, inPage: node.inPage,
                              position: node.info.position ?? .zero, container: node.container, region: node.region, clickable: true))
        }
        // Custom editors (a rich-text composer) may not use a text role but still accept text.
        if let focused = focusedInput, !items.contains(where: { CFEqual($0.element, focused) }) {
            let info = AX.read(focused)
            if info.subrole != kAXSecureTextFieldSubrole, info.enabled,
               AX.isSettable(focused, kAXValueAttribute) || AX.isSettable(focused, kAXSelectedTextAttribute) {
                items.append(Item(element: focused, verb: .type, info: info, name: info.name, inPage: true, position: info.position ?? .zero,
                                  container: "", region: nil, clickable: false))
            }
        }

        // Screen order (top to bottom, then left to right). Of two same-named things at the same place, the one with a real
        // action comes first and is the one kept.
        func dependable(_ verb: Verb) -> Int { switch verb { case .press, .type: return 0; case .select: return 1; case .clickAt: return 2 } }
        items.sort { lhs, rhs in
            let (ly, ry) = ((lhs.position.y / 12).rounded(), (rhs.position.y / 12).rounded())
            if ly != ry { return ly < ry }
            let (lx, rx) = ((lhs.position.x / 24).rounded(), (rhs.position.x / 24).rounded())
            return lx == rx ? dependable(lhs.verb) < dependable(rhs.verb) : lx < rx
        }
        func isInput(_ verb: Verb) -> Bool { if case .type = verb { return true } else { return false } }
        // The word a person would use for the thing; the system supplies it for every role, in the user's language.
        func kind(_ info: AX.Control) -> String {
            if info.role == kAXGroupRole { return "item" }
            return info.roleDescription.isEmpty ? info.role.replacingOccurrences(of: "AX", with: "").lowercased() : info.roleDescription
        }
        func shownName(_ item: Item) -> String {
            if !item.name.isEmpty { return item.name }
            let base = item.info.dom.isEmpty ? kind(item.info) : "\(kind(item.info)) \(item.info.dom)"
            return item.container.isEmpty ? base : "\(base) in \(item.container)"
        }
        // Only the same label at the same place is a duplicate; the same label elsewhere gets an ordinal.
        var places = Set<String>()
        items = items.filter { places.insert("\(isInput($0.verb))|\(shownName($0))|\(Int($0.position.x / 24))|\(Int($0.position.y / 24))").inserted }
        var totals: [String: Int] = [:], ordinal: [String: Int] = [:]
        for item in items { totals["\(isInput(item.verb))|\(shownName(item))", default: 0] += 1 }

        var result: [SnapshotElement] = []
        for item in items {
            guard result.count < maxElements else { break }
            let key = "\(isInput(item.verb))|\(shownName(item))"
            ordinal[key, default: 0] += 1
            let shown = totals[key]! > 1 ? "\(shownName(item)) (\(ordinal[key]!) of \(totals[key]!))" : shownName(item)
            // A value that is empty or only repeats the name says nothing.
            let value = item.info.value.flatMap {
                $0.isEmpty || $0.trimmingCharacters(in: .whitespaces) == item.name.trimmingCharacters(in: .whitespaces) ? nil : $0
            }
            let place = place(region: item.region, inPage: item.inPage, isChromium: isChromium)
            let operations: [ElementOperation]
            var pressAction: String?
            switch item.verb {
            case .type: operations = [.type, .focus]
            case .press(let action): operations = [.press]; pressAction = action
            case .select: operations = item.clickable ? [.select, .click] : [.select]
            case .clickAt: operations = [.click]
            }
            let handle = AXHandle(element: item.element, pid: pid, window: window, role: item.info.role, ownLabel: item.info.ownLabel,
                                  pressAction: pressAction)
            result.append(SnapshotElement(role: kind(item.info), label: shown, value: value, place: place, operations: operations, handle: handle))
        }
        log.debug("Walked \(walked) controls, \(nodes.count) kept, \(result.count) elements")
        return result
    }

    /// The protocol's places: toolbar, sidebar, content, dialog, menu.
    static func place(region: String?, inPage: Bool, isChromium: Bool) -> Place {
        switch region {
        case "toolbar": return .toolbar
        case "dialog": return .dialog
        case "menu": return .menu
        case "sidebar": return .sidebar
        default: return isChromium && !inPage ? .toolbar : .content
        }
    }

    // MARK: Menus

    /// Enabled menu items as `Menu > Item` paths (and `Menu > Submenu > Item`), skipping the Apple menu and Quit items.
    static func menus(app: AXUIElement, limit: Int) -> [String] {
        guard let menuBar = AX.element(AX.attribute(app, kAXMenuBarAttribute)) else { return [] }
        var paths: [String] = []
        let menus = (AX.attribute(menuBar, kAXChildrenAttribute) as? [AXUIElement] ?? []).dropFirst() // the Apple menu
        for menu in menus {
            let menuName = AX.label(menu)
            guard !menuName.isEmpty, let list = (AX.attribute(menu, kAXChildrenAttribute) as? [AXUIElement])?.first else { continue }
            var pending: [(AXUIElement, [String])] = (AX.attribute(list, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed().map { ($0, [menuName]) }
            while let (item, path) = pending.popLast() {
                guard paths.count < limit else { return paths }
                let info = AX.read(item)
                guard info.role == kAXMenuItemRole, !info.name.isEmpty, info.enabled, !info.name.hasPrefix("Quit ") else { continue }
                if let submenu = info.children.first, path.count < 2 {
                    pending.append(contentsOf: (AX.attribute(submenu, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed().map { ($0, path + [info.name]) })
                    continue
                }
                paths.append((path + [info.name]).joined(separator: MenuPath.separator))
            }
        }
        return paths
    }

    // MARK: Fingerprint

    /// Ported from jev-use's `fingerprint(of:)`, with a digest of the window's roles, labels and values.
    static func fingerprint(pid: pid_t) -> ScreenFingerprint {
        let app = AXUIElementCreateApplication(pid)
        let window = AX.focusedWindow(app)
        let focused = AX.focusedElement(app).map { element -> String in
            let value = AX.isSecure(element) ? "" : String((AX.string(element, kAXValueAttribute) ?? "").prefix(40))
            return "\(AX.role(element))|\(AX.label(element))|\(value)"
        }
        var digest = ScreenFingerprint.Digest()
        var frame: String?
        if let window {
            var pending = [window]
            while let control = pending.popLast(), digest.count < 400 {
                let info = AX.read(control)
                digest.add(role: info.role, label: info.ownLabel, value: info.subrole == kAXSecureTextFieldSubrole ? nil : info.value.map { String($0.prefix(40)) })
                pending.append(contentsOf: info.children.reversed())
            }
            if let rect = AX.frame(window) {
                frame = "\(Int(rect.minX)),\(Int(rect.minY))/\(Int(rect.width))x\(Int(rect.height))"
            }
        }
        return ScreenFingerprint(pid: pid, window: window.map(AX.label), windowFrame: frame, focused: focused,
                                 elementCount: digest.count, digest: digest.value)
    }
}
