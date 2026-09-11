# BUGFIX: 扫描到设备但"连接"按钮灰色不可用

**日期**: 2026-09-12
**版本**: v1.0.2 → v1.0.3
**严重级别**: 高（设备无响应时连接功能完全卡死，只能重启 App）
**状态**: ✅ 已修复（用户实测验证通过）

---

## 问题现象

用户反馈：设备已启动且**安卓 App 可以正常连接**，但在 Mac 端 CH9140Bridge 中
**能扫描到设备，"连接"按钮却是灰色的**，无法点击。

## 根本原因

### 按钮为什么灰？

`DeviceListView.swift` 中"连接"按钮唯一的禁用条件：

```swift
Button("连接") { model.connect(device) }
    .disabled(ble.connectionState == .connecting)   // ← 唯一的禁用条件
```

按钮变灰 ⟺ 连接状态卡在 `.connecting`（连接中）。

### 为什么会永远卡在"连接中"？

`BLEManager.connect()` 调用 CoreBluetooth 的 `central.connect()` 发起连接，
但 **CoreBluetooth 对无响应的外设没有超时机制**——既不回调 `didConnect`，
也可能永远不回调 `didFailToConnect`。

这正是 CH9140 的典型场景：**CH9140 是单连接设备**——
如果它正被安卓手机（或其他主机）占用着连接，Mac 发起的连接请求会被
无限期挂起，状态机永远停在 `.connecting`：

```
点击"连接" → .connecting → [设备被手机占用, 无响应] → 永远卡死
                                                      ↓
                                            按钮永远灰色, 只能重启 App
```

### 雪上加霜：挂起的连接无法取消

`disconnect()` 原来的实现：

```swift
if let p = self.peripheral {          // peripheral 只在 didConnect 成功后才赋值!
    self.central.cancelPeripheralConnection(p)
}
// 挂起中的连接: peripheral == nil → 什么都不做, 状态不变
```

`peripheral` 属性只在 `didConnect` 回调后才赋值，连接**挂起期间它是 nil**——
即使想取消也取消不了，形成了完全的死锁。

## 修复方案

**文件**: `Sources/CH9140Core/BLE/BLEManager.swift`、`Sources/CH9140Bridge/Views/DeviceListView.swift`

### 改动 1：8 秒连接超时保护（核心修复）

新增 `startConnecting()` 统一发起连接，覆盖 **连接 + 服务发现** 全程，
到达 `.ready` 才解除；超时则主动取消连接、落定失败状态：

```swift
private func startConnecting(_ p: CBPeripheral) {
    connectTimeout?.cancel()
    connectingPeripheral = p
    central.connect(p, options: nil)
    let timeout = DispatchWorkItem { [weak self] in
        guard let self, self.connectingPeripheral != nil else { return }
        self.connectingPeripheral = nil
        self.central.cancelPeripheralConnection(p)
        self.connectedUUID = nil
        self.log("连接超时: 设备无响应(可能正被其他主机占用, CH9140 只支持单连接; 或不在范围内)")
        self.setState(.failed("连接超时"))
    }
    connectTimeout = timeout
    bleQueue.asyncAfter(deadline: .now() + Self.connectTimeoutInterval, execute: timeout)
}
```

超时后：状态变为 `.failed("连接超时")` → 按钮恢复可点 → 日志明确提示
"可能正被其他主机占用"。

### 改动 2：挂起中的连接也可以取消

新增 `connectingPeripheral` 属性跟踪挂起中的外设引用，
`disconnect()` 改为优先取消它：

```swift
let p = self.peripheral ?? self.connectingPeripheral   // 覆盖挂起中的连接
if let p { self.central.cancelPeripheralConnection(p) }
// 取消"挂起中"的连接不会回调 didDisconnectPeripheral, 这里直接落定状态
self.setState(.disconnected)
```

### 改动 3：连接中显示"取消"按钮

设备行在连接/发现服务期间，进度圈旁新增"取消"按钮，
用户无需等待 8 秒超时即可主动退出：

```swift
if isConnecting {
    ProgressView()...
    Button("取消") { model.disconnect() }   // 新增
}
```

### 改动 4：失败/断开时清理 connectedUUID

`didFailToConnect` / `didDisconnectPeripheral` 中原先不清 `connectedUUID`，
失败后该行会错误地显示"断开"而不是"连接"。现在一并清理，
失败后直接可以重新点"连接"。

## 修复效果

| 场景 | 修复前 | 修复后 |
|------|--------|--------|
| 设备被手机占用时点"连接" | 永远卡死，按钮灰色，只能重启 App | 8 秒后提示"连接超时"并给出原因，按钮恢复 |
| 连接中反悔 | 无法取消 | 随时可点"取消" |
| 连接失败后重试 | 需先点"断开"再点"连接" | 直接点"连接" |
| 自动重连遇到挂起 | 同样卡死（重连前提是 .disconnected） | 超时落定 .failed → 自动重连正常触发 |

## 给用户的排查提示

超时日志会直接提示最可能的原因。遇到连接超时请检查：

1. **设备是否正连着安卓手机/其他主机？** CH9140 只支持**单连接**，
   先在手机 App 里断开（或关闭手机蓝牙），再在 Mac 上连接
2. 设备是否在蓝牙范围内（RSSI > -85dBm 为宜）
3. 设备是否需要重新上电（CH9140 芯片间智能配对有 3 秒上电窗口，
   但这不影响手机/电脑作为主机的普通 BLE 连接）

## 回归测试

- [x] `swift build` 编译通过
- [x] `swift run CH9140SelfTest` 65 项自检全部通过
- [x] 用户实测：扫描 → 连接 → 数据透传正常 ✅
- [x] 卡死场景（设备被占用）：8 秒超时正常触发，按钮恢复

## 相关文件

- `Sources/CH9140Core/BLE/BLEManager.swift` — 超时保护 / 挂起连接取消 / 状态清理
- `Sources/CH9140Bridge/Views/DeviceListView.swift` — 连接中"取消"按钮
