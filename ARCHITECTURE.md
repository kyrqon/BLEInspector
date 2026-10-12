# 架构

## 分层

- `Core.swift`：可序列化设备 / 广播 / GATT / 事件模型、SIG 字典、Profile Repository、诊断状态机、字节差异、DataDiffEngine 和协议启发式引擎。仅依赖 Foundation，可脱离蓝牙测试。
- `Bluetooth.swift`：BluetoothCentralManager 作为 ObservableObject ViewModel，同时封装原工程的 CoreBluetooth Central / Peripheral 委托服务。CB 对象、扫描、连接、发现、超时、手动操作和 UI 快照只在主串行队列使用。通过稳定的服务实例 / 特征实例路径区分重复 UUID。类型标注 @MainActor，公开方法、状态和 CB 对象均由编译器隔离；CoreBluetooth 的旧式委托采用 @preconcurrency conformance，回调配置在主队列；主 RunLoop Timer 显式恢复 MainActor。
- `Storage.swift`：EventLogStore 独立串行写盘和读取队列、批量缓冲、定时刷盘、轮转、有界排队、Session Repository 和流式 ExportService。跨队列数据使用 Sendable 值模型；锁仅保护排队准入计数，文件和缓冲仅 IO 队列访问。onError 在初始化后只设一次，由调用者转发到主队列。
- `App.swift`：SwiftUI 原生五 Tab 及设备、特征、会话详情。重分析在 Task.detached，文件导出在存储队列。深色默认，浅色和系统主题可选；原生控件支持动态字体与基本 VoiceOver 标签，仍需真机可访问性审计。

为减少原小工程重构复杂性，本版没有拆成十几个薄 Service 类。硬件与 ViewModel 暂在同一文件，其余模型、持久化、分析和视图已分离。未来可在保持值模型和测试边界的前提下拆分硬件服务及连接 Repository。

## 状态和操作

idle → connecting → discovering → collecting。停止进入 stopped；权限变化、断开、超时或错误进入 failed。只有相应前序状态允许 connected / discovered 事件推进。发现 Pending Set 包含服务、Included Services、特征和描述符；没有剩余项后启动串行读取 / 订阅。该阶段完成表示拓扑已枚举，不表示每个 Read / Notify 都成功。

操作队列一次一个读取或订阅，8 秒超时不重试未知操作。发现过程整体 45 秒超时。通知订阅后读取响应与通知无法可靠对应；迟到回调也不能可靠关联请求，所有分析和报告保留歧义。服务变化会清空失效 CB 引用并重新发现；断线不会丢弃已采集日志。

## 持久化和导出

会话元数据原子替换；JSONL 原始数据分段追加。每事件记录墙上时间、单调时间、会话、设备、服务、特征、类型、方向、长度、Hex、Base64、描述及错误。二进制不执行或信任。主线程仅显示小窗口。超过会话 / 总容量 / 队列上限时显式停止保存，不默默覆盖旧证据。

JSON / JSONL / CSV 完整事件采用固定大小读块逐行处理；读取首先在写盘队列刷盘并记录各文件长度，再在独立读取队列逐行扫描固定快照，避免长导出阻塞新通知。报告 / UI 使用 FrameAccumulator 和 SessionAnalysis 对完整会话或指定时间段做有界增量统计；前 512 字节分析、1024 种重复模式索引、4096 个特征实例上限均在结果中说明，不声称完整协议解码。导出脱敏在生成副本时执行，原始文件不变。原始 Payload 未自动识别敏感信息。强杀、磁盘失败和持续吞吐超过写盘能力仍可能丢失末尾记录，错误会在可运行的 App 中提示。

## 扩展点

Profile 是无命令数据配置，未来可扩展 SIG 字典、标准特征解码器、特征实例级跨会话匹配、独立 BLETransport Mock、增量大日志分析和用户授权写入。新日志按 Service UUID / Characteristic UUID / characteristicInstanceID 区分重复实例。实例 ID 含发现序号，跨会话顺序可能改变，因此对应关系需要人工核实。旧日志缺少实例 ID 时仍按 UUID 聚合。ReadOnlyDiagnosticPlanner 为实际硬件层生成仅 Read / Subscribe 的操作计划，并由 Mock BLE 测试验证不对仅 Write 特征生成指令。完整 Central / Peripheral 委托集成仍需 iOS 硬件验证。

## 1.2 平台与历史删除

App / Test Target 最低 iOS 26，使用 Xcode 26 SwiftUI 原生 Liquid Glass。独立 Foundation 核心包仍可在 Linux / macOS 测试，不调用玻璃 API。状态卡遵循 accessibilityReduceTransparency；日志保持原生可读文本。

SessionDeletionPolicy 保护当前正在录制（含暂停）会话。删除在写盘队列标记 UUID 墓碑、丢弃目标待写缓冲，然后在读取队列清理目录及匹配导出副本；正在读取的目标会话会在下一个块边界取消，失败导出自动清理。墓碑阻止迟到 save / append 重建删除会话。读写其他会话不受删除影响。清理完成重新检查容量，ViewModel 同步清空当前会话引用和目标日志窗口。
