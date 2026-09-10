# CH9140Bridge — CH9140 蓝牙串口桥 (macOS)

把 **CH9140 蓝牙转串口芯片** 桥接成 Mac 上的**虚拟串口**, 配合原生 GUI 控制面板,
用于调试交换机/路由器等网络设备的 Console 口, 兼容任意串口工具
(screen / minicom / CoolTerm / PuTTY / SecureCRT 等)。

协议实现对照 WCH 官方资料(见 `../doc`):
- `BleUartLib/iOS` CH9140Lib 官方 iOS 库(连接/配置逻辑逐字节对齐)
- `CH9140DS1.PDF` 芯片数据手册(FFF0-FFF3 GATT 通道定义)

## 功能

| 功能 | 说明 |
|---|---|
| BLE 扫描/连接 | 自动过滤 CH9140 透传服务(0xFFF0), 可切换显示全部设备, 信号强度排序 |
| 虚拟串口 | 基于 PTY 伪终端, 无需内核扩展; 路径 `~/Library/Application Support/CH9140Bridge/cu.CH9140` |
| 波特率跟随 | 串口工具 `tcsetattr` 修改波特率/数据位/停止位/校验 → 自动经 0xFFF3 下发给芯片 |
| 串口参数配置 | 面板直接下发 波特率(300~1M)/数据位/停止位/校验/流控/DTR/RTS, 芯片回包校验 |
| MODEM 状态 | CTS/DSR/RI/DCD 实时指示灯(0x88 上报), 芯片发送缓冲区满/空流控 |
| 默认保存日志 | 自定义目录; 文件名模板({device}/{name}/{date}/{time}/{datetime}/{seq}); 一键切割新建文件; 按会话/按日期分目录/按日期合并三种方式, 跨午夜自动切换 |
| 内置终端 | 监视收发(HEX/文本), 按行合并分包数据, 支持跨行复制; 整行发送(默认 CR 行尾) + **交互模式**(键盘直连: Tab 补全/↑↓ 历史/Ctrl+C/退格编辑, 回显自动重绘) |
| 自动重连 | 意外断开 2 秒后自动重连(可在设置关闭) |

## 构建与运行

```bash
cd CH9140Bridge
./build_app.sh          # Release 构建 + 打包 + ad-hoc 签名
open CH9140Bridge.app   # 运行
```

只需 Xcode Command Line Tools(无需完整 Xcode)。首次运行会弹蓝牙权限请求,
或在 **系统设置 → 隐私与安全性 → 蓝牙** 中允许 CH9140Bridge。

运行自检(30 项: 协议编解码/PTY 数据通路/日志/设置):

```bash
swift run CH9140SelfTest
```

## 使用(以调试交换机为例)

1. 打开 App → 点 **扫描设备** → 选择 `CH9140BLE2U`(或你的模块名)→ **连接**。
2. 连接后自动下发默认串口参数(出厂为交换机习惯: **9600 8N1 无校验**,
   可在 `⌘,` 设置里改)。CH9140 模块串口侧接交换机 Console 口。
3. 用任意串口工具打开虚拟串口:

   ```bash
   screen ~/Library/Application\ Support/CH9140Bridge/cu.CH9140 9600
   # 退出: Ctrl+A 然后 K
   ```

   CoolTerm/minicom 等 GUI 工具里填同样的路径即可。
4. 串口工具里设什么波特率, 芯片就自动切到什么波特率(设置里可关闭"自动同步")。
5. 日志默认保存在 `~/Documents/CH9140Logs/`(可自定义), 默认按日期分目录存储, 自动记录全部会话。

## 设置面板(⌘,)

- **通用**: 默认串口参数、连接后自动下发、波特率跟随、自动重连
- **日志**: 默认保存日志开关、TX 记录、时间戳、格式(纯文本/HEX/HEX+文本)、自定义保存目录、
  按日期存储方式(按会话 / 按日期分目录 `yyyy-MM-dd/…` / 按日期合并, 跨午夜自动切换)、
  **文件名模板**(变量 `{device}` 设备名 `{name}` 自定义标识 `{date}` `{time}` `{datetime}` `{seq}` 切割序号,
  实时预览; 重名自动补序号)、**截断并新建**按钮(日志卡片/终端工具条, ⌘T 快捷键默认关闭可在设置开启)
- **虚拟串口**: 串口名称(构成 `cu.<名称>`)、启动时自动创建

## 技术说明

```
串口工具 ──/dev/ttysNNN──┐
                         │ openpty()        BLE GATT
CH9140Bridge App ── master fd ──────────► 0xFFF2 (WriteWithoutResponse)
CH9140Bridge App ◄─ master fd ◄────────── 0xFFF1 (Notify)
                     tcsetattr 巡检 ─────► 0xFFF3 (0x06 配置串口 / 0x07 流控)
                     MODEM 状态  ◄──────── 0xFFF3 (0x88 上报)
```

- 为什么用 PTY 而不是内核驱动: macOS 早已废弃第三方串口 kext, DriverKit 串口驱动
  需要额外 entitlement 与公证; PTY + `cu.*` 符号链接对所有串口工具透明, 零安装。
- 芯片出厂默认 115200 8N1 流控开, 本软件默认在连接后下发 9600 8N1 无流控(交换机 Console 标准)。
- 蓝牙侧是透传通道, 真正决定能否通讯的是 **芯片 UART 波特率与交换机 Console 波特率一致**。

## 目录结构

```
CH9140Bridge/
├── Package.swift
├── build_app.sh                 # 一键构建 .app
├── Resources/Info.plist         # 含蓝牙权限说明
├── Sources/
│   ├── CH9140Core/              # 核心库
│   │   ├── Protocol/            #   CH9140 协议编解码(0x06/0x86/0x07/0x87/0x88)
│   │   ├── BLE/                 #   CoreBluetooth 中心端
│   │   ├── Serial/              #   PTY 虚拟串口
│   │   ├── Logging/             #   会话日志
│   │   ├── Settings/            #   UserDefaults 设置
│   │   └── BridgeModel.swift    #   粘合层
│   ├── CH9140Bridge/            # SwiftUI App(界面)
│   └── CH9140SelfTest/          # 自检程序(30 项断言)
└── CH9140Bridge.app             # 构建产物
```

## 故障排查

### 已知问题与修复

| 问题 | 症状 | 修复版本 | 详细文档 |
|------|------|----------|----------|
| CPU 占用过高 (156%) | 电脑发热、风扇狂转 | v1.0.1 | [BUGFIX-2026-09-10-HighCPU.md](docs/BUGFIX-2026-09-10-HighCPU.md) |

### 常见问题

**Q: 虚拟串口路径在哪里？**  
A: `~/Library/Application Support/CH9140Bridge/cu.CH9140`（或自定义名称）

**Q: 串口工具提示"Permission denied"？**  
A: 检查系统设置 → 隐私与安全性 → 蓝牙，确保 CH9140Bridge 已授权

**Q: 连接后没有数据？**  
A: 检查 CH9140 模块与目标设备的串口连线，确认波特率一致

**Q: CPU 占用很高？**  
A: v1.0.0 存在此问题，请升级到 v1.0.1+。详见 [BUGFIX 文档](docs/BUGFIX-2026-09-10-HighCPU.md)
