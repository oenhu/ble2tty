//
//  VirtualSerialPort.swift
//  基于伪终端(PTY)的虚拟串口
//
//  macOS 上无需内核扩展即可创建虚拟串口: openpty() 产生一对主/从设备,
//  从设备路径为 /dev/ttysNNN。我们在用户目录创建 cu.* 符号链接指向从设备,
//  任何串口工具(screen / minicom / CoolTerm / PuTTY)都可以像真实串口一样打开它。
//
//  数据流向:
//   - 串口工具写入从设备 -> 主 fd 可读 -> onDataFromPort -> 经 BLE 发给 CH9140
//   - CH9140 经 BLE 上报 -> writeToPort -> 主 fd 写入 -> 串口工具从从设备读到
//   - 串口工具用 tcsetattr 修改波特率 -> 定时巡检 termios -> onBaudChange -> 同步给芯片
//

import Foundation
import Darwin

public final class VirtualSerialPort: ObservableObject {

    public enum PortError: Error, LocalizedError {
        case openptyFailed
        case symlinkFailed(String)
        public var errorDescription: String? {
            switch self {
            case .openptyFailed: return "openpty() 调用失败"
            case .symlinkFailed(let m): return "创建符号链接失败: \(m)"
            }
        }
    }

    // MARK: 发布状态
    @Published public private(set) var isOpen = false
    @Published public private(set) var slavePath: String = ""      // /dev/ttysNNN
    @Published public private(set) var linkPath: String = ""       // ~/Library/Application Support/.../cu.CH9140
    @Published public private(set) var compatLinkPath: String = "" // ~/.ch9140/cu.CH9140 (无空格, 兼容 minicom 等工具)
    @Published public private(set) var clientConnected = false     // 有程序打开了从设备(启发式)
    @Published public private(set) var currentBaudRate: UInt32 = 9600
    @Published public private(set) var bytesFromClient: UInt64 = 0
    @Published public private(set) var bytesToClient: UInt64 = 0
    @Published public private(set) var droppedBytes: UInt64 = 0    // 无客户端打开时丢弃的字节

    // MARK: 回调(后台线程触发, 请自行切线程)
    public var onDataFromPort: ((Data) -> Void)?
    public var onBaudChange: ((SerialParameters) -> Void)?
    public var onLog: ((String) -> Void)?

    // MARK: 内部
    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var worker: Thread?
    private var running = false
    private let stateLock = NSLock()
    /// pollLoop 退出信号: close() 用它等待线程结束, 替代此前的忙等轮询
    private let pollExitSemaphore = DispatchSemaphore(value: 0)
    private var inboundBuffer = Data()      // 待写入从设备的数据(BLE -> 串口工具)
    /// inboundBuffer 专用锁: 写入发生在 writeQueue, 而 pollLoop 也会读取,
    /// 之前两侧锁保护不一致存在数据竞争, 现统一由该锁保护
    private let inboundLock = NSLock()
    // 字节统计合帧: 高频读写下逐块跳主线程刷新 @Published 开销大,
    // 任意线程先累加, 再以 <=10Hz 的节奏统一发布
    private let counterLock = NSLock()
    private var pendingFromClient: UInt64 = 0
    private var pendingToClient: UInt64 = 0
    private var pendingDropped: UInt64 = 0
    private var counterFlushScheduled = false
    private var lastTermios: termios?
    private let writeQueue = DispatchQueue(label: "cn.wch.CH9140Bridge.pty.write", qos: .userInitiated)

    /// running 的加锁访问: close()(任意线程)写, pollLoop 线程读
    private var isRunning: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return running }
        set { stateLock.lock(); running = newValue; stateLock.unlock() }
    }

    /// 符号链接存放目录
    public static var defaultLinkDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CH9140Bridge", isDirectory: true)
    }

    /// 无空格的兼容符号链接目录(minicom 等工具会把设备路径按空格分词)
    public static var compatLinkDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ch9140", isDirectory: true)
    }

    public init() {}

    deinit { close() }

    // MARK: - 打开 / 关闭

    /// 打开虚拟串口并在指定目录创建 cu.<name> 符号链接
    @discardableResult
    public func open(name: String = "CH9140") throws -> String {
        stateLock.lock()
        if isOpen { stateLock.unlock(); return linkPath }
        stateLock.unlock()

        // 净化名称: 防止路径分隔符把符号链接创建到目录之外
        let portName = Self.sanitizedName(name)

        var master: Int32 = -1
        var slave: Int32 = -1
        var nameBuf = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &nameBuf, nil, nil) == 0 else {
            throw PortError.openptyFailed
        }
        // 与 close()/pollLoop 的读写保持同一把锁(此前 open 无锁赋值是不对称的)
        stateLock.lock()
        masterFD = master
        slaveFD = slave
        stateLock.unlock()

        // 主 fd 非阻塞
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        // 给从设备一个合理的初始行规: 9600 8N1 RAW
        var tio = termios()
        tcgetattr(slave, &tio)
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetispeed(&tio, speed_t(B9600))
        cfsetospeed(&tio, speed_t(B9600))
        tcsetattr(slave, TCSANOW, &tio)
        // 与 pollLoop 的 checkTermios 读写保持同一把锁
        stateLock.lock()
        lastTermios = tio
        stateLock.unlock()

        let path = String(cString: nameBuf)

        // 创建符号链接目录与链接
        let dir = Self.defaultLinkDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("cu.\(portName)")
        try? FileManager.default.removeItem(at: link)
        do {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: path)
        } catch {
            Darwin.close(master); Darwin.close(slave)
            stateLock.lock()
            masterFD = -1; slaveFD = -1
            stateLock.unlock()
            throw PortError.symlinkFailed(error.localizedDescription)
        }

        // 额外的无空格兼容链接, 供 minicom 等按空格分词设备路径的工具使用
        let compatDir = Self.compatLinkDirectory
        let compatLink = compatDir.appendingPathComponent("cu.\(portName)")
        try? FileManager.default.createDirectory(at: compatDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: compatLink)
        try? FileManager.default.createSymbolicLink(atPath: compatLink.path, withDestinationPath: path)

        stateLock.lock()
        isOpen = true
        slavePath = path
        linkPath = link.path
        compatLinkPath = compatLink.path
        droppedBytes = 0
        stateLock.unlock()

        let thread = Thread { [weak self] in self?.pollLoop() }
        thread.name = "CH9140Bridge.PTYPoll"
        thread.qualityOfService = .userInitiated
        stateLock.lock()
        running = true
        worker = thread
        stateLock.unlock()
        thread.start()

        emitLog("虚拟串口已创建: \(link.path) -> \(path)")
        return link.path
    }

    /// 净化串口名: 过滤路径分隔符, 空名回退默认值
    public static func sanitizedName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\u{0}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "CH9140" : cleaned
    }

    public func close() {
        stateLock.lock()
        let w = worker
        stateLock.unlock()
        isRunning = false
        w?.cancel()
        // 等待轮询线程退出, 避免关闭 fd 后仍在使用;
        // poll() 最多阻塞 200ms, 用信号量高效唤醒, 不再忙等轮询占用调用线程
        if let w, w.isExecuting {
            _ = pollExitSemaphore.wait(timeout: .now() + 0.5)
        }
        stateLock.lock()
        worker = nil
        let m = masterFD, s = slaveFD
        masterFD = -1; slaveFD = -1
        let link = linkPath
        let compat = compatLinkPath
        isOpen = false
        slavePath = ""
        linkPath = ""
        compatLinkPath = ""
        clientConnected = false
        inboundLock.lock()
        inboundBuffer.removeAll()
        inboundLock.unlock()
        stateLock.unlock()
        if m >= 0 { Darwin.close(m) }
        if s >= 0 { Darwin.close(s) }
        if !link.isEmpty { try? FileManager.default.removeItem(atPath: link) }
        if !compat.isEmpty { try? FileManager.default.removeItem(atPath: compat) }
        emitLog("虚拟串口已关闭")
    }

    // MARK: - 写向从设备 (BLE -> 串口工具)

    public func writeToPort(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let fd = self.masterFD
            let open = self.isOpen
            self.stateLock.unlock()
            guard open, fd >= 0 else { return }

            self.inboundLock.lock()
            self.inboundBuffer.append(data)
            // 最多缓存 256KB, 超出则丢弃最旧数据(防止客户端不读导致内存膨胀)
            let maxBuffer = 256 * 1024
            var overflow = 0
            if self.inboundBuffer.count > maxBuffer {
                overflow = self.inboundBuffer.count - maxBuffer
                self.inboundBuffer.removeFirst(overflow)
            }
            self.inboundLock.unlock()
            if overflow > 0 { self.addDropped(UInt64(overflow)) }
            self.flushInbound(fd: fd)
        }
    }

    /// 在 writeQueue 上调用
    private func flushInbound(fd: Int32) {
        inboundLock.lock()
        var written: UInt64 = 0
        while !inboundBuffer.isEmpty {
            let n = inboundBuffer.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!, inboundBuffer.count)
            }
            if n > 0 {
                inboundBuffer.removeFirst(n)
                written &+= UInt64(n)
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                break   // 内核缓冲已满, 等待 pollLoop 的可写事件再冲刷
            } else {
                // EIO: 没有客户端打开从设备, 数据无意义, 丢弃
                let dropped = inboundBuffer.count
                inboundBuffer.removeAll()
                inboundLock.unlock()
                if written > 0 { bumpCounters(toClient: written) }
                addDropped(UInt64(dropped))
                setClientConnected(false)
                return
            }
        }
        inboundLock.unlock()
        if written > 0 { bumpCounters(toClient: written) }
    }

    // MARK: - 主循环: 读取客户端数据 + 巡检波特率 + 冲刷写入缓冲

    private func pollLoop() {
        defer { pollExitSemaphore.signal() }
        var fds = pollfd()
        var buf = [UInt8](repeating: 0, count: 8192)
        var lastCheck = Date.distantPast

        while isRunning && !Thread.current.isCancelled {
            stateLock.lock()
            let fd = masterFD
            stateLock.unlock()
            inboundLock.lock()
            let hasPendingWrite = !inboundBuffer.isEmpty
            inboundLock.unlock()
            if fd < 0 { break }

            fds.fd = fd
            // 只在有数据待写入时才监听 POLLOUT，避免 PTY 写缓冲区始终就绪导致的忙等待
            fds.events = Int16(POLLIN | (hasPendingWrite ? POLLOUT : 0))
            fds.revents = 0
            let r = poll(&fds, 1, 200)
            if r > 0 {
                if fds.revents & Int16(POLLIN) != 0 {
                    let n = Darwin.read(fd, &buf, buf.count)
                    if n > 0 {
                        setClientConnected(true)
                        bumpCounters(fromClient: UInt64(n))
                        let data = Data(buf[0..<n])
                        onDataFromPort?(data)
                    } else if n < 0 && errno == EIO {
                        setClientConnected(false)
                    }
                }
                if fds.revents & Int16(POLLOUT) != 0 {
                    writeQueue.async { [weak self] in self?.flushInbound(fd: fd) }
                }
                if fds.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    setClientConnected(false)
                }
            }

            // 每 0.5s 巡检一次 termios, 同步波特率给芯片
            if Date().timeIntervalSince(lastCheck) > 0.5 {
                lastCheck = Date()
                checkTermios(fd: fd)
            }
        }
    }

    private func checkTermios(fd: Int32) {
        var tio = termios()
        guard tcgetattr(fd, &tio) == 0 else { return }
        stateLock.lock()
        let last = lastTermios
        // 无论本次是否触发同步都刷新基线, 避免"检测到变化但未同步"时每 0.5s 重复告警
        lastTermios = tio
        stateLock.unlock()
        guard var last else { return }

        let speedChanged = cfgetispeed(&tio) != cfgetispeed(&last)
        let flagsChanged = (tio.c_cflag & (tcflag_t(CSIZE) | tcflag_t(CSTOPB) | tcflag_t(PARENB) | tcflag_t(PARODD)))
                        != (last.c_cflag & (tcflag_t(CSIZE) | tcflag_t(CSTOPB) | tcflag_t(PARENB) | tcflag_t(PARODD)))
        guard speedChanged || flagsChanged else { return }

        // 波特率超出 PTY 标准可表达范围(macOS termios 上限 230400, 如经 IOSSIOSPEED
        // 设置 460800+): 不再静默回落 9600 把错误波特率同步给芯片, 明确告警并跳过本次
        guard let baud = Self.baudRate(from: cfgetispeed(&tio)), baud > 0 else {
            emitLog("串口工具设置的波特率超出 macOS PTY 标准可表达范围(≤230400), 本次参数未同步给芯片")
            return
        }

        var params = SerialParameters.default
        params.baudRate = baud
        switch tio.c_cflag & tcflag_t(CSIZE) {
        case tcflag_t(CS5): params.dataBits = 5
        case tcflag_t(CS6): params.dataBits = 6
        case tcflag_t(CS7): params.dataBits = 7
        default:             params.dataBits = 8
        }
        params.stopBits = (tio.c_cflag & tcflag_t(CSTOPB)) != 0 ? 2 : 1
        if (tio.c_cflag & tcflag_t(PARENB)) != 0 {
            params.parity = (tio.c_cflag & tcflag_t(PARODD)) != 0 ? 1 : 2
        } else {
            params.parity = 0
        }
        DispatchQueue.main.async { self.currentBaudRate = params.baudRate }
        emitLog("虚拟串口参数变化 -> \(params.baudRate) bps \(params.dataBits)\(params.stopBits == 2 ? "2" : "1") 校验\(params.parity)")
        onBaudChange?(params)
    }

    /// termios speed_t -> 实际波特率
    public static func baudRate(from speed: speed_t) -> UInt32? {
        switch speed {
        case speed_t(B0):      return 0
        case speed_t(B50):     return 50
        case speed_t(B75):     return 75
        case speed_t(B110):    return 110
        case speed_t(B134):    return 134
        case speed_t(B150):    return 150
        case speed_t(B200):    return 200
        case speed_t(B300):    return 300
        case speed_t(B600):    return 600
        case speed_t(B1200):   return 1200
        case speed_t(B1800):   return 1800
        case speed_t(B2400):   return 2400
        case speed_t(B4800):   return 4800
        case speed_t(B9600):   return 9600
        case speed_t(B19200):  return 19200
        case speed_t(B38400):  return 38400
        case speed_t(B7200):   return 7200
        case speed_t(B14400):  return 14400
        case speed_t(B28800):  return 28800
        case speed_t(B57600):  return 57600
        case speed_t(B76800):  return 76800
        case speed_t(B115200): return 115200
        case speed_t(B230400): return 230400
        default:               return nil
        }
    }

    // MARK: - 状态辅助

    private func setClientConnected(_ value: Bool) {
        DispatchQueue.main.async {
            if self.clientConnected != value {
                self.clientConnected = value
                self.emitLogMain(value ? "串口工具已打开虚拟串口" : "串口工具已释放虚拟串口")
            }
        }
    }

    private func bumpCounters(fromClient: UInt64 = 0, toClient: UInt64 = 0) {
        counterLock.lock()
        pendingFromClient &+= fromClient
        pendingToClient &+= toClient
        scheduleCounterFlushLocked()
        counterLock.unlock()
    }

    private func addDropped(_ n: UInt64) {
        counterLock.lock()
        pendingDropped &+= n
        scheduleCounterFlushLocked()
        counterLock.unlock()
    }

    /// 在 counterLock 内调用: 以 <=10Hz 的节奏把累计计数一次性发布到主线程
    private func scheduleCounterFlushLocked() {
        guard !counterFlushScheduled else { return }
        counterFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.counterLock.lock()
            let f = self.pendingFromClient
            let t = self.pendingToClient
            let d = self.pendingDropped
            self.pendingFromClient = 0; self.pendingToClient = 0; self.pendingDropped = 0
            self.counterFlushScheduled = false
            self.counterLock.unlock()
            self.bytesFromClient &+= f
            self.bytesToClient &+= t
            self.droppedBytes &+= d
        }
    }

    private func emitLog(_ message: String) {
        DispatchQueue.main.async { self.onLog?(message) }
    }

    private func emitLogMain(_ message: String) { onLog?(message) }
}
