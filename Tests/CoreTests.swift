import XCTest
import Foundation
#if canImport(BLEInspectorCore)
@testable import BLEInspectorCore
#else
@testable import BLEInspector
#endif

final class CoreTests: XCTestCase, @unchecked Sendable {
    func testSIGUUIDNormalization() {
        XCTAssertEqual(SIG.normalized("0000180f-0000-1000-8000-00805f9b34fb"),"180F")
        XCTAssertEqual(SIG.name("180F"),"Battery")
        XCTAssertTrue(SIG.name("E7810B92-73AE-499D-8C15-FAA9AEF0C3F2").contains("未确认"))
    }
    func testHexAndBase64() {
        let d = Data([0,1,128,255]); XCTAssertEqual(Data(hex:d.hex),d)
        XCTAssertEqual(Data(base64Encoded:d.base64EncodedString()),d)
        XCTAssertNil(Data(hex:"0")); XCTAssertNil(Data(hex:"GG")); XCTAssertEqual(Data(hex:" 0a \n ff "),Data([10,255]))
    }
    func testDiffLengthAndOffsets() {
        XCTAssertEqual(ByteDiff.compare(Data([1,2,3]),Data([1,4,3,5])).changedOffsets,[1,3])
        XCTAssertEqual(ByteDiff.compare(Data(),Data()).changedOffsets,[])
    }
    func sample(_ id:UUID, byte:UInt8, time:Double) -> BLEEvent {
        var e = BLEEvent(sessionID:id,eventType:"value",payload:Data([0xAA,byte]),detail:"mock")
        e.monotonicTimestamp = time; e.serviceUUID = "180F"; e.characteristicUUID = "2A19"; return e
    }
    func testNotificationStatisticsAndHeuristics() {
        let id = UUID(); let e = (0..<5).map { sample(id,byte:UInt8($0),time:Double($0)) }
        let a = ProtocolHeuristicsEngine.analyze(e)
        XCTAssertEqual(a.samples,5); XCTAssertEqual(a.lengths,[2]); XCTAssertEqual(a.changedOffsets,[1]); XCTAssertEqual(a.meanInterval,1)
        XCTAssertTrue(a.hypotheses.contains { $0.contains("计数器") }); XCTAssertTrue(a.hypotheses.contains { $0.contains("周期性") })
    }
    func testSessionDiffFrequency() {
        let id = UUID(); let a = [sample(id,byte:1,time:0),sample(id,byte:2,time:2)]
        let b = [sample(id,byte:3,time:0),sample(id,byte:4,time:1)]
        let diff = DataDiffEngine.compare(a,b)
        XCTAssertEqual(diff.count,1); XCTAssertEqual(diff[0].baselineHz,0.5); XCTAssertEqual(diff[0].changedHz,1); XCTAssertEqual(diff[0].latestChangedOffsets,[1])
    }
    func testChecksumHintsAreUnconfirmed() {
        let id = UUID(); let samples = (1...5).map { i -> BLEEvent in BLEEvent(sessionID:id,eventType:"value",payload:Data([1,UInt8(i),UInt8(i+1)])) }
        XCTAssertTrue(ProtocolHeuristicsEngine.analyze(samples).hypotheses.contains { $0.contains("校验字段") && $0.contains("可能") })
    }
    func testEmptyAnalysisAndEndian() {
        XCTAssertEqual(ProtocolHeuristicsEngine.analyze([]).samples,0)
        XCTAssertTrue(ProtocolHeuristicsEngine.integers(Data([1,2])).contains("LE 513 / BE 258"))
    }
    func testSerializationContextAndBinary() throws {
        let id = UUID(); var e = sample(id,byte:255,time:4); e.peripheralIdentifier = "private-id"; e.errorDescription = "mock failure"
        let data = try LogCodec.encoder().encode(e), decoded = try LogCodec.decoder().decode(BLEEvent.self,from:data)
        XCTAssertEqual(decoded.payload,e.payload); XCTAssertEqual(decoded.sessionID,id); XCTAssertEqual(decoded.monotonicTimestamp,4)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual(object["rawHexPayload"] as? String,"AA FF"); XCTAssertEqual(object["payloadLength"] as? Int,2)
    }
    func testEmptyPayloadAndInvalidBase64() throws {
        let e = BLEEvent(sessionID:UUID(),eventType:"value",payload:Data())
        let decoded = try LogCodec.decoder().decode(BLEEvent.self,from:LogCodec.encoder().encode(e)); XCTAssertEqual(decoded.payload,Data())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:LogCodec.encoder().encode(e)) as? [String:Any])
        object["base64Payload"] = "!invalid!"
        XCTAssertThrowsError(try LogCodec.decoder().decode(BLEEvent.self,from:JSONSerialization.data(withJSONObject:object)))
    }
    func testCSVQuoteNewline() {
        let e = BLEEvent(sessionID:UUID(),eventType:"error",detail:"a,\"b\"\nc")
        XCTAssertTrue(LogCodec.csv(e).contains("\"a,\"\"b\"\"\nc\""))
    }
    func testProfileLoadAndNoInventedUUID() throws {
        let data = try JSONEncoder().encode([DeviceProfile.yadea]); let profiles = try DeviceProfileRepository.load(data)
        XCTAssertEqual(profiles[0].characteristicPrefixes,["BEF8E7E0","BEF8E7E1"])
        XCTAssertEqual(profiles[0].services[0],"E7810B92-73AE-499D-8C15-FAA9AEF0C3F2")
        XCTAssertThrowsError(try DeviceProfileRepository.load(try JSONEncoder().encode([DeviceProfile.yadea,DeviceProfile.yadea])))
    }
    func testAdvertisementSerialization() throws {
        let a = Advertisement(name:"Mock",services:["180F"],serviceData:["180F":Data([4])],manufacturer:Data([1,2]),connectable:false,txPower:-4)
        XCTAssertEqual(try JSONDecoder().decode(Advertisement.self,from:JSONEncoder().encode(a)),a)
    }
    func testMockDiagnosticStateMachine() {
        var m = DiagnosticMachine(); m.discovered(); XCTAssertEqual(m.state,.idle)
        m.start(); XCTAssertEqual(m.state,.connecting); m.connected(); XCTAssertEqual(m.state,.discovering)
        m.discovered(); XCTAssertEqual(m.state,.collecting); m.stop(); XCTAssertEqual(m.state,.stopped)
        m.start(); m.fail(); m.connected(); XCTAssertEqual(m.state,.failed)
    }
    func testRotationAndExports() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir,rotationBytes:1), id = UUID()
        let record = SessionRecord(id:id,started:Date(),note:"private-note",device:nil,topology:[])
        store.save(record)
        for i in 0..<3 { store.append(sample(id,byte:UInt8(i),time:Double(i))); await store.barrier() }
        let files = try FileManager.default.contentsOfDirectory(at:dir.appendingPathComponent(id.uuidString),includingPropertiesForKeys:nil).filter { $0.pathExtension == "jsonl" }
        XCTAssertEqual(files.count,3)
        let samples = try await store.samples(id); XCTAssertEqual(samples.count,3)
        let history = try await store.history(); XCTAssertEqual(history.count,1)
        for format in ExportFormat.allCases {
            let url = try await store.export(record,format:format,privacy:PrivacyOptions(hideIdentifiers:false,removePayloads:false))
            let d = try Data(contentsOf:url)
            XCTAssertFalse(d.isEmpty)
            if format == .json { let json = try XCTUnwrap(JSONSerialization.jsonObject(with:d) as? [String:Any]); XCTAssertEqual((json["events"] as? [Any])?.count,3) }
            if format == .jsonl { let lines = String(decoding:d,as:UTF8.self).split(separator:"\n"); XCTAssertEqual(lines.count,4); for line in lines { _ = try LogCodec.decoder().decode(BLEEvent.self,from:Data(line.utf8)) } }
            if format == .csv { XCTAssertTrue(String(decoding:d,as:UTF8.self).hasPrefix("timestamp,")) }
            if format == .markdown { XCTAssertTrue(String(decoding:d,as:UTF8.self).contains("推测")) }
        }
    }
    func testRotationLimitAndCorruptLog() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir,rotationBytes:1), id = UUID()
        for i in 0..<66 { store.append(sample(id,byte:UInt8(i),time:Double(i))); await store.barrier() }
        let samples = try await store.samples(id); XCTAssertEqual(samples.count,64)
        let file = dir.appendingPathComponent(id.uuidString).appendingPathComponent("events-0000.jsonl")
        try Data("corrupt\n".utf8).write(to:file)
        do { _ = try await store.samples(id); XCTFail("损坏日志不能被静默跳过") } catch { }
    }
    func testStreamingFullSessionAndEarlyTimeRange() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir), id = UUID(), start = Date(timeIntervalSince1970:1_700_000_000)
        store.save(SessionRecord(id:id,started:start,note:"",device:nil,topology:[]))
        for batch in 0..<30 {
            for j in 0..<200 {
                let index = batch*200+j
                var event = sample(id,byte:UInt8(truncatingIfNeeded:index),time:Double(index))
                event.timestamp = start.addingTimeInterval(Double(index)); store.append(event)
            }
            await store.barrier()
        }
        let all = try await store.analysis(id)
        XCTAssertEqual(all.groups["180F/2A19"]?.count,6000)
        let early = try await store.analysis(id,since:start.addingTimeInterval(10),until:start.addingTimeInterval(20))
        XCTAssertEqual(early.groups["180F/2A19"]?.count,11)
        let recent = try await store.samples(id); XCTAssertEqual(recent.count,80)
        XCTAssertEqual(recent.first?.monotonicTimestamp,5920)
        let selected = try await store.samples(id,since:start.addingTimeInterval(10),until:start.addingTimeInterval(20))
        XCTAssertEqual(selected.count,11)
        do { _ = try await store.analysis(id,since:start.addingTimeInterval(1),until:start); XCTFail("无效时间段应报错") } catch { }
    }
    func testExportSnapshotWhileRecordingContinues() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir), id = UUID()
        let record = SessionRecord(id:id,started:Date(),note:"",device:nil,topology:[]); store.save(record)
        for i in 0..<200 { store.append(sample(id,byte:UInt8(truncatingIfNeeded:i),time:Double(i))) }
        await store.barrier()
        let export = Task { try await store.export(record,format:.jsonl,privacy:PrivacyOptions(hideIdentifiers:false,removePayloads:false)) }
        for i in 200..<400 { store.append(sample(id,byte:UInt8(truncatingIfNeeded:i),time:Double(i))) }
        await store.barrier()
        let url = try await export.value
        let lines = try String(contentsOf:url,encoding:.utf8).split(separator:"\n")
        XCTAssertGreaterThanOrEqual(lines.count,201); XCTAssertLessThanOrEqual(lines.count,401)
        for line in lines { _ = try LogCodec.decoder().decode(BLEEvent.self,from:Data(line.utf8)) }
        let analysis = try await store.analysis(id); XCTAssertEqual(analysis.groups.values.first?.count,400)
    }
    func testRepeatedUUIDInstancesStaySeparate() throws {
        let id = UUID(); var one = sample(id,byte:1,time:0), two = sample(id,byte:2,time:1)
        one.characteristicInstanceID = "0:0:2A19"; two.characteristicInstanceID = "1:0:2A19"
        var analysis = SessionAnalysis(); try analysis.append(one); try analysis.append(two)
        XCTAssertEqual(analysis.groups.count,2)
        let decoded = try LogCodec.decoder().decode(BLEEvent.self,from:LogCodec.encoder().encode(one))
        XCTAssertEqual(decoded.characteristicInstanceID,one.characteristicInstanceID)
    }
    func testReadOnlyDiagnosticPlannerWithMockBLE() throws {
        struct MockBLE {
            var calls: [ReadOnlyOperation] = []
            var values: [BLEEvent] = []
            mutating func perform(_ operation: ReadOnlyOperation, session:UUID) {
                calls.append(operation)
                if case .read(let id) = operation {
                    var event = BLEEvent(sessionID:session,characteristicUUID:"2A19",eventType:"value",payload:Data([75]))
                    event.characteristicInstanceID = id; values.append(event)
                }
            }
        }
        let readable = GATTCharacteristic(id:"battery",uuid:"2A19",service:"180F",properties:["Read","Notify","Write"])
        let writeOnly = GATTCharacteristic(id:"control",uuid:"unknown",service:"vendor",properties:["Write","Write Without Response"])
        var mock = MockBLE(); let session = UUID(); var state = DiagnosticMachine()
        state.start(); state.connected(); state.discovered()
        for characteristic in [readable,writeOnly] {
            for operation in ReadOnlyDiagnosticPlanner.operations(for:characteristic,subscribe:true) { mock.perform(operation,session:session) }
        }
        XCTAssertEqual(mock.calls,[.read("battery"),.subscribe("battery")]); XCTAssertEqual(mock.values.count,1)
        XCTAssertEqual(ReadOnlyDiagnosticPlanner.operations(for:readable,subscribe:false),[.read("battery")])
        var analysis = SessionAnalysis(); for value in mock.values { try analysis.append(value) }
        XCTAssertEqual(analysis.groups.values.first?.count,1); XCTAssertEqual(state.state,.collecting)
    }
    func testPayloadRedactionAlsoRemovesAdvertisementText() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir), id = UUID()
        let record = SessionRecord(id:id,started:Date(),note:"",device:nil,topology:[]); store.save(record)
        store.append(BLEEvent(sessionID:id,eventType:"advertisement",detail:"manufacturerHex=DE AD BE EF"))
        for format in ExportFormat.allCases {
            let url = try await store.export(record,format:format,privacy:PrivacyOptions(hideIdentifiers:false,removePayloads:true))
            XCTAssertFalse(try String(contentsOf:url,encoding:.utf8).contains("DE AD BE EF"))
        }
    }
    func testNotificationStateSurvivesPrivacyRedaction() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir), id = UUID()
        let record = SessionRecord(id:id,started:Date(),note:"",device:nil,topology:[]); store.save(record)
        var event = sample(id,byte:1,time:0); event.notificationEnabled = true; store.append(event)
        let url = try await store.export(record,format:.jsonl,privacy:PrivacyOptions())
        let lines = try String(contentsOf:url,encoding:.utf8).split(separator:"\n")
        let decoded = try LogCodec.decoder().decode(BLEEvent.self,from:Data(lines.last!.utf8))
        XCTAssertEqual(decoded.notificationEnabled,true)
        var accumulator = FrameAccumulator(); accumulator.append(decoded)
        XCTAssertTrue(accumulator.result.facts.contains { $0.contains("通知开启期间回调：1") })
    }
    func testConnectionRequestPolicyIsIdempotent() {
        let first = UUID(), other = UUID()
        XCTAssertEqual(ConnectionRequestPolicy.evaluate(requested:first,active:nil,disconnecting:false),.start)
        XCTAssertEqual(ConnectionRequestPolicy.evaluate(requested:first,active:first,disconnecting:false),.showExisting)
        XCTAssertEqual(ConnectionRequestPolicy.evaluate(requested:other,active:first,disconnecting:false),.switchRequired)
        XCTAssertEqual(ConnectionRequestPolicy.evaluate(requested:first,active:first,disconnecting:true),.disconnecting)
    }
    func testTextLogAndReportExports() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir), id = UUID()
        let record = SessionRecord(id:id,started:Date(),note:"",device:nil,topology:[]); store.save(record)
        var value = sample(id,byte:255,time:0); value.peripheralIdentifier = "PRIVATE-DEVICE"; value.deviceName = "PRIVATE-NAME"; store.append(value)
        for format in [ExportFormat.text,.reportText] {
            let file = try await store.export(record,format:format,privacy:PrivacyOptions())
            XCTAssertEqual(file.pathExtension,"txt")
            let text = try String(contentsOf:file,encoding:.utf8)
            XCTAssertFalse(text.contains("PRIVATE-DEVICE")); XCTAssertFalse(text.contains("PRIVATE-NAME"))
            if format == .text { XCTAssertTrue(text.contains("AA FF")); XCTAssertTrue(text.contains("value")) }
            if format == .reportText { XCTAssertTrue(text.contains("诊断报告")); XCTAssertTrue(text.contains("观测事实")); XCTAssertTrue(text.contains("推测（未确认）")) }
        }
        let redacted = try await store.export(record,format:.text,privacy:PrivacyOptions(hideIdentifiers:true,removePayloads:true))
        XCTAssertFalse(try String(contentsOf:redacted,encoding:.utf8).contains("AA FF"))
    }
    func testSessionDeletionProtectsActiveRecording() async throws {
        let id = UUID(), other = UUID()
        XCTAssertFalse(SessionDeletionPolicy.canDelete(id,recordingSessionID:id))
        XCTAssertTrue(SessionDeletionPolicy.canDelete(id,recordingSessionID:other))
        XCTAssertTrue(SessionDeletionPolicy.canDelete(id,recordingSessionID:nil))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir)
        store.save(SessionRecord(id:id,started:Date(),note:"",device:nil,topology:[])); store.append(sample(id,byte:1,time:0)); await store.barrier()
        do { try await store.deleteSession(id,preservingActiveSession:id); XCTFail("正在录制的会话不能删除") }
        catch { XCTAssertEqual((error as NSError).code,7) }
        let history = try await store.history(); XCTAssertEqual(history.count,1)
        let events = try await store.samples(id); XCTAssertEqual(events.count,1)
    }
    func testSessionDeletionCleansOnlyTargetAndPreventsResurrection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir), first = UUID(), second = UUID()
        let a = SessionRecord(id:first,started:Date(),ended:Date(),note:"first",device:nil,topology:[])
        let b = SessionRecord(id:second,started:Date(),ended:Date(),note:"second",device:nil,topology:[])
        store.save(a); store.save(b); store.append(sample(first,byte:1,time:0)); store.append(sample(second,byte:2,time:0))
        let aFile = try await store.export(a,format:.text,privacy:PrivacyOptions())
        let bFile = try await store.export(b,format:.text,privacy:PrivacyOptions())
        try await store.deleteSession(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent(first.uuidString).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:aFile.path)); XCTAssertTrue(FileManager.default.fileExists(atPath:bFile.path))
        store.save(a); store.append(sample(first,byte:3,time:1)); await store.barrier()
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent(first.uuidString).path))
        let history = try await store.history(); XCTAssertEqual(history.map(\.id),[second])
        do { _ = try await store.analysis(first); XCTFail("已删除会话不可分析") } catch { XCTAssertEqual((error as NSError).code,6) }
        try await store.deleteSession(first)
    }
    func testDeletionWithConcurrentExportDoesNotLeaveArtifacts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir), id = UUID(), other = UUID()
        let a = SessionRecord(id:id,started:Date(),ended:Date(),note:"",device:nil,topology:[])
        store.save(a); store.save(SessionRecord(id:other,started:Date(),note:"",device:nil,topology:[]))
        for i in 0..<100 { store.append(sample(id,byte:UInt8(i),time:Double(i))) }; await store.barrier()
        let exporting = Task { try await store.export(a,format:.jsonl,privacy:PrivacyOptions()) }
        let deleting = Task { try await store.deleteSession(id,preservingActiveSession:other) }
        for i in 0..<100 { store.append(sample(other,byte:UInt8(i),time:Double(i))) }
        _ = await exporting.result; try await deleting.value; await store.barrier()
        let analysis = try await store.analysis(other); XCTAssertEqual(analysis.groups.values.first?.count,100)
        let exports = dir.appendingPathComponent("Exports")
        if FileManager.default.fileExists(atPath:exports.path) {
            let files = try FileManager.default.contentsOfDirectory(at:exports,includingPropertiesForKeys:nil)
            XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix("BLEInspector-\(id)-") })
        }
    }
    func testExportPrivacy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = EventLogStore(root:dir), id = UUID()
        let record = SessionRecord(id:id,started:Date(),note:"SECRET",device:nil,topology:[])
        store.save(record)
        var e = sample(id,byte:1,time:0); e.peripheralIdentifier = "SECRET"; e.deviceName = "SECRET"; e.detail = "SECRET"; e.errorDescription = "SECRET"; store.append(e)
        let url = try await store.export(record,format:.json,privacy:PrivacyOptions(hideIdentifiers:true,removePayloads:true))
        let text = try String(contentsOf:url,encoding:.utf8); XCTAssertFalse(text.contains("SECRET")); XCTAssertTrue(text.contains("\"payloadLength\":0"))
    }
}

#if canImport(CoreBluetooth) && !canImport(BLEInspectorCore)
import CoreBluetooth
final class AdvertisementParsingTests: XCTestCase {
    func testCoreBluetoothDictionary() {
        let parsed = BluetoothCentralManager.advertisement([
            CBAdvertisementDataLocalNameKey:"Mock BLE",
            CBAdvertisementDataServiceUUIDsKey:[CBUUID(string:"180F")],
            CBAdvertisementDataServiceDataKey:[CBUUID(string:"180F"):Data([50])],
            CBAdvertisementDataManufacturerDataKey:Data([1,2]),
            CBAdvertisementDataIsConnectable:NSNumber(value:true),
            CBAdvertisementDataTxPowerLevelKey:NSNumber(value:-4)
        ],fallback:nil)
        XCTAssertEqual(parsed.name,"Mock BLE"); XCTAssertEqual(parsed.services,["180F"])
        XCTAssertEqual(parsed.serviceData["180F"],Data([50])); XCTAssertEqual(parsed.manufacturer,Data([1,2])); XCTAssertEqual(parsed.connectable,true); XCTAssertEqual(parsed.txPower,-4)
    }
}
#endif
