import Foundation

struct SessionRecord: Codable, Identifiable, Sendable {
    var id: UUID
    var started: Date
    var ended: Date?
    var note: String
    var device: Device?
    var topology: [GATTService]
    var rssiSamples: [Int] = []
}
struct PrivacyOptions: Sendable {
    var hideIdentifiers = true
    var removePayloads = false
}
enum ExportFormat: String, CaseIterable, Sendable { case json, jsonl, csv, markdown }
enum LogCodec {
    static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .custom { date, encoder in var c = encoder.singleValueContainer(); try c.encode(iso(date)) }; e.outputFormatting = [.sortedKeys]; return e }
    static func iso(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.string(from:date) }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .custom { decoder in let c = try decoder.singleValueContainer(); let s = try c.decode(String.self); let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; if let date = f.date(from:s) ?? ISO8601DateFormatter().date(from:s) { return date }; throw DecodingError.dataCorruptedError(in:c,debugDescription:"无效 ISO 8601 时间") }; return d }
    static func csv(_ e: BLEEvent) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return [iso(e.timestamp),String(e.monotonicTimestamp),e.sessionID.uuidString,e.peripheralIdentifier ?? "",e.deviceName ?? "",e.serviceUUID ?? "",e.characteristicUUID ?? "",e.eventType,e.direction,e.characteristicInstanceID ?? "",String(e.payloadLength),e.rawHexPayload,e.base64Payload,e.errorDescription ?? "",e.detail].map(q).joined(separator:",") + "\n"
    }
}
/// All file IO is serialized off the main thread. Buffer bounded by 64 KiB; timed flush every second.
final class EventLogStore: @unchecked Sendable {
    let root: URL
    private let queue = DispatchQueue(label: "BLEInspector.disk", qos: .utility)
    private let readQueue = DispatchQueue(label: "BLEInspector.read-export", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let admission = NSLock()
    private var queuedEvents = 0
    private var overloadReported = false
    private let encoder = LogCodec.encoder()
    private let decoder = LogCodec.decoder()
    private var buffers: [UUID: Data] = [:]
    private var segment: [UUID: Int] = [:]
    private var sizes: [UUID: Int] = [:]
    private let rotationBytes: Int
    private var blocked = Set<UUID>()
    private var lastCapacityCheck = Date.distantPast
    private var totalCapacityReached = false
    var onError: (@Sendable (String) -> Void)?
    init(root: URL, rotationBytes: Int = 4*1024*1024) {
        self.root = root; self.rotationBytes = rotationBytes
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories:true) } catch { /* surfaced on first write */ }
        let t = DispatchSource.makeTimerSource(queue:queue); t.schedule(deadline:.now()+1,repeating:1)
        t.setEventHandler { [weak self] in self?.flushAll() }; t.resume(); timer = t
    }
    deinit { timer?.cancel() }
    func append(_ event: BLEEvent) {
        admission.lock()
        guard queuedEvents < 4096 else { let report = !overloadReported; overloadReported = true; admission.unlock(); if report { onError?("写盘队列超过 4096 条，停止录制；部分过载事件未保存") }; return }
        queuedEvents += 1; admission.unlock()
        queue.async { [self] in
            defer { admission.lock(); queuedEvents -= 1; admission.unlock() }
            guard !blocked.contains(event.sessionID) else { return }; do { buffers[event.sessionID,default:Data()].append(try encoder.encode(event) + Data([10])); if buffers[event.sessionID,default:Data()].count >= 65536 { try flush(event.sessionID) } }
            catch { buffers[event.sessionID] = nil; blocked.insert(event.sessionID); onError?(error.localizedDescription) }
        }
    }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString,isDirectory:true) }
    private func flush(_ id: UUID) throws {
        guard let data = buffers[id], !data.isEmpty else { return }
        if Date().timeIntervalSince(lastCapacityCheck) > 5 {
            lastCapacityCheck = Date(); var bytes = 0
            if let items = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.fileSizeKey],options:[.skipsHiddenFiles]) { for case let url as URL in items { bytes += (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0 } }
            totalCapacityReached = bytes >= 1024*1024*1024
        }
        if totalCapacityReached { buffers[id] = nil; blocked.insert(id); throw NSError(domain:"LogStore",code:4,userInfo:[NSLocalizedDescriptionKey:"本地日志达到 1 GiB；请通过文件 App 清理历史会话和导出副本"]) }
        let dir = directory(id); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        if sizes[id,default:0] + data.count > rotationBytes, sizes[id,default:0] > 0 { segment[id,default:0] += 1; sizes[id] = 0 }
        // 64 segments per session: stop recording rather than silently delete raw evidence.
        guard segment[id,default:0] < 64 else { buffers[id] = nil; blocked.insert(id); throw NSError(domain:"LogStore",code:1,userInfo:[NSLocalizedDescriptionKey:"会话达到日志上限；请结束并创建新会话"]) }
        let url = dir.appendingPathComponent(String(format:"events-%04d.jsonl",segment[id,default:0]))
        if !FileManager.default.fileExists(atPath:url.path) { try Data().write(to:url) }
        let h = try FileHandle(forWritingTo:url); defer { try? h.close() }
        try h.seekToEnd(); try h.write(contentsOf:data); try h.synchronize(); sizes[id,default:0] += data.count; buffers[id] = nil
    }
    private func flushAll() { for id in Array(buffers.keys) { do { try flush(id) } catch { buffers[id] = nil; blocked.insert(id); onError?(error.localizedDescription) } } }
    func save(_ record: SessionRecord) { queue.async { [self] in do { try FileManager.default.createDirectory(at:directory(record.id),withIntermediateDirectories:true); try encoder.encode(record).write(to:directory(record.id).appendingPathComponent("session.json"),options:.atomic); try flush(record.id) } catch { onError?(error.localizedDescription) } } }
    func barrier() async { await withCheckedContinuation { continuation in queue.async { [self] in flushAll(); continuation.resume() } } }
    func history() async throws -> [SessionRecord] {
        try await withCheckedThrowingContinuation { c in queue.async { [self] in
            do { let dirs = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil); let records = dirs.compactMap { try? decoder.decode(SessionRecord.self,from:Data(contentsOf:$0.appendingPathComponent("session.json"))) }; c.resume(returning:records.sorted { $0.started > $1.started }) } catch { c.resume(throwing:error) }
        } }
    }
    private struct LogSegment: Sendable {
        var url: URL
        var length: Int
    }
    /// Capture byte lengths on the writer queue; readers never wait on future appends.
    private func snapshotFiles(_ id: UUID) async throws -> [LogSegment] {
        try await withCheckedThrowingContinuation { c in queue.async { [self] in
            do {
                try flush(id)
                let urls = try FileManager.default.contentsOfDirectory(at:directory(id),includingPropertiesForKeys:[.fileSizeKey])
                    .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                let files = try urls.map { LogSegment(url:$0,length:try $0.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) }
                c.resume(returning:files)
            } catch { c.resume(throwing:error) }
        } }
    }
    private func eachEvent(_ files: [LogSegment], _ body: (BLEEvent) throws -> Void) throws {
        let decoder = LogCodec.decoder()
        for file in files {
            let h = try FileHandle(forReadingFrom:file.url); defer { try? h.close() }
            var pending = Data(), remaining = file.length
            while remaining > 0 {
                guard let chunk = try h.read(upToCount:min(65536,remaining)), !chunk.isEmpty else { throw NSError(domain:"LogStore",code:5,userInfo:[NSLocalizedDescriptionKey:"日志在读取期间被截断或删除"]) }
                remaining -= chunk.count; pending.append(chunk)
                while let index = pending.firstIndex(of:10) {
                    let line = Data(pending[..<index]); pending.removeSubrange(...index)
                    guard line.count < 2*1024*1024 else { throw NSError(domain:"LogStore",code:2,userInfo:[NSLocalizedDescriptionKey:"异常日志行过长"]) }
                    if !line.isEmpty { try body(decoder.decode(BLEEvent.self,from:line)) }
                }
                guard pending.count < 2*1024*1024 else { throw NSError(domain:"LogStore",code:2,userInfo:[NSLocalizedDescriptionKey:"异常日志行过长"]) }
            }
            if !pending.isEmpty { throw NSError(domain:"LogStore",code:3,userInfo:[NSLocalizedDescriptionKey:"日志尾部不完整"]) }
        }
    }
    func samples(_ id: UUID, since: Date? = nil, until: Date? = nil, limit: Int = 80) async throws -> [BLEEvent] {
        let files = try await snapshotFiles(id)
        return try await withCheckedThrowingContinuation { c in readQueue.async { [self] in do { var result:[BLEEvent] = []; try eachEvent(files) { if $0.payload != nil && $0.eventType == "value" && (since == nil || $0.timestamp >= since!) && (until == nil || $0.timestamp <= until!) { result.append($0); if result.count > max(1,min(4096,limit)) { result.removeFirst() } } }; c.resume(returning:result) } catch { c.resume(throwing:error) } } }
    }
    func analysis(_ id: UUID, since: Date? = nil, until: Date? = nil) async throws -> SessionAnalysis {
        let files = try await snapshotFiles(id)
        return try await withCheckedThrowingContinuation { c in readQueue.async { [self] in
            do {
                if let since, let until, since > until { throw NSError(domain:"Analysis",code:2,userInfo:[NSLocalizedDescriptionKey:"时间范围开始晚于结束"]) }
                var summary = SessionAnalysis()
                try eachEvent(files) { event in
                    if (since == nil || event.timestamp >= since!) && (until == nil || event.timestamp <= until!) { try summary.append(event) }
                }
                c.resume(returning:summary)
            } catch { c.resume(throwing:error) }
        } }
    }
    func export(_ record: SessionRecord, format: ExportFormat, privacy: PrivacyOptions) async throws -> URL {
        let files = try await snapshotFiles(record.id)
        return try await withCheckedThrowingContinuation { c in readQueue.async { [self] in
            var output: URL?
            let encoder = LogCodec.encoder()
            do {
                let dir = root.appendingPathComponent("Exports"); try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                let url = dir.appendingPathComponent("BLEInspector-\(record.id)-\(UUID()).\(format == .markdown ? "md" : format.rawValue)")
                output = url; try Data().write(to:url); let h = try FileHandle(forWritingTo:url); defer { try? h.close() }
                func write(_ s:String) throws { try h.write(contentsOf:Data(s.utf8)) }
                var safeRecord = record
                if privacy.hideIdentifiers { safeRecord.device = nil; safeRecord.note = "备注已隐藏"; for i in safeRecord.topology.indices { for j in safeRecord.topology[i].characteristics.indices { safeRecord.topology[i].characteristics[j].error = nil } } }
                if privacy.removePayloads { safeRecord.device?.advertisement.manufacturer = nil; safeRecord.device?.advertisement.serviceData = [:]; for i in safeRecord.topology.indices { for j in safeRecord.topology[i].characteristics.indices { safeRecord.topology[i].characteristics[j].value = nil; safeRecord.topology[i].characteristics[j].lastReadValue = nil } } }
                if format == .json { try write("{\"session\":"); try h.write(contentsOf:encoder.encode(safeRecord)); try write(",\"events\":[") }
                if format == .csv { try write("timestamp,monotonicTimestamp,sessionID,peripheralIdentifier,deviceName,serviceUUID,characteristicUUID,eventType,direction,characteristicInstanceID,payloadLength,rawHexPayload,base64Payload,errorDescription,detail\n") }
                if format == .jsonl { var context = BLEEvent(sessionID:record.id,eventType:"session_context",detail:"会话与 GATT 上下文"); context.payload = try encoder.encode(safeRecord); try h.write(contentsOf:encoder.encode(context)+Data([10])) }
                var first = true; var count = 0; var summary = SessionAnalysis(); var valueCount = 0
                try eachEvent(files) { event in
                    var e = event
                    if privacy.hideIdentifiers { e.peripheralIdentifier = nil; e.deviceName = nil; e.detail = "上下文文字已隐藏"; e.errorDescription = e.errorDescription == nil ? nil : "错误文字已隐藏" }
                    if privacy.removePayloads { e.payload = nil; if e.eventType == "advertisement" { e.detail = "广播原始数据已隐藏" } }
                    count += 1; if e.eventType == "value" { valueCount += 1 }; if format == .json || format == .markdown { try summary.append(e) }
                    if format == .jsonl { try h.write(contentsOf:encoder.encode(e)+Data([10])) }
                    if format == .json { if !first { try write(",") }; first = false; try h.write(contentsOf:encoder.encode(e)) }
                    if format == .csv { try write(LogCodec.csv(e)) }
                    
                }
                if format == .json { try write("],\"analysis\":"); try h.write(contentsOf:encoder.encode(summary.groups.mapValues { $0.result })); try write(",\"diagnosticErrors\":"); try h.write(contentsOf:encoder.encode(summary.errorCounts)); try write("}") }
                if format == .markdown {
                    try write("# BLE Inspector 诊断报告\n\n会话：\(record.id)\n\n开始：\(record.started)\n\n事件数：\(count)\n\nMAC：iOS 不可获取\n\n## GATT 拓扑\n\n")
                    try write("## 设备基本信息与广播\n\n")
                    if let device = safeRecord.device { try write("名称：\(device.name)\n\n广播服务：\(device.advertisement.services.joined(separator:","))\n\nManufacturer Data：\(privacy.removePayloads ? "已隐藏" : device.advertisement.manufacturer?.hex ?? "无")\n\nService Data：\(privacy.removePayloads ? "已隐藏" : device.advertisement.serviceData.map { $0.key+":"+$0.value.hex }.joined(separator:"; "))\n\n可连接：\(device.advertisement.connectable.map(String.init) ?? "未知")\n\n") } else { try write("设备身份与广播上下文已隐藏，或未连接设备。\n\n") }
                    let rssis = safeRecord.rssiSamples
                    try write("## 信号质量\n\n采样数：\(rssis.count)；范围：\(rssis.min().map(String.init) ?? "无") 至 \(rssis.max().map(String.init) ?? "无") dBm\n\n## 可读与可订阅特征\n\n")
                    for c in safeRecord.topology.flatMap(\.characteristics) { if c.properties.contains("Read") || c.properties.contains("Notify") || c.properties.contains("Indicate") { try write("- \(c.service)/\(c.uuid)：\(c.properties.joined(separator:","))；通知开启期间回调 \(c.notificationCount)\n") } }
                    try write("\n## 未知 / 厂商自定义服务\n\n"+safeRecord.topology.filter { SIG.names[SIG.normalized($0.uuid)] == nil }.map { "- \($0.uuid)（字典未收录，不保证属于厂商自定义）" }.joined(separator:"\n")+"\n\n## 拓扑详情\n\n")
                    for s in safeRecord.topology { try write("- \(s.uuid) \(SIG.name(s.uuid)) primary=\(s.primary)\n"); for ch in s.characteristics { try write("  - \(ch.uuid) [\(ch.properties.joined(separator:", "))] descriptors=\(ch.descriptors.joined(separator:","))\n") } }
                    for key in summary.groups.keys.sorted() { let a = summary.groups[key]!.result; try write("\n## \(key)\n\n观测事实（完整会话增量统计）：\n\n"+a.facts.map { "- \($0)" }.joined(separator:"\n")+"\n\n推测（未确认）：\n\n"+a.hypotheses.map { "- \($0)" }.joined(separator:"\n")+"\n") }
                    try write("\n## 诊断异常\n\n"+summary.errorCounts.map { "- \($0.key)：\($0.value) 次" }.joined(separator:"\n")+"\n\n其他错误：\(summary.truncatedErrors)；数据回调数：\(valueCount)\n")
                    try write("\n## 未确认信息与限制\n\n读取和通知回调无法始终区分。私有协议、校验字段及帧边界未确认。无法抓链路层、其他 App 通信或经典蓝牙全量流量。原始证据请同时导出 JSONL。\n")
                }
                try h.synchronize(); c.resume(returning:url)
            } catch { if let output { try? FileManager.default.removeItem(at:output) }; c.resume(throwing:error) }
        } }
    }
}
