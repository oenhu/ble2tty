//
//  BLEManager.swift
//  CH9140 蓝牙中心端: 扫描/连接/透传收发/参数配置
//  逻辑对照 WCH 官方 iOS CH9140BluetoothManager
//

import Foundation
import CoreBluetooth
import Combine

public enum BLEConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case discovering      // 已连接, 正在发现服务/特征
    case ready            // 透传通道已就绪
    case failed(String)
}

public struct DiscoveredDevice: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var rssi: Int
    public var lastSeen: Date
    /// 是否为 CH9140/CH91xx 设备(广播含 FFF0 服务或名称以 CH91 开头)
    public var isWCHDevice: Bool
    /// 保留的 CBPeripheral 引用(不入 Equatable 比较)
    let peripheral: CBPeripheral?

    public static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.rssi == rhs.rssi
    }
}

public final class BLEManager: NSObject, ObservableObject {

    // MARK: 发布给 UI 的状态
    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var isScanning = false
    @Published public private(set) var devices: [DiscoveredDevice] = []
    @Published public private(set) var connectionState: BLEConnectionState = .disconnected
    @Published public private(set) var connectedDeviceName: String = ""
    @Published public private(set) var modemStatus = ModemStatus()
    /// 芯片 UART 发送缓冲区满(0x88 上报)
    @Published public private(set) var chipBufferFull = false
    /// 连接中的实时信号强度(每 2 秒轮询)
    @Published public private(set) var currentRSSI: Int?
    /// 本次连接建立时间
    @Published public private(set) var connectedAt: Date?

    // MARK: 回调(均在主线程触发)
    /// 收到 FFF1 透传数据
    public var onReceive: ((Data) -> Void)?
    /// 运行日志
    public var onLog: ((String) -> Void)?
    /// 连接状态变化(用于自动重连等)
    public var onConnectionChange: ((BLEConnectionState) -> Void)?

    // MARK: 内部
    private let bleQueue = DispatchQueue(label: "cn.wch.CH9140Bridge.ble", qos: .userInitiated)
    private lazy var central = CBCentralManager(delegate: self, queue: bleQueue, options: [
        CBCentralManagerOptionShowPowerAlertKey: true
    ])
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var readChar: CBCharacteristic?
    private var writeChar: CBCharacteristic?
    private var configChar: CBCharacteristic?

    private var wantScan = false
    private var scanShowAll = false

    // 透传发送队列: 分块 FIFO(头部索引 + 定期压缩),
    // 取代 Data + removeFirst 的 O(n²) 搬移(满缓冲 drain 时曾达数百 MB memcpy)
    private var outboxChunks: [Data] = []
    private var outboxHead = 0
    private var outboxBytes = 0
    private var chipFullFlag = false
    /// 芯片缓冲满看门狗: "已空"上报丢失时防止 TX 永久停摆(仅 bleQueue)
    private var chipFullWatchdog: DispatchWorkItem?
    /// 扫描发现时间(仅 bleQueue): 淘汰长时间未再见到的设备, 防止列表/引用无界增长
    private var discoveredAt: [UUID: Date] = [:]
    /// 按 UUID 直连时系统未缓存设备 -> 转扫描查找的挂起状态(仅 bleQueue)
    private var pendingScanConnect: (uuid: UUID, name: String)?
    private var pendingScanTimeout: DispatchWorkItem?

    // 配置应答匹配
    private var pendingSerial: ((Bool, String) -> Void)?
    private var pendingSerialParams: SerialParameters?
    private var pendingSerialTimeout: DispatchWorkItem?
    private var pendingModem: ((Bool, String) -> Void)?
    private var pendingModemLines: ModemLines?
    private var pendingModemTimeout: DispatchWorkItem?
    private var rssiTimer: DispatchSourceTimer?

    // 扫描发现批量发布: 开启 AllowDuplicates 后每个广播包都会回调,
    // 先按设备聚合并留在 bleQueue, 再以固定节奏一次性发布到主线程,
    // 避免每个广播包都跳主线程 + 全量排序 + 触发设备列表重绘
    private var pendingDeviceUpdates: [UUID: (name: String, rssi: Int, isWCH: Bool)] = [:]
    private var deviceFlushScheduled = false
    /// 设备列表发布节奏(秒)
    private static let deviceFlushInterval: Double = 0.4
    /// 设备多久(秒)没再广播就被移出列表(当前连接除外)
    private static let deviceStaleInterval: Double = 60

    /// 当前连接的设备 UUID(用于 UI 高亮/自动重连)。
    /// 统一在主线程写入(@Published 要求), bleQueue 侧的连接判定用 activePeripheralID。
    @Published public private(set) var connectedUUID: UUID?

    /// 仅在 bleQueue 读写的"透传通道就绪"标志。
    /// bleQueue 上的收发/配置逻辑不再跨线程读 connectionState(主线程写)。
    private var isReadyOnQueue = false
    /// 当前活动连接的外设标识(仅 bleQueue): 识别迟到的过期回调
    /// (超时取消 / 手动断开挂起连接 / 已转连其他设备后的迟到事件)
    private var activePeripheralID: UUID?

    // 连接超时保护: CoreBluetooth 对无响应外设可能永远不回调
    // (CH9140 为单连接设备, 被安卓等其他主机占用时 connect 会无限挂起)
    /// 挂起中的外设引用(peripheral 属性只在 didConnect 后才赋值, 挂起期间靠它取消)
    private var connectingPeripheral: CBPeripheral?
    private var connectTimeout: DispatchWorkItem?
    /// 连接+服务发现总超时(秒)
    private static let connectTimeoutInterval: Double = 8

    public override init() {
        super.init()
        _ = central   // 触发 CBCentralManager 创建
    }

    public var isReady: Bool { connectionState == .ready }

    // MARK: - 扫描

    public func startScan(showAll: Bool = false) {
        bleQueue.async {
            self.wantScan = true
            self.scanShowAll = showAll
            guard self.central.state == .poweredOn else {
                self.log("蓝牙未就绪(状态 \(self.central.state.rawValue)), 等待蓝牙打开…")
                return
            }
            self.peripherals.removeAll()
            self.discoveredAt.removeAll()
            self.pendingDeviceUpdates.removeAll()   // 丢弃上一轮扫描的待发布残留
            // @Published 必须在主线程更新
            self.updateMain { $0.devices.removeAll() }
            // 注意: 部分 CH9140 固件的广播包不含 FFF0 服务 UUID,
            // 按服务过滤会漏掉设备, 因此始终全量扫描, 在发现回调中按名称/服务过滤
            self.central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ])
            self.updateMain { $0.isScanning = true }
            self.log(showAll ? "开始扫描全部 BLE 设备…" : "开始扫描 CH9140 设备(服务 FFF0)…")
        }
    }

    public func stopScan() {
        bleQueue.async {
            self.wantScan = false
            // 用户显式停止扫描: 若扫描正在为挂起连接服务, 一并取消并落定状态,
            // 否则状态会停在 connecting 直到 10s 超时
            if self.pendingScanConnect != nil {
                self.cancelPendingScanConnect()
                self.activePeripheralID = nil
                self.updateMain { $0.connectedUUID = nil }
                self.setState(.disconnected)
            }
            if self.central.isScanning { self.central.stopScan() }
            self.flushDeviceUpdates()
            self.updateMain { $0.isScanning = false }
        }
    }

    // MARK: - 连接

    public func connect(_ device: DiscoveredDevice) {
        bleQueue.async {
            guard self.central.state == .poweredOn else {
                self.log("蓝牙未开启, 无法连接")
                self.setState(.failed("蓝牙未开启"))
                return
            }
            guard let p = self.peripherals[device.id] ?? device.peripheral else {
                self.log("设备引用已失效, 请重新扫描")
                return
            }
            if self.central.isScanning { self.central.stopScan(); self.updateMain { $0.isScanning = false } }
            self.activePeripheralID = device.id
            self.updateMain { $0.connectedUUID = device.id }
            self.setState(.connecting)
            self.updateMain { $0.connectedDeviceName = device.name }
            self.log("正在连接 \(device.name) …")
            self.startConnecting(p)
        }
    }

    /// 按 UUID 直连(系统已知的设备, 无需先扫描)
    public func connect(uuid: UUID, name: String) {
        bleQueue.async {
            guard self.central.state == .poweredOn else {
                self.log("蓝牙未开启, 无法连接 \(name)")
                self.setState(.failed("蓝牙未开启"))
                return
            }
            let found = self.central.retrievePeripherals(withIdentifiers: [uuid])
            guard let p = found.first else {
                // 系统未缓存(蓝牙重启/换机/系统状态重置): 转扫描按 UUID 查找,
                // 不再静默放弃——自动重连承诺靠这条路继续兑现
                self.startPendingScanConnect(uuid: uuid, name: name)
                return
            }
            self.peripherals[uuid] = p
            if self.central.isScanning { self.central.stopScan(); self.updateMain { $0.isScanning = false } }
            self.activePeripheralID = uuid
            self.updateMain { $0.connectedUUID = uuid }
            self.setState(.connecting)
            self.updateMain { $0.connectedDeviceName = name }
            self.log("正在连接 \(name) …")
            self.startConnecting(p)
        }
    }

    /// 在 bleQueue 调用: 发起连接并启动超时保护(覆盖 连接+服务发现 全程, ready 时解除)
    private func startConnecting(_ p: CBPeripheral) {
        isReadyOnQueue = false
        cancelPendingScanConnect()
        // 转连新目标前先清理旧连接: CoreBluetooth 允许同时连多个外设,
        // 不主动断开的话旧设备的数据会继续从 FFF1 涌进来造成串流
        if let old = connectingPeripheral, !old.isEqual(p) {
            central.cancelPeripheralConnection(old)
        }
        if let old = peripheral, !old.isEqual(p) {
            log("断开当前设备, 转连新设备")
            central.cancelPeripheralConnection(old)
            peripheral = nil
            readChar = nil; writeChar = nil; configChar = nil
            clearOutbox()
        }
        connectTimeout?.cancel()
        connectingPeripheral = p
        central.connect(p, options: nil)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connectingPeripheral != nil else { return }
            self.connectingPeripheral = nil
            self.connectTimeout = nil
            self.central.cancelPeripheralConnection(p)
            self.activePeripheralID = nil
            self.isReadyOnQueue = false
            self.updateMain { $0.connectedUUID = nil }
            self.log("连接超时: 设备无响应(可能正被其他主机占用, CH9140 只支持单连接; 不在范围内; 或固件缺少 FFF1/FFF2/FFF3 透传特征)")
            self.setState(.failed("连接超时"))
        }
        connectTimeout = timeout
        bleQueue.asyncAfter(deadline: .now() + Self.connectTimeoutInterval, execute: timeout)
    }

    /// 在 bleQueue 调用: 解除连接超时保护(连接就绪/失败/断开时)
    private func disarmConnectTimeout() {
        connectTimeout?.cancel()
        connectTimeout = nil
        connectingPeripheral = nil
    }

    public func disconnect() {
        bleQueue.async {
            self.updateMain { $0.connectedUUID = nil }
            let p = self.peripheral ?? self.connectingPeripheral
            self.disarmConnectTimeout()
            // 取消"转扫描查找"阶段的挂起连接(其专用扫描一并停止)
            if self.pendingScanConnect != nil {
                self.cancelPendingScanConnect(stopScan: true)
                self.activePeripheralID = nil
            }
            let wasEstablished = self.peripheral != nil
            if let p {
                self.log("主动断开连接")
                self.central.cancelPeripheralConnection(p)
            }
            if !wasEstablished {
                // 挂起中的连接取消后不会回调 didDisconnectPeripheral, 这里直接落定状态;
                // activePeripheralID 同时清空, 使迟到的断连回调被识别为过期事件
                self.activePeripheralID = nil
                self.isReadyOnQueue = false
                self.peripheral = nil
                self.readChar = nil; self.writeChar = nil; self.configChar = nil
                self.clearOutbox()
                self.stopRSSIPolling()
                self.setState(.disconnected)
            }
            // 已建立连接的取消: 状态由 didDisconnectPeripheral 回调统一落定(避免双重事件)
        }
    }

    // MARK: - 透传发送

    /// 串口方向: 主机 -> 芯片 (FFF2, WriteWithoutResponse, 按 MTU 分包)
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        bleQueue.async {
            // 仅在透传通道就绪时排队: 断连期间(如串口工具仍在写虚拟串口)的数据
            // 直接丢弃, 防止陈旧数据在下次连接时"复活"发给新连接的设备
            guard self.isReadyOnQueue else { return }
            self.outboxChunks.append(data)
            self.outboxBytes += data.count
            // 芯片缓冲长期满载(如流控卡死/对端不读)时防止内存无限增长: 丢弃最旧数据
            let maxOutbox = 256 * 1024
            if self.outboxBytes > maxOutbox {
                var dropped = 0
                while self.outboxBytes > maxOutbox, self.outboxHead < self.outboxChunks.count {
                    self.outboxBytes -= self.outboxChunks[self.outboxHead].count
                    dropped += self.outboxChunks[self.outboxHead].count
                    self.outboxHead += 1
                }
                self.log("芯片发送缓冲区持续满载, 发送队列溢出, 已丢弃最旧 \(dropped) 字节")
            }
            self.pumpOutbox()
        }
    }

    /// 必须在 bleQueue 调用
    private func pumpOutbox() {
        guard let p = peripheral, let wc = writeChar, !chipFullFlag else { return }
        let mtu = max(20, p.maximumWriteValueLength(for: .withoutResponse))
        while outboxHead < outboxChunks.count, p.canSendWriteWithoutResponse {
            let chunk = outboxChunks[outboxHead]
            let n = min(mtu, chunk.count)
            p.writeValue(Data(chunk.prefix(n)), for: wc, type: .withoutResponse)
            outboxBytes -= n
            if n == chunk.count {
                outboxHead += 1
            } else {
                // 大块按 MTU 截发: 余量写回(拷贝 ≤ 单块大小, 不再是全队列 O(n) 搬移)
                outboxChunks[outboxHead] = chunk.dropFirst(n)
            }
        }
        // 头部索引前进后定期压缩, 防止数组前缀空洞增长
        if outboxHead > 64 && outboxHead * 2 > outboxChunks.count {
            outboxChunks.removeFirst(outboxHead)
            outboxHead = 0
        }
    }

    /// 仅 bleQueue: 清空发送队列并复位芯片流控状态(新会话/断连/蓝牙关闭时)
    private func clearOutbox() {
        outboxChunks.removeAll()
        outboxHead = 0
        outboxBytes = 0
        chipFullFlag = false
        chipFullWatchdog?.cancel()
        chipFullWatchdog = nil
    }

    /// 仅 bleQueue: 取消"转扫描查找"的挂起连接
    private func cancelPendingScanConnect(stopScan: Bool = false) {
        pendingScanConnect = nil
        pendingScanTimeout?.cancel()
        pendingScanTimeout = nil
        if stopScan, central.isScanning {
            central.stopScan()
            updateMain { $0.isScanning = false }
        }
    }

    /// 仅 bleQueue: 系统未缓存目标设备时, 转扫描按 UUID 查找(带 10s 超时)
    private func startPendingScanConnect(uuid: UUID, name: String) {
        cancelPendingScanConnect()
        pendingScanConnect = (uuid, name)
        activePeripheralID = uuid
        updateMain {
            $0.connectedUUID = uuid
            $0.connectedDeviceName = name
        }
        setState(.connecting)
        log("系统未缓存设备 \(name), 转为扫描查找…")
        if !central.isScanning {
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ])
            updateMain { $0.isScanning = true }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pendingScanConnect != nil else { return }
            self.pendingScanConnect = nil
            self.pendingScanTimeout = nil
            self.activePeripheralID = nil
            self.updateMain { $0.connectedUUID = nil }
            self.log("扫描查找超时: 未发现 \(name)(不在范围内或未开机)")
            self.setState(.failed("扫描查找超时"))
        }
        pendingScanTimeout = timeout
        bleQueue.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    /// 仅 bleQueue: 芯片缓冲满看门狗。4 秒未解除则试探恢复发送;
    /// 若芯片真的仍满, 下一次 0x88 满上报会重新武装看门狗
    private func armChipFullWatchdog() {
        let wd = DispatchWorkItem { [weak self] in
            guard let self, self.chipFullFlag else { return }
            self.chipFullWatchdog = nil
            self.chipFullFlag = false
            self.log("芯片缓冲满状态超过 4 秒未解除, 试探恢复发送(状态上报可能已丢失)")
            DispatchQueue.main.async { self.chipBufferFull = false }
            self.pumpOutbox()
        }
        chipFullWatchdog = wd
        bleQueue.asyncAfter(deadline: .now() + 4, execute: wd)
    }

    // MARK: - 参数配置 (FFF3)

    /// 配置串口参数, 主线程回调 (成功, 信息)
    public func applySerialParameters(_ params: SerialParameters,
                                      completion: @escaping (Bool, String) -> Void) {
        bleQueue.async {
            guard let p = self.peripheral, let cc = self.configChar, self.isReadyOnQueue else {
                DispatchQueue.main.async { completion(false, "配置通道不可用(未连接)") }
                return
            }
            self.failPendingSerial("被新的配置请求覆盖")
            self.pendingSerial = completion
            self.pendingSerialParams = params
            let cmd = CH9140Protocol.encodeSerialParameters(params)
            p.writeValue(cmd, for: cc, type: .withResponse)
            self.log("下发串口配置: 波特率 \(params.baudRate) 数据位 \(params.dataBits) 停止位 \(params.stopBits) 校验 \(params.parity)")
            let timeout = DispatchWorkItem { [weak self] in
                self?.failPendingSerial("等待芯片应答超时")
            }
            self.pendingSerialTimeout = timeout
            self.bleQueue.asyncAfter(deadline: .now() + 2.0, execute: timeout)
            // 兼容只支持读方式的固件: 150ms 后主动读一次
            self.bleQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let cc = self.configChar, self.pendingSerial != nil else { return }
                p.readValue(for: cc)
            }
        }
    }

    /// 配置流控及 DTR/RTS
    public func applyModemLines(_ lines: ModemLines,
                                completion: @escaping (Bool, String) -> Void) {
        bleQueue.async {
            guard let p = self.peripheral, let cc = self.configChar, self.isReadyOnQueue else {
                DispatchQueue.main.async { completion(false, "配置通道不可用(未连接)") }
                return
            }
            self.failPendingModem("被新的配置请求覆盖")
            self.pendingModem = completion
            self.pendingModemLines = lines
            let cmd = CH9140Protocol.encodeModemLines(lines)
            p.writeValue(cmd, for: cc, type: .withResponse)
            self.log("下发 MODEM/流控配置: 流控 \(lines.flowControl ? "开" : "关") DTR \(lines.dtr) RTS \(lines.rts)")
            let timeout = DispatchWorkItem { [weak self] in
                self?.failPendingModem("等待芯片应答超时")
            }
            self.pendingModemTimeout = timeout
            self.bleQueue.asyncAfter(deadline: .now() + 2.0, execute: timeout)
            self.bleQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let cc = self.configChar, self.pendingModem != nil else { return }
                p.readValue(for: cc)
            }
        }
    }

    private func failPendingSerial(_ reason: String) {
        guard let cb = pendingSerial else { return }
        pendingSerial = nil; pendingSerialParams = nil
        pendingSerialTimeout?.cancel(); pendingSerialTimeout = nil
        DispatchQueue.main.async { cb(false, reason) }
    }

    private func failPendingModem(_ reason: String) {
        guard let cb = pendingModem else { return }
        pendingModem = nil; pendingModemLines = nil
        pendingModemTimeout?.cancel(); pendingModemTimeout = nil
        DispatchQueue.main.async { cb(false, reason) }
    }

    // MARK: - 连接质量(RSSI 轮询)

    private func startRSSIPolling() {
        stopRSSIPolling()
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self, let p = self.peripheral, p.state == .connected else { return }
            p.readRSSI()
        }
        rssiTimer = timer
        timer.resume()
    }

    private func stopRSSIPolling() {
        rssiTimer?.cancel()
        rssiTimer = nil
        updateMain {
            $0.currentRSSI = nil
            $0.connectedAt = nil
        }
    }

    // MARK: - 工具

    private func setState(_ s: BLEConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = s
            self.onConnectionChange?(s)
        }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { self.onLog?(message) }
    }

    private func updateMain(_ mutate: @escaping (BLEManager) -> Void) {
        DispatchQueue.main.async { mutate(self) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateMain { $0.bluetoothState = central.state }
        switch central.state {
        case .poweredOn:
            log("蓝牙已打开")
            if wantScan {
                wantScan = false
                startScan(showAll: scanShowAll)
            }
        case .poweredOff:  log("蓝牙已关闭")
        case .unauthorized: log("蓝牙未授权: 请在 系统设置 > 隐私与安全性 > 蓝牙 中允许本 App")
        case .unsupported: log("该 Mac 不支持蓝牙低功耗")
        default: break
        }
        if central.state != .poweredOn {
            // 蓝牙不可用: CoreBluetooth 不保证对每个外设补发断连回调,
            // 这里主动落定连接状态, 防止 UI 停在"已就绪"、RSSI 轮询空转
            let hadLink = peripheral != nil || connectingPeripheral != nil
                || isReadyOnQueue || pendingScanConnect != nil
            if hadLink {
                log("蓝牙不可用, 连接已断开")
                teardownConnectionOnQueue(configFailReason: "蓝牙已关闭")
                setState(.disconnected)
            }
            // 断电后系统缓存的外设引用全部失效, 一并清除
            peripherals.removeAll()
            discoveredAt.removeAll()
            pendingDeviceUpdates.removeAll()
            updateMain {
                $0.isScanning = false
                $0.devices.removeAll()
            }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover p: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        // 重连扫描匹配优先于一切过滤: 目标设备可能不广播 FFF0, 也可能被改名
        if let pend = pendingScanConnect, p.identifier == pend.uuid {
            cancelPendingScanConnect(stopScan: true)
            peripherals[p.identifier] = p
            discoveredAt[p.identifier] = Date()
            log("扫描到目标设备 \(pend.name), 发起连接…")
            startConnecting(p)
            return
        }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? p.name ?? "未知设备"
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isWCH = advertised.contains { $0.uuidString.uppercased() == CH9140UUID.service }
            || name.uppercased().hasPrefix("CH91")
        guard self.scanShowAll || isWCH else { return }
        peripherals[p.identifier] = p
        discoveredAt[p.identifier] = Date()
        // 聚合并安排批量发布(同一设备一个窗口内的多个广播包只保留最新一条)
        pendingDeviceUpdates[p.identifier] = (name, RSSI.intValue, isWCH)
        scheduleDeviceListFlush()
    }

    /// 在 bleQueue 上调用: 安排一次设备列表批量发布(窗口内的所有广播合并为一次主线程更新+排序)
    private func scheduleDeviceListFlush() {
        guard !deviceFlushScheduled else { return }
        deviceFlushScheduled = true
        bleQueue.asyncAfter(deadline: .now() + Self.deviceFlushInterval) { [weak self] in
            guard let self else { return }
            self.deviceFlushScheduled = false
            self.flushDeviceUpdates()
        }
    }

    /// 在 bleQueue 上调用: 把聚合的广播更新一次性发布到主线程
    private func flushDeviceUpdates() {
        // 淘汰 60s 未再见到的设备(当前连接除外): 长时间扫描时列表与外设引用不再无界增长
        let cutoff = Date().addingTimeInterval(-Self.deviceStaleInterval)
        let staleIDs = discoveredAt.filter { $0.value < cutoff }.map(\.key)
            .filter { $0 != activePeripheralID }
        for id in staleIDs {
            peripherals.removeValue(forKey: id)
            discoveredAt.removeValue(forKey: id)
        }
        let staleSet = Set(staleIDs)
        guard !pendingDeviceUpdates.isEmpty || !staleSet.isEmpty else { return }
        // 在 bleQueue 上取好外设引用, 避免主线程访问 peripherals
        let batch: [(id: UUID, name: String, rssi: Int, isWCH: Bool, peripheral: CBPeripheral?)] =
            pendingDeviceUpdates.map { ($0.key, $0.value.name, $0.value.rssi, $0.value.isWCH, self.peripherals[$0.key]) }
        pendingDeviceUpdates.removeAll()
        DispatchQueue.main.async {
            let now = Date()
            if !staleSet.isEmpty {
                self.devices.removeAll { staleSet.contains($0.id) }
            }
            for item in batch {
                if let idx = self.devices.firstIndex(where: { $0.id == item.id }) {
                    self.devices[idx].name = item.name
                    self.devices[idx].rssi = item.rssi
                    self.devices[idx].lastSeen = now
                    self.devices[idx].isWCHDevice = item.isWCH
                } else {
                    self.devices.append(DiscoveredDevice(id: item.id, name: item.name,
                                                         rssi: item.rssi,
                                                         lastSeen: now,
                                                         isWCHDevice: item.isWCH,
                                                         peripheral: item.peripheral))
                }
            }
            self.devices.sort { $0.rssi > $1.rssi }
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        // 迟到的连接成功回调(已被超时取消 / 已转连其他设备): 立即断开, 不进入发现流程
        guard let pending = connectingPeripheral, p.isEqual(pending) else {
            log("忽略过期连接的成功回调")
            central.cancelPeripheralConnection(p)
            return
        }
        log("已连接, 正在发现服务…")
        // 新会话从清空发送队列开始: 断连期间积压的数据不带入新连接
        clearOutbox()
        setState(.discovering)
        peripheral = p
        p.delegate = self
        p.discoverServices([CBUUID(string: CH9140UUID.service)])
        DispatchQueue.main.async { self.connectedAt = Date() }
        startRSSIPolling()
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect p: CBPeripheral, error: Error?) {
        disarmConnectTimeout()
        activePeripheralID = nil
        isReadyOnQueue = false
        updateMain { $0.connectedUUID = nil }
        log("连接失败: \(error?.localizedDescription ?? "未知错误")")
        stopRSSIPolling()
        setState(.failed(error?.localizedDescription ?? "连接失败"))
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        // 过期回调统一由 activePeripheralID 识别:
        // 超时取消后 / 手动断开挂起连接后 / 已转连新设备后的迟到断连事件
        guard activePeripheralID == p.identifier else {
            log("忽略过期连接的断连回调")
            return
        }
        if let error { log("连接意外断开: \(error.localizedDescription)") }
        else { log("连接已断开") }
        teardownConnectionOnQueue(configFailReason: "连接已断开")
        setState(.disconnected)
    }

    /// 仅 bleQueue: 连接态统一清理(断连回调 / 蓝牙关闭 / 主动断开共用)
    private func teardownConnectionOnQueue(configFailReason: String) {
        disarmConnectTimeout()
        cancelPendingScanConnect()
        activePeripheralID = nil
        isReadyOnQueue = false
        updateMain { $0.connectedUUID = nil }
        peripheral = nil
        readChar = nil; writeChar = nil; configChar = nil
        clearOutbox()
        failPendingSerial(configFailReason)
        failPendingModem(configFailReason)
        stopRSSIPolling()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = p.services, !services.isEmpty else {
            log("服务发现失败: \(error?.localizedDescription ?? "无服务")")
            return
        }
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ p: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else {
            log("特征发现失败: \(error?.localizedDescription ?? "无特征")")
            return
        }
        for c in chars {
            switch c.uuid.uuidString.uppercased() {
            case CH9140UUID.readCharacteristic:
                readChar = c
                p.setNotifyValue(true, for: c)
            case CH9140UUID.writeCharacteristic:
                writeChar = c
            case CH9140UUID.configCharacteristic:
                configChar = c
                p.setNotifyValue(true, for: c)
            default: break
            }
        }
        if readChar != nil, writeChar != nil, configChar != nil {
            disarmConnectTimeout()
            isReadyOnQueue = true
            let mtu = max(20, p.maximumWriteValueLength(for: .withoutResponse))
            log("透传通道就绪 (写入 MTU \(mtu) 字节)")
            setState(.ready)
        } else if service.uuid.uuidString.uppercased() == CH9140UUID.service {
            // 特征不全: 明确指出缺了什么, 避免用户只看到误导性的"连接超时"
            let missing = [
                readChar == nil ? CH9140UUID.readCharacteristic : nil,
                writeChar == nil ? CH9140UUID.writeCharacteristic : nil,
                configChar == nil ? CH9140UUID.configCharacteristic : nil
            ].compactMap { $0 }
            if !missing.isEmpty {
                log("透传服务缺少特征: \(missing.joined(separator: " / " )), 无法就绪(将按连接超时处理)")
            }
        }
    }

    public func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil {
            updateMain { $0.currentRSSI = RSSI.intValue }
        }
    }

    public func peripheral(_ p: CBPeripheral,
                           didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { log("订阅 \(c.uuid.uuidString) 失败: \(error.localizedDescription)") }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        pumpOutbox()
    }

    public func peripheral(_ p: CBPeripheral,
                           didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { log("写入 \(c.uuid.uuidString) 出错: \(error.localizedDescription)") }
    }

    public func peripheral(_ p: CBPeripheral,
                           didUpdateValueFor c: CBCharacteristic, error: Error?) {
        // 只处理当前设备的数据(防御多连接并存期间的串流)
        guard let current = peripheral, p.isEqual(current) else { return }
        guard error == nil, let value = c.value, !value.isEmpty else {
            if let error { log("读取出错: \(error.localizedDescription)") }
            return
        }
        switch c.uuid.uuidString.uppercased() {
        case CH9140UUID.readCharacteristic:
            DispatchQueue.main.async { self.onReceive?(value) }

        case CH9140UUID.configCharacteristic:
            // 帧拆分解码: 容忍固件粘连多帧或夹带噪声, 可解析的帧不陪葬
            let (packets, residue) = CH9140Protocol.decodeFrames(value)
            if !residue.isEmpty {
                log("配置通道丢弃无法识别的 \(residue.count) 字节: \(HexUtil.hexString(residue))")
            }
            for packet in packets { handleConfigPacket(packet) }

        default: break
        }
    }

    /// 在 bleQueue 上调用
    private func handleConfigPacket(_ packet: ConfigPacket) {
        switch packet {
        case .serialParameters(let sp):
            if let expected = pendingSerialParams, let cb = pendingSerial {
                let ok = (sp == expected)
                pendingSerial = nil; pendingSerialParams = nil
                pendingSerialTimeout?.cancel(); pendingSerialTimeout = nil
                DispatchQueue.main.async { cb(ok, ok ? "串口参数配置成功" : "芯片回包与请求不一致") }
            }

        case .modemLines(let ml):
            if let expected = pendingModemLines, let cb = pendingModem {
                let ok = (ml == expected)
                pendingModem = nil; pendingModemLines = nil
                pendingModemTimeout?.cancel(); pendingModemTimeout = nil
                DispatchQueue.main.async { cb(ok, ok ? "流控/MODEM 配置成功" : "芯片回包与请求不一致") }
            }

        case .status(let s):
            chipFullWatchdog?.cancel()
            chipFullWatchdog = nil
            chipFullFlag = s.uartSendFull && !s.uartSendEmpty
            DispatchQueue.main.async {
                self.modemStatus = s
                self.chipBufferFull = self.chipFullFlag
            }
            if chipFullFlag {
                armChipFullWatchdog()   // "已空"上报丢失时兜底
            } else {
                pumpOutbox()            // 缓冲区已空, 继续发送
            }
        }
    }
}
