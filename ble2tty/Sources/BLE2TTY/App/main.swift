//
//  main.swift
//  入口分流: 默认启动 SwiftUI GUI; 带 --cli 参数进入无界面桥接模式
//
//  CLI 模式与 GUI 使用同一个签名 Bundle, 因此继承 App 的蓝牙权限(TCC)。
//  用法:
//    BLE2TTY.app/Contents/MacOS/BLE2TTY --cli \
//        [--name CH9140BLE2U] [--baud 115200] [--port-name CH9140] [--timeout 45]
//        [--uuid 53ECEF71-...]   多块同名芯片同场时按 UUID 直连(系统已缓存的设备)
//  退出: Ctrl+C / SIGTERM 均会清理虚拟串口符号链接后退出。
//

import Foundation
import CH9140Core

if CommandLine.arguments.contains("--cli") {
    CLIRunner.run()
} else {
    BLE2TTYApp.main()
}
