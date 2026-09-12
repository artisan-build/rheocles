import Foundation
import Testing

@testable import RheoclesCore

@Suite("Streams")
struct StreamTests {
    @Test("Ids are kind-prefixed and URL-safe whatever the device identifier holds")
    func ids() {
        #expect(StreamInfo.makeID(.camera, "0x2300000fd9009c") == "camera:0x2300000fd9009c")
        #expect(
            StreamInfo.makeID(
                .microphone, "AppleUSBAudioEngine:Focusrite:Scarlett 2i2 USB:Y8CABR91C1CA8A:1,2")
                == "microphone:AppleUSBAudioEngine_Focusrite_Scarlett_2i2_USB_Y8CABR91C1CA8A_1_2")
        #expect(
            StreamInfo.makeID(.display, "56A96CFC-7F21-168E-0857-D6964E3302DB").hasPrefix(
                "display:56A96CFC-"))
        let id = StreamInfo.makeID(.window, "9565/é ?")
        #expect(!id.contains(" ") && !id.contains("/") && !id.contains("?") && !id.contains("é"))
    }

    @Test("A stream encodes with the documented keys and decodes back")
    func json() throws {
        let stream = StreamInfo(
            id: "camera:x", kind: .camera, name: "Cam", model: "M",
            capabilities: .init(video: .init(width: 1920, height: 1080, maxFrameRate: 30)))
        let data = Response(json: stream).body
        let text = String(decoding: data, as: UTF8.self)
        #expect(
            text
                == #"{"armed":false,"capabilities":{"video":{"height":1080,"maxFrameRate":30,"width":1920}},"id":"camera:x","kind":"camera","model":"M","name":"Cam"}"#
        )
        #expect(try JSONDecoder().decode(StreamInfo.self, from: data) == stream)
    }

    /// Runs against whatever this machine has. On CI that is no camera, no
    /// screen grant and possibly no microphone; the catalog must still answer,
    /// and system audio is always there.
    @Test("The real catalog enumerates without crashing and always offers system audio")
    func realCatalog() async {
        let streams = await DeviceCatalog.standard.streams()
        #expect(streams.contains { $0.kind == .systemAudio })
        #expect(Set(streams.map(\.id)).count == streams.count, "ids are unique")
        for stream in streams {
            #expect(!stream.name.isEmpty)
            #expect(!stream.armed)
            switch stream.kind {
            case .display, .window, .camera: #expect(stream.capabilities.video != nil)
            case .microphone, .systemAudio: #expect(stream.capabilities.audio != nil)
            }
        }
        let permissions = DeviceCatalog.permissions()
        _ = permissions.camera
    }
}
