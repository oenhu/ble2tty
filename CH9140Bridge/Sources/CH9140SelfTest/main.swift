//
//  CH9140SelfTest - 无需 Xcode 的自检测试程序
//  运行: swift run CH9140SelfTest   (或 .build/debug/CH9140SelfTest)
//

import Foundation
import CH9140Core

var passed = 0
var failed = 0

/// 在主线程上边跑 RunLoop 边等条件成立(logger 回调跑在主队列, 不能死等信号量)
func waitMain(_ cond: () -> Bool, timeout: Double = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !cond() && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return cond()
}

func check(_ condition: Bool, _ name: String, _ detail: String = "") {
    if condition {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        print("  ❌ \(name) \(detail)")
    }
}

print("== CH9140Protocol 编解码 ==")

// 测试向量与 WCH iOS 官方库注释一致: 86000900 00c20100 080100cc -> 115200 8N1
do {
    let data = Data([0x86, 0x00, 0x09, 0x00, 0x00, 0xC2, 0x01, 0x00, 0x08, 0x01, 0x00, 0xCC])
    if case .serialParameters(let p)? = CH9140Protocol.decode(data) {
        check(p.baudRate == 115200 && p.dataBits == 8 && p.stopBits == 1 && p.parity == 0,
              "解码 0x86 串口参数回包")
    } else { check(false, "解码 0x86 串口参数回包") }
}
do {
    let cmd = CH9140Protocol.encodeSerialParameters(SerialParameters(baudRate: 115200, dataBits: 8, stopBits: 1, parity: 0))
    check(cmd == Data([0x06, 0x00, 0x09, 0x00, 0x00, 0xC2, 0x01, 0x00, 0x08, 0x01, 0x00, 0xCC]),
          "编码 0x06 串口配置 (115200 8N1)", HexUtil.hexString(cmd))
}
do {
    let cmd = CH9140Protocol.encodeSerialParameters(SerialParameters(baudRate: 9600, dataBits: 8, stopBits: 1, parity: 0))
    check(cmd == Data([0x06, 0x00, 0x09, 0x00, 0x80, 0x25, 0x00, 0x00, 0x08, 0x01, 0x00, 0xAE]),
          "编码 0x06 串口配置 (9600 8N1)", HexUtil.hexString(cmd))
}
do {
    let cmd = CH9140Protocol.encodeModemLines(ModemLines(flowControl: true, dtr: 1, rts: 1))
    check(cmd == Data([0x07, 0x00, 0x05, 0x00, 0x01, 0x01, 0x01, 0x03]),
          "编码 0x07 流控/MODEM 配置", HexUtil.hexString(cmd))
}
do {
    let data = Data([0x87, 0x00, 0x05, 0x00, 0x01, 0x00, 0x01, 0x02])
    if case .modemLines(let m)? = CH9140Protocol.decode(data) {
        check(m.flowControl && m.dtr == 0 && m.rts == 1, "解码 0x87 MODEM 回包")
    } else { check(false, "解码 0x87 MODEM 回包") }
}
do {
    let data = Data([0x88, 0x00, 0x03, 0x00, 0x07, 0xF0, 0xF7])
    if case .status(let s)? = CH9140Protocol.decode(data) {
        check(s.uartSendEmpty && s.modemChanged && s.uartSendFull && s.cts && s.dsr && s.ri && s.dcd,
              "解码 0x88 状态上报(全置位)")
    } else { check(false, "解码 0x88 状态上报(全置位)") }
}
do {
    let data = Data([0x88, 0x00, 0x03, 0x00, 0x01, 0x00, 0x01])
    if case .status(let s)? = CH9140Protocol.decode(data) {
        check(s.uartSendEmpty && !s.uartSendFull && !s.cts, "解码 0x88 状态上报(空闲)")
    } else { check(false, "解码 0x88 状态上报(空闲)") }
}
check(CH9140Protocol.decode(Data([0x86, 0x00, 0x09, 0x00, 0x00, 0xC2, 0x01, 0x00, 0x08, 0x01, 0x00, 0xCD])) == nil,
      "校验和错误时拒绝解析")
check(CH9140Protocol.decode(Data([0x99, 0x00, 0x03, 0x00, 0x01, 0x00, 0x01])) == nil,
      "未知指令拒绝解析")

print("== HexUtil ==")
check(HexUtil.hexString(Data([0x0D, 0x0A])) == "0D 0A", "hexString")
check(HexUtil.data(fromHexString: "0D 0A") == Data([0x0D, 0x0A]), "data fromHex '0D 0A'")
check(HexUtil.data(fromHexString: "0d0a") == Data([0x0D, 0x0A]), "data fromHex '0d0a'")
check(HexUtil.data(fromHexString: "0x0D 0x0A") == Data([0x0D, 0x0A]), "data fromHex '0x0D 0x0A'")
check(HexUtil.data(fromHexString: "0D0") == nil, "奇数个字符返回 nil")
check(HexUtil.data(fromHexString: "ZZ") == nil, "非法字符返回 nil")

print("== VirtualSerialPort (PTY) ==")

let port = VirtualSerialPort()
do {
    let link = try port.open(name: "CH9140SelfTest")
    check(port.isOpen && FileManager.default.fileExists(atPath: link),
          "创建虚拟串口与符号链接", link)
    check(port.slavePath.hasPrefix("/dev/ttys"), "从设备路径形如 /dev/ttysNNN", port.slavePath)

    // 客户端 -> 端口 -> 回调
    let sem1 = DispatchSemaphore(value: 0)
    var received = Data()
    port.onDataFromPort = { d in
        received.append(d)
        if received.count >= 5 { sem1.signal() }
    }
    let client = FileHandle(forUpdatingAtPath: port.slavePath)!
    client.write(Data("HELLO".utf8))
    check(sem1.wait(timeout: .now() + 3) == .success && String(decoding: received, as: UTF8.self) == "HELLO",
          "客户端写入 -> onDataFromPort", String(decoding: received, as: UTF8.self))

    // 端口 -> 客户端
    let sem2 = DispatchSemaphore(value: 0)
    var gotBack = Data()
    DispatchQueue.global().async {
        let d = client.availableData
        gotBack = d
        sem2.signal()
    }
    Thread.sleep(forTimeInterval: 0.3)
    port.writeToPort(Data("WORLD".utf8))
    check(sem2.wait(timeout: .now() + 3) == .success && String(decoding: gotBack, as: UTF8.self).contains("WORLD"),
          "writeToPort -> 客户端读到", String(decoding: gotBack, as: UTF8.self))

    // 波特率变化检测
    let sem3 = DispatchSemaphore(value: 0)
    var detectedBaud: UInt32 = 0
    port.onBaudChange = { p in
        if p.baudRate == 115200 { detectedBaud = p.baudRate; sem3.signal() }
    }
    let fd = Darwin.open(port.slavePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
    var tio = termios()
    tcgetattr(fd, &tio)
    cfsetispeed(&tio, speed_t(B115200))
    cfsetospeed(&tio, speed_t(B115200))
    tcsetattr(fd, TCSANOW, &tio)
    check(sem3.wait(timeout: .now() + 3) == .success && detectedBaud == 115200,
          "tcsetattr -> onBaudChange(115200)")
    Darwin.close(fd)
    client.closeFile()

    port.close()
    check(!FileManager.default.fileExists(atPath: link), "关闭后符号链接被移除")
} catch {
    check(false, "创建虚拟串口", error.localizedDescription)
}

check(VirtualSerialPort.baudRate(from: speed_t(B9600)) == 9600, "speed_t 映射 B9600")
check(VirtualSerialPort.baudRate(from: speed_t(B115200)) == 115200, "speed_t 映射 B115200")
check(VirtualSerialPort.baudRate(from: speed_t(B230400)) == 230400, "speed_t 映射 B230400")
check(VirtualSerialPort.baudRate(from: speed_t(B0)) == 0, "speed_t 映射 B0")
check(VirtualSerialPort.baudRate(from: speed_t(460800)) == nil, "超出 PTY 标准范围的波特率返回 nil(不回落)")
check(VirtualSerialPort.sanitizedName("a/b") == "a-b", "串口名净化(路径分隔符)")
check(VirtualSerialPort.sanitizedName("   ") == "CH9140", "空白串口名回退默认值")

print("== SessionLogger ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "CH9140BLE2U", header: "自检测试")
    logger.log(Data("enable\r\n".utf8), direction: .rx, format: .ascii, timestamps: true)
    logger.log(Data([0x01, 0x02]), direction: .tx, format: .hex, timestamps: true)
    Thread.sleep(forTimeInterval: 0.8)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.5)

    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    check(files.count == 1 && files.first!.hasPrefix("CH9140_CH9140BLE2U_") && files.first!.hasSuffix(".log"),
          "日志文件创建", files.joined())
    if let f = files.first {
        let content = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
        check(content.contains("CH9140 Bridge 会话日志") && content.contains("[RX] enable")
              && content.contains("[TX] 01 02") && content.contains("会话结束"),
              "日志内容完整")
    }
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "日志写入", error.localizedDescription)
}

print("== SessionLogger 按日期存储 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let day = SessionLogger.dayFormatter.string(from: Date())

    // 按日期分目录: <dir>/yyyy-MM-dd/CH9140_设备名_HHmmss.log
    let logger1 = SessionLogger()
    logger1.openSession(directory: dir, deviceName: "CH9140BLE2U",
                        header: "按日期分目录", mode: .dailyFolder)
    logger1.log(Data("conf t\r\n".utf8), direction: .rx, format: .ascii, timestamps: true)
    Thread.sleep(forTimeInterval: 0.6)
    logger1.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    let dayDir = dir.appendingPathComponent(day)
    let dayFiles = (try? FileManager.default.contentsOfDirectory(atPath: dayDir.path)) ?? []
    check(dayFiles.count == 1 && dayFiles.first!.hasPrefix("CH9140_CH9140BLE2U_"),
          "按日期分目录创建 \(day)/ 子目录文件", dayFiles.joined())

    // 按日期合并: 两个会话追加到同一文件 CH9140_yyyy-MM-dd.log
    let logger2 = SessionLogger()
    logger2.openSession(directory: dir, deviceName: "CH9140BLE2U",
                        header: "会话一", mode: .dailyFile)
    logger2.log(Data("enable\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.5)
    logger2.closeSession()
    Thread.sleep(forTimeInterval: 0.3)

    let logger3 = SessionLogger()
    logger3.openSession(directory: dir, deviceName: "CH9140BLE2U",
                        header: "会话二", mode: .dailyFile)
    logger3.log(Data("show version\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.5)
    logger3.closeSession()
    Thread.sleep(forTimeInterval: 0.3)

    let dailyFile = dir.appendingPathComponent("CH9140_CH9140BLE2U_\(day).log")
    if let content = try? String(contentsOf: dailyFile, encoding: .utf8) {
        let bannerCount = content.components(separatedBy: "CH9140 Bridge 会话日志").count - 1
        check(bannerCount == 2 && content.contains("enable") && content.contains("show version"),
              "按日期合并文件追加两个会话", "会话数=\(bannerCount)")
    } else {
        check(false, "按日期合并文件追加两个会话", "文件不存在 \(dailyFile.path)")
    }

    // 示例路径
    let example = SessionLogger.examplePath(directory: dir.path, deviceName: "CH9140BLE2U",
                                            customName: "", template: SessionLogger.defaultTemplate,
                                            mode: .dailyFolder)
    check(example.contains("/\(day)/CH9140_CH9140BLE2U_"), "示例路径(按日期分目录)", example)
    let example2 = SessionLogger.examplePath(directory: dir.path, deviceName: "x",
                                             customName: "", template: SessionLogger.defaultTemplate,
                                             mode: .dailyFile)
    check(example2.hasSuffix("CH9140_x_\(day).log"), "示例路径(按日期合并)", example2)

    try? FileManager.default.removeItem(at: dir)
}

print("== SessionLogger 字节精确写入 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()

    // 纯文本无时间戳: 字节精确, 不注入多余换行(模拟 BLE 分包到达)
    logger.openSession(directory: dir, deviceName: "T", header: "字节精确测试", mode: .perSession)
    logger.log(Data("Switch# show ver".utf8), direction: .rx, format: .ascii, timestamps: false)
    logger.log(Data("\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    logger.log(Data("A\r\nB".utf8), direction: .rx, format: .ascii, timestamps: false)
    logger.log(Data("C\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.6)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    if let f = try? FileManager.default.contentsOfDirectory(atPath: dir.path).first,
       let content = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) {
        check(content.contains("Switch# show ver\r\nA\r\nBC\r\n"),
              "纯文本模式字节精确(分包合流不注换行)")
    } else { check(false, "纯文本模式字节精确") }
    try? FileManager.default.removeItem(at: dir)

    // 纯文本带时间戳: 前缀只出现在行首, 分包不破坏内容
    let logger2 = SessionLogger()
    logger2.openSession(directory: dir, deviceName: "T", header: "时间戳行首测试", mode: .perSession)
    logger2.log(Data("show ver\r\nsh".utf8), direction: .rx, format: .ascii, timestamps: true)
    logger2.log(Data("ow vlan\r\n".utf8), direction: .rx, format: .ascii, timestamps: true)
    Thread.sleep(forTimeInterval: 0.6)
    logger2.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    if let f = try? FileManager.default.contentsOfDirectory(atPath: dir.path).first,
       let content = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) {
        check(content.contains("[RX] show ver\r\n") && content.contains("[RX] show vlan\r\n"),
              "时间戳只出现在行首且分包内容合并", content.replacingOccurrences(of: "\r", with: ""))
    } else { check(false, "时间戳只出现在行首") }
    try? FileManager.default.removeItem(at: dir)
}

print("== 文件名模板解析 ==")
do {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let date = df.date(from: "2026-09-05 18:44:30")!
    func resolve(_ t: String, _ dev: String = "CH9140BLE2U", _ name: String = "",
                 _ seq: Int = 1, degrade: Bool = false) -> String {
        SessionLogger.resolveTemplate(t, deviceName: dev, customName: name,
                                      date: date, seq: seq, degradeTime: degrade)
    }
    check(resolve("CH9140_{device}_{datetime}") == "CH9140_CH9140BLE2U_20260905_184430",
          "默认模板", resolve("CH9140_{device}_{datetime}"))
    check(resolve("{name}_{date}", "dev", "机房A-SW01") == "机房A-SW01_2026-09-05",
          "自定义标识+日期", resolve("{name}_{date}", "dev", "机房A-SW01"))
    check(resolve("CH9140_{name}_{device}") == "CH9140_CH9140BLE2U",
          "空标识折叠分隔符", resolve("CH9140_{name}_{device}"))
    check(resolve("{device}_{seq}", "dev", "", 3) == "dev_03", "序号两位", resolve("{device}_{seq}", "dev", "", 3))
    check(resolve("a/b\\c:d") == "a-b-c-d", "非法字符净化", resolve("a/b\\c:d"))
    check(resolve("") == "CH9140", "空模板回退默认")
    check(resolve("x_{datetime}", "d", "", 1, degrade: true) == "x_2026-09-05",
          "合并模式下 datetime 退化为 date", resolve("x_{datetime}", "d", "", 1, degrade: true))
    check(resolve("{name}_log", "dev", "") == "log", "空标识开头分隔符修剪", resolve("{name}_log", "dev", ""))
}

print("== 日志切割 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let day = SessionLogger.dayFormatter.string(from: Date())

    // 固定模板切割: 重名自动补 -02 序号
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "切割测试",
                       mode: .perSession, template: "rotate_fixed")
    logger.log(Data("part1\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.5)
    var newURL: URL?
    var callbackFired = false
    logger.rotateSession { url in newURL = url; callbackFired = true }
    check(waitMain { callbackFired }, "切割回调")
    logger.log(Data("part2\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.5)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.4)

    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    check(files.contains("rotate_fixed.log") && files.contains("rotate_fixed-02.log"),
          "固定模板切割生成序号文件", files.joined())
    check(newURL?.lastPathComponent == "rotate_fixed-02.log", "切割回调返回新文件", newURL?.lastPathComponent ?? "nil")
    if let c1 = try? String(contentsOf: dir.appendingPathComponent("rotate_fixed.log"), encoding: .utf8),
       let c2 = try? String(contentsOf: dir.appendingPathComponent("rotate_fixed-02.log"), encoding: .utf8) {
        check(c1.contains("part1") && !c1.contains("part2") && c2.contains("part2") && !c2.contains("part1"),
              "切割前后数据各归其档")
        check(c2.contains("手动切割"), "新文件含切割标记")
    }
    try? FileManager.default.removeItem(at: dir)

    // 含 {seq} 模板切割
    let logger2 = SessionLogger()
    logger2.openSession(directory: dir, deviceName: "T", header: "seq 测试",
                        mode: .perSession, template: "rot_{seq}")
    Thread.sleep(forTimeInterval: 0.4)
    var cb2 = false
    logger2.rotateSession { _ in cb2 = true }
    _ = waitMain { cb2 }
    logger2.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    let files2 = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    check(files2.contains("rot_01.log") && files2.contains("rot_02.log"),
          "{seq} 模板序号递增", files2.joined())
    try? FileManager.default.removeItem(at: dir)

    // 追加模式(dailyFile)切割: 同一文件内分隔, 不新建文件
    let logger3 = SessionLogger()
    logger3.openSession(directory: dir, deviceName: "T", header: "会话一",
                        mode: .dailyFile, template: "merged_{date}")
    logger3.log(Data("AAA\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.4)
    var cb3 = false
    logger3.rotateSession { _ in cb3 = true }
    _ = waitMain { cb3 }
    logger3.log(Data("BBB\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.5)
    logger3.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    let files3 = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    check(files3 == ["merged_\(day).log"], "追加模式切割不产生新文件", files3.joined())
    if let c = try? String(contentsOf: dir.appendingPathComponent("merged_\(day).log"), encoding: .utf8) {
        let banners = c.components(separatedBy: "CH9140 Bridge 会话日志").count - 1
        check(banners == 2 && c.contains("AAA") && c.contains("BBB"),
              "追加模式切割后同文件含两个会话头", " banners=\(banners)")
    }
    try? FileManager.default.removeItem(at: dir)

    // 无会话时切割返回 nil
    let logger4 = SessionLogger()
    var cb4 = false
    var gotNil = false
    logger4.rotateSession { url in cb4 = true; gotNil = (url == nil) }
    check(waitMain { cb4 } && gotNil, "无会话切割回调 nil")
}

print("== LineAssembler 行装配 ==")
do {
    func B(_ s: String) -> Data { Data(s.utf8) }
    let CR: UInt8 = 0x0D, LF: UInt8 = 0x0A, BS: UInt8 = 0x08, BEL: UInt8 = 0x07, ESC: UInt8 = 0x1B

    // 基本成行
    var a = LineAssembler()
    check(a.feed(B("Switch# show ver") + [CR, LF]) == [B("Switch# show ver")], "CRLF 成行")

    // 分包合流: CRLF 跨包
    var b = LineAssembler()
    let r1 = b.feed(B("ab"))
    let r2 = b.feed(B("c") + [CR])
    let r3 = b.feed([LF] + B("next") + [LF])
    check(r1.isEmpty && r2.isEmpty && r3 == [B("abc"), B("next")], "跨包暂存并成行")

    // 退格编辑: "lisy" BS "t" -> "list"
    var c = LineAssembler()
    check(c.feed(B("lisy") + [BS] + B("t") + [CR, LF]) == [B("list")], "退格回删 lisy->list")

    // 单独 CR 行内重绘(模拟 Tab 补全后提示符重画)
    var d = LineAssembler()
    check(d.feed(B("Switch# dis")).isEmpty, "提示符暂存")
    check(d.feed([CR] + B("Switch# display") + [CR, LF]) == [B("Switch# display")], "CR 行内重绘")

    // Bell 回调
    var e = LineAssembler()
    var bellCount = 0
    e.onBell = { bellCount += 1 }
    _ = e.feed(B("error") + [BEL, BEL] + [CR, LF])
    check(bellCount == 2, "Bell 触发两次", "bellCount=\(bellCount)")

    // ANSI CSI 过滤
    var f = LineAssembler()
    check(f.feed([ESC] + B("[31mred") + [ESC] + B("[0m") + [CR, LF]) == [B("red")],
          "ANSI 颜色序列过滤")

    // 残行吐出
    var g = LineAssembler()
    _ = g.feed(B("Switch# "))
    let flushed = g.flushPending()
    check(flushed == B("Switch# ") && g.flushPending() == nil, "残行吐出且只吐一次")

    // 空行
    var h = LineAssembler()
    check(h.feed(Data([CR, LF])) == [Data()], "空行成行")
}

print("== SettingsStore ==")
do {
    // 自检使用显式注入的独立 suite, 与正式 App 的偏好域(cn.wch.CH9140Bridge)完全隔离,
    // 结束后整域清理, 不留任何持久化残留
    let suiteName = "CH9140SelfTest"
    UserDefaults().removePersistentDomain(forName: suiteName)
    let d = UserDefaults(suiteName: suiteName)!

    let s = SettingsStore(defaults: d)
    check(s.defaultBaudRate == 9600 && s.defaultDataBits == 8 && s.defaultStopBits == 1 && s.defaultParity == 0,
          "默认串口参数 9600 8N1 无校验(交换机 Console)")
    check(s.logEnabled && s.logTimestamps && s.logSentData, "默认保存日志开启")

    // 损坏/越界的持久化值回退默认值, 而不是 clamp 后直接下发芯片
    d.set(300, forKey: "CH9140Bridge.defaultDataBits")   // UInt8(clamping:300) = 255
    d.set(9,   forKey: "CH9140Bridge.defaultStopBits")
    d.set(99,  forKey: "CH9140Bridge.defaultParity")
    d.set(50,  forKey: "CH9140Bridge.defaultBaudRate")   // 低于 300
    let sBad = SettingsStore(defaults: d)
    check(sBad.defaultDataBits == 8 && sBad.defaultStopBits == 1 && sBad.defaultParity == 0 && sBad.defaultBaudRate == 9600,
          "越界持久化值回退默认值")

    s.defaultBaudRate = 38400
    let s2 = SettingsStore(defaults: d)
    check(s2.defaultBaudRate == 38400, "设置持久化")
    s2.defaultBaudRate = 9600

    // 最近连接设备
    let s3 = SettingsStore(defaults: d)
    s3.addRecentDevice(uuid: UUID(uuidString: "8BE7B8EA-0000-0000-0000-000000000001")!, name: "CH9140BLE2U")
    s3.addRecentDevice(uuid: UUID(uuidString: "8BE7B8EA-0000-0000-0000-000000000002")!, name: "设备B")
    s3.addRecentDevice(uuid: UUID(uuidString: "8BE7B8EA-0000-0000-0000-000000000001")!, name: "CH9140BLE2U")
    check(s3.recentDevices.count == 2 && s3.recentDevices[0].name == "CH9140BLE2U",
          "最近连接去重置顶")
    let s4 = SettingsStore(defaults: d)
    check(s4.recentDevices.count == 2, "最近连接持久化")
    s4.removeRecentDevice(UUID(uuidString: "8BE7B8EA-0000-0000-0000-000000000001")!)
    check(SettingsStore(defaults: d).recentDevices.count == 1, "最近连接删除并持久化")
    s4.removeRecentDevice(UUID(uuidString: "8BE7B8EA-0000-0000-0000-000000000002")!)

    // 整域清理
    UserDefaults().removePersistentDomain(forName: suiteName)
}

print("")
print("========================================")
print("通过 \(passed) 项, 失败 \(failed) 项")
print("========================================")
exit(failed == 0 ? 0 : 1)
