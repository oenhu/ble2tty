//
//  SessionLogger.swift
//  会话日志: 自动把串口收发数据保存到日志文件
//  支持文件名模板自定义 / 手动切割 / 按日期存储 / 跨午夜自动切换
//

import Foundation

public enum LogFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case ascii = "纯文本"
    case hex   = "十六进制"
    case both  = "HEX + 文本"
    public var id: String { rawValue }
}

/// 日志按日期的存储方式
public enum LogStorageMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 每次连接一个文件: <目录>/<文件名>.log
    case perSession  = "按会话存储"
    /// 按日期分目录: <目录>/yyyy-MM-dd/<文件名>.log
    case dailyFolder = "按日期分目录"
    /// 追加模式: 同名文件持续追加(搭配含 {date} 的模板即为每天一个文件)
    case dailyFile   = "按日期合并文件"
    public var id: String { rawValue }
}

public enum LogDirection: String, Sendable {
    case rx = "RX"   // 芯片 -> 主机
    case tx = "TX"   // 主机 -> 芯片
}

public final class SessionLogger: ObservableObject {

    /// 默认文件名模板
    public static let defaultTemplate = "CH9140_{device}_{datetime}"

    @Published public private(set) var currentFileURL: URL?
    @Published public private(set) var bytesWritten: UInt64 = 0

    private let queue = DispatchQueue(label: "cn.wch.CH9140Bridge.logger", qos: .utility)
    private var handle: FileHandle?
    /// 纯文本日志模式下, RX/TX 流各自是否处于行首(只在行首插入时间戳前缀, 保证字节精确)
    private var rxAtLineStart = true
    private var txAtLineStart = true

    // 当前会话上下文(用于切割与跨午夜自动切换)
    private var mode: LogStorageMode = .perSession
    private var directory: URL?
    private var deviceName: String?
    private var header = ""
    private var template = SessionLogger.defaultTemplate
    private var customName = ""
    private var openedDayStamp = ""
    /// 每个日期下的切割序号
    private var seqForDay: [String: Int] = [:]
    // 字节统计合帧: 每次写盘都跳主线程刷新 @Published 开销大,
    // 在串行队列上累加, 以 <=5Hz 的节奏统一发布
    private var pendingBytes: UInt64 = 0
    private var byteFlushScheduled = false

    public init() {}

    deinit { try? handle?.close() }

    // MARK: - 会话生命周期

    /// 开启一个新的日志会话(连接建立时调用)
    public func openSession(directory: URL, deviceName: String?, header: String,
                            mode: LogStorageMode = .perSession,
                            template: String = SessionLogger.defaultTemplate,
                            customName: String = "") {
        queue.async {
            self.closeLocked()
            self.mode = mode
            self.directory = directory
            self.deviceName = deviceName
            self.header = header
            self.template = template
            self.customName = customName
            self.openFileLocked(bannerNote: nil)
        }
    }

    /// 结束当前会话(断开连接时调用)
    public func closeSession() {
        queue.async {
            self.closeLocked()
            self.directory = nil
            self.deviceName = nil
        }
    }

    /// 会话进行中更新命名规则(用户在设置里改了模板/标识, 下次切割生效)
    public func updateNaming(template: String, customName: String) {
        queue.async {
            self.template = template
            self.customName = customName
        }
    }

    /// 手动切割: 收尾当前文件, 立即按命名规则开启新文件
    /// - Parameter completion: 主线程回调新文件 URL; 无进行中会话时回调 nil
    public func rotateSession(completion: ((URL?) -> Void)? = nil) {
        queue.async {
            guard self.handle != nil, self.directory != nil else {
                DispatchQueue.main.async { completion?(nil) }
                return
            }
            self.closeLocked()
            let day = Self.dayFormatter.string(from: Date())
            self.seqForDay[day] = (self.seqForDay[day] ?? 1) + 1
            self.openFileLocked(bannerNote: "手动切割, 序号 \(self.seqForDay[day] ?? 1)")
            DispatchQueue.main.async { completion?(self.currentFileURL) }
        }
    }

    // MARK: - 文件打开

    /// 在 queue 上调用: 按 mode + 模板计算文件路径并打开
    private func openFileLocked(bannerNote: String?) {
        guard let directory else { return }
        let now = Date()
        let day = Self.dayFormatter.string(from: now)
        let degradeTime = (mode == .dailyFile)

        // 文件所在目录(按日期分目录模式加一层日期子目录)
        let folder: URL = (mode == .dailyFolder)
            ? directory.appendingPathComponent(day, isDirectory: true)
            : directory

        let seq = seqForDay[day] ?? 1
        var name = Self.resolveTemplate(template, deviceName: deviceName ?? "CH9140",
                                        customName: customName, date: now,
                                        seq: seq, degradeTime: degradeTime)
        var url = folder.appendingPathComponent(name + ".log")

        // 非追加模式下保证不覆盖已有文件:
        // 模板含 {seq} 则递增序号, 否则从 -02 起追加序号后缀
        if mode != .dailyFile {
            if template.contains("{seq}") {
                var n = seq
                while FileManager.default.fileExists(atPath: url.path) {
                    n += 1
                    name = Self.resolveTemplate(template, deviceName: deviceName ?? "CH9140",
                                                customName: customName, date: now,
                                                seq: n, degradeTime: degradeTime)
                    url = folder.appendingPathComponent(name + ".log")
                }
                seqForDay[day] = n
            } else {
                var suffix = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    name = Self.resolveTemplate(template, deviceName: deviceName ?? "CH9140",
                                                customName: customName, date: now,
                                                seq: seq, degradeTime: degradeTime)
                       + String(format: "-%02d", suffix)
                    url = folder.appendingPathComponent(name + ".log")
                    suffix += 1
                }
            }
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileExists = FileManager.default.fileExists(atPath: url.path)
            if !fileExists {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: url)
            if fileExists { h.seekToEndOfFile() }   // 追加模式续写
            self.handle = h
            self.openedDayStamp = day
            self.rxAtLineStart = true
            self.txAtLineStart = true

            var bannerText = """

            ============================================================
             CH9140 Bridge 会话日志
             设备: \(deviceName ?? "未知")
             开始时间: \(Self.lineStampFormatter.string(from: now))
             \(header)
            """
            if let note = bannerNote { bannerText += "     (\(note))\n" }
            bannerText += "============================================================\n\n"
            h.write(Data(bannerText.utf8))
            bumpBytes(UInt64(bannerText.utf8.count))
            DispatchQueue.main.async { self.currentFileURL = url }
        } catch {
            DispatchQueue.main.async { self.currentFileURL = nil }
        }
    }

    private func closeLocked() {
        if let h = handle {
            let footer = "\n----- 会话结束 \(Self.lineStampFormatter.string(from: Date())) -----\n"
            h.write(Data(footer.utf8))
            try? h.close()
        }
        handle = nil
        DispatchQueue.main.async { self.currentFileURL = nil }
    }

    /// 在 queue 上调用: 累计已写字节, 以 <=5Hz 的节奏发布到主线程
    private func bumpBytes(_ n: UInt64) {
        pendingBytes &+= n
        guard !byteFlushScheduled else { return }
        byteFlushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let b = self.pendingBytes
            self.pendingBytes = 0
            self.byteFlushScheduled = false
            DispatchQueue.main.async { self.bytesWritten &+= b }
        }
    }

    // MARK: - 写入

    public func log(_ data: Data, direction: LogDirection, format: LogFormat, timestamps: Bool) {
        guard !data.isEmpty else { return }
        queue.async {
            // 按日期模式跨午夜自动切换到新文件
            if self.mode != .perSession, self.handle != nil {
                let today = Self.dayFormatter.string(from: Date())
                if today != self.openedDayStamp {
                    self.closeLocked()
                    self.openFileLocked(bannerNote: "日期切换, 自动创建")
                }
            }
            guard let h = self.handle else { return }
            var out = Data()
            switch format {
            case .ascii:
                // 纯文本: 字节精确写入, 不追加额外换行; 时间戳只出现在行首
                if timestamps {
                    var atLineStart = (direction == .rx) ? self.rxAtLineStart : self.txAtLineStart
                    let prefix = Data("[\(Self.lineStampFormatter.string(from: Date()))] [\(direction.rawValue)] ".utf8)
                    var rest = data[...]
                    while !rest.isEmpty {
                        if atLineStart {
                            out.append(prefix)
                            atLineStart = false
                        }
                        if let nl = rest.firstIndex(of: 0x0A) {
                            out.append(rest[...nl])
                            rest = rest[rest.index(after: nl)...]
                            atLineStart = true
                        } else {
                            out.append(rest)
                            rest = rest[rest.endIndex...]
                        }
                    }
                    if direction == .rx { self.rxAtLineStart = atLineStart }
                    else { self.txAtLineStart = atLineStart }
                } else {
                    out.append(data)
                }
            case .hex:
                if timestamps {
                    out.append(Data("[\(Self.lineStampFormatter.string(from: Date()))] [\(direction.rawValue)] ".utf8))
                }
                out.append(Data(HexUtil.hexString(data).utf8))
                out.append(0x0A)
            case .both:
                if timestamps {
                    out.append(Data("[\(Self.lineStampFormatter.string(from: Date()))] [\(direction.rawValue)] ".utf8))
                }
                out.append(Data("\(HexUtil.hexString(data))  | \(HexUtil.printableASCII(data))\n".utf8))
            }
            do {
                try h.write(contentsOf: out)
                self.bumpBytes(UInt64(out.count))
            } catch {
                // 磁盘写失败时静默丢弃, 避免影响数据通路
            }
        }
    }

    // MARK: - 文件名模板

    /// 净化文件名片段(保留中英文数字 _ -)
    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "[^A-Za-z0-9\\u4e00-\\u9fa5_-]", with: "-",
                                  options: .regularExpression)
    }

    /// 解析文件名模板
    /// 支持变量: {device} 设备名, {name} 自定义标识, {date} 日期, {time} 时间,
    ///           {datetime} 日期时间, {seq} 当日切割序号(两位)
    /// - Parameter degradeTime: 按日期合并模式下 {datetime}/{time} 退化为 {date}/空
    public static func resolveTemplate(_ template: String, deviceName: String,
                                       customName: String, date: Date,
                                       seq: Int, degradeTime: Bool = false) -> String {
        let day = dayFormatter.string(from: date)
        var t = template
        t = t.replacingOccurrences(of: "{device}", with: sanitize(deviceName))
        t = t.replacingOccurrences(of: "{name}", with: sanitize(customName))
        t = t.replacingOccurrences(of: "{date}", with: day)
        if degradeTime {
            t = t.replacingOccurrences(of: "{datetime}", with: day)
            t = t.replacingOccurrences(of: "{time}", with: "")
        } else {
            t = t.replacingOccurrences(of: "{datetime}", with: fileStampFormatter.string(from: date))
            t = t.replacingOccurrences(of: "{time}", with: timeStampFormatter.string(from: date))
        }
        t = t.replacingOccurrences(of: "{seq}", with: String(format: "%02d", seq))
        // 非法文件名字符 -> -
        t = t.replacingOccurrences(of: #"[/:*?"<>|\\]"#, with: "-", options: .regularExpression)
        // 折叠连续分隔符(变量为空时避免 "a__b" / "a-_-b")
        t = t.replacingOccurrences(of: "[_\\- ]{2,}", with: "_", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        if t.isEmpty { t = "CH9140" }
        return t
    }

    /// 按当前时间与设置计算示例完整路径(设置面板预览用)
    public static func examplePath(directory: String, deviceName: String, customName: String,
                                   template: String, mode: LogStorageMode, date: Date = Date()) -> String {
        let dir = (directory as NSString).expandingTildeInPath
        let day = dayFormatter.string(from: date)
        let name = resolveTemplate(template, deviceName: deviceName, customName: customName,
                                   date: date, seq: 1, degradeTime: mode == .dailyFile)
        switch mode {
        case .dailyFolder: return "\(dir)/\(day)/\(name).log"
        default:           return "\(dir)/\(name).log"
        }
    }

    // MARK: - 格式化器

    public static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    static let timeStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f
    }()

    static let lineStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
