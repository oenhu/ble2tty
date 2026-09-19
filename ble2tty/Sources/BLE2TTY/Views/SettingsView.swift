//
//  SettingsView.swift
//  原生设置面板(⌘,), 含默认日志保存等设置
//

import SwiftUI
import CH9140Core
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralSettingsTab().environmentObject(settings)
                .tabItem { Label("通用", systemImage: "gear") }
            LoggingSettingsTab().environmentObject(settings)
                .tabItem { Label("日志", systemImage: "doc.text") }
            PortSettingsTab().environmentObject(settings)
                .tabItem { Label("虚拟串口", systemImage: "cable.connector") }
        }
        .frame(width: 540, height: 380)
    }
}

// MARK: - 通用

private struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var ble: BLEManager
    /// 终端毛玻璃(SwiftTermView 读同一键, 无需经 SettingsStore 中转)
    @AppStorage("CH9140Bridge.terminalFrostedGlass") private var terminalFrostedGlass = false

    static let baudRates: [UInt32] = [
        300, 600, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 38400,
        57600, 76800, 115200, 128000, 230400, 250000, 256000,
        460800, 500000, 512000, 921600, 1000000
    ]
    static let parityNames = ["无", "奇校验", "偶校验", "标志位", "空白位"]

    var body: some View {
        Form {
            Section {
                Picker("默认波特率", selection: $settings.defaultBaudRate) {
                    ForEach(Self.baudRates, id: \.self) { Text(verbatim: "\($0) bps").tag($0) }
                }
                Picker("默认数据位", selection: $settings.defaultDataBits) {
                    ForEach([UInt8(5), 6, 7, 8], id: \.self) { Text(verbatim: "\($0) 位").tag($0) }
                }
                Picker("默认停止位", selection: $settings.defaultStopBits) {
                    ForEach([UInt8(1), 2], id: \.self) { Text(verbatim: "\($0) 位").tag($0) }
                }
                Picker("默认校验", selection: $settings.defaultParity) {
                    ForEach(0..<Self.parityNames.count, id: \.self) {
                        Text(Self.parityNames[$0]).tag(UInt8($0))
                    }
                }
                Toggle("默认开启硬件流控(CTS/RTS)", isOn: $settings.defaultFlowControl)
            } header: {
                Text("默认串口参数").font(.headline)
            }

            Section {
                Toggle("连接成功后自动下发默认参数到芯片", isOn: $settings.applyDefaultsOnConnect)
                Toggle("虚拟串口波特率变化时自动同步给芯片", isOn: $settings.followVirtualPortBaud)
                Toggle("意外断开后自动重连", isOn: $settings.autoReconnect)
            } header: {
                Text("连接行为").font(.headline)
            }

            Section {
                // 状态指示灯 + 应用按钮
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
                        .controlSize(.small)
                        .disabled(!model.isLinkReady)
                        .help("通过 0xFFF3 配置通道下发流控与 MODEM 输出(指令 0x07)")
                }
                Toggle("硬件流控(CTS/RTS)", isOn: $model.editFlowControl)
                    .help("CTS/RTS 硬件流控(指令 0x07)")
                Toggle("DTR 输出电平", isOn: bitBinding(\.editDTR))
                Toggle("RTS 输出电平", isOn: bitBinding(\.editRTS))
            } header: {
                Text("MODEM 与流控").font(.headline)
            }

            Section {
                Toggle("终端毛玻璃效果", isOn: $terminalFrostedGlass)
                Text("「终端」页背景变为半透明模糊并压暗以保证可读性; 仅影响终端仿真模式, 监视模式不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("终端").font(.headline)
            }

            Text("提示: 华为/H3C/思科交换机 Console 通常为 9600 8N1 无校验无流控。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - MODEM 辅助

private extension GeneralSettingsTab {
    func bitBinding(_ keyPath: ReferenceWritableKeyPath<BridgeModel, UInt8>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] == 1 },
                set: { model[keyPath: keyPath] = $0 ? 1 : 0 })
    }

    func modemLED(_ name: String, on: Bool, tip: String) -> some View {
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

// MARK: - 日志

private struct LoggingSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("默认保存日志(连接后自动记录会话)", isOn: $settings.logEnabled)
                Picker("日志格式", selection: $settings.logFormat) {
                    ForEach(LogFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!settings.logEnabled)
                Picker("按日期存储", selection: $settings.logStorageMode) {
                    ForEach(LogStorageMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!settings.logEnabled)
                .help("按会话: 每次连接一个文件\n按日期分目录: 每天一个子目录\n按日期合并: 同名文件持续追加(搭配含 {date} 的模板即每天一个文件)")
                Toggle("启用「截断日志」快捷键 ⌘T", isOn: $settings.logRotateShortcutEnabled)
                    .disabled(!settings.logEnabled)
                Text("文件名模板与自定义标识在主界面「会话日志」卡片中编辑。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("会话日志").font(.headline)
            }

            Section {
                Toggle("双份保存 raw 原始日志", isOn: $settings.logRawEnabled)
                    .disabled(!settings.logEnabled)
                Text("raw 永远全量保留线上原始字节(CR/退格/ANSI 转义/GBK 编码均不处理), 带时间戳与方向, 保存在日志目录 raw/ 子目录(<名字>.raw.log), 用于排查取证; 不受 clean 选项影响。会话进行中切换立即生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("raw 原始日志").font(.headline)
            }

            Section {
                Toggle("日志中包含发送到设备的数据(TX)", isOn: $settings.logSentData)
                    .disabled(!settings.logEnabled)
                Toggle("每行附加时间戳与方向", isOn: $settings.logTimestamps)
                    .disabled(!settings.logEnabled)
                    .help("关闭后输出行不带前缀、方向切换不强制断行, 得到连续文本便于整段复制(建议搭配关闭 TX)")
                Toggle("去除 ANSI 转义序列", isOn: $settings.logCleanStripANSI)
                    .disabled(!settings.logEnabled)
                    .help("剥离 ESC[A 之类的光标/颜色控制序列(方向键翻历史命令产生)")
                Picker("CR 回车符", selection: $settings.logCleanCRMode) {
                    ForEach(LogCRHandling.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!settings.logEnabled)
                .help("原样保留: 编辑器里可见 ^M\n去除: CRLF 只留 LF\n应用行内重绘: 进度条类覆盖输出只保留最终内容")
                Picker("退格回显", selection: $settings.logCleanBSMode) {
                    ForEach(LogBSHandling.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(!settings.logEnabled)
                .help("原样保留: 保留 0x08/0x7F 字节\n删除控制字节: 仅去掉控制字符\n应用抹除: 按终端语义真正抹掉前一字符, 所见即所得")
                Toggle("中文兼容(GBK 设备输出自动转 UTF-8)", isOn: $settings.logGBKCompatible)
                    .disabled(!settings.logEnabled)
                    .help("华为/H3C 等国产设备控制台用 GBK 编码输出中文, 原样保存在 UTF-8 编辑器中是乱码; 开启后自动转码")
            } header: {
                Text("clean 日志选项(仅纯文本格式生效)").font(.headline)
            }

            Section {
                HStack {
                    TextField("日志保存目录", text: $settings.logDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { pickDirectory() }
                    Button("默认") {
                        settings.logDirectoryPath = SettingsStore.defaultLogDirectory
                    }
                    .help("恢复为默认目录 ~/Documents/CH9140Logs")
                    Button("打开") {
                        let dir = settings.logDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
                Text("示例: \(examplePath)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("保存位置").font(.headline)
            }

            Text("连接设备后自动创建日志文件, 断开时自动收尾; 按日期模式下跨午夜自动切换到新文件。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var examplePath: String {
        SessionLogger.examplePath(directory: settings.logDirectoryPath,
                                  deviceName: "CH9140BLE2U",
                                  customName: settings.logCustomName,
                                  template: settings.logNameTemplate,
                                  mode: settings.logStorageMode)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择日志目录"
        panel.directoryURL = settings.logDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.logDirectoryPath = url.path
        }
    }
}

// MARK: - 虚拟串口

private struct PortSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                TextField("串口名称", text: $settings.portName)
                    .textFieldStyle(.roundedBorder)
                Text("虚拟串口会创建两个符号链接:\n• ~/Library/Application Support/BLE2TTY/cu.<名称>\n• ~/.ch9140/cu.<名称> (无空格, 兼容 minicom 等按空格分词的工具)\n在 screen / minicom / CoolTerm / PuTTY 中选择任一路径即可使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("App 启动时自动创建虚拟串口", isOn: $settings.autoCreatePort)
            } header: {
                Text("虚拟串口").font(.headline)
            }

            Section {
                Text("""
                工作原理: 使用 macOS 伪终端(PTY)创建虚拟串口对, 无需内核扩展。\
                串口工具设置的波特率/数据位/停止位/校验会被自动检测并通过 0xFFF3 \
                配置通道下发给 CH9140 芯片(需在“通用”中开启自动同步)。
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("说明").font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
