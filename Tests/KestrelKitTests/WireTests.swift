import Foundation
import Testing
@testable import KestrelKit

@Suite("Wire format")
struct WireTests {
    static let signal = WireSignal(
        type: "App.launched",
        time: "2026-10-22T18:59:58.123Z",
        installID: "8F3C2B1A-0D4E-4F5A-9B6C-7D8E9F0A1B2C",
        sessionID: "1B2C3D4E-5F60-4718-8293-A4B5C6D7E8F9",
        app: .init(bundleID: "com.example.app", version: "1.4.0", build: "57"),
        device: .init(platform: "iOS", osVersion: "18.2", model: "iPhone16,2", locale: "nb_NO"),
        flags: .init(debug: false, testflight: false, simulator: false),
        payload: ["plan": "pro"]
    )

    @Test("A batch encodes exactly as the protocol describes")
    func goldenBatch() throws {
        let line = try Wire.makeEncoder().encode(Self.signal)
        let body = Wire.body(lines: [line], sentAt: Date(timeIntervalSince1970: 1_792_695_600))
        let expected = #"{"sdk":{"name":"kestrelkit","version":"\#(Kestrel.sdkVersion)"},"sent_at":"2026-10-22T19:00:00.000Z","signals":[{"app":{"build":"57","bundle_id":"com.example.app","version":"1.4.0"},"device":{"locale":"nb_NO","model":"iPhone16,2","os_version":"18.2","platform":"iOS"},"flags":{"debug":false,"simulator":false,"testflight":false},"install_id":"8F3C2B1A-0D4E-4F5A-9B6C-7D8E9F0A1B2C","payload":{"plan":"pro"},"session_id":"1B2C3D4E-5F60-4718-8293-A4B5C6D7E8F9","time":"2026-10-22T18:59:58.123Z","type":"App.launched"}]}"#
        #expect(String(decoding: body, as: UTF8.self) == expected)
    }

    @Test("The protocol document's example decodes into the same fields")
    func protocolExample() throws {
        let example = """
        {"sent_at":"2026-10-22T19:00:00.000Z","sdk":{"name":"kestrelkit","version":"0.1.0"},
         "signals":[{"type":"App.launched","time":"2026-10-22T18:59:58.123Z",
           "install_id":"8F3C2B1A-0D4E-4F5A-9B6C-7D8E9F0A1B2C","session_id":"1B2C3D4E-5F60-4718-8293-A4B5C6D7E8F9",
           "app":{"bundle_id":"com.example.app","version":"1.4.0","build":"57"},
           "device":{"platform":"iOS","os_version":"18.2","model":"iPhone16,2","locale":"nb_NO"},
           "flags":{"debug":false,"testflight":false,"simulator":false},
           "payload":{"plan":"pro"}}]}
        """
        let batch = try JSONDecoder().decode(RecordedRequest.Batch.self, from: Data(example.utf8))
        #expect(batch.signals == [Self.signal])
        #expect(batch.sdk == ["name": "kestrelkit", "version": "0.1.0"])
        #expect(batch.sentAt == "2026-10-22T19:00:00.000Z")
    }

    @Test("Several signals are joined with commas")
    func severalSignals() throws {
        let line = try Wire.makeEncoder().encode(Self.signal)
        let body = Wire.body(lines: [line, line, line], sentAt: Date())
        let batch = try JSONDecoder().decode(RecordedRequest.Batch.self, from: body)
        #expect(batch.signals.count == 3)
        #expect(Wire.body(lines: [line, line], sentAt: Date()).count == Wire.envelopeSize + 2 * line.count + 1)
    }

    @Test("Timestamps are UTC with milliseconds", arguments: [
        (0.0, "1970-01-01T00:00:00.000Z"),
        (1_792_695_598.123, "2026-10-22T18:59:58.123Z"),
        (951_782_400.5, "2000-02-29T00:00:00.500Z"),
        (4_102_444_799.999, "2099-12-31T23:59:59.999Z"),
        (-1.0, "1969-12-31T23:59:59.000Z"),
    ])
    func timestamps(seconds: Double, expected: String) {
        #expect(Wire.timestamp(Date(timeIntervalSince1970: seconds)) == expected)
    }

    @Test("Requests carry the key, the content type and the endpoint")
    func requestHeaders() {
        let uploader = Uploader(
            endpoint: Uploader.endpoint(for: URL(string: "https://kestrel.example.com/base/")!),
            key: TestKey.value,
            session: mockSession()
        )
        let request = uploader.request(for: Data("{}".utf8))
        #expect(request.url?.absoluteString == "https://kestrel.example.com/base/ingest/v1/signals")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Kestrel-Key") == TestKey.value)
        #expect(request.value(forHTTPHeaderField: "Content-Encoding") == nil)
    }

    @Test("Device helpers format versions and locales")
    func deviceHelpers() {
        #expect(DeviceInfo.osVersion(OperatingSystemVersion(majorVersion: 18, minorVersion: 2, patchVersion: 0)) == "18.2")
        #expect(DeviceInfo.osVersion(OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 1)) == "15.1.1")
        #expect(DeviceInfo.localeIdentifier("nb_NO@calendar=gregorian") == "nb_NO")
        #expect(DeviceInfo.localeIdentifier("") == "unknown")
        let current = DeviceInfo.current()
        #expect(!current.model.isEmpty)
        #expect(!current.platform.isEmpty)
    }
}
