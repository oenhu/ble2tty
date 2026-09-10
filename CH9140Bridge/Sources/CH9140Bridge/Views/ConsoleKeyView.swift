//
//  ConsoleKeyView.swift
//  键盘直连(交互模式)输入区: 按键即时逐字节发送到设备
//
//  按键映射:
//   可打印字符     -> 原样 UTF-8
//   Tab            -> 0x09        (交换机命令补全)
//   Shift+Tab      -> ESC [ Z     (反向补全)
//   Return         -> 0x0D        (CR)
//   Backspace      -> 0x7F        (DEL, 串口设备惯例)
//   ↑↓→←           -> ESC [ A/B/C/D (历史/光标)
//   Home/End       -> ESC [ H/F
//   PgUp/PgDn      -> ESC [ 5~ / 6~
//   Ctrl+A..Z      -> 0x01..0x1A  (Ctrl+C = 0x03 中断)
//

import SwiftUI
import AppKit

struct ConsoleKeyView: NSViewRepresentable {
    var onBytes: (Data) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let v = KeyCaptureNSView()
        v.onBytes = onBytes
        return v
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onBytes = onBytes
    }
}

final class KeyCaptureNSView: NSView {
    var onBytes: ((Data) -> Void)?
    private var focused = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        InputSourceGuard.shared.enter()   // 强制英文输入法
        focused = true
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        InputSourceGuard.shared.leave()   // 恢复原输入法
        focused = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.setFill()
        path.fill()
        (focused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = focused ? 2 : 1
        path.stroke()

        let hint = focused
            ? "键盘直连中: 按键直发设备   (Esc 或点击他处退出焦点)"
            : "点击进入键盘直连 —— Tab 补全 · ↑↓ 历史 · Ctrl+C 中断 · 直接打字发送"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: focused ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        ]
        let size = hint.size(withAttributes: attrs)
        hint.draw(at: NSPoint(x: max(8, (bounds.width - size.width) / 2),
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Ctrl+字母 -> 控制字符
        if event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers,
           let scalar = chars.unicodeScalars.first?.value {
            if (0x61...0x7A).contains(scalar) {   // ctrl+a..z
                send(Data([UInt8(scalar - 0x60)]))
                return
            }
            if (0x41...0x5A).contains(scalar) {   // ctrl+A..Z
                send(Data([UInt8(scalar - 0x40)]))
                return
            }
        }

        if let special = event.specialKey {
            switch special {
            case .tab:           send(Data([0x09])); return
            case .backTab:       send(Data([0x1B, 0x5B, 0x5A])); return          // ESC [ Z
            case .carriageReturn, .enter: send(Data([0x0D])); return             // CR
            case .delete:        send(Data([0x7F])); return                      // Backspace -> DEL
            case .deleteForward: send(Data([0x1B, 0x5B, 0x33, 0x7E])); return    // ESC [ 3~
            case .upArrow:       send(Data([0x1B, 0x5B, 0x41])); return
            case .downArrow:     send(Data([0x1B, 0x5B, 0x42])); return
            case .rightArrow:    send(Data([0x1B, 0x5B, 0x43])); return
            case .leftArrow:     send(Data([0x1B, 0x5B, 0x44])); return
            case .home:          send(Data([0x1B, 0x5B, 0x48])); return
            case .end:           send(Data([0x1B, 0x5B, 0x46])); return
            case .pageUp:        send(Data([0x1B, 0x5B, 0x35, 0x7E])); return
            case .pageDown:      send(Data([0x1B, 0x5B, 0x36, 0x7E])); return
            default: break
            }
        }

        if let chars = event.characters, !chars.isEmpty {
            send(Data(chars.utf8))   // 含 Esc(0x1B) 与可打印字符
        } else {
            super.keyDown(with: event)
        }
    }

    private func send(_ data: Data) {
        onBytes?(data)
    }
}
