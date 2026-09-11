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

    // 透传发送队列
    private var outbox = Data()
    private var chipFullFlag = false

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

    /// 当前连接的设备 UUID(用于自动重连)
    public private(set) var connectedUUID: UUID?

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
            self.devices.removeAll()
            self.peripherals.removeAll()
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
            if self.central.isScanning { self.central.stopScan() }
            self.flushDeviceUpdates()
            self.updateMain { $0.isScanning = false }
        }
    }

    // MARK: - 连接

    public func connect(_ device: DiscoveredDevice) {
        bleQueue.async {
            guard let p = self.peripherals[device.id] ?? device.peripheral else {
                self.log("设备引用已失效, 请重新扫描")
                return
            }
            if self.central.isScanning { self.central.stopScan(); self.updateMain { $0.isScanning = false } }
            self.connectedUUID = device.id
            self.setState(.connecting)
            self.updateMain { $0.connectedDeviceName = device.name }
            self.log("正在连接 \(device.name) …")
            self.startConnecting(p)
        }
    }

    /// 按 UUID 直连(系统已知的设备, 无需先扫描)
    public func connect(uuid: UUID, name: String) {
        bleQueue.async {
            let found = self.central.retrievePeripherals(withIdentifiers: [uuid])
            guard let p = found.first else {
                self.log("未找到设备 \(name)(\(uuid.uuidString.prefix(8))), 请先扫描")
                return
            }
            self.peripherals[uuid] = p
            if self.central.isScanning { self.central.stopScan(); self.updateMain { $0.isScanning = false } }
            self.connectedUUID = uuid
            self.setState(.connecting)
            self.updateMain { $0.connectedDeviceName = name }
            self.log("正在连接 \(name) …")
            self.startConnecting(p)
        }
    }

    /// 在 bleQueue 调用: 发起连接并启动超时保护(覆盖 连接+服务发现 全程, ready 时解除)
    private func startConnecting(_ p: CBPeripheral) {
        connectTimeout?.cancel()
        connectingPeripheral = p
        central.connect(p, options: nil)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connectingPeripheral != nil else { return }
            self.connectingPeripheral = nil
            self.connectTimeout = nil
            self.central.cancelPeripheralConnection(p)
            self.connectedUUID = nil
            self.log("连接超时: 设备无响应(可能正被其他主机占用, CH9140 只支持单连接; 或不在范围内)")
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
            self.connectedUUID = nil
            let p = self.peripheral ?? self.connectingPeripheral
            self.disarmConnectTimeout()
            if let p {
                self.log("主动断开连接")
                self.central.cancelPeripheralConnection(p)
            }
            // 取消"挂起中"的连接不会回调 didDisconnectPeripheral, 这里直接落定状态
            self.setState(.disconnected)
        }
    }

    // MARK: - 透传发送

    /// 串口方向: 主机 -> 芯片 (FFF2, WriteWithoutResponse, 按 MTU 分包)
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        bleQueue.async {
            self.outbox.append(data)
            self.pumpOutbox()
        }
    }

    /// 必须在 bleQueue 调用
    private func pumpOutbox() {
        guard let p = peripheral, let wc = writeChar, !chipFullFlag else { return }
        let mtu = max(20, p.maximumWriteValueLength(for: .withoutResponse))
        while !outbox.isEmpty, p.canSendWriteWithoutResponse {
            let n = min(mtu, outbox.count)
            let chunk = outbox.prefix(n)
            p.writeValue(Data(chunk), for: wc, type: .withoutResponse)
            outbox.removeFirst(n)
        }
    }

    // MARK: - 参数配置 (FFF3)

    /// 配置串口参数, 主线程回调 (成功, 信息)
    public func applySerialParameters(_ params: SerialParameters,
                                      completion: @escaping (Bool, String) -> Void) {
        bleQueue.async {
            guard let p = self.peripheral, let cc = self.configChar, self.connectionState == .ready else {
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
            guard let p = self.peripheral, let cc = self.configChar, self.connectionState == .ready else {
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
            updateMain { $0.isScanning = false }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover p: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? p.name ?? "未知设备"
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isWCH = advertised.contains { $0.uuidString.uppercased() == CH9140UUID.service }
            || name.uppercased().hasPrefix("CH91")
        guard self.scanShowAll || isWCH else { return }
        peripherals[p.identifier] = p
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
        guard !pendingDeviceUpdates.isEmpty else { return }
        // 在 bleQueue 上取好外设引用, 避免主线程访问 peripherals
        let batch: [(id: UUID, name: String, rssi: Int, isWCH: Bool, peripheral: CBPeripheral?)] =
            pendingDeviceUpdates.map { ($0.key, $0.value.name, $0.value.rssi, $0.value.isWCH, self.peripherals[$0.key]) }
        pendingDeviceUpdates.removeAll()
        DispatchQueue.main.async {
            let now = Date()
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
        log("已连接, 正在发现服务…")
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
        connectedUUID = nil
        log("连接失败: \(error?.localizedDescription ?? "未知错误")")
        stopRSSIPolling()
        setState(.failed(error?.localizedDescription ?? "连接失败"))
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if let error { log("连接意外断开: \(error.localizedDescription)") }
        else { log("连接已断开") }
        disarmConnectTimeout()
        connectedUUID = nil
        peripheral = nil
        readChar = nil; writeChar = nil; configChar = nil
        outbox.removeAll()
        chipFullFlag = false
        failPendingSerial("连接已断开")
        failPendingModem("连接已断开")
        stopRSSIPolling()
        setState(.disconnected)
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
            let mtu = max(20, p.maximumWriteValueLength(for: .withoutResponse))
            log("透传通道就绪 (写入 MTU \(mtu) 字节)")
            setState(.ready)
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
        guard error == nil, let value = c.value, !value.isEmpty else {
            if let error { log("读取出错: \(error.localizedDescription)") }
            return
        }
        switch c.uuid.uuidString.uppercased() {
        case CH9140UUID.readCharacteristic:
            DispatchQueue.main.async { self.onReceive?(value) }

        case CH9140UUID.configCharacteristic:
            guard let packet = CH9140Protocol.decode(value) else {
                log("配置通道收到无法识别的报文: \(HexUtil.hexString(value))")
                return
            }
            handleConfigPacket(packet)

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
            chipFullFlag = s.uartSendFull && !s.uartSendEmpty
            DispatchQueue.main.async {
                self.modemStatus = s
                self.chipBufferFull = self.chipFullFlag
            }
            if !chipFullFlag { pumpOutbox() }   // 缓冲区已空, 继续发送
        }
    }
}
