//
//  SessionLogger.swift
//  会话日志: 自动把串口收发数据保存到日志文件
//  双份保存: raw 原始日志(全量原始字节零过滤, 取证用, raw/ 子目录)
//            + clean 日志(GBK 转码 / ANSI·CR·退格过滤, 日常查看复制用)
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

/// clean 日志的 CR 回车符处理(仅纯文本格式)
public enum LogCRHandling: String, CaseIterable, Identifiable, Codable, Sendable {
    case keep  = "原样保留"
    case strip = "去除"
    case apply = "应用行内重绘"
    public var id: String { rawValue }
}

/// clean 日志的退格回显处理(仅纯文本格式)
public enum LogBSHandling: String, CaseIterable, Identifiable, Codable, Sendable {
    case keep  = "原样保留"
    case strip = "删除控制字节"
    case apply = "应用抹除"
    public var id: String { rawValue }
}

public final class SessionLogger: ObservableObject {

    /// 默认文件名模板
    public static let defaultTemplate = "CH9140_{device}_{datetime}"

    @Published public private(set) var currentFileURL: URL?
    /// raw 原始日志文件路径(未启用或无会话时为 nil)
    @Published public private(set) var rawFileURL: URL?
    /// 双文件合计已写字节
    @Published public private(set) var bytesWritten: UInt64 = 0

    private let queue = DispatchQueue(label: "cn.wch.CH9140Bridge.logger", qos: .utility)

    // ── clean 文件(过滤后的日常查看日志) ──
    private var handle: FileHandle?
    /// clean 纯文本的行装配状态(每方向一份)
    private var cleanLines: [LogDirection: CleanLine] = [:]
    /// 最近一次纯文本写入的选项(会话收尾冲刷开放行时用)
    private var lastCleanTimestamps = true
    private var lastCleanCR: LogCRHandling = .keep
    private var lastCleanBS: LogBSHandling = .keep

    // ── raw 原始文件(全量原始字节, 零转码零过滤) ──
    private var rawHandle: FileHandle?
    private var rawEnabled = false
    /// raw 流式写入的行首状态(行首插 [时间] [方向] 前缀)
    private var rawLineAtStart = true
    /// 当前开放物理行所属方向(仅 rawLineAtStart == false 时有意义)
    private var rawLineDirection: LogDirection? = nil

    // 当前会话上下文(用于切割与跨午夜自动切换)
    private var mode: LogStorageMode = .perSession
    private var directory: URL?
    private var deviceName: String?
    private var header = ""
    private var template = SessionLogger.defaultTemplate
    private var customName = ""
    private var openedDayStamp = ""
    /// 当前 clean 文件的最终基准名(含冲突后缀), raw 文件据此配对命名
    private var currentBaseName: String?
    /// 每个日期下的切割序号
    private var seqForDay: [String: Int] = [:]
    // 字节统计合帧: 每次写盘都跳主线程刷新 @Published 开销大,
    // 在串行队列上累加, 以 <=5Hz 的节奏统一发布
    private var pendingBytes: UInt64 = 0
    private var byteFlushScheduled = false

    /// clean 纯文本的每方向行装配状态
    private struct CleanLine {
        var buf = Data()      // 当前行内容(已过滤)
        var cursor = 0        // 写入位置; cursor < count 时为覆盖写(CR/退格的应用语义)
        var open = false      // 有未闭合内容
        var esc = Data()      // 未收完的 ANSI 序列(仅开启剥离时使用)
        var escActive = false
    }

    public init() {}

    deinit { try? handle?.close(); try? rawHandle?.close() }

    // MARK: - 会话生命周期

    /// 开启一个新的日志会话(连接建立时调用)
    public func openSession(directory: URL, deviceName: String?, header: String,
                            mode: LogStorageMode = .perSession,
                            template: String = SessionLogger.defaultTemplate,
                            customName: String = "",
                            rawEnabled: Bool = false) {
        queue.async {
            self.closeLocked()
            self.mode = mode
            self.directory = directory
            self.deviceName = deviceName
            self.header = header
            self.template = template
            self.customName = customName
            self.rawEnabled = rawEnabled
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

    /// 会话进行中开关 raw 原始日志(开=立即补开文件, 关=收尾关闭)
    public func setRawEnabled(_ on: Bool) {
        queue.async {
            guard on != self.rawEnabled else { return }
            self.rawEnabled = on
            if on {
                if self.handle != nil { self.openRawLocked(bannerNote: "会话进行中开启") }
            } else {
                self.closeRawLocked()
            }
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
        // 模板含 {seq} 则递增序号, 否则从 -2 起追加序号后缀
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
                       + "-\(suffix)"
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
            self.currentBaseName = name
            self.cleanLines.removeAll()

            var bannerText = """

            ============================================================
             CH9140 Bridge 会话日志
             设备: \(deviceName ?? "未知")
             开始时间: \(Self.lineStampFormatter.string(from: now))
             \(header)
             格式: 每行以 [时间] [方向] 开头(RX=芯片→主机, TX=主机→芯片);
                   行尾 "⏎" 表示该行无线上换行符, 因方向切换或会话收尾被强制断行。

            """
            if let note = bannerNote { bannerText += "     (\(note))\n" }
            bannerText += "============================================================\n\n"
            h.write(Data(bannerText.utf8))
            bumpBytes(UInt64(bannerText.utf8.count))
            DispatchQueue.main.async { self.currentFileURL = url }
            if self.rawEnabled { self.openRawLocked(bannerNote: bannerNote) }
        } catch {
            DispatchQueue.main.async { self.currentFileURL = nil }
        }
    }

    /// 在 queue 上调用: 打开与 clean 同基准名配对的 raw 原始日志
    /// 位置: <日志目录>/raw/[yyyy-MM-dd/]<clean基准名>.raw.log(按日期分目录模式加日期层)
    private func openRawLocked(bannerNote: String?) {
        guard let directory, let base = self.currentBaseName else { return }
        let day = Self.dayFormatter.string(from: Date())
        let rawRoot = directory.appendingPathComponent("raw", isDirectory: true)
        let folder = (mode == .dailyFolder)
            ? rawRoot.appendingPathComponent(day, isDirectory: true)
            : rawRoot
        var name = base + ".raw"
        var url = folder.appendingPathComponent(name + ".log")
        if mode != .dailyFile {
            var suffix = 2
            while FileManager.default.fileExists(atPath: url.path) {
                name = base + ".raw-\(suffix)"
                url = folder.appendingPathComponent(name + ".log")
                suffix += 1
            }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileExists = FileManager.default.fileExists(atPath: url.path)
            if !fileExists { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let h = try FileHandle(forWritingTo: url)
            if fileExists { h.seekToEndOfFile() }   // 追加模式续写
            self.rawHandle = h
            self.rawLineAtStart = true
            self.rawLineDirection = nil
            var bannerText = """

            ============================================================
             CH9140 Bridge 原始日志(raw)
             设备: \(deviceName ?? "未知")
             开始时间: \(Self.lineStampFormatter.string(from: Date()))
             \(header)
             格式: 线上原始字节流, 未做转码与过滤(含 CR/退格/ANSI 转义;
                   中文设备输出通常为 GBK 编码, 请用支持 GBK/HEX 的查看器);
                   每行以 [时间] [方向] 开头, 行尾 "⏎" 为强制断行标记。

            """
            if let note = bannerNote { bannerText += "     (\(note))\n" }
            bannerText += "============================================================\n\n"
            h.write(Data(bannerText.utf8))
            bumpBytes(UInt64(bannerText.utf8.count))
            DispatchQueue.main.async { self.rawFileURL = url }
        } catch {
            DispatchQueue.main.async { self.rawFileURL = nil }
        }
    }

    private func closeLocked() {
        // clean 文件收尾
        if let h = handle {
            // 转码暂存的半个字符等不到下文: 以 U+FFFD 标记进入对应方向的行缓冲, 不静默丢字节
            for (d, carry) in self.textCarry where !carry.isEmpty {
                var st = self.cleanLines[d] ?? CleanLine()
                self.putCleanByte(0xEF, into: &st)   // U+FFFD = EF BF BD
                self.putCleanByte(0xBF, into: &st)
                self.putCleanByte(0xBD, into: &st)
                self.cleanLines[d] = st
            }
            self.textCarry.removeAll()
            // 冲刷未闭合行: 时间戳模式补 ⏎ 标记并断行; 无时间戳模式保持字节精确(不补换行)
            for d in [LogDirection.rx, .tx] {
                if let st = self.cleanLines[d], st.open {
                    h.write(self.renderCleanLine(st, direction: d,
                                                 timestamps: self.lastCleanTimestamps,
                                                 cr: self.lastCleanCR, bs: self.lastCleanBS,
                                                 marker: self.lastCleanTimestamps,
                                                 newline: self.lastCleanTimestamps))
                }
            }
            self.cleanLines.removeAll()
            let footer = "\n----- 会话结束 \(Self.lineStampFormatter.string(from: Date())) -----\n"
            h.write(Data(footer.utf8))
            try? h.close()
        }
        handle = nil
        self.currentBaseName = nil
        self.closeRawLocked()
        DispatchQueue.main.async { self.currentFileURL = nil }
    }

    /// raw 文件收尾(会话结束/手动关闭 raw 时调用)
    private func closeRawLocked() {
        if let h = rawHandle {
            if !rawLineAtStart {
                h.write(Data(" ⏎\n".utf8))
                rawLineAtStart = true
                rawLineDirection = nil
            }
            let footer = "\n----- 会话结束 \(Self.lineStampFormatter.string(from: Date())) -----\n"
            h.write(Data(footer.utf8))
            try? h.close()
        }
        rawHandle = nil
        DispatchQueue.main.async { self.rawFileURL = nil }
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

    /// 写日志: raw 文件零处理直写; clean 文件按格式与过滤选项写入
    /// - Parameters:
    ///   - timestamps/decodeGBK/stripANSI/cr/bs: clean 过滤选项(默认全部原样, 即旧版行为)
    ///   - includeClean: false 时仅写 raw(TX 开关关闭但 raw 开启时使用, raw 永远全量)
    public func log(_ data: Data, direction: LogDirection, format: LogFormat, timestamps: Bool,
                    decodeGBK: Bool = false, stripANSI: Bool = false,
                    cr: LogCRHandling = .keep, bs: LogBSHandling = .keep,
                    includeClean: Bool = true) {
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
            // raw 原始日志: 线上字节零处理(不过滤/不转码), 流式行首前缀
            if let rh = self.rawHandle {
                self.writeRawLocked(data, direction: direction, to: rh)
            }
            guard includeClean, let h = self.handle else { return }
            switch format {
            case .ascii:
                self.writeCleanAsciiLocked(data, direction: direction, to: h,
                                           timestamps: timestamps, decodeGBK: decodeGBK,
                                           stripANSI: stripANSI, cr: cr, bs: bs)
            case .hex, .both:
                var out = Data()
                if timestamps {
                    out.append(Data("[\(Self.lineStampFormatter.string(from: Date()))] [\(direction.rawValue)] ".utf8))
                }
                if format == .hex {
                    out.append(Data(HexUtil.hexString(data).utf8))
                    out.append(0x0A)
                } else {
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
    }

    /// raw 原始日志: 流式直写, 行首插 [时间] [方向] 前缀, 方向切换处强制断行补 ⏎。
    /// 字节本身零处理 —— CR/退格/ANSI/GBK 全部原样保留(不变式见文件 banner 图例)
    private func writeRawLocked(_ data: Data, direction: LogDirection, to h: FileHandle) {
        var out = Data()
        let prefix = Data("[\(Self.lineStampFormatter.string(from: Date()))] [\(direction.rawValue)] ".utf8)
        var rest = data[...]
        while !rest.isEmpty {
            if !self.rawLineAtStart, let lineDir = self.rawLineDirection, lineDir != direction {
                out.append(Data(" ⏎\n".utf8))      // 方向切换: 强制闭合上一行
                self.rawLineAtStart = true
                self.rawLineDirection = nil
            }
            if self.rawLineAtStart {
                out.append(prefix)
                self.rawLineAtStart = false
                self.rawLineDirection = direction
            }
            if let nl = rest.firstIndex(of: 0x0A) {
                out.append(rest[...nl])
                rest = rest[rest.index(after: nl)...]
                self.rawLineAtStart = true
                self.rawLineDirection = nil
            } else {
                out.append(rest)
                rest = rest[rest.endIndex...]
            }
        }
        do {
            try h.write(contentsOf: out)
            self.bumpBytes(UInt64(out.count))
        } catch {
            // 磁盘写失败时静默丢弃, 避免影响数据通路
        }
    }

    /// clean 纯文本: GBK 转码 → ANSI 剥离 → 行装配(CR/退格按策略) → 成行写盘
    /// 时间戳开: 每行带 [时间] [方向] 前缀, 方向切换强制断行补 ⏎(单行单方向);
    /// 时间戳关: 不带前缀也不断行, 与旧版字节语义一致(仅多了可选过滤)
    private func writeCleanAsciiLocked(_ data0: Data, direction: LogDirection, to h: FileHandle,
                                       timestamps: Bool, decodeGBK: Bool, stripANSI: Bool,
                                       cr: LogCRHandling, bs: LogBSHandling) {
        self.lastCleanTimestamps = timestamps
        self.lastCleanCR = cr
        self.lastCleanBS = bs
        // 0x0A 不出现在 UTF-8/GBK 多字节字符与 ANSI 序列内, 转码/剥离后再分行是安全的
        var data = decodeGBK ? self.decodeTextChunk(data0, direction: direction) : data0
        var st = self.cleanLines[direction] ?? CleanLine()
        if stripANSI {
            data = self.stripANSILocked(data, st: &st)
        }
        guard !data.isEmpty else {                 // 半字/半个转义序列全部进暂存
            self.cleanLines[direction] = st
            return
        }
        var out = Data()
        if timestamps {
            // 方向切换: 另一方向的开放行强制收尾, 保证单行单方向
            let other: LogDirection = (direction == .rx) ? .tx : .rx
            if let ost = self.cleanLines[other], ost.open {
                out.append(self.renderCleanLine(ost, direction: other, timestamps: true,
                                                cr: cr, bs: bs, marker: true, newline: true))
                var fresh = ost                      // 保留 ANSI 暂存(流状态), 只清行缓冲
                fresh.buf.removeAll(); fresh.cursor = 0; fresh.open = false
                self.cleanLines[other] = fresh
            }
        }
        for b in data {
            switch b {
            case 0x0A:   // LF: 成行吐出
                out.append(self.renderCleanLine(st, direction: direction, timestamps: timestamps,
                                                cr: cr, bs: bs, marker: false, newline: true))
                st.buf.removeAll(); st.cursor = 0; st.open = false
            case 0x0D:   // CR 回车
                switch cr {
                case .keep:  self.putCleanByte(b, into: &st)
                case .strip: break
                case .apply: st.cursor = 0          // 回到行首, 后续覆盖写
                }
            case 0x08, 0x7F:   // 退格 / DEL
                switch bs {
                case .keep:  self.putCleanByte(b, into: &st)
                case .strip: break
                case .apply: st.cursor = max(0, st.cursor - 1)   // 抹除前一字符(配合终端回显的 BS+空格+BS)
                }
            default:
                self.putCleanByte(b, into: &st)
            }
            // 超长行保护: 设备久不发 LF 时防止内存堆积
            if st.buf.count > 65536 {
                out.append(self.renderCleanLine(st, direction: direction, timestamps: timestamps,
                                                cr: cr, bs: bs, marker: timestamps, newline: true))
                st.buf.removeAll(); st.cursor = 0; st.open = false
            }
        }
        self.cleanLines[direction] = st
        guard !out.isEmpty else { return }
        do {
            try h.write(contentsOf: out)
            self.bumpBytes(UInt64(out.count))
        } catch {
            // 磁盘写失败时静默丢弃, 避免影响数据通路
        }
    }

    /// 写一个字节进行缓冲: 追加或按 cursor 覆盖(CR/退格的应用语义)
    private func putCleanByte(_ b: UInt8, into st: inout CleanLine) {
        if st.cursor == st.buf.count { st.buf.append(b) }
        else { st.buf[st.cursor] = b }
        st.cursor += 1
        st.open = true
    }

    /// 渲染一行: [时间] [方向] 前缀(可选) + 内容 + ⏎ 强制断行标记(可选) + 换行(可选)
    private func renderCleanLine(_ st: CleanLine, direction: LogDirection, timestamps: Bool,
                                 cr: LogCRHandling, bs: LogBSHandling,
                                 marker: Bool, newline: Bool) -> Data {
        var content = st.buf
        // 应用类模式会在行尾留下覆盖空格(如 "退格+空格+退格" 回显), 修整掉
        if cr == .apply || bs == .apply {
            while let last = content.last, last == 0x20 || last == 0x09 { content.removeLast() }
        }
        var out = Data()
        if timestamps {
            out.append(Data("[\(Self.lineStampFormatter.string(from: Date()))] [\(direction.rawValue)] ".utf8))
        }
        out.append(content)
        if marker { out.append(Data(" ⏎".utf8)) }
        if newline { out.append(0x0A) }
        return out
    }

    /// 剥离 ANSI 转义序列; 未收完的序列留在行状态里等下一块(跨 BLE 包)
    private func stripANSILocked(_ data: Data, st: inout CleanLine) -> Data {
        var out = Data()
        for b in data {
            if st.escActive {
                st.esc.append(b)
                if Self.ansiSequenceComplete(st.esc) {
                    st.esc.removeAll(); st.escActive = false      // 整段丢弃
                } else if st.esc.count > 32 {                     // 畸形长序列防呆: 放弃剥离, 丢弃
                    st.esc.removeAll(); st.escActive = false
                }
                continue
            }
            if b == 0x1B { st.escActive = true; st.esc = Data([0x1B]); continue }
            out.append(b)
        }
        return out
    }

    /// 判断转义序列是否收完: CSI = ESC[ …0x40-0x7E; OSC = ESC] …BEL 或 ST; 字符集等双/三字节序列
    static func ansiSequenceComplete(_ e: Data) -> Bool {
        guard e.count >= 2 else { return false }
        let second = e[e.index(after: e.startIndex)]
        switch second {
        case 0x5B:  // CSI "["
            return e.count >= 3 && (0x40...0x7E).contains(e.last!)
        case 0x5D:  // OSC "]": BEL 或 ESC \ 结束
            if e.last == 0x07 { return true }
            return e.count >= 3 && e[e.index(e.endIndex, offsetBy: -2)] == 0x1B && e.last == 0x5C
        case 0x28...0x2F:  // ESC ( X 之类的字符集序列
            return e.count >= 3
        default:           // 其余双字节序列(ESC c / ESC = 等)
            return true
        }
    }

    // MARK: - 中文兼容(GBK → UTF-8 增量转码)

    /// GB18030(GBK 超集): 华为/H3C 等国产设备控制台常用编码
    static let gbkEncoding = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// 每个方向的半字暂存(跨 BLE 包的不完整 UTF-8 序列 / GBK 孤立前导字节, 至多 3 字节)
    private var textCarry: [LogDirection: [UInt8]] = [:]

    /// 在 queue 上调用: 把一块串口字节流转码为 UTF-8
    /// 判定: 严格 UTF-8 优先(现代 UTF-8 设备原样通过); 失败按 GBK 解码; 再失败宽松解码(非法字节 → U+FFFD)。
    /// 已知取舍: 与 UTF-8 双字节序列同形的 GBK 字(如「猫」= C3 A8 = UTF-8 è)按 UTF-8 处理。
    private func decodeTextChunk(_ data: Data, direction: LogDirection) -> Data {
        var buf = Data()
        if let carry = textCarry[direction], !carry.isEmpty {
            buf.append(contentsOf: carry)
            textCarry[direction] = nil
        }
        buf.append(data)
        guard buf.contains(where: { $0 >= 0x80 }) else { return buf }   // 纯 ASCII 直通

        // 1) 严格 UTF-8(整块)
        if let str = String(bytes: buf, encoding: .utf8) { return Data(str.utf8) }

        // 2) 结尾是不完整 UTF-8 序列(前导字节 + 至多 3 个 continuation, 或孤立前导):
        //    暂存尾巴等下一块拼接, 头部若能严格解码则按 UTF-8 输出
        var cont = 0
        var idx = buf.count
        while idx > 0, cont < 3, (buf[idx - 1] & 0xC0) == 0x80 { cont += 1; idx -= 1 }
        var tailStart: Int?      // 不完整序列的起点
        if cont == 0, let last = buf.last, last >= 0xC2, last <= 0xF4 {
            tailStart = buf.count - 1                            // 孤立前导(序列刚开始)
        } else if idx > 0 {
            let lead = buf[idx - 1]
            let expect = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC2 ? 2 : 0
            if expect > cont + 1 { tailStart = idx - 1 }         // continuation 不够, 序列未完整
        }
        if let split = tailStart, let str = String(bytes: buf[..<split], encoding: .utf8) {
            textCarry[direction] = Array(buf[split...])
            return Data(str.utf8)
        }

        // 3) GBK: 整块解码; 失败且末尾是孤立前导字节则暂存半字再试
        if let str = String(bytes: buf, encoding: Self.gbkEncoding) { return Data(str.utf8) }
        if let last = buf.last, (0x81...0xFE).contains(last),
           let str = String(bytes: buf.dropLast(), encoding: Self.gbkEncoding) {
            textCarry[direction] = [last]
            return Data(str.utf8)
        }

        // 4) 兜底: 宽松 UTF-8(非法字节段 → U+FFFD)
        return Data(String(decoding: buf, as: UTF8.self).utf8)
    }

    // MARK: - 文件名模板

    /// 净化文件名片段(保留中英文数字 _ -)
    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "[^A-Za-z0-9\\u4e00-\\u9fa5_-]", with: "-",
                                  options: .regularExpression)
    }

    /// 解析文件名模板
    /// 支持变量: {device} 设备名, {name} 自定义标识, {date} 日期, {time} 时间,
    ///           {datetime} 日期时间, {seq} 当日切割序号
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
        t = t.replacingOccurrences(of: "{seq}", with: String(seq))
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
