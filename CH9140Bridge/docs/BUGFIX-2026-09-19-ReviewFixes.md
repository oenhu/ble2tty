# BUGFIX: 代码审核修复(2026-09-19 审核意见的 4 个优先级组)

**日期**: 2026-09-19
**基于版本**: v1.0.5 之后的工作区源码
**状态**: ✅ 已修复(构建通过 / 自检 137 项全部通过 / CLI 冒烟通过)

---

## 背景

2026-09-19 对当前源码做了一轮逻辑审核, 在之前审计(09-13)与真机测试报告(09-14)
之外新发现若干"卡死/停摆/边缘正确性"问题, 并复核出部分已报告问题仍未修。
本次按 4 个优先级组全部修复。另经代码核对: 测试报告问题⑦(日志字节计数切割
不清零)在当前源码实际已修复(SessionLogger.swift openFileLocked 内
`self.bytesWritten = 0`), 审核报告该项判断有误, 特此更正。

## P1 卡死/停摆类

### 1. 芯片缓冲满后 TX 可能永久停摆(BLEManager)
发送恢复完全依赖芯片下一次 0x88"已空"上报; 上报丢失(链路丢包/固件缺陷)则
`chipFullFlag` 永真, TX 停摆至队列溢出。
**修复**: 新增 4 秒看门狗 `armChipFullWatchdog()`——满状态超时未解除则试探
恢复发送; 若芯片真的仍满, 下一次 0x88 满上报会重新武装看门狗。

### 2. DeviceMACResolver 管道死锁模式
先 `waitUntilExit()` 后读 stdout 管道, 输出超 64KB(配对设备多的机器)时
父子进程互等死锁; stderr 管道创建后从未读取同理。
**修复**: stderr 改 `FileHandle.nullDevice`; 先 `readDataToEndOfFile()`
再 `waitUntilExit()`; 另加 15s 兜底超时(system_profiler 挂起时 terminate)。

### 3. 自动重连两个残留缺口
- `connect(uuid:)` 系统未缓存设备时只打日志静默返回, 重连承诺落空。
- 无退避无上限: 失败每 ~10s 无限重试刷屏; 蓝牙关闭期间照样空转。

**修复**:
- BLEManager 新增 `startPendingScanConnect()`: 未缓存则转扫描按 UUID 查找
  (10s 超时, 匹配优先于名称/服务过滤——目标可能不广播 FFF0 或被改名);
  用户显式停止扫描时挂起连接一并取消并落定状态。
- BridgeModel `scheduleReconnect()`: 指数退避 2s→30s 封顶(不限次),
  蓝牙未开启时挂起, 由 `$bluetoothState` 观察者在恢复 poweredOn 时补发;
  就绪/手动连接/手动断开清零重连状态。

## P2 边缘正确性

### 4. 蓝牙关闭时连接状态不落定(BLEManager)
`centralManagerDidUpdateState` 非 poweredOn 分支原先只复位 isScanning;
CoreBluetooth 不保证补发断连回调, UI 可能停在"已就绪"。
**修复**: 非 poweredOn 时如有活动/挂起连接, 主动
`teardownConnectionOnQueue()`(从 didDisconnectPeripheral 抽取的统一清理)
并置 .disconnected; 同时清空外设引用缓存与设备列表。

### 5. flushInbound 与 close() 的 fd 复用竞争(VirtualSerialPort)
writeQueue 与 close() 无同步, 已捕获的 fd 被关闭复用后可能写入无关 fd。
**修复**: `flushInbound` 入口在 stateLock 下重校验 `isOpen && masterFD == fd`。

### 6. 退出不清理符号链接(测试报告问题②③)
- GUI: willTerminate 观察者原只 `closeSessionSync()`, 现先 `port.close()`
  清理 cu.* 符号链接再冲刷日志。
- CLI: 新增 SIGINT/SIGTERM DispatchSourceSignal 处理, 清理后退出
  (SIGINT→130, SIGTERM→0); 实测验证。

## P3 性能与体验

### 7. 发送队列 O(n²) 搬移(BLEManager)
`Data` + 循环 `removeFirst(n)`, 满缓冲(256KB, MTU 77)一次 drain 约数百 MB
memcpy, 独占 bleQueue 引发配置应答超时连锁误报。
**修复**: 分块 FIFO(outboxChunks + outboxHead + outboxBytes), 头部索引前进
定期压缩; 单块截发拷贝 ≤ 单块大小。

### 8. 已连接时无断开入口(测试报告问题④)
最近连接行 isCurrent 分支新增「断开」按钮(已连接设备停止广播, 扫描行
够不到断开按钮)。

### 9. 监视器中文不可读 / OSC 序列污染
- TerminalView 非 HEX 显示原用 printableASCII(≥0x7F 全替换为 ".")。
  现经 `BridgeModel.displayText()`: 严格 UTF-8 优先, 中文兼容开启时回退
  GBK(复用 SessionLogger.gbkEncoding), 再失败宽松解码。
- LineAssembler 新增 OSC(ESC ] … BEL/ST)与三字节序列(ESC(0 / ESC#8)过滤;
  OSC 终止 BEL 不再误触发提示音。新增 6 项自检。

## P4 健壮性加固

### 10. 配置通道帧拆分(CH9140Protocol.decodeFrames)
原 decode() 假定一次 FFF3 通知恰好一帧; 粘连多帧或夹带噪声时整包丢弃
(表现为配置偶发"超时")。新增 `decodeFrames()`: 已知指令按整帧长拆分,
逐帧校验, 噪声逐字节重同步, 截断半帧/坏帧归入 residue 记日志, 好帧不陪葬。
新增 5 项自检。

### 11. 扫描设备按 lastSeen 淘汰(BLEManager)
长时间扫描(showAll)下设备列表与外设引用原只增不减。现 60s 未再广播的设备
(当前连接除外)在发布节拍中淘汰。

### 12. CLI 生产化(CLIRunner)
- 新增 `--uuid <UUID>`: 多块同名 CH9140 同场时直连指定设备;
  非法 UUID 退出码 64(EX_USAGE)。
- `.failed` 原立即 exit(2), 现总超时预算内 2s 后重试(瞬时失败不杀死桥接)。
- CLI_READY 改为主队列异步打印, 修正其出现在"虚拟串口已创建"日志之前的
  误导顺序(测试报告问题③附)。

## 验证

- `swift build` 通过(GUI + CLI + SelfTest)
- `swift run CH9140SelfTest`: **137/137 通过**(新增 11 项: OSC/三字节序列 6,
  decodeFrames 5)
- CLI 冒烟: `--uuid` 非法→64; 扫描超时→2; SIGTERM→0 且打印清理日志

## 遗留(建议真机回线后验证)

- 自动重连全链路(掉电/超距/蓝牙开关)真机行为
- 芯片缓冲满看门狗在真实流控卡死场景的表现
- 扫描查找兜底(系统未缓存设备)的真机命中率
- GBK 设备控制台的监视器显示效果
