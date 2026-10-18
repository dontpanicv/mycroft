// Acting on elements, ported from jev-use's `Desktop.perform`, `focus`, `select`, `click`, `wheel` and `postKey`
// (https://github.com/savka777/jev-use, MIT, Copyright (c) 2026 Savva Bojko). Changes: errors carry the protocol's codes,
// PRESS falls back to AXConfirm and AXPick, a menu is pressed by path, keys come from `KeyStroke`, a scroll is one
// screen per time, and nothing secure is typed.

import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum AXActions {
    static func check(_ result: AXError, _ what: String) throws(DesktopError) {
        guard result == .success else { throw .failed("The app refused to \(what) (Accessibility error \(result.rawValue)).") }
    }

    static func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    // MARK: Target app and window

    /// Brings the observed app to the front if it is not already, as jev-use does before acting.
    static func bringToFront(_ target: TargetApp) throws(DesktopError) {
        guard let running = NSRunningApplication(processIdentifier: target.pid), !running.isTerminated else {
            throw .stale("\(target.name) has quit since the observation. Call ui.observe again.")
        }
        if AX.frontmostPID() == target.pid { return }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if waitForFront(target.pid, upTo: 0.5) { return }
        running.activate(options: [])
        if waitForFront(target.pid, upTo: 0.7) { return }
        throw .failed("Could not bring \(target.name) to the front; nothing was done.")
    }

    static func waitForFront(_ pid: pid_t, upTo seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if AX.frontmostPID() == pid { return true }
            sleep(0.03)
        } while Date() < deadline
        return AX.frontmostPID() == pid
    }

    /// The element still exists, still has its label, and its window is still the app's focused window.
    static func checkCurrent(_ handle: AXHandle, label shown: String, allowOtherWindow: Bool = false) throws(DesktopError) {
        guard AX.isAlive(handle.element) else {
            throw .stale("“\(shown)” is no longer on screen. Call ui.observe again.")
        }
        guard AX.label(handle.element) == handle.ownLabel else {
            throw .stale("“\(shown)” changed since the observation. Call ui.observe again.")
        }
        if !allowOtherWindow, let window = handle.window {
            let app = AXUIElementCreateApplication(handle.pid)
            guard let focused = AX.focusedWindow(app), CFEqual(focused, window) else {
                throw .stale("The window changed since the observation. Call ui.observe again.")
            }
        }
    }

    // MARK: PRESS, SELECT, FOCUS, CLICK

    static func press(_ handle: AXHandle, label shown: String, appName: String) throws(DesktopError) -> String {
        let isMenuItem = handle.role == kAXMenuItemRole
        try checkCurrent(handle, label: shown, allowOtherWindow: isMenuItem)
        guard (AX.attribute(handle.element, kAXEnabledAttribute) as? Bool) != false else {
            throw .failed("“\(shown)” is disabled.")
        }
        let available = AX.actions(handle.element)
        let preferred = [handle.pressAction, kAXPressAction, kAXConfirmAction, kAXPickAction].compactMap { $0 }
        guard let action = preferred.first(where: available.contains) else {
            throw .failed("“\(shown)” has no press action (it offers \(available.isEmpty ? "none" : available.joined(separator: ", "))). Try CLICK.")
        }
        try check(AXUIElementPerformAction(handle.element, action as CFString), "press “\(shown)”")
        sleep(0.1)
        return "Pressed “\(shown)” in \(appName)"
    }

    static func select(_ target: AXUIElement) {
        AXUIElementSetAttributeValue(target, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        // Some tables take the selection only on the table itself.
        guard (AX.attribute(target, kAXSelectedAttribute) as? Bool) != true else { return }
        var parent = AX.element(AX.attribute(target, kAXParentAttribute))
        for _ in 0..<6 {
            guard let table = parent else { return }
            if AX.isSettable(table, kAXSelectedRowsAttribute) {
                AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [target] as CFArray)
                return
            }
            parent = AX.element(AX.attribute(table, kAXParentAttribute))
        }
    }

    static func select(_ handle: AXHandle, label shown: String, appName: String) throws(DesktopError) -> String {
        try checkCurrent(handle, label: shown)
        select(handle.element)
        sleep(0.1)
        guard (AX.attribute(handle.element, kAXSelectedAttribute) as? Bool) == true else {
            throw .failed("“\(shown)” did not take the selection. Try CLICK.")
        }
        return "Selected “\(shown)” in \(appName)"
    }

    /// Focuses an input: through Accessibility, or with a click at its centre for inputs (mostly in web pages) that only
    /// take focus from a click.
    static func focus(_ target: AXUIElement, pid: pid_t) throws(DesktopError) {
        let app = AXUIElementCreateApplication(pid)
        func focused() -> Bool { AX.focusedElement(app).map { CFEqual($0, target) } ?? false }
        if focused() { return }
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        sleep(0.06)
        if focused() { return }
        guard let frame = AX.frame(target), frame.width > 0, frame.height > 0 else {
            throw .failed("The input did not accept focus.")
        }
        try click(at: CGPoint(x: frame.midX, y: frame.midY), pid: pid)
        sleep(0.2)
        guard focused() else { throw .failed("The input did not accept focus, even after a click.") }
    }

    static func focus(_ handle: AXHandle, label shown: String, appName: String) throws(DesktopError) -> String {
        try checkCurrent(handle, label: shown)
        guard !AX.isSecure(handle.element) else { throw .failed("“\(shown)” is a secure text field; it is not touched.") }
        try focus(handle.element, pid: handle.pid)
        return "Focused “\(shown)” in \(appName)"
    }

    /// `throughSystem` sends the click the way a mouse does (some apps ignore events posted to their process), and puts
    /// the pointer back where the user left it.
    static func click(at centre: CGPoint, pid: pid_t, throughSystem: Bool = false) throws(DesktopError) {
        let pointer = CGEvent(source: nil)?.location
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: centre, mouseButton: .left) else {
                throw .failed("Could not create the click event.")
            }
            event.flags = []
            if throughSystem { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
        }
        if throughSystem, let pointer {
            usleep(60_000)
            CGWarpMouseCursorPosition(pointer)
        }
    }

    static func click(_ handle: AXHandle, label shown: String, appName: String) throws(DesktopError) -> String {
        try checkCurrent(handle, label: shown, allowOtherWindow: handle.role == kAXMenuItemRole)
        let target = handle.element
        let app = AXUIElementCreateApplication(handle.pid)
        guard let frame = AX.frame(target), frame.width > 0, frame.height > 0 else {
            throw .stale("“\(shown)” has no place on screen now. Call ui.observe again.")
        }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        // Click only when the item itself is what a pointer would land on there: not an overlay, not a gap.
        var under: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(centre.x), Float(centre.y), &under) == .success, var hit = under else {
            throw .failed("“\(shown)” is covered; nothing was clicked.")
        }
        let deepest = hit
        var lands = CFEqual(hit, target)
        for _ in 0..<4 where !lands {
            guard let parent = AX.element(AX.attribute(hit, kAXParentAttribute)) else { break }
            hit = parent
            lands = CFEqual(hit, target)
        }
        guard lands else { throw .failed("Something else is on top of “\(shown)”; nothing was clicked.") }
        let isRow = [kAXRowRole, kAXCellRole].contains(handle.role)
        // A row whose centre holds its own control would give that control the click; select the row instead.
        if isRow, !CFEqual(deepest, target),
           AX.actions(deepest).contains(kAXPressAction) || AX.editableRoles.contains(AX.role(deepest)) {
            select(target)
            sleep(0.1)
            return "Selected “\(shown)” in \(appName)"
        }
        // The click goes to whatever is on top on the whole screen, so the target's app must be what is on top there.
        var onTop: AXUIElement?
        var owner: pid_t = 0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(centre.x), Float(centre.y), &onTop) == .success,
              let onTop, AXUIElementGetPid(onTop, &owner) == .success, owner == handle.pid else {
            let covering = NSRunningApplication(processIdentifier: owner)?.localizedName ?? "Another window"
            throw .failed("\(covering) covers “\(shown)”; nothing was clicked.")
        }
        try click(at: centre, pid: handle.pid, throughSystem: true)
        sleep(0.15)
        // Finder's rows take the click and ignore an AX selection; System Settings' rows do the reverse.
        if isRow, (AX.attribute(target, kAXSelectedAttribute) as? Bool) == false {
            select(target)
            sleep(0.1)
        }
        return "Clicked “\(shown)” in \(appName)"
    }

    // MARK: TYPE_TEXT

    static func type(_ text: String, into handle: AXHandle?, label shown: String?, target: TargetApp) throws(DesktopError) -> String {
        let pid = target.pid
        let app = AXUIElementCreateApplication(pid)
        var field: AXUIElement?
        if let handle {
            try checkCurrent(handle, label: shown ?? "")
            guard !AX.isSecure(handle.element) else { throw .failed("“\(shown ?? "")” is a secure text field; secure text is never typed.") }
            guard (AX.attribute(handle.element, kAXEnabledAttribute) as? Bool) != false else { throw .failed("“\(shown ?? "")” is disabled.") }
            try focus(handle.element, pid: pid)
            field = handle.element
        } else {
            field = AX.focusedElement(app)
        }
        if let field, AX.isSecure(field) { throw .failed("A secure text field has focus; secure text is never typed.") }
        if AXTree.secureEventInput() { throw .failed("Secure input is active (a password field or Secure Keyboard Entry); nothing was typed.") }
        guard AX.frontmostPID() == pid else { throw .failed("\(target.name) is no longer in front; nothing was typed.") }

        var inserted = false
        if let field, AX.isSettable(field, kAXSelectedTextAttribute),
           AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
           (AX.attribute(field, kAXValueAttribute) as? String)?.contains(text) == true {
            inserted = true
        }
        if !inserted {
            for character in text {
                try postCharacter(character, pid: pid)
                usleep(2_000)
            }
            sleep(0.25)
        }
        let name = field.map { AX.label($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? shown ?? "the focused field"
        let shows = field.flatMap { AX.attribute($0, kAXValueAttribute) as? String }?.contains(text) == true
        return shows ? "Typed \(text.count) characters into “\(name)” in \(target.name)"
            : "Sent \(text.count) characters to “\(name)” in \(target.name), but they do not show there yet"
    }

    /// One character as a unicode key event; a line break and a tab are sent as their keys.
    static func postCharacter(_ character: Character, pid: pid_t) throws(DesktopError) {
        if character == "\n" || character == "\r\n" || character == "\r" { return try postKey(36, flags: [], pid: pid) }
        if character == "\t" { return try postKey(48, flags: [], pid: pid) }
        var units = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw .failed("Could not create the typing event.")
        }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.flags = []
        up.flags = []
        down.postToPid(pid)
        up.postToPid(pid)
    }

    // MARK: PRESS_KEY

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags, pid: pid_t) throws(DesktopError) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
            throw .failed("Could not create the keyboard event.")
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }

    static func press(_ stroke: KeyStroke, times: Int, target: TargetApp) throws(DesktopError) -> String {
        let app = AXUIElementCreateApplication(target.pid)
        if stroke.isCharacter, stroke.modifiers.subtracting(.shift).isEmpty,
           AXTree.secureEventInput() || (AX.focusedElement(app).map(AX.isSecure) ?? false) {
            throw .failed("Secure input is active; characters are not typed into it.")
        }
        for index in 0..<times {
            switch stroke.key {
            case .code(let code): try postKey(code, flags: stroke.flags, pid: target.pid)
            case .character(let text):
                var units = Array(text.utf16)
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                    throw .failed("Could not create the keyboard event.")
                }
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down.flags = stroke.flags
                up.flags = stroke.flags
                down.postToPid(target.pid)
                up.postToPid(target.pid)
            }
            if index < times - 1 { sleep(0.15) }
        }
        return "Pressed \(stroke.name)\(times > 1 ? " \(times) times" : "") in \(target.name)"
    }

    // MARK: SCROLL

    /// Scroll events posted to one process are ignored by some apps, like clicks. A wheel event sent through the system
    /// goes to whatever is under the pointer, so the pointer is put over the app's window for the moment, only when that
    /// app really is what is on top there, and then put back. Each time scrolls about one screen of the window.
    static func scroll(_ direction: ScrollDirection, times: Int, target: TargetApp) throws(DesktopError) -> String {
        let pid = target.pid
        let app = AXUIElementCreateApplication(pid)
        let window = AX.focusedWindow(app)
        var middle: CGPoint?
        var area: AXUIElement?
        var height: CGFloat = 600
        if let window, let frame = AX.frame(window) {
            let candidate = CGPoint(x: frame.minX + frame.width * 0.6, y: frame.minY + frame.height * 0.55)
            height = frame.height
            var onTop: AXUIElement?
            var owner: pid_t = 0
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(candidate.x), Float(candidate.y), &onTop) == .success,
               let onTop, AXUIElementGetPid(onTop, &owner) == .success, owner == pid {
                middle = candidate
                var current: AXUIElement? = onTop
                for _ in 0..<25 {
                    guard let node = current else { break }
                    if AX.role(node) == kAXScrollAreaRole { area = node; break }
                    current = AX.element(AX.attribute(node, kAXParentAttribute))
                }
            }
        }
        if let area, let frame = AX.frame(area), frame.height > 0 { height = frame.height }
        func position() -> Double? {
            guard let area, let bar = AX.element(AX.attribute(area, kAXVerticalScrollBarAttribute)) else { return nil }
            return (AX.attribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue
        }
        let before = position()
        // One screen, less a little overlap so the reader keeps their place.
        let amount = Int32(max(80, height * 0.85)) * (direction == .down ? -1 : 1)
        let pointer = CGEvent(source: nil)?.location
        if let middle {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: middle, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(40_000)
        }
        for _ in 0..<times {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else {
                throw .failed("Could not create the scroll event.")
            }
            event.flags = []
            if middle != nil { event.post(tap: .cghidEventTap) } else { event.postToPid(pid) }
            sleep(0.12)
        }
        if middle != nil, let pointer { CGWarpMouseCursorPosition(pointer) }
        sleep(0.15)
        var outcome = ""
        if let before, let after = position() {
            outcome = abs(after - before) > 0.0005 ? ": the content moved"
                : ": the content did not move, it is already at the \(direction == .down ? "end" : "start")"
        }
        return "Scrolled \(direction.rawValue)\(times > 1 ? " \(times) times" : "") in \(target.name)\(outcome)"
    }

    // MARK: MENU

    /// Finds `path` in the app's menu bar and presses the item.
    static func menu(_ path: MenuPath, target: TargetApp) throws(DesktopError) -> String {
        let app = AXUIElementCreateApplication(target.pid)
        guard let menuBar = AX.element(AX.attribute(app, kAXMenuBarAttribute)) else {
            throw .notFound("\(target.name) has no menu bar.")
        }
        var items = AX.attribute(menuBar, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var current: AXUIElement?
        for (depth, component) in path.components.enumerated() {
            let titles = items.map(AX.label)
            guard let index = MenuPath.match(component, in: titles) else {
                let walked = path.components.prefix(depth).joined(separator: MenuPath.separator)
                throw .notFound("No menu item “\(component)”\(walked.isEmpty ? " in the menu bar" : " under \(walked)") of \(target.name).")
            }
            current = items[index]
            if depth < path.components.count - 1 {
                // A menu bar item and a submenu item hold their menu as the first child.
                guard let submenu = (AX.attribute(items[index], kAXChildrenAttribute) as? [AXUIElement])?.first else {
                    throw .notFound("“\(titles[index])” in \(target.name) has no submenu.")
                }
                items = AX.attribute(submenu, kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
        }
        guard let item = current else { throw .invalid("Empty menu path.") }
        guard (AX.attribute(item, kAXEnabledAttribute) as? Bool) != false else {
            throw .failed("The menu item \(path) is disabled.")
        }
        try check(AXUIElementPerformAction(item, kAXPressAction as CFString), "choose \(path)")
        sleep(0.1)
        return "Chose \(path) in \(target.name)"
    }
}
