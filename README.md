# SakuraDeBug 🌸

一个樱花风格的 iOS JIT 调试工具（macOS）。

通过 Apple ID 签名 IPA 并安装到设备，随后通过 RSD 回环隧道为应用启用 JIT（Just-In-Time）调试能力，供调试器附加使用。

## 功能特性

- 🌸 樱花风格界面：粉白渐变背景 + 飘落花瓣动画
- 📦 **IPA 导入**：导入本地 `.ipa` 文件并解析
- 🔑 **Apple ID 签名**：使用 Apple ID 登录，对 IPA 重新签名（基于 AltSign）
- 📲 **设备连接**：通过 idevice 与 iOS 设备配对、通信
- ⚡ **JIT 启用**：通过 LocalDevVPN 回环隧道 + debugserver 附加启用 JIT
- 🔐 **配对文件管理**：导入/管理设备配对文件
- 🧬 **USB 一键生成配对文件**：无需从其他电脑导出，USB 连上设备即可直接配对并生成配对文件（参考 StikPair）
- 📡 **设备自配对（无需电脑）**：本机伪装成配对主机，在「设置 › 开发者模式」里直接与本机配对，全程不经过电脑（参考 StikPair）

## 系统要求

- macOS 14+
- Xcode 16+
- iOS 设备已开启开发者模式（Developer Mode）

## 构建

1. 克隆仓库后，在 `SakuraDeBug.xcodeproj` 的 **Signing & Capabilities** 中选择你自己的开发者团队（`DEVELOPMENT_TEAM` 已留空，请填入自己的 Team ID）
2. 在 Xcode 中打开 `SakuraDeBug.xcodeproj`
3. 选择你的 macOS 目标，点击 Run

> 注意：本项目依赖 `idevice` 静态库（`SakuraDeBug/idevice/`，由 [jkcoxson/idevice](https://github.com/jkcoxson/idevice) 构建，MIT 许可），已随仓库提供，无需额外安装。

## 使用流程

1. **获取配对文件（三选一）**：
   - **设备自配对（推荐，无需电脑）**：点「开始自配对」，按提示到本机「设置 › 隐私与安全 › 开发者模式」选择 SakuraDeBug 并输入应用内显示的 PIN，配对文件自动生成
   - **USB 一键生成**：数据线连接设备（解锁 + 开启开发者模式），在应用里点击「USB 生成」，应用通过 CoreDeviceProxy USB 隧道完成配对并自动生成配对文件
   - **导入现有配对文件**：从已与设备建立信任的电脑导出配对文件（如 `usbmuxd` 的配对记录），在应用中导入
2. **导入 IPA**：选择要调试的 `.ipa` 文件
3. **登录 Apple ID**：输入 Apple ID 与密码（也可导入 Anisette JSON），对应用签名
4. **连接设备并启用 JIT**：应用会通过 RSD 回环隧道与设备通信，启动目标 App 并通过 debugserver 附加，随后 detach，保留 `CS_DEBUGGED` 标志使 JIT 保持开启

## 技术原理

JIT 启用核心链路（移植自 [StikDebug/StikJIT](https://github.com/StikDebug/StikJIT)）：

```
导入配对文件 → LocalDevVPN 回环隧道(10.7.0.1:49152)
→ tunnel_create_rppairing → remote_server_connect_rsd + debug_proxy_connect_rsd
→ process_control_launch_app 启动目标 App（须带 get-task-allow）
→ debugserver 发送 vAttach;<pidhex> 附加 → 发送 D detach（保留 CS_DEBUGGED 标志）
```

配对文件生成链路（参考 StikPair / jkcoxson/idevice_pair）：

```
USB 一键生成：
usbmuxd 枚举 USB 设备 → usbmuxd_provider_new 建立设备连接
→ tunnel_pair_usb 走 CoreDeviceProxy USB 隧道 + RPPairing 协议配对
→ rp_pairing_file_write 输出配对文件（与 JIT 隧道的 tunnel_create_rppairing 完全兼容）

设备自配对（无需电脑）：
App 本机伪装为 PairableHost（RPPairing 配对主机）→ NetService 广播 _remotepairing-pairable-host._tcp.
→ 在「设置 › 开发者模式」选择 SakuraDeBug 并发起配对 → 输入 App 内显示的 PIN
→ RPPairing 握手完成 → 配对文件直接写入标准位置，JIT 立即可用
```

## 致谢

- [jkcoxson/idevice](https://github.com/jkcoxson/idevice) — iOS 设备通信库（MIT）
- [AltSign](https://github.com/rileytestut/AltSign) — Apple ID 签名
- [StikDebug/StikJIT](https://github.com/StikDebug/StikJIT) — JIT 启用逻辑参考
- [StikDebug/StikPair](https://github.com/StikDebug/StikPair) — 配对文件生成思路参考

## 许可证

[MIT](LICENSE)
