import AppKit
import SwiftTerm
import Testing
@testable import GPUWorkbench

@MainActor
struct TerminalFocusTests {
    @Test func terminalViewportDoesNotInterceptClicksOutsideItsBounds() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let viewport = TerminalViewport(frame: NSRect(x: 20, y: 30, width: 160, height: 160))
        let child = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 240))
        parent.addSubview(viewport)
        viewport.addSubview(child)

        #expect(viewport.hitTest(NSPoint(x: 30, y: 40)) === child)
        #expect(viewport.hitTest(NSPoint(x: 30, y: 220)) == nil)
    }

    @Test func mountingReselectingAndClickingTerminalRestoresKeyboardFocus() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content
        let field = NSTextField(frame: NSRect(x: 0, y: 400, width: 160, height: 30))
        content.addSubview(field)
        #expect(window.makeFirstResponder(field))

        let terminal = WorkbenchTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 390))
        content.addSubview(terminal)
        await drainFocusRequest()
        #expect(window.firstResponder === terminal)

        #expect(window.makeFirstResponder(field))
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        terminal.mouseDown(with: click)
        #expect(window.firstResponder === terminal)

        #expect(window.makeFirstResponder(field))
        terminal.focusKeyboard()
        await drainFocusRequest()
        #expect(window.firstResponder === terminal)

        #expect(window.makeFirstResponder(field))
        terminal.focusKeyboard()
        terminal.removeFromSuperview()
        await drainFocusRequest()
        #expect(window.firstResponder !== terminal)
    }

    @Test func terminalEncodesCommonKeysForSSHAndTmux() throws {
        _ = NSApplication.shared
        let terminal = WorkbenchTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 390))
        let recorder = KeyRecorder()
        terminal.terminalDelegate = recorder
        let cases: [(String, String, UInt16, NSEvent.ModifierFlags, [UInt8])] = [
            ("a", "a", 0, [], [97]),
            ("\r", "\r", 36, [], [13]),
            ("\u{7f}", "\u{7f}", 51, [], [127]),
            ("\t", "\t", 48, [], [9]),
            ("\u{02}", "b", 11, .control, [2]),
            ("\u{03}", "c", 8, .control, [3]),
            ("\u{f702}", "\u{f702}", 123, .function, [27, 91, 68]),
            ("\u{f703}", "\u{f703}", 124, .function, [27, 91, 67]),
        ]
        for (characters, base, code, modifiers, expected) in cases {
            recorder.bytes.removeAll()
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: base, isARepeat: false, keyCode: code))
            terminal.keyDown(with: event)
            #expect(recorder.bytes == expected, "Key code \(code)")
        }
    }

    private func drainFocusRequest() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private final class KeyRecorder: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
