//
//  BridgeModel.swift
//  顶层模型: BLE <-> 虚拟串口 <-> 日志 <-> 设置 的粘合层
//

import Foundation
import Combine

public enum TerminalLineKind: Sendable, Equatable {
    case rx       // 芯片 -> 主机
    case tx       // 主机 -> 芯片
    case system   // 运行日志
}

public struct TerminalLine: Identifiable, Sendable {
    public let id = UUID()
    public let time: Date
    public let kind: TerminalLineKind
    public let data: Data
    public let text: String

    public init(kind: TerminalLineKind, data: Data, time: Date = Date()) {
        self.time = time
        self.kind = kind
        self.data = data
        self.text = ""
    }

    public init(system text: String) {
        self.time = Date()
        self.kind = .system
        self.data = Data()
        self.text = text
    }
}

public final class BridgeModel: ObservableObject {

    public let ble = BLEManager()
    public let port = VirtualSerialPort()
    public let logger = SessionLogger()
    public let settings = SettingsStore()

    // MARK: 全链路字节统计(状态栏)
    @Published public private(set) var totalRXBytes: UInt64 = 0
    @Published public private(set) var totalTXBytes: UInt64 = 0
    // 字节统计合帧: BLE 满载时每秒数百个包, 逐包刷新状态栏开销大;
    // 任意线程先累加, 再以 <=10Hz 发布
    // (顺带修正了 TX 计数原来在 PTY 轮询线程直接改 @Published 的线程安全问题)
    private let byteCountLock = NSLock()
    private var pendingRXBytes: UInt64 = 0
    private var pendingTXBytes: UInt64 = 0
    private var byteFlushScheduled = false

    /// 任意线程安全: 累计收/发字节, 以 <=10Hz 合帧发布
    private func addBytes(rx: UInt64 = 0, tx: UInt64 = 0) {
        byteCountLock.lock()
        pendingRXBytes &+= rx
        pendingTXBytes &+= tx
        let needSchedule = !byteFlushScheduled
        if needSchedule { byteFlushScheduled = true }
        byteCountLock.unlock()
        guard needSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.byteCountLock.lock()
            let rx = self.pendingRXBytes
            let tx = self.pendingTXBytes
            self.pendingRXBytes = 0; self.pendingTXBytes = 0
            self.byteFlushScheduled = false
            self.byteCountLock.unlock()
            self.totalRXBytes &+= rx
            self.totalTXBytes &+= tx
        }
    }

    /// 主线程调用: 连接建立时清零统计(含未发布的累计值)
    private func resetByteCounters() {
        byteCountLock.lock()
        pendingRXBytes = 0
        pendingTXBytes = 0
        byteCountLock.unlock()
        totalRXBytes = 0
        totalTXBytes = 0
    }

    // MARK: 终端显示
    @Published public private(set) var lines: [TerminalLine] = []
    /// lines 的"仅数据"镜像(剔除系统消息): 终端"仅数据"模式 O(1) 取用,
    /// 避免每个数据包都对全量数组做一次 filter
    @Published public private(set) var dataLines: [TerminalLine] = []
    /// 清屏时递增, 供终端视图触发整体重绘(批量截断由视图按行 ID 增量处理, 不再递增)
    @Published public private(set) var terminalGeneration = 0
    @Published public var displayHex = false
    private let maxLines = 3000
    /// 超出上限后一次多截掉的行数: 摊销 Array.removeFirst 的 O(n) 搬移,
    /// 并让终端视图的头部增量删除低频发生
    private let trimBatch = 500

    /// 流式数据的行装配: BLE 按 MTU 分包到达, 完整行立即显示; 残行(提示符等)作为"活"行尾
    /// 即时原地更新——逐键回显也能即时呈现, 不会有空闲延迟;
    /// 支持退格编辑/行内重绘/ANSI 过滤
    private var rxAssembler = LineAssembler()
    private var txAssembler = LineAssembler()
    /// 最后一行是否是对应方向的"活"行尾(可被原地替换)
    private var rxLiveTail = false
    private var txLiveTail = false

    /// 收到 Bell (0x07) 时回调(App 层接系统提示音)
    public var onBell: (() -> Void)?
    /// RX 原始字节旁路(主线程): 供终端仿真器等附加消费者使用; 日志与虚拟串口不受影响
    public var onRawRX: ((Data) -> Void)?

    // MARK: 串口参数编辑(控制面板)
    @Published public var editBaudRate: UInt32 = 9600
    @Published public var editDataBits: UInt8 = 8
    @Published public var editStopBits: UInt8 = 1
    @Published public var editParity: UInt8 = 0
    @Published public var editFlowControl = false
    @Published public var editDTR: UInt8 = 0
    @Published public var editRTS: UInt8 = 0
    @Published public private(set) var applyingConfig = false

    /// 最近一次成功应用到芯片的串口参数
    @Published public private(set) var activeSerial: SerialParameters?
    @Published public private(set) var activeModem: ModemLines?

    private var reconnectTarget: (uuid: UUID, name: String)?

    public init() {
        rxAssembler.onBell = { [weak self] in self?.onBell?() }
        txAssembler.onBell = { [weak self] in self?.onBell?() }
        wireBLE()
        wirePort()
        // 面板初始值 = 设置里的默认参数
        editBaudRate = settings.defaultBaudRate
        editDataBits = settings.defaultDataBits
        editStopBits = settings.defaultStopBits
        editParity   = settings.defaultParity
        editFlowControl = settings.defaultFlowControl
    }

    // MARK: - 启动

    public func startup() {
        if settings.autoCreatePort, !port.isOpen {
            _ = try? port.open(name: settings.portName)
        }
    }

    // MARK: - BLE 事件接线

    private func wireBLE() {
        ble.onReceive = { [weak self] data in
            guard let self else { return }
            self.addBytes(rx: UInt64(data.count))
            self.port.writeToPort(data)
            if self.settings.logEnabled {
                self.logger.log(data, direction: .rx,
                                format: self.settings.logFormat,
                                timestamps: self.settings.logTimestamps)
            }
            self.appendStreamChunk(data, kind: .rx)
            self.onRawRX?(data)
        }

        ble.onLog = { [weak self] msg in
            self?.appendSystem(msg)
        }

        ble.onConnectionChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.resetByteCounters()
                if let uuid = self.ble.connectedUUID {
                    let name = self.ble.connectedDeviceName
                    self.settings.addRecentDevice(uuid: uuid, name: name)
                    // CoreBluetooth 不给 MAC: 后台查一次系统蓝牙报告, 回填"最近连接"
                    DeviceMACResolver.connectedDeviceMAC(name: name) { [weak self] mac in
                        guard let self, let mac else { return }
                        self.settings.updateRecentDeviceMAC(uuid, mac: mac)
                        self.appendSystem("设备 MAC: \(mac)")
                    }
                }
                // 连接就绪: 下发默认参数, 开启日志会话
                if self.settings.logEnabled {
                    self.startLog()
                }
                if self.settings.applyDefaultsOnConnect {
                    self.applySerialParameters()
                    self.applyModemLines()
                }
            case .disconnected, .failed:
                self.logger.closeSession()
                if self.settings.autoReconnect, let target = self.reconnectTarget {
                    self.appendSystem("2 秒后尝试自动重连 \(target.name) …")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self else { return }
                        // 排除进行态与已恢复连接即可; .failed 是连接尝试的常见终态,
                        // 也要放行重连(否则超时/失败后重连承诺永不兑现)
                        switch self.ble.connectionState {
                        case .connecting, .discovering, .ready:
                            return
                        case .disconnected, .failed:
                            break
                        }
                        self.ble.connect(uuid: target.uuid, name: target.name)
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - 虚拟串口事件接线

    private func wirePort() {
        port.onDataFromPort = { [weak self] data in
            guard let self else { return }
            self.addBytes(tx: UInt64(data.count))
            self.ble.send(data)
            DispatchQueue.main.async {
                if self.settings.logEnabled, self.settings.logSentData {
                    self.logger.log(data, direction: .tx,
                                    format: self.settings.logFormat,
                                    timestamps: self.settings.logTimestamps)
                }
                self.appendStreamChunk(data, kind: .tx)
            }
        }

        port.onBaudChange = { [weak self] params in
            guard let self else { return }
            DispatchQueue.main.async {
                self.editBaudRate = params.baudRate
                self.editDataBits = params.dataBits
                self.editStopBits = params.stopBits
                self.editParity   = params.parity
                guard self.settings.followVirtualPortBaud, self.ble.isReady else { return }
                self.applySerialParameters()
            }
        }

        port.onLog = { [weak self] msg in
            self?.appendSystem(msg)
        }
    }

    // MARK: - 设备操作

    public func toggleScan() {
        if ble.isScanning { ble.stopScan() }
        else { ble.startScan(showAll: settings.showAllDevices) }
    }

    public func connect(_ device: DiscoveredDevice) {
        reconnectTarget = (device.id, device.name)
        ble.connect(device)
    }

    /// 连接"最近连接"列表里的设备(无需先扫描)
    public func connectRecent(_ device: RecentDevice) {
        reconnectTarget = (device.uuid, device.name)
        ble.connect(uuid: device.uuid, name: device.name)
    }

    public func disconnect() {
        reconnectTarget = nil
        ble.disconnect()
    }

    // MARK: - 参数下发

    public func applySerialParameters() {
        let params = SerialParameters(baudRate: editBaudRate, dataBits: editDataBits,
                                      stopBits: editStopBits, parity: editParity)
        applyingConfig = true
        ble.applySerialParameters(params) { [weak self] ok, info in
            guard let self else { return }
            self.applyingConfig = false
            if ok { self.activeSerial = params }
            self.appendSystem(info)
        }
    }

    public func applyModemLines() {
        let lines = ModemLines(flowControl: editFlowControl, dtr: editDTR, rts: editRTS)
        ble.applyModemLines(lines) { [weak self] ok, info in
            guard let self else { return }
            if ok { self.activeModem = lines }
            self.appendSystem(info)
        }
    }

    // MARK: - 日志切割

    /// 截断当前日志文件并立即开启新文件
    public func rotateLog() {
        logger.updateNaming(template: settings.logNameTemplate,
                            customName: settings.logCustomName)
        logger.rotateSession { [weak self] url in
            guard let self else { return }
            if let url {
                self.appendSystem("日志已切割, 新文件 → \(url.lastPathComponent)")
            } else {
                self.appendSystem("当前没有进行中的日志会话(需先连接设备并开启日志)")
            }
        }
    }

    /// 手动开启日志会话(「结束日志」后恢复记录; 重名按规则自动避让, 不覆盖旧文件)
    public func startLog() {
        guard ble.isReady else {
            appendSystem("未连接设备, 无法开始日志")
            return
        }
        guard logger.currentFileURL == nil else { return }
        logger.openSession(directory: settings.logDirectory,
                           deviceName: ble.connectedDeviceName,
                           header: "虚拟串口: \(port.linkPath.isEmpty ? "未创建" : port.linkPath)",
                           mode: settings.logStorageMode,
                           template: settings.logNameTemplate,
                           customName: settings.logCustomName)
        appendSystem("已开启新的日志会话")
    }

    /// 手动结束日志会话(连接保持, 数据停止写盘; 重连或「开始日志」可恢复)
    public func stopLog() {
        guard logger.currentFileURL != nil else { return }
        logger.closeSession()
        appendSystem("日志会话已结束, 可在日志面板点击「开始日志」恢复记录")
    }

    // MARK: - 终端直接发送(内置控制台)

    public func sendFromTerminal(_ data: Data) {
        guard !data.isEmpty, ble.isReady else { return }
        addBytes(tx: UInt64(data.count))
        ble.send(data)
        if settings.logEnabled, settings.logSentData {
            logger.log(data, direction: .tx, format: settings.logFormat, timestamps: settings.logTimestamps)
        }
        flushPendings()
        appendLine(TerminalLine(kind: .tx, data: data))
    }

    /// 键盘直连(交互)模式: 按键字节立即发送, 不显示 TX 行(交换机回显即视觉反馈)
    public func sendInteractive(_ data: Data) {
        guard !data.isEmpty, ble.isReady else { return }
        addBytes(tx: UInt64(data.count))
        ble.send(data)
        if settings.logEnabled, settings.logSentData {
            logger.log(data, direction: .tx, format: settings.logFormat, timestamps: settings.logTimestamps)
        }
    }

    // MARK: - 终端行管理

    public func clearTerminal() {
        lines.removeAll()
        dataLines.removeAll()
        rxAssembler.reset()
        txAssembler.reset()
        rxLiveTail = false
        txLiveTail = false
        terminalGeneration &+= 1
    }

    /// 流式数据入口: 完整行立即显示, 残行即时更新到"活"行尾
    private func appendStreamChunk(_ data: Data, kind: TerminalLineKind) {
        let newLines = (kind == .rx) ? rxAssembler.feed(data) : txAssembler.feed(data)
        for line in newLines {
            appendCompletedLine(TerminalLine(kind: kind, data: line))
        }
        let pending = (kind == .rx) ? rxAssembler.pending : txAssembler.pending
        if !pending.isEmpty { updateLiveTail(kind: kind, content: pending) }
    }

    /// 完整行到达: 若行尾是同方向的"活"行尾(提示符残行), 完整行取而代之, 否则追加
    private func appendCompletedLine(_ line: TerminalLine) {
        let live = (line.kind == .rx) ? rxLiveTail : txLiveTail
        if live, lines.last?.kind == line.kind {
            let newLine = TerminalLine(kind: line.kind, data: line.data,
                                       time: lines[lines.count - 1].time)
            lines[lines.count - 1] = newLine
            // "活"行尾必为数据行且同时在两个数组末尾(系统消息会使其失效)
            if !dataLines.isEmpty { dataLines[dataLines.count - 1] = newLine }
        } else {
            lines.append(line)
            dataLines.append(line)   // 完整行只可能是 rx/tx 数据行
        }
        rxLiveTail = false
        txLiveTail = false
        trimIfNeeded()
    }

    /// 残行即时显示: "活"行尾原地更新(回显编辑/逐键输入都走这里, 无延迟)
    private func updateLiveTail(kind: TerminalLineKind, content: Data) {
        let live = (kind == .rx) ? rxLiveTail : txLiveTail
        if live, lines.last?.kind == kind {
            let old = lines[lines.count - 1]
            let newLine = TerminalLine(kind: kind, data: content, time: old.time)
            lines[lines.count - 1] = newLine
            if !dataLines.isEmpty { dataLines[dataLines.count - 1] = newLine }
        } else {
            let newLine = TerminalLine(kind: kind, data: content)
            lines.append(newLine)
            dataLines.append(newLine)   // 残行只可能是 rx/tx 数据行
            trimIfNeeded()
        }
        if kind == .rx { rxLiveTail = true } else { txLiveTail = true }
    }

    /// 封尾: 插入系统消息/整行发送前调用, 之后残行再起新行
    private func flushPendings() {
        // 吐出装配器中的残行, 使其与显示保持一致: 残行已作为"活"行尾显示,
        // 此后同一方向的后续数据不再与它拼成一行(系统消息插入后的新片段起新行)
        _ = rxAssembler.flushPending()
        _ = txAssembler.flushPending()
        rxLiveTail = false
        txLiveTail = false
    }

    private func trimIfNeeded() {
        guard lines.count > maxLines else { return }
        // 批量截断: 一次删到上限以下 trimBatch 行, 摊销 O(n) 搬移
        let removeCount = lines.count - maxLines + trimBatch
        // 同步镜像: 数出被删前缀中的数据行数
        let removedData = lines.prefix(removeCount).reduce(0) { $0 + ($1.kind == .system ? 0 : 1) }
        lines.removeFirst(removeCount)
        if removedData > 0 { dataLines.removeFirst(removedData) }
    }

    private func appendSystem(_ text: String) {
        flushPendings()
        appendLine(TerminalLine(system: text))
    }

    private func appendLine(_ line: TerminalLine) {
        lines.append(line)
        if line.kind != .system { dataLines.append(line) }
        rxLiveTail = false   // 任何新行都会使"活"行尾失效
        txLiveTail = false
        trimIfNeeded()
    }
}
