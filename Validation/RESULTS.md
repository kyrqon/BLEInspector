# 实际验证结果

日期：2026-10-12。环境：Debian 13 x86_64，临时下载的官方 Swift 6.0.3 Linux 工具链。没有 macOS、Xcode、iOS SDK 或蓝牙硬件。

## 已运行

- `swift test`：**27 个 XCTest，0 失败**。源代码及测试按 Swift 6 语言模式编译。覆盖 SIG UUID、Hex / Base64、空二进制与错误编码、字节差异、两会话频率、模拟数据统计 / 周期 / 计数器 / 校验提示、事件序列化、CSV 引号换行、Profile 加载校验、广播模型序列化、Mock 状态机、文件轮转、64 分段上限、损坏日志报错、四种导出以及隐私隐藏；新增完整 6000 帧会话和早期时间段、重复 UUID 实例、Mock 只读操作计划、广播数据脱敏、导出期间继续录制、通知状态脱敏后保留测试；新增重复连接策略和两种 TXT 导出 / 脱敏测试。
- `swiftc -frontend -parse Sources/*.swift Tests/CoreTests.swift`：语法解析通过。包括 SwiftUI / CoreBluetooth 源文件，但**没有用 iOS SDK 类型检查或链接**。
- `python3 Validation/check_project.py`：36 个 PBX 对象，所有工程引用 / 源文件、权限 plist、共享 Scheme、JSON 资源通过；源码中不存在 `writeValue(` 调用。

完整核心测试输出见 `swift-tests.txt`。复现命令：

```sh
swift test
python3 Validation/check_project.py
swiftc -frontend -parse Sources/*.swift Tests/CoreTests.swift
```

云端缓存目录只读，第一次测试启动失败；将 CLANG_MODULE_CACHE_PATH、SWIFTPM_MODULECACHE_OVERRIDE、XDG_CACHE_HOME 和 SwiftPM cache-path 设置为工作区后通过。这个环境问题与 App 源码无关。

## 没有验证

- Xcode 打开工程、iOS SDK 全工程类型检查 / 构建、Test Host 运行、签名、安装。
- 真实权限弹窗、扫描 / GATT / 通知行为、各种厂商兼容性及雅迪实车。
- 长时间吞吐 / 能耗、前后台调度、实际断线和重连、VoiceOver / 动态字体人工验收、真实 Share Sheet。
- App 测试 Target 的 CoreBluetooth 广播字典解析测试仅提供代码，Linux 核心包不运行它。

不能根据核心包成功声称 iOS App 编译成功。Mac 真机步骤见 MAC_ACCEPTANCE.md。

## 已实现代码的范围和限制

真实 CoreBluetooth 扫描 / 连接 / 服务发现 / Read / Notify、日志保存与流式导出路径已编写并接入 UI；没有假设备数据填充 UI。模拟事件只用于单元测试。

本版没有用户写入功能、后台持续采集、完整 SIG 字典或可靠私有协议分帧器。启发式算法只有提示；按完整会话增量统计，字节位置前 512 字节、重复模式最多索引 1024 种，最多 4096 个实例；跨会话实例发现顺序可能改变，旧日志缺少实例 ID 时仍聚合。诊断硬件层未抽成完整 Mock Transport，现有状态机和模拟事件测试不是 CoreBluetooth 集成测试。过载、磁盘失败、强杀或掉电可能导致日志未全部保存，限制与告警见 README。

版本 1.1：24 个核心测试通过；图标尺寸、无透明通道和 AppIcon 编译设置静态验证通过。界面跳转、真实重复点击处理、图标在主屏幕显示、TXT 的系统分享 / 存储到文件仍需 Mac + iPhone 验收。

版本 1.2：新增录制保护、定向清理 / 防复活、并发导出删除测试；最低部署版本和原生玻璃 API 静态检查。云端没有 iOS 26 SDK，Liquid Glass 外观、左划 / 详情删除交互仍需 Xcode 26 与 iPhone 验证。
