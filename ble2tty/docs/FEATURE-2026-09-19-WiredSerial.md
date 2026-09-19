# FEATURE: 有线串口支持(USB 转串口直连, 无需 CH9140)

**日期**: 2026-09-19
**版本**: v1.1.0 → v1.2.0
**状态**: ✅ 已完成(构建通过 / 自检 154 项全部通过 / CLI 冒烟通过)

---

## 动机

项目的核心价值是 Console 调试技术栈(终端仿真/收发监视/会话日志/GBK 中文/MODEM 面板),
BLE 只是数据源之一。新增有线串口数据源后, 不插 CH9140 也能用整套工具调试
普通 USB 转串口设备(CH340/CP210x/FTDI 等), 顺带获得两个 BLE 模式没有的能力:

- **任意高波特率**(460800/921600/1.5M 等, 不受 PTY termios ≤230400 的表达上限约束)
- **真实 MODEM 线**: DTR/RTS 输出(ioctl TIOCMSET)与 CTS/DSR/RI/DCD 输入状态(TIOCMGET 1s 轮询)

## 设计原则: 现有功能零改动

- `BLEManager` 一行未动; BLE 数据通路/状态机/重连逻辑保持原样
- 有线功能 = 2 个新文件 + BridgeModel 增量接线 + 视图最小条件化
- 同一时刻只允许一条活动链路: 发起新连接前自动断开另一链路
- BridgeModel 把 wired 的 objectWillChange 转发给 model, 视图观察 model 即联动

## 新增文件

| 文件 | 职责 |
|---|---|
| `CH9140Core/Serial/SerialPortEnumerator.swift` | IOKit `IOSerialBSDClient` 枚举, 取 callout 路径 + 父节点 USB Product Name 友好名 |
| `CH9140Core/Serial/WiredSerialPort.swift` | 打开(TIOCEXCL 尽力独占)/termios 配置/poll 读线程/分块 FIFO 写背压/热拔出落定/MODEM ioctl/状态轮询 |
| `BLE2TTY/Views/WiredPortListView.swift` | 有线页: 刷新/端口列表/空态驱动指引 |

## 关键实现点

- **公开接口与 BLEManager 对齐**(connectionState/onReceive/onLog/onConnectionChange/
  send/applySerialParameters/applyModemLines/modemStatus/isReady), BridgeModel 接线对称
- **参数是本地 tcsetattr, 同步生效**; 打开时即配置(主机侧帧格式必须与对端一致);
  切换后 `tcflush` 冲刷两侧(乱码字节曾触发对端 Linux SysRq, 教训内置)
- **Mark/Space 校验**(CH9140 支持 3/4): macOS termios 不支持, 优雅失败提示, 不改参数
- **MODEM 线降级**: PTY 等伪终端 TIOCM* 返回 ENOTTY(实测), 流控(CRTSCTS=0x30000,
  macOS 无 CNEW_RTSCTS 常量)照设, DTR/RTS 报"不支持"不阻断
- **占用语义**: 打开后尝试 TIOCEXCL; 实测 macOS PTY 上独占不拦截后续 open(伪终端忽略),
  真实驱动是否拦截取决于厂商实现, 故为"尽力而为", UI 文案如实说明
- **热拔出**: 读线程 EIO/POLLHUP → queue 上幂等落定 → .disconnected → 走既有退避自动重连
  (重连恢复同一会话参数 lastWiredParams)

## CLI

`--wired /dev/cu.xxx --baud 115200`: 无界面监视模式, `CLI_READY wired=…` 就绪行,
打印收发与 10s 统计, 失败在超时预算内重试; SIGINT→130 / SIGTERM→0, 退出前断开串口。

## 验证

- 自检 **154/154**(新增 17 项: PTY 对模拟有线串口——连接就绪/双向收发/参数读回/
  Mark 拒绝/CRTSCTS 标志/MODEM 降级回调/断开落定/断连丢弃/不存在设备失败/枚举)
- CLI 冒烟: python pty 对 → `CLI_READY` → 收到数据 → SIGTERM 退出码 0
- 现有 137 项自检全部保持通过(BLE 路径无回归)

## 待真机验证(设备回线后)

- CH340/CP2102/FTDI 真实适配器的: 打开/收发/高波特率/DTR-RTS/CTS 状态灯/热拔出重连
- 被 screen 占用时的行为(不同驱动的独占语义差异)
