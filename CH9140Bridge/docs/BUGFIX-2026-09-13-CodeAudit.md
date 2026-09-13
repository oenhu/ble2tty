# BUGFIX: 全量代码审计修复(18 项审计意见 + 6 项新发现)

**日期**: 2026-09-13
**版本**: v1.0.4 → v1.0.5
**严重级别**: 高（含 2 项功能性 Bug + 5 项数据竞争）
**状态**: ✅ 已修复（构建通过 / 自检 69 项全部通过）

---

## 背景

对 `CH9140Bridge/` 全部源文件(~3400 行)做了一次全量代码审核, 核对上一轮审计
提出的 18 项意见并复核, 另发现 6 项新问题。本文档汇总修复内容。

修复分四个提交:

1. **BLE 状态机**: 自动重连/陈旧数据/跨线程状态/断开重复事件
2. **PTY 线程安全**: running/lastTermios/FD 锁一致性, 波特率回落告警
3. **健壮性**: 终端防御/设置校验/自检隔离/CLI 断开退出/粘贴/输入法守卫
4. **版本与文档**: 版本号 1.0.5, 构建脚本注入版本, README 同步

---

## P0 功能性 Bug

### 1. 自动重连在连接失败时"承诺了但永不执行"

`BridgeModel` 的重连守卫是 `connectionState == .disconnected`, 而 `.failed`
是终态(没有任何代码把它改回 `.disconnected`)——连接超时/失败后日志承诺
"2 秒后尝试自动重连", 但重连从不发生。

**修复**: 守卫改为排除进行态(`.connecting/.discovering/.ready` 即返回),
`.disconnected` 与 `.failed` 都放行重连。

### 2. 断连期间的发送数据会在下次连接时"复活"

`BLEManager.send()` 不检查连接状态; `BridgeModel` 的 PTY→BLE 通路也无
`isReady` 守卫。断连期间串口工具仍在往虚拟串口写, 数据积压在 outbox,
下次连接 ready 后会把**陈旧数据发给新连接的设备**。

**修复**(双保险):
- `send()` 入口按 bleQueue 私有的 `isReadyOnQueue` 判断, 非就绪直接丢弃;
- `didConnect` 时无条件清空 outbox 并复位 `chipFullFlag`, 新会话从零开始。

### 3. 版本号漂移

`Resources/Info.plist` 停留在 1.0.0, 而 git 提交历史已到 v1.0.4, 且无任何
git tag。

**修复**:
- Info.plist 提升到 1.0.5 (build 5), 并补打 `v1.0.5` tag;
- `build_app.sh` 打包时从 `git describe --tags` 自动注入版本号、从提交数
  注入 build 号(无 tag 时回退 plist 值), 避免再次漂移。

---

## P1 数据竞争

### 4. `connectionState`: 主线程写 / bleQueue 读

`setState` 只在主线程写 @Published; 而 `applySerialParameters` /
`applyModemLines` 在 bleQueue 上读 `connectionState == .ready`。

**修复**: bleQueue 侧改用仅在 bleQueue 维护的私有 `isReadyOnQueue`,
在 `didDiscoverCharacteristicsFor` 就绪处与超时/失败/断开处同步维护。

### 5. `connectedUUID`: bleQueue 写 / 主线程读

UUID 为 128 位结构体, 跨线程无同步读写理论上可能读到撕裂值(设备行高亮/
按钮状态错乱)。

**修复**: 改为 `@Published public private(set)`, 全部写挪到主线程;
bleQueue 侧的连接判定改用私有的 `activePeripheralID`。

### 6. `VirtualSerialPort.running` 无同步

`close()`(任意线程)写 / `pollLoop` 线程读。

**修复**: 改为 `stateLock` 保护的 `isRunning` 访问器(`Thread.isCancelled`
仍是备份退出信号)。

### 7. `lastTermios` 跨线程

`open()`(调用方线程)写 / `checkTermios`(poll 线程)读写。

**修复**: 纳入 `stateLock`——open 的初始基线与 checkTermios 的基线读写
均在锁内。

### 8. `masterFD/slaveFD` 赋值不对称

`open()` 无锁赋值, `close()` 加锁赋值, pollLoop/writeToPort 加锁读。

**修复**: `open()` 侧全部改为经 `stateLock` 赋值(含符号链接失败的
回滚路径)。

---

## P2 健壮性

### 9. 终端增量删除缺乏防御

`storage.deleteCharacters(in:)` 依赖 render 与已渲染内容严格一致, 失配时
NSRange 越界直接抛 ObjC 异常崩溃。

**修复**: 头部删除与行尾改写两处加防御——删除长度超出已渲染总量时
整屏重绘兜底, 不再直接删除。

### 10. PTY 波特率映射上限 230400, 与 UI 的 1M 矛盾

串口工具经 IOSSIOSPEED 设置 460800+ 时 `baudRate(from:)` 返回 nil →
静默回落 9600 → **把错误波特率同步给芯片**。

**修复**: 无法映射时明确告警
("串口工具设置的波特率超出 macOS PTY 标准可表达范围(≤230400), 本次参数
未同步给芯片")并跳过本次同步, 不再回落。基线仍会刷新, 避免重复告警。

### 11. UserDefaults 读取用 clamping 且无合法性校验

损坏值(如 dataBits=300)被 `UInt8(clamping:)` 成 255 后直接下发芯片。

**修复**: 读取即校验——波特率 300~1_000_000、数据位 5-8、停止位 1-2、
校验 0-4, 越界回退默认值。

### 12. 自检程序触碰 UserDefaults.standard

> 复核结论: 实测 `swift run CH9140SelfTest` 无 bundle, standard 的持久域
> 按进程名落到独立的 `CH9140SelfTest` 域, **与 App 的
> `cn.wch.CH9140Bridge` 域天然隔离**, 原意见的"干扰用户配置"危害
> 实际不成立。

尽管如此, 依赖隐式隔离是脆弱的(一旦自检被放进 bundle 就会穿透)。

**修复**: `SettingsStore` 支持注入 `UserDefaults`; 自检显式使用
`UserDefaults(suiteName: "CH9140SelfTest")` 并在结束时
`removePersistentDomain` 整域清理。

---

## P3 次要问题

| # | 问题 | 修复 |
|---|------|------|
| 13 | `disconnect()` 主动 setState 后 `didDisconnectPeripheral` 再设一次, `onConnectionChange` 双触发 | 已建立连接的取消改由回调单次落定; 挂起中取消(无回调)单独落定 |
| 14 | `LineAssembler.flushPending()` 生产代码从未调用 | 接入 `BridgeModel.flushPendings()`: 系统消息插入后残行正确封尾, 后续片段不再与旧残行错误拼行 |
| 15 | CLI 模式 ready 后设备断开不退出也不重连, 进程变僵尸 | `.disconnected` 即收尾退出(exit 4), 退出前关闭虚拟串口清理符号链接 |
| 16 | 交互模式不支持 Cmd+V, 且 Cmd+任意键会把裸字符发到设备 | Cmd+V 粘贴(LF 归一为 CR)后发送; 其余 Cmd 组合键不再透传 |
| 17 | `InputSourceGuard.leave()` 覆盖用户聚焦期间手动切换的输入法 | leave 前比较当前输入源与 enter 时切过去的源, 已被用户改动则保留 |
| 18 | README 写"自检 30 项断言"实际 69 项; 故障排查表缺 v1.0.2~v1.0.4 条目 | 已同步数字与表格 |

---

## 审计之外的新发现(一并修复)

1. **过期回调守卫漏洞**(#13 同源): 手动断开"挂起中"的连接后
   `peripheral/connectingPeripheral` 双空, 迟到的 `didDisconnectPeripheral`
   会穿透旧守卫再次触发断连事件。改为 `activePeripheralID` 精确识别过期
   回调(超时取消/手动断开/转连后的迟到事件统一拦截)。
2. **特征不全时错误归因**: 固件缺 FFF1/FFF2/FFF3 任一特征时只会报
   "连接超时: 设备无响应", 现在明确日志缺失的特征; 连接超时消息也提示
   该可能性。
3. **串口名未净化**: 设置里的串口名含 `/` 会把符号链接创建到目录之外;
   `open()` 侧 `sanitizedName` 过滤路径分隔符, 空名回退默认值。
4. **`close()` 主线程忙等 0.5s**: 改用 `pollExitSemaphore`, pollLoop 退出时
   信号唤醒(poll 最多阻塞 200ms), 不再轮询占用调用线程。
5. **CLI `StateBox.txBytes`** poll 线程写/主线程读无同步: 加锁保护。
6. **终端 TX 行 HEX/文本显示不一致**: 文本模式剥离行尾换行而 HEX 模式
   显示全部字节, 统一剥离。
7. **`build_app.sh` 两个缺陷**: ① 打包时创建空的
   `Contents/Resources` 目录, 导致 `codesign --verify` 报
   "code has no resources but signature indicates they must be present",
   产物其实一直处于"未签名"状态; ② `set -e` 下 `git describe` 在无 tag
   的仓库返回非零直接终止脚本, 版本注入之后的签名步骤从未执行。
   已修复(空目录不再创建、git 命令 `|| true` 兜底), 签名验证通过。

---

## 验证

```
swift build              # 无警告通过
swift run CH9140SelfTest # 通过 69 项, 失败 0 项
```

自检新增 4 项断言: 波特率越界返回 nil / 串口名净化 / 空白名回退默认 /
越界设置回退默认值。
