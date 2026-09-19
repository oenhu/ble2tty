# ISSUE: 纯文本日志 TX 记录"隐形"并污染 RX 行

| 项 | 值 |
|---|---|
| 严重度 | 中(数据未丢, 但日志无法按行解析方向, TX 看似丢失) |
| 状态 | 待修复(根因已定位, 方案见 §6) |
| 影响版本 | v1.0.5 build 12(2026-09-14 12:00 构建, 与当前源码一致, 已核对) |
| 首次报告 | 测试报告-2026-09-14.md 问题① |
| 二次复现 | 2026-09-14 16:12–16:46 会话, 锐捷 EG2000CE @9600(本文 §3 证据) |
| 涉及文件 | `CH9140Bridge/Sources/CH9140Core/Logging/SessionLogger.swift` |

---

## 1. 一句话概述

纯文本(ASCII)+时间戳日志模式下, RX/TX 两个方向共用同一文件流, 但各自独立维护"是否在行首"标志; 当某方向的数据不带 `\n`(无换行提示符、单字节回车、粘贴片段)使物理行处于"开放"状态时, 另一方向的写入**无前缀直接拼进同一物理行**——TX 字节其实在文件里, 但无 `[TX]` 标记、无独立行, 日志无法按行解析方向。

## 2. 期望行为 vs 实际行为

**期望**: 每个含数据的物理行都以 `[时间] [方向] ` 前缀开头; `grep "\[TX\]"` 能找到全部 TX 记录; 一行只含一个方向的数据。

**实际**: TX 记录大量缺失前缀, 与 RX 数据混在同一物理行, 形如"设备回显重复"。

## 3. 现象与证据

证据文件: `~/Documents/CH9140Logs/2026-09-14/CH9140_CH9140BLE2U_20260914_16123301.log`
(2026-09-14 16:12 连接锐捷路由器 @9600 的会话; 以下均为 `xxd` 级原始字节)

整个会话实际 TX 事件超过 10 次(键入 en/多次回车/show clock/show version/两次多行粘贴),
但 `grep -c "\[TX\]"` 只有 **3**。典型污染行:

```
[2026-09-14 16:17:18.365] [TX] en[2026-09-14 16:17:18.447] [RX] \r\r\n
        ↑ TX "en" 无换行结尾, 下一条 RX 记录被粘到同一物理行

...Press RETURN to get started\r\r\nshow clock\r[2026-09-14 16:43:04.617] [RX] \r\r\n
        ↑ TX "show clock\r" 零前缀, 裸贴在 RX 数据之后, 看似设备回显

...Press RETURN to get started\r\r\nshow clock\n[2026-09-14 16:44:56.853] [RX] \r\r\n
        ↑ 又一次裸 TX(且字节为 0x0A, 见附录 A)

[2026-09-14 16:46:51.429] [TX] show clock\n[2026-09-14 16:46:51.429] [TX] show version[2026-09-14 16:46:51.532] [RX] \r\r\n
        ↑ 多行粘贴的 TX; 末段无换行, 下一条 RX 被粘住

行间还散落完全孤立的 \r(回车键的 TX 字节), 无任何方向标记
```

同一行内 RX/TX 时间戳交错后, 日志时间序也无法再用于复盘"何时发了什么"——
本次会话中多次出现"命令回显与输出相隔 2–5 分钟"的假象, 即因 TX 不可见而无法解释
(另有主线程繁忙导致时间戳滞后的叠加因素, 见附录 B)。

## 4. 复现步骤

1. 设置: 日志格式 = 纯文本, 时间戳 = 开, 记录发送数据 = 开(默认即此组合)
2. 连接任意设备, 打开"终端"页(或用任意串口工具经虚拟串口)
3. 等设备给出**不带换行的提示符**(如 `Ruijie> ` / `Switch# `)——此时 RX 物理行处于开放状态
4. 发送任意数据: 敲几个字符 / 按一次回车 / 粘贴一行文本
5. 检查日志文件:
   - 该次 TX 要么完全没有 `[TX]` 前缀(裸字节贴在上一条 RX 行尾), 要么把下一条 RX 记录粘在自己行尾
   - `grep -c "\[TX\]"` 远小于实际发送次数

确定性验证命令(修复前):

```zsh
L=~/Documents/CH9140Logs/2026-09-14/CH9140_CH9140BLE2U_20260914_16123301.log
grep -c "\[TX\]" "$L"                       # 3 (实际发送 10+ 次)
awk '!/^\[/ && NF' "$L" | head             # 存在裸数据行(无前缀), 修复后应为空
grep -n "\[TX\].*\[RX\]" "$L"              # 一行内含两个方向前缀, 修复后应为空
```

## 5. 根因分析

`Sources/CH9140Core/Logging/SessionLogger.swift`:

- L43–44: `rxAtLineStart` / `txAtLineStart` **两个独立标志**, 注释自述"只在行首插入时间戳前缀, 保证字节精确"
- L220–258 `log(_:direction:format:timestamps:)` 的 `.ascii` + `timestamps` 分支:
  写入时按**本方向**的标志决定是否插 `[时间] [方向] ` 前缀; 数据含 `0x0A` 才把本方向标志重置为"行首"

机制走查(以 §3 第二行为例):

```
时刻1  RX "Press RETURN to get started\r\r\n" → 该 chunk 以 \n 结束 → rxAtLineStart=true
时刻2  TX "show clock\r"   → txAtLineStart=false(上一次 TX 未以 \n 结尾)
                              → 不插任何前缀, 裸字节直接写入文件
                              → 文件物理行 = "[..] [RX] ...started\r\r\n" + "show clock\r"
                              ↑ 注: RX 的 \n 已在文件中, 所以 "show clock\r" 处在新物理行行首,
                                但 TX 自己的标志说"不在行首"——标志与物理行位置脱节
时刻3  RX "\r\r\n"          → rxAtLineStart=true → 插前缀 → 前缀出现在物理行中间
                              → "[..] [RX] \r\r\n" 接在 "show clock\r" 之后
```

本质矛盾: **"是否行首"是文件流的属性, 而代码把它当成了每个方向的私有属性**。
设计初衷"字节精确写入"在插入前缀的那一刻就已不成立(前缀本身改变了流),
代价却是丢掉了日志最重要的属性——每行可解析出方向与时间。

## 6. 解决方案(推荐)

### 6.1 设计决策

把"行首"状态从**每方向各一份**改为**文件流全局一份**, 并确立不变式:

> **不变式**: 纯文本+时间戳模式下, 每个含数据的物理行有且仅有一个 `[时间] [方向] ` 前缀;
> 一行只含一个方向的字节。

方向切换时若上一行未闭合(无 `\n`), 先补一个**带可见标记的强制断行**再开新行。
强制断行标记用 `⏎`(U+23CE), 含义"此行未以线上换行符结束, 因方向切换/会话收尾被人为断行",
并在文件 banner 中写明图例。

### 6.2 为什么不选其他方案

| 方案 | 否决理由 |
|---|---|
| A. 维持现状(方向各自判行首) | 即本 bug |
| B. 每块数据强制独立一行(同 HEX 模式) | 9600 波特下 RX 以 ~64B BLE 块到达, 一行设备输出被切成 8+ 个带前缀的碎片行, 可读性崩塌; 当前"只在行首插前缀"正是为避免此问题 |
| C. 每方向各自缓冲, 凑满一行才落盘 | 无 `\n` 的提示符(如 `Ruijie> `)会滞留缓冲区, 落盘时间严重滞后, 日志时间序失真; 进程异常退出还会丢尾部数据 |
| D. 保持"字节精确"不加任何标记 | 前缀本身就破坏字节精确, 该目标在此模式从来未达成; 需要字节级重建应使用 HEX 模式(每块独立成行带前缀, 天然精确) |

修复只改变日志文件的落盘格式, 不改变线上数据; HEX / HEX+文本 / 无时间戳原始模式行为完全不变
(无时间戳模式本就是无标注原始流, 不承诺方向可解析)。

### 6.3 具体补丁(SessionLogger.swift)

**(1) L43–44 成员变量替换**:

```swift
// 改前
private var rxAtLineStart = true
private var txAtLineStart = true

// 改后: "行首"是文件流的属性, 全局只维护一份
private var lineAtStart = true
/// 当前开放物理行所属方向(仅 lineAtStart == false 时有意义)
private var lineDirection: LogDirection? = nil
```

**(2) L173–174 openFileLocked 复位逻辑同步替换**:

```swift
self.lineAtStart = true
self.lineDirection = nil
```

**(3) L234–258 `.ascii` + `timestamps` 分支重写**:

```swift
case .ascii:
    // 纯文本: 只在行首插入时间戳前缀; 方向切换时未闭合的行先补 ⏎ 强制断行,
    // 保证每个物理行只含一个方向且行首必有前缀(不变式见文件 banner 图例)
    if timestamps {
        let prefix = Data("[\(Self.lineStampFormatter.string(from: Date()))] [\(direction.rawValue)] ".utf8)
        var rest = data[...]
        while !rest.isEmpty {
            if !self.lineAtStart, let lineDir = self.lineDirection, lineDir != direction {
                out.append(Data(" ⏎\n".utf8))      // 方向切换: 强制闭合上一行
                self.lineAtStart = true
                self.lineDirection = nil
            }
            if self.lineAtStart {
                out.append(prefix)
                self.lineAtStart = false
                self.lineDirection = direction
            }
            if let nl = rest.firstIndex(of: 0x0A) {
                out.append(rest[...nl])
                rest = rest[rest.index(after: nl)...]
                self.lineAtStart = true
                self.lineDirection = nil
            } else {
                out.append(rest)
                rest = rest[rest.endIndex...]
            }
        }
    } else {
        out.append(data)
    }
```

**(4) closeLocked(L194 起): 会话收尾时闭合未完成的行**(放在写 footer 之前):

```swift
private func closeLocked() {
    if let h = handle {
        if !self.lineAtStart {                    // 仅 ASCII+时间戳路径会置 false, 其他模式恒 true 不受影响
            h.write(Data(" ⏎\n".utf8))
            self.lineAtStart = true
            self.lineDirection = nil
        }
        let footer = "\n----- 会话结束 \(Self.lineStampFormatter.string(from: Date())) -----\n"
        h.write(Data(footer.utf8))
        try? h.close()
    }
    handle = nil
    ...
}
```

**(5) openFileLocked 的 banner 增加格式图例**(L177 附近 bannerText 内追加):

```
 格式: 每行以 [时间] [方向] 开头(RX=芯片→主机, TX=主机→芯片);
       行尾 "⏎" 表示该行无线上换行符, 因方向切换或会话收尾被强制断行。
```

### 6.4 修复后效果(§3 同会话的重放)

```
[2026-09-14 16:42:33.718] [RX] Press RETURN to get started ⏎
[2026-09-14 16:42:48.xxx] [TX] show clock\r ⏎
[2026-09-14 16:43:04.617] [RX] \r\r\n
[2026-09-14 16:43:04.617] [RX] Press RETURN to get started ⏎
[2026-09-14 16:43:30.xxx] [TX] show clock\n
[2026-09-14 16:46:51.429] [TX] show clock\n
[2026-09-14 16:46:51.429] [TX] show version ⏎
[2026-09-14 16:46:51.532] [RX] \r\r\n
```

每次 TX 都有独立带前缀的行; `awk '!/^\[/ && NF'` 除 banner/footer 外为空;
`grep -c "\[TX\]"` 与实际发送次数一致。

## 7. 测试方案

### 7.1 自检(CH9140SelfTest, 风格参照 main.swift L153–177)

```swift
print("== SessionLogger TX/RX 行隔离 ==")
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("CH9140SelfTest-\(UUID().uuidString)")
    let logger = SessionLogger()
    logger.openSession(directory: dir, deviceName: "T", header: "行隔离")
    // 复现序列: RX 开放行(无 \n) → TX 无 \n → RX 回显
    logger.log(Data("Ruijie> ".utf8),      direction: .rx, format: .ascii, timestamps: true)
    logger.log(Data("show clock\r".utf8),  direction: .tx, format: .ascii, timestamps: true)
    logger.log(Data("16:30:36 UTC\r\n".utf8), direction: .rx, format: .ascii, timestamps: true)
    logger.log(Data("abc\r".utf8),         direction: .tx, format: .ascii, timestamps: true)
    logger.closeSession()
    Thread.sleep(forTimeInterval: 0.8)

    let f = try FileManager.default.contentsOfDirectory(atPath: dir.path).first!
    let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
    let dataLines = text.components(separatedBy: "\n")
        .filter { !$0.isEmpty && !$0.hasPrefix("=") && !$0.hasPrefix(" ")
                  && !$0.hasPrefix("-----") && $0 != "⏎" }
    let allPrefixed = dataLines.allSatisfy {
        $0.hasPrefix("[") && ($0.contains("] [RX] ") || $0.contains("] [TX] ")) }
    check(allPrefixed, "每个数据行均有方向前缀")
    check(text.contains("[TX] show clock"), "无换行 TX 有独立行与前缀")
    check(!text.contains("show clock\r["), "无跨方向粘连")
    check(text.contains("⏎"), "强制断行有可见标记")
    try? FileManager.default.removeItem(at: dir)
} catch {
    check(false, "TX/RX 行隔离", error.localizedDescription)
}
```

(注: 上例 banner 行以空格/`=` 开头, 过滤条件与现自检对 banner 的认知一致;
⏎ 强制断行标记附在被闭合行的行尾, 不会单独成行, `!= "⏎"` 仅为防御。)

### 7.2 真机回归

1. 按 §4 复现步骤操作 → 确认每次 TX 均有 `[TX]` 前缀行, `grep -c "\[TX\]"` 与实际发送次数一致
2. 无换行提示符后发送 → 上一 RX 行尾出现 `⏎`, TX 独立成行
3. 多行粘贴 → 每行均有前缀; 末行无 `\n` 时带 `⏎`
4. 截断并新建 / 结束日志 → 旧文件未闭合行已补 `⏎`, 新文件 banner 含格式图例
5. HEX、HEX+文本、无时间戳三种模式日志与修复前逐字节一致(回归基线)
6. `swift run CH9140SelfTest` 全绿

## 8. 兼容性与风险

- **格式变化仅限纯文本+时间戳模式**; 其余三种组合(HEX / HEX+文本 / 无时间戳原始流)输出不变
- 对下游消费者是**收紧而非破坏**: 凡按 `^\[.*\] \[(RX|TX)\] ` 解析的工具, 修复后结果更全更准;
  不存在"依赖 TX 无前缀"的合法消费者(那是 bug 本身)
- `⏎` 为 UTF-8 三字节(U+23CE); 日志本就可能含设备输出的中文 UTF-8, 无新增编码风险
- 历史日志文件不受影响(只改变新写入内容)
- 高频双向交替(逐字节交互)会产生较多 `⏎` 断行——行数增多但每行语义完整, 优于现状的不可解析
- 已知小瑕疵: 会话在开放行状态下结束时, footer 前会因 `⏎\n` + footer 自带 `\n` 出现一个空行(cosmetic)

---

## 附录 A: 关联发现——终端粘贴不转换 `\n`→`\r`(更正此前测试结论)

证据: §3 日志中 `[TX] show clock\n`(0x0A 原样出现在 TX 流)。
SwiftTerm 的 `paste(_:)` → `insertText(_:replacementRange:isPaste:)` 直接 `send(txt:)` 剪贴板原文,
不做换行符转换(`.build/checkouts/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift` L2723/L1875)。
此前测试会话"粘贴换行已转换为 \r"的结论**有误**(当时只看了终端渲染, 未核对发送字节)。
影响: 对只认 `\r` 的设备, 粘贴多行文本可能不按预期逐行执行。是否修复(在
`BridgeModel.sendInteractive` 或 SwiftTermView 包装层统一 `\n`→`\r`)建议单独立项讨论。

## 附录 B: 关联发现——日志行时间戳在数据抵达主线程时生成

RX 路径: `BLEManager.didUpdateValueFor`(bleQueue) → `DispatchQueue.main.async`(BLEManager.swift L611)
→ `BridgeModel.onReceive` → `logger.log`, 时间戳在 `log()` 内取 `Date()`。
主线程繁忙(如 GUI 自动化测试的 AX 大树查询)时, 日志时间戳滞后于字节真实到达时间,
本次会话中"回显与输出相隔 2–5 分钟"的异常间隔即主要由此叠加造成(测试诱发, 非常态)。
如需严格时序, 可考虑在 bleQueue 回调处打时间戳并随数据透传。建议单独立项评估。
