//
//  SettingsStore.swift
//  用户设置(UserDefaults 持久化)
//

import Foundation
import Combine

/// 最近连接过的设备
public struct RecentDevice: Codable, Equatable, Identifiable, Sendable {
    public let uuid: UUID
    public var name: String
    public var lastUsed: Date
    /// 设备真实 MAC(XX-XX-XX-XX-XX-XX), 连接就绪时从系统解析并缓存;
    /// 旧持久化记录无此字段, 解码为 nil(可选属性自动兼容缺失键)
    public var macAddress: String?
    public var id: UUID { uuid }
}

public final class SettingsStore: ObservableObject {

    /// 允许注入 UserDefaults 实例(自检用独立 suite, 不触碰正式 App 的偏好域)
    private let defaults: UserDefaults
    private func key(_ k: String) -> String { "CH9140Bridge.\(k)" }

    // MARK: - 串口默认参数(连接后自动下发给芯片)

    @Published public var defaultBaudRate: UInt32 {
        didSet { defaults.set(Int(defaultBaudRate), forKey: key("defaultBaudRate")) }
    }
    @Published public var defaultDataBits: UInt8 {
        didSet { defaults.set(Int(defaultDataBits), forKey: key("defaultDataBits")) }
    }
    @Published public var defaultStopBits: UInt8 {
        didSet { defaults.set(Int(defaultStopBits), forKey: key("defaultStopBits")) }
    }
    /// 0=无 1=奇 2=偶 3=标志 4=空白
    @Published public var defaultParity: UInt8 {
        didSet { defaults.set(Int(defaultParity), forKey: key("defaultParity")) }
    }
    @Published public var defaultFlowControl: Bool {
        didSet { defaults.set(defaultFlowControl, forKey: key("defaultFlowControl")) }
    }
    /// 连接成功后自动把默认串口参数下发给芯片
    @Published public var applyDefaultsOnConnect: Bool {
        didSet { defaults.set(applyDefaultsOnConnect, forKey: key("applyDefaultsOnConnect")) }
    }
    /// 虚拟串口的波特率变化时自动同步给芯片
    @Published public var followVirtualPortBaud: Bool {
        didSet { defaults.set(followVirtualPortBaud, forKey: key("followVirtualPortBaud")) }
    }

    public var defaultSerialParameters: SerialParameters {
        SerialParameters(baudRate: defaultBaudRate, dataBits: defaultDataBits,
                         stopBits: defaultStopBits, parity: defaultParity)
    }

    // MARK: - 日志

    /// 默认保存日志: 每次连接自动开启日志文件
    @Published public var logEnabled: Bool {
        didSet { defaults.set(logEnabled, forKey: key("logEnabled")) }
    }
    @Published public var logDirectoryPath: String {
        didSet { defaults.set(logDirectoryPath, forKey: key("logDirectoryPath")) }
    }
    @Published public var logFormat: LogFormat {
        didSet { defaults.set(logFormat.rawValue, forKey: key("logFormat")) }
    }
    /// 按日期存储方式: 按会话 / 按日期分目录 / 按日期合并文件
    @Published public var logStorageMode: LogStorageMode {
        didSet { defaults.set(logStorageMode.rawValue, forKey: key("logStorageMode")) }
    }
    /// 文件名模板, 支持 {device} {name} {date} {time} {datetime} {seq}
    @Published public var logNameTemplate: String {
        didSet { defaults.set(logNameTemplate, forKey: key("logNameTemplate")) }
    }
    /// 自定义标识, 对应模板变量 {name}
    @Published public var logCustomName: String {
        didSet { defaults.set(logCustomName, forKey: key("logCustomName")) }
    }
    /// 是否启用日志切割快捷键 ⌘T (默认关闭)
    @Published public var logRotateShortcutEnabled: Bool {
        didSet { defaults.set(logRotateShortcutEnabled, forKey: key("logRotateShortcutEnabled")) }
    }
    /// 每行数据前加时间戳与方向
    @Published public var logTimestamps: Bool {
        didSet { defaults.set(logTimestamps, forKey: key("logTimestamps")) }
    }
    /// 是否把发送到串口方向的数据也写入日志
    @Published public var logSentData: Bool {
        didSet { defaults.set(logSentData, forKey: key("logSentData")) }
    }
    /// 纯文本日志中文兼容: GBK 设备输出自动转码为 UTF-8(HEX 类格式不受影响, 始终保留原始字节)
    @Published public var logGBKCompatible: Bool {
        didSet { defaults.set(logGBKCompatible, forKey: key("logGBKCompatible")) }
    }

    public var logDirectory: URL {
        URL(fileURLWithPath: (logDirectoryPath as NSString).expandingTildeInPath)
    }

    public static var defaultLogDirectory: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CH9140Logs").path
    }

    // MARK: - 虚拟串口

    @Published public var portName: String {
        didSet { defaults.set(portName, forKey: key("portName")) }
    }
    /// App 启动时自动创建虚拟串口
    @Published public var autoCreatePort: Bool {
        didSet { defaults.set(autoCreatePort, forKey: key("autoCreatePort")) }
    }

    // MARK: - 连接

    /// 意外断开后自动重连
    @Published public var autoReconnect: Bool {
        didSet { defaults.set(autoReconnect, forKey: key("autoReconnect")) }
    }
    /// 扫描时显示全部 BLE 设备(默认只显示 CH9140 服务 FFF0 的设备)
    @Published public var showAllDevices: Bool {
        didSet { defaults.set(showAllDevices, forKey: key("showAllDevices")) }
    }
    /// 终端输入区聚焦时强制英文输入法(离开后恢复), 默认开
    @Published public var terminalForceEnglish: Bool {
        didSet { defaults.set(terminalForceEnglish, forKey: key("terminalForceEnglish")) }
    }

    /// 最近连接设备(最多 5 个, 最新在前)
    @Published public private(set) var recentDevices: [RecentDevice] {
        didSet { persistRecentDevices() }
    }

    public func addRecentDevice(uuid: UUID, name: String, macAddress: String? = nil) {
        var list = recentDevices.filter { $0.uuid != uuid }
        // 本次未解析到 MAC 时保留历史缓存(同名芯片仍可区分)
        let mac = macAddress ?? recentDevices.first { $0.uuid == uuid }?.macAddress
        list.insert(RecentDevice(uuid: uuid, name: name, lastUsed: Date(), macAddress: mac), at: 0)
        recentDevices = Array(list.prefix(5))
    }

    /// 连接就绪后异步解析到 MAC 时回填(不改变排序与时间)
    public func updateRecentDeviceMAC(_ uuid: UUID, mac: String) {
        guard let i = recentDevices.firstIndex(where: { $0.uuid == uuid }),
              recentDevices[i].macAddress != mac else { return }
        recentDevices[i].macAddress = mac
    }

    public func removeRecentDevice(_ uuid: UUID) {
        recentDevices = recentDevices.filter { $0.uuid != uuid }
    }

    private func persistRecentDevices() {
        if let data = try? JSONEncoder().encode(recentDevices) {
            defaults.set(data, forKey: key("recentDevices"))
        }
    }

    // MARK: - 初始化

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        // 读取即校验: 损坏/越界的持久化值回退默认值, 不再 clamp 后直接下发芯片
        func uint32(_ k: String, _ def: UInt32, _ range: ClosedRange<UInt32>) -> UInt32 {
            guard d.object(forKey: "CH9140Bridge.\(k)") != nil else { return def }
            let v = UInt32(clamping: d.integer(forKey: "CH9140Bridge.\(k)"))
            return range.contains(v) ? v : def
        }
        func uint8(_ k: String, _ def: UInt8, _ range: ClosedRange<UInt8>) -> UInt8 {
            guard d.object(forKey: "CH9140Bridge.\(k)") != nil else { return def }
            let v = UInt8(clamping: d.integer(forKey: "CH9140Bridge.\(k)"))
            return range.contains(v) ? v : def
        }
        func bool(_ k: String, _ def: Bool) -> Bool {
            d.object(forKey: "CH9140Bridge.\(k)") != nil
                ? d.bool(forKey: "CH9140Bridge.\(k)") : def
        }

        // 交换机 Console 常用参数: 9600 8N1 无流控
        defaultBaudRate = uint32("defaultBaudRate", 9600, 300...1_000_000)
        defaultDataBits = uint8("defaultDataBits", 8, 5...8)
        defaultStopBits = uint8("defaultStopBits", 1, 1...2)
        defaultParity   = uint8("defaultParity", 0, 0...4)
        defaultFlowControl     = bool("defaultFlowControl", false)
        applyDefaultsOnConnect = bool("applyDefaultsOnConnect", true)
        followVirtualPortBaud  = bool("followVirtualPortBaud", true)

        logEnabled       = bool("logEnabled", true)
        logDirectoryPath = d.string(forKey: "CH9140Bridge.logDirectoryPath") ?? Self.defaultLogDirectory
        logFormat        = LogFormat(rawValue: d.string(forKey: "CH9140Bridge.logFormat") ?? "") ?? .ascii
        logStorageMode   = LogStorageMode(rawValue: d.string(forKey: "CH9140Bridge.logStorageMode") ?? "") ?? .dailyFolder
        logNameTemplate  = d.string(forKey: "CH9140Bridge.logNameTemplate") ?? SessionLogger.defaultTemplate
        logCustomName    = d.string(forKey: "CH9140Bridge.logCustomName") ?? ""
        logRotateShortcutEnabled = bool("logRotateShortcutEnabled", false)
        logTimestamps    = bool("logTimestamps", true)
        logSentData      = bool("logSentData", true)
        logGBKCompatible = bool("logGBKCompatible", true)

        portName       = d.string(forKey: "CH9140Bridge.portName") ?? "CH9140"
        autoCreatePort = bool("autoCreatePort", true)

        autoReconnect  = bool("autoReconnect", true)
        showAllDevices = bool("showAllDevices", false)
        terminalForceEnglish = bool("terminalForceEnglish", true)
        if let data = d.data(forKey: "CH9140Bridge.recentDevices"),
           let list = try? JSONDecoder().decode([RecentDevice].self, from: data) {
            recentDevices = list
        } else {
            recentDevices = []
        }
    }
}
