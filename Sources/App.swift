import SwiftUI
import UniformTypeIdentifiers

@main
struct BLEInspectorApp: App {
    @StateObject private var model = BluetoothCentralManager()
    @AppStorage("appearance") private var appearance = "dark"
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            MainView(model:model).preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
                .onChange(of:phase) { _, value in model.lifecycle(background:value != .active) }
        }
    }
}
struct MainView: View {
    @ObservedObject var model: BluetoothCentralManager
    var body: some View {
        TabView {
            DevicesView(model:model).tabItem { Label("Devices",systemImage:"antenna.radiowaves.left.and.right") }
            InspectorView(model:model).tabItem { Label("Inspector",systemImage:"list.bullet.indent") }
            CaptureView(model:model).tabItem { Label("Capture",systemImage:"record.circle") }
            AnalysisView(model:model).tabItem { Label("Analysis",systemImage:"chart.bar.xaxis") }
            SettingsView(model:model).tabItem { Label("Settings",systemImage:"gear") }
        }.tint(.cyan)
        .alert("诊断提示",isPresented:Binding(get:{ model.errorMessage != nil },set:{ if !$0 { model.errorMessage = nil } })) { Button("确定") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }
}
struct DevicesView: View {
    @ObservedObject var model: BluetoothCentralManager
    @State private var search = ""
    @State private var serviceFilter = ""
    @State private var minimumRSSI = -100.0
    @State private var favoritesOnly = false
    var filtered: [Device] { model.devices.filter { (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) && (serviceFilter.isEmpty || $0.advertisement.services.contains { $0.localizedCaseInsensitiveContains(serviceFilter) }) && ($0.rssi >= Int(minimumRSSI) || $0.rssi == 127) && (!favoritesOnly || $0.favorite) }.sorted { $0.rssi > $1.rssi } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.bluetoothState); Text(model.status).foregroundStyle(.secondary)
                    Button(model.scanning ? "停止扫描":"扫描附近 BLE") { if model.scanning { model.stopScan() } else { model.scan() } }
                }
                Section("筛选") {
                    TextField("广播 Service UUID",text:$serviceFilter).textInputAutocapitalization(.never)
                    Toggle("仅收藏",isOn:$favoritesOnly)
                    Slider(value:$minimumRSSI,in:-100 ... -20,step:5) { Text("最低 RSSI") }
                    Text("最低 RSSI：\(Int(minimumRSSI)) dBm；127 表示无有效采样").font(.caption)
                }
                Section("附近与历史设备") {
                    if filtered.isEmpty { ContentUnavailableView("未发现匹配设备",systemImage:"antenna.radiowaves.left.and.right",description:Text("开启蓝牙并扫描；设备需正在广播。")) }
                    ForEach(filtered) { device in NavigationLink { DeviceDetail(model:model,deviceID:device.id) } label: {
                        VStack(alignment:.leading) { Text(device.name); Text("\(device.rssi == 127 ? "RSSI 未知":String(device.rssi)+" dBm") · \(device.favorite ? "收藏":"")").font(.caption); Text(device.id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary); Text(device.lastSeen,style:.relative).font(.caption2) }
                    } }
                }
            }.navigationTitle("BLE Inspector").searchable(text:$search,prompt:"设备名称")
        }
    }
}
struct DeviceDetail: View {
    @ObservedObject var model: BluetoothCentralManager
    let deviceID: UUID
    var device: Device? { model.devices.first { $0.id == deviceID } }
    var body: some View {
        Form {
            if let d = device {
                Section("设备") {
                    Text(d.name); Text(d.id.uuidString).textSelection(.enabled)
                    LabeledContent("RSSI",value:"\(d.rssi) dBm")
                    LabeledContent("MAC",value:"iOS 不可获取")
                    LabeledContent("可连接",value:d.advertisement.connectable.map { $0 ? "是":"否" } ?? "未知")
                    Button(d.favorite ? "取消收藏":"收藏设备") { model.favorite(d) }
                    Button("开始一键自动诊断") { model.connect(d,automatic:true) }
                    Button("连接：专业调试") { model.connect(d,automatic:false) }
                }
                Section("广播") {
                    ForEach(d.advertisement.services,id:\.self) { Text($0).font(.caption.monospaced()) }
                    Text("Manufacturer Data：\(d.advertisement.manufacturer?.hex ?? "无")").textSelection(.enabled)
                    ForEach(d.advertisement.serviceData.keys.sorted(),id:\.self) { k in Text("\(k)：\(d.advertisement.serviceData[k]?.hex ?? "")").font(.caption.monospaced()) }
                    if let tx = d.advertisement.txPower { LabeledContent("TX Power",value:"\(tx) dBm") }
                }
                if let profile = model.profiles.first(where: { $0.matches(d) }) {
                    Section("匹配 Profile：\(profile.name)") {
                        Text(profile.manufacturerObservation)
                        Text("已知服务：\(profile.services.joined(separator:","))")
                        Text("已观察前缀：\(profile.characteristicPrefixes.joined(separator:","))；完整 UUID 以发现结果为准，协议未确认。")
                    }
                }
            } else { Text("设备已从缓存移除，请重新扫描") }
        }.navigationTitle("设备详情")
    }
}
struct InspectorView: View {
    @ObservedObject var model: BluetoothCentralManager
    var body: some View {
        NavigationStack {
            List {
                Section { Text(model.status); Text("诊断阶段：\(model.diagnostic.state.rawValue)"); if model.diagnostic.state == .connecting || model.diagnostic.state == .discovering { ProgressView() }; Button("停止诊断并断开") { model.disconnect() } }
                if model.services.isEmpty { ContentUnavailableView("等待 GATT 发现",systemImage:"list.bullet.indent",description:Text("在 Devices 中选择设备连接。")) }
                ForEach(model.services) { service in
                    DisclosureGroup {
                        ForEach(service.characteristics) { c in NavigationLink { CharacteristicView(model:model,id:c.id) } label: { VStack(alignment:.leading) { Text(c.uuid).font(.caption.monospaced()); Text(c.properties.joined(separator:" · ")).font(.caption2).foregroundStyle(.secondary) } } }
                    } label: { VStack(alignment:.leading) { Text(SIG.name(service.uuid)); Text(service.uuid).font(.caption.monospaced()); Text(service.primary ? "Primary":"Secondary").font(.caption2) } }
                }
            }.navigationTitle("Inspector")
        }
    }
}
struct CharacteristicView: View {
    @ObservedObject var model: BluetoothCentralManager
    let id: String
    var characteristic: GATTCharacteristic? { model.services.flatMap(\.characteristics).first { $0.id == id } }
    var body: some View {
        Form {
            if let c = characteristic {
                Section("结构") { Text(SIG.full(c.uuid)).textSelection(.enabled); Text("Service：\(SIG.full(c.service))"); Text(c.properties.joined(separator:", ")); ForEach(c.descriptors,id:\.self) { Text("Descriptor：\($0)").font(.caption.monospaced()) } }
                Section("操作（只读）") {
                    Button("读取") { model.read(id) }.disabled(!c.properties.contains("Read"))
                    Button(c.notifying ? "停止 Notify / Indicate":"启用 Notify / Indicate") { model.subscribe(id,enabled:!c.notifying) }.disabled(!c.properties.contains("Notify") && !c.properties.contains("Indicate"))
                    Text("写入调试未提供；应用不会发送厂商控制命令。").font(.caption)
                }
                Section("最近数据") {
                    Text("最近可确认读取（通知关闭时）：\(c.lastReadValue?.hex ?? "无")").font(.caption.monospaced()).textSelection(.enabled)
                    if let date = c.lastReadAt { Text(date,format:.dateTime).font(.caption) }
                    Text("Hex：\(c.value?.hex ?? "无")").font(.body.monospaced()).textSelection(.enabled)
                    Text("Base64：\(c.value?.base64EncodedString() ?? "无")").textSelection(.enabled)
                    Text("UTF-8：\(c.value.flatMap { String(data:$0,encoding:.utf8) } ?? "不可解码")").textSelection(.enabled)
                    Text("ASCII：\(c.value.flatMap { String(data:$0,encoding:.ascii) } ?? "不可解码")")
                    if let data = c.value { Text(ProtocolHeuristicsEngine.integers(data)) }
                    if let date = c.updated { Text(date,format:.dateTime) }
                    Text("通知开启期间回调数：\(c.notificationCount)（可能包含读取响应）")
                    if let error = c.error { Text(error).foregroundStyle(.red) }
                }
            } else { Text("连接已更新，该特征值不再有效") }
        }.navigationTitle("Characteristic")
    }
}
struct CaptureView: View {
    @ObservedObject var model: BluetoothCentralManager
    @State private var search = ""
    @State private var eventType = ""
    @State private var since = Date.distantPast
    @State private var until = Date.distantFuture
    @State private var timeFilter = false
    var body: some View {
        NavigationStack {
            List {
                Section("录制") {
                    Text(model.recording ? (model.paused ? "已暂停":"正在录制到本地") : "未录制")
                    Button("开始 / 继续录制") { model.startRecording() }
                    Button(model.paused ? "继续":"暂停") { model.pauseRecording() }.disabled(!model.recording)
                    Button("结束并保存") { model.endRecording() }.disabled(!model.recording)
                    TextField("会话备注 / 事件标记",text:$model.note)
                    Button("添加事件标记") { model.mark() }
                }
                Section("过滤") { TextField("事件类型",text:$eventType); Toggle("时间范围",isOn:$timeFilter); if timeFilter { DatePicker("开始",selection:$since); DatePicker("结束",selection:$until) } }
                Section("实时日志：最近 500 条，完整日志在会话文件中") {
                    ForEach(model.events.reversed().filter { e in (eventType.isEmpty || e.eventType.localizedCaseInsensitiveContains(eventType)) && (!timeFilter || (e.timestamp >= since && e.timestamp <= until)) && (search.isEmpty || [e.deviceName,e.peripheralIdentifier,e.serviceUUID,e.characteristicUUID,e.detail,e.rawHexPayload].compactMap { $0 }.joined(separator:" ").localizedCaseInsensitiveContains(search)) }) { e in
                        VStack(alignment:.leading) { Text("\(e.eventType) · \(e.timestamp.formatted(date:.omitted,time:.standard))").font(.caption); Text(e.characteristicUUID ?? e.detail).font(.caption.monospaced()).lineLimit(3); if e.payload != nil { Text(e.rawHexPayload).font(.caption.monospaced()).lineLimit(4) }; if let error = e.errorDescription { Text(error).foregroundStyle(.red) } }.textSelection(.enabled)
                    }
                }
            }.navigationTitle("Capture").searchable(text:$search,prompt:"设备 / UUID / 内容")
        }
    }
}
struct AnalysisView: View {
    @ObservedObject var model: BluetoothCentralManager
    @State private var first: UUID?
    @State private var second: UUID?
    @State private var result = "选择会话进行被动数据比较"
    @State private var working = false
    @State private var comparePeriods = false
    @State private var baselineStart = Date().addingTimeInterval(-600)
    @State private var baselineEnd = Date().addingTimeInterval(-300)
    @State private var changedStart = Date().addingTimeInterval(-300)
    @State private var changedEnd = Date()
    var body: some View {
        NavigationStack {
            List {
                Section("会话比较（完整会话 / 时间范围）") {
                    Picker("基线",selection:$first) { Text("请选择").tag(Optional<UUID>.none); ForEach(model.history) { Text($0.started.formatted()).tag(Optional($0.id)) } }
                    Picker("变化后",selection:$second) { Text("请选择").tag(Optional<UUID>.none); ForEach(model.history) { Text($0.started.formatted()).tag(Optional($0.id)) } }
                    Toggle("指定两个时间段（可选同一会话）",isOn:$comparePeriods)
                    if comparePeriods { DatePicker("基线开始",selection:$baselineStart); DatePicker("基线结束",selection:$baselineEnd); DatePicker("变化开始",selection:$changedStart); DatePicker("变化结束",selection:$changedEnd) }
                    Button("比较") { compare() }.disabled(first == nil || second == nil || working)
                    if working { ProgressView() }; Text(result).font(.caption.monospaced()).textSelection(.enabled)
                }
                Section("诊断历史与报告") {
                    if model.history.isEmpty { Text("开始并结束一次录制后，会话将显示在这里。") }
                    ForEach(model.history) { r in NavigationLink { SessionView(model:model,record:r) } label: { VStack(alignment:.leading) { Text(r.device?.name ?? "扫描会话"); Text(r.started,format:.dateTime).font(.caption); Text(r.note).font(.caption) } } }
                }
            }.navigationTitle("Analysis").refreshable { await model.refreshHistory() }
        }
    }
    func compare() {
        guard let a = first, let b = second else { return }; working = true
        Task {
            do {
                let x = try await model.store.analysis(a,since:comparePeriods ? baselineStart:nil,until:comparePeriods ? baselineEnd:nil)
                let y = try await model.store.analysis(b,since:comparePeriods ? changedStart:nil,until:comparePeriods ? changedEnd:nil)
                let text = await Task.detached(priority:.utility) { x.comparing(to:y).map { d in
                    "\(d.key)\n帧数 \(d.baselineSamples) → \(d.changedSamples)\n频率 \(d.baselineHz.map { String(format:"%.2f",$0) } ?? "未知") → \(d.changedHz.map { String(format:"%.2f",$0) } ?? "未知") Hz\n末帧差异偏移 \(d.latestChangedOffsets)\n" + d.changedPeriod.facts.joined(separator:"\n") + "\n推测：" + d.changedPeriod.hypotheses.joined(separator:"；")
                }.joined(separator:"\n\n") }.value
                result = text.isEmpty ? "没有数据帧":text
            } catch { result = error.localizedDescription }; working = false
        }
    }
}
struct SessionView: View {
    @ObservedObject var model: BluetoothCentralManager
    let record: SessionRecord
    @State private var hideIdentifiers = true
    @State private var removePayloads = false
    @State private var exportURL: URL?
    @State private var working = false
    @State private var summary = ""
    @State private var historySamples: [BLEEvent] = []
    var body: some View {
        Form {
            Section("会话") { Text(record.id.uuidString); Text(record.note); Text(record.started,format:.dateTime); Text("服务数：\(record.topology.count)") }
            Section("隐私检查") { Toggle("隐藏设备 UUID、名称、备注及自由文字",isOn:$hideIdentifiers); Toggle("移除原始 Payload（含广播数据）",isOn:$removePayloads); Text("二进制数据本身可能含设备身份。分享前请检查；隐藏标识符不会自动识别 Payload 内的个人信息。").font(.caption) }
            Section("导出") {
                ForEach(ExportFormat.allCases,id:\.rawValue) { format in Button("生成 \(format.rawValue.uppercased())") { working = true; exportURL = nil; Task { do { exportURL = try await model.store.export(record,format:format,privacy:PrivacyOptions(hideIdentifiers:hideIdentifiers,removePayloads:removePayloads)) } catch { model.errorMessage = error.localizedDescription }; working = false } }.disabled(working) }
                if working { ProgressView() }; if let url = exportURL { ShareLink(item:url) { Label("系统分享",systemImage:"square.and.arrow.up") } }
            }
            Section("历史原始数据（最近 80 个 value 回调）") {
                ForEach(Array(historySamples.suffix(80).reversed())) { e in VStack(alignment:.leading) { Text(e.timestamp,format:.dateTime).font(.caption); Text(e.characteristicUUID ?? "").font(.caption.monospaced()); Text(e.rawHexPayload).font(.caption.monospaced()).textSelection(.enabled) } }
            }
            Section("数据统计与启发式分析") { Text(summary).font(.caption).textSelection(.enabled) }
        }.navigationTitle("会话报告").task {
            do {
                historySamples = try await model.store.samples(record.id)
                let analysis = try await model.store.analysis(record.id)
                summary = await Task.detached(priority:.utility) { analysis.groups.keys.sorted().map { key in
                    let a = analysis.groups[key]!.result
                    return key+"\n观测："+a.facts.joined(separator:"；")+"\n推测（未确认）："+a.hypotheses.joined(separator:"；")
                }.joined(separator:"\n\n") }.value
            } catch { summary = error.localizedDescription }
        }
    }
}
struct SettingsView: View {
    @ObservedObject var model: BluetoothCentralManager
    @State private var importing = false
    @AppStorage("appearance") private var appearance = "dark"
    var body: some View {
        NavigationStack { Form {
            Section("外观") { Picker("主题",selection:$appearance) { Text("深色").tag("dark"); Text("浅色").tag("light"); Text("跟随系统").tag("system") } }
            Section("扫描与连接") { Slider(value:$model.scanSeconds,in:5 ... 120,step:5); Text("扫描超时：\(Int(model.scanSeconds)) 秒"); Toggle("自动诊断订阅 Notify / Indicate",isOn:$model.autoSubscribe); Toggle("收藏设备意外断线后重连（最多 2 次）",isOn:$model.reconnectFavorites) }
            Section("Profile") { ForEach(model.profiles) { Text($0.name) }; Button("导入 Profile JSON") { importing = true }; Text("只匹配名称与提示已观察 UUID；不含任何车辆控制命令。") }
            Section("能力边界") { Text("仅访问本 App 连接设备提供的 GATT。不能抓取 BLE 链路层、其他 App 的全部蓝牙通信或完整经典蓝牙数据；真实 MAC 地址不可获取；加密 / 私有协议不保证能理解。所有日志仅本地保存。保持前台以持续采集。") }
            Section("存储与版本") { Text("每会话最多 64 个约 4 MiB 分段；达到上限停止录制并提示。UI 最近 500 条；分析按完整会话增量统计（最多 4096 个特征实例，重复模式索引最多 1024 种）；导出流式读取完整会话。总日志空间达到约 1 GiB 停止录制。历史文件请通过 iOS 文件 App 管理删除。导出副本也需手动删除。"); Text("BLE Inspector 1.0 · iOS 17+") }
        }.navigationTitle("Settings").fileImporter(isPresented:$importing,allowedContentTypes:[.json]) { result in
            do { let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }; let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0; guard size <= 262144 else { throw NSError(domain:"Profile",code:1,userInfo:[NSLocalizedDescriptionKey:"Profile 文件超过 256 KiB"]) }; try model.importProfiles(Data(contentsOf:url)) } catch { model.errorMessage = error.localizedDescription }
        } }
    }
}
