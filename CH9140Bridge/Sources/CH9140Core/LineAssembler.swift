//
//  LineAssembler.swift
//  串口字节流 -> 显示行 的装配器(纯逻辑, 可测试)
//
//  处理控制台回显中的控制字符:
//   - \r\n 或单独 \n  -> 成行
//   - 单独 \r        -> 行内重绘(清空当前残行, 如 Tab 补全后的提示符重画)
//   - \b (0x08)      -> 行内回删
//   - Bell (0x07)    -> 触发 onBell 回调
//   - ANSI CSI (ESC [ ... 最终字节) -> 过滤(颜色/光标控制序列)
//

import Foundation

public struct LineAssembler {

    public private(set) var pending = Data()
    private var sawCR = false
    /// ANSI 转义解析状态: none -> esc(收到 ESC) -> csi(收到 ESC [)
    private enum EscState { case none, esc, csi }
    private var escState: EscState = .none
    public var onBell: (() -> Void)?

    public init() {}

    /// 喂入数据, 返回本轮装配出的完整行(不含换行符)
    public mutating func feed(_ bytes: Data) -> [Data] {
        var lines: [Data] = []
        for b in bytes {
            switch escState {
            case .esc:
                // ESC 后只有 '[' 才进入 CSI 序列, 否则按两字节序列吞掉
                escState = (b == 0x5B) ? .csi : .none
                continue
            case .csi:
                // CSI: 跳过参数/中间字节直到最终字节 (0x40...0x7E)
                if (0x40...0x7E).contains(b) { escState = .none }
                continue
            case .none:
                break
            }
            switch b {
            case 0x1B:                      // ESC
                escState = .esc
            case 0x07:                      // Bell
                onBell?()
            case 0x0A:                      // LF: 成行
                lines.append(pending)
                pending.removeAll()
                sawCR = false
            case 0x0D:                      // CR: 等下一字节决定换行还是行内重绘
                sawCR = true
            case 0x08:                      // BS: 行内回删
                sawCR = false
                if !pending.isEmpty { pending.removeLast() }
            default:
                if sawCR {                  // 单独 CR + 非 LF: 行内重绘
                    pending.removeAll()
                    sawCR = false
                }
                pending.append(b)
            }
        }
        return lines
    }

    /// 空闲时取出残行(无换行的提示符等), 无残行返回 nil
    public mutating func flushPending() -> Data? {
        sawCR = false
        guard !pending.isEmpty else { return nil }
        let line = pending
        pending.removeAll()
        return line
    }

    public mutating func reset() {
        pending.removeAll()
        sawCR = false
        escState = .none
    }
}
