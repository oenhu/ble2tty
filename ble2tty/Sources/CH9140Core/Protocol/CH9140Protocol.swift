//
//  CH9140Protocol.swift
//  CH9140 蓝牙转串口芯片 GATT 配置通道(0xFFF3)协议编解码
//
//  协议参考 WCH 官方 iOS 库 (BleUartLib/iOS CH9140Lib) 与 CH9140DS1 数据手册:
//   - 下行 0x06: 配置串口参数(波特率/数据位/停止位/校验), 芯片回包首字节 0x86
//   - 下行 0x07: 配置流控与 MODEM 输出(DTR/RTS),      芯片回包首字节 0x87
//   - 上行 0x88: 芯片主动上报串口发送缓冲区状态与 MODEM 输入状态(CTS/DSR/RI/DCD)
//   - 校验和: 从第 4 个字节(下标 3)起所有字节之和取低 8 位
//

import Foundation

// MARK: - GATT UUID (CH9140DS1 6.1)

public enum CH9140UUID {
    public static let service             = "FFF0" // 透传服务
    public static let readCharacteristic  = "FFF1" // 通知: 芯片串口 RX -> 主机
    public static let writeCharacteristic = "FFF2" // 只写: 主机 -> 芯片串口 TX
    public static let configCharacteristic = "FFF3" // 读写/通知: 配置通道
}

// MARK: - 数据模型

/// 串口参数
public struct SerialParameters: Equatable, Codable, Sendable {
    /// 波特率 300 ~ 1_000_000
    public var baudRate: UInt32
    /// 数据位 5...8
    public var dataBits: UInt8
    /// 停止位 1 或 2
    public var stopBits: UInt8
    /// 校验位 0=无 1=奇 2=偶 3=标志位(Mark) 4=空白位(Space)
    public var parity: UInt8

    public init(baudRate: UInt32 = 9600, dataBits: UInt8 = 8, stopBits: UInt8 = 1, parity: UInt8 = 0) {
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.stopBits = stopBits
        self.parity   = parity
    }

    public static let `default` = SerialParameters()
}

/// MODEM 输出与流控配置
public struct ModemLines: Equatable, Codable, Sendable {
    /// 是否开启硬件流控(CTS/RTS)
    public var flowControl: Bool
    /// DTR 输出电平 0/1
    public var dtr: UInt8
    /// RTS 输出电平 0/1
    public var rts: UInt8

    public init(flowControl: Bool = false, dtr: UInt8 = 0, rts: UInt8 = 0) {
        self.flowControl = flowControl
        self.dtr = dtr
        self.rts = rts
    }
}

/// 0x88 上报的串口与 MODEM 输入状态
public struct ModemStatus: Equatable, Sendable {
    /// 芯片串口发送缓冲区已空
    public var uartSendEmpty: Bool = false
    /// MODEM 输入状态发生变化
    public var modemChanged: Bool = false
    /// 芯片串口发送缓冲区已满(主机应暂停写入)
    public var uartSendFull: Bool = false

    public var cts: Bool = false
    public var dsr: Bool = false
    public var ri:  Bool = false
    public var dcd: Bool = false

    public init() {}
}

/// 配置通道(FFF3)上收到的报文
public enum ConfigPacket: Equatable, Sendable {
    /// 0x86 串口参数回包
    case serialParameters(SerialParameters)
    /// 0x87 流控/MODEM 回包
    case modemLines(ModemLines)
    /// 0x88 状态上报
    case status(ModemStatus)
}

// MARK: - 编解码

public enum CH9140Protocol {

    /// 校验和: 所有字节之和取低 8 位
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    /// 编码"配置串口参数"指令 (下行 0x06)
    public static func encodeSerialParameters(_ p: SerialParameters) -> Data {
        var data = Data([0x06, 0x00, 0x09, 0x00])
        let baud = p.baudRate.littleEndian
        withUnsafeBytes(of: baud) { data.append(contentsOf: $0) }
        data.append(contentsOf: [p.dataBits, p.stopBits, p.parity])
        data.append(checksum(data.dropFirst(3)))
        return data
    }

    /// 编码"配置流控及 MODEM"指令 (下行 0x07)
    public static func encodeModemLines(_ m: ModemLines) -> Data {
        var data = Data([0x07, 0x00, 0x05, 0x00,
                         m.flowControl ? 1 : 0, m.dtr, m.rts])
        data.append(checksum(data.dropFirst(3)))
        return data
    }

    /// 解码配置通道上行的报文 (0x86 / 0x87 / 0x88), 校验失败或无法识别返回 nil
    public static func decode(_ data: Data) -> ConfigPacket? {
        let b = [UInt8](data)
        guard b.count >= 5 else { return nil }
        let chk = checksum(b[3..<(b.count - 1)])
        guard chk == b[b.count - 1] else { return nil }

        switch b[0] {
        case 0x86:
            guard b.count >= 12 else { return nil }
            let baud = UInt32(b[4])
                     | UInt32(b[5]) << 8
                     | UInt32(b[6]) << 16
                     | UInt32(b[7]) << 24
            return .serialParameters(SerialParameters(baudRate: baud,
                                                      dataBits: b[8],
                                                      stopBits: b[9],
                                                      parity: b[10]))
        case 0x87:
            guard b.count >= 8 else { return nil }
            return .modemLines(ModemLines(flowControl: b[4] != 0, dtr: b[5], rts: b[6]))
        case 0x88:
            guard b.count >= 7 else { return nil }
            var s = ModemStatus()
            s.uartSendEmpty = b[4] & 0x01 != 0
            s.modemChanged  = b[4] & 0x02 != 0
            s.uartSendFull  = b[4] & 0x04 != 0
            s.cts = b[5] & 0x10 != 0
            s.dsr = b[5] & 0x20 != 0
            s.ri  = b[5] & 0x40 != 0
            s.dcd = b[5] & 0x80 != 0
            return .status(s)
        default:
            return nil
        }
    }

    /// 已知指令的整帧长度(命令字 + 3 字节头 + 负载 + 校验和)
    private static let frameLengths: [UInt8: Int] = [0x86: 12, 0x87: 8, 0x88: 7]

    /// 拆分解码配置通道上行字节流: 容忍一次通知粘连多帧或夹带噪声字节。
    /// 逐帧独立校验; 无法识别的字节归入 residue 交调用方记日志, 不影响后续帧解析。
    public static func decodeFrames(_ data: Data) -> (packets: [ConfigPacket], residue: Data) {
        let b = [UInt8](data)
        var packets: [ConfigPacket] = []
        var residue = Data()
        var i = 0
        while i < b.count {
            guard let len = frameLengths[b[i]] else {
                residue.append(b[i]); i += 1; continue          // 未知命令字: 逐字节重同步
            }
            guard i + len <= b.count else {
                residue.append(contentsOf: b[i...])             // 截断半帧(固件分包, 下一通知无法续接, 丢弃)
                break
            }
            if let pkt = decode(Data(b[i..<(i + len)])) {
                packets.append(pkt); i += len
            } else {
                residue.append(b[i]); i += 1                    // 校验失败: 逐字节重同步
            }
        }
        return (packets, residue)
    }
}
