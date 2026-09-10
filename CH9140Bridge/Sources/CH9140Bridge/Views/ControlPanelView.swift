//
//  ControlPanelView.swift
//  控制面板: 串口参数 / MODEM 状态 / 虚拟串口 / 日志
//

import SwiftUI
import CH9140Core
import AppKit

struct ControlPanelView: View {
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var port: VirtualSerialPort
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
        ("{seq}",      "当日切割序号, 如 01、02(切割时自动递增)"),
    ]

    static let baudRates: [UInt32] = [
        300, 600, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 38400,
        57600, 76800, 115200, 128000, 230400, 250000, 256000,
        460800, 500000, 512000, 921600, 1000000
    ]
    static let parityNames = ["无", "奇校验", "偶校验", "标志位", "空白位"]
    static let parityShort = ["无", "奇", "偶", "标志", "空白"]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                serialSection
                modemSection
                virtualPortSection
                loggingSection
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - 串口参数

    private var serialSection: some View {
        GroupBox {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    paramField("波特率") {
                        Picker("", selection: $model.editBaudRate) {
                            ForEach(Self.baudRates, id: \.self) {
                                Text(verbatim: "\($0)").tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                    paramField("数据位") {
                        Picker("", selection: $model.editDataBits) {
                            ForEach([UInt8(5), 6, 7, 8], id: \.self) { Text(verbatim: "\($0)").tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                HStack(spacing: 8) {
                    paramField("停止位") {
                        Picker("", selection: $model.editStopBits) {
                            ForEach([UInt8(1), 2], id: \.self) { Text(verbatim: "\($0)").tag($0) }
                        }
                        .labelsHidden()
                    }
                    paramField("校验位") {
                        Picker("", selection: $model.editParity) {
                            ForEach(0..<Self.parityShort.count, id: \.self) {
                                Text(Self.parityShort[$0]).tag(UInt8($0))
                            }
                        }
                        .labelsHidden()
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        model.applySerialParameters()
                    } label: {
                        Text(model.applyingConfig ? "配置中…" : "写入芯片")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!ble.isReady || model.applyingConfig)
                    .help("通过 0xFFF3 配置通道下发串口参数(指令 0x06), 芯片回包校验")

                    if let active = model.activeSerial {
                        Text(verbatim: "芯片: \(active.baudRate)/\(active.dataBits)/\(active.stopBits)/\(Self.parityShort[Int(min(active.parity, 4))])")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("最近一次成功写入芯片的串口参数")
                    }
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("串口参数", systemImage: "slider.horizontal.3")
        }
    }

    /// 上标题下控件的紧凑字段
    private func paramField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - MODEM

    private var modemSection: some View {
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

    // MARK: - 虚拟串口

    private var virtualPortSection: some View {
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

    // MARK: - 日志

    private var loggingSection: some View {
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
                    Text(settings.logEnabled ? "连接设备后自动创建日志文件" : "可在 设置 > 日志 中开启")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                        Button("结束日志") { logger.closeSession() }
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
}
