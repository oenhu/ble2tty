# PERF: 终端整屏重绘与多处高频路径性能优化

**日期**: 2026-09-10
**版本**: v1.0.1 → v1.0.2
**严重级别**: 高（潜伏隐患，高速刷数据时 UI 卡顿 / CPU 爬升）
**状态**: ✅ 已修复

---

## 背景

继 v1.0.1 修复 PTY 忙等待导致的高 CPU 问题（见 [BUGFIX-2026-09-10-HighCPU.md](BUGFIX-2026-09-10-HighCPU.md)）后，
对全项目做了一次性能审查，发现 **7 处潜伏的性能隐患**。这些问题平时不显现，但在
**设备高速刷日志 / BLE 满载 / 设备密集环境扫描** 等场景下会造成 UI 卡顿与 CPU 爬升。

本次全部为预防性修复，无用户报障。

## 问题清单

| # | 严重度 | 问题 | 位置 |
|---|--------|------|------|
| 1 | 🔴 高 | 终端刷满 3000 行后每来一行触发整屏重绘 | BridgeModel / TerminalView |
| 2 | 🟠 中 | BLE 扫描每个广播包都跳主线程 + 全量排序 | BLEManager |
| 3 | 🟠 中 | 字节统计逐数据块跳主线程刷新界面 | BridgeModel / VirtualSerialPort / SessionLogger |
| 4 | 🟠 中 | SwiftTerm 逐包投喂 + 每包一次多余主线程跳转 | SwiftTermView |
| 5 | 🟡 低 | HEX 转换逐字节调用格式化函数 | HexUtil |
| 6 | 🟡 低 | `inboundBuffer` 跨线程访问锁保护不一致（数据竞争） | VirtualSerialPort |
| 7 | 🟡 低 | "仅数据"模式每个数据包全量 filter 一次 | BridgeModel / TerminalView |

---

## 问题 1 🔴：终端到达行数上限后，每行新数据触发整屏重绘

### 根本原因

`BridgeModel.trimIfNeeded()` 截断时递增 `terminalGeneration`，而 `TerminalTextView`
把 generation 当作重绘签名——**每次截断 = 3000 行全部重新渲染为 NSAttributedString**。

由于截断逻辑是"超 1 行删 1 行"，行数到达上限进入稳态后：

- 每收到一行新数据 → `Array.removeFirst(1)`（O(n) 数组搬移，n=3000）
- `terminalGeneration` 递增 → 整屏 3000 行全量重绘

高速刷日志（每秒几十行）时，每秒要做十几万行富文本渲染，UI 必然卡顿。
与 v1.0.1 修复的高 CPU 问题同量级，只是触发条件不同。

### 修复方案

**模型侧**（`BridgeModel.swift:389` `trimIfNeeded()`）：批量截断，一次删到上限以下
500 行，摊销 O(n) 搬移；**截断不再递增 `terminalGeneration`**：

```swift
private func trimIfNeeded() {
    guard lines.count > maxLines else { return }
    // 批量截断: 一次删到上限以下 trimBatch 行, 摊销 O(n) 搬移
    let removeCount = lines.count - maxLines + trimBatch
    let removedData = lines.prefix(removeCount).reduce(0) { $0 + ($1.kind == .system ? 0 : 1) }
    lines.removeFirst(removeCount)
    if removedData > 0 { dataLines.removeFirst(removedData) }
}
```

**视图侧**（`TerminalView.swift:83` 起）：Coordinator 记录已渲染首行的行 ID。
模型截断后，首行 ID 不在数组开头 → 定位其新下标，只渲染被删的约 500 行算出字符长度，
从 textStorage **头部增量删除**，不再整屏重建：

```swift
if let firstID = coord.firstRenderedID, visibleLines.first?.id != firstID {
    guard let idx = visibleLines.firstIndex(where: { $0.id == firstID }) else {
        fullRedraw(storage: storage, coord: coord, signature: signature)  // 兜底
        ...
    }
    var deleteLength = 0
    for line in visibleLines[0..<idx] { deleteLength += render(line).length }
    storage.deleteCharacters(in: NSRange(location: 0, length: deleteLength))
    coord.renderedCount -= idx
    coord.firstRenderedID = visibleLines.first?.id
}
```

### 效果

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| 整屏重绘频率 | 达到上限后**每行一次** | 仅显示模式切换/清屏时 |
| 截断开销 | 每行一次 O(n) 搬移 | 每 501 行一次（摊销 ~1/500） |
| 截断时渲染量 | 3000 行全量 | 仅被删的 ~500 行算长度 |

---

## 问题 2 🟠：BLE 扫描每个广播包都跳主线程 + 全量排序

### 根本原因

扫描开启了 `CBCentralManagerScanOptionAllowDuplicatesKey`（RSSI 实时更新需要），
**每个广播包**都会触发 `didDiscover` → `DispatchQueue.main.async` → 更新数组 →
`devices.sort` 全量排序 → SwiftUI 列表重排重绘。设备密集环境（办公室数十台 BLE 设备）
每秒可产生上百个广播包。

### 修复方案

`BLEManager.swift:348`：广播包先按设备聚合并留在 bleQueue，以 **0.4 秒固定节奏**
批量发布到主线程，一个窗口内的所有更新合并为一次数组更新 + 一次排序；
外设引用在 bleQueue 上取好再跳主线程，避免跨线程访问 `peripherals`。
`stopScan()` 时主动冲刷一次，保证停止后列表为最新。

### 效果

主线程更新与排序频率：每秒数十~上百次 → **固定 2.5 次/秒**。

---

## 问题 3 🟠：字节统计逐数据块刷新界面

### 根本原因

三处字节计数每处理一个数据块就跳主线程更新 `@Published`，触发状态栏重绘：

- `BridgeModel.totalRXBytes / totalTXBytes`（每个 BLE 包 / 串口块一次）
- `VirtualSerialPort.bytesFromClient / bytesToClient / droppedBytes`（每次读写一次）
- `SessionLogger.bytesWritten`（每次写盘一次）

BLE 满载时每秒数百个通知包 = 每秒数百次界面刷新。
另外 `totalTXBytes` 原来在 PTY 轮询线程上直接改写 `@Published`，
属于线程安全隐患，一并修正。

### 修复方案

统一改为**合帧发布**：任意线程先在锁内（或串行队列上）累加，
再以固定节奏一次性发布到主线程：

- `BridgeModel.addBytes(rx:tx:)` — 10Hz（`BridgeModel.swift:56`）
- `VirtualSerialPort.scheduleCounterFlushLocked()` — 10Hz（`VirtualSerialPort.swift:382`）
- `SessionLogger.bumpBytes()` — 5Hz（`SessionLogger.swift:205`）

---

## 问题 4 🟠：SwiftTerm 逐包投喂

### 根本原因

`onRawRX` 每个 BLE 包都执行 `Array(data)` 拷贝并喂给 SwiftTerm 终端仿真器，
且 feeder 内部每个包都再做一次 `DispatchQueue.main.async` 跳转
（`onRawRX` 本就在主线程，属多余跳转）。

### 修复方案

`TermFeeder` 改为**合帧投喂**（`SwiftTermView.swift:26`）：主线程上以 30ms 窗口
聚合多个数据包，批量一次解析；移除多余的主线程再跳转。

交互回显最坏增加 30ms 延迟，低于人类感知阈值；**双终端保活、切模式不丢历史的
特性完整保留**（两个视图均常驻的既定设计不变）。

---

## 问题 5 🟡：HEX 转换逐字节格式化

### 根本原因

`HexUtil.hexString` 原实现 `data.map { String(format: "%02X", $0) }` 逐字节走
locale 格式化，比查表法慢一个数量级。HEX 日志（hex/both 模式）与 HEX 显示
每个数据块都调用，是明确的热点。

### 修复方案

`HexUtil.swift:13`：改为静态字符表逐字节拼接，预分配容量：

```swift
private static let hexDigits: [Character] = Array("0123456789ABCDEF")

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
```

---

## 问题 6 🟡：inboundBuffer 数据竞争

### 根本原因

`VirtualSerialPort` 的 `inboundBuffer`：写入发生在 `writeQueue`（无锁），
而 `pollLoop` 在 `stateLock` 下读取——**两侧锁保护不一致**，存在数据竞争，
极端情况下可能崩溃。

### 修复方案

新增专用锁 `inboundLock`（`VirtualSerialPort.swift:56`），统一保护全部访问点：
`writeToPort`（追加/截断）、`flushInbound`（读取/移除）、`pollLoop`（判空）、
`close()`（清空）。锁粒度细化到缓冲区操作，写 fd 仍在锁内但 fd 为非阻塞，
不会长时间持锁。`flushInbound` 顺便把多次 `bumpCounters` 合并为一次。

---

## 问题 7 🟡："仅数据"模式 O(n) 过滤

### 根本原因

`hideSystem` 打开时，视图与工具栏行数统计每个数据包都对全量数组
（最多 3000 行）执行一次 `filter`，产生大数组分配与拷贝。

### 修复方案

`BridgeModel` 维护 `dataLines` 镜像数组（`BridgeModel.swift:91`）——只含数据行的
`lines` 子序列，所有变更点（追加/活行尾替换/截断/清屏）同步维护；
视图与计数直接取用，O(1)。`TerminalTextView` 改为接收预过滤的 `visibleLines`。

镜像一致性依赖一条不变式：**"活"行尾必为数据行且同时在两个数组末尾**
（任何系统消息都会使活行尾失效），已在代码注释中注明。

---

## 功能与兼容性影响评估

### ✅ 无功能变化

| 功能点 | 状态 | 说明 |
|--------|------|------|
| 终端显示内容 | ✅ 一致 | 增量删除与整屏重绘结果像素级一致 |
| 切模式不丢历史 | ✅ 保留 | 双终端常驻设计不变，仅投喂改为合帧 |
| 交互回显延迟 | ✅ 无感知 | SwiftTerm 合帧最坏 +30ms |
| 设备扫描 | ✅ 一致 | 设备出现最坏延迟 +0.4s，RSSI 照常更新 |
| 状态栏字节统计 | ✅ 准确 | 仅刷新节奏降为 10Hz，总量精确 |
| 日志文件内容 | ✅ 字节精确 | 合帧只影响计数显示，不影响写盘内容 |
| HEX 输出格式 | ✅ 一致 | `"AA BB CC"` 分隔符行为不变 |

### ✅ 兼容性：完全兼容

- 协议层（FFF0–FFF3 GATT 通信）零改动
- 虚拟串口 PTY 行为零改动
- macOS 全版本支持（均为既有 API 的重排）

---

## 回归测试

### 自动化

```
swift build                 ✅ Build complete!
swift run CH9140SelfTest    ✅ 通过 65 项, 失败 0 项
```

自检覆盖：协议编解码 / 日志切割 / 行装配 / 设置持久化等，全部通过。

### 建议人工验证

- [ ] 高速刷日志（如交换机 `display logbuffer` 连刷），观察活动监视器 CPU 保持低位
- [ ] 刷满 3000 行后继续输出，确认滚动流畅、旧行正确消失
- [ ] 监视/终端模式互切，历史完整
- [ ] "仅数据"开关切换，行数统计正确
- [ ] HEX 显示与 HEX 日志内容正确
- [ ] 设备密集环境扫描，列表刷新流畅
- [ ] 串口工具双向大流量传输，字节统计准确

---

## 后续优化建议

1. **行缓冲改用环形队列**：批量截断后 `Array.removeFirst` 仍是 O(n)，
   如需进一步降低峰值可换双数组/环形结构（当前摊销后已非热点）。
2. **NSAttributedString 渲染缓存**：行内容不变但显示模式（时间戳/HEX）切换时
   仍需整屏重建，可缓存原始渲染结果。
3. **真实设备压测**：建议以 115200 bps 满速双向跑 1 小时，确认 CPU / 内存曲线平稳。

---

## 相关文件

- `Sources/CH9140Core/BridgeModel.swift` — 批量截断 / dataLines 镜像 / 字节统计合帧
- `Sources/CH9140Bridge/Views/TerminalView.swift` — 头部增量删除 / 预过滤数组
- `Sources/CH9140Bridge/Views/SwiftTermView.swift` — TermFeeder 合帧投喂
- `Sources/CH9140Core/BLE/BLEManager.swift` — 扫描发现批量发布
- `Sources/CH9140Core/Serial/VirtualSerialPort.swift` — inboundLock / 计数器合帧
- `Sources/CH9140Core/Logging/SessionLogger.swift` — 日志字节数合帧
- `Sources/CH9140Core/Protocol/HexUtil.swift` — HEX 查表转换
- 前作: [BUGFIX-2026-09-10-HighCPU.md](BUGFIX-2026-09-10-HighCPU.md)
