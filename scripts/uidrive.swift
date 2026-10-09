#!/usr/bin/env swift
//
// Synthetic pointer + keyboard driver for the L3 UI-smoke layer.
//
//   swift scripts/uidrive.swift warp  <x> <y>          — move the pointer only
//   swift scripts/uidrive.swift click <x> <y>          — warp, then left click
//   swift scripts/uidrive.swift type  "<text>"         — Unicode keystrokes
//   swift scripts/uidrive.swift key   <name> [mods...] — enter|esc|tab|delete|a…z
//   swift scripts/uidrive.swift where                  — print pointer position
//
// Coordinates are CoreGraphics global pixels: origin at the TOP-LEFT of the
// main display, y growing downward. AppKit's `NSScreen.frame` is bottom-left
// origin, so convert with  cgY = mainScreen.frame.maxY - appKitY.
//
// Two different TCC grants are involved, and only one of them is needed for
// hover: `CGWarpMouseCursorPosition` requires NO Accessibility grant, and
// because NotchShell *polls* `NSEvent.mouseLocation` rather than using tracking
// areas, a bare warp is enough to trigger a real hover expand. `CGEventPost`
// (clicks, keystrokes) is Accessibility-gated.
//
// The grant belongs to the *calling* process — this `swift` invocation inherits
// the terminal's. `scripts/preflight.sh` asserts both.

import AppKit
import CoreGraphics

let args = Array(CommandLine.arguments.dropFirst())

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(64)
}

func source() -> CGEventSource? {
    CGEventSource(stateID: .hidSystemState)
}

func warp(_ point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    // Without this the OS keeps applying the pre-warp delta for ~250 ms and the
    // pointer visibly slides back toward where the user left it.
    CGAssociateMouseAndMouseCursorPosition(1)
}

func click(_ point: CGPoint) {
    warp(point)
    usleep(120_000)
    let src = source()
    guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                             mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                           mouseCursorPosition: point, mouseButton: .left)
    else { die("uidrive: could not create mouse events") }
    down.post(tap: .cghidEventTap)
    usleep(30_000)
    up.post(tap: .cghidEventTap)
}

/// Types arbitrary Unicode without a keycode table: post a dummy key event and
/// override its payload with `keyboardSetUnicodeString`. This is layout- and
/// language-independent, which a keycode table is not.
func type(_ text: String) {
    let src = source()
    for character in text {
        let utf16 = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        else { die("uidrive: could not create key events") }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        usleep(8_000)
        up.post(tap: .cghidEventTap)
        usleep(8_000)
    }
}

/// Physical key codes. Named keys need real codes because a Unicode payload
/// carries no "this is Return" semantics.
let keyCodes: [String: CGKeyCode] = [
    "enter": 36, "return": 36, "tab": 48, "space": 49, "delete": 51,
    "esc": 53, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
    "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
]

let modifierFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand,
    "shift": .maskShift, "opt": .maskAlternate, "alt": .maskAlternate,
    "ctrl": .maskControl, "control": .maskControl,
]

func key(_ name: String, modifiers: [String]) {
    guard let code = keyCodes[name.lowercased()] else {
        die("uidrive: unknown key '\(name)' — known: \(keyCodes.keys.sorted().joined(separator: " "))")
    }
    var flags: CGEventFlags = []
    for modifier in modifiers {
        guard let flag = modifierFlags[modifier.lowercased()] else {
            die("uidrive: unknown modifier '\(modifier)'")
        }
        flags.insert(flag)
    }
    let src = source()
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
    else { die("uidrive: could not create key events") }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    usleep(20_000)
    up.post(tap: .cghidEventTap)
}

func point(_ xs: String?, _ ys: String?) -> CGPoint {
    guard let xs, let ys, let x = Double(xs), let y = Double(ys) else {
        die("uidrive: expected <x> <y>")
    }
    return CGPoint(x: x, y: y)
}

/// Momentum-free scroll wheel at the pointer's position. Deltas are in lines
/// for `.line` unit; negative dy scrolls content up (wheel down).
func scroll(dy: Int32, steps: Int, delayMicros: UInt32) {
    let src = source()
    for _ in 0..<steps {
        guard let event = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                                  wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
        else { die("uidrive: could not create scroll event") }
        event.post(tap: .cghidEventTap)
        usleep(delayMicros)
    }
}

switch args.first {
case "warp":
    warp(point(args.count > 1 ? args[1] : nil, args.count > 2 ? args[2] : nil))
case "click":
    click(point(args.count > 1 ? args[1] : nil, args.count > 2 ? args[2] : nil))
case "type":
    guard args.count > 1 else { die("uidrive: expected text") }
    type(args[1])
case "key":
    guard args.count > 1 else { die("uidrive: expected key name") }
    key(args[1], modifiers: Array(args.dropFirst(2)))
case "scroll":
    // scroll <dy-per-step> <steps> [delay-us]  — post at current pointer position
    guard args.count > 2, let dy = Int32(args[1]), let steps = Int(args[2]) else {
        die("uidrive: expected scroll <dy> <steps> [delay-us]")
    }
    let delay = args.count > 3 ? UInt32(args[3]) ?? 16_000 : 16_000
    scroll(dy: dy, steps: steps, delayMicros: delay)
case "where":
    let location = NSEvent.mouseLocation
    let mainHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
        ?? NSScreen.main?.frame.maxY ?? 0
    print("appkit=\(location.x),\(location.y) cg=\(location.x),\(mainHeight - location.y)")
default:
    die("""
        usage: uidrive.swift warp <x> <y> | click <x> <y> | type "<text>" \
        | key <name> [mods...] | where
        """)
}
