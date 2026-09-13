//
//  TerminalView.swift
//  数据终端: 监视收发数据, 可直接向芯片发送(便于交换机 Console 联调)
//  显示层使用 NSTextView: 支持跨行选择复制, 大数据量流畅
//

import SwiftUI
import AppKit
import CH9140Core

private enum LineEnding: String, CaseIterable, Identifiable {
    case none = "无"
    case cr   = "CR"
    case lf   = "LF"
    case crlf = "CR+LF"
    var id: String { rawValue }

    var bytes: Data {
        switch self {
        case .none: return Data()
        case .cr:   return Data([0x0D])
        case .lf:   return Data([0x0A])
        case .crlf: return Data([0x0D, 0x0A])
        }
    }
}

// MARK: - NSTextView 终端显示

struct TerminalTextView: NSViewRepresentable {
    /// 已按"仅数据"开关选好的可见行数组(视图内不再 filter)
    let visibleLines: [TerminalLine]
    let hex: Bool
    let showTimestamp: Bool
    let hideSystem: Bool
    let autoScroll: Bool
    let generation: Int

    final class Coordinator {
        var lastSignature = ""
        var renderedCount = 0
        /// 已渲染行尾内容及其长度(用于"活"行尾的增量改写)
        var tailString = ""
        var tailLength = 0
        /// 已渲染的首行行 ID: 模型端批量截断后用于定位头部增量删除的范围
        var firstRenderedID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.backgroundColor = .textBackgroundColor
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let signature = "\(hex)|\(showTimestamp)|\(hideSystem)|\(generation)"
        let coord = context.coordinator

        if signature != coord.lastSignature {
            // 显示模式变化 / 清屏: 整体重绘(批量截断不走这里)
            fullRedraw(storage: storage, coord: coord, signature: signature)
        } else {
            // 头部增量删除: 模型批量截断后, 已渲染的首行不在数组开头
            if let firstID = coord.firstRenderedID, visibleLines.first?.id != firstID {
                guard let idx = visibleLines.firstIndex(where: { $0.id == firstID }) else {
                    // 已渲染内容整体失效(兜底): 整屏重绘
                    fullRedraw(storage: storage, coord: coord, signature: signature)
                    if autoScroll { tv.scrollToEndOfDocument(nil) }
                    return
                }
                var deleteLength = 0
                for line in visibleLines[0..<idx] { deleteLength += render(line).length }
                // 防御: 已渲染内容与模型失配(删除长度超出已渲染总量)时整屏重绘兜底,
                // 避免 NSRange 越界抛 ObjC 异常崩溃
                if deleteLength > storage.length {
                    fullRedraw(storage: storage, coord: coord, signature: signature)
                    if autoScroll { tv.scrollToEndOfDocument(nil) }
                    return
                }
                storage.beginEditing()
                storage.deleteCharacters(in: NSRange(location: 0, length: deleteLength))
                storage.endEditing()
                coord.renderedCount -= idx
                coord.firstRenderedID = visibleLines.first?.id
            }

            if visibleLines.count > coord.renderedCount {
                // 增量追加新行
                let more = NSMutableAttributedString()
                for line in visibleLines[coord.renderedCount...] { more.append(render(line)) }
                storage.append(more)
                coord.renderedCount = visibleLines.count
                coord.tailString = visibleLines.last.map { render($0).string } ?? ""
                coord.tailLength = visibleLines.last.map { render($0).length } ?? 0
            } else if visibleLines.count < coord.renderedCount {
                // 行数变少但首行 ID 未变(理论上不会走到): 安全兜底
                fullRedraw(storage: storage, coord: coord, signature: signature)
            } else if let last = visibleLines.last {
                // 行数未变: 校对"活"行尾, 内容不同则原地改写最后一行(增量, 不整屏重绘)
                let rendered = render(last)
                if rendered.string != coord.tailString {
                    // 防御: 尾部长度超出已渲染总量(失配)时整屏重绘, 避免 NSRange 越界崩溃
                    if coord.tailLength > storage.length {
                        fullRedraw(storage: storage, coord: coord, signature: signature)
                    } else {
                        storage.beginEditing()
                        storage.deleteCharacters(in: NSRange(location: storage.length - coord.tailLength,
                                                             length: coord.tailLength))
                        storage.append(rendered)
                        storage.endEditing()
                        coord.tailString = rendered.string
                        coord.tailLength = rendered.length
                    }
                }
            }
        }

        if autoScroll { tv.scrollToEndOfDocument(nil) }
    }

    /// 整体重绘(显示模式切换 / 清屏 / 兜底): 重建全部可见行
    private func fullRedraw(storage: NSTextStorage, coord: Coordinator, signature: String) {
        let full = NSMutableAttributedString()
        for line in visibleLines { full.append(render(line)) }
        storage.setAttributedString(full)
        coord.lastSignature = signature
        coord.renderedCount = visibleLines.count
        coord.tailString = visibleLines.last.map { render($0).string } ?? ""
        coord.tailLength = visibleLines.last.map { render($0).length } ?? 0
        coord.firstRenderedID = visibleLines.first?.id
    }

    // MARK: 渲染

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func render(_ line: TerminalLine) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let small = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        if showTimestamp {
            result.append(NSAttributedString(
                string: Self.timeFormatter.string(from: line.time) + " ",
                attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor]))
        }

        let body: String
        let color: NSColor
        switch line.kind {
        case .system:
            body = "● " + line.text
            color = .systemOrange
        case .rx:
            body = hex ? HexUtil.hexString(line.data) : HexUtil.printableASCII(line.data)
            color = .labelColor
        case .tx:
            // 行尾换行符是发送时的行尾附加(传输修饰), 文本/HEX 两种模式一致剥离
            var d = line.data
            while d.last == 0x0D || d.last == 0x0A { d = d.dropLast() }
            body = "→ " + (hex ? HexUtil.hexString(d) : HexUtil.printableASCII(d))
            color = .systemBlue
        }
        result.append(NSAttributedString(string: body + "\n",
                                         attributes: [.font: font, .foregroundColor: color]))
        return result
    }
}

// MARK: - 终端视图

private enum TerminalMode: String, CaseIterable {
    case monitor = "监视"
    case terminal = "终端"
}

struct TerminalView: View {
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var termFeeder = TermFeeder()

    @State private var mode: TerminalMode = .monitor
    @State private var input = ""
    @State private var inputHex = false
    @State private var lineEnding: LineEnding = .cr   // 串口 Console 惯例: 回车 = CR
    @State private var autoScroll = true
    @State private var showTimestamps = true
    @State private var hideSystem = false
    @State private var interactive = false   // 键盘直连(交互)模式
    @State private var history: [String] = []

    private var visibleCount: Int {
        hideSystem ? model.dataLines.count : model.lines.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // 工具条
            HStack(spacing: 12) {
                Picker("", selection: $mode) {
                    ForEach(TerminalMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)

                if mode == .monitor {
                    Toggle("HEX", isOn: $model.displayHex).toggleStyle(.checkbox)
                        .help("以十六进制显示数据")
                    Toggle("时间戳", isOn: $showTimestamps).toggleStyle(.checkbox)
                    Toggle("滚动", isOn: $autoScroll).toggleStyle(.checkbox)
                        .help("有新数据时自动滚动到底部")
                    Toggle("仅数据", isOn: $hideSystem).toggleStyle(.checkbox)
                        .help("只显示串口数据, 隐藏连接/配置等系统消息")
                    Spacer()
                    Text("\(visibleCount) 行")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Button { model.rotateLog() } label: {
                        Image(systemName: "scissors")
                    }
                    .fixedSize()
                    .disabled(model.logger.currentFileURL == nil)
                    .help("截断当前日志并新建文件")
                    Button("清屏") { model.clearTerminal() }
                        .fixedSize()
                        .help("清空终端显示(不影响日志文件)")
                } else {
                    Toggle(isOn: $settings.terminalForceEnglish) {
                        Image(systemName: "keyboard")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("终端输入区聚焦时强制英文输入法, 移开焦点自动恢复")
                    Spacer()
                    Button("清屏") {
                        termFeeder.feed(Data([0x1B, 0x63]))   // RIS: 终端复位清屏
                    }
                    .fixedSize()
                    .help("复位并清空终端显示(不影响日志文件)")
                }
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // 双模共存: 两个终端视图常驻保活, 切模式不丢历史
            ZStack {
                TerminalTextView(visibleLines: hideSystem ? model.dataLines : model.lines,
                                 hex: model.displayHex,
                                 showTimestamp: showTimestamps,
                                 hideSystem: hideSystem,
                                 autoScroll: autoScroll,
                                 generation: model.terminalGeneration)
                    .opacity(mode == .monitor ? 1 : 0)
                    .allowsHitTesting(mode == .monitor)

                SwiftTermView(feeder: termFeeder) { data in
                    model.sendInteractive(data)
                }
                .opacity(mode == .terminal ? 1 : 0)
                .allowsHitTesting(mode == .terminal)
            }
            .onAppear {
                // RX 旁路喂给终端仿真器(日志与虚拟串口通路不变)
                model.onRawRX = { data in termFeeder.feed(data) }
                InputSourceGuard.shared.setEnabled(settings.terminalForceEnglish)
            }
            .onChange(of: settings.terminalForceEnglish) { on in
                InputSourceGuard.shared.setEnabled(on)
            }
            .onChange(of: ble.connectionState) { state in
                switch state {
                case .ready:
                    termFeeder.feed(Data("\u{1B}[32m● 已连接 \(ble.connectedDeviceName), 通道就绪\u{1B}[0m\r\n".utf8))
                case .disconnected:
                    termFeeder.feed(Data("\u{1B}[31m● 连接已断开\u{1B}[0m\r\n".utf8))
                default:
                    break
                }
            }

            // 发送区仅监视模式显示(终端模式键盘输入由 SwiftTerm 直接接管)
            if mode == .monitor {
                Divider()
                HStack(spacing: 8) {
                    Toggle("交互", isOn: $interactive)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .controlSize(.small)
                        .help("键盘直连模式: 按键逐字节直发, 支持 Tab 补全/方向键/Ctrl 组合键")
                    if interactive {
                        ConsoleKeyView { data in model.sendInteractive(data) }
                            .frame(height: 28)
                            .opacity(ble.isReady ? 1 : 0.5)
                    } else {
                        sendRowContent
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    /// 整行发送区内容(非交互模式)
    private var sendRowContent: some View {
            HStack(spacing: 8) {
                Toggle("HEX", isOn: $inputHex)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .controlSize(.small)
                TextField(inputHex ? "十六进制, 如: 0D 0A" : "输入内容, 回车发送",
                          text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 60)
                    .onSubmit(send)
                if !history.isEmpty {
                    Menu {
                        ForEach(history.reversed(), id: \.self) { item in
                            Button(item) { input = item }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 26)
                    .help("最近发送")
                }
                Picker("", selection: $lineEnding) {
                    ForEach(LineEnding.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .frame(width: 84)
                .disabled(inputHex)
                .help("发送时附加的行尾(串口 Console 通常为 CR)")
                Button("发送") { send() }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!ble.isReady)
                    .help(ble.isReady ? "发送到 CH9140 (⌘⏎)" : "连接设备后才能发送")
            }
    }

    private func send() {
        guard !input.isEmpty else { return }
        var data: Data
        if inputHex {
            guard let d = HexUtil.data(fromHexString: input) else {
                NSSound.beep()
                return
            }
            data = d
        } else {
            data = Data(input.utf8)
            data.append(lineEnding.bytes)
        }
        model.sendFromTerminal(data)
        history.removeAll { $0 == input }
        history.append(input)
        if history.count > 20 { history.removeFirst() }
        input = ""
    }
}
