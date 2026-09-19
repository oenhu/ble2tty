//
//  BLE2TTYApp.swift
//  CH9140 蓝牙串口桥 - macOS App 入口
//

import SwiftUI
import CH9140Core

struct BLE2TTYApp: App {
    @StateObject private var model = BridgeModel()

    var body: some Scene {
        WindowGroup("BLE2TTY") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.ble)
                .environmentObject(model.port)
                .environmentObject(model.logger)
                .environmentObject(model.settings)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { model.startup() }
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("串口") {
                Button(model.ble.isScanning ? "停止扫描" : "开始扫描") { model.toggleScan() }
                    .keyboardShortcut("s", modifiers: [.command])
                Divider()
                Button("应用串口参数到芯片") { model.applySerialParameters() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!model.ble.isReady)
            }
            CommandMenu("日志") {
                Button("截断并新建日志文件") { model.rotateLog() }
                    .keyboardShortcut(model.settings.logRotateShortcutEnabled
                                      ? KeyboardShortcut("t", modifiers: [.command]) : nil)
                    .disabled(model.logger.currentFileURL == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model.settings)
                .environmentObject(model)
                .environmentObject(model.ble)
        }
    }
}
