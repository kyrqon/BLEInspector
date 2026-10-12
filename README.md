# BLE Inspector

通用、仅本地保存数据的 iOS BLE 诊断应用。基于提供的 YadeaBLEProbe-Xcode.zip 重构，最低 iOS 17，Swift 6，SwiftUI / CoreBluetooth，无第三方运行时依赖。

**当前交付包含真实 CoreBluetooth 硬件实现，不是模拟 UI。云端只验证核心 Swift 包和源码语法；没有执行 iOS SDK 编译、签名或 iPhone 测试。** 请先按下面步骤完成 Mac 验收。

## 免费个人真机安装

1. 在 Mac App Store 安装 Xcode 16 或更新版本，启动并完成平台组件安装。iPhone 的系统版本必须被该 Xcode 支持。
2. 解压交付 ZIP，打开 `BLEInspector.xcodeproj`，选择共享 Scheme `BLEInspector`。
3. Xcode → Settings → Accounts，登录普通 Apple ID。无需加入付费 Apple Developer Program。
4. 选择 BLEInspector Target → Signing & Capabilities，开启 Automatically manage signing，Team 选择你的 **Personal Team**。
5. 将 Bundle Identifier 从 `com.example.BLEInspector` 改为自己唯一的值，例如 `com.yourname.bleinspector`。运行测试时同样设置 BLEInspectorTests 的签名 Team 和唯一 Bundle Identifier。
6. 用 USB 将 iPhone 连接 Mac，解锁并信任电脑。Xcode 的运行目标选择你的 iPhone。
7. iPhone → 设置 → 隐私与安全性 → 开发者模式，打开并按系统要求重启确认。若该选项未出现，先尝试 Xcode 配对 / 运行。
8. 点击 Xcode Run（⌘R）。如果系统要求，在设置 → 通用 → VPN 与设备管理中信任个人开发者证书。
9. 免费签名有设备、App 数量及有效期限制（通常约七天需重新安装）；以 Apple 当前规则为准。免费签名用于自己的设备开发调试，无法据此发布普通用户可直接安装的 IPA。

## 扫描与自动诊断

1. 首次启动允许蓝牙权限；权限被拒绝时到设置中允许 BLE Inspector 使用蓝牙。模拟器无法替代真实 BLE 测试。
2. Devices → 扫描附近 BLE。名称、设备 UUID、RSSI、可连接标记、服务 UUID、Service Data 和 Manufacturer Data 来自系统广播字典；真实 MAC 地址不可获取。
3. 用名称搜索、服务 UUID、RSSI 或收藏筛选。结果与历史设备合并，注意“最近发现时间”，历史条目不表示现在在线。
4. 打开设备详情 → 开始一键自动诊断。自动创建录制会话、连接、发现服务 / Included Services / 特征 / 描述符，串行读取 Read 特征并订阅 Notify / Indicate。
5. Inspector 展示发现进度、服务树和特征详情。Read / Notify 必须有对应属性，设备仍可能拒绝、要求系统配对或返回错误。App 不绕过权限和鉴权。
6. Capture 查看日志并添加备注或事件标记。可暂停保存，蓝牙接收及屏幕更新仍继续；继续后仅保存之后的数据。
7. 停止自动诊断请在 Inspector 选择“停止诊断并断开”；普通断线会保留会话，便于查看错误并手动结束保存。收藏设备的意外断线重连选项默认关闭，开启后最多两次。
8. 扫描默认 20 秒，连接 15 秒，发现 45 秒，单次读取 / 订阅 8 秒超时。通知持续到用户停止、连接断开或系统暂停。

## 专业调试与录制

- 设备详情 → 连接：专业调试，只发现结构，自动读取和订阅关闭。
- 特征详情可手动 Read 或启停 Notify / Indicate，展示完整 UUID、属性、描述符、Hex / Base64 / ASCII / UTF-8、前 8 字节整数大小端解释、更新时间、最近可确认读取（通知关闭时）、错误及通知开启期间回调数。
- 应用不提供 Write 调试，因此不会发送用户未授权的控制数据。Notify / Indicate 订阅本身会改变 CCCD，属于 GATT 订阅操作，并非厂商控制命令。
- 若需采集扫描广播，先在 Capture 开始录制，再在 Devices 扫描。
- Capture → 结束并保存。Analysis 展示会话历史、最近原始 value 数据和启发式统计。采集车辆按钮变化时，由你手动操作设备；App 只观察数据。

## 比较与导出

1. Analysis 选择基线和变化后的两次会话；也可选择同一会话并开启“指定两个时间段”。
2. 点击比较，展示特征采样次数、采样频率、两个时间段末帧的变化偏移，以及变化时间段内逐帧变化、重复模式和启发式提示。分析逐行扫描完整会话并按指定时间筛选，使用增量统计，不截断为最近帧。字节位置分析覆盖前 512 字节；重复模式索引最多 1024 种，超过时显示数量下界；最多分析 4096 个特征实例。完整原始证据仍可导出。
3. 打开历史会话 → 隐私检查。默认隐藏设备 UUID、名称、备注及自由文本；Payload 可能仍含身份信息，不会自动识别私有二进制中的个人数据。可选择移除 Payload（也移除广播二进制和拓扑最近值）。
4. 生成 JSON / JSONL / CSV / Markdown，然后点击系统分享。导出在独立读取队列逐行读盘，以刷盘后的文件长度为快照，不阻塞新通知写盘，不将整个日志加载到内存。Markdown 是摘要，应和 JSONL 一起分享以保留原始证据。
5. 将 JSONL 文件附加给 ChatGPT，建议说明：设备类别、采集时的操作、两个时间段和你的分析目标；要求严格区分观测事实与推测。不要上传你不愿分享的设备身份或敏感 Payload。
6. JSONL 首行是 `session_context` 事件，其 Base64 Payload 是 UTF-8 JSON 会话元数据（含广播、GATT 拓扑和 RSSI 样本）；随后每行一个事件。每行独立合法 JSON。value 事件的 characteristicInstanceID 区分重复 UUID；跨会话仅能按发现顺序对齐实例，不能证明顺序相同的实例一定是同一个物理特征。JSON 另含 analysis 结构化事实与推测摘要。CSV 遵循双引号转义，字段可能有换行，请使用标准 CSV 解析器。

## Profile

内置雅迪 Q17 Pro 配置只匹配 `YD61236288` 并提示已观察服务与特征前缀。不推断完整特征 UUID，不预设车辆协议或命令。发现结果才是实际完整 UUID 的证据。

Settings 可导入 JSON Profile 数组，样例见 `Profiles/yadea-q17-pro.json`。导入会替换 Profile 列表；每份配置仅提供提示，不改变通用只读发现引擎。限制 256 KiB / 100 条，检查 UUID 和重复 ID。

## 存储与性能

- Documents/BLEInspector/<Session UUID>/session.json 与 events-0000.jsonl 等分段。iOS 文件 App → 我的 iPhone → BLE Inspector 可管理原始会话与 Exports 导出副本。
- UI 最近 500 条事件，更新最多每 0.2 秒一次；日志写入在独立串行队列，缓冲最多约 64 KiB 或一秒触发刷盘。
- 单会话最多 64 段，每段约 4 MiB；本地根目录约 1 GiB 时停止写入。容量检查有五秒采样间隔，小幅超额可能发生。导出副本也会占空间，请手动清理。
- 写盘排队最多 4096 条；超过上限会明确报错并停止录制，过载事件可能未保存。磁盘错误也会提示。App 被系统强制结束时最后一秒缓冲可能未落盘；不能保证掉电或强杀时零丢失。
- 本版不申请后台蓝牙运行模式；进入后台停止扫描并刷盘，iOS 可能挂起通知接收，持续采集请保持前台。

## 测试

Mac 上运行 `swift test` 可验证独立核心包；Xcode ⌘U 可运行 App 测试 Target，额外包含 CoreBluetooth 广播字典解析测试。Linux 不运行该额外测试。

云端结果见 `Validation/swift-tests.txt` 与 `Validation/RESULTS.md`。纯 Swift 核心测试不能证明 UI / CoreBluetooth 在 iOS 上编译、签名和工作；请依据 `Validation/MAC_ACCEPTANCE.md` 验收。

## CoreBluetooth 限制

不能任意抓取 BLE 链路层数据包；不能监听其他 App 的全部蓝牙通信；不能获取真实 MAC；不能完整抓取经典蓝牙；不保证理解私有或加密协议。通知开启期间，CoreBluetooth 的同一个 value 回调也可能是读取响应，因此回调计数不是绝对准确的空中通知计数。
