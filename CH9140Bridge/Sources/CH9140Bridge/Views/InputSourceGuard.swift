//
//  InputSourceGuard.swift
//  输入法守卫: 终端输入区获得焦点时自动切换到英文(ASCII)键盘布局, 移开焦点后恢复
//
//  通过 Carbon TIS(Text Input Source)实现, 只影响键盘输入源, 不干扰系统其他设置。
//

import Foundation
import Carbon.HIToolbox

final class InputSourceGuard {

    static let shared = InputSourceGuard()

    /// 开关状态(由设置同步过来)
    private(set) var isEnabled = true
    private var savedSource: TISInputSource?
    private var active = false

    private init() {}

    /// 同步开关; 关闭时若正处于强制英文状态则立即恢复
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { leave() }
    }

    /// 输入区获得焦点
    func enter() {
        guard isEnabled, !active else { return }
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
            if Self.isASCIICapable(current) { return }   // 已是英文, 无需切换
            savedSource = current
        }
        if let ascii = Self.firstASCIICapableSource() {
            TISSelectInputSource(ascii)
            active = true
        }
    }

    /// 输入区失去焦点: 恢复之前的输入法
    func leave() {
        guard active else { return }
        if let saved = savedSource {
            TISSelectInputSource(saved)
        }
        savedSource = nil
        active = false
    }

    // MARK: - TIS 工具

    private static func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let ref = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
        else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ref).takeUnretainedValue())
    }

    private static func firstASCIICapableSource() -> TISInputSource? {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]
        else { return nil }
        // 键盘布局类别中第一个支持 ASCII 直输的(如 ABC/美式键盘)
        return list.first(where: isASCIICapable)
    }
}
