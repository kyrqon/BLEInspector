import Foundation
import CoreBluetooth
import Combine

/// CoreBluetooth delegates and published snapshots share the main serial queue.
/// Expensive persistence/export/analysis runs separately; no CB objects cross queues.
@MainActor
final class BluetoothCentralManager: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var profiles = [DeviceProfile.yadea]
    @Published var devices: [Device] = []
    @Published var services: [GATTService] = []
    @Published var events: [BLEEvent] = []
    @Published var bluetoothState = "蓝牙初始化"
    @Published var status = "未连接"
    @Published var scanning = false
    @Published var diagnostic = DiagnosticMachine()
    @Published var recording = false
    @Published var paused = false
    @Published var current: SessionRecord?
    @Published var history: [SessionRecord] = []
    @Published var errorMessage: String?
    @Published var scanSeconds = 20.0 { didSet { defaults.set(scanSeconds, forKey: "scanSeconds") } }
    @Published var autoSubscribe = true { didSet { defaults.set(autoSubscribe, forKey: "autoSubscribe") } }
    @Published var reconnectFavorites = false { didSet { defaults.set(reconnectFavorites, forKey: "reconnectFavorites") } }
    @Published var note = ""
    @Published var rssiSamples: [Int] = []
    let store: EventLogStore
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var serviceObjects: [CBService] = []
    private var operationQueue: [(String, Bool?)] = []
    private var currentOperation: (String, Bool?)?
    private var operationTimer: Timer?
    private var chars: [String: CBCharacteristic] = [:]
    private var favoriteIDs: Set<UUID> = []
    private var autoDiagnostic = false
    private var scanTimer: Timer?
    private var connectionTimer: Timer?
    private var rssiTimer: Timer?
    private var pending: Set<String> = []
    private var reconnectAttempts = 0
    private var allowReconnect = false
    private var userStopped = false
    private var devicePersistTimer: Timer?
    private let defaults = UserDefaults.standard
    private var dirtyUI = false
    private var uiTimer: Timer?
    private var eventBuffer: [BLEEvent] = []
    private struct ValueSnapshot {
        var value: Data?
        var updated: Date?
        var notificationIncrement = 0
        var lastReadValue: Data?
        var lastReadAt: Date?
        var error: String?
    }
    private var pendingValues: [String: ValueSnapshot] = [:]
    override init() {
        let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("BLEInspector",isDirectory:true)
        store = EventLogStore(root:root)
        super.init()
        if defaults.object(forKey: "scanSeconds") != nil { scanSeconds = max(5, min(120, defaults.double(forKey: "scanSeconds"))) }
        if defaults.object(forKey: "autoSubscribe") != nil { autoSubscribe = defaults.bool(forKey: "autoSubscribe") }
        reconnectFavorites = defaults.bool(forKey: "reconnectFavorites")
        favoriteIDs = Set((defaults.stringArray(forKey:"favorites") ?? []).compactMap(UUID.init(uuidString:)))
        if let data = defaults.data(forKey:"devices"), let saved = try? JSONDecoder().decode([Device].self,from:data) { devices = saved }
        store.onError = { [weak self] message in DispatchQueue.main.async { self?.errorMessage = message; self?.recording = false } }
        central = CBCentralManager(delegate:self,queue:.main)
        uiTimer = mainTimer(interval:0.2,repeats:true) { [weak self] in self?.publishEvents() }
        if let data = defaults.data(forKey:"profiles"), let loaded = try? DeviceProfileRepository.load(data) { profiles = loaded }
        Task { await refreshHistory() }
    }
    private func mainTimer(interval: TimeInterval, repeats: Bool, action: @escaping @MainActor @Sendable () -> Void) -> Timer {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { action() }
        }
    }
    func importProfiles(_ data: Data) throws {
        let loaded = try DeviceProfileRepository.load(data); profiles = loaded; defaults.set(data,forKey:"profiles")
    }
    func refreshHistory() async { do { let h = try await store.history(); await MainActor.run { self.history = h } } catch { await MainActor.run { self.errorMessage = error.localizedDescription } } }
    private func publishEvents() {
        guard dirtyUI || !pendingValues.isEmpty else { return }; dirtyUI = false
        if !pendingValues.isEmpty {
            var topology = services
            for i in topology.indices {
                for j in topology[i].characteristics.indices {
                    if let snapshot = pendingValues[topology[i].characteristics[j].id] {
                        if let updated = snapshot.updated { topology[i].characteristics[j].value = snapshot.value; topology[i].characteristics[j].updated = updated }
                        if let at = snapshot.lastReadAt { topology[i].characteristics[j].lastReadValue = snapshot.lastReadValue; topology[i].characteristics[j].lastReadAt = at }
                        topology[i].characteristics[j].notificationCount += snapshot.notificationIncrement
                        topology[i].characteristics[j].error = snapshot.error
                    }
                }
            }
            pendingValues.removeAll(keepingCapacity:true); services = topology
        }
        events.append(contentsOf:eventBuffer); eventBuffer.removeAll(keepingCapacity:true)
        if events.count > 500 { events.removeFirst(events.count-500) }
    }
    private func log(_ type: String, _ detail: String = "", service: String? = nil, characteristic: String? = nil, instanceID: String? = nil, notifying: Bool? = nil, data: Data? = nil, error: Error? = nil, peripheral: CBPeripheral? = nil) {
        let p = peripheral ?? active
        let outbound = ["connect_attempt","scan_started","read_requested","subscription_requested"].contains(type)
        let inbound = data != nil || ["advertisement","value","value_error","rssi","service","services","characteristic","characteristics","descriptors","included_services","subscription"].contains(type)
        var event = BLEEvent(sessionID:current?.id ?? UUID(),peripheralIdentifier:p?.identifier.uuidString,deviceName:p?.name,serviceUUID:service,characteristicUUID:characteristic,eventType:type,direction:outbound ? "outbound" : inbound ? "inbound" : "system",payload:data,detail:detail,errorDescription:error?.localizedDescription)
        event.characteristicInstanceID = instanceID; event.notificationEnabled = notifying
        eventBuffer.append(event); if eventBuffer.count > 500 { eventBuffer.removeFirst() }; dirtyUI = true
        if recording && !paused { store.append(event) }
        if let error { errorMessage = error.localizedDescription }
    }
    func startRecording() {
        guard !recording else { if paused { pauseRecording() }; return }
        let record = SessionRecord(id:UUID(),started:Date(),note:note,device:devices.first { $0.id == active?.identifier },topology:services)
        current = record; recording = true; paused = false; store.save(record); log("session_started")
    }
    func pauseRecording() { guard recording else { return }; if paused { paused = false; log("session_resumed") } else { log("session_paused"); paused = true } }
    func mark() { log("marker",note); if var r = current, r.ended == nil { r.note = note; current = r; store.save(r) } }
    func endRecording() {
        guard var r = current, r.ended == nil else { return }; publishEvents(); paused = false; log("session_ended"); r.ended = Date(); r.note = note; r.topology = services; r.rssiSamples = rssiSamples
        r.device = devices.first { $0.id == active?.identifier } ?? r.device; current = r; recording = false; paused = false; store.save(r)
        Task { await refreshHistory() }
    }
    func favorite(_ device:Device) {
        if favoriteIDs.contains(device.id) { favoriteIDs.remove(device.id) } else { favoriteIDs.insert(device.id) }
        defaults.set(favoriteIDs.map(\.uuidString),forKey:"favorites")
        if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i].favorite = favoriteIDs.contains(device.id) }; persistDevices()
    }
    private func persistDevices() { if let data = try? JSONEncoder().encode(Array(devices.prefix(200))) { defaults.set(data,forKey:"devices") } }
    func scan() {
        guard central.state == .poweredOn else { errorMessage = "请在系统设置允许蓝牙权限并开启蓝牙"; return }
        guard active == nil else { errorMessage = "请先断开当前设备再扫描"; return }
        stopScan(); scanning = true
        central.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:true]); log("scan_started")
        scanTimer = mainTimer(interval:max(5,min(scanSeconds,120)),repeats:false) { [weak self] in self?.stopScan(); self?.status = "扫描时间结束" }
        devicePersistTimer = mainTimer(interval:2,repeats:true) { [weak self] in self?.persistDevices() }
    }
    func stopScan() { let wasScanning = scanning; central.stopScan(); scanning = false; if wasScanning { log("scan_stopped") }; scanTimer?.invalidate(); devicePersistTimer?.invalidate(); persistDevices() }
    func connect(_ device:Device, automatic:Bool) {
        guard central.state == .poweredOn else { errorMessage = "蓝牙尚未就绪"; return }
        guard active == nil else { errorMessage = "已有连接或连接请求，请先断开"; return }
        guard device.advertisement.connectable != false else { errorMessage = "广播标记为不可连接"; return }
        guard let p = peripherals[device.id] ?? central.retrievePeripherals(withIdentifiers:[device.id]).first else { errorMessage = "历史设备暂不可用，请重新扫描"; return }
        autoDiagnostic = automatic; reconnectAttempts = 0; allowReconnect = true; userStopped = false; services = []; chars = [:]; rssiSamples = []; pending = []
        active = p; p.delegate = self; stopScan(); diagnostic.start(); status = "正在连接 \(device.name)"
        if automatic { startRecording() }; log("connect_attempt"); central.connect(p,options:nil); armTimeout(seconds:15)
    }
    private func armTimeout(seconds:Double) {
        connectionTimer?.invalidate(); connectionTimer = mainTimer(interval:seconds,repeats:false) { [weak self] in
            guard let self, let p = self.active else { return }; self.allowReconnect = false; self.diagnostic.fail(); self.status = "连接 / 发现超时"; self.log("timeout",self.pending.sorted().joined(separator:",")); self.central.cancelPeripheralConnection(p)
        }
    }
    func disconnect() {
        allowReconnect = false; userStopped = true; autoDiagnostic = false; operationQueue = []; currentOperation = nil; operationTimer?.invalidate(); stopScan(); connectionTimer?.invalidate(); rssiTimer?.invalidate(); pending = []
        if let p = active { central.cancelPeripheralConnection(p) }; diagnostic.stop(); status = "已停止"; endRecording()
    }
    func lifecycle(background:Bool) {
        if background { stopScan(); if recording { store.save(snapshot()) }; Task { await store.barrier() }; status = active == nil ? "已进入后台":"后台可能暂停采集，请保持前台" }
    }
    func snapshot() -> SessionRecord { publishEvents(); var r = current ?? SessionRecord(id:UUID(),started:Date(),note:note,device:nil,topology:services); r.topology = services; r.rssiSamples = rssiSamples; r.note = note; if let device = devices.first(where: { $0.id == active?.identifier }) { r.device = device }; return r }
    func centralManagerDidUpdateState(_ central:CBCentralManager) {
        let names:[CBManagerState:String] = [.unknown:"未知",.resetting:"蓝牙重置",.unsupported:"不支持蓝牙",.unauthorized:"蓝牙权限被拒绝",.poweredOff:"蓝牙关闭",.poweredOn:"蓝牙已开启"]
        bluetoothState = names[central.state] ?? "未知"; log("bluetooth_state",bluetoothState)
        if central.state != .poweredOn { for i in services.indices { for j in services[i].characteristics.indices { services[i].characteristics[j].notifying = false } }; chars = [:]; serviceObjects = []; stopScan(); connectionTimer?.invalidate(); rssiTimer?.invalidate(); active = nil; pending = []; operationQueue = []; currentOperation = nil; operationTimer?.invalidate(); diagnostic.fail(); status = "连接不可用" }
    }
    nonisolated static func advertisement(_ data:[String:Any], fallback:String?) -> Advertisement {
        let services = ((data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []) + ((data[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? [])
        let sd = data[CBAdvertisementDataServiceDataKey] as? [CBUUID:Data] ?? [:]
        return Advertisement(name:data[CBAdvertisementDataLocalNameKey] as? String ?? fallback ?? "未命名",services:services.map(\.uuidString),serviceData:Dictionary(uniqueKeysWithValues:sd.map { ($0.key.uuidString,$0.value) }),manufacturer:data[CBAdvertisementDataManufacturerDataKey] as? Data,connectable:(data[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,txPower:(data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue)
    }
    func centralManager(_ central:CBCentralManager,didDiscover p:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber) {
        peripherals[p.identifier] = p
        let device = Device(id:p.identifier,advertisement:Self.advertisement(advertisementData,fallback:p.name),rssi:RSSI.intValue,lastSeen:Date(),favorite:favoriteIDs.contains(p.identifier))
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) { devices[i] = device } else { devices.append(device) }
        if devices.count > 200 { let removable = devices.firstIndex { !$0.favorite && $0.id != p.identifier }; if let removable { devices.remove(at:removable); peripherals = peripherals.filter { id,_ in devices.contains { $0.id == id } } } }
        log("advertisement","RSSI=\(RSSI) advertisement=\((try? LogCodec.encoder().encode(device.advertisement)).flatMap { String(data:$0,encoding:.utf8) } ?? "")",peripheral:p)
    }
    func centralManager(_ central:CBCentralManager,didConnect p:CBPeripheral) {
        guard active === p, !userStopped else { central.cancelPeripheralConnection(p); return }
        publishEvents(); pendingValues = [:]; services = []; serviceObjects = []; chars = [:]; operationQueue = []; currentOperation = nil; operationTimer?.invalidate(); diagnostic.connected(); status = "正在发现 GATT"; log("connected"); pending = ["services"]; armTimeout(seconds:45); p.discoverServices(nil)
        rssiTimer?.invalidate(); rssiTimer = mainTimer(interval:3,repeats:true) { [weak self] in self?.active?.readRSSI() }
    }
    func centralManager(_ central:CBCentralManager,didFailToConnect p:CBPeripheral,error:Error?) { guard active === p else { return }; connectionTimer?.invalidate(); log("connect_failed",error:error); active = nil; if userStopped { diagnostic.stop(); status = "已停止" } else { diagnostic.fail(); status = "连接失败" } }
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?) {
        guard active === p else { return }; log("disconnected",error:error); if recording { current = snapshot(); if let r = current { store.save(r) } }; connectionTimer?.invalidate(); rssiTimer?.invalidate(); pending = []; operationQueue = []; currentOperation = nil; operationTimer?.invalidate(); active = nil; status = userStopped ? "已停止":"已断开"; if userStopped { diagnostic.stop() } else { diagnostic.fail() }; for i in services.indices { for j in services[i].characteristics.indices { services[i].characteristics[j].notifying = false } }; chars = [:]; serviceObjects = []
        if allowReconnect && reconnectFavorites && favoriteIDs.contains(p.identifier) && reconnectAttempts < 2 && central.state == .poweredOn {
            reconnectAttempts += 1; active = p; diagnostic.start(); status = "重连 \(reconnectAttempts)/2"; central.connect(p,options:nil); armTimeout(seconds:15)
        }
    }
    private func finish(_ key:String) { pending.remove(key); guard diagnostic.state == .discovering else { return }; status = "GATT 发现：剩余 \(pending.count) 项"; if pending.isEmpty, diagnostic.state == .discovering { connectionTimer?.invalidate(); diagnostic.discovered(); status = "GATT 发现完成；只读监听中"; runNextOperation(); if let r = current { var updated = r; updated.topology = services; store.save(updated) } } }
    func peripheral(_ p:CBPeripheral,didDiscoverServices error:Error?) {
        guard active === p, !userStopped else { return }; log("services",error:error)
        if error != nil { diagnostic.fail(); status = "服务发现失败"; connectionTimer?.invalidate(); return }
        for service in p.services ?? [] { register(service, peripheral:p) }
        finish("services")
    }
    private func register(_ service: CBService, peripheral: CBPeripheral) {
        guard !serviceObjects.contains(where: { $0 === service }) else { return }
        let i = serviceObjects.count; serviceObjects.append(service)
        services.append(GATTService(id:"\(i):\(service.uuid)",uuid:service.uuid.uuidString,primary:service.isPrimary))
        pending.insert("chars:\(i)"); pending.insert("included:\(i)")
        peripheral.discoverCharacteristics(nil,for:service); peripheral.discoverIncludedServices(nil,for:service)
        log("service","primary=\(service.isPrimary)",service:service.uuid.uuidString)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        guard active === p, !userStopped, let i = serviceIndex(service) else { return }
        log("included_services",service:service.uuid.uuidString,error:error)
        for included in service.includedServices ?? [] { register(included,peripheral:p) }
        finish("included:\(i)")
    }
    private func serviceIndex(_ s:CBService) -> Int? { serviceObjects.firstIndex { $0 === s } }
    private func key(_ c:CBCharacteristic) -> String? {
        guard let s = c.service, let i = serviceIndex(s), let j = s.characteristics?.firstIndex(where: { $0 === c }) else { return nil }; return "\(i):\(j):\(c.uuid)"
    }
    nonisolated static func properties(_ p:CBCharacteristicProperties) -> [String] {
        let pairs:[(CBCharacteristicProperties,String)] = [(.read,"Read"),(.write,"Write"),(.writeWithoutResponse,"Write Without Response"),(.notify,"Notify"),(.indicate,"Indicate"),(.broadcast,"Broadcast"),(.extendedProperties,"Extended Properties"),(.authenticatedSignedWrites,"Authenticated Signed Writes"),(.notifyEncryptionRequired,"Notify Encryption Required"),(.indicateEncryptionRequired,"Indicate Encryption Required")]
        return pairs.filter { p.contains($0.0) }.map(\.1)
    }
    func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor s:CBService,error:Error?) {
        guard active === p, !userStopped, let i = serviceIndex(s), services.indices.contains(i) else { return }
        log("characteristics",service:s.uuid.uuidString,error:error)
        for c in s.characteristics ?? [] {
            guard let id = key(c) else { continue }; chars[id] = c
            services[i].characteristics.append(GATTCharacteristic(id:id,uuid:c.uuid.uuidString,service:s.uuid.uuidString,properties:Self.properties(c.properties)))
            pending.insert("desc:"+id); p.discoverDescriptors(for:c)
            log("characteristic",Self.properties(c.properties).joined(separator:","),service:s.uuid.uuidString,characteristic:c.uuid.uuidString)
            if autoDiagnostic {
                let model = GATTCharacteristic(id:id,uuid:c.uuid.uuidString,service:s.uuid.uuidString,properties:Self.properties(c.properties))
                for action in ReadOnlyDiagnosticPlanner.operations(for:model,subscribe:autoSubscribe) {
                    switch action { case .read(let key): operationQueue.append((key,nil)); case .subscribe(let key): operationQueue.append((key,true)) }
                }
            }
        }
        finish("chars:\(i)")
    }
    func peripheral(_ p:CBPeripheral,didDiscoverDescriptorsFor c:CBCharacteristic,error:Error?) {
        guard active === p, !userStopped, let id = key(c) else { return }
        update(id) { $0.descriptors = (c.descriptors ?? []).map(\.uuid.uuidString); $0.error = error?.localizedDescription }
        log("descriptors",(c.descriptors ?? []).map(\.uuid.uuidString).joined(separator:","),service:c.service?.uuid.uuidString,characteristic:c.uuid.uuidString,error:error); finish("desc:"+id)
    }
    private func update(_ id:String, _ action:(inout GATTCharacteristic)->Void) {
        for i in services.indices { if let j = services[i].characteristics.firstIndex(where: { $0.id == id }) { action(&services[i].characteristics[j]); return } }
    }
    func read(_ id:String) { guard let c = chars[id], c.properties.contains(.read) else { return }; enqueue(id,nil) }
    func subscribe(_ id:String, enabled:Bool) { guard let c = chars[id], c.properties.contains(.notify) || c.properties.contains(.indicate) else { return }; enqueue(id,enabled) }
    private func enqueue(_ id:String, _ notify:Bool?) {
        guard active?.state == .connected, operationQueue.count < 256 else { return }
        operationQueue.append((id,notify)); runNextOperation()
    }
    private func runNextOperation() {
        if operationQueue.isEmpty && currentOperation == nil && active?.state == .connected { status = "只读操作完成；持续监听已订阅通知" }
        guard currentOperation == nil, diagnostic.state != .discovering, let p = active, p.state == .connected, !operationQueue.isEmpty else { return }
        let item = operationQueue.removeFirst(); guard let c = chars[item.0] else { runNextOperation(); return }; currentOperation = item; status = "只读操作剩余 \(operationQueue.count+1) 项"
        if let notify = item.1 { p.setNotifyValue(notify,for:c); log("subscription_requested","enabled=\(notify)",service:c.service?.uuid.uuidString,characteristic:c.uuid.uuidString) }
        else { p.readValue(for:c); log("read_requested",service:c.service?.uuid.uuidString,characteristic:c.uuid.uuidString) }
        let uuid = c.uuid.uuidString
        operationTimer = mainTimer(interval:8,repeats:false) { [weak self] in
            guard let self else { return }; self.update(item.0) { $0.error = "操作超时；迟到回调无法与后续操作可靠区分" }; self.log("operation_timeout",characteristic:uuid); self.currentOperation = nil; self.runNextOperation()
        }
    }
    private func completeOperation(_ id:String, subscription:Bool) {
        if let op = currentOperation, op.0 == id, (op.1 != nil) == subscription { operationTimer?.invalidate(); currentOperation = nil; runNextOperation() }
    }
    func peripheral(_ p:CBPeripheral,didUpdateValueFor c:CBCharacteristic,error:Error?) {
        guard active === p, !userStopped, let id = key(c) else { return }
        var snapshot = pendingValues[id] ?? ValueSnapshot()
        snapshot.error = error?.localizedDescription
        if error == nil { snapshot.value = c.value; snapshot.updated = Date(); if !c.isNotifying { snapshot.lastReadValue = c.value; snapshot.lastReadAt = snapshot.updated }; if c.isNotifying { snapshot.notificationIncrement += 1 } }
        pendingValues[id] = snapshot
        log(error == nil ? "value":"value_error",c.isNotifying ? "通知开启期间的回调（可能包含读取响应）":"读取回调",service:c.service?.uuid.uuidString,characteristic:c.uuid.uuidString,instanceID:id,notifying:c.isNotifying,data:error == nil ? c.value:nil,error:error)
        completeOperation(id,subscription:false)
    }
    func peripheral(_ p:CBPeripheral,didUpdateNotificationStateFor c:CBCharacteristic,error:Error?) {
        guard active === p, !userStopped, let id = key(c) else { return }; update(id) { $0.notifying = c.isNotifying; $0.error = error?.localizedDescription }
        log("subscription","isNotifying=\(c.isNotifying)",service:c.service?.uuid.uuidString,characteristic:c.uuid.uuidString,error:error)
        completeOperation(id,subscription:true)
    }
    func peripheral(_ p:CBPeripheral,didReadRSSI RSSI:NSNumber,error:Error?) { guard active === p, !userStopped else { return }; if error == nil && RSSI.intValue != 127 { rssiSamples.append(RSSI.intValue); if rssiSamples.count > 300 { rssiSamples.removeFirst() } }; log("rssi",String(RSSI.intValue),error:error) }
    func peripheral(_ peripheral:CBPeripheral,didModifyServices invalidatedServices:[CBService]) {
        guard active === peripheral, !userStopped else { return }; publishEvents(); pendingValues = [:]; services = []; serviceObjects = []; chars = [:]; operationQueue = []; currentOperation = nil; operationTimer?.invalidate(); pending = ["services"]; diagnostic = DiagnosticMachine(); diagnostic.start(); diagnostic.connected(); armTimeout(seconds:45); log("services_invalidated"); peripheral.discoverServices(nil)
    }
}
