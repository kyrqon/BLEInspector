import Foundation

struct Advertisement: Codable, Equatable, Sendable {
    var name: String
    var services: [String]
    var serviceData: [String: Data]
    var manufacturer: Data?
    var connectable: Bool?
    var txPower: Int?
}
struct Device: Identifiable, Codable, Sendable {
    var id: UUID
    var advertisement: Advertisement
    var rssi: Int
    var lastSeen: Date
    var favorite = false
    var name: String { advertisement.name }
}
struct GATTCharacteristic: Identifiable, Codable, Sendable {
    var id: String
    var uuid: String
    var service: String
    var properties: [String]
    var descriptors: [String] = []
    var value: Data?
    var updated: Date?
    var lastReadValue: Data? = nil
    var lastReadAt: Date? = nil
    var notificationCount = 0
    var notifying = false
    var error: String?
}
struct GATTService: Identifiable, Codable, Sendable {
    var id: String
    var uuid: String
    var primary: Bool
    var characteristics: [GATTCharacteristic] = []
}
struct BLEEvent: Codable, Identifiable, Sendable {
    var id = UUID()
    var timestamp = Date()
    var monotonicTimestamp = ProcessInfo.processInfo.systemUptime
    var sessionID: UUID
    var peripheralIdentifier: String?
    var deviceName: String?
    var serviceUUID: String?
    var characteristicUUID: String?
    var characteristicInstanceID: String? = nil
    var notificationEnabled: Bool? = nil
    var eventType: String
    var direction: String = "system"
    var payload: Data?
    var detail: String
    var errorDescription: String?
    var payloadLength: Int { payload?.count ?? 0 }
    var rawHexPayload: String { payload?.hex ?? "" }
    var base64Payload: String { payload?.base64EncodedString() ?? "" }
    enum CodingKeys: String, CodingKey {
        case id, timestamp, monotonicTimestamp, sessionID, peripheralIdentifier, deviceName, serviceUUID, characteristicUUID, characteristicInstanceID, notificationEnabled, eventType, direction, hasPayload, payloadLength, rawHexPayload, base64Payload, detail, errorDescription
    }
    init(sessionID: UUID, peripheralIdentifier: String? = nil, deviceName: String? = nil, serviceUUID: String? = nil, characteristicUUID: String? = nil, eventType: String, direction: String = "system", payload: Data? = nil, detail: String = "", errorDescription: String? = nil) {
        self.sessionID = sessionID; self.peripheralIdentifier = peripheralIdentifier; self.deviceName = deviceName
        self.serviceUUID = serviceUUID; self.characteristicUUID = characteristicUUID; self.eventType = eventType
        self.direction = direction; self.payload = payload; self.detail = detail; self.errorDescription = errorDescription
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); timestamp = try c.decode(Date.self, forKey: .timestamp)
        monotonicTimestamp = try c.decode(Double.self, forKey: .monotonicTimestamp); sessionID = try c.decode(UUID.self, forKey: .sessionID)
        peripheralIdentifier = try c.decodeIfPresent(String.self, forKey: .peripheralIdentifier); deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        serviceUUID = try c.decodeIfPresent(String.self, forKey: .serviceUUID); characteristicUUID = try c.decodeIfPresent(String.self, forKey: .characteristicUUID)
        characteristicInstanceID = try c.decodeIfPresent(String.self,forKey:.characteristicInstanceID)
        notificationEnabled = try c.decodeIfPresent(Bool.self,forKey:.notificationEnabled)
        eventType = try c.decode(String.self, forKey: .eventType); direction = try c.decode(String.self, forKey: .direction)
        let base64 = try c.decodeIfPresent(String.self, forKey:.base64Payload) ?? ""
        let present = try c.decodeIfPresent(Bool.self,forKey:.hasPayload) ?? (!base64.isEmpty || eventType == "value")
        if present {
            guard let decoded = Data(base64Encoded:base64), decoded.count == (try c.decode(Int.self,forKey:.payloadLength)) else { throw DecodingError.dataCorruptedError(forKey:.base64Payload,in:c,debugDescription:"Payload Base64 无效或长度不匹配") }
            payload = decoded
        } else { payload = nil }
        detail = try c.decode(String.self, forKey: .detail); errorDescription = try c.decodeIfPresent(String.self, forKey: .errorDescription)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(timestamp, forKey: .timestamp); try c.encode(monotonicTimestamp, forKey: .monotonicTimestamp); try c.encode(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(peripheralIdentifier, forKey: .peripheralIdentifier); try c.encodeIfPresent(deviceName, forKey: .deviceName)
        try c.encodeIfPresent(serviceUUID, forKey: .serviceUUID); try c.encodeIfPresent(characteristicUUID, forKey: .characteristicUUID)
        try c.encodeIfPresent(characteristicInstanceID,forKey:.characteristicInstanceID); try c.encodeIfPresent(notificationEnabled,forKey:.notificationEnabled); try c.encode(eventType, forKey: .eventType); try c.encode(direction, forKey: .direction); try c.encode(payload != nil, forKey:.hasPayload); try c.encode(payloadLength, forKey: .payloadLength)
        try c.encode(rawHexPayload, forKey: .rawHexPayload); try c.encode(base64Payload, forKey: .base64Payload); try c.encode(detail, forKey: .detail); try c.encodeIfPresent(errorDescription, forKey: .errorDescription)
    }
}
extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
    init?(hex: String) {
        let s = hex.filter { !$0.isWhitespace }
        guard s.count % 2 == 0, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes: [UInt8] = []; var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); guard let b = UInt8(s[i..<j], radix: 16) else { return nil }; bytes.append(b); i = j }
        self.init(bytes)
    }
}
enum SIG {
    static func full(_ uuid: String) -> String {
        let s = uuid.uppercased()
        if s.count == 4 { return "0000"+s+"-0000-1000-8000-00805F9B34FB" }
        if s.count == 8 { return s+"-0000-1000-8000-00805F9B34FB" }
        return s
    }
    static func normalized(_ uuid: String) -> String {
        let s = uuid.uppercased(); let suffix = "-0000-1000-8000-00805F9B34FB"
        if s.count == 36, s.hasPrefix("0000"), s.hasSuffix(suffix) { return String(s.dropFirst(4).prefix(4)) }
        return s
    }
    static let names = ["1800":"Generic Access", "1801":"Generic Attribute", "180A":"Device Information", "180F":"Battery", "180D":"Heart Rate", "1810":"Blood Pressure", "1812":"Human Interface Device", "1816":"Cycling Speed and Cadence", "1818":"Cycling Power", "181A":"Environmental Sensing", "1826":"Fitness Machine"]
    static func name(_ uuid: String) -> String { names[normalized(uuid)] ?? "未知 / 厂商自定义（未确认）" }
}
struct DeviceProfile: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var deviceName: String
    var services: [String]
    var characteristicPrefixes: [String]
    var manufacturerObservation: String
    func matches(_ device: Device) -> Bool { device.name == deviceName }
    static let yadea = DeviceProfile(id: "yadea-q17-pro", name: "雅迪 Q17 Pro", deviceName: "YD61236288", services: ["E7810B92-73AE-499D-8C15-FAA9AEF0C3F2"], characteristicPrefixes: ["BEF8E7E0", "BEF8E7E1"], manufacturerObservation: "_Newbit Studio（nRF Connect 观察，非广播厂商 ID 定义）")
}
enum DiagnosticState: String, Codable { case idle, connecting, discovering, collecting, stopped, failed }
struct DiagnosticMachine {
    private(set) var state: DiagnosticState = .idle
    mutating func start() { state = .connecting }
    mutating func connected() { if state == .connecting { state = .discovering } }
    mutating func discovered() { if state == .discovering { state = .collecting } }
    mutating func stop() { state = .stopped }
    mutating func fail() { state = .failed }
}
struct ByteDiff: Codable, Sendable {
    var changedOffsets: [Int]
    static func compare(_ a: Data, _ b: Data) -> ByteDiff {
        let x = Array(a), y = Array(b)
        return ByteDiff(changedOffsets: (0..<max(x.count,y.count)).filter { $0 >= x.count || $0 >= y.count || x[$0] != y[$0] })
    }
}
struct AnalysisResult: Codable, Sendable {
    var samples: Int
    var lengths: [Int]
    var changedOffsets: [Int]
    var meanInterval: Double?
    var facts: [String]
    var hypotheses: [String]
}
enum ProtocolHeuristicsEngine {
    static func analyze(_ events: [BLEEvent]) -> AnalysisResult {
        let samples = events.filter { $0.payload != nil }; let values = samples.compactMap(\.payload)
        var offsets = Set<Int>(); var intervals: [Double] = []
        if values.count > 1 { for i in 1..<values.count { offsets.formUnion(ByteDiff.compare(values[i-1], values[i]).changedOffsets); let dt = samples[i].monotonicTimestamp-samples[i-1].monotonicTimestamp; if dt > 0 { intervals.append(dt) } } }
        let lengths = Array(Set(values.map(\.count))).sorted()
        var facts = ["采样 \(values.count) 帧", "观测长度：\(lengths)", "变化字节偏移（从 0 开始）：\(offsets.sorted())"]
        var guesses: [String] = []
        if let firstTime = samples.first?.timestamp, let lastTime = samples.last?.timestamp { facts.append("变化观测时间：\(firstTime) 至 \(lastTime)") }
        let unique = Set(values)
        facts.append("不同帧数：\(unique.count)；重复帧数：\(values.count-unique.count)")
        if lengths.count > 1 { guesses.append("长度变化可能表示可变帧或不同消息类型；不能据此确定应用层帧边界") }
        if values.count >= 5, values.allSatisfy({ $0.count >= 3 }) {
            let sumMatches = values.filter { d in UInt8(truncatingIfNeeded:d.dropLast().reduce(0) { $0+Int($1) }) == d.last! }.count
            let xorMatches = values.filter { d in d.dropLast().reduce(UInt8(0),^) == d.last! }.count
            if sumMatches == values.count { guesses.append("全部样本尾字节符合前缀字节和 mod 256；可能是校验字段，也可能巧合") }
            if xorMatches == values.count { guesses.append("全部样本尾字节符合前缀 XOR；可能是校验字段，也可能巧合") }
        }
        if let first = values.first, values.count >= 3 {
            let prefix = first
            var common = 0
            for i in 0..<min(prefix.count, values.map(\.count).min() ?? 0) {
                if values.allSatisfy({ $0[$0.startIndex+i] == first[first.startIndex+i] }) { common += 1 } else { break }
            }
            if common > 0 { guesses.append("前 \(common) 字节固定，可能是头部或静态数据；未确认帧边界") }
            for offset in offsets.sorted().prefix(32) where values.allSatisfy({ $0.count > offset }) {
                let bytes = values.map { $0[$0.startIndex+offset] }
                if zip(bytes, bytes.dropFirst()).allSatisfy({ ($0.0 &+ 1) == $0.1 }) { guesses.append("偏移 \(offset) 每帧递增 1，可能是计数器 / 序列号") }
                let masks = zip(bytes, bytes.dropFirst()).map { $0.0 ^ $0.1 }
                facts.append("偏移 \(offset) 变化位掩码：\(Data(masks).hex)")
            }
            if values.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) { facts.append("所有采样可解码为 UTF-8；不等同于文本协议") }
        }
        let mean = intervals.isEmpty ? nil : intervals.reduce(0,+)/Double(intervals.count)
        if let mean, intervals.count >= 3, intervals.allSatisfy({ abs($0-mean) < mean*0.15 }) { guesses.append("间隔接近 \(String(format: "%.3f", mean)) 秒，可能为周期性通知") }
        guesses.append("CoreBluetooth value 是回调数据；应用层分帧、校验和、加密与命令语义均未确认")
        return AnalysisResult(samples: values.count, lengths: lengths, changedOffsets: offsets.sorted(), meanInterval: mean, facts: facts, hypotheses: guesses)
    }
    static func integers(_ data: Data) -> String {
        let bytes = Array(data.prefix(8)); guard !bytes.isEmpty else { return "无数据" }
        let le = bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset*8) }
        let be = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return "前 \(bytes.count) 字节无符号整数：LE \(le) / BE \(be)"
    }
}

struct DeviceProfileRepository {
    static func load(_ data: Data) throws -> [DeviceProfile] {
        let profiles = try JSONDecoder().decode([DeviceProfile].self, from: data)
        guard profiles.count <= 100, Set(profiles.map(\.id)).count == profiles.count,
              profiles.allSatisfy({ !$0.id.isEmpty && !$0.deviceName.isEmpty && $0.services.allSatisfy { UUID(uuidString:$0) != nil || ($0.count == 4 && $0.allSatisfy(\.isHexDigit)) } }) else {
            throw NSError(domain:"Profiles",code:1,userInfo:[NSLocalizedDescriptionKey:"Profile 格式错误、UUID 无效或 ID 重复"])
        }
        return profiles
    }
}

struct CharacteristicDiff: Codable, Sendable {
    var key: String
    var baselineSamples: Int
    var changedSamples: Int
    var baselineHz: Double?
    var changedHz: Double?
    var latestChangedOffsets: [Int]
    var changedPeriod: AnalysisResult
}
enum DataDiffEngine {
    static func compare(_ baseline: [BLEEvent], _ changed: [BLEEvent]) -> [CharacteristicDiff] {
        let key: (BLEEvent)->String = { ($0.serviceUUID ?? "")+"/"+($0.characteristicUUID ?? "") }
        let x = Dictionary(grouping:baseline.filter { $0.payload != nil },by:key)
        let y = Dictionary(grouping:changed.filter { $0.payload != nil },by:key)
        func rate(_ e:[BLEEvent]) -> Double? { guard e.count > 1, let first = e.first, let last = e.last, last.monotonicTimestamp > first.monotonicTimestamp else { return nil }; return Double(e.count-1)/(last.monotonicTimestamp-first.monotonicTimestamp) }
        return Set(x.keys).union(y.keys).sorted().map { k in
            let a = x[k] ?? [], b = y[k] ?? []
            return CharacteristicDiff(key:k,baselineSamples:a.count,changedSamples:b.count,baselineHz:rate(a),changedHz:rate(b),latestChangedOffsets:ByteDiff.compare(a.last?.payload ?? Data(),b.last?.payload ?? Data()).changedOffsets,changedPeriod:ProtocolHeuristicsEngine.analyze(b))
        }
    }
}

/// Bounded, incremental statistics over the entire selected time range.
/// Byte heuristics inspect at most the first 512 bytes of each callback, matching the GATT value limit.
struct FrameAccumulator: Sendable {
    private(set) var count = 0
    private(set) var latest: Data?
    private(set) var firstTime: Date?
    private(set) var lastTime: Date?
    private var lengths = Set<Int>()
    private var changes = Set<Int>()
    private var fixedPrefix: Data?
    private var counterOffsets = Set<Int>()
    private var bitMasks: [Int: UInt8] = [:]
    private var distinctFrames = Set<Data>()
    private var repeats = 0
    private var distinctOverflow = false
    private var allUTF8 = true
    private var allASCII = true
    private var checksumSum = true
    private var checksumXOR = true
    private var lastMonotonic: Double?
    private var intervalCount = 0
    private var intervalTotal = 0.0
    private var minInterval = Double.infinity
    private var maxInterval = 0.0
    private var notificationEnabledCount = 0
    private var oversized = false

    mutating func append(_ event: BLEEvent) {
        guard let payload = event.payload, event.eventType == "value" else { return }
        let data = Data(payload.prefix(512))
        count += 1; lengths.insert(payload.count); oversized = oversized || payload.count > 512
        if count == 1 {
            firstTime = event.timestamp; fixedPrefix = data
            counterOffsets = Set(0..<data.count)
        }
        lastTime = event.timestamp
        if event.notificationEnabled == true || (event.notificationEnabled == nil && event.detail.contains("通知开启")) { notificationEnabledCount += 1 }
        if distinctFrames.contains(data) { repeats += 1 }
        else if distinctFrames.count < 1024 { distinctFrames.insert(data) }
        else { distinctOverflow = true }
        allUTF8 = allUTF8 && String(data:payload,encoding:.utf8) != nil
        allASCII = allASCII && payload.allSatisfy { $0 < 128 }
        if payload.count >= 3 {
            let sum = payload.dropLast().reduce(UInt8(0)) { $0 &+ $1 }
            checksumSum = checksumSum && sum == payload.last
            checksumXOR = checksumXOR && payload.dropLast().reduce(UInt8(0),^) == payload.last
        } else { checksumSum = false; checksumXOR = false }
        if let previous = latest {
            let offsets = ByteDiff.compare(previous,data).changedOffsets
            changes.formUnion(offsets)
            for i in offsets where i < previous.count && i < data.count { bitMasks[i,default:0] |= previous[i] ^ data[i] }
            counterOffsets = Set(counterOffsets.filter { $0 < previous.count && $0 < data.count && previous[$0] &+ 1 == data[$0] })
        }
        if let prefix = fixedPrefix {
            var size = 0
            while size < min(prefix.count,data.count), prefix[size] == data[size] { size += 1 }
            fixedPrefix = Data(prefix.prefix(size))
        }
        if let previous = lastMonotonic {
            let interval = event.monotonicTimestamp - previous
            if interval > 0 { intervalCount += 1; intervalTotal += interval; minInterval = min(minInterval,interval); maxInterval = max(maxInterval,interval) }
        }
        lastMonotonic = event.monotonicTimestamp; latest = data
    }
    var frequency: Double? { guard intervalTotal > 0 else { return nil }; return Double(intervalCount)/intervalTotal }
    var result: AnalysisResult {
        let mean = intervalCount > 0 ? intervalTotal/Double(intervalCount) : nil
        var facts = ["采样 \(count) 帧（完整时间范围）", "观测长度：\(lengths.sorted())", "变化字节偏移（0 开始）：\(changes.sorted())", "通知开启期间回调：\(notificationEnabledCount)（可能含读取响应）"]
        if let firstTime, let lastTime { facts.append("观测时间：\(LogCodec.iso(firstTime)) 至 \(LogCodec.iso(lastTime))") }
        facts.append("不同帧\(distinctOverflow ? "至少":"") \(distinctFrames.count)；重复帧\(distinctOverflow ? "至少":"") \(repeats)（重复模式索引最多 1024 种）")
        if allUTF8 && count > 0 { facts.append("全部采样可解码 UTF-8；不等同于文本协议") }
        if allASCII && count > 0 { facts.append("全部字节位于 ASCII 范围") }
        if oversized { facts.append("存在超过 512 字节的回调：字节位置与模式分析仅覆盖前 512 字节，原始日志保留全部数据") }
        for offset in bitMasks.keys.sorted().prefix(32) { facts.append("偏移 \(offset) 累积变化位掩码：\(String(format:"%02X",bitMasks[offset]!))") }
        var hypotheses: [String] = []
        if count >= 3, let fixedPrefix, !fixedPrefix.isEmpty { hypotheses.append("前 \(fixedPrefix.count) 字节固定，可能是头部或静态字段；帧边界未确认") }
        if count >= 3 { for offset in counterOffsets.sorted().prefix(32) { hypotheses.append("偏移 \(offset) 每帧递增 1，可能是计数器 / 序列号") } }
        if lengths.count > 1 { hypotheses.append("变长回调可能是不同消息或可变帧，无法据此确认边界") }
        if count >= 5, checksumSum { hypotheses.append("所有尾字节符合前缀和 mod 256，可能是校验字段，也可能巧合") }
        if count >= 5, checksumXOR { hypotheses.append("所有尾字节符合前缀 XOR，可能是校验字段，也可能巧合") }
        if let mean, intervalCount >= 3, minInterval >= mean*0.85, maxInterval <= mean*1.15 { hypotheses.append("间隔接近 \(String(format:"%.3f",mean)) 秒，可能是周期性更新") }
        hypotheses.append("应用层帧边界、加密方式和命令含义均未确认")
        return AnalysisResult(samples:count,lengths:lengths.sorted(),changedOffsets:changes.sorted(),meanInterval:mean,facts:facts,hypotheses:hypotheses)
    }
}
struct SessionAnalysis: Sendable {
    var groups: [String: FrameAccumulator] = [:]
    var events = 0
    var errorCounts: [String: Int] = [:]
    var truncatedErrors = 0
    mutating func append(_ event: BLEEvent) throws {
        events += 1
        let diagnosticError = event.errorDescription ?? (["timeout","operation_timeout","connect_failed","value_error"].contains(event.eventType) ? "\(event.eventType)：\(event.detail)" : nil)
        if let error = diagnosticError {
            if errorCounts[error] != nil || errorCounts.count < 128 { errorCounts[error,default:0] += 1 } else { truncatedErrors += 1 }
        }
        guard event.payload != nil, event.eventType == "value" else { return }
        let key = Self.key(event)
        guard groups[key] != nil || groups.count < 4096 else { throw NSError(domain:"Analysis",code:1,userInfo:[NSLocalizedDescriptionKey:"超过 4096 个特征实例，无法生成内存有界摘要；请导出原始日志"]) }
        groups[key,default:FrameAccumulator()].append(event)
    }
    static func key(_ event: BLEEvent) -> String {
        let base = (event.serviceUUID ?? "")+"/"+(event.characteristicUUID ?? "")
        return base + (event.characteristicInstanceID.map { " [instance=\($0)]" } ?? "")
    }
    func comparing(to other: SessionAnalysis) -> [CharacteristicDiff] {
        Set(groups.keys).union(other.groups.keys).sorted().map { key in
            let a = groups[key] ?? FrameAccumulator(), b = other.groups[key] ?? FrameAccumulator()
            return CharacteristicDiff(key:key,baselineSamples:a.count,changedSamples:b.count,baselineHz:a.frequency,changedHz:b.frequency,latestChangedOffsets:ByteDiff.compare(a.latest ?? Data(),b.latest ?? Data()).changedOffsets,changedPeriod:b.result)
        }
    }
}

enum ReadOnlyOperation: Equatable, Sendable {
    case read(String)
    case subscribe(String)
}
enum ReadOnlyDiagnosticPlanner {
    static func operations(for characteristic: GATTCharacteristic, subscribe: Bool) -> [ReadOnlyOperation] {
        var result: [ReadOnlyOperation] = []
        if characteristic.properties.contains("Read") { result.append(.read(characteristic.id)) }
        if subscribe && (characteristic.properties.contains("Notify") || characteristic.properties.contains("Indicate")) { result.append(.subscribe(characteristic.id)) }
        return result
    }
}


enum ConnectionRequestDisposition: Equatable { case start, showExisting, switchRequired, disconnecting }
enum ConnectionRequestPolicy {
    static func evaluate(requested: UUID, active: UUID?, disconnecting: Bool) -> ConnectionRequestDisposition {
        if disconnecting { return .disconnecting }
        guard let active else { return .start }
        return active == requested ? .showExisting : .switchRequired
    }
}
extension DiagnosticState {
    var displayName: String {
        switch self {
        case .idle: "未开始"
        case .connecting: "正在连接"
        case .discovering: "正在发现 GATT"
        case .collecting: "只读采集中"
        case .stopped: "已停止"
        case .failed: "连接中断或诊断异常"
        }
    }
}
