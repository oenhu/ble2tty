//
//  ContentView.swift
//  主界面: 设备列表 | 控制面板 | 数据终端 三栏, 底部全局状态栏
//  使用 HSplitView 保证各栏最小宽度始终生效(窗口最小尺寸 = 各栏最小宽度之和)
//

import SwiftUI
import CH9140Core

struct ContentView: View {
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var ble: BLEManager
    @State private var showDeviceList = true

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if showDeviceList {
                    DeviceListView()
                        .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                }
                ControlPanelView()
                    .frame(minWidth: 290, idealWidth: 320, maxWidth: 400)
                TerminalView()
                    .frame(minWidth: 420)
            }
            Divider()
            StatusBarView()
        }
        .navigationTitle("CH9140 Bridge")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation { showDeviceList.toggle() }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("显示 / 隐藏设备列表")
            }
        }
    }
}

/// 底部全局状态栏: 连接 / 虚拟串口 / 日志 / 字节统计
struct StatusBarView: View {
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var port: VirtualSerialPort
    @EnvironmentObject var logger: SessionLogger
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        HStack(spacing: 12) {
            // BLE 连接
            HStack(spacing: 5) {
                Circle().fill(connectionColor).frame(width: 7, height: 7)
                Text(connectionText)
            }
            separator
            // 连接质量: 实时 RSSI + 评级 + 连接时长
            if ble.connectionState == .ready {
                separator
                HStack(spacing: 5) {
                    Image(systemName: "cellularbars")
                        .foregroundStyle(rssiColor)
                    if let rssi = ble.currentRSSI {
                        Text(verbatim: "\(rssi) dBm")
                        Text(rssiQuality)
                            .foregroundStyle(rssiColor)
                    } else {
                        Text("读取中…").foregroundStyle(.secondary)
                    }
                }
                .help("链路信号质量, 每 2 秒刷新")
                if let at = ble.connectedAt {
                    separator
                    HStack(spacing: 5) {
                        Image(systemName: "timer")
                            .foregroundStyle(.secondary)
                        Text(at, style: .timer)
                            .monospacedDigit()
                    }
                    .help("本次连接时长")
                }
            }
            // 虚拟串口
            HStack(spacing: 5) {
                Image(systemName: "cable.connector")
                    .foregroundStyle(port.isOpen ? Color.accentColor : Color.gray)
                if port.isOpen {
                    Text(verbatim: "cu.\(settings.portName)")
                    Text(port.clientConnected ? "已占用" : "空闲")
                        .foregroundStyle(port.clientConnected ? Color.blue : Color.secondary)
                } else {
                    Text("未创建").foregroundStyle(.secondary)
                }
            }
            separator
            // 日志
            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .foregroundStyle(logger.currentFileURL != nil ? Color.green : Color.gray)
                if let url = logger.currentFileURL {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .leading)
                } else {
                    Text(settings.logEnabled ? "待连接" : "日志关")
                        .foregroundStyle(.secondary)
                }
            }
            if ble.chipBufferFull {
                separator
                Label("芯片缓冲满", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text("RX \(Self.formatBytes(model.totalRXBytes))  TX \(Self.formatBytes(model.totalTXBytes))")
                .foregroundStyle(.secondary)
                .help("本次连接芯片收发的全部字节(含内置终端与虚拟串口)")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var separator: some View {
        Divider().frame(height: 12)
    }

    private var connectionColor: Color {
        switch ble.connectionState {
        case .ready: return .green
        case .connecting, .discovering: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var connectionText: String {
        switch ble.connectionState {
        case .ready: return ble.connectedDeviceName
        case .connecting: return "连接中…"
        case .discovering: return "发现服务中…"
        case .failed: return "连接失败"
        case .disconnected: return "未连接"
        }
    }

    private var rssiQuality: String {
        guard let rssi = ble.currentRSSI else { return "" }
        switch rssi {
        case -55...0:      return "极好"
        case -65 ..< -55:  return "良好"
        case -75 ..< -65:  return "一般"
        case -85 ..< -75:  return "较差"
        default:           return "很差"
        }
    }

    private var rssiColor: Color {
        guard let rssi = ble.currentRSSI else { return .secondary }
        switch rssi {
        case -65...0:     return .green
        case -75 ..< -65: return .orange
        default:          return .red
        }
    }

    static func formatBytes(_ n: UInt64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / 1024 / 1024)
    }
}
