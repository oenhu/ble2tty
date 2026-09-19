//
//  CLIRunner.swift
//  无界面桥接模式: 扫描 -> 连接 -> 下发串口参数 -> 创建虚拟串口 -> 双向透传
//

import Foundation
import CH9140Core

enum CLIRunner {

    private final class StateBox {
        var rxBytes = 0        // 仅主线程读写
        /// poll 线程写 / 主线程读, 加锁保护
        private let txLock = NSLock()
        private var _txBytes = 0
        var txBytes: Int {
            get { txLock.lock(); defer { txLock.unlock() }; return _txBytes }
            set { txLock.lock(); _txBytes = newValue; txLock.unlock() }
        }
        var connecting = false
        var ready = false
    }

    static func run() -> Never {
        var name = "CH9140BLE2U"
        var baud: UInt32 = 115200
        var portName = "CH9140"
        var timeout: Double = 45
        var uuidArg: UUID? = nil

        var args = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--cli" }
        var i = 0
        while i < args.count {
            let key = args[i]
            let value: String? = (i + 1 < args.count) ? args[i + 1] : nil
            switch (key, value) {
            case ("--name", let v?):       name = v;                              i += 2
            case ("--baud", let v?):       baud = UInt32(v) ?? 115200;            i += 2
            case ("--port-name", let v?):  portName = v;                          i += 2
            case ("--timeout", let v?):    timeout = Double(v) ?? 45;             i += 2
            case ("--uuid", let v?):
                guard let u = UUID(uuidString: v) else {
                    print("[CLI] --uuid 参数不是合法 UUID: \(v)")
                    exit(64)   // EX_USAGE
                }
                uuidArg = u;                                                      i += 2
            default: i += 1
            }
        }
        args.removeAll()

        let ble = BLEManager()
        let port = VirtualSerialPort()
        let state = StateBox()
        let start = Date()

        func say(_ s: String) { print(s); fflush(stdout) }

        say("[CLI] 无界面桥接模式 目标设备=\(uuidArg?.uuidString ?? name) 波特率=\(baud)")

        // 优雅退出: SIGINT/SIGTERM 时清理虚拟串口符号链接, 不残留失效 cu.* 路径
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigInt.setEventHandler {
            say("[CLI] 收到 SIGINT, 清理退出")
            port.close()
            exit(130)
        }
        sigInt.resume()
        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigTerm.setEventHandler {
            say("[CLI] 收到 SIGTERM, 清理退出")
            port.close()
            exit(0)
        }
        sigTerm.resume()

        // 发起一次连接尝试: 指定 --uuid 时直连(多块同名 CH9140 同场必备), 否则扫描按名匹配
        func beginAttempt() {
            if let u = uuidArg {
                state.connecting = true
                say("[CLI] 按 UUID 直连 \(u.uuidString) …")
                ble.connect(uuid: u, name: name)
            } else {
                ble.startScan(showAll: false)
            }
        }

        ble.onLog  = { say("[BLE] \($0)") }
        port.onLog = { say("[PTY] \($0)") }

        // 芯片 -> 虚拟串口
        ble.onReceive = { data in
            state.rxBytes += data.count
            port.writeToPort(data)
            say("[RX \(data.count)B] \(String(decoding: data, as: UTF8.self))")
        }

        // 虚拟串口 -> 芯片
        port.onDataFromPort = { data in
            state.txBytes += data.count
            ble.send(data)
        }

        // 串口工具设置波特率 -> 自动同步给芯片(0xFFF3 / 0x06)
        port.onBaudChange = { params in
            say("[PTY] 串口工具设置参数 -> \(params.baudRate) bps \(params.dataBits) 数据位 \(params.stopBits) 停止位 校验 \(params.parity), 同步芯片…")
            ble.applySerialParameters(params) { ok, info in
                say("[BLE] 跟随同步结果: \(ok ? "成功" : "失败")(\(info))")
            }
        }

        ble.onConnectionChange = { st in
            switch st {
            case .ready:
                // 连接就绪: 顺带解析设备真实 MAC(CoreBluetooth 不提供)
                DeviceMACResolver.connectedDeviceMAC(name: ble.connectedDeviceName) { mac in
                    if let mac { say("[BLE] 设备 MAC: \(mac)") }
                }
                // 连接就绪: 先下发目标串口参数, 再创建虚拟串口
                let p = SerialParameters(baudRate: baud, dataBits: 8, stopBits: 1, parity: 0)
                ble.applySerialParameters(p) { ok, info in
                    say("[BLE] 下发串口参数 \(baud) 8N1: \(ok ? "成功" : "失败")(\(info))")
                    ble.applyModemLines(ModemLines(flowControl: false, dtr: 0, rts: 0)) { ok2, info2 in
                        say("[BLE] 关闭流控: \(ok2 ? "成功" : "失败")(\(info2))")
                    }
                    do {
                        let link = try port.open(name: portName)
                        // open() 的"虚拟串口已创建"日志经主队列异步投递,
                        // CLI_READY 也排队到其后, 避免就绪行出现在创建日志之前的误导顺序
                        DispatchQueue.main.async {
                            say("CLI_READY port=\(link) compat=\(port.compatLinkPath)")
                            state.ready = true
                        }
                    } catch {
                        say("[CLI] 创建虚拟串口失败: \(error.localizedDescription)")
                        exit(3)
                    }
                }
            case .failed(let m):
                say("[CLI] 连接失败: \(m)")
                // 无人值守场景: 总超时预算内 2 秒后重试, 一次瞬时失败不杀死桥接
                if Date().timeIntervalSince(start) + 2 < timeout {
                    state.connecting = false
                    say("[CLI] 2 秒后重试…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        // 扫描轮询可能已先行发起新尝试, 避免重复
                        if !state.ready && !state.connecting { beginAttempt() }
                    }
                } else {
                    exit(2)
                }
            case .disconnected:
                // CLI 不做自动重连: 连接断开(无论是否已就绪)即收尾退出,
                // 清理虚拟串口符号链接, 避免进程变僵尸/残留链接
                say("[CLI] 连接已断开, 退出")
                port.close()
                exit(4)
            default:
                break
            }
        }

        // 开始首次连接尝试
        beginAttempt()

        // 扫描/连接状态机轮询
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if state.ready || state.connecting { return }
            if Date().timeIntervalSince(start) > timeout {
                say("[CLI] 超时: \(Int(timeout))s 内未找到/未连上 \(name)")
                exit(2)
            }
            if let dev = ble.devices.first(where: {
                $0.name.localizedCaseInsensitiveContains(name)
            }) {
                state.connecting = true
                ble.stopScan()
                say("[CLI] 发现设备 \(dev.name) RSSI=\(dev.rssi) dBm, 连接中…")
                ble.connect(dev)
            }
        }

        // 每 10s 打印字节统计
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            if state.ready {
                say("[CLI] 统计: 芯片->串口 \(state.rxBytes)B / 串口->芯片 \(state.txBytes)B")
            }
        }

        RunLoop.main.run()
        fatalError("unreachable")
    }
}
