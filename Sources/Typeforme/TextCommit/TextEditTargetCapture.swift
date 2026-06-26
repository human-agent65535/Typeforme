import AppKit
import ApplicationServices

enum TextEditTargetKind {
    case selection
    case focusedValue
}

struct TextEditTargetSnapshot {
    let kind: TextEditTargetKind
    let element: AXUIElement
    let targetText: String
    let contextBefore: String
    let contextAfter: String
    let targetRange: CFRange?
}

enum TextEditTargetCapture {
    private static let contextLimit = 600

    @MainActor
    static func snapshot(
        in appSnapshot: FrontmostAppSnapshot?,
        allowFocusedValue: Bool
    ) -> TextEditTargetSnapshot? {
        guard AppPermissions.accessibilityTrusted else { return nil }
        guard let appSnapshot else { return nil }
        let app = AXUIElementCreateApplication(appSnapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = focusedElement(in: app) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        guard !isSecureTextElement(focused) else { return nil }

        let selectedRange = selectedRange(in: focused)
        if let selected = stringAttribute(kAXSelectedTextAttribute, from: focused),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let context = contextAroundSelection(in: focused)
            return TextEditTargetSnapshot(
                kind: .selection,
                element: focused,
                targetText: selected,
                contextBefore: context.before,
                contextAfter: context.after,
                targetRange: selectedRange
            )
        }

        guard allowFocusedValue,
              let value = stringAttribute(kAXValueAttribute, from: focused),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return TextEditTargetSnapshot(
            kind: .focusedValue,
            element: focused,
            targetText: value,
            contextBefore: "",
            contextAfter: "",
            targetRange: CFRange(location: 0, length: (value as NSString).length)
        )
    }

    static func currentSelectedText(in appSnapshot: FrontmostAppSnapshot?) -> String? {
        currentSelection(in: appSnapshot)?.text
    }

    static func currentSelection(in appSnapshot: FrontmostAppSnapshot?) -> (text: String, range: CFRange?)? {
        guard AppPermissions.accessibilityTrusted else { return nil }
        guard let appSnapshot else { return nil }
        let app = AXUIElementCreateApplication(appSnapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = focusedElement(in: app) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        guard !isSecureTextElement(focused) else { return nil }
        guard let text = stringAttribute(kAXSelectedTextAttribute, from: focused) else { return nil }
        return (text, selectedRange(in: focused))
    }

    static func selectionStillMatches(_ target: TextEditTargetSnapshot, in appSnapshot: FrontmostAppSnapshot?) -> Bool {
        guard AppPermissions.accessibilityTrusted else { return false }
        guard let appSnapshot else { return false }
        guard let focused = currentFocusedElement(in: appSnapshot),
              sameElement(focused, target.element),
              !isSecureTextElement(focused),
              let currentText = stringAttribute(kAXSelectedTextAttribute, from: focused),
              currentText == target.targetText,
              let capturedRange = target.targetRange,
              let currentRange = selectedRange(in: focused),
              sameRange(currentRange, capturedRange)
        else { return false }
        return true
    }

    static func focusedValueStillMatches(_ target: TextEditTargetSnapshot, in appSnapshot: FrontmostAppSnapshot?) -> Bool {
        guard AppPermissions.accessibilityTrusted else { return false }
        guard let appSnapshot else { return false }
        guard let focused = currentFocusedElement(in: appSnapshot),
              sameElement(focused, target.element),
              !isSecureTextElement(focused),
              stringAttribute(kAXValueAttribute, from: focused) == target.targetText
        else { return false }
        return true
    }

    @MainActor
    static func focusedTextContext(in appSnapshot: FrontmostAppSnapshot?) -> (before: String, after: String) {
        guard AppPermissions.accessibilityTrusted else { return ("", "") }
        guard let appSnapshot else { return ("", "") }
        let app = AXUIElementCreateApplication(appSnapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = focusedElement(in: app) else { return ("", "") }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        guard !isSecureTextElement(focused) else { return ("", "") }
        return contextAroundSelection(in: focused)
    }

    static func currentValue(of target: TextEditTargetSnapshot) -> String? {
        stringAttribute(kAXValueAttribute, from: target.element)
    }

    static func setFocusedValue(_ text: String, target: TextEditTargetSnapshot) -> Bool {
        let element = target.element
        var settable = DarwinBoolean(false)
        let check = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard check == .success, settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef) == .success
    }

    static func selectedRange(in element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        let axValue = rangeRef as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            return nil
        }
        return range
    }

    private static func currentFocusedElement(in appSnapshot: FrontmostAppSnapshot) -> AXUIElement? {
        let app = AXUIElementCreateApplication(appSnapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = focusedElement(in: app) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        return focused
    }

    private static func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        if CFEqual(lhs, rhs) { return true }
        var lhsPID = pid_t()
        var rhsPID = pid_t()
        guard AXUIElementGetPid(lhs, &lhsPID) == .success,
              AXUIElementGetPid(rhs, &rhsPID) == .success,
              lhsPID == rhsPID
        else { return false }
        guard let lhsIdentifier = stringAttribute(kAXIdentifierAttribute, from: lhs),
              let rhsIdentifier = stringAttribute(kAXIdentifierAttribute, from: rhs),
              !lhsIdentifier.isEmpty,
              lhsIdentifier == rhsIdentifier
        else { return false }
        return stringAttribute(kAXRoleAttribute, from: lhs) == stringAttribute(kAXRoleAttribute, from: rhs)
            && stringAttribute(kAXSubroleAttribute, from: lhs) == stringAttribute(kAXSubroleAttribute, from: rhs)
    }

    private static func sameRange(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }

    private static func focusedElement(in app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success else {
            return nil
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func intAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    private static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        let values = [
            stringAttribute(kAXRoleAttribute, from: element),
            stringAttribute(kAXSubroleAttribute, from: element),
            stringAttribute(kAXDescriptionAttribute, from: element),
            stringAttribute(kAXTitleAttribute, from: element)
        ]
        return values.contains { value in
            guard let value else { return false }
            let lower = value.lowercased()
            return lower.contains("secure") || lower.contains("password")
        }
    }

    private static func contextAroundSelection(in element: AXUIElement) -> (before: String, after: String) {
        guard let range = selectedRange(in: element) else { return ("", "") }
        let start = max(0, range.location - contextLimit)
        let beforeLength = range.location - start
        let afterStart = range.location + range.length

        if let documentLength = intAttribute(kAXNumberOfCharactersAttribute, from: element),
           range.location <= documentLength {
            let afterLength = min(contextLimit, max(0, documentLength - afterStart))
            if let before = stringForRange(CFRange(location: start, length: beforeLength), in: element),
               let after = stringForRange(CFRange(location: afterStart, length: afterLength), in: element) {
                return (before, after)
            }
        }

        return contextAroundSelectionFromFullValue(in: element, selectedRange: range)
    }

    private static func stringForRange(_ range: CFRange, in element: AXUIElement) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        if range.length == 0 { return "" }
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func contextAroundSelectionFromFullValue(
        in element: AXUIElement,
        selectedRange range: CFRange
    ) -> (before: String, after: String) {
        guard let fullValue = stringAttribute(kAXValueAttribute, from: element) else {
            return ("", "")
        }
        let ns = fullValue as NSString
        guard range.location <= ns.length else { return ("", "") }
        let start = max(0, range.location - contextLimit)
        let beforeLength = range.location - start
        let afterStart = min(ns.length, range.location + range.length)
        let afterLength = min(contextLimit, ns.length - afterStart)
        return (
            ns.substring(with: NSRange(location: start, length: beforeLength)),
            ns.substring(with: NSRange(location: afterStart, length: afterLength))
        )
    }
}
