# BUGFIX: 审计发现的 3 个隐患(v1.0.4)

**日期**: 2026-09-12
**版本**: v1.0.3 → v1.0.4
**严重级别**: 中(后台线程发布 / 内存增长 / 多设备串流)
**状态**: ✅ 已修复(提交 2a701ff)

---

## 背景

对 BLE 与 UI 层做例行审计时发现 3 个隐患。三项都不会立刻崩溃,
但在特定时序下会导致未定义行为或数据错乱。

---

## 1. 扫描列表在后台线程发布 @Published

**现象**: `startScan`/`stopScan` 在 `bleQueue` 上直接修改
`@Published` 的 `devices`/`isScanning`。@Published 要求在主线程更新,
后台线程发布属于未定义行为(SwiftUI 可能丢更新或触发运行时警告)。

**修复**: 所有 @Published 写入统一经 `updateMain` 跳主线程;
开始新扫描时同时清理上一轮扫描聚合缓冲区(`pendingDeviceUpdates`)
的待发布残留, 避免旧数据混入新列表。

## 2. 发送队列 outbox 无上限

**现象**: 芯片 UART 发送缓冲长期满载(流控卡死/对端不读)时,
`outbox` 无限增长, 内存持续膨胀。

**修复**: outbox 封顶 256KB, 超出丢弃最旧数据并输出告警日志
("芯片发送缓冲区持续满载, 发送队列溢出, 已丢弃最旧 N 字节")。

## 3. 转连新设备不断开旧连接

**现象**: CoreBluetooth 允许同时连接多个外设。已连接设备 A 时再点
连接设备 B, 旧连接不被断开, 设备 A 的数据继续从 FFF1 涌入,
与新设备的数据串流混在一起。

**修复**: `startConnecting` 转连新目标前先 `cancelPeripheralConnection`
旧外设(挂起中的与已建立的两类都处理); `didConnect`/
`didDisconnectPeripheral`/`didUpdateValueFor` 增加过期回调守卫,
迟到的旧连接事件不再污染当前状态机。

---

## 验证

```
swift build              # 通过
swift run CH9140SelfTest # 全部通过
```

> 注: 第 3 项的守卫后来被发现仍有漏洞(手动断开挂起连接后迟到事件
> 可穿透), 已在 v1.0.5 改用 `activePeripheralID` 精确识别, 详见
> [BUGFIX-2026-09-13-CodeAudit.md](BUGFIX-2026-09-13-CodeAudit.md)。
