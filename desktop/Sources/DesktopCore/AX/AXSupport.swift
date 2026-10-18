// Accessibility helpers ported from jev-use (https://github.com/savka777/jev-use, MIT, Copyright (c) 2026 Savva Bojko),
// Sources/JevDesktop/Desktop.swift: attribute reads, the one-round-trip control read, and label rules.

import AppKit
import ApplicationServices

enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    /// The element's own name: title, description, help or placeholder, the first that says something.
    static func label(_ element: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute] {
            if let text = attribute(element, name) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return ""
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var result: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(attribute(element, kAXPositionAttribute)), let size = size(attribute(element, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var raw: CFArray?
        AXUIElementCopyActionNames(element, &raw)
        return raw as? [String] ?? []
    }

    static func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) ?? "" }

    /// False once the element is gone (its window closed, the app rebuilt that part of its tree).
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return result != .invalidUIElement && result != .cannotComplete
    }

    static func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        element(attribute(app, kAXFocusedWindowAttribute)) ?? element(attribute(app, kAXMainWindowAttribute))
    }

    static func focusedElement(_ app: AXUIElement) -> AXUIElement? { element(attribute(app, kAXFocusedUIElementAttribute)) }

    static func isSecure(_ element: AXUIElement) -> Bool { string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole }

    /// The app that has keyboard focus, read live from the system-wide element; NSWorkspace's answer lags without a run loop.
    static func frontmostPID() -> pid_t? {
        if let app = element(attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)) {
            var pid: pid_t = 0
            if AXUIElementGetPid(app, &pid) == .success, pid > 0 { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static let editableRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    // One Accessibility round trip per control instead of one per attribute.
    static let walkAttributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute, "AXHidden", kAXVisibleChildrenAttribute,
                                 kAXChildrenAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                                 kAXPlaceholderValueAttribute, kAXURLAttribute, kAXPositionAttribute, kAXValueAttribute,
                                 kAXSizeAttribute, "AXDOMIdentifier", "AXDOMClassList", kAXRoleDescriptionAttribute,
                                 kAXSelectedAttribute, kAXExpandedAttribute, kAXTitleUIElementAttribute, kAXVisibleRowsAttribute,
                                 kAXHeaderAttribute, kAXIdentifierAttribute]

    struct Control {
        let role: String, subrole: String, enabled: Bool, hidden: Bool, children: [AXUIElement], name: String, url: URL?, position: CGPoint?, value: String?
        /// How many children the control has in all; `children` holds only the visible ones when the app reports those.
        let allChildren: Int
        /// For telling unnamed controls apart: size, the web element's id or first classes, and the system's word for the role.
        let size: CGSize?, dom: String, roleDescription: String
        /// The element's own label before any richer naming; what `label(_:)` returns later, so what the
        /// "did the control change" check compares.
        let ownLabel: String
        /// State a person can see, present only when the element reports it.
        let selected: Bool?, expanded: Bool?
        /// The app's identifier for the element (AXIdentifier), used to recognise sidebars.
        let identifier: String
        var frame: CGRect? { position.flatMap { origin in size.map { CGRect(origin: origin, size: $0) } } }
    }

    static func read(_ element: AXUIElement) -> Control {
        var raw: CFArray?
        var values: [CFTypeRef?] = Array(repeating: nil, count: walkAttributes.count)
        if AXUIElementCopyMultipleAttributeValues(element, walkAttributes as CFArray, [], &raw) == .success, let raw = raw as [AnyObject]? {
            for (index, value) in raw.enumerated() where index < values.count {
                if CFGetTypeID(value) == CFNullGetTypeID() { continue }
                if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
                values[index] = value
            }
        }
        var name = values[6...9].compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        let ownLabel = name
        // Static text keeps its words in the value (Chromium always does), so a short text node is named by what it says.
        if name.isEmpty, values[0] as? String == kAXStaticTextRole, let text = (values[12] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty { name = String(text.prefix(200)) }
        // An input is usually named by a separate label element next to it.
        if name.isEmpty, let titled = AX.element(values[19]) {
            name = label(titled).isEmpty ? ((attribute(titled, kAXValueAttribute) as? String) ?? "") : label(titled)
        }
        let domID = (values[14] as? String) ?? ""
        let dom = domID.isEmpty ? ((values[15] as? [String]) ?? []).prefix(2).joined(separator: " ") : domID
        let rawURL = values[10]
        // Which children to visit. A small child list is taken whole and the off-screen filter decides per control; only a
        // long list (a table's rows, a folder's files) uses the app's own visible subset, which keeps a 3,000-row window fast.
        let all = values[5] as? [AXUIElement] ?? []
        var children = all
        if all.count > 50 {
            let rows = values[20] as? [AXUIElement] ?? []
            let header = AX.element(values[21]).map { [$0] } ?? []
            children = !rows.isEmpty ? header + rows : (values[4] as? [AXUIElement]) ?? all
        }
        return Control(role: values[0] as? String ?? "", subrole: values[1] as? String ?? "",
                       enabled: (values[2] as? Bool) != false, hidden: (values[3] as? Bool) == true,
                       children: children, name: name,
                       url: rawURL as? URL ?? (rawURL as? String).flatMap { URL(string: $0) }, position: point(values[11]),
                       value: (values[12] as? String).map { String($0.prefix(200)) } ?? (values[12] as? Bool).map { $0 ? "on" : "off" }
                           ?? (values[12] as? NSNumber).map { $0.stringValue },
                       allChildren: all.count, size: size(values[13]), dom: dom, roleDescription: values[16] as? String ?? "",
                       ownLabel: ownLabel, selected: values[17] as? Bool, expanded: values[18] as? Bool,
                       identifier: values[22] as? String ?? "")
    }
}

/// Process-wide caches guarded by a lock (the Chromium web-content bookkeeping and installed apps' names).
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
