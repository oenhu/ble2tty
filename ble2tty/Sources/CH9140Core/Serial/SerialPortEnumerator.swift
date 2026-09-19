//
//  SerialPortEnumerator.swift
//  枚举系统中的有线串口设备(USB 转串口适配器等)
//
//  走 IOKit 的 IOSerialBSDClient 服务: 能拿到 callout 设备路径(/dev/cu.*)
//  与 USB Product Name 友好名(如 "USB2.0-Serial" / "FT231X USB UART"),
//  比直接 glob /dev/cu.* 体验好(蓝牙/console/debug 等伪设备天然被过滤)。
//

import Foundation
import IOKit
import IOKit.serial

/// 一个有线串口设备
public struct SerialPortInfo: Identifiable, Equatable, Sendable {
    /// callout 设备路径(/dev/cu.*), 打开串口用它
    public let path: String
    /// tty 设备路径(/dev/tty.*)
    public let ttyPath: String
    /// 显示名(USB Product Name, 拿不到时回退 baseName)
    public let name: String
    /// IOTTYBaseName(驱动名, 如 usbserial / SLAB_USBtoUART / wch)
    public let baseName: String

    public var id: String { path }

    public init(path: String, ttyPath: String, name: String, baseName: String) {
        self.path = path
        self.ttyPath = ttyPath
        self.name = name
        self.baseName = baseName
    }
}

public enum SerialPortEnumerator {

    /// 列出当前系统全部有线串口(按路径排序; 无设备时返回空数组)
    public static func listPorts() -> [SerialPortInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(kIOSerialBSDServiceValue),
            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [SerialPortInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let info = portInfo(from: service) { result.append(info) }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func portInfo(from service: io_object_t) -> SerialPortInfo? {
        func str(_ key: String, from obj: io_object_t) -> String? {
            IORegistryEntryCreateCFProperty(obj, key as CFString,
                                            kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
        }
        guard let callout = str(kIOCalloutDeviceKey, from: service) else { return nil }
        let tty = str(kIOTTYDeviceKey, from: service) ?? callout
        let base = str(kIOTTYBaseNameKey, from: service) ?? "serial"
        // 友好名: USB Product Name 一般在父节点(USB interface)上
        var product: String?
        var parent: io_object_t = 0
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 {
            product = str("USB Product Name", from: parent)
            IOObjectRelease(parent)
        }
        let name = (product?.isEmpty == false) ? product! : base
        return SerialPortInfo(path: callout, ttyPath: tty, name: name, baseName: base)
    }
}
