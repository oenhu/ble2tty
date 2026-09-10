//
//  HexUtil.swift
//  十六进制/字节工具
//

import Foundation

public enum HexUtil {
    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    /// Data -> "AA BB CC"
    /// 查表实现: 避免逐字节 String(format:) 的 locale 格式化开销(HEX 日志/HEX 显示是高频路径)
    public static func hexString(_ data: Data, separator: String = " ") -> String {
        if data.isEmpty { return "" }
        var out = String()
        out.reserveCapacity(data.count * (2 + separator.count))
        for (i, b) in data.enumerated() {
            if i > 0, !separator.isEmpty { out.append(separator) }
            out.append(hexDigits[Int(b >> 4)])
            out.append(hexDigits[Int(b & 0x0F)])
        }
        return out
    }

    /// "AA BB" / "AABB" / "aa-bb" -> Data, 非法输入返回 nil
    public static func data(fromHexString string: String) -> Data? {
        let cleaned = string
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
        guard !cleaned.isEmpty, cleaned.count % 2 == 0,
              cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// 尽量按 UTF-8 解码, 不可打印字符用 "." 代替(用于 HEX+ASCII 双栏显示)
    public static func printableASCII(_ data: Data) -> String {
        String(decoding: data.map { ($0 >= 0x20 && $0 < 0x7F) || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 ? $0 : UInt8(ascii: ".") },
               as: UTF8.self)
    }
}
