//
//  WiredSerialPort.swift
//  有线串口连接(USB 转串口适配器等, 无需 CH9140)
//
//  公开接口与 BLEManager 对齐(connectionState / onReceive / onLog /
//  onConnectionChange / send / applySerialParameters / applyModemLines /
//  modemStatus / isReady), 让 BridgeModel 可以用同一套方式接线。
//
//  与 BLE 版的差异:
//   - 参数配置是本地 tcsetattr, 同步生效, 无需芯片回包校验;
//   - DTR/RTS/CTS 等 MODEM 线走 ioctl(TIOCM*); PTY 等伪终端返回 ENOTTY 时
//     优雅降级(报"不支持"), 不影响数据通路;
//   - 打开时尝试 TIOCEXCL 独占, 避免与其他串口工具互相抢数据;
//   - 发送侧同样使用分块 FIFO 背压(与 BLE 版同一模式)。
//

import Foundation
import Darwin

public final class WiredSerialPort: ObservableObject {

    // MARK: 发布给 UI 的状态
    @Published public private(set) var connectionState: BLEConnectionState = .disconnected
    @Published public private(set) var connectedPortPath: String = ""
    @Published public private(set) var connectedPortName: String = ""
    @Published public private(set) var modemStatus = ModemStatus()
    /// 最近一次成功应用到串口的参数(切波特率/打开时更新)
    @Published public private(set) var activeParams: SerialParameters?

    // MARK: 回调(均在主线程触发)
    public var onReceive: ((Data) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onConnectionChange: ((BLEConnectionState) -> Void)?

    public var isReady: Bool { connectionState == .ready }

    // MARK: 内部
    private let queue = DispatchQueue(label: "cn.wch.CH9140Bridge.wired", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "cn.wch.CH9140Bridge.wired.write", qos: .userInitiated)
    private var fd: Int32 = -1
    private var reader: Thread?
    private var running = false
    private let stateLock = NSLock()
    private let readerExit = DispatchSemaphore(value: 0)
    /// MODEM 输入状态轮询(1s; 设备不支持时自动停止)
    private var modemTimer: DispatchSourceTimer?
    /// 已确认支持 MODEM 线 ioctl(ENOTTY 后置 false, 避免每次配置都报错刷屏)
    private var modemIOCTLSupported = true

    // 发送队列: 分块 FIFO(与 BLEManager 同一模式)
    private var outboxChunks: [Data] = []
    private var outboxHead = 0
    private var outboxBytes = 0

    private var isRunning: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return running }
        set { stateLock.lock(); running = newValue; stateLock.unlock() }
    }

    public init() {}

    deinit { teardown(notify: false) }

    // MARK: - 连接 / 断开

    /// 打开有线串口并以指定参数配置(9600 8N1 之外的参数必须在打开时就设置,
    /// 主机侧帧格式必须与对端一致才能正确收发)
    public func connect(path: String, name: String,
                        params: SerialParameters, flowControl: Bool = false) {
        queue.async {
            guard self.fd < 0 else {
                self.log("已有打开的串口, 请先断开")
                return
            }
            self.updateMain {
                $0.connectedPortPath = path
                $0.connectedPortName = name
            }
            self.setState(.connecting)
            self.log("正在打开串口 \(name)(\(path))…")

            let newFD = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard newFD >= 0 else {
                let msg = Self.openErrorMessage(errno, path: path)
                self.log("打开串口失败: \(msg)")
                self.updateMain {
                    $0.connectedPortPath = ""
                    $0.connectedPortName = ""
                }
                self.setState(.failed(msg))
                return
            }
            // 独占: 防止其他串口工具与本 App 互相抢数据(驱动不支持则忽略)
            if ioctl(newFD, TIOCEXCL) != 0, errno != ENOTTY {
                let msg = "串口被其他程序占用(可用 lsof \(path) 查看)"
                self.log("打开串口失败: \(msg)")
                Darwin.close(newFD)
                self.updateMain {
                    $0.connectedPortPath = ""
                    $0.connectedPortName = ""
                }
                self.setState(.failed(msg))
                return
            }

            // 原始模式 + 初始参数; 冲刷两侧缓冲, 丢掉上会话残留的乱码
            // (乱码字节可能被对端串口控制台解释为 BREAK/命令, 实测触发过 Linux SysRq)
            var tio = termios()
            guard tcgetattr(newFD, &tio) == 0 else {
                Darwin.close(newFD)
                self.setState(.failed("读取串口参数失败"))
                return
            }
            cfmakeraw(&tio)
            tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
            tio.c_cc.16 = 0   // VMIN
            tio.c_cc.17 = 0   // VTIME
            guard Self.apply(params, flowControl: flowControl, to: &tio) else {
                Darwin.close(newFD)
                self.setState(.failed("串口参数不受支持"))
                return
            }
            guard tcsetattr(newFD, TCSANOW, &tio) == 0 else {
                Darwin.close(newFD)
                self.setState(.failed("设置串口参数失败: \(String(cString: strerror(errno)))"))
                return
            }
            tcflush(newFD, TCIOFLUSH)

            self.stateLock.lock()
            self.fd = newFD
            self.stateLock.unlock()
            self.modemIOCTLSupported = true

            // 读线程(poll 模式, 与 VirtualSerialPort 同一形态)
            let thread = Thread { [weak self] in self?.readLoop() }
            thread.name = "BLE2TTY.WiredRead"
            thread.qualityOfService = .userInitiated
            self.stateLock.lock()
            self.running = true
            self.reader = thread
            self.stateLock.unlock()
            thread.start()

            self.startModemPolling()
            self.updateMain { $0.activeParams = params }
            self.log("串口已就绪: \(name) \(Self.describe(params)) 流控\(flowControl ? "开" : "关")")
            self.setState(.ready)
        }
    }

    public func disconnect() {
        queue.async {
            guard self.currentFD() >= 0 else { return }
            self.log("主动断开串口")
            self.teardownLocked()
            self.setState(.disconnected)
        }
    }

    /// 打开失败的友好错误信息
    private static func openErrorMessage(_ e: Int32, path: String) -> String {
        switch e {
        case EBUSY:  return "串口被其他程序占用(可用 lsof \(path) 查看)"
        case EACCES: return "没有权限访问 \(path)"
        case ENOENT: return "设备不存在(已拔出?): \(path)"
        default:     return "\(String(cString: strerror(e)))(errno \(e))"
        }
    }

    // MARK: - 收发

    /// 主机 -> 串口(分块 FIFO 背压; 断连期间丢弃)
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async {
            guard self.currentFD() >= 0 else { return }
            self.outboxChunks.append(data)
            self.outboxBytes += data.count
            let maxOutbox = 256 * 1024
            if self.outboxBytes > maxOutbox {
                var dropped = 0
                while self.outboxBytes > maxOutbox, self.outboxHead < self.outboxChunks.count {
                    self.outboxBytes -= self.outboxChunks[self.outboxHead].count
                    dropped += self.outboxChunks[self.outboxHead].count
                    self.outboxHead += 1
                }
                self.log("串口写入持续阻塞, 发送队列溢出, 已丢弃最旧 \(dropped) 字节")
            }
            self.pumpOutbox()
        }
    }

    /// 必须在 writeQueue 调用
    private func pumpOutbox() {
        let fd = currentFD()
        guard fd >= 0 else { return }
        while outboxHead < outboxChunks.count {
            let chunk = outboxChunks[outboxHead]
            let n = chunk.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!, chunk.count)
            }
            if n > 0 {
                outboxBytes -= n
                if n == chunk.count {
                    outboxHead += 1
                } else {
                    outboxChunks[outboxHead] = chunk.dropFirst(n)
                }
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return   // 驱动缓冲已满, 等 POLLOUT 再继续
            } else {
                // EIO/EBADF 等: 设备已拔出, 读线程会统一落定, 这里只清空队列
                clearOutbox()
                return
            }
        }
        if outboxHead > 64 && outboxHead * 2 > outboxChunks.count {
            outboxChunks.removeFirst(outboxHead)
            outboxHead = 0
        }
    }

    private func clearOutbox() {
        outboxChunks.removeAll()
        outboxHead = 0
        outboxBytes = 0
    }

    /// 读线程主循环: poll 读数据 + 按需 POLLOUT 冲刷写缓冲 + 拔出检测
    private func readLoop() {
        defer { readerExit.signal() }
        var fds = pollfd()
        var buf = [UInt8](repeating: 0, count: 8192)
        while isRunning && !Thread.current.isCancelled {
            let fd = currentFD()
            if fd < 0 { break }
            let hasPendingWrite = outboxBytes > 0
            fds.fd = fd
            fds.events = Int16(POLLIN | (hasPendingWrite ? POLLOUT : 0))
            fds.revents = 0
            let r = poll(&fds, 1, 200)
            if r > 0 {
                if fds.revents & Int16(POLLIN) != 0 {
                    let n = Darwin.read(fd, &buf, buf.count)
                    if n > 0 {
                        let data = Data(buf[0..<n])
                        DispatchQueue.main.async { self.onReceive?(data) }
                    } else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                        handleLinkLoss(reason: "读取失败: \(String(cString: strerror(errno)))")
                        break
                    }
                }
                if fds.revents & Int16(POLLOUT) != 0 {
                    writeQueue.async { [weak self] in self?.pumpOutbox() }
                }
                if fds.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    handleLinkLoss(reason: "设备已拔出或驱动已卸载")
                    break
                }
            }
        }
    }

    /// 设备异常断开(读线程/写线程触发): 在 queue 上统一落定, 幂等
    private func handleLinkLoss(reason: String) {
        queue.async {
            guard self.currentFD() >= 0 else { return }
            self.log("串口连接中断: \(reason)")
            self.teardownLocked()
            self.setState(.disconnected)
        }
    }

    // MARK: - 参数配置

    /// 应用串口参数(本地 tcsetattr, 同步生效), 主线程回调 (成功, 信息)
    public func applySerialParameters(_ params: SerialParameters,
                                      completion: @escaping (Bool, String) -> Void) {
        queue.async {
            let fd = self.currentFD()
            guard fd >= 0 else {
                DispatchQueue.main.async { completion(false, "串口未连接") }
                return
            }
            var tio = termios()
            guard tcgetattr(fd, &tio) == 0 else {
                DispatchQueue.main.async { completion(false, "读取串口参数失败") }
                return
            }
            let flowOn = (tio.c_cflag & tcflag_t(CRTSCTS)) != 0
            guard Self.apply(params, flowControl: flowOn, to: &tio),
                  tcsetattr(fd, TCSANOW, &tio) == 0 else {
                DispatchQueue.main.async { completion(false, Self.unsupportedMessage(params)) }
                return
            }
            // 参数切换后冲刷两侧: 旧波特率期间收到的乱码不带给新会话
            tcflush(fd, TCIOFLUSH)
            // 读回校验: 驱动可能对非标准速率取整, 提示但不判失败
            var back = termios()
            var warn = ""
            if tcgetattr(fd, &back) == 0, cfgetispeed(&back) != speed_t(params.baudRate) {
                warn = "(驱动实际生效 \(cfgetispeed(&back)) bps, 与请求值不一致)"
            }
            self.updateMain { $0.activeParams = params }
            self.log("串口参数已应用: \(Self.describe(params)) \(warn)")
            DispatchQueue.main.async { completion(true, "串口参数已应用 \(warn)") }
        }
    }

    /// 应用流控与 DTR/RTS(CRTSCTS 走 termios; DTR/RTS 走 TIOCM*, 设备不支持时优雅降级)
    public func applyModemLines(_ lines: ModemLines,
                                completion: @escaping (Bool, String) -> Void) {
        queue.async {
            let fd = self.currentFD()
            guard fd >= 0 else {
                DispatchQueue.main.async { completion(false, "串口未连接") }
                return
            }
            // 硬件流控(macOS CRTSCTS = CCTS_OFLOW|CRTS_IFLOW): termios 层
            var tio = termios()
            guard tcgetattr(fd, &tio) == 0 else {
                DispatchQueue.main.async { completion(false, "读取串口参数失败") }
                return
            }
            if lines.flowControl {
                tio.c_cflag |= tcflag_t(CRTSCTS)
            } else {
                tio.c_cflag &= ~tcflag_t(CRTSCTS)
            }
            guard tcsetattr(fd, TCSANOW, &tio) == 0 else {
                DispatchQueue.main.async { completion(false, "设置流控失败") }
                return
            }
            // DTR/RTS: ioctl 层, USB 串口支持, PTY 等伪终端返回 ENOTTY
            var bits: Int32 = 0
            guard ioctl(fd, TIOCMGET, &bits) == 0 else {
                self.modemIOCTLSupported = false
                let msg = "流控\(lines.flowControl ? "已开启" : "已关闭"); 该设备不支持 DTR/RTS 控制"
                self.log(msg)
                DispatchQueue.main.async { completion(true, msg) }
                return
            }
            if lines.dtr != 0 { bits |= TIOCM_DTR } else { bits &= ~TIOCM_DTR }
            if lines.rts != 0 { bits |= TIOCM_RTS } else { bits &= ~TIOCM_RTS }
            guard ioctl(fd, TIOCMSET, &bits) == 0 else {
                let msg = "流控已设置, 但 DTR/RTS 写入失败: \(String(cString: strerror(errno)))"
                self.log(msg)
                DispatchQueue.main.async { completion(false, msg) }
                return
            }
            let msg = "流控\(lines.flowControl ? "开" : "关"), DTR \(lines.dtr), RTS \(lines.rts) 已应用"
            self.log(msg)
            DispatchQueue.main.async { completion(true, msg) }
        }
    }

    /// 把参数写入 termios; 不支持的参数返回 false
    private static func apply(_ p: SerialParameters, flowControl: Bool,
                              to tio: inout termios) -> Bool {
        // macOS termios 的 speed 即数值波特率, 支持任意速率(驱动决定是否生效)
        guard p.baudRate > 0 else { return false }
        cfsetispeed(&tio, speed_t(p.baudRate))
        cfsetospeed(&tio, speed_t(p.baudRate))
        tio.c_cflag &= ~tcflag_t(CSIZE)
        switch p.dataBits {
        case 5: tio.c_cflag |= tcflag_t(CS5)
        case 6: tio.c_cflag |= tcflag_t(CS6)
        case 7: tio.c_cflag |= tcflag_t(CS7)
        case 8: tio.c_cflag |= tcflag_t(CS8)
        default: return false
        }
        if p.stopBits == 2 { tio.c_cflag |= tcflag_t(CSTOPB) }
        else if p.stopBits == 1 { tio.c_cflag &= ~tcflag_t(CSTOPB) }
        else { return false }
        switch p.parity {
        case 0:
            tio.c_cflag &= ~tcflag_t(PARENB)
        case 1:   // 奇
            tio.c_cflag |= tcflag_t(PARENB | PARODD)
        case 2:   // 偶
            tio.c_cflag = (tio.c_cflag | tcflag_t(PARENB)) & ~tcflag_t(PARODD)
        default:
            return false   // 3/4(Mark/Space): macOS termios 不支持
        }
        if flowControl { tio.c_cflag |= tcflag_t(CRTSCTS) }
        else { tio.c_cflag &= ~tcflag_t(CRTSCTS) }
        return true
    }

    /// 参数摘要: "9600 8N1 无校验"
    private static func describe(_ p: SerialParameters) -> String {
        let pl: Character = ["N", "O", "E", "M", "S"][Int(min(p.parity, 4))]
        let pn = ["无", "奇", "偶", "标志", "空白"][Int(min(p.parity, 4))]
        return "\(p.baudRate) \(p.dataBits)\(pl)\(p.stopBits) \(pn)校验"
    }

    private static func unsupportedMessage(_ p: SerialParameters) -> String {
        if p.parity > 2 { return "macOS 串口不支持 Mark/Space 校验(仅 无/奇/偶)" }
        return "串口参数不受支持(波特率 \(p.baudRate)/数据位 \(p.dataBits)/停止位 \(p.stopBits))"
    }

    // MARK: - MODEM 状态轮询

    private func startModemPolling() {
        stopModemPolling()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.modemIOCTLSupported else { return }
            let fd = self.currentFD()
            guard fd >= 0 else { return }
            var bits: Int32 = 0
            guard ioctl(fd, TIOCMGET, &bits) == 0 else {
                // 设备不支持(如 PTY): 停止轮询, 不再打扰
                self.modemIOCTLSupported = false
                return
            }
            var s = ModemStatus()
            s.cts = bits & TIOCM_CTS != 0
            s.dsr = bits & TIOCM_DSR != 0
            s.ri  = bits & TIOCM_RI  != 0
            s.dcd = bits & TIOCM_CAR != 0
            DispatchQueue.main.async {
                if self.modemStatus != s { self.modemStatus = s }
            }
        }
        modemTimer = timer
        timer.resume()
    }

    private func stopModemPolling() {
        modemTimer?.cancel()
        modemTimer = nil
        updateMain { $0.modemStatus = ModemStatus() }
    }

    // MARK: - 内部工具

    private func currentFD() -> Int32 {
        stateLock.lock(); defer { stateLock.unlock() }; return fd
    }

    /// 在 queue 上调用(disconnect/handleLinkLoss/deinit 共用), 幂等
    private func teardownLocked() {
        stopModemPolling()
        stateLock.lock()
        let f = fd
        fd = -1
        let r = reader
        reader = nil
        running = false
        stateLock.unlock()
        r?.cancel()
        if let r, r.isExecuting, !r.isFinished {
            _ = readerExit.wait(timeout: .now() + 0.5)
        }
        if f >= 0 { Darwin.close(f) }
        writeQueue.async { self.clearOutbox() }
        updateMain {
            $0.connectedPortPath = ""
            $0.connectedPortName = ""
            $0.activeParams = nil
        }
    }

    /// deinit 用: 不同步状态发布
    private func teardown(notify: Bool) {
        stateLock.lock()
        let f = fd
        fd = -1
        running = false
        let r = reader
        stateLock.unlock()
        r?.cancel()
        if let r, r.isExecuting, !r.isFinished {
            _ = readerExit.wait(timeout: .now() + 0.5)
        }
        if f >= 0 { Darwin.close(f) }
        if notify { setState(.disconnected) }
    }

    private func setState(_ s: BLEConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = s
            self.onConnectionChange?(s)
        }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { self.onLog?(message) }
    }

    private func updateMain(_ mutate: @escaping (WiredSerialPort) -> Void) {
        DispatchQueue.main.async { mutate(self) }
    }
}
