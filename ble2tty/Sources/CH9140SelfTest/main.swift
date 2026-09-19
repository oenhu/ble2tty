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
        check(content.contains("BLE2TTY 会话日志") && content.contains("[RX] enable")
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
        let bannerCount = content.components(separatedBy: "BLE2TTY 会话日志").count - 1
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

print("== SessionLogger TX/RX 行隔离 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "行隔离")
    // 复现序列: RX 开放行(无 \n) → TX 无 \n → RX 回显
    logger.log(Data("Ruijie> ".utf8),      direction: .rx, format: .ascii, timestamps: true)
    logger.log(Data("show clock\r".utf8),  direction: .tx, format: .ascii, timestamps: true)
    logger.log(Data("16:30:36 UTC\r\n".utf8), direction: .rx, format: .ascii, timestamps: true)
    logger.log(Data("abc\r".utf8),         direction: .tx, format: .ascii, timestamps: true)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.8)

    let f = try FileManager.default.contentsOfDirectory(atPath: dir.path).first!
    let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    let dataLines = text.components(separatedBy: "\n")
        .filter { !$0.isEmpty && !$0.hasPrefix("=") && !$0.hasPrefix(" ")
                  && !$0.hasPrefix("-----") && $0 != "⏎" }
    let allPrefixed = dataLines.allSatisfy {
        $0.hasPrefix("[") && ($0.contains("] [RX] ") || $0.contains("] [TX] ")) }
    check(allPrefixed, "每个数据行均有方向前缀")
    check(text.contains("[TX] show clock"), "无换行 TX 有独立行与前缀")
    check(!text.contains("show clock\r["), "无跨方向粘连")
    check(text.contains("⏎"), "强制断行有可见标记")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "TX/RX 行隔离", error.localizedDescription)
}

print("== SessionLogger 无时间戳直通与保序 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "保序测试", mode: .perSession)
    // 复现序列: RX 提示符(无 \n) → TX 命令 → RX 回显 → TX 尾段(无 \n)
    logger.log(Data("Ruijie> ".utf8),         direction: .rx, format: .ascii, timestamps: false)
    logger.log(Data("show clock\r".utf8),     direction: .tx, format: .ascii, timestamps: false)
    logger.log(Data("16:30:36 UTC\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    logger.log(Data("abc".utf8),              direction: .tx, format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.6)

    // 零滞留: 未收尾、无换行的 TX 尾段此刻就应已在文件里
    let f = try FileManager.default.contentsOfDirectory(atPath: dir.path).first!
    let mid = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    check(mid.contains("abc"), "无时间戳模式无换行数据立即落盘(零滞留)")

    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    if let i1 = text.range(of: "Ruijie> ")?.lowerBound,
       let i2 = text.range(of: "show clock")?.lowerBound,
       let i3 = text.range(of: "16:30:36")?.lowerBound,
       let i4 = text.range(of: "abc")?.lowerBound {
        check(i1 < i2 && i2 < i3 && i3 < i4, "无时间戳模式跨方向保到达序")
    } else { check(false, "无时间戳模式跨方向保到达序", "文件缺数据段") }
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "无时间戳直通与保序", error.localizedDescription)
}

print("== SessionLogger ANSI 三字节序列 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "ANSI 测试", mode: .perSession)
    // ESC # 8(DECALN) 与 ESC % G 均为三字节序列, 末字节不得漏入文本
    logger.log(Data([0x1B, 0x23, 0x38] + Array("hello\n".utf8)), direction: .rx,
               format: .ascii, timestamps: false, stripANSI: true)
    logger.log(Data([0x1B, 0x25, 0x47] + Array("world\n".utf8)), direction: .rx,
               format: .ascii, timestamps: false, stripANSI: true)
    Thread.sleep(forTimeInterval: 0.6)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    let f = try FileManager.default.contentsOfDirectory(atPath: dir.path).first!
    let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    check(text.contains("hello") && !text.contains("8hello"), "ESC#8 三字节序列完整剥离")
    check(text.contains("world") && !text.contains("Gworld"), "ESC%%G 三字节序列完整剥离")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "ANSI 三字节序列", error.localizedDescription)
}

print("== SessionLogger 失败上报 ==")
do {
    // 用一个已存在的文件当目录: createDirectory 必失败
    let blocker = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-blocker-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: blocker.path, contents: Data())
    let logger = SessionLogger()
    var reported = false
    var callbackFired = false
    var cbURL: URL? = URL(fileURLWithPath: "/placeholder")   // 区分"未回调"与"回调 nil"
    logger.onError = { _ in reported = true }
    logger.openSession(directory: blocker.appendingPathComponent("sub"),
                       deviceName: "T", header: "失败测试") { url in
        cbURL = url; callbackFired = true
    }
    check(waitMain { callbackFired }, "打开失败 completion 回调")
    check(callbackFired && cbURL == nil, "打开失败回调 URL 为 nil")
    check(waitMain { reported }, "打开失败 onError 上报")
    try? FileManager.default.removeItem(at: blocker)
}

print("== SessionLogger 计数重置与大小上限 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "计数", mode: .perSession)
    logger.log(Data("hello\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    check(waitMain { logger.bytesWritten > 0 }, "字节计数随写入增长")
    logger.openSession(directory: dir, deviceName: "T", header: "计数2", mode: .perSession)
    check(waitMain { logger.bytesWritten == 0 }, "新会话字节计数清零")
    logger.closeSession()

    // 单文件大小上限: cap=1 时任意写入后下一包必触发切割
    let prevCap = SessionLogger.maxFileBytes
    SessionLogger.maxFileBytes = 1
    let logger2 = SessionLogger()
    logger2.openSession(directory: dir, deviceName: "T", header: "上限",
                        mode: .perSession, template: "cap_test")
    Thread.sleep(forTimeInterval: 0.3)
    logger2.log(Data("chunk\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.5)
    logger2.closeSession()
    Thread.sleep(forTimeInterval: 0.3)
    SessionLogger.maxFileBytes = prevCap

    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    let capFiles = files.filter { $0.hasPrefix("cap_test") }
    check(capFiles.count >= 2, "超过大小上限自动切割", capFiles.joined())
    let anyNote = capFiles.contains {
        (try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))?.contains("自动切割") == true
    }
    check(anyNote, "切割文件 banner 含原因")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "计数重置与大小上限", error.localizedDescription)
}

print("== SessionLogger 选项变更标记 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "变更", mode: .perSession)
    logger.log(Data("line1\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    logger.log(Data([0x01, 0x02]), direction: .rx, format: .hex, timestamps: false)   // 中途改格式
    Thread.sleep(forTimeInterval: 0.6)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    let f = try FileManager.default.contentsOfDirectory(atPath: dir.path).first!
    let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    check(text.contains("日志选项变更"), "会话中途改格式留系统标记行")
    check(text.contains("格式=十六进制"), "标记行含新格式")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "选项变更标记", error.localizedDescription)
}

print("== SessionLogger GBK 开关切换半字吐出 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "半字", mode: .perSession)
    logger.log(Data([0xD6]), direction: .rx, format: .ascii, timestamps: false, decodeGBK: true)   // GBK 孤立前导进暂存
    logger.log(Data("OK\r\n".utf8), direction: .rx, format: .ascii, timestamps: false, decodeGBK: false) // 开关关闭
    Thread.sleep(forTimeInterval: 0.6)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    let f = try FileManager.default.contentsOfDirectory(atPath: dir.path).first!
    let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    check(text.contains("\u{FFFD}OK"), "转码关闭时残留半字立即以 U+FFFD 吐出(不滞留到收尾)")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "GBK 开关切换半字吐出", error.localizedDescription)
}

print("== SessionLogger 同步收尾 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "同步收尾", mode: .perSession)
    logger.log(Data("Ruijie> ".utf8), direction: .rx, format: .ascii, timestamps: true)   // 开放行滞留缓冲
    logger.closeSessionSync()   // 返回即应已落盘(不 sleep)
    let f = try FileManager.default.contentsOfDirectory(atPath: dir.path).first!
    let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    check(text.contains("Ruijie>") && text.contains("⏎"), "同步收尾冲刷开放行")
    check(text.contains("会话结束"), "同步收尾写 footer")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "同步收尾", error.localizedDescription)
}

print("== SessionLogger U+FFFD 追加不覆盖 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "追加", mode: .perSession)
    // CR apply 模式: "abcdef\r" 后 cursor 回到行首; 再暂存一个 GBK 半字, 收尾时注入 U+FFFD
    logger.log(Data("abcdef\r".utf8), direction: .rx, format: .ascii, timestamps: false,
               decodeGBK: true, cr: .apply)
    logger.log(Data([0xD6]), direction: .rx, format: .ascii, timestamps: false,
               decodeGBK: true, cr: .apply)
    Thread.sleep(forTimeInterval: 0.6)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    let f = try FileManager.default.contentsOfDirectory(atPath: dir.path).first!
    let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    check(text.contains("abcdef\u{FFFD}"), "U+FFFD 追加在行尾不覆盖已有内容")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "U+FFFD 追加不覆盖", error.localizedDescription)
}

print("== SessionLogger banner 图例与 locale ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let loggerHex = SessionLogger()
    loggerHex.openSession(directory: dir, deviceName: "T", header: "图例",
                          mode: .perSession, template: "legend_hex",
                          format: .hex, timestamps: false)
    Thread.sleep(forTimeInterval: 0.3)
    loggerHex.closeSession()
    Thread.sleep(forTimeInterval: 0.3)
    let hexText = try String(contentsOf: dir.appendingPathComponent("legend_hex.log"), encoding: .utf8)
    check(hexText.contains("格式: 十六进制"), "banner 图例按实际格式生成(HEX)")

    let loggerRaw = SessionLogger()
    loggerRaw.openSession(directory: dir, deviceName: "T", header: "图例",
                          mode: .perSession, template: "legend_raw",
                          format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.3)
    loggerRaw.closeSession()
    Thread.sleep(forTimeInterval: 0.3)
    let rawText = try String(contentsOf: dir.appendingPathComponent("legend_raw.log"), encoding: .utf8)
    check(rawText.contains("纯文本原始流") && !rawText.contains("每行以 [时间] [方向] 开头"),
          "无时间戳模式 banner 不再宣称每行有前缀")
    check(SessionLogger.dayFormatter.locale?.identifier == "en_US_POSIX",
          "固定格式 formatter 使用 POSIX locale")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "banner 图例与 locale", error.localizedDescription)
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
    check(resolve("{device}_{seq}", "dev", "", 3) == "dev_3", "序号不补零", resolve("{device}_{seq}", "dev", "", 3))
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

    // 固定模板切割: 重名自动补 -2 序号
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
    check(files.contains("rotate_fixed.log") && files.contains("rotate_fixed-2.log"),
          "固定模板切割生成序号文件", files.joined())
    check(newURL?.lastPathComponent == "rotate_fixed-2.log", "切割回调返回新文件", newURL?.lastPathComponent ?? "nil")
    if let c1 = try? String(contentsOf: dir.appendingPathComponent("rotate_fixed.log"), encoding: .utf8),
       let c2 = try? String(contentsOf: dir.appendingPathComponent("rotate_fixed-2.log"), encoding: .utf8) {
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
    check(files2.contains("rot_1.log") && files2.contains("rot_2.log"),
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
        let banners = c.components(separatedBy: "BLE2TTY 会话日志").count - 1
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

print("== 日志 GBK 转码 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    // "宿州本部" 的 GBK 编码(真实设备主机名样本: 宿州本部1-10.34.240.11>)
    let gbk: [UInt8] = [0xCB, 0xDE, 0xD6, 0xDD, 0xB1, 0xBE, 0xB2, 0xBF]

    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "GBK 测试",
                       mode: .perSession, template: "gbk_compat")
    // 第一块以半个汉字(州的前导 0xD6)结尾, 验证跨包拼接
    logger.log(Data(gbk[0..<3]), direction: .rx, format: .ascii, timestamps: false, decodeGBK: true)
    logger.log(Data(gbk[3...]), direction: .rx, format: .ascii, timestamps: false, decodeGBK: true)
    logger.log(Data(">\r\n".utf8), direction: .rx, format: .ascii, timestamps: false, decodeGBK: true)
    // UTF-8 设备内容须原样通过(「你好」E4BD A0 / E5A5 BD)
    logger.log(Data("你好".utf8), direction: .rx, format: .ascii, timestamps: false, decodeGBK: true)
    // UTF-8 半个字符跨包: 「好」= E5 A5 BD, 拆成 E5 | A5 BD
    logger.log(Data([0xE5]), direction: .tx, format: .ascii, timestamps: false, decodeGBK: true)
    logger.log(Data([0xA5, 0xBD]), direction: .tx, format: .ascii, timestamps: false, decodeGBK: true)
    logger.log(Data("\r\n".utf8), direction: .tx, format: .ascii, timestamps: false, decodeGBK: true)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.5)

    let content = try? String(contentsOf: dir.appendingPathComponent("gbk_compat.log"), encoding: .utf8)
    check(content?.contains("宿州本部>") == true, "GBK 主机名转 UTF-8", content ?? "nil")
    check(content?.contains("你好") == true, "UTF-8 内容原样保留", content ?? "nil")
    check(content?.contains("好") == true, "UTF-8 半字跨包拼接", content ?? "nil")

    // 关闭转码: GBK 原始字节逐字节保留
    let logger2 = SessionLogger()
    logger2.openSession(directory: dir, deviceName: "T", header: "raw",
                        mode: .perSession, template: "gbk_raw")
    logger2.log(Data(gbk), direction: .rx, format: .ascii, timestamps: false, decodeGBK: false)
    logger2.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    if let raw = try? Data(contentsOf: dir.appendingPathComponent("gbk_raw.log")) {
        check(raw.contains(Data(gbk)), "关闭转码时 GBK 原始字节保留")
    } else {
        check(false, "关闭转码时 GBK 原始字节保留", "文件读取失败")
    }
    try? FileManager.default.removeItem(at: dir)
}

print("== 日志双份保存与 clean 过滤 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let rawDir = dir.appendingPathComponent("raw")

    /// raw 文件重组: 数据行均有 31 字节 "[yyyy-MM-dd HH:mm:ss.SSS] [RX] " 前缀;
    /// 结尾 " ⏎" 的换行是插入的(剔除), 其余换行来自线上(还原)
    func rebuildRaw(_ name: String) -> Data {
        guard let data = try? Data(contentsOf: rawDir.appendingPathComponent(name)) else { return Data() }
        var out = Data()
        var bannerSeen = 0
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = Data(slice)
            if bannerSeen < 2 {
                if line.starts(with: [UInt8](repeating: 0x3D, count: 8)) { bannerSeen += 1 }
                continue
            }
            if line.starts(with: Array("-----".utf8)) { break }  // footer
            if line.isEmpty { continue }                          // banner 后空行
            guard line.count >= 31, line.starts(with: [0x5B, 0x32]) else { continue }  // "[2"
            var payload = Data(line.dropFirst(31))
            if payload.count >= 4, Array(payload.suffix(4)) == [0x20, 0xE2, 0x8F, 0x8E] {
                payload.removeLast(4)
                out.append(payload)
            } else {
                out.append(payload)
                out.append(0x0A)
            }
        }
        return out
    }

    // ── A. 双份保存 + 过滤全开 + 同步切割 ──
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "双份测试",
                       mode: .perSession, template: "dual_{seq}", rawEnabled: true)
    let part1: [(LogDirection, [UInt8])] = [
        (.rx, Array("Ruijie>".utf8)),          // 开放行
        (.tx, Array("en".utf8)),               // 方向切换 → rx 行强制 ⏎
        (.tx, [0x7F]),                         // DEL 回删
        (.tx, Array("able\r\n".utf8)),       // BS 应用抹除 → "eable"
        (.rx, [0x1B]),                         // ANSI 跨包: ESC
        (.rx, [0x5B, 0x41]),                   //        "[A"
        (.rx, [0xCB, 0xDE, 0xD6, 0xDD]),       // GBK "宿州"
        (.rx, Array("\r\n".utf8)),
    ]
    for (d, bytes) in part1 {
        logger.log(Data(bytes), direction: d, format: .ascii, timestamps: true,
                   decodeGBK: true, stripANSI: true, cr: .strip, bs: .apply)
    }
    let stream1 = Data(part1.flatMap { $0.1 })
    logger.rotateSession { _ in }
    Thread.sleep(forTimeInterval: 0.4)
    let part2: [(LogDirection, [UInt8])] = [(.rx, Array("after\r\n".utf8))]
    for (d, bytes) in part2 {
        logger.log(Data(bytes), direction: d, format: .ascii, timestamps: true,
                   decodeGBK: true, stripANSI: true, cr: .strip, bs: .apply)
    }
    let stream2 = Data(part2.flatMap { $0.1 })
    Thread.sleep(forTimeInterval: 0.5)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.5)

    let rawFiles = (try? FileManager.default.contentsOfDirectory(atPath: rawDir.path)) ?? []
    check(rawFiles.contains("dual_1.raw.log") && rawFiles.contains("dual_2.raw.log"),
          "raw 子目录配对命名与同步切割", rawFiles.joined())
    check(rebuildRaw("dual_1.raw.log") == stream1, "raw 逐字节等于线上流(过滤全开)",
          "重组 \(rebuildRaw("dual_1.raw.log").count)/原 \(stream1.count) 字节")
    check(rebuildRaw("dual_2.raw.log") == stream2, "raw 切割后第二段逐字节一致")

    if let cleanData = try? Data(contentsOf: dir.appendingPathComponent("dual_1.log")),
       let cleanText = String(data: cleanData, encoding: .utf8) {
        check(cleanText.contains("Ruijie> ⏎"), "clean 方向切换强制断行标记", cleanText)
        check(cleanText.contains("[TX] eable"), "clean 退格应用抹除(DEL 回删)", cleanText)
        check(cleanText.contains("宿州"), "clean GBK 转码保留中文", cleanText)
        check(!cleanData.contains(0x1B), "clean ANSI 转义剥离(含跨包)")
        check(!cleanData.contains(0x0D), "clean CR 已去除")
    } else { check(false, "clean 文件读取", "dual_1.log") }

    // ── B. 退格三档 ──
    func runBS(_ template: String, _ bs: LogBSHandling) -> Data {
        let l = SessionLogger()
        l.openSession(directory: dir, deviceName: "T", header: "t", mode: .perSession, template: template)
        l.log(Data("lisy\u{08} \u{08}t\r\n".utf8), direction: .rx, format: .ascii, timestamps: false, bs: bs)
        Thread.sleep(forTimeInterval: 0.4)
        l.closeSession()
        Thread.sleep(forTimeInterval: 0.3)
        return (try? Data(contentsOf: dir.appendingPathComponent(template + ".log"))) ?? Data()
    }
    check(runBS("bs_keep", .keep).contains(0x08), "退格原样保留 0x08")
    let bsStrip = String(decoding: runBS("bs_strip", .strip), as: UTF8.self)
    check(bsStrip.contains("lisy t"), "退格删除控制字节", bsStrip)
    let bsApply = String(decoding: runBS("bs_apply", .apply), as: UTF8.self)
    check(bsApply.contains("list\r\n") && !bsApply.contains("lisy"), "退格应用抹除", bsApply)

    // ── C. CR 三档 ──
    func runCR(_ template: String, _ text: String, _ cr: LogCRHandling) -> Data {
        let l = SessionLogger()
        l.openSession(directory: dir, deviceName: "T", header: "t", mode: .perSession, template: template)
        l.log(Data(text.utf8), direction: .rx, format: .ascii, timestamps: false, cr: cr)
        Thread.sleep(forTimeInterval: 0.4)
        l.closeSession()
        Thread.sleep(forTimeInterval: 0.3)
        return (try? Data(contentsOf: dir.appendingPathComponent(template + ".log"))) ?? Data()
    }
    check(String(decoding: runCR("cr_keep", "a\r\nb\r\n", .keep), as: UTF8.self).contains("a\r\nb\r\n"),
          "CR 原样保留")
    let crStrip = String(decoding: runCR("cr_strip", "a\r\nb\r\n", .strip), as: UTF8.self)
    check(crStrip.contains("a\nb\n") && !crStrip.contains("\r"), "CR 去除", crStrip)
    let crApply = String(decoding: runCR("cr_apply", "10%\r99%\r\n", .apply), as: UTF8.self)
    check(crApply.contains("99%\n") && !crApply.contains("10%"), "CR 应用行内重绘", crApply)

    // ── D. raw 中途开关 ──
    let l2 = SessionLogger()
    l2.openSession(directory: dir, deviceName: "T", header: "t",
                   mode: .perSession, template: "toggle_{seq}", rawEnabled: false)
    l2.log(Data("x\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    Thread.sleep(forTimeInterval: 0.4)
    check(!FileManager.default.fileExists(atPath: rawDir.appendingPathComponent("toggle_1.raw.log").path),
          "raw 关闭时不建文件")
    l2.setRawEnabled(true)
    Thread.sleep(forTimeInterval: 0.4)
    l2.log(Data("y\r\n".utf8), direction: .rx, format: .ascii, timestamps: false)
    l2.closeSession()
    Thread.sleep(forTimeInterval: 0.4)
    let toggleRaw = try? Data(contentsOf: rawDir.appendingPathComponent("toggle_1.raw.log"))
    check(toggleRaw?.contains(Data("y\r\n".utf8)) == true && toggleRaw?.contains(Data("x\r\n".utf8)) == false,
          "raw 中途开启只含之后的数据")

    try? FileManager.default.removeItem(at: dir)
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

print("== LineAssembler OSC / 三字节序列 ==")
do {
    func B(_ s: String) -> Data { Data(s.utf8) }
    let BEL: UInt8 = 0x07, ESC: UInt8 = 0x1B, LF: UInt8 = 0x0A

    // OSC(窗口标题) BEL 终止: 整段吞掉, 标题文本不得入行
    var a = LineAssembler()
    check(a.feed([ESC] + B("]0;user@switch:~") + [BEL] + B("Switch#") + [LF]) == [B("Switch#")],
          "OSC(BEL 终止)整段过滤")

    // OSC ST(ESC \) 终止
    var b = LineAssembler()
    check(b.feed([ESC] + B("]0;title") + [ESC] + B("\\") + B("abc") + [LF]) == [B("abc")],
          "OSC(ST 终止)整段过滤")

    // OSC 内的 BEL 只作终止符, 不触发提示音
    var c = LineAssembler()
    var bells = 0
    c.onBell = { bells += 1 }
    _ = c.feed([ESC] + B("]0;t") + [BEL] + B("x") + [BEL, LF])
    check(bells == 1, "OSC 终止 BEL 不响铃, 内容后 BEL 正常响铃", "bells=\(bells)")

    // OSC 跨包: 半个序列暂存, 不泄漏内容
    var d = LineAssembler()
    _ = d.feed([ESC] + B("]0;ti"))
    check(d.feed(B("tle") + [BEL] + B("ok") + [LF]) == [B("ok")], "OSC 跨包过滤")

    // 三字节序列 ESC(0 字符集 / ESC#8: 末字节不得漏入文本
    var e = LineAssembler()
    check(e.feed([ESC] + B("(0") + B("hi") + [LF]) == [B("hi")], "ESC(0 三字节序列过滤")
    var f = LineAssembler()
    check(f.feed([ESC] + B("#8") + B("hi") + [LF]) == [B("hi")], "ESC#8 三字节序列过滤")
}

print("== CH9140Protocol 帧拆分(decodeFrames) ==")
do {
    let f86 = Data([0x86, 0x00, 0x09, 0x00, 0x00, 0xC2, 0x01, 0x00, 0x08, 0x01, 0x00, 0xCC])   // 115200 8N1
    let f88 = Data([0x88, 0x00, 0x03, 0x00, 0x01, 0x00, 0x01])                                  // 空闲状态

    // 粘连两帧一次通知: 两帧都应解出
    let (p1, r1) = CH9140Protocol.decodeFrames(f86 + f88)
    check(p1.count == 2 && r1.isEmpty, "粘连双帧全部解出", "packets=\(p1.count)")
    if case .serialParameters(let sp) = p1.first {
        check(sp.baudRate == 115200, "首帧为串口参数回包")
    } else { check(false, "首帧为串口参数回包") }
    if case .status = p1.last { check(true, "次帧为状态上报") } else { check(false, "次帧为状态上报") }

    // 噪声字节前缀: 逐字节重同步后帧仍可解出
    let (p2, r2) = CH9140Protocol.decodeFrames(Data([0x55, 0xAA]) + f86)
    check(p2.count == 1 && r2 == Data([0x55, 0xAA]), "噪声前缀重同步", "packets=\(p2.count) residue=\(HexUtil.hexString(r2))")

    // 截断半帧: 归入 residue, 不崩溃不误解
    let (p3, r3) = CH9140Protocol.decodeFrames(f86.prefix(8))
    check(p3.isEmpty && r3.count == 8, "截断半帧归入 residue")

    // 校验和错误的帧: 跳过坏帧后后续好帧仍解出
    var bad = f86; bad[bad.count - 1] ^= 0xFF
    let (p4, r4) = CH9140Protocol.decodeFrames(bad + f88)
    check(p4.count == 1 && !r4.isEmpty, "坏帧跳过, 后续好帧解出", "packets=\(p4.count)")
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

    // 最近连接的 MAC: 回填 / 持久化 / 重连保留
    let macUUID = UUID(uuidString: "8BE7B8EA-0000-0000-0000-000000000003")!
    s4.addRecentDevice(uuid: macUUID, name: "CH9140BLE2U")
    check(s4.recentDevices.first { $0.uuid == macUUID }?.macAddress == nil, "新记录初始无 MAC")
    s4.updateRecentDeviceMAC(macUUID, mac: "DC-04-5A-5E-12-5B")
    check(s4.recentDevices.first { $0.uuid == macUUID }?.macAddress == "DC-04-5A-5E-12-5B", "MAC 回填")
    check(SettingsStore(defaults: d).recentDevices.first { $0.uuid == macUUID }?.macAddress == "DC-04-5A-5E-12-5B",
          "MAC 随最近连接持久化")
    s4.updateRecentDeviceMAC(macUUID, mac: "DC-04-5A-5E-12-5B")
    check(s4.recentDevices.first { $0.uuid == macUUID }?.macAddress == "DC-04-5A-5E-12-5B"
          && s4.recentDevices[0].uuid == macUUID, "MAC 重复回填幂等不改排序")
    // 重连未解析到 MAC(传 nil)时保留历史缓存
    s4.addRecentDevice(uuid: macUUID, name: "CH9140BLE2U")
    check(s4.recentDevices[0].uuid == macUUID && s4.recentDevices[0].macAddress == "DC-04-5A-5E-12-5B",
          "重连未解析到 MAC 时保留历史缓存")
    // 旧持久化格式(无 macAddress 字段)可正常解码
    let legacy = #"[{"uuid":"8BE7B8EA-0000-0000-0000-000000000009","name":"OldDev","lastUsed":700000000}]"#
    d.set(legacy.data(using: .utf8)!, forKey: "CH9140Bridge.recentDevices")
    let s6 = SettingsStore(defaults: d)
    check(s6.recentDevices.count == 1 && s6.recentDevices[0].name == "OldDev" && s6.recentDevices[0].macAddress == nil,
          "旧持久化格式兼容(缺失 MAC 字段解码为 nil)")

    // MAC 归一化: 每两位用 - 分割, 大写
    check(DeviceMACResolver.formatMAC("DC:04:5A:5E:12:5B") == "DC-04-5A-5E-12-5B", "冒号 MAC 转横线大写")
    check(DeviceMACResolver.formatMAC("dc-04-5a-5e-12-5b") == "DC-04-5A-5E-12-5B", "横线小写归一")
    check(DeviceMACResolver.formatMAC("dc045a5e125b") == "DC-04-5A-5E-12-5B", "无分隔符补全")
    check(DeviceMACResolver.formatMAC("DC:04:5A") == nil, "位数不足拒绝")
    check(DeviceMACResolver.formatMAC("DC:04:5A:5E:12:5B!") == nil, "含杂字符拒绝")
    check(DeviceMACResolver.formatMAC("DC:04:5A:5E:12:ZZ") == nil, "非十六进制拒绝")

    // 整域清理
    UserDefaults().removePersistentDomain(forName: suiteName)
}

print("")
print("========================================")
print("通过 \(passed) 项, 失败 \(failed) 项")
print("========================================")
exit(failed == 0 ? 0 : 1)
