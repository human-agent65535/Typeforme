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

struct VoiceDraftInsertionTarget {
    let element: AXUIElement
    let originalSelectedRange: CFRange
    let originalSelectedText: String
    let originalValue: String?
}

struct VoiceDraftTextSnapshot {
    let element: AXUIElement
    let originalSelectedRange: CFRange
    let originalSelectedText: String
    let originalValue: String?
    var draftRange: CFRange
    var draftText: String
    var anchorRect: CGRect?
}

enum TextEditTargetCapture {
    private static let contextLimit = 600

    @MainActor
    static func snapshot(
        in appSnapshot: FrontmostAppSnapshot?,
        allowFocusedValue: Bool
    ) -> TextEditTargetSnapshot? {
        guard AccessibilityPermissions.isTrusted else { return nil }
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

    @MainActor
    static func draftInsertionTarget(in appSnapshot: FrontmostAppSnapshot?) -> VoiceDraftInsertionTarget? {
        guard AccessibilityPermissions.isTrusted else { return nil }
        guard let appSnapshot else { return nil }
        let app = AXUIElementCreateApplication(appSnapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = focusedElement(in: app) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        guard !isSecureTextElement(focused),
              let range = selectedRange(in: focused)
        else { return nil }

        return VoiceDraftInsertionTarget(
            element: focused,
            originalSelectedRange: range,
            originalSelectedText: stringAttribute(kAXSelectedTextAttribute, from: focused) ?? "",
            originalValue: stringAttribute(kAXValueAttribute, from: focused)
        )
    }

    static func draftInsertionTarget(from target: TextEditTargetSnapshot) -> VoiceDraftInsertionTarget? {
        guard let range = target.targetRange else { return nil }
        return VoiceDraftInsertionTarget(
            element: target.element,
            originalSelectedRange: range,
            originalSelectedText: target.targetText,
            originalValue: stringAttribute(kAXValueAttribute, from: target.element)
        )
    }

    static func currentSelectedText(in appSnapshot: FrontmostAppSnapshot?) -> String? {
        guard AccessibilityPermissions.isTrusted else { return nil }
        guard let appSnapshot else { return nil }
        let app = AXUIElementCreateApplication(appSnapshot.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = focusedElement(in: app) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        guard !isSecureTextElement(focused) else { return nil }
        return stringAttribute(kAXSelectedTextAttribute, from: focused)
    }

    @MainActor
    static func focusedTextContext(in appSnapshot: FrontmostAppSnapshot?) -> (before: String, after: String) {
        guard AccessibilityPermissions.isTrusted else { return ("", "") }
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

    static func currentValue(of element: AXUIElement) -> String? {
        stringAttribute(kAXValueAttribute, from: element)
    }

    static func setFocusedValue(_ text: String, target: TextEditTargetSnapshot) -> Bool {
        setValue(text, in: target.element)
    }

    static func setValue(_ text: String, in element: AXUIElement) -> Bool {
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

    static func setSelectedRange(_ range: CFRange, in element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    static func bounds(for range: CFRange, in element: AXUIElement) -> CGRect? {
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        ) == .success,
              let boundsRef,
              CFGetTypeID(boundsRef) == AXValueGetTypeID()
        else {
            return elementBounds(element)
        }
        let axValue = boundsRef as! AXValue
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect),
              isUsableBounds(rect)
        else { return elementBounds(element) }
        return rect
    }

    static func elementBounds(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        let rect = CGRect(origin: point, size: size)
        return isUsableBounds(rect) ? rect : nil
    }

    private static func isUsableBounds(_ rect: CGRect) -> Bool {
        rect.minX.isFinite &&
            rect.minY.isFinite &&
            rect.width.isFinite &&
            rect.height.isFinite &&
            rect.width > 1 &&
            rect.height > 1
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
        guard let fullValue = stringAttribute(kAXValueAttribute, from: element) else {
            return ("", "")
        }
        guard let range = selectedRange(in: element) else { return ("", "") }
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
