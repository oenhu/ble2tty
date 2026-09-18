//
//  PanelSections.swift
//  左侧面板区块(原中间栏控制面板拆分): MODEM 与流控 / 虚拟串口 / 会话日志
//  串口参数横排到了终端工具条(见 TerminalView.serialStrip)
//

import SwiftUI
import CH9140Core
import AppKit

// MARK: - MODEM 与流控

struct ModemSectionView: View {
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                // 指示灯 + 应用按钮 一行
                HStack(spacing: 14) {
                    modemLED("CTS", on: ble.modemStatus.cts, tip: "清除发送(芯片输入)")
                    modemLED("DSR", on: ble.modemStatus.dsr, tip: "数据设备就绪(芯片输入)")
                    modemLED("RI",  on: ble.modemStatus.ri,  tip: "振铃指示(芯片输入)")
                    modemLED("DCD", on: ble.modemStatus.dcd, tip: "载波检测(芯片输入)")
                    Spacer()
                    if ble.chipBufferFull {
                        Text("缓冲满")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("芯片串口发送缓冲区已满(0x88 上报), 发送已暂停")
                    }
                    Button("应用") { model.applyModemLines() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!ble.isReady)
                        .help("通过 0xFFF3 配置通道下发流控与 MODEM 输出(指令 0x07)")
                }
                // 流控/DTR/RTS 一行
                HStack(spacing: 12) {
                    Toggle("硬件流控", isOn: $model.editFlowControl)
                        .toggleStyle(.switch)
                        .help("CTS/RTS 硬件流控(指令 0x07)")
                    Spacer()
                    Toggle("DTR", isOn: bitBinding(\.editDTR))
                        .toggleStyle(.switch)
                        .help("DTR 输出电平")
                    Toggle("RTS", isOn: bitBinding(\.editRTS))
                        .toggleStyle(.switch)
                        .help("RTS 输出电平")
                }
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        } label: {
            Label("MODEM 与流控", systemImage: "antenna.radiowaves.left.and.right.circle")
        }
    }

    private func bitBinding(_ keyPath: ReferenceWritableKeyPath<BridgeModel, UInt8>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] == 1 },
                set: { model[keyPath: keyPath] = $0 ? 1 : 0 })
    }

    private func modemLED(_ name: String, on: Bool, tip: String) -> some View {
        VStack(spacing: 3) {
            Circle()
                .fill(on ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 11, height: 11)
                .shadow(color: on ? .green.opacity(0.6) : .clear, radius: 3)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .help(tip)
    }
}

// MARK: - 虚拟串口

struct VirtualPortSectionView: View {
    @EnvironmentObject var port: VirtualSerialPort
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if port.isOpen {
                    let displayPath = port.compatLinkPath.isEmpty ? port.linkPath : port.compatLinkPath
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text(verbatim: displayPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help("兼容路径: \(port.compatLinkPath)\n完整路径: \(port.linkPath)")
                        Spacer(minLength: 4)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(displayPath, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("拷贝虚拟串口路径(无空格, minicom/screen 均可用)")
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: port.linkPath)])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("在 Finder 中显示")
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(port.clientConnected ? Color.blue : Color.gray.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(port.clientConnected ? "串口工具已占用" : "等待串口工具打开")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if port.droppedBytes > 0 {
                            Text("· 空闲丢弃 \(port.droppedBytes)B")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help("无客户端打开期间收到的数据已被丢弃")
                        }
                        Spacer()
                        Button("关闭串口") { port.close() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } else {
                    Text("虚拟串口未创建")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("创建虚拟串口") {
                        _ = try? port.open(name: settings.portName)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("虚拟串口", systemImage: "cable.connector")
        }
    }
}

// MARK: - 会话日志

struct LoggingSectionView: View {
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var logger: SessionLogger
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var templateInsertion = TextFieldInsertion()

    /// 模板变量按钮定义
    static let templateVariables: [(token: String, tip: String)] = [
        ("{device}",   "设备名, 如 CH9140BLE2U"),
        ("{name}",     "自定义标识(下方输入框的内容), 如 机房A-SW01"),
        ("{date}",     "日期, 如 2026-09-05"),
        ("{time}",     "时间, 如 184430"),
        ("{datetime}", "日期时间, 如 20260905_184430"),
        ("{seq}",      "当日切割序号, 如 1、2(切割时自动递增)"),
    ]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // 状态行
                HStack(spacing: 6) {
                    Image(systemName: settings.logEnabled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(settings.logEnabled ? Color.green : Color.gray)
                    Text(settings.logEnabled ? "默认保存日志已开启" : "默认保存日志已关闭")
                        .font(.caption)
                    Spacer()
                    Text(StatusBarView.formatBytes(logger.bytesWritten))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                // 当前文件
                if let url = logger.currentFileURL {
                    Text(verbatim: url.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(url.path)
                } else {
                    Text(logIdleHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // raw 原始日志文件(全量原始字节, 不受 clean 选项影响)
                if let raw = logger.rawFileURL {
                    Text(verbatim: raw.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help("raw 原始日志(取证用)\n" + raw.path)
                }
                // clean 过滤摘要
                if logger.currentFileURL != nil {
                    Text(cleanSummary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider().padding(.vertical, 2)

                // 自定义标识
                HStack(spacing: 6) {
                    Text("标识")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    TextField("自定义标识(可选), 如: 机房A-SW01", text: $settings.logCustomName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .help("对应模板变量 {name}; 下次切割/连接时生效")
                }
                // 文件名模板
                HStack(spacing: 6) {
                    Text("模板")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .trailing)
                    InsertableTextField(text: $settings.logNameTemplate,
                                        placeholder: SessionLogger.defaultTemplate,
                                        insertion: templateInsertion)
                        .frame(height: 22)
                    Button("默认") { settings.logNameTemplate = SessionLogger.defaultTemplate }
                        .controlSize(.small)
                        .help("恢复默认模板 \(SessionLogger.defaultTemplate)")
                }
                // 变量按钮(3 列网格): 点击插入到模板光标处
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                          spacing: 6) {
                    ForEach(Self.templateVariables, id: \.token) { v in
                        Button(v.token) { templateInsertion.insert(v.token) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .focusable(false)   // 不抢夺模板输入框焦点, 保证插入到光标处
                            .help(v.tip)
                    }
                }
                .disabled(!settings.logEnabled)

                // 操作按钮
                HStack {
                    Button("截断并新建") { model.rotateLog() }
                        .disabled(logger.currentFileURL == nil)
                        .help("收尾当前日志文件, 立即开启一个新文件")
                    Button("打开目录") {
                        let dir = settings.logDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    if logger.currentFileURL != nil {
                        Button("结束日志") { model.stopLog() }
                            .help("收尾并关闭当前日志文件; 连接保持, 数据停止写盘")
                    } else {
                        Button("开始日志") { model.startLog() }
                            .disabled(!settings.logEnabled || !ble.isReady)
                            .help(startLogHelp)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        } label: {
            Label("会话日志", systemImage: "doc.text")
        }
    }

    /// clean 日志当前过滤摘要(显示在日志文件路径下方)
    private var cleanSummary: String {
        var parts: [String] = []
        if !settings.logSentData { parts.append("不含TX") }
        if !settings.logTimestamps { parts.append("无时间戳") }
        if settings.logCleanStripANSI { parts.append("去ANSI") }
        switch settings.logCleanCRMode {
        case .keep: break
        case .strip: parts.append("去CR")
        case .apply: parts.append("应用CR")
        }
        switch settings.logCleanBSMode {
        case .keep: break
        case .strip: parts.append("删退格")
        case .apply: parts.append("抹退格")
        }
        if settings.logGBKCompatible { parts.append("GBK转码") }
        return parts.isEmpty ? "clean: 全部原样" : "clean: " + parts.joined(separator: " · ")
    }

    /// 无日志文件时的提示文案(区分未开启/未连接/已手动结束)
    private var logIdleHint: String {
        if !settings.logEnabled { return "可在 设置 > 日志 中开启" }
        if !ble.isReady { return "连接设备后自动创建日志文件" }
        return "日志已结束, 点击下方「开始日志」恢复记录"
    }

    /// 「开始日志」按钮的提示(含不可用原因)
    private var startLogHelp: String {
        if !settings.logEnabled { return "需先在 设置 > 日志 中开启「默认保存日志」" }
        if !ble.isReady { return "连接设备后才能开始记录" }
        return "按当前模板开启新日志文件, 恢复记录(重名自动避让)"
    }
}
