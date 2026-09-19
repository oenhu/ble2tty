//
//  WiredPortListView.swift
//  有线串口页: 端口枚举 / 刷新 / 连接
//

import SwiftUI
import CH9140Core

struct WiredPortListView: View {
    @EnvironmentObject var model: BridgeModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    model.refreshWiredPorts()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新列表")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("重新枚举系统中的串口设备")
            }
            .padding(10)

            Divider()

            Group {
                if model.wiredPorts.isEmpty {
                    emptyState
                } else {
                    List(model.wiredPorts) { port in
                        WiredPortRow(port: port)
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: .infinity)
        }
        .onAppear { model.refreshWiredPorts() }
    }

    /// 空态: 引导插入设备与安装驱动(CH340/CP210x 需厂商驱动, FTDI/CDC-ACM 内置)
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "cable.connector")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("未发现串口设备\n插入 USB 转串口适配器后点「刷新列表」")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("FTDI 与 CDC-ACM 设备 macOS 内置支持;\nCH340/CH341 需安装 WCH 驱动, CP210x 需 SiLabs 驱动")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WiredPortRow: View {
    @EnvironmentObject var model: BridgeModel
    let port: SerialPortInfo

    private var isCurrent: Bool {
        model.activeLinkKind == .wired
            && model.wired.connectedPortPath == port.path
            && model.wired.connectionState != .disconnected
    }
    private var isConnecting: Bool {
        isCurrent && model.wired.connectionState == .connecting
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "memorystick")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(port.name)
                    .font(.callout)
                    .lineLimit(1)
                Text(port.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(port.path)
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
                }
            } else if isCurrent {
                Button("断开") { model.disconnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("连接") { model.connectWired(port) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.activeConnectionState == .connecting)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !isCurrent && !isConnecting { model.connectWired(port) }
        }
    }
}
