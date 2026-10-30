import AppKit
import ApplicationServices
import CoreGraphics
import WorkspaceCore

enum DesktopError: LocalizedError {
    case accessibility, conflict, window(String)
    var errorDescription: String? {
        switch self {
        case .accessibility: "Grant FocusWM Accessibility access in System Settings."
        case .conflict: "Quit AeroSpace before enabling FocusWM."
        case .window(let message): message
        }
    }
}

@MainActor
final class MacDesktop {
    struct Window {
        var element: AXUIElement
        var pid: pid_t
        var appID: String
        var title: String
        var identifier: String
        var frame: Frame
        var minimized: Bool
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func displays() -> [Display] {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid)! as String
            let bounds = CGDisplayBounds(number.uint32Value)
            let visible = screen.visibleFrame
            // AX/CoreGraphics use a top-left origin; AppKit uses bottom-left.
            return Display(id: id, name: screen.localizedName,
                           frame: Frame(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                           usableFrame: Frame(x: visible.minX, y: mainHeight - visible.maxY,
                                              width: visible.width, height: visible.height))
        }
    }

    static func screen(for display: Display) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return false }
            return CFUUIDCreateString(nil, uuid)! as String == display.id
        }
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func frame(_ element: AXUIElement) -> Frame? {
        guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return Frame(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    static func windows() -> [Window] {
        guard trusted else { return [] }
        return NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.flatMap { app -> [Window] in
            guard let appID = app.bundleIdentifier else { return [] }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
            return windows.compactMap { window in
                guard attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                      attribute(window, "AXFullScreen") as? Bool != true,
                      let rect = frame(window) else { return nil }
                var positionSettable = DarwinBoolean(false)
                var sizeSettable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable)
                AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable)
                guard positionSettable.boolValue && sizeSettable.boolValue else { return nil }
                return Window(element: window, pid: app.processIdentifier, appID: appID,
                              title: attribute(window, kAXTitleAttribute) as? String ?? "",
                              identifier: attribute(window, kAXIdentifierAttribute) as? String ?? "",
                              frame: rect,
                              minimized: attribute(window, kAXMinimizedAttribute) as? Bool ?? false)
            }
        }
    }

    static func setMinimized(_ window: Window, _ minimized: Bool) throws {
        let result = AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString,
                                                 minimized ? kCFBooleanTrue : kCFBooleanFalse)
        guard result == .success else { throw DesktopError.window("\(window.appID): minimize failed (\(result.rawValue)).") }
    }

    // Apps that enable AXEnhancedUserInterface (Chrome, Electron, anything a screen reader touched)
    // animate every AX move. Turning it off for the duration makes moves land instantly.
    static func withoutEnhancedUI<T>(_ pid: pid_t, _ body: () throws -> T) rethrows -> T {
        let app = AXUIElementCreateApplication(pid)
        let enhanced = attribute(app, "AXEnhancedUserInterface") as? Bool == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        return try body()
    }

    static func setPosition(_ window: Window, _ target: Frame) {
        var point = CGPoint(x: target.x, y: target.y)
        withoutEnhancedUI(window.pid) {
            _ = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
        }
    }

    static func setFrame(_ window: Window, _ target: Frame) throws {
        if frame(window.element)?.approximatelyEquals(target) == true { return }
        var point = CGPoint(x: target.x, y: target.y)
        var size = CGSize(width: target.width, height: target.height)
        let position = AXValueCreate(.cgPoint, &point)!
        let dimensions = AXValueCreate(.cgSize, &size)!
        try withoutEnhancedUI(window.pid) {
            // Some apps clamp sizes differently depending on the current position.
            _ = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, dimensions)
            let moved = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, position)
            let resized = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, dimensions)
            guard moved == .success, resized == .success,
                  frame(window.element)?.approximatelyEquals(target) == true else {
                throw DesktopError.window("\(window.appID) refused its tile size. Its minimum size may exceed the available tile.")
            }
        }
    }

    static func raise(_ window: Window) {
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    static func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let value = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
