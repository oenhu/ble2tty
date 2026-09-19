//
//  BridgeModel.swift
//  顶层模型: BLE <-> 虚拟串口 <-> 日志 <-> 设置 的粘合层
//

import Foundation
import Combine
import CoreBluetooth   // CBManagerState(重连的蓝牙门控)
import AppKit   // NSApplication.willTerminateNotification(进程退出日志收尾)

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
    public let wired = WiredSerialPort()
    public let port = VirtualSerialPort()
    public let logger = SessionLogger()
    public let settings = SettingsStore()

    /// 链路种类: BLE(CH9140) 或 有线串口
    public enum LinkKind: String, Sendable { case ble, wired }
    /// 设备列表页正在查看的源(可与活动连接不同)
    @Published public var listSource: LinkKind = .ble
    /// 当前活动连接所属的链路
    @Published public private(set) var activeLinkKind: LinkKind = .ble
    /// 枚举到的有线串口(有线页展示)
    @Published public private(set) var wiredPorts: [SerialPortInfo] = []
    /// 有线连接时使用的参数(自动重连时恢复同一会话参数)
    private var lastWiredParams: (params: SerialParameters, flowControl: Bool)?

    /// 活动链路是否就绪(发送区/参数面板的总开关)
    public var isLinkReady: Bool {
        activeLinkKind == .ble ? ble.isReady : wired.isReady
    }
    /// 活动链路的连接状态(状态栏指示)
    public var activeConnectionState: BLEConnectionState {
        activeLinkKind == .ble ? ble.connectionState : wired.connectionState
    }
    /// 活动链路的对端名称
    public var activeConnectionName: String {
        activeLinkKind == .ble ? ble.connectedDeviceName : wired.connectedPortName
    }

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

    /// 自动重连目标: BLE 按 UUID, 有线按设备路径
    private var reconnectTarget: (kind: LinkKind, uuid: UUID?, path: String?, name: String)?
    /// 退出收尾观察者 token(deinit 时移除)
    private var terminateObserver: NSObjectProtocol?

    deinit {
        if let t = terminateObserver { NotificationCenter.default.removeObserver(t) }
    }

    public init() {
        rxAssembler.onBell = { [weak self] in self?.onBell?() }
        txAssembler.onBell = { [weak self] in self?.onBell?() }
        wireBLE()
        wireWired()
        wirePort()
        // 有线链路的状态变化经 model 转发, 视图观察 model 即可联动(isLinkReady 等计算属性)
        wired.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        // 进程退出收尾: 同步冲刷日志开放行/半字暂存并写会话 footer, 落盘后再退出
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.port.close()              // 清理 cu.* 符号链接与 PTY, 退出不残留
            self?.wired.disconnect()        // 释放有线串口独占
            self?.logger.closeSessionSync()
        }
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

    private var cancellables = Set<AnyCancellable>()

    private func wireBLE() {
        // raw 原始日志开关: 会话进行中切换立即生效(补开/收尾文件)
        settings.$logRawEnabled.dropFirst().sink { [weak self] on in
            self?.logger.setRawEnabled(on)
        }.store(in: &cancellables)

        // 日志打开/写盘失败上报(每会话一次): 让"取证日志没写成"立即可见
        logger.onError = { [weak self] msg in
            self?.appendSystem(msg)
        }

        ble.onReceive = { [weak self] data in
            self?.handleInboundData(data)
        }

        ble.onLog = { [weak self] msg in
            self?.appendSystem(msg)
        }

        // 蓝牙恢复: 补上因蓝牙关闭而挂起的重连
        ble.$bluetoothState.dropFirst().sink { [weak self] st in
            guard let self, st == .poweredOn, self.reconnectPendingBT else { return }
            self.reconnectPendingBT = false
            self.scheduleReconnect()
        }.store(in: &cancellables)

        ble.onConnectionChange = { [weak self] state in
            guard let self, self.activeLinkKind == .ble else { return }
            switch state {
            case .ready:
                self.reconnectAttempt = 0
                self.reconnectPendingBT = false
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
                self.scheduleReconnect()
            default:
                break
            }
        }
    }

    /// BLE / 有线共用的接收处理: 字节统计 / 转发虚拟串口 / 日志 / 终端显示 / 原始旁路
    private func handleInboundData(_ data: Data) {
        addBytes(rx: UInt64(data.count))
        port.writeToPort(data)
        if settings.logEnabled {
            logger.log(data, direction: .rx,
                        format: settings.logFormat,
                        timestamps: settings.logTimestamps,
                        decodeGBK: settings.logGBKCompatible,
                        stripANSI: settings.logCleanStripANSI,
                        cr: settings.logCleanCRMode,
                        bs: settings.logCleanBSMode)
        }
        appendStreamChunk(data, kind: .rx)
        onRawRX?(data)
    }

    // MARK: - 有线串口事件接线

    private func wireWired() {
        wired.onReceive = { [weak self] data in
            self?.handleInboundData(data)
        }
        wired.onLog = { [weak self] msg in
            self?.appendSystem(msg)
        }
        wired.onConnectionChange = { [weak self] state in
            guard let self, self.activeLinkKind == .wired else { return }
            switch state {
            case .ready:
                self.reconnectAttempt = 0
                self.reconnectPendingBT = false
                self.resetByteCounters()
                if self.settings.logEnabled { self.startLog() }
                // 与 BLE 一致: 就绪后按需下发 MODEM/流控(打开时串口参数已随 open 设置)
                if self.settings.applyDefaultsOnConnect {
                    self.applyModemLines()
                }
            case .disconnected, .failed:
                self.logger.closeSession()
                self.scheduleReconnect()
            default:
                break
            }
        }
    }

    /// 枚举有线串口(后台执行, 结果发布到 wiredPorts)
    public func refreshWiredPorts() {
        DispatchQueue.global(qos: .userInitiated).async {
            let ports = SerialPortEnumerator.listPorts()
            DispatchQueue.main.async { self.wiredPorts = ports }
        }
    }

    // MARK: - 自动重连

    /// 已尝试次数(连接就绪/用户手动操作时清零)
    private var reconnectAttempt = 0
    /// 蓝牙关闭导致的挂起重连(蓝牙恢复 poweredOn 时补发)
    private var reconnectPendingBT = false

    /// 自动重连: 指数退避(2s 起, 30s 封顶, 不限次);
    /// 触发时蓝牙未开启则挂起, 待蓝牙恢复后由 $bluetoothState 观察者补发
    private func scheduleReconnect() {
        guard settings.autoReconnect, let target = reconnectTarget else { return }
        reconnectAttempt += 1
        let delay = min(2.0 * pow(2.0, Double(reconnectAttempt - 1)), 30.0)
        appendSystem("\(Int(delay)) 秒后尝试自动重连 \(target.name)(第 \(reconnectAttempt) 次)…")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // 排除进行态与已恢复连接即可; .failed 是连接尝试的常见终态, 也要放行重连
            switch self.ble.connectionState {
            case .connecting, .discovering, .ready:
                return
            case .disconnected, .failed:
                break
            }
            guard self.ble.bluetoothState == .poweredOn else {
                self.appendSystem("蓝牙未开启, 待恢复后重连 \(target.name)")
                self.reconnectPendingBT = true
                return
            }
            switch target.kind {
            case .ble:
                guard let uuid = target.uuid else { return }
                self.ble.connect(uuid: uuid, name: target.name)
            case .wired:
                guard let path = target.path else { return }
                let lp = self.lastWiredParams
                    ?? (self.settings.defaultSerialParameters, self.settings.defaultFlowControl)
                self.wired.connect(path: path, name: target.name,
                                   params: lp.params, flowControl: lp.flowControl)
            }
        }
    }

    // MARK: - 虚拟串口事件接线

    private func wirePort() {
        port.onDataFromPort = { [weak self] data in
            guard let self else { return }
            self.addBytes(tx: UInt64(data.count))
            self.sendToActiveLink(data)
            DispatchQueue.main.async {
                // raw 永远全量含 TX; logSentData 只决定 clean 是否包含
                if self.settings.logEnabled, self.settings.logSentData || self.settings.logRawEnabled {
                    self.logger.log(data, direction: .tx,
                                    format: self.settings.logFormat,
                                    timestamps: self.settings.logTimestamps,
                                    decodeGBK: self.settings.logGBKCompatible,
                                    stripANSI: self.settings.logCleanStripANSI,
                                    cr: self.settings.logCleanCRMode,
                                    bs: self.settings.logCleanBSMode,
                                    includeClean: self.settings.logSentData)
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
                guard self.settings.followVirtualPortBaud, self.isLinkReady else { return }
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
        wired.disconnect()   // 同一时刻只允许一条活动链路
        activeLinkKind = .ble
        reconnectTarget = (.ble, device.id, nil, device.name)
        reconnectAttempt = 0
        reconnectPendingBT = false
        ble.connect(device)
    }

    /// 连接"最近连接"列表里的设备(无需先扫描)
    public func connectRecent(_ device: RecentDevice) {
        wired.disconnect()   // 同一时刻只允许一条活动链路
        activeLinkKind = .ble
        reconnectTarget = (.ble, device.uuid, nil, device.name)
        reconnectAttempt = 0
        reconnectPendingBT = false
        ble.connect(uuid: device.uuid, name: device.name)
    }

    /// 连接有线串口(IOKit 枚举到的设备)
    public func connectWired(_ info: SerialPortInfo) {
        ble.disconnect()   // 同一时刻只允许一条活动链路
        activeLinkKind = .wired
        reconnectTarget = (.wired, nil, info.path, info.name)
        reconnectAttempt = 0
        reconnectPendingBT = false
        let params = SerialParameters(baudRate: editBaudRate, dataBits: editDataBits,
                                      stopBits: editStopBits, parity: editParity)
        lastWiredParams = (params, editFlowControl)
        wired.connect(path: info.path, name: info.name,
                      params: params, flowControl: editFlowControl)
    }

    public func disconnect() {
        reconnectTarget = nil
        reconnectAttempt = 0
        reconnectPendingBT = false
        switch activeLinkKind {
        case .ble:   ble.disconnect()
        case .wired: wired.disconnect()
        }
    }

    // MARK: - 参数下发

    public func applySerialParameters() {
        let params = SerialParameters(baudRate: editBaudRate, dataBits: editDataBits,
                                      stopBits: editStopBits, parity: editParity)
        applyingConfig = true
        let done: (Bool, String) -> Void = { [weak self] ok, info in
            guard let self else { return }
            self.applyingConfig = false
            if ok { self.activeSerial = params }
            self.appendSystem(info)
        }
        switch activeLinkKind {
        case .ble:   ble.applySerialParameters(params, completion: done)
        case .wired: wired.applySerialParameters(params, completion: done)
        }
    }

    public func applyModemLines() {
        let lines = ModemLines(flowControl: editFlowControl, dtr: editDTR, rts: editRTS)
        let done: (Bool, String) -> Void = { [weak self] ok, info in
            guard let self else { return }
            if ok { self.activeModem = lines }
            self.appendSystem(info)
        }
        switch activeLinkKind {
        case .ble:   ble.applyModemLines(lines, completion: done)
        case .wired: wired.applyModemLines(lines, completion: done)
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
        guard isLinkReady else {
            appendSystem("未连接设备, 无法开始日志")
            return
        }
        guard logger.currentFileURL == nil else { return }
        // banner 中如实标注转码(文件字节与线上原始字节不一致的唯一情况)
        var header = "虚拟串口: \(port.linkPath.isEmpty ? "未创建" : port.linkPath)"
        if settings.logGBKCompatible, settings.logFormat == .ascii {
            header += "\n编码: 中文兼容已启用, GBK 内容已转码为 UTF-8"
        }
        logger.openSession(directory: settings.logDirectory,
                           deviceName: ble.connectedDeviceName,
                           header: header,
                           mode: settings.logStorageMode,
                           template: settings.logNameTemplate,
                           customName: settings.logCustomName,
                           rawEnabled: settings.logRawEnabled,
                           format: settings.logFormat,
                           timestamps: settings.logTimestamps) { [weak self] url in
            guard let self else { return }
            if let url {
                self.appendSystem("已开启新的日志会话 → \(url.lastPathComponent)")
            } else {
                self.appendSystem("日志开启失败: 无法写入 \(self.settings.logDirectoryPath), 请检查目录权限与磁盘空间")
            }
        }
    }

    /// 手动结束日志会话(连接保持, 数据停止写盘; 重连或「开始日志」可恢复)
    public func stopLog() {
        guard logger.currentFileURL != nil else { return }
        logger.closeSession()
        appendSystem("日志会话已结束, 可在日志面板点击「开始日志」恢复记录")
    }

    /// 向活动链路发送(BLE 或 有线)
    private func sendToActiveLink(_ data: Data) {
        switch activeLinkKind {
        case .ble:   ble.send(data)
        case .wired: wired.send(data)
        }
    }

    // MARK: - 终端直接发送(内置控制台)

    public func sendFromTerminal(_ data: Data) {
        guard !data.isEmpty, isLinkReady else { return }
        addBytes(tx: UInt64(data.count))
        sendToActiveLink(data)
        if settings.logEnabled, settings.logSentData || settings.logRawEnabled {
            logger.log(data, direction: .tx, format: settings.logFormat, timestamps: settings.logTimestamps,
                       decodeGBK: settings.logGBKCompatible,
                       stripANSI: settings.logCleanStripANSI,
                       cr: settings.logCleanCRMode, bs: settings.logCleanBSMode,
                       includeClean: settings.logSentData)
        }
        flushPendings()
        appendLine(TerminalLine(kind: .tx, data: data))
    }

    /// 键盘直连(交互)模式: 按键字节立即发送, 不显示 TX 行(交换机回显即视觉反馈)
    public func sendInteractive(_ data: Data) {
        guard !data.isEmpty, isLinkReady else { return }
        addBytes(tx: UInt64(data.count))
        sendToActiveLink(data)
        if settings.logEnabled, settings.logSentData || settings.logRawEnabled {
            logger.log(data, direction: .tx, format: settings.logFormat, timestamps: settings.logTimestamps,
                       decodeGBK: settings.logGBKCompatible,
                       stripANSI: settings.logCleanStripANSI,
                       cr: settings.logCleanCRMode, bs: settings.logCleanBSMode,
                       includeClean: settings.logSentData)
        }
    }

    /// 终端监视页文本解码: 严格 UTF-8 优先; 开启中文兼容时回退 GBK; 再失败宽松解码。
    /// (此前用 printableASCII 把 ≥0x7F 字节全部替换为 ".", 中文控制台输出不可读)
    public func displayText(_ data: Data) -> String {
        if let s = String(bytes: data, encoding: .utf8) { return s }
        if settings.logGBKCompatible, let s = String(bytes: data, encoding: SessionLogger.gbkEncoding) { return s }
        return String(decoding: data, as: UTF8.self)
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
