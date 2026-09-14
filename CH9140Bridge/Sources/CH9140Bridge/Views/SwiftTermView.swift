//
//  SwiftTermView.swift
//  SwiftTerm 完整终端仿真器的 SwiftUI 封装
//
//  数据流:
//   RX: BridgeModel.onRawRX -> TermFeeder.sink -> terminalView.feed(byteArray:)
//   TX: TerminalViewDelegate.send -> model.sendInteractive (记录日志, 直发芯片)
//
//  毛玻璃效果(设置开关):
//   终端视图背景透明(backgroundOpacity = 0, 文字保持不透明),
//   底层垫 NSVisualEffectView(模糊窗口背后内容) + 压暗层(保证文字可读性)。
//

import SwiftUI
import AppKit
import SwiftTerm

/// RX 字节注入通道(避免 View 反向持有)
/// 合帧投喂: BLE 按 MTU 分包高频到达, 逐包唤醒终端仿真器开销大;
/// 在主线程以 <=30ms 窗口聚合成一批一次解析(交互回显延迟无感知)。
/// feed 必须在主线程调用(当前的调用方: onRawRX 主线程回调 / 清屏按钮)。
final class TermFeeder: ObservableObject {
    /// 在主线程调用
    var sink: ((Data) -> Void)?
    private var pending = Data()
    private var flushScheduled = false

    func feed(_ data: Data) {
        pending.append(data)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let batch = self.pending
            self.pending.removeAll()
            if !batch.isEmpty { self.sink?(batch) }
        }
    }
}

struct SwiftTermView: NSViewRepresentable {
    let feeder: TermFeeder
    var onSend: (Data) -> Void

    /// 终端毛玻璃效果开关(与设置面板共用同一 UserDefaults 键, 前缀与 SettingsStore 一致)
    @AppStorage("CH9140Bridge.terminalFrostedGlass") private var frostedGlass = false

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onSend: (Data) -> Void
        weak var termView: SwiftTerm.TerminalView?
        weak var effectView: NSVisualEffectView?
        weak var tintView: NSView?
        private var frostedApplied: Bool?
        private var clickMonitor: Any?
        private var resignKeyObserver: NSObjectProtocol?

        init(onSend: @escaping (Data) -> Void) { self.onSend = onSend }

        // 用户键盘输入 -> 发给芯片
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            onSend(Data(data))
        }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

        /// 切换毛玻璃: 开启时终端背景透明, 露出底层的模糊与压暗; 关闭时恢复不透明。
        /// 仅在状态变化时真正写属性(backgroundOpacity 赋值会触发终端全量重绘)。
        func setFrosted(_ on: Bool) {
            guard frostedApplied != on, let tv = termView else { return }
            frostedApplied = on
            effectView?.isHidden = !on
            tintView?.isHidden = !on
            tv.backgroundOpacity = on ? 0 : 1
        }

        /// 输入法守卫: 点击终端区域 -> 切英文; 点击落在他处且焦点在终端 -> 恢复; 窗口失焦 -> 恢复
        func startFocusWatch(_ tv: SwiftTerm.TerminalView) {
            termView = tv
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let tv = self.termView, let window = tv.window else { return event }
                let point = tv.convert(event.locationInWindow, from: nil)
                if tv.bounds.contains(point) {
                    InputSourceGuard.shared.enter()
                } else if window.firstResponder === tv {
                    InputSourceGuard.shared.leave()
                }
                return event
            }
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
                    InputSourceGuard.shared.leave()
                }
        }

        func stopFocusWatch() {
            if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
            if let o = resignKeyObserver { NotificationCenter.default.removeObserver(o); resignKeyObserver = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSend: onSend) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        // 毛玻璃底层: 模糊窗口背后的内容(系统合成器采样, 性能开销可忽略)
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active

        // 压暗层: 保证终端文字在明亮桌面背景上的可读性
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        let tv = SwiftTerm.TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // 回滚缓冲
        tv.getTerminal().options.scrollback = 5000

        // 自底向上: 毛玻璃 -> 压暗 -> 终端
        for v in [effect, tint, tv] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        context.coordinator.effectView = effect
        context.coordinator.tintView = tint

        feeder.sink = { data in   // feeder 已在主线程完成合帧, 直接投喂
            tv.feed(byteArray: Array(data)[...])
        }
        context.coordinator.startFocusWatch(tv)
        context.coordinator.setFrosted(frostedGlass)

        // 欢迎横幅
        tv.feed(text: "\u{1B}[36mCH9140 interactive terminal ready. Keystrokes go to the connected device.\u{1B}[0m\r\n")
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.onSend = onSend
        context.coordinator.setFrosted(frostedGlass)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopFocusWatch()
    }
}
