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
            // 数据源切换: 蓝牙(CH9140) / 有线串口
            Picker("", selection: $model.listSource) {
                Text("蓝牙").tag(BridgeModel.LinkKind.ble)
                Text("有线").tag(BridgeModel.LinkKind.wired)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)

            if model.listSource == .ble {
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

            // 设备列表: 占据剩余空间, 随窗口自动调整
            deviceListArea
                .frame(minHeight: 100, maxHeight: .infinity)

            } else {
                WiredPortListView()
            }

            Divider()

            // 面板区: 虚拟串口 / 会话日志 —— 固定取内容理想高度, 完整显示
            // 不用 ScrollView(高度足够时滚动条仍会占位/闪现); 窗口变矮时优先压缩上方列表
            VStack(spacing: 12) {
                VirtualPortSectionView()
                LoggingSectionView()
            }
            .padding(10)
            .layoutPriority(1)

            Divider()

            if model.listSource == .ble {
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
    }

    /// 设备列表 + 最近连接(空态给占位提示)
    @ViewBuilder
    private var deviceListArea: some View {
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
    @EnvironmentObject var settings: SettingsStore
    let device: DiscoveredDevice

    /// 历史连接缓存的真实 MAC(扫描时系统不提供 MAC, 仅能显示曾连接过的设备)
    private var cachedMAC: String? {
        settings.recentDevices.first { $0.uuid == device.id }?.macAddress
    }

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
                Text("\(device.rssi) dBm · \(cachedMAC ?? String(device.id.uuidString.prefix(8)))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(cachedMAC != nil
                          ? "设备 MAC(来自历史连接缓存)"
                          : "CoreBluetooth 标识前 8 位(连接成功后自动识别真实 MAC)")
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

    /// 副标题: MAC 优先(CH9140 出厂同名, MAC 是区分不同芯片的唯一稳定标识),
    /// 未识别到 MAC 的旧记录回退显示 UUID 前 8 位
    private var recentSubtitle: String {
        let identity = recent.macAddress
            ?? String(recent.uuid.uuidString.prefix(8)).uppercased()
        let time = Self.relativeFormatter.localizedString(for: recent.lastUsed, relativeTo: Date())
        return "\(identity) · \(time)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(recent.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(recentSubtitle)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(recent.macAddress != nil
                          ? "设备 MAC(连接时自动识别, 用于区分同名芯片)"
                          : "尚未识别到 MAC(该设备连接成功后自动补充)")
            }
            Spacer()
            if isCurrent {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    // 已连接的 CH9140 停止广播、不出现在扫描列表,
                    // 断开入口必须留在最近连接行(否则只能退出 App 来断开)
                    Button("断开") { model.disconnect() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
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
