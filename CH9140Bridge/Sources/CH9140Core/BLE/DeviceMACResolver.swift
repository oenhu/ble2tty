//
//  DeviceMACResolver.swift
//  解析已连接 BLE 设备的真实 MAC 地址
//
//  CoreBluetooth 不暴露 BLE 外设 MAC(CBPeripheral.identifier 是本机派生 UUID),
//  IOBluetooth 公共设备列表(paired/recent)只覆盖经典蓝牙;
//  macOS 系统蓝牙报告(system_profiler)在设备处于连接状态时可给出真实 MAC:
//  "device_connected" 数组以设备名为键, 内含 device_address。
//  查询为秒级外部进程, 仅在连接就绪时后台执行一次, 结果持久化到"最近连接"。
//

import Foundation

public enum DeviceMACResolver {

    /// 归一化 MAC 为 "XX-XX-XX-XX-XX-XX"(每两位一组用 - 分割, 大写)。
    /// 接受冒号/横线/无分隔与小写写法; 位数不足/含杂字符/非十六进制返回 nil。
    public static func formatMAC(_ raw: String) -> String? {
        let upper = raw.uppercased()
        let hex = upper.filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        // 过滤后的合法字符必须与剔除分隔符后的原文一致, 防止混入其他内容时恰好凑满 12 位
        guard upper.filter { $0 != ":" && $0 != "-" } == hex else { return nil }
        var groups: [Substring] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            groups.append(hex[i..<hex.index(i, offsetBy: 2)])
            i = hex.index(i, offsetBy: 2)
        }
        return groups.joined(separator: "-")
    }

    /// 查询系统已连接蓝牙设备中指定名称设备的 MAC(异步, 回调在主线程)。
    /// 仅在设备保持连接期间有效; 进程失败/未匹配/格式非法均回调 nil。
    public static func connectedDeviceMAC(name: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let mac = queryConnectedMAC(matching: name)
            DispatchQueue.main.async { completion(mac) }
        }
    }

    private static func queryConnectedMAC(matching name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPBluetoothDataType", "-json"]
        let out = Pipe()
        proc.standardOutput = out
        // stderr 不消费: 直接丢弃(若用 Pipe 而不读, 写满 64KB 后子进程阻塞)
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        // 兜底超时: system_profiler 异常挂起时主动终止, 防止读取永久阻塞
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: watchdog)
        // 必须先读再 waitUntilExit: 输出超过管道缓冲(64KB, 配对设备多的机器可达)时
        // 子进程阻塞在写、父进程阻塞在等退出, 顺序颠倒即死锁
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        guard proc.terminationStatus == 0 else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let report = (obj["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = report["device_connected"] as? [[String: Any]] else { return nil }
        // 元素形如 { "CH9140BLE2U": { "device_address": "DC:04:5A:5E:12:5B", ... } }
        for entry in connected {
            for (deviceName, info) in entry {
                guard deviceName.caseInsensitiveCompare(name) == .orderedSame,
                      let info = info as? [String: Any],
                      let addr = info["device_address"] as? String else { continue }
                if let mac = formatMAC(addr) { return mac }
            }
        }
        return nil
    }
}
