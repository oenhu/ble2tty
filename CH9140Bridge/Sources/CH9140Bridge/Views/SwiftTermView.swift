//
//  SwiftTermView.swift
//  SwiftTerm 完整终端仿真器的 SwiftUI 封装
//
//  数据流:
//   RX: BridgeModel.onRawRX -> TermFeeder.sink -> terminalView.feed(byteArray:)
//   TX: TerminalViewDelegate.send -> model.sendInteractive (记录日志, 直发芯片)
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

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onSend: (Data) -> Void
        weak var termView: SwiftTerm.TerminalView?
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

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let tv = SwiftTerm.TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // 回滚缓冲
        tv.getTerminal().options.scrollback = 5000

        feeder.sink = { data in   // feeder 已在主线程完成合帧, 直接投喂
            tv.feed(byteArray: Array(data)[...])
        }
        context.coordinator.startFocusWatch(tv)

        // 欢迎横幅
        tv.feed(text: "\u{1B}[36m● CH9140 交互终端 (SwiftTerm) —— 连接设备后直接打字即可\u{1B}[0m\r\n")
        return tv
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.onSend = onSend
    }

    static func dismantleNSView(_ nsView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        coordinator.stopFocusWatch()
    }
}
