//
//  DeviceListView.swift
//  侧边栏: BLE 设备扫描与连接
//

import SwiftUI
import CH9140Core
import CoreBluetooth

struct DeviceListView: View {
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            // 扫描控制
            HStack {
                Button {
                    model.toggleScan()
                } label: {
                    HStack(spacing: 6) {
                        if ble.isScanning {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text(ble.isScanning ? "停止扫描" : "扫描设备")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(ble.isScanning ? .red : .accentColor)
                .disabled(ble.bluetoothState != .poweredOn)
                .help(ble.bluetoothState == .poweredOn
                      ? "扫描广播 CH9140 透传服务(0xFFF0)的设备"
                      : "蓝牙不可用")
            }
            .padding(10)

            Toggle("显示全部 BLE 设备", isOn: $settings.showAllDevices)
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .onChange(of: settings.showAllDevices) { _ in
                    if ble.isScanning {
                        ble.stopScan()
                        ble.startScan(showAll: settings.showAllDevices)
                    }
                }

            Divider()

            // 设备列表 + 最近连接
            if ble.devices.isEmpty && settings.recentDevices.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    if ble.isScanning {
                        ProgressView()
                            .controlSize(.large)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 30))
                            .foregroundStyle(.tertiary)
                    }
                    Text(ble.isScanning ? "正在搜索 CH9140 设备…" : "未发现设备\n点击上方按钮开始扫描")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !ble.isScanning {
                        Text("双击列表项快速连接")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            } else {
                List {
                    if !ble.devices.isEmpty {
                        Section("发现的设备") {
                            ForEach(ble.devices) { device in
                                DeviceRow(device: device)
                            }
                        }
                    }
                    if !settings.recentDevices.isEmpty {
                        Section("最近连接") {
                            ForEach(settings.recentDevices) { recent in
                                RecentDeviceRow(recent: recent)
                            }
                            .onDelete { indexSet in
                                for i in indexSet {
                                    settings.removeRecentDevice(settings.recentDevices[i].uuid)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            // 底部蓝牙状态
            HStack(spacing: 6) {
                Image(systemName: "bluetooth")
                    .foregroundStyle(ble.bluetoothState == .poweredOn ? Color.blue : Color.gray)
                Text(bluetoothStateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if ble.isScanning {
                    Text("\(ble.devices.count) 台")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
        }
    }

    private var bluetoothStateText: String {
        switch ble.bluetoothState {
        case .poweredOn: return "蓝牙就绪"
        case .poweredOff: return "蓝牙已关闭"
        case .unauthorized: return "蓝牙未授权(系统设置中开启)"
        case .unsupported: return "不支持 BLE"
        case .resetting: return "蓝牙重置中"
        case .unknown: return "蓝牙状态未知"
        @unknown default: return "未知"
        }
    }
}

private struct DeviceRow: View {
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var ble: BLEManager
    let device: DiscoveredDevice

    private var isConnected: Bool {
        ble.connectedUUID == device.id && ble.connectionState != .disconnected
    }

    private var isConnecting: Bool {
        ble.connectedUUID == device.id &&
        (ble.connectionState == .connecting || ble.connectionState == .discovering)
    }

    var body: some View {
        HStack(spacing: 8) {
            RSSIBars(rssi: device.rssi)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body.weight(isConnected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(device.rssi) dBm · \(device.id.uuidString.prefix(8))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isConnecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Button("取消") { model.disconnect() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("取消正在进行的连接")
                }
            } else if isConnected {
                Button("断开") { model.disconnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("连接") { model.connect(device) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(ble.connectionState == .connecting)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !isConnected && !isConnecting { model.connect(device) }
        }
    }
}

/// RSSI 信号条
struct RSSIBars: View {
    let rssi: Int

    private var level: Int {
        switch rssi {
        case ..<(-85): return 1
        case ..<(-70): return 2
        case ..<(-55): return 3
        default:       return 4
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + i * 3))
            }
        }
        .accessibilityLabel("信号强度 \(level)/4")
    }
}


/// 最近连接的设备行: 点击直连, 右滑删除
private struct RecentDeviceRow: View {
    @EnvironmentObject var model: BridgeModel
    @EnvironmentObject var ble: BLEManager
    let recent: RecentDevice

    private var isCurrent: Bool {
        ble.connectedUUID == recent.uuid && ble.connectionState != .disconnected
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(recent.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(Self.relativeFormatter.localizedString(for: recent.lastUsed, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("连接") { model.connectRecent(recent) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(ble.connectionState == .connecting)
                    .help("无需扫描, 直接连接(蓝牙直连)")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !isCurrent { model.connectRecent(recent) }
        }
    }
}
