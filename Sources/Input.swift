import AppKit

enum InputError: Error { case invalid, permission }

final class RemoteInput {
    private var heldButtons = Set<CGMouseButton>()
    private let source = CGEventSource(stateID: .hidSystemState)

    func releaseAll() {
        for button in heldButtons {
            CGEvent(mouseEventSource: source, mouseType: button == .left ? .leftMouseUp : .rightMouseUp, mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero, mouseButton: button)?.post(tap: .cghidEventTap)
        }
        heldButtons.removeAll()
    }
    func apply(_ value: [String: Any], displayID: CGDirectDisplayID) throws {
        guard AXIsProcessTrusted() else { throw InputError.permission }
        guard let type = value["type"] as? String else { throw InputError.invalid }
        let bounds = CGDisplayBounds(displayID)
        var flags: CGEventFlags = []
        let modifiers = value["modifiers"] as? [String] ?? []
        if modifiers.contains("meta") { flags.insert(.maskCommand) }
        if modifiers.contains("ctrl") { flags.insert(.maskControl) }
        if modifiers.contains("alt") { flags.insert(.maskAlternate) }
        if modifiers.contains("shift") { flags.insert(.maskShift) }
        func post(_ event: CGEvent?) { event?.flags = flags; event?.post(tap: .cghidEventTap) }
        switch type {
        case "release": releaseAll()
        case "move", "down", "up", "click":
            guard let x = value["x"] as? Double, let y = value["y"] as? Double, x.isFinite, y.isFinite else { throw InputError.invalid }
            let point = CGPoint(x: bounds.minX + min(1, max(0, x)) * (bounds.width - 1), y: bounds.minY + min(1, max(0, y)) * (bounds.height - 1))
            let button: CGMouseButton = (value["button"] as? Int) == 2 ? .right : .left
            if type == "move" {
                let mouseType: CGEventType = heldButtons.contains(.left) ? .leftMouseDragged : heldButtons.contains(.right) ? .rightMouseDragged : .mouseMoved
                post(CGEvent(mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: point, mouseButton: button))
            } else {
                let down = type == "down" || type == "click"
                let eventType: CGEventType = down ? (button == .left ? .leftMouseDown : .rightMouseDown) : (button == .left ? .leftMouseUp : .rightMouseUp)
                let event = CGEvent(mouseEventSource: source, mouseType: eventType, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: value["count"] as? Int64 ?? 1)
                post(event)
                if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
                if type == "click" {
                    let up = CGEvent(mouseEventSource: source, mouseType: button == .left ? .leftMouseUp : .rightMouseUp, mouseCursorPosition: point, mouseButton: button)
                    up?.setIntegerValueField(.mouseEventClickState, value: value["count"] as? Int64 ?? 1)
                    post(up); heldButtons.remove(button)
                }
            }
        case "scroll":
            let dx = value["dx"] as? Double ?? 0, dy = value["dy"] as? Double ?? 0
            guard dx.isFinite, dy.isFinite else { throw InputError.invalid }
            post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(max(-2000, min(2000, dy))), wheel2: Int32(max(-2000, min(2000, dx))), wheel3: 0))
        case "text":
            guard let text = value["text"] as? String, text.utf16.count <= 4096 else { throw InputError.invalid }
            let units = Array(text.utf16)
            // CGEvent's Unicode payload is limited; never split a surrogate pair.
            var offset = 0
            while offset < units.count {
                var end = min(offset + 20, units.count)
                if end < units.count, (0xD800...0xDBFF).contains(units[end-1]) { end -= 1 }
                let chunk = Array(units[offset..<end])
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    post(event)
                }
                offset = end
            }
        case "key":
            guard let key = value["key"] as? String, let code = Self.keys[key] else { throw InputError.invalid }
            post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true))
            post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false))
        default: throw InputError.invalid
        }
    }
    static let keys: [String: CGKeyCode] = ["Enter":36,"Tab":48,"Space":49,"Backspace":51,"Escape":53,"Delete":117,"ArrowLeft":123,"ArrowRight":124,"ArrowDown":125,"ArrowUp":126,"Home":115,"End":119,"PageUp":116,"PageDown":121,"a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,"F1":122,"F2":120,"F3":99,"F4":118,"F5":96,"F6":97,"F7":98,"F8":100,"F9":101,"F10":109,"F11":103,"F12":111]
}
