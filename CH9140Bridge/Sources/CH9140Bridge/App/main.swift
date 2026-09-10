//
//  main.swift
//  入口分流: 默认启动 SwiftUI GUI; 带 --cli 参数进入无界面桥接模式
//
//  CLI 模式与 GUI 使用同一个签名 Bundle, 因此继承 App 的蓝牙权限(TCC)。
//  用法:
//    CH9140Bridge.app/Contents/MacOS/CH9140Bridge --cli \
//        [--name CH9140BLE2U] [--baud 115200] [--port-name CH9140] [--timeout 45]
//

import Foundation
import CH9140Core

if CommandLine.arguments.contains("--cli") {
    CLIRunner.run()
} else {
    CH9140BridgeApp.main()
}
